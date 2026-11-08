"""Send one or more Responses API requests and print the answer with its metadata.

    scripts/infer.py "Hello"                          # streaming, one request
    scripts/infer.py --no-stream "Hello"
    scripts/infer.py --repeat 3 --input-file prompt.txt  # repeats show KV-cache hits
    scripts/infer.py --json "Hello"                   # one JSON report per request

Connection settings come from API and TOKEN in the environment
(eval "$(scripts/api-env.sh)"). If they are not set, the script runs
scripts/api-env.sh itself, which needs the Terraform state of this checkout.

What is printed, and where it comes from:
  text             response.output_text deltas (streaming) or output[].content
  status           response.status and incomplete_details.reason
  cell, region     x-served-cell / x-served-region headers, added by the router
  tokens           usage: input, cached (KV-cache hit), output, total
  client timing    measured here: TTFT (first output_text.delta), total, TPOT
  server timing    Dynamo nvext.timing: TTFT, prefill, total, kv_hit_rate,
                   router queue depth (requested with nvext.extra_fields)
  worker           Dynamo nvext.worker_id: prefill and decode worker

To add a field, add it to build_report(); the text and JSON output both use it.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

import httpx

SCRIPTS_DIR = Path(__file__).resolve().parent
NVEXT_FIELDS = ["worker_id", "timing"]


def connection() -> tuple[str, str, str | None]:
    """API base URL, access token and model (from the env or scripts/api-env.sh)."""
    if not (os.environ.get("API") and os.environ.get("TOKEN")):
        out = subprocess.run([str(SCRIPTS_DIR / "api-env.sh")], check=True, capture_output=True, text=True).stdout
        for line in out.splitlines():
            key, _, value = line.removeprefix("export ").partition("=")
            os.environ[key] = shlex.split(value)[0] if value else ""
    return os.environ["API"].rstrip("/"), os.environ["TOKEN"], os.environ.get("MODEL")


def request_body(args: argparse.Namespace, model: str) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": model,
        "input": args.input,
        "max_output_tokens": args.max_output_tokens,
        "stream": args.stream,
        # Dynamo extension: return the serving worker and server-side timing.
        "nvext": {"extra_fields": NVEXT_FIELDS},
    }
    if args.instructions:
        body["instructions"] = args.instructions
    if args.temperature is not None:
        body["temperature"] = args.temperature
    return body


def call(client: httpx.Client, url: str, headers: dict[str, str], body: dict[str, Any]) -> dict[str, Any]:
    """Sends one request. Returns the final response object, headers and client timings."""
    start = time.perf_counter()
    first_token_at = None
    text: list[str] = []
    events = 0
    final: dict[str, Any] | None = None

    with client.stream("POST", url, headers=headers, json=body) as resp:
        if resp.status_code != 200:
            resp.read()
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text}")
        if body["stream"]:
            for line in resp.iter_lines():
                if not line.startswith("data: ") or line == "data: [DONE]":
                    continue
                event = json.loads(line.removeprefix("data: "))
                events += 1
                kind = event.get("type", "")
                if kind == "response.output_text.delta":
                    if first_token_at is None:
                        first_token_at = time.perf_counter()
                    text.append(event["delta"])
                elif kind in ("response.completed", "response.incomplete", "response.failed"):
                    final = event["response"]
                    # Dynamo puts nvext on the event, next to the response.
                    if "nvext" in event and "nvext" not in final:
                        final["nvext"] = event["nvext"]
        else:
            final = json.loads(resp.read())
        end = time.perf_counter()
        resp_headers = dict(resp.headers)

    final = final or {}
    if not text:
        text = [
            part.get("text", "")
            for item in final.get("output", [])
            for part in item.get("content", [])
            if part.get("type") == "output_text"
        ]
    return {
        "response": final,
        "headers": resp_headers,
        "text": "".join(text),
        "events": events,
        "client_total_ms": (end - start) * 1000,
        "client_ttft_ms": (first_token_at - start) * 1000 if first_token_at else None,
    }


def build_report(result: dict[str, Any], session_id: str) -> dict[str, Any]:
    """Collects the fields to print. Add new fields here."""
    response, headers = result["response"], result["headers"]
    usage = response.get("usage") or {}
    input_tokens = usage.get("input_tokens") or 0
    cached = (usage.get("input_tokens_details") or {}).get("cached_tokens") or 0
    output_tokens = usage.get("output_tokens") or 0
    nvext = response.get("nvext") or {}
    timing = nvext.get("timing") or {}
    worker = nvext.get("worker_id") or {}

    ttft = result["client_ttft_ms"]
    tpot = None
    if ttft is not None and output_tokens > 1:
        tpot = (result["client_total_ms"] - ttft) / (output_tokens - 1)

    return {
        "id": response.get("id"),
        "model": response.get("model"),
        "status": response.get("status"),
        "incomplete_reason": (response.get("incomplete_details") or {}).get("reason"),
        "session_id": session_id,
        "region": headers.get("x-served-region"),
        "cell": headers.get("x-served-cell"),
        "prefill_worker": worker.get("prefill_worker_id"),
        "decode_worker": worker.get("decode_worker_id"),
        "input_tokens": input_tokens,
        "cached_tokens": cached,
        "cache_hit_pct": round(100 * cached / input_tokens, 1) if input_tokens else None,
        "cache": "hit" if cached > 0 else "miss",
        "output_tokens": output_tokens,
        "total_tokens": usage.get("total_tokens"),
        "client_ttft_ms": round(ttft, 1) if ttft is not None else None,
        "client_total_ms": round(result["client_total_ms"], 1),
        "client_tpot_ms": round(tpot, 2) if tpot is not None else None,
        "client_output_tokens_per_s": round(output_tokens / (result["client_total_ms"] / 1000), 1)
        if output_tokens
        else None,
        "server_ttft_ms": _round(timing.get("ttft_ms")),
        "server_prefill_ms": _round(timing.get("prefill_time_ms")),
        "server_prefill_wait_ms": _round(timing.get("prefill_wait_time_ms")),
        "server_total_ms": _round(timing.get("total_time_ms")),
        "server_kv_hit_rate": _round(timing.get("kv_hit_rate"), 3),
        "router_queue_depth": timing.get("router_queue_depth"),
        "stream_events": result["events"] or None,
        "text": result["text"],
    }


def _round(value: Any, digits: int = 1) -> Any:
    return round(value, digits) if isinstance(value, (int, float)) else value


def print_report(n: int, report: dict[str, Any]) -> None:
    def show(label: str, *keys: str, unit: str = "") -> None:
        values = [report.get(k) for k in keys]
        if all(v is None for v in values):
            return
        print(f"  {label:<16} " + " / ".join("-" if v is None else f"{v}{unit}" for v in values))

    print(f"\n#{n}  {report['id']}  {report['model']}")
    print(f"  {'text':<16} {report['text']!r}")
    status = report["status"] + (f" ({report['incomplete_reason']})" if report["incomplete_reason"] else "")
    print(f"  {'status':<16} {status}")
    print(f"  {'served by':<16} region {report['region']}, cell {report['cell']}, session {report['session_id']}")
    show("worker p / d", "prefill_worker", "decode_worker")
    print(
        f"  {'tokens':<16} input {report['input_tokens']} (cached {report['cached_tokens']}, "
        f"{report['cache_hit_pct']}% -> cache {report['cache']}), output {report['output_tokens']}, "
        f"total {report['total_tokens']}"
    )
    show("client ms", "client_ttft_ms", "client_total_ms", unit="")
    print(f"  {'':<16} (TTFT / total; TPOT {report['client_tpot_ms']} ms, {report['client_output_tokens_per_s']} tok/s)")
    show("server ms", "server_ttft_ms", "server_prefill_ms", "server_total_ms")
    print(f"  {'':<16} (TTFT / prefill / total; kv_hit_rate {report['server_kv_hit_rate']}, "
          f"prefill wait {report['server_prefill_wait_ms']} ms, router queue {report['router_queue_depth']})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("input", nargs="?", help="prompt text (or use --input-file)")
    parser.add_argument("--input-file", type=Path, help="read the prompt from a file")
    parser.add_argument("--instructions", help="system-style instructions")
    parser.add_argument("--session-id", help="session-id header (default: a new random one)")
    parser.add_argument("--max-output-tokens", type=int, default=64)
    parser.add_argument("--temperature", type=float)
    parser.add_argument("--repeat", type=int, default=1, help="send the same request N times (same session)")
    parser.add_argument("--no-stream", dest="stream", action="store_false", help="non-streaming request")
    parser.add_argument("--json", action="store_true", help="print one JSON report per request")
    args = parser.parse_args()

    if args.input_file:
        args.input = args.input_file.read_text()
    if not args.input:
        parser.error("give a prompt or --input-file")

    api, token, model = connection()
    session_id = args.session_id or f"infer-{uuid.uuid4()}"
    headers = {"authorization": f"Bearer {token}", "session-id": session_id}

    with httpx.Client(timeout=httpx.Timeout(10, read=300)) as client:
        if not model:
            model = client.get(f"{api}/models", headers=headers).json()["data"][0]["id"]
        body = request_body(args, model)
        for n in range(1, args.repeat + 1):
            try:
                report = build_report(call(client, f"{api}/responses", headers, body), session_id)
            except RuntimeError as exc:
                print(f"#{n}: {exc}", file=sys.stderr)
                return 1
            if args.json:
                print(json.dumps(report))
            else:
                print_report(n, report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
