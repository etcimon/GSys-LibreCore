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
    // ST-008C: ProfileMapped contract legality.
    assert (g6lc_storamic_cfg_pkg::cfg_legal(
        g6lc_storamic_cfg_pkg::StoramicMapped))
      else $fatal(1, "STORAMIC_MAPPED_LEGAL");
    assert (!g6lc_storamic_cfg_pkg::cfg_legal('{
        Enable: 1'b0, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
        MaxSticks: 1, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0}))
      else $fatal(1, "STORAMIC_MAPPED_DISABLE");
    assert (!g6lc_storamic_cfg_pkg::cfg_legal('{
        Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
        MaxSticks: 1, RequestedMediaCaps: '0, ModelBase: '0,
        ModelBytes: 64'd65536}))
      else $fatal(1, "STORAMIC_MAPPED_MODELBYTES");
    assert (!g6lc_storamic_cfg_pkg::cfg_legal('{
        Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
        MaxSticks: 0, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0}))
      else $fatal(1, "STORAMIC_MAPPED_STICKS0");
    assert (!g6lc_storamic_cfg_pkg::cfg_legal('{
        Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
        MaxSticks: 9, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0}))
      else $fatal(1, "STORAMIC_MAPPED_STICKS9");
    $display("STORAMIC_CORE_CONFIG_PASS");
    $finish;
  end
endmodule
