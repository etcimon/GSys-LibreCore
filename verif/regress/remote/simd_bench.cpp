// Micro-benchmark: isolate the half-width SIMD tier effect on 4-7 word ops.
// Runs elementwise + funnel kernels over a 6-word (192-bit) buffer in a hot
// loop; the ONLY variable is which verilated_types.h the TU includes.
#include "verilated.h"
#include <cstdio>
#include <cstdint>

int main() {
    constexpr int W = 6;  // 192 bits -> the gap the half-tier closes
    EData a[W], b[W], o[W], d[W + 1];
    for (int i = 0; i < W; ++i) { a[i] = 0x9e3779b9u * (i + 1); b[i] = 0x85ebca6bu * (i + 3); }
    volatile EData sink = 0;
    const int N = 20000000;
    for (int n = 0; n < N; ++n) {
        _vl_words_and(o, a, b, W);
        _vl_words_or(o, a, b, W);
        _vl_words_xor(o, a, b, W);
        sink ^= o[0];
        // funnel over W words (reads W+1 src words -> need d sized W+1)
        EData src[W + 1];
        for (int i = 0; i <= W; ++i) src[i] = a[i % W] + i;
        _vl_words_funnel(d, src, W, 7, 25);
        sink ^= d[0];
    }
    std::printf("sink=%u\n", (unsigned)sink);
    return 0;
}
