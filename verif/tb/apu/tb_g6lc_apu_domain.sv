// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_domain;
  import g6lc_apu_cfg_pkg::*;
  int errors = 0, checks = 0;

  function automatic config_pkg::cva6_cfg_t dual();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t smt2();
    config_pkg::cva6_cfg_t cfg = dual();
    cfg.NrHarts = 2;
    return cfg;
  endfunction
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  initial begin
    apu_cfg_t cfg, bad;
    cfg = ApuHarness;

    check("ApuOff domain is legal", apu_domain_legal(ApuOff, dual()));
    check("ApuHarness domain is legal", apu_domain_legal(cfg, dual()));
    check("SMT2 firmware reservation is rejected", !apu_domain_legal(cfg, smt2()));
    check("single-core firmware reservation is rejected",
          !apu_soc_legal(cfg, config_pkg::cva6_cfg_t'(0)));

    check("RAM order 18", apu_region_order(cfg.FirmwareRamBytes) == 18);
    check("control order 12", apu_region_order(cfg.ControlLength) == 12);
    check("guest order 12", apu_region_order(cfg.MmioLength) == 12);
    check("RAM NAPOT", apu_pmp_napot(cfg.FirmwareRamBase, cfg.FirmwareRamBytes)
          == 64'h2400_7fff);
    check("control NAPOT", apu_pmp_napot(cfg.ControlBase, cfg.ControlLength)
          == 64'h1000_09ff);
    check("firmware hart is 1", cfg.FirmwareHart == 1);
    check("guest is not firmware RAM",
          !apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                              cfg.MmioBase, cfg.MmioLength));
    check("control is not guest",
          !apu_ranges_overlap(cfg.MmioBase, cfg.MmioLength,
                              cfg.ControlBase, cfg.ControlLength));
    check("GPIO/AI is not an APU window",
          !apu_ranges_overlap(cfg.MmioBase, cfg.MmioLength,
                              64'h4000_0000, 64'h1000));
    check("1GiB DRAM hole",
          apu_dram_hole_legal(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                              64'h8000_0000, 64'h4000_0000));
    check("512MiB DRAM hole",
          apu_dram_hole_legal(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                              64'h8000_0000, 64'h2000_0000));
    check("RAM at DRAM base is not a hole",
          !apu_dram_hole_legal(64'h8000_0000, cfg.FirmwareRamBytes,
                               64'h8000_0000, 64'h4000_0000));
    check("RAM past DRAM is not a hole",
          !apu_dram_hole_legal(64'hC000_0000, cfg.FirmwareRamBytes,
                               64'h8000_0000, 64'h4000_0000));
    check("hart 0 boots ROM",
          apu_core_boot_addr(cfg, 0, 64'h1_0000) == 64'h1_0000);
    check("hart 1 boots firmware RAM",
          apu_core_boot_addr(cfg, 1, 64'h1_0000) == 64'h9000_0000);
    check("ApuOff keeps ROM",
          apu_core_boot_addr(ApuOff, 1, 64'h1_0000) == 64'h1_0000);
    check("boot split is legal",
          apu_boot_split_legal(cfg, dual(), 64'h1_0000));
    check("firmware boot alias of ROM is rejected",
          !apu_boot_split_legal(cfg, dual(), 64'h9000_0000));

    bad = cfg;
    bad.FirmwareRamBase = 64'h9000_1000;
    check("unaligned firmware RAM is rejected", !apu_domain_legal(bad, dual()));
    bad = cfg;
    bad.FirmwareRamBytes = 64'h20000;
    check("undersized firmware RAM is rejected", !apu_domain_legal(bad, dual()));
    bad = cfg;
    bad.FirmwareRamBase = 64'h4000_2000;
    check("RAM overlapping control is rejected", !apu_domain_legal(bad, dual()));
    bad = cfg;
    bad.MmioBase = 64'h4000_0000;
    check("guest alias of GPIO/AI is rejected", !apu_domain_legal(bad, dual()));

    if (errors != 0) $fatal(1, "APU domain errors=%0d", errors);
    $display("PASS tb_g6lc_apu_domain checks=%0d errors=0", checks);
    $finish;
  end
endmodule
