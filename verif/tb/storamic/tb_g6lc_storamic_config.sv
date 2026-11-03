// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_storamic_config #(parameter bit BadGeometry = 1'b0);
  localparam config_pkg::cva6_cfg_t Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  initial begin
    config_pkg::cva6_cfg_t checked_cfg;
    checked_cfg = Cfg;
    if (BadGeometry) checked_cfg.AxiIdWidth = 0;
    config_pkg::check_cfg(checked_cfg);
    assert (!cva6_config_pkg::cva6_cfg.StoramicEn)
      else $fatal(1, "STORAMIC_TARGET_NOT_DEFAULT_OFF");
`ifdef G6LC_STORAMIC
    assert (Cfg.StoramicEn) else $fatal(1, "STORAMIC_OVERLAY_NOT_PROPAGATED");
`else
    assert (!Cfg.StoramicEn) else $fatal(1, "STORAMIC_DEFAULT_NOT_PROPAGATED");
`endif
    $display("STORAMIC_CORE_CONFIG_PASS");
    $finish;
  end
endmodule
