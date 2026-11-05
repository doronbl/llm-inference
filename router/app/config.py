"""Router configuration, loaded from environment variables and the cells file.

The cells file is mounted from a ConfigMap. Its order defines cell indexes, so
append new cells at the end; changing the list remaps sessions (they are
treated as cold in their new cell).

    {"cells": [{"id": "a", "url": "http://<internal-nlb>:8000"},
               {"id": "b", "url": "http://<internal-nlb>:8000"}]}
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse


@dataclass(frozen=True)
class Cell:
    id: str
    url: str


@dataclass(frozen=True)
class Settings:
    region: str
    cells: tuple[Cell, ...]
    issuer: str
    jwks_url: str
    required_scope: str
    jwks_cache_seconds: float = 300.0
    jwks_min_refresh_seconds: float = 30.0
    upstream_connect_timeout_seconds: float = 5.0
    upstream_write_timeout_seconds: float = 30.0
    max_upstream_connections: int = 1000


def parse_cells(raw: str) -> tuple[Cell, ...]:
    data = json.loads(raw)
    entries = data.get("cells") if isinstance(data, dict) else None
    if not isinstance(entries, list) or not entries:
        raise ValueError("cells config must be an object with a non-empty 'cells' list")

    cells: list[Cell] = []
    for entry in entries:
        cell_id = str(entry.get("id", "")).strip()
        url = str(entry.get("url", "")).strip().rstrip("/")
        parsed = urlparse(url)
        if not cell_id or parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError(f"invalid cell entry: {entry!r}")
        cells.append(Cell(id=cell_id, url=url))

    ids = [c.id for c in cells]
    if len(set(ids)) != len(ids):
        raise ValueError(f"duplicate cell ids: {ids}")
    return tuple(cells)


def _require(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise ValueError(f"environment variable {name} is required")
    return value


def load_settings(env: Mapping[str, str] | None = None) -> Settings:
    env = os.environ if env is None else env
    issuer = _require(env, "ROUTER_COGNITO_ISSUER").rstrip("/")
    cells_file = Path(env.get("ROUTER_CELLS_FILE", "/etc/router/cells.json"))
    return Settings(
        region=_require(env, "ROUTER_REGION"),
        cells=parse_cells(cells_file.read_text(encoding="utf-8")),
        issuer=issuer,
        jwks_url=env.get("ROUTER_COGNITO_JWKS_URL", "").strip() or f"{issuer}/.well-known/jwks.json",
        required_scope=_require(env, "ROUTER_REQUIRED_SCOPE"),
    )
