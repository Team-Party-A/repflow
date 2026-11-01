from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import TIMESTAMP
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint("username ~ '^[a-z0-9_]{3,32}$'", name="ck_users_username"),
    )

    user_id: Mapped[UUID] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(32), unique=True)
    password_hash: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class LoginSession(Base):
    __tablename__ = "sessions"
    __table_args__ = (
        CheckConstraint("octet_length(token_hash) = 32", name="ck_sessions_token_hash"),
    )

    token_hash: Mapped[bytes] = mapped_column(LargeBinary, primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.user_id"))
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Workout(Base):
    __tablename__ = "workouts"
    __table_args__ = (
        CheckConstraint(
            "revision BETWEEN 1 AND 2147483647", name="ck_workouts_revision"
        ),
        CheckConstraint(
            "(is_deleted AND record_kind IS NULL AND started_at IS NULL "
            "AND ended_at IS NULL AND time_zone IS NULL) OR "
            "(NOT is_deleted AND record_kind IS NOT NULL AND record_kind = 'actual' "
            "AND started_at IS NOT NULL AND time_zone IS NOT NULL "
            "AND char_length(time_zone) BETWEEN 1 AND 64 "
            "AND (ended_at IS NULL OR ended_at >= started_at))",
            name="ck_workouts_shape",
        ),
    )

    workout_id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.user_id"))
    revision: Mapped[int]
    is_deleted: Mapped[bool]
    record_kind: Mapped[str | None] = mapped_column(Text)
    started_at: Mapped[datetime | None] = mapped_column(
        TIMESTAMP(timezone=True, precision=6)
    )
    ended_at: Mapped[datetime | None] = mapped_column(
        TIMESTAMP(timezone=True, precision=6)
    )
    time_zone: Mapped[str | None] = mapped_column(String(64))


Index(
    "ix_workouts_user_started",
    Workout.user_id,
    Workout.started_at.desc(),
    Workout.workout_id.desc(),
    postgresql_where=~Workout.is_deleted,
)


class WorkoutSet(Base):
    __tablename__ = "workout_sets"
    __table_args__ = (
        UniqueConstraint("workout_id", "position", name="uq_workout_sets_position"),
        CheckConstraint(
            "(is_removed AND position IS NULL AND exercise_id IS NULL "
            "AND final_rep_count IS NULL AND estimated_rep_count IS NULL "
            "AND record_source IS NULL AND weight_grams IS NULL) OR "
            "(NOT is_removed AND position IS NOT NULL AND position BETWEEN 1 AND 1000 "
            "AND exercise_id IS NOT NULL AND exercise_id ~ '^[a-z][a-z0-9_]*$' "
            "AND final_rep_count IS NOT NULL AND final_rep_count BETWEEN 1 AND 9999 "
            "AND record_source IS NOT NULL AND "
            "((record_source = 'automatic' AND estimated_rep_count IS NOT NULL "
            "AND estimated_rep_count BETWEEN 0 AND 2147483647) OR "
            "(record_source = 'manual' AND estimated_rep_count IS NULL)) "
            "AND (weight_grams IS NULL OR weight_grams BETWEEN 0 AND 1000000))",
            name="ck_workout_sets_shape",
        ),
    )

    set_id: Mapped[UUID] = mapped_column(primary_key=True)
    workout_id: Mapped[UUID] = mapped_column(ForeignKey("workouts.workout_id"))
    is_removed: Mapped[bool]
    position: Mapped[int | None]
    exercise_id: Mapped[str | None] = mapped_column(String(64))
    final_rep_count: Mapped[int | None]
    estimated_rep_count: Mapped[int | None]
    record_source: Mapped[str | None] = mapped_column(Text)
    weight_grams: Mapped[int | None]
