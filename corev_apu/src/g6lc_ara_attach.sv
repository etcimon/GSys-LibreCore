// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U10ᵇ Ara attach — glue for one CVA6/ariane accelerator port pair.
//
// Live Ara IP requires `define CVA6_ARA_ATTACH and vendor/ara on the flist.
// Without the define, a stub elaborates (acc_resp tied, AXI idle).
//
// See architecture/ara-vector-attach.md.

module g6lc_ara_attach
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned NrLanes = 4,
    parameter int unsigned VLEN    = 4096,
    parameter int unsigned AxiAddrWidth = 64,
    parameter int unsigned AxiIdWidth   = 4,
    parameter int unsigned AxiNarrowDataWidth = 64,
    parameter int unsigned AxiWideDataWidth = 64 * NrLanes / 2,
    // Typed interfaces (must match ariane EnableAccelerator path)
    parameter type exception_t        = logic,
    parameter type accelerator_req_t  = logic,
    parameter type accelerator_resp_t = logic,
    parameter type acc_mmu_req_t      = logic,
    parameter type acc_mmu_resp_t     = logic,
    parameter type cva6_to_acc_t      = logic,
    parameter type acc_to_cva6_t      = logic,
    parameter type ara_axi_req_t  = logic,
    parameter type ara_axi_resp_t = logic,
    parameter type ara_axi_ar_t   = logic,
    parameter type ara_axi_r_t    = logic,
    parameter type ara_axi_aw_t   = logic,
    parameter type ara_axi_w_t    = logic,
    parameter type ara_axi_b_t    = logic
) (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         scan_enable_i,
    input  logic         scan_data_i,
    output logic         scan_data_o,
    input  cva6_to_acc_t acc_req_i,
    output acc_to_cva6_t acc_resp_o,
    output ara_axi_req_t  ara_axi_req_o,
    input  ara_axi_resp_t ara_axi_resp_i
);

  if (!CVA6Cfg.RVV && !CVA6Cfg.EnableAccelerator) begin : gen_off
    assign scan_data_o   = scan_data_i;
    assign acc_resp_o    = '0;
    assign ara_axi_req_o = '0;
  end else begin : gen_ara
`ifdef CVA6_ARA_ATTACH
    ara #(
        .NrLanes           (NrLanes),
        .VLEN              (VLEN),
        .CVA6Cfg           (CVA6Cfg),
        .exception_t       (exception_t),
        .accelerator_req_t (accelerator_req_t),
        .accelerator_resp_t(accelerator_resp_t),
        .acc_mmu_req_t     (acc_mmu_req_t),
        .acc_mmu_resp_t    (acc_mmu_resp_t),
        .cva6_to_acc_t     (cva6_to_acc_t),
        .acc_to_cva6_t     (acc_to_cva6_t),
        .AxiDataWidth      (AxiWideDataWidth),
        .AxiAddrWidth      (AxiAddrWidth),
        .axi_ar_t          (ara_axi_ar_t),
        .axi_r_t           (ara_axi_r_t),
        .axi_aw_t          (ara_axi_aw_t),
        .axi_w_t           (ara_axi_w_t),
        .axi_b_t           (ara_axi_b_t),
        .axi_req_t         (ara_axi_req_t),
        .axi_resp_t        (ara_axi_resp_t)
    ) i_ara (
        .clk_i,
        .rst_ni,
        .scan_enable_i,
        .scan_data_i,
        .scan_data_o,
        .acc_req_i,
        .acc_resp_o,
        .axi_req_o  (ara_axi_req_o),
        .axi_resp_i (ara_axi_resp_i)
    );
`else
    assign scan_data_o   = scan_data_i;
    assign acc_resp_o    = '0;
    assign ara_axi_req_o = '0;
    // pragma translate_off
    initial $info("g6lc_ara_attach: CVA6_ARA_ATTACH not defined — stub (no Ara IP).");
    // pragma translate_on
`endif
  end

endmodule
