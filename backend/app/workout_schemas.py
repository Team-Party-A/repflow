import re
from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import (
    UUID4,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    field_validator,
    model_validator,
)

EXERCISE_IDS = {
    "dumbbell_curl",
    "dumbbell_shoulder_press",
    "dumbbell_squat",
    "bench_press",
    "deadlift",
    "pull_up",
    "push_up",
}
CLIENT_ID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-"
    r"[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}"
)
UTC_TIME = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z"
)


def parse_client_id(value):
    if not isinstance(value, str) or not CLIENT_ID.fullmatch(value):
        raise ValueError("必须为标准 UUIDv4")
    return UUID(value)


def parse_utc_time(value):
    if not isinstance(value, str) or not UTC_TIME.fullmatch(value):
        raise ValueError("必须为 UTC 时间，至多微秒精度")
    # Python 的 ISO 解析也接受次日 24:00，契约采用的 RFC 3339 只允许 00–23 时。
    if int(value[11:13]) > 23:
        raise ValueError("UTC 小时必须介于 00 与 23")
    return datetime.fromisoformat(value)


def parse_query_revision(value):
    # URL 参数本来就是字符串，先拒绝 1.0 等写法，再交给严格整数范围校验。
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+", value):
        raise ValueError("必须为整数版本")
    return int(value)


ClientId = Annotated[UUID4, BeforeValidator(parse_client_id)]
UtcTime = Annotated[datetime, BeforeValidator(parse_utc_time)]
Revision = Annotated[int, Field(strict=True, ge=1, le=2147483647)]
QueryRevision = Annotated[Revision, BeforeValidator(parse_query_revision)]


class StrictInput(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)


class WorkoutSetInput(StrictInput):
    set_id: ClientId
    exercise_id: str = Field(min_length=1, max_length=64, pattern=r"^[a-z][a-z0-9_]*$")
    final_rep_count: int = Field(ge=1, le=9999)
    estimated_rep_count: Annotated[int, Field(ge=0, le=2147483647)] | None
    record_source: Literal["automatic", "manual"]
    weight_grams: Annotated[int, Field(ge=0, le=1000000)] | None

    @field_validator("exercise_id")
    @classmethod
    def known_exercise(cls, value):
        if value not in EXERCISE_IDS:
            raise ValueError("动作不在已确认的共享清单中")
        return value

    @model_validator(mode="after")
    def source_matches_estimate(self):
        if (self.record_source == "manual") != (self.estimated_rep_count is None):
            raise ValueError("自动组需要估计值，手动组估计值必须为空")
        return self


class WorkoutInput(StrictInput):
    revision: Revision
    record_kind: Literal["actual"]
    started_at: UtcTime
    ended_at: UtcTime | None
    time_zone: str = Field(min_length=1, max_length=64)
    sets: list[WorkoutSetInput] = Field(min_length=1, max_length=1000)

    @field_validator("time_zone")
    @classmethod
    def known_time_zone(cls, value):
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError, ValueError:
            raise ValueError("必须为有效 IANA 时区") from None
        return value

    @field_validator("sets")
    @classmethod
    def unique_set_ids(cls, value):
        if len({item.set_id for item in value}) != len(value):
            raise ValueError("同一训练的组 ID 不能重复")
        return value

    @model_validator(mode="after")
    def ordered_times(self):
        if self.ended_at is not None and self.ended_at < self.started_at:
            raise ValueError("结束时刻不能早于开始")
        return self


class WriteReceipt(StrictInput):
    workout_id: UUID4
    accepted_revision: Revision
    deleted: bool
