import asyncio
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select

from app.nutrition_admin import moderate
from app.nutrition_analysis import MAX_BYTES, stripped_jpeg
from app.nutrition_ark import ArkProvider, ProviderFailure, VisualItem, account_cost
from app.nutrition_catalog import publish
from app.nutrition_models import Analysis, Food
from app.nutrition_schemas import FoodInput, Profile

BASE = "/api/v1/nutrition"
PROFILE = {"carbs_g": 28, "protein_g": 2, "fat_g": 0, "energy_kcal": 120}
RICE = {"name": "米饭", "preparation": "熟", "aliases": ["白米饭"], "per_100g": PROFILE}
FRAME = bytes.fromhex("ffc0000b080001000101011100")
SCAN = bytes.fromhex("ffda0008010100003f0003")
META = bytes.fromhex("ffe1000b") + b"GPSsecret"
JPEG = b"\xff\xd8" + META + FRAME + SCAN + b"\xff\xd9"


async def login(client, username):
    response = await client.post(
        "/api/v1/auth/register",
        json={"username": username, "password": "diet integration test only"},
    )
    assert response.status_code == 201, response.text
    return {"Authorization": "Bearer " + response.json()["access_token"]}


def key(headers):
    return {**headers, "Idempotency-Key": str(uuid4())}


@pytest.mark.asyncio
async def test_private_food_submission_meals_history_and_isolation(account_client):
    app, client = account_client
    alice = await login(client, "rice_owner")
    bob = await login(client, "rice_other")
    req = key(alice)
    create = await client.post(BASE + "/foods", headers=req, json=RICE)
    assert create.status_code == 201, create.text
    rice = create.json()
    assert rice["source"] == "private"
    assert (
        await client.post(BASE + "/foods", headers=req, json=RICE)
    ).status_code == 200
    assert (
        await client.post(BASE + "/foods", headers=req, json=RICE | {"name": "豆腐"})
    ).status_code == 409
    assert (await client.get(BASE + "/foods", headers=bob)).json()["items"] == []
    assert (
        await client.get(BASE + "/foods", headers=alice, params={"q": "白米"})
    ).json()["items"] == [rice]
    ref = {k: rice[k] for k in ("id", "version")}
    path = BASE + "/meals/" + str(uuid4())
    meal = {
        "revision": 1,
        "eaten_at": "2026-11-21T00:15:00+08:00",
        "items": [{"grams": 200, "food": ref}],
    }
    assert (await client.put(path, headers=bob, json=meal)).status_code == 404
    first = await client.put(path, headers=alice, json=meal)
    assert first.status_code == 201, first.text
    assert first.json()["totals"] == {
        "carbs_g": 56,
        "protein_g": 4,
        "fat_g": 0,
        "energy_kcal": 240,
    }
    assert (await client.put(path, headers=alice, json=meal)).status_code == 200
    assert (await client.get(path, headers=bob)).status_code == 404
    assert (
        await client.delete(path, headers=bob, params={"revision": 2})
    ).status_code == 404
    assert (
        await client.put(path, headers=alice, json=meal | {"revision": 3})
    ).status_code == 409
    assert (
        await client.get(
            BASE + "/meals",
            headers=alice,
            params={"date": "2026-11-20", "timezone": "UTC"},
        )
    ).json()["meals"][0]["id"] == first.json()["id"]
    assert not (
        await client.get(
            BASE + "/meals",
            headers=alice,
            params={"date": "2026-11-20", "timezone": "Asia/Shanghai"},
        )
    ).json()["meals"]
    assert (
        await client.get(
            BASE + "/meals",
            headers=alice,
            params={"date": "2026-11-21", "timezone": "invalid-zone"},
        )
    ).status_code == 422
    submission = BASE + "/foods/" + rice["id"] + "/submissions"
    assert (await client.post(submission, headers=bob)).status_code == 404
    posted = await client.post(submission, headers=alice)
    assert posted.status_code == 201
    assert (await client.post(submission, headers=alice)).json() == posted.json()
    async with app.state.database_sessions.begin() as db:
        public = await moderate(
            db, "verify", UUID(posted.json()["id"]), reference="包装标签 A"
        )
    assert public["source"] == "verified" and public["source_reference"] == "包装标签 A"
    public_ref = {k: public[k] for k in ("id", "version")}
    public_meal = BASE + "/meals/" + str(uuid4())
    assert (
        await client.put(
            public_meal,
            headers=bob,
            json=meal | {"items": [{"grams": 120, "food": public_ref}]},
        )
    ).status_code == 201
    async with app.state.database_sessions.begin() as db:
        revised = await moderate(
            db,
            "verify",
            UUID(public["id"]),
            reference="新标签 B",
            profile=Profile(**(PROFILE | {"carbs_g": 20})),
        )
    assert revised["version"] == public["version"] + 1
    assert (await client.get(public_meal, headers=bob)).json()["totals"][
        "carbs_g"
    ] == 33.6
    edit = meal | {
        "revision": 2,
        "items": [
            {"grams": 120, "food": ref},
            {"grams": None, "unmatched_name": "酱汁"},
        ],
    }
    updated = await client.put(path, headers=alice, json=edit)
    assert updated.status_code == 200 and updated.json()["totals"] == dict.fromkeys(
        PROFILE
    )
    assert updated.json()["items"][0]["nutrients"]["energy_kcal"] == 144
    for _ in range(2):
        assert (
            await client.delete(path, headers=alice, params={"revision": 3})
        ).status_code == 204
    assert (await client.put(path, headers=alice, json=edit)).status_code == 409
    assert (await client.get(path, headers=alice)).status_code == 404


