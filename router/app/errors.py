"""OpenAI-format error responses."""

from __future__ import annotations

from collections.abc import Mapping

from fastapi.responses import JSONResponse


def openai_error(
    status_code: int,
    message: str,
    *,
    error_type: str,
    code: str,
    headers: Mapping[str, str] | None = None,
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"error": {"message": message, "type": error_type, "param": None, "code": code}},
        headers=dict(headers or {}),
    )
