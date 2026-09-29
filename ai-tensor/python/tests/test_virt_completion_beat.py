# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""A virtual-card completion beat keeps the GEMM word and reports ST_ERR."""

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[2]
for _p in (_ROOT / "python", _ROOT / "tools"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from virt_ai_card.driver import (  # noqa: E402
    CONTRACT_VERSION,
    CTL,
    DESC,
    DOORBELL,
    DSTATUS,
    FLAG_REUSE_B,
    PMU_VA_TURBO_LEVEL,
    PMU_VA_TURBO_RECIPE,
    PMU_VA_TURBO_WINDOW,
    REG_VA_TURBO_LEVEL,
    REG_VA_TURBO_RECIPE,
    REG_VA_TURBO_WINDOW,
    OP_GEMM,
    REG_REUSE_EPOCH,
    ST_ERR,
    ST_OK,
    VirtualUioDevice,
)


def test_a_completion_beat_error_keeps_the_gemm_word_and_the_product():
    dev = VirtualUioDevice()
    dev.write32(CTL, 1)
    dev.stage_tensor("A", [[1, 2], [3, 4]])
    dev.stage_tensor("B", [[5, 6], [7, 8]])
    dev.fail_next_completion_bus()
    dev.write32(DOORBELL, 1 << 8)
    assert dev._last_completion_word == (ST_OK << 32) | 1
    assert dev.read32(DSTATUS) == ST_ERR
    assert dev.get_tensor("C") == [[19, 22], [43, 50]]


def test_enabled_reuse_keeps_the_resident_b_row():
    dev = VirtualUioDevice()
    dev.set_reuse_en(True)
    dev.write32(CTL, 1)
    dev.stage_tensor("A", [[1]])
    dev.stage_tensor("B", [[2]])
    dev.write32(DESC, CONTRACT_VERSION | (OP_GEMM << 16))
    dev.write32(DESC + 4, 0)
    dev.write32(DESC + 8, 1)
    dev.write32(DESC + 12, 1)
    dev.write32(DESC + 16, 1)
    dev.write32(DESC + 20, 1 | (1 << 16))
    dev.write32(DOORBELL, 1 << 8)
    assert dev.get_tensor("C") == [[2]]
    dev.stage_tensor("B", [[9]])
    dev.write32(DESC + 4, FLAG_REUSE_B)
    dev.write32(DOORBELL, 2 << 8)
    assert dev.get_tensor("C") == [[2]]
    dev.write32(REG_REUSE_EPOCH, 1)
    dev.write32(DOORBELL, 3 << 8)
    assert dev.get_tensor("C") == [[9]]
    assert dev.read32(REG_REUSE_EPOCH) == 1


def test_a_recipe_request_keeps_the_exact_product():
    dev = VirtualUioDevice()
    dev.write32(CTL, 1)
    dev.write32(REG_VA_TURBO_RECIPE, 0x110)
    assert dev.read32(REG_VA_TURBO_RECIPE) == 0x10
    assert dev.read32(PMU_VA_TURBO_RECIPE) == 0
    dev.stage_tensor("A", [[1]])
    dev.stage_tensor("B", [[2]])
    dev.write32(DOORBELL, 1 << 8)
    assert dev.get_tensor("C") == [[2]]
    assert dev.read32(PMU_VA_TURBO_RECIPE) == 0x10
    assert (dev.read32(REG_VA_TURBO_RECIPE) >> 8) & 0x1F == 0
    dev.write32(REG_VA_TURBO_WINDOW, 1)
    assert dev.read32(REG_VA_TURBO_WINDOW) == 1
    dev.write32(REG_VA_TURBO_RECIPE, 0x10)
    assert dev.read32(REG_VA_TURBO_WINDOW) == 0


def test_a_level_request_keeps_the_exact_product():
    dev = VirtualUioDevice()
    dev.write32(CTL, 1)
    dev.write32(REG_VA_TURBO_LEVEL, 0xFFFFFFFF)
    assert dev.read32(REG_VA_TURBO_LEVEL) == 0xF
    dev.write32(REG_VA_TURBO_LEVEL, 0x109)
    assert dev.read32(REG_VA_TURBO_LEVEL) == 9
    assert (dev.read32(REG_VA_TURBO_LEVEL) >> 8) & 0xF == 0
    assert dev.read32(PMU_VA_TURBO_LEVEL) == 0
    dev.write32(REG_VA_TURBO_WINDOW, 1)
    dev.write32(REG_VA_TURBO_LEVEL, 0x109)
    assert dev.read32(REG_VA_TURBO_WINDOW) == 0
    dev.write32(REG_VA_TURBO_WINDOW, 1)
    dev.stage_tensor("A", [[1, 2], [3, 4]])
    dev.stage_tensor("B", [[5, 6], [7, 8]])
    dev.write32(DOORBELL, 1 << 8)
    assert dev.get_tensor("C") == [[19, 22], [43, 50]]
    assert dev.read32(PMU_VA_TURBO_LEVEL) == 9
    assert (dev.read32(PMU_VA_TURBO_LEVEL) >> 8) & 0xF == 0
    assert dev.read32(PMU_VA_TURBO_WINDOW) == 1
    dev.write32(REG_VA_TURBO_LEVEL, 1)
    assert dev.read32(REG_VA_TURBO_LEVEL) == 1
    assert dev.read32(REG_VA_TURBO_WINDOW) == 0
    assert dev.read32(PMU_VA_TURBO_LEVEL) == 9
    dev.write32(DOORBELL, 2 << 8)
    assert dev.get_tensor("C") == [[19, 22], [43, 50]]
    assert dev.read32(PMU_VA_TURBO_LEVEL) == 1
    assert dev.read32(PMU_VA_TURBO_WINDOW) == 0
