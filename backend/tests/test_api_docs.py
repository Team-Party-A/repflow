import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from app.main import create_app


@pytest_asyncio.fixture
async def docs_client():
    async with AsyncClient(
        transport=ASGITransport(app=create_app()), base_url="https://test"
    ) as client:
        yield client


@pytest.mark.asyncio
async def test_api_docs_has_same_origin_assets_and_disables_try_it_out(docs_client):
    client = docs_client
    page = await client.get("/docs")
    assert page.status_code == 200
    assert page.headers["content-type"].startswith("text/html")
    assert page.headers["x-content-type-options"] == "nosniff"
    assert "script-src 'self'" in page.headers["content-security-policy"]
    assert 'src="/docs/swagger-ui-bundle.js"' in page.text
    assert 'href="/docs/swagger-ui.css"' in page.text
    assert 'src="/docs/init.js"' in page.text

    settings = await client.get("/docs/init.js")
    assert settings.status_code == 200
    assert 'url: "/docs/openapi.yaml"' in settings.text
    assert "supportedSubmitMethods: []" in settings.text
    assert "validatorUrl: null" in settings.text
    assert "queryConfigEnabled: false" in settings.text


@pytest.mark.asyncio
async def test_docs_routes_accept_only_reads_and_known_paths(docs_client):
    client = docs_client
    for path in (
        "/docs",
        "/docs/init.js",
        "/docs/openapi.yaml",
        "/docs/nutrition.yaml",
    ):
        head = await client.head(path)
        assert head.status_code == 200
        assert head.content == b""
        assert (await client.post(path)).status_code == 405
    for path in ("/openapi.json", "/redoc", "/docs/README.md", "/docs/env/config"):
        assert (await client.get(path)).status_code == 404
