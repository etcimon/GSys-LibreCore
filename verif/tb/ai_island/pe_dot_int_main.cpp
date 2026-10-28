// SPDX-License-Identifier: MIT
// Copyright 2026 Etienne Cimon
// Direct C++ stimulus avoids the stale unpacked-array stimulus in the old SV
// leaf fixture. One independent integer oracle checks both dot implementations.
#ifdef PE_DOT_PIPE
#include "Vg6lc_ai_pe_dot_pipe.h"
using DotModel = Vg6lc_ai_pe_dot_pipe;
#ifndef PE_DOT_PIPE_EXTRA
#define PE_DOT_PIPE_EXTRA 6
#endif
#else
#include "Vg6lc_ai_pe_dot.h"
using DotModel = Vg6lc_ai_pe_dot;
#endif
#include "verilated.h"
#include <cstdint>
#include <deque>
#include <iostream>
#include <random>
#include <stdexcept>
#include <utility>

static int signed_bits(unsigned x, unsigned width) {
    const unsigned modulus = 1U << width;
    x &= modulus - 1;
    return x & (modulus >> 1) ? int(x) - int(modulus) : int(x);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    DotModel dut;
    const unsigned lanes = sizeof(dut.a_i) / sizeof(dut.a_i[0]);
    std::mt19937 rng(0x67363139);
    uint64_t checked = 0;
    try {
#ifdef PE_DOT_PIPE
        unsigned levels = 0;
        while ((1U << levels) < lanes) ++levels;
        const unsigned latency = levels + PE_DOT_PIPE_EXTRA;
        uint64_t cycle = 0;
        std::deque<std::pair<uint64_t, uint32_t>> expected;
        auto tick = [&]() {
            dut.clk_i = 0; dut.eval();
            dut.clk_i = 1; dut.eval();
            ++cycle;
            const bool due = !expected.empty() && expected.front().first == cycle;
            if (bool(dut.valid_o) != due)
                throw std::runtime_error("valid/latency mismatch at cycle " + std::to_string(cycle));
            if (due) {
                if (dut.sum_o != expected.front().second)
                    throw std::runtime_error("sum mismatch at cycle " + std::to_string(cycle));
                expected.pop_front();
                ++checked;
            }
        };
        auto reset = [&]() {
            dut.rst_ni = 0;
            dut.start_i = 0;
            expected.clear();
            for (unsigned i = 0; i < 3; ++i) tick();
            dut.rst_ni = 1;
        };
        reset();
#endif
        const unsigned trials = lanes == 1 ? 65536 + 10000 : 12000;
        for (unsigned t = 0; t < trials; ++t) {
#ifdef PE_DOT_PIPE
            if (t == trials - 5000) reset();  // discard a partially occupied pipe
#endif
            const bool exhaustive = lanes == 1 && t < 65536;
            const bool int4 = !exhaustive && (rng() & 1);
            dut.numfmt_i = int4 ? 1 : 0;
            int64_t sum = 0;
            for (unsigned l = 0; l < lanes; ++l) {
                const unsigned a = exhaustive ? t >> 8 : rng() & 255;
                const unsigned b = exhaustive ? t & 255 : rng() & 255;
                const bool live = exhaustive || (t % 17 != 0 && (rng() & 1));
                dut.a_i[l] = a;
                dut.b_i[l] = b;
                dut.valid_i[l] = live;
                if (live) {
                    sum += int4
                        ? signed_bits(a, 4) * signed_bits(b, 4) +
                          signed_bits(a >> 4, 4) * signed_bits(b >> 4, 4)
                        : signed_bits(a, 8) * signed_bits(b, 8);
                }
            }
            const uint32_t want = uint32_t(sum);
#ifdef PE_DOT_PIPE
            dut.start_i = exhaustive || (rng() % 4 != 0);
            if (dut.start_i) expected.emplace_back(cycle + latency, want);
            tick();
#else
            dut.eval();
            if (dut.sum_o != want)
                throw std::runtime_error("combinational sum mismatch at vector " + std::to_string(t));
            ++checked;
#endif
        }
#ifdef PE_DOT_PIPE
        dut.start_i = 0;
        for (unsigned i = 0; i < latency + 2; ++i) tick();
        if (!expected.empty()) throw std::runtime_error("undrained results");
        std::cout << "PASS pe_dot_int pipeline lanes=" << lanes << " latency=" << latency;
#else
        std::cout << "PASS pe_dot_int combinational lanes=" << lanes;
#endif
        std::cout << " checked=" << checked << " seed=0x67363139\n";
        dut.final();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL pe_dot_int " << e.what() << '\n';
        return 1;
    }
}
