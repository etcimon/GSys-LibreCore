// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// RVA23 named PMAs that the live core already implements:
//   Ziccif  — aligned ILEN fetch is a contiguous slice of one I$ line
//             (g6lc_icache refills the whole line before it is valid and
//             ignores PC[1:0]; cl_sel is the same indexed part-select).
//   Ziccrse — RsrvEventual on cacheable+coherent: aligned word/dword LR/SC
//             (g6lc_axi_lrsc exact-address set).
//   Ziccamoa — AMO atomicity on those regions: aligned W/D AMOs (misaligned
//             AMOs still trap even with RVZicclsm).
// Off-config: predicates stay low; fetch extract still returns the slice.

module g6lc_pma_zi #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned LINE_W = 128
) (
    input  logic [LINE_W-1:0] line_i,
    input  logic [31:0]       fetch_off_i,
    output logic [31:0]       fetch_instr_o,
    output logic              fetch_aligned_o,
    output logic              ziccif_ok_o,
    input  logic [63:0]       rsrv_addr_i,
    input  logic [3:0]        rsrv_size_i,
    output logic              reservable_o,
    output logic              ziccrse_ok_o,
    input  logic [63:0]       amo_addr_i,
    input  logic [3:0]        amo_size_i,
    output logic              amo_aligned_o,
    output logic              ziccamoa_ok_o
);

  localparam int unsigned NWORDS = LINE_W / 32;
  localparam int unsigned WSEL_W = (NWORDS <= 1) ? 1 : $clog2(NWORDS);

  logic [WSEL_W-1:0] wsel;
  assign wsel = fetch_off_i[2+:WSEL_W];
  assign fetch_aligned_o = (fetch_off_i[1:0] == 2'b00);
  assign fetch_instr_o = line_i[{wsel, 5'b0}+:32];
  assign ziccif_ok_o = CVA6Cfg.RVZiccif && (LINE_W >= 32);

  wire rsrv_sz_w = (rsrv_size_i == 4'd4);
  wire rsrv_sz_d = (rsrv_size_i == 4'd8);
  wire rsrv_aln = rsrv_sz_w ? (rsrv_addr_i[1:0] == 2'b00)
                            : (rsrv_sz_d && (rsrv_addr_i[2:0] == 3'b000));
  assign ziccrse_ok_o = CVA6Cfg.RVZiccrse && CVA6Cfg.RVA;
  assign reservable_o = ziccrse_ok_o && (rsrv_sz_w || rsrv_sz_d) && rsrv_aln;

  wire amo_sz_w = (amo_size_i == 4'd4);
  wire amo_sz_d = (amo_size_i == 4'd8);
  assign amo_aligned_o = amo_sz_w ? (amo_addr_i[1:0] == 2'b00)
                                  : (amo_sz_d && (amo_addr_i[2:0] == 3'b000));
  assign ziccamoa_ok_o = CVA6Cfg.RVZiccamoa && CVA6Cfg.RVA;

endmodule
