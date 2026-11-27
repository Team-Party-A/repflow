"""仅用于新建的 Compose HTTPS 验收项目，核对饮食迁移、可恢复备份和手动记餐。"""

import hashlib
import json
from urllib.request import Request, urlopen
from uuid import uuid4


def check(command, address, tls):
    owner = "repflow_https_test"
    archive = "/tmp/repflow-nutrition-before.dump"
    restored = "repflow_nutrition_restore_test"

    def call(path, method="GET", data=None, *, token=None, ident=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        if ident:
            headers["Idempotency-Key"] = str(ident)
        request = Request(
            address + "/api/v1/" + path,
            method=method,
            headers=headers,
            data=json.dumps(data).encode() if data is not None else None,
        )
        with urlopen(request, timeout=10, context=tls) as reply:
            return json.load(reply) if reply.status != 204 else None

    def psql(database, sql):
        return command(
            "exec",
            "-T",
            "db",
            "psql",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            owner,
            "-d",
            database,
            "-Atc",
            sql,
        ).strip()

    command("exec", "-T", "api", "alembic", "upgrade", "0002_workouts")
    token = call(
        "auth/register",
        "POST",
        {"username": "nutrition_demo", "password": "isolated-check-nutrition"},
    )["access_token"]
    command(
        "exec", "-T", "db", "pg_dump", "-U", owner, "-d", owner, "-Fc", "-f", archive
    )
    digest = command("exec", "-T", "db", "sha256sum", archive).split()[0]
    assert len(bytes.fromhex(digest)) == hashlib.sha256().digest_size
    assert "TABLE DATA" in command("exec", "-T", "db", "pg_restore", "--list", archive)
    command("exec", "-T", "db", "createdb", "-U", owner, restored)
    command(
        "exec",
        "-T",
        "db",
        "pg_restore",
        "--exit-on-error",
        "-U",
        owner,
        "-d",
        restored,
        archive,
    )
    assert psql(restored, "SELECT version_num FROM alembic_version") == "0002_workouts"
    assert psql(restored, "SELECT username FROM users") == "nutrition_demo"
    command("exec", "-T", "api", "alembic", "upgrade", "head")
    food = call(
        "nutrition/foods",
        "POST",
        {
            "name": "测试米饭",
            "preparation": "熟",
            "per_100g": {"carbs_g": 28, "protein_g": 2, "fat_g": 0, "energy_kcal": 120},
        },
        token=token,
        ident=uuid4(),
    )
    path = "nutrition/meals/" + str(uuid4())
    meal = {
        "eaten_at": "2026-11-20T19:00:00+08:00",
        "revision": 1,
        "items": [
            {"food": {"id": food["id"], "version": food["version"]}, "grams": 200}
        ],
    }
    assert call(path, "PUT", meal, token=token)["totals"]["energy_kcal"] == 240
    meal["revision"] = 2
    meal["items"][0]["grams"] = 120
    call(path, "PUT", meal, token=token)
    day = call("nutrition/meals?date=2026-11-20&timezone=Asia%2FShanghai", token=token)
    assert len(day["meals"]) == 1 and day["totals"] == {
        "carbs_g": 33.6,
        "protein_g": 2.4,
        "fat_g": 0,
        "energy_kcal": 144,
    }
    assert psql(owner, "SELECT username FROM users") == "nutrition_demo"
    return digest
