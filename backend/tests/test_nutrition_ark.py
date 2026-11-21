"""Model-provider protocol, error handling and nutritional validation, with no API key or network."""

import json
from unittest.mock import Mock

import pytest

from app.nutrition_ark import ArkProvider, ProviderFailure, account_cost


def wire_reply(message, *, finish="stop", usage=None):
    return json.dumps(
        {
            "choices": [{"finish_reason": finish, "message": {"content": message}}],
            "usage": usage,
        }
    ).encode()


@pytest.fixture
def ark(monkeypatch):
    connection = Mock()
    transport = Mock(return_value=connection)
    monkeypatch.setattr("app.nutrition_ark.http.client.HTTPSConnection", transport)
    monkeypatch.setenv("ARK_API_KEY", "fixture-only")
    monkeypatch.setenv("ARK_VISION_MODEL", "fixture-vision")
    monkeypatch.setenv("ARK_TEXT_MODEL", "fixture-text")
    connection.getresponse.return_value.status = 200
    return ArkProvider(), connection, transport


@pytest.mark.asyncio
async def test_vision_wire_uses_inline_image_and_reports_only_valid_usage(ark):
    provider, connection, transport = ark
    message = {
        "items": [
            {
                "name": "熟豆",
                "preparation": "熟",
                "grams": None,
                "needs_review": True,
                "generic": True,
            }
        ]
    }
    connection.getresponse.return_value.read.return_value = wire_reply(
        "```json\n" + json.dumps(message) + "\n```",
        usage={"prompt_tokens": 21, "completion_tokens": False},
    )
    assert provider.available
    foods, usage = await provider.recognize(b"jpeg")
    assert foods[0].name == "熟豆" and foods[0].grams is None
    assert usage == {"prompt_tokens": 21, "completion_tokens": None}
    transport.assert_called_once_with("ark.cn-beijing.volces.com", timeout=38)
    args, kwargs = connection.request.call_args
    assert args == ("POST", "/api/v3/chat/completions")
    assert kwargs["headers"]["Authorization"] == "Bearer fixture-only"
    payload = json.loads(kwargs["body"])
    assert payload["model"] == "fixture-vision"
    assert "thinking" not in payload
    assert (
        payload["messages"][1]["content"][0]["image_url"]["url"]
        == "data:image/jpeg;base64,anBlZw=="
    )
    connection.close.assert_called_once()


@pytest.mark.asyncio
async def test_seed_pro_draft_omits_deep_thinking_and_prices_cached_input(
    ark, monkeypatch
):
    provider, connection, _ = ark
    provider.vision = provider.text = "doubao-seed-2-1-pro-260915"
    connection.getresponse.return_value.read.return_value = wire_reply(
        '{"items": []}',
        usage={
            "prompt_tokens": 100,
            "completion_tokens": 10,
            "prompt_tokens_details": {"cached_tokens": 40},
        },
    )
    _, vision_usage = await provider.recognize(b"jpeg")
    _, text_usage = await provider.profiles([("米饭", "熟")])
    assert all(
        json.loads(call.kwargs["body"])["thinking"] == {"type": "disabled"}
        for call in connection.request.call_args_list
    )
    metrics = {
        "vision_calls": 1,
        "vision_usage": vision_usage,
        "text_calls": 1,
        "text_usage": text_usage,
    }
    for phase in ("VISION", "TEXT"):
        monkeypatch.setenv(f"ARK_{phase}_INPUT_CNY_PER_MTOK", "6")
        monkeypatch.setenv(f"ARK_{phase}_OUTPUT_CNY_PER_MTOK", "30")
        monkeypatch.delenv(f"ARK_{phase}_CACHED_INPUT_CNY_PER_MTOK", raising=False)
    assert account_cost(metrics)["cost_cny"] is None
    for phase in ("VISION", "TEXT"):
        monkeypatch.setenv(f"ARK_{phase}_CACHED_INPUT_CNY_PER_MTOK", "1.2")
    assert account_cost(metrics)["cost_cny"] == "0.001416"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("failure", "code"),
    [
        ("timeout", "provider_unavailable"),
        ("http", "provider_unavailable"),
        ("size", "invalid_result"),
        ("envelope", "invalid_result"),
        ("object", "invalid_result"),
        ("schema", "invalid_result"),
        ("truncated", "invalid_result"),
    ],
)
async def test_invalid_provider_responses_produce_a_manual_fallback(ark, failure, code):
    provider, connection, _ = ark
    response = connection.getresponse.return_value
    if failure == "timeout":
        connection.getresponse.side_effect = TimeoutError("fixture timeout")
    elif failure == "http":
        response.status = 429
    else:
        response.read.return_value = {
            "size": b"x" * (512 * 1024 + 1),
            "envelope": b"invalid",
            "object": wire_reply("[]"),
            "schema": wire_reply('{"items": [1]}'),
            "truncated": wire_reply('{"items": []}', finish="length"),
        }[failure]
    with pytest.raises(ProviderFailure) as exc:
        await provider.recognize(b"jpeg")
    assert exc.value.code == code
    connection.close.assert_called_once()


@pytest.mark.asyncio
async def test_profile_rows_keep_uncertain_nutrients_and_discard_ambiguous_indices(ark):
    provider, connection, _ = ark
    foods = [(f"测试食物{index}", "熟") for index in range(8)]
    profile = {"carbs_g": 10, "protein_g": None, "fat_g": 0, "energy_kcal": None}
    rows = [
        {"index": 0, "per_100g": profile},
        {"index": 0, "per_100g": profile},
        {"index": 1, "per_100g": profile},
        {"index": True, "per_100g": profile},
        "invalid",
        {"index": 100, "per_100g": profile},
        {"index": 6, "per_100g": dict.fromkeys(profile)},
        {"index": 7, "per_100g": profile | {"fat_g": 99}},
    ]
    connection.getresponse.return_value.read.return_value = wire_reply(
        json.dumps({"items": rows})
    )
    result, _ = await provider.profiles(foods)
    assert list(result) == [foods[1]]
    assert result[foods[1]].model_dump() == profile
    payload = json.loads(connection.request.call_args.kwargs["body"])
    assert payload["model"] == "fixture-text"
    sent = json.loads(payload["messages"][1]["content"])
    assert sent == [
        {"index": i, "name": name, "preparation": prep}
        for i, (name, prep) in enumerate(foods)
    ]
    connection.getresponse.return_value.read.return_value = wire_reply(
        '{"items": [1, 2]}'
    )
    with pytest.raises(ProviderFailure, match="invalid_result"):
        await provider.profiles(foods[:1])


@pytest.mark.parametrize("rate", ["NaN", "unpriced", "-1"])
def test_invalid_model_price_stays_unknown(monkeypatch, rate):
    monkeypatch.setenv("ARK_VISION_INPUT_CNY_PER_MTOK", rate)
    assert (
        account_cost({"vision_calls": 1, "vision_usage": {"prompt_tokens": 7}})[
            "cost_cny"
        ]
        is None
    )
