from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import uuid
from collections import Counter
from pathlib import Path

import pytest

from app.routing import cell_index, select_cell


def test_same_session_always_maps_to_same_cell() -> None:
    for session_id in ("conversation-1", "a", "ünïcødé-session", str(uuid.uuid4())):
        results = {cell_index(session_id, 2) for _ in range(100)}
        assert len(results) == 1


def test_index_is_sha256_mod_n() -> None:
    session_id = "conversation-42"
    expected = int.from_bytes(hashlib.sha256(session_id.encode()).digest(), "big") % 3
    assert cell_index(session_id, 3) == expected


def test_known_vectors_are_stable() -> None:
    # Fixed expectations guard against any change of the routing function.
    assert cell_index("session-1", 2) == 1
    assert cell_index("session-2", 2) == 0
    assert cell_index("session-1", 3) == 0
    assert cell_index("session-2", 3) == 2


def test_routing_is_independent_of_python_hash_seed() -> None:
    router_dir = Path(__file__).resolve().parents[1]
    code = "from app.routing import cell_index; print([cell_index(f's{i}', 5) for i in range(50)])"
    outputs = set()
    for seed in ("0", "1", "12345"):
        env = {**os.environ, "PYTHONHASHSEED": seed}
        result = subprocess.run(
            [sys.executable, "-c", code], cwd=router_dir, env=env, capture_output=True, text=True, check=True
        )
        outputs.add(result.stdout)
    assert len(outputs) == 1


@pytest.mark.parametrize("n_cells", [2, 3, 5])
def test_sessions_are_spread_evenly_across_cells(n_cells: int) -> None:
    samples = 20_000
    counts = Counter(cell_index(str(uuid.uuid4()), n_cells) for _ in range(samples))
    assert set(counts) == set(range(n_cells))
    expected = samples / n_cells
    for count in counts.values():
        assert abs(count - expected) / expected < 0.05


def test_select_cell_returns_element() -> None:
    cells = ["a", "b"]
    assert select_cell("session-1", cells) == cells[cell_index("session-1", 2)]


def test_zero_cells_rejected() -> None:
    with pytest.raises(ValueError):
        cell_index("x", 0)
