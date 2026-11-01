import base64
from datetime import timedelta
from uuid import UUID, uuid1

import pytest
from sqlalchemy import event
from sqlalchemy.exc import OperationalError, TimeoutError
from test_accounts import bearer, register
from test_workout_queries import URL, pack_cursor, seed_workouts, unpack_cursor

from app import auth
from app.models import LoginSession


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "params",
    [{"limit": value} for value in [0, 101, "1.0", "1e0", "true", "", " 1 ", "9" * 200]]
    + [
        {"cursor": value}
        for value in ["", "a" * 2049, "not@base64", "a", "____", "e30"]
    ]
    + [
        {"started_from": value}
        for value in [
            "",
            "2026-02-30T00:00:00Z",
            "2026-11-01T24:00:00Z",
            "2026-11-01T00:00:00+00:00",
            "2026-11-01T00:00:00.1234567Z",
        ]
    ]
    + [
        {"started_before": "not-a-time"},
        {
            "started_from": "2026-11-01T00:00:00Z",
            "started_before": "2026-11-01T00:00:00Z",
        },
        {
            "started_from": "2026-11-02T00:00:00Z",
            "started_before": "2026-11-01T00:00:00Z",
        },
    ],
)
async def test_bad_query_is_422_with_generic_paths(account_client, params):
    _, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    response = await client.get(URL, params=params, headers=headers)
    assert response.status_code == 422, response.text
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"
    assert all(field["path"] == "" for field in response.json()["error"]["fields"])
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.asyncio
async def test_cursor_rejects_malformed_structure_values_and_boundaries(
    account_client, caplog
):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    await seed_workouts(application, account["user_id"], 2)
    page = (await client.get(URL, params={"limit": 1}, headers=headers)).json()
    original = unpack_cursor(page["next_cursor"])
    sensitive = "private-example-do-not-echo"
    invalid = (
        [[], None, sensitive]
        + [
            original | changes
            for changes in [
                {"version": 0},
                {"version": 2},
                {"version": True},
                {"version": "1"},
                {"user_id": str(uuid1())},
                {"last_workout_id": UUID(original["last_workout_id"]).hex},
                {"last_started_at": "2026-11-01T00:00:00+00:00"},
                {"last_started_at": sensitive},
                {sensitive: sensitive},
            ]
        ]
        + [
            {
                name: value
                for name, value in original.items()
                if name != "last_workout_id"
            }
        ]
    )
    for content in invalid:
        response = await client.get(
            URL, params={"cursor": pack_cursor(content)}, headers=headers
        )
        assert response.status_code == 422, response.text
        assert sensitive not in response.text + caplog.text
    for raw in [b"not-json", b"\xff", b"[" * 250 + b"0" + b"]" * 250]:
        value = base64.urlsafe_b64encode(raw).decode().rstrip("=")
        assert (
            await client.get(URL, params={"cursor": value}, headers=headers)
        ).status_code == 422
    for name, boundary in [
        ("started_from", "2026-11-02T00:00:00Z"),
        ("started_before", "2026-11-01T00:00:00Z"),
    ]:
        changed = original | {name: boundary}
        response = await client.get(
            URL,
            params={name: boundary, "cursor": pack_cursor(changed)},
            headers=headers,
        )
        assert response.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize("state", ["missing", "invalid", "expired", "revoked"])
async def test_query_authentication_is_independent_of_cursor(account_client, state):
    application, client = account_client
    account = (await register(client)).json()
    await seed_workouts(application, account["user_id"], 2)
    headers = bearer(account["access_token"])
    cursor = (await client.get(URL, params={"limit": 1}, headers=headers)).json()[
        "next_cursor"
    ]
    if state == "missing":
        headers = {}
    elif state == "invalid":
        headers = bearer("invalid-example-token")
    else:
        async with application.state.database_sessions() as session, session.begin():
            stored = await session.get(
                LoginSession, auth.token_digest(account["access_token"])
            )
            if state == "expired":
                stored.expires_at = auth.now_utc() - timedelta(seconds=1)
            else:
                stored.revoked_at = auth.now_utc()
    response = await client.get(URL, params={"cursor": cursor}, headers=headers)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["error"]["code"] == "AUTH_REQUIRED"


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", [OperationalError, TimeoutError, RuntimeError])
async def test_late_query_failure_is_redacted_not_partial_success(
    account_client, caplog, failure
):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    await seed_workouts(application, account["user_id"], 1)
    engine = application.state.database_sessions.kw["bind"].sync_engine

    def fail(connection, cursor, statement, parameters, context, executemany):
        if statement.startswith("SELECT workout_sets.set_id"):
            if failure is OperationalError:
                raise failure(
                    "private-sql", None, RuntimeError("private-connection-secret")
                )
            raise failure("private-connection-secret")

    event.listen(engine, "before_cursor_execute", fail)
    try:
        response = await client.get(URL, headers=headers)
    finally:
        event.remove(engine, "before_cursor_execute", fail)
    expected = 500 if failure is RuntimeError else 503
    assert response.status_code == expected
    assert "private-connection-secret" not in response.text + caplog.text
    assert "private-sql" not in response.text + caplog.text
    assert engine.pool.checkedout() == 0
    assert (await client.get(URL, headers=headers)).status_code == 200
