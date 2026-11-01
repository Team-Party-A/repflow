import asyncio
from copy import deepcopy
from uuid import UUID, uuid4

import pytest
from sqlalchemy import event, select
from test_accounts import bearer, register
from test_workout_writes import snapshot, workout_input

from app.models import Workout, WorkoutSet


async def contend(application, requests, prepare, statement_prefix):
    """等两个独立请求都到达受阻 SQL 后放锁，而非依赖调度或 sleep。"""
    sessions = application.state.database_sessions
    engine = sessions.kw["bind"].sync_engine
    arrived = asyncio.Event()
    count = 0

    def observe(connection, cursor, statement, parameters, context, executemany):
        nonlocal count
        if statement.startswith(statement_prefix):
            count += 1
            if count == 2:
                arrived.set()

    tasks = []
    async with sessions() as blocker:
        try:
            await prepare(blocker)
            event.listen(engine, "before_cursor_execute", observe)
            tasks = [asyncio.create_task(request) for request in requests]
            await asyncio.wait_for(arrived.wait(), timeout=5)
            # 首次创建测试中的占位行一并撤销，随后真实请求必须自己争用唯一键。
            await blocker.rollback()
            return await asyncio.wait_for(asyncio.gather(*tasks), timeout=5)
        finally:
            if event.contains(engine, "before_cursor_execute", observe):
                event.remove(engine, "before_cursor_execute", observe)
            await blocker.rollback()
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["same", "different", "out_of_order"])
async def test_competing_updates_have_a_serial_result(account_client, case):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    workout_id = uuid4()
    url = "/api/v1/workouts/" + str(workout_id)
    payload = workout_input()
    assert (await client.put(url, json=payload, headers=headers)).status_code == 200
    first = deepcopy(payload) | {"revision": 2}
    second = deepcopy(first)
    if case != "same":
        second["sets"][0]["final_rep_count"] = 15
    if case == "out_of_order":
        second["revision"] = 3

    async def lock(session):
        await session.execute(
            select(Workout).where(Workout.workout_id == workout_id).with_for_update()
        )

    responses = await contend(
        application,
        [
            client.put(url, json=first, headers=headers),
            client.put(url, json=second, headers=headers),
        ],
        lock,
        "INSERT INTO workouts",
    )
    statuses = sorted(response.status_code for response in responses)
    if case == "same":
        assert statuses == [200, 200]
    elif case == "different":
        assert statuses == [200, 409]
    else:
        assert responses[1].status_code == 200 and responses[0].status_code in [
            200,
            409,
        ]
    async with application.state.database_sessions() as session:
        stored = await session.get(Workout, workout_id)
        group = await session.scalar(select(WorkoutSet).where(~WorkoutSet.is_removed))
        assert stored.revision == (3 if case == "out_of_order" else 2)
        accepted = second if responses[1].status_code == 200 else first
        assert group.final_rep_count == accepted["sets"][0]["final_rep_count"]


@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["same_owner", "foreign_owner", "delete"])
async def test_first_creation_and_delete_share_one_permanent_identity(
    account_client, case
):
    application, client = account_client
    account = (await register(client, "first_user")).json()
    first = bearer(account["access_token"])
    second = first
    if case == "foreign_owner":
        second = bearer((await register(client, "second_user")).json()["access_token"])
    workout_id = uuid4()
    url = "/api/v1/workouts/" + str(workout_id)
    payload = workout_input()

    async def guard(session):
        session.add(
            Workout(
                workout_id=workout_id,
                user_id=UUID(account["user_id"]),
                revision=1,
                is_deleted=True,
            )
        )
        await session.flush()

    rival = (
        client.delete(url, params={"revision": 2}, headers=first)
        if case == "delete"
        else client.put(url, json=payload, headers=second)
    )
    responses = await contend(
        application,
        [client.put(url, json=payload, headers=first), rival],
        guard,
        "INSERT INTO workouts",
    )
    statuses = sorted(response.status_code for response in responses)
    if case == "same_owner":
        assert statuses == [200, 200]
    elif case == "foreign_owner":
        assert statuses == [200, 404]
        denied = next(response for response in responses if response.status_code == 404)
        assert "current_revision" not in denied.text
    else:
        assert responses[1].status_code == 200 and responses[0].status_code in [
            200,
            410,
        ]
        assert (await client.put(url, json=payload, headers=first)).status_code == 410
    async with application.state.database_sessions() as session:
        rows = (await session.scalars(select(Workout))).all()
        assert len(rows) == 1
        assert rows[0].is_deleted == (case == "delete")
        assert rows[0].revision == (2 if case == "delete" else 1)
        sets = (await session.scalars(select(WorkoutSet))).all()
        assert len(sets) <= 1 and all(item.is_removed for item in sets) == (
            case == "delete"
        )


@pytest.mark.asyncio
@pytest.mark.parametrize("foreign", [False, True])
async def test_racing_set_claims_recheck_owner_and_roll_back_all_new_ids(
    account_client, foreign
):
    application, client = account_client
    account = (await register(client, "first_user")).json()
    headers = [bearer(account["access_token"])] * 2
    if foreign:
        headers[1] = bearer(
            (await register(client, "second_user")).json()["access_token"]
        )
    shared_sets = [str(uuid4()), str(uuid4())]
    first, second = workout_input(), workout_input()
    for payload in [first, second]:
        payload["sets"].extend(
            workout_input()["sets"][0] | {"set_id": set_id} for set_id in shared_sets
        )
    # 两个输入用不同顺序，测试服务端固定登记顺序仍能正常处理。
    second["sets"].reverse()
    workout_ids = [uuid4(), uuid4()]
    guard_id = uuid4()

    async def guard(session):
        session.add(
            Workout(
                workout_id=guard_id,
                user_id=UUID(account["user_id"]),
                revision=1,
                is_deleted=True,
            )
        )
        await session.flush()
        session.add_all(
            WorkoutSet(set_id=UUID(set_id), workout_id=guard_id, is_removed=True)
            for set_id in shared_sets
        )
        await session.flush()

    responses = await contend(
        application,
        [
            client.put(
                "/api/v1/workouts/" + str(workout_id), json=payload, headers=header
            )
            for workout_id, payload, header in zip(
                workout_ids, [first, second], headers
            )
        ],
        guard,
        "INSERT INTO workout_sets",
    )
    assert sorted(response.status_code for response in responses) == [
        200,
        404 if foreign else 409,
    ]
    denied = next(response for response in responses if response.status_code != 200)
    assert denied.json()["error"]["code"] == (
        "NOT_FOUND" if foreign else "SET_ID_CONFLICT"
    )
    assert "current_revision" not in denied.text
    stored = await snapshot(application)
    assert len(stored[0]) == 1 and len(stored[1]) == 3
    assert all(row["workout_id"] == stored[0][0]["workout_id"] for row in stored[1])
    assert not any(row["is_removed"] for row in stored[1])
