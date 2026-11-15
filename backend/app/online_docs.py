from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

router = APIRouter(include_in_schema=False)
DOCS = Path(__file__).with_name("api_docs")
REPO_CONTRACT = Path(__file__).resolve().parents[2] / "docs/api/openapi.yaml"


@router.api_route("/docs", methods=["GET", "HEAD"])
async def documentation() -> FileResponse:
    return FileResponse(
        DOCS / "index.html",
        media_type="text/html",
        headers={
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": (
                "default-src 'none'; script-src 'self'; "
                "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"
            ),
        },
    )


@router.api_route("/docs/{name}", methods=["GET", "HEAD"])
async def docs_asset(name: str) -> FileResponse:
    types = {
        "openapi.yaml": "application/yaml",
        "init.js": "text/javascript",
        "swagger-ui-bundle.js": "text/javascript",
        "swagger-ui.css": "text/css",
        "licenses.txt": "text/plain",
    }
    media_type = types.get(name)
    if media_type is None:
        raise HTTPException(404)
    file = DOCS / name
    if name == "openapi.yaml" and REPO_CONTRACT.is_file():
        # 在源码运行时直接使用原文件，镜像使用构建时复制的同一份契约。
        file = REPO_CONTRACT
    return FileResponse(
        file, media_type=media_type, headers={"X-Content-Type-Options": "nosniff"}
    )
