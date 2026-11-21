from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Request, Response

from app import nutrition_catalog as catalogue
from app import nutrition_meals as meals
from app.auth import DatabaseSession, authenticated_user_id
from app.nutrition_schemas import FoodInput, MealInput, fingerprint

router = APIRouter(prefix="/api/v1/nutrition")


async def owner_id(request: Request, session: DatabaseSession):
    return await authenticated_user_id(request, session)


Owner = Annotated[UUID, Depends(owner_id)]
Key = Annotated[UUID, Header(alias="Idempotency-Key")]


@router.get("/foods")
async def foods(
    owner: Owner,
    session: DatabaseSession,
    q: str = Query("", max_length=120),
    limit: int = Query(20, ge=1, le=50),
    cursor: str | None = Query(None, max_length=2048),
):
    return await catalogue.search(session, owner, q, limit, cursor)


@router.post("/foods")
async def create_food(
    data: FoodInput,
    owner: Owner,
    key: Key,
    session: DatabaseSession,
    response: Response,
):
    food, created = await catalogue.save_private(
        session, owner, key, data, fingerprint(data.model_dump())
    )
    await session.commit()
    response.status_code = 201 if created else 200
    return catalogue.describe(food)


@router.post("/foods/{food_id}/submissions")
async def submit_food(
    food_id: UUID, owner: Owner, session: DatabaseSession, response: Response
):
    entry, created = await catalogue.submit(session, owner, food_id)
    await session.commit()
    response.status_code = 201 if created else 200
    return {"id": entry.id, "status": entry.status}


@router.get("/meals")
async def meal_day(
    date: date,
    timezone: Annotated[str, Query(min_length=1, max_length=128)],
    owner: Owner,
    session: DatabaseSession,
):
    return await meals.day_meals(session, owner, date, timezone)


@router.get("/meals/{meal_id}")
async def get_meal(meal_id: UUID, owner: Owner, session: DatabaseSession):
    return await meals.get_meal(session, owner, meal_id)


@router.put("/meals/{meal_id}")
async def save_meal(
    meal_id: UUID,
    data: MealInput,
    owner: Owner,
    session: DatabaseSession,
    response: Response,
):
    result, created = await meals.save(session, owner, meal_id, data)
    await session.commit()
    response.status_code = 201 if created else 200
    return result


@router.delete("/meals/{meal_id}", status_code=204)
async def delete_meal(
    meal_id: UUID,
    revision: Annotated[int, Query(ge=1, le=2147483647)],
    owner: Owner,
    session: DatabaseSession,
):
    await meals.remove(session, owner, meal_id, revision)
    await session.commit()
    return Response(status_code=204)
