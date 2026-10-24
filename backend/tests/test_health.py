import asyncio
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import OperationalError

from app.main import create_app
from app.settings import DatabaseSettings


@pytest_asyncio.fixture
async def health_client():
    application = create_app(
        DatabaseSettings(password="health-test-only", host="unreachable.invalid")
    )
    async with application.router.lifespan_context(application):
        async with AsyncClient(
            transport=ASGITransport(app=application), base_url="http://test"
        ) as client:
            yield application, client


@pytest.mark.asyncio
async def test_database_failure_is_unavailable_without_sensitive_details(
    health_client, caplog
):
    application, client = health_client
    sensitive_detail = "database-credential-must-stay-private"

    @asynccontextmanager
    async def unavailable_session():
        session = AsyncMock()
        session.execute.side_effect = OperationalError(
            "SELECT 1", None, RuntimeError(sensitive_detail)
        )
        yield session

    application.state.database_sessions = unavailable_session
    response = await client.get("/health")

    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}
    assert response.headers["cache-control"] == "no-store"
    assert sensitive_detail not in response.text + caplog.text
    assert "OperationalError" in caplog.text


@pytest.mark.asyncio
async def test_database_timeout_is_unavailable_and_cleans_up(
    health_client, monkeypatch, caplog
):
    application, client = health_client
    monkeypatch.setattr("app.main.HEALTH_TIMEOUT_SECONDS", 0.01)
    session = AsyncMock()
    cancelled = asyncio.Event()

    async def blocked_query(*_):
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()

    session.execute.side_effect = blocked_query

    @asynccontextmanager
    async def blocked_session():
        yield session

    application.state.database_sessions = blocked_session
    response = await client.get("/health")

    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}
    assert cancelled.is_set()
    assert "TimeoutError" in caplog.text


@pytest.mark.asyncio
async def test_health_queries_real_postgres_and_keeps_business_schema_empty():
    application = create_app()
    async with application.router.lifespan_context(application):
        async with AsyncClient(
            transport=ASGITransport(app=application), base_url="http://test"
        ) as client:
            responses = await asyncio.gather(*(client.get("/health") for _ in range(4)))
        assert all(response.status_code == 200 for response in responses)
        assert all(response.json() == {"status": "ok"} for response in responses)
        async with application.state.database_sessions() as session:
            tables = await session.execute(
                text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
            )
            assert tables.all() == []


@pytest.mark.asyncio
async def test_only_operational_health_route_is_available(health_client):
    _, client = health_client
    for path in ("/docs", "/openapi.json", "/register", "/workouts"):
        assert (await client.get(path)).status_code == 404
