// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// hyp8-mc configuration package: 4-core coherence-hub variant of the hyp8 profile.
// Derived from g6lc64_hyp8_config_pkg: identical except where a
// "// hyp8-mc:" note marks a departure (NrCores=4, NrIssuePorts=8, L2/L3 + snoop on).
// Derived from the out-of-order config package; every field is verbatim
// except where a `// hyp8:` note marks a departure. The target is 8 FO4 per
// cycle (5 GHz nameplate at fo4_ps = 20, margin 0.2) — indicative,
// un-linted, un-simulated. Redesign knobs live in g6lc_hyp_pkg and are
// bound into the design via the `HypCfg` localparam at the bottom.
// Copyright (c) 2026 Etienne Cimon
// Original Author: Jean-Roch COULON - Thales

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: hyp8 profile derived from the out-of-order config package template.
// Etienne Cimon offers this file AS A WHOLE under the dual licence below.
// Expressed as a non-SPDX tag because SPDX has no operator for "whole is X,
// portions remain Y"; the machine-readable form is in REUSE.toml.
// Outbound-License: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial


package g6lc_config_pkg;

  localparam G6LCConfigXlen = 64;

  localparam G6LCConfigRVF = 1;
  localparam G6LCConfigRVD = 1;
  localparam G6LCConfigF16En = 0;
  localparam G6LCConfigF16AltEn = 0;
  localparam G6LCConfigF8En = 0;
  localparam G6LCConfigFVecEn = 0;

  // 0: see g6lc64_smt2_config_pkg.sv -- CVXIF offload is issue-port-0 only, so
  // CvxifEn on a multi-issue core drops illegal-instruction exceptions.
  localparam G6LCConfigCvxifEn = 0;
  localparam G6LCConfigCExtEn = 1;
  localparam G6LCConfigZcbExtEn = 1;
  localparam G6LCConfigZcmpExtEn = 0;
  localparam G6LCConfigAExtEn = 1;
  localparam G6LCConfigHExtEn = 0;  // always disabled
  localparam G6LCConfigBExtEn = 1;
  localparam G6LCConfigVExtEn = 0;
  localparam G6LCConfigRVZiCond = 1;

  // hyp8 SMT2 integration seam: the default source profile stays
  // single-hart; -DG6LC_HYP8_SMT2 selects the two-hart configuration.
  localparam int unsigned G6LCConfigNrHarts = 2;  // hyp8-mc: dual-hart cores (4x2 = 8 harts)

  localparam G6LCConfigAxiIdWidth = 4;
  localparam G6LCConfigAxiAddrWidth = 64;
  localparam G6LCConfigAxiDataWidth = 64;
  localparam G6LCConfigFetchUserEn = 0;
  localparam G6LCConfigFetchUserWidth = G6LCConfigXlen;
  localparam G6LCConfigDataUserEn = 0;
  localparam G6LCConfigDataUserWidth = G6LCConfigXlen;

  localparam G6LCConfigIcacheByteSize = 16384;
  localparam G6LCConfigIcacheSetAssoc = 4;
  localparam G6LCConfigIcacheLineWidth = 128;
  localparam G6LCConfigDcacheByteSize = 32768;
  localparam G6LCConfigDcacheSetAssoc = 8;
  localparam G6LCConfigDcacheLineWidth = 128;

  localparam G6LCConfigDcacheFlushOnFence = 1'b0;
  localparam G6LCConfigDcacheFlushOnFenceI = 1'b0;
  localparam G6LCConfigDcacheInvalidateOnFlush = 1'b0;

  // 8 load-buffer entries need 3 bits of D\$ request id. At 1 the
  // load_unit assertion "DcacheIdWidth parameter is not wide enough to
  // encode pending loads" fires at time 0. g6lc64_smt2 already carries
  // this fix ("G1n: hang-7 raised NrLoadBufEntries to 8; 1-bit D\$ rid
  // truncated"); it was never propagated to the OoO packages, which
  // could not reach simulation to expose it.
  localparam G6LCConfigDcacheIdWidth = 5;  // hyp8-mc: NrLoadBufEntries floors at NrIssuePorts*4 = 32 (r71: 3 fired the time-0 assert on model2)
  localparam G6LCConfigMemTidWidth = 2;

  localparam G6LCConfigWtDcacheWbufDepth = 8;
  // T28 (2026-10-14): the SL-W post-ACK fixup queue is ON here as on smt2.
  // With depth 0 the L1-stale class is live on this WT package: OpenSBI's FDT
  // walk read a stack word 13 cycles after the store buffer handed its store
  // to the dcache and got the line's previous content (fw_platform_init
  // fail-wfi, Spike lockstep at retirement 6,537; prof-t28fst).
  // T34 (2026-10-14): the depth-2 queue's full-queue fallback is the prime
  // suspect for the two stale-read kernel oopses seen with T28-T33 in (a NULL
  // task->cgroups at 1 s, a half-written device_node pointer in of_irq_init);
  // the queue is the wbuffer depth so every in-flight write-through is fixed up.
  localparam G6LCConfigWtDcacheFixupDepth = 8;
  localparam G6LCConfigWtDcacheFixupVoidKeepEn = 1'b0;

  localparam G6LCConfigNrScoreboardEntries = 32;

  localparam G6LCConfigNrLoadPipeRegs = 1;
  localparam G6LCConfigNrStorePipeRegs = 0;
  localparam G6LCConfigNrLoadBufEntries = 8;

  localparam G6LCConfigRASDepth = 2;
  localparam G6LCConfigBTBEntries = 32;
  localparam G6LCConfigBHTEntries = 128;

  localparam G6LCConfigTvalEn = 1;

  localparam G6LCConfigNrPMPEntries = 8;

  localparam G6LCConfigPerfCounterEn = 1;

  localparam config_pkg::cache_type_t G6LCConfigDcacheType = config_pkg::WT;

  localparam G6LCConfigMmuPresent = 1;

  localparam G6LCConfigRvfiTrace = 1;

  localparam config_pkg::g6lc_user_cfg_t g6lc_cfg = '{
      XLEN: unsigned'(G6LCConfigXlen),
      VLEN: unsigned'(64),
      FpgaEn: bit'(0),  // for Xilinx and Altera
      FpgaAlteraEn: bit'(0),  // for Altera (only)
      TechnoCut: bit'(0),
      SuperscalarEn: bit'(1),
      NrIssuePorts: unsigned'(8),  // hyp8-mc: 8-wide issue (max legal)
      FetchWidth: unsigned'(64),   // hyp8-mc: fetch-bound 8-issue on the hardened 64-bit path (r72 A)
      ALUBypass: bit'(0),
      NrCommitPorts: unsigned'(2),
      AxiAddrWidth: unsigned'(G6LCConfigAxiAddrWidth),
      AxiDataWidth: unsigned'(G6LCConfigAxiDataWidth),
      AxiIdWidth: unsigned'(G6LCConfigAxiIdWidth),
      AxiUserWidth: unsigned'(G6LCConfigDataUserWidth),
      MemTidWidth: unsigned'(G6LCConfigMemTidWidth),
      NrLoadBufEntries: unsigned'(G6LCConfigNrLoadBufEntries),
      RVF: bit'(G6LCConfigRVF),
      RVD: bit'(G6LCConfigRVD),
      XF16: bit'(G6LCConfigF16En),
      XF16ALT: bit'(G6LCConfigF16AltEn),
      XF8: bit'(G6LCConfigF8En),
      RVA: bit'(G6LCConfigAExtEn),
      RVZacas: bit'(0),  // assignment-pattern field (off; requires RVA)
      RVB: bit'(G6LCConfigBExtEn),
      ZKN: bit'(1),
      RVV: bit'(G6LCConfigVExtEn),
      RVC: bit'(G6LCConfigCExtEn),
      RVH: bit'(G6LCConfigHExtEn),
      RVZCB: bit'(G6LCConfigZcbExtEn),
      RVZCMT: bit'(0),
      RVZCMP: bit'(G6LCConfigZcmpExtEn),
      XFVec: bit'(G6LCConfigFVecEn),
      CvxifEn: bit'(G6LCConfigCvxifEn),
      CoproType: config_pkg::COPRO_NONE,
      AiCfg: config_pkg::AiCfgOff,
      RVZiCond: bit'(G6LCConfigRVZiCond),
      RVZiCbom: bit'(0),
      RVZiCboz: bit'(1),
      RVZiCbop: bit'(1),
      RVZicntr: bit'(1),
      RVZihpm: bit'(1),
      NrScoreboardEntries: unsigned'(G6LCConfigNrScoreboardEntries),
      PerfCounterEn: bit'(G6LCConfigPerfCounterEn),
      MmuPresent: bit'(G6LCConfigMmuPresent),
      RVS: bit'(1),
      RVU: bit'(1),
      SoftwareInterruptEn: bit'(1),
      HaltAddress: 64'h800,
      ExceptionAddress: 64'h808,
      RASDepth: unsigned'(G6LCConfigRASDepth),
      BTBEntries: unsigned'(G6LCConfigBTBEntries),
      BPType: config_pkg::TAGE_LITE,
      BHTEntries: unsigned'(G6LCConfigBHTEntries),
      BHTHist: unsigned'(3),
      BPGhistLen: unsigned'(24),
      BPTageTables: unsigned'(3),
      BPTageTableEntries: unsigned'(64),
      BPTageTagBits: unsigned'(8),
      BPLoopEn: bit'(1),
      BPIndirectEn: bit'(1),
      BPIndirectEntries: unsigned'(32),
      BPStatCorEn: bit'(1),
      BPCkptDepth: unsigned'(128),  // hyp8-mc: >= derived RobEntries (NrIssuePorts*16 = 128)
      BPBaseHash: bit'(0),
      DmBaseAddress: 64'h0,
      TvalEn: bit'(G6LCConfigTvalEn),
      DirectVecOnly: bit'(0),
      NrPMPEntries: unsigned'(G6LCConfigNrPMPEntries),
      PMPCfgRstVal: {64{64'h0}},
      PMPAddrRstVal: {64{64'h0}},
      PMPEntryReadOnly: 64'd0,
      PMPNapotEn: bit'(1),
      NOCType: config_pkg::NOC_TYPE_AXI4_ATOP,
      NrNonIdempotentRules: unsigned'(2),
      NonIdempotentAddrBase: 1024'({64'b0, 64'b0}),
      NonIdempotentLength: 1024'({64'b0, 64'b0}),
      NrExecuteRegionRules: unsigned'(3),
      ExecuteRegionAddrBase: 1024'({64'h8000_0000, 64'h1_0000, 64'h0}),
      ExecuteRegionLength: 1024'({64'h40000000, 64'h10000, 64'h1000}),
      NrCachedRegionRules: unsigned'(1),
      CachedRegionAddrBase: 1024'({64'h8000_0000}),
      CachedRegionLength: 1024'({64'h40000000}),
      MaxOutstandingStores: unsigned'(8),
      DebugEn: bit'(1),
      SDTRIG: bit'(0),
      Mcontrol6: bit'(0),
      Icount: bit'(0),
      Etrigger: bit'(0),
      Itrigger: bit'(0),
      AxiBurstWriteEn: bit'(0),
      IcacheByteSize: unsigned'(G6LCConfigIcacheByteSize),
      IcacheSetAssoc: unsigned'(G6LCConfigIcacheSetAssoc),
      IcacheLineWidth: unsigned'(G6LCConfigIcacheLineWidth),
      DCacheType: G6LCConfigDcacheType,
      DcacheByteSize: unsigned'(G6LCConfigDcacheByteSize),
      DcacheSetAssoc: unsigned'(G6LCConfigDcacheSetAssoc),
      DcacheLineWidth: unsigned'(G6LCConfigDcacheLineWidth),
      DcacheFlushOnFence: unsigned'(G6LCConfigDcacheFlushOnFence),
      DcacheFlushOnFenceI: unsigned'(G6LCConfigDcacheFlushOnFenceI),
      DcacheInvalidateOnFlush: unsigned'(G6LCConfigDcacheInvalidateOnFlush),
      DataUserEn: unsigned'(G6LCConfigDataUserEn),
      WtDcacheWbufDepth: int'(G6LCConfigWtDcacheWbufDepth),
      WtDcacheFixupDepth: int'(G6LCConfigWtDcacheFixupDepth),
      WtDcacheFixupVoidKeepEn: bit'(G6LCConfigWtDcacheFixupVoidKeepEn),
      FetchUserWidth: unsigned'(G6LCConfigFetchUserWidth),
      FetchUserEn: unsigned'(G6LCConfigFetchUserEn),
      InstrTlbEntries: int'(16),
      DataTlbEntries: int'(16),
      UseSharedTlb: bit'(0),
      SvnapotEn: bit'(1),
      SstcEn: bit'(1),
      SscofpmfEn: bit'(1),
      ZihintpauseEn: bit'(1),
      SvpbmtEn: bit'(1),
      ZawrsEn: bit'(1),
      // hyp8 L3 integration seam: the default profile keeps the L2/L3
      // engines dark; -DG6LC_HYP8_L3 selects the ooocoh L2->L3->PF->DRAM
      // stack, values copied verbatim from g6lc64_smt2_l3 (the single-
      // core no-hub L3 package; ooocoh-p2-osbi-smt2l3-L0-r2 booted stock
      // OpenSBI on it).
