from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from alembic import command
from sqlalchemy import inspect, select
from sqlalchemy.exc import DataError, IntegrityError

from app.models import LoginSession, User, Workout, WorkoutSet

NOW = datetime(2026, 11, 1, tzinfo=UTC)


def seed_user(connection):
    user_id = uuid4()
    connection.execute(
        User.__table__.insert().values(
            user_id=user_id,
            username="migration_user",
            password_hash="test-only-hash",
            created_at=NOW,
        )
    )
    return user_id


def live_workout(user_id):
    return dict(
        workout_id=uuid4(),
        user_id=user_id,
        revision=1,
        is_deleted=False,
        record_kind="actual",
        started_at=NOW,
        ended_at=None,
        time_zone="UTC",
    )


def active_set(workout_id):
    return dict(
        set_id=uuid4(),
        workout_id=workout_id,
        is_removed=False,
        position=1,
        exercise_id="push_up",
        final_rep_count=1,
        estimated_rep_count=None,
        record_source="manual",
        weight_grams=None,
    )


def test_upgrade_and_workout_only_downgrade_preserve_accounts(account_database):
    _, _, engine, config = account_database
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.downgrade(config, "0001_accounts")
        user_id = seed_user(connection)
        connection.execute(
            LoginSession.__table__.insert().values(
                token_hash=b"t" * 32,
                user_id=user_id,
                issued_at=NOW,
                expires_at=NOW + timedelta(days=365),
                revoked_at=None,
            )
        )
    for _ in range(2):
        with engine.begin() as connection:
            config.attributes["connection"] = connection
            command.upgrade(config, "head")
            assert connection.scalar(select(User.user_id)) == user_id
            assert connection.scalar(select(LoginSession.token_hash)) == b"t" * 32
            workout = live_workout(user_id)
            connection.execute(Workout.__table__.insert().values(workout))
            connection.execute(
                WorkoutSet.__table__.insert().values(active_set(workout["workout_id"]))
            )
            command.downgrade(config, "0001_accounts")
            assert set(inspect(connection).get_table_names()) == {
                "users",
                "sessions",
                "alembic_version",
            }
            assert connection.scalar(select(User.user_id)) == user_id
            assert connection.scalar(select(LoginSession.token_hash)) == b"t" * 32


@pytest.mark.parametrize(
    "changes",
    [
        {"revision": 0},
        {"revision": 2147483648},
        {"user_id": uuid4()},
        {"record_kind": None},
        {"record_kind": "template"},
        {"started_at": None},
        {"time_zone": None},
        {"time_zone": ""},
        {"time_zone": "a" * 65},
        {"ended_at": NOW - timedelta(microseconds=1)},
        {"is_deleted": True},
    ],
)
def test_workout_constraints_reject_invalid_shape(account_database, changes):
    _, _, engine, _ = account_database
    with engine.begin() as connection:
        user_id = seed_user(connection)
    with pytest.raises((IntegrityError, DataError)), engine.begin() as connection:
        connection.execute(
            Workout.__table__.insert().values(live_workout(user_id) | changes)
        )


@pytest.mark.parametrize(
    "changes",
    [
        {"workout_id": uuid4()},
        {"position": None},
        {"position": 0},
        {"position": 1001},
        {"exercise_id": None},
        {"exercise_id": "bad name"},
        {"final_rep_count": None},
        {"final_rep_count": 0},
        {"final_rep_count": 10000},
        {"record_source": None},
        {"record_source": "unknown"},
        {"record_source": "automatic"},
        {"estimated_rep_count": 1},
        {"record_source": "automatic", "estimated_rep_count": -1},
        {"record_source": "automatic", "estimated_rep_count": 2147483648},
        {"weight_grams": -1},
        {"weight_grams": 1000001},
        {"is_removed": True},
    ],
)
def test_set_constraints_reject_invalid_shape(account_database, changes):
    _, _, engine, _ = account_database
    with engine.begin() as connection:
        workout = live_workout(seed_user(connection))
        connection.execute(Workout.__table__.insert().values(workout))
    with pytest.raises((IntegrityError, DataError)), engine.begin() as connection:
        connection.execute(
            WorkoutSet.__table__.insert().values(
                active_set(workout["workout_id"]) | changes
            )
        )


def test_removed_rows_keep_identity_without_taking_position(account_database):
    _, _, engine, _ = account_database
    with engine.begin() as connection:
        user_id = seed_user(connection)
        workout = live_workout(user_id)
        connection.execute(Workout.__table__.insert().values(workout))
        connection.execute(
            Workout.__table__.insert().values(
                workout_id=uuid4(),
                user_id=user_id,
                revision=2147483647,
                is_deleted=True,
            )
        )
        connection.execute(
            WorkoutSet.__table__.insert().values(
                [
                    dict(
                        set_id=uuid4(),
                        workout_id=workout["workout_id"],
                        is_removed=True,
                    )
                    for _ in range(2)
                ]
            )
        )
        connection.execute(
            WorkoutSet.__table__.insert().values(active_set(workout["workout_id"]))
        )
    with pytest.raises(IntegrityError), engine.begin() as connection:
        connection.execute(
            WorkoutSet.__table__.insert().values(active_set(workout["workout_id"]))
        )
