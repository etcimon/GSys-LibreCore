// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 global LR/SC reservation tracker — multi-core atomics contention.
//
// RISC-V LR/SC: a remote store/AMO to the reserved line must kill other cores'
// reservations. This is the cluster view (one slot per core) that drives kill
// / inv hints — not a replacement for the core-local reservation bit.
//
// Contention optimisations:
//   * O(1) per-core slot (no CAM for "my reservation?")
//   * One-cycle line match kill across all cores
//   * SC probe returns ok/fail without side effects until store_valid commits

module g6lc_lr_sc_tracker
  import g6lc_coherence_pkg::*;
#(
    parameter int unsigned NR_CORES   = 1,
    parameter int unsigned LINE_BYTES = COH_DEFAULT_LINE_BYTES,
    parameter int unsigned ADDR_WIDTH = 64
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic                       lr_valid_i,
    input  logic [ADDR_WIDTH-1:0]      lr_addr_i,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] lr_core_i,
    input  logic                       store_valid_i,
    input  logic [ADDR_WIDTH-1:0]      store_addr_i,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] store_core_i,
    input  logic                       store_is_sc_i,
    input  logic                       sc_probe_i,
    input  logic [ADDR_WIDTH-1:0]      sc_addr_i,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] sc_core_i,
    output logic                       sc_ok_o,
    output logic [NR_CORES-1:0]        kill_cores_o,
    output logic [55:0]                kill_line_o,
    output logic                       kill_valid_o,
    output logic                       lr_set_o,
    output logic                       sc_fail_o
);

  localparam int unsigned NC    = (NR_CORES < 1) ? 1 : NR_CORES;
  localparam int unsigned CID_W = (NC <= 1) ? 1 : $clog2(NC);
  localparam int unsigned OFF   = $clog2(LINE_BYTES);

  logic        valid_q[NC], valid_d[NC];
  logic [55:0] line_q[NC], line_d[NC];

  logic [55:0] lr_line, st_line, sc_line;
  assign lr_line = lr_addr_i[ADDR_WIDTH-1:OFF];
  assign st_line = store_addr_i[ADDR_WIDTH-1:OFF];
  assign sc_line = sc_addr_i[ADDR_WIDTH-1:OFF];

  always_comb begin
    for (int unsigned c = 0; c < NC; c++) begin
      valid_d[c] = valid_q[c];
      line_d[c]  = line_q[c];
    end
    kill_cores_o = '0;
    kill_line_o  = '0;
    kill_valid_o = 1'b0;
    lr_set_o     = 1'b0;
    sc_fail_o    = 1'b0;
    sc_ok_o      = 1'b0;

    if (sc_probe_i) begin
      sc_ok_o = valid_q[sc_core_i] && (line_q[sc_core_i] == sc_line);
      if (!sc_ok_o) sc_fail_o = 1'b1;
    end

    if (lr_valid_i) begin
      valid_d[lr_core_i] = 1'b1;
      line_d[lr_core_i]  = lr_line;
      lr_set_o           = 1'b1;
    end

    if (store_valid_i) begin
      kill_line_o = st_line;
      for (int unsigned c = 0; c < NC; c++) begin
        if (valid_q[c] && line_q[c] == st_line) begin
          if (c[CID_W-1:0] != store_core_i || store_is_sc_i) begin
            valid_d[c]      = 1'b0;
            kill_cores_o[c] = 1'b1;
            kill_valid_o    = 1'b1;
          end
        end
      end
      if (store_is_sc_i) valid_d[store_core_i] = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned c = 0; c < NC; c++) begin
        valid_q[c] <= 1'b0;
        line_q[c]  <= '0;
      end
    end else begin
      for (int unsigned c = 0; c < NC; c++) begin
        valid_q[c] <= valid_d[c];
        line_q[c]  <= line_d[c];
      end
    end
  end

endmodule