L2En: bit'(1),  // hyp8-mc: always on (4-core shared L2/L3)
      L2ByteSize: unsigned'(262144),
      L2SetAssoc: unsigned'(8),
      L2LineWidth: unsigned'(512),
      L2MshrDepth: unsigned'(2),
      L2DataBanks: unsigned'(4),
      L2RoundRobinEn: bit'(0),
      NrHarts: unsigned'(G6LCConfigNrHarts),
      SmtPolicy: config_pkg::SMT_HYBRID,
      SmtFetchQuantum: unsigned'(4),
      SmtStarveLimit: unsigned'(16),
      CoreSleepGate: bit'(0),
      NrCores: unsigned'(4),  // hyp8-mc
      CohPolicy: config_pkg::COH_FILTERED,
      SnoopFilterEn: bit'(1),  // hyp8-mc: hub snoop filter on
      SnoopFilterEntries: unsigned'(0),  // auto -> 64xNrCores
      CohInvalDepth: unsigned'(4),
      CohAxiStarveLimit: unsigned'(16),
      CohMaxOutstanding: unsigned'(0),  // auto
      WayPredEn: bit'(1),
      WayPredEntries: unsigned'(128),
      ReplPolicy: config_pkg::REPL_RRIP,
      HwPrefetchEn: bit'(0),
      HwPrefetchStreams: unsigned'(0),
      DcacheMshrDepth: unsigned'(0),
      FtqDepth: unsigned'(8),
      FdipEn: bit'(1),
      FdipDistance: unsigned'(2),
      LoopBufEn: bit'(1),
      LoopBufEntries: unsigned'(8),
      SliceOoOEn: bit'(0),
      SliceIstEntries: unsigned'(0),
      SliceAiqDepth: unsigned'(0),
      SliceBiqDepth: unsigned'(0),
      SliceMaxRunahead: unsigned'(0),
      OoOEn: bit'(1),
      SmtDrainedHandoff: bit'(1),
      SmtDrainForceCycles: unsigned'(256),
      DeepSpecEn: bit'(1),
      RobEntries: unsigned'(0),
      PrfEntries: unsigned'(0),
      IqEntries: unsigned'(0),
      LsqLoadEntries: unsigned'(0),
      LsqStoreEntries: unsigned'(0),
      MemDepPredEn: bit'(1),
      OoORetireWidth: unsigned'(0),
      MultStages: unsigned'(8),  // hyp8: latency parameter co-emitted with the 8-stage multiplier (group 7)
      L3En: bit'(1),  // hyp8-mc: always on
      L3ByteSize: unsigned'(1048576),
      L3SetAssoc: unsigned'(16),
      L3LineWidth: unsigned'(512),
      L3MshrDepth: unsigned'(4),
      L3DataBanks: unsigned'(4),
      ServerPrefetchEn: bit'(0),
      ServerPfStreams: unsigned'(0),
      ServerPfDistance: unsigned'(0),
      // WtAxiAllocEn emits BUFFERABLE|MODIFIABLE|RD_ALLOC|WR_ALLOC at the
      // WT boundary — without the attributes the L2/L3 chain is a bypass
      // (T8a). Inclusive off; tag SRAM and write-update per the reference.
      WtAxiAllocEn: bit'(1),
      L3InclusiveEn: bit'(0),
      L2TagSramEn: bit'(1),
      L2WriteUpdateEn: bit'(1),
      L2CmoEn: bit'(1),
      L2PostedWriteEn: bit'(1),

      L2WriteTrackDepth: unsigned'(4),
      L2ReadTrackDepth: unsigned'(4),
      L2PrefetchEn: bit'(0),
      L2PfStreams: unsigned'(0),
      L2PfDistance: unsigned'(0),
      L2PfStrideEn: bit'(0),
      L2PfMshrReserve: unsigned'(0),
      L2PfMaxOutstanding: unsigned'(0),
      L2PfQuiet: unsigned'(0),
      L3PrefetchEn: bit'(0),
      SharedTlbDepth: int'(64),

      NrLoadPipeRegs: int'(G6LCConfigNrLoadPipeRegs),
      NrStorePipeRegs: int'(G6LCConfigNrStorePipeRegs),
      DcacheIdWidth: int'(G6LCConfigDcacheIdWidth)
  };

  // The hyp8 redesign seam — every `// hyp8:` knob bound at compile time.
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8;

  // hyp8 bring-up: `initial` is illegal at package scope (a package body
  // parses even under translate_off), so the legality check runs at
  // elaboration time — same condition as the original assert.
  function automatic int hyp_cfg_check(input g6lc_hyp_pkg::g6lc_hyp_cfg_t c);
    if (!g6lc_hyp_pkg::hyp_cfg_ok(c))
      $fatal(1, "g6lc64_hyp8_config_pkg: HypCfg fails hyp_cfg_ok legality");
    return 1;
  endfunction
  localparam int _hyp_cfg_ok_check = hyp_cfg_check(HypCfg);

endpackage
