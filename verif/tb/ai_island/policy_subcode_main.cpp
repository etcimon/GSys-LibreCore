// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

#include "Vtb_g6lc_ai_policy_subcode.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using U64 = std::uint64_t;
using U32 = std::uint32_t;

struct Topology {
    unsigned valid = 0, apply = 0, rows = 0, cols = 0, reduction = 0;
    unsigned slots = 0, bits = 0, gain = 0;
    U32 pack() const {
        return (valid << 22) | (apply << 21) | (rows << 18) | (cols << 15) |
               (reduction << 11) | (slots << 7) | (bits << 4) | gain;
    }
    static Topology unpack(U32 value) {
        return {(value >> 22) & 1, (value >> 21) & 1, (value >> 18) & 7,
                (value >> 15) & 7, (value >> 11) & 15, (value >> 7) & 15,
                (value >> 4) & 7, value & 15};
    }
};

struct Job {
    unsigned code = 0, fmt = 0, m = 1, n = 1, k = 1, balance = 1;
    bool override_baseline = false;
    U32 baseline = 0;
};

struct Parameters {
    U32 read_bytes, min_savings, switch_cycles, steps, min_reduction, groups;
};

struct Result {
    bool evaluated = false;
    unsigned subcode = 0;
    U32 topology = 0;
    U64 baseline = 0, selected = 0, best = 0;
    std::array<bool, 8> legal{};
    std::array<U64, 8> costs{};
};

static unsigned format_bits(unsigned fmt) {
    constexpr unsigned bits[] = {3, 2, 3, 3, 3, 4, 4, 5};
    return bits[fmt];
}

static unsigned family(unsigned code) {
    if (code == 0) return 0;
    if (code == 3) return 1;
    if (code == 5) return 2;
    if (code == 6) return 3;
    return 4;
}

static bool same_key(const Job &a, U32 abase, const Job &b, U32 bbase) {
    return a.code == b.code && a.fmt == b.fmt && a.m == b.m && a.n == b.n && a.k == b.k && abase == bbase;
}

static U64 ceil_div(U64 value, U64 divisor) {
    return value / divisor + (value % divisor != 0);
}

static U64 resource_cost(const Job &job, const Topology &t, const Parameters &p) {
    const U64 rows = U64{1} << t.rows;
    const U64 cols = U64{1} << t.cols;
    const unsigned quantum = 1U << t.reduction;
    const U64 step = (p.steps >> (job.fmt * 4)) & 15;
    U64 cycles_per_group = 0;
    for (unsigned offset = 0; offset < job.k;) {
        const unsigned elements = std::min(quantum, job.k - offset);
        const U64 bytes_per_row = ceil_div(U64{elements} * (U64{1} << t.bits), 8);
        const U64 read_cycles = ceil_div((rows + cols) * bytes_per_row, p.read_bytes);
        cycles_per_group += std::max(step, read_cycles);
        offset += elements;
    }
    return (job.m / rows) * (job.n / cols) * cycles_per_group;
}

static Result reference(const Job &job, U32 baseline, const Parameters &p) {
    Result result;
    result.topology = baseline;
    const Topology original = Topology::unpack(baseline);
    if (!original.valid || job.fmt == 2 || family(job.code) == 4 ||
        job.m == 0 || job.n == 0 || job.k == 0 ||
        job.m > 256 || job.n > 256 || job.k > 256 ||
        original.slots < 1 || original.slots > 9 || original.rows > 4 || original.cols > 4 ||
        original.rows + original.cols > 4 ||
        original.rows + original.cols + original.reduction != original.slots ||
        original.bits != format_bits(job.fmt) ||
        job.m % (1U << original.rows) || job.n % (1U << original.cols))
        return result;
    result.evaluated = true;
    result.legal[0] = true;
    result.baseline = resource_cost(job, original, p);
    result.costs[0] = result.baseline;
    result.best = result.baseline;
    unsigned best_index = 0;
    Topology best_topology = original;
    for (unsigned index = 1; index < 8; ++index) {
        Topology candidate = original;
        if (index == 1) {
            candidate.rows = 0;
            candidate.cols = 0;
        } else if (index < 7) {
            candidate.rows = index - 2;
            candidate.cols = 4 - candidate.rows;
        } else {
            const unsigned shape = (p.groups >> (6 * family(job.code))) & 63;
            candidate.rows = shape >> 3;
            candidate.cols = shape & 7;
        }
        const unsigned sum = candidate.rows + candidate.cols;
        if (candidate.rows > 4 || candidate.cols > 4 || sum > 4 || sum > original.slots)
            continue;
        candidate.reduction = original.slots - sum;
        if ((job.m % (1U << candidate.rows)) || (job.n % (1U << candidate.cols)) ||
            candidate.reduction < ((p.min_reduction >> (4 * job.fmt)) & 15))
            continue;
        candidate.apply = sum != 0;
        const unsigned rows = 1U << candidate.rows;
        const unsigned cols = 1U << candidate.cols;
        candidate.gain = (16 * (2 * rows * cols - rows - cols)) / (2 * rows * cols);
        result.legal[index] = true;
        const U64 cost = resource_cost(job, candidate, p);
        result.costs[index] = cost;
        if (cost < result.best) {
            result.best = cost;
            best_index = index;
            best_topology = candidate;
        }
    }
    if (best_index != 0 && result.best + p.switch_cycles + 32 + p.min_savings < result.baseline) {
        result.subcode = best_index;
        result.topology = best_topology.pack();
        result.selected = result.best + 32 + p.switch_cycles;
    } else {
        result.selected = result.baseline + 32;
    }
    if (result.baseline > std::numeric_limits<U32>::max() ||
        result.selected > std::numeric_limits<U32>::max())
        throw std::runtime_error("reference cycle counter overflow");
    return result;
}

struct Totals {
    U64 jobs = 0, macs = 0, baseline = 0, selected = 0, external = 0;
    U64 improved = 0, regressed = 0, unchanged = 0;
};

class Bench {
public:
    Vtb_g6lc_ai_policy_subcode dut;
    std::mt19937_64 random;
    Parameters params{};
    U64 checks = 0, cases = 0, eligible = 0, rejected = 0, cancelled = 0, busy_starts = 0;
    U64 held = 0, boundary_equal = 0, boundary_below = 0, boundary_above = 0, ties = 0;
    std::array<U64, 8> winners{}, legal{};
    std::array<std::array<Totals, 8>, 4> totals{};
    std::string context;
    Job steer_job{};
    Result steer_result{};
    U32 steer_baseline = 0;
    unsigned steer_remaining = 0;
    bool steer_valid = false;
    U64 steer_accepts = 0, steer_results = 0, steer_cancellations = 0, steer_ticks = 0;
    unsigned steer_formats = 0, steer_families = 0;
    bool steer_cache_valid = false, steer_seen = false, steer_last = false;
    bool steer_pending_hit = false, steer_hit = false;
    Job steer_cached_job{};
    U32 steer_cached_baseline = 0;
    Result steer_cached_result{};
    U64 cache_hits = 0, cache_misses = 0, steer_cache_hits = 0;

