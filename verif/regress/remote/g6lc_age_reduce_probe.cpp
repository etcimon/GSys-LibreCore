// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <initializer_list>

constexpr uint64_t mask40 = (UINT64_C(1) << 40) - 1;
struct Age {
    uint32_t words[50];
};

static uint64_t row(const Age& age, unsigned r) {
    const unsigned start = r * 40;
    const unsigned w = start / 32;
    // Start is byte aligned, so a 40-bit row fits in two words, including row 39.
    return ((age.words[w] | (uint64_t(age.words[w+1]) << 32)) >> (start % 32)) & mask40;
}

static uint64_t oracle(const Age& a, uint64_t cand) {
    uint64_t result = cand;
    for (unsigned c = 0; c < 40; ++c) {
        for (unsigned r = 0; r < 40; ++r) {
            const unsigned ix = 40*r+c;
            if (((cand >> r) & (a.words[ix/32] >> (ix%32))) & 1) {
                result &= ~(UINT64_C(1) << c);
                break;
            }
        }
    }
    return result;
}

__attribute__((noinline)) static uint64_t sparse(const Age& a, uint64_t cand) {
    uint64_t blocked = 0;
    for (uint64_t left = cand; left; left &= left-1) blocked |= row(a, __builtin_ctzll(left));
    return cand & ~blocked;
}

__attribute__((noinline)) static uint64_t scan(const Age& a, uint64_t cand) {
    uint64_t blocked = 0;
    for (unsigned r = 0; r < 40; ++r) blocked |= row(a, r) & (0ULL - ((cand >> r) & 1));
    return cand & ~blocked;
}

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    uint64_t seed = 54321;
    auto next = [&]() { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed; };
    Age data[32]{};
    uint64_t masks[1024];
    for (unsigned g = 0; g < 32; ++g) {
        for (unsigned r = 0; r < 40; ++r) for (unsigned c = 0; c < 40; ++c) {
            const unsigned ix = 40*r+c;
            if ((r+g)%40 < (c+g)%40) data[g].words[ix/32] |= 1U << (ix%32);
        }
    }
    for (unsigned i = 0; i < 1024; ++i) {
        const uint64_t random = next();
        const uint64_t cand = argv[2][0] == 's' ? UINT64_C(1) << (random % 40)
                            : argv[2][0] == 'f' ? mask40 : random & mask40;
        masks[i] = cand;
        for (auto c : {cand, uint64_t(0), random & mask40}) {
            const auto ref = oracle(data[i%32], c);
            if (sparse(data[i%32], c) != ref || scan(data[i%32], c) != ref) return 1;
        }
    }
    auto fn = argv[1][0] == 's' ? sparse : scan;
    uint64_t h = 0;
    const auto begin = std::chrono::steady_clock::now();
    for (unsigned i = 0; i < 4000000; ++i) h += fn(data[(i>>5)%32], masks[i%1024]);
    double s = std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
    std::printf("%.3f M eval/s checksum=%llx\n", 4/s, static_cast<unsigned long long>(h));
}
