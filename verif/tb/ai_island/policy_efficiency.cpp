// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

#include "Vtb_g6lc_ai_policy_steer.h"
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
#include <utility>
#include <vector>

#ifndef AI_POLICY_READ_BYTES
#define AI_POLICY_READ_BYTES 128
#endif
#ifndef AI_POLICY_MIN_GAIN
#define AI_POLICY_MIN_GAIN 2
#endif
#ifndef AI_POLICY_SLOTS
#define AI_POLICY_SLOTS 0x67788098u
#endif

namespace {
using U64 = uint64_t;
constexpr unsigned ReadBytes = AI_POLICY_READ_BYTES;
constexpr unsigned MinGain = AI_POLICY_MIN_GAIN;
constexpr uint32_t Slots = AI_POLICY_SLOTS;
constexpr std::array<unsigned, 7> Formats{{0, 1, 3, 4, 5, 6, 7}};
constexpr std::array<const char *, 8> Names{{"INT8", "INT4", "SP24_UNSUPPORTED",
    "FP8_E4M3", "FP8_E5M2", "FP16", "BF16", "FP32"}};
constexpr std::array<unsigned, 8> Bits{{8, 4, 0, 8, 8, 16, 16, 32}};
constexpr std::array<unsigned, 8> RowCaps{{2, 1, 3, 0, 2, 1, 2, 0}};
constexpr std::array<unsigned, 8> ColCaps{{2, 3, 1, 4, 2, 2, 2, 0}};
constexpr std::array<unsigned, 8> Next{{4, 0, 1, 3, 1, 3, 1, 0}};
constexpr std::array<unsigned, 8> Policies{{0x03332, 0x0a433, 0x14232, 0x103c1,
    0x02ab2, 0x11ab9, 0x0ab3d, 0x19b1b}};

void check(bool ok, const std::string &message) {
    if (!ok) throw std::runtime_error(message);
}

U64 ceildiv(U64 a, U64 b) { return a / b + (a % b != 0); }
U64 rowbytes(unsigned k, unsigned fmt) { return ceildiv(U64(k) * Bits.at(fmt), 8); }
unsigned slotslog(unsigned fmt, uint32_t table = Slots) { return (table >> (fmt * 4)) & 15; }
unsigned bitslog(unsigned fmt) {
    unsigned log = 0;
    while ((1u << log) < Bits.at(fmt)) ++log;
    return log;
}

struct Topology {
    bool valid = false, apply = false;
    unsigned r = 0, c = 0, p = 0, slots = 0, bits = 0, gain = 0;
    unsigned pack() const {
        return (unsigned(valid) << 22) | (unsigned(apply) << 21) | (r << 18) |
            (c << 15) | (p << 11) | (slots << 7) | (bits << 4) | gain;
    }
    static Topology unpack(unsigned x) {
        return {bool(x & (1u << 22)), bool(x & (1u << 21)), (x >> 18) & 7,
            (x >> 15) & 7, (x >> 11) & 15, (x >> 7) & 15, (x >> 4) & 7, x & 15};
    }
};

Topology baseline(unsigned fmt, unsigned m, unsigned n, unsigned k, uint32_t table = Slots) {
    if (fmt >= Bits.size() || fmt == 2 || !m || !n || !k) return {};
    const unsigned s = slotslog(fmt, table);
    if (!s || s > 9) return {};
    return {true, false, 0, 0, s, s, bitslog(fmt), 0};
}

Topology topology(unsigned code, unsigned fmt, unsigned m, unsigned n, unsigned k,
                  unsigned balance, unsigned read = ReadBytes, unsigned min_gain = MinGain,
                  uint32_t table = Slots) {
    auto t = baseline(fmt, m, n, k, table);
    if (!t.valid || code == 7) return t;
    auto divisor_log = [](unsigned dim, unsigned cap) {
        unsigned log = 0;
        while (log < cap && dim % 2 == 0) { dim /= 2; ++log; }
        return log;
    };
    auto reuse_gain = [](unsigned r, unsigned c) {
        const unsigned rows = 1u << r, cols = 1u << c;
        return unsigned(16 - ceildiv(8 * (rows + cols), rows * cols));
    };
    unsigned r = std::min(divisor_log(m, RowCaps.at(code)), t.slots);
    unsigned c = std::min(divisor_log(n, ColCaps.at(code)), t.slots - r);
    unsigned gain = reuse_gain(r, c);
    const unsigned rmax = divisor_log(m, 4), cmax = divisor_log(n, 4);
    const unsigned group_log = std::min({4u, t.slots, rmax + cmax});
    unsigned balanced_r = std::min(rmax, group_log / 2);
    unsigned balanced_c = group_log - balanced_r;
    if (balanced_c > cmax) { balanced_c = cmax; balanced_r = group_log - balanced_c; }
    const unsigned balanced_gain = reuse_gain(balanced_r, balanced_c);
    if (balanced_gain > gain || (balanced_gain == gain && group_log > r + c)) {
        r = balanced_r;
        c = balanced_c;
        gain = balanced_gain;
    }
    const U64 slots_group = U64(1) << t.slots;
    const U64 base_k = std::min(U64(k), slots_group);
    const U64 base_step = (U64(m) + n) * rowbytes(unsigned(base_k), fmt);
    const bool underfilled = k <= ((1u << t.slots) >> 1);

    const bool balance_eligible = balance != 0 || (code == 3);
    if (!balance_eligible || r + c == 0 || (m < 8 && n < 8) || gain < min_gain ||
        (!underfilled && base_step < U64(read))) return t;
    t.apply = true;
    t.r = r;
    t.c = c;
    t.p = t.slots - r - c;
    t.gain = gain;
    return t;
}

struct Input {
    bool reset = false, enable = true, flush = false, valid = true;
    bool first = false, last = false, scan = false, sample_valid = true, exact_zero = false;
    bool addr_valid = true, mispredict = false;
    unsigned m = 64, n = 64, k = 64, fmt = 0, opcode = 0, balance = 1;
    U64 address = UINT64_C(0xabcdf00012345640);
    std::array<uint32_t, 8> sample{{0x01010101, 0x01010101, 0, 0, 0, 0, 0, 0}};
};

void element(Input &in, unsigned lane, uint32_t value) {
    const unsigned bits = in.fmt == 2 ? 8 : Bits.at(in.fmt);
    const unsigned pos = lane * bits, word = pos / 32, shift = pos % 32;
    const uint32_t mask = bits == 32 ? UINT32_MAX : (1u << bits) - 1;
    in.sample[word] = (in.sample[word] & ~(mask << shift)) | ((value & mask) << shift);
}

U64 normalize(const Input &in) {
    if (in.fmt == 2) return UINT64_C(0x0101010101010101);
    U64 result = 0;
    for (unsigned i = 0; i < 8; ++i) {
        unsigned bits = Bits[in.fmt], pos = i * bits;
        uint32_t mask = bits == 32 ? UINT32_MAX : (1u << bits) - 1;
        if (in.fmt >= 3) mask >>= 1;
        const bool nonzero = ((in.sample[pos / 32] >> (pos % 32)) & mask) != 0;
        result |= U64(nonzero) << (8 * i);
    }
    return result;
}

unsigned bucket(unsigned x) { return x <= 1 ? 0 : x <= 8 ? 1 : x <= 64 ? 2 : 3; }

struct Expected {
    unsigned code = 0, next = 0;
    bool work = false, eval = false, commit = false, hold = false;
    bool warm = false, skip = false, hit = false, miss = false;
};

class Reference {
    bool active = false, seen = false, prediction = false;
    unsigned fmt = 0, current = 0, next = 0, candidate = 0, pending = 0;
    unsigned votes = 0, dwell = 0, cooldown = 0;
    std::array<unsigned, 3> shape{};
    std::array<unsigned, 8> signature{};
public:
    Expected step(const Input &in) {
        if (in.reset || !in.enable || in.flush) {
            *this = Reference{};
            return {};
        }
        Expected e;
        e.code = current;
        e.next = next;
        if (!in.valid) return e;
        const bool fresh = !active || in.first || (seen && fmt != in.fmt);
        std::array<unsigned, 3> dims{{bucket(in.m), bucket(in.n), bucket(in.k)}};
        const bool continuous = !fresh && dims == shape;
        const bool valid_shape = in.m && in.n && in.k;
        const U64 sample = normalize(in);
        unsigned zeros = 0;
        for (unsigned i = 0; i < 8; ++i) zeros += ((sample >> (i * 8)) & 255) == 0;
        const bool sparse = in.fmt != 2 && in.sample_valid && zeros >= 6;
        const unsigned bal = in.balance == 3 ? 1 : in.balance;
        const unsigned opcode = in.fmt == 2 ? 7 : in.opcode;
        std::array<unsigned, 8> sig{{dims[0], dims[1], dims[2], opcode, bal,
            unsigned(continuous), unsigned(valid_shape), unsigned(sparse)}};
        unsigned raw = 0;
        if (!valid_shape || opcode >= 4) raw = 7;
        else if (opcode == 1) raw = 4;
        else if (opcode == 2) raw = 5;
        else if (dims[0] <= 1 && dims[1] >= 2 && dims[2] >= 2) raw = 3;
        else if (sparse && continuous && bal == 2 && dims[0] >= 2) raw = 6;
        else if (bal == 0) raw = 7;
        else if (dims[1] > dims[0]) raw = 1;
        else if (dims[0] > dims[1]) raw = 2;
        e.work = true;
        e.eval = fresh || sig != signature;
        if (e.eval) candidate = raw;
        check(candidate == raw, "reference classification signature incomplete");
        const unsigned old_cooldown = fresh ? 0 : cooldown;
        if (fresh) {
            current = pending = raw;
            votes = dwell = cooldown = 0;
            prediction = false;
            e.commit = true;
        } else {
            dwell = std::min(4u, dwell + 1);
            if (raw == current) votes = 0;
            else {
                votes = pending == raw && votes ? std::min(3u, votes + 1) : 1;
                pending = raw;
                if (votes >= 3 && dwell >= 4) {
                    current = raw;
                    votes = dwell = 0;
                    e.commit = true;
                }
            }
        }
        e.miss = prediction && (in.mispredict || next != raw);
        e.hit = prediction && !e.miss;
        if (e.miss) cooldown = 2;
        else if (cooldown) --cooldown;
        next = continuous && raw == current ? current : Next[current];
        e.code = current;
        e.next = next;
        e.hold = !e.commit;
        e.skip = current == 6 && valid_shape && in.exact_zero && in.fmt <= 1;
        e.warm = !in.last && valid_shape && in.addr_valid && in.fmt != 2 &&
            !e.miss && old_cooldown == 0;
        prediction = e.warm;
        if (in.last) votes = cooldown = 0;
        active = !in.last;
        seen = true;
        fmt = in.fmt;
        shape = dims;
        signature = sig;
        return e;
    }
};

class Bench {
    Reference reference;
    Input retained;
    bool seen = false;
    U64 ticks = 0;
    std::array<U64, 17> snapshot() const {
        return {{dut.work_valid_o, dut.code_o, dut.next_code_o, dut.numfmt_o,
            dut.topology_o, dut.policy_o, dut.next_policy_o, dut.warm_valid_o,
            dut.warm_addr_o, dut.warm_bank_o, dut.residual_skip_o, dut.eval_o,
            dut.commit_o, dut.hold_o, dut.predict_hit_o, dut.predict_miss_o,
            dut.disabled_nonzero_o}};
    }
public:
    Vtb_g6lc_ai_policy_steer dut;
    std::array<U64, 8> coverage{};
    U64 skips = 0, format_changes = 0;
    Bench() {
        dut.clk_i = 0;
        dut.resource_start_i = 0;
        dut.probe_read_bytes_i = ReadBytes;
        dut.probe_min_gain_i = MinGain;
        dut.probe_slots_i = Slots;
        Input in;
        in.reset = true;
        tick(in);
    }
    ~Bench() { dut.final(); }
    void equal(U64 got, U64 want, const std::string &field) const {
        if (got != want) {
            std::ostringstream s;
            s << "cycle=" << ticks << " field=" << field << " got=" << got << " want=" << want
              << " fmt=" << unsigned(dut.numfmt_i) << " shape=" << dut.m_i << ',' << dut.n_i
              << ',' << dut.k_i << " code=" << unsigned(dut.code_o);
            throw std::runtime_error(s.str());
        }
    }
    void drive(const Input &in) {
        dut.rst_ni = !in.reset;
        dut.enable_i = in.enable;
        dut.flush_i = in.flush;
        dut.valid_i = in.valid;
        dut.batch_first_i = in.first;
        dut.batch_last_i = in.last;
        dut.testmode_i = in.scan;
        dut.m_i = in.m;
        dut.n_i = in.n;
        dut.k_i = in.k;
        dut.numfmt_i = in.fmt;
        dut.opcode_i = in.opcode;
        dut.balance_i = in.balance;
        for (unsigned i = 0; i < 8; ++i) dut.sample_i[i] = in.sample[i];
        dut.sample_valid_i = in.sample_valid;
        dut.exact_zero_i = in.exact_zero;
        dut.next_addr_i = in.address;
        dut.next_addr_valid_i = in.addr_valid;
        dut.mispredict_i = in.mispredict;
    }
    void clock() {
        dut.clk_i = 0;
        dut.eval();
        dut.clk_i = 1;
        dut.eval();
        ++ticks;
    }
    void validate_topology(unsigned packed, const Topology &t, const std::string &where) {
        equal(packed, t.pack(), where);
    }
    Topology probe(const Input &in, unsigned code, unsigned read = ReadBytes,
                   unsigned min_gain = MinGain, uint32_t slots = Slots) {
        dut.clk_i = 0;
        drive(in);
        dut.probe_code_i = code;
        dut.probe_read_bytes_i = read;
        dut.probe_min_gain_i = min_gain;
        dut.probe_slots_i = slots;
        dut.eval();
        if (in.fmt != 2) equal(dut.normalized_o, normalize(in), "native normalization");
        validate_topology(dut.probe_topology_o,
            topology(code, in.fmt, in.m, in.n, in.k, in.balance, read, min_gain, slots),
            "pure topology table");
        return Topology::unpack(dut.probe_topology_o);
    }
    Expected tick(const Input &in) {
        dut.clk_i = 0;
        dut.eval();
        auto before = snapshot();
        drive(in);
        dut.eval();
        if (!in.reset) check(before == snapshot(), "retained outputs changed without acceptance edge");
        equal(dut.ready_o, in.enable && !in.flush, "ready");
        equal(dut.normalized_o, normalize(in), "normalization");
        const bool changed = seen && in.fmt != retained.fmt;
        const auto e = reference.step(in);
        clock();
        equal(dut.disabled_nonzero_o, 0, "disabled outputs");
        if (in.reset || !in.enable || in.flush) {
            retained = Input{};
            retained.m = retained.n = retained.k = 0;
            seen = false;
        } else if (in.valid) {
            retained = in;
            seen = true;
        }
        equal(dut.work_valid_o, e.work, "work");
        equal(dut.policy_o, Policies.at(dut.code_o), "policy tuple");
        equal(dut.next_policy_o, Policies.at(dut.next_code_o), "next policy tuple");
        equal(dut.numfmt_o, seen ? retained.fmt : 0, "retained format");
        equal(dut.code_o, e.code, "code");
        equal(dut.next_code_o, e.next, "next code");
        equal(dut.eval_o, e.eval, "evaluation");
        equal(dut.commit_o, e.commit, "commit");
        equal(dut.hold_o, e.hold, "hold");
        equal(dut.warm_valid_o, e.warm, "warm");
        equal(dut.residual_skip_o, e.skip, "integer-only proof");
        equal(dut.predict_hit_o, e.hit, "prediction hit");
        equal(dut.predict_miss_o, e.miss, "prediction miss");
        if (seen) validate_topology(dut.topology_o,
            topology(dut.code_o, retained.fmt, retained.m, retained.n, retained.k, retained.balance),
            "retained topology alignment");
        if (e.work && changed) {
            check(dut.commit_o && dut.eval_o && !dut.hold_o && !dut.predict_hit_o &&
                  !dut.predict_miss_o, "accepted format change did not reset history");
            ++format_changes;
        }
        if (dut.warm_valid_o) {
            equal(dut.warm_addr_o, in.address, "warm address");
            equal(dut.warm_bank_o, (in.address >> 6) & 15, "warm bank");
        }
        if (seen && retained.fmt == 2)
            check(!dut.warm_valid_o && !dut.residual_skip_o &&
                  !Topology::unpack(dut.topology_o).valid, "SP24 must fail closed");
        if (e.work) ++coverage.at(dut.code_o);
        skips += dut.residual_skip_o;
        return e;
    }
    void reset() {
        Input in;
        in.reset = true;
        tick(in);
    }
};

struct Cost {
    U64 external = 0, compute = 0, macs = 0, reads = 0, operands = 0, cbytes = 0, steps = 0;
    U64 total(unsigned decision = 0) const { return external + compute + decision; }
};

std::array<std::pair<unsigned, U64>, 2> classes(unsigned dim, unsigned group) {
    return {{{group, dim / group}, {dim % group, dim % group ? 1u : 0u}}};
}

Cost closed_form(unsigned m, unsigned n, unsigned k, unsigned fmt, const Topology &t) {
    Cost cost;
    if (!m || !n || !k || fmt == 2) return cost;
    cost.operands = (U64(m) + n) * rowbytes(k, fmt);
    cost.cbytes = U64(8) * m * n;
    cost.external = ceildiv(cost.operands + cost.cbytes, 8);
    for (auto rr : classes(m, 1u << t.r))
        for (auto cc : classes(n, 1u << t.c))
            for (auto kk : classes(k, 1u << t.p)) {
                const U64 count = rr.second * cc.second * kk.second;
                if (!count) continue;
                const U64 bytes = (U64(rr.first) + cc.first) * rowbytes(kk.first, fmt);
                cost.compute += count * std::max<U64>(1, ceildiv(bytes, ReadBytes));
                cost.reads += count * bytes;
                cost.macs += count * rr.first * cc.first * kk.first;
                cost.steps += count;
            }
    check(cost.macs == U64(m) * n * k, "closed form lost useful products");
    return cost;
}

void timed_case(Bench &tb, unsigned m, unsigned n, unsigned k, unsigned fmt,
                const Topology &t, bool decision, std::mt19937_64 &rng) {
    auto &d = tb.dut;
    Input idle;
    idle.valid = false;
    tb.tick(idle);
    d.resource_start_i = 1;
    d.resource_decision_i = decision;
    d.resource_m_i = m;
    d.resource_n_i = n;
    d.resource_k_i = k;
    d.resource_fmt_i = fmt;
    d.resource_rows_i = t.r;
    d.resource_cols_i = t.c;
    d.resource_reduction_i = t.p;
    tb.clock();
    d.resource_start_i = 0;
    const auto cost = closed_form(m, n, k, fmt, t);
    if (!m || !n || !k || fmt == 2) {
        check(d.resource_done_o && d.resource_rejected_o && !d.resource_busy_o,
              "timed unsupported/zero shape rejection");
        tb.equal(d.resource_cycles_o, 0, "rejected cycles");
        return;
    }
    check(d.resource_busy_o && !d.resource_done_o, "scheduler start handshake");
    U64 elapsed = 0;
    const U64 expected = cost.total(decision);
    while (!d.resource_done_o && elapsed <= expected + 1) {
        d.resource_m_i = unsigned(rng() & 65535);
        d.resource_n_i = unsigned(rng() & 65535);
        d.resource_k_i = unsigned(rng() & 65535);
        d.resource_fmt_i = unsigned(rng() & 7);
        d.resource_rows_i = unsigned(rng() & 7);
        d.resource_cols_i = unsigned(rng() & 7);
        d.resource_reduction_i = unsigned(rng() & 15);
        d.resource_decision_i = rng() & 1;
        d.resource_start_i = (elapsed % 13) == 4;
        tb.clock();
        ++elapsed;
    }
    d.resource_start_i = 0;
    check(d.resource_done_o && !d.resource_busy_o && !d.resource_rejected_o,
          "timed scheduler completion/watchdog");
    tb.equal(elapsed, expected, "wall clock service cycles");
    tb.equal(d.resource_cycles_o, expected, "scheduler counted cycles");
    tb.equal(d.resource_compute_o, cost.compute, "scheduler compute cycles");
    tb.equal(d.resource_external_o, cost.external, "scheduler external cycles");
    tb.equal(d.resource_macs_o, cost.macs, "scheduler useful MACs");
    tb.equal(d.resource_reads_o, cost.reads, "scheduler SRAM reads");
    tb.equal(d.resource_operands_o, cost.operands, "scheduler operand traffic");
    tb.equal(d.resource_c_o, cost.cbytes, "scheduler C initial/final traffic");
    tb.equal(d.resource_steps_o, cost.steps, "scheduler group steps");
    tb.clock();
    check(!d.resource_done_o, "scheduler done must pulse");
}

void directed(Bench &tb, std::mt19937_64 &rng) {
    struct RefinementProbe {
        const char *name;
        unsigned code, fmt, m, n, k, balance, read;
        uint32_t slots;
        Topology expected;
    };
    const std::vector<RefinementProbe> refinement{
        {"balanced_strict_gain_wide", 1, 0, 64, 64, 64, 1, 128, 0x67788098u,
            {true, true, 2, 2, 4, 8, 3, 12}},
        {"balanced_strict_gain_routed", 5, 0, 64, 64, 64, 1, 128, 0x67788098u,
            {true, true, 2, 2, 4, 8, 3, 12}},
        {"balanced_equal_gain_more_outputs", 1, 0, 1, 16, 64, 1, 128, 0x67788098u,
            {true, true, 0, 4, 4, 8, 3, 7}},
        {"decode_movement_underfilled", 3, 0, 1, 128, 128, 0, 128, 0x67788098u,
            {true, true, 0, 4, 4, 8, 3, 7}},
        {"decode_movement_underfilled_sram512", 3, 0, 1, 128, 128, 0, 512, 0x67788098u,
            {true, true, 0, 4, 4, 8, 3, 7}},
        {"decode_movement_fourfold_pressure", 3, 0, 1, 128, 256, 0, 128, 0x67788098u,
            {true, true, 0, 4, 4, 8, 3, 7}},
        {"decode_movement_below_fourfold_pressure", 3, 0, 1, 128, 255, 0, 128, 0x67788098u,
            {true, true, 0, 4, 4, 8, 3, 7}},
        {"decode_movement_twofold_pressure", 3, 0, 1, 128, 256, 0, 256, 0x67788098u,
            {true, true, 0, 4, 4, 8, 3, 7}},
        {"decode_outer_gate_still_required", 3, 0, 1, 128, 256, 1, 512, 0x67788098u,
            {true, true, 0, 4, 4, 8, 3, 7}},
        {"nondecode_movement_still_conservative", 1, 0, 64, 64, 64, 0, 128, 0x67788098u,
            {true, false, 0, 0, 8, 8, 3, 0}},
        {"movement_code_still_baseline", 7, 0, 64, 64, 64, 1, 128, 0x67788098u,
            {true, false, 0, 0, 8, 8, 3, 0}},
        {"preferred_low_budget_equal_gain_tie", 0, 0, 64, 64, 1, 1, 128, 0x67788091u,
            {true, true, 1, 0, 0, 1, 3, 4}},
        {"group_cap_sixteen_with_int4_budget512", 5, 1, 64, 64, 64, 1, 128, 0x67788098u,
            {true, true, 2, 2, 5, 9, 2, 12}},
        {"decode_fp32_pressure_schedule_only", 3, 7, 1, 128, 64, 0, 128, 0x67788098u,
            {true, true, 0, 4, 2, 6, 5, 7}},
        {"decode_int4_odd_row_fourfold_pressure", 3, 1, 1, 128, 511, 0, 128, 0x67788098u,
            {true, true, 0, 4, 5, 9, 2, 7}},
        {"unsupported_sp24", 3, 2, 64, 64, 64, 0, 128, 0x67788098u, {}},
        {"zero_shape_all_zero", 1, 0, 0, 64, 64, 1, 128, 0x67788098u, {}},
        {"zero_profile_all_zero", 1, 0, 64, 64, 64, 1, 128, 0x67788090u, {}},
        {"unknown_profile_all_zero", 1, 0, 64, 64, 64, 1, 128, 0x6778809au, {}}
    };
    unsigned refinement_failures = 0;
    for (const auto &test : refinement) {
        Input in;
        in.valid = false;
        in.fmt = test.fmt;
        in.m = test.m;
        in.n = test.n;
        in.k = test.k;
        in.balance = test.balance;
        const auto expected = topology(test.code, test.fmt, test.m, test.n, test.k,
                                      test.balance, test.read, 2, test.slots);
        check(expected.pack() == test.expected.pack(), std::string("reference anchor ") + test.name);
        try {
            tb.probe(in, test.code, test.read, 2, test.slots);
            std::cout << "REFINEMENT_PROBE PASS " << test.name << '\n';
        } catch (const std::exception &error) {
            ++refinement_failures;
            std::cout << "REFINEMENT_PROBE FAIL " << test.name << " " << error.what() << '\n';
        }
    }
    check(refinement_failures == 0,
          "test-first topology refinement mismatches=" + std::to_string(refinement_failures));
    const std::array<unsigned, 18> dims{{0, 1, 2, 3, 4, 6, 7, 8, 9, 16, 17, 31, 32,
                                       64, 127, 128, 255, 256}};
    U64 probes = refinement.size();
    for (unsigned fmt = 0; fmt < 8; ++fmt)
        for (unsigned slot_log = 0; slot_log <= 10; ++slot_log)
            for (unsigned code = 0; code < 8; ++code)
                for (auto shape : {std::pair<unsigned, unsigned>{64, 64}, {6, 10}, {8, 3}}) {
                    Input in;
                    in.valid = false;
                    in.fmt = fmt;
                    in.m = shape.first;
                    in.n = shape.second;
                    in.k = 1;
                    const uint32_t table = (Slots & ~(uint32_t(15) << (fmt * 4))) |
                        (uint32_t(slot_log) << (fmt * 4));
                    tb.probe(in, code, ReadBytes, 2, table);
                    ++probes;
                }
    for (unsigned fmt = 0; fmt < 8; ++fmt)
        for (unsigned code = 0; code < 8; ++code)
            for (unsigned i = 0; i < dims.size(); ++i)
                for (unsigned bal = 0; bal < 4; ++bal) {
                    Input in;
                    in.valid = false;
                    in.fmt = fmt;
                    in.m = dims[i];
                    in.n = dims[(i * 7 + code) % dims.size()];
                    in.k = dims[(i * 5 + bal) % dims.size()];
                    in.balance = bal;
                    tb.probe(in, code);
                    ++probes;
                }
    for (unsigned fmt : Formats)
        for (unsigned code = 0; code < 8; ++code)
            for (unsigned k : {1u, 3u, 63u, 64u, 65u, 127u, 128u, 129u, 255u, 256u, 257u, 513u})
                for (unsigned read : {1u, 64u, 128u, 512u, 4096u})
                    for (unsigned min_gain : {0u, 2u, 8u, 12u, 15u, 16u}) {
                        Input in;
                        in.valid = false;
                        in.fmt = fmt;
                        in.m = 64;
                        in.n = 32;
                        in.k = k;
                        tb.probe(in, code, read, min_gain);
                        tb.probe(in, code, read, min_gain, 0x56677087u);
                        probes += 2;
                    }
    for (unsigned fmt : Formats) {
        for (unsigned mask = 0; mask < 256; ++mask) {
            Input in;
            in.fmt = fmt;
            in.first = true;
            in.balance = 2;
            in.exact_zero = true;
            in.sample.fill(UINT32_MAX);
            for (unsigned lane = 0; lane < 8; ++lane) {
                uint32_t zero = fmt >= 3 && (lane & 1) ? 1u << (Bits[fmt] - 1) : 0;
                element(in, lane, mask & (1u << lane) ? zero : 1);
            }
            tb.tick(in);
            in.first = false;
            for (unsigned repeat = 0; repeat < 5; ++repeat) tb.tick(in);
        }
        std::vector<uint32_t> edge;
        switch (fmt) {
            case 0: edge = {0, 1, 0x80, 0xff}; break;
            case 1: edge = {0, 1, 8, 15}; break;
            case 3: edge = {0, 0x80, 1, 0x81, 0x78, 0xf8, 0x7f, 0xff}; break;
            case 4: edge = {0, 0x80, 1, 0x81, 0x7c, 0xfc, 0x7d, 0xff}; break;
            case 5: edge = {0, 0x8000, 1, 0x8001, 0x7c00, 0xfc00, 0x7e00, 0x7fff}; break;
            case 6: edge = {0, 0x8000, 1, 0x8001, 0x7f80, 0xff80, 0x7fc0, 0x7fff}; break;
            default: edge = {0, 0x80000000u, 1, 0x80000001u, 0x7f800000u,
                             0xff800000u, 0x7fc00000u, 0x7fffffffu}; break;
        }
        for (uint32_t pattern : edge)
            for (unsigned lane = 0; lane < 8; ++lane) {
                Input in;
                in.fmt = fmt;
                in.sample.fill(0);
                element(in, lane, pattern);
                tb.probe(in, 0);
                tb.tick(in);
            }
    }
    tb.reset();
    Input unsupported;
    unsupported.fmt = 2;
    unsupported.balance = 2;
    unsupported.exact_zero = true;
    tb.tick(unsupported);
    tb.tick(unsupported);
    for (unsigned opcode = 0; opcode < 8; ++opcode) {
        unsupported.opcode = opcode;
        unsupported.sample.fill(opcode & 1 ? UINT32_MAX : 0);
        const auto e = tb.tick(unsupported);
        check(e.code == 7 && !e.eval && !e.commit && e.hold && !e.warm && !e.skip &&
              !e.hit && !e.miss, "SP24 must stay closed across raw opcode/sample changes");
    }
    tb.reset();
    Input same;
    same.m = 1;
    same.n = 128;
    same.k = 128;
    tb.tick(same);
    tb.tick(same);
    for (unsigned fmt = 0; fmt < 8; ++fmt) {
        Input idle = same;
        idle.valid = false;
        idle.fmt = fmt;
        idle.m = 0;
        idle.first = idle.last = idle.mispredict = true;
        idle.scan = fmt & 1;
        tb.tick(idle);
    }
    auto e = tb.tick(same);
    check(e.hit && !e.commit, "idle format changes must preserve prediction and hysteresis");
    for (unsigned fmt = 0; fmt < 8; ++fmt) {
        same.fmt = fmt;
        same.opcode = fmt % 3;
        same.mispredict = true;
        same.exact_zero = true;
        tb.tick(same);
    }
    for (unsigned i = 0; i < 8000; ++i) {
        Input in;
        in.fmt = unsigned((i / 11) % 8);
        in.m = dims[rng() % dims.size()];
        in.n = dims[rng() % dims.size()];
        in.k = dims[rng() % dims.size()];
        in.opcode = unsigned(rng() & 7);
        in.balance = unsigned(rng() & 3);
        in.valid = (rng() & 7) != 0;
        in.enable = (rng() & 63) != 0;
        in.flush = (rng() & 127) == 0;
        in.reset = (rng() & 511) == 0;
        in.first = (rng() & 15) == 0;
        in.last = (rng() & 15) == 0;
        in.scan = rng() & 1;
        in.sample_valid = rng() & 1;
        in.exact_zero = rng() & 1;
        in.addr_valid = rng() & 1;
        in.mispredict = (rng() & 7) == 0;
        in.address = rng();
        for (auto &word : in.sample) word = uint32_t(rng());
        tb.tick(in);
    }
    for (unsigned code = 0; code < 8; ++code) {
        Input in;
        in.first = true;
        if (code == 1) in.n = 256;
        if (code == 2) in.m = 256;
        if (code == 3) in.m = 1;
        if (code == 4) in.opcode = 1;
        if (code == 5) in.opcode = 2;
        if (code == 6) { in.balance = 2; in.sample.fill(0); in.exact_zero = true; }
        if (code == 7) in.opcode = 7;
        tb.tick(in);
        in.first = false;
        for (unsigned repeat = 0; repeat < 6; ++repeat) tb.tick(in);
        tb.equal(tb.dut.code_o, code, "directed codeword reachability");
    }
    const std::array<unsigned, 10> high_parts{{0, 16, 32, 64, 128, 256, 512, 4096, 32768, 65520}};
    const std::array<unsigned, 13> k_boundaries{{0, 1, 8, 63, 64, 127, 128, 255, 256, 511, 512, 513, 65535}};
    U64 metadata_cases = 0;
    for (unsigned fmt : Formats)
        for (unsigned high : high_parts)
            for (unsigned low = 0; low < 16; ++low)
                for (unsigned k : k_boundaries) {
                    Input in;
                    in.fmt = fmt;
                    in.first = true;
                    in.m = high + low;
                    in.n = high + 15 - low;
                    in.k = k;
                    in.balance = 2;
                    tb.tick(in);
                    ++metadata_cases;
                }
    std::cout << "METADATA_BOUNDARIES PASS cases=" << metadata_cases << '\n';
    for (auto count : tb.coverage) check(count != 0, "all codewords must be observed");
    check(tb.skips && tb.format_changes, "integer skip and accepted format transitions required");
    std::cout << "STEER_DIRECTED PASS probes=" << probes << " accepted_format_changes="
              << tb.format_changes << " integer_skips=" << tb.skips << '\n';
}

void timed_validation(Bench &tb, std::mt19937_64 &rng) {
    U64 cases = 0;
    for (unsigned fmt : Formats)
        for (unsigned code = 0; code < 8; ++code)
            for (unsigned fixture = 0; fixture < 3; ++fixture) {
                Input in;
                in.valid = false;
                in.fmt = fmt;
                in.m = fixture == 0 ? 8 : fixture == 1 ? 9 : 32;
                in.n = fixture == 0 ? 16 : fixture == 1 ? 17 : 24;
                in.k = fixture == 0 ? 33 : fixture == 1 ? 65 : 129;
                auto refined = tb.probe(in, code);
                timed_case(tb, in.m, in.n, in.k, fmt, baseline(fmt, in.m, in.n, in.k), false, rng);
                timed_case(tb, in.m, in.n, in.k, fmt, refined, true, rng);
                cases += 2;
            }
    for (unsigned i = 0; i < 28; ++i) {
        unsigned fmt = Formats[i % Formats.size()];
        Input in;
        in.valid = false;
        in.fmt = fmt;
        in.m = 1 + unsigned(rng() % 67);
        in.n = 1 + unsigned(rng() % 67);
        in.k = 1 + unsigned(rng() % 257);
        auto t = tb.probe(in, unsigned(rng() & 7));
        timed_case(tb, in.m, in.n, in.k, fmt, t, i & 1, rng);
        ++cases;
    }
    for (unsigned fmt : Formats) {
        auto t = baseline(fmt, 13, 19, 37);
        t.r = t.c = 2;
        t.p = t.slots - t.r - t.c;
        timed_case(tb, 13, 19, 37, fmt, t, false, rng);
        timed_case(tb, 13, 19, 37, fmt, t, true, rng);
        cases += 2;
    }
    timed_case(tb, 8, 8, 8, 2, {}, false, rng);
    timed_case(tb, 0, 8, 8, 0, baseline(0, 0, 8, 8), true, rng);
    std::cout << "TIMED_RESOURCE PASS cases=" << cases + 2
              << " tail_class_reference=O(8) input_mutation_and_busy_start_rejection=1 "
                 "includes_14_artificial_output_tail_scheduler_unit_fixtures=1\n";
    tb.reset();
}

struct Operator { unsigned m, n, k, opcode, zero_per_mille; };
struct Workload { std::string name; std::vector<Operator> ops; };

std::vector<Workload> workloads(U64 seed) {
    std::mt19937_64 rng(seed ^ UINT64_C(0x736861706573));
    std::vector<Workload> all{{"dense_prefill", {}}, {"dense_decode", {}},
                             {"routed_experts", {}}, {"diffusion_matrices", {}}};
    auto decoder = [](std::vector<Operator> &ops, unsigned m, unsigned context) {
        ops.push_back({m, 4096, 4096, 0, 40});
        ops.push_back({m, 4096, 4096, 0, 80});
        ops.push_back({m, 4096, 4096, 0, 120});
        ops.push_back({m, context, 128, 1, 50});
        ops.push_back({m, 128, context, 1, 75});
        ops.push_back({m, 4096, 4096, 0, 80});
        ops.push_back({m, 11008, 4096, 0, 750});
        ops.push_back({m, 11008, 4096, 0, 150});
        ops.push_back({m, 4096, 11008, 0, 300});
    };
    for (unsigned block = 0; block < 4; ++block)
        decoder(all[0].ops, block % 2 ? 256 : 128, block % 2 ? 256 : 128);
    for (unsigned step = 0; step < 3; ++step)
        decoder(all[1].ops, step == 0 ? 1 : step == 1 ? 4 : (rng() & 1 ? 1 : 4), 257 + 256 * step);
    const std::array<unsigned, 8> tokens{{3, 7, 17, 33, 65, 129, 5, 9}};
    const std::array<unsigned, 4> widths{{1536, 1537, 3072, 3073}};
    for (unsigned burst = 0; burst < tokens.size(); ++burst) {
        unsigned m = tokens[burst] + unsigned(rng() % 4), width = widths[rng() % widths.size()];
        unsigned zero = burst % 2 ? 850 : 50;
        all[2].ops.push_back({m, 4096, 4096, 0, 100});
        all[2].ops.push_back({m, width, 4096, 2, zero});
        all[2].ops.push_back({m, 4096, width, 2, zero});
    }
    for (unsigned step = 0; step < 4; ++step) {
        unsigned noise = 50 + unsigned(rng() % 4) * 200;
        all[3].ops.push_back({1024, 320, 320, 0, noise});
        all[3].ops.push_back({1024, 1280, 320, 0, noise});
        all[3].ops.push_back({1024, 320, 1280, 0, noise});
        all[3].ops.push_back({1024, 320, 2880, 3, noise});
        all[3].ops.push_back({256, 256, 80, 1, 80});
        all[3].ops.push_back({1003, 321, 1280, 0, noise});
    }
    return all;
}

struct Stats {
    U64 records = 0, apply = 0, b = 0, r = 0, bc = 0, rc = 0, macs = 0;
    U64 bread = 0, rread = 0, abytes = 0, bbytes = 0, cbytes = 0, ext = 0, switches = 0;
    U64 capacity_b = 0, capacity_r = 0;
    void add(const Input &in, const Topology &t, const Cost &base, const Cost &refined) {
        ++records;
        apply += t.apply;
        b += base.total();
        r += refined.total(1);
        bc += base.compute;
        rc += refined.compute;
        macs += base.macs;
        bread += base.reads;
        rread += refined.reads;
        abytes += U64(in.m) * rowbytes(in.k, in.fmt);
        bbytes += U64(in.n) * rowbytes(in.k, in.fmt);
        cbytes += base.cbytes;
        ext += base.external;
        capacity_b += base.compute * (U64(1) << t.slots);
        capacity_r += refined.compute * (U64(1) << t.slots);
    }
    void merge(const Stats &s) {
        records += s.records; apply += s.apply; b += s.b; r += s.r;
        bc += s.bc; rc += s.rc; macs += s.macs; bread += s.bread; rread += s.rread;
        abytes += s.abytes; bbytes += s.bbytes; cbytes += s.cbytes; ext += s.ext;
        capacity_b += s.capacity_b; capacity_r += s.capacity_r; switches += s.switches;
    }
};

double percent(U64 part, U64 whole) { return whole ? 100.0 * double(part) / double(whole) : 0; }
void improvements(U64 b, U64 r) {
    std::cout << " baseline_cycles=" << b << " refined_cycles=" << r
              << " signed_time_reduction_pct=" << 100.0 * (1.0 - double(r) / double(b))
              << " speedup_pct=" << 100.0 * (double(b) / double(r) - 1.0);
}
void print_stats(const std::string &prefix, const Stats &s) {
    std::cout << prefix;
    if (!s.records) { std::cout << " records=0 improvement=N/A\n"; return; }
    improvements(s.b, s.r);
    std::cout << " records=" << s.records << " applied_records=" << s.apply
              << " apply_records_pct=" << percent(s.apply, s.records)
              << " useful_MACs=" << s.macs << " baseline_compute_cycles=" << s.bc
              << " refined_compute_cycles=" << s.rc << " external_cycles=" << s.ext
              << " codec_decision_cycles=" << s.records
              << " baseline_slot_utilization=" << double(s.macs) / double(s.capacity_b)
              << " refined_slot_utilization=" << double(s.macs) / double(s.capacity_r)
              << " baseline_SRAM_operand_bytes=" << s.bread << " refined_SRAM_operand_bytes=" << s.rread
              << " external_A_bytes=" << s.abytes << " external_B_bytes=" << s.bbytes
              << " C_initial_bytes=" << s.cbytes / 2 << " C_final_bytes=" << s.cbytes / 2 << '\n';
}

void external_replay(Bench &tb, const std::string &path) {
    std::ifstream file(path);
    check(file.is_open(), "cannot open external policy TSV");
    auto split = [](const std::string &line) {
        std::vector<std::string> fields;
        size_t begin = 0;
        for (;;) {
            const auto end = line.find('\t', begin);
            fields.push_back(line.substr(begin, end == std::string::npos ? end : end - begin));
            if (end == std::string::npos) return fields;
            begin = end + 1;
        }
    };
    auto number = [](const std::string &text, unsigned maximum) {
        check(!text.empty() && text.size() <= 10 &&
              text.find_first_not_of("0123456789") == std::string::npos,
              "external TSV requires unsigned decimal integers");
        const U64 value = std::stoull(text);
        check(value <= maximum, "external TSV integer out of range");
        return unsigned(value);
    };
    auto token = [](const std::string &text) {
        return !text.empty() && text.size() <= 128 &&
            text.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-") ==
            std::string::npos;
    };
    std::string line;
    check(bool(std::getline(file, line)), "empty external TSV");
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const auto header = split(line);
    check(header.size() == 4 && header[0] == "g6lc.policy-workload.tsv.v1" &&
          token(header[1]) && token(header[2]), "invalid external TSV header");
    const unsigned count = number(header[3], 256);
    check(count != 0, "empty external workload");
    std::vector<Input> inputs;
    while (std::getline(file, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const auto fields = split(line);
        check(fields.size() == 9 && inputs.size() < count, "invalid external TSV record count/fields");
        check(number(fields[0], 255) == inputs.size(), "external record order mismatch");
        Input in;
        in.m = number(fields[1], 256);
        in.n = number(fields[2], 256);
        in.k = number(fields[3], 256);
        check(in.m && in.n && in.k, "external shapes must be 1..256; no implicit tiling");
        in.fmt = number(fields[4], 7);
        check(in.fmt != 2, "SP24 external replay unsupported");
        in.opcode = number(fields[5], 3);
        in.sample_valid = number(fields[6], 1);
        check(number(fields[7], 0) == 0, "external exact-zero proof forbidden");
        in.exact_zero = false;
        in.sample.fill(0);
        const auto &sample = fields[8];
        if (in.sample_valid) {
            check(in.m * in.k >= 8 && sample.size() == 2 * Bits[in.fmt] &&
                  sample.find_first_not_of("0123456789abcdefABCDEF") == std::string::npos,
                  "external native sample length/hex/geometry mismatch");
            for (unsigned i = 0; i < sample.size() / 2; ++i)
                in.sample[i / 4] |= uint32_t(std::stoul(sample.substr(2 * i, 2), nullptr, 16)) << (8 * (i % 4));
        } else check(sample == "-", "invalid sample must be empty");
        in.first = inputs.empty();
        in.last = inputs.size() + 1 == count;
        in.addr_valid = false;
        const U64 footprint = (U64(in.m) + in.n) * rowbytes(in.k, in.fmt) + U64(4) * in.m * in.n;
        const U64 macs = U64(in.m) * in.n * in.k;
        in.balance = macs < 4 * footprint ? 0 : macs < 16 * footprint ? 1 : 2;
        inputs.push_back(in);
    }
    check(file.eof() && inputs.size() == count, "truncated external TSV");
    tb.reset();
    Stats total;
    std::array<std::array<Stats, 8>, 8> by_format_code{};
    for (const auto &in : inputs) {
        tb.tick(in);
        const auto t = Topology::unpack(tb.dut.topology_o);
        check(t.valid && tb.dut.work_valid_o && !tb.dut.residual_skip_o,
              "external accepted work/topology/proof mismatch");
        const auto b = closed_form(in.m, in.n, in.k, in.fmt, baseline(in.fmt, in.m, in.n, in.k));
        const auto r = closed_form(in.m, in.n, in.k, in.fmt, t);
        check(b.macs == r.macs && b.operands == r.operands && b.cbytes == r.cbytes,
              "external format/operand/output conservation");
        total.add(in, t, b, r);
        by_format_code[in.fmt][tb.dut.code_o].add(in, t, b, r);
    }
    const std::string prefix = "EXTERNAL_POLICY_REPLAY source_target=" + header[1] +
        " source_profile=" + header[2] + " resource_profile=future-array-hypothesis" +
        " SRAM_read_bytes_per_cycle=" + std::to_string(ReadBytes) +
        " min_gain_16ths=" + std::to_string(MinGain) + " slots_table=" + std::to_string(Slots) +
        " trace_functional_backend=b3-descriptor-executor scheduling_model_not_actual_fp_array=1" +
        " qemu_guest=0 rtl_cycles=0 exact_zero_proof=0 scalar_pipe3_MACs=1 scalar_pipe3_cycles=10" +
        " scalar_pipe3_rates_match_array_hypothesis=0";
    for (unsigned fmt : Formats)
        for (unsigned code = 0; code < 8; ++code)
            if (by_format_code[fmt][code].records)
                print_stats(prefix + " format=" + Names[fmt] + " code=" + std::to_string(code),
                            by_format_code[fmt][code]);
    print_stats(prefix + " format=ALL code=ALL", total);
}

void efficiency(Bench &tb, U64 seed) {
    std::cout << "EFFICIENCY_CONTRACT validated scheduling model, not production speed; "
                 "same-format baseline; native representations never converted/quantized; "
                 "floats schedule-only, arithmetic/rounding/reassociation not modeled or proved\n";
    std::cout << "RESOURCE_ASSUMPTIONS SRAM_read_bytes_per_cycle=" << ReadBytes
              << " external_bytes_per_cycle=8 C_element_bytes=4 tile_max=256 "
                 "service_slots_INT4=512_INT8=256_FP8E4M3=256_FP8E5M2=256_FP16=128_BF16=128_FP32=64 "
                 "rates_are_assumed_not_physical_gate_or_transistor_counts=1 "
                 "baseline_one_output_full_K_slots=1 equal_buffers_operands_output_memory=1 "
                 "external_then_compute_no_DMA_overlap=1 each_step=max(1,ceil(operand_read_bytes/SRAM_rate)) "
                 "no_hit_credits=1 codec_overhead=1_cycle_per_record static_overhead=0 "
                 "external_traffic_once_per_independent_MNK_tile=1 C_initial_and_final_each_K_partial=1 "
                 "no_cross_tile_operand_or_C_residency_credit=1 exact_zero_proof=never "
                 "illustrative_assumed_shapes_not_named_pretrained_model_traces=1\n";
    const auto all = workloads(seed);
    U64 planned = 0;
    for (const auto &workload : all)
        for (const auto &op : workload.ops)
            planned += ceildiv(op.m, 256) * ceildiv(op.n, 256) * ceildiv(op.k, 256);
    check(planned >= 10000 && planned <= 50000, "logical workload record count must stay bounded");
    std::cout << "PLANNED_RECORDS per_format=" << planned << " all_formats="
              << planned * Formats.size() << " timed_scheduler_used_only_for_bounded_fixtures=1\n";
    double ratio_sum = 0, inverse_sum = 0, oracle_sum = 0, decision_ratio_sum = 0;
    std::array<double, 8> static_ratios{};
    std::array<Stats, 8> states{}, format_stats{};
    U64 total_records = 0;
    for (unsigned wi = 0; wi < all.size(); ++wi) {
        std::cout << "UNSUPPORTED workload=" << all[wi].name << " format=SP24 performance=N/A\n";
        for (unsigned fmt : Formats) {
            tb.reset();
            std::mt19937_64 rng(seed ^ (UINT64_C(0x9e3779b97f4a7c15) * (wi + 1)));
            Stats sum;
            std::array<Stats, 8> per_code{};
            std::array<U64, 8> static_costs{};
            U64 oracle = 0, tails = 0;
            unsigned previous_code = 0;
            bool first_record = true;
            for (const auto &op : all[wi].ops) {
                bool first = true;
                for (unsigned mi = 0; mi < op.m; mi += 256)
                    for (unsigned ni = 0; ni < op.n; ni += 256)
                        for (unsigned ki = 0; ki < op.k; ki += 256) {
                            Input in;
                            in.fmt = fmt;
                            in.m = std::min(256u, op.m - mi);
                            in.n = std::min(256u, op.n - ni);
                            in.k = std::min(256u, op.k - ki);
                            in.opcode = op.opcode;
                            in.first = first;
                            in.last = mi + 256 >= op.m && ni + 256 >= op.n && ki + 256 >= op.k;
                            first = false;
                            in.exact_zero = false;
                            in.sample_valid = (rng() & 31) != 0;
                            in.address += total_records * 4096;
                            const U64 footprint = (U64(in.m) + in.n) * rowbytes(in.k, fmt) + U64(4) * in.m * in.n;
                            const U64 macs = U64(in.m) * in.n * in.k;
                            in.balance = macs < 4 * footprint ? 0 : macs < 16 * footprint ? 1 : 2;
                            in.sample.fill(0);
                            for (unsigned lane = 0; lane < 8; ++lane) {
                                const bool zero = rng() % 1000 < op.zero_per_mille;
                                uint32_t value = zero ? 0 : uint32_t(rng()) | 1u;
                                element(in, lane, value);
                            }
                            tb.tick(in);
                            const unsigned code = tb.dut.code_o;
                            const auto t = Topology::unpack(tb.dut.topology_o);
                            check(t.valid, "known nonzero workload must have valid topology");
                            const auto b = closed_form(in.m, in.n, in.k, fmt, baseline(fmt, in.m, in.n, in.k));
                            const auto r = closed_form(in.m, in.n, in.k, fmt, t);
                            check(b.macs == r.macs && b.operands == r.operands && b.cbytes == r.cbytes,
                                  "format/operand/output conservation");
                            sum.add(in, t, b, r);
                            per_code[code].add(in, t, b, r);
                            states[code].add(in, t, b, r);
                            tails += in.m != 256 || in.n != 256 || in.k != 256;
                            sum.switches += !first_record && previous_code != code;
                            first_record = false;
                            previous_code = code;
                            U64 best = b.total();
                            for (unsigned affinity = 0; affinity < 8; ++affinity) {
                                const auto st = topology(affinity, fmt, in.m, in.n, in.k, in.balance);
                                const U64 cost = closed_form(in.m, in.n, in.k, fmt, st).total();
                                static_costs[affinity] += cost;
                                best = std::min(best, cost);
                            }
                            oracle += best;
                            ++total_records;
                        }
            }
            const std::string key = " workload=" + all[wi].name + " format=" + Names[fmt];
            print_stats("WORKLOAD_FORMAT" + key, sum);
            for (unsigned code = 0; code < 8; ++code) {
                std::cout << "CODE_SHARE" << key << " code=" << code
                          << " baseline_cycles_pct=" << percent(per_code[code].b, sum.b)
                          << " refined_cycles_pct=" << percent(per_code[code].r, sum.r)
                          << " useful_MACs_pct=" << percent(per_code[code].macs, sum.macs) << '\n';
                print_stats("STATE" + key + " code=" + std::to_string(code), per_code[code]);
            }
            const auto best = std::min_element(static_costs.begin(), static_costs.end());
            std::cout << "STATIC_ORACLE" << key << " best_static_code=" << (best - static_costs.begin())
                      << " best_static_cycles=" << *best << " oracle_per_tile_cycles=" << oracle
                      << " refined_vs_best_static_time_reduction_pct=" << 100 * (1 - double(sum.r) / double(*best))
                      << " best_static_with_decision_cycles=" << *best + sum.records
                      << " refined_vs_same_decision_static_time_reduction_pct="
                      << 100 * (1 - double(sum.r) / double(*best + sum.records))
                      << " static_decision_cycles_per_record=1 oracle_selection_overhead=0_diagnostic_lower_bound "
                         "static_selection=retrospective_comparator_not_gate_training "
                         "tail_records=" << tails << '\n';
            for (unsigned affinity = 0; affinity < 8; ++affinity) {
                std::cout << "STATIC_AFFINITY" << key << " code=" << affinity
                          << " cycles=" << static_costs[affinity] << '\n';
                static_ratios[affinity] += double(static_costs[affinity]) / double(sum.b);
            }
            for (unsigned tax : {0u, 1u, 4u, 16u}) {
                std::cout << "SWITCH_TAX_SENSITIVITY" << key << " extra_cycles_per_code_change=" << tax
                          << " code_changes=" << sum.switches;
                improvements(sum.b, sum.r + U64(tax) * sum.switches);
                std::cout << " hypothetical_not_measured=1\n";
            }
            ratio_sum += double(sum.r) / double(sum.b);
            inverse_sum += double(sum.b) / double(sum.r);
            oracle_sum += double(oracle) / double(sum.b);
            decision_ratio_sum += double(sum.records) / double(sum.b);
            format_stats[fmt].merge(sum);
        }
    }
    check(total_records == planned * Formats.size(), "all workload-format records accounted");
    for (unsigned code = 0; code < 8; ++code)
        print_stats("STATE_AGGREGATE_RAW_MODEL code=" + std::to_string(code), states[code]);
    U64 all_b = 0, all_r = 0, all_macs = 0;
    for (unsigned fmt : Formats) { all_b += format_stats[fmt].b; all_r += format_stats[fmt].r; all_macs += format_stats[fmt].macs; }
    for (unsigned fmt : Formats) {
        print_stats(std::string("FORMAT_AGGREGATE_RAW_MODEL format=") + Names[fmt], format_stats[fmt]);
        std::cout << "FORMAT_SHARE_RAW_MODEL format=" << Names[fmt]
                  << " baseline_cycles_pct=" << percent(format_stats[fmt].b, all_b)
                  << " refined_cycles_pct=" << percent(format_stats[fmt].r, all_r)
                  << " useful_MACs_pct=" << percent(format_stats[fmt].macs, all_macs) << '\n';
    }
    constexpr double pairs = 28;
    const auto best = std::min_element(static_ratios.begin(), static_ratios.end());
    std::cout << "BALANCED_MIX equal_weight=4_workloads_x_7_formats normalized_pairs=28"
              << " mean_refined_over_baseline=" << ratio_sum / pairs
              << " signed_time_reduction_pct=" << 100 * (1 - ratio_sum / pairs)
              << " speedup_of_normalized_time_pct=" << 100 * (pairs / ratio_sum - 1)
              << " mean_pair_speedup_pct=" << 100 * (inverse_sum / pairs - 1)
              << " best_single_static_code=" << (best - static_ratios.begin())
              << " best_single_static_normalized_time=" << *best / pairs
              << " best_static_same_decision_normalized_time=" << (*best + decision_ratio_sum) / pairs
              << " refined_vs_same_decision_static_time_reduction_pct="
              << 100 * (1 - ratio_sum / (*best + decision_ratio_sum))
              << " oracle_normalized_time=" << oracle_sum / pairs
              << " records=" << total_records << " SRAM_read_bytes_per_cycle=" << ReadBytes << '\n';
}
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const char *env = std::getenv("AI_POLICY_SEED");
        const U64 seed = env ? std::stoull(env, nullptr, 0) : UINT64_C(0x6c706f6c696379);
        std::cout << std::fixed << std::setprecision(6);
        std::cout << "STEER_SEED " << seed << " read_bytes=" << ReadBytes
                  << " min_gain=" << MinGain << " slots_table=" << Slots << '\n';
        Bench tb;
        std::mt19937_64 rng(seed ^ UINT64_C(0x656666696369656e));
        directed(tb, rng);
        timed_validation(tb, rng);
        if (MinGain == 2 && Slots == 0x67788098u) efficiency(tb, seed);
        else std::cout << "EFFICIENCY SKIP nondefault_capability_contract_probe_only\n";
        if (const char *trace = std::getenv("AI_POLICY_TRACE")) external_replay(tb, trace);
        std::cout << "AI_POLICY_STEER PASS\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "AI_POLICY_STEER FAIL " << e.what() << '\n';
        return 1;
    }
}
