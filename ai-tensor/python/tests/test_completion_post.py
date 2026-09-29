# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""The completion word and the FIFO follow the same split as the sequencer."""

from ai_tensor.c_abi import ST_ERR, ST_OK, completion_post


def test_a_gemm_error_is_in_the_word_and_the_fifo():
    word, fifo = completion_post(36, ST_ERR, False)
    assert word == (ST_ERR << 32) | 36
    assert fifo == ST_ERR


def test_va_turbo_budget_ladder_does_not_apply():
    from ai_tensor.policy import (
        va_turbo_applied_level,
        va_turbo_budget_ppm,
        va_turbo_error_bound_q4,
        va_turbo_level_within_bound,
    )

    assert va_turbo_budget_ppm(0) == 0
    assert va_turbo_budget_ppm(1) == 100
    assert va_turbo_budget_ppm(5) == 1_600
    assert va_turbo_budget_ppm(8) == 12_800
    assert va_turbo_budget_ppm(15) == 1_000_000
    assert va_turbo_budget_ppm(16) is None
    assert va_turbo_error_bound_q4(1_600) == 5
    assert va_turbo_error_bound_q4(1_601) == 6
    assert va_turbo_level_within_bound(5, 1_600)
    assert not va_turbo_level_within_bound(8, 1_600)
    assert va_turbo_applied_level(8) == 0
    from ai_tensor.va_turbo import compose_ppm, recipe_admitted

    assert compose_ppm(977, 256) == 977
    assert recipe_admitted(5, 977, 256, 1_600)
    assert not recipe_admitted(1, 977, 256, 1_600)
    assert compose_ppm(977, 255) is None
    from ai_tensor.va_turbo import DOC_INT8_PPM, measurement_fits

    assert measurement_fits(0, None)
    assert not measurement_fits(8, None)
    assert not measurement_fits(8, DOC_INT8_PPM)
    assert measurement_fits(9, DOC_INT8_PPM)


def test_va_turbo_level_word_keeps_the_request_and_applied_stays_zero():
    from ai_tensor.policy import (
        PMU_VA_TURBO_LEVEL,
        REG_VA_TURBO_LEVEL,
        va_turbo_level_applied,
        va_turbo_level_word,
    )

    assert REG_VA_TURBO_LEVEL == 0x0F04
    assert PMU_VA_TURBO_LEVEL == 0x0F08
    assert va_turbo_level_word(0x109) == 9
    assert va_turbo_level_word(0xFFFFFFFF) == 15
    assert va_turbo_level_applied(va_turbo_level_word(9)) == 0
    from ai_tensor.policy import (
        PMU_VA_TURBO_RECIPE,
        REG_VA_TURBO_RECIPE,
        va_turbo_recipe_applied,
        va_turbo_recipe_word,
    )

    assert REG_VA_TURBO_RECIPE == 0x0F0C
    assert PMU_VA_TURBO_RECIPE == 0x0F10
    assert va_turbo_recipe_word(0x110) == 0x10
    assert va_turbo_recipe_word(0xFFFFFFFF) == 0x1F
    assert va_turbo_recipe_applied(va_turbo_recipe_word(0x10)) == 0


def test_operand_reuse_keeps_the_resident_image_until_the_epoch_changes():
    from ai_tensor.policy import FLAG_REUSE_B, OperandReuse

    key = (2, 1, 1, 1, 0)
    fresh = OperandReuse()
    read, image = fresh.bind("b", True, key, [[9]])
    fresh.finish(True)
    assert read and image == [[9]]

    reuse = OperandReuse()
    reuse.set_enabled(True)
    read, image = reuse.bind("b", False, key, [[2]])
    reuse.finish(True)
    assert read and image == [[2]]
    read, image = reuse.bind("b", FLAG_REUSE_B, key, [[9]])
    assert not read and image == [[2]]
    reuse.finish(True)
    reuse.epoch = 1
    read, image = reuse.bind("b", FLAG_REUSE_B, key, [[9]])
    assert read and image == [[9]]
    reuse.finish(True)
    read, image = reuse.bind("b", FLAG_REUSE_B, key, [[4]], disjoint=False)
    assert read and image == [[4]]
    reuse.finish(True)
    read, image = reuse.bind("b", FLAG_REUSE_B, key, [[7]])
    assert read and image == [[7]]


def test_an_evidence_window_drops_when_the_identity_changes():
    from ai_tensor.policy import EvidenceWindow
    from ai_tensor.va_turbo import DOC_INT8_PPM

    window = EvidenceWindow()
    assert not window.commit(8, 0x10, 1, 7, 0, 1, DOC_INT8_PPM)
    assert not window.commit(9, 27, 1, 7, 0, 1, DOC_INT8_PPM, 256)
    assert not window.valid
    assert window.commit(9, 0x10, 1, 7, 0, 1, DOC_INT8_PPM)
    assert window.observe(9, 0x10, 1, 7, 0, 1)
    assert not window.observe(9, 0x10, 1, 7, 1, 1)
    assert not window.valid
    assert window.commit(0, 0, 0, 7, 0, 4)
    assert not window.observe(0, 0, 0, 7, 0, 5)
    assert not window.commit(0, 32, 0, 7, 0, 4)


def test_reuse_lease_invalidate_wraps():
    from ai_tensor.policy import ReuseLease

    lease = ReuseLease()
    assert lease.invalidate() == 1
    wrapped = ReuseLease(0xFFFFFFFF)
    assert wrapped.invalidate() == 0


def test_a_completion_beat_error_leaves_the_gemm_word():
    word, fifo = completion_post(42, ST_OK, True)
    assert word == 42
    assert fifo == ST_ERR