    explicit Bench(U64 seed) : random(seed) {
        dut.clk_i = 0;
        dut.rst_ni = 0;
        dut.enable_i = 0;
        dut.flush_i = 0;
        dut.cancel_i = 0;
        dut.start_i = 0;
        dut.testmode_i = 0;
        dut.steer_enable_i = 0;
        dut.steer_flush_i = 0;
        dut.steer_valid_i = 0;
        dut.steer_batch_first_i = 0;
        dut.steer_batch_last_i = 0;
        dut.steer_m_i = 0;
        dut.steer_n_i = 0;
        dut.steer_k_i = 0;
        dut.steer_opcode_i = 0;
        dut.steer_numfmt_i = 0;
        dut.steer_balance_i = 0;
        for (unsigned i = 0; i < 8; ++i) dut.steer_sample_i[i] = 0;
        dut.steer_sample_valid_i = 0;
        dut.steer_exact_zero_i = 0;
        dut.steer_next_addr_i = 0;
        dut.steer_next_addr_valid_i = 0;
        dut.steer_mispredict_i = 0;
        drive(Job{});
        dut.eval();
        params = {dut.read_bytes_o, dut.min_savings_o, dut.switch_cycles_o,
                  dut.format_steps_o, dut.format_min_reduction_o, dut.group_shapes_o};
        tick();
        clear_result("reset");
        dut.rst_ni = 1;
        dut.enable_i = 1;
        tick();
        require(dut.ready_o, "ready after reset");
    }

    void require(bool condition, const std::string &message) {
        ++checks;
        if (!condition) throw std::runtime_error(context + ": " + message);
    }

    void eval() {
        dut.eval();
        require(!dut.disabled_nonzero_o, "Enabled=0 output nonzero");
        if (!dut.cache_enabled_o)
            require(!dut.cache_hit_o && !dut.steer_subcode_cache_hit_o, "disabled cache hit output nonzero");
        require(!dut.steer_legacy_mismatch_o, "subcode config gate changed original steering outputs");
        require(!dut.steer_disabled_nonzero_o, "PolicySubcodeEn=0 output nonzero");
    }

    void tick() {
        dut.clk_i = 0;
        eval();
        dut.clk_i = 1;
        eval();
        dut.clk_i = 0;
        eval();
    }

    void drive(const Job &job) {
        dut.code_i = job.code;
        dut.numfmt_i = job.fmt;
        dut.m_i = job.m;
        dut.n_i = job.n;
        dut.k_i = job.k;
        dut.balance_i = job.balance;
        dut.baseline_override_i = job.override_baseline;
        dut.baseline_i = job.baseline;
    }

    void noise() {
        Job job;
        job.code = random() & 7;
        job.fmt = random() & 7;
        job.m = random() & 65535;
        job.n = random() & 65535;
        job.k = random() & 65535;
        job.balance = random() & 3;
        job.override_baseline = true;
        job.baseline = random() & ((1U << 23) - 1);
        drive(job);
        dut.testmode_i = random() & 1;
    }

    void clear_result(const std::string &name) {
        require(!dut.busy_o && !dut.valid_o && !dut.evaluated_o && !dut.cache_hit_o,
                name + " status not cleared");
        require(!dut.subcode_o && !dut.topology_o && !dut.baseline_cycles_o &&
                !dut.selected_cycles_o, name + " data not cleared");
    }

    void compare(const Result &expected) {
        require(dut.valid_o && !dut.busy_o && dut.ready_o, "completed handshake");
        require(dut.evaluated_o == expected.evaluated, "evaluated mismatch");
        require(dut.subcode_o == expected.subcode, "subcode got=" + std::to_string(dut.subcode_o) +
                " expected=" + std::to_string(expected.subcode));
        require(dut.topology_o == expected.topology, "topology got=" + std::to_string(dut.topology_o) +
                " expected=" + std::to_string(expected.topology));
        require(dut.baseline_cycles_o == expected.baseline, "baseline cycles got=" +
                std::to_string(dut.baseline_cycles_o) + " expected=" + std::to_string(expected.baseline));
        require(dut.selected_cycles_o == expected.selected, "selected cycles got=" +
                std::to_string(dut.selected_cycles_o) + " expected=" + std::to_string(expected.selected));
    }

    Result run(const Job &job, bool account = false, unsigned hold_cycles = 1) {
        std::ostringstream label;
        label << "case=" << cases << " code=" << job.code << " fmt=" << job.fmt
              << " M/N/K=" << job.m << '/' << job.n << '/' << job.k;
        context = label.str();
        drive(job);
        dut.start_i = 0;
        dut.testmode_i = cases & 1;
        eval();
        require(dut.ready_o, "not ready for start");
        const U32 baseline = dut.baseline_o;
        const Result expected = reference(job, baseline, params);
        dut.start_i = 1;
        tick();
        dut.start_i = 0;
        if (expected.evaluated) {
            ++eligible;
            require(dut.busy_o && !dut.valid_o && !dut.ready_o, "eligible acceptance");
            for (unsigned cycle = 1; cycle <= 32; ++cycle) {
                noise();
                dut.start_i = (cycle == 1 || cycle == 4 || cycle == 16 || cycle == 31 || cycle == 32);
                busy_starts += dut.start_i;
                tick();
                if (cycle != 32)
                    require(dut.busy_o && !dut.valid_o && !dut.ready_o,
                            "early completion cycle=" + std::to_string(cycle));
            }
            for (unsigned i = 0; i < 8; ++i) legal[i] += expected.legal[i];
            ++winners[expected.subcode];
            const U64 threshold = expected.best + params.switch_cycles + 32 + params.min_savings;
            boundary_equal += threshold == expected.baseline;
            boundary_below += threshold + 1 == expected.baseline;
            boundary_above += threshold == expected.baseline + 1;
            for (unsigned i = 1; i < 8; ++i)
                ties += expected.legal[i] && expected.costs[i] == expected.best;
        } else {
            ++rejected;
        }
        dut.start_i = 0;
        compare(expected);
        for (unsigned cycle = 0; cycle < hold_cycles; ++cycle) {
            noise();
            tick();
            compare(expected);
            ++held;
        }
        if (account && expected.evaluated) {
            Totals &t = totals[family(job.code)][job.fmt];
            const U64 external = ceil_div((U64{job.m} + job.n) *
                    ceil_div(U64{job.k} * (U64{1} << format_bits(job.fmt)), 8) +
                    U64{8} * job.m * job.n, 8);
            ++t.jobs;
            t.macs += U64{job.m} * job.n * job.k;
            t.external += external;
            t.baseline += expected.baseline + external;
            t.selected += expected.selected + external;
            t.improved += expected.selected < expected.baseline;
            t.regressed += expected.selected > expected.baseline;
            t.unchanged += expected.selected == expected.baseline;
        }
        ++cases;
        return expected;
    }

