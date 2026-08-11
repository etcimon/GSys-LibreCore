#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Structured PyTorch validation of ai-tensor against **ai_island** features
via the virtual PCIe AI board (``virt-ai-pcie`` / ``virt-card`` backend).

Maps framework GEMM to the same host path that will eventually hit:
  CAP/CTL @ 0x4000_0000 · PLIC-8 claim order · AccTile 256 · INT8→i32 C ·
  multi-ticket DONE FIFO · soft UIO ``virt://…`` · optional TCP CardAgent
  (BAR4 / virtio-SSH stand-in).

Run (package):
  PYTHONPATH=python:tools python -m unittest python.tests.test_torch_virt_ai_island -v
  PYTHONPATH=python:tools python python/tests/test_torch_virt_ai_island.py

Run (monorepo / build-platform — preferred):
  bun run src/cli/index.ts tensor frameworks --board virt-ai-pcie --core g6lc64_ai
  bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai
  bash monorepo-soak/run-ai-tensor-pytorch.sh

Env (set by build-platform from board.json + --core):
  AI_TENSOR_BOARD_ID=virt-ai-pcie
  AI_TENSOR_BACKEND=virt-card
  AI_TENSOR_CORE=g6lc64_ai
  AI_TENSOR_UIO=virt://virt-ai-pcie/island0
  AI_TENSOR_VIRT_MODE=local|tcp|auto
  AI_TENSOR_REQUIRE_TORCH=1   # fail if torch missing (CI optional gate)

If PyTorch is not installed:
  - default: skip with code 0 and print SKIP (hostless CI without torch wheels)
  - AI_TENSOR_REQUIRE_TORCH=1 or --require-torch: exit 1
