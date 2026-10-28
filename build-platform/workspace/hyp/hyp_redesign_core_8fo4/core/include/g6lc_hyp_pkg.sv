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
    // Rename: 1 = single-cycle R2 resolve; 2 = RR-a compare register +
    // RR-b late-select (g6lc_rename.md, r43-T T1(b)).
    int unsigned RenameResolveStages;
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
    // PTW: 0 = single-cycle PTE verdict; 1 = registered decode bundle +
    // PTE_DECODE verdict state (r43-T T2).
    int unsigned PtwDecodeStage;
    // LSQ reduce: 1 = single R stage; 2 = R1 tournament + R2 publish
    // (r43-T T3). The wrapper's event-context pipeline extends to match.
    int unsigned LsqReduceStages;
    // IQ arb: 1 = CTL+GRN combinational; 2 = registered CTL outputs and
    // candidate snapshot feeding GRN/port-select (r43-T T7). Take moves
    // one cycle later; take-relative distances are unchanged.
    int unsigned IqArbStages;
    // FPU: latency override on, use package fp latencies (t1_rest.md fpu_wrap).
    bit FpuLatOverride;
    // LSQ: CAM/age-check banking factor (g6lc_lsq.md).
    int unsigned LsqCamBanks;
    // Write buffer: pipelined drain path (wt_dcache_wbuffer.md).
    bit WbufPipelined;
    // LSU L5: 1 = combinational publish pick; 2 = registered select
    // record (L5a) + presentation (L5b); load WB +1.
    int unsigned LoadPubStages;
    // LSU L5 exception publish: 1 = the same-cycle kill presents ex_i
    // directly (ex_pub arm); 2 = every exception completion pushes the
    // r51 pending record and presents +1 cycle. Fault path only.
    int unsigned LoadExPubStages;
    // IQ bank steer: 1 = same-cycle first fit; 2 = eligibility
    // registered at the bank update edge (design r76 §B2; not
    // implemented yet).
    int unsigned IqSteerStages;
    // IQ bank select/payload: 1 or 2 (design r69 P9; not implemented).
    int unsigned IqSelStages;
    // 1 or 2 (design r75 §4; not implemented).
    int unsigned RenameReadStages;
    // 1 or 2 (not implemented).
    int unsigned FreelistPickStages;
    // 1 or 2 (design r69 P7; not implemented).
    int unsigned StoreTransStages;
    // 1 or 2 (design r75 S4; not implemented).
    int unsigned TlbCtxStages;
    // 1 or 2 (design r69 P5; not implemented).
    int unsigned LsqVerdictStages;
    // 1 or 2 (not implemented).
    int unsigned CsrReadMuxStages;
    // 1 or 2 (not implemented).
    int unsigned CommitStages;
    // 1 or 3 (not implemented).
    int unsigned AesStages;
    // 1 or 2; 2 = the r75 formed-result register. Today's RTL registers
    // the formed AMO result unconditionally (wt_dcache_missunit
    // AMO_RESULT_FORM), so every profile binds 2 until the ==1 arm is
    // written.
    int unsigned MissunitResultStages;
  } g6lc_hyp_cfg_t;

  // Pre-redesign behaviour: single stages, no banking, no overrides.
  localparam g6lc_hyp_cfg_t HypDefault = '{
      AluStages: 1,
      AluStaggered: 1'b0,
      RenameStages: 1,
      RenameResolveStages: 1,
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
      PtwDecodeStage: 0,
      LsqReduceStages: 1,
      IqArbStages: 1,
      FpuLatOverride: 1'b0,
      LsqCamBanks: 1,
      WbufPipelined: 1'b0,
      LoadPubStages: 1,
      LoadExPubStages: 1,
      IqSteerStages: 1,
      IqSelStages: 1,
      RenameReadStages: 1,
      FreelistPickStages: 1,
      StoreTransStages: 1,
      TlbCtxStages: 1,
      LsqVerdictStages: 1,
      CsrReadMuxStages: 1,
      CommitStages: 1,
      AesStages: 1,
      // r76 note: wt_dcache_missunit registers the formed AMO result
      // unconditionally (AMO_RESULT_FORM), so even the pre-redesign
      // profile carries 2 — the ==1 arm does not exist yet.
      MissunitResultStages: 2
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
      RenameResolveStages: 2,
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
      // r42-T item 20 countercase: the gated implementation stays
      // (registered FLU publication record in ex_stage, mutant
      // G6LC_MUT_T2_WBCAP, counter `ex_stage wbcapture`) but OFF in
      // Hyp8 — the ex_stage row was 16.4 FO4 before and after, so the
      // record bought no structural gain while adding +1 cycle to every
      // fixed FLU class' dependence chain under IqSpecWakeup=0.
      // Re-enable only when the FLU publication mux sets the clock.
      // With the field at 0, ooo_flu_cycles returns the pre-r42
      // distances by construction (the +1 term is gated on the field).
      WbCaptureStages: 0,
      WbReserve: 1'b1,
      WbLanes: 6,
      MultStagesOverride: 0,
      DecodeStages: 3,
      CsrReadStages: 2,
      TlbStages: 3,
      PtwDecodeStage: 1,
      LsqReduceStages: 2,
      IqArbStages: 2,
      FpuLatOverride: 1'b1,
      LsqCamBanks: 2,
      WbufPipelined: 1'b1,
      LoadPubStages: 1,
      LoadExPubStages: 1,
      IqSteerStages: 1,
      IqSelStages: 1,
      RenameReadStages: 1,
      FreelistPickStages: 1,
      StoreTransStages: 1,
      TlbCtxStages: 1,
      LsqVerdictStages: 1,
      CsrReadMuxStages: 1,
      CommitStages: 1,
      AesStages: 1,
      // Same r76 note as HypDefault: the formed-result register is
      // unconditional in today's missunit.
      MissunitResultStages: 2
  };

  // r76 deep-publish profile: Hyp8 with LoadPubStages==2. The registered
  // L5 select record it names was implemented and measured as a
  // COUNTERCASE in r76 (analyze-r76-lu-deep: module 42.0 -> 47.0) and
  // reverted, so today no RTL arm reads the field: this profile builds
  // the same netlist as Hyp8 and only the LAT_LOAD / WAKE_LD sizing
  // terms (+1, inert under IqSpecWakeup==0) differ. It is kept as the
  // seam for the next load_unit stage attempt. The other new
  // stage-count fields keep their Hyp8 value because the RTL arms they
  // would gate do not exist yet (see each field's comment).
  localparam g6lc_hyp_cfg_t Hyp8Deep = '{
      AluStages: 3,
      AluStaggered: 1'b1,
      RenameStages: 3,
      RenameResolveStages: 2,
      FreelistBanks: 2,
      IqBanks: 8,
      IqBankEntries: 4,
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
      PtwDecodeStage: 1,
      LsqReduceStages: 2,
      IqArbStages: 2,
      FpuLatOverride: 1'b1,
      LsqCamBanks: 2,
      WbufPipelined: 1'b1,
      LoadPubStages: 2,
      LoadExPubStages: 2,
      IqSteerStages: 1,
      IqSelStages: 1,
      RenameReadStages: 1,
      FreelistPickStages: 1,
      StoreTransStages: 1,
      TlbCtxStages: 1,
      LsqVerdictStages: 1,
      CsrReadMuxStages: 1,
      CommitStages: 1,
      AesStages: 1,
      MissunitResultStages: 2
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
      LAT_LOAD:      return 2 + h.DcacheHitExtra + h.LoadUseExtra +
                           (h.LoadPubStages - 1);
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
    ok &= h.RenameResolveStages inside {1, 2};
    // The two-cycle resolve needs the staged rename (the RR-a register
    // sits inside the R2 kernel, which exists only under RenameStages 3).
    ok &= (h.RenameResolveStages == 1) || (h.RenameStages == 3);
    ok &= h.IqBanks >= 1;
    ok &= !(h.IqBanks > 1) || (h.IqBankEntries >= 2);
    ok &= h.IqSpecWakeup inside {0, 1, 2};
    // Stalled-IRO WbReserve admits only real-WB wakeup: a spec-broadcast
    // producer could still stall after grant, which the reservation model
    // forbids, so the two knobs may not combine.
    ok &= !h.WbReserve || (h.IqSpecWakeup == 0);
    // The legacy structural-hazard arm models only one-cycle FLU classes
    // (ALU/branch/CSR/AES write back at t+1) plus the T50 multiplier lag;
    // a staged ALU publishes past t+1 and needs the reservation model.
    ok &= h.WbReserve || (h.AluStages == 1);
    ok &= h.StoreFwdCycles inside {1, 3};
    ok &= h.LsuAguStages inside {1, 2};
    // wt_dcache: the read ctrl/mems carry exactly the reference
    // single-cycle arm (0) and the staged T1/T2 arm (2).
    ok &= h.DcacheHitExtra inside {0, 2};
    ok &= h.CommitBundleStages <= 1;
    // The publication record adds one cycle to every fixed FLU class; the
    // distance is carried only by the reservation model (the legacy
    // !WbReserve arm has fixed t+1 structural-hazard rules and cannot
    // absorb the extra edge).
    ok &= (h.WbCaptureStages == 0) || h.WbReserve;
    ok &= h.WbCaptureStages <= 1;
    ok &= h.DecodeStages inside {1, 3};
    ok &= h.CsrReadStages inside {1, 2};
    ok &= h.TlbStages inside {1, 3};
    ok &= h.PtwDecodeStage <= 1;
    ok &= h.LsqReduceStages inside {1, 2};
    ok &= h.IqArbStages inside {1, 2};
    ok &= !h.FeOverridePred || (h.FeEpochBits >= 2);
    ok &= h.LsqCamBanks >= 1;
    ok &= h.LoadPubStages inside {1, 2};
    ok &= h.LoadExPubStages inside {1, 2};
    ok &= h.IqSteerStages inside {1, 2};
    ok &= h.IqSelStages inside {1, 2};
    ok &= h.RenameReadStages inside {1, 2};
    ok &= h.FreelistPickStages inside {1, 2};
    ok &= h.StoreTransStages inside {1, 2};
    ok &= h.TlbCtxStages inside {1, 2};
    ok &= h.LsqVerdictStages inside {1, 2};
    ok &= h.CsrReadMuxStages inside {1, 2};
    ok &= h.CommitStages inside {1, 2};
    ok &= h.AesStages inside {1, 3};
    ok &= h.MissunitResultStages inside {1, 2};
    return ok;
  endfunction

endpackage
