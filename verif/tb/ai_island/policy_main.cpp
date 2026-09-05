// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

#include "Vtb_g6lc_ai_policy.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#ifndef AI_POLICY_HOLD
#define AI_POLICY_HOLD 3
#endif
#ifndef AI_POLICY_DWELL
#define AI_POLICY_DWELL 4
#endif
#ifndef AI_POLICY_COOLDOWN
#define AI_POLICY_COOLDOWN 2
#endif
#ifndef AI_POLICY_BANK_BITS
#define AI_POLICY_BANK_BITS 4
#endif

namespace {
constexpr unsigned HoldWork = AI_POLICY_HOLD;
constexpr unsigned DwellWork = AI_POLICY_DWELL;
constexpr unsigned CooldownWork = AI_POLICY_COOLDOWN;
constexpr unsigned BankBits = AI_POLICY_BANK_BITS;
constexpr unsigned BankMask = (1u << BankBits) - 1;
static_assert(HoldWork >= 1 && HoldWork <= 15 && DwellWork >= 1 && DwellWork <= 15,
              "unsupported evidence/dwell parameters");
static_assert(CooldownWork <= 15 && BankBits >= 1 && BankBits <= 8,
              "unsupported cooldown/bank parameters");
constexpr std::array<unsigned, 8> Successor{{4, 0, 1, 3, 1, 3, 1, 0}};
constexpr std::array<std::array<unsigned, 6>, 8> Tuples{{
    {{0, 6, 6, 6, 0, 2}}, {{1, 4, 8, 6, 0, 3}},
    {{2, 8, 4, 6, 0, 2}}, {{2, 0, 7, 8, 0, 1}},
    {{0, 5, 5, 6, 0, 2}}, {{2, 3, 5, 7, 0, 1}},
    {{1, 5, 6, 7, 1, 1}}, {{3, 3, 6, 3, 0, 3}}
}};

unsigned packed_policy(unsigned code) {
    const auto &p = Tuples.at(code);
    return (p[0] << 15) | (p[1] << 11) | (p[2] << 7) |
           (p[3] << 3) | (p[4] << 2) | p[5];
}

void require(bool condition, const std::string &message) {
    if (!condition) throw std::runtime_error(message);
}

struct Input {
    bool reset = false, enable = true, flush = false, valid = true;
    bool first = false, last = false, testmode = false;
    uint16_t m = 64, n = 64, k = 64;
    unsigned opcode = 0, balance = 1;
    uint64_t sample = UINT64_C(0x0101010101010101);
    bool sample_valid = true, exact_zero = false;
    uint64_t next_addr = UINT64_C(0x1234567880000240);
    bool next_addr_valid = false, mispredict = false;
};

unsigned bucket(unsigned x) {
    if (x <= 1) return 0;
    if (x <= 8) return 1;
    if (x <= 64) return 2;
    return 3;
}

uint64_t sample_with_zeros(unsigned zeros) {
    uint64_t result = 0;
    for (unsigned i = zeros; i < 8; ++i)
        result |= uint64_t(0x81 + i) << (8 * i);
    return result;
}

struct Features {
    unsigned mb, nb, kb, opcode, balance;
    bool valid_shape, residue, continuity;
    std::array<unsigned, 8> signature() const {
        return {{mb, nb, kb, opcode, balance,
                 unsigned(valid_shape), unsigned(residue), unsigned(continuity)}};
    }
};

unsigned classify(const Features &f) {
    if (!f.valid_shape || f.opcode >= 4) return 7;
    if (f.opcode == 1) return 4;
    if (f.opcode == 2) return 5;
    if (f.mb <= 1 && f.nb >= 2 && f.kb >= 2) return 3;
    if (f.residue && f.continuity && f.balance == 2 && f.mb >= 2) return 6;
    if (f.balance == 0) return 7;
    if (f.nb > f.mb) return 1;
    if (f.mb > f.nb) return 2;
    return 0;
}

struct Expected {
    bool work = false, eval = false, commit = false, hold = false;
    bool warm = false, skip = false, hit = false, miss = false;
    bool known = false;
    unsigned code = 0, raw = 0, next_code = 0;
};

class Reference {
    bool active = false, shape_known = false, signature_known = false;
    bool pending_prediction = false, output_known = false;
    std::array<unsigned, 3> previous_shape{{0, 0, 0}};
    std::array<unsigned, 8> previous_signature{};
    unsigned current = 0, candidate_cache = 0, pending_code = 0, next_code = 0;
    unsigned votes = 0, dwell = 0, cooldown = 0, predicted = 0;

public:
    Expected step(const Input &in) {
        Expected e;
        if (in.reset || !in.enable || in.flush) {
            *this = Reference{};
            return e;
        }
        e.known = output_known;
        e.code = current;
        e.next_code = next_code;
        if (!in.valid) return e;
        const bool fresh = !active || in.first;
        unsigned zeros = 0;
        for (unsigned i = 0; i < 8; ++i)
            zeros += ((in.sample >> (8 * i)) & 255) == 0;
        Features f{bucket(in.m), bucket(in.n), bucket(in.k), in.opcode,
                   in.balance == 3 ? 1u : in.balance,
                   in.m != 0 && in.n != 0 && in.k != 0,
                   in.sample_valid && zeros >= 6, false};
        const std::array<unsigned, 3> shape{{f.mb, f.nb, f.kb}};
        f.continuity = !fresh && shape_known && shape == previous_shape;
        const auto signature = f.signature();
        e.work = true;
        e.eval = fresh || !signature_known || signature != previous_signature;
        e.raw = classify(f);
        if (e.eval) candidate_cache = e.raw;
        require(candidate_cache == e.raw, "oracle signature lost classification information");
        if (fresh) {
            current = candidate_cache;
            votes = dwell = cooldown = 0;
            pending_prediction = false;
            e.commit = true;
        } else {
            dwell = std::min(DwellWork, dwell + 1);
            if (candidate_cache == current) {
                votes = 0;
            } else {
                votes = votes && pending_code == candidate_cache ? votes + 1 : 1;
                votes = std::min(HoldWork, votes);
                pending_code = candidate_cache;
                if (votes >= HoldWork && dwell >= DwellWork) {
                    current = candidate_cache;
                    votes = dwell = 0;
                    e.commit = true;
                }
            }
        }
        e.hold = !e.commit;
        e.known = output_known = true;
        e.code = current;
        next_code = f.continuity && e.raw == current ? current : Successor[current];
        e.next_code = next_code;
        e.skip = Tuples[current][4] && in.exact_zero && f.valid_shape;
        e.miss = pending_prediction && (in.mispredict || predicted != e.raw);
        e.hit = pending_prediction && !e.miss;
        pending_prediction = false;
        if (e.miss) {
            cooldown = CooldownWork;
        } else if (cooldown) {
            --cooldown;
        } else if (in.next_addr_valid && !in.last && f.valid_shape) {
            e.warm = true;
            pending_prediction = true;
            predicted = next_code;
        }
        previous_shape = shape;
        previous_signature = signature;
        shape_known = signature_known = active = !in.last;
        if (in.last) {
            pending_prediction = false;
            votes = dwell = cooldown = 0;
        }
        return e;
    }
};

struct Snapshot {
    std::array<uint64_t, 15> data;
    bool operator==(const Snapshot &other) const { return data == other.data; }
};

class Bench {
    Vtb_g6lc_ai_policy dut;
    Reference ref;
    uint64_t cycles = 0;

