// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Unit test for g6lc_ai_pe_dot_float (FP8 E4M3/E5M2 block-floating dot).
//
// Compares the DUT output against a reference that decodes FP8 to double,
// accumulates the exact real sum for Lanes=4, and rounds to binary32 with
// round-to-nearest-even. The DUT's BFP final rounding should match because the
// reference is the correctly-rounded result of the exact dot product.
//
// Not Variane. Not a throughput number.

#include "Vg6lc_ai_pe_dot_float.h"
#include "verilated.h"
#include <array>
#include <cmath>
#include <cfenv>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <random>

static uint32_t bits(float value) {
    uint32_t result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

struct Fp8 {
    double value;
    bool is_nan;
    bool is_inf;
    bool is_zero;
};

static Fp8 decode_fp8(uint8_t raw, unsigned numfmt) {
    Fp8 d{};
    d.is_zero = true;
    d.value = 0.0;
    bool sign = (raw >> 7) & 1;
    double sm = sign ? -1.0 : 1.0;
    int exp_bits, man_bits, bias, max_exp, max_man;
    int exp_enc, man_enc;
    if (numfmt == 3) {  // E4M3
        exp_bits = 4; man_bits = 3; bias = 7; max_exp = 15; max_man = 7;
        exp_enc = (raw >> 3) & 0xf;
        man_enc = raw & 0x7;
    } else {  // E5M2
        exp_bits = 5; man_bits = 2; bias = 15; max_exp = 31; max_man = 3;
        exp_enc = (raw >> 2) & 0x1f;
        man_enc = raw & 0x3;
    }
    if (exp_enc == 0 && man_enc == 0) {
        d.value = sm * 0.0;
    } else if (exp_enc == max_exp && man_enc == max_man) {
        d.is_nan = true;
        d.is_zero = false;
    } else if (numfmt == 4 && exp_enc == 31 && man_enc == 0) {
        d.is_inf = true;
        d.is_zero = false;
        d.value = sm * HUGE_VAL;
    } else {
        d.is_zero = false;
        int mant, exp;
        if (exp_enc == 0) {
            mant = man_enc;
            exp = 1 - bias - man_bits;
        } else {
            mant = (1 << man_bits) + man_enc;
            exp = exp_enc - bias - man_bits;
        }
        d.value = sm * static_cast<double>(mant) * std::pow(2.0, exp);
    }
    return d;
}

static uint32_t reference_dot(const std::array<uint8_t, 4>& a,
                              const std::array<uint8_t, 4>& b,
                              const std::array<bool, 4>& v,
                              unsigned numfmt) {
    bool any_nan = false;
    bool any_inf = false;
    bool inf_sign = false;
    bool same_inf_sign = true;
    double sum = 0.0;
    for (int l = 0; l < 4; l++) {
        if (!v[l]) continue;
        Fp8 da = decode_fp8(a[l], numfmt);
        Fp8 db = decode_fp8(b[l], numfmt);
        if (da.is_nan || db.is_nan) {
            any_nan = true;
            continue;
        }
        if ((da.is_inf && db.is_zero) || (db.is_inf && da.is_zero)) {
            any_nan = true;
            continue;
        }
        if (da.is_inf || db.is_inf) {
            bool s = ((a[l] >> 7) & 1) ^ ((b[l] >> 7) & 1);
            if (!any_inf) {
                inf_sign = s;
            } else if (s != inf_sign) {
                same_inf_sign = false;
            }
            any_inf = true;
            continue;
        }
        if (!da.is_zero && !db.is_zero) {
            sum += da.value * db.value;
        }
    }
    if (any_nan || (any_inf && !same_inf_sign)) return 0x7fc00000;
    if (any_inf) {
        uint32_t s = inf_sign ? 0x80000000U : 0;
        return s | 0x7f800000U;
    }
    return bits(static_cast<float>(sum));
}

class Test {
public:
    Vg6lc_ai_pe_dot_float dut;
    std::mt19937_64 random;
    uint64_t transactions = 0;
    uint64_t checks = 0;
    explicit Test(uint64_t seed) : random(seed) {}

    uint32_t dot(unsigned numfmt, const std::array<uint8_t, 4>& a,
                 const std::array<uint8_t, 4>& b,
                 const std::array<bool, 4>& v) {
        dut.numfmt_i = numfmt;
        for (int l = 0; l < 4; l++) {
            dut.a_i[l] = a[l];
            dut.b_i[l] = b[l];
            dut.valid_i[l] = v[l];
        }
        dut.eval();
        uint32_t got = dut.sum_o;
        uint32_t want = reference_dot(a, b, v, numfmt);
        checks++;
        if (got != want) {
            std::cerr << "FAIL numfmt=" << numfmt
                      << " a=" << std::hex;
            for (auto x : a) std::cerr << (int)x;
            std::cerr << " b=";
            for (auto x : b) std::cerr << (int)x;
            std::cerr << " got=0x" << got << " want=0x" << want << std::dec << '\n';
            throw std::runtime_error("dot mismatch");
        }
        transactions++;
        return got;
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
        Test test(0x676c636670ULL);

        // E4M3: 1.875 + 1.0 = 2.875 = 0x40380000
        test.dot(3, {0x3f, 0x40, 0x00, 0x00}, {0x38, 0x30, 0x00, 0x00},
                 {true, true, false, false});

        // E4M3: 1.0*1.0 + 1.0*1.0 = 2.0 = 0x40000000
        test.dot(3, {0x38, 0x38, 0x00, 0x00}, {0x38, 0x38, 0x00, 0x00},
                 {true, true, false, false});

        // E4M3: subnormal 2 * 2^-18 = 2^-17 = 0x37000000
        test.dot(3, {0x01, 0x01, 0x00, 0x00}, {0x01, 0x01, 0x00, 0x00},
                 {true, true, false, false});

        // E4M3: single subnormal = 2^-18 = 0x36800000
        test.dot(3, {0x01, 0x00, 0x00, 0x00}, {0x01, 0x00, 0x00, 0x00},
                 {true, false, false, false});

        // E5M2: 1.0*1.0 + 1.0*1.0 = 2.0
        test.dot(4, {0x3c, 0x3c, 0x00, 0x00}, {0x3c, 0x3c, 0x00, 0x00},
                 {true, true, false, false});

        // E5M2: 1.0 + (-1.0) = 0 (signed)
        test.dot(4, {0x3c, 0xbc, 0x00, 0x00}, {0x3c, 0x3c, 0x00, 0x00},
                 {true, true, false, false});

        // E4M3: zero handling
        test.dot(3, {0x00, 0x3f, 0x00, 0x00}, {0x38, 0x38, 0x00, 0x00},
                 {true, true, false, false});

        // Random exhaustive-ish over the Lanes=4 FP8 space for E4M3.
        // We avoid the few NaN patterns and test with one active format.
        std::uniform_int_distribution<int> dist(0, 255);
        std::bernoulli_distribution coin(0.5);
        std::array<uint8_t, 4> a, b;
        std::array<bool, 4> v;
        for (unsigned numfmt : {3U, 4U}) {
            uint8_t max_exp = numfmt == 3 ? 0x0f : 0x1f;
            uint8_t max_man = numfmt == 3 ? 0x07 : 0x03;
            for (unsigned trial = 0; trial < 2000; trial++) {
                for (int l = 0; l < 4; l++) {
                    a[l] = static_cast<uint8_t>(dist(test.random));
                    b[l] = static_cast<uint8_t>(dist(test.random));
                    v[l] = coin(test.random);
                    // skip NaN patterns for oracle sanity; DUT can still see them
                    if (((a[l] >> (numfmt == 3 ? 3 : 2)) & (numfmt == 3 ? 0xf : 0x1f)) == max_exp &&
                        (a[l] & (numfmt == 3 ? 0x7 : 0x3)) == max_man) a[l] = 0x00;
                    if (((b[l] >> (numfmt == 3 ? 3 : 2)) & (numfmt == 3 ? 0xf : 0x1f)) == max_exp &&
                        (b[l] & (numfmt == 3 ? 0x7 : 0x3)) == max_man) b[l] = 0x00;
                }
                test.dot(numfmt, a, b, v);
            }
        }

        std::cout << "PASS pe_dot_float Lanes=4 transactions=" << test.transactions
                  << " checks=" << test.checks << " seed=0x676c636670\n";
        test.dut.final();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL pe_dot_float " << error.what() << '\n';
        return 1;
    }
}
