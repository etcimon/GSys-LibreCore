# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Wait-policy names (mirror Rust WaitPolicy) for docs / future native bindings.

``DMA_THEN_CLAIM`` observes the completion word, then uses the FIFO status.
The word is stored before the write response, so its status can still be 0,
or the store can be discarded, while the FIFO says ``ST_ERR``.
"""

from __future__ import annotations

import copy
from enum import Enum
from typing import Any, Optional, Tuple


FLAG_REUSE_B = 1 << 15
FLAG_REUSE_A = 1 << 23
REG_REUSE_EPOCH = 0x0F00


class OperandReuse:
    """Exact operand reuse. Off until :meth:`set_enabled`.

    A hit multiplies the captured image. The key is
    ``(pointer, rows, k, leading dimension, format, epoch)``.
    ``rows`` is M for A and N for B. A range that meets C drops that key.
    """

    def __init__(self) -> None:
        self.enabled = False
        self.epoch = 0
        self.last_read_a = True
        self.last_read_b = True
        self._a: Optional[Tuple[tuple, Any]] = None
        self._b: Optional[Tuple[tuple, Any]] = None
        self._pending_a: Any = _UNSET
        self._pending_b: Any = _UNSET

    def set_enabled(self, on: bool) -> None:
        self.enabled = bool(on)
        if not self.enabled:
            self._a = None
            self._b = None

    def drop_both(self) -> None:
        self._a = None
        self._b = None

    def bind(
        self,
        side: str,
        flag: bool,
        key: tuple,
        data: Any,
        disjoint: bool = True,
    ) -> Tuple[bool, Any]:
        """Return ``(read_from_caller, image)`` for one operand."""
        if side not in ("a", "b"):
            raise ValueError(f"side must be 'a' or 'b', got {side!r}")
        if not self.enabled:
            self._mark(side, True)
            return True, data
        resident = self._a if side == "a" else self._b
        full = tuple(key) + (self.epoch & 0xFFFFFFFF,)
        hit = bool(flag) and disjoint and resident is not None and resident[0] == full
        image = resident[1] if hit else data
        self._mark(side, not hit)
        pending = None if not disjoint else (full, image)
        if side == "a":
            self._pending_a = pending
        else:
            self._pending_b = pending
        return (not hit), image

    def finish(self, ok: bool) -> None:
        """Install the images from the last :meth:`bind` calls."""
        if not self.enabled:
            return
        if not ok:
            self.drop_both()
            self._pending_a = _UNSET
            self._pending_b = _UNSET
            return
        if self._pending_a is not _UNSET:
            self._a = _freeze(self._pending_a)
        if self._pending_b is not _UNSET:
            self._b = _freeze(self._pending_b)
        self._pending_a = _UNSET
        self._pending_b = _UNSET

    def _mark(self, side: str, read: bool) -> None:
        if side == "a":
            self.last_read_a = read
        else:
            self.last_read_b = read


_UNSET = object()


def _freeze(pending: Optional[Tuple[tuple, Any]]) -> Optional[Tuple[tuple, Any]]:
    if pending is None:
        return None
    key, image = pending
    return key, copy.deepcopy(image)


class ReuseLease:
    """Epoch lease for the directed VaTurbo test island.

    ``invalidate`` advances the epoch after a writer touches A or B.
    Hardware does not snoop that write. The live stream does not use this.
    """

    def __init__(self, epoch: int = 0) -> None:
        self.epoch = int(epoch) & 0xFFFFFFFF

    def invalidate(self) -> int:
        self.epoch = (self.epoch + 1) & 0xFFFFFFFF
        return self.epoch


VA_TURBO_LEVEL_MAX = 15
VA_TURBO_PPM_SAT = 1_000_000


def va_turbo_budget_ppm(level: int):
    """Geometric ppm ladder. Level 0 is exact. The datapath does not apply it."""
    from ai_tensor.va_turbo import budget_ppm

    try:
        return budget_ppm(level)
    except ValueError:
        return None


def va_turbo_error_bound_q4(ppm: int):
    """Round up onto the ladder. A bound above 100% is ``None``, not level 15."""
    from ai_tensor.va_turbo import error_budget_level

    try:
        return error_budget_level(ppm)
    except ValueError:
        return None


def va_turbo_level_within_bound(level: int, caller_ppm: int) -> bool:
    budget = va_turbo_budget_ppm(level)
    bound = va_turbo_error_bound_q4(caller_ppm)
    if budget is None or bound is None:
        return False
    return level <= bound


def va_turbo_applied_level(level: int) -> int:
    del level
    return 0


REG_VA_TURBO_LEVEL = 0x0F04
PMU_VA_TURBO_LEVEL = 0x0F08
VA_TURBO_LEVEL_APPLIED_SHIFT = 8


def va_turbo_level_word(requested: int) -> int:
    """Low 4 bits of the request. The applied nibble is 0."""
    if isinstance(requested, bool) or not isinstance(requested, int):
        raise ValueError(f"requested level must be an int, got {requested!r}")
    if requested < 0:
        raise ValueError("requested level must be non-negative")
    return requested & 0xF


REG_VA_TURBO_RECIPE = 0x0F0C
PMU_VA_TURBO_RECIPE = 0x0F10
VA_TURBO_RECIPE_APPLIED_SHIFT = 8


def va_turbo_recipe_word(requested: int) -> int:
    """Low 5 bits of the recipe id. The applied id is 0."""
    if isinstance(requested, bool) or not isinstance(requested, int):
        raise ValueError(f"recipe id must be an int, got {requested!r}")
    if requested < 0:
        raise ValueError("recipe id must be non-negative")
    return requested & 0x1F


def va_turbo_recipe_applied(word: int) -> int:
    """Applied recipe id. The register keeps this at 0."""
    if isinstance(word, bool) or not isinstance(word, int):
        raise ValueError(f"recipe word must be an int, got {word!r}")
    return (word >> VA_TURBO_RECIPE_APPLIED_SHIFT) & 0x1F


def va_turbo_level_applied(word: int) -> int:
    """Applied level from a level word. The register keeps this at 0."""
    if isinstance(word, bool) or not isinstance(word, int):
        raise ValueError(f"level word must be an int, got {word!r}")
    return (word >> VA_TURBO_LEVEL_APPLIED_SHIFT) & 0xF


class EvidenceWindow:
    """Caller-owned evidence window. A mismatch clears the claim.

    The device also clears its bit when the epoch, level, or recipe
    register is written. This object covers tensor identity, numeric
    format, and the approval profile. A level the budget rejects cannot
    arm the claim. A recipe whose analytic bound does not fit that level
    cannot arm it either. Neither one changes the product.
    """

    def __init__(self) -> None:
        self.level = 0
        self.recipe = 0
        self.epoch = 0
        self.identity = 0
        self.format = 0
        self.profile = 0
        self.valid = False

    def commit(
        self,
        level: int,
        recipe: int,
        epoch: int,
        identity: int,
        format: int,
        profile: int,
        measured_ppm: Optional[int] = None,
        kappa_q8: Optional[int] = None,
        approx_param: Optional[int] = None,
    ) -> bool:
        from ai_tensor.va_turbo import recipe_claim_fits

        if (
            isinstance(recipe, bool)
            or isinstance(format, bool)
            or not isinstance(recipe, int)
            or not isinstance(format, int)
            or recipe < 0
            or recipe > 31
            or format < 0
            or format > 7
            or not recipe_claim_fits(level, recipe, measured_ppm, kappa_q8, approx_param)
        ):
            self.valid = False
            return False
        self.level = int(level)
        self.recipe = recipe
        self.epoch = int(epoch) & 0xFFFFFFFF
        self.identity = int(identity)
        self.format = format
        self.profile = int(profile)
        self.valid = True
        return True

    def observe(
        self,
        level: int,
        recipe: int,
        epoch: int,
        identity: int,
        format: int,
        profile: int,
    ) -> bool:
        same = (
            self.valid
            and self.level == int(level)
            and self.recipe == int(recipe)
            and self.epoch == (int(epoch) & 0xFFFFFFFF)
            and self.identity == int(identity)
            and self.format == int(format)
            and self.profile == int(profile)
        )
        if not same:
            self.valid = False
        return same


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
