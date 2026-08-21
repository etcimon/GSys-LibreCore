// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U2 loop buffer ΓÇö aggressively optimised for the fetch datapath.
//
// Data-path analysis (vs N-way CAM):
//   * Old: full-VLEN tag compare ├ù N every cycle (long cone, high toggle).
//   * New: sequential capture + sequential replay. Lookup is a *single*
//     equality (expect_pc == lookup) and a bounds check ΓÇö one comparator,
//     flop array read by binary index, no CAM.
//   * Capture is also sequential: only the next expected fill address is
//     accepted (eliminates the [base,end] range compare on the fill path).
//   * Storage is data-only; address = base + i<<ALIGN (reconstructed).
//   * Hit injects data and advances the cursor; wrap to 0 on back-edge.
//   * Flush / fence.i / leave-loop disarms in one cycle.
//
// Critical path: expect_pc add ΓåÆ EQ ΓåÆ hit ΓåÆ inject mux (frontend).
// Keep the EQ cone short: base is fetch-aligned; cursor is IDX_W bits.

module g6lc_loop_buffer
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned NR_ENTRIES = 8,
    parameter int unsigned DATA_W = 32
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    enable_i,
    // Control-flow observation (arm / disarm)
    input  logic                    cf_valid_i,
    input  logic                    cf_taken_i,
    input  logic [CVA6Cfg.VLEN-1:0] cf_pc_i,
    input  logic [CVA6Cfg.VLEN-1:0] cf_target_i,
    // Fill from demand I$ return (only while capturing; sequential)
    input  logic                    fill_valid_i,
    input  logic [CVA6Cfg.VLEN-1:0] fill_vaddr_i,
    input  logic [DATA_W-1:0]       fill_data_i,
    // Sequential lookup (FTQ head)
    input  logic [CVA6Cfg.VLEN-1:0] lookup_vaddr_i,
    input  logic                    lookup_ready_i,  // consumer accepts inject
    output logic                    hit_o,
    output logic [DATA_W-1:0]       data_o,
    // When high, suppress I$ demand; frontend injects data_o instead
    output logic                    active_o,
    // Pop FTQ on successful inject
    output logic                    consume_o
);

  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);
  localparam int unsigned ALIGN = CVA6Cfg.FETCH_ALIGN_BITS;
  localparam logic [IDX_W:0] NR_EXT = NR_ENTRIES[IDX_W:0];

  // Body storage: data only (address = base + i<<ALIGN)
  logic [NR_ENTRIES-1:0][DATA_W-1:0] data_q, data_d;
  logic [IDX_W:0] body_len_q, body_len_d;  // valid fill slots
  logic [IDX_W-1:0] fill_ptr_q, fill_ptr_d;
  logic [IDX_W-1:0] replay_q, replay_d;    // sequential read cursor
  logic             capturing_q, capturing_d;
  logic             armed_q, armed_d;
  logic [CVA6Cfg.VLEN-1:0] base_q, base_d;  // loop start (back-edge target)
  logic [CVA6Cfg.VLEN-1:0] end_q, end_d;    // PC of back-edge branch

  // Short backward edge: target < pc and body fits in NR_ENTRIES fetch blocks
  logic short_back;
  logic [CVA6Cfg.VLEN-1:0] span_bytes;
  assign span_bytes = cf_pc_i - cf_target_i;
  assign short_back = cf_valid_i && cf_taken_i && (cf_target_i < cf_pc_i) &&
                      (span_bytes <= (CVA6Cfg.VLEN'(NR_ENTRIES) << ALIGN));

  // ---- Sequential address reconstruction (shared shift) ----
  // expect_pc  = base + replay<<ALIGN   (lookup hit)
  // expect_fill = base + fill_ptr<<ALIGN (capture accept)
  logic [CVA6Cfg.VLEN-1:0] expect_pc, expect_fill;
  assign expect_pc   = base_q + (CVA6Cfg.VLEN'(replay_q)   << ALIGN);
  assign expect_fill = base_q + (CVA6Cfg.VLEN'(fill_ptr_q) << ALIGN);

  // Single-comparator hit: armed and lookup matches sequential cursor
  logic seq_hit;
  assign seq_hit = enable_i && armed_q && (lookup_vaddr_i == expect_pc) &&
                   ({1'b0, replay_q} < body_len_q);

  assign hit_o     = seq_hit;
  assign data_o    = data_q[replay_q];
  assign active_o  = seq_hit;  // same as hit: demand suppressed only on inject
  assign consume_o = seq_hit && lookup_ready_i;

  // Sequential fill accept (one EQ, no range cone)
  logic fill_accept;
  assign fill_accept = capturing_q && fill_valid_i && (fill_vaddr_i == expect_fill) &&
                       (body_len_q < NR_EXT);

  always_comb begin
    data_d       = data_q;
    body_len_d   = body_len_q;
    fill_ptr_d   = fill_ptr_q;
    replay_d     = replay_q;
    capturing_d  = capturing_q;
    armed_d      = armed_q;
    base_d       = base_q;
    end_d        = end_q;

    if (flush_i) begin
      capturing_d = 1'b0;
      armed_d     = 1'b0;
      fill_ptr_d  = '0;
      body_len_d  = '0;
      replay_d    = '0;
    end else if (enable_i) begin
      // ---- Arm: start capture on short back-edge ----
      if (short_back && !capturing_q) begin
        capturing_d = 1'b1;
        armed_d     = 1'b0;
        fill_ptr_d  = '0;
        body_len_d  = '0;
        replay_d    = '0;
        base_d      = cf_target_i;
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
      end_q       <= '0;
    end else begin
      data_q      <= data_d;
      body_len_q  <= body_len_d;
      fill_ptr_q  <= fill_ptr_d;
      replay_q    <= replay_d;
      capturing_q <= capturing_d;
      armed_q     <= armed_d;
      base_q      <= base_d;
      end_q       <= end_d;
    end
  end

endmodule
