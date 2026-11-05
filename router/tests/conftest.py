from __future__ import annotations

import json
import time
import uuid
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from typing import Any

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from app.config import Cell, Settings
from app.main import create_app

ISSUER = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_TEST"
JWKS_URL = f"{ISSUER}/.well-known/jwks.json"
SCOPE = "llm-api/invoke"
KID = "test-key-1"

CELLS = (
    Cell(id="a", url="http://cell-a.internal:8000"),
    Cell(id="b", url="http://cell-b.internal:8000"),
)


@pytest.fixture(scope="session")
def rsa_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="session")
def other_rsa_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="session")
def jwks(rsa_key: rsa.RSAPrivateKey) -> dict[str, Any]:
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(rsa_key.public_key()))
    jwk.update({"kid": KID, "alg": "RS256", "use": "sig"})
    return {"keys": [jwk]}


@pytest.fixture
def make_token(rsa_key: rsa.RSAPrivateKey) -> Callable[..., str]:
    def _make(
        *,
        key: rsa.RSAPrivateKey | None = None,
        kid: str = KID,
        issuer: str = ISSUER,
        scope: str = SCOPE,
        token_use: str = "access",
        expires_in: int = 3600,
        algorithm: str = "RS256",
        secret: str | None = None,
    ) -> str:
        now = int(time.time())
        claims = {
            "sub": "client-123",
            "client_id": "client-123",
            "iss": issuer,
            "token_use": token_use,
            "scope": scope,
            "iat": now,
            "exp": now + expires_in,
        }
        signing_key: Any = secret if secret is not None else (key or rsa_key)
        return jwt.encode(claims, signing_key, algorithm=algorithm, headers={"kid": kid})

    return _make


def _json_response(payload: dict[str, Any]) -> httpx.Response:
    # An unread byte stream, like a real network response.
    body = json.dumps(payload).encode()
    return httpx.Response(
        200,
        headers={"content-type": "application/json", "content-length": str(len(body))},
        stream=httpx.ByteStream(body),
    )


@dataclass
class FakeCells:
    """Records proxied requests and answers like a Dynamo frontend."""

    requests: list[httpx.Request] = field(default_factory=list)
    fail: bool = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.fail:
            raise httpx.ConnectError("connection refused", request=request)

        cell = request.url.host.split(".")[0]  # "cell-a" / "cell-b"
        if request.url.path == "/v1/models":
            return _json_response({"object": "list", "data": [{"id": "Qwen/Qwen3-0.6B", "object": "model"}]})

        body = json.loads(request.content or b"{}")
        if body.get("stream"):
            chunks = [
                {"id": "c1", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": word}}]}
                for word in ("Hello", " from", f" {cell}")
            ]
            payload = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
            return httpx.Response(
                200,
                headers={"content-type": "text/event-stream", "x-served-cell": "spoofed"},
                stream=httpx.ByteStream(payload.encode()),
            )
        return _json_response(
            {
                "id": "c1",
                "object": "chat.completion",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": f"Hello from {cell}"}}],
            }
        )


class FakeJWKClient(jwt.PyJWKClient):
    """PyJWKClient that serves a fixed JWKS instead of calling the network."""

    def __init__(self, jwks: dict[str, Any]) -> None:
        super().__init__(JWKS_URL, cache_keys=True, lifespan=300)
        self.jwks = jwks
        self.fetches = 0
        self.down = False

    def fetch_data(self) -> Any:
        self.fetches += 1
        if self.down:
            raise jwt.PyJWKClientConnectionError("JWKS endpoint unreachable")
        return self.jwks


@pytest.fixture
def settings() -> Settings:
    return Settings(
        region="us-east-1",
        cells=CELLS,
        issuer=ISSUER,
        jwks_url=JWKS_URL,
        required_scope=SCOPE,
    )


@pytest.fixture
def fake_cells() -> FakeCells:
    return FakeCells()


@pytest.fixture
def jwk_client(jwks: dict[str, Any]) -> FakeJWKClient:
    return FakeJWKClient(jwks)


@pytest.fixture
def client(settings: Settings, fake_cells: FakeCells, jwk_client: FakeJWKClient) -> Iterator[TestClient]:
    app = create_app(
        settings,
        upstream_transport=httpx.MockTransport(fake_cells.handler),
        jwks=jwk_client,
    )
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def auth_headers(make_token: Callable[..., str]) -> Callable[..., dict[str, str]]:
    def _headers(session_id: str | None = None, **token_kwargs: Any) -> dict[str, str]:
        headers = {"authorization": f"Bearer {make_token(**token_kwargs)}"}
        if session_id is not None:
            headers["session-id"] = session_id
        return headers

    return _headers


def new_session_id() -> str:
    return str(uuid.uuid4())
