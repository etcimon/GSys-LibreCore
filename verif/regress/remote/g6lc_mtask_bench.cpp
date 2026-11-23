// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include "Vg6lc_mtask_bench.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <sched.h>
#include <unistd.h>

#ifndef BENCH_ROUNDS
#define BENCH_ROUNDS 0
#endif

// Start under taskset with two CPUs. Pin the model's worker and caller separately.
static bool pin_lanes() {
    cpu_set_t allowed;
    if (sched_getaffinity(0, sizeof allowed, &allowed) || CPU_COUNT(&allowed) != 2) return false;
    int first = 0;
    while (!CPU_ISSET(first, &allowed)) ++first;
    DIR* tasks = opendir("/proc/self/task");
    if (!tasks) return false;
    int count = 0;
    bool ok = true;
    while (const auto* ent = readdir(tasks)) {
        const int tid = std::atoi(ent->d_name);
        if (!tid) continue;
        cpu_set_t lane = allowed;
        if (tid == getpid()) {
            CPU_ZERO(&lane);
            CPU_SET(first, &lane);
        } else {
            CPU_CLR(first, &lane);
        }
        if (sched_setaffinity(tid, sizeof lane, &lane)) ok = false;
        ++count;
    }
    closedir(tasks);
    return ok && count == 2;
}

static uint32_t reference(int cycles) {
    uint32_t x[24], y[24], r = 1, hash = 0;
    for (unsigned k = 0; k < 24; ++k) { x[k] = k + 1; y[k] = k; }
    for (int i = 0; i < cycles; ++i) {
        r = r * 1664525u + 1013904223u;
        uint32_t sum = 0;
        for (unsigned k = 0; k < 24; ++k) {
            y[k] += x[k] ^ x[(k + 1) % 24];
            sum += y[k];
        }
        for (unsigned k = 0; k < 24; ++k) {
            uint32_t v = ((x[k] << 7) | (x[k] >> 25)) + (r ^ (37u * k));
            for (int j = 0; j < BENCH_ROUNDS; ++j) v = ((v << 11) | (v >> 21)) ^ ((v + r) >> 3);
            x[k] = v;
        }
        hash = hash * 33 + sum;
    }
    return hash;
}

int main() {
    constexpr int warm = 4096, cycles = 250000;
    VerilatedContext context;
    context.threads(2);
    Vg6lc_mtask_bench model{&context};
    model.clk = 0;
    model.stimulus = 0;
    model.eval();
    if (!pin_lanes()) {
        std::fprintf(stderr, "Expected a two-thread model and a two-CPU affinity mask\n");
        return 2;
    }
    using Clock = std::chrono::steady_clock;
    Clock::time_point start;
    uint32_t r = 1, hash = 0;
    for (int i = 0; i < warm + cycles; ++i) {
        if (i == warm) start = Clock::now();
        r = r * 1664525u + 1013904223u;
        model.stimulus = r;
        model.clk = 1;
        model.eval();
        model.clk = 0;
        model.eval();
        hash = hash * 33 + model.digest;
    }
    const double seconds = std::chrono::duration<double>(Clock::now() - start).count();
    model.final();
    const uint32_t expected = reference(warm + cycles);
    if (hash != expected) {
        std::fprintf(stderr, "Checksum mismatch: %08x != %08x\n", hash, expected);
        return 1;
    }
    std::printf("%08x %.0f simulated cycles/s\n", hash, cycles / seconds);
}
