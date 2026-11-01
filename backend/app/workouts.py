from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Query, Request
from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import DatabaseSession, authenticated_user_id
from app.errors import APIError
from app.models import Workout, WorkoutSet
from app.workout_schemas import (
    ClientId,
    QueryRevision,
    WorkoutInput,
    WorkoutSetInput,
    WriteReceipt,
)

router = APIRouter(prefix="/api/v1/workouts")
REMOVED_SET = dict.fromkeys(
    [
        "position",
        "exercise_id",
        "final_rep_count",
        "estimated_rep_count",
        "record_source",
        "weight_grams",
    ]
)


async def create_or_lock(
    session: AsyncSession, workout_id: UUID, user_id: UUID, values: dict
) -> tuple[Workout, bool]:
    # 空查询没有可锁的行；先用唯一键协调首次创建，再在新语句快照中锁行。
    created = await session.scalar(
        insert(Workout)
        .values(workout_id=workout_id, user_id=user_id, **values)
        .on_conflict_do_nothing(index_elements=[Workout.workout_id])
        .returning(Workout.workout_id)
    )
    workout = await session.scalar(
        select(Workout).where(Workout.workout_id == workout_id).with_for_update()
    )
    if workout.user_id != user_id:
        raise APIError(404, "NOT_FOUND", "训练不存在或无权访问")
    return workout, created is not None


async def verify_set_ownership(
    session: AsyncSession, set_ids: list[UUID], user_id: UUID, workout_id: UUID
) -> None:
    owners = (
        await session.execute(
            select(WorkoutSet.workout_id, Workout.user_id)
            .join(Workout, Workout.workout_id == WorkoutSet.workout_id)
            .where(WorkoutSet.set_id.in_(set_ids))
        )
    ).all()
    if any(owner.user_id != user_id for owner in owners):
        raise APIError(404, "NOT_FOUND", "训练不存在或无权访问")
    if any(owner.workout_id != workout_id for owner in owners):
        raise APIError(409, "SET_ID_CONFLICT", "组 ID 已属于其他训练")


async def retire_sets(session: AsyncSession, workout_id: UUID) -> None:
    await session.execute(
        update(WorkoutSet)
        .where(WorkoutSet.workout_id == workout_id)
        .values(is_removed=True, **REMOVED_SET)
    )


def revision_conflict(workout: Workout) -> APIError:
    return APIError(
        409,
        "REVISION_CONFLICT",
        "训练版本冲突，请核对本地待同步记录",
        current_revision=workout.revision,
    )


def receipt(workout: Workout) -> WriteReceipt:
    return WriteReceipt(
        workout_id=workout.workout_id,
        accepted_revision=workout.revision,
        deleted=workout.is_deleted,
    )


async def same_content(
    session: AsyncSession, workout: Workout, payload: WorkoutInput
) -> bool:
    content = payload.model_dump()
    sets = content.pop("sets")
    if any(getattr(workout, name) != value for name, value in content.items()):
        return False
    current = await session.scalars(
        select(WorkoutSet)
        .where(WorkoutSet.workout_id == workout.workout_id, ~WorkoutSet.is_removed)
        .order_by(WorkoutSet.position)
    )
    return [
        {name: getattr(item, name) for name in WorkoutSetInput.model_fields}
        for item in current
    ] == sets


@router.put("/{workout_id}", response_model=WriteReceipt)
async def put_workout(
    workout_id: ClientId,
    payload: WorkoutInput,
    request: Request,
    session: DatabaseSession,
):
    async with session.begin():
        user_id = await authenticated_user_id(request, session)
        content = payload.model_dump(exclude={"sets"})
        workout, created = await create_or_lock(
            session, workout_id, user_id, dict(content, is_deleted=False)
        )
        set_ids = sorted(item.set_id for item in payload.sets)
        # 先查组归属，避免通过版本冲突或删除状态泄露跨账号资源信息。
        await verify_set_ownership(session, set_ids, user_id, workout_id)
        if workout.is_deleted:
            raise APIError(410, "WORKOUT_DELETED", "训练已删除，不能重新上传此 ID")
        if not created and payload.revision <= workout.revision:
            if payload.revision < workout.revision or not await same_content(
                session, workout, payload
            ):
                raise revision_conflict(workout)
        else:
            # 固定 ID 顺序减少并发登记多组时的死锁；冲突后重新校验真实归属。
            await session.execute(
                insert(WorkoutSet)
                .values(
                    [
                        {"set_id": set_id, "workout_id": workout_id, "is_removed": True}
                        for set_id in set_ids
                    ]
                )
                .on_conflict_do_nothing(index_elements=[WorkoutSet.set_id])
            )
            await verify_set_ownership(session, set_ids, user_id, workout_id)
            # 先清为完整移除形态，再恢复新数组，交换位置也始终符合 CHECK／唯一约束。
            await retire_sets(session, workout_id)
            await session.execute(
                update(WorkoutSet),
                [
                    dict(item.model_dump(), position=position, is_removed=False)
                    for position, item in enumerate(payload.sets, 1)
                ],
            )
            for name, value in content.items():
                setattr(workout, name, value)
        result = receipt(workout)
    return result


@router.delete("/{workout_id}", response_model=WriteReceipt)
async def delete_workout(
    workout_id: ClientId,
    revision: Annotated[QueryRevision, Query()],
    request: Request,
    session: DatabaseSession,
):
    async with session.begin():
        user_id = await authenticated_user_id(request, session)
        workout, created = await create_or_lock(
            session, workout_id, user_id, {"revision": revision, "is_deleted": True}
        )
        if not created and (
            revision < workout.revision
            or (revision == workout.revision and not workout.is_deleted)
        ):
            raise revision_conflict(workout)
        if not workout.is_deleted:
            await retire_sets(session, workout_id)
            for name in ["record_kind", "started_at", "ended_at", "time_zone"]:
                setattr(workout, name, None)
            workout.is_deleted = True
        workout.revision = revision
        result = receipt(workout)
    return result
