// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_origin_profile;
  import config_pkg::*;
  cva6_cfg_t cfg;
  int checks = 0;
  task automatic check(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "ORIGIN_PROFILE_FAIL %s", label);
  endtask
  function automatic cva6_cfg_t scalar();
    cva6_cfg_t c = cva6_cfg_empty;
    c.StoramicEn = 1;
    c.StoramicIoEn = 1;
    c.StoramicCheckpointEn = 1;
    c.NrHarts = 1;
    c.DCacheType = WT;
    c.CoproType = COPRO_NONE;
    return c;
  endfunction
  initial begin
    logic [2:0] expected;
    cfg = scalar();
    check(g6lc_storamic_origin_supported(cfg), "scalar");
    cfg.EnableAccelerator = 1;
    check(!g6lc_storamic_origin_supported(cfg), "shared-accelerator-writer");
    cfg = scalar(); cfg.CoproType = COPRO_EXAMPLE;
    check(!g6lc_storamic_origin_supported(cfg), "example-unqualified");
    cfg = scalar(); cfg.CoproType = COPRO_G6LC_AI;
    check(!g6lc_storamic_origin_supported(cfg), "ai-unqualified");
    cfg = scalar(); cfg.CvxifEn = 1;
    check(g6lc_storamic_origin_supported(cfg), "empty-cvxif-is-not-a-writer");
    cfg = scalar(); cfg.StoramicCheckpointEn = 0;
    check(!g6lc_storamic_origin_supported(cfg), "off");
    cfg = scalar(); cfg.StoramicEn = 0;
    check(!g6lc_storamic_origin_supported(cfg), "no-primary");
    cfg = scalar(); cfg.StoramicIoEn = 0;
    check(!g6lc_storamic_origin_supported(cfg), "no-io");
    cfg = scalar(); cfg.NrHarts = 2;
    check(!g6lc_storamic_origin_supported(cfg), "smt-unqualified");
    cfg = scalar(); cfg.OoOEn = 1;
    check(!g6lc_storamic_origin_supported(cfg), "ooo-unqualified");
    cfg = scalar(); cfg.RVH = 1;
    check(!g6lc_storamic_origin_supported(cfg), "virtual-unqualified");
    cfg = scalar(); cfg.DCacheType = WB;
    check(!g6lc_storamic_origin_supported(cfg), "wb-unqualified");
    for (int p = 0; p < 4; p++)
      for (int v = 0; v < 2; v++)
        for (int d = 0; d < 2; d++) begin
          expected = '0;
          if (v == 0 && d == 0)
            case (p)
              0: expected = 3'b010;
              1: expected = 3'b011;
              3: expected = 3'b001;
              default: expected = '0;
            endcase
          check(g6lc_storamic_data_prot(2'(p), 1'(v), 1'(d)) == expected,
                "explicit-data-context");
        end
    if ($test$plusargs("oracle_debug"))
      check(g6lc_storamic_data_prot(2'b11, 0, 1) == 3'b001,
            "negative-debug-authority");
    if ($test$plusargs("oracle_negative")) begin
      cfg = scalar(); cfg.EnableAccelerator = 1;
      check(g6lc_storamic_origin_supported(cfg), "negative-shared-writer");
    end
    $display("ORIGIN_PROFILE_PASS checks=%0d", checks);
    $finish;
  end
endmodule
