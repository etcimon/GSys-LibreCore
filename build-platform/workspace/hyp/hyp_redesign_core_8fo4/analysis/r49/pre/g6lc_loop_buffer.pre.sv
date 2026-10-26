// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U2 loop buffer — aggressively optimised for the fetch datapath.
//
// Data-path analysis (vs N-way CAM):
//   * Old: full-VLEN tag compare × N every cycle (long cone, high toggle).
//   * New: sequential capture + sequential replay. Lookup is a *single*
//     equality (expect_pc == lookup) and a bounds check — one comparator,
//     flop array read by binary index, no CAM.
//   * Capture is also sequential: only the next expected fill address is
//     accepted (eliminates the [base,end] range compare on the fill path).
//   * Storage is data-only; address = base + i<<ALIGN (reconstructed).
//   * Hit injects data and advances the cursor; wrap to 0 on back-edge.
//   * Flush / fence.i / leave-loop disarms in one cycle.
//
// Critical path: expect_pc add → EQ → hit → inject mux (frontend).
// Keep the EQ cone short: base is fetch-aligned; cursor is IDX_W bits.

module g6lc_loop_buffer
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter int unsigned NR_ENTRIES = 8,
    parameter int unsigned DATA_W = 32
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    enable_i,
    // hyp8: current fetch epoch; the armed capture is tagged and a lookup hit
    // only stands while that epoch is still live
    input  logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_i,
    // Control-flow observation (arm / disarm)
    input  logic                    cf_valid_i,
    input  logic                    cf_taken_i,
    input  logic [G6LCCfg.VLEN-1:0] cf_pc_i,
    input  logic [G6LCCfg.VLEN-1:0] cf_target_i,
    // Fill from demand I$ return (only while capturing; sequential)
    input  logic                    fill_valid_i,
    input  logic [G6LCCfg.VLEN-1:0] fill_vaddr_i,
    input  logic [DATA_W-1:0]       fill_data_i,
    // Sequential lookup (FTQ head)
    input  logic [G6LCCfg.VLEN-1:0] lookup_vaddr_i,
    input  logic                    lookup_valid_i,  // FTQ head is valid
    input  logic                    lookup_ready_i,  // consumer accepts inject
    output logic                    hit_o,
    output logic [DATA_W-1:0]       data_o,
    // When high, suppress I$ demand; frontend injects data_o instead
    output logic                    active_o,
    // Pop FTQ on successful inject
    output logic                    consume_o,
    // hyp8: hit candidate detected this cycle, result registered for the next:
    // suppress the demand request while it lands (keeps the FTQ head parked)
    output logic                    hold_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_loop_buffer status=proposal target=10-adjusted-FO4
  // svt-plan: cone expect_pc/expect_fill reconstruct base+cursor before
  // address equality; the cursor is bounded although base has full VLEN width.
  // svt-plan: reshape choose a low slice covering the configured maximum
  // cursor offset; precompute base upper and upper+1 at arm, then select by
  // the low addition's carry. Preserve full-width wrap and crossing behavior.
  // svt-plan: boundary optional prepare arm bounds/base alternatives ->
  // capture/replay; make capturing/armed visible only with prepared metadata.
  // svt-plan: carry base/end, body length, fill/replay cursor and flush state;
  // simultaneous arm/fill/consume must retain the current priority semantics.
  // svt-plan: effect replaces a full-VLEN recurring add with bounded low
  // arithmetic plus upper compare/select; precompute both cursor cases.
  // svt-plan: cost upper alternatives and potentially an arm cycle; replay
  // remains one block/cycle only when hit/data/consume remain aligned.
  // svt-plan: limit the high select/equality can still dominate; restricting
  // loops to one page is an optional policy loss, not an equivalent rewrite.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 71.6 adjusted FO4 on the
  // Nangate45 board): loop buffer: fill / replay state machine on the fetch stream (id-less domain); expect_fill is its control.
  // svt-pipe: require-contract
  // svt-pipe: protocol lb valid=cf_valid_i flush=flush_i
  // svt-pipe: no-cut on=fill_low_sum
  // svt-pipe: cycle lb q=fill_low_sum d=data_o hold=cf_valid_i steps=1

  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);
  // hyp8 dual-issue + RVC fetch is 64 bits, so the block shift is 3.
  // FETCH_ALIGN_BITS is a struct field and does not fold: `<< ALIGN` was a
  // variable shift and the seq_hit cone.
  localparam int unsigned ALIGN = 3;
  localparam logic [IDX_W:0] NR_EXT = NR_ENTRIES[IDX_W:0];

  // Body storage: data only (address = base + i<<ALIGN)
  logic [NR_ENTRIES-1:0][DATA_W-1:0] data_q, data_d;
  logic [IDX_W:0] body_len_q, body_len_d;  // valid fill slots
  logic [IDX_W-1:0] fill_ptr_q, fill_ptr_d;
  logic [IDX_W-1:0] replay_q, replay_d;    // sequential read cursor
  logic             capturing_q, capturing_d;
  logic             armed_q, armed_d;
  logic [G6LCCfg.VLEN-1:0] base_q, base_d;  // loop start (back-edge target)
  logic [G6LCCfg.VLEN-1:0] end_q, end_d;    // PC of back-edge branch
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;
  // hyp8: epoch the body was captured under; a hit is only offered while that
  // epoch is still the live fetch epoch
  logic [EW-1:0] arm_epoch_q, arm_epoch_d;
  // hyp8: registered hit (rank 2/4): detect at the head this cycle, inject the
  // block the next. hit_q holds until the consumer accepts (lookup_ready_i).
  // hit_vaddr_q/hit_epoch_q pin the registration to the head it was detected
  // for: a reseed/epoch change under a held hit retires it instead of
  // injecting the old block under the new head.
  logic                hit_q;
  logic [G6LCCfg.VLEN-1:0] hit_vaddr_q;
  logic [EW-1:0]       hit_epoch_q;
  logic [DATA_W-1:0]   hit_data_q;

  // Short backward edge: target < pc and body fits in NR_ENTRIES fetch blocks
  logic short_back;
  logic [G6LCCfg.VLEN-1:0] span_bytes;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_loop_buffer  region=3715  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: armed_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to armed_q
