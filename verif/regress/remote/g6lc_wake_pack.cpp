// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "Vg6lc_wake_pack.h"

#include <chrono>
#include <cstdint>
#include <cstdio>

int main() {
    Vg6lc_wake_pack m;
    uint64_t x = 1234567;
    const auto next = [&]() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        return x;
    };
    for (unsigned i = 0; i < 8192; ++i) {
        m.valid = next();
        m.veto = next();
        m.allow_low = i & 1;
        m.eval();
        uint64_t expected = 0;
        unsigned reverse = 0;
        for (unsigned k = 0; k < 56; ++k) {
            if ((m.valid >> (k+2) & 1) && (m.allow_low || !(m.veto >> (k+5) & 1)))
                expected |= UINT64_C(1) << k;
        }
        for (unsigned k = 0; k < 16; ++k) {
            if ((m.valid >> k & 1) && (m.allow_low || !(m.veto >> (15-k) & 1)))
                reverse |= 1U << k;
        }
        if (expected != m.ready || reverse != m.swapped) return 1;
    }
    uint64_t h = 0;
    constexpr unsigned n = 4000000;
    const auto start = std::chrono::steady_clock::now();
    for (unsigned i = 0; i < n; ++i) {
        m.valid += UINT64_C(0x9e3779b97f4a7c15);
        m.veto ^= m.valid;
        m.allow_low = i & 1;
        m.eval();
        h = 33*h + m.ready + m.swapped;
    }
    const double sec = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::printf("%.3f M eval/s checksum=%llx\n", n/(sec*1e6), static_cast<unsigned long long>(h));
    m.final();
}
