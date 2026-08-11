#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Framework regress: PyTorch / TensorFlow / numpy / golden via Device backends.

Primary path for virtual PCIe AI board:
  AI_TENSOR_BOARD_ID=virt-ai-pcie AI_TENSOR_BACKEND=virt-card \\
    python3 tools/frameworks_regress.py --backend virt-card

Also exercises sim (always) and optional mmio when native is present.

Exit codes:
  0  all selected suites pass (or soft-skipped missing frameworks)
  1  hard failure
  2  usage error
"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
_TOOLS = ROOT / "tools"
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))


def log(msg: str) -> None:
    print(f"[frameworks-regress] {msg}", flush=True)


def _set_board_env(board: Optional[str], backend: Optional[str], core: Optional[str]) -> None:
    if board:
        os.environ["AI_TENSOR_BOARD_ID"] = board
        if board in ("virt-ai-pcie", "virt-ai", "virt_ai_pcie"):
            os.environ.setdefault("AI_TENSOR_UIO", f"virt://{board}/island0")
            os.environ.setdefault("AI_TENSOR_EVENTFD", f"virt://{board}/island0_irq")
            os.environ.setdefault("AI_TENSOR_BACKEND", "virt-card")
    if backend:
        os.environ["AI_TENSOR_BACKEND"] = backend
    if core:
        os.environ["AI_TENSOR_CORE"] = core
        os.environ.setdefault("CVA6_CORE_CONFIG", core)


def _open_device(backend: str, board: Optional[str], virt_mode: Optional[str]):
    from ai_tensor.device import Device

    if backend == "virt-card" or (board and str(board).startswith("virt")):
        return Device.from_board(
            board or os.environ.get("AI_TENSOR_BOARD_ID", "virt-ai-pcie"),
            virt_mode=virt_mode,
        )
    return Device(backend)


def suite_device_gemm(backend: str, board: Optional[str], virt_mode: Optional[str]) -> None:
    from ai_tensor.device import Device

    with _open_device(backend, board, virt_mode) as dev:
        a = [1, 2, 3, 4]
        b = [5, 6, 7, 8]
        c, tix, st, meta = dev.gemm_s8(2, 2, 2, a, b, ticket=11)
        assert st == 0, f"status={st}"
        assert c == [19, 22, 43, 50], c
        # larger tile-ish
        m, n, k = 8, 4, 8
        a8 = [(i % 7) - 3 for i in range(m * k)]
        b8 = [(i % 5) - 2 for i in range(k * n)]
        c2, _, st2, meta2 = dev.gemm_s8(m, n, k, a8, b8, ticket=12)
        assert st2 == 0
        assert len(c2) == m * n
        log(
            f"device ok backend={dev.backend} board={dev.board_id} "
            f"ticket={tix} tiles={meta.get('tiles')} large_tiles={meta2.get('tiles')}"
        )


def suite_numpy(backend: str, board: Optional[str], virt_mode: Optional[str]) -> None:
    try:
        import numpy as np  # noqa: F401
    except ImportError:
        log("skip numpy (not installed)")
        return
    from ai_tensor.device import Device

    with _open_device(backend, board, virt_mode) as dev:
        a = [[1, 2], [3, 4]]
        b = [[5, 6], [7, 8]]
        flat_a = [x for row in a for x in row]
        flat_b = [x for row in b for x in row]
        c, _, st, meta = dev.gemm_s8(2, 2, 2, flat_a, flat_b, ticket=1)
        assert st == 0 and c == [19, 22, 43, 50]
        log(f"numpy path ok backend={meta.get('backend')}")


def suite_torch(backend: str, board: Optional[str], virt_mode: Optional[str]) -> None:
    try:
        import torch
    except ImportError:
        log("skip torch (not installed)")
        return
    from ai_tensor.torch_ops import check_close_to_torch, gemm_s8

    with _open_device(backend, board, virt_mode) as dev:
        torch.manual_seed(1)
        a = torch.randint(-8, 8, (8, 16), dtype=torch.int8)
        b = torch.randint(-8, 8, (16, 8), dtype=torch.int8)
        c, meta = gemm_s8(a, b, device=dev, ticket=20)
        assert c.shape == (8, 8)
        rep = check_close_to_torch(a, b, device=dev)
        assert rep["match"], rep
        log(
            f"torch ok backend={meta.get('backend')} board={meta.get('board_id')} "
            f"match={rep['match']} tiles={meta.get('tiles')}"
        )


def suite_tf(backend: str, board: Optional[str], virt_mode: Optional[str]) -> None:
    try:
        import tensorflow as tf
    except ImportError:
        log("skip tensorflow (not installed)")
        return
    from ai_tensor.tf_ops import check_close_to_tf, gemm_s8

    with _open_device(backend, board, virt_mode) as dev:
        a = tf.constant([[1, 2], [3, 4]], dtype=tf.int8)
        b = tf.constant([[5, 6], [7, 8]], dtype=tf.int8)
        c, meta = gemm_s8(a, b, device=dev, ticket=30)
        assert int(c[0, 0]) == 19
        rep = check_close_to_tf(a, b, device=dev)
        assert rep["match"], rep
        log(
            f"tf ok backend={meta.get('backend')} board={meta.get('board_id')} "
            f"match={rep['match']}"
        )


def suite_golden_sim() -> None:
    from ai_tensor import run_golden_suite

    n = run_golden_suite(backends=("sim",))
    log(f"golden sim count={n}")