// order expect: base_hi_p1_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to base_hi_p1_q
// order expect: base_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to base_q
// order expect: body_len_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to body_len_q
// order expect: capturing_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to capturing_q
// order expect: data_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to data_q
// order expect: end_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to end_q
// order expect: fill_ptr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fill_ptr_q
// order expect: replay_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to replay_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     armed_q <= …; // sv-timing: cycle 1/1 on clk_i
//     base_hi_p1_q <= …; // sv-timing: cycle 1/1 on clk_i
//     base_q <= …; // sv-timing: cycle 1/1 on clk_i
//     body_len_q <= …; // sv-timing: cycle 1/1 on clk_i
//     capturing_q <= …; // sv-timing: cycle 1/1 on clk_i
//     data_q <= …; // sv-timing: cycle 1/1 on clk_i
//     end_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fill_ptr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     replay_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node13426 c=3.50 slack=0.00 */
//     /* node13427 c=3.50 slack=0.00 */
//     /* node13428 c=3.50 slack=0.00 */
//     /* node13429 c=3.50 slack=0.00 */
//     /* node13430 c=3.50 slack=0.00 */
//     /* node13431 c=3.50 slack=0.00 */
//     /* node13432 c=3.50 slack=0.00 */
//     /* node13433 c=3.50 slack=0.00 */
//     /* node13434 c=3.50 slack=0.00 */
//     /* node13435 c=3.50 slack=0.00 */
//     /* node13436 c=3.50 slack=0.00 */
//     /* node13437 c=3.50 slack=0.00 */
//     /* node13438 c=3.50 slack=0.00 */
//     /* node13439 c=3.50 slack=0.00 */
//     /* node13440 c=3.50 slack=0.00 */
//     /* node13441 c=3.50 slack=0.00 */
//     /* node13442 c=3.50 slack=0.00 */
//     /* node13443 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign span_bytes = cf_pc_i - cf_target_i;
  assign short_back = cf_valid_i && cf_taken_i && (cf_target_i < cf_pc_i) &&
                      (span_bytes <= (64'(NR_ENTRIES) << ALIGN));

  // ---- Sequential address reconstruction (shared shift) ----
  // expect_pc  = base + replay<<ALIGN   (lookup hit)
  // expect_fill = base + fill_ptr<<ALIGN (capture accept)
  // A140: the cursor offset is below 2**LOW_W bytes, so base + offset only
  // carries into base[VLEN-1:LOW_W] as +0 or +1. The +1 alternative is
  // registered at arm (base_hi_p1_q); both high compares run in parallel with
  // the LOW_W-bit add and the add's carry picks one. Exactly
  // base + (cursor << ALIGN) modulo 2**VLEN, including the wrap, with no
  // VLEN-wide add or incrementer in front of the equality.
  localparam int unsigned LOW_W = (IDX_W + ALIGN >= 64) ? 63 : IDX_W + ALIGN;
  localparam int unsigned HI_W  = 64 - LOW_W;
  logic [HI_W-1:0] base_hi_p1_q, base_hi_p1_d;
  logic [LOW_W:0]  pc_low_sum, fill_low_sum;
  // hyp8: NR_ENTRIES=8 and ALIGN=3, so LOW_W is 6 and HI_W is 58.
  // A part-select whose bound is $clog2(...) is billed as a variable
  // shift. The hit uses the literal ranges. The localparam stays for
  // the rest of the module.
  // pragma translate_off
  initial begin
    assert (LOW_W == 6 && HI_W == 58)
      else $error("g6lc_loop_buffer: literal hit slices assume LOW_W=6");
  end
  // pragma translate_on
  logic [6:0] pc_low_lit, fill_low_lit;
  assign pc_low_lit   = {1'b0, base_q[5:0]} + {1'b0, replay_q[2:0], 3'b0};
  assign fill_low_lit = {1'b0, base_q[5:0]} + {1'b0, fill_ptr_q[2:0], 3'b0};
  assign pc_low_sum   = pc_low_lit;
  assign fill_low_sum = fill_low_lit;
  function automatic logic addr_eq(input logic [G6LCCfg.VLEN-1:0] a, input logic [LOW_W:0] low_sum);
    logic hi_eq;
    // Carry picks a registered high alternative. A unique case is one mux;
    // the old ternary was a priority mux on a VLEN part-select.
    unique case (low_sum[LOW_W])
      1'b1:    hi_eq = (a[63:LOW_W] == base_hi_p1_q);
      default: hi_eq = (a[63:LOW_W] == base_q[63:LOW_W]);
    endcase
    return (a[LOW_W-1:0] == low_sum[LOW_W-1:0]) && hi_eq;
  endfunction

  // Lookup hit compares, outside addr_eq so the high PC is not one
  // function node. [63:32] and [31:LOW_W] are the high field.
  logic seq_lo, seq_hi_hi, seq_hi_lo, seq_in_body, seq_epoch;
  assign seq_lo = lookup_vaddr_i[5:0] == pc_low_lit[5:0];
  always_comb begin
    unique case (pc_low_lit[6])
      1'b1:    seq_hi_hi = lookup_vaddr_i[63:32] == base_hi_p1_q[57:26];
      default: seq_hi_hi = lookup_vaddr_i[63:32] == base_q[63:32];
    endcase
  end
  always_comb begin
    unique case (pc_low_lit[6])
      1'b1:    seq_hi_lo = lookup_vaddr_i[31:6] == base_hi_p1_q[25:0];
      default: seq_hi_lo = lookup_vaddr_i[31:6] == base_q[31:6];
    endcase
  end
  assign seq_epoch   = arm_epoch_q == epoch_i;
  assign seq_in_body = {1'b0, replay_q} < body_len_q;
  logic seq_hit;
  assign seq_hit = enable_i && armed_q && lookup_valid_i && seq_epoch &&
                   seq_lo && seq_hi_lo && seq_hi_hi && seq_in_body;

  // hyp8: the hit and its payload are registered; the frontend suppresses the
  // demand request on hold_o while the hit lands, then lbuf_inject takes the
  // response port the next cycle. The registered hit survives a not-ready
  // lookup cycle until consume — but only while the head it was detected for
  // is still presented under the same epoch (hit_live). A reseed/redirect that
  // re-pushes the FTQ under a held hit would otherwise inject the OLD block's
  // bytes under the NEW head address (the inject uses ftq_head_vaddr).
  logic hit_live;
  assign hit_live  = hit_q && lookup_valid_i && (lookup_vaddr_i == hit_vaddr_q) &&
                     (hit_epoch_q == epoch_i);
  assign hold_o    = seq_hit;
  assign data_o    = hit_data_q;
`ifdef G6LC_MUT_LBUF_STALE_HIT
  // Review-only mutation: the held hit is consumed without re-checking head
  // identity — a reseed under a pending hit injects the old block under the
  // new head.
  assign hit_o     = hit_q;
  assign active_o  = hit_q | seq_hit;
  assign consume_o = hit_q && lookup_ready_i;
`else
  assign hit_o     = hit_live;
  assign active_o  = hit_live | seq_hit;  // demand suppressed while hit pending/held
  assign consume_o = hit_live && lookup_ready_i;
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hit_q       <= 1'b0;
      hit_vaddr_q <= '0;
      hit_epoch_q <= '0;
      hit_data_q  <= '0;
    end else if (flush_i) begin
      // flush dominates: a coincident detection does not re-arm the hit
      hit_q <= 1'b0;
    end else if (consume_o || (hit_q && !hit_live)) begin
      hit_q       <= seq_hit && !consume_o;
      hit_vaddr_q <= lookup_vaddr_i;
      hit_epoch_q <= epoch_i;
      hit_data_q  <= data_q[replay_q];
    end else if (seq_hit) begin
      hit_q       <= 1'b1;
      hit_vaddr_q <= lookup_vaddr_i;
      hit_epoch_q <= epoch_i;
      hit_data_q  <= data_q[replay_q];
    end
  end

  // Sequential fill accept (one EQ, no range cone)
  logic fill_accept;
  assign fill_accept = capturing_q && fill_valid_i && addr_eq(fill_vaddr_i, fill_low_sum) &&
                       (body_len_q < NR_EXT);

  always_comb begin
    data_d       = data_q;
    body_len_d   = body_len_q;
    fill_ptr_d   = fill_ptr_q;
    replay_d     = replay_q;
    capturing_d  = capturing_q;
    armed_d      = armed_q;
    base_d       = base_q;
    base_hi_p1_d = base_hi_p1_q;
    end_d        = end_q;
    arm_epoch_d  = arm_epoch_q;

    if (flush_i) begin
      capturing_d = 1'b0;
      armed_d     = 1'b0;
      fill_ptr_d  = '0;
      body_len_d  = '0;
      replay_d    = '0;
      arm_epoch_d = '0;
    end else if (enable_i) begin
      // ---- Arm: start capture on short back-edge ----
      if (short_back && !capturing_q) begin
        capturing_d = 1'b1;
        armed_d     = 1'b0;
        fill_ptr_d  = '0;
        body_len_d  = '0;
        replay_d    = '0;
        arm_epoch_d = epoch_i;
        base_d      = cf_target_i;
        base_hi_p1_d = cf_target_i[63:LOW_W] + HI_W'(1);
        end_d       = cf_pc_i;
      end

      // ---- Capture sequential fill (indexed write, single EQ) ----
      if (fill_accept) begin
        data_d[fill_ptr_q] = fill_data_i;
        fill_ptr_d = fill_ptr_q + IDX_W'(1);
        body_len_d = body_len_q + (IDX_W+1)'(1);
        // Close when we filled the back-edge line or the buffer is full
        if (fill_vaddr_i == end_q || body_len_q == NR_EXT - (IDX_W+1)'(1)) begin
          capturing_d = 1'b0;
          armed_d     = 1'b1;
          replay_d    = '0;
        end
      end

      // ---- Sequential replay advance (wrap for next iteration) ----
      if (consume_o) begin
        if ({1'b0, replay_q} + (IDX_W+1)'(1) >= body_len_q)
          replay_d = '0;
        else
          replay_d = replay_q + IDX_W'(1);
      end

      // ---- Disarm on taken CF leaving the loop region ----
      if (armed_q && cf_valid_i && cf_taken_i &&
          !((cf_target_i >= base_q) && (cf_target_i <= end_q))) begin
        armed_d     = 1'b0;
        capturing_d = 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_q      <= '0;
      body_len_q  <= '0;
      fill_ptr_q  <= '0;
      replay_q    <= '0;
      capturing_q <= 1'b0;
      armed_q     <= 1'b0;
      base_q      <= '0;
      base_hi_p1_q <= HI_W'(1);
      end_q       <= '0;
      arm_epoch_q <= '0;
    end else begin
      data_q      <= data_d;
      body_len_q  <= body_len_d;
      fill_ptr_q  <= fill_ptr_d;
      replay_q    <= replay_d;
      capturing_q <= capturing_d;
      armed_q     <= armed_d;
      base_q      <= base_d;
      base_hi_p1_q <= base_hi_p1_d;
      end_q       <= end_d;
      arm_epoch_q <= arm_epoch_d;
    end
  end

  //pragma translate_off
  // A140 invariants: the registered high alternative is exactly base's high
  // slice plus one, and the split compare equals the VLEN-wide reference
  // (base + (cursor << ALIGN)) for both cursors.
  logic [G6LCCfg.VLEN-1:0] expect_pc, expect_fill;
  assign expect_pc   = base_q + (G6LCCfg.VLEN'(replay_q)   << ALIGN);
  assign expect_fill = base_q + (G6LCCfg.VLEN'(fill_ptr_q) << ALIGN);
  always_ff @(posedge clk_i) if (rst_ni) begin
    assert (base_hi_p1_q == base_q[G6LCCfg.VLEN-1:LOW_W] + HI_W'(1))
    else $error("g6lc_loop_buffer: base_hi_p1_q lost the base invariant");
    assert (addr_eq(lookup_vaddr_i, pc_low_sum) == (lookup_vaddr_i == expect_pc))
    else $error("g6lc_loop_buffer: split lookup compare differs from the reference");
    assert (addr_eq(fill_vaddr_i, fill_low_sum) == (fill_vaddr_i == expect_fill))
    else $error("g6lc_loop_buffer: split fill compare differs from the reference");
    // consume only ever injects the block registered for THIS head/epoch
    assert (!consume_o || (lookup_valid_i && lookup_vaddr_i == hit_vaddr_q &&
                           hit_epoch_q == epoch_i))
    else $error("g6lc_loop_buffer: inject identity");
  end
  //pragma translate_on

endmodule
