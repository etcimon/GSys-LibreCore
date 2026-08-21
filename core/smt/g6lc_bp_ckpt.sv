// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// FSE S2 / U1 prediction checkpoint FIFO: GHR + full RAS stack snapshot so a
// mispredict can restore control-flow prediction state. Circular buffer;
// overflow drops the oldest entry. Prerequisite for U4/U5/FSE recovery.
//
// FSE S5: when NrHarts>1 the FIFO is banked per hart so a mispredict on hart A
// never pops/restores peer-hart checkpoints. NrHarts==1 is identity (single
// FIFO).

module g6lc_bp_ckpt
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned GHIST_LEN = 24,
    parameter int unsigned DEPTH = 8,
    // RAS stack depth (0 ΓåÆ GHR-only checkpoints, RAS fields ignored)
    parameter int unsigned RAS_DEPTH = 0,
    parameter int unsigned RAS_VLEN = 64
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic                 flush_i,
    // FSE S5: which hart bank push/pop/restore apply to (ignored when NrHarts==1)
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // Push a checkpoint (on branch train / predict-resolve path)
    input  logic                 push_i,
    input  logic [GHIST_LEN-1:0] push_ghist_i,
    // Full RAS stack snapshot at push (ignored when RAS_DEPTH==0)
    input  logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0]                 push_ras_valid_i,
    input  logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0][RAS_VLEN-1:0]    push_ras_ra_i,
    // Pop / restore on resolution (mispredict restores head, correct pop discards)
    input  logic                 pop_i,
    input  logic                 restore_i,  // 1 = mispredict ΓåÆ restore head
    output logic [GHIST_LEN-1:0] restore_ghist_o,
    output logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0]              restore_ras_valid_o,
    output logic [RAS_DEPTH == 0 ? 0 : RAS_DEPTH-1:0][RAS_VLEN-1:0] restore_ras_ra_o,
    output logic                 restore_valid_o,
    output logic                 empty_o,
    output logic                 full_o
);

  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned RD = (RAS_DEPTH < 1) ? 1 : RAS_DEPTH;
  localparam int unsigned NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  typedef struct packed {
    logic [GHIST_LEN-1:0] ghist;
    logic [RD-1:0] ras_v;
    logic [RD-1:0][RAS_VLEN-1:0] ras_ra;
  } ckpt_t;

  // One circular FIFO per hart when multi-hart; single when NrHarts==1.
  ckpt_t [NH-1:0][DEPTH-1:0] mem_q;
  logic [NH-1:0][PTR_W-1:0] head_q, tail_q;
  logic [NH-1:0][PTR_W:0] count_q;  // 0..DEPTH

  logic [HID_W-1:0] hsel;
  assign hsel = hart_i[HID_W-1:0];

  assign empty_o = (count_q[hsel] == '0);
  assign full_o  = (count_q[hsel] == DEPTH[PTR_W:0]);
  // Oldest (head) of the selected bank is what we restore / pop
  assign restore_ghist_o = mem_q[hsel][head_q[hsel]].ghist;
  assign restore_valid_o = restore_i && !empty_o;

  if (RAS_DEPTH == 0) begin : gen_no_ras
    assign restore_ras_valid_o = '0;
    assign restore_ras_ra_o    = '0;
  end else begin : gen_ras
    assign restore_ras_valid_o = mem_q[hsel][head_q[hsel]].ras_v;
    assign restore_ras_ra_o    = mem_q[hsel][head_q[hsel]].ras_ra;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      mem_q   <= '0;
    end else if (flush_i) begin
      // Flush only the selected bank (peer-hart checkpoints survive)
      head_q[hsel]  <= '0;
      tail_q[hsel]  <= '0;
      count_q[hsel] <= '0;
    end else begin
      if (push_i) begin
        mem_q[hsel][tail_q[hsel]].ghist <= push_ghist_i;
        if (RAS_DEPTH != 0) begin
          mem_q[hsel][tail_q[hsel]].ras_v  <= push_ras_valid_i;
          mem_q[hsel][tail_q[hsel]].ras_ra <= push_ras_ra_i;
        end else begin
          mem_q[hsel][tail_q[hsel]].ras_v  <= '0;
          mem_q[hsel][tail_q[hsel]].ras_ra <= '0;
        end
        tail_q[hsel] <= tail_q[hsel] + PTR_W'(1);
        if (full_o) begin
          head_q[hsel] <= head_q[hsel] + PTR_W'(1);  // drop oldest
        end else begin
          count_q[hsel] <= count_q[hsel] + (PTR_W+1)'(1);
        end
      end
      if (pop_i && !empty_o) begin
        head_q[hsel]  <= head_q[hsel] + PTR_W'(1);
        if (!(push_i && full_o)) count_q[hsel] <= count_q[hsel] - (PTR_W+1)'(1);
      end
    end
  end

endmodule