def suite_pytorch_unittest(board: Optional[str], virt_mode: Optional[str]) -> None:
    """Structured unittest: test_torch_virt_ai_island.py (Device + optional torch)."""
    import subprocess

    test = ROOT / "python" / "tests" / "test_torch_virt_ai_island.py"
    if not test.is_file():
        raise FileNotFoundError(str(test))
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT / "python") + os.pathsep + str(ROOT / "tools") + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
    )
    if board:
        env["AI_TENSOR_BOARD_ID"] = board
    if virt_mode:
        env["AI_TENSOR_VIRT_MODE"] = virt_mode
    cmd = [sys.executable, str(test), "--board", board or "virt-ai-pcie"]
    if env.get("AI_TENSOR_CORE"):
        cmd.extend(["--core", env["AI_TENSOR_CORE"]])
    r = subprocess.run(cmd, cwd=str(ROOT), env=env)
    if r.returncode != 0:
        raise RuntimeError(f"test_torch_virt_ai_island exit {r.returncode}")
    log("pytorch unittest ok")


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="ai-tensor frameworks regress")
    p.add_argument(
        "--backend",
        default=os.environ.get("AI_TENSOR_BACKEND", "virt-card"),
        help="sim | mmio | virt-card (default: virt-card or AI_TENSOR_BACKEND)",
    )
    p.add_argument(
        "--board",
        default=os.environ.get("AI_TENSOR_BOARD_ID", "virt-ai-pcie"),
        help="board id propagated as AI_TENSOR_BOARD_ID",
    )
    p.add_argument(
        "--core",
        default=os.environ.get("AI_TENSOR_CORE")
        or os.environ.get("CVA6_CORE_CONFIG"),
        help="core config name (g6lc64_ai); exported as AI_TENSOR_CORE",
    )
    p.add_argument(
        "--virt-mode",
        default=os.environ.get("AI_TENSOR_VIRT_MODE", "auto"),
        choices=("auto", "local", "tcp"),
        help="virt-card path: local VirtualUioDevice or TCP CardAgent",
    )
    p.add_argument(
        "--suites",
        default="device,numpy,torch,tf,pytorch",
        help="comma list: device,numpy,torch,tf,pytorch,golden,all",
    )
    p.add_argument(
        "--require-torch",
        action="store_true",
        help="fail if torch missing (default: soft-skip)",
    )
    p.add_argument(
        "--require-tf",
        action="store_true",
        help="fail if tensorflow missing (default: soft-skip)",
    )
    p.add_argument(
        "--tcp",
        action="store_true",
        help="force virt-mode=tcp (virtual PCIe link + CardAgent)",
    )
    return p.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    backend = args.backend.lower().replace("_", "-")
    if backend in ("virt", "virt-ai", "virt-ai-pcie", "pcie-virt"):
        backend = "virt-card"
    board = args.board
    virt_mode = "tcp" if args.tcp else args.virt_mode
    _set_board_env(board, backend, args.core)

    suites_raw = [s.strip().lower() for s in args.suites.split(",") if s.strip()]
    if "all" in suites_raw:
        suites_raw = ["device", "numpy", "torch", "tf", "pytorch", "golden"]

    log(
        f"start backend={backend} board={board} core={args.core!r} "
        f"virt_mode={virt_mode} suites={suites_raw}"
    )
    if os.environ.get("CVA6_FROM_TIMING") or os.environ.get("FROM_TIMING"):
        log(
            f"from-timing={os.environ.get('CVA6_FROM_TIMING') or os.environ.get('FROM_TIMING')}"
        )

    failed: List[Tuple[str, str]] = []
    ran = 0

    def run_one(name: str, fn) -> None:
        nonlocal ran
        log(f"--- suite {name} ---")
        try:
            fn()
            ran += 1
        except Exception as exc:  # noqa: BLE001
            failed.append((name, f"{exc}\n{traceback.format_exc()}"))
            log(f"FAIL {name}: {exc}")

    for s in suites_raw:
        if s == "device":
            run_one("device", lambda: suite_device_gemm(backend, board, virt_mode))
        elif s == "numpy":
            run_one("numpy", lambda: suite_numpy(backend, board, virt_mode))
        elif s == "torch":
            if args.require_torch:
                run_one("torch", lambda: suite_torch(backend, board, virt_mode))
            else:
                try:
                    import torch  # noqa: F401
                except ImportError:
                    log("skip torch (not installed)")
                    continue
                run_one("torch", lambda: suite_torch(backend, board, virt_mode))
        elif s == "tf":
            if args.require_tf:
                run_one("tf", lambda: suite_tf(backend, board, virt_mode))
            else:
                try:
                    import tensorflow  # noqa: F401
                except ImportError:
                    log("skip tensorflow (not installed)")
                    continue
                run_one("tf", lambda: suite_tf(backend, board, virt_mode))
        elif s == "pytorch":
            run_one(
                "pytorch",
                lambda: suite_pytorch_unittest(board, virt_mode),
            )
        elif s == "golden":
            run_one("golden", suite_golden_sim)
        else:
            log(f"unknown suite {s!r} (ignored)")
            return 2

    if failed:
        for name, detail in failed:
            print(f"\n=== FAIL {name} ===\n{detail}", file=sys.stderr)
        log(f"RESULT FAIL ({len(failed)} suite(s); ran={ran})")
        return 1
    log(f"RESULT PASS (ran={ran})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
