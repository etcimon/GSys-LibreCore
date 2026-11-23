// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "Vg6lc_masked_row_bench.h"

#include <chrono>
#include <cstdint>
#include <cstdio>

int main() {
    struct Vector {
        uint32_t src[50];
        uint32_t enables;
    } vectors[256];
    uint32_t r = 42;
    for (int i = 0; i < 256; ++i) {
        for (auto& v : vectors[i].src) v = r = r * 1664525u + 1013904223u;
        vectors[i].enables = i * 0x01010101u;  // Exhaust all zero/one/multi-hit masks per row.
        vectors[i].enables ^= 0xf05a9900u;
    }
    VerilatedContext context;
    context.threads(1);
    Vg6lc_masked_row_bench m{&context};
    const auto eval = [&](const Vector& v) {
        for (int j = 0; j < 50; ++j) m.data_i[j] = v.src[j];
        m.enable_i = v.enables;
        m.eval();
    };
    for (const Vector& v : vectors) {
        eval(v);
        for (int s = 0; s < 4; ++s) {
            for (int bit = 0; bit < 200; ++bit) {
                unsigned expected = 0;
                for (int p = 0; p < 8; ++p) {
                    const int k = 200 * p + bit;
                    expected |= (v.enables >> (8 * s + p)) & (v.src[k / 32] >> (k % 32)) & 1u;
                }
                const int k = 200 * s + bit;
                if (((m.data_o[k / 32] >> (k % 32)) & 1u) != expected) return 1;
            }
        }
    }
    constexpr int count = 500000;
    uint32_t hash = 0;
    const auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < count; ++i) {
        eval(vectors[i % 256]);
        hash = hash * 33u + m.data_o[i % 25];
    }
    const double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("%08x %.0f evaluations/s\n", hash, count / sec);
    m.final();
}
