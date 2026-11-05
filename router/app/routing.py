"""Tier-2 routing: pin a session to a cell.

cell_index = sha256(session-id) mod N_cells

SHA-256 is used because it is identical across processes, hosts and Python
versions (Python's built-in hash() is salted per process).
"""

from __future__ import annotations

import hashlib
from collections.abc import Sequence
from typing import TypeVar

T = TypeVar("T")


def cell_index(session_id: str, n_cells: int) -> int:
    if n_cells <= 0:
        raise ValueError("n_cells must be positive")
    digest = hashlib.sha256(session_id.encode("utf-8")).digest()
    return int.from_bytes(digest, "big") % n_cells


def select_cell(session_id: str, cells: Sequence[T]) -> T:
    return cells[cell_index(session_id, len(cells))]
