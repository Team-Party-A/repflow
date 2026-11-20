"""受限运维命令：仅持有服务数据库权限的维护者可用。"""

import argparse
import asyncio
import json
import sys
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.nutrition_catalog import (
    assign_profile,
    describe,
    lock_key,
    publish,
    record_version,
)
from app.nutrition_models import Analysis, Food, Submission
from app.nutrition_schemas import FoodInput, Profile, food_key
from app.settings import DatabaseSettings


async def moderate(
    db, command, ident=None, *, reference=None, profile=None, target=None
):
    if command == "list":
        pending = await db.execute(
            select(Submission, Food)
            .join(Food, Food.id == Submission.food_id)
            .where(Submission.status == "pending")
            .order_by(Submission.id)
        )
        estimates = await db.scalars(
            select(Food)
            .where(Food.source == "ai_estimate", Food.merged_into.is_(None))
            .order_by(Food.id)
        )
        return {
            "submissions": [
                {"id": str(entry.id), "food": describe(food)} for entry, food in pending
            ],
            "estimates": [describe(food) for food in estimates],
        }
    if command == "metrics":
        job = await db.get(Analysis, ident)
        if job is None:
            raise ValueError("找不到识别任务")
        return {"status": job.status, **job.metrics}
    # 串行化维护者操作，以一致顺序更新投稿、合并目标和不可变的历史版本。
    await lock_key(db, "moderation")
    if command == "merge":
        if ident == target:
            raise ValueError("重复项和保留项必须不同")
        records = (
            await db.scalars(
                select(Food)
                .where(Food.id.in_((ident, target)))
                .order_by(Food.id)
                .with_for_update()
            )
        ).all()
        by_id = {food.id: food for food in records}
        if len(records) != 2 or any(
            food.owner_id is not None or food.merged_into for food in records
        ):
            raise ValueError("只能合并两项有效的共享食物")
        source, kept = by_id[ident], by_id[target]
        if source.preparation_key != kept.preparation_key or (
            source.source == "verified" and kept.source != "verified"
        ):
            raise ValueError("请核对生熟状态并保留已核实条目")
        kept.aliases = list(
            dict.fromkeys([*kept.aliases, source.name, *source.aliases])
        )
        kept.alias_keys = list(dict.fromkeys(map(food_key, kept.aliases)))
        source.merged_into = kept.id
        kept.version += 1
        await record_version(db, kept)
        for submission in await db.scalars(
            select(Submission).where(Submission.public_id == ident)
        ):
            submission.public_id, submission.status = target, "merged"
        return describe(kept)
    entry = await db.get(Submission, ident, with_for_update=True)
    if entry is not None and entry.status != "pending":
        raise ValueError("投稿已处理")
    if command == "reject":
        if entry is None:
            raise ValueError("找不到待审核投稿")
        entry.status = "rejected"
        return {"status": entry.status}
    if not reference or not reference.strip():
        raise ValueError("核实需要包装标签或有许可的成分表出处")
    source = await db.get(Food, entry.food_id if entry else ident, with_for_update=True)
    if (
        source is None
        or source.merged_into
        or (not entry and source.owner_id is not None)
    ):
        raise ValueError("只能核实已投稿或当前公开的食物")
    data = FoodInput(
        name=source.name,
        preparation=source.preparation,
        aliases=source.aliases,
        per_100g=profile if profile is not None else source.profile,
    )
    if entry:
        public = await publish(db, data, "verified", reference.strip())
        entry.status, entry.public_id = "verified", public.id
    else:
        assign_profile(source, data)
        source.version += 1
        source.source, source.source_reference = "verified", reference.strip()
        await record_version(db, source)
        public = source
    return describe(public)


async def run(args):
    engine = create_async_engine(
        DatabaseSettings.from_environment().url, hide_parameters=True
    )
    try:
        async with async_sessionmaker(engine, expire_on_commit=False).begin() as db:
            return await moderate(
                db,
                args.command,
                getattr(args, "id", None),
                target=getattr(args, "target", None),
                reference=getattr(args, "reference", None),
                profile=Profile.model_validate_json(args.profile)
                if getattr(args, "profile", None)
                else None,
            )
    finally:
        await engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    for name in ("verify", "reject", "merge", "metrics"):
        sub = commands.add_parser(name)
        sub.add_argument("id", type=UUID)
        if name == "verify":
            sub.add_argument("--reference", required=True)
            sub.add_argument("--profile", help="每 100 克的四项数值，JSON")
        if name == "merge":
            sub.add_argument("target", type=UUID)
    args = parser.parse_args()
    try:
        output = asyncio.run(run(args))
    except ValueError as error:
        parser.exit(2, f"{error}\n")
    sys.stdout.write(json.dumps(output, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
