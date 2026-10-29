import asyncio
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy import event, inspect, select, text
from sqlalchemy.exc import DataError, IntegrityError, OperationalError

from app import auth
from app.models import Base, LoginSession, User

PASSWORD = " account test passphrase "


async def register(client, username="Account_One", password=PASSWORD):
    return await client.post(
        "/api/v1/auth/register", json={"username": username, "password": password}
    )


def bearer(token):
    return {"Authorization": "Bearer " + token}


@pytest.mark.asyncio
async def test_registration_persists_only_hashes_and_matches_contract(account_client):
    application, client = account_client
    response = await register(client)
    assert response.status_code == 201
    assert response.headers["cache-control"] == "no-store"
    result = response.json()
    assert set(result) == {
        "user_id",
        "username",
        "access_token",
        "token_type",
        "expires_at",
    }
    assert UUID(result["user_id"]).version == 4
    assert result["username"] == "account_one" and result["token_type"] == "Bearer"
    assert PASSWORD not in response.text
    async with application.state.database_sessions() as session:
        user = await session.get(User, UUID(result["user_id"]))
        stored = await session.get(
            LoginSession, auth.token_digest(result["access_token"])
        )
        assert user.password_hash.startswith("$argon2id$")
        assert auth.passwords.verify(PASSWORD, user.password_hash)
        assert not auth.passwords.verify(PASSWORD.strip(), user.password_hash)
        assert stored.user_id == user.user_id
        assert stored.expires_at - stored.issued_at == timedelta(days=365)
        assert stored.revoked_at is None
        assert len(stored.token_hash) == 32
        assert datetime.fromisoformat(result["expires_at"]) == stored.expires_at
        assert result["access_token"] not in repr(stored.token_hash)


@pytest.mark.asyncio
async def test_case_insensitive_and_concurrent_registration_is_unique(account_client):
    application, client = account_client
    responses = await asyncio.gather(
        register(client, "Concurrent"), register(client, "CONCURRENT")
    )
    assert sorted(response.status_code for response in responses) == [201, 409]
    conflict = next(response for response in responses if response.status_code == 409)
    assert conflict.json()["error"]["code"] == "USERNAME_TAKEN"
    async with application.state.database_sessions() as session:
        assert len((await session.scalars(select(User))).all()) == 1
        assert len((await session.scalars(select(LoginSession))).all()) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "changes",
    [
        {"username": "ab"},
        {"username": "a" * 33},
        {"username": " spaced"},
        {"username": "测试账号"},
        {"username": "new\n"},
        {"username": "abc' OR 1=1"},
        {"password": "x" * 14},
        {"password": "x" * 129},
        {"username": 123},
        {"password": 123},
        {"password": None},
        {"private-key-name": "must-not-echo"},
    ],
)
async def test_invalid_credentials_do_not_echo_input(account_client, caplog, changes):
    _, client = account_client
    payload = {"username": "valid_name", "password": PASSWORD} | changes
    response = await client.post("/api/v1/auth/register", json=payload)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"
    assert response.headers["cache-control"] == "no-store"
    assert PASSWORD not in response.text + caplog.text
    for value in changes.values():
        if isinstance(value, str) and len(value) > 6:
            assert value not in response.text + caplog.text
    assert "private-key-name" not in response.text


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "username,password", [("a_0", "密码🙂" * 5), ("a" * 32, "x" * 128)]
)
async def test_valid_input_boundaries(account_client, username, password):
    _, client = account_client
    assert (await register(client, username, password)).status_code == 201
    response = await client.post(
        "/api/v1/auth/login", json={"username": username.upper(), "password": password}
    )
    assert response.status_code == 200


