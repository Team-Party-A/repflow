from alembic import context
from sqlalchemy import create_engine

from app.models import Base
from app.settings import DatabaseSettings


def migrate(connection):
    context.configure(connection=connection, target_metadata=Base.metadata)
    with context.begin_transaction():
        context.run_migrations()


connection = context.config.attributes.get("connection")
if connection is not None:
    migrate(connection)
else:
    engine = create_engine(
        DatabaseSettings.from_environment().url, hide_parameters=True
    )
    try:
        with engine.connect() as connection:
            migrate(connection)
    finally:
        engine.dispose()
