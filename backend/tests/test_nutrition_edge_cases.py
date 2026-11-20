import asyncio
import json
import sys
from unittest.mock import AsyncMock
from uuid import UUID, uuid4

import pytest
from test_nutrition import (
    BASE,
    FRAME,
    JPEG,
    META,
    PROFILE,
    RICE,
    SCAN,
    TestProvider,
    finished,
    key,
    login,
)

from app import nutrition_admin
from app.nutrition_analysis import shutdown, stripped_jpeg, work
from app.nutrition_ark import ProviderFailure, VisualItem
from app.nutrition_catalog import publish
from app.nutrition_models import Submission
from app.nutrition_schemas import FoodInput


@pytest.mark.asyncio
async def test_catalog_pagination_public_priority_and_distinct_preparations(
    account_client,
):
    app, client = account_client
    owner = await login(client, "catalog_paging")

    async def estimate():
        async with app.state.database_sessions.begin() as db:
            return (await publish(db, FoodInput(**RICE), "ai_estimate")).id

    one, two = await asyncio.gather(estimate(), estimate())
    assert one == two
    async with app.state.database_sessions.begin() as db:
        official = await publish(db, FoodInput(**RICE), "verified", "标签")
        assert official.id == one and official.version == 2
        raw = await publish(
            db, FoodInput(**(RICE | {"preparation": "生"})), "ai_estimate"
        )
        assert raw.id != official.id
    mine = await client.post(BASE + "/foods", headers=key(owner), json=RICE)
    assert mine.status_code == 201
    cursor, ids = None, []
    for _ in range(3):
        query = {"q": "米饭", "limit": 1}
        if cursor:
            query["cursor"] = cursor
        page = await client.get(BASE + "/foods", headers=owner, params=query)
        assert page.status_code == 200
        ids.append(page.json()["items"][0]["id"])
        cursor = page.json()["next_cursor"]
        if cursor:
            other = await client.get(
                BASE + "/foods", headers=owner, params={"q": "豆腐", "cursor": cursor}
            )
            assert other.status_code == 422
    assert ids == [str(official.id), mine.json()["id"], str(raw.id)] and cursor is None
    bad = await client.get(BASE + "/foods", headers=owner, params={"cursor": "invalid"})
    assert bad.status_code == 422


@pytest.mark.asyncio
async def test_moderation_only_accepts_owned_submissions_and_respects_verified_references(
    account_client,
):
    app, client = account_client
    owner = await login(client, "moderation_bounds")
    private = (await client.post(BASE + "/foods", headers=key(owner), json=RICE)).json()
    submitted = (
        await client.post(f"{BASE}/foods/{private['id']}/submissions", headers=owner)
    ).json()
    async with app.state.database_sessions.begin() as db:
        first = await nutrition_admin.moderate(
            db, "verify", UUID(submitted["id"]), reference="标签原文"
        )
        first_id = UUID(first["id"])
        other = await publish(
            db, FoodInput(**(RICE | {"name": "另一种饭", "aliases": []})), "ai_estimate"
        )
        cooked = await publish(
            db,
            FoodInput(**(RICE | {"name": "去皮熟饭", "aliases": []})),
            "verified",
            "标签 B",
        )
        for command, ident, options in [
            ("verify", UUID(private["id"]), {"reference": "出处"}),
            ("verify", first_id, {"reference": " "}),
            ("reject", UUID(submitted["id"]), {}),
            ("reject", uuid4(), {}),
            ("merge", first_id, {"target": first_id}),
            ("merge", first_id, {"target": other.id}),
            ("metrics", uuid4(), {}),
        ]:
            with pytest.raises(ValueError):
                await nutrition_admin.moderate(db, command, ident, **options)
        kept = await nutrition_admin.moderate(db, "merge", first_id, target=cooked.id)
        assert first["name"] in kept["aliases"]
        record = await db.get(Submission, UUID(submitted["id"]))
        assert str(record.public_id) == kept["id"]
    resubmitted = await client.post(
        f"{BASE}/foods/{private['id']}/submissions", headers=owner
    )
    assert resubmitted.json() == {"id": submitted["id"], "status": "merged"}


def test_maintainer_cli_uses_test_database_and_reports_bad_inputs(
    account_database, monkeypatch, capsys
):
    _, schema, _, _ = account_database
    monkeypatch.setenv("PGOPTIONS", f"-c search_path={schema}")
    monkeypatch.setattr(sys, "argv", ["nutrition_admin", "list"])
    nutrition_admin.main()
    assert json.loads(capsys.readouterr().out) == {"submissions": [], "estimates": []}
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "nutrition_admin",
            "verify",
            str(uuid4()),
            "--profile",
            json.dumps(PROFILE),
            "--reference",
            "测试标签",
        ],
    )
    with pytest.raises(SystemExit) as exc:
        nutrition_admin.main()
    assert exc.value.code == 2 and "只能核实" in capsys.readouterr().err


