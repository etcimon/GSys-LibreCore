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
from virt_ai_card.driver import (
    CTL,
    DESC,
    DESC_BYTES,
    DONE,
    DOORBELL,
    DSTATUS,
    FLAG_IRQ,
    STATUS,
    ST_BAD_OP,
    ST_BAD_FMT,
    ST_DISABLED,
    ST_ERR,
    TICKET,
    VirtualEventFd,
    VirtualUioDevice,
    int8_gemm,
)
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
    snap = dev.cap_snapshot()
    assert snap["clusters"] == 1 and snap["macs_per_cycle"] == 512
    assert snap["acc_tile_m"] == 1024 and snap["acc_tile_n"] == 512 and snap["acc_tile_k"] == 512
    seeded = VirtualUioDevice(cap={"clusters": 2, "macs_per_cycle": 256, "sram_bytes": 2097152})
    seeded_snap = seeded.cap_snapshot()
    assert seeded_snap["clusters"] == 2 and seeded_snap["sram_bytes"] == 2097152
    print("  CAP seed/snapshot: ok")
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
    assert FLAG_IRQ == 1 << 2
    seeded_irq = VirtualUioDevice(cap={"irq_bit": 2})
    assert seeded_irq._irq_bit == 2
    bare = VirtualUioDevice()
    bare.enable(True)
    bare.stage_tensor("A", GOLDEN_A)
    bare.stage_tensor("B", GOLDEN_B)
    desc_irq = bytearray(DESC_BYTES)
    desc_irq[0:4] = (2 | (1 << 16)).to_bytes(4, "little")
    desc_irq[4:8] = FLAG_IRQ.to_bytes(4, "little")
    desc_irq[8:12] = (2).to_bytes(4, "little")
    desc_irq[12:16] = (2).to_bytes(4, "little")
    desc_irq[16:20] = (2).to_bytes(4, "little")
    bare.load_desc(bytes(desc_irq))
    bare.write32(DOORBELL, 9 << 8)
    assert bare.irq_pending, "ingested irq_bit=2 must raise IRQ without eventfd"
    head = bare.claim_done()
    assert head is not None and head.ticket == 9
    assert not bare.irq_pending
    noirq = VirtualUioDevice()
    noirq.enable(True)
    noirq.stage_tensor("A", GOLDEN_A)
    noirq.stage_tensor("B", GOLDEN_B)
    desc_quiet = bytearray(DESC_BYTES)
    desc_quiet[0:4] = (2 | (1 << 16)).to_bytes(4, "little")
    desc_quiet[8:12] = (2).to_bytes(4, "little")
    desc_quiet[12:16] = (2).to_bytes(4, "little")
    desc_quiet[16:20] = (2).to_bytes(4, "little")
    noirq.load_desc(bytes(desc_quiet))
    noirq.write32(DOORBELL, 10 << 8)
    assert not noirq.irq_pending, "flags=0 and no eventfd must not raise IRQ"
    print("  FLAG_IRQ bit 2 (isa-encoding) vs flags=0: ok")
    ld_ok = VirtualUioDevice()
    ld_ok.enable(True)
    ld_ok.stage_tensor("A", GOLDEN_A)
    ld_ok.stage_tensor("B", GOLDEN_B)
    desc_ld = bytearray(DESC_BYTES)
    desc_ld[0:4] = (2 | (1 << 16)).to_bytes(4, "little")
    desc_ld[8:12] = (2).to_bytes(4, "little")
    desc_ld[12:16] = (2).to_bytes(4, "little")
    desc_ld[16:20] = (2).to_bytes(4, "little")
    desc_ld[20:24] = (2 | (2 << 16)).to_bytes(4, "little")
    ld_ok.load_desc(bytes(desc_ld))
    ld_ok.write32(DOORBELL, 11 << 8)
    assert ld_ok.read32(DSTATUS) == 0, "matching ld_ab must complete ST_OK"
    ld_ok.claim_done()
    for flags in (1 << 8, 1 << 10, 1 << 12, 1 << 14, 1 << 20, 5 << 20):
        unsupported = VirtualUioDevice()
        unsupported.enable(True)
        unsupported.stage_tensor("A", GOLDEN_A)
        unsupported.stage_tensor("B", GOLDEN_B)
        desc_mode = bytearray(desc_ld)
        desc_mode[4:8] = flags.to_bytes(4, "little")
        unsupported.load_desc(bytes(desc_mode))
        unsupported.write32(DOORBELL, 19 << 8)
        assert unsupported.read32(DSTATUS) == ST_BAD_FMT, f"unsupported arithmetic flags {flags:#x}"
    ld_bad = VirtualUioDevice()
    ld_bad.enable(True)
    ld_bad.stage_tensor("A", GOLDEN_A)
    ld_bad.stage_tensor("B", GOLDEN_B)
    desc_bad = bytearray(desc_ld)
    desc_bad[20:24] = (9 | (9 << 16)).to_bytes(4, "little")
    ld_bad.load_desc(bytes(desc_bad))
    ld_bad.write32(DOORBELL, 12 << 8)
    assert ld_bad.read32(DSTATUS) == ST_ERR, "mismatched ld_ab must complete ST_ERR"
    print("  ld_ab vs n,k check: ok")
    bound = VirtualUioDevice(cap={"queues": 2, "queue_depth": 64})
    bound.enable(True)
    bound.stage_tensor("A", GOLDEN_A)
    bound.stage_tensor("B", GOLDEN_B)
    bound.write32(DOORBELL, (13 << 8) | 0)
    assert bound.read32(DSTATUS) == 0
    bound.claim_done()
    bound.write32(DOORBELL, (14 << 8) | 2)
    assert bound.read32(DSTATUS) == ST_ERR, "qid >= queues must complete ST_ERR"
    bound.claim_done()
    bad_ver = VirtualUioDevice(cap={"queues": 1})
    bad_ver.enable(True)
    bad_ver.stage_tensor("A", GOLDEN_A)
    bad_ver.stage_tensor("B", GOLDEN_B)
    desc_ver = bytearray(DESC_BYTES)
    desc_ver[0:4] = (99 | (1 << 16)).to_bytes(4, "little")
    desc_ver[8:12] = (2).to_bytes(4, "little")
    desc_ver[12:16] = (2).to_bytes(4, "little")
    desc_ver[16:20] = (2).to_bytes(4, "little")
    bad_ver.load_desc(bytes(desc_ver))
    bad_ver.write32(DOORBELL, 15 << 8)
    assert bad_ver.read32(DSTATUS) == 2, "desc version != 2 must complete ST_BAD_VER"
    print("  qid bound + desc version: ok")
    bad_op = VirtualUioDevice(cap={"queues": 1})
    bad_op.enable(True)
    bad_op.stage_tensor("A", GOLDEN_A)
    bad_op.stage_tensor("B", GOLDEN_B)
    desc_op = bytearray(DESC_BYTES)
    desc_op[0:4] = (2 | (99 << 16)).to_bytes(4, "little")
    desc_op[8:12] = (2).to_bytes(4, "little")
    desc_op[12:16] = (2).to_bytes(4, "little")
    desc_op[16:20] = (2).to_bytes(4, "little")
    bad_op.load_desc(bytes(desc_op))
    bad_op.write32(DOORBELL, 16 << 8)
    assert bad_op.read32(DSTATUS) == ST_BAD_OP, "unknown op must complete ST_BAD_OP"
    off = VirtualUioDevice()
    off.stage_tensor("A", GOLDEN_A)
    off.stage_tensor("B", GOLDEN_B)
    off.write32(DOORBELL, 17 << 8)
    assert off.read32(DSTATUS) == ST_DISABLED, "disabled CTL must complete ST_DISABLED"
    off.claim_done()
    off.enable(True)
    off.write32(DOORBELL, 18 << 8)
    assert off.read32(DSTATUS) == 0, "re-enable must complete ST_OK"
    assert off.claim_done() is not None
    print("  unknown op + disabled CTL + re-enable: ok")


