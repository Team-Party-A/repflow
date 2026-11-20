from collections import defaultdict
from datetime import UTC, date, datetime, time, timedelta
from decimal import Decimal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import delete, or_, select, tuple_

from app.errors import APIError
from app.nutrition_catalog import lock_key
from app.nutrition_models import Food, FoodVersion, Meal, MealItem
from app.nutrition_schemas import serving, total, unknown_food


def numbers(values):
    return {
        key: float(value) if value is not None else None
        for key, value in values.items()
    }


def render(meal, rows):
    items, values = [], []
    for row in rows:
        nutrients = serving(row.snapshot["per_100g"], row.grams)
        values.append(nutrients)
        items.append(
            {
                "food": row.snapshot,
                "grams": float(row.grams) if row.grams is not None else None,
                "nutrients": numbers(nutrients),
            }
        )
    totals = total(values)
    return dict(
        id=meal.id,
        revision=meal.revision,
        eaten_at=meal.eaten_at,
        items=items,
        totals=numbers(totals),
    ), totals


async def get_meal(db, owner, ident):
    meal = await db.get(Meal, ident)
    if meal is None or meal.owner_id != owner or meal.deleted:
        raise APIError(404, "NOT_FOUND", "找不到这餐")
    rows = await db.scalars(
        select(MealItem).where(MealItem.meal_id == ident).order_by(MealItem.position)
    )
    return render(meal, rows)[0]


async def save(db, owner, ident, data):
    await lock_key(db, "meal", ident)
    meal = await db.get(Meal, ident)
    created = meal is None
    digest = data.write_hash()
    if meal is not None:
        if meal.owner_id != owner:
            raise APIError(404, "NOT_FOUND", "找不到这餐")
        if (
            not meal.deleted
            and meal.revision == data.revision
            and meal.input_hash == digest
        ):
            return await get_meal(db, owner, ident), False
    previous = meal.revision if meal is not None else 0
    if (meal is not None and meal.deleted) or data.revision != previous + 1:
        raise APIError(
            409,
            "REVISION_CONFLICT",
            "餐次版本已变化，请刷新",
            current_revision=previous,
        )
    refs = {
        (item.food.id, item.food.version)
        for item in data.items
        if item.food is not None
    }
    found = {}
    if refs:
        result = await db.scalars(
            select(FoodVersion)
            .join(Food, Food.id == FoodVersion.food_id)
            .where(
                or_(Food.owner_id == owner, Food.owner_id.is_(None)),
                tuple_(FoodVersion.food_id, FoodVersion.version).in_(list(refs)),
            )
        )
        found = {(v.food_id, v.version): v.snapshot for v in result}
        if found.keys() != refs:
            raise APIError(404, "NOT_FOUND", "食物或该版本不可用")
    if created:
        meal = Meal(id=ident, owner_id=owner, deleted=False)
        db.add(meal)
    meal.revision, meal.eaten_at, meal.input_hash = (
        data.revision,
        data.eaten_at.astimezone(UTC),
        digest,
    )
    await db.flush()
    await db.execute(delete(MealItem).where(MealItem.meal_id == ident))
    rows = []
    for index, item in enumerate(data.items):
        food = (
            found[(item.food.id, item.food.version)]
            if item.food
            else unknown_food(item.unmatched_name)
        )
        row = MealItem(
            meal_id=ident,
            position=index,
            grams=None if item.grams is None else Decimal(str(item.grams)),
            snapshot=food,
        )
        rows.append(row)
    db.add_all(rows)
    return render(meal, rows)[0], created


async def remove(db, owner, ident, revision):
    await lock_key(db, "meal", ident)
    meal = await db.get(Meal, ident)
    if meal is None or meal.owner_id != owner:
        raise APIError(404, "NOT_FOUND", "找不到这餐")
    if meal.deleted and revision == meal.revision:
        return
    if meal.deleted or revision != meal.revision + 1:
        raise APIError(
            409,
            "REVISION_CONFLICT",
            "餐次版本已变化，请刷新",
            current_revision=meal.revision,
        )
    meal.revision, meal.deleted, meal.eaten_at = revision, True, None
    await db.execute(delete(MealItem).where(MealItem.meal_id == ident))


async def day_meals(db, owner, day: date, timezone: str):
    try:
        zone = ZoneInfo(timezone)
        start = datetime.combine(day, time.min, zone).astimezone(UTC)
        end = datetime.combine(day + timedelta(days=1), time.min, zone).astimezone(UTC)
    except ZoneInfoNotFoundError, ValueError, OverflowError:
        raise APIError(422, "VALIDATION_ERROR", "日期或时区无效") from None
    statement = (
        select(Meal, MealItem)
        .join(MealItem, MealItem.meal_id == Meal.id)
        .where(
            Meal.owner_id == owner,
            ~Meal.deleted,
            Meal.eaten_at >= start,
            Meal.eaten_at < end,
        )
        .order_by(Meal.eaten_at, Meal.id, MealItem.position)
    )
    grouped = defaultdict(list)
    meals = {}
    for meal, item in await db.execute(statement):
        grouped[meal.id].append(item)
        meals[meal.id] = meal
    records, values = [], []
    for ident, meal in meals.items():
        record, nutrients = render(meal, grouped[ident])
        records.append(record)
        values.append(nutrients)
    return dict(
        date=day, timezone=timezone, meals=records, totals=numbers(total(values))
    )
