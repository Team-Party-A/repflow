from copy import deepcopy
from uuid import uuid1, uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select
from test_accounts import bearer, register
from test_workout_writes import workout_input

from app.models import Workout, WorkoutSet
from app.workout_schemas import WorkoutInput

INVALID_FIELDS = [("revision", value) for value in [True, 1.0, "1", 0, 2147483648]] + [
    ("record_kind", "template"),
    ("started_at", "2026-02-30T00:00:00Z"),
    ("started_at", "2026-11-01T24:00:00Z"),
    ("started_at", "2026-11-01T00:00:00+00:00"),
    ("started_at", "2026-11-01T00:00:00.1234567Z"),
    ("started_at", 1793491200),
    ("ended_at", "2026-10-31T23:59:59Z"),
    ("time_zone", "NoSuch/Zone"),
    ("time_zone", "../UTC"),
    ("time_zone", ""),
    ("time_zone", "a" * 65),
    ("sets", []),
    ("user_id", str(uuid4())),
]
INVALID_SET_FIELDS = [
    ("set_id", str(uuid1())),
    ("set_id", uuid4().hex),
    ("set_id", "{" + str(uuid4()) + "}"),
    ("exercise_id", "unknown_exercise"),
    ("exercise_id", "dumbbell_curl\n"),
    ("record_source", "replay"),
    ("estimated_rep_count", None),
    ("estimated_rep_count", -1),
    ("estimated_rep_count", 2147483648),
    ("estimated_rep_count", True),
    ("estimated_rep_count", 1.0),
    ("final_rep_count", 0),
    ("final_rep_count", 10000),
    ("final_rep_count", True),
    ("final_rep_count", 1.0),
    ("final_rep_count", "10"),
    ("weight_grams", -1),
    ("weight_grams", 1000001),
    ("weight_grams", False),
    ("weight_grams", 0.5),
    ("position", 1),
]


@pytest.mark.parametrize("name,value", INVALID_FIELDS)
def test_invalid_workout_fields(name, value):
    with pytest.raises(ValidationError):
        WorkoutInput.model_validate(workout_input() | {name: value})


@pytest.mark.parametrize("name,value", INVALID_SET_FIELDS)
def test_invalid_set_fields(name, value):
    payload = workout_input()
    payload["sets"][0][name] = value
    with pytest.raises(ValidationError):
        WorkoutInput.model_validate(payload)


@pytest.mark.parametrize("name", list(workout_input()))
def test_all_workout_fields_are_required_even_nullable_ones(name):
    payload = workout_input()
    del payload[name]
    with pytest.raises(ValidationError):
        WorkoutInput.model_validate(payload)


@pytest.mark.parametrize("name", list(workout_input()["sets"][0]))
def test_all_set_fields_are_required_even_nullable_ones(name):
    payload = workout_input()
    del payload["sets"][0][name]
    with pytest.raises(ValidationError):
        WorkoutInput.model_validate(payload)


def test_set_limit_and_duplicate_ids_after_normalization():
    payload = workout_input(2147483647)
    payload["sets"] *= 2
    payload["sets"] = deepcopy(payload["sets"])
    payload["sets"][1]["set_id"] = payload["sets"][0]["set_id"].upper()
    with pytest.raises(ValidationError):
        WorkoutInput.model_validate(payload)
    template = payload["sets"][0]
    payload["sets"] = [template | {"set_id": str(uuid4())} for _ in range(1000)]
    assert len(WorkoutInput.model_validate(payload).sets) == 1000
    payload["sets"].append(template | {"set_id": str(uuid4())})
    with pytest.raises(ValidationError):
        WorkoutInput.model_validate(payload)


@pytest.mark.parametrize("weight", [None, 0, 1000000])
def test_manual_and_corrected_automatic_boundaries(weight):
    payload = workout_input(2147483647)
    payload["started_at"] = "2026-11-01T00:00:00.123456Z"
    payload["ended_at"] = payload["started_at"]
    payload["sets"][0].update(
        final_rep_count=9999, estimated_rep_count=0, weight_grams=weight
    )
    # 修正最终次数不改变来源；也不按当前手表算法支持范围限制共享动作。
    payload["sets"][0]["exercise_id"] = "pull_up"
    assert WorkoutInput.model_validate(payload).sets[0].estimated_rep_count == 0
    payload["sets"][0].update(record_source="manual", estimated_rep_count=None)
    assert WorkoutInput.model_validate(payload).sets[0].estimated_rep_count is None
    payload["sets"][0]["estimated_rep_count"] = 1
    with pytest.raises(ValidationError):
        WorkoutInput.model_validate(payload)


@pytest.mark.asyncio
async def test_validation_http_paths_and_sensitive_input_do_not_persist(
    account_client, caplog
):
    application, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    url = "/api/v1/workouts/" + str(uuid4())
    for field, value in INVALID_FIELDS:
        response = await client.put(
            url, json=workout_input() | {field: value}, headers=headers
        )
        assert response.status_code == 422, response.text
        assert response.json()["error"]["code"] == "VALIDATION_ERROR"
    for field, value in INVALID_SET_FIELDS:
        payload = workout_input()
        payload["sets"][0][field] = value
        response = await client.put(url, json=payload, headers=headers)
        assert response.status_code == 422, response.text
        if field == "final_rep_count":
            assert response.json()["error"]["fields"] == [
                {"path": "/sets/0/final_rep_count", "message": "字段不符合接口要求"}
            ]
    sensitive = "private-example-must-not-echo"
    response = await client.put(
        url, json=workout_input() | {sensitive: sensitive}, headers=headers
    )
    assert response.status_code == 422
    assert sensitive not in response.text + caplog.text
    response = await client.put(
        url,
        content='{"password":"' + sensitive,
        headers=headers | {"Content-Type": "application/json"},
    )
    assert response.status_code == 400
    assert sensitive not in response.text + caplog.text
    async with application.state.database_sessions() as session:
        assert await session.scalar(select(func.count()).select_from(Workout)) == 0
        assert await session.scalar(select(func.count()).select_from(WorkoutSet)) == 0


@pytest.mark.asyncio
async def test_path_and_delete_query_validation(account_client):
    _, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    for workout_id in [str(uuid1()), uuid4().hex, "not-a-uuid"]:
        response = await client.put(
            "/api/v1/workouts/" + workout_id, json=workout_input(), headers=headers
        )
        assert response.status_code == 422
        assert response.json()["error"]["fields"][0]["path"] == ""
    url = "/api/v1/workouts/" + str(uuid4())
    for revision in ["1.0", "1e0", "true", "-1", "0", "2147483648", ""]:
        response = await client.delete(
            url, params={"revision": revision}, headers=headers
        )
        assert response.status_code == 422
        assert response.json()["error"]["fields"][0]["path"] == ""
    missing = await client.request("DELETE", url, json={"revision": 1}, headers=headers)
    assert missing.status_code == 422
    maximum = await client.delete(url, params={"revision": 2147483647}, headers=headers)
    assert maximum.status_code == 200
