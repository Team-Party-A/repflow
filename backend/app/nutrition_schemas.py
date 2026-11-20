import hashlib
import json
import unicodedata
from datetime import UTC
from decimal import Decimal
from typing import Annotated
from uuid import UUID

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    model_validator,
)

Name = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)
]
Revision = Annotated[int, Field(strict=True, ge=1, le=2147483647)]
Amount = Annotated[float, Field(strict=True, ge=0, allow_inf_nan=False)]
Macro = Annotated[float, Field(strict=True, ge=0, le=100, allow_inf_nan=False)]
Weight = Annotated[float, Field(strict=True, gt=0, allow_inf_nan=False, le=1000000)]
NUTRIENTS = ("carbs_g", "protein_g", "fat_g", "energy_kcal")


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)


class Profile(Input):
    carbs_g: Macro | None
    protein_g: Macro | None
    fat_g: Macro | None
    energy_kcal: Amount | None = Field(le=1000)


class FoodInput(Input):
    name: Name
    preparation: Name
    aliases: list[Name] = Field(default_factory=list, max_length=32)
    per_100g: Profile


class FoodRef(Input):
    id: UUID
    version: Revision


class MealItemInput(Input):
    grams: Weight | None
    food: FoodRef | None = None
    unmatched_name: Name | None = None

    @model_validator(mode="after")
    def require_one_source(self):
        if (self.food is None) == (self.unmatched_name is None):
            raise ValueError("choose a food or supply an unmatched name")
        return self


class MealInput(Input):
    revision: Revision
    eaten_at: AwareDatetime
    items: list[MealItemInput] = Field(min_length=1, max_length=256)

    def write_hash(self):
        payload = self.model_dump(mode="json", exclude_none=False)
        payload["eaten_at"] = self.eaten_at.astimezone(UTC).isoformat()
        return fingerprint(payload)


def food_key(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def fingerprint(payload: dict) -> str:
    data = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )
    return hashlib.sha256(data.encode()).hexdigest()


def unknown_food(name: str) -> dict:
    return dict(
        reference=None,
        name=name,
        preparation="未注明",
        source="unmatched",
        source_reference=None,
        per_100g=dict.fromkeys(NUTRIENTS),
    )


def serving(profile: dict, grams: Decimal | None) -> dict:
    return {
        key: None
        if value is None or grams is None
        else Decimal(str(value)) * grams / 100
        for key, value in profile.items()
    }


def total(rows: list[dict]) -> dict:
    result = dict.fromkeys(NUTRIENTS, Decimal(0))
    for row in rows:
        for key, value in row.items():
            result[key] = (
                None if value is None or result[key] is None else result[key] + value
            )
    return result
