"""Regional router (tier 2).

Public endpoints: POST /v1/responses (OpenAI Responses API) and GET /v1/models.

For every request:
  1. verify the Cognito access token,
  2. on POST, require a non-empty session-id header,
  3. pick the cell with sha256(session-id) mod N_cells,
  4. proxy to the cell's Dynamo frontend, streaming the response body through
     unchanged (SSE chunks are forwarded as they arrive),
  5. add x-served-region and x-served-cell response headers.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import httpx
import jwt
from fastapi import FastAPI, Request
from fastapi.responses import Response, StreamingResponse

from .auth import AuthError, KeysUnavailable, TokenVerifier, jwk_client
from .config import Cell, Settings, load_settings
from .errors import openai_error
from .routing import select_cell

logger = logging.getLogger("router")

SESSION_HEADER = "session-id"

# Hop-by-hop headers (RFC 9110 §7.6.1) plus headers the proxy sets itself.
_HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)
_DROP_REQUEST = _HOP_BY_HOP | {"host", "content-length", "authorization"}
_DROP_RESPONSE = _HOP_BY_HOP | {"x-served-region", "x-served-cell"}


def create_app(
    settings: Settings | None = None,
    *,
    upstream_transport: httpx.AsyncBaseTransport | None = None,
    jwks: jwt.PyJWKClient | None = None,
) -> FastAPI:
    """Build the app. The upstream transport and JWKS client are injectable for tests."""

    settings = settings or load_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        upstream = httpx.AsyncClient(
            transport=upstream_transport,
            timeout=httpx.Timeout(
                connect=settings.upstream_connect_timeout_seconds,
                read=None,  # streams may pause between tokens
                write=settings.upstream_write_timeout_seconds,
                pool=settings.upstream_connect_timeout_seconds,
            ),
            limits=httpx.Limits(
                max_connections=settings.max_upstream_connections,
                max_keepalive_connections=settings.max_upstream_connections,
            ),
            follow_redirects=False,
        )
        app.state.upstream = upstream
        app.state.verifier = TokenVerifier(
            issuer=settings.issuer,
            required_scope=settings.required_scope,
            jwks=jwks or jwk_client(settings.jwks_url, lifespan_seconds=settings.jwks_cache_seconds),
        )
        try:
            yield
        finally:
            await upstream.aclose()

    app = FastAPI(title="llm-inference regional router", lifespan=lifespan, docs_url=None, redoc_url=None)

    def served_headers(cell: Cell) -> dict[str, str]:
        return {"x-served-region": settings.region, "x-served-cell": cell.id}

    async def handle(request: Request, *, require_session: bool) -> Response:
        try:
            await request.app.state.verifier.verify(request.headers.get("authorization"))
        except AuthError as exc:
            return openai_error(
                401,
                f"Invalid or missing access token: {exc}",
                error_type="invalid_request_error",
                code="invalid_api_key",
                headers={"www-authenticate": "Bearer"},
            )
        except KeysUnavailable:
            return openai_error(
                503,
                "Token verification is temporarily unavailable.",
                error_type="server_error",
                code="auth_unavailable",
            )

        session_id = request.headers.get(SESSION_HEADER, "").strip()
        if require_session and not session_id:
            return openai_error(
                400,
                "The 'session-id' header is required and must not be empty.",
                error_type="invalid_request_error",
                code="missing_session_id",
            )

        # GET /v1/models may omit session-id; it is then served by the first cell.
        cell = select_cell(session_id, settings.cells) if session_id else settings.cells[0]
        return await proxy(request, cell, served_headers(cell))

    async def proxy(request: Request, cell: Cell, extra_headers: dict[str, str]) -> Response:
        upstream: httpx.AsyncClient = request.app.state.upstream
        url = f"{cell.url}{request.url.path}"
        if request.url.query:
            url = f"{url}?{request.url.query}"

        headers = [(k, v) for k, v in request.headers.items() if k.lower() not in _DROP_REQUEST]
        upstream_request = upstream.build_request(
            request.method, url, headers=headers, content=await request.body()
        )
        try:
            upstream_response = await upstream.send(upstream_request, stream=True)
        except httpx.HTTPError as exc:
            logger.warning("cell %s unreachable: %s", cell.id, exc)
            return openai_error(
                502,
                f"Cell '{cell.id}' is unavailable.",
                error_type="server_error",
                code="cell_unavailable",
                headers=extra_headers,
            )

        response_headers = {
            k: v for k, v in upstream_response.headers.items() if k.lower() not in _DROP_RESPONSE
        }
        response_headers.update(extra_headers)

        async def body() -> AsyncIterator[bytes]:
            # Raw bytes are forwarded as soon as they arrive (no re-chunking or
            # decoding), so SSE events reach the client without buffering.
            try:
                async for chunk in upstream_response.aiter_raw():
                    yield chunk
            finally:
                await upstream_response.aclose()

        return StreamingResponse(
            body(),
            status_code=upstream_response.status_code,
            headers=response_headers,
        )

    @app.get("/healthz", include_in_schema=False)
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    # The public API is the OpenAI Responses API plus the model list. Other
    # paths the Dynamo frontend serves are not routed and return 404 here.
    @app.post("/v1/responses")
    async def responses(request: Request) -> Response:
        return await handle(request, require_session=True)

    @app.get("/v1/models")
    async def models(request: Request) -> Response:
        return await handle(request, require_session=False)

    return app


def app_factory() -> FastAPI:
    """Entry point for `uvicorn --factory app.main:app_factory`."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    return create_app()
