from copy import deepcopy
from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy import event, select, text
from sqlalchemy.exc import OperationalError
from test_accounts import bearer, register

from app import auth
from app.models import LoginSession, Workout, WorkoutSet


def workout_input(revision=1):
    return {
        "revision": revision,
        "record_kind": "actual",
        "started_at": "2026-11-01T00:00:00Z",
        "ended_at": None,
        "time_zone": "Asia/Shanghai",
        "sets": [
            {
                "set_id": str(uuid4()),
                "exercise_id": "dumbbell_curl",
                "final_rep_count": 10,
                "estimated_rep_count": 9,
                "record_source": "automatic",
                "weight_grams": None,
            }
        ],
    }


async def snapshot(application):
    # xmin 用来证明幂等重试没有 UPDATE，不只检查最终内容碰巧相同。
    async with application.state.database_sessions() as session:
        return [
            (
                await session.execute(
                    text(f"SELECT *, xmin::text AS row_version FROM {table} ORDER BY 1")
                )
            )
            .mappings()
            .all()
            for table in ["workouts", "workout_sets"]
        ]


@pytest.mark.asyncio
async def test_first_upload_is_idempotent_and_rejects_old_revision(account_client):
    _, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    workout_id = str(uuid4())
    url = "/api/v1/workouts/" + workout_id
    payload = workout_input(7)
    for _ in range(2):
        response = await client.put(url, json=payload, headers=headers)
        assert response.status_code == 200, response.text
        assert response.json() == {
            "workout_id": workout_id,
            "accepted_revision": 7,
            "deleted": False,
        }
    payload["revision"] = 6
    conflict = await client.put(url, json=payload, headers=headers)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["current_revision"] == 7


@pytest.mark.asyncio
async def test_delete_unknown_id_blocks_even_newer_upload(account_client):
    _, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    workout_id = str(uuid4())
    url = "/api/v1/workouts/" + workout_id
    response = await client.delete(url, params={"revision": 2}, headers=headers)
    assert response.status_code == 200, response.text
    assert response.json()["deleted"] is True
    for revision in [1, 2, 3]:
        replay = await client.put(url, json=workout_input(revision), headers=headers)
        assert replay.status_code == 410
        assert replay.json()["error"]["code"] == "WORKOUT_DELETED"


@pytest.mark.asyncio
async def test_normalized_retry_is_noop_and_changed_content_conflicts(account_client):
    application, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    workout_id = str(uuid4())
    url = "/api/v1/workouts/" + workout_id
    payload = workout_input()
    payload["sets"].append(workout_input()["sets"][0])
    assert (await client.put(url, json=payload, headers=headers)).status_code == 200
    original = await snapshot(application)
    canonical = dict(reversed(list(deepcopy(payload).items())))
    canonical["started_at"] = "2026-11-01T00:00:00.000000Z"
    for item in canonical["sets"]:
        item["set_id"] = item["set_id"].upper()
    assert (
        await client.put(
            "/api/v1/workouts/" + workout_id.upper(),
            json=canonical,
            headers=headers,
        )
    ).status_code == 200
    assert await snapshot(application) == original
    for change in ["order", "weight", "time_zone", "count"]:
        altered = deepcopy(payload)
        if change == "order":
            altered["sets"].reverse()
        elif change == "weight":
            altered["sets"][0]["weight_grams"] = 0
        elif change == "time_zone":
            altered["time_zone"] = "UTC"
        else:
            altered["sets"][0]["final_rep_count"] += 1
        response = await client.put(url, json=altered, headers=headers)
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "REVISION_CONFLICT"
        assert response.json()["error"]["current_revision"] == 1
    assert await snapshot(application) == original


