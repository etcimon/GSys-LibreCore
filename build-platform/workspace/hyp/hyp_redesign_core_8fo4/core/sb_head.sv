// hyp8 provenance: REWRITTEN (sv-timing emit base, head discovery stage)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// hyp8 (group 6): per-hart oldest-live head discovery, split as a 2-step
// lowest-set (rank-4 bookkeeping, +1 on the head outputs):
//   step 1 (registered): per-CHUNK find-first on each hart's issued mask,
//         split by the at/above-pointer thermometer into hi/lo halves;
//   step 2 (combinational): merge the registered chunk winners in chunk
//         order -- hi chunks first, then lo -- and rotate the winning
//         index back to a slot.
// The registered head can trail a commit by one cycle: it may point at a
// slot just freed (stale-older, conservative) but never at a slot younger
// than the true head, because the live frontier only moves forward and
// new allocations append at the issue tail.
//
// The commit-port slot select (sb_commit_bundle, MixedSmt only) needs the
// head in the SAME cycle as the entry state it routes -- a stale head
// there could reroute a just-reallocated slot -- so the emit's
// absolute-order combinational head is kept alongside (head_*_c) for the
// select path only. sb_head_pc_o / sb_head_valid_o come from the
// registered head. The serial reference under translate_off remains the
// equivalence witness for both.