    Result run_cached(const Job &job, bool hit) {
        context = "cache case=" + std::to_string(cache_hits + cache_misses) +
            " expected_hit=" + std::to_string(hit);
        drive(job);
        dut.start_i = 0;
        eval();
        const Result miss_result = reference(job, dut.baseline_o, params);
        Result expected = miss_result;
        require(!hit || expected.evaluated, "ineligible cache hit requested");
        if (hit) expected.selected -= 31;
        require(dut.ready_o, "cache start not ready");
        dut.start_i = 1;
        tick();
        dut.start_i = 0;
        require(!dut.cache_hit_o, "cache hit visible before completion");
        if (expected.evaluated) {
            require(dut.busy_o && !dut.valid_o && !dut.ready_o, "cache acceptance");
            const unsigned latency = hit ? 1 : 32;
            for (unsigned cycle = 1; cycle <= latency; ++cycle) {
                noise();
                dut.start_i = 1;
                tick();
                if (cycle != latency)
                    require(dut.busy_o && !dut.valid_o && !dut.cache_hit_o, "early cache completion");
            }
        }
        dut.start_i = 0;
        compare(expected);
        require(dut.cache_hit_o == hit, "cache hit observation mismatch");
        for (unsigned hold = 0; hold < 3; ++hold) {
            noise();
            tick();
            compare(expected);
            require(dut.cache_hit_o == hit, "cache held result changed");
        }
        cache_hits += hit;
        cache_misses += !hit;
        return miss_result;
    }

    void cancel(unsigned kind, unsigned age) {
        Job job{0, 1, 128, 128, 255, 1, false, 0};
        context = "cancel kind=" + std::to_string(kind) + " age=" + std::to_string(age);
        drive(job);
        dut.start_i = 1;
        tick();
        require(dut.busy_o && !dut.valid_o, "cancellation job not accepted");
        dut.start_i = 0;
        for (unsigned cycle = 0; cycle < age; ++cycle) tick();
        noise();
        dut.start_i = 1;
        if (kind == 0) dut.flush_i = 1;
        if (kind == 1) dut.enable_i = 0;
        if (kind == 2) dut.rst_ni = 0;
        eval();
        if (kind == 2) clear_result("asynchronous cancellation");
        tick();
        clear_result("cancellation");
        if (kind != 2) require(!dut.ready_o, "ready during flush/disable");
        dut.start_i = 0;
        dut.flush_i = 0;
        dut.enable_i = 1;
        dut.rst_ni = 1;
        for (unsigned cycle = 0; cycle < 36; ++cycle) {
            noise();
            tick();
            clear_result("cancelled result resurfaced");
            require(dut.ready_o, "cancelled controller not ready");
        }
        ++cancelled;
        run(job, false, 2);
    }

    void steer_tick() {
        context = "steering cycle=" + std::to_string(steer_ticks);
        eval();
        const bool accept = dut.steer_valid_i && dut.steer_ready_o && dut.rst_ni;
        const bool epoch = !dut.rst_ni || !dut.steer_enable_i || dut.steer_flush_i ||
            (accept && (dut.steer_batch_first_i || steer_last ||
                        (steer_seen && dut.steer_numfmt_i != steer_job.fmt)));
        const bool clear = !dut.rst_ni || !dut.steer_enable_i || dut.steer_flush_i || accept;
        if (epoch) steer_cache_valid = false;
        if (!dut.rst_ni || !dut.steer_enable_i || dut.steer_flush_i) {
            steer_seen = false;
            steer_last = false;
        }
        Job accepted;
        if (accept) {
            accepted.fmt = dut.steer_numfmt_i;
            accepted.m = dut.steer_m_i;
            accepted.n = dut.steer_n_i;
            accepted.k = dut.steer_k_i;
            accepted.balance = dut.steer_balance_i;
        }
        if (clear) {
            steer_cancellations += steer_remaining != 0 || steer_valid;
            steer_remaining = 0;
            steer_valid = false;
            steer_hit = false;
            steer_pending_hit = false;
        } else if (dut.steer_work_valid_o) {
            steer_result = reference(steer_job, steer_baseline, params);
            steer_pending_hit = dut.cache_enabled_o && steer_cache_valid && steer_result.evaluated &&
                same_key(steer_job, steer_baseline, steer_cached_job, steer_cached_baseline);
            if (steer_pending_hit) {
                steer_result = steer_cached_result;
                steer_result.selected -= 31;
            } else {
                steer_cache_valid = false;
                steer_cached_job = steer_job;
                steer_cached_baseline = steer_baseline;
                steer_cached_result = steer_result;
            }
            steer_remaining = steer_result.evaluated ? (steer_pending_hit ? 1 : 32) : 0;
            steer_valid = !steer_result.evaluated;
            steer_hit = false;
            steer_results += steer_valid;
        } else if (steer_remaining) {
            --steer_remaining;
            if (!steer_remaining) {
                steer_valid = true;
                steer_cache_valid = dut.cache_enabled_o;
                steer_hit = steer_pending_hit;
                steer_cache_hits += steer_hit;
                ++steer_results;
            }
        }
        tick();
        require(dut.steer_ready_o == (dut.steer_enable_i && !dut.steer_flush_i),
                "sidecar must never backpressure original steering");
        require(dut.steer_work_valid_o == (accept && dut.steer_enable_i && !dut.steer_flush_i),
                "original work-valid acceptance alignment");
        if (accept && dut.steer_enable_i && !dut.steer_flush_i) {
            steer_seen = true;
            steer_last = dut.steer_batch_last_i;
            steer_job = accepted;
            steer_job.code = dut.steer_code_o;
            steer_baseline = dut.steer_topology_o;
            require(dut.steer_numfmt_o == accepted.fmt, "accepted numeric format misaligned");
            steer_formats |= 1U << accepted.fmt;
            if (family(steer_job.code) < 4) steer_families |= 1U << family(steer_job.code);
            ++steer_accepts;
        }
        require(dut.steer_subcode_valid_o == steer_valid, "stale or mistimed sidecar result");
        require(dut.steer_subcode_cache_hit_o == steer_hit, "stale or mistimed sidecar cache hit");
        if (clear) {
            require(!dut.steer_subcode_evaluated_o && !dut.steer_subcode_o &&
                    !dut.steer_subcode_topology_o && !dut.steer_baseline_cycles_o &&
                    !dut.steer_selected_cycles_o, "accepted input/cancellation did not clear sidecar");
        }
        if (steer_valid) {
            require(dut.steer_subcode_evaluated_o == steer_result.evaluated, "sidecar evaluated alignment");
            require(dut.steer_subcode_o == steer_result.subcode, "sidecar selected index alignment");
            require(dut.steer_subcode_topology_o == steer_result.topology, "sidecar topology alignment");
            require(dut.steer_baseline_cycles_o == steer_result.baseline, "sidecar baseline cost alignment");
            require(dut.steer_selected_cycles_o == steer_result.selected, "sidecar selected cost alignment");
        }
        ++steer_ticks;
    }

