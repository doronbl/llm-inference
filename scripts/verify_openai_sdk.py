"""Definition of Done 7: the official OpenAI Python SDK works against the API
(Responses API: client.responses.create, non-streaming and streaming) with
only base_url, api_key (= Cognito access token) and a session-id header in
default_headers.

Usage:
    pip install openai==3.46.0
    API_URL=https://<api_hostname>/v1 ACCESS_TOKEN=<token> python3 scripts/verify_openai_sdk.py
"""

from __future__ import annotations

import os
import sys
import uuid

from openai import OpenAI


def main() -> int:
    session_id = f"sdk-{uuid.uuid4()}"
    client = OpenAI(
        base_url=os.environ["API_URL"],
        api_key=os.environ["ACCESS_TOKEN"],
        default_headers={"session-id": session_id},
    )

    model = client.models.list().data[0].id
    print(f"model: {model}")

    raw = client.responses.with_raw_response.create(
        model=model,
        instructions="Answer briefly.",
        input="Say hello.",
        max_output_tokens=16,
    )
    response = raw.parse()
    print(f"non-streaming ({response.status}): {response.output_text!r}")
    print(f"  x-served-region={raw.headers.get('x-served-region')} x-served-cell={raw.headers.get('x-served-cell')}")

    # The API is stateless: send the conversation so far as the input.
    history = [
        {"role": "user", "content": "Say hello."},
        {"role": "assistant", "content": response.output_text},
        {"role": "user", "content": "Count to five."},
    ]
    text, event_types = [], []
    for event in client.responses.create(model=model, input=history, max_output_tokens=16, stream=True):
        event_types.append(event.type)
        if event.type == "response.output_text.delta":
            text.append(event.delta)
    print(f"streaming: {''.join(text)!r} ({event_types[0]} ... {event_types[-1]}, {len(event_types)} events)")

    if not response.output_text or not text:
        print("FAIL: empty response", file=sys.stderr)
        return 1
    if event_types[-1] not in ("response.completed", "response.incomplete"):
        print(f"FAIL: stream ended with {event_types[-1]}", file=sys.stderr)
        return 1
    print("OK: OpenAI SDK works with base_url, api_key and default_headers only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