"""

from __future__ import annotations

import argparse
import os
import sys
import unittest
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Import path: package python/ + tools/ (virt_ai_card)
# ---------------------------------------------------------------------------
_ROOT = Path(__file__).resolve().parents[2]
_PY = _ROOT / "python"
_TOOLS = _ROOT / "tools"
for _p in (_PY, _TOOLS):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

# ---------------------------------------------------------------------------
# Optional torch
# ---------------------------------------------------------------------------
_TORCH_ERR: Optional[BaseException] = None
try:
    import torch
except Exception as _e:  # noqa: BLE001 — ImportError or broken wheel
    torch = None  # type: ignore
    _TORCH_ERR = _e

from ai_tensor.device import Caps, Device  # noqa: E402

# torch_ops hard-requires torch at import time — only load when available.
if torch is not None:
    from ai_tensor.torch_ops import check_close_to_torch, gemm_s8  # noqa: E402
else:
    check_close_to_torch = None  # type: ignore
    gemm_s8 = None  # type: ignore


def _require_torch() -> bool:
    return os.environ.get("AI_TENSOR_REQUIRE_TORCH", "").strip() in (
        "1",
        "true",
        "yes",
    )


def _board() -> str:
    return os.environ.get("AI_TENSOR_BOARD_ID", "virt-ai-pcie").strip() or "virt-ai-pcie"


def _core() -> str:
    return (
        os.environ.get("AI_TENSOR_CORE")
        or os.environ.get("CVA6_CORE_CONFIG")
        or "g6lc64_ai"
    ).strip()


def _virt_mode() -> str:
    return (os.environ.get("AI_TENSOR_VIRT_MODE") or "auto").strip().lower()


def _open_device(virt_mode: Optional[str] = None) -> Device:
    """Open Device under board env; always virt-card for this suite."""
    os.environ.setdefault("AI_TENSOR_BOARD_ID", _board())
    os.environ.setdefault("AI_TENSOR_BACKEND", "virt-card")
    os.environ.setdefault("AI_TENSOR_CORE", _core())
    board = _board()
    mode = virt_mode or _virt_mode()
    return Device.from_board(board, virt_mode=mode)


def _torch_int8_mm_ref(a: "torch.Tensor", b: "torch.Tensor") -> "torch.Tensor":
    return a.to(torch.int32) @ b.to(torch.int32)


# ===========================================================================
# Feature suites (ai_island contract through virt-card)
# ===========================================================================


@unittest.skipUnless(torch is not None, f"PyTorch not installed ({_TORCH_ERR})")
class TestAiIslandGemmThroughVirtPcie(unittest.TestCase):
    """INT8 GEMM feature — OP_GEMM / Desc64 path via virt-card Device."""

    def setUp(self) -> None:
        self.board = _board()
        self.core = _core()
        torch.manual_seed(0xC0FFEE)

    def test_env_selects_ai_island_config(self) -> None:
        """Board + core selection surface used by build-platform tensor CLI."""
        self.assertTrue(self.board.startswith("virt"), msg=self.board)
        self.assertIn("ai", self.core.lower(), msg=f"core should be g6lc64_ai-class, got {self.core}")
        os.environ["AI_TENSOR_BOARD_ID"] = self.board
        os.environ["AI_TENSOR_CORE"] = self.core
        with _open_device("local") as dev:
            self.assertEqual(dev.board_id, self.board)
            self.assertIn("virt-card", dev.backend)
            caps = dev.caps()
            # island_p3 / I1 freeze
            self.assertEqual(caps.acc_tile_m, 256)
            self.assertEqual(caps.acc_tile_n, 256)
            self.assertEqual(caps.acc_tile_k, 256)
            self.assertEqual(caps.macs_per_cycle, 256)
            self.assertEqual(caps.noc_width, 64)

    def test_gemm_s8_2x2_golden(self) -> None:
        """Canonical 2×2 INT8 golden (same as HARD ai_gemm_s8_smoke numbers)."""
        a = torch.tensor([[1, 2], [3, 4]], dtype=torch.int8)
        b = torch.tensor([[5, 6], [7, 8]], dtype=torch.int8)
        with _open_device("local") as dev:
            c, meta = gemm_s8(a, b, device=dev, ticket=1)
            self.assertEqual(meta.get("status"), 0)
            self.assertEqual(meta.get("board_id"), self.board)
            self.assertTrue(torch.equal(c, torch.tensor([[19, 22], [43, 50]], dtype=torch.int32)))
            rep = check_close_to_torch(a, b, device=dev)
            self.assertTrue(rep["match"], rep)

    def test_gemm_s8_matches_torch_mm(self) -> None:
        """Random small GEMM matches torch int32 matmul of int8 operands."""
        m, n, k = 8, 12, 16
        a = torch.randint(-8, 8, (m, k), dtype=torch.int8)
        b = torch.randint(-8, 8, (k, n), dtype=torch.int8)
        with _open_device("local") as dev:
            c, meta = gemm_s8(a, b, device=dev, ticket=7)
            self.assertEqual(tuple(c.shape), (m, n))
            self.assertEqual(meta.get("status"), 0)
            ref = _torch_int8_mm_ref(a, b)
            self.assertTrue(torch.equal(c, ref), f"diff max={(c - ref).abs().max().item()}")

    def test_multi_ticket_sequential(self) -> None:
        """Multiple tickets in order (CPL FIFO multi-claim discipline host-side)."""
        a = torch.tensor([[1, 0], [0, 1]], dtype=torch.int8)
        b = torch.tensor([[2, 3], [4, 5]], dtype=torch.int8)
        expect = torch.tensor([[2, 3], [4, 5]], dtype=torch.int32)
        with _open_device("local") as dev:
            for tix in (20, 21, 22):
                c, meta = gemm_s8(a, b, device=dev, ticket=tix)
                self.assertEqual(meta.get("ticket"), tix)
                self.assertTrue(torch.equal(c, expect), f"ticket={tix} c={c}")


@unittest.skipUnless(torch is not None, f"PyTorch not installed ({_TORCH_ERR})")
class TestAiIslandAccTileThroughVirtPcie(unittest.TestCase):
    """AccTile host streaming — shapes that may exceed a single tile later."""

    def test_within_acctile_single_tile_meta(self) -> None:
        a = torch.randint(-4, 4, (32, 48), dtype=torch.int8)
        b = torch.randint(-4, 4, (48, 24), dtype=torch.int8)
        with _open_device("local") as dev:
            self.assertTrue(dev.caps().fits(32, 24, 48))
            c, meta = gemm_s8(a, b, device=dev, ticket=30, auto_tile=True)
            self.assertEqual(meta.get("tiles"), 1)
            self.assertFalse(meta.get("auto_tile"))
            self.assertTrue(torch.equal(c, _torch_int8_mm_ref(a, b)))

    def test_force_tile_stream_matches_ref(self) -> None:
        """Shrink AccTile caps so host auto_tile streams multiple jobs."""
        m, n, k = 20, 18, 24
        a = torch.randint(-5, 5, (m, k), dtype=torch.int8)
        b = torch.randint(-5, 5, (k, n), dtype=torch.int8)
        small = Caps(
            acc_tile_m=8,
            acc_tile_n=8,
            acc_tile_k=8,
            macs_per_cycle=256,
            noc_width=64,
        )
        with Device("virt-card", caps=small, board_id=_board(), virt_mode="local") as dev:
            self.assertFalse(dev.caps().fits(m, n, k))
            c, meta = gemm_s8(a, b, device=dev, ticket=40, auto_tile=True)
            self.assertTrue(meta.get("auto_tile"))
            self.assertGreater(meta.get("tiles", 0), 1)
            self.assertTrue(torch.equal(c, _torch_int8_mm_ref(a, b)), meta)


@unittest.skipUnless(torch is not None, f"PyTorch not installed ({_TORCH_ERR})")
class TestAiIslandVirtualPcieLink(unittest.TestCase):
    """TCP VirtualPcieLink / CardAgent path (virtio-SSH + BAR4 stand-in)."""

    def test_tcp_agent_gemm_matches_torch(self) -> None:
        a = torch.tensor([[1, 2], [3, 4]], dtype=torch.int8)
        b = torch.tensor([[5, 6], [7, 8]], dtype=torch.int8)
        with _open_device("tcp") as dev:
            self.assertIn("tcp", dev.backend)
            c, meta = gemm_s8(a, b, device=dev, ticket=50)
            self.assertEqual(meta.get("board_id"), _board())
            self.assertTrue(torch.equal(c, torch.tensor([[19, 22], [43, 50]], dtype=torch.int32)))
            rep = check_close_to_torch(a, b, device=dev)
            self.assertTrue(rep["match"], rep)

    def test_tcp_larger_shape(self) -> None:
        torch.manual_seed(1)
        a = torch.randint(-6, 6, (6, 10), dtype=torch.int8)
        b = torch.randint(-6, 6, (10, 5), dtype=torch.int8)
        with _open_device("tcp") as dev:
            c, meta = gemm_s8(a, b, device=dev, ticket=51)
            self.assertEqual(meta.get("status"), 0)
            self.assertTrue(torch.equal(c, _torch_int8_mm_ref(a, b)))


@unittest.skipUnless(torch is not None, f"PyTorch not installed ({_TORCH_ERR})")
class TestAiIslandDeviceEnvPropagation(unittest.TestCase):
    """from_env / board UIO path used when mb select writes ai-tensor.env."""

    def test_from_env_virt_uio(self) -> None:
        os.environ["AI_TENSOR_BOARD_ID"] = "virt-ai-pcie"
        os.environ["AI_TENSOR_BACKEND"] = "virt-card"
        os.environ["AI_TENSOR_UIO"] = "virt://virt-ai-pcie/island0"
        os.environ["AI_TENSOR_CORE"] = "g6lc64_ai"
        with Device.from_env() as dev:
            self.assertIn("virt-card", dev.backend)
            a = torch.tensor([[2, 0], [0, 2]], dtype=torch.int8)
            b = torch.tensor([[3, 0], [0, 4]], dtype=torch.int8)
            c, _ = gemm_s8(a, b, device=dev, ticket=60)
            self.assertTrue(torch.equal(c, torch.tensor([[6, 0], [0, 8]], dtype=torch.int32)))


# ===========================================================================
# Hostless fallback (no torch): still validate Device virt-card for CI
# ===========================================================================


class TestVirtCardDeviceWithoutTorch(unittest.TestCase):
    """Always runs — pure Device path so build-platform stays green without torch."""

    def test_device_local_golden(self) -> None:
        with _open_device("local") as dev:
            c, tix, st, meta = dev.gemm_s8(
                2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8], ticket=99
            )
            self.assertEqual(st, 0)
            self.assertEqual(c, [19, 22, 43, 50])
            self.assertEqual(meta.get("board_id"), _board())
            self.assertEqual(tix, 99)

    def test_device_tcp_golden(self) -> None:
        with _open_device("tcp") as dev:
            c, _, st, meta = dev.gemm_s8(
                2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8], ticket=100
            )
            self.assertEqual(st, 0)
            self.assertEqual(c, [19, 22, 43, 50])
            self.assertIn("tcp", dev.backend)


def _load_suite(include_torch: bool = True) -> unittest.TestSuite:
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(TestVirtCardDeviceWithoutTorch))
    if include_torch and torch is not None:
        for cls in (
            TestAiIslandGemmThroughVirtPcie,
            TestAiIslandAccTileThroughVirtPcie,
            TestAiIslandVirtualPcieLink,
            TestAiIslandDeviceEnvPropagation,
        ):
            suite.addTests(loader.loadTestsFromTestCase(cls))
    return suite


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description="PyTorch + Device tests for ai_island features via virt-ai-pcie"
    )
    p.add_argument("--board", default=None, help="AI_TENSOR_BOARD_ID (default virt-ai-pcie)")
    p.add_argument("--core", default=None, help="AI_TENSOR_CORE (default g6lc64_ai)")
    p.add_argument(
        "--virt-mode",
        default=None,
        choices=("auto", "local", "tcp"),
        help="default virt mode for tests that call _open_device() without override",
    )
    p.add_argument(
        "--require-torch",
        action="store_true",
        help="fail if PyTorch is not installed",
    )
    p.add_argument(
        "--device-only",
        action="store_true",
        help="skip torch classes even if torch is present",
    )
    p.add_argument("-v", "--verbose", action="store_true", default=True)
    p.add_argument("-q", "--quiet", action="store_true")
    args = p.parse_args(argv)

    if args.board:
        os.environ["AI_TENSOR_BOARD_ID"] = args.board
    if args.core:
        os.environ["AI_TENSOR_CORE"] = args.core
    if args.virt_mode:
        os.environ["AI_TENSOR_VIRT_MODE"] = args.virt_mode
    if args.require_torch:
        os.environ["AI_TENSOR_REQUIRE_TORCH"] = "1"

    board, core = _board(), _core()
    print(
        f"[test_torch_virt_ai_island] board={board} core={core} "
        f"torch={'yes ' + torch.__version__ if torch else 'no'}",
        flush=True,
    )
    if os.environ.get("CVA6_FROM_TIMING") or os.environ.get("FROM_TIMING"):
        print(
            f"[test_torch_virt_ai_island] from-timing="
            f"{os.environ.get('CVA6_FROM_TIMING') or os.environ.get('FROM_TIMING')}",
            flush=True,
        )

    if torch is None and (_require_torch() or args.require_torch):
        print(
            f"[test_torch_virt_ai_island] FAIL: PyTorch required but missing: {_TORCH_ERR}",
            file=sys.stderr,
        )
        return 1

    if torch is None:
        print(
            "[test_torch_virt_ai_island] WARN: PyTorch not installed — "
            "running Device virt-card cases only (install torch for full suite)",
            flush=True,
        )

    suite = _load_suite(include_torch=not args.device_only)
    verbosity = 1 if args.quiet else 2
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    if not result.wasSuccessful():
        return 1
    n_torch = 0 if (torch is None or args.device_only) else (
        result.testsRun - 2
    )  # approx; two always-on device tests
    print(
        f"[test_torch_virt_ai_island] PASS testsRun={result.testsRun} "
        f"board={board} core={core}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