    void steer_drive(unsigned fmt, unsigned shape, bool first = true) {
        dut.steer_numfmt_i = fmt;
        dut.steer_m_i = shape == 1 ? 1 : 64;
        dut.steer_n_i = 128;
        if (shape != 1) dut.steer_n_i = 64;
        dut.steer_k_i = 127;
        dut.steer_opcode_i = shape == 2 ? 2 : 0;
        dut.steer_balance_i = shape == 3 ? 2 : 1;
        dut.steer_batch_first_i = first;
        dut.steer_batch_last_i = 0;
        dut.steer_sample_valid_i = shape == 3;
        dut.steer_exact_zero_i = shape == 3;
        for (unsigned i = 0; i < 8; ++i) dut.steer_sample_i[i] = 0;
        dut.steer_next_addr_i = 0x80000000ULL + (steer_ticks << 6);
        dut.steer_next_addr_valid_i = steer_ticks & 1;
        dut.steer_mispredict_i = (steer_ticks % 7) == 0;
        dut.steer_valid_i = 1;
    }

    void steer_idle(unsigned cycles) {
        dut.steer_valid_i = 0;
        for (unsigned cycle = 0; cycle < cycles; ++cycle) {
            dut.steer_numfmt_i = random() & 7;
            dut.steer_m_i = random() & 65535;
            dut.steer_n_i = random() & 65535;
            dut.steer_k_i = random() & 65535;
            dut.testmode_i = random() & 1;
            steer_tick();
        }
    }

    void integration() {
        dut.start_i = 0;
        dut.steer_enable_i = 1;
        dut.steer_flush_i = 1;
        steer_tick();
        dut.steer_flush_i = 0;
        for (unsigned fmt = 0; fmt < 8; ++fmt) {
            for (unsigned shape = 0; shape < 4; ++shape) {
                const unsigned repeats = shape == 3 ? 12 : 1;
                for (unsigned repeat = 0; repeat < repeats; ++repeat) {
                    steer_drive(fmt, shape, repeat == 0);
                    steer_tick();
                }
                steer_idle(40);
            }
        }
        for (unsigned age = 0; age <= 35; ++age) {
            steer_drive(0, 0);
            steer_tick();
            steer_idle(age);
            steer_drive((age % 7) + 1, age % 3);
            steer_tick();
            steer_idle(40);
            for (unsigned kind = 0; kind < 3; ++kind) {
                steer_drive(1, 0);
                steer_tick();
                steer_idle(age);
                dut.steer_valid_i = 1;
                if (kind == 0) dut.steer_flush_i = 1;
                if (kind == 1) dut.steer_enable_i = 0;
                if (kind == 2) dut.rst_ni = 0;
                steer_tick();
                dut.steer_valid_i = 0;
                dut.steer_flush_i = 0;
                dut.steer_enable_i = 1;
                dut.rst_ni = 1;
                steer_idle(40);
                steer_drive((age + kind) % 8, kind);
                steer_tick();
                steer_idle(36);
            }
        }
        for (unsigned cycle = 0; cycle < 128; ++cycle) {
            steer_drive(cycle % 8, cycle % 4, (cycle % 5) == 0);
            steer_tick();
            require(!dut.steer_subcode_valid_o, "burst leaked previous sidecar result");
        }
        steer_idle(64);
        for (unsigned cycle = 0; cycle < 2000; ++cycle) {
            steer_drive(random() % 8, random() % 4, random() & 1);
            dut.steer_opcode_i = random() & 7;
            dut.steer_valid_i = random() % 100 < 35;
            dut.steer_flush_i = random() % 100 < 2;
            dut.steer_enable_i = random() % 100 >= 3;
            dut.rst_ni = random() % 100 >= 1;
            steer_tick();
        }
        dut.steer_enable_i = 1;
        dut.steer_flush_i = 0;
        dut.rst_ni = 1;
        steer_drive(7, 2);
        steer_tick();
        steer_idle(40);
        require(steer_accepts > 500 && steer_results > 100 && steer_cancellations > 100,
                "insufficient steering integration coverage");
        require(steer_formats == 255 && steer_families == 15, "missing steering formats/families");
        std::cout << "INTEGRATION PASS accepts=" << steer_accepts << " results=" << steer_results
                  << " cancellations=" << steer_cancellations << " cycles=" << steer_ticks
                  << " formats=" << steer_formats << " families=" << steer_families
                  << " ages=0..35 burst=128 legacy_equivalence=all_outputs\n";
    }

    void report() {
        constexpr const char *names[] = {"bulk", "decode", "routed", "sparse"};
        std::cout << "SCOPE controller RTL checked against independent conflict-free resource model; "
                     "MAC/cycle model includes shared external bytes/8, not measured GEMM/SoC throughput\n";
        std::cout << std::fixed << std::setprecision(6);
        for (unsigned group = 0; group < 4; ++group) {
            for (unsigned fmt = 0; fmt < 8; ++fmt) {
                const Totals &t = totals[group][fmt];
                if (!t.jobs) continue;
                const double base_rate = static_cast<double>(t.macs) / t.baseline;
                const double chosen_rate = static_cast<double>(t.macs) / t.selected;
                const double delta = 100.0 * (chosen_rate / base_rate - 1.0);
                std::cout << "MODEL {\"family\":\"" << names[group] << "\",\"fmt\":" << fmt
                          << ",\"jobs\":" << t.jobs << ",\"macs\":" << t.macs
                          << ",\"baseline_cycles\":" << t.baseline << ",\"selected_cycles\":" << t.selected
                          << ",\"shared_external_cycles\":" << t.external
                          << ",\"baseline_macs_per_cycle\":" << base_rate
                          << ",\"selected_macs_per_cycle\":" << chosen_rate
                          << ",\"delta_percent\":" << delta
                          << ",\"regression\":" << (t.selected > t.baseline ? "true" : "false")
                          << ",\"improved_jobs\":" << t.improved << ",\"regressed_jobs\":" << t.regressed
                          << ",\"unchanged_jobs\":" << t.unchanged << "}\n";
            }
        }
        std::cout << "COVERAGE legal=";
        for (auto count : legal) std::cout << count << ',';
        std::cout << " winners=";
        for (auto count : winners) std::cout << count << ',';
        std::cout << " threshold_equal=" << boundary_equal << " threshold_one_below=" << boundary_below
                  << " threshold_one_above=" << boundary_above << " ties=" << ties
                  << " held=" << held << " busy_starts=" << busy_starts << " cancelled=" << cancelled << '\n';
        std::cout << "PASS policy_subcode cases=" << cases << " eligible=" << eligible
                  << " ineligible=" << rejected << " checks=" << checks << '\n';
    }
};

