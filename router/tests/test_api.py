from __future__ import annotations

import json
from collections import Counter
from collections.abc import Callable

import pytest
from fastapi.testclient import TestClient

from app.routing import cell_index
from conftest import CELLS, FakeCells, new_session_id

RESPONSES = "/v1/responses"
BODY = {"model": "Qwen/Qwen3-0.6B", "input": "hi", "max_output_tokens": 16}


################################################################################
# Public endpoints: only the Responses API and the model list
################################################################################


@pytest.mark.parametrize(
    ("method", "path"),
    [("POST", "/v1/chat/completions"), ("POST", "/v1/completions"), ("POST", "/v1/messages"), ("GET", "/v1/responses")],
)
def test_other_endpoints_are_not_routed(
    client: TestClient,
    auth_headers: Callable[..., dict[str, str]],
    fake_cells: FakeCells,
    method: str,
    path: str,
) -> None:
    response = client.request(method, path, json=BODY, headers=auth_headers("s-1"))
    assert response.status_code in (404, 405)
    assert fake_cells.requests == []


################################################################################
# 400 when session-id is missing or empty
################################################################################


@pytest.mark.parametrize("session_id", [None, "", "   "])
def test_post_without_session_id_returns_400(
    client: TestClient,
    auth_headers: Callable[..., dict[str, str]],
    fake_cells: FakeCells,
    session_id: str | None,
) -> None:
    response = client.post(RESPONSES, json=BODY, headers=auth_headers(session_id))

    assert response.status_code == 400
    assert response.headers["content-type"].startswith("application/json")
    error = response.json()["error"]
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "missing_session_id"
    assert "session-id" in error["message"]
    assert fake_cells.requests == []


def test_auth_is_checked_before_session_id(client: TestClient) -> None:
    response = client.post(RESPONSES, json=BODY)
    assert response.status_code == 401


def test_models_does_not_require_session_id(
    client: TestClient, auth_headers: Callable[..., dict[str, str]]
) -> None:
    response = client.get("/v1/models", headers=auth_headers())
    assert response.status_code == 200
    assert response.json()["data"][0]["id"] == "Qwen/Qwen3-0.6B"
    assert response.headers["x-served-cell"] == CELLS[0].id


################################################################################
# Session pinning and response headers
################################################################################


def test_response_carries_served_headers(
    client: TestClient, auth_headers: Callable[..., dict[str, str]]
) -> None:
    session_id = "conversation-1"
    response = client.post(RESPONSES, json=BODY, headers=auth_headers(session_id))
    assert response.status_code == 200
    assert response.headers["x-served-region"] == "us-east-1"
    assert response.headers["x-served-cell"] == CELLS[cell_index(session_id, len(CELLS))].id


def test_same_session_is_always_served_by_same_cell(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], fake_cells: FakeCells
) -> None:
    session_id = new_session_id()
    served = {
        client.post(RESPONSES, json=BODY, headers=auth_headers(session_id)).headers["x-served-cell"]
        for _ in range(20)
    }
    assert len(served) == 1
    assert {r.url.host for r in fake_cells.requests} == {f"cell-{served.pop()}.internal"}


def test_different_sessions_same_client_are_spread(
    client: TestClient, auth_headers: Callable[..., dict[str, str]]
) -> None:
    headers = auth_headers()  # one client identity (same token) for every session
    counts = Counter()
    for _ in range(200):
        response = client.post(RESPONSES, json=BODY, headers={**headers, "session-id": new_session_id()})
        counts[response.headers["x-served-cell"]] += 1
    assert set(counts) == {"a", "b"}
    assert min(counts.values()) > 60


def test_request_is_forwarded_unchanged(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], fake_cells: FakeCells
) -> None:
    body = {
        "model": "m",
        "instructions": "Be brief.",
        "input": [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}],
    }
    client.post(RESPONSES + "?debug=1", json=body, headers=auth_headers("s-1"))
    forwarded = fake_cells.requests[0]
    assert forwarded.method == "POST"
    assert forwarded.url.path == RESPONSES
    assert forwarded.url.query == b"debug=1"
    assert forwarded.headers["session-id"] == "s-1"
    assert json.loads(forwarded.content) == body


################################################################################
# Streaming
################################################################################


def test_sse_stream_is_passed_through(
    client: TestClient, auth_headers: Callable[..., dict[str, str]]
) -> None:
    session_id = "stream-session"
    with client.stream("POST", RESPONSES, json={**BODY, "stream": True}, headers=auth_headers(session_id)) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        # The upstream's own x-served-cell header is replaced by the router's.
        assert response.headers["x-served-cell"] == CELLS[cell_index(session_id, len(CELLS))].id
        lines = list(response.iter_lines())

    names = [line.removeprefix("event: ") for line in lines if line.startswith("event: ")]
    data = [line.removeprefix("data: ") for line in lines if line.startswith("data: ")]
    assert names == ["response.created"] + ["response.output_text.delta"] * 3 + ["response.completed"]
    assert data[-1] == "[DONE]"
    assert [json.loads(d)["type"] for d in data[:-1]] == names


def test_non_streaming_response(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    response = client.post(RESPONSES, json=BODY, headers=auth_headers("s-2"))
    assert response.status_code == 200
    payload = response.json()
    assert payload["object"] == "response"
    assert payload["output"][0]["content"][0]["type"] == "output_text"


def test_unreachable_cell_returns_502(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], fake_cells: FakeCells
) -> None:
    fake_cells.fail = True
    response = client.post(RESPONSES, json=BODY, headers=auth_headers("s-3"))
    assert response.status_code == 502
    assert response.json()["error"]["code"] == "cell_unavailable"
    assert response.headers["x-served-cell"] in {"a", "b"}
