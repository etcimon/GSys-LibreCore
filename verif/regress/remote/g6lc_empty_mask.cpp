// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "Vg6lc_empty_mask.h"
#include <chrono>
#include <cstdint>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc != 2 || (argv[1][0] != 'z' && argv[1][0] != 'd')) return 2;
    Vg6lc_empty_mask m;
    uint64_t seed = 6789;
    constexpr uint64_t mask = (UINT64_C(1) << 40) - 1;
    auto next = [&]() { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed; };
    for (unsigned i = 0; i < 4096; ++i) {
        for (unsigned w = 0; w < 50; ++w) m.columns[w] = next() & next();
        m.cand = (i%3 == 0 ? 0 : i%3 == 1 ? UINT64_C(1) << (i%40) : next() & mask);
        m.eval();
        uint64_t expected = m.cand;
        for (unsigned c = 0; c < 40; ++c) for (unsigned r = 0; r < 40; ++r) {
            const unsigned b = 40*c+r;
            if ((m.cand >> r) & (m.columns[b/32] >> (b%32)) & 1)
                expected &= ~(UINT64_C(1) << c);
        }
        if (m.winner != expected) return 1;
    }
    uint64_t sum = 0;
    const auto start = std::chrono::steady_clock::now();
    for (unsigned i = 0; i < 4000000; ++i) {
        const uint64_t x = next();
        m.columns[i%50] ^= uint32_t(x);
        m.cand = argv[1][0] == 'z' && (i%128) ? 0 : x & mask;
        m.eval();
        sum += m.winner;
    }
    const auto sec = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::printf("%.3f M eval/s sum=%llx\n", 4/sec, static_cast<unsigned long long>(sum));
    m.final();
}
