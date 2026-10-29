"""创建用户和登录会话；训练表由后续任务设计。"""

import sqlalchemy as sa
from alembic import op

revision = "0001_accounts"
down_revision = None


def upgrade():
    op.create_table(
        "users",
        sa.Column("user_id", sa.Uuid(), primary_key=True),
        sa.Column("username", sa.String(32), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("username", name="users_username_key"),
        sa.CheckConstraint("username ~ '^[a-z0-9_]{3,32}$'", name="ck_users_username"),
    )
    op.create_table(
        "sessions",
        sa.Column("token_hash", sa.LargeBinary(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "octet_length(token_hash) = 32", name="ck_sessions_token_hash"
        ),
    )


def downgrade():
    op.drop_table("sessions")
    op.drop_table("users")
