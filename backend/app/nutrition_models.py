from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import (
    ARRAY,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Numeric,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.models import Base


class Food(Base):
    __tablename__ = "nutrition_foods"
    __table_args__ = (
        UniqueConstraint("owner_id", "request_key"),
        Index(
            "nutrition_public_key",
            "name_key",
            "preparation_key",
            unique=True,
            postgresql_where=text("owner_id IS NULL AND merged_into IS NULL"),
        ),
        CheckConstraint("source IN ('private','ai_estimate','verified')"),
        CheckConstraint("version > 0"),
        CheckConstraint("(source = 'private') = (owner_id IS NOT NULL)"),
        CheckConstraint(
            "source <> 'verified' OR length(trim(source_reference)) > 0 AND source_reference IS NOT NULL"
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID | None] = mapped_column(ForeignKey("users.user_id"))
    name: Mapped[str] = mapped_column(Text)
    preparation: Mapped[str] = mapped_column(Text)
    name_key: Mapped[str] = mapped_column(Text)
    preparation_key: Mapped[str] = mapped_column(Text)
    aliases: Mapped[list[str]] = mapped_column(ARRAY(Text))
    alias_keys: Mapped[list[str]] = mapped_column(ARRAY(Text))
    source: Mapped[str] = mapped_column(Text)
    version: Mapped[int]
    source_reference: Mapped[str | None] = mapped_column(Text)
    profile: Mapped[dict] = mapped_column(JSONB)
    merged_into: Mapped[UUID | None] = mapped_column(ForeignKey("nutrition_foods.id"))
    request_key: Mapped[UUID | None]
    input_hash: Mapped[str | None] = mapped_column(Text)


class FoodVersion(Base):
    __tablename__ = "nutrition_food_versions"
    food_id: Mapped[UUID] = mapped_column(
        ForeignKey("nutrition_foods.id"), primary_key=True
    )
    version: Mapped[int] = mapped_column(primary_key=True)
    snapshot: Mapped[dict] = mapped_column(JSONB)


class Submission(Base):
    __tablename__ = "nutrition_submissions"
    __table_args__ = (
        UniqueConstraint("food_id", "version"),
        ForeignKeyConstraint(
            ["food_id", "version"],
            ["nutrition_food_versions.food_id", "nutrition_food_versions.version"],
        ),
        CheckConstraint("status IN ('pending','verified','rejected','merged')"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    food_id: Mapped[UUID]
    version: Mapped[int]
    status: Mapped[str] = mapped_column(Text)
    public_id: Mapped[UUID | None] = mapped_column(ForeignKey("nutrition_foods.id"))


class Meal(Base):
    __tablename__ = "nutrition_meals"
    __table_args__ = (
        CheckConstraint("revision > 0"),
        Index(
            "nutrition_day",
            "owner_id",
            "eaten_at",
            "id",
            postgresql_where=text("NOT deleted"),
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.user_id"))
    revision: Mapped[int]
    eaten_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    input_hash: Mapped[str] = mapped_column(Text)
    deleted: Mapped[bool]


class MealItem(Base):
    __tablename__ = "nutrition_meal_items"
    __table_args__ = (CheckConstraint("grams > 0"),)
    meal_id: Mapped[UUID] = mapped_column(
        ForeignKey("nutrition_meals.id", ondelete="CASCADE"), primary_key=True
    )
    position: Mapped[int] = mapped_column(primary_key=True)
    grams: Mapped[Decimal | None] = mapped_column(Numeric)
    snapshot: Mapped[dict] = mapped_column(JSONB)


class Analysis(Base):
    __tablename__ = "nutrition_analyses"
    __table_args__ = (
        UniqueConstraint("owner_id", "request_key"),
        Index("nutrition_analyses_date", "created_at"),
        CheckConstraint("status IN ('queued','processing','ready','failed','expired')"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.user_id"))
    request_key: Mapped[UUID]
    input_hash: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(Text)
    failure_code: Mapped[str | None] = mapped_column(Text)
    items: Mapped[list] = mapped_column(JSONB)
    metrics: Mapped[dict] = mapped_column(JSONB)
