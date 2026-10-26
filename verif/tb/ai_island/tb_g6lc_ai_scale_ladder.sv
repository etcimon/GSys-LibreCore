// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Scaling-ladder SKU legality and nameplate check (L1 of the latency ladder: an
// illegal or mis-sized SKU literal fails here, at elaboration, not in a SoC build).
// The peaks are the scaling-100tops.md s2 definition (dense INT8, 2 ops/MAC),
// evaluated from the literals: nameplates, not measurements.
module tb_g6lc_ai_scale_ladder;
  import g6lc_ai_island_cfg_pkg::*;
  initial begin
    int fails;
    fails = 0;
    // Legality of every ladder step and of the live default.
    if (!island_cfg_legal(AiIslandLatencyDefault)) begin $display("FAIL legal LatencyDefault"); fails++; end
    if (!island_cfg_legal(AiIslandV1WidePort))     begin $display("FAIL legal V1"); fails++; end
    if (!island_cfg_legal(AiIslandV2ColumnArray))  begin $display("FAIL legal V2"); fails++; end
    if (!island_cfg_legal(AiIslandV3Quad))         begin $display("FAIL legal V3"); fails++; end
    if (!island_cfg_legal(AiIslandV4Octo))         begin $display("FAIL legal V4"); fails++; end
    // Column count per cycle derived from MacsPerCycle / AccTileK.
    if (island_cfg_out_cols(AiIslandLatencyDefault) != 1) begin $display("FAIL cols live"); fails++; end
    if (island_cfg_out_cols(AiIslandV1WidePort) != 1)     begin $display("FAIL cols V1"); fails++; end
    if (island_cfg_out_cols(AiIslandV2ColumnArray) != 8)  begin $display("FAIL cols V2"); fails++; end
    if (island_cfg_out_cols(AiIslandV4Octo) != 8)         begin $display("FAIL cols V4"); fails++; end
    // Nameplates (milli-TOPS, INT8 dense).
    if (sketch_milli_tops(AiIslandLatencyDefault, 0) != 2048)  begin $display("FAIL tops live %0d", sketch_milli_tops(AiIslandLatencyDefault, 0)); fails++; end
    if (sketch_milli_tops(AiIslandV1WidePort, 0) != 2048)      begin $display("FAIL tops V1"); fails++; end
    if (sketch_milli_tops(AiIslandV2ColumnArray, 0) != 16384)  begin $display("FAIL tops V2 %0d", sketch_milli_tops(AiIslandV2ColumnArray, 0)); fails++; end
    if (sketch_milli_tops(AiIslandV3Quad, 0) != 49152)         begin $display("FAIL tops V3 %0d", sketch_milli_tops(AiIslandV3Quad, 0)); fails++; end
    if (sketch_milli_tops(AiIslandV4Octo, 0) != 98304)         begin $display("FAIL tops V4 %0d", sketch_milli_tops(AiIslandV4Octo, 0)); fails++; end
    // Bytes per cycle and machine balance (MAC per byte) of each step.
    $display("LADDER live  bytes/cy=%0d macs/cy=%0d balance=%0d", AiIslandLatencyDefault.NocWidth/8, AiIslandLatencyDefault.MacsPerCycle, AiIslandLatencyDefault.MacsPerCycle/(AiIslandLatencyDefault.NocWidth/8));
    $display("LADDER V1    bytes/cy=%0d macs/cy=%0d balance=%0d", AiIslandV1WidePort.NocWidth/8, AiIslandV1WidePort.MacsPerCycle, AiIslandV1WidePort.MacsPerCycle/(AiIslandV1WidePort.NocWidth/8));
    $display("LADDER V2    bytes/cy=%0d macs/cy=%0d balance=%0d", AiIslandV2ColumnArray.NocWidth/8, AiIslandV2ColumnArray.MacsPerCycle, AiIslandV2ColumnArray.MacsPerCycle/(AiIslandV2ColumnArray.NocWidth/8));
    $display("LADDER V3    clusters=%0d milli_tops=%0d dram_gbps=%0d", AiIslandV3Quad.Clusters, sketch_milli_tops(AiIslandV3Quad, 0), AiIslandV3Quad.DramGBps);
    $display("LADDER V4    clusters=%0d milli_tops=%0d dram_gbps=%0d", AiIslandV4Octo.Clusters, sketch_milli_tops(AiIslandV4Octo, 0), AiIslandV4Octo.DramGBps);
    // r68: the four SKU steps per numeric format, and the bandwidth balance
    // (numeric-formats-datapath.md §2): required DRAM GB/s at the step's peak
    // = mac_rate * 2*w/T with T = the live 512 blocking. INT4/INT8/FP8 must fit
    // the step's DramGBps nameplate; BF16/FP16/FP32 are declared half/quarter
    // rate by the sketch itself, so their ratios are the checked quantity.
    begin
      ai_island_cfg_t steps [4];
      string          names [4];
      int unsigned    fmts  [6] = '{1, 0, 3, 6, 5, 7};   // INT4 INT8 FP8e4m3 BF16 FP16 FP32
      int unsigned    wq    [6] = '{1, 2, 2, 4, 4, 8};   // element bytes * 2 (INT4 = 0.5 B)
      string          fname [6] = '{"int4", "int8", "fp8", "bf16", "fp16", "fp32"};
      steps = '{AiIslandV1WidePort, AiIslandV2ColumnArray, AiIslandV3Quad, AiIslandV4Octo};
      names = '{"V1", "V2", "V3", "V4"};
      for (int s = 0; s < 4; s++) begin
        for (int f = 0; f < 6; f++) begin
          longint unsigned milli, mac_per_s, bw_mbps;
          milli = sketch_milli_tops(steps[s], fmts[f]);
          // MAC/s = TOPS/2; bytes/MAC = 2w/T; GB/s*1000 = MAC/s * 2w / T / 1e6
          mac_per_s = (milli * 1000000000) / 2;                 // milli-TOPS -> MAC/s
          bw_mbps   = (mac_per_s * wq[f]) / (2 * AI_LIVE_MACS) / 1000000;   // MB/s
          $display("LADDER %s %-4s milli_tops=%0d req_dram_mbps=%0d nameplate_gbps=%0d",
                   names[s], fname[f], milli, bw_mbps, steps[s].DramGBps);
          // the formats that must run at INT8-equivalent speed fit the nameplate
          if (f < 3 && bw_mbps > steps[s].DramGBps * 1000) begin
            $display("FAIL %s %s needs %0d MB/s > %0d GB/s nameplate", names[s], fname[f], bw_mbps, steps[s].DramGBps);
            fails++;
          end
        end
        // derived ratio table must hold on every step
        if (sketch_milli_tops(steps[s], 1) != 2 * sketch_milli_tops(steps[s], 0)) begin $display("FAIL %s int4 ratio", names[s]); fails++; end
        if (sketch_milli_tops(steps[s], 3) != sketch_milli_tops(steps[s], 0))     begin $display("FAIL %s fp8 ratio", names[s]); fails++; end
        if (sketch_milli_tops(steps[s], 6) != sketch_milli_tops(steps[s], 0) / 2) begin $display("FAIL %s bf16 ratio", names[s]); fails++; end
        if (sketch_milli_tops(steps[s], 7) != sketch_milli_tops(steps[s], 0) / 4) begin $display("FAIL %s fp32 ratio", names[s]); fails++; end
      end
      // the 100-TOPS definition (scaling-100tops.md §2): dense INT8, MAC=2 ops
      if (sketch_milli_tops(AiIslandV4Octo, 0) < 98000) begin $display("FAIL V4 below the 100-TOPS class"); fails++; end
      if (sketch_milli_tops(AiIslandV4Octo, 1) != 2 * sketch_milli_tops(AiIslandV4Octo, 0)) begin $display("FAIL V4 INT4 effective"); fails++; end
    end

    // A deliberately illegal step must be refused (the check can say no).
    begin
      ai_island_cfg_t bad;
      bad = AiIslandV2ColumnArray;
      bad.MacsPerCycle = 3 * AI_LIVE_MACS;  // 3 columns: not a power of two
      if (island_cfg_legal(bad)) begin $display("FAIL negative: 3 columns accepted"); fails++; end
    end
    if (fails == 0) $display("PASS tb_g6lc_ai_scale_ladder");
    else $display("FAIL tb_g6lc_ai_scale_ladder fails=%0d", fails);
    $finish;
  end
endmodule
