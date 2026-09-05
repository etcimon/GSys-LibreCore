// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

#include "Vtb_g6lc_ai_fp_mac.h"
#include "verilated.h"
#include <array>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#if defined(__SSE__)
#include <xmmintrin.h>
#endif

static uint32_t bits(float value) {
    uint32_t result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
static float floating(uint32_t value) {
    float result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
static uint32_t canonical(uint32_t value) {
    return (value & 0x7fffffffU) > 0x7f800000U ? 0x7fc00000U : value;
}
static std::string hex(uint32_t value) {
    std::ostringstream out;
    out << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return out.str();
}
static void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
struct Widened { uint32_t value; bool snan; bool valid; };
static Widened decode(uint32_t raw, unsigned format) {
    if (format < 3) return {0, false, false};
    if (format == 7) return {raw, false, true};
    if (format == 6) return {raw << 16, false, true};
    const unsigned m = format == 5 ? 10 : format == 4 ? 2 : 3;
    const unsigned e = format == 3 ? 4 : 5;
    const int bias = format == 3 ? 7 : 15;
    const uint32_t fraction = raw % (1U << m);
    const unsigned exponent = (raw / (1U << m)) % (1U << e);
    const uint32_t sign = ((raw / (1U << (m + e))) % 2) << 31;
    if (exponent == (1U << e) - 1 && (format != 3 || fraction == 7)) {
        if (!fraction) return {sign | 0x7f800000U, false, true};
        return {0x7fc00000U, format != 3 && fraction < (1U << (m - 1)), true};
    }
    uint32_t significand = fraction + (exponent ? (1U << m) : 0);
    if (!significand) return {sign, false, true};
    int power = (exponent ? int(exponent) : 1) - bias - int(m);
    while (significand < 0x800000U) {
        significand *= 2;
        --power;
    }
    return {sign | (uint32_t(power + 23 + 127) << 23) | (significand - 0x800000U), false, true};
}
struct Expected { uint32_t result; unsigned flags; bool error; };
static Expected oracle(unsigned format, uint32_t a, uint32_t b, uint32_t acc) {
    Widened wa = decode(a, format), wb = decode(b, format);
    if (!wa.valid) return {0, 0, true};
    std::feclearexcept(FE_ALL_EXCEPT);
    volatile float fa = floating(wa.value);
    volatile float fb = floating(wb.value);
    volatile float fc = floating(acc);
    volatile float product = fa * fb;
    volatile float result = product + fc;
    const int raised = std::fetestexcept(FE_ALL_EXCEPT);
    unsigned flags = ((raised & FE_INVALID) || wa.snan || wb.snan) ? 16 : 0;
    if (raised & FE_DIVBYZERO) flags |= 8;
    if (raised & FE_OVERFLOW) flags |= 4;
    if (raised & FE_UNDERFLOW) flags |= 2;
    if (raised & FE_INEXACT) flags |= 1;
    return {canonical(bits(result)), flags, false};
}

class Test {
public:
    Vtb_g6lc_ai_fp_mac dut;
    std::mt19937_64 random;
    uint64_t cycles = 0, transactions = 0, probes = 0;
    std::array<uint64_t, 8> format_transactions{}, format_probes{};
    unsigned pipeline;
    unsigned min_latency = 1000, max_latency = 0;
    explicit Test(uint64_t seed, unsigned pipe) : random(seed), pipeline(pipe) {
        dut.clk_i = 0;
        dut.rst_ni = 0;
        dut.testmode_i = 0;
        dut.enable_i = 1;
        dut.flush_i = 0;
        dut.req_valid_i = 0;
        dut.result_ready_i = 0;
        tick(); tick();
        dut.rst_ni = 1;
        eval();
    }
    void eval() {
        dut.eval();
        require(dut.disabled_o == 0, "compile-disabled instance not constant zero");
        require(!(dut.req_ready_o && dut.busy_o), "ready while busy");
        require(!dut.result_valid_o || dut.busy_o, "valid without busy");
    }
    void tick() {
        dut.clk_i = 0; eval();
        dut.clk_i = 1; eval();
        dut.clk_i = 0; eval();
        ++cycles;
    }
    void probe(unsigned fmt, uint32_t raw) {
        dut.probe_fmt_i = fmt;
        dut.probe_raw_i = raw;
        eval();
        const auto want = decode(raw, fmt);
        require(dut.probe_value_o == want.value && dut.probe_snan_o == want.snan &&
                dut.probe_valid_o == want.valid,
                "widen fmt=" + std::to_string(fmt) + " raw=" + hex(raw) +
                " got=" + hex(dut.probe_value_o) + " expected=" + hex(want.value));
        ++probes;
        ++format_probes[fmt];
    }
    void launch(unsigned fmt, uint32_t a, uint32_t b, uint32_t acc) {
        dut.numfmt_i = fmt;
        dut.a_i = a; dut.b_i = b; dut.acc_i = acc;
        dut.req_valid_i = 1;
        dut.result_ready_i = 0;
        eval();
        require(dut.req_ready_o, "not ready for new scalar request");
        tick();
        dut.req_valid_i = 0;
        eval();
    }
    void perturb(unsigned index) {
        dut.req_valid_i = 1;
        dut.numfmt_i = index % 8;
        dut.a_i = uint32_t(random());
        dut.b_i = uint32_t(random());
        dut.acc_i = uint32_t(random());
        dut.testmode_i = index & 1;
        eval();
        require(!dut.req_ready_o, "busy format transition accepted");
    }
    uint32_t mac(unsigned fmt, uint32_t a, uint32_t b, uint32_t acc, unsigned stall = 0,
                 int directed_flags = -1) {
        const auto want = oracle(fmt, a, b, acc);
        if (directed_flags >= 0) require(want.flags == unsigned(directed_flags), "directed flag oracle disagreement");
        launch(fmt, a, b, acc);
        const auto accepted = cycles;
        unsigned waits = 0;
        while (!dut.result_valid_o) {
            require(++waits < 100, "scalar result timeout");
            perturb(waits);
            tick();
        }
        if (fmt >= 3) {
            const unsigned latency = unsigned(cycles - accepted);
            require(latency == 2 * pipeline + 2, "unexpected scalar primitive latency");
            min_latency = std::min(min_latency, latency);
            max_latency = std::max(max_latency, latency);
        }
        const std::string detail = " fmt=" + std::to_string(fmt) + " a=" + hex(a) +
            " b=" + hex(b) + " acc=" + hex(acc) + " got=" + hex(dut.result_o) +
            " want=" + hex(want.result) + " flags=" + hex(dut.flags_o) + "/" + hex(want.flags);
        require(dut.result_o == want.result, "two-rounding scalar mismatch" + detail);
        require(dut.flags_o == want.flags, "aggregated flags mismatch" + detail);
        require(bool(dut.error_o) == want.error, "error mismatch" + detail);
        require(!(dut.flags_o & 8), "unexpected DZ");
        for (unsigned i = 0; i < stall; ++i) {
            perturb(i); tick();
            require(dut.result_valid_o && dut.result_o == want.result && dut.flags_o == want.flags &&
                    bool(dut.error_o) == want.error, "response unstable under backpressure");
        }
        dut.req_valid_i = 0;
        dut.result_ready_i = 1;
        tick();
        require(!dut.result_valid_o && dut.req_ready_o && !dut.busy_o, "response not consumed once");
        dut.result_ready_i = 0;
        dut.testmode_i = 0;
        ++transactions;
        ++format_transactions[fmt];
        return dut.result_o;
    }
    void cancel(unsigned when, unsigned kind, unsigned fmt = 7) {
        launch(fmt, 0x3f800001, 0x3f7ffffe, 0xbf800000);
        for (unsigned i = 0; i < when; ++i) { perturb(i); tick(); }
        dut.testmode_i = 1;
        dut.req_valid_i = 1;
        if (kind == 0) dut.flush_i = 1;
        if (kind == 1) dut.enable_i = 0;
        if (kind == 2) dut.rst_ni = 0;
        eval();
        require(!dut.result_valid_o && !dut.req_ready_o && !dut.busy_o, "cancel not immediately masked");
        tick(); tick();
        dut.req_valid_i = 0;
        dut.flush_i = 0; dut.enable_i = 1; dut.rst_ni = 1;
        for (unsigned i = 0; i < 2 * pipeline + 8; ++i) {
            tick();
            require(!dut.result_valid_o && !dut.busy_o && dut.req_ready_o, "stale result after cancellation");
        }
        mac(7, 0x40000000, 0x40400000, 0x40800000, 2, 0);
    }
    void initiation_interval() {
        launch(7, 0x3f800000, 0x40000000, 0);
        const auto first = cycles;
        dut.result_ready_i = 1;
        while (!dut.result_valid_o) tick();
        const auto visible = cycles;
        tick();
        launch(7, 0x3f800000, 0x40000000, 0);
        const auto second = cycles;
        require(second - first == 2 * pipeline + 4, "scalar initiation interval mismatch");
        while (!dut.result_valid_o) tick();
        dut.result_ready_i = 1; tick(); dut.result_ready_i = 0;
        std::cout << "SCALAR_TIMING pipe_regs=" << pipeline
                  << " accept_edge_to_visible_edge_cycles=" << visible - first
                  << " initiation_interval_cycles=" << second - first
                  << " scope=single_serial_scalar_primitive_not_vector_rate\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        require(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559, "IEEE binary32 host required");
        require(std::fesetround(FE_TONEAREST) == 0, "cannot set host RNE");
#if defined(__SSE__)
        _mm_setcsr(_mm_getcsr() & ~((1U << 15) | (1U << 6)));
#endif
        const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 0) : 0x676c636670ULL;
        const unsigned pipeline = argc > 2 ? unsigned(std::strtoul(argv[2], nullptr, 0)) : 3;
        Test test(seed, pipeline);
        for (unsigned fmt : {5U, 6U})
            for (uint32_t raw = 0; raw < 65536; ++raw)
                test.probe(fmt, raw | (uint32_t(test.random()) & 0xffff0000U));
        for (unsigned fmt : {3U, 4U})
            for (uint32_t raw = 0; raw < 256; ++raw)
                test.probe(fmt, raw | (uint32_t(test.random()) & 0xffffff00U));
        for (unsigned i = 0; i < 10000; ++i) test.probe(7, uint32_t(test.random()));
        for (unsigned fmt = 0; fmt < 3; ++fmt) {
            test.probe(fmt, uint32_t(test.random()));
            test.mac(fmt, 0x7f800000, 0, 0x7f800001, 8, 0);
        }
        test.mac(7, 0, 0x7f800000, 0, 7, 16);
        test.mac(7, 0x7f800000, 0x3f800000, 0xff800000, 0, 16);
        test.mac(7, 0x7f800001, 0x3f800000, 0, 1, 16);
        test.mac(7, 0x3f800000, 0x3f800000, 0x7f800001, 1, 16);
        test.mac(7, 0x7fc00001, 0x3f800000, 0, 0, 0);
        test.mac(7, 0x7f7fffff, 0x40000000, 0, 0, 5);
        test.mac(7, 0x00800000, 0x3f000000, 0, 0, 0);
        test.mac(7, 1, 0x3f000000, 0, 0, 3);
        test.mac(7, 3, 0x3f000000, 0, 0, 3);
        test.mac(7, 0x3f800000, 0x3f800000, 0x33800000, 0, 1);
        test.mac(7, 0x3f800001, 0x3f800000, 0x33800000, 0, 1);
        test.mac(7, 0x3f800800, 0x3f800800, 0, 0, 1);
        test.mac(7, 0x80000000, 0x3f800000, 0, 9, 0);
        test.mac(7, 0x80000000, 0x3f800000, 0x80000000, 0, 0);
        test.mac(7, 0x7f7fffff, 0x3f800000, 0x7f7fffff, 0, 5);
        test.mac(7, 0x7f7fffff, 0x40000000, 0xff800000, 0, 21);
        test.mac(5, 0x7c01, 0x3c00, 0, 0, 16);
        test.mac(4, 0x7d, 0x3c, 0, 0, 16);
        test.mac(3, 0x7f, 0x38, 0, 0, 0);
        test.mac(3, 0x7e, 0x38, 0, 0, 0);
        test.mac(6, 0x7f81, 0x3f80, 0, 0, 16);
        const uint32_t separate = test.mac(7, 0x3f800001, 0x3f7ffffe, 0xbf800000, 0, 1);
        const uint32_t fused = bits(std::fma(floating(0x3f800001), floating(0x3f7ffffe), -1.0f));
        require(separate == 0 && fused == 0xa8800000, "FMA discriminator did not distinguish two roundings");
        const std::array<uint32_t, 19> edges = {0, 0x80000000, 1, 2, 0x007fffff, 0x00800000,
            0x00800001, 0x3f000000, 0x3f800000, 0x3f800001, 0xbf800000, 0x7f7fffff,
            0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0xff800001, 0x80800000};
        for (auto a : edges) for (auto b : edges) for (auto acc : edges)
            test.mac(7, a, b, acc);
        for (unsigned fmt = 3; fmt < 8; ++fmt) {
            for (unsigned i = 0; i < 5000; ++i)
                test.mac(fmt, uint32_t(test.random()), uint32_t(test.random()),
                         uint32_t(test.random()), i % 41 == 0 ? 5 : 0);
            for (unsigned sequence = 0; sequence < 25; ++sequence) {
                uint32_t actual = 0, expected = 0;
                for (unsigned k = 0; k < 64; ++k) {
                    uint32_t a, b;
                    if (fmt == 3) { a = uint32_t(test.random()) & 0xbf; b = uint32_t(test.random()) & 0xbf; }
                    else if (fmt == 4) { a = uint32_t(test.random()) & 0xef; b = uint32_t(test.random()) & 0xef; }
                    else if (fmt == 5) { a = uint32_t(test.random()) & 0xbfff; b = uint32_t(test.random()) & 0xbfff; }
                    else if (fmt == 6) { a = (uint32_t(test.random()) & 0x807f) | 0x3f00; b = (uint32_t(test.random()) & 0x807f) | 0x3f00; }
                    else { a = (uint32_t(test.random()) & 0x807fffff) | 0x3f000000; b = (uint32_t(test.random()) & 0x807fffff) | 0x3f000000; }
                    expected = oracle(fmt, a, b, expected).result;
                    actual = test.mac(fmt, a, b, actual);
                    require(actual == expected, "ascending-K external accumulation mismatch");
                }
            }
        }
        for (unsigned kind = 0; kind < 3; ++kind) {
            for (unsigned when = 0; when <= 2 * pipeline + 5; ++when) test.cancel(when, kind);
            test.cancel(0, kind, 0);
        }
        test.dut.enable_i = 0; test.dut.req_valid_i = 1; test.dut.testmode_i = 1;
        for (unsigned i = 0; i < 10; ++i) {
            test.tick();
            require(!test.dut.req_ready_o && !test.dut.result_valid_o && !test.dut.busy_o,
                    "testmode caused functional acceptance while disabled");
        }
        test.dut.enable_i = 1; test.dut.req_valid_i = 0; test.dut.testmode_i = 0; test.eval();
        test.initiation_interval();
        for (unsigned fmt = 0; fmt < 8; ++fmt)
            std::cout << "FORMAT_PASS numfmt=" << fmt << " widening_patterns=" << test.format_probes[fmt]
                      << " scalar_transactions=" << test.format_transactions[fmt]
                      << " values=bit_exact flags=exact error=" << (fmt < 3 ? "required" : "none") << '\n';
        std::cout << "PASS fp_mac seed=" << seed << " pipe_regs=" << pipeline
                  << " widening_patterns=" << test.probes << " scalar_transactions=" << test.transactions
                  << " dot_sequences=125 cycles=" << test.cycles << " flags=NV_OF_UF_NX_DZ_checked"
                  << " cancellation=all_phases_reset_flush_disable backpressure=checked\n";
        test.dut.final();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL fp_mac " << error.what() << '\n';
        return 1;
    }
}
