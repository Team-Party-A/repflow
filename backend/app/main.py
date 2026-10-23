import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.settings import DatabaseSettings

logger = logging.getLogger(__name__)
HEALTH_TIMEOUT_SECONDS = 3


def create_app(settings: DatabaseSettings | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(application: FastAPI):
        database = settings or DatabaseSettings.from_environment()
        engine = create_async_engine(
            database.url,
            pool_size=2,
            max_overflow=0,
            pool_timeout=HEALTH_TIMEOUT_SECONDS,
            pool_pre_ping=True,
            hide_parameters=True,
            connect_args={"connect_timeout": HEALTH_TIMEOUT_SECONDS},
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
        try:
            async with asyncio.timeout(HEALTH_TIMEOUT_SECONDS):
                async with request.app.state.database_sessions() as session:
                    await session.execute(text("SELECT 1"))
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
