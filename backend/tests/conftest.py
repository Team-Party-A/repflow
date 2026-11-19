from pathlib import Path
from uuid import uuid4

import pytest
import pytest_asyncio
from alembic import command
from alembic.config import Config
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.schema import CreateSchema, DropSchema

from app.main import create_app
from app.settings import DatabaseSettings


@pytest.fixture
def account_database():
    settings = DatabaseSettings.from_environment()
    schema = "account_test_" + uuid4().hex
    admin = create_engine(settings.url, hide_parameters=True)
    with admin.begin() as connection:
        connection.execute(CreateSchema(schema))
    options = {"options": f"-c search_path={schema}"}
    engine = create_engine(settings.url, connect_args=options, hide_parameters=True)
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    try:
        with engine.begin() as connection:
            config.attributes["connection"] = connection
            command.upgrade(config, "head")
        yield settings, schema, engine, config
    finally:
        engine.dispose()
        with admin.begin() as connection:
            connection.execute(DropSchema(schema, cascade=True))
        admin.dispose()


@pytest_asyncio.fixture
async def account_client(account_database):
    settings, schema, _, _ = account_database
    engine = create_async_engine(
        settings.url,
        connect_args={"options": f"-c search_path={schema}"},
        hide_parameters=True,
    )
    application = create_app(settings)
    try:
        async with application.router.lifespan_context(application):
            application.state.database_sessions = async_sessionmaker(
                engine, expire_on_commit=False
            )
            async with AsyncClient(
                transport=ASGITransport(app=application),
                base_url="https://test",
            ) as client:
                yield application, client
    finally:
        await engine.dispose()
