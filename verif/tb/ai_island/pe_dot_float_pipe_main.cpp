// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Pipelined floating dot product unit test (g6lc_ai_pe_dot_float_pipe).
//
// Issues back-to-back transactions to the pipelined dot product and compares
// the delayed sum_o output against a reference that decodes each lane to double,
// accumulates the exact real dot product and rounds to binary32 RNE.
//
// Build/run (example Lanes=8):
//   verilator --cc --exe --build -j 2 -GLanes=8 \
//     core/include/config_pkg.sv \
//     corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv \
//     corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv \
//     verif/tb/ai_island/pe_dot_float_pipe_main.cpp \
//     --top-module g6lc_ai_pe_dot_float_pipe -Mdir /tmp/pe-dot-pipe -o pe_dot_float_pipe
//   /tmp/pe-dot-pipe/pe_dot_float_pipe
//
// Not Variane. Not a throughput number.

#include "Vg6lc_ai_pe_dot_float_pipe.h"
#include "verilated.h"
#include <array>
#include <cmath>
#include <cfenv>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <random>
#include <vector>

static uint32_t bits(float value) {
    uint32_t result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

struct FpVal {
    double value;
    bool sign;
    bool is_nan;
    bool is_inf;
    bool is_zero;
};

static FpVal decode_float(uint32_t raw, unsigned numfmt) {
    FpVal d{};
    int exp_bits, man_bits, bias, max_exp, max_man, sign_pos;
    bool has_inf = true;
    uint32_t exp_mask, man_mask;
    uint32_t exp, man;

    switch (numfmt) {
    case 3:  // FP8 E4M3
        exp_bits = 4; man_bits = 3; bias = 7; has_inf = false;
        max_exp = 15; max_man = 7; sign_pos = 7;
        break;
    case 4:  // FP8 E5M2
        exp_bits = 5; man_bits = 2; bias = 15; has_inf = true;
        max_exp = 31; max_man = 3; sign_pos = 7;
        break;
    case 5:  // FP16
        exp_bits = 5; man_bits = 10; bias = 15; has_inf = true;
        max_exp = 31; max_man = 1023; sign_pos = 15;
        break;
    case 6:  // BF16
        exp_bits = 8; man_bits = 7; bias = 127; has_inf = true;
        max_exp = 255; max_man = 127; sign_pos = 15;
        break;
    case 7:  // FP32
        exp_bits = 8; man_bits = 23; bias = 127; has_inf = true;
        max_exp = 255; max_man = 0x7fffff; sign_pos = 31;
        break;
    default:
        d.is_nan = true;
        return d;
    }

    exp_mask = (1u << exp_bits) - 1;
    man_mask = (1u << man_bits) - 1;
    d.sign = ((raw >> sign_pos) & 1u) != 0;
    exp = (raw >> man_bits) & exp_mask;
    man = raw & man_mask;
    double sm = d.sign ? -1.0 : 1.0;

    if (exp == 0 && man == 0) {
        d.is_zero = true;
        d.value = sm * 0.0;
    } else if (has_inf && (int)exp == max_exp) {
        if (man == 0) {
            d.is_inf = true;
            d.value = sm * HUGE_VAL;
        } else {
            d.is_nan = true;
        }
    } else if (!has_inf && (int)exp == max_exp && (int)man == max_man) {
        d.is_nan = true;
    } else {
        d.is_zero = false;
        int mant, realexp;
        if (exp == 0) {
            mant = (int)man;
            realexp = 1 - bias - man_bits;
        } else {
            mant = (1 << man_bits) + (int)man;
            realexp = (int)exp - bias - man_bits;
        }
        d.value = sm * static_cast<double>(mant) * std::pow(2.0, realexp);
    }
    return d;
}

static bool is_nan_pattern(uint32_t raw, unsigned numfmt) {
    int exp_bits, man_bits, max_exp, max_man;
    bool has_inf;
    switch (numfmt) {
    case 3: exp_bits = 4; man_bits = 3; has_inf = false; max_exp = 15; max_man = 7; break;
    case 4: exp_bits = 5; man_bits = 2; has_inf = true;  max_exp = 31; max_man = 3; break;
    case 5: exp_bits = 5; man_bits = 10; has_inf = true; max_exp = 31; max_man = 1023; break;
    case 6: exp_bits = 8; man_bits = 7;  has_inf = true; max_exp = 255; max_man = 127; break;
    case 7: exp_bits = 8; man_bits = 23; has_inf = true; max_exp = 255; max_man = 0x7fffff; break;
    default: return true;
    }
    uint32_t exp = (raw >> man_bits) & ((1u << exp_bits) - 1);
    uint32_t man = raw & ((1u << man_bits) - 1);
    if (!has_inf && (int)exp == max_exp && (int)man == max_man) return true;
    if (has_inf && (int)exp == max_exp && man != 0) return true;
    return false;
}

static uint32_t one_for_format(unsigned numfmt) {
    switch (numfmt) {
    case 3: return 0x38;
    case 4: return 0x3c;
    case 5: return 0x3c00;
    case 6: return 0x3f80;
    case 7: return 0x3f800000;
    default: return 0;
    }
}

static uint32_t neg_one_for_format(unsigned numfmt) {
    switch (numfmt) {
    case 3: return 0xb8;
    case 4: return 0xbc;
    case 5: return 0xbc00;
    case 6: return 0xbf80;
    case 7: return 0xbf800000;
    default: return 0;
    }
}

static uint32_t reference_dot(const std::vector<uint32_t>& a,
                              const std::vector<uint32_t>& b,
                              const std::vector<bool>& v,
                              unsigned numfmt) {
    bool any_nan = false;
    bool any_inf = false;
    bool same_inf_sign = true;
    bool inf_sign = false;
    bool any_finite = false;
    double sum = 0.0;
    for (size_t l = 0; l < a.size(); l++) {
        if (!v[l]) continue;
        FpVal da = decode_float(a[l], numfmt);
        FpVal db = decode_float(b[l], numfmt);
        if (da.is_nan || db.is_nan) {
            any_nan = true;
            continue;
        }
        if ((da.is_inf && db.is_zero) || (db.is_inf && da.is_zero)) {
            any_nan = true;
            continue;
        }
        if (da.is_inf || db.is_inf) {
            bool s = da.sign ^ db.sign;
            if (!any_inf) {
                inf_sign = s;
            } else if (s != inf_sign) {
                same_inf_sign = false;
            }
            any_inf = true;
            continue;
        }
        if (!da.is_zero && !db.is_zero) {
            any_finite = true;
            sum += da.value * db.value;
        }
    }
    if (any_nan || (any_inf && !same_inf_sign)) return 0x7fc00000;
    if (any_inf) {
        uint32_t s = inf_sign ? 0x80000000U : 0;
        return s | 0x7f800000U;
    }
    if (sum == 0.0) return 0x00000000;
    return bits(static_cast<float>(sum));
}

class PipeTest {
public:
    Vg6lc_ai_pe_dot_float_pipe dut;
    std::mt19937_64 random;
    int Lanes;
    int Latency;
    uint64_t transactions = 0;
    uint64_t checks = 0;
    std::deque<uint32_t> want;

    explicit PipeTest(uint64_t seed) : random(seed) {
        Lanes = static_cast<int>(sizeof(dut.a_i) / sizeof(dut.a_i[0]));
        Latency = 4 + ceil_log2(Lanes);
        reset();
    }

    static int ceil_log2(int x) {
        if (x <= 1) return 0;
        int log = 0;
        while ((1 << log) < x) ++log;
        return log;
    }

    void reset() {
        dut.rst_ni = 0;
        dut.start_i = 0;
        dut.numfmt_i = 0;
        for (int l = 0; l < Lanes; l++) {
            dut.a_i[l] = 0;
            dut.b_i[l] = 0;
            dut.valid_i[l] = 0;
        }
        for (int i = 0; i < 8; i++) {
            dut.clk_i = 0; dut.eval();
            dut.clk_i = 1; dut.eval();
        }
        dut.rst_ni = 1;
        for (int i = 0; i < 4; i++) {
            dut.clk_i = 0; dut.eval();
            dut.clk_i = 1; dut.eval();
        }
        want.clear();
    }

    void tick() {
        dut.clk_i = 0; dut.eval();
        dut.clk_i = 1; dut.eval();
        if (dut.valid_o) {
            if (want.empty()) {
                throw std::runtime_error("unexpected valid_o");
            }
            uint32_t got = dut.sum_o;
            uint32_t expected = want.front();
            want.pop_front();
            // The pipelined dot product is a block-floating reduction followed
            // by a single RNE conversion, which may differ from a direct
            // double->float cast by at most one ULP.  Allow 1-ULP on finite
            // results; special values (Inf/NaN/zero) are checked exactly.
            bool special_got = ((got & 0x7f800000U) == 0x7f800000U) || (got == 0U);
            bool special_want = ((expected & 0x7f800000U) == 0x7f800000U) || (expected == 0U);
            bool match = (got == expected) ||
                         (!special_got && !special_want &&
                          std::abs(static_cast<int32_t>(got) - static_cast<int32_t>(expected)) <= 1);
            if (!match) {
                std::cerr << "FAIL transaction " << checks
                          << " got=0x" << std::hex << got
                          << " want=0x" << expected << std::dec << '\n';
                throw std::runtime_error("dot mismatch");
            }
            checks++;
        }
    }

    void start_dot(unsigned numfmt,
                   const std::vector<uint32_t>& a,
                   const std::vector<uint32_t>& b,
                   const std::vector<bool>& v) {
        if ((int)a.size() != Lanes || (int)b.size() != Lanes || (int)v.size() != Lanes) {
            throw std::runtime_error("lane count mismatch");
        }
        dut.numfmt_i = numfmt;
        for (int l = 0; l < Lanes; l++) {
            dut.a_i[l] = a[l];
            dut.b_i[l] = b[l];
            dut.valid_i[l] = v[l] ? 1 : 0;
        }
        dut.start_i = 1;
        want.push_back(reference_dot(a, b, v, numfmt));
        transactions++;
        tick();
    }

    void stop() {
        dut.start_i = 0;
    }

    void drain(int cycles) {
        for (int c = 0; c < cycles; c++) tick();
    }
};

int main(int argc, char** argv) {
    (void)argc; (void)argv;
    Verilated::commandArgs(argc, argv);
    std::fesetround(FE_TONEAREST);
    try {
        if (std::fesetround(FE_TONEAREST) != 0) {
            throw std::runtime_error("cannot set RNE rounding");
        }
        PipeTest test(0x676c636670ULL);
        const int L = test.Lanes;

        // Directed: 1.0 * 1.0 for every supported float format, all lanes valid.
        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            uint32_t one = one_for_format(numfmt);
            std::vector<uint32_t> a(L, one), b(L, one);
            std::vector<bool> v(L, true);
            test.start_dot(numfmt, a, b, v);
        }

        // Directed: 1.0 * -1.0 = -N for every format, all lanes.
        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            uint32_t one = one_for_format(numfmt);
            uint32_t none = neg_one_for_format(numfmt);
            std::vector<uint32_t> a(L, one), b(L, none);
            std::vector<bool> v(L, true);
            test.start_dot(numfmt, a, b, v);
        }

        // Directed: half the lanes valid (expected L/2).
        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            uint32_t one = one_for_format(numfmt);
            std::vector<uint32_t> a(L, one), b(L, one);
            std::vector<bool> v(L, false);
            for (int l = 0; l < L; l++) v[l] = (l % 2 == 0);
            test.start_dot(numfmt, a, b, v);
        }

        // Directed: alternating signs -> 0.
        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            uint32_t one = one_for_format(numfmt);
            uint32_t none = neg_one_for_format(numfmt);
            std::vector<uint32_t> a(L, one), b(L, one);
            for (int l = 0; l < L; l++) b[l] = (l % 2 == 0) ? one : none;
            std::vector<bool> v(L, true);
            test.start_dot(numfmt, a, b, v);
        }

        // Directed subnormal / tiny cases.
        // E4M3: two subnormal 2^-9 * 2^-9 products per lane -> L * 2^-17.
        test.start_dot(3,
            std::vector<uint32_t>(L, 0x01U),
            std::vector<uint32_t>(L, 0x01U),
            std::vector<bool>(L, true));
        // E5M2: subnormal 2^-16 * 2^-16 per lane -> L * 2^-31.
        test.start_dot(4,
            std::vector<uint32_t>(L, 0x01U),
            std::vector<uint32_t>(L, 0x01U),
            std::vector<bool>(L, true));
        // FP16 subnormal products.
        test.start_dot(5,
            std::vector<uint32_t>(L, 0x0001U),
            std::vector<uint32_t>(L, 0x0001U),
            std::vector<bool>(L, true));
        // BF16 and FP32 subnormal products underflow to +0 when L > 1.
        test.start_dot(6,
            std::vector<uint32_t>(L, 0x0001U),
            std::vector<uint32_t>(L, 0x0001U),
            std::vector<bool>(L, true));
        test.start_dot(7,
            std::vector<uint32_t>(L, 0x00000001U),
            std::vector<uint32_t>(L, 0x00000001U),
            std::vector<bool>(L, true));

        // Directed NaN and Inf propagation.
        // E5M2: 1.0 * Inf = Inf for one valid lane.
        {
            std::vector<uint32_t> a(L, 0), b(L, 0);
            std::vector<bool> v(L, false);
            a[0] = 0x3c; b[0] = 0xfc; v[0] = true;
            test.start_dot(4, a, b, v);
        }
        // E5M2: 0 * Inf = NaN.
        {
            std::vector<uint32_t> a(L, 0), b(L, 0);
            std::vector<bool> v(L, false);
            a[0] = 0x00; b[0] = 0xfc; v[0] = true;
            test.start_dot(4, a, b, v);
        }
        // FP32: 1.0 * Inf = Inf, plus 1.0*1.0 (no conflict).
        {
            std::vector<uint32_t> a(L, 0), b(L, 0x3f800000U);
            std::vector<bool> v(L, true);
            a[0] = 0x7f800000U;
            test.start_dot(7, a, b, v);
        }

        // Random exhaustive-ish over the lane space for each format.
        std::uniform_int_distribution<int> dist8(0, 255);
        std::uniform_int_distribution<int> dist16(0, 65535);
        std::uniform_int_distribution<int> dist32(0, 2147483647);
        std::bernoulli_distribution coin(0.5);

        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            std::uniform_int_distribution<int>* dist;
            switch (numfmt) {
            case 3:
            case 4:
                dist = &dist8;
                break;
            case 5:
            case 6:
                dist = &dist16;
                break;
            case 7:
                dist = &dist32;
                break;
            default:
                dist = &dist8;
            }
            for (unsigned trial = 0; trial < 1000; trial++) {
                std::vector<uint32_t> a(L), b(L);
                std::vector<bool> v(L);
                for (int l = 0; l < L; l++) {
                    a[l] = static_cast<uint32_t>((*dist)(test.random));
                    b[l] = static_cast<uint32_t>((*dist)(test.random));
                    v[l] = coin(test.random);
                    if (is_nan_pattern(a[l], numfmt)) a[l] = 0;
                    if (is_nan_pattern(b[l], numfmt)) b[l] = 0;
                }
                test.start_dot(numfmt, a, b, v);
            }
        }

        test.stop();
        test.drain(test.Latency + 16);

        if (!test.want.empty()) {
            std::cerr << "FAIL " << test.want.size() << " expected outputs never arrived\n";
            throw std::runtime_error("outputs missing");
        }

        std::cout << "PASS pe_dot_float_pipe Lanes=" << L
                  << " transactions=" << test.transactions
                  << " checks=" << test.checks
                  << " latency=" << test.Latency
                  << " seed=0x676c636670\n";
        test.dut.final();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL pe_dot_float_pipe " << error.what() << '\n';
        return 1;
    }
}