@pytest.mark.asyncio
async def test_unrecognized_photo_partial_profiles_and_manually_recorded_meals(
    account_client, monkeypatch
):
    app, client = account_client
    owner, other = (
        await login(client, "photo_cases"),
        await login(client, "photo_cases_b"),
    )

    def upload():
        return client.post(
            BASE + "/analyses",
            headers=key(owner) | {"Content-Type": "image/jpeg"},
            content=JPEG,
        )

    monkeypatch.delenv("ARK_API_KEY", raising=False)
    assert (await upload()).status_code == 503
    provider = TestProvider()
    app.state.nutrition_provider = provider
    monkeypatch.setenv("NUTRITION_ACTIVE_LIMIT", "invalid")
    limited = await upload()
    assert limited.status_code == 429 and limited.headers["Retry-After"] == "2"
    monkeypatch.setenv("NUTRITION_ACTIVE_LIMIT", "2")
    provider.recognize = AsyncMock(return_value=([], {}))
    first = await upload()
    empty = await finished(client, owner, first.json()["id"])
    assert empty["status"] == "failed" and empty["failure_code"] == "no_food"

    known = VisualItem(
        name="通用食物", preparation="熟", grams=10, needs_review=False, generic=True
    )
    private = known.model_copy(update={"name": "私人餐包", "generic": False})
    provider.recognize = AsyncMock(return_value=([known, private], {}))
    provider.profiles = AsyncMock(side_effect=ProviderFailure("invalid_result"))
    new = await upload()
    job = await finished(client, owner, new.json()["id"])
    assert job["status"] == "ready"
    assert all(
        item["needs_review"] and item["food"]["source"] == "unmatched"
        for item in job["items"]
    )
    provider.profiles.assert_awaited_once_with([("通用食物", "熟")])
    async with app.state.database_sessions() as db:
        metrics = await nutrition_admin.moderate(db, "metrics", UUID(job["id"]))
    assert metrics["profile_error"] == "invalid_result"
    await work(app.state.database_sessions, provider, UUID(job["id"]), JPEG)
    provider.profiles.assert_awaited_once()
    path = f"{BASE}/meals/{uuid4()}"
    meal = {
        "revision": 1,
        "eaten_at": "2026-11-21T01:00:00Z",
        "items": [{"grams": 10, "unmatched_name": "私人餐包"}],
    }
    result = await client.put(path, json=meal, headers=owner)
    assert result.status_code == 201 and result.json()["totals"] == dict.fromkeys(
        PROFILE
    )
    assert (await client.put(path, json=meal, headers=other)).status_code == 404
    assert (
        await client.delete(path, params={"revision": 1}, headers=owner)
    ).status_code == 409


@pytest.mark.asyncio
async def test_shutdown_expires_active_work_without_saving_a_meal(account_client):
    app, client = account_client
    owner = await login(client, "photo_shutdown")
    provider = TestProvider()
    started = asyncio.Event()

    async def wait_for_provider(_):
        started.set()
        await asyncio.Event().wait()

    provider.recognize = wait_for_provider
    app.state.nutrition_provider = provider
    result = await client.post(
        BASE + "/analyses",
        headers=key(owner) | {"Content-Type": "image/jpeg"},
        content=JPEG,
    )
    await asyncio.wait_for(started.wait(), 3)
    await shutdown(app)
    job = await finished(client, owner, result.json()["id"])
    assert job["status"] == job["failure_code"] == "expired" and not job["items"]


@pytest.mark.parametrize(
    "image",
    [
        b"\xff\xd8",
        b"\xff\xd8x",
        b"\xff\xd8\xff",
        b"\xff\xd8\xff\xd9",
        b"\xff\xd8\xff\xd8",
        b"\xff\xd8" + META[:-1],
        b"\xff\xd8" + FRAME.replace(b"\x00\x01", b"\x00\x00", 1) + SCAN + b"\xff\xd9",
        b"\xff\xd8" + SCAN + b"\xff\xd9",
        JPEG[:-2],
        JPEG[:-1],
    ],
)
def test_incomplete_or_invalid_jpegs_are_rejected(image):
    with pytest.raises(ValueError):
        stripped_jpeg(image)


def test_progressive_scan_keeps_stuffed_bytes_and_restart_markers():
    encoded = JPEG[:-2] + b"\xff\x00\x12\xff\xd0\x03\xff" + META + SCAN + b"\xff\xd9"
    cleaned = stripped_jpeg(encoded)
    assert b"\xff\x00\x12\xff\xd0\x03" in cleaned and META not in cleaned
