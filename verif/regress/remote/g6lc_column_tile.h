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

// Arbitrary bit-stride byte extract: 8 consecutive bits starting at bitPos.
// Caller proves bitPos + 7 is strictly inside the backing VlWide word array.
inline uint8_t load_byte_at_bit(const uint32_t* p, uint64_t bitPos) {
    const uint64_t w = bitPos >> 5U;
    const unsigned sh = static_cast<unsigned>(bitPos & 31U);
    if (sh <= 24U) return static_cast<uint8_t>((p[w] >> sh) & 0xffU);
    return static_cast<uint8_t>(((p[w] >> sh) | (p[w + 1U] << (32U - sh))) & 0xffU);
}

// Arbitrary bit-stride 32-bit extract: 32 consecutive bits starting at bitPos.
// Caller proves bitPos + 31 is strictly inside the backing VlWide word array.
inline uint32_t load_u32_at_bit(const uint32_t* p, uint64_t bitPos) {
    const uint64_t w = bitPos >> 5U;
    const unsigned sh = static_cast<unsigned>(bitPos & 31U);
    if (sh == 0U) return p[w];
    return (p[w] >> sh) | (p[w + 1U] << (32U - sh));
}

// Eight rows at arbitrary bit stride -> eight 8-bit transposed column planes.
template <uint64_t StartBit, uint64_t StrideBits>
inline uint64_t octet_bits(const uint32_t* p) {
    uint64_t x = 0;
    for (unsigned j = 0; j < 8U; ++j) {
        x |= uint64_t(load_byte_at_bit(p, StartBit + uint64_t(j) * StrideBits)) << (8U * j);
    }
    uint64_t t = (x ^ (x >> 7U)) & 0x00aa00aa00aa00aaULL;
    x ^= t ^ (t << 7U);
    t = (x ^ (x >> 14U)) & 0x0000cccc0000ccccULL;
    x ^= t ^ (t << 14U);
    t = (x ^ (x >> 28U)) & 0x00000000f0f0f0f0ULL;
    return x ^ t ^ (t << 28U);
}

// 64 rows at arbitrary constant bit stride -> eight 64-bit transposed columns.
#if defined(__AVX512BW__)
struct Tile64 { __m512i bytes; };

inline Tile64 load_tile64(const uint8_t* buf) {
    return {_mm512_load_si512(reinterpret_cast<const void*>(buf))};
}

template <uint64_t StartBit, uint64_t StrideBits>
inline Tile64 gather_bits64(const uint32_t* p) {
    alignas(64) uint8_t buf[64];
    for (unsigned j = 0; j < 64U; ++j) {
        buf[j] = load_byte_at_bit(p, StartBit + uint64_t(j) * StrideBits);
    }
    return load_tile64(buf);
}

template <int Bit>
inline uint64_t column64(const Tile64& t) {
    return static_cast<uint64_t>(_mm512_movepi8_mask(_mm512_slli_epi16(t.bytes, 7 - Bit)));
}
#elif defined(__AVX2__)
struct Tile64 { __m256i lo; __m256i hi; };

inline Tile64 load_tile64(const uint8_t* buf) {
    return {
        _mm256_load_si256(reinterpret_cast<const __m256i*>(buf)),
        _mm256_load_si256(reinterpret_cast<const __m256i*>(buf + 32)),
    };
}

template <uint64_t StartBit, uint64_t StrideBits>
inline Tile64 gather_bits64(const uint32_t* p) {
    alignas(32) uint8_t buf[64];
    for (unsigned j = 0; j < 64U; ++j) {
        buf[j] = load_byte_at_bit(p, StartBit + uint64_t(j) * StrideBits);
    }
    return load_tile64(buf);
}

template <int Bit>
inline uint64_t column64(const Tile64& t) {
    const uint64_t l = static_cast<uint32_t>(_mm256_movemask_epi8(_mm256_slli_epi16(t.lo, 7 - Bit)));
    const uint64_t h = static_cast<uint32_t>(_mm256_movemask_epi8(_mm256_slli_epi16(t.hi, 7 - Bit)));
    return l | (h << 32U);
}
#else
struct Tile64 { uint64_t octets[8]; };

inline Tile64 load_tile64(const uint8_t* buf) {
    Tile64 r;
    for (unsigned g = 0; g < 8U; ++g) {
        uint64_t x = 0;
        for (unsigned j = 0; j < 8U; ++j) {
            x |= uint64_t(buf[8U * g + j]) << (8U * j);
        }
        uint64_t t = (x ^ (x >> 7U)) & 0x00aa00aa00aa00aaULL;
        x ^= t ^ (t << 7U);
        t = (x ^ (x >> 14U)) & 0x0000cccc0000ccccULL;
        x ^= t ^ (t << 14U);
        t = (x ^ (x >> 28U)) & 0x00000000f0f0f0f0ULL;
        r.octets[g] = x ^ t ^ (t << 28U);
    }
    return r;
}

template <uint64_t StartBit, uint64_t StrideBits>
inline Tile64 gather_bits64(const uint32_t* p) {
    alignas(64) uint8_t buf[64];
    for (unsigned j = 0; j < 64U; ++j) {
        buf[j] = load_byte_at_bit(p, StartBit + uint64_t(j) * StrideBits);
    }
    return load_tile64(buf);
}

template <int Bit>
inline uint64_t column64(const Tile64& t) {
    uint64_t out = 0;
    for (unsigned g = 0; g < 8U; ++g) {
        out |= ((t.octets[g] >> (Bit * 8)) & 255ULL) << (g * 8U);
    }
    return out;
}
#endif

// Batched 4-byte (32-column) arbitrary-bit-stride gather: 1 load_u32_at_bit per row.
struct Tile64x4 { Tile64 t[4]; };

template <uint64_t StartBit, uint64_t StrideBits>
inline Tile64x4 gather_bits64_x4(const uint32_t* p) {
    alignas(64) uint8_t b0[64], b1[64], b2[64], b3[64];
    for (unsigned j = 0; j < 64U; ++j) {
        const uint32_t v = load_u32_at_bit(p, StartBit + uint64_t(j) * StrideBits);
        b0[j] = static_cast<uint8_t>(v);
        b1[j] = static_cast<uint8_t>(v >> 8U);
        b2[j] = static_cast<uint8_t>(v >> 16U);
        b3[j] = static_cast<uint8_t>(v >> 24U);
    }
    return {{load_tile64(b0), load_tile64(b1), load_tile64(b2), load_tile64(b3)}};
}
}  // namespace g6lc_column
#endif
