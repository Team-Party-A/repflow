import base64
import json
import re
from collections import defaultdict
from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Query, Request
from pydantic import Field
from sqlalchemy import select, tuple_

from app.auth import DatabaseSession, authenticated_user_id
from app.errors import APIError
from app.models import Workout, WorkoutSet
from app.workout_schemas import (
    ClientId,
    QueryLimit,
    StrictInput,
    UtcTime,
    WorkoutPage,
    WorkoutResult,
    WorkoutSetResult,
    utc_text,
)

router = APIRouter(prefix="/api/v1/workouts")


class WorkoutCursor(StrictInput):
    version: int = Field(ge=1, le=1)
    user_id: ClientId
    started_from: UtcTime | None
    started_before: UtcTime | None
    last_started_at: UtcTime
    last_workout_id: ClientId


def encode_cursor(
    user_id: UUID,
    started_from: datetime | None,
    started_before: datetime | None,
    last_workout: Workout,
) -> str:
    content = {
        "version": 1,
        "user_id": str(user_id),
        "started_from": utc_text(started_from) if started_from is not None else None,
        "started_before": utc_text(started_before)
        if started_before is not None
        else None,
        "last_started_at": utc_text(last_workout.started_at),
        "last_workout_id": str(last_workout.workout_id),
    }
    # 游标只编码位置，不是授权凭据；每次查询仍独立鉴权并限定账号。
    return (
        base64.urlsafe_b64encode(json.dumps(content, separators=(",", ":")).encode())
        .decode()
        .rstrip("=")
    )


def decode_cursor(
    value: str,
    user_id: UUID,
    started_from: datetime | None,
    started_before: datetime | None,
) -> WorkoutCursor:
    try:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
            raise ValueError
        content = base64.b64decode(
            value + "=" * (-len(value) % 4), altchars=b"-_", validate=True
        )
        cursor = WorkoutCursor.model_validate_json(content)
        if (cursor.user_id, cursor.started_from, cursor.started_before) != (
            user_id,
            started_from,
            started_before,
        ):
            raise ValueError
        if (started_from is not None and cursor.last_started_at < started_from) or (
            started_before is not None and cursor.last_started_at >= started_before
        ):
            raise ValueError
        return cursor
    except ValueError:
        # 不回显编码内容、校验库详情或客户端提供的字段名。
        raise APIError(422, "VALIDATION_ERROR", "游标无效，请从首页重新查询") from None


@router.get("", response_model=WorkoutPage)
async def list_workouts(
    request: Request,
    session: DatabaseSession,
    limit: Annotated[QueryLimit, Query()] = 50,
    cursor: Annotated[str | None, Query(min_length=1, max_length=2048)] = None,
    started_from: Annotated[UtcTime | None, Query()] = None,
    started_before: Annotated[UtcTime | None, Query()] = None,
):
    if (
        started_from is not None
        and started_before is not None
        and started_from >= started_before
    ):
        raise APIError(422, "VALIDATION_ERROR", "开始边界必须早于结束边界")
    async with session.begin():
        # 必须早于鉴权的第一条 SQL：整页训练与组共用快照，归还连接时恢复默认配置。
        await session.connection(
            execution_options={
                "isolation_level": "REPEATABLE READ",
                "postgresql_readonly": True,
            }
        )
        user_id = await authenticated_user_id(request, session)
        query = select(Workout).where(Workout.user_id == user_id, ~Workout.is_deleted)
        if started_from is not None:
            query = query.where(Workout.started_at >= started_from)
        if started_before is not None:
            query = query.where(Workout.started_at < started_before)
        if cursor is not None:
            position = decode_cursor(cursor, user_id, started_from, started_before)
            query = query.where(
                tuple_(Workout.started_at, Workout.workout_id)
                < (position.last_started_at, position.last_workout_id)
            )
        rows = (
            await session.scalars(
                query.order_by(
                    Workout.started_at.desc(), Workout.workout_id.desc()
                ).limit(limit + 1)
            )
        ).all()
        page = rows[:limit]
        groups = defaultdict(list)
        if page:
            sets = await session.scalars(
                select(WorkoutSet)
                .where(
                    WorkoutSet.workout_id.in_([item.workout_id for item in page]),
                    ~WorkoutSet.is_removed,
                )
                .order_by(WorkoutSet.workout_id, WorkoutSet.position)
            )
            for item in sets:
                groups[item.workout_id].append(WorkoutSetResult.model_validate(item))
        result = WorkoutPage(
            items=[
                WorkoutResult(
                    workout_id=item.workout_id,
                    revision=item.revision,
                    record_kind=item.record_kind,
                    started_at=item.started_at,
                    ended_at=item.ended_at,
                    time_zone=item.time_zone,
                    sets=groups[item.workout_id],
                )
                for item in page
            ],
            next_cursor=(
                encode_cursor(user_id, started_from, started_before, page[-1])
                if len(rows) > limit
                else None
            ),
        )
    return result
