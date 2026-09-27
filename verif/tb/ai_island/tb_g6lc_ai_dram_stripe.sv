// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Standalone smoke for the shared DRAM stripe helpers used by core L2 fills
// and island GEMM. Not LiteDRAM. Not a Variane cookie.

`timescale 1ns/1ps

module tb_g6lc_ai_dram_stripe;
  import g6lc_ai_island_cfg_pkg::*;

  int unsigned errors;

  initial begin
    errors = 0;

    if (!island_cfg_legal(AiIslandSimChans2)) begin
      $error("AiIslandSimChans2 illegal");
      errors++;
    end
    if (AiIslandSimChans2.DramClass != AI_DRAM_SIM_AXI) begin
      $error("SimChans2 must stay class 0");
      errors++;
    end
    if (AiIslandSimChans2.DramChannels != unsigned'(2)) begin
      $error("SimChans2 DramChannels");
      errors++;
    end
    if (AiIslandLatencyDefault.DramGBps != unsigned'(16) ||
        AiIslandLatencyDefault.ClockKhz != unsigned'(2_000_000)) begin
      $error("live class-0 nameplate must be 64-bit x 2 GHz = 16 GB/s");
      errors++;
    end
    if (AiIslandSimChans2.DramGBps != AiIslandLatencyDefault.DramGBps ||
        AiIslandSimChans2.DramGBps !=
        dram_nameplate_gbps(64, 2_000_000, 2, AI_DRAM_SIM_AXI)) begin
      $error("SimChans2 nameplate must stay the live NoC peak, not N times it");
      errors++;
    end
    if (!island_cfg_legal(AiIslandSimChans4) || AiIslandSimChans4.DramChannels != unsigned'(4)) begin
      $error("AiIslandSimChans4");
      errors++;
    end
    if (!island_cfg_legal(AiIslandSimChans8) || AiIslandSimChans8.DramChannels != unsigned'(8)) begin
      $error("AiIslandSimChans8");
      errors++;
    end
    if (!island_cfg_legal(AiIslandDdr4x4Bringup) ||
        AiIslandDdr4x4Bringup.DramGBps != unsigned'(4 * AI_DRAM_DDR4_2400_X64_GBPS)) begin
      $error("AiIslandDdr4x4Bringup 76 GB/s");
      errors++;
    end
    if (!island_cfg_legal(AiIslandDdr4x8Bringup) ||
        AiIslandDdr4x8Bringup.DramGBps != unsigned'(8 * AI_DRAM_DDR4_2400_X64_GBPS)) begin
      $error("AiIslandDdr4x8Bringup 152 GB/s");
      errors++;
    end

    // N=1: any burst fits (core/GEMM identity).
    if (!dram_burst_fits_stripe(1, 6, 64'h0, 2040)) begin
      $error("N=1 must accept long GEMM burst");
      errors++;
    end
    if (dram_beats_in_stripe(1, 6, 8, 64'h0) != unsigned'(255)) begin
      $error("N=1 beats must stay AXI4 cap 255");
      errors++;
    end

    // N=2, 64 B stripe, L2-class fill at line align.
    if (!dram_burst_fits_stripe(2, 6, 64'h0, 64)) begin
      $error("64 B from 0 must fit");
      errors++;
    end
    if (!dram_burst_fits_stripe(2, 6, 64'h40, 64)) begin
      $error("64 B from 0x40 must fit");
      errors++;
    end
    if (dram_burst_fits_stripe(2, 6, 64'h0, 65)) begin
      $error("65 B from 0 must straddle");
      errors++;
    end

    // L1 16 B at 0x30 stays in stripe 0.
    if (!dram_burst_fits_stripe(2, 6, 64'h30, 16)) begin
      $error("16 B from 0x30 must fit");
      errors++;
    end
    if (dram_burst_fits_stripe(2, 6, 64'h30, 17)) begin
      $error("17 B from 0x30 must straddle");
      errors++;
    end

    if (dram_beats_in_stripe(2, 6, 8, 64'h0) != unsigned'(8)) begin
      $error("beats from 0: expect 8");
      errors++;
    end
    if (dram_beats_in_stripe(2, 6, 8, 64'h30) != unsigned'(2)) begin
      $error("beats from 0x30: expect 2");
      errors++;
    end
    if (dram_beats_in_stripe(2, 6, 8, 64'h40) != unsigned'(8)) begin
      $error("beats from 0x40: expect 8");
      errors++;
    end

    // Nameplate guards: never 400 on class 0/1; DDR4 is N×19; N power of two.
    begin
      automatic ai_island_cfg_t c;
      if (!island_cfg_legal(AiIslandLatencyDefault)) begin
        $error("live default illegal"); errors++;
      end
      if (!island_cfg_legal(AiIslandDdr4Bringup) ||
          AiIslandDdr4Bringup.DramGBps != unsigned'(AI_DRAM_DDR4_2400_X64_GBPS)) begin
        $error("DDR4 N=1 nameplate 19"); errors++;
      end
      c = AiIslandLatencyDefault;
      c.DramGBps = unsigned'(400);
      if (island_cfg_legal(c)) begin
        $error("class 0 must refuse 400 GB/s"); errors++;
      end
      c = AiIslandDdr4Bringup;
      c.DramGBps = unsigned'(400);
      if (island_cfg_legal(c)) begin
        $error("DDR4 must refuse 400 GB/s"); errors++;
      end
      c = AiIslandDdr4Bringup;
      c.DramGBps = AiIslandLatencyDefault.DramGBps;
      if (island_cfg_legal(c)) begin
        $error("DDR4 must refuse the class-0 NoC nameplate"); errors++;
      end
      c = AiIslandDdr4Bringup;
      c.DramClass = unsigned'(AI_DRAM_LPDDR5);
      c.DramGBps  = AiIslandLatencyDefault.DramGBps;
      if (island_cfg_legal(c)) begin
        $error("LPDDR5 must not reuse the class-0 NoC nameplate"); errors++;
      end
      c = AiIslandDdr4Bringup;
      c.DramChannels = unsigned'(3);
      if (island_cfg_legal(c)) begin
        $error("N=3 must be illegal"); errors++;
      end
      c = AiIslandDdr4Bringup;
      c.DramChanShift = unsigned'(2);
      if (island_cfg_legal(c)) begin
        $error("ChanShift 2 must be illegal"); errors++;
      end
      if (dram_aw_out(AiIslandLatencyDefault) != unsigned'(1)) begin
        $error("live dram_aw_out must stay 1"); errors++;
      end
      if (dram_aw_out(AiIslandSimChans2) != unsigned'(1)) begin
        $error("SIM_CHANS dram_aw_out must stay 1"); errors++;
      end
      if (dram_aw_out(AiIslandDdr4TimingSim) != unsigned'(AI_MAX_AR_OUT_DRAM)) begin
        $error("ai-dt dram_aw_out must be 8"); errors++;
      end
      if (dram_aw_out(AiIslandDdr4Bringup) != unsigned'(AI_MAX_AR_OUT_DRAM)) begin
        $error("CLASS1 dram_aw_out must be 8"); errors++;
      end
    end

    if (errors == 0) $display("PASS g6lc_ai_dram_stripe");
    else begin
      $display("FAIL g6lc_ai_dram_stripe errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
