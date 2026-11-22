// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#ifndef G6LC_NATIVE_ISA_H
#define G6LC_NATIVE_ISA_H
// Checked with the effective flags on each native compile (including PGO use).
#if !defined(__AVX512F__) || !defined(__AVX512BW__) || !defined(__AVX512CD__) \
    || !defined(__AVX512DQ__) || !defined(__AVX512VL__) || !defined(__BMI2__) \
    || !defined(VL_SIMD_PREFER_512)
#error "Hyp8 native profile requires AVX-512F/BW/CD/DQ/VL, BMI2 and VL_SIMD_PREFER_512"
#endif
#endif
