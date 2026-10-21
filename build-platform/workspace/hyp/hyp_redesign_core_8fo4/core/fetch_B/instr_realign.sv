// hyp8 provenance: REWRITTEN for the 8-FO4 frontend (two response stages)
// Copyright 2018 - 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
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
//
// hyp8: the response path is two registered stages (rank 4, front-end depth):
//   A (boundary/carry-half): the accepted response is registered together
//      with its fetch epoch; the carry bank sees windows one cycle after
//      acceptance.
//   B (lane alignment): the halfword visit prefix and the per-slot gather run
//      combinationally between the stage-A registers and the output
//      registers. All module outputs are registered stage-B results.
// A stage-A window whose recorded epoch is older than the current epoch is a
// dead response: it is presented as not-valid at stage B and, exactly like a
// killed window, leaves the carry bank untouched (SPEC L1).

module instr_realign
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8
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
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart_i,
    // hyp8: current fetch epoch, and the epoch stamped on this response when
    // its request was accepted; a mismatch at stage B kills the window
    input logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_i,
    input logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] rsp_epoch_i,
    // 32-bit block is valid - CACHE
    input logic valid_i,
    // Instruction is unaligned - FRONTEND
    output logic serving_unaligned_o,
    // Leftover valid but not completing this window (I3 keep)
    output logic leftover_pending_o,
    // Carry valid (completing or not) — replay may retake leftover_next
    output logic leftover_valid_o,
    // Carry PC (reset 0; leftover_retake gates on leftover_valid_o)
    output logic [G6LCCfg.VLEN-1:0] leftover_pc_o,
    // hyp8: LIVE bank state at the accept-time hart (hart_i) — the frontend's
    // replay-retake test runs at response accept, two stages before the
    // registered leftover_*_o values describe the window
    output logic                    bank_valid_o,
    output logic [G6LCCfg.VLEN-1:0] bank_pc_o,
    // hyp8: a carry completion is pending its verdict
    output logic                    pend_valid_o,
    // hyp8: this stage-B window completed a carry at slot0 (travels with the
    // window to the verdict stage)
    output logic carry_done_o,
    // hyp8: verdict for the pending completer arrives from the frontend:
    // resolve_i fires on the completing window's verdict cycle; keep_i holds
    // the carry (protected split branch / refused window re-present); a
    // resolve without keep finally drops the consumed carry.
    input logic pend_resolve_i,
    input logic pend_keep_i,
    // 32-bit block address - CACHE
    input logic [G6LCCfg.VLEN-1:0] address_i,
    // 32-bit block - CACHE
    input logic [G6LCCfg.FETCH_WIDTH-1:0] data_i,
    // instruction is valid - FRONTEND
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0] valid_o,
    // Instruction address - FRONTEND
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] addr_o,
    // The same address as {base, byte offset}: addr_o[k] == base_o[k] +
    // off_o[k] by construction (sv-timing A105). A consumer that adds an
    // immediate to the slot address can form one three-operand sum
    // (base + off + imm: a carry-save layer and one adder) instead of
    // waiting for the realigner's adder and adding again.
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] base_o,
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] off_o,
    // Instruction - instr_scan&instr_queue
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][31:0] instr_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin instr_realign status=proposal target=10-adjusted-FO4
  // svt-plan: cone realign_visits already uses a parallel prefix matrix;
  // prefix -> per-position rank -> instruction gather remains serial work.
  // svt-plan: boundary halfword classification/visits/ranks -> gather;
  // alternatively bank rank/gather locally before adding an interface cycle.
  // svt-plan: carry fetched bytes, starting VA, token/hart/epoch, carry
  // half+PC, continuation match, lengths, split flags and exception association.
  // svt-plan: ownership accept a window once; commit carry state only at
  // the defined consumption event, including partial acceptance and kill retention.
  // svt-plan: effect splits prefix/rank calculation from wide gather;
  // registered continuation-address state already exists and is not a new gain.
  // svt-plan: cost whole-window storage and realignment latency; frontend
  // and instr_queue need packet backpressure and synchronized consumed masks.
  // svt-plan: limit a delayed same-hart window cannot use an old carry bank
  // while a younger window updates it; serialize or forward pending carry state.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 119.0 adjusted FO4 on the
  // Nangate45 board): fetch-window realign: a stream with a global kill (id-less domain); the carry bank is per-hart state.
  // svt-pipe: require-contract
  // svt-pipe: protocol rl valid=valid_i kill=kill_i flush=flush_i
  // svt-pipe: no-cut on=carry_addr_bank_q
  // svt-pipe: cycle rl q=carry_addr_bank_q d=carry_next_bank_q hold=valid_i steps=1

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(G6LCCfg);
  // halfwords per fetch block, bits needed to index one, and the cursor width
  // (the cursor also has to represent "one past the last halfword")
  localparam int unsigned NrHalfWords = Geo.hw_per_w;
  localparam int unsigned HwIdxW = Geo.align_bits - 1;
  localparam int unsigned CurW = Geo.align_bits;
  localparam bit FastContinuation = G6LCCfg.RVC && NrHalfWords > 1 &&
      (NrHalfWords == (1 << HwIdxW)) && G6LCCfg.VLEN > CurW && G6LCCfg.VLEN <= 64;
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;

  // ------------------------------------------------------------------
  // hyp8 stage A — boundary / carry-half: register the accepted response
  // ------------------------------------------------------------------
  // The halfword slice classification also lands here: it is pure function of
  // data_i, so registering the classified form keeps the B cone to prefix +
  // gather (svt-plan boundary "halfword classification/visits/ranks -> gather").
  logic                     a_valid_q;
  logic [G6LCCfg.VLEN-1:0]  a_addr_q;
  logic [NrHalfWords-1:0][15:0] a_hw_q;
  logic [NrHalfWords-1:0]   a_hw_compressed_q;
  logic                     a_kill_q;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] a_hart_q;
  logic [EW-1:0]            a_epoch_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_valid_q         <= 1'b0;
      a_addr_q          <= '0;
      a_hw_q            <= '0;
      a_hw_compressed_q <= '0;
      a_kill_q          <= 1'b0;
      a_hart_q          <= '0;
      a_epoch_q         <= '0;
    end else begin
      a_valid_q <= valid_i & ~flush_i;
      a_addr_q  <= address_i;
      for (int unsigned j = 0; j < NrHalfWords; j++) begin
        a_hw_q[j]            <= data_i[16*j+:16];
        // without RVC no halfword can terminate an instruction
        a_hw_compressed_q[j] <= (g6lc_fetch_pkg::ilen_of(G6LCCfg, data_i[16*j+:16]) == 2);
      end
      a_kill_q  <= kill_i;
      a_hart_q  <= hart_i;
      a_epoch_q <= rsp_epoch_i;
    end
  end

  // hyp8: the stage-A window is dead when its epoch predates the current one;
  // a dead window acts exactly like a killed one (not presented, carry inert).
  logic a_stale;
  assign a_stale = a_valid_q && (a_epoch_q != epoch_i);

  // ------------------------------------------------------------------
  // Stage B — lane alignment (combinational on the stage-A registers)
  // ------------------------------------------------------------------
  localparam int unsigned NH = (Geo.harts < 1) ? 1 : Geo.harts;
  logic [NH-1:0] carry_valid_bank_q;
  logic [NH-1:0][15:0] carry_instr_bank_q;
  logic [NH-1:0][G6LCCfg.VLEN-1:0] carry_addr_bank_q;
  logic [15:0] carry_instr_d, carry_instr_q;
  logic [G6LCCfg.VLEN-1:0] carry_addr_d, carry_addr_q;
  logic carry_valid_d, carry_valid_q;
  // A split instruction can only be completed by the block that immediately
  // follows the one that produced it. Its lower half is by construction the last
  // halfword of its block, so that block starts at carry_addr_q + 2. Any other
  // address (a redirect, a replay, or the same block presented twice) leaves the
  // carry stale and it must be dropped instead of consuming a halfword.
  logic carry_ok;
  logic carry_next_match;
  logic [G6LCCfg.VLEN-1:0] window_last_pc;

  assign carry_valid_q = carry_valid_bank_q[a_hart_q];
  assign carry_instr_q = carry_instr_bank_q[a_hart_q];
  assign carry_addr_q  = carry_addr_bank_q[a_hart_q];

  // leftover_complete(start_hw0=1) && rvi_prefix. Inlined so the 2-bit
  // prefix test is not a function-call node on the select cone.
  assign carry_ok = carry_valid_q && carry_next_match && (carry_instr_q[1:0] == 2'b11);

  // Stage-B presented window: only a dead epoch suppresses the slots. A kill
  // (leftover_kill) does NOT invalidate the window — kill is inert on the
  // carry bank, and the leftover_branch_bp_fire case still pushes slot0 while
  // protecting the carry (SPEC L1); slot suppression lives downstream.
  logic b_valid;
  assign b_valid = a_valid_q & ~a_stale;

  // hyp8: deferred carry consumption. The reference dropped the carry the
  // cycle the completing window was realigned, because cf_select (and hence
  // "this is a predicted-taken split branch whose replay needs the carry")
  // was computed in the same cycle. Here the verdict is two stages later, so
  // a completion leaves the carry bank in place and arms pend_q instead; the
  // frontend retires it (pend_resolve_i/!pend_keep_i) or keeps it
  // (pend_keep_i: predicted-taken split branch, or the window was refused and
  // will be re-presented). A fresh split overwrites the bank and voids the
  // pending completion; a dead-epoch completer resolves with keep=0.
  logic                    pend_q;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] pend_hart_q;
  logic                    b_complete;
  logic                    b_carry_ok, b_valid_b;
  assign b_complete = b_carry_ok & b_valid & ~a_kill_q;
  // accept-time bank peek for leftover_retake
  assign bank_valid_o  = carry_valid_bank_q[hart_i] | pend_q;
  assign bank_pc_o     = carry_addr_bank_q[hart_i];
  assign pend_valid_o  = pend_q;

  logic [NrHalfWords-1:0][15:0] hw;
  logic [NrHalfWords-1:0] hw_compressed;
  logic [CurW-1:0] hw_first;  // halfwords skipped by the fetch alignment
  logic [CurW-1:0] hw_avail;  // halfwords carried by this block

  assign b_carry_ok = carry_ok & a_valid_q;
  assign hw = a_hw_q;
  assign hw_compressed = a_hw_compressed_q;

  // hw_first is how many halfwords the fetch alignment skipped; hw_avail is what
  // is left in this block. The cursor runs 0..hw_avail because the host already
  // right-shifted the line, so slot 0 is always the addressed halfword.
  // hw_off(pc) = (pc >> 1) & ((1 << (align-1)) - 1), and align is CurW.
  // The part-select is that mask. The function form was a shift on this cone.
  assign hw_first = G6LCCfg.RVC ? CurW'(a_addr_q[CurW-1:1]) : '0;
  assign hw_avail = CurW'(NrHalfWords) - hw_first;

  // hyp8 geometry (RVC, power-of-two window, VLEN in (align, 64]) makes
  // FastContinuation constant 1. The add fallback was a second driver on
  // carry_next_match and was the front of the carry cone. Silicon keeps the
  // registered successor only.
  // svt-pipe: no-cut on=carry_next_bank_q
  if (1'b1) begin : gen_continuation
    // A134: a split can only start at the last available halfword. Its PC
    // is the window base plus the constant last-halfword offset.
    // Precompute and register the successor with the same hart's carry
    // state, removing carry_addr_q + 2 from the next window's feedback cone.
    // Keep 64 bits: at VLEN<64, overflow is NOT a match for a wrapped address.
    // hyp8: the continuation check moved into stage B — carry_next_bank_q is
    // written when a stage-B window leaves a carry, keyed by its stage-A hart.
    logic [NH-1:0][63:0] carry_next_bank_q;
    logic [63:0] window_next_pc;
    assign window_last_pc =
        {a_addr_q[G6LCCfg.VLEN-1:CurW], {(CurW-1){1'b1}}, a_addr_q[0]};
    assign window_next_pc = 64'(window_last_pc) + 64'd2;
    assign carry_next_match = 64'(a_addr_q) == carry_next_bank_q[a_hart_q];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) carry_next_bank_q <= '0;
      else if (g6lc_fetch_pkg::leftover_update(flush_i, b_valid, a_kill_q) && carry_valid_d)
        carry_next_bank_q[a_hart_q] <= window_next_pc;
    end
    // pragma translate_off
    initial assert (FastContinuation)
      else $error("instr_realign continuation requires hyp8 fetch geometry");
    always_ff @(posedge clk_i) if (rst_ni) begin
      for (int unsigned h = 0; h < NH; h++)
        if (carry_valid_bank_q[h])
          assert (carry_next_bank_q[h] == 64'(carry_addr_bank_q[h]) + 64'd2)
            else $error("realign continuation lost carry PC/hart alignment");
    end
    // pragma translate_on
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
  //
  // Only cprime[0] and vis0 depend on b_carry_ok. Both visit prefixes are
  // computed from the registered halfwords (side 1: carry completes at
  // position 0; side 0: it does not). b_carry_ok selects the finished
  // slot and carry vectors in one mux, so the 64-bit continuation compare
  // is not in series with the prefix. The carry bank still updates in this
  // cycle: the next back-to-back window sees the new carry.
  localparam int unsigned IdxW = $clog2(NrHalfWords + 1);
  localparam int unsigned Lvl = (NrHalfWords > 1) ? $clog2(NrHalfWords) : 1;

  // Stage-B combinational outputs (registered below)
  logic [G6LCCfg.INSTR_PER_FETCH-1:0]                      b_slot_valid;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][31:0]                b_slot_instr;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0]    b_slot_addr;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0]    b_slot_base;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0]    b_slot_off;

  logic [NrHalfWords-1:0][15:0]             rl_hi;
  logic [NrHalfWords-1:0][G6LCCfg.VLEN-1:0] rl_saddr, rl_soff;

  logic [1:0] vis0_s;
  logic [1:0][G6LCCfg.INSTR_PER_FETCH-1:0] sv_s;
  logic [1:0][G6LCCfg.INSTR_PER_FETCH-1:0][31:0] si_s;
  logic [1:0][G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] sa_s, sb_s, so_s;
  logic [1:0] cv_s;
  logic [1:0][15:0] ci_fin;
  logic [1:0][G6LCCfg.VLEN-1:0] ca_fin;

  // side 0: no completing carry. side 1: position 0 consumes the carried half.
  assign vis0_s[0] = (hw_avail != '0);
  assign vis0_s[1] = 1'b1;

  for (genvar h = 0; h < NrHalfWords; h++) begin : gen_rl_pre
    // on the last halfword there is no successor to read; the zero is
    // never emitted as instruction bytes (a split RVI carries instead)
    assign rl_hi[h]    = (CurW'(h) + CurW'(1) < hw_avail)
                           ? hw[(h + 1) % NrHalfWords] : 16'b0;
    assign rl_saddr[h] = a_addr_q +
        {{(G6LCCfg.VLEN - CurW - 1) {1'b0}}, CurW'(h), 1'b0};
    assign rl_soff[h]  = {{(G6LCCfg.VLEN - CurW - 1) {1'b0}}, CurW'(h), 1'b0};
  end

  // Module-scope nets. Generate-local prefix arrays did not connect
  // pfx into vis, so the walk disappeared from reg-to-reg paths.
  logic [NrHalfWords-1:0] vis0v, vis1v;
  logic [1:0][NrHalfWords-1:0] vis, split, cprime;
  logic [1:0][NrHalfWords-1:0][IdxW-1:0] idx;
  logic [1:0][G6LCCfg.INSTR_PER_FETCH-1:0][NrHalfWords-1:0] rl_sel, rl_carryf, rl_normf;
  logic [1:0][NrHalfWords-1:0] rl_csel, rl_coh;
  logic [1:0][NrHalfWords-1:0][15:0] carry_i_acc;
  // Same index shape as the single prefix the timing walk already followed.
  // A side dimension on pfx dropped the matrix off the reg-to-reg path.
  logic [NrHalfWords-1:0] cprime0, cprime1;
  logic [Lvl:0][NrHalfWords-1:0][1:0][1:0] pfx0, pfx1;

  for (genvar h = 0; h < NrHalfWords; h++) begin : gen_cp0
    assign cprime0[h] = hw_compressed[h];
    assign cprime1[h] = (h == 0) ? 1'b1 : hw_compressed[h];
    assign cprime[0][h] = cprime0[h];
    assign cprime[1][h] = cprime1[h];
  end

  // Each prefix cell is its own assign. A procedural for that both
  // reads and writes pfx is billed as one chain per halfword.
  for (genvar h = 1; h < NrHalfWords; h++) begin : gen_pfx0_b
    assign pfx0[0][h][0][0] = cprime0[h-1];
    assign pfx0[0][h][0][1] = (h >= 2) ? ~cprime0[h-2] : 1'b0;
    assign pfx0[0][h][1][0] = 1'b1;
    assign pfx0[0][h][1][1] = 1'b0;
    assign pfx1[0][h][0][0] = cprime1[h-1];
    assign pfx1[0][h][0][1] = (h >= 2) ? ~cprime1[h-2] : 1'b0;
    assign pfx1[0][h][1][0] = 1'b1;
    assign pfx1[0][h][1][1] = 1'b0;
  end
  assign pfx0[0][0][0][0] = 1'b1;
  assign pfx0[0][0][0][1] = 1'b0;
  assign pfx0[0][0][1][0] = 1'b0;
  assign pfx0[0][0][1][1] = 1'b1;
  assign pfx1[0][0][0][0] = 1'b1;
  assign pfx1[0][0][0][1] = 1'b0;
  assign pfx1[0][0][1][0] = 1'b0;
  assign pfx1[0][0][1][1] = 1'b1;
  for (genvar l = 1; l <= Lvl; l++) begin : gen_pfxl
    for (genvar h = 0; h < NrHalfWords; h++) begin : gen_pfxh
      if (h >= (1 << (l - 1))) begin : gen_mul
        for (genvar i = 0; i < 2; i++) begin : gen_i
          for (genvar j = 0; j < 2; j++) begin : gen_j
            assign pfx0[l][h][i][j] =
                (pfx0[l-1][h][i][0] & pfx0[l-1][h-(1<<(l-1))][0][j]) |
                (pfx0[l-1][h][i][1] & pfx0[l-1][h-(1<<(l-1))][1][j]);
            assign pfx1[l][h][i][j] =
                (pfx1[l-1][h][i][0] & pfx1[l-1][h-(1<<(l-1))][0][j]) |
                (pfx1[l-1][h][i][1] & pfx1[l-1][h-(1<<(l-1))][1][j]);
          end
        end
      end else begin : gen_copy
        assign pfx0[l][h] = pfx0[l-1][h];
        assign pfx1[l][h] = pfx1[l-1][h];
      end
    end
  end

  for (genvar h = 0; h < NrHalfWords; h++) begin : gen_vis0
    assign vis0v[h] = (h == 0) ? vis0_s[0]
                   : (pfx0[Lvl][h][0][0] & vis0_s[0] & (CurW'(h) < hw_avail));
    assign vis[0][h] = vis0v[h];
  end
  for (genvar h = 0; h < NrHalfWords; h++) begin : gen_vis1
    assign vis1v[h] = (h == 0) ? vis0_s[1]
                   : (pfx1[Lvl][h][0][0] & vis0_s[1] & (CurW'(h) < hw_avail));
    assign vis[1][h] = vis1v[h];
  end

  for (genvar side = 0; side < 2; side++) begin : gen_side
    for (genvar h = 0; h < NrHalfWords; h++) begin : gen_vis
      assign idx[side][h] = IdxW'($countones(vis[side] & NrHalfWords'((NrHalfWords'(1) << h) - 1'b1)));
      assign split[side][h] = vis[side][h] && !cprime[side][h] && (CurW'(h) + CurW'(1) >= hw_avail);
      assign rl_csel[side][h] = vis[side][h] && (int'(idx[side][h]) < int'(G6LCCfg.INSTR_PER_FETCH)) &&
                          split[side][h];
      if (h == NrHalfWords - 1) begin : gen_col
        assign rl_coh[side][h] = rl_csel[side][h];
      end else begin : gen_con
        assign rl_coh[side][h] = rl_csel[side][h] && !(|rl_csel[side][NrHalfWords-1:h+1]);
      end
    end
    for (genvar k = 0; k < G6LCCfg.INSTR_PER_FETCH; k++) begin : gen_rl_x
      for (genvar h = 0; h < NrHalfWords; h++) begin : gen_rl_xh
        assign rl_sel[side][k][h]    = vis[side][h] && (idx[side][h] == IdxW'(k));
        // carried position 0 on side 1 emits {hw[0], carry_instr}
        assign rl_carryf[side][k][h] = rl_sel[side][k][h] && (h == 0) && (side == 1);
        assign rl_normf[side][k][h]  = rl_sel[side][k][h] && !((h == 0) && (side == 1)) &&
                                 !split[side][h];
      end
    end
    // Slot gather is an OR of one-hot matches. rl_coh is the last set
    // carry, so the masked OR matches the old ascending last-writer.
    for (genvar k = 0; k < G6LCCfg.INSTR_PER_FETCH; k++) begin : gen_slot
      logic [NrHalfWords-1:0]                   vacc;
      logic [NrHalfWords-1:0][31:0]             iacc;
      logic [NrHalfWords-1:0][G6LCCfg.VLEN-1:0] aacc, bacc, oacc;
      for (genvar h = 0; h < NrHalfWords; h++) begin : gen_acc
        logic                    vterm;
        logic [31:0]             iterm;
        logic [G6LCCfg.VLEN-1:0] aterm, bterm, oterm;
        assign vterm = rl_carryf[side][k][h] | rl_normf[side][k][h];
        assign iterm = ({32{rl_carryf[side][k][h]}} & {hw[0], carry_instr_q}) |
                       ({32{rl_normf[side][k][h]}}  & {rl_hi[h], hw[h]});
        assign aterm = ({G6LCCfg.VLEN{rl_carryf[side][k][h]}} & carry_addr_q) |
                       ({G6LCCfg.VLEN{rl_normf[side][k][h]}}  & rl_saddr[h]);
        assign bterm = ({G6LCCfg.VLEN{rl_carryf[side][k][h]}} & carry_addr_q) |
                       ({G6LCCfg.VLEN{rl_normf[side][k][h]}}  & a_addr_q);
        assign oterm = {G6LCCfg.VLEN{rl_normf[side][k][h]}} & rl_soff[h];
        if (h == 0) begin : gen_z
          assign vacc[h] = vterm;
          assign iacc[h] = iterm;
          assign aacc[h] = aterm;
          assign bacc[h] = bterm;
          assign oacc[h] = oterm;
        end else begin : gen_n
          assign vacc[h] = vacc[h-1] | vterm;
          assign iacc[h] = iacc[h-1] | iterm;
          assign aacc[h] = aacc[h-1] | aterm;
          assign bacc[h] = bacc[h-1] | bterm;
          assign oacc[h] = oacc[h-1] | oterm;
        end
      end
      assign sv_s[side][k] = vacc[NrHalfWords-1];
      assign si_s[side][k] = iacc[NrHalfWords-1];
      assign sa_s[side][k] = aacc[NrHalfWords-1];
      assign sb_s[side][k] = bacc[NrHalfWords-1];
      assign so_s[side][k] = oacc[NrHalfWords-1];
    end
    for (genvar h = 0; h < NrHalfWords; h++) begin : gen_carry_mux
      logic [15:0] i_term;
      assign i_term = {16{rl_coh[side][h]}} & hw[h];
      if (h == 0) begin : gen_z
        assign carry_i_acc[side][h] = i_term;
      end else begin : gen_n
        assign carry_i_acc[side][h] = carry_i_acc[side][h-1] | i_term;
      end
    end
    assign cv_s[side]   = |rl_coh[side];
    assign ci_fin[side] = cv_s[side] ? carry_i_acc[side][NrHalfWords-1] : carry_instr_q;
    // FastContinuation: the split PC is window_last_pc for every side.
    assign ca_fin[side] = cv_s[side] ? window_last_pc : carry_addr_q;
  end

  // Separate assigns: a concatenation LHS is not a driver the timing
  // walk can follow back into the prefix. b_carry_ok is only the select.
  // Result and the carry bank still land in this cycle.
  for (genvar k = 0; k < G6LCCfg.INSTR_PER_FETCH; k++) begin : gen_slot_mux
    assign b_slot_valid[k] = b_carry_ok ? (b_valid & sv_s[1][k]) : (b_valid & sv_s[0][k]);
    assign b_slot_instr[k] = b_carry_ok ? si_s[1][k] : si_s[0][k];
    assign b_slot_addr[k]  = b_carry_ok ? sa_s[1][k] : sa_s[0][k];
    assign b_slot_base[k]  = b_carry_ok ? sb_s[1][k] : sb_s[0][k];
    assign b_slot_off[k]   = b_carry_ok ? so_s[1][k] : so_s[0][k];
  end
  assign carry_valid_d = b_carry_ok ? cv_s[1] : cv_s[0];
  assign carry_instr_d = b_carry_ok ? ci_fin[1] : ci_fin[0];
  assign carry_addr_d  = b_carry_ok ? ca_fin[1] : ca_fin[0];

  // ------------------------------------------------------------------
  // Stage-B registers — all module outputs are registered
  // ------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o              <= '0;
      instr_o              <= '0;
      addr_o               <= '0;
      base_o               <= '0;
      off_o                <= '0;
      serving_unaligned_o  <= 1'b0;
      leftover_pending_o   <= 1'b0;
      leftover_valid_o     <= 1'b0;
      leftover_pc_o        <= '0;
      b_valid_b            <= 1'b0;
    end else begin
      if (flush_i) begin
        valid_o <= '0;
      end else begin
        valid_o <= b_slot_valid;
      end
      instr_o  <= b_slot_instr;
      addr_o   <= b_slot_addr;
      base_o   <= b_slot_base;
      off_o    <= b_slot_off;
      serving_unaligned_o <= b_carry_ok;
      leftover_pending_o  <= g6lc_fetch_pkg::leftover_pending(carry_valid_q, b_carry_ok);
      leftover_valid_o    <= carry_valid_q;
      leftover_pc_o       <= carry_addr_q;
      carry_done_o        <= b_complete;
      b_valid_b           <= b_valid;
    end
  end

  // Carry bank + pending completion: written by the stage-B window (valid and
  // not killed, not stale). Kill, flush and epoch kill are INERT on carry
  // state (SPEC L1): only a valid live window may produce a new carry or
  // complete one. A completion retains the bank entry and arms pend_q; the
  // frontend's verdict resolves the pend (keep = protected split branch /
  // refused window). A foreign window while pend_q is armed leaves the bank
  // untouched; a fresh split overwrites it and voids the pend (I4az).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      carry_valid_bank_q <= '0;
      carry_instr_bank_q <= '0;
      carry_addr_bank_q  <= '0;
      pend_q             <= 1'b0;
      pend_hart_q        <= '0;
    end else begin
      if (pend_resolve_i) begin
        if (!pend_keep_i) carry_valid_bank_q[pend_hart_q] <= 1'b0;
        pend_q <= 1'b0;
      end
      if (flush_i) pend_q <= 1'b0;
      if (g6lc_fetch_pkg::leftover_update(flush_i, b_valid, a_kill_q)) begin
        if (b_complete) begin
          // retain the carry for the verdict; record who completed it
          pend_q      <= 1'b1;
          pend_hart_q <= a_hart_q;
        end else if (carry_valid_d) begin
          // a new split carry replaces the bank and voids an older pend
          carry_instr_bank_q[a_hart_q] <= carry_instr_d;
          carry_addr_bank_q[a_hart_q]  <= carry_addr_d;
          carry_valid_bank_q[a_hart_q] <= carry_valid_d;
          pend_q <= 1'b0;
        end else if (!pend_q) begin
          // foreign window, no pend: normal drop (carry_valid_d = 0)
          carry_instr_bank_q[a_hart_q] <= carry_instr_d;
          carry_addr_bank_q[a_hart_q]  <= carry_addr_d;
          carry_valid_bank_q[a_hart_q] <= carry_valid_d;
        end
        // foreign window while pend_q: bank untouched
      end
    end
  end
endmodule
