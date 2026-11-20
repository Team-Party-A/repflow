import asyncio
import hashlib
import logging
import os
from contextlib import suppress
from datetime import UTC, datetime, timedelta
from time import monotonic
from uuid import UUID, uuid4

from fastapi import APIRouter, Request, Response
from sqlalchemy import func, select

from app.auth import DatabaseSession
from app.errors import APIError, error_response
from app.nutrition import Key, Owner
from app.nutrition_ark import ArkProvider, ProviderFailure, account_cost
from app.nutrition_catalog import find_public, lock_key, publish, snapshot
from app.nutrition_models import Analysis
from app.nutrition_schemas import FoodInput, food_key, unknown_food

router = APIRouter(prefix="/api/v1/nutrition/analyses")
logger = logging.getLogger(__name__)
MAX_BYTES = 4 * 1024 * 1024
JOB_SECONDS = 90


def initialize(app):
    app.state.nutrition_provider = ArkProvider()
    app.state.nutrition_tasks = set()


async def shutdown(app):
    tasks = tuple(app.state.nutrition_tasks)
    for task in tasks:
        task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


def public_job(job):
    return dict(
        id=job.id, status=job.status, items=job.items, failure_code=job.failure_code
    )


def stripped_jpeg(data):
    """只传 JPEG 编码图像，丢弃所有扫描段之间的 APP 元数据和评论。"""
    if not data.startswith(b"\xff\xd8"):
        raise ValueError
    output = bytearray(data[:2])
    offset = 2
    has_frame = has_scan = False
    while offset < len(data):
        if data[offset] != 255:
            raise ValueError
        while offset < len(data) and data[offset] == 255:
            offset += 1
        if offset >= len(data):
            raise ValueError
        marker = data[offset]
        offset += 1
        if marker == 217:
            if not has_scan or offset != len(data):
                raise ValueError
            return bytes(output + b"\xff\xd9")
        if marker in (0, 1, 216) or 208 <= marker <= 215:
            raise ValueError
        length = int.from_bytes(data[offset : offset + 2], "big")
        end = offset + length
        if length < 2 or end > len(data):
            raise ValueError
        if marker in (192, 193, 194):
            width = int.from_bytes(data[offset + 5 : offset + 7], "big")
            height = int.from_bytes(data[offset + 3 : offset + 5], "big")
            if length < 8 or not width or not height or width * height > 48_000_000:
                raise ValueError
            has_frame = True
        if not (224 <= marker <= 239 or marker == 254):
            output.extend((255, marker))
            output.extend(data[offset:end])
        offset = end
        if marker != 218:
            continue
        if not has_frame:
            raise ValueError
        has_scan = True
        # 0xff00 和 restart marker 都属于扫描数据，其他 marker 开始新段。
        scan = offset
        while True:
            boundary = data.find(b"\xff", offset)
            if boundary < 0:
                raise ValueError
            index = boundary + 1
            while index < len(data) and data[index] == 255:
                index += 1
            if index >= len(data):
                raise ValueError
            if data[index] == 0 or 208 <= data[index] <= 215:
                offset = index + 1
                continue
            output.extend(data[scan:boundary])
            offset = boundary
            break
    raise ValueError


async def process_foods(factory, provider, visible, metrics):
    candidates = {}
    for item in visible:
        if item.generic:
            candidates.setdefault(
                (food_key(item.name), food_key(item.preparation)),
                (item.name, item.preparation),
            )
    known = {}
    async with factory() as db:
        for key, (name, prep) in candidates.items():
            match = await find_public(db, name, prep)
            if match:
                known[key] = snapshot(match)
    missing = [pair for key, pair in candidates.items() if key not in known]
    metrics.update(
        lookups_unique=len(candidates), cache_hits_unique=len(known), text_calls=0
    )
    if missing:
        metrics["text_calls"] = 1
        try:
            profiles, usage = await provider.profiles(missing)
            metrics["text_usage"] = usage
        except ProviderFailure as error:
            profiles = {}
            metrics["profile_error"] = error.code
        async with factory.begin() as db:
            for (name, prep), profile in sorted(
                profiles.items(), key=lambda x: tuple(map(food_key, x[0]))
            ):
                data = FoodInput(name=name, preparation=prep, per_100g=profile)
                food = await publish(db, data, "ai_estimate")
                known[(food_key(name), food_key(prep))] = snapshot(food)
    items = []
    for item in visible:
        found = (
            known.get((food_key(item.name), food_key(item.preparation)))
            if item.generic
            else None
        )
        food = found or (unknown_food(item.name) | {"preparation": item.preparation})
        items.append(
            dict(
                food=food,
                grams=item.grams,
                needs_review=item.needs_review
                or item.grams is None
                or None in food["per_100g"].values(),
            )
        )
    return items