static void workload_fixtures(U64 seed) {
    struct Workload {
        const char *name;
        unsigned code;
        std::vector<std::array<unsigned, 3>> shapes;
    };
    const std::array<Workload, 4> workloads = {{
        {"dense_prefill", 0, {{128, 256, 256}, {256, 256, 256}, {128, 128, 128}}},
        {"dense_decode", 3, {{1, 256, 256}, {4, 256, 256}, {1, 128, 129}}},
        {"routed_experts", 5, {{3, 256, 256}, {7, 256, 256}, {17, 256, 256},
                               {33, 256, 255}, {65, 256, 256}}},
        {"diffusion_matrices", 0, {{256, 256, 256}, {256, 64, 64}, {256, 256, 80}, {235, 65, 256}}}
    }};
    constexpr std::array<unsigned, 7> formats = {0, 1, 3, 4, 5, 6, 7};
    Bench bench(seed);
    unsigned reports = 0;
    std::cout << "WORKLOAD_SCOPE handcrafted TILE fixtures, not full operator/model capture; "
                 "incremental current allocator baseline, not fixed-dot baseline; "
                 "same shape/format/clock, modeled MAC/cycle not absolute MAC/s\n";
    std::cout << std::fixed << std::setprecision(6);
    for (const auto &workload : workloads) {
        for (unsigned fmt : formats) {
            Totals totals;
            U64 baseline_compute = 0, selected_compute = 0, switch_cycles = 0;
            std::array<U64, 8> usage{};
            std::ostringstream tiles;
            bool first = true;
            for (const auto &shape : workload.shapes) {
                const Job job{workload.code, fmt, shape[0], shape[1], shape[2], 1, false, 0};
                bench.drive(job);
                bench.eval();
                const U32 baseline_topology = bench.dut.baseline_o;
                const Result result = bench.run(job, false, 0);
                bench.require(result.evaluated, "named TILE fixture unexpectedly ineligible");
                const U64 external = ceil_div((U64{job.m} + job.n) *
                        ceil_div(U64{job.k} * (U64{1} << format_bits(fmt)), 8) +
                        U64{8} * job.m * job.n, 8);
                const U64 switch_cost = result.subcode ? bench.params.switch_cycles : 0;
                ++totals.jobs;
                totals.macs += U64{job.m} * job.n * job.k;
                totals.external += external;
                totals.baseline += result.baseline + external;
                totals.selected += result.selected + external;
                totals.improved += result.selected < result.baseline;
                totals.regressed += result.selected > result.baseline;
                totals.unchanged += result.selected == result.baseline;
                baseline_compute += result.baseline;
                selected_compute += result.selected;
                switch_cycles += switch_cost;
                ++usage[result.subcode];
                if (!first) tiles << ',';
                first = false;
                tiles << "{\"m\":" << job.m << ",\"n\":" << job.n << ",\"k\":" << job.k
                      << ",\"baseline_topology\":" << baseline_topology
                      << ",\"selected_topology\":" << result.topology
                      << ",\"subcode\":" << result.subcode
                      << ",\"baseline_compute_cycles\":" << result.baseline
                      << ",\"selected_resource_cycles\":" << result.costs[result.subcode]
                      << ",\"selected_compute_cycles\":" << result.selected
                      << ",\"external_cycles\":" << external << '}';
            }
            const double time_reduction = 100.0 *
                    (1.0 - static_cast<double>(totals.selected) / totals.baseline);
            const double throughput_delta = 100.0 *
                    (static_cast<double>(totals.baseline) / totals.selected - 1.0);
            std::cout << "WORKLOAD_TILE {\"name\":\"" << workload.name
                      << "\",\"scope\":\"handcrafted TILE fixtures; not full operator/model capture\""
                      << ",\"baseline\":\"current_allocator\",\"fmt\":" << fmt
                      << ",\"code\":" << workload.code << ",\"balance\":1,\"jobs\":" << totals.jobs
                      << ",\"macs\":" << totals.macs
                      << ",\"baseline_compute_cycles\":" << baseline_compute
                      << ",\"selected_compute_cycles\":" << selected_compute
                      << ",\"evaluator_cycles\":" << 32 * totals.jobs
                      << ",\"switch_cycles\":" << switch_cycles
                      << ",\"shared_external_cycles\":" << totals.external
                      << ",\"baseline_cycles\":" << totals.baseline
                      << ",\"selected_cycles\":" << totals.selected
                      << ",\"time_reduction_percent\":" << time_reduction
                      << ",\"baseline_macs_per_cycle\":" << static_cast<double>(totals.macs) / totals.baseline
                      << ",\"selected_macs_per_cycle\":" << static_cast<double>(totals.macs) / totals.selected
                      << ",\"throughput_delta_percent\":" << throughput_delta
                      << ",\"regression\":" << (totals.selected > totals.baseline ? "true" : "false")
                      << ",\"improved_jobs\":" << totals.improved
                      << ",\"regressed_jobs\":" << totals.regressed
                      << ",\"unchanged_jobs\":" << totals.unchanged << ",\"winner_usage\":[";
            for (unsigned index = 0; index < usage.size(); ++index) {
                if (index) std::cout << ',';
                std::cout << usage[index];
            }
            std::cout << "],\"tiles\":[" << tiles.str() << "]}\n";
            ++reports;
        }
    }
    bench.require(bench.cases == 105 && reports == 28 && bench.rejected == 0,
                  "named TILE fixture count mismatch");
    std::cout << "WORKLOAD_FIXTURES PASS jobs=" << bench.cases << " reports=" << reports
              << " formats=7 checks=" << bench.checks << '\n';
    bench.dut.final();
}

static Job single_output(unsigned code, unsigned fmt, unsigned m, unsigned n, unsigned k,
                         unsigned slots = 8) {
    Topology t{1, 0, 0, 0, slots, slots, format_bits(fmt), 0};
    return {code, fmt, m, n, k, 1, true, t.pack()};
}

