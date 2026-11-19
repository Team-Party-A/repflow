"""训练、组及最小删除标记；ID 归属不随内容删除而清理。"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0002_workouts"
down_revision = "0001_accounts"


def upgrade():
    op.create_table(
        "workouts",
        sa.Column("workout_id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("is_deleted", sa.Boolean(), nullable=False),
        sa.Column("record_kind", sa.Text()),
        sa.Column("started_at", postgresql.TIMESTAMP(timezone=True, precision=6)),
        sa.Column("ended_at", postgresql.TIMESTAMP(timezone=True, precision=6)),
        sa.Column("time_zone", sa.String(64)),
        sa.CheckConstraint(
            "revision BETWEEN 1 AND 2147483647", name="ck_workouts_revision"
        ),
        sa.CheckConstraint(
            "(is_deleted AND record_kind IS NULL AND started_at IS NULL "
            "AND ended_at IS NULL AND time_zone IS NULL) OR "
            "(NOT is_deleted AND record_kind IS NOT NULL AND record_kind = 'actual' "
            "AND started_at IS NOT NULL AND time_zone IS NOT NULL "
            "AND char_length(time_zone) BETWEEN 1 AND 64 "
            "AND (ended_at IS NULL OR ended_at >= started_at))",
            name="ck_workouts_shape",
        ),
    )
    op.create_index(
        "ix_workouts_user_started",
        "workouts",
        ["user_id", sa.text("started_at DESC"), sa.text("workout_id DESC")],
        postgresql_where=sa.text("NOT is_deleted"),
    )
    op.create_table(
        "workout_sets",
        sa.Column("set_id", sa.Uuid(), primary_key=True),
        sa.Column(
            "workout_id",
            sa.Uuid(),
            sa.ForeignKey("workouts.workout_id"),
            nullable=False,
        ),
        sa.Column("is_removed", sa.Boolean(), nullable=False),
        sa.Column("position", sa.Integer()),
        sa.Column("exercise_id", sa.String(64)),
        sa.Column("final_rep_count", sa.Integer()),
        sa.Column("estimated_rep_count", sa.Integer()),
        sa.Column("record_source", sa.Text()),
        sa.Column("weight_grams", sa.Integer()),
        sa.UniqueConstraint("workout_id", "position", name="uq_workout_sets_position"),
        sa.CheckConstraint(
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


def downgrade():
    op.drop_table("workout_sets")
    op.drop_index("ix_workouts_user_started", table_name="workouts")
    op.drop_table("workouts")
