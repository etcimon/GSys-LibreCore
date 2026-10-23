// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_hyp_pkg — the hyp8 configuration seam.
//
// One struct carries every knob the 8-FO4 redesign turns: stage counts,
// banking factors and protocol variants introduced by the `// hyp8:` edits.
// HypDefault reproduces the pre-redesign behaviour; Hyp8 is the 8-FO4
// (5 GHz nameplate, fo4_ps = 20, margin 0.2) operating point. Every value
// is indicative (analysis/*.md); nothing here has been linted or simulated.
//
// Consumers take `parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg =
// g6lc_hyp_pkg::Hyp8` and read fields — no dependency on g6lc_core_pkg.

package g6lc_hyp_pkg;

  typedef struct packed {
    // ALU: number of result stages on the value path (execute.md).
    int unsigned AluStages;
    // ALU: low 32-bit half of add/logic results in stage 1 and forwardable
    // next cycle; high half in stage 2 (execute.md).
    bit AluStaggered;
    // Rename: pipeline stages through map/freelist (g6lc_rename.md).
    int unsigned RenameStages;
    // Rename: freelist bank count (g6lc_rename.md).
    int unsigned FreelistBanks;
    // Issue queue: number of banks (g6lc_iq.md).
    int unsigned IqBanks;
    // Issue queue: entries per bank; 0 = flat single queue (g6lc_iq.md).
    int unsigned IqBankEntries;
    // Issue queue: speculative wakeup depth 0/1/2 (g6lc_iq.md).
    int unsigned IqSpecWakeup;
    // Issue queue: bank steering on dispatch (g6lc_iq.md).
    bit IqSteer;
    // Frontend: untagged next-line target buffer (frontend.md).
    bit FeNextlineUntagged;
    // Frontend: next-line buffer entries (frontend.md).
    int unsigned FeNextlineEntries;
    // Frontend: mid-decode predictor override path (frontend.md).
    bit FeOverridePred;
    // Frontend: epoch/tag bits for redirect filtering (frontend.md).
    int unsigned FeEpochBits;
    // LSU: extra load-use delay cycles added to the contract (g6lc_lsq.md).
    int unsigned LoadUseExtra;
    // Store buffer: store->load forward latency in cycles
    // (store_buffer.md / g6lc_lsq.md).
    int unsigned StoreFwdCycles;
    // LSU request AGU: 1 = legacy same-cycle operand_a+imm add;
    // 2 = staggered low/high add (A1 capture, A2 record formation).
    int unsigned LsuAguStages;
    // Dcache: extra hit latency cycles (tier2_tier3.md wt_dcache*).
    int unsigned DcacheHitExtra;
    // Commit: bundle staging registers before writeback
    // (tier2_tier3.md commit_stage).
    int unsigned CommitBundleStages;
    // Writeback: capture stage on the scoreboard publish (scoreboard.md).
    int unsigned WbCaptureStages;
    // Writeback: result-lane reservation table (scoreboard.md).
    bit WbReserve;
    // Writeback: result lane count; 0 = legacy single bus (scoreboard.md).
    int unsigned WbLanes;
    // Multiplier: stage-count override; 0 = keep config MultStages
    // (execute.md multiplier).
    int unsigned MultStagesOverride;
    // Decode: stages through the decode group (t1_rest.md decode group).
    int unsigned DecodeStages;
    // CSR: read-side staging (csr_regfile.md).
    int unsigned CsrReadStages;
    // MMU/TLB: lookup staging through the TLBs (t1_rest.md g6lc_tlb/mmu).
    int unsigned TlbStages;
    // FPU: latency override on, use package fp latencies (t1_rest.md fpu_wrap).
    bit FpuLatOverride;
    // LSQ: CAM/age-check banking factor (g6lc_lsq.md).
    int unsigned LsqCamBanks;
    // Write buffer: pipelined drain path (wt_dcache_wbuffer.md).
    bit WbufPipelined;
  } g6lc_hyp_cfg_t;

  // Pre-redesign behaviour: single stages, no banking, no overrides.
  localparam g6lc_hyp_cfg_t HypDefault = '{
      AluStages: 1,
      AluStaggered: 1'b0,
      RenameStages: 1,
      FreelistBanks: 1,
      IqBanks: 1,
      IqBankEntries: 0,
      IqSpecWakeup: 0,
      IqSteer: 1'b0,
      FeNextlineUntagged: 1'b0,
      FeNextlineEntries: 0,
      FeOverridePred: 1'b0,
      FeEpochBits: 0,
      LoadUseExtra: 0,
      StoreFwdCycles: 1,
      LsuAguStages: 1,
      DcacheHitExtra: 0,
      CommitBundleStages: 0,
      WbCaptureStages: 0,
      WbReserve: 1'b0,
      WbLanes: 0,
      MultStagesOverride: 0,
      DecodeStages: 1,
      CsrReadStages: 1,
      TlbStages: 1,
      FpuLatOverride: 1'b0,
      LsqCamBanks: 1,
      WbufPipelined: 1'b0
  };

  // The 8-FO4 operating point.
  // hyp8 r5: AluStages==3 -- the LAT_ALU_FULL (shift/compare/full-op)
  // result completes in the A3 stage three cycles after fu_data_i, while
  // LAT_ALU_LOW add/logic results keep their A1-low forward at distance 1
  // and their A2 writeback slot at distance 2.
  localparam g6lc_hyp_cfg_t Hyp8 = '{
      AluStages: 3,
      AluStaggered: 1'b1,
      RenameStages: 3,
      FreelistBanks: 2,
      IqBanks: 8,
      IqBankEntries: 4,
      // Stalled-IRO WbReserve profile: speculative wakeup is OFF -- the
      // consumer wakes on the registered real-WB capture only. Retained
      // speculation (IqSpecWakeup!=0) is not falsely qualified: the
      // reservation gate was not designed to cover spec-broadcast
      // producers, so the legality below binds the pair.
      IqSpecWakeup: 0,
      IqSteer: 1'b1,
      FeNextlineUntagged: 1'b1,
      FeNextlineEntries: 256,
      FeOverridePred: 1'b1,
      FeEpochBits: 3,
      LoadUseExtra: 2,
      StoreFwdCycles: 3,
      LsuAguStages: 2,
      DcacheHitExtra: 2,
      CommitBundleStages: 1,
      WbCaptureStages: 0,
      WbReserve: 1'b1,
      WbLanes: 6,
      MultStagesOverride: 0,
      DecodeStages: 3,
      CsrReadStages: 2,
      TlbStages: 3,
      FpuLatOverride: 1'b1,
      LsqCamBanks: 2,
      WbufPipelined: 1'b1
  };

  // Wakeup/contract latency classes used by scoreboard + functional units.
  typedef enum logic [2:0] {
    LAT_NONSPEC   = 0,  // non-speculative: wake on real writeback only
    LAT_ALU_LOW   = 1,  // single-cycle ALU result
    LAT_ALU_FULL  = 2,  // AluStages-deep ALU result
    LAT_MUL       = 3,  // multiplier, hyp_mult_stages deep
    LAT_LOAD      = 4,  // 2 + DcacheHitExtra + LoadUseExtra deep
    LAT_FP_FIXED  = 5   // fixed FP unit latency (fp_lat)
  } hyp_lat_class_e;

  // Multiplier stage count: explicit override wins, else the config base.
  function automatic int unsigned hyp_mult_stages(input g6lc_hyp_cfg_t h,
                                                  input int unsigned base);
    return (h.MultStagesOverride != 0) ? h.MultStagesOverride : base;
  endfunction

  // Cycles a consumer must wait for a produced value, by latency class.
  function automatic int unsigned hyp_lat_cycles(input g6lc_hyp_cfg_t h,
                                                 input hyp_lat_class_e c,
                                                 input int unsigned mult_stages,
                                                 input int unsigned fp_lat);
    case (c)
      LAT_ALU_LOW:   return 1;
      LAT_ALU_FULL:  return h.AluStages;
      LAT_MUL:       return mult_stages;
      LAT_LOAD:      return 2 + h.DcacheHitExtra + h.LoadUseExtra;
      LAT_FP_FIXED:  return fp_lat;
      default:       return 0;  // LAT_NONSPEC: wake on real writeback only
    endcase
  endfunction

  // Config legality; asserted in the config package under translate_off.
  function automatic bit hyp_cfg_ok(input g6lc_hyp_cfg_t h);
    bit ok;
    ok = 1'b1;
    ok &= !h.AluStaggered || (h.AluStages inside {2, 3});
    ok &= h.RenameStages inside {1, 2, 3};
    ok &= h.IqBanks >= 1;
    ok &= !(h.IqBanks > 1) || (h.IqBankEntries >= 2);
    ok &= h.IqSpecWakeup inside {0, 1, 2};
    // Stalled-IRO WbReserve admits only real-WB wakeup: a spec-broadcast
    // producer could still stall after grant, which the reservation model
    // forbids, so the two knobs may not combine.
    ok &= !h.WbReserve || (h.IqSpecWakeup == 0);
    ok &= h.StoreFwdCycles inside {1, 3};
    ok &= h.LsuAguStages inside {1, 2};
    // wt_dcache: the read ctrl/mems carry exactly the reference
    // single-cycle arm (0) and the staged T1/T2 arm (2).
    ok &= h.DcacheHitExtra inside {0, 2};
    ok &= h.CommitBundleStages <= 1;
    ok &= h.WbCaptureStages <= 1;
    ok &= h.DecodeStages inside {1, 3};
    ok &= h.CsrReadStages inside {1, 2};
    ok &= h.TlbStages inside {1, 3};
    ok &= !h.FeOverridePred || (h.FeEpochBits >= 2);
    ok &= h.LsqCamBanks >= 1;
    return ok;
  endfunction

endpackage