static void cache_tests(Bench &bench) {
    auto &dut = bench.dut;
    bench.require(dut.cache_enabled_o, "cache suite requires CacheEn=1");
    auto clear = [&](unsigned kind) {
        dut.start_i = 1;
        if (kind == 0) dut.flush_i = 1;
        if (kind == 1) dut.enable_i = 0;
        if (kind == 2) dut.rst_ni = 0;
        if (kind == 3) dut.cancel_i = 1;
        bench.eval();
        if (kind == 2) bench.clear_result("cache asynchronous reset");
        bench.tick();
        bench.clear_result("cache clear");
        dut.start_i = 0;
        dut.flush_i = 0;
        dut.enable_i = 1;
        dut.rst_ni = 1;
        dut.cancel_i = 0;
        for (unsigned cycle = 0; cycle < 36; ++cycle) {
            bench.noise();
            bench.tick();
            bench.clear_result("cache stale completion");
        }
    };
    const Job a = single_output(0, 1, 16, 16, 17, 9);
    for (unsigned code : {0U, 3U, 5U, 6U}) {
        for (unsigned fmt : {0U, 1U, 3U, 4U, 5U, 6U, 7U}) {
            for (unsigned dimension : {1U, 16U, 256U}) {
                clear(0);
                const Job job = single_output(code, fmt, dimension, dimension, dimension);
                bench.run_cached(job, false);
                for (unsigned repeat = 0; repeat < 4; ++repeat) bench.run_cached(job, true);
                clear(3);
                bench.run_cached(job, true);
            }
        }
    }
    for (unsigned axis = 0; axis < 3; ++axis) {
        for (unsigned bit = 0; bit < 16; ++bit) {
            clear(0);
            bench.run_cached(a, false);
            Job changed = a;
            if (axis == 0) changed.m ^= 1U << bit;
            if (axis == 1) changed.n ^= 1U << bit;
            if (axis == 2) changed.k ^= 1U << bit;
            bench.run_cached(changed, false);
            bench.run_cached(a, false);
            bench.run_cached(a, true);
        }
    }
    for (unsigned bit = 0; bit < 23; ++bit) {
        clear(0);
        bench.run_cached(a, false);
        Job changed = a;
        changed.baseline ^= 1U << bit;
        bench.run_cached(changed, false);
        bench.run_cached(a, false);
    }
    for (unsigned value = 0; value < 8; ++value) {
        for (unsigned field = 0; field < 2; ++field) {
            if ((field == 0 && value == a.code) || (field == 1 && value == a.fmt)) continue;
            clear(0);
            bench.run_cached(a, false);
            Job changed = a;
            if (field == 0) changed.code = value;
            else changed.fmt = value;
            bench.run_cached(changed, false);
            bench.run_cached(a, false);
        }
    }
    for (unsigned fmt : {0U, 1U, 3U, 4U, 5U, 6U, 7U}) {
        for (unsigned next_fmt : {0U, 1U, 3U, 4U, 5U, 6U, 7U}) {
            if (fmt == next_fmt) continue;
            clear(0);
            const Job first = single_output(0, fmt, 16, 16, 17);
            const Job next = single_output(0, next_fmt, 16, 16, 17);
            bench.run_cached(first, false);
            bench.run_cached(next, false);
            bench.run_cached(first, false);
        }
    }
    clear(0);
    bench.run_cached(a, false);
    Job nonkey = a;
    nonkey.balance = 0;
    bench.run_cached(nonkey, true);
    for (unsigned kind = 0; kind < 3; ++kind) {
        for (unsigned phase = 0; phase < 2; ++phase) {
            clear(0);
            bench.run_cached(a, false);
            if (phase == 1) {
                bench.drive(a);
                dut.start_i = 1;
                bench.tick();
                dut.start_i = 0;
                bench.require(dut.busy_o && !dut.valid_o, "pending hit not started");
            }
            clear(kind);
            bench.run_cached(a, false);
            bench.run_cached(a, true);
        }
    }
    for (unsigned age = 0; age < 32; ++age) {
        clear(0);
        bench.run_cached(a, false);
        Job changed = a;
        ++changed.k;
        bench.drive(changed);
        dut.start_i = 1;
        bench.tick();
        dut.start_i = 0;
        for (unsigned cycle = 0; cycle < age; ++cycle) bench.tick();
        clear(3);
        bench.run_cached(a, false);
        bench.run_cached(changed, false);
        bench.run_cached(changed, true);
    }
    clear(0);
    bench.run_cached(a, false);
    bench.drive(a);
    dut.start_i = 1;
    bench.tick();
    clear(3);
    bench.run_cached(a, true);
    U64 conservative = 0;
    for (unsigned m = 1; m <= 48; ++m) {
        clear(0);
        const Job job = single_output(5, 0, m, 4, 3, 2);
        const Result result = bench.run_cached(job, false);
        bench.run_cached(job, true);
        conservative += result.subcode == 0 && result.best < result.baseline &&
            result.best + bench.params.switch_cycles + 1 + bench.params.min_savings < result.baseline;
    }
    if (bench.params.read_bytes == 128 && bench.params.min_savings == 2 && bench.params.switch_cycles == 2)
        bench.require(conservative != 0, "conservative previous-winner threshold not exercised");
    for (unsigned index = 0; index < 1000; ++index) {
        clear(0);
        const unsigned codes[] = {0, 3, 5, 6};
        unsigned fmt = bench.random() & 7;
        if (fmt == 2) fmt = 3;
        const Job job = single_output(codes[bench.random() & 3], fmt, 1 + bench.random() % 256,
            1 + bench.random() % 256, 1 + bench.random() % 256, 1 + bench.random() % 9);
        bench.run_cached(job, false);
        bench.run_cached(job, true);
    }
    bench.integration();
    auto steer_run = [&](unsigned fmt, bool first, bool last, bool hit) {
        bench.steer_drive(fmt, 0, first);
        dut.steer_batch_last_i = last;
        bench.steer_tick();
        bench.steer_idle(1);
        bench.require(!dut.steer_subcode_valid_o, "steering result before lookup/search");
        bench.steer_idle(hit ? 1 : 32);
        bench.require(dut.steer_subcode_valid_o && dut.steer_subcode_cache_hit_o == hit,
                      "directed steering cache latency/hit");
    };
    dut.steer_flush_i = 1;
    bench.steer_tick();
    dut.steer_flush_i = 0;
    steer_run(0, true, false, false);
    steer_run(0, false, false, true);
    steer_run(0, false, true, true);
    steer_run(0, false, false, false);
    steer_run(0, false, false, true);
    steer_run(0, true, false, false);
    steer_run(0, false, false, true);
    steer_run(3, false, false, false);
    steer_run(0, false, false, false);
    steer_run(0, false, false, true);
    for (unsigned kind = 0; kind < 3; ++kind) {
        dut.steer_valid_i = 0;
        if (kind == 0) dut.steer_flush_i = 1;
        if (kind == 1) dut.steer_enable_i = 0;
        if (kind == 2) dut.rst_ni = 0;
        bench.steer_tick();
        dut.steer_flush_i = 0;
        dut.steer_enable_i = 1;
        dut.rst_ni = 1;
        steer_run(0, false, false, false);
        steer_run(0, false, false, true);
    }
    bench.steer_drive(0, 0, false);
    bench.steer_tick();
    bench.steer_idle(1);
    bench.steer_drive(0, 0, false);
    bench.steer_tick();
    bench.require(!dut.steer_subcode_valid_o, "accept on cache completion leaked stale response");
    bench.steer_idle(2);
    bench.require(dut.steer_subcode_valid_o && dut.steer_subcode_cache_hit_o,
                  "completed entry lost by cancelled lookup");
    bench.require(bench.cache_hits > 1000 && bench.cache_misses > 1000 && bench.steer_cache_hits >= 9,
                  "cache coverage insufficient");
    std::cout << "CACHE PASS hits=" << bench.cache_hits << " misses=" << bench.cache_misses
              << " steer_hits=" << bench.steer_cache_hits << " checks=" << bench.checks
              << " hit_cycles=1 miss_cycles=32 key_bits=all cancel_ages=0..31 legacy_equivalence=all_outputs\n";
}