@pytest.mark.asyncio
async def test_complete_replacement_reorders_removes_and_reuses_own_set_ids(
    account_client,
):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    workout_id = uuid4()
    url = "/api/v1/workouts/" + str(workout_id)
    payload = workout_input()
    payload["sets"] += [workout_input()["sets"][0] for _ in range(2)]
    payload["sets"][1].update(
        record_source="manual", estimated_rep_count=None, weight_grams=0
    )
    assert (await client.put(url, json=payload, headers=headers)).status_code == 200
    replacement = deepcopy(payload)
    replacement["revision"] = 2
    replacement["sets"] = [replacement["sets"][1], replacement["sets"][0]]
    replacement["ended_at"] = "2026-11-01T01:00:00.123456Z"
    assert (await client.put(url, json=replacement, headers=headers)).status_code == 200
    async with application.state.database_sessions() as session:
        stored = await session.get(Workout, workout_id)
        assert stored.revision == 2 and str(stored.user_id) == account["user_id"]
        groups = (
            await session.scalars(select(WorkoutSet).order_by(WorkoutSet.position))
        ).all()
        assert [str(item.set_id) for item in groups[:2]] == [
            item["set_id"] for item in replacement["sets"]
        ]
        assert [item.position for item in groups[:2]] == [1, 2]
        removed = groups[-1]
        assert removed.is_removed and removed.position is None
        assert all(
            getattr(removed, field) is None
            for field in [
                "exercise_id",
                "final_rep_count",
                "estimated_rep_count",
                "record_source",
                "weight_grams",
            ]
        )
        assert groups[0].weight_grams == 0 and groups[1].weight_grams is None
    payload["revision"] = 3
    assert (await client.put(url, json=payload, headers=headers)).status_code == 200
    async with application.state.database_sessions() as session:
        groups = (
            await session.scalars(select(WorkoutSet).where(~WorkoutSet.is_removed))
        ).all()
        assert len(groups) == 3


