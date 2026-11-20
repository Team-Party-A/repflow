import base64
import binascii
import json
from uuid import UUID, uuid4

from sqlalchemy import case, func, or_, select, text, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import APIError
from app.nutrition_models import Food, FoodVersion, Submission
from app.nutrition_schemas import FoodInput, food_key


async def lock_key(db: AsyncSession, *parts):
    # 也保护尚不存在的行；请求重放和首次插入在同一个事务内判定。
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))"),
        {"key": json.dumps([str(part) for part in parts])},
    )


def describe(food: Food) -> dict:
    return dict(
        id=str(food.id),
        version=food.version,
        name=food.name,
        preparation=food.preparation,
        aliases=food.aliases,
        source=food.source,
        source_reference=food.source_reference,
        per_100g=food.profile,
    )


def snapshot(food: Food) -> dict:
    return dict(
        reference={"id": str(food.id), "version": food.version},
        name=food.name,
        preparation=food.preparation,
        source=food.source,
        source_reference=food.source_reference,
        per_100g=food.profile,
    )


def assign_profile(food: Food, data: FoodInput):
    food.name, food.preparation = data.name, data.preparation
    food.name_key, food.preparation_key = (
        food_key(data.name),
        food_key(data.preparation),
    )
    food.aliases = list(dict.fromkeys(data.aliases))
    food.alias_keys = list(dict.fromkeys(map(food_key, food.aliases)))
    food.profile = data.per_100g.model_dump()


async def record_version(db, food):
    await db.flush()
    db.add(FoodVersion(food_id=food.id, version=food.version, snapshot=snapshot(food)))
    await db.flush()


async def save_private(db, owner, key, data, digest):
    await lock_key(db, "private", owner, key)
    existing = await db.scalar(
        select(Food).where(Food.owner_id == owner, Food.request_key == key)
    )
    if existing is not None:
        if existing.input_hash != digest:
            raise APIError(409, "REQUEST_CONFLICT", "同一请求标识已用于另一条食物")
        return existing, False
    food = Food(
        id=uuid4(),
        owner_id=owner,
        version=1,
        source="private",
        request_key=key,
        input_hash=digest,
    )
    assign_profile(food, data)
    db.add(food)
    await record_version(db, food)
    return food, True


async def find_public(db, name, preparation):
    key = food_key(name)
    return await db.scalar(
        select(Food)
        .where(
            Food.owner_id.is_(None),
            Food.merged_into.is_(None),
            Food.preparation_key == food_key(preparation),
            or_(Food.name_key == key, Food.alias_keys.any(key)),
        )
        .order_by(
            (Food.source == "verified").desc(), (Food.name_key == key).desc(), Food.id
        )
        .limit(1)
    )


async def publish(db, data, source, reference=None):
    await lock_key(db, "catalogue", food_key(data.name), food_key(data.preparation))
    food = await find_public(db, data.name, data.preparation)
    if food and (source == "ai_estimate" or food.source == "verified"):
        return food
    if food is None:
        food = Food(id=uuid4(), version=1, source=source)
        db.add(food)
    else:
        food.version += 1
    food.source, food.source_reference = source, reference
    assign_profile(food, data)
    await record_version(db, food)
    return food


async def search(db, owner, query, limit, cursor):
    name = food_key(query)
    rank = case((Food.source == "verified", 0), (Food.source == "private", 1), else_=2)
    statement = select(Food, rank).where(
        or_(Food.owner_id == owner, Food.owner_id.is_(None)), Food.merged_into.is_(None)
    )
    if name:
        statement = statement.where(
            or_(
                Food.name_key.contains(name, autoescape=True),
                func.array_to_string(Food.alias_keys, " ").contains(
                    name, autoescape=True
                ),
            )
        )
    if cursor:
        try:
            previous_query, order, previous_name, ident = json.loads(
                base64.urlsafe_b64decode(cursor)
            )
            if (
                previous_query != name
                or type(order) is not int
                or not isinstance(previous_name, str)
            ):
                raise ValueError
            last_id = UUID(ident)
        except ValueError, TypeError, AttributeError, binascii.Error:
            raise APIError(422, "VALIDATION_ERROR", "食物查询游标无效") from None
        statement = statement.where(
            tuple_(rank, Food.name_key, Food.id) > (order, previous_name, last_id)
        )
    rows = (
        await db.execute(
            statement.order_by(rank, Food.name_key, Food.id).limit(limit + 1)
        )
    ).all()
    next_cursor = None
    if len(rows) > limit:
        last, order = rows[limit - 1]
        token = json.dumps([name, order, last.name_key, str(last.id)]).encode()
        next_cursor = base64.urlsafe_b64encode(token).decode()
    return {
        "items": [describe(food) for food, _ in rows[:limit]],
        "next_cursor": next_cursor,
    }


async def submit(db, owner, ident):
    await lock_key(db, "submission", ident)
    food = await db.get(Food, ident)
    if food is None or food.owner_id != owner:
        raise APIError(404, "NOT_FOUND", "找不到这项私人食物")
    entry = await db.scalar(
        select(Submission).where(
            Submission.food_id == ident, Submission.version == food.version
        )
    )
    if entry is not None:
        return entry, False
    entry = Submission(
        id=uuid4(), food_id=ident, version=food.version, status="pending"
    )
    db.add(entry)
    return entry, True
