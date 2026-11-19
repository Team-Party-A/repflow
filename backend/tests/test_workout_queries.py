import base64
import json
from copy import deepcopy
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import insert
from test_accounts import PASSWORD, bearer, register
from test_workout_writes import snapshot, workout_input

from app.models import Workout, WorkoutSet

URL = "/api/v1/workouts"


async def seed_workouts(application, user_id, count, day=1):
    # 分页要覆盖同一时间的多个 ID；只在隔离测试库构造数据，写入行为另有完整测试。
    records = [
        dict(
            workout_id=uuid4(),
            user_id=UUID(user_id),
            revision=1,
            is_deleted=False,
            record_kind="actual",
            started_at=datetime(2026, 11, day, tzinfo=UTC)
            + timedelta(seconds=index // 3),
            ended_at=None,
            time_zone="Asia/Shanghai",
        )
        for index in range(count)
    ]
    async with application.state.database_sessions() as session, session.begin():
        await session.execute(insert(Workout), records)
        await session.execute(
            insert(WorkoutSet),
            [
                dict(
                    set_id=uuid4(),
                    workout_id=record["workout_id"],
                    is_removed=False,
                    position=1,
                    exercise_id="push_up",
                    final_rep_count=10,
                    estimated_rep_count=None,
                    record_source="manual",
                    weight_grams=None,
                )
                for record in records
            ],
        )
    return sorted(
        records, key=lambda item: (item["started_at"], item["workout_id"]), reverse=True
    )


def pack_cursor(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def unpack_cursor(value):
    return json.loads(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)))


@pytest.mark.asyncio
async def test_empty_query_is_success_and_is_not_cached(account_client):
    _, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    response = await client.get(URL, headers=headers)
    assert response.status_code == 200, response.text
    assert response.json() == {"items": [], "next_cursor": None}
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.asyncio
async def test_query_returns_full_ordered_groups_and_utc_times(account_client):
    _, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    workout_id = str(uuid4())
    payload = workout_input(7)
    payload["sets"].append(workout_input()["sets"][0])
    payload["sets"][0].update(
        record_source="manual", estimated_rep_count=None, weight_grams=0
    )
    payload["started_at"] = "2026-11-01T00:00:00.123456Z"
    payload["ended_at"] = "2026-11-01T01:00:00.123456Z"
    assert (
        await client.put(URL + "/" + workout_id, json=payload, headers=headers)
    ).status_code == 200
    result = await client.get(URL, headers=headers)
    assert result.status_code == 200, result.text
    assert result.json() == {
        "items": [dict(deepcopy(payload), workout_id=workout_id)],
        "next_cursor": None,
    }


@pytest.mark.asyncio
async def test_pagination_default_limit_ties_and_changing_limit(account_client):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    expected = [
        str(item["workout_id"])
        for item in await seed_workouts(application, account["user_id"], 101)
    ]
    original = await snapshot(application)
    page = (await client.get(URL, headers=headers)).json()
    assert len(page["items"]) == 50
    seen = [item["workout_id"] for item in page["items"]]
    for limit, size in [(1, 1), (100, 50)]:
        assert page["next_cursor"] and len(page["next_cursor"]) <= 2048
        response = await client.get(
            URL, params={"limit": limit, "cursor": page["next_cursor"]}, headers=headers
        )
        assert response.status_code == 200, response.text
        page = response.json()
        assert len(page["items"]) == size
        seen += [item["workout_id"] for item in page["items"]]
    assert page["next_cursor"] is None and seen == expected
    maximum = (await client.get(URL, params={"limit": 100}, headers=headers)).json()
    assert len(maximum["items"]) == 100 and maximum["next_cursor"]
    assert await snapshot(application) == original


@pytest.mark.asyncio
async def test_query_excludes_other_accounts_deleted_workouts_and_removed_sets(
    account_client,
):
    application, client = account_client
    first = (await register(client, "first_owner")).json()
    second = (await register(client, "second_owner")).json()
    first_headers, second_headers = (
        bearer(first["access_token"]),
        bearer(second["access_token"]),
    )
    foreign = await seed_workouts(application, second["user_id"], 2)
    workout_id, deleted_id = str(uuid4()), str(uuid4())
    payload = workout_input()
    payload["sets"].append(workout_input()["sets"][0])
    assert (
        await client.put(URL + "/" + workout_id, json=payload, headers=first_headers)
    ).status_code == 200
    payload["revision"] = 2
    payload["sets"].pop(0)
    assert (
        await client.put(URL + "/" + workout_id, json=payload, headers=first_headers)
    ).status_code == 200
    assert (
        await client.put(
            URL + "/" + deleted_id, json=workout_input(), headers=first_headers
        )
    ).status_code == 200
    assert (
        await client.delete(
            URL + "/" + deleted_id, params={"revision": 2}, headers=first_headers
        )
    ).status_code == 200
    for extra in [{}, {"user_id": second["user_id"]}]:
        response = await client.get(URL, params=extra, headers=first_headers)
        assert response.status_code == 200
        assert response.json() == {
            "items": [dict(payload, workout_id=workout_id)],
            "next_cursor": None,
        }
    response = await client.get(URL, headers=second_headers)
    assert [item["workout_id"] for item in response.json()["items"]] == [
        str(item["workout_id"]) for item in foreign
    ]


