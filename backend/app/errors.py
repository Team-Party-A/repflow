import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import OperationalError, SQLAlchemyError
from sqlalchemy.exc import TimeoutError as DatabaseTimeout
from starlette.exceptions import HTTPException

logger = logging.getLogger(__name__)


class APIError(Exception):
    def __init__(self, status: int, code: str, message: str, *, current_revision=None):
        self.status, self.code, self.message = status, code, message
        self.current_revision = current_revision


def error_response(
    status: int, code: str, message: str, fields=None, current_revision=None
) -> JSONResponse:
    headers = {"Cache-Control": "no-store"}
    if status == 401:
        headers["WWW-Authenticate"] = "Bearer"
    error = {"code": code, "message": message, "fields": fields or []}
    if code == "REVISION_CONFLICT" and current_revision is not None:
        error["current_revision"] = current_revision
    return JSONResponse(
        {"error": error},
        status_code=status,
        headers=headers,
    )


def install_error_handlers(application: FastAPI) -> None:
    @application.middleware("http")
    async def disable_caching(request: Request, call_next):
        try:
            response = await call_next(request)
        except Exception as error:
            # 在进入 Uvicorn 的异常日志前处理，避免其回显异常中的敏感信息。
            response = await server_error(request, error)
        response.headers["Cache-Control"] = "no-store"
        return response

    @application.exception_handler(APIError)
    async def api_error(request: Request, error: APIError):
        return error_response(
            error.status,
            error.code,
            error.message,
            current_revision=error.current_revision,
        )

    @application.exception_handler(RequestValidationError)
    async def invalid_request(request: Request, error: RequestValidationError):
        if any(item["type"] == "json_invalid" for item in error.errors()):
            return error_response(400, "INVALID_REQUEST", "请求格式错误")
        # loc 中的额外键也可能是敏感输入，只允许已知字段和数组下标进入路径。
        known = {
            "username",
            "password",
            "revision",
            "record_kind",
            "started_at",
            "ended_at",
            "time_zone",
            "sets",
            "set_id",
            "exercise_id",
            "final_rep_count",
            "estimated_rep_count",
            "record_source",
            "weight_grams",
        }
        fields = []
        for item in error.errors():
            location = item["loc"]
            if location[0] != "body":
                path = ""
            elif all(type(part) is int or part in known for part in location[1:]):
                path = (
                    "/" + "/".join(str(part) for part in location[1:])
                    if len(location) > 1
                    else ""
                )
            else:
                continue
            fields.append({"path": path, "message": "字段不符合接口要求"})
        return error_response(422, "VALIDATION_ERROR", "请求字段不合法", fields)

    @application.exception_handler(HTTPException)
    async def http_error(request: Request, error: HTTPException):
        if error.status_code == 404:
            return error_response(404, "NOT_FOUND", "接口不存在")
        return error_response(
            error.status_code, "INVALID_REQUEST", "请求格式或方式错误"
        )

    async def server_error(request: Request, error: Exception):
        logger.warning("request failed: kind=%s", type(error).__name__)
        if isinstance(error, (OperationalError, DatabaseTimeout)):
            return error_response(
                503, "SERVICE_UNAVAILABLE", "服务暂不可用，请稍后重试"
            )
        return error_response(500, "INTERNAL_ERROR", "服务暂时无法完成请求，请稍后重试")

    application.add_exception_handler(SQLAlchemyError, server_error)
    application.add_exception_handler(Exception, server_error)
