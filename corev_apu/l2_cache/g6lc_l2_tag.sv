// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.0 L2 tag array — parallel SET_ASSOC tag compare.
// TAG_SRAM=0 keeps the flop array with a single-cycle combinational compare
// (the original netlist; every existing package selects this path).
// TAG_SRAM=1 moves the tag words behind one 1R1W tc_sram (Latency=1): the
// parent launches the row read one cycle before the compare needs it, and
// the valid bits stay in flops so the reset contract is unchanged. See
// g6lc_l2_tag.tech-spec.md for the launched-read protocol.

module g6lc_l2_tag #(
    parameter int unsigned NUM_SETS   = 512,
    parameter int unsigned SET_ASSOC  = 8,
    parameter int unsigned TAG_WIDTH  = 48,
    parameter int unsigned IDX_WIDTH  = 9,
    parameter bit          TAG_SRAM   = 1'b0
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // Launched row read for the NEXT cycle's compare (TAG_SRAM=1 only).
    // launch_i asserts with the index whose row is needed next cycle.
    input  logic                          launch_i,
    input  logic [IDX_WIDTH-1:0]          launch_index_i,
    // Lookup
    input  logic                          lookup_i,
    input  logic [IDX_WIDTH-1:0]          index_i,
    input  logic [TAG_WIDTH-1:0]          tag_i,
    output logic                          hit_o,
    output logic [$clog2(SET_ASSOC)-1:0]  way_o,
    output logic [SET_ASSOC-1:0]          way_valid_o,
    // 1 iff the row now presented was launched last cycle and won the read
    // port (an inval-match read takes priority). Constant 1 under flops.
    output logic                          row_valid_o,
    // Probe tag of a selected way (for victim/evict address rebuild)
    input  logic [$clog2(SET_ASSOC)-1:0]  probe_way_i,
    output logic [TAG_WIDTH-1:0]          probe_tag_o,
    output logic                          probe_valid_o,
    // Allocate / update on fill
    input  logic                          write_i,
    input  logic [IDX_WIDTH-1:0]          write_index_i,
    input  logic [$clog2(SET_ASSOC)-1:0]  write_way_i,
    input  logic [TAG_WIDTH-1:0]          write_tag_i,
    input  logic                          write_valid_i,
    // Invalidate way
    input  logic                          inval_i,
    input  logic [IDX_WIDTH-1:0]          inval_index_i,
    input  logic [$clog2(SET_ASSOC)-1:0]  inval_way_i,
    // Address-match invalidate (L3→L2 inclusive back-inval): clear every way
    // in the set whose tag matches.
    input  logic                          inval_match_i,
    input  logic [IDX_WIDTH-1:0]          inval_match_index_i,
    input  logic [TAG_WIDTH-1:0]          inval_match_tag_i
);

  localparam int unsigned WAY_W = (SET_ASSOC <= 1) ? 1 : $clog2(SET_ASSOC);

  typedef struct packed {
    logic                 valid;
    logic [TAG_WIDTH-1:0] tag;
  } tag_entry_t;

  if (!TAG_SRAM) begin : gen_tag_flop
    // Flop array: single-cycle combinational compare, bit-identical to the
    // original implementation. The launch ports are unused and row_valid_o
    // is constant — the parent's S_TAG gate folds away entirely.
    // [sets][ways]
    tag_entry_t [NUM_SETS-1:0][SET_ASSOC-1:0] tags_q, tags_d;

    // Parallel compare (contention-critical path: keep short)
    logic [SET_ASSOC-1:0] hit_way;
    always_comb begin
      hit_way = '0;
      for (int unsigned w = 0; w < SET_ASSOC; w++) begin
        hit_way[w] = lookup_i && tags_q[index_i][w].valid &&
                     (tags_q[index_i][w].tag == tag_i);
      end
    end
    assign hit_o = |hit_way;

    // One-hot → binary way
    always_comb begin
      way_o = '0;
      for (int unsigned w = 0; w < SET_ASSOC; w++) begin
        if (hit_way[w]) way_o = WAY_W'(w);
      end
    end

    always_comb begin
      for (int unsigned w = 0; w < SET_ASSOC; w++) begin
        way_valid_o[w] = tags_q[index_i][w].valid;
      end
    end

    assign probe_tag_o   = tags_q[index_i][probe_way_i].tag;
    assign probe_valid_o = tags_q[index_i][probe_way_i].valid;
    assign row_valid_o   = 1'b1;

    // Victim: first invalid, else way 0 (RRIP later)
    // Exposed via write_way_i from parent.

    always_comb begin
      tags_d = tags_q;
      if (write_i) begin
        tags_d[write_index_i][write_way_i].valid = write_valid_i;
        tags_d[write_index_i][write_way_i].tag   = write_tag_i;
      end
      if (inval_i) begin
        tags_d[inval_index_i][inval_way_i].valid = 1'b0;
      end
      // Inclusive upper-level victim: drop matching L2 line (all ways, tag match)
      if (inval_match_i) begin
        for (int unsigned w = 0; w < SET_ASSOC; w++) begin
          if (tags_q[inval_match_index_i][w].valid &&
              tags_q[inval_match_index_i][w].tag == inval_match_tag_i) begin
            tags_d[inval_match_index_i][w].valid = 1'b0;
          end
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        // Whole-array clear rather than a nested per-set/per-way loop.
        // Identical behaviour, but the loop form is unrolled per set by the
        // synthesis frontend, and at the production geometry (512 sets x 8
        // ways) that exceeds its unroll budget: the design failed to
        // elaborate for synthesis even though the simulator accepted it.
        // This removes the elaboration blocker only; the array is still
        // flops, which is the real cost issue and is tracked separately.
        tags_q <= '0;
      end else begin
        tags_q <= tags_d;
      end
    end

    logic _unused_launch;
    assign _unused_launch = launch_i & (|launch_index_i);
  end else begin : gen_tag_sram
    // Valid bits stay in flops: they carry the whole-array reset contract
    // and are consulted combinationally by hit/probe/way_valid. The SRAM
    // row contents are don't-care until written — a way is only ever
    // compared or probed once its valid bit is set, and a set's row is
    // rewritten on every install into it.
    logic [NUM_SETS-1:0][SET_ASSOC-1:0] valid_q, valid_d;

    // One read port serves launched lookups and the inval-match read; the
    // match wins because the lookup simply re-launches (row_valid_o low
    // stalls the parent in S_TAG one extra cycle) while the invalidation
    // must be captured at its offer cycle to keep ordering vs fills.
    logic                    inv_rd, rd_req;
    logic [IDX_WIDTH-1:0]    rd_index;
    logic                    row_valid_q, inv_pend_q;
    logic [IDX_WIDTH-1:0]    inv_index_q, row_index_q;
    logic [TAG_WIDTH-1:0]    inv_tag_q;
    // Valid row snapshot taken WITH the read (cycle 1): the deferred compare
    // must decide on the pre-read state exactly like the flop array's
    // tags_q sampling. Using live valid_q in cycle 2 would let a stale tag
    // in an invalid way clear a line installed in the same cycle as the
    // read — the flop path never sees that match (old valid was 0).
    logic [SET_ASSOC-1:0]    inv_valid_q;
    // Same-index write forward: a fill that installs into the set whose row
    // was just read is substituted next cycle so the compare and the victim
    // probe see post-write tags like the flop array. No use-cycle forward:
    // the flop compare reads tags_q (pre-write) too, and a combinational
    // replay would close a loop through the parent's bank-conflict term.
    logic                    fwd_valid_q;
    logic [WAY_W-1:0]        fwd_way_q;
    logic [TAG_WIDTH-1:0]    fwd_tag_q;

    assign inv_rd   = inval_match_i;
    assign rd_req   = inv_rd || launch_i;
    assign rd_index = inv_rd ? inval_match_index_i : launch_index_i;

    logic [SET_ASSOC-1:0][TAG_WIDTH-1:0] row_raw, row_tag;
    logic [1:0][SET_ASSOC*TAG_WIDTH-1:0] sram_rdata;
    logic [SET_ASSOC-1:0]                way_be;

    // be = one-hot way select: ByteWidth=TAG_WIDTH makes each byte lane one
    // way's tag.
    always_comb begin
      way_be = '0;
      way_be[write_way_i] = 1'b1;
    end

    tc_sram #(
        .NumWords   (NUM_SETS),
        .DataWidth  (SET_ASSOC * TAG_WIDTH),
        .ByteWidth  (TAG_WIDTH),
        .NumPorts   (2),
        .Latency    (1),
        .SimInit    ("none"),
        .ImplKey    ("g6lc_l2_tag")
    ) i_tags (
        .clk_i,
        .rst_ni,
        .req_i   ({write_i && write_valid_i, rd_req}),
        .we_i    ({1'b1, 1'b0}),
        .addr_i  ({write_index_i, rd_index}),
        .wdata_i ({{SET_ASSOC{write_tag_i}}, {(SET_ASSOC*TAG_WIDTH){1'b0}}}),
        .be_i    ({way_be, {SET_ASSOC{1'b0}}}),
        .rdata_o (sram_rdata)
    );
    assign row_raw = sram_rdata[0];

    // Forward substitution: only the launch-cycle write is replayed
    // (registered). A use-cycle combinational forward would (a) diverge from
    // the flop array — its compare reads tags_q, so a write landing in the
    // compare cycle is invisible there too — and (b) close a combinational
    // loop hit_way -> tag_way -> data-bank conflict -> write_i -> row_tag.
    // Writes landing in the use cycle reach the compare one cycle later
    // through the re-launched row, exactly like the flop path.
    always_comb begin
      row_tag = row_raw;
      if (fwd_valid_q) begin
        row_tag[fwd_way_q] = fwd_tag_q;
      end
    end

    // Parallel compare against the forwarded row (contention-critical path:
    // now a registered SRAM row + valid flops instead of a NUM_SETS-deep
    // flop mux — see tech-spec for the timing note).
    logic [SET_ASSOC-1:0] hit_way;
    always_comb begin
      hit_way = '0;
      for (int unsigned w = 0; w < SET_ASSOC; w++) begin
        hit_way[w] = lookup_i && row_valid_q && valid_q[index_i][w] &&
                     (row_tag[w] == tag_i);
      end
    end
    assign hit_o = |hit_way;

    // One-hot → binary way
    always_comb begin
      way_o = '0;
      for (int unsigned w = 0; w < SET_ASSOC; w++) begin
        if (hit_way[w]) way_o = WAY_W'(w);
      end
    end

    always_comb begin
      for (int unsigned w = 0; w < SET_ASSOC; w++) begin
        way_valid_o[w] = valid_q[index_i][w];
      end
    end

    assign probe_tag_o   = row_tag[probe_way_i];
    assign probe_valid_o = valid_q[index_i][probe_way_i];
    assign row_valid_o   = row_valid_q;

    // Deferred half of the inval-match read: cycle 1 takes the read port
    // (inv_rd) and snapshots the set's valid bits, cycle 2 compares the row
    // and clears matching valid bits. Both operands are the cycle-1 state —
    // the RAW row (no write forward) and the snapshot inv_valid_q: a write
    // that landed in the read cycle is an event the flop path also matched
    // against pre-write contents, while a write landing this cycle is newer
    // and outranks the clear below.
    always_comb begin
      valid_d = valid_q;
      if (inv_pend_q) begin
        for (int unsigned w = 0; w < SET_ASSOC; w++) begin
          if (inv_valid_q[w] && (row_raw[w] == inv_tag_q)) begin
            valid_d[inv_index_q][w] = 1'b0;
          end
        end
      end
      if (write_i) begin
        valid_d[write_index_i][write_way_i] = write_valid_i;
      end
      if (inval_i) begin
        valid_d[inval_index_i][inval_way_i] = 1'b0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_q     <= '0;
        row_valid_q <= 1'b0;
        inv_pend_q  <= 1'b0;
        inv_index_q <= '0;
        inv_tag_q   <= '0;
        inv_valid_q <= '0;
        row_index_q <= '0;
        fwd_valid_q <= 1'b0;
        fwd_way_q   <= '0;
        fwd_tag_q   <= '0;
      end else begin
        valid_q     <= valid_d;
        row_valid_q <= launch_i && !inv_rd;
        inv_pend_q  <= inv_rd;
        inv_index_q <= inval_match_index_i;
        inv_tag_q   <= inval_match_tag_i;
        inv_valid_q <= valid_q[inval_match_index_i];
        row_index_q <= rd_index;
        fwd_valid_q <= rd_req && write_i && write_valid_i &&
                       (write_index_i == rd_index);
        fwd_way_q   <= write_way_i;
        fwd_tag_q   <= write_tag_i;
      end
    end

    //pragma translate_off
    `ifndef SYNTHESIS
    // Contract: a consumed row must be the one launched for this index —
    // the parent launches idx_of(addr_d) on every transition into (or hold
    // of) S_TAG, so an unset row can only be a stale inval-match read.
    always_ff @(posedge clk_i) begin
      if (rst_ni && lookup_i && row_valid_o && (index_i != row_index_q)) begin
        $fatal(1, "L2_TAG_ROW_INDEX got=%0d want=%0d", index_i, row_index_q);
      end
    end
    `endif
    //pragma translate_on
  end

endmodule
