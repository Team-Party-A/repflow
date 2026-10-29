import asyncio
import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from typing import Annotated, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, FastAPI, Request, Response
from pwdlib import PasswordHash
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from app.errors import APIError
from app.models import LoginSession, User

router = APIRouter(prefix="/api/v1/auth")
passwords = PasswordHash.recommended()


def now_utc() -> datetime:
    return datetime.now(UTC)


def token_digest(token: str) -> bytes:
    return hashlib.sha256(token.encode("utf-8")).digest()


async def initialize_auth(application: FastAPI) -> None:
    # 骨架资源有限，先串行执行密码计算；生产参数仍须在目标服务器实测。
    application.state.password_gate = asyncio.Semaphore(1)
    application.state.dummy_password_hash = await run_in_threadpool(
        passwords.hash, secrets.token_urlsafe(32)
    )


async def password_work(request: Request, function, *arguments):
    async with request.app.state.password_gate:
        task = asyncio.create_task(run_in_threadpool(function, *arguments))
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            # 线程无法随请求取消；等实际计算结束再释放并发额度。
            await task
            raise


async def database_session(request: Request):
    async with request.app.state.database_sessions() as session:
        yield session


DatabaseSession = Annotated[AsyncSession, Depends(database_session)]


class Credentials(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)
    username: str = Field(min_length=3, max_length=32, pattern=r"^[A-Za-z0-9_]+$")
    password: SecretStr = Field(min_length=15, max_length=128)


class AuthResult(BaseModel):
    user_id: UUID
    username: str
    access_token: str
    token_type: Literal["Bearer"] = "Bearer"
    expires_at: datetime


def issue_session(session: AsyncSession, user: User) -> AuthResult:
    token = secrets.token_urlsafe(32)
    issued_at = now_utc()
    expires_at = issued_at + timedelta(days=365)
    session.add(
        LoginSession(
            token_hash=token_digest(token),
            user_id=user.user_id,
            issued_at=issued_at,
            expires_at=expires_at,
        )
    )
    return AuthResult(
        user_id=user.user_id,
        username=user.username,
        access_token=token,
        expires_at=expires_at,
    )


@router.post("/register", status_code=201, response_model=AuthResult)
async def register(
    credentials: Credentials, request: Request, session: DatabaseSession
):
    encoded = await password_work(
        request, passwords.hash, credentials.password.get_secret_value()
    )
    user = User(
        user_id=uuid4(),
        username=credentials.username.lower(),
        password_hash=encoded,
        created_at=now_utc(),
    )
    try:
        async with session.begin():
            session.add(user)
            await session.flush()
            result = issue_session(session, user)
    except IntegrityError as error:
        diagnostic = getattr(error.orig, "diag", None)
        if getattr(diagnostic, "constraint_name", None) == "users_username_key":
            raise APIError(409, "USERNAME_TAKEN", "用户名已被使用") from None
        raise
    return result


@router.post("/login", response_model=AuthResult)
async def login(credentials: Credentials, request: Request, session: DatabaseSession):
    async with session.begin():
        user = await session.scalar(
            select(User).where(User.username == credentials.username.lower())
        )
        # 未知账号也执行哈希校验，避免直接跳过昂贵运算。
        encoded = user.password_hash if user else request.app.state.dummy_password_hash
        valid, replacement = await password_work(
            request,
            passwords.verify_and_update,
            credentials.password.get_secret_value(),
            encoded,
        )
        if not valid or user is None:
            raise APIError(401, "INVALID_CREDENTIALS", "用户名或密码错误")
        if replacement is not None:
            user.password_hash = replacement
        result = issue_session(session, user)
    return result


@router.post("/logout", status_code=204)
async def logout(request: Request, session: DatabaseSession):
    scheme, separator, token = request.headers.get("Authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not separator or not token:
        raise APIError(401, "AUTH_REQUIRED", "请重新登录")
    timestamp = now_utc()
    async with session.begin():
        revoked = await session.scalar(
            update(LoginSession)
            .where(
                LoginSession.token_hash == token_digest(token),
                LoginSession.revoked_at.is_(None),
                LoginSession.expires_at > timestamp,
            )
            .values(revoked_at=timestamp)
            .returning(LoginSession.token_hash)
        )
        if revoked is None:
            raise APIError(401, "AUTH_REQUIRED", "请重新登录")
    return Response(status_code=204)