module sb_head
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type sb_mem_t = logic
) (
    input  logic                                          clk_i,
    input  logic                                          rst_ni,
    input  logic                                          flush_i,
    // Live entry array (read-only)
    input  sb_mem_t [G6LCCfg.NR_SB_ENTRIES-1:0]           mem_q_i,
    // Reclaim/commit anchor -- ring-order origin of the scan
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]              commit_ptr_i,
    // Registered 2-step head -- T6b-2 recovery PC/valid outputs
    output logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:0]  sb_head_pc_o,
    output logic [G6LCCfg.NrHarts-1:0]                    sb_head_valid_o,
    // Combinational head (same-cycle, emit form) -- commit-select only
    output logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][G6LCCfg.TRANS_ID_BITS-1:0]   head_slot_c_o,
    output logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0]                            head_valid_c_o
);

  localparam int unsigned SB_NH = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned CHUNK = 8;
  localparam int unsigned NCHUNK = (G6LCCfg.NR_SB_ENTRIES + CHUNK - 1) / CHUNK;
  localparam int unsigned CW = $clog2(CHUNK);      // chunk-local index width
  localparam int unsigned GCW = (NCHUNK > 1) ? $clog2(NCHUNK) : 1;  // chunk id

  // Lowest set bit as a log-depth prefix OR (the A136 form): a bit is the
  // lowest set bit iff it is set and no lower bit is. `x & (~x + 1)` mapped
  // as a carry chain on the live board.
  function automatic logic [CHUNK-1:0] chunk_below(input logic [CHUNK-1:0] x);
    logic [CHUNK-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < CHUNK; l = l << 1) below = below | (below << l);
    return below;
  endfunction

  // hyp8: index of the lowest set bit as a balanced popcount -- the bits
  // strictly below it are exactly `~x & ~below`, so $countones yields the
  // position as an adder tree instead of a serial find-first.
  function automatic int unsigned chunk_idx(input logic [CHUNK-1:0] x);
    return $countones(~x & ~chunk_below(x));
  endfunction

  function automatic logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_below(input logic [G6LCCfg.NR_SB_ENTRIES-1:0] x);
    logic [G6LCCfg.NR_SB_ENTRIES-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < G6LCCfg.NR_SB_ENTRIES; l = l << 1) below = below | (below << l);
    return below;
  endfunction

  function automatic int unsigned sb_idx(input logic [G6LCCfg.NR_SB_ENTRIES-1:0] x);
    return $countones(~x & ~sb_below(x));
  endfunction

  // ------------------------------------------------------------------
  // Step 1 (registered): per-hart, per-chunk find-first, split into
  // at-or-above-pointer (hi) and below-pointer (lo) halves. For each hart
  // and each half, each chunk contributes {valid, chunk-local first idx}.
  // ------------------------------------------------------------------
  logic [SB_NH-1:0][NCHUNK-1:0]            hi_v_q, lo_v_q;
  logic [SB_NH-1:0][NCHUNK-1:0][CW-1:0]    hi_i_q, lo_i_q;
  logic [GCW-1:0]                          ptr_chunk_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : head_step1_ptr
    if (!rst_ni)        ptr_chunk_q <= '0;
    // hyp8: CHUNK == 8 is a power of two, so the chunk id is the index
    // high bits -- a shift, not the emit's constant division (the
    // structural model bills `/` as a real divider).
    else if (flush_i)   ptr_chunk_q <= '0;
    else                ptr_chunk_q <= GCW'(commit_ptr_i >> $clog2(CHUNK));
  end

  // hyp8: per-(hart, chunk) candidate vectors and encoders are genvar
  // blocks of continuous assigns, so the structural model bills them as
  // independent cones instead of a serial procedural loop.
  for (genvar gh = 0; gh < SB_NH; gh++) begin : gen_head_h
    for (genvar gc = 0; gc < NCHUNK; gc++) begin : gen_head_c
      logic [CHUNK-1:0] hc, lc;
      for (genvar gk = 0; gk < CHUNK; gk++) begin : gen_head_k
        if (gc * CHUNK + gk < G6LCCfg.NR_SB_ENTRIES) begin : gen_in
          localparam int unsigned S = gc * CHUNK + gk;
          assign hc[gk] = mem_q_i[S].issued &&
                          (mem_q_i[S].sbe.hart_id ==
                           $bits(mem_q_i[S].sbe.hart_id)'(gh)) &&
                          (G6LCCfg.TRANS_ID_BITS'(S) >= commit_ptr_i);
          assign lc[gk] = mem_q_i[S].issued &&
                          (mem_q_i[S].sbe.hart_id ==
                           $bits(mem_q_i[S].sbe.hart_id)'(gh)) &&
                          (G6LCCfg.TRANS_ID_BITS'(S) < commit_ptr_i);
        end else begin : gen_pad
          assign hc[gk] = 1'b0;
          assign lc[gk] = 1'b0;
        end
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin : head_step1
        if (!rst_ni) begin
          hi_v_q[gh][gc] <= 1'b0;
          lo_v_q[gh][gc] <= 1'b0;
          hi_i_q[gh][gc] <= '0;
          lo_i_q[gh][gc] <= '0;
        end else if (flush_i) begin
          hi_v_q[gh][gc] <= 1'b0;
          lo_v_q[gh][gc] <= 1'b0;
          hi_i_q[gh][gc] <= '0;
          lo_i_q[gh][gc] <= '0;
        end else begin
          hi_v_q[gh][gc] <= |hc;
          lo_v_q[gh][gc] <= |lc;
          hi_i_q[gh][gc] <= CW'(chunk_idx(hc));
          lo_i_q[gh][gc] <= CW'(chunk_idx(lc));
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Step 2 (combinational): merge the registered chunk winners. The chunk
  // holding the pointer is the rotation origin: hi chunks at-or-above it
  // first, then the lo chunks. Since the hi/lo split already encoded the
  // pointer comparison inside each chunk, the merge is: first hi chunk
  // with index >= ptr_chunk, else first hi chunk, else first lo chunk
  // with index >= ptr_chunk, else first lo chunk.
  // ------------------------------------------------------------------
  logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] head_slot_q;
  logic [SB_NH-1:0]                          head_valid_q;

  // hyp8: the four candidate groups (hi/lo x at-or-above/below pointer
  // chunk) are per-chunk compare vectors; the winner is a fixed 4-way
  // select on their group valids, index by balanced popcount.
  for (genvar gh = 0; gh < SB_NH; gh++) begin : gen_step2
    logic [NCHUNK-1:0] hige, hilt, loge, lolt;
    for (genvar gc = 0; gc < NCHUNK; gc++) begin : gen_sel
      assign hige[gc] = hi_v_q[gh][gc] && (GCW'(gc) >= ptr_chunk_q);
      assign hilt[gc] = hi_v_q[gh][gc] && (GCW'(gc) <  ptr_chunk_q);
      assign loge[gc] = lo_v_q[gh][gc] && (GCW'(gc) >= ptr_chunk_q);
      assign lolt[gc] = lo_v_q[gh][gc] && (GCW'(gc) <  ptr_chunk_q);
    end
    // hyp8: the four groups form one ordered candidate list (hige, hilt,
    // loge, lolt -- each in ascending chunk order). A log-depth prefix OR
    // isolates the first live candidate as a one-hot, and a balanced
    // genvar OR tree selects its slot -- no serial accumulate.
    localparam int unsigned ORD_N = 4 * NCHUNK;
    localparam int unsigned OLV = (ORD_N > 1) ? $clog2(ORD_N) : 1;
    function automatic logic [ORD_N-1:0] ord_below(input logic [ORD_N-1:0] x);
      logic [ORD_N-1:0] below;
      below = x << 1;
      for (int unsigned l = 1; l < ORD_N; l = l << 1) below = below | (below << l);
      return below;
    endfunction
    logic [ORD_N-1:0] ord, ooh;
    logic [ORD_N-1:0][G6LCCfg.TRANS_ID_BITS-1:0] val;
    logic [OLV:0][ORD_N-1:0][G6LCCfg.TRANS_ID_BITS-1:0] r;
    for (genvar gk = 0; gk < ORD_N; gk++) begin : gen_ord
      localparam int unsigned GC2 = gk % NCHUNK;
      localparam int unsigned GRP = gk / NCHUNK;
      assign ord[gk] = (GRP == 0) ? hige[GC2] : (GRP == 1) ? hilt[GC2] :
                       (GRP == 2) ? loge[GC2] : lolt[GC2];
      assign val[gk] = G6LCCfg.TRANS_ID_BITS'(GC2 * CHUNK) +
                       ((GRP < 2) ? G6LCCfg.TRANS_ID_BITS'(hi_i_q[gh][GC2])
                                  : G6LCCfg.TRANS_ID_BITS'(lo_i_q[gh][GC2]));
      assign r[0][gk] = ooh[gk] ? val[gk] : '0;
    end
    assign ooh = ord & ~ord_below(ord);
    for (genvar l = 0; l < OLV; l++) begin : gen_lvl
      for (genvar i = 0; i < ORD_N; i++) begin : gen_or
        if (i < ((ORD_N + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * i + 1) < ((ORD_N + (1 << l) - 1) >> l)) begin : gen_pair
            assign r[l+1][i] = r[l][2*i] | r[l][2*i+1];
          end else begin : gen_odd
            assign r[l+1][i] = r[l][2*i];
          end
        end else begin : gen_pad
          assign r[l+1][i] = '0;
        end
      end
    end
    assign head_valid_q[gh] = |ord;
    assign head_slot_q[gh]  = r[OLV][0];
  end

  // ------------------------------------------------------------------
  // Combinational head (emit absolute-order form) for the commit select:
  // two lowest-set isolations on the registered candidate vector split by
  // a thermometer mask; the slot is encoded directly.
  // ------------------------------------------------------------------
  // hyp8: candidate/thermometer vectors are genvar assigns; the encode is
  // a balanced popcount on the prefix-OR mask (index of the lowest set
  // bit) rather than a serial accumulate.
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] ge_all;
  for (genvar gi = 0; gi < G6LCCfg.NR_SB_ENTRIES; gi++) begin : gen_ge
    assign ge_all[gi] = (G6LCCfg.TRANS_ID_BITS'(gi) >= commit_ptr_i);
  end
  for (genvar gh = 0; gh < SB_NH; gh++) begin : gen_scan_c
    logic [G6LCCfg.NR_SB_ENTRIES-1:0] cand, hi_c, lo_c;
    for (genvar gi = 0; gi < G6LCCfg.NR_SB_ENTRIES; gi++) begin : gen_cand
      assign cand[gi] = mem_q_i[gi].issued &&
                        (mem_q_i[gi].sbe.hart_id ==
                         $bits(mem_q_i[gi].sbe.hart_id)'(gh));
    end
    assign hi_c = cand & ge_all;
    assign lo_c = cand & ~ge_all;
    assign head_valid_c_o[gh] = |cand;
    assign head_slot_c_o[gh]  = G6LCCfg.TRANS_ID_BITS'(
        (|hi_c) ? sb_idx(hi_c) : sb_idx(lo_c));
  end

  // Outputs: registered head -> PC mux + valid.
  for (genvar gh = 0; gh < SB_NH; gh++) begin : gen_head_out
    assign sb_head_valid_o[gh] =
        head_valid_q[gh] &&
        mem_q_i[head_slot_q[gh]].issued &&
        (mem_q_i[head_slot_q[gh]].sbe.hart_id ==
         $bits(mem_q_i[head_slot_q[gh]].sbe.hart_id)'(gh));
    assign sb_head_pc_o[gh] =
        sb_head_valid_o[gh] ? mem_q_i[head_slot_q[gh]].sbe.pc : '0;
  end

//pragma translate_off
  // Serial reference (the T6b-1 implementation): both head forms must
  // agree with it. The registered head is checked one cycle late through
  // a shadow copy -- staleness is by design (stale-older is legal), so the
  // reference tracks the registered pipeline rather than the live array.
  logic [SB_NH-1:0][G6LCCfg.VLEN-1:0] sb_head_pc_ref;
  logic [SB_NH-1:0]                   sb_head_valid_ref;
  logic [SB_NH-1:0][G6LCCfg.VLEN-1:0] sb_head_pc_ref_q;
  logic [SB_NH-1:0]                   sb_head_valid_ref_q;
  logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] head_slot_c_ref;
  logic [SB_NH-1:0]                   head_valid_c_ref;
  logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] head_slot_c_ref_q;
  always_comb begin : sb_head_ref
    automatic logic [G6LCCfg.TRANS_ID_BITS-1:0] slot;
    automatic logic [SB_NH-1:0] found;
    slot              = commit_ptr_i;
    found             = '0;
    sb_head_valid_ref = '0;
    sb_head_pc_ref    = '0;
    head_valid_c_ref  = '0;
    head_slot_c_ref   = '0;
    for (int unsigned k = 0; k < G6LCCfg.NR_SB_ENTRIES; k++) begin
      if (mem_q_i[slot].issued && int'(mem_q_i[slot].sbe.hart_id) < SB_NH &&
          !found[mem_q_i[slot].sbe.hart_id]) begin
        found[mem_q_i[slot].sbe.hart_id]             = 1'b1;
        sb_head_valid_ref[mem_q_i[slot].sbe.hart_id] = 1'b1;
        sb_head_pc_ref[mem_q_i[slot].sbe.hart_id]    = mem_q_i[slot].sbe.pc;
        head_valid_c_ref[mem_q_i[slot].sbe.hart_id]  = 1'b1;
        head_slot_c_ref[mem_q_i[slot].sbe.hart_id]   = slot;
      end
      slot = slot + 1'b1;
    end
  end
  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      sb_head_pc_ref_q    <= '0;
      sb_head_valid_ref_q <= '0;
      head_slot_c_ref_q   <= '0;
    end else begin
      sb_head_pc_ref_q    <= sb_head_pc_ref;
      sb_head_valid_ref_q <= sb_head_valid_ref;
      head_slot_c_ref_q   <= head_slot_c_ref;
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (head_valid_c_o == head_valid_c_ref)
      else $fatal(1, "sb_head combinational head_valid diverges from the serial reference");
      for (int h = 0; h < SB_NH; h++)
        if (head_valid_c_ref[h])
          assert (head_slot_c_o[h] == head_slot_c_ref[h])
          else $fatal(1, "sb_head combinational head_slot diverges from the serial reference");
      // Registered head: the merge of the step-1 chunk registers must equal
      // last cycle's serial scan. The slot may be dead NOW (stale-older is
      // legal -- a commit can free it between the step-1 sample and this
      // cycle; the live re-check on sb_head_valid_o masks that at the
      // output), so the check compares against the delayed reference, not
      // the live mem_q.
      for (int h = 0; h < SB_NH; h++)
        assert (head_valid_q[h] == sb_head_valid_ref_q[h])
        else $fatal(1, "sb_head registered head_valid diverges from the delayed serial reference");
      for (int h = 0; h < SB_NH; h++)
        if (head_valid_q[h])
          assert (head_slot_q[h] == head_slot_c_ref_q[h])
          else $fatal(1, "sb_head registered head slot diverges from the delayed serial reference");
    end
  end
//pragma translate_on

endmodule
