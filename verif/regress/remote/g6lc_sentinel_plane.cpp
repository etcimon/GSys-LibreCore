// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Isolated SV idiom: concatenate the high bit of each of 64 contiguous bytes.
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
# include <immintrin.h>
# define G6LC_X86 1
#endif

using Row = std::array<uint8_t, 64>;
using Kernel = uint64_t (*)(const Row&);

static uint64_t portable(const Row& r) {
    uint64_t out = 0;
    for (unsigned j = 0; j < 64; ++j) out |= uint64_t(r[j] >> 7) << j;
    return out;
}

#ifdef G6LC_X86
__attribute__((target("bmi2"))) static uint64_t extract(const Row& r) {
    uint64_t out = 0;
    for (unsigned i = 0; i < 8; ++i) {
        uint64_t word;
        std::memcpy(&word, &r[8*i], sizeof(word));
        out |= _pext_u64(word, 0x8080808080808080ULL) << (8*i);
    }
    return out;
}
__attribute__((target("avx2"))) static uint64_t two_masks(const Row& r) {
    const auto* p = reinterpret_cast<const __m256i*>(r.data());
    return uint32_t(_mm256_movemask_epi8(_mm256_loadu_si256(p)))
           | (uint64_t(uint32_t(_mm256_movemask_epi8(_mm256_loadu_si256(p+1)))) << 32);
}
__attribute__((target("avx512bw,avx512f"))) static uint64_t byte_mask(const Row& r) {
    return _mm512_movepi8_mask(_mm512_loadu_si512(r.data()));
}
#endif

static bool run(const char* name, Kernel fn, const std::array<Row, 64>& rows) {
    for (unsigned i = 0; i < 64*8; ++i) {
        Row one{};
        one[i/8] = uint8_t(1U << (i%8));
        if (fn(one) != (i%8 == 7 ? uint64_t(1) << (i/8) : 0)) return false;
    }
    for (const Row& r : rows) if (fn(r) != portable(r)) return false;
    constexpr unsigned n = 2000000;
    uint64_t sum = 0;
    const auto begin = std::chrono::steady_clock::now();
    for (unsigned i = 0; i < n; ++i) sum += fn(rows[i%64]);
    const double dt = std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
    std::printf("%s %.3f Mrows/s checksum=%llx\n", name, n / (dt * 1e6),
                static_cast<unsigned long long>(sum));
    return true;
}

int main() {
    std::array<Row, 64> rows;
    uint32_t seed = 17;
    for (auto& r : rows) for (auto& b : r) {
        seed = seed * 1664525U + 1013904223U;
        b = uint8_t(seed >> 24);
    }
    if (!run("portable", portable, rows)) return 1;
#ifdef G6LC_X86
    if (__builtin_cpu_supports("bmi2") && !run("bmi2", extract, rows)) return 1;
    if (__builtin_cpu_supports("avx2") && !run("avx2", two_masks, rows)) return 1;
    if (__builtin_cpu_supports("avx512bw") && __builtin_cpu_supports("avx512f")
        && !run("avx512bw", byte_mask, rows)) return 1;
#endif
}
