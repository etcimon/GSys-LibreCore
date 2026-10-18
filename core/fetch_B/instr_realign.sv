// Copyright 2018 - 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
// Modified by: Etienne Cimon
// Description: Instruction Re-aligner
//
// A fetch block is a stream of halfwords. The frontend right-shifts the I$ line
// so halfword 0 is the one addressed by address_i, therefore this block carries
// FETCH_WIDTH/16 - address_i[FETCH_ALIGN_BITS-1:1] meaningful halfwords. An
// instruction starts at a halfword boundary and is 1 halfword (RVC) or 2
// halfwords (RVI) long, so the only state needed is the lower half of an RVI
// that did not fit in the block.
//
// A/B draft note: this replaces the (FETCH_WIDTH x offset x compressed-pattern)
// decision tree with one cursor walking that halfword stream, which makes the
// block width-generic (32/64/128/256) instead of hand-written for 32 and 64.

module instr_realign
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Fetch flush request - CONTROLLER (inert on leftover, like kill)
    input logic flush_i,
    // In-flight kill (misp/bp/replay) — must not consume leftover
    input logic kill_i,
    // Active hart — leftover is per-hart (I4)
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // 32-bit block is valid - CACHE
    input logic valid_i,
    // Instruction is unaligned - FRONTEND
    output logic serving_unaligned_o,
    // Leftover valid but not completing this window (I3 keep)
    output logic leftover_pending_o,
    // Carry valid (completing or not) — replay may retake leftover_next
    output logic leftover_valid_o,
    // Carry PC (reset 0; leftover_retake gates on leftover_valid_o)
    output logic [CVA6Cfg.VLEN-1:0] leftover_pc_o,
    // 32-bit block address - CACHE
    input logic [CVA6Cfg.VLEN-1:0] address_i,
    // 32-bit block - CACHE
    input logic [CVA6Cfg.FETCH_WIDTH-1:0] data_i,
    // instruction is valid - FRONTEND
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0] valid_o,
    // Instruction address - FRONTEND
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr_o,
    // The same address as {base, byte offset}: addr_o[k] == base_o[k] +
    // off_o[k] by construction (sv-timing A105). A consumer that adds an
    // immediate to the slot address can form one three-operand sum
    // (base + off + imm: a carry-save layer and one adder) instead of
    // waiting for the realigner's adder and adding again.
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] base_o,
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] off_o,
    // Instruction - instr_scan&instr_queue
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0][31:0] instr_o
);

  // Re-pipelining contract (sv-timing A128; 119.0 adjusted FO4 on the
  // Nangate45 board): fetch-window realign: a stream with a global kill (id-less domain); the carry bank is per-hart state.
  // svt-pipe: require-contract
  // svt-pipe: protocol rl valid=valid_i kill=kill_i flush=flush_i
  // svt-pipe: no-cut on=carry_addr_bank_q

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(CVA6Cfg);
  // halfwords per fetch block, bits needed to index one, and the cursor width
  // (the cursor also has to represent "one past the last halfword")
  localparam int unsigned NrHalfWords = Geo.hw_per_w;
  localparam int unsigned HwIdxW = Geo.align_bits - 1;
  localparam int unsigned CurW = Geo.align_bits;
  localparam bit FastContinuation = CVA6Cfg.RVC && NrHalfWords > 1 &&
      (NrHalfWords == (1 << HwIdxW)) && CVA6Cfg.VLEN > CurW && CVA6Cfg.VLEN <= 64;

  logic [NrHalfWords-1:0][15:0] hw;
  logic [NrHalfWords-1:0] hw_compressed;
  logic [CurW-1:0] hw_first;  // halfwords skipped by the fetch alignment
  logic [CurW-1:0] hw_avail;  // halfwords carried by this block

  // lower half of an instruction that spans into the next fetch block
  localparam int unsigned NH = (Geo.harts < 1) ? 1 : Geo.harts;
  logic [NH-1:0] carry_valid_bank_q;
  logic [NH-1:0][15:0] carry_instr_bank_q;
  logic [NH-1:0][CVA6Cfg.VLEN-1:0] carry_addr_bank_q;
  logic [15:0] carry_instr_d, carry_instr_q;
  logic [CVA6Cfg.VLEN-1:0] carry_addr_d, carry_addr_q;
  logic carry_valid_d, carry_valid_q;
  // A split instruction can only be completed by the block that immediately
  // follows the one that produced it. Its lower half is by construction the last
  // halfword of its block, so that block starts at carry_addr_q + 2. Any other
  // address (a redirect, a replay, or the same block presented twice) leaves the
  // carry stale and it must be dropped instead of consuming a halfword.
  logic carry_ok;
  logic carry_next_match;
  logic [CVA6Cfg.VLEN-1:0] window_last_pc;

  assign carry_valid_q = carry_valid_bank_q[hart_i];
  assign carry_instr_q = carry_instr_bank_q[hart_i];
  assign carry_addr_q  = carry_addr_bank_q[hart_i];

  assign carry_ok = g6lc_fetch_pkg::leftover_complete(
      carry_valid_q,
      carry_next_match,
      g6lc_fetch_pkg::rvi_prefix(carry_instr_q),
      1'b1);
  assign serving_unaligned_o = carry_ok;
  assign leftover_pending_o = g6lc_fetch_pkg::leftover_pending(carry_valid_q, carry_ok);
  assign leftover_valid_o = carry_valid_q;
  assign leftover_pc_o = carry_addr_q;

  for (genvar j = 0; j < NrHalfWords; j++) begin : gen_halfword
    assign hw[j] = data_i[16*j+:16];
    // without RVC no halfword can terminate an instruction
    assign hw_compressed[j] = (g6lc_fetch_pkg::ilen_of(CVA6Cfg, hw[j]) == 2);
  end

  // hw_first is how many halfwords the fetch alignment skipped; hw_avail is what
  // is left in this block. The cursor runs 0..hw_avail because the host already
  // right-shifted the line, so slot 0 is always the addressed halfword.
  assign hw_first = CVA6Cfg.RVC ? CurW'(g6lc_fetch_pkg::hw_off(CVA6Cfg, 64'(address_i))) : '0;
  assign hw_avail = CurW'(NrHalfWords) - hw_first;

  if (FastContinuation) begin : gen_continuation
    // A134: a split can only start at the last available halfword. Its PC
    // is therefore the window base plus the constant last-halfword offset.
    // Precompute and register the successor with the same hart's carry
    // state, removing carry_addr_q + 2 from the next window's feedback cone.
    // Keep 64 bits: at VLEN<64, overflow is NOT a match for a wrapped address.
    // svt-pipe: no-cut on=carry_next_bank_q
    logic [NH-1:0][63:0] carry_next_bank_q;
    logic [63:0] window_next_pc;
    assign window_last_pc =
        {address_i[CVA6Cfg.VLEN-1:CurW], {(CurW-1){1'b1}}, address_i[0]};
    assign window_next_pc = 64'(window_last_pc) + 64'd2;
    assign carry_next_match = 64'(address_i) == carry_next_bank_q[hart_i];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) carry_next_bank_q <= '0;
      else if (g6lc_fetch_pkg::leftover_update(flush_i, valid_i, kill_i) && carry_valid_d)
        carry_next_bank_q[hart_i] <= window_next_pc;
    end
    // pragma translate_off
    always_ff @(posedge clk_i) if (rst_ni) begin
      for (int unsigned h = 0; h < NH; h++)
        if (carry_valid_bank_q[h])
          assert (carry_next_bank_q[h] == 64'(carry_addr_bank_q[h]) + 64'd2)
            else $error("realign continuation lost carry PC/hart alignment");
    end
    // pragma translate_on
  end else begin : gen_continuation_fallback
    assign window_last_pc = '0;
    assign carry_next_match =
        g6lc_fetch_pkg::leftover_next(64'(address_i), 64'(carry_addr_q));
  end

  // Parallel realignment (sv-timing A110). The serial walk — a cursor that
  // steps by 1 or 2 halfwords depending on what it finds — was the module
  // board's realigner path and the first half of the frontend's branch-target
  // path (the predictor adds the immediate to the cursor's address). Here:
  //
  //   vis[h]  — an instruction is visited at halfword h. The walk's recurrence
  //             vis[h] = vis[h-1] & c'[h-1]  |  vis[h-2] & ~c'[h-2]
  //             (c' = "compressed", with position 0 counted compressed when a
  //             carried lower half completes there) is a two-term linear
  //             recurrence over the boolean semiring: a product of 2x2
  //             matrices, taken as a log-depth prefix. Positions at or past
  //             hw_avail are never visited.
  //   idx[h]  — the visit's ordinal = popcount(vis[h-1:0]) = its slot.
  //   split   — a visited RVI whose upper half is past the block: it carries.
  //
  // Each slot takes the one visited position whose ordinal is the slot; the
  // carry takes the one split visit. Same values as the walk, position by
  // position (equivalence: side-by-side harness, see the A110 record).
  localparam int unsigned IdxW = $clog2(NrHalfWords + 1);
  localparam int unsigned Lvl = (NrHalfWords > 1) ? $clog2(NrHalfWords) : 1;

  logic [NrHalfWords-1:0] vis, split, cprime;
  logic [NrHalfWords-1:0][IdxW-1:0] idx;
  // prefix[l][h]: the product of the step matrices covering the last 2**l
  // steps ending at h (boolean 2x2, [row][col])
  logic [Lvl:0][NrHalfWords-1:0][1:0][1:0] pfx;
  logic vis0;

  always_comb begin : realign_visits
    // position 0 counts as a compressed visit when the carried half completes
    for (int unsigned h = 0; h < NrHalfWords; h++)
      cprime[h] = (h == 0 && carry_ok) ? 1'b1 : hw_compressed[h];
    vis0 = carry_ok || (hw_avail != '0);
    // step matrix M_h: s[h+1] = M_h * s[h], s = (vis[h], vis[h-1])
    //   [ c'[h]   ~c'[h-1] ]
    //   [ 1        0       ]
    // pfx[0][h] = M_{h-1} (the single step into h); pfx[0][0] = identity
    pfx = '0;
    pfx[0][0][0][0] = 1'b1;
    pfx[0][0][1][1] = 1'b1;
    for (int unsigned h = 1; h < NrHalfWords; h++) begin
      pfx[0][h][0][0] = cprime[h-1];
      pfx[0][h][0][1] = (h >= 2) ? ~cprime[h-2] : 1'b0;
      pfx[0][h][1][0] = 1'b1;
      pfx[0][h][1][1] = 1'b0;
    end
    // Kogge-Stone: pfx[l][h] = pfx[l-1][h] * pfx[l-1][h - 2**(l-1)]
    for (int unsigned l = 1; l <= Lvl; l++) begin
      for (int unsigned h = 0; h < NrHalfWords; h++) begin
        if (h >= (1 << (l - 1))) begin
          for (int unsigned i = 0; i < 2; i++)
            for (int unsigned j = 0; j < 2; j++)
              pfx[l][h][i][j] = (pfx[l-1][h][i][0] & pfx[l-1][h-(1<<(l-1))][0][j]) |
                                (pfx[l-1][h][i][1] & pfx[l-1][h-(1<<(l-1))][1][j]);
        end else begin
          pfx[l][h] = pfx[l-1][h];
        end
      end
    end
    // s[0] = (vis0, 0): vis[h] = pfx[Lvl][h][0][0] & vis0, masked to the block
    for (int unsigned h = 0; h < NrHalfWords; h++) begin
      vis[h] = (h == 0) ? vis0 : (pfx[Lvl][h][0][0] & vis0 & (CurW'(h) < hw_avail));
      idx[h] = IdxW'($countones(vis & NrHalfWords'((NrHalfWords'(1) << h) - 1'b1)));
      // an RVI whose upper half is past the block carries (never at the
      // carried position: that visit is compressed by construction)
      split[h] = vis[h] && !cprime[h] && (CurW'(h) + CurW'(1) >= hw_avail);
    end
  end

  always_comb begin : realign
    logic [15:0] lo, hi;
    logic [CVA6Cfg.VLEN-1:0] slot_addr;

    carry_valid_d = 1'b0;
    carry_instr_d = carry_instr_q;
    carry_addr_d  = carry_addr_q;

    valid_o       = '0;
    instr_o       = '0;
    addr_o        = '0;
    base_o        = '0;
    off_o         = '0;
    lo            = '0;
    hi            = '0;
    slot_addr     = '0;

    for (int unsigned h = 0; h < NrHalfWords; h++) begin
      lo        = hw[h];
      // on the last halfword there is no successor to read; the zero is never
      // emitted as instruction bytes (a split RVI carries instead)
      hi        = (CurW'(h) + CurW'(1) < hw_avail) ? hw[(h + 1) % NrHalfWords] : 16'b0;
      slot_addr = address_i + {{(CVA6Cfg.VLEN - CurW - 1) {1'b0}}, CurW'(h), 1'b0};
      if (vis[h] && int'(idx[h]) < int'(CVA6Cfg.INSTR_PER_FETCH)) begin
        for (int unsigned k = 0; k < CVA6Cfg.INSTR_PER_FETCH; k++) begin
          if (idx[h] == IdxW'(k)) begin
            if (h == 0 && carry_ok) begin
              // the carried pc, not address_i: the instruction began in the
              // previous window; hw[0] is its upper half
              valid_o[k] = valid_i;
              instr_o[k] = {hw[0], carry_instr_q};
              addr_o[k]  = carry_addr_q;
              base_o[k]  = carry_addr_q;
            end else if (!split[h]) begin
              valid_o[k] = valid_i;
              instr_o[k] = {hi, lo};
              addr_o[k]  = slot_addr;
              base_o[k]  = address_i;
              off_o[k]   = {{(CVA6Cfg.VLEN - CurW - 1) {1'b0}}, CurW'(h), 1'b0};
            end
          end
        end
        if (split[h]) begin
          carry_valid_d = 1'b1;
          carry_instr_d = lo;
          carry_addr_d  = FastContinuation ? window_last_pc : slot_addr;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      carry_valid_bank_q <= '0;
      carry_instr_bank_q <= '0;
      carry_addr_bank_q  <= '0;
    end else begin
      // Kill and flush are INERT on carry state (SPEC L1): only a valid unkilled
      // window may consume or overwrite it. carry_valid_d defaults to 0, so a
      // foreign window drops the carry rather than keeping it (I4az).
      if (g6lc_fetch_pkg::leftover_update(flush_i, valid_i, kill_i)) begin
        carry_instr_bank_q[hart_i] <= carry_instr_d;
        carry_addr_bank_q[hart_i]  <= carry_addr_d;
        carry_valid_bank_q[hart_i] <= carry_valid_d;
      end
    end
  end
endmodule
