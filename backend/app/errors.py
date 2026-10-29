import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import OperationalError, SQLAlchemyError
from sqlalchemy.exc import TimeoutError as DatabaseTimeout
from starlette.exceptions import HTTPException

logger = logging.getLogger(__name__)


class APIError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status, self.code, self.message = status, code, message


def error_response(status: int, code: str, message: str, fields=None) -> JSONResponse:
    headers = {"Cache-Control": "no-store"}
    if status == 401:
        headers["WWW-Authenticate"] = "Bearer"
    return JSONResponse(
        {"error": {"code": code, "message": message, "fields": fields or []}},
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
        return error_response(error.status, error.code, error.message)

    @application.exception_handler(RequestValidationError)
    async def invalid_request(request: Request, error: RequestValidationError):
        if any(item["type"] == "json_invalid" for item in error.errors()):
            return error_response(400, "INVALID_REQUEST", "请求格式错误")
        # 校验库的 msg/input/ctx 可能包含密码或请求值，仅暴露已知字段名。
        fields = [
            {"path": "/" + item["loc"][1], "message": "字段不符合接口要求"}
            for item in error.errors()
            if len(item["loc"]) == 2
            and item["loc"][0] == "body"
            and item["loc"][1] in {"username", "password"}
        ]
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
