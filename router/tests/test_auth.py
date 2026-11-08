from __future__ import annotations

from collections.abc import Callable

import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from conftest import FakeCells, FakeJWKClient

RESPONSES = "/v1/responses"
BODY = {"model": "Qwen/Qwen3-0.6B", "input": "hi", "max_output_tokens": 16}


def assert_unauthorized(response) -> None:
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    error = response.json()["error"]
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_api_key"


def test_valid_token_is_accepted(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    response = client.post(RESPONSES, json=BODY, headers=auth_headers("s1"))
    assert response.status_code == 200


def test_missing_authorization_header(client: TestClient, fake_cells: FakeCells) -> None:
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers={"session-id": "s1"}))
    assert fake_cells.requests == []


@pytest.mark.parametrize("value", ["Basic dXNlcjpwYXNz", "Bearer", "Bearer   ", "token-without-scheme", "Bearer not-a-jwt"])
def test_malformed_authorization_header(client: TestClient, value: str) -> None:
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers={"authorization": value, "session-id": "s1"}))


def test_expired_token(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers=auth_headers("s1", expires_in=-60)))


def test_wrong_issuer(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    headers = auth_headers("s1", issuer="https://cognito-idp.us-east-1.amazonaws.com/us-east-1_OTHER")
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers=headers))


def test_missing_scope(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers=auth_headers("s1", scope="other/scope")))


def test_id_token_rejected(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers=auth_headers("s1", token_use="id")))


def test_signature_from_other_key_rejected(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], other_rsa_key: rsa.RSAPrivateKey
) -> None:
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers=auth_headers("s1", key=other_rsa_key)))


def test_unknown_kid_rejected(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers=auth_headers("s1", kid="unknown")))


def test_symmetric_algorithm_rejected(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    headers = auth_headers("s1", algorithm="HS256", secret="x" * 32)
    assert_unauthorized(client.post(RESPONSES, json=BODY, headers=headers))


def test_models_endpoint_requires_token(client: TestClient) -> None:
    assert_unauthorized(client.get("/v1/models"))


def test_token_is_not_forwarded_to_cells(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], fake_cells: FakeCells
) -> None:
    client.post(RESPONSES, json=BODY, headers=auth_headers("s1"))
    assert "authorization" not in fake_cells.requests[0].headers


def test_signing_keys_are_cached(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], jwk_client: FakeJWKClient
) -> None:
    for i in range(5):
        assert client.post(RESPONSES, json=BODY, headers=auth_headers(f"s{i}")).status_code == 200
    assert jwk_client.fetches == 1


def test_unreachable_jwks_returns_503(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], jwk_client: FakeJWKClient, fake_cells: FakeCells
) -> None:
    jwk_client.down = True
    response = client.post(RESPONSES, json=BODY, headers=auth_headers("s1"))
    assert response.status_code == 503
    error = response.json()["error"]
    assert error["type"] == "server_error"
    assert error["code"] == "auth_unavailable"
    assert fake_cells.requests == []


def test_healthz_needs_no_token(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
