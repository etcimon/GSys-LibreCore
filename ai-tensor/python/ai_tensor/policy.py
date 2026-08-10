# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Wait-policy names (mirror Rust WaitPolicy) for docs / future native bindings."""

from __future__ import annotations

from enum import Enum


class WaitPolicy(str, Enum):
    POLL = "poll"
    IRQ_THEN_POLL = "irq_then_poll"
    DMA_THEN_CLAIM = "dma_then_claim"
    CLAIM_ONLY = "claim_only"


def recommend_policy(*, wr_cpl_en: bool, irq: bool, ptr_done: int = 0) -> WaitPolicy:
    if irq:
        return WaitPolicy.IRQ_THEN_POLL
    if wr_cpl_en and ptr_done != 0:
        return WaitPolicy.DMA_THEN_CLAIM
    return WaitPolicy.POLL
