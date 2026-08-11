#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
End-to-end hostless smoke for virt-ai-pcie.

Starts card agent in a thread, pushes 2×2 INT8 GEMM, asserts
C == [[19, 22], [43, 50]]. Optional multi-ticket claim path.

Usage (from monorepo root or any cwd):
  python3 ai-tensor/tools/virt_ai_card/smoke.py
  bash monorepo-soak/run-virt-ai-card.sh
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

_PKG = Path(__file__).resolve().parent
if str(_PKG.parent) not in sys.path:
    sys.path.insert(0, str(_PKG.parent))

from virt_ai_card.card_agent import CardAgent
from virt_ai_card.driver import VirtualEventFd, VirtualUioDevice, int8_gemm
from virt_ai_card.host_client import HostClient


GOLDEN_A = [[1, 2], [3, 4]]
GOLDEN_B = [[5, 6], [7, 8]]
GOLDEN_C = [[19, 22], [43, 50]]


def _test_local_driver() -> None:
    """Direct VirtualUioDevice path (no TCP) — soft-sticky + eventfd claim order."""
    efd = VirtualEventFd()
    dev = VirtualUioDevice(eventfd=efd)
    assert dev.cap_version() == 1
    dev.enable(True)
    c = dev.gemm_s8(GOLDEN_A, GOLDEN_B, ticket=7, irq=True, wait=True)
    assert c == GOLDEN_C, f"local gemm mismatch: {c}"
    # multi-ticket
    efd2 = VirtualEventFd()
    dev2 = VirtualUioDevice(eventfd=efd2)
    dev2.enable(True)
    dev2.stage_gemm_s8(GOLDEN_A, GOLDEN_B, ticket=20, irq=True)
    dev2.stage_gemm_s8(GOLDEN_A, GOLDEN_B, ticket=21, irq=True)
    c20 = dev2.wait_claim_result(ticket=20, timeout=2.0)
    assert c20 == GOLDEN_C
    c21 = dev2.wait_claim_result(ticket=21, timeout=2.0)
    assert c21 == GOLDEN_C
    assert not dev2.irq_pending
    print("  local VirtualUioDevice + multi-ticket: ok")


def _test_int8_ref() -> None:
    c = int8_gemm(GOLDEN_A, GOLDEN_B)
    assert c == GOLDEN_C
    print("  int8_gemm golden: ok")


def _test_tcp_path() -> None:
    agent = CardAgent(host="127.0.0.1", port=0)
    host, port = agent.start()
    try:
        # brief settle for accept thread
        time.sleep(0.05)
        cli = HostClient(host=host, port=port)
        hello = cli.connect()
        assert hello.get("boardid") == "virt-ai-pcie"
        assert hello.get("cap_version") == 1
        assert cli.ping()
        # BAR4 bulk then gemm by name
        cli.bar4_put("A", GOLDEN_A)
        cli.bar4_put("B", GOLDEN_B)
        c = cli.gemm_s8(a_name="A", b_name="B", ticket=42)
        assert c == GOLDEN_C, f"tcp gemm-by-name mismatch: {c}"
        # inline matrices
        c2 = cli.gemm_s8(GOLDEN_A, GOLDEN_B, ticket=43)
        assert c2 == GOLDEN_C, f"tcp gemm inline mismatch: {c2}"
        c_bar = cli.bar4_get("C")
        assert c_bar == GOLDEN_C
        cli.close()
        print(f"  TCP VirtualPcieLink ({host}:{port}): ok")
    finally:
        agent.stop()


def main() -> int:
    print("virt_ai_card smoke: start")
    _test_int8_ref()
    _test_local_driver()
    _test_tcp_path()
    print("virt_ai_card smoke: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"virt_ai_card smoke: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
