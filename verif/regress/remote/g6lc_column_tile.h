// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#ifndef G6LC_COLUMN_TILE_H
#define G6LC_COLUMN_TILE_H

#include <cstdint>
#if defined(__AVX2__)
#include <immintrin.h>
#endif

namespace g6lc_column {
// Eight strided bytes yield eight column fragments, LSB-first in each byte.
template <unsigned Start, unsigned Stride>
inline uint64_t octet(const uint32_t* p) {
    uint64_t x = 0;
    for (unsigned j = 0; j < 8; ++j) {
        const uint64_t byte = Start + uint64_t(j) * Stride;
        x |= uint64_t((p[byte / 4] >> (8 * (byte % 4))) & 255) << (8 * j);
    }
    uint64_t t = (x ^ (x >> 7)) & 0x00aa00aa00aa00aaULL;
    x ^= t ^ (t << 7);
    t = (x ^ (x >> 14)) & 0x0000cccc0000ccccULL;
    x ^= t ^ (t << 14);
    t = (x ^ (x >> 28)) & 0x00000000f0f0f0f0ULL;
    return x ^ t ^ (t << 28);
}
#if defined(__AVX2__)
struct Tile { __m256i bytes; };

template <int Bit>
inline uint32_t column(const Tile& t) {
    return static_cast<uint32_t>(_mm256_movemask_epi8(_mm256_slli_epi16(t.bytes, 7 - Bit)));
}
#else
struct Tile { uint64_t columns[4]; };

template <int Bit>
inline uint32_t column(const Tile& t) {
    uint32_t result = 0;
    for (unsigned g = 0; g < 4; ++g)
        result |= uint32_t((t.columns[g] >> (Bit * 8)) & 255) << (g * 8);
    return result;
}
#endif

// Read only the 32 words proven in-bounds by the matcher. Number bits
// arithmetically, independent of host endianness and destination layout.
template <int Start, int Stride>
inline Tile gather(const uint32_t* p) {
#if defined(__AVX2__)
    alignas(32) int index[8], shift[8];
    for (int i = 0; i < 8; ++i) {
        index[i] = ((Start % 4) + i * Stride) / 4;
        shift[i] = ((Start + i * Stride) % 4) * 8;
    }
    __m256i groups[4];
    for (int i = 0; i < 4; ++i) {
        const auto* base = reinterpret_cast<const int*>(p + Start / 4 + i * (2 * Stride));
        const __m256i words = _mm256_i32gather_epi32(
            base, _mm256_load_si256(reinterpret_cast<const __m256i*>(index)), 4);
        groups[i] = _mm256_and_si256(_mm256_srlv_epi32(words, _mm256_load_si256(
            reinterpret_cast<const __m256i*>(shift))), _mm256_set1_epi32(255));
    }
    const __m256i bytes = _mm256_packus_epi16(_mm256_packus_epi32(groups[0], groups[1]),
                                               _mm256_packus_epi32(groups[2], groups[3]));
    // Packs concatenate within 128-bit lanes; restore ascending source-row order.
    return {_mm256_permutevar8x32_epi32(bytes, _mm256_setr_epi32(0, 4, 1, 5, 2, 6, 3, 7))};
#else
    Tile result;
    for (int g = 0; g < 4; ++g) {
        uint64_t x = 0;
        for (int j = 0; j < 8; ++j) {
            const int byte = Start + (8 * g + j) * Stride;
            x |= uint64_t((p[byte / 4] >> (8 * (byte % 4))) & 255) << (8 * j);
        }
        // Transpose each 8x8 bit block by exchanging off-diagonal halves.
        uint64_t t = (x ^ (x >> 7)) & 0x00aa00aa00aa00aaULL;
        x ^= t ^ (t << 7);
        t = (x ^ (x >> 14)) & 0x0000cccc0000ccccULL;
        x ^= t ^ (t << 14);
        t = (x ^ (x >> 28)) & 0x00000000f0f0f0f0ULL;
        result.columns[g] = x ^ t ^ (t << 28);
    }
    return result;
#endif
}
}  // namespace g6lc_column
#endif