@pytest.mark.asyncio
async def test_malformed_json_is_400_without_echo(account_client, caplog):
    _, client = account_client
    response = await client.post(
        "/api/v1/auth/login",
        content='{"password":"sensitive-malformed',
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_REQUEST"
    assert "sensitive-malformed" not in response.text + caplog.text


@pytest.mark.asyncio
async def test_login_preserves_identity_and_creates_independent_sessions(
    account_client,
):
    application, client = account_client
    original = (await register(client)).json()
    response = await client.post(
        "/api/v1/auth/login", json={"username": "ACCOUNT_ONE", "password": PASSWORD}
    )
    assert response.status_code == 200
    current = response.json()
    assert original["user_id"] == current["user_id"]
    assert original["access_token"] != current["access_token"]
    async with application.state.database_sessions() as session:
        assert len((await session.scalars(select(LoginSession))).all()) == 2
    response = await client.post(
        "/api/v1/auth/logout", headers=bearer(current["access_token"])
    )
    assert response.status_code == 204 and response.content == b""
    assert response.headers["cache-control"] == "no-store"
    assert (
        await client.post(
            "/api/v1/auth/logout", headers=bearer(current["access_token"])
        )
    ).status_code == 401
    assert (
        await client.post(
            "/api/v1/auth/logout", headers=bearer(original["access_token"])
        )
    ).status_code == 204


@pytest.mark.asyncio
async def test_unknown_account_and_wrong_password_have_identical_failures(
    account_client, monkeypatch
):
    _, client = account_client
    await register(client)
    original = auth.passwords.verify_and_update
    calls = []

    def verify(password, encoded):
        calls.append(encoded)
        return original(password, encoded)

    monkeypatch.setattr(auth.passwords, "verify_and_update", verify)
    failures = []
    for username in ("account_one", "unknown_name"):
        response = await client.post(
            "/api/v1/auth/login",
            json={"username": username, "password": "different passphrase"},
        )
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"
        failures.append(response.json())
    assert failures[0] == failures[1]
    assert len(calls) == 2


@pytest.mark.asyncio
@pytest.mark.parametrize("offset,expected", [(-1, 204), (0, 401), (1, 401)])
async def test_exact_fixed_expiry_without_renewal(
    account_client, monkeypatch, offset, expected
):
    application, client = account_client
    issued_at = datetime(2026, 1, 1, tzinfo=UTC)
    monkeypatch.setattr(auth, "now_utc", lambda: issued_at)
    result = (await register(client)).json()
    expires_at = issued_at + timedelta(days=365)
    assert datetime.fromisoformat(result["expires_at"]) == expires_at
    monkeypatch.setattr(auth, "now_utc", lambda: expires_at + timedelta(seconds=offset))
    response = await client.post(
        "/api/v1/auth/logout", headers=bearer(result["access_token"])
    )
    assert response.status_code == expected
    async with application.state.database_sessions() as session:
        stored = await session.get(
            LoginSession, auth.token_digest(result["access_token"])
        )
        assert stored.expires_at == expires_at


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "authorization",
    [None, "Basic not-a-token", "Bearer", "Bearer ", "Bearer unknown-token"],
)
async def test_missing_or_invalid_token_is_401(account_client, authorization):
    _, client = account_client
    response = await client.post(
        "/api/v1/auth/logout",
        headers={} if authorization is None else {"Authorization": authorization},
    )
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json()["error"]["code"] == "AUTH_REQUIRED"


@pytest.mark.asyncio
async def test_two_accounts_keep_independent_sessions(account_client):
    application, client = account_client
    first = (await register(client, "first_user")).json()
    second = (await register(client, "second_user")).json()
    assert first["user_id"] != second["user_id"]
    assert (
        await client.post("/api/v1/auth/logout", headers=bearer(first["access_token"]))
    ).status_code == 204
    async with application.state.database_sessions() as session:
        stored = await session.get(
            LoginSession, auth.token_digest(second["access_token"])
        )
        assert stored.revoked_at is None


@pytest.mark.asyncio
async def test_session_failure_rolls_back_registration(
    account_client, monkeypatch, caplog
):
    application, client = account_client
    original = auth.issue_session

    def fail_session(session, user):
        raise RuntimeError("private-database-password-and-token")

    monkeypatch.setattr(auth, "issue_session", fail_session)
    response = await register(client)
    assert response.status_code == 500
    assert response.json()["error"]["code"] == "INTERNAL_ERROR"
    assert "private-database-password-and-token" not in response.text + caplog.text
    async with application.state.database_sessions() as session:
        assert (await session.scalars(select(User))).all() == []
    monkeypatch.setattr(auth, "issue_session", original)
    assert (await register(client)).status_code == 201


