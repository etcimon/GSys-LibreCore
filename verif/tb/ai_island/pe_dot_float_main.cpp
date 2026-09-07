// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Unit test for g6lc_ai_pe_dot_float (FP8/FP16/BF16/FP32 block-floating dot).
//
// Compares the DUT output against a reference that decodes to double,
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
        // E4M3: only the all-ones pattern at the top exponent is NaN.
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
    case 3: return 0x38;       // E4M3 1.0
    case 4: return 0x3c;       // E5M2 1.0
    case 5: return 0x3c00;     // FP16 1.0
    case 6: return 0x3f80;     // BF16 1.0
    case 7: return 0x3f800000; // FP32 1.0
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

static uint32_t reference_dot(const std::array<uint32_t, 4>& a,
                              const std::array<uint32_t, 4>& b,
                              const std::array<bool, 4>& v,
                              unsigned numfmt) {
    bool any_nan = false;
    bool any_inf = false;
    bool inf_sign = false;
    bool same_inf_sign = true;
    bool any_finite = false;
    double sum = 0.0;
    for (int l = 0; l < 4; l++) {
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
    // The DUT returns a positive zero when the exact dot is zero and no finite
    // non-zero products contribute. Match that so the test is of the hardware
    // behaviour, not the sign of an all-zero IEEE sum.
    if (sum == 0.0) return 0x00000000;
    return bits(static_cast<float>(sum));
}

class Test {
public:
    Vg6lc_ai_pe_dot_float dut;
    std::mt19937_64 random;
    uint64_t transactions = 0;
    uint64_t checks = 0;
    explicit Test(uint64_t seed) : random(seed) {}

    uint32_t dot(unsigned numfmt, const std::array<uint32_t, 4>& a,
                 const std::array<uint32_t, 4>& b,
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
            for (auto x : a) std::cerr << x << " ";
            std::cerr << " b=";
            for (auto x : b) std::cerr << x << " ";
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

        // Directed: 1.0*1.0 + 1.0*1.0 = 2.0 for every float format.
        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            uint32_t one = one_for_format(numfmt);
            test.dot(numfmt, {one, one, 0U, 0U}, {one, one, 0U, 0U},
                     {true, true, false, false});
        }

        // Directed: 1.0 + (-1.0) = 0 for every float format.
        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            uint32_t one  = one_for_format(numfmt);
            uint32_t none = neg_one_for_format(numfmt);
            test.dot(numfmt, {one, none, 0U, 0U}, {one, one, 0U, 0U},
                     {true, true, false, false});
        }

        // Directed subnormal / tiny cases:
        // E4M3: two subnormal 2^-9 * 2^-9 products -> 2^-17 = 0x37000000
        test.dot(3, {0x01U, 0x01U, 0U, 0U}, {0x01U, 0x01U, 0U, 0U},
                 {true, true, false, false});
        // E5M2: subnormal 2^-16 * 2^-16 products -> 2 * 2^-32 = 2^-31 = 0x30000000
        test.dot(4, {0x01U, 0x01U, 0U, 0U}, {0x01U, 0x01U, 0U, 0U},
                 {true, true, false, false});
        // FP16: subnormal 2^-24 * 2^-24 products -> 2 * 2^-48 = 2^-47 = 0x28000000
        test.dot(5, {0x0001U, 0x0001U, 0U, 0U}, {0x0001U, 0x0001U, 0U, 0U},
                 {true, true, false, false});
        // BF16 and FP32 subnormal products underflow to +0.
        test.dot(6, {0x0001U, 0x0001U, 0U, 0U}, {0x0001U, 0x0001U, 0U, 0U},
                 {true, true, false, false});
        test.dot(7, {0x00000001U, 0x00000001U, 0U, 0U},
                 {0x00000001U, 0x00000001U, 0U, 0U},
                 {true, true, false, false});

        // Directed WORST-CASE EXPONENT SPREAD, aimed at the one arm of
        // fp_dot_product_aligned that silently returns zero: a product whose
        // alignment shift reaches FP_DOT_MAXW is DROPPED, which loses the
        // largest term in the window rather than rounding it. With the
        // integer-significand convention the FP32 product exponent spans
        // [-298, 208], so the widest possible shift is 506, and 506 + 48 bits
        // of product + 8 bits of lane headroom is 562 of the 640 available.
        // These cases put the largest and smallest representable products in
        // ONE window, so the shift sits at that 506-bit maximum and the RTL
        // assertion added in g6lc_ai_pe_dot_float.sv is exercised at its limit
        // instead of only on benign data. The tiny term is far below the ULP of
        // the huge one, so the correctly rounded answer is the huge product --
        // which is exactly why an output-only check could never catch a drop
        // here, and why the invariant is asserted inside the DUT.
        //
        // FP32: max normal^2 alongside min subnormal^2.
        test.dot(7, {0x7f7fffffU, 0x00000001U, 0x00000001U, 0x7f7fffffU},
                 {0x7f7fffffU, 0x00000001U, 0x7f7fffffU, 0x00000001U},
                 {true, true, true, true});
        // FP32: min normal^2 against max normal^2, both signs, to sweep the
        // block exponent to the bottom of its range with a live large term.
        test.dot(7, {0x00800000U, 0xff7fffffU, 0x80800000U, 0x7f7fffffU},
                 {0x00800000U, 0x7f7fffffU, 0x00800000U, 0x00800000U},
                 {true, true, true, true});
        // BF16: same shape, 506-bit spread with a 16-bit product.
        test.dot(6, {0x7f7fU, 0x0001U, 0x0001U, 0x7f7fU},
                 {0x7f7fU, 0x0001U, 0x7f7fU, 0x0001U},
                 {true, true, true, true});
        // FP16 and both FP8 formats at their own extremes.
        test.dot(5, {0x7bffU, 0x0001U, 0x0001U, 0xfbffU},
                 {0x7bffU, 0x0001U, 0x7bffU, 0x0001U},
                 {true, true, true, true});
        test.dot(3, {0x7eU, 0x01U, 0x01U, 0xfeU}, {0x7eU, 0x01U, 0x7eU, 0x01U},
                 {true, true, true, true});
        test.dot(4, {0x7bU, 0x01U, 0x01U, 0xfbU}, {0x7bU, 0x01U, 0x7bU, 0x01U},
                 {true, true, true, true});

        // Directed NaN and Inf propagation.
        // E5M2: 1.0 * Inf = Inf
        test.dot(4, {0x3cU, 0x00U, 0U, 0U}, {0xfcU, 0x00U, 0U, 0U},
                 {true, false, false, false});
        // E5M2: 0 * Inf = NaN
        test.dot(4, {0x00U, 0x00U, 0U, 0U}, {0xfcU, 0x00U, 0U, 0U},
                 {true, false, false, false});
        // FP32: 1.0 * Inf = Inf, plus 1.0*1.0 (no conflict)
        test.dot(7, {0x3f800000U, 0x3f800000U, 0U, 0U},
                 {0x7f800000U, 0x3f800000U, 0U, 0U},
                 {true, true, false, false});

        // Random exhaustive-ish over the Lanes=4 space for each float format.
        std::uniform_int_distribution<int> dist8(0, 255);
        std::uniform_int_distribution<int> dist16(0, 65535);
        std::uniform_int_distribution<int> dist32(0, 2147483647);
        std::bernoulli_distribution coin(0.5);
        std::array<uint32_t, 4> a, b;
        std::array<bool, 4> v;

        for (unsigned numfmt : {3U, 4U, 5U, 6U, 7U}) {
            int max_raw;
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
                for (int l = 0; l < 4; l++) {
                    a[l] = static_cast<uint32_t>((*dist)(test.random));
                    b[l] = static_cast<uint32_t>((*dist)(test.random));
                    v[l] = coin(test.random);
                    // Replace any generated NaN/Inf pattern with a quiet zero so
                    // the oracle is not asked to classify every special case at
                    // random. Specials are tested in the directed cases above.
                    if (is_nan_pattern(a[l], numfmt)) a[l] = 0;
                    if (is_nan_pattern(b[l], numfmt)) b[l] = 0;
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
