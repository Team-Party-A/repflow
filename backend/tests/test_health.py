import asyncio
from contextlib import asynccontextmanager
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import OperationalError

from app.main import _health_connections, create_app
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
@pytest.mark.parametrize("blocked_method", ["connection", "execute"])
async def test_database_timeout_is_unavailable_and_cleans_up(
    health_client, monkeypatch, caplog, blocked_method
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

    getattr(session, blocked_method).side_effect = blocked_query

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
@pytest.mark.parametrize("phase", ["query", "initialization", "returned_connection"])
async def test_timeout_closes_driver_before_waiting_for_query_cancellation(
    health_client, monkeypatch, phase
):
    application, client = health_client
    monkeypatch.setattr("app.main.HEALTH_TIMEOUT_SECONDS", 0.01)
    driver_closed = asyncio.Event()
    query_cancelled = asyncio.Event()
    session_closed = asyncio.Event()
    driver = AsyncMock()
    driver.close.side_effect = driver_closed.set
    session = AsyncMock()
    session.connection.return_value.get_raw_connection.return_value = SimpleNamespace(
        driver_connection=None if phase == "returned_connection" else driver
    )

    async def blocked_query(*_):
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            query_cancelled.set()
            if phase != "returned_connection":
                await driver_closed.wait()
            raise

    if phase == "initialization":
        session.connection.side_effect = blocked_query
    else:
        session.execute.side_effect = blocked_query

    @asynccontextmanager
    async def blocked_session():
        _health_connections.get().append(driver)
        try:
            yield session
        finally:
            session_closed.set()

    application.state.database_sessions = blocked_session
    response_task = asyncio.create_task(client.get("/health"))
    try:
        completed, _ = await asyncio.wait({response_task}, timeout=0.3)
    finally:
        driver_closed.set()
        response = await response_task

    assert completed, "query cancellation must not extend the response deadline"
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}
    if phase == "returned_connection":
        driver.close.assert_not_awaited()
    else:
        driver.close.assert_awaited_once()
    assert query_cancelled.is_set()
    assert session_closed.is_set()


@pytest.mark.asyncio
async def test_cancelled_request_closes_driver_and_query(health_client):
    application, client = health_client
    driver_closed = asyncio.Event()
    query_started = asyncio.Event()
    query_cancelled = asyncio.Event()
    session_closed = asyncio.Event()
    driver = AsyncMock()
    driver.close.side_effect = driver_closed.set
    session = AsyncMock()
    session.connection.return_value.get_raw_connection.return_value = SimpleNamespace(
        driver_connection=driver
    )

    async def blocked_query(*_):
        query_started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            query_cancelled.set()
            await driver_closed.wait()
            raise

    session.execute.side_effect = blocked_query

    @asynccontextmanager
    async def blocked_session():
        try:
            yield session
        finally:
            session_closed.set()

    application.state.database_sessions = blocked_session
    response_task = asyncio.create_task(client.get("/health"))
    await query_started.wait()
    response_task.cancel()
    try:
        completed, _ = await asyncio.wait({response_task}, timeout=0.3)
    finally:
        driver_closed.set()
        with pytest.raises(asyncio.CancelledError):
            await response_task

    assert completed
    driver.close.assert_awaited_once()
    assert query_cancelled.is_set()
    assert session_closed.is_set()


@pytest.mark.asyncio
@pytest.mark.parametrize("prewarm", [False, True])
async def test_health_queries_real_postgres_and_keeps_business_schema_empty(prewarm):
    application = create_app()
    async with application.router.lifespan_context(application):
        if prewarm:
            async with application.state.database_sessions() as session:
                await session.execute(text("SELECT 1"))
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
