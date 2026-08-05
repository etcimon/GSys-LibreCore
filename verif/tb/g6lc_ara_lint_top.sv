// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Lint/elab top for g6lc64_server_math_v:
// Instantiates **ariane** so the U10ᵇ EnableAccelerator path (typed acc
// interfaces + g6lc_ara_attach + optional CVA6_ARA_ATTACH live Ara AXI mux)
// is elaborated. Requires:
//   - TARGET_CFG=g6lc64_server_math_v
//   - vendor/ara/Flist.ara via verify.extraFlistsByTarget
//   - +define+CVA6_ARA_ATTACH when live Ara IP is on the flist
//
// See architecture/ara-vector-attach.md.

module g6lc_ara_lint_top
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg =
        build_config_pkg::build_config(cva6_config_pkg::cva6_cfg)
);
  logic clk_i, rst_ni;
  ariane_axi::req_t  noc_req;
  ariane_axi::resp_t noc_resp;
  assign noc_resp = '0;

  // RVFI probe type matching ariane defaults
  typedef struct packed {
    logic csr;
    logic [0:0] instr;  // unused in lint; real type comes from RVFI macros in sim TB
  } rvfi_probes_stub_t;

  // Use ariane's own rvfi parameter defaults by not overriding probe types.
  ariane #(
      .CVA6Cfg (CVA6Cfg)
  ) i_ariane (
      .clk_i,
      .rst_ni,
      .boot_addr_i      ('0),
      .hart_id_i        ('0),
      .irq_i            ('0),
      .ipi_i            ('0),
      .time_irq_i       ('0),
      .rtc_time_i       ('0),
      .debug_req_i      (1'b0),
      .rvfi_probes_o    (),
      .noc_req_o        (noc_req),
      .noc_resp_i       (noc_resp),
      .l1_inval_addr_i  ('0),
      .l1_inval_valid_i (1'b0),
      .l1_inval_ready_o (),
      .l2_miss_i        (1'b0),
      .l3_hit_i         (1'b0),
      .l3_miss_i        (1'b0),
      .pf_issue_i       (1'b0),
      .pf_train_i       (1'b0)
  );

endmodule
