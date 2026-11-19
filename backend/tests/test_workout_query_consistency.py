import asyncio
from copy import deepcopy
from uuid import uuid4

import pytest
from sqlalchemy import event, text
from test_accounts import bearer, register
from test_workout_queries import URL
from test_workout_writes import workout_input


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["replace", "delete"])
async def test_one_page_has_a_single_snapshot_during_concurrent_change(
    account_client, change
):
    application, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    workout_id = str(uuid4())
    payload = workout_input()
    payload["sets"].append(workout_input()["sets"][0])
    assert (
        await client.put(URL + "/" + workout_id, json=payload, headers=headers)
    ).status_code == 200
    engine = application.state.database_sessions.kw["bind"].sync_engine
    parents_loaded, resume = asyncio.Event(), asyncio.Event()
    settings = []

    async def hold(driver):
        parents_loaded.set()
        await asyncio.wait_for(resume.wait(), timeout=5)

    def pause(connection, cursor, statement, parameters, context, executemany):
        if (
            statement.startswith("SELECT workout_sets.set_id")
            and not parents_loaded.is_set()
        ):
            settings.append(
                (
                    connection.exec_driver_sql("SHOW transaction_isolation").scalar(),
                    connection.exec_driver_sql("SHOW transaction_read_only").scalar(),
                )
            )
            # 使用驱动适配器在 SQL 边界等待；写入走另一条连接，不靠 sleep 碰调度。
            connection.connection.run_async(hold)

    event.listen(engine, "before_cursor_execute", pause)
    reader = asyncio.create_task(client.get(URL, headers=headers))
    replacement = deepcopy(payload)
    replacement["revision"] = 2
    replacement["sets"] = [workout_input()["sets"][0]]
    try:
        await asyncio.wait_for(parents_loaded.wait(), timeout=5)
        if change == "replace":
            response = await client.put(
                URL + "/" + workout_id, json=replacement, headers=headers
            )
        else:
            response = await client.delete(
                URL + "/" + workout_id, params={"revision": 2}, headers=headers
            )
        assert response.status_code == 200, response.text
        resume.set()
        response = await asyncio.wait_for(reader, timeout=5)
    finally:
        resume.set()
        event.remove(engine, "before_cursor_execute", pause)
        if not reader.done():
            reader.cancel()
        await asyncio.gather(reader, return_exceptions=True)
    assert settings == [("repeatable read", "on")]
    assert response.status_code == 200
    assert response.json()["items"] == [dict(payload, workout_id=workout_id)]
    latest = await client.get(URL, headers=headers)
    assert latest.status_code == 200
    assert latest.json()["items"] == (
        [] if change == "delete" else [dict(replacement, workout_id=workout_id)]
    )


@pytest.mark.asyncio
async def test_read_transaction_settings_are_restored_before_next_write(account_client):
    application, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    assert (await client.get(URL, headers=headers)).status_code == 200
    async with application.state.database_sessions() as session:
        assert (
            await session.scalar(text("SHOW transaction_isolation")) == "read committed"
        )
        assert await session.scalar(text("SHOW transaction_read_only")) == "off"
    response = await client.put(
        URL + "/" + str(uuid4()), json=workout_input(), headers=headers
    )
    assert response.status_code == 200, response.text