    Snapshot snapshot() const {
        return {{{dut.work_valid_o, dut.code_o, dut.next_code_o, dut.policy_o,
                  dut.next_policy_o, dut.warm_valid_o, dut.warm_addr_o,
                  dut.warm_bank_o, dut.residual_skip_o, dut.eval_o, dut.commit_o,
                  dut.hold_o, dut.predict_hit_o, dut.predict_miss_o,
                  dut.disabled_nonzero_o}}};
    }

    void equal(uint64_t got, uint64_t want, const std::string &field) const {
        if (got == want) return;
        std::ostringstream out;
        out << "cycle=" << cycles << " " << field << " got=" << got << " expected=" << want
            << " shape=" << dut.m_i << ',' << dut.n_i << ',' << dut.k_i
            << " opcode=" << unsigned(dut.opcode_i) << " balance=" << unsigned(dut.balance_i)
            << " valid=" << unsigned(dut.valid_i) << " first=" << unsigned(dut.batch_first_i)
            << " last=" << unsigned(dut.batch_last_i) << " injected_miss=" << unsigned(dut.mispredict_i);
        throw std::runtime_error(out.str());
    }

    void drive(const Input &in) {
        dut.rst_ni = !in.reset;
        dut.enable_i = in.enable;
        dut.flush_i = in.flush;
        dut.valid_i = in.valid;
        dut.batch_first_i = in.first;
        dut.batch_last_i = in.last;
        dut.testmode_i = in.testmode;
        dut.m_i = in.m;
        dut.n_i = in.n;
        dut.k_i = in.k;
        dut.opcode_i = in.opcode;
        dut.balance_i = in.balance;
        dut.sample_i = in.sample;
        dut.sample_valid_i = in.sample_valid;
        dut.exact_zero_i = in.exact_zero;
        dut.next_addr_i = in.next_addr;
        dut.next_addr_valid_i = in.next_addr_valid;
        dut.mispredict_i = in.mispredict;
    }

public:
    uint64_t accepted = 0, evals = 0, commits = 0, hits = 0, misses = 0, skips = 0;
    std::array<uint64_t, 8> codes{};

    ~Bench() { dut.final(); }

    Expected tick(const Input &in) {
        dut.clk_i = 0;
        dut.eval();
        const auto before = snapshot();
        drive(in);
        dut.eval();
        if (!in.reset)
            require(snapshot() == before, "registered output changed before rising edge at cycle=" +
                    std::to_string(cycles));
        equal(dut.ready_o, in.enable && !in.flush, "ready");
        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        const Expected e = ref.step(in);
        equal(dut.disabled_nonzero_o, 0, "compile-disabled outputs");
        equal(dut.work_valid_o, e.work, "work_valid");
        equal(dut.eval_o, e.eval, "eval");
        equal(dut.commit_o, e.commit, "commit");
        equal(dut.hold_o, e.hold, "hold");
        equal(dut.warm_valid_o, e.warm, "warm_valid");
        equal(dut.residual_skip_o, e.skip, "residual_skip");
        equal(dut.predict_hit_o, e.hit, "predict_hit");
        equal(dut.predict_miss_o, e.miss, "predict_miss");
        if (e.known) {
            equal(dut.code_o, e.code, "code");
            equal(dut.policy_o, packed_policy(e.code), "policy tuple");
            equal(dut.next_code_o, e.next_code, "conditional repeat/successor next code");
            equal(dut.next_policy_o, packed_policy(e.next_code), "latched next policy tuple");
        }
        if (e.warm) {
            equal(dut.warm_addr_o, in.next_addr, "caller-provided warm address");
            equal(dut.warm_bank_o, (in.next_addr >> 6) & BankMask, "warm bank");
        }
        require(!(dut.predict_hit_o && dut.predict_miss_o), "hit/miss mutually exclusive");
        require(!dut.residual_skip_o || (in.valid && in.exact_zero && in.m && in.n && in.k),
                "skip without exact full-tile zero authorization");
        if (e.work) {
            ++accepted;
            ++codes[e.code];
            evals += e.eval;
            commits += e.commit;
            hits += e.hit;
            misses += e.miss;
            skips += e.skip;
        }
        return e;
    }

    void reset() {
        Input in;
        in.reset = true;
        tick(in);
        in.reset = false;
        in.valid = false;
        tick(in);
    }

    void check_cleared_prediction() const {
        equal(dut.next_code_o, 0, "cleared next code");
        equal(dut.next_policy_o, packed_policy(0), "cleared next policy tuple");
    }

