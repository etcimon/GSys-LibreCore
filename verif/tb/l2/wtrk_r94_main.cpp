// SPDX-License-Identifier: MIT
// Copyright 2026 Etienne Cimon
// Independent transaction-age model for the Hyp posted-write tracker.
#include "Vg6lc_l2_wtrk.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>

#ifndef WTRK_DEPTH
#define WTRK_DEPTH 4
#endif

struct Entry {
    bool valid = false, pending = false, marked = false;
    bool blocking = false, need_r = false;
    uint64_t age = 0;
    unsigned id = 0, dsid = 0, line = 0, resp = 0, user = 0;
};

struct Test {
    Vg6lc_l2_wtrk d;
    std::array<Entry, WTRK_DEPTH> entries{};
    std::mt19937 random{0x94a6e001};
    uint64_t age = 0, checks = 0, cycles = 0, pushes = 0, pops = 0, overlap = 0;

    void check(bool ok, const char* what) {
        ++checks;
        if (!ok) throw std::runtime_error(std::string(what) + " cycle=" +
                                         std::to_string(cycles));
    }
    int free_index() const {
        for (int e = 0; e < WTRK_DEPTH; ++e) if (!entries[e].valid) return e;
        return -1;
    }
    int oldest(bool pending, unsigned dsid = 0) const {
        int found = -1;
        for (int e = 0; e < WTRK_DEPTH; ++e)
            if (entries[e].valid && entries[e].pending == pending &&
                (pending || entries[e].dsid == dsid) &&
                (found < 0 || entries[e].age < entries[found].age)) found = e;
        return found;
    }
    void defaults() {
        d.clk_i = 0;
        d.push_i = 0; d.push_id_i = 0; d.push_dsid_i = 0;
        d.push_line_i = 0; d.push_blocking_i = 0; d.push_need_r_i = 0;
        d.mark_i = 0; d.mark_idx_i = 0;
        d.m_b_valid_i = 0; d.m_b_id_i = 0; d.m_b_resp_i = 0; d.m_b_user_i = 0;
        d.s_b_ready_i = 0; d.line0_i = 0xffff; d.line1_i = 0xfffe;
        d.need_r_id_i = 15;
    }
    void reset() {
        defaults(); d.rst_ni = 0; d.eval();
        d.clk_i = 1; d.eval();
        entries = {};
        defaults(); d.rst_ni = 1; d.eval();
    }
    void allocation(unsigned id, unsigned dsid) {
        d.push_i = 1; d.push_id_i = id & 15; d.push_dsid_i = dsid & 15;
        d.push_line_i = (age + 1) & 0xffff;
        d.push_blocking_i = id & 1; d.push_need_r_i = (id >> 1) & 1;
    }
    void tick() {
        ++cycles;
        d.clk_i = 0; d.eval();
        const int f = free_index(), m = oldest(false, d.m_b_id_i), p = oldest(true);
        bool any = false, l0 = false, wu = false, l1 = false, need = false;
        unsigned line_id = 0;
        for (const auto& e : entries) if (e.valid) {
            any = true;
            if (e.line == d.line0_i) { l0 = true; wu |= e.marked; }
            if (e.line == d.line1_i) { l1 = true; line_id = e.dsid; }
            need |= e.need_r && e.id == d.need_r_id_i;
        }
        check(bool(d.full_o) == (f < 0), "full");
        check(bool(d.empty_o) == !any, "empty");
        if (f >= 0) check(d.alloc_idx_o == unsigned(f), "allocation index");
        check(bool(d.m_b_match_o) == (m >= 0), "memory ID match");
        check(bool(d.s_b_valid_o) == (p >= 0), "pending B");
        check(bool(d.pop_o) == (p >= 0 && d.s_b_ready_i), "pop");
        if (p >= 0) {
            const auto& e = entries[p];
            check(d.s_b_id_o == e.id, "oldest B ID");
            check(d.s_b_resp_o == e.resp && d.s_b_user_o == e.user, "B payload");
            check(bool(d.s_b_blocking_o) == e.blocking, "blocking owner");
            check(d.pop_idx_o == unsigned(p), "pop index");
        }
        check(bool(d.line0_match_o) == l0 && bool(d.line0_wu_o) == wu, "line0");
        check(bool(d.line1_match_o) == l1, "line1");
        if (l1) check(d.line1_match_id_o == line_id, "line1 ID");
        check(bool(d.need_r_id_match_o) == need, "ATOP owner");
        check(!d.push_i || f >= 0, "legal allocation");
        check(!d.m_b_valid_i || m >= 0, "legal memory B");
        if (d.push_i && d.m_b_valid_i && p >= 0 && d.s_b_ready_i) ++overlap;

        // All choices above use the pre-edge model, never DUT selection outputs.
        if (d.m_b_valid_i) {
            entries[m].pending = true;
            entries[m].resp = d.m_b_resp_i; entries[m].user = d.m_b_user_i;
        }
        if (d.mark_i) entries[d.mark_idx_i].marked = true;
        if (d.push_i) {
            Entry e;
            e.valid = true; e.age = ++age; e.id = d.push_id_i; e.dsid = d.push_dsid_i;
            e.line = d.push_line_i; e.blocking = d.push_blocking_i; e.need_r = d.push_need_r_i;
            entries[f] = e; ++pushes;
        }
        if (p >= 0 && d.s_b_ready_i) { entries[p].valid = false; ++pops; }
        d.clk_i = 1; d.eval();
    }
    void drain() {
        for (int t = 0; t < 4 * WTRK_DEPTH + 4; ++t) {
            defaults(); d.s_b_ready_i = 1;
            for (const auto& e : entries) if (e.valid && !e.pending) {
                d.m_b_valid_i = 1; d.m_b_id_i = e.dsid; break;
            }
            tick();
        }
        for (const auto& e : entries) check(!e.valid, "drained");
    }
    void run() {
        reset();
        // Same downstream ID, all B responses retained under backpressure.
        for (int e = 0; e < WTRK_DEPTH; ++e) {
            defaults(); allocation(e, 1); tick();
        }
        for (int e = 0; e < WTRK_DEPTH; ++e) {
            defaults(); d.m_b_valid_i = 1; d.m_b_id_i = 1;
            d.m_b_resp_i = e & 3; d.m_b_user_i = e & 1; tick();
        }
        drain();
        // Distinct IDs complete in reverse order, then oldest-pending publication.
        for (int e = 0; e < WTRK_DEPTH; ++e) {
            defaults(); allocation(e, e); tick();
        }
        for (int e = WTRK_DEPTH - 1; e >= 0; --e) {
            defaults(); d.m_b_valid_i = 1; d.m_b_id_i = e; tick();
        }
        drain();
        for (int t = 0; t < 2000; ++t) {
            if (t == 777) reset();
            defaults();
            if (free_index() >= 0 && random() % 4 != 0) allocation(random(), random() % 3);
            d.s_b_ready_i = random() % 4 != 0;
            d.m_b_id_i = random() % 16;
            const unsigned start = random() % WTRK_DEPTH;
            for (int k = 0; k < WTRK_DEPTH; ++k) {
                const unsigned i = (start + k) % WTRK_DEPTH;
                const auto& e = entries[i];
                if (!e.valid) continue;
                d.line0_i = e.line; d.line1_i = e.line; d.need_r_id_i = e.id;
                d.mark_i = random() & 1; d.mark_idx_i = i;
                if (!e.pending && random() % 4 != 0) {
                    d.m_b_valid_i = 1; d.m_b_id_i = e.dsid;
                    d.m_b_resp_i = random() & 3; d.m_b_user_i = random() & 1;
                    break;
                }
            }
            tick();
        }
        drain();
        check(pushes > 100 && pops > 100, "traffic coverage");
        if (WTRK_DEPTH >= 3) check(overlap > 0, "push/B/pop overlap");
        d.final();
        std::cout << "PASS wtrk_r94 depth=" << WTRK_DEPTH << " checks=" << checks
                  << " pushes=" << pushes << " pops=" << pops << " overlap=" << overlap << '\n';
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try { Test t; t.run(); return 0; }
    catch (const std::exception& e) { std::cerr << "FAIL wtrk_r94 " << e.what() << '\n'; return 1; }
}