static int captured_replay(const char *path, U64 seed) {
    constexpr std::size_t max_bytes = 256 * 1024;
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("cannot open captured replay TSV");
    std::vector<char> buffer(max_bytes + 1);
    file.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    if (file.bad() || (file.fail() && !file.eof()) || file.gcount() > static_cast<std::streamsize>(max_bytes))
        throw std::runtime_error("captured replay exceeds 256 KiB or read failed");
    const std::string contents(buffer.data(), static_cast<std::size_t>(file.gcount()));
    if (contents.empty() || contents.back() != '\n')
        throw std::runtime_error("captured replay must contain complete newline-terminated records");
    std::istringstream input(contents);
    auto fields = [](const std::string &line, std::size_t count) {
        std::vector<std::string> result;
        std::size_t start = 0;
        while (true) {
            const auto end = line.find('\t', start);
            result.push_back(line.substr(start, end == std::string::npos ? end : end - start));
            if (end == std::string::npos) break;
            start = end + 1;
        }
        if (result.size() != count) throw std::runtime_error("captured replay TSV field count mismatch");
        return result;
    };
    auto decimal = [](const std::string &text, U32 maximum) {
        if (text.empty() || (text.size() > 1 && text.front() == '0'))
            throw std::runtime_error("noncanonical replay integer");
        U64 value = 0;
        for (char digit : text) {
            if (digit < '0' || digit > '9') throw std::runtime_error("invalid replay integer");
            value = value * 10 + static_cast<unsigned>(digit - '0');
            if (value > maximum) throw std::runtime_error("replay integer exceeds field bounds");
        }
        return static_cast<U32>(value);
    };
    std::string line;
    if (!std::getline(input, line)) throw std::runtime_error("missing replay header");
    const auto header = fields(line, 9);
    if (header[0] != "g6lc.policy-subcode-replay.tsv.v1" || header[1].size() != 64 ||
        !std::all_of(header[1].begin(), header[1].end(), [](char value) {
            return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f');
        }))
        throw std::runtime_error("invalid replay schema/source hash; B3 traces are not accepted");
    const U32 count = decimal(header[2], 1024);
    if (!count) throw std::runtime_error("empty replay record list");
    Bench bench(seed);
    const std::array<U32, 6> parameters = {bench.params.read_bytes, bench.params.min_savings,
        bench.params.switch_cycles, bench.params.steps, bench.params.min_reduction, bench.params.groups};
    for (unsigned index = 0; index < parameters.size(); ++index)
        bench.require(decimal(header[index + 3], std::numeric_limits<U32>::max()) == parameters[index],
                      "captured replay parameters differ from compiled RTL");
    constexpr std::array<U32, 11> maxima = {256, 256, 256, 7, 7, 3, (1U << 23) - 1, 7,
        (1U << 23) - 1, std::numeric_limits<U32>::max(), std::numeric_limits<U32>::max()};
    for (U32 index = 0; index < count; ++index) {
        bench.context = "replay record=" + std::to_string(index);
        if (!std::getline(input, line)) throw std::runtime_error("replay record count exceeds available rows");
        const auto row = fields(line, maxima.size());
        std::array<U32, 11> values{};
        for (unsigned column = 0; column < values.size(); ++column)
            values[column] = decimal(row[column], maxima[column]);
        bench.require(values[0] && values[1] && values[2], "replay has zero dimension");
        const Job job{values[4], values[3], values[0], values[1], values[2], values[5], false, 0};
        bench.drive(job);
        bench.eval();
        bench.require(bench.dut.baseline_o == values[6],
                      "captured baseline does not match current allocator/default slot table");
        const Result expected = reference(job, values[6], bench.params);
        bench.require(expected.subcode == values[7], "captured subcode differs from independent reference");
        bench.require(expected.topology == values[8], "captured topology differs from independent reference");
        bench.require(expected.baseline == values[9], "captured baseline cost differs from independent reference");
        bench.require(expected.selected == values[10], "captured selected cost differs from independent reference");
        bench.run(job, false, 2);
        bench.require(bench.dut.valid_o && bench.dut.subcode_o == values[7] &&
                      bench.dut.topology_o == values[8] && bench.dut.baseline_cycles_o == values[9] &&
                      bench.dut.selected_cycles_o == values[10], "captured result differs from actual RTL");
        std::cout << "REPLAY_RECORD index=" << index << " subcode=" << values[7]
                  << " baseline_cycles=" << values[9] << " selected_cycles=" << values[10] << '\n';
    }
    if (std::getline(input, line)) throw std::runtime_error("replay contains undeclared extra rows");
    bench.require(bench.cases == count, "replay did not exercise every declared record");
    std::cout << "REPLAY PASS count=" << count << " source_sha256=" << header[1]
              << " reference=independent rtl=checked source_execution_verified=0\n";
    bench.dut.final();
    return EXIT_SUCCESS;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const U64 seed = argc > 1 ? std::stoull(argv[1], nullptr, 0) : 0x6c737562636f6465ULL;
        if (argc == 4 && std::string(argv[2]) == "--replay") return captured_replay(argv[3], seed);
        if (argc > 2) throw std::runtime_error("unexpected arguments; expected seed [--replay TSV]");
        Bench bench(seed);
        if (bench.dut.cache_enabled_o) {
            cache_tests(bench);
            bench.dut.final();
            return EXIT_SUCCESS;
        }
        std::cout << "PARAMETERS seed=" << seed << " read_bytes=" << bench.params.read_bytes
                  << " min_savings=" << bench.params.min_savings << " switch=" << bench.params.switch_cycles
                  << " steps=" << bench.params.steps << " min_reduction=" << bench.params.min_reduction
                  << " group_shapes=" << bench.params.groups << '\n';
        constexpr std::array<unsigned, 4> codes = {0, 3, 5, 6};
        constexpr std::array<unsigned, 7> formats = {0, 1, 3, 4, 5, 6, 7};
        constexpr std::array<unsigned, 24> bounds = {
            1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65,
            127, 128, 129, 239, 240, 254, 255, 256};
        for (unsigned code = 0; code < 8; ++code) {
            for (unsigned fmt = 0; fmt < 8; ++fmt) {
                bench.run({code, fmt, 128, 128, 127, 1, false, 0});
                Job invalid = single_output(code, fmt, 32, 32, 31);
                invalid.baseline &= ~(1U << 22);
                bench.run(invalid, false, 3);
            }
        }
        for (unsigned m : {35U, 36U, 37U}) {
            const Topology t{1, 1, 0, 1, 1, 2, 3, 4};
            bench.run({5, 0, m, 4, 3, 1, true, t.pack()}, false, 4);
        }
        for (unsigned code : codes) {
            for (unsigned fmt : formats) {
                for (unsigned defect = 0; defect < 10; ++defect) {
                    Job job = single_output(code, fmt, 16, 16, 17);
                    Topology t = Topology::unpack(job.baseline);
                    if (defect == 0) { t.slots = 0; t.reduction = 0; }
                    if (defect == 1) { t.slots = 10; t.reduction = 10; }
                    if (defect == 2) { t.rows = 5; t.reduction = 3; }
                    if (defect == 3) { t.cols = 5; t.reduction = 3; }
                    if (defect == 4) { t.rows = 3; t.cols = 2; t.reduction = 3; }
                    if (defect == 5) t.reduction = 7;
                    if (defect == 6) t.bits = (t.bits + 1) & 7;
                    if (defect == 7) { t.rows = 1; t.reduction = 7; job.m = 15; }
                    if (defect == 8) { t.cols = 1; t.reduction = 7; job.n = 15; }
                    if (defect == 9) { t.rows = 4; t.reduction = 4; job.m = 8; }
                    job.baseline = t.pack();
                    bench.run(job);
                }
                for (unsigned dim : {0U, 257U, 511U, 65535U}) {
                    for (unsigned axis = 0; axis < 3; ++axis) {
                        Job job = single_output(code, fmt, 16, 16, 17);
                        if (axis == 0) job.m = dim;
                        if (axis == 1) job.n = dim;
                        if (axis == 2) job.k = dim;
                        bench.run(job);
                    }
                }
                for (unsigned k : bounds) {
                    for (unsigned shape = 0; shape < 5; ++shape) {
                        const unsigned m = shape == 0 ? 1 : shape == 1 ? 8 : shape == 2 ? 32 :
                                           shape == 3 ? 128 : 256;
                        const unsigned n = shape == 0 ? 256 : shape == 1 ? 128 : shape == 2 ? 32 :
                                           shape == 3 ? 8 : 1;
                        bench.run({code, fmt, m, n, k, shape % 3, false, 0}, true);
                        bench.run(single_output(code, fmt, m, n, k));
                    }
                }
                for (unsigned slots = 1; slots <= 9; ++slots) {
                    bench.run(single_output(code, fmt, 256, 256, 256, slots));
                    bench.run(single_output(code, fmt, 256, 256, 255, slots));
                    bench.run(single_output(code, fmt, 16, 16, 255, slots));
                    const unsigned r = std::min(slots, 2U);
                    const unsigned c = std::min(slots - r, 2U);
                    Topology t{1, unsigned(r + c != 0), r, c, slots - r - c, slots,
                               format_bits(fmt), 0};
                    t.gain = (16 * (2 * (1U << (r + c)) - (1U << r) - (1U << c))) /
                             (2 * (1U << (r + c)));
                    bench.run({code, fmt, 16, 16, 255, 1, true, t.pack()});
                }
            }
        }
        for (unsigned index = 0; index < 5000; ++index) {
            const unsigned code = codes[bench.random() % codes.size()];
            const unsigned fmt = formats[bench.random() % formats.size()];
            auto dimension = [&]() {
                return index & 1 ? bounds[bench.random() % bounds.size()] :
                                   1U + static_cast<unsigned>(bench.random() % 256);
            };
            Job job{code, fmt, dimension(), dimension(), dimension(),
                    static_cast<unsigned>(bench.random() % 3), false, 0};
            if (index % 3 == 0) {
                job.override_baseline = true;
                const unsigned slots = 1 + bench.random() % 9;
                Topology t{1, 0, 0, 0, slots, slots, format_bits(fmt), 0};
                job.baseline = t.pack();
            }
            bench.run(job, !job.override_baseline, index % 97 == 0 ? 16 : 0);
        }
        for (unsigned kind = 0; kind < 3; ++kind) {
            for (unsigned age = 0; age < 32; ++age) bench.cancel(kind, age);
            bench.dut.start_i = 1;
            if (kind == 0) bench.dut.flush_i = 1;
            if (kind == 1) bench.dut.enable_i = 0;
            if (kind == 2) bench.dut.rst_ni = 0;
            bench.tick();
            bench.clear_result("held-result cancellation");
            bench.dut.start_i = 0;
            bench.dut.flush_i = 0;
            bench.dut.enable_i = 1;
            bench.dut.rst_ni = 1;
            bench.tick();
            bench.run({0, 0, 256, 256, 256, 1, false, 0});
        }
        bench.require(bench.eligible > 1000 && bench.rejected > 100, "insufficient eligibility coverage");
        bench.require(bench.cancelled == 96 && bench.busy_starts > 1000 && bench.held > 1000,
                      "insufficient protocol coverage");
        bench.require(bench.ties != 0, "tie retention untested");
        if (bench.params.read_bytes == 128 && bench.params.steps == 0x11111111 &&
            bench.params.min_reduction == 0 && bench.params.min_savings == 2 &&
            bench.params.switch_cycles == 2 && ((bench.params.groups >> 12) & 63) == 2)
            bench.require(bench.boundary_equal && bench.boundary_below && bench.boundary_above,
                          "strict savings threshold boundary untested");
        if (bench.params.read_bytes == 1 && bench.params.steps == 0x11111111 &&
            bench.params.min_reduction == 0)
            bench.require(bench.winners[1] && bench.winners[7], "single-output/group winner untested");
        bench.integration();
        workload_fixtures(seed);
        bench.report();
        bench.dut.final();
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << "FAIL policy_subcode " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
