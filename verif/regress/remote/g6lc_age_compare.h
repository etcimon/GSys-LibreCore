// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#ifndef G6LC_AGE_COMPARE_H
#define G6LC_AGE_COMPARE_H

#include <cstdint>
#if defined(__AVX512VL__) && defined(__AVX512BW__)
#include <immintrin.h>
#endif

namespace g6lc_age {

// Exact circular age comparison for unsigned indices modulo (Mask + 1):
// Equivalent to (((a < cp) == (b < cp)) ? (a < b) : (b < cp)) for a,b,cp in [0, Mask].
template <uint32_t Mask>
inline uint8_t older(uint32_t a, uint32_t b, uint32_t cp) {
    return static_cast<uint8_t>((((a - cp) & Mask) < ((b - cp) & Mask)) ? 1U : 0U);
}

// 32-lane vectorized circular age compare (Mask <= 0x7fU, e.g. 0x3fU).
template <uint32_t Mask>
inline uint32_t older32_u8(const uint8_t* a, const uint8_t* b, uint32_t cp) {
#if defined(__AVX512VL__) && defined(__AVX512BW__)
    const __m256i vcp = _mm256_set1_epi8(static_cast<char>(cp & Mask));
    const __m256i vm  = _mm256_set1_epi8(static_cast<char>(Mask));
    const __m256i ka  = _mm256_and_si256(
        _mm256_sub_epi8(_mm256_loadu_si256(reinterpret_cast<const __m256i*>(a)), vcp), vm);
    const __m256i kb  = _mm256_and_si256(
        _mm256_sub_epi8(_mm256_loadu_si256(reinterpret_cast<const __m256i*>(b)), vcp), vm);
    return static_cast<uint32_t>(_mm256_cmplt_epu8_mask(ka, kb));
#else
    uint32_t out = 0U;
    for (unsigned i = 0; i < 32U; ++i) {
        out |= static_cast<uint32_t>(older<Mask>(a[i], b[i], cp)) << i;
    }
    return out;
#endif
}

template <uint32_t Mask>
inline uint32_t older32_const_a(uint32_t a, const uint8_t* b, uint32_t cp) {
#if defined(__AVX512VL__) && defined(__AVX512BW__)
    const __m256i ka  = _mm256_set1_epi8(static_cast<char>((a - cp) & Mask));
    const __m256i vcp = _mm256_set1_epi8(static_cast<char>(cp & Mask));
    const __m256i vm  = _mm256_set1_epi8(static_cast<char>(Mask));
    const __m256i kb  = _mm256_and_si256(
        _mm256_sub_epi8(_mm256_loadu_si256(reinterpret_cast<const __m256i*>(b)), vcp), vm);
    return static_cast<uint32_t>(_mm256_cmplt_epu8_mask(ka, kb));
#else
    uint32_t out = 0U;
    for (unsigned i = 0; i < 32U; ++i) {
        out |= static_cast<uint32_t>(older<Mask>(a, b[i], cp)) << i;
    }
    return out;
#endif
}

// 64-bit mask where bit k in [0..63] is 1 iff older<0x3fU>(k, b, cp).
inline uint64_t mask64(uint32_t b, uint32_t cp) {
    const uint32_t c = cp & 63U;
    const uint32_t d = (b - c) & 63U;
    if (!d) return 0ULL;
    const uint64_t raw = (1ULL << d) - 1ULL;
    return c ? ((raw << c) | (raw >> (64U - c))) : raw;
}

// Scatter-OR equality bitmask: bit t in [0..63] is 1 iff exists s in [0..N-1]
// with ((mask >> s) & 1) && (extract(eid_words, BaseBit + s*BitStride, Width) == t).
template <unsigned N, unsigned Width, unsigned BaseBit, unsigned BitStride>
inline uint64_t scatter_eq64(uint32_t mask, const uint32_t* eid_words) {
    uint64_t out = 0ULL;
    const uint32_t valid_mask = (N >= 32U) ? 0xffffffffU : ((1U << N) - 1U);
    uint32_t m = mask & valid_mask;
    const uint32_t wmask = (1U << Width) - 1U;
    while (m) {
        const unsigned s = static_cast<unsigned>(__builtin_ctz(m));
        m &= (m - 1U);
        const unsigned bit = BaseBit + s * BitStride;
        const unsigned w = bit >> 5U;
        const unsigned sh = bit & 31U;
        const uint32_t val = (sh + Width <= 32U)
            ? ((eid_words[w] >> sh) & wmask)
            : (((eid_words[w] >> sh) | (eid_words[w + 1U] << (32U - sh))) & wmask);
        out |= (1ULL << val);
    }
    return out;
}

}  // namespace g6lc_age
#endif
