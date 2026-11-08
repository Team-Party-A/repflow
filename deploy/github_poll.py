"""公开 GitHub API 的持久请求预算与按端点缓存。"""

import json
import time
from email.utils import parsedate_to_datetime
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class PollDeferred(Exception):
    def __init__(self, until, reason):
        super().__init__(reason)
        self.until = until


def pause_until(headers, now):
    retry = headers.get("Retry-After")
    until = now
    if retry:
        try:
            until = now + float(retry)
        except ValueError:
            until = parsedate_to_datetime(retry).timestamp()
    if headers.get("X-RateLimit-Remaining") == "0":
        until = max(until, float(headers.get("X-RateLimit-Reset", now + 3600)))
    return until


def get(path, state_file, save):
    now = time.time()
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    calls = [row for row in state.get("calls", []) if row[0] > now - 3600]
    discovery = not path.startswith("jobs/")
    category = "discovery" if discovery else "control"
    limited = [row for row in calls if not discovery or row[1] == category]
    limit = 36 if discovery else 48
    until = max(
        state.get("not_before", 0), state.get("endpoint_after", {}).get(path, 0)
    )
    if len(calls) >= 48:
        until = max(until, calls[0][0] + 3600)
    if len(limited) >= limit:
        until = max(until, limited[0][0] + 3600)
    if now < until:
        raise PollDeferred(until, "GitHub polling is waiting for request budget")
    state["calls"] = calls + [[now, category]]
    state["request_count"] = state.get("request_count", 0) + 1
    cache = state.setdefault("cache", {})
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10",
    }
    if path in cache:
        headers["If-None-Match"] = cache[path]["etag"]
    # 发送前记账，网络失败和重启也不会重置预算。
    save(state_file, json.dumps(state) + "\n")
    request = Request(
        "https://api.github.com/repos/Team-Party-A/repflow/actions/" + path,
        headers=headers,
    )
    try:
        with urlopen(request, timeout=10) as response:
            body = response.read()
            result = json.loads(body)
            response_headers = response.headers
            etag = response_headers.get("ETag")
            cache.pop(path, None)
            if etag:
                cache[path] = {"etag": etag, "body": result}
    except HTTPError as error:
        response_headers = error.headers
        error.close()
        if error.code == 304 and path in cache:
            body = b""
            result = cache[path]["body"]
        elif error.code in (403, 429):
            received_at = time.time()
            state["rate_backoff"] = min(
                3600, max(60, state.get("rate_backoff", 30) * 2)
            )
            state["not_before"] = max(
                received_at + state["rate_backoff"],
                pause_until(response_headers, received_at),
            )
            save(state_file, json.dumps(state) + "\n")
            raise PollDeferred(
                state["not_before"], "GitHub rate limit response"
            ) from None
        else:
            raise
    except (URLError, OSError) as error:
        state["not_before"] = time.time() + 120
        save(state_file, json.dumps(state) + "\n")
        raise PollDeferred(
            state["not_before"], "GitHub network request deferred"
        ) from error
    state["rate_backoff"] = 0
    received_at = time.time()
    state["not_before"] = pause_until(response_headers, received_at)
    pauses = state.setdefault("endpoint_after", {})
    pauses.pop(path, None)
    if response_headers.get("X-Poll-Interval"):
        pauses[path] = received_at + float(response_headers["X-Poll-Interval"])
    state["endpoint_after"] = dict(list(pauses.items())[-4:])
    # 只保留最近四个端点，避免每个历史发布留下完整 job 列表。
    state["cache"] = dict(list(cache.items())[-4:])
    state["response_bytes"] = state.get("response_bytes", 0) + len(body)
    state["responses"] = state.get("responses", 0) + 1
    state["not_modified"] = state.get("not_modified", 0) + (len(body) == 0)
    state["remaining"] = response_headers.get("X-RateLimit-Remaining")
    save(state_file, json.dumps(state) + "\n")
    return result
