# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Package-local offline goldens (lockstep with Rust cosim.rs + cosim_harness.py)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Sequence, Tuple

from .device import Device, ST_OK


@dataclass(frozen=True)
class GoldenGemm:
    name: str
    m: int
    n: int
    k: int
    a: Tuple[int, ...]
    b: Tuple[int, ...]
    c: Tuple[int, ...]


def builtin_goldens() -> List[GoldenGemm]:
    return [
        GoldenGemm(
            "2x2_manual",
            2,
            2,
            2,
            (1, 2, 3, 4),
            (5, 6, 7, 8),
            (19, 22, 43, 50),
        ),
        GoldenGemm(
            "1x1",
            1,
            1,
            1,
            (7,),
            (-3,),
            (-21,),
        ),
        GoldenGemm(
            "3x2x4_ones",
            3,
            2,
            4,
            tuple([1] * 12),
            tuple([1] * 8),
            (4, 4, 4, 4, 4, 4),
        ),
        GoldenGemm(
            "2x3x2_mixed",
            2,
            3,
            2,
            (1, -1, 2, 0),
            (3, 4, 5, -2, 1, 0),
            (5, 3, 5, 6, 8, 10),
        ),
    ]


def check_device_against_golden(
    dev: Device, g: GoldenGemm, ticket: int = 1
) -> None:
    c, tix, status, meta = dev.gemm_s8(
        g.m, g.n, g.k, list(g.a), list(g.b), ticket=ticket, auto_tile=False
    )
    if status != ST_OK:
        raise AssertionError(f"{g.name}: status={status} meta={meta}")
    if tuple(c) != g.c:
        raise AssertionError(f"{g.name}: c={c} exp={list(g.c)}")
    if tix != ticket:
        raise AssertionError(f"{g.name}: ticket={tix} exp={ticket}")


def run_golden_suite(backends: Sequence[str] = ("sim",)) -> int:
    """
    Run built-in goldens on each backend.

    Returns number of golden vectors checked (not backends × goldens).
    ``mmio`` requires ``ai_tensor_native``; missing backends are skipped with a note.
    """
    goldens = builtin_goldens()
    checked = 0
    for be in backends:
        try:
            dev = Device(be)
        except RuntimeError as e:
            print(f"golden_skip backend={be} reason={e}")
            continue
        for i, g in enumerate(goldens):
            check_device_against_golden(dev, g, ticket=10 + i)
            checked += 1
        print(f"golden_ok backend={dev.backend} count={len(goldens)}")
    if checked == 0:
        raise RuntimeError("no backends ran goldens")
    # Vector count per successful backend
    return len(goldens)