@pytest.mark.asyncio
async def test_time_filter_is_left_closed_right_open_by_started_at(account_client):
    _, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    times = [
        "2026-10-31T23:59:59.999999Z",
        "2026-11-01T00:00:00Z",
        "2026-11-01T00:00:00.999999Z",
        "2026-11-01T00:00:01Z",
    ]
    ids = [str(uuid4()) for _ in times]
    for workout_id, started_at in zip(ids, times):
        payload = workout_input() | {
            "started_at": started_at,
            "time_zone": "America/New_York",
        }
        assert (
            await client.put(URL + "/" + workout_id, json=payload, headers=headers)
        ).status_code == 200
    for params, indices in [
        ({"started_from": times[1], "started_before": times[3]}, [2, 1]),
        ({"started_from": times[1]}, [3, 2, 1]),
        ({"started_before": times[3]}, [2, 1, 0]),
        ({"started_from": "2026-11-02T00:00:00Z"}, []),
    ]:
        response = await client.get(URL, params=params, headers=headers)
        assert response.status_code == 200
        assert [item["workout_id"] for item in response.json()["items"]] == [
            ids[index] for index in indices
        ]


@pytest.mark.asyncio
async def test_cursor_is_bound_to_account_and_normalized_filters_not_login_or_limit(
    account_client,
):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    await seed_workouts(application, account["user_id"], 5)
    filters = {
        "started_from": "2026-11-01T00:00:00Z",
        "started_before": "2026-11-02T00:00:00Z",
    }
    first = (
        await client.get(URL, params=filters | {"limit": 2}, headers=headers)
    ).json()
    cursor = first["next_cursor"]
    assert cursor
    equivalent = {
        name: value.replace("Z", ".000000Z") for name, value in filters.items()
    }
    new_login = await client.post(
        "/api/v1/auth/login", json={"username": "account_one", "password": PASSWORD}
    )
    response = await client.get(
        URL,
        params=equivalent | {"cursor": cursor, "limit": 1},
        headers=bearer(new_login.json()["access_token"]),
    )
    assert response.status_code == 200 and len(response.json()["items"]) == 1
    for changed in [
        {},
        {"started_from": filters["started_from"]},
        filters | {"started_from": "2026-10-31T00:00:00Z"},
        filters | {"started_before": "2026-11-03T00:00:00Z"},
    ]:
        response = await client.get(
            URL, params=changed | {"cursor": cursor}, headers=headers
        )
        assert response.status_code == 422
    other = (await register(client, "other_owner")).json()
    denied = await client.get(
        URL, params=filters | {"cursor": cursor}, headers=bearer(other["access_token"])
    )
    assert denied.status_code == 422


@pytest.mark.asyncio
async def test_unsigned_cursor_cannot_authorize_foreign_data(account_client):
    application, client = account_client
    first, second = (
        (await register(client, "first_owner")).json(),
        (await register(client, "second_owner")).json(),
    )
    owned = await seed_workouts(application, first["user_id"], 2)
    await seed_workouts(application, second["user_id"], 2, day=2)
    foreign_page = (
        await client.get(
            URL, params={"limit": 1}, headers=bearer(second["access_token"])
        )
    ).json()
    forged = unpack_cursor(foreign_page["next_cursor"])
    forged["user_id"] = first["user_id"]
    response = await client.get(
        URL,
        params={"cursor": pack_cursor(forged)},
        headers=bearer(first["access_token"]),
    )
    assert response.status_code == 200
    assert [item["workout_id"] for item in response.json()["items"]] == [
        str(item["workout_id"]) for item in owned
    ]


@pytest.mark.asyncio
async def test_deleted_anchor_does_not_break_the_next_page(account_client):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    records = await seed_workouts(application, account["user_id"], 4)
    first = (await client.get(URL, params={"limit": 2}, headers=headers)).json()
    anchor = first["items"][-1]["workout_id"]
    assert (
        await client.delete(URL + "/" + anchor, params={"revision": 2}, headers=headers)
    ).status_code == 200
    response = await client.get(
        URL, params={"cursor": first["next_cursor"]}, headers=headers
    )
    assert response.status_code == 200
    assert [item["workout_id"] for item in response.json()["items"]] == [
        str(item["workout_id"]) for item in records[2:]
    ]
