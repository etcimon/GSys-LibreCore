// Correctness test for the half-width SIMD tier in verilated_types.h.
// Compares every _vl_words_* kernel against a scalar reference for word
// counts 1..40 (covering <half, half-only, mixed, and multi-chunk cases).
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

static int fails = 0;
#define CHECK(cond, msg) \
    do { \
        if (!(cond)) { \
            std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, msg); \
            ++fails; \
        } \
    } while (0)

int main() {
#ifdef VL_SIMD_WORDS
    std::printf("VL_SIMD_WORDS=%d VL_SIMD_HALF_WORDS=%d\n", VL_SIMD_WORDS,
                VL_SIMD_HALF_WORDS);
#else
    std::printf("VL_SIMD_WORDS undefined (scalar build)\n");
    return 0;
#endif
    const int MAXW = 40;
    std::vector<EData> a(MAXW), b(MAXW), o(MAXW), ref(MAXW);
    // Deterministic pseudo-random fill (xorshift) so results are reproducible.
    uint32_t s = 0x12345678u;
    auto rnd = [&]() {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s;
    };
    for (int trial = 0; trial < 200; ++trial) {
        for (int i = 0; i < MAXW; ++i) { a[i] = rnd(); b[i] = rnd(); }
        for (int words = 1; words <= MAXW; ++words) {
            // elementwise
            for (int i = 0; i < words; ++i) ref[i] = a[i] & b[i];
            _vl_words_and(o.data(), a.data(), b.data(), words);
            for (int i = 0; i < words; ++i) CHECK(o[i] == ref[i], "and");
            for (int i = 0; i < words; ++i) ref[i] = a[i] | b[i];
            _vl_words_or(o.data(), a.data(), b.data(), words);
            for (int i = 0; i < words; ++i) CHECK(o[i] == ref[i], "or");
            for (int i = 0; i < words; ++i) ref[i] = a[i] ^ b[i];
            _vl_words_xor(o.data(), a.data(), b.data(), words);
            for (int i = 0; i < words; ++i) CHECK(o[i] == ref[i], "xor");
            for (int i = 0; i < words; ++i) ref[i] = ~a[i];
            _vl_words_not(o.data(), a.data(), b.data(), words);
            for (int i = 0; i < words; ++i) CHECK(o[i] == ref[i], "not");
            for (int i = 0; i < words; ++i) ref[i] = a[i] & ~b[i];
            _vl_words_andnot(o.data(), a.data(), b.data(), words);
            for (int i = 0; i < words; ++i) CHECK(o[i] == ref[i], "andnot");
            // reductions
            EData acc;
            acc = 0; for (int i = 0; i < words; ++i) acc |= (a[i] ^ b[i]);
            CHECK(_vl_words_orxor(a.data(), b.data(), words) == acc, "orxor");
            acc = 0; for (int i = 0; i < words; ++i) acc |= a[i];
            CHECK(_vl_words_orall(a.data(), words) == acc, "orall");
            acc = 0; for (int i = 0; i < words; ++i) acc ^= a[i];
            CHECK(_vl_words_xorall(a.data(), words) == acc, "xorall");
            // funnel: dst[t]=(src[t]>>shr)|(src[t+1]<<shl), src has n+1 words
            for (int n = 1; n <= MAXW - 1; ++n) {
                std::vector<EData> src(n + 1), dst(n), dref(n);
                for (int i = 0; i <= n; ++i) src[i] = rnd();
                int shr = 1 + (rnd() % 31), shl = 32 - shr;  // shr+shl==32, both in (0,32)
                _vl_words_funnel(dst.data(), src.data(), n, shr, shl);
                for (int t = 0; t < n; ++t)
                    dref[t] = (src[t] >> shr) | (src[t + 1] << shl);
                for (int t = 0; t < n; ++t) CHECK(dst[t] == dref[t], "funnel");
            }
        }
    }
    if (fails == 0) std::printf("SIMD_HALF_TEST_OK\n");
    else std::printf("SIMD_HALF_TEST_FAILS=%d\n", fails);
    return fails ? 1 : 0;
}
