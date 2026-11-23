// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "Vg6lc_lsq_reduce.h"
#include <chrono>
#include <cstdint>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc != 2 || (argv[1][0] != 'z' && argv[1][0] != 'd')) return 2;
    Verilated::commandArgs(argc, argv);
    Vg6lc_lsq_reduce m;
    uint64_t seed = 714283;
    auto next = [&]() { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed; };
    constexpr uint64_t mask = (UINT64_C(1) << 40) - 1;
    auto cycle = [&]() { m.clk_i = 0; m.eval(); m.clk_i = 1; m.eval(); };
    m.rst_ni = 0;
    cycle();
    m.rst_ni = 1;
    m.flush_i = 0;
    m.older_i = mask;
    uint64_t last = 0;
    for (unsigned i = 0; i < 8192; ++i) {
        for (unsigned w = 0; w < 50; ++w) m.age_i[w] = next() & next() & next();
        m.match_i = i%4 == 0 ? 0 : i%4 == 1 ? UINT64_C(1) << (i%40) : next() & mask;
        m.flush_i = i%113 == 0;
        uint64_t win = 0;
        for (unsigned c = 0; c < 40 && !win; ++c) {
            if (!((m.match_i >> c) & 1)) continue;
            bool blocked = false;
            for (unsigned r = 0; r < 40; ++r) {
                const unsigned b = 40*r+c;
                blocked |= (m.match_i >> r) & (m.age_i[b/32] >> (b%32)) & 1;
            }
            if (!blocked) win = UINT64_C(1) << c;
        }
        cycle();
        const uint64_t expected = m.flush_i ? 0 : last;
        if (m.win_leaf_o != expected || m.win_valid_o != !!expected) {
            std::fprintf(stderr, "winner mismatch at cycle %u\n", i);
            return 1;
        }
        last = m.flush_i ? 0 : win;
    }
    m.flush_i = 0;
    const auto start = std::chrono::steady_clock::now();
    uint64_t sum = 0;
    for (unsigned i = 0; i < 1000000; ++i) {
        const uint64_t x = next();
        m.age_i[i%50] = uint32_t(x & (x >> 20) & (x >> 32));
        m.match_i = argv[1][0] == 'z' ? ((i%128) ? 0 : UINT64_C(1) << (x%40)) : (x & mask);
        cycle();
        sum += m.win_leaf_o;
    }
    const double sec = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::printf("%.3f M reducer cycles/s checksum=%llx\n", 1/sec, static_cast<unsigned long long>(sum));
    m.final();
}
