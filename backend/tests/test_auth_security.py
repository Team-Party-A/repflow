import asyncio
import threading
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.auth import password_work
from app.errors import install_error_handlers


@pytest.mark.asyncio
async def test_internal_error_is_handled_without_rethrowing_private_details(caplog):
    application = FastAPI()
    install_error_handlers(application)

    @application.get("/failure")
    async def failure():
        raise RuntimeError("a-private-password-or-connection-string")

    async with AsyncClient(
        transport=ASGITransport(app=application), base_url="https://test"
    ) as client:
        response = await client.get("/failure")
    assert response.status_code == 500
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["error"]["code"] == "INTERNAL_ERROR"
    assert "a-private-password-or-connection-string" not in response.text + caplog.text


@pytest.mark.asyncio
async def test_cancelled_password_work_holds_capacity_until_thread_finishes():
    request = SimpleNamespace(
        app=SimpleNamespace(state=SimpleNamespace(password_gate=asyncio.Semaphore(1)))
    )
    first_started, release_first, second_started = (
        threading.Event(),
        threading.Event(),
        threading.Event(),
    )

    def first_work():
        first_started.set()
        assert release_first.wait(3)

    first = asyncio.create_task(password_work(request, first_work))
    while not first_started.is_set():
        await asyncio.sleep(0.001)
    first.cancel()
    second = asyncio.create_task(password_work(request, second_started.set))
    try:
        await asyncio.sleep(0.02)
        assert not second_started.is_set()
    finally:
        release_first.set()
    with pytest.raises(asyncio.CancelledError):
        await first
    await second
    assert second_started.is_set()