def _test_int8_ref() -> None:
    c = int8_gemm(GOLDEN_A, GOLDEN_B)
    assert c == GOLDEN_C
    print("  int8_gemm golden: ok")


def _test_tcp_path() -> None:
    agent = CardAgent(host="127.0.0.1", port=0, cap={"queues": 2, "queue_depth": 64})
    host, port = agent.start()
    try:
        # brief settle for accept thread
        time.sleep(0.05)
        cli = HostClient(host=host, port=port)
        hello = cli.connect()
        assert hello.get("boardid") == "virt-ai-pcie"
        assert hello.get("cap_version") == 1
        assert hello.get("mmio_size") == 0x1000
        assert cli.ping()
        assert cli.mmio_read32(0) == 1
        desc = bytearray(DESC_BYTES)
        desc[0:4] = (2 | (1 << 16)).to_bytes(4, "little")
        desc[8:12] = (2).to_bytes(4, "little")
        desc[12:16] = (2).to_bytes(4, "little")
        desc[16:20] = (2).to_bytes(4, "little")
        cli.mmio_write_bytes(DESC, bytes(desc))
        assert cli.mmio_read_bytes(DESC, DESC_BYTES) == bytes(desc)
        # BAR4 bulk then MMIO doorbell + DONE claim (no gemm_s8 helper)
        cli.bar4_put("A", GOLDEN_A)
        cli.bar4_put("B", GOLDEN_B)
        cli.mmio_write32(CTL, 1)
        cli.mmio_write32(DOORBELL, 41 << 8)
        assert cli.irq_wait(2.0) == 1
        assert cli.mmio_read32(DONE) & 1
        assert cli.mmio_read32(TICKET) == 41
        assert cli.mmio_read32(DSTATUS) == 0
        cli.mmio_write32(DONE, 1)
        cli.irq_clear()
        assert (cli.mmio_read32(STATUS) & 1) == 0
        assert cli.bar4_get("C") == GOLDEN_C
        # second ingested-style ring (qid 1)
        cli.mmio_write32(DOORBELL, (50 << 8) | 1)
        assert cli.irq_wait(2.0) == 1
        assert cli.mmio_read32(TICKET) == 50
        cli.mmio_write32(DONE, 1)
        cli.irq_clear()
        assert cli.bar4_get("C") == GOLDEN_C
        cli.mmio_write32(DOORBELL, (51 << 8) | 2)
        assert cli.mmio_read32(DONE) & 1
        assert cli.mmio_read32(TICKET) == 51
        assert cli.mmio_read32(DSTATUS) == ST_ERR
        cli.mmio_write32(DONE, 1)
        c = cli.gemm_s8(a_name="A", b_name="B", ticket=42)
        assert c == GOLDEN_C, f"tcp gemm-by-name mismatch: {c}"
        # packed DESC blob over BAR4 into the existing UIO DESC window (0x140)
        desc = bytearray(DESC_BYTES)
        desc[0:4] = (2 | (1 << 16)).to_bytes(4, "little")
        desc[8:12] = (2).to_bytes(4, "little")
        desc[12:16] = (2).to_bytes(4, "little")
        desc[16:20] = (2).to_bytes(4, "little")
        cli.bar4_put_bytes("DESC", bytes(desc))
        assert cli.bar4_get("DESC") == bytes(desc)
        c_desc = cli.gemm_s8(a_name="A", b_name="B", ticket=44)
        assert c_desc == GOLDEN_C, f"tcp gemm-with-desc mismatch: {c_desc}"
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
