// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "Vg6lc_byte_plane.h"

#include <chrono>
#include <cstdint>
#include <cstdio>

static bool check(Vg6lc_byte_plane& m) {
    m.eval();
    uint64_t expect = 0;
    unsigned reverse = 0, mixed = 0;
    for (unsigned j = 0; j < 8; ++j) {
        for (unsigned p = 0; p < 8; ++p) {
            expect |= ((m.row >> (8*j + p)) & UINT64_C(1)) << (8*p + j);
        }
        reverse |= ((m.other >> (8*j)) & 1) << (7-j);
        mixed |= (((j == 3 ? m.row : m.other) >> (8*j + 1)) & 1) << j;
    }
    if (m.planes == expect && m.reversed_plane == reverse && m.mixed_plane == mixed) return true;
    std::fprintf(stderr, "row=%llx got=%llx expected=%llx reverse=%u/%u mixed=%u/%u\n",
                 static_cast<unsigned long long>(m.row), static_cast<unsigned long long>(m.planes),
                 static_cast<unsigned long long>(expect), unsigned(m.reversed_plane), reverse,
                 unsigned(m.mixed_plane), mixed);
    return false;
}

int main() {
    Vg6lc_byte_plane m;
    for (unsigned v = 0; v < 256; ++v) {
        for (unsigned p = 0; p < 8; ++p) {
            m.row = ~(UINT64_C(0x0101010101010101) << p);
            for (unsigned j = 0; j < 8; ++j) m.row |= uint64_t((v >> j) & 1) << (8*j + p);
            m.other = ~m.row;
            if (!check(m)) return 1;
        }
    }
    uint64_t h = 0;
    constexpr unsigned n = 4000000;
    const auto start = std::chrono::steady_clock::now();
    for (unsigned i = 0; i < n; ++i) {
        m.row += UINT64_C(0x9e3779b97f4a7c15);
        m.other ^= m.row;
        m.eval();
        h = 33*h + m.planes + m.reversed_plane + m.mixed_plane;
    }
    const double time = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::printf("%.3f M eval/s %llx\n", n / (time * 1e6), static_cast<unsigned long long>(h));
    m.final();
}