@pytest.mark.asyncio
async def test_delete_versions_clear_content_and_keep_permanent_id_ownership(
    account_client,
):
    application, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    workout_id = uuid4()
    url = "/api/v1/workouts/" + str(workout_id)
    payload = workout_input(2)
    assert (await client.put(url, json=payload, headers=headers)).status_code == 200
    original = await snapshot(application)
    for revision in [1, 2]:
        response = await client.delete(
            url, params={"revision": revision}, headers=headers
        )
        assert response.status_code == 409
        assert response.json()["error"]["current_revision"] == 2
    assert await snapshot(application) == original
    response = await client.delete(url, params={"revision": 3}, headers=headers)
    assert response.status_code == 200
    assert response.json() == {
        "workout_id": str(workout_id),
        "accepted_revision": 3,
        "deleted": True,
    }
    deleted = await snapshot(application)
    assert deleted[0][0]["is_deleted"] and deleted[1][0]["is_removed"]
    for name in ["record_kind", "started_at", "ended_at", "time_zone"]:
        assert deleted[0][0][name] is None
    for name in [
        "position",
        "exercise_id",
        "final_rep_count",
        "estimated_rep_count",
        "record_source",
        "weight_grams",
    ]:
        assert deleted[1][0][name] is None
    assert (
        await client.delete(url, params={"revision": 3}, headers=headers)
    ).status_code == 200
    assert await snapshot(application) == deleted
    assert (
        await client.delete(url, params={"revision": 4}, headers=headers)
    ).status_code == 200
    advanced = await snapshot(application)
    assert advanced[0][0]["revision"] == 4 and advanced[1] == deleted[1]
    assert (
        await client.delete(url, params={"revision": 3}, headers=headers)
    ).status_code == 409
    for revision in [2, 4, 5]:
        payload["revision"] = revision
        replay = await client.put(url, json=payload, headers=headers)
        assert replay.status_code == 410 and "current_revision" not in replay.text
    response = await client.put(
        "/api/v1/workouts/" + str(uuid4()), json=payload, headers=headers
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "SET_ID_CONFLICT"
    assert "current_revision" not in response.json()["error"]
    assert await snapshot(application) == advanced


@pytest.mark.asyncio
async def test_foreign_ids_never_disclose_versions_or_deleted_status(account_client):
    application, client = account_client
    first = bearer((await register(client, "first_owner")).json()["access_token"])
    second = bearer((await register(client, "second_owner")).json()["access_token"])
    owned_payload, foreign_payload = workout_input(7), workout_input(9)
    owned_url, foreign_url = ["/api/v1/workouts/" + str(uuid4()) for _ in range(2)]
    assert (
        await client.put(owned_url, json=owned_payload, headers=first)
    ).status_code == 200
    assert (
        await client.put(foreign_url, json=foreign_payload, headers=second)
    ).status_code == 200
    assert (
        await client.delete(foreign_url, params={"revision": 10}, headers=second)
    ).status_code == 200
    original = await snapshot(application)
    # 他人的训练本身、他人的已删除组、混合组均不能暴露资源状态。
    attempts = [
        (foreign_url, workout_input(1)),
        (owned_url, foreign_payload),
        ("/api/v1/workouts/" + str(uuid4()), foreign_payload),
        (
            "/api/v1/workouts/" + str(uuid4()),
            workout_input() | {"sets": owned_payload["sets"] + foreign_payload["sets"]},
        ),
    ]
    for url, payload in attempts:
        response = await client.put(url, json=payload, headers=first)
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "NOT_FOUND"
        assert "current_revision" not in response.json()["error"]
    response = await client.delete(foreign_url, params={"revision": 999}, headers=first)
    assert response.status_code == 404
    assert "current_revision" not in response.json()["error"]
    assert await snapshot(application) == original


@pytest.mark.asyncio
@pytest.mark.parametrize("state", ["missing", "invalid", "expired", "revoked"])
async def test_workout_routes_require_valid_live_session(account_client, state):
    application, client = account_client
    account = (await register(client)).json()
    headers = bearer(account["access_token"])
    if state == "missing":
        headers = {}
    elif state == "invalid":
        headers = bearer("invalid-example-token")
    else:
        async with application.state.database_sessions() as session, session.begin():
            stored = await session.get(
                LoginSession, auth.token_digest(account["access_token"])
            )
            if state == "expired":
                stored.expires_at = auth.now_utc() - timedelta(seconds=1)
            else:
                stored.revoked_at = auth.now_utc()
    url = "/api/v1/workouts/" + str(uuid4())
    responses = [
        await client.put(url, json=workout_input(), headers=headers),
        await client.delete(url, params={"revision": 1}, headers=headers),
    ]
    for response in responses:
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"
        assert response.headers["cache-control"] == "no-store"
    assert await snapshot(application) == [[], []]


@pytest.mark.asyncio
@pytest.mark.parametrize("stage", ["group_update", "commit"])
async def test_database_failure_rolls_back_entire_replacement_and_claims(
    account_client, caplog, stage
):
    application, client = account_client
    headers = bearer((await register(client)).json()["access_token"])
    url = "/api/v1/workouts/" + str(uuid4())
    payload = workout_input()
    assert (await client.put(url, json=payload, headers=headers)).status_code == 200
    original = await snapshot(application)
    replacement = workout_input(2)
    engine = application.state.database_sessions.kw["bind"].sync_engine

    def fail(*args):
        if stage == "group_update" and not (
            args[2].startswith("UPDATE workout_sets SET")
            and "WHERE workout_sets.set_id =" in args[2]
        ):
            return
        raise OperationalError(
            "private-sql", None, RuntimeError("private-connection-secret")
        )

    event_name = "commit" if stage == "commit" else "before_cursor_execute"
    event.listen(engine, event_name, fail)
    try:
        response = await client.put(url, json=replacement, headers=headers)
    finally:
        event.remove(engine, event_name, fail)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "SERVICE_UNAVAILABLE"
    assert "private-sql" not in response.text + caplog.text
    assert "private-connection-secret" not in response.text + caplog.text
    assert await snapshot(application) == original
    assert (await client.put(url, json=replacement, headers=headers)).status_code == 200
    assert (await client.put(url, json=replacement, headers=headers)).status_code == 200