    unsigned policy() const { return dut.policy_o; }
    bool skip() const { return dut.residual_skip_o; }
    uint64_t cycle_count() const { return cycles; }
};

Input for_class(unsigned code) {
    Input in;
    switch (code) {
    case 0: break;
    case 1: in.n = 128; break;
    case 2: in.m = 128; break;
    case 3: in.m = 1; in.n = in.k = 128; break;
    case 4: in.opcode = 1; break;
    case 5: in.opcode = 2; break;
    case 6: in.balance = 2; in.sample = sample_with_zeros(6); break;
    case 7: in.opcode = 4; break;
    default: throw std::runtime_error("invalid test class");
    }
    return in;
}

void check_matrix(unsigned packed, bool skip, bool zero) {
    const unsigned df = (packed >> 15) & 3;
    const unsigned tm = std::min(7u, 1u << ((packed >> 11) & 15));
    const unsigned tn = std::min(11u, 1u << ((packed >> 7) & 15));
    const unsigned tk = std::min(13u, 1u << ((packed >> 3) & 15));
    const unsigned M = 19, N = 37, K = 73;
    std::vector<int8_t> a(M * K), b(K * N);
    std::vector<int64_t> golden(M * N), tiled(M * N);
    for (unsigned i = 0; i < a.size(); ++i)
        a[i] = zero ? 0 : int8_t(int((i * 37 + 11) % 256) - 128);
    for (unsigned i = 0; i < b.size(); ++i)
        b[i] = int8_t(int((i * 19 + 7) % 256) - 128);
    for (unsigned m = 0; m < M; ++m)
        for (unsigned n = 0; n < N; ++n)
            for (unsigned k = 0; k < K; ++k)
                golden[m * N + n] += int(a[m * K + k]) * int(b[k * N + n]);
    auto tile = [&](unsigned mi, unsigned ni, unsigned ki) {
        for (unsigned m = mi; m < std::min(M, mi + tm); ++m)
            for (unsigned n = ni; n < std::min(N, ni + tn); ++n)
                for (unsigned k = ki; k < std::min(K, ki + tk); ++k)
                    tiled[m * N + n] += int(a[m * K + k]) * int(b[k * N + n]);
    };
    if (!skip) {
        if (df == 0) {
            for (unsigned m = 0; m < M; m += tm)
                for (unsigned n = 0; n < N; n += tn)
                    for (unsigned k = 0; k < K; k += tk) tile(m, n, k);
        } else if (df == 1) {
            for (unsigned n = 0; n < N; n += tn)
                for (unsigned k = 0; k < K; k += tk)
                    for (unsigned m = 0; m < M; m += tm) tile(m, n, k);
        } else if (df == 2) {
            for (unsigned m = 0; m < M; m += tm)
                for (unsigned k = 0; k < K; k += tk)
                    for (unsigned n = 0; n < N; n += tn) tile(m, n, k);
        } else {
            for (unsigned k = 0; k < K; k += tk)
                for (unsigned m = 0; m < M; m += tm)
                    for (unsigned n = 0; n < N; n += tn) tile(m, n, k);
        }
    }
    require(tiled == golden, "int8 matrix consumer differs from untiled int64 golden");
}

void directed(Bench &tb) {
    tb.reset();
    for (unsigned code = 0; code < 8; ++code) {
        Input in = for_class(code);
        in.first = true;
        auto first = tb.tick(in);
        require(first.next_code == Successor[first.code], "new batch selects frozen map");
        in.first = false;
        Expected e;
        for (unsigned i = 0; i < 12; ++i) e = tb.tick(in);
        require(e.code == code && e.next_code == code,
                "all eight fitting continuous classes select repeat prediction");
        check_matrix(tb.policy(), tb.skip(), false);
        in.exact_zero = true;
        e = tb.tick(in);
        require(e.skip == (code == 6), "exact-zero sparse authorization");
        check_matrix(tb.policy(), tb.skip(), true);
        in.k = in.k == 64 ? 128 : 64;
        auto broken = tb.tick(in);
        require(broken.code == code && broken.next_code == Successor[code],
                "all eight selected classes use literal frozen map on shape discontinuity");
        auto idle = for_class((code + 1) % 8);
        idle.valid = false;
        idle.first = idle.last = idle.next_addr_valid = true;
        require(tb.tick(idle).next_code == Successor[code],
                "idle holds latched successor despite unrelated input metadata");
        auto restored = tb.tick(in);
        require(restored.code == code && restored.next_code == code,
                "repeat resumes after continuity is restored, without needing a warm hint");
        in.last = in.next_addr_valid = true;
        auto last = tb.tick(in);
        require(!last.warm && last.next_code == code,
                "last suppresses hint but still latches selected next code");
    }
    for (unsigned code = 0; code < 8; ++code)
        require(tb.codes[code] != 0, "all eight committed classes must be covered");

    tb.reset();
    tb.check_cleared_prediction();
    auto continuous = for_class(0);
    continuous.next_addr_valid = true;
    auto prior = tb.tick(continuous);
    require(prior.warm && prior.next_code == 4, "first bulk work emits transition prior");
    auto repeated = tb.tick(continuous);
    require(repeated.miss && !repeated.warm && repeated.next_code == 0,
            "previous transition prior misses while current repeat is latched without a hint");
    for (unsigned i = 0; i < CooldownWork; ++i) {
        auto held = tb.tick(continuous);
        require(!held.warm && held.next_code == 0, "cooldown does not freeze next-code selection");
    }
    require(tb.tick(continuous).warm, "repeat hint resumes after cooldown");
    continuous.opcode = 3;
    auto compatible = tb.tick(continuous);
    require(compatible.hit && compatible.raw == 0 && compatible.next_code == 0,
            "opcode change retaining raw class and shape continuity still predicts repeat");
    continuous.opcode = 2;
    auto challenger = tb.tick(continuous);
    require(challenger.miss && challenger.code == 0 && challenger.raw == 5 &&
            challenger.next_code == 4,
            "same-shape different raw class vetoes incumbent repeat and resolves previous hint");
    tb.tick(continuous);
    auto switched = tb.tick(continuous);
    require(switched.commit && switched.code == 5 && switched.next_code == 5,
            "newly selected fitting class predicts repeat on its commit record");
    require(tb.tick(continuous).warm, "new class issues its repeat hint");
    continuous.k = 128;
    auto discontinuous = tb.tick(continuous);
    require(discontinuous.hit && discontinuous.code == 5 && discontinuous.next_code == 3,
            "same raw class but changed buckets uses prior and resolves the previous repeat");
    auto recontinuous = tb.tick(continuous);
    require(recontinuous.miss && recontinuous.next_code == 5,
            "prediction resolution uses previous issued prior, not newly selected repeat");

    tb.reset();
    tb.tick(for_class(0));
    for (unsigned i = 1; i <= 4; ++i) {
        const auto e = tb.tick(for_class(1));
        require(e.commit == (i == 4), "dwell must count accepted records, not cycles");
        if (i == 2) {
            auto idle = for_class(5);
            idle.valid = false;
            idle.first = idle.last = idle.mispredict = true;
            for (unsigned j = 0; j < 19; ++j) tb.tick(idle);
        }
    }
    for (unsigned i = 0; i < 10; ++i) tb.tick(for_class(1));
    for (unsigned i = 1; i <= 3; ++i) {
        auto e = tb.tick(for_class(2));
        require(e.commit == (i == 3), "aged policy switches on third vote");
    }
    for (unsigned i = 0; i < 5; ++i) tb.tick(for_class(2));
    tb.tick(for_class(4));
    tb.tick(for_class(4));
    tb.tick(for_class(5));
    tb.tick(for_class(2));
    for (unsigned i = 1; i <= 3; ++i) {
        auto e = tb.tick(for_class(4));
        require(e.commit == (i == 3), "same-current vote must cancel pending evidence");
    }

    tb.reset();
    auto sticky = for_class(3);
    tb.tick(sticky);
    tb.tick(sticky);
    for (unsigned i = 0; i < 300; ++i) {
        sticky.m = uint16_t(2 + i % 7);
        sticky.n = uint16_t(65 + i);
        sticky.k = uint16_t(1000 + i);
        sticky.sample = sample_with_zeros(i % 6);
        sticky.exact_zero = i & 1;
        sticky.testmode = i & 1;
        auto e = tb.tick(sticky);
        require(e.code == 3 && !e.commit, "sticky decode must not oscillate");
        if (i > 1) require(!e.eval, "same bucket signature should not re-encode");
    }
    for (unsigned pass = 0; pass < 3; ++pass)
        for (unsigned code : {0u, 4u, 1u, 2u, 5u, 3u, 6u, 7u}) {
            auto in = for_class(code);
            for (unsigned i = 0; i < 30; ++i) tb.tick(in);
        }

    tb.reset();
    auto sparse = for_class(6);
    for (unsigned i = 0; i < 8; ++i) tb.tick(sparse);
    for (unsigned zeros : {5u, 6u, 7u, 8u, 0u, 6u}) {
        sparse.sample = sample_with_zeros(zeros);
        sparse.exact_zero = false;
        auto e = tb.tick(sparse);
        require(!e.skip, "sample residue must never authorize numerical skipping");
        check_matrix(tb.policy(), tb.skip(), false);
    }
    sparse.sample_valid = false;
    sparse.sample = 0;
    for (unsigned i = 0; i < 8; ++i) tb.tick(sparse);
    require(tb.policy() == packed_policy(0), "invalid sample cannot select sparse");
    sparse.sample_valid = true;
    for (unsigned i = 0; i < 8; ++i) tb.tick(sparse);
    sparse.m = 0;
    sparse.exact_zero = true;
    require(!tb.tick(sparse).skip, "invalid shape vetoes skip even during sparse hold");
    sparse = for_class(6);
    sparse.first = true;
    require(tb.tick(sparse).code == 0, "batch_first clears sparse continuity");
    sparse.first = false;
    sparse.last = true;
    tb.tick(sparse);
    sparse.last = false;
    require(tb.tick(sparse).code == 0, "batch_last clears next record continuity");

    for (unsigned mask = 0; mask < 256; ++mask) {
        auto residue = for_class(6);
        residue.sample = 0;
        unsigned zero_count = 0;
        for (unsigned byte = 0; byte < 8; ++byte) {
            zero_count += (mask >> byte) & 1;
            if (!((mask >> byte) & 1)) residue.sample |= uint64_t(0x80 + byte) << (8 * byte);
        }
        residue.first = true;
        tb.tick(residue);
        residue.first = false;
        Expected settled;
        for (unsigned i = 0; i < 6; ++i) settled = tb.tick(residue);
        require(settled.code == (zero_count >= 6 ? 6u : 0u) && !settled.skip,
                "all 256 signed-int8 sample zero masks must honor the six-of-eight threshold");
    }

    tb.reset();
    auto decode = for_class(3);
    decode.next_addr_valid = true;
    require(tb.tick(decode).warm, "initial warm hint");
    auto idle = for_class(7);
    idle.valid = false;
    idle.next_addr_valid = idle.mispredict = idle.first = idle.last = true;
    for (unsigned i = 0; i < 20; ++i) tb.tick(idle);
    require(tb.tick(decode).hit, "idle must preserve prediction until accepted input");
    decode.mispredict = true;
    auto miss = tb.tick(decode);
    require(miss.miss && !miss.hit && !miss.warm, "injected miss suppresses current hint");
    decode.mispredict = false;
    for (unsigned i = 0; i < CooldownWork; ++i) {
        for (unsigned j = 0; j < 7; ++j) tb.tick(idle);
        require(!tb.tick(decode).warm, "cooldown counts accepted records");
    }
    require(tb.tick(decode).warm, "hint resumes immediately after cooldown");
    decode.next_addr_valid = false;
    require(tb.tick(decode).hit, "pending hint resolves even without a new address");
    require(!tb.tick(decode).hit, "no address must not fabricate a prediction");
    decode.next_addr_valid = true;
    tb.tick(decode);
    auto bulk = for_class(0);
    bulk.next_addr_valid = true;
    auto raw_miss = tb.tick(bulk);
    require(raw_miss.code == 3 && raw_miss.raw == 0 && raw_miss.miss,
            "prediction compares raw candidate, not held committed code");
    for (unsigned i = 0; i < 4; ++i) tb.tick(decode);
    auto fresh = for_class(5);
    fresh.first = true;
    fresh.next_addr_valid = true;
    auto e = tb.tick(fresh);
    require(e.commit && !e.hit && !e.miss, "new batch cancels outstanding prediction");
    fresh.first = false;
    fresh.last = true;
    require(!tb.tick(fresh).warm, "last suppresses warm hint");
    auto after_last = tb.tick(bulk);
    require(after_last.commit && after_last.eval && !after_last.miss,
            "first record after last commits immediately");
    for (unsigned bank = 0; bank < 16; ++bank) {
        decode.first = true;
        decode.next_addr = UINT64_C(0xfedcba9800000000) | (uint64_t(bank) << 6) | 63;
        require(tb.tick(decode).warm, "all caller-selected banks must be tested");
    }

    tb.reset();
    auto injected = for_class(0);
    tb.tick(injected);
    injected.next_addr_valid = true;
    injected.mispredict = true;
    auto without_pending = tb.tick(injected);
    require(!without_pending.miss && !without_pending.hit && without_pending.warm,
            "injected miss without a pending hint is ignored, including cooldown");
    injected.first = true;
    auto fresh_injected = tb.tick(injected);
    require(!fresh_injected.miss && !fresh_injected.hit && fresh_injected.warm,
            "new batch discards pending hint without scoring an injected miss");
    injected.first = false;
    auto resolved_injected = tb.tick(injected);
    require(resolved_injected.miss && !resolved_injected.warm,
            "injected miss resolves an issued hint on accepted work");
    injected.mispredict = false;
    for (unsigned i = 0; i < CooldownWork; ++i)
        require(!tb.tick(injected).warm, "resolved injected miss starts cooldown");
    require(tb.tick(injected).warm, "resolved miss cooldown must expire");
    for (unsigned dimension = 0; dimension < 3; ++dimension) {
        auto empty = for_class(0);
        empty.first = empty.next_addr_valid = true;
        if (dimension == 0) empty.m = 0;
        if (dimension == 1) empty.n = 0;
        if (dimension == 2) empty.k = 0;
        auto invalid = tb.tick(empty);
        require(invalid.code == 7 && !invalid.warm && !invalid.hit && !invalid.miss,
                "empty shapes never emit warm hints");
    }

    tb.reset();
    auto metadata = for_class(0);
    tb.tick(metadata);
    tb.tick(metadata);
    require(!tb.tick(metadata).eval, "metadata cache must settle");
    metadata.balance = 3;
    auto mixed_reserved = tb.tick(metadata);
    require(mixed_reserved.code == 0 && !mixed_reserved.eval,
            "reserved balance normalizes to mixed before the lossless semantic signature");
    metadata.balance = 1;
    require(!tb.tick(metadata).eval, "normalized balance 1 to 3 to 1 must remain silent");

    for (unsigned mode = 0; mode < 3; ++mode) {
        tb.tick(for_class(5));
        tb.tick(for_class(4));
        Input clear;
        clear.reset = mode == 0;
        clear.flush = mode == 1;
        clear.enable = mode != 2;
        clear.valid = false;
        tb.tick(clear);
        tb.check_cleared_prediction();
        for (unsigned i = 0; i < 4; ++i) tb.tick(clear);
        auto start = for_class(2);
        auto restart = tb.tick(start);
        require(restart.eval && restart.commit && restart.code == 2,
                "reset/flush/disable must invalidate cached policy and evidence");
    }
    std::cout << "DIRECTED PASS tables, walks, holds, buckets, residue, cooldown, batches, purity\n";
}

void parameter_directed(Bench &tb) {
    const unsigned settle = std::max(HoldWork, DwellWork) + 2;
    tb.reset();
    tb.check_cleared_prediction();
    for (unsigned code = 0; code < 8; ++code) {
        auto in = for_class(code);
        in.first = true;
        tb.tick(in);
        in.first = false;
        Expected e;
        for (unsigned i = 0; i < settle; ++i) e = tb.tick(in);
        require(e.code == code && e.next_code == code, "parameterized all-class settling and repeat");
        check_matrix(tb.policy(), tb.skip(), false);
        in.exact_zero = true;
        require(tb.tick(in).skip == (code == 6), "parameterized exact-zero authorization");
        check_matrix(tb.policy(), tb.skip(), true);
    }
    tb.reset();
    tb.tick(for_class(0));
    const unsigned first_switch = std::max(HoldWork, DwellWork);
    for (unsigned vote = 1; vote <= first_switch; ++vote) {
        auto idle = for_class(7);
        idle.valid = false;
        idle.first = idle.last = idle.mispredict = true;
        for (unsigned gap = 0; gap < 5; ++gap) tb.tick(idle);
        auto e = tb.tick(for_class(1));
        require(e.commit == (vote == first_switch), "parameterized first-switch latency");
    }
    for (unsigned i = 0; i < DwellWork + 3; ++i) tb.tick(for_class(1));
    for (unsigned vote = 1; vote <= HoldWork; ++vote)
        require(tb.tick(for_class(2)).commit == (vote == HoldWork),
                "parameterized saturated-dwell switch latency");
    for (unsigned i = 0; i < DwellWork + 3; ++i) tb.tick(for_class(2));
    if (HoldWork > 1) {
        for (unsigned vote = 1; vote < HoldWork; ++vote)
            require(!tb.tick(for_class(4)).commit, "short challenger must not take over");
        tb.tick(for_class(2));
        for (unsigned vote = 1; vote <= HoldWork; ++vote)
            require(tb.tick(for_class(4)).commit == (vote == HoldWork),
                    "parameterized pending evidence cancellation");
    }
    tb.reset();
    auto decode = for_class(3);
    decode.next_addr_valid = true;
    require(tb.tick(decode).warm, "parameterized initial hint");
    decode.mispredict = true;
    require(tb.tick(decode).miss, "parameterized injected resolution miss");
    for (unsigned i = 0; i < CooldownWork; ++i) {
        auto idle = for_class(0);
        idle.valid = false;
        idle.mispredict = idle.first = idle.last = true;
        for (unsigned gap = 0; gap < 4; ++gap) tb.tick(idle);
        auto e = tb.tick(decode);
        require(!e.warm && !e.hit && !e.miss,
                "cooldown ignores idle cycles and injection without pending hints");
    }
    auto resume = tb.tick(decode);
    require(resume.warm && !resume.miss, "parameterized cooldown expires exactly");
    decode.mispredict = false;
    require(tb.tick(decode).hit, "parameterized resumed hint resolves");
    for (unsigned bank = 0; bank <= BankMask; ++bank) {
        decode.first = true;
        decode.testmode = bank & 1;
        decode.next_addr = UINT64_C(0xa55a550000000000) | (uint64_t(bank) << 6) | 37;
        auto e = tb.tick(decode);
        require(e.warm && !e.hit && !e.miss, "parameterized bank/new-batch coverage");
    }
    for (unsigned boundary = 0; boundary < 4; ++boundary) {
        auto end = for_class(6);
        end.valid = boundary == 3;
        end.reset = boundary == 0;
        end.flush = boundary == 1;
        end.enable = boundary != 2;
        end.last = boundary == 3;
        tb.tick(end);
        auto e = tb.tick(for_class(5));
        require(e.commit && e.eval && e.code == 5, "parameterized history invalidation");
    }
    std::cout << "PARAMETERS PASS hold=" << HoldWork << " dwell=" << DwellWork
              << " cooldown=" << CooldownWork << " bank_bits=" << BankBits << '\n';
}

void shape_sweep(Bench &tb) {
    const std::array<uint16_t, 8> dimensions{{0, 1, 2, 8, 9, 64, 65, 65535}};
    for (auto m : dimensions)
        for (auto n : dimensions)
            for (auto k : dimensions)
                for (unsigned op = 0; op < 8; ++op)
                    for (unsigned balance = 0; balance < 4; ++balance) {
                        Input in;
                        in.m = m;
                        in.n = n;
                        in.k = k;
                        in.opcode = op;
                        in.balance = balance;
                        in.first = true;
                        in.sample = sample_with_zeros(6);
                        tb.tick(in);
                        in.first = false;
                        for (unsigned repeat = 0; repeat < 5; ++repeat) tb.tick(in);
                    }
    std::cout << "SHAPE_SWEEP PASS 16384 metadata combinations with six accepted records each\n";
}

void randomized(Bench &tb, uint64_t seed, unsigned count) {
    std::mt19937_64 rng(seed);
    const std::array<uint16_t, 10> dimensions{{0, 1, 2, 7, 8, 9, 63, 64, 65, 65535}};
    Input in;
    for (unsigned i = 0; i < count; ++i) {
        if (rng() % 5 == 0) {
            in = for_class(unsigned(rng() % 8));
        } else if (rng() % 7 == 0) {
            in.m = dimensions[rng() % dimensions.size()];
            in.n = dimensions[rng() % dimensions.size()];
            in.k = dimensions[rng() % dimensions.size()];
            in.opcode = unsigned(rng() % 8);
            in.balance = unsigned(rng() % 4);
        }
        in.sample_valid = rng() % 5 != 0;
        in.sample = sample_with_zeros(unsigned(rng() % 9));
        in.exact_zero = rng() % 4 == 0;
        in.next_addr = rng();
        in.next_addr_valid = rng() % 3 != 0;
        in.mispredict = rng() % 47 == 0;
        in.valid = rng() % 5 != 0;
        in.first = rng() % 67 == 0;
        in.last = rng() % 71 == 0;
        in.enable = rng() % 113 != 0;
        in.flush = rng() % 127 == 0;
        in.reset = rng() % 257 == 0;
        in.testmode = rng() & 1;
        tb.tick(in);
    }
    std::cout << "RANDOM PASS seed=" << seed << " cycles=" << count << '\n';
}

struct Metrics {
    uint64_t work = 0, eval = 0, commit = 0, fit = 0, hit = 0, miss = 0, hints = 0;
    uint64_t injected_requests = 0, injected_resolutions = 0;
    std::array<uint64_t, 8> raw{}, selected{};
    void add(const Expected &e, bool injected) {
        if (!e.work) return;
        ++work;
        eval += e.eval;
        commit += e.commit;
        fit += e.code == e.raw;
        hit += e.hit;
        miss += e.miss;
        hints += e.warm;
        injected_requests += injected;
        injected_resolutions += injected && e.miss;
        ++raw[e.raw];
        ++selected[e.code];
    }
    void report(const std::string &name, bool representative, bool gate_prediction) const {
        require(work != 0, "empty workload");
        require(hit + miss <= hints, "prediction denominator must not include nonexistent hints");
        const double accuracy = double(fit) / double(work);
        std::cout << std::fixed << std::setprecision(4)
                  << "SCENARIO " << name << " work=" << work
                  << " eval_rate=" << double(eval) / double(work)
                  << " commit_rate=" << double(commit) / double(work)
                  << " committed_raw_fit=" << accuracy
                  << " prediction_hits=" << hit << " prediction_misses=" << miss
                  << " hint_count=" << hints << " prediction_resolved=" << hit + miss
                  << " unscored_hints=" << hints - hit - miss
                  << " injected_requests=" << injected_requests
                  << " injected_resolutions=" << injected_resolutions
                  << " prediction_accuracy="
                  << (hit + miss ? double(hit) / double(hit + miss) : 0.0) << '\n';
        std::cout << "DISTRIBUTION " << name << " raw=";
        for (auto x : raw) std::cout << x << ',';
        std::cout << " selected=";
        for (auto x : selected) std::cout << x << ',';
        std::cout << '\n';
        const double ideal = 100.0 * double(work);
        const double bulk_baseline = ideal + 30.0 * double(work - raw[0]);
        for (double transition_tax : {0.0, 1.0, 4.0, 16.0, 64.0})
            for (double mispredict_tax : {0.0, 12.0, 48.0, 192.0}) {
                const double model = ideal + 30.0 * double(work - fit) +
                    transition_tax * double(commit) + 0.25 * transition_tax * double(eval) +
                    0.5 * transition_tax * double(hints) + mispredict_tax * double(miss) -
                    6.0 * double(hit);
                std::cout << "MODELED_COST " << name << " transition_tax=" << transition_tax
                          << " mispredict_tax=" << mispredict_tax
                          << " codec=" << model << " static_bulk=" << bulk_baseline
                          << " oracle_no_tax=" << ideal
                          << " delta_vs_bulk=" << (model / bulk_baseline - 1.0) << '\n';
            }
        if (representative) {
            require(accuracy >= 0.90, name + " long-run committed/raw fit below 90%");
            require(eval * 5 < work, name + " long-run re-encode rate above 20%");
            require(commit * 10 < work, name + " long-run commit rate above 10%");
        }
        if (gate_prediction) {
            require(hit + miss != 0, name + " must resolve issued predictions");
            require(hit * 10 >= (hit + miss) * 9,
                    name + " representative issued-hint accuracy below 90%");
        }
    }
};

void workload(Bench &tb, const std::string &name,
              const std::vector<std::array<unsigned, 2>> &phases, bool representative,
              unsigned injection_period = 0) {
    tb.reset();
    Metrics metrics;
    uint64_t seq = 0;
    const unsigned repetitions = representative ? 4 : 256;
    for (unsigned repetition = 0; repetition < repetitions; ++repetition)
        for (const auto &phase : phases) {
            auto in = for_class(phase[0]);
            in.next_addr_valid = true;
            for (unsigned i = 0; i < phase[1]; ++i) {
                in.next_addr = UINT64_C(0x1234000000000000) + 64 * seq++;
                in.first = seq == 1;
                in.mispredict = injection_period && seq % injection_period == 0;
                metrics.add(tb.tick(in), in.mispredict);
                if (i % 23 == 0) {
                    auto idle = for_class(7);
                    idle.valid = false;
                    tb.tick(idle);
                }
            }
        }
    metrics.report(name, representative, representative && injection_period == 0);
}

struct LogicalOperator {
    std::string name;
    unsigned m, n, k, opcode, zero_per_mille;
};

struct ShapeWorkload {
    std::string name;
    std::vector<LogicalOperator> operators;
};

struct ShapeWork {
    Input input;
    uint64_t address;
};

struct ShapeAccounting {
    uint64_t records = 0, tail_records = 0, output_tiles = 0, useful_macs = 0;
    uint64_t logical_a = 0, logical_b = 0, streamed_a = 0, streamed_b = 0;
    uint64_t c_initial = 0, c_final = 0, c_spill_reads = 0, c_spill_writes = 0;
    std::array<uint64_t, 3> balance_counts{};
};

constexpr unsigned ShapeTile = 256;

uint64_t shape_tiles(unsigned dimension) {
    return (uint64_t(dimension) + ShapeTile - 1) / ShapeTile;
}

uint64_t shape_record_count(const LogicalOperator &op) {
    require(op.m && op.n && op.k && op.opcode <= 3 && op.zero_per_mille <= 1000,
            "invalid assumed logical operator");
    return shape_tiles(op.m) * shape_tiles(op.n) * shape_tiles(op.k);
}

uint64_t sampled_int8_metadata(std::mt19937_64 &rng, unsigned zero_per_mille) {
    std::array<int8_t, 64> patch{};
    for (auto &value : patch) {
        const unsigned draw = unsigned(rng() % 255);
        const int nonzero = draw < 128 ? int(draw) - 128 : int(draw) - 127;
        value = rng() % 1000 < zero_per_mille ? int8_t(0) : int8_t(nonzero);
    }
    uint64_t sample = 0;
    const unsigned offset = unsigned(rng() % 8);
    for (unsigned lane = 0; lane < 8; ++lane)
        sample |= uint64_t(uint8_t(patch[8 * lane + offset])) << (8 * lane);
    return sample;
}

unsigned shape_balance(unsigned m, unsigned n, unsigned k) {
    const uint64_t macs = uint64_t(m) * n * k;
    const uint64_t footprint = uint64_t(m) * k + uint64_t(n) * k + uint64_t(4) * m * n;
    const double intensity = double(macs) / double(footprint);
    return intensity < 4.0 ? 0 : intensity < 16.0 ? 1 : 2;
}

uint64_t shape_workload(Bench &tb, const ShapeWorkload &scenario, uint64_t seed,
                        unsigned scenario_index) {
    uint64_t planned = 0;
    for (const auto &op : scenario.operators) planned += shape_record_count(op);
    require(planned && planned <= 50000, "shape workload exceeds bounded record budget");
    std::vector<ShapeWork> records;
    records.reserve(static_cast<std::size_t>(planned));
    ShapeAccounting accounting;
    std::mt19937_64 rng(seed);
    uint64_t address = UINT64_C(0x4000000000000000) +
                       uint64_t(scenario_index) * UINT64_C(0x10000000000);
    unsigned operator_index = 0;
    for (const auto &op : scenario.operators) {
        const uint64_t start_records = accounting.records;
        const uint64_t start_macs = accounting.useful_macs;
        const uint64_t start_a = accounting.streamed_a, start_b = accounting.streamed_b;
        const uint64_t start_initial = accounting.c_initial, start_final = accounting.c_final;
        const uint64_t start_spill_reads = accounting.c_spill_reads;
        const uint64_t start_spill_writes = accounting.c_spill_writes;
        const uint64_t logical_macs = uint64_t(op.m) * op.n * op.k;
        accounting.logical_a += uint64_t(op.m) * op.k;
        accounting.logical_b += uint64_t(op.n) * op.k;
        std::cout << "ASSUMED_OPERATOR " << scenario.name << " index=" << operator_index++
                  << " name=" << op.name << " logical_m=" << op.m << " logical_n=" << op.n
                  << " logical_k=" << op.k << " opcode=" << op.opcode
                  << " sample_zero_per_mille=" << op.zero_per_mille
                  << " physical_records=" << shape_record_count(op)
                  << " useful_macs=" << logical_macs << '\n';
        for (unsigned mi = 0; mi < op.m; mi += ShapeTile)
            for (unsigned ni = 0; ni < op.n; ni += ShapeTile) {
                const unsigned m = std::min(ShapeTile, op.m - mi);
                const unsigned n = std::min(ShapeTile, op.n - ni);
                const uint64_t c_bytes = uint64_t(4) * m * n;
                ++accounting.output_tiles;
                accounting.c_initial += c_bytes;
                accounting.c_final += c_bytes;
                for (unsigned ki = 0; ki < op.k; ki += ShapeTile) {
                    const unsigned k = std::min(ShapeTile, op.k - ki);
                    const uint64_t a_bytes = uint64_t(m) * k;
                    const uint64_t b_bytes = uint64_t(n) * k;
                    Input in;
                    in.m = uint16_t(m);
                    in.n = uint16_t(n);
                    in.k = uint16_t(k);
                    in.opcode = op.opcode;
                    in.balance = shape_balance(m, n, k);
                    in.sample = sampled_int8_metadata(rng, op.zero_per_mille);
                    in.sample_valid = rng() % 32 != 0;
                    in.exact_zero = false;
                    require(in.m && in.n && in.k && in.m <= ShapeTile &&
                            in.n <= ShapeTile && in.k <= ShapeTile,
                            "logical lowering must emit nonempty physical tiles no larger than 256");
                    records.push_back({in, address});
                    address += (a_bytes + 63) & ~UINT64_C(63);
                    ++accounting.records;
                    accounting.tail_records += m != ShapeTile || n != ShapeTile || k != ShapeTile;
                    accounting.useful_macs += uint64_t(m) * n * k;
                    accounting.streamed_a += a_bytes;
                    accounting.streamed_b += b_bytes;
                    accounting.c_spill_reads += c_bytes;
                    accounting.c_spill_writes += c_bytes;
                    ++accounting.balance_counts[in.balance];
                }
            }
        const uint64_t c_matrix_bytes = uint64_t(4) * op.m * op.n;
        require(accounting.records - start_records == shape_record_count(op) &&
                accounting.useful_macs - start_macs == logical_macs,
                "lowered tile work must conserve useful logical MACs and cover all tails");
        require(accounting.streamed_a - start_a == uint64_t(op.m) * op.k * shape_tiles(op.n) &&
                accounting.streamed_b - start_b == uint64_t(op.n) * op.k * shape_tiles(op.m),
                "no-cross-tile-reuse INT8 operand byte accounting mismatch");
        require(accounting.c_initial - start_initial == c_matrix_bytes &&
                accounting.c_final - start_final == c_matrix_bytes &&
                accounting.c_spill_reads - start_spill_reads == c_matrix_bytes * shape_tiles(op.k) &&
                accounting.c_spill_writes - start_spill_writes == c_matrix_bytes * shape_tiles(op.k),
                "split-K accumulator traffic must distinguish resident from per-partial spill");
    }
    require(accounting.records == planned && records.size() == planned,
            "planned shape workload record count mismatch");
    tb.reset();
    Metrics metrics;
    for (std::size_t index = 0; index < records.size(); ++index) {
        auto in = records[index].input;
        in.first = index == 0;
        in.last = index + 1 == records.size();
        in.next_addr_valid = !in.last;
        if (in.next_addr_valid) in.next_addr = records[index + 1].address;
        const auto e = tb.tick(in);
        require(e.work && !e.skip,
                "shape-only sampling must not claim an exact-zero proof for unmaterialized operands");
        metrics.add(e, false);
        if (index % 127 == 0) {
            in.valid = false;
            tb.tick(in);
        }
    }
    require(metrics.work == planned, "held-out shape workload must consume every lowered record");
    const uint64_t operand_bytes = accounting.streamed_a + accounting.streamed_b;
    const uint64_t resident_bytes = operand_bytes + accounting.c_initial + accounting.c_final;
    const uint64_t spilled_bytes = operand_bytes + accounting.c_spill_reads + accounting.c_spill_writes;
    std::cout << "SHAPE_ACCOUNTING " << scenario.name << " seed=" << seed
              << " operators=" << scenario.operators.size() << " records=" << accounting.records
              << " partial_extent_records=" << accounting.tail_records
              << " output_tiles=" << accounting.output_tiles
              << " useful_macs=" << accounting.useful_macs
              << " logical_unique_a_bytes=" << accounting.logical_a
              << " logical_unique_b_bytes=" << accounting.logical_b
              << " streamed_a_bytes=" << accounting.streamed_a
              << " streamed_b_bytes=" << accounting.streamed_b
              << " c_initial_read_bytes=" << accounting.c_initial
              << " c_final_write_bytes=" << accounting.c_final
              << " worstcase_kspill_read_bytes=" << accounting.c_spill_reads
              << " worstcase_kspill_write_bytes=" << accounting.c_spill_writes
              << " resident_total_bytes=" << resident_bytes
              << " worstcase_kspill_total_bytes=" << spilled_bytes
              << " resident_macs_per_byte=" << double(accounting.useful_macs) / double(resident_bytes)
              << " balance_distribution=" << accounting.balance_counts[0] << ','
              << accounting.balance_counts[1] << ',' << accounting.balance_counts[2] << '\n';
    std::cout << "HELD_OUT_SHAPES " << scenario.name
              << " accuracy_gate=none fit_reference=raw_classifier_not_ground_truth_optimal\n";
    metrics.report(scenario.name, false, false);
    return accounting.records;
}

void shape_workloads(Bench &tb, uint64_t seed) {
    std::mt19937_64 shape_rng(seed ^ UINT64_C(0x736861706573));
    std::vector<ShapeWorkload> scenarios{
        {"shape_dense_prefill", {}}, {"shape_dense_decode", {}},
        {"shape_routed_experts", {}}, {"shape_diffusion_matrices", {}}
    };
    auto decoder = [](std::vector<LogicalOperator> &operators, unsigned m, unsigned context) {
        operators.push_back({"query_projection", m, 4096, 4096, 0, 40});
        operators.push_back({"key_projection", m, 4096, 4096, 0, 80});
        operators.push_back({"value_projection", m, 4096, 4096, 0, 120});
        operators.push_back({"attention_scores_per_head", m, context, 128, 1, 50});
        operators.push_back({"attention_mix_per_head", m, 128, context, 1, 75});
        operators.push_back({"attention_output_projection", m, 4096, 4096, 0, 80});
        operators.push_back({"ffn_gate_projection", m, 11008, 4096, 0, 750});
        operators.push_back({"ffn_up_projection", m, 11008, 4096, 0, 150});
        operators.push_back({"ffn_down_projection", m, 4096, 11008, 0, 300});
    };
    for (unsigned block = 0; block < 4; ++block) {
        const unsigned m = block % 2 ? 256 : 128;
        decoder(scenarios[0].operators, m, m);
    }
    for (unsigned step = 0; step < 3; ++step) {
        const unsigned m = step == 0 ? 1 : step == 1 ? 4 : (shape_rng() & 1 ? 1 : 4);
        decoder(scenarios[1].operators, m, 257 + 256 * step);
    }
    const std::array<unsigned, 8> routed_tokens{{3, 7, 17, 33, 65, 129, 5, 9}};
    const std::array<unsigned, 4> expert_widths{{1536, 1537, 3072, 3073}};
    for (unsigned burst = 0; burst < routed_tokens.size(); ++burst) {
        const unsigned tokens = routed_tokens[burst] + unsigned(shape_rng() % 4);
        const unsigned width = expert_widths[shape_rng() % expert_widths.size()];
        const unsigned zero_noise = burst % 2 ? 850 : 50;
        scenarios[2].operators.push_back({"shared_dense_projection", tokens, 4096, 4096, 0, 100});
        scenarios[2].operators.push_back({"explicitly_routed_expert_up", tokens, width, 4096, 2, zero_noise});
        scenarios[2].operators.push_back({"explicitly_routed_expert_down", tokens, 4096, width, 2, zero_noise});
    }
    for (unsigned step = 0; step < 4; ++step) {
        const unsigned noise = 50 + unsigned(shape_rng() % 4) * 200;
        auto &operators = scenarios[3].operators;
        operators.push_back({"spatial_linear", 1024, 320, 320, 0, noise});
        operators.push_back({"channel_expansion", 1024, 1280, 320, 0, noise});
        operators.push_back({"channel_reduction", 1024, 320, 1280, 0, noise});
        operators.push_back({"conv3x3_already_lowered", 1024, 320, 2880, 3, noise});
        operators.push_back({"spatial_attention_per_head", 256, 256, 80, 1, 80});
        operators.push_back({"ragged_spatial_projection", 1003, 321, 1280, 0, noise});
    }
    uint64_t planned = 0;
    for (const auto &scenario : scenarios)
        for (const auto &op : scenario.operators) planned += shape_record_count(op);
    require(planned >= 10000 && planned <= 50000, "held-out shape generation must remain bounded");
    std::cout << "SHAPE_ASSUMPTIONS seed=" << seed << " planned_records=" << planned
              << " illustrative_assumed_shapes_not_named_pretrained_model_traces=1 "
                 "not_a_complete_model_or_measured_hardware_throughput=1 "
                 "tile_max=256x256x256 loop_order=M,N,K INT8_A_B=1_byte INT32_C=4_bytes "
                 "C_initial_read_and_final_write_once_per_MN_tile=1 "
                 "K_resident_accumulation=1 worstcase_Kspill=read_and_write_C_each_K_partial "
                 "A_B_no_cross_tile_reuse=1 "
                 "excludes_alignment_padding_cache_bias_activation_and_conv_lowering_traffic=1 "
                 "balance_host_MACs_per_MK_plus_NK_plus_4MN=movement_below4_mixed_below16_compute_otherwise "
                 "balance_is_uncalibrated_footprint_estimate_not_the_reported_traffic_model=1 "
                 "sample_source=seeded_64_byte_patch_not_materialized_full_operands "
                 "sample_valid_probability=31/32 exact_zero_proof=never_claimed "
                 "next_addr=next_synthetic_A_tile_stream_storage "
                 "classifier_table_and_existing_thresholds_unchanged=1\n";
    uint64_t actual = 0;
    for (unsigned index = 0; index < scenarios.size(); ++index)
        actual += shape_workload(tb, scenarios[index],
                                 seed ^ (UINT64_C(0x9e3779b97f4a7c15) * (index + 1)), index);
    require(actual == planned, "shape workload accounting must match the complete logical walks");
    std::cout << "SHAPE_WORKLOADS PASS records=" << actual
              << " scope=scoreboard_and_lowering_accounting_not_full_tensor_execution\n";
}

void workloads(Bench &tb) {
    std::cout << "MODELED_ONLY synthetic LLM-inspired traces, frozen repeat-or-successor rule; "
                 "not hardware speed, learned PGO, power, or measured memory latency\n";
    std::cout << "MODELED_ASSUMPTIONS base=100/work wrong_exact_code=30/work "
                 "commit=transition_tax eval=transition_tax/4 hint=transition_tax/2 "
                 "miss=mispredict_tax hit_credit=6 cost_units; "
                 "fit_is_exact_code_agreement_not_compatible_policy_fit\n";
    workload(tb, "pure_bulk", {{{0, 500}}}, true);
    workload(tb, "prefill", {{{0, 160}}, {{4, 80}}, {{1, 120}}}, true);
    workload(tb, "decode", {{{3, 500}}}, true);
    workload(tb, "decode_injected_misses", {{{3, 500}}}, true, 11);
    workload(tb, "mixed_prefill_decode", {{{0, 160}}, {{4, 100}}, {{3, 220}}, {{7, 80}}}, true);
    workload(tb, "routed_experts", {{{5, 160}}, {{1, 140}}, {{3, 140}}}, true);
    workload(tb, "diffusion_like", {{{2, 140}}, {{0, 160}}, {{4, 100}}, {{6, 100}}}, true);
    workload(tb, "adversarial_route_dense", {{{5, 1}}, {{0, 1}}, {{5, 2}}, {{0, 2}}}, false);
    workload(tb, "adversarial_all_classes", {{{0, 1}}, {{2, 1}}, {{5, 1}}, {{7, 1}},
                                             {{4, 1}}, {{1, 1}}, {{3, 1}}, {{6, 1}}}, false);
}
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    try {
        uint64_t seed = UINT64_C(0x6c706f6c696379);
        if (const char *s = std::getenv("AI_POLICY_SEED")) seed = std::stoull(s, nullptr, 0);
        Bench tb;
        const bool defaults = HoldWork == 3 && DwellWork == 4 && CooldownWork == 2 && BankBits == 4;
        if (defaults) {
            directed(tb);
            shape_sweep(tb);
            randomized(tb, seed, 30000);
            workloads(tb);
            shape_workloads(tb, seed);
        }
        parameter_directed(tb);
        if (!defaults) randomized(tb, seed, 6000);
        require(tb.hits && tb.misses && tb.skips, "hit/miss/exact-zero coverage required");
        std::cout << "AI_POLICY_CODEC PASS hold=" << HoldWork << " dwell=" << DwellWork
                  << " cooldown=" << CooldownWork << " bank_bits=" << BankBits
                  << " cycles=" << tb.cycle_count()
                  << " accepted=" << tb.accepted << " evals=" << tb.evals
                  << " commits=" << tb.commits << " hits=" << tb.hits
                  << " misses=" << tb.misses << " skips=" << tb.skips << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "AI_POLICY_CODEC FAIL " << e.what() << '\n';
        return 1;
    }
}