class TestProvider:
    __test__ = False
    available, vision, text = True, "vision-test", "text-test"

    def __init__(self):
        self.calls = []
        self.images = []
        self.fail = False

    async def recognize(self, picture):
        assert b"GPSsecret" not in picture
        self.images.append(len(picture))
        if self.fail:
            raise ProviderFailure()
        return [
            VisualItem(
                name=name, preparation="熟", grams=120, needs_review=True, generic=True
            )
            for name in ("白米饭", "青豆", "青豆")
        ], {"prompt_tokens": 10, "completion_tokens": 5}

    async def profiles(self, foods):
        self.calls.append(foods)
        return {pair: Profile(**PROFILE) for pair in foods}, {
            "prompt_tokens": 8,
            "completion_tokens": 4,
        }


async def finished(client, headers, ident):
    for _ in range(120):
        response = await client.get(BASE + "/analyses/" + ident, headers=headers)
        assert response.status_code == 200, response.text
        if response.json()["status"] not in ("processing", "queued"):
            return response.json()
        await asyncio.sleep(0.05)
    pytest.fail("识别任务未结束")


@pytest.mark.asyncio
async def test_analysis_real_task_lifecycle_and_batched_cache(
    account_client, monkeypatch
):
    app, client = account_client
    alice, bob = await login(client, "photo_owner"), await login(client, "photo_other")
    request = key(alice) | {"Content-Type": "image/jpeg"}
    first_path = BASE + "/analyses"
    assert (
        await client.post(first_path, headers=key(alice), content=b"x")
    ).status_code == 415
    assert (
        await client.post(first_path, headers=request, content=b"invalid")
    ).status_code == 422
    assert (
        await client.post(first_path, headers=request, content=b"x" * (MAX_BYTES + 1))
    ).status_code == 413
    provider = TestProvider()
    app.state.nutrition_provider = provider
    async with app.state.database_sessions.begin() as db:
        await publish(db, FoodInput(**RICE), "verified", "测试包装标签")
    for var in ("VISION_INPUT", "VISION_OUTPUT", "TEXT_INPUT", "TEXT_OUTPUT"):
        monkeypatch.setenv("ARK_" + var + "_CNY_PER_MTOK", "1")
    results = await asyncio.gather(
        *(client.post(first_path, headers=request, content=JPEG) for _ in range(2))
    )
    assert all(res.status_code == 202 for res in results), [r.text for r in results]
    ident = results[0].json()["id"]
    assert results[1].json()["id"] == ident
    assert (await client.get(first_path + "/" + ident, headers=bob)).status_code == 404
    draft = await finished(client, alice, ident)
    assert draft["status"] == "ready", draft
    assert [i["food"]["source"] for i in draft["items"]] == [
        "verified",
        "ai_estimate",
        "ai_estimate",
    ]
    assert len(provider.images) == 1 and provider.calls == [[("青豆", "熟")]]
    assert (
        await client.get(
            BASE + "/meals",
            headers=alice,
            params={"date": "2026-11-21", "timezone": "UTC"},
        )
    ).json()["meals"] == []
    changed = JPEG.replace(b"GPSsecret", b"GPSother1")
    assert (
        await client.post(first_path, headers=request, content=changed)
    ).status_code == 409
    rerun = await client.post(
        first_path, headers=key(bob) | {"Content-Type": "image/jpeg"}, content=JPEG
    )
    assert (await finished(client, bob, rerun.json()["id"]))["status"] == "ready"
    assert len(provider.calls) == 1
    async with app.state.database_sessions() as db:
        metrics = (await db.get(Analysis, UUID(ident))).metrics
        assert metrics["cache_hits_unique"] == 1 and metrics["lookups_unique"] == 2
        assert float(metrics["cost_cny"]) == 27 / 1_000_000
        assert (
            await db.scalar(
                select(func.count())
                .select_from(Food)
                .where(Food.source == "ai_estimate")
            )
            == 1
        )
    provider.fail = True
    failed = await client.post(
        first_path, headers=key(alice) | {"Content-Type": "image/jpeg"}, content=JPEG
    )
    assert (await finished(client, alice, failed.json()["id"]))[
        "failure_code"
    ] == "provider_unavailable"
    monkeypatch.setenv("NUTRITION_DAILY_LIMIT", "0")
    quota = await client.post(
        first_path, headers=key(alice) | {"Content-Type": "image/jpeg"}, content=JPEG
    )
    assert quota.status_code == 429 and int(quota.headers["retry-after"]) > 0
    assert (await client.post(first_path, headers=request, content=JPEG)).json()[
        "id"
    ] == ident
    async with app.state.database_sessions.begin() as db:
        job = await db.get(Analysis, UUID(ident))
        job.status = "processing"
        job.items = []
        job.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    assert (await finished(client, alice, ident))["status"] == "expired"


