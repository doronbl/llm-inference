from __future__ import annotations

import json
from collections import Counter
from collections.abc import Callable

import pytest
from fastapi.testclient import TestClient

from app.routing import cell_index
from conftest import CELLS, FakeCells, new_session_id

CHAT = "/v1/chat/completions"
COMPLETIONS = "/v1/completions"
BODY = {"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "hi"}]}


################################################################################
# 400 when session-id is missing or empty
################################################################################


@pytest.mark.parametrize("path", [CHAT, COMPLETIONS])
@pytest.mark.parametrize("session_id", [None, "", "   "])
def test_post_without_session_id_returns_400(
    client: TestClient,
    auth_headers: Callable[..., dict[str, str]],
    fake_cells: FakeCells,
    path: str,
    session_id: str | None,
) -> None:
    response = client.post(path, json=BODY, headers=auth_headers(session_id))

    assert response.status_code == 400
    assert response.headers["content-type"].startswith("application/json")
    error = response.json()["error"]
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "missing_session_id"
    assert "session-id" in error["message"]
    assert fake_cells.requests == []


def test_auth_is_checked_before_session_id(client: TestClient) -> None:
    response = client.post(CHAT, json=BODY)
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
    response = client.post(CHAT, json=BODY, headers=auth_headers(session_id))
    assert response.status_code == 200
    assert response.headers["x-served-region"] == "us-east-1"
    assert response.headers["x-served-cell"] == CELLS[cell_index(session_id, len(CELLS))].id


def test_same_session_is_always_served_by_same_cell(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], fake_cells: FakeCells
) -> None:
    session_id = new_session_id()
    served = {client.post(CHAT, json=BODY, headers=auth_headers(session_id)).headers["x-served-cell"] for _ in range(20)}
    assert len(served) == 1
    assert {r.url.host for r in fake_cells.requests} == {f"cell-{served.pop()}.internal"}


def test_different_sessions_same_client_are_spread(
    client: TestClient, auth_headers: Callable[..., dict[str, str]]
) -> None:
    headers = auth_headers()  # one client identity (same token) for every session
    counts = Counter()
    for _ in range(200):
        response = client.post(CHAT, json=BODY, headers={**headers, "session-id": new_session_id()})
        counts[response.headers["x-served-cell"]] += 1
    assert set(counts) == {"a", "b"}
    assert min(counts.values()) > 60


def test_request_is_forwarded_unchanged(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], fake_cells: FakeCells
) -> None:
    client.post(COMPLETIONS + "?debug=1", json={"model": "m", "prompt": "hi"}, headers=auth_headers("s-1"))
    forwarded = fake_cells.requests[0]
    assert forwarded.method == "POST"
    assert forwarded.url.path == COMPLETIONS
    assert forwarded.url.query == b"debug=1"
    assert forwarded.headers["session-id"] == "s-1"
    assert json.loads(forwarded.content) == {"model": "m", "prompt": "hi"}


################################################################################
# Streaming
################################################################################


def test_sse_stream_is_passed_through(
    client: TestClient, auth_headers: Callable[..., dict[str, str]]
) -> None:
    session_id = "stream-session"
    with client.stream("POST", CHAT, json={**BODY, "stream": True}, headers=auth_headers(session_id)) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        # The upstream's own x-served-cell header is replaced by the router's.
        assert response.headers["x-served-cell"] == CELLS[cell_index(session_id, len(CELLS))].id
        events = [line for line in response.iter_lines() if line.startswith("data: ")]

    assert events[-1] == "data: [DONE]"
    chunks = [json.loads(e.removeprefix("data: ")) for e in events[:-1]]
    assert all(c["object"] == "chat.completion.chunk" for c in chunks)
    assert len(chunks) == 3


def test_non_streaming_response(client: TestClient, auth_headers: Callable[..., dict[str, str]]) -> None:
    response = client.post(CHAT, json=BODY, headers=auth_headers("s-2"))
    assert response.status_code == 200
    assert response.json()["object"] == "chat.completion"


def test_unreachable_cell_returns_502(
    client: TestClient, auth_headers: Callable[..., dict[str, str]], fake_cells: FakeCells
) -> None:
    fake_cells.fail = True
    response = client.post(CHAT, json=BODY, headers=auth_headers("s-3"))
    assert response.status_code == 502
    assert response.json()["error"]["code"] == "cell_unavailable"
    assert response.headers["x-served-cell"] in {"a", "b"}
