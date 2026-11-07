// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include "cpu.cc"

namespace {
constexpr uint64_t Boot = 0x80000000, Probe = 0x50000000;
bool is_probe(uint64_t a) { return a >= Probe && a < Probe + 64; }
void check(bool condition, const char* label) {
  if (!condition) throw std::runtime_error(label);
}
unsigned protection(uint64_t a, bool enabled, bool negative) {
  unsigned result = 0;
  if (enabled) {
    switch (a - Probe) {
      case 0: result = 1; break;
      case 8: case 24: result = 3; break;
      case 16: case 32: result = 2; break;
    }
  }
  if (negative && a == Probe) result ^= 1;
  return result;
}
}

int main(int argc, char** argv) {
  try {
    check(argc == 5, "arguments");
    const bool enabled = std::stoi(argv[2]) != 0;
    const unsigned delay = std::stoul(argv[3]);
    const bool negative = std::stoi(argv[4]) != 0;
    std::array<uint32_t, 1024> rom{};
    std::array<uint32_t, 16> memory{};
    std::ifstream file(argv[1]);
    check(bool(file), "rom-open");
    for (auto& word : rom) check(bool(file >> std::hex >> word), "rom-length");
    auto read_data = [&](uint64_t a) -> uint64_t {
      a &= ~uint64_t(7);
      if (is_probe(a)) {
        const unsigned i = (a - Probe) / 4;
        return uint64_t(memory[i]) | (uint64_t(memory[i + 1]) << 32);
      }
      if (a >= Boot && a + 7 < Boot + 4096) {
        const unsigned i = (a - Boot) / 4;
        return uint64_t(rom[i]) | (uint64_t(rom[i + 1]) << 32);
      }
      return 0;
    };
    cxxrtl_design::p_g6lc__storamic__cpu__netlist top;
    top.p_clk.set(false);
    top.p_rst__n.set(false);
    top.step();
    for (unsigned n = 0; n < 8; ++n) {
      top.p_clk.set(false); top.step();
      top.p_clk.set(true); top.step();
    }
    top.p_rst__n.set(true);
    bool write_owned = false, read_owned = false, b_valid = false, done = false;
    uint64_t wa = 0, ra = 0;
    unsigned wi = 0, ri = 0, rlen = 0, rsize = 0, beat = 0, wait = 0;
    unsigned writes = 0, reads = 0;
    for (unsigned cycle = 0; cycle < 200000; ++cycle) {
      const bool awready = !write_owned && !b_valid && (cycle % 7 != 2);
      const bool arready = !read_owned && (cycle % 5 != 1);
      const bool wready = write_owned && !b_valid && (cycle % 7 != 3);
      const bool rvalid = read_owned && wait == 0;
      const bool last = beat == rlen;
      top.p_clk.set(false);
      top.p_awr.set(awready);
      top.p_wr.set(wready);
      top.p_bv.set(b_valid);
      top.p_bid.set(wi);
      top.p_bresp.set(0u);
      top.p_arr.set(arready);
      top.p_rv.set(rvalid);
      top.p_rid.set(ri);
      top.p_rd.set(read_data(ra + (uint64_t(beat) << rsize)));
      top.p_rl.set(last);
      top.p_rresp.set(0u);
      top.step();
      const bool aw = awready && top.p_awv.get<bool>();
      const bool w = wready && top.p_wv.get<bool>();
      const bool b = b_valid && top.p_br.get<bool>();
      const bool ar = arready && top.p_arv.get<bool>();
      const bool r = rvalid && top.p_rr.get<bool>();
      const uint64_t awa = top.p_awa.get<uint64_t>(), ara = top.p_ara.get<uint64_t>();
      const unsigned awid = top.p_awid.get<unsigned>(), arid = top.p_arid.get<unsigned>();
      const unsigned arlen = top.p_arlen.get<unsigned>(), arsize = top.p_arsize.get<unsigned>();
      const uint64_t data = top.p_wd.get<uint64_t>();
      const unsigned strobe = top.p_ws.get<unsigned>();
      const bool wlast = top.p_wl.get<bool>();
      if (aw && is_probe(awa)) {
        std::cout << "AW cycle=" << cycle << " address=" << std::hex << awa
                  << " prot=" << top.p_awprot.get<unsigned>() << std::dec << '\n';
        check(top.p_awprot.get<unsigned>() == protection(awa, enabled, negative), "aw-prot");
        check(top.p_awlen.get<unsigned>() == 0 && top.p_awsize.get<unsigned>() == 2 &&
              top.p_awatop.get<unsigned>() == 0, "scalar-write");
        ++writes;
      }
      if (ar && is_probe(ara)) {
        std::cout << "AR cycle=" << cycle << " address=" << std::hex << ara
                  << " prot=" << top.p_arprot.get<unsigned>() << std::dec << '\n';
        check(top.p_arprot.get<unsigned>() == protection(ara, enabled, negative), "ar-prot");
        check(arlen == 0 && arsize == 2, "scalar-read");
        ++reads;
      }
      top.p_clk.set(true);
      top.step();
      if (wait) --wait;
      if (b) {
        b_valid = false;
        if (done) {
          check(writes == 5 && reads == 4, "coverage");
          check(memory[0] == 0x11 && memory[2] == 0x22 && memory[4] == 0x33 &&
                memory[6] == 0x44 && memory[8] == 0x55, "readback");
          std::cout << "CPU_NETLIST_PASS enabled=" << enabled << " delay=" << delay
                    << " cycles=" << cycle << " writes=" << writes << " reads=" << reads << '\n';
          return 0;
        }
      }
      if (r) {
        if (last) read_owned = false;
        else { ++beat; wait = delay; }
      }
      if (aw) { check(!write_owned, "aw-owner"); wa = awa; wi = awid; write_owned = true; }
      if (w) {
        check(write_owned && wlast, "w-owner");
        check(is_probe(wa), "unexpected-write");
        for (unsigned lane = 0; lane < 8; ++lane) if (strobe & (1u << lane)) {
          const unsigned offset = unsigned(((wa & ~uint64_t(7)) + lane) - Probe);
          check(offset < 64, "write-range");
          const unsigned shift = (offset % 4) * 8;
          memory[offset / 4] = (memory[offset / 4] & ~(0xffu << shift)) |
                              (unsigned((data >> (lane * 8)) & 0xffu) << shift);
        }
        check(wa != Probe + 36, "architectural-trap-or-mismatch");
        done = wa == Probe + 32;
        write_owned = false;
        b_valid = true;
      }
      if (ar) {
        check(!read_owned, "ar-owner");
        ra = ara; ri = arid; rlen = arlen; rsize = arsize;
        beat = 0; wait = delay; read_owned = true;
      }
    }
    throw std::runtime_error("timeout");
  } catch (const std::exception& error) {
    std::cerr << "CPU_NETLIST_FAIL " << error.what() << '\n';
    return 1;
  }
}