async def work(factory, provider, ident, picture):
    started = monotonic()
    metrics = {
        "vision_model": provider.vision,
        "text_model": provider.text,
        "vision_calls": 0,
        "text_calls": 0,
    }
    status, code, items = "failed", "provider_unavailable", []
    try:
        async with asyncio.timeout(JOB_SECONDS):
            async with factory.begin() as db:
                job = await db.get(Analysis, ident, with_for_update=True)
                if job is None or job.status != "queued":
                    return
                job.status = "processing"
            metrics["vision_calls"] = 1
            visible, metrics["vision_usage"] = await provider.recognize(picture)
            picture = None
            if not visible:
                raise ProviderFailure("no_food")
            items = await process_foods(factory, provider, visible, metrics)
            status, code = "ready", None
    except ProviderFailure as error:
        code = error.code
    except TimeoutError, asyncio.CancelledError:
        status, code = "expired", "expired"
    except Exception as error:
        logger.warning(
            "nutrition analysis failed: job=%s kind=%s", ident, type(error).__name__
        )
    finally:
        picture = None
    metrics.update(
        latency_ms=round((monotonic() - started) * 1000), **account_cost(metrics)
    )
    async with factory.begin() as db:
        job = await db.get(Analysis, ident, with_for_update=True)
        if job is not None and job.status in ("queued", "processing"):
            job.status, job.failure_code, job.items, job.metrics = (
                status,
                code,
                items,
                metrics,
            )


def completed(tasks, task):
    tasks.discard(task)
    with suppress(asyncio.CancelledError):
        if error := task.exception():
            logger.warning(
                "nutrition task storage failed: kind=%s", type(error).__name__
            )


def quota(name, default):
    try:
        return max(0, int(os.getenv(name, str(default))))
    except ValueError:
        return 0


@router.post("")
async def start(
    request: Request,
    owner: Owner,
    key: Key,
    session: DatabaseSession,
    response: Response,
):
    if (
        request.headers.get("content-type", "").split(";")[0].strip().lower()
        != "image/jpeg"
    ):
        raise APIError(415, "UNSUPPORTED_MEDIA_TYPE", "请上传 JPEG 餐照")
    # 账号读取已结束，上传期间把数据库连接归还给连接池。
    await session.rollback()
    raw = bytearray()
    async for chunk in request.stream():
        if len(raw) + len(chunk) > MAX_BYTES:
            raise APIError(413, "IMAGE_TOO_LARGE", "餐照超过 4 MiB")
        raw.extend(chunk)
    digest = hashlib.sha256(raw).hexdigest()
    try:
        picture = stripped_jpeg(raw)
    except ValueError:
        raise APIError(422, "VALIDATION_ERROR", "无法读取 JPEG 餐照") from None
    del raw
    await lock_key(session, "analysis-admission")
    existing = await session.scalar(
        select(Analysis).where(Analysis.owner_id == owner, Analysis.request_key == key)
    )
    response.status_code = 202
    response.headers["Retry-After"] = "2"
    if existing:
        if existing.input_hash != digest:
            raise APIError(409, "REQUEST_CONFLICT", "此请求键已用于其他照片")
        return public_job(existing)
    provider = request.app.state.nutrition_provider
    if not provider.available:
        raise APIError(503, "SERVICE_UNAVAILABLE", "拍照识别暂不可用，可手动记餐")
    now = datetime.now(UTC)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    daily, personal = (
        await session.execute(
            select(func.count(), func.count().filter(Analysis.owner_id == owner)).where(
                Analysis.created_at >= midnight
            )
        )
    ).one()
    active = await session.scalar(
        select(func.count())
        .select_from(Analysis)
        .where(Analysis.status.in_(("queued", "processing")), Analysis.expires_at > now)
    )
    daily_limit = daily >= quota("NUTRITION_DAILY_LIMIT", 100) or personal >= quota(
        "NUTRITION_USER_DAILY_LIMIT", 20
    )
    if daily_limit or active >= quota("NUTRITION_ACTIVE_LIMIT", 4):
        result = error_response(
            429, "QUOTA_EXCEEDED", "识别额度已用完或队列繁忙，可手动记餐"
        )
        result.headers["Retry-After"] = str(
            max(1, int((midnight + timedelta(days=1) - now).total_seconds()))
            if daily_limit
            else 2
        )
        return result
    job = Analysis(
        id=uuid4(),
        owner_id=owner,
        request_key=key,
        input_hash=digest,
        created_at=now,
        expires_at=now + timedelta(seconds=JOB_SECONDS + 5),
        status="queued",
        items=[],
        metrics={},
    )
    session.add(job)
    await session.commit()
    tasks = request.app.state.nutrition_tasks
    task = asyncio.create_task(
        work(request.app.state.database_sessions, provider, job.id, picture)
    )
    tasks.add(task)
    task.add_done_callback(lambda finished: completed(tasks, finished))
    return public_job(job)


@router.get("/{analysis_id}")
async def get_analysis(
    analysis_id: UUID, owner: Owner, session: DatabaseSession, response: Response
):
    job = await session.scalar(
        select(Analysis)
        .where(Analysis.id == analysis_id, Analysis.owner_id == owner)
        .with_for_update()
    )
    if job is None:
        raise APIError(404, "NOT_FOUND", "找不到识别任务")
    if job.status in ("queued", "processing"):
        if job.expires_at <= datetime.now(UTC):
            job.status, job.failure_code = "expired", "expired"
            await session.commit()
        else:
            response.headers["Retry-After"] = "2"
    return public_job(job)