@pytest.mark.asyncio
async def test_database_failure_is_503_and_redacted(account_client, caplog):
    application, client = account_client
    engine = application.state.database_sessions.kw["bind"]

    def fail(*_):
        raise OperationalError(
            "private-sql", None, RuntimeError("private-connection-string")
        )

    event.listen(engine.sync_engine, "before_cursor_execute", fail)
    try:
        response = await client.post(
            "/api/v1/auth/login", json={"username": "valid_user", "password": PASSWORD}
        )
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", fail)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "SERVICE_UNAVAILABLE"
    assert "private-connection-string" not in response.text + caplog.text
    assert "private-sql" not in response.text + caplog.text


def test_real_migrations_match_models_and_round_trip(account_database):
    _, schema, engine, config = account_database
    with engine.begin() as connection:
        assert set(inspect(connection).get_table_names()) == {
            "users",
            "sessions",
            "alembic_version",
        }
        assert (
            compare_metadata(MigrationContext.configure(connection), Base.metadata)
            == []
        )
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
        command.downgrade(config, "base")
        assert inspect(connection).get_table_names(schema) == ["alembic_version"]
        command.upgrade(config, "head")
        assert set(inspect(connection).get_table_names()) == {
            "users",
            "sessions",
            "alembic_version",
        }


@pytest.mark.parametrize("username", ["Upper", "ab", "bad name", "bad!", "a" * 33])
def test_database_rejects_invalid_username(account_database, username):
    _, _, engine, _ = account_database
    with pytest.raises((IntegrityError, DataError)):
        with engine.begin() as connection:
            connection.execute(
                User.__table__.insert().values(
                    user_id=uuid4(),
                    username=username,
                    password_hash="hash",
                    created_at=datetime.now(UTC),
                )
            )


def test_database_enforces_session_hash_length_and_user_reference(account_database):
    _, _, engine, _ = account_database
    user_id = uuid4()
    with engine.begin() as connection:
        connection.execute(
            User.__table__.insert().values(
                user_id=user_id,
                username="valid_user",
                password_hash="hash",
                created_at=datetime.now(UTC),
            )
        )
    for digest in (b"too-short", b"x" * 32):
        with pytest.raises(IntegrityError):
            with engine.begin() as connection:
                connection.execute(
                    LoginSession.__table__.insert().values(
                        token_hash=digest,
                        user_id=user_id if digest == b"too-short" else uuid4(),
                        issued_at=datetime.now(UTC),
                        expires_at=datetime.now(UTC),
                    )
                )
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT count(*) FROM users")) == 1


@pytest.mark.asyncio
async def test_concurrent_logout_confirms_only_one_revocation(account_client):
    _, client = account_client
    result = (await register(client)).json()
    responses = await asyncio.gather(
        *(
            client.post("/api/v1/auth/logout", headers=bearer(result["access_token"]))
            for _ in range(2)
        )
    )
    assert sorted(response.status_code for response in responses) == [204, 401]


@pytest.mark.asyncio
async def test_password_rehash_is_updated_on_successful_login(account_client):
    from pwdlib import PasswordHash
    from pwdlib.hashers.argon2 import Argon2Hasher

    application, client = account_client
    result = (await register(client)).json()
    old_hash = PasswordHash((Argon2Hasher(time_cost=1),)).hash(PASSWORD)
    async with application.state.database_sessions() as session, session.begin():
        user = await session.get(User, UUID(result["user_id"]))
        user.password_hash = old_hash
    response = await client.post(
        "/api/v1/auth/login", json={"username": "account_one", "password": PASSWORD}
    )
    assert response.status_code == 200
    async with application.state.database_sessions() as session:
        user = await session.get(User, UUID(result["user_id"]))
        assert user.password_hash != old_hash
        assert auth.passwords.verify_and_update(PASSWORD, user.password_hash) == (
            True,
            None,
        )


@pytest.mark.asyncio
async def test_database_session_insert_failure_rolls_back_user(account_client):
    application, client = account_client
    engine = application.state.database_sessions.kw["bind"]

    def fail(connection, cursor, statement, parameters, context, executemany):
        if statement.startswith("INSERT INTO sessions"):
            raise OperationalError(
                "private statement", None, RuntimeError("private credentials")
            )

    event.listen(engine.sync_engine, "before_cursor_execute", fail)
    try:
        response = await register(client)
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", fail)
    assert response.status_code == 503
    async with application.state.database_sessions() as session:
        assert (await session.scalars(select(User))).all() == []
        assert (await session.scalars(select(LoginSession))).all() == []