@pytest.mark.asyncio
async def test_moderation_merges_public_only_and_rejects_submissions(account_client):
    app, client = account_client
    auth = await login(client, "catalog_owner")
    private = (await client.post(BASE + "/foods", headers=key(auth), json=RICE)).json()
    entry = (
        await client.post(
            BASE + "/foods/" + private["id"] + "/submissions", headers=auth
        )
    ).json()
    async with app.state.database_sessions.begin() as db:
        assert len((await moderate(db, "list"))["submissions"]) == 1
        assert await moderate(db, "reject", UUID(entry["id"])) == {"status": "rejected"}
        original = await publish(db, FoodInput(**RICE), "verified", "标签")
        duplicate = await publish(
            db, FoodInput(**(RICE | {"name": "普通熟饭", "aliases": []})), "ai_estimate"
        )
        with pytest.raises(ValueError):
            await moderate(db, "merge", UUID(private["id"]), target=original.id)
        kept = await moderate(db, "merge", duplicate.id, target=original.id)
        assert "普通熟饭" in kept["aliases"]
    page = await client.get(BASE + "/foods", headers=auth, params={"q": "普通熟饭"})
    assert (
        len(page.json()["items"]) == 1 and page.json()["items"][0]["id"] == kept["id"]
    )


@pytest.mark.asyncio
async def test_ark_validates_model_output_and_does_not_invent_cost(monkeypatch):
    provider = ArkProvider()

    def answer(*args):
        return {
            "items": [
                {"index": 0, "per_100g": PROFILE},
                {"index": 1, "per_100g": PROFILE | {"fat_g": 101}},
            ]
        }, {}

    monkeypatch.setattr(provider, "_request", answer)
    profiles, _ = await provider.profiles([("饭", "熟"), ("油", "生")])
    assert list(profiles) == [("饭", "熟")]
    assert account_cost({"vision_calls": 1})["cost_cny"] is None
    assert stripped_jpeg(JPEG) == JPEG.replace(META, b"")
    assert stripped_jpeg(JPEG[:-2] + META + SCAN + b"\xff\xd9").count(b"GPSsecret") == 0
    with pytest.raises(ValueError):
        stripped_jpeg(JPEG + b"hidden")


@pytest.mark.asyncio
async def test_empty_or_invalid_inputs_never_write_food_or_meal(account_client):
    _, client = account_client
    auth = await login(client, "manual_owner")
    for field, value in (
        ("fat_g", 101),
        ("carbs_g", -1),
        ("protein_g", "20"),
        ("energy_kcal", 1001),
    ):
        res = await client.post(
            BASE + "/foods",
            headers=key(auth),
            json=RICE | {"per_100g": PROFILE | {field: value}},
        )
        assert res.status_code == 422
    assert (await client.get(BASE + "/foods", headers=auth)).json()["items"] == []
    assert (await client.get(BASE + "/foods")).status_code == 401
    path = BASE + "/meals/" + str(uuid4())
    for item in (
        {"grams": 0, "unmatched_name": "饭"},
        {"grams": 1},
        {
            "grams": 1,
            "food": {"id": str(uuid4()), "version": 1},
            "unmatched_name": "重复",
        },
    ):
        assert (
            await client.put(
                path,
                headers=auth,
                json={
                    "revision": 1,
                    "eaten_at": "2026-11-20T11:00:00Z",
                    "items": [item],
                },
            )
        ).status_code == 422
