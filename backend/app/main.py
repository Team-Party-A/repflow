import asyncio
import logging
from contextlib import asynccontextmanager, suppress
from contextvars import ContextVar

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from psycopg import AsyncConnection
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import PoolProxiedConnection

from app.settings import DatabaseSettings

logger = logging.getLogger(__name__)
HEALTH_TIMEOUT_SECONDS = 3
_health_connections: ContextVar[list[AsyncConnection] | None] = ContextVar(
    "health_connections", default=None
)


def create_app(settings: DatabaseSettings | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(application: FastAPI):
        database = settings or DatabaseSettings.from_environment()

        async def connect_database() -> AsyncConnection:
            connection = await AsyncConnection.connect(
                host=database.host,
                port=database.port,
                dbname=database.name,
                user=database.user,
                password=database.password.get_secret_value(),
                connect_timeout=HEALTH_TIMEOUT_SECONDS,
            )
            connections = _health_connections.get()
            if connections is not None:
                # SQLAlchemy 首次连接初始化也可能阻塞，提前登记可关闭的连接。
                connections.append(connection)
            return connection

        engine = create_async_engine(
            database.url,
            async_creator=connect_database,
            pool_size=2,
            max_overflow=0,
            pool_timeout=HEALTH_TIMEOUT_SECONDS,
            # SELECT 1 本身就是探活，避免取连接前的额外探测先阻塞。
            pool_pre_ping=False,
            hide_parameters=True,
        )
        application.state.database_sessions = async_sessionmaker(
            engine, expire_on_commit=False
        )
        try:
            yield
        finally:
            await engine.dispose()

    application = FastAPI(
        lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None
    )

    @application.get("/health")
    async def health(request: Request) -> JSONResponse:
        pool_connection: PoolProxiedConnection | None = None

        async def query_database() -> None:
            nonlocal pool_connection
            async with request.app.state.database_sessions() as session:
                connection = await session.connection()
                pool_connection = await connection.get_raw_connection()
                await session.execute(text("SELECT 1"))

        try:
            connections: list[AsyncConnection] = []
            token = _health_connections.set(connections)
            try:
                query_task = asyncio.create_task(query_database())
            finally:
                _health_connections.reset(token)
            try:
                completed, _ = await asyncio.wait(
                    {query_task}, timeout=HEALTH_TIMEOUT_SECONDS
                )
                if not completed:
                    raise TimeoutError
                await query_task
            finally:
                if not query_task.done():
                    # 先断开再取消，避免驱动等待故障数据库确认取消而拖长响应。
                    # 池代理归还后返回 None，此时不能关闭可能已被复用的连接。
                    if pool_connection is not None:
                        driver_connection = pool_connection.driver_connection
                    elif connections:
                        driver_connection = connections[-1]
                    else:
                        driver_connection = None
                    if driver_connection is not None:
                        await driver_connection.close()
                    query_task.cancel()
                    with suppress(asyncio.CancelledError):
                        await query_task
        except (SQLAlchemyError, TimeoutError) as error:
            # 驱动异常可能包含连接信息，只记录异常类型供排障。
            logger.warning(
                "database health check failed: kind=%s", type(error).__name__
            )
            return JSONResponse(
                {"status": "unavailable"},
                status_code=503,
                headers={"Cache-Control": "no-store"},
            )
        return JSONResponse({"status": "ok"}, headers={"Cache-Control": "no-store"})

    return application
