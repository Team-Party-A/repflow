import asyncio
import textwrap
import uuid

import pytest
from alembic import command
from alembic.config import Config
from pwdlib import PasswordHash
from sqlalchemy import create_engine, inspect
from sqlalchemy.schema import CreateSchema, DropSchema

from app.settings import DatabaseSettings


@pytest.mark.asyncio
async def test_argon2id_binary_dependencies_work_in_thread_pool():
    password_hash = PasswordHash.recommended()
    encoded = await asyncio.to_thread(password_hash.hash, "compatibility-test-only")
    assert encoded.startswith("$argon2id$")
    assert await asyncio.to_thread(
        password_hash.verify, "compatibility-test-only", encoded
    )
    assert not await asyncio.to_thread(password_hash.verify, "different-input", encoded)


def test_alembic_round_trip_uses_only_an_isolated_test_schema(tmp_path):
    migration_dir = tmp_path / "migrations"
    (migration_dir / "versions").mkdir(parents=True)
    (migration_dir / "env.py").write_text(
        textwrap.dedent("""\
        from alembic import context

        context.configure(
            connection=context.config.attributes["connection"],
            version_table_schema=context.config.attributes["schema"],
        )
        with context.begin_transaction():
            context.run_migrations()
        """)
    )
    (migration_dir / "versions" / "probe.py").write_text(
        textwrap.dedent("""\
        from alembic import op
        import sqlalchemy as sa

        revision = "probe"
        down_revision = None

        def upgrade():
            op.create_table(
                "migration_probe", sa.Column("id", sa.Integer, primary_key=True),
                schema=op.get_context().opts["version_table_schema"],
            )

        def downgrade():
            op.drop_table(
                "migration_probe",
                schema=op.get_context().opts["version_table_schema"],
            )
        """)
    )
    config = Config()
    config.set_main_option("script_location", str(migration_dir))
    config.set_main_option("path_separator", "os")
    schema = "migration_test_" + uuid.uuid4().hex
    engine = create_engine(DatabaseSettings.from_environment().url)
    try:
        with engine.begin() as connection:
            connection.execute(CreateSchema(schema))
            config.attributes.update(connection=connection, schema=schema)
            command.upgrade(config, "head")
            assert "migration_probe" in inspect(connection).get_table_names(schema)
            command.downgrade(config, "base")
            assert "migration_probe" not in inspect(connection).get_table_names(schema)
            connection.execute(DropSchema(schema, cascade=True))
    finally:
        engine.dispose()
