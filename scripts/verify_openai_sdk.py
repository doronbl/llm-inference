"""Definition of Done 7: the official OpenAI Python SDK works against the API
with only base_url, api_key (= Cognito access token) and a session-id header
in default_headers.

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

    raw = client.chat.completions.with_raw_response.create(
        model=model,
        messages=[{"role": "user", "content": "Say hello."}],
        max_tokens=16,
    )
    completion = raw.parse()
    print(f"non-streaming: {completion.choices[0].message.content!r}")
    print(f"  x-served-region={raw.headers.get('x-served-region')} x-served-cell={raw.headers.get('x-served-cell')}")

    text = []
    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": "Count to five."}],
        max_tokens=16,
        stream=True,
    )
    for chunk in stream:
        if chunk.choices and chunk.choices[0].delta.content:
            text.append(chunk.choices[0].delta.content)
    print(f"streaming: {''.join(text)!r}")

    legacy = client.completions.create(model=model, prompt="Hello", max_tokens=8)
    print(f"completions: {legacy.choices[0].text!r}")

    if not completion.choices or not text:
        print("FAIL: empty response", file=sys.stderr)
        return 1
    print("OK: OpenAI SDK works with base_url, api_key and default_headers only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
