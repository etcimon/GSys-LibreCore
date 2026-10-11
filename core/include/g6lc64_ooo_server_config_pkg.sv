// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales
// U5 production OoO server profile (Etienne Cimon 2026):
//   4-issue OoO, 4-core cluster, 2 SMT harts/core, shared L2/L3 (sizes auto-inferred).

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: production OoO server profile derived from the Thales config package template.
// Etienne Cimon offers this file AS A WHOLE under the dual licence below.
// Expressed as a non-SPDX tag because SPDX has no operator for "whole is X,
// portions remain Y"; the machine-readable form is in REUSE.toml.
// Outbound-License: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial


package cva6_config_pkg;

  localparam CVA6ConfigXlen = 64;

  localparam CVA6ConfigRVF = 1;
  localparam CVA6ConfigRVD = 1;
  localparam CVA6ConfigF16En = 0;
  localparam CVA6ConfigF16AltEn = 0;
  localparam CVA6ConfigF8En = 0;
  localparam CVA6ConfigFVecEn = 0;

  // 0: see g6lc64_smt2_config_pkg.sv -- CVXIF offload is issue-port-0 only, so
  // CvxifEn on a multi-issue core drops illegal-instruction exceptions.
  localparam CVA6ConfigCvxifEn = 0;
  localparam CVA6ConfigCExtEn = 1;
  localparam CVA6ConfigZcbExtEn = 1;
  localparam CVA6ConfigZcmpExtEn = 0;
  localparam CVA6ConfigAExtEn = 1;
  localparam CVA6ConfigHExtEn = 1;  // U9: hypervisor for KVM/Bao
  localparam CVA6ConfigBExtEn = 1;
  localparam CVA6ConfigVExtEn = 0;  // RVV needs Ara; enable when vector IP attached
  localparam CVA6ConfigRVZiCond = 1;

  // HPDCACHE needs memIdWidth ≥ clog2(mshrSets×mshrWays)+1 and ≥ clog2(wbuf)+1;
  // with 24 load-buf / wbuf-16 that is ≥6. Keep AXI ≥ MEM_TID.
  localparam CVA6ConfigAxiIdWidth = 8;
  localparam CVA6ConfigAxiAddrWidth = 64;
  localparam CVA6ConfigAxiDataWidth = 64;
  localparam CVA6ConfigFetchUserEn = 0;
  localparam CVA6ConfigFetchUserWidth = CVA6ConfigXlen;
  localparam CVA6ConfigDataUserEn = 0;
  localparam CVA6ConfigDataUserWidth = CVA6ConfigXlen;

  localparam CVA6ConfigIcacheByteSize = 16384;
  localparam CVA6ConfigIcacheSetAssoc = 4;
  localparam CVA6ConfigIcacheLineWidth = 128;
  localparam CVA6ConfigDcacheByteSize = 32768;
  localparam CVA6ConfigDcacheSetAssoc = 8;
  localparam CVA6ConfigDcacheLineWidth = 128;

  localparam CVA6ConfigDcacheFlushOnFence = 1'b0;
  localparam CVA6ConfigDcacheFlushOnFenceI = 1'b0;
  localparam CVA6ConfigDcacheInvalidateOnFlush = 1'b0;

  // Encode up to NrLoadBufEntries pending loads (clog2(24)=5)
  localparam CVA6ConfigDcacheIdWidth = 5;
  localparam CVA6ConfigMemTidWidth = 8;

  localparam CVA6ConfigWtDcacheWbufDepth = 16;
  localparam CVA6ConfigWtDcacheFixupDepth = 0;
  localparam CVA6ConfigWtDcacheFixupVoidKeepEn = 1'b1;

  // 4-issue window: deeper SB than dual-issue baseline
  localparam CVA6ConfigNrScoreboardEntries = 64;

  localparam CVA6ConfigNrLoadPipeRegs = 1;
  localparam CVA6ConfigNrStorePipeRegs = 0;
  localparam CVA6ConfigNrLoadBufEntries = 24;

  // T18 (2026-10-06): the 64 M strict boot profile showed 97-100 % of the
  // ~68 k libfdt returns per FDT-init phase mispredicted at depth 2 (11-cycle
  // redirect each, ~0.7 M cycles per phase). Same depth as g6lc64_ooo_int2_l3;
  // RAS-miss is NoCF in the fetch_B frontend so EX corrects an empty RAS.
  localparam CVA6ConfigRASDepth = 16;
  localparam CVA6ConfigBTBEntries = 32;
  // T21e (2026-10-10): the TAGE base bimodal is indexed by pc bits above the
  // slot (NR_ENTRIES / INSTR_PER_FETCH rows); at 128 entries that is 32 rows
  // of 4 slots, a 256-byte alias period. In libfdt the always-taken bltu at
  // fdt_next_tag+0x120 and the never-taken c.beqz at +0x20 are 0x100 apart
  // and thrashed one counter (P2 window: 1,057 mispredicts of the latter
  // once the corrector stopped masking it). 1024 entries = 256 rows (2 KB).
  localparam CVA6ConfigBHTEntries = 1024;

  localparam CVA6ConfigTvalEn = 1;

  localparam CVA6ConfigNrPMPEntries = 8;

  localparam CVA6ConfigPerfCounterEn = 1;

  localparam config_pkg::cache_type_t CVA6ConfigDcacheType = config_pkg::HPDCACHE_WT;

  localparam CVA6ConfigMmuPresent = 1;

  localparam CVA6ConfigRvfiTrace = 1;

  localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{
      XLEN: unsigned'(CVA6ConfigXlen),
      VLEN: unsigned'(64),
      FpgaEn: bit'(0),  // for Xilinx and Altera
      FpgaAlteraEn: bit'(0),  // for Altera (only)
      TechnoCut: bit'(0),
      SuperscalarEn: bit'(1),
      NrIssuePorts: unsigned'(4),
      ALUBypass: bit'(1),
      NrCommitPorts: unsigned'(4),
      AxiAddrWidth: unsigned'(CVA6ConfigAxiAddrWidth),
      AxiDataWidth: unsigned'(CVA6ConfigAxiDataWidth),
      AxiIdWidth: unsigned'(CVA6ConfigAxiIdWidth),
      AxiUserWidth: unsigned'(CVA6ConfigDataUserWidth),
      MemTidWidth: unsigned'(CVA6ConfigMemTidWidth),
      NrLoadBufEntries: unsigned'(CVA6ConfigNrLoadBufEntries),
      RVF: bit'(CVA6ConfigRVF),
      RVD: bit'(CVA6ConfigRVD),
      XF16: bit'(CVA6ConfigF16En),
      XF16ALT: bit'(CVA6ConfigF16AltEn),
      XF8: bit'(CVA6ConfigF8En),
      RVA: bit'(CVA6ConfigAExtEn),
      RVZacas: bit'(1),  // Zacas AMOCAS.W/D for lock-free multi-core
      RVB: bit'(CVA6ConfigBExtEn),
      ZKN: bit'(1),
      RVV: bit'(CVA6ConfigVExtEn),
      RVC: bit'(CVA6ConfigCExtEn),
      RVH: bit'(CVA6ConfigHExtEn),
      RVZCB: bit'(CVA6ConfigZcbExtEn),
      RVZCMT: bit'(0),
      RVZCMP: bit'(CVA6ConfigZcmpExtEn),
      XFVec: bit'(CVA6ConfigFVecEn),
      CvxifEn: bit'(CVA6ConfigCvxifEn),
      CoproType: config_pkg::COPRO_NONE,
      AiCfg: config_pkg::AiCfgOff,
      RVZiCond: bit'(CVA6ConfigRVZiCond),
      RVZiCbom: bit'(1),
      RVZiCboz: bit'(1),
      RVZiCbop: bit'(1),
      RVZicntr: bit'(1),
      RVZihpm: bit'(1),
      NrScoreboardEntries: unsigned'(CVA6ConfigNrScoreboardEntries),
      PerfCounterEn: bit'(CVA6ConfigPerfCounterEn),
      MmuPresent: bit'(CVA6ConfigMmuPresent),
      RVS: bit'(1),
      RVU: bit'(1),
      SoftwareInterruptEn: bit'(1),
      HaltAddress: 64'h800,
      ExceptionAddress: 64'h808,
      RASDepth: unsigned'(CVA6ConfigRASDepth),
      BTBEntries: unsigned'(CVA6ConfigBTBEntries),
      BPType: config_pkg::TAGE_LITE,
      BHTEntries: unsigned'(CVA6ConfigBHTEntries),
      BHTHist: unsigned'(3),
      BPGhistLen: unsigned'(24),
      BPTageTables: unsigned'(3),
      // T21e: 3 x 64 tagged entries and 32 indirect targets could not hold
      // the libfdt walk (jr a5 at fdt_next_tag+0x74 44-95 % mispredicted);
      // 256 / 128 with the same 8-bit tags.
      BPTageTableEntries: unsigned'(256),
      BPTageTagBits: unsigned'(8),
      BPLoopEn: bit'(1),
      BPIndirectEn: bit'(1),
      BPIndirectEntries: unsigned'(128),
      BPStatCorEn: bit'(1),
      BPCkptDepth: unsigned'(64),
      DmBaseAddress: 64'h0,
      TvalEn: bit'(CVA6ConfigTvalEn),
      DirectVecOnly: bit'(0),
      NrPMPEntries: unsigned'(CVA6ConfigNrPMPEntries),
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
      MaxOutstandingStores: unsigned'(16),  // check_cfg: DeepSpecEn caps STQ CAM at 16 (v1)
      DebugEn: bit'(1),
      SDTRIG: bit'(0),
      Mcontrol6: bit'(0),
      Icount: bit'(0),
      Etrigger: bit'(0),
      Itrigger: bit'(0),
      AxiBurstWriteEn: bit'(0),
      IcacheByteSize: unsigned'(CVA6ConfigIcacheByteSize),
      IcacheSetAssoc: unsigned'(CVA6ConfigIcacheSetAssoc),
      IcacheLineWidth: unsigned'(CVA6ConfigIcacheLineWidth),
      DCacheType: CVA6ConfigDcacheType,
      DcacheByteSize: unsigned'(CVA6ConfigDcacheByteSize),
      DcacheSetAssoc: unsigned'(CVA6ConfigDcacheSetAssoc),
      DcacheLineWidth: unsigned'(CVA6ConfigDcacheLineWidth),
      DcacheFlushOnFence: unsigned'(CVA6ConfigDcacheFlushOnFence),
      DcacheFlushOnFenceI: unsigned'(CVA6ConfigDcacheFlushOnFenceI),
      DcacheInvalidateOnFlush: unsigned'(CVA6ConfigDcacheInvalidateOnFlush),
      DataUserEn: unsigned'(CVA6ConfigDataUserEn),
      WtDcacheWbufDepth: int'(CVA6ConfigWtDcacheWbufDepth),
      WtDcacheFixupDepth: int'(CVA6ConfigWtDcacheFixupDepth),
      WtDcacheFixupVoidKeepEn: bit'(CVA6ConfigWtDcacheFixupVoidKeepEn),
      FetchUserWidth: unsigned'(CVA6ConfigFetchUserWidth),
      FetchUserEn: unsigned'(CVA6ConfigFetchUserEn),
      InstrTlbEntries: int'(32),
      DataTlbEntries: int'(32),
      UseSharedTlb: bit'(0),
      SvnapotEn: bit'(1),
      SstcEn: bit'(1),
      SscofpmfEn: bit'(1),
      ZihintpauseEn: bit'(1),
      SvpbmtEn: bit'(1),
      ZawrsEn: bit'(1),
      // Shared L2/L3: sizes 0 → build_config_pkg infers from NrCores
      // (L2 = max(256 KiB, N×128 KiB), L3 = max(2 MiB, N×1 MiB))
      L2En: bit'(1),
      L2ByteSize: unsigned'(0),
      L2SetAssoc: unsigned'(0),
      L2LineWidth: unsigned'(0),
      L2MshrDepth: unsigned'(0),
      L2DataBanks: unsigned'(0),
      L2RoundRobinEn: bit'(0),
      // 2 SMT threads per core
      NrHarts: unsigned'(2),
      SmtPolicy: config_pkg::SMT_HYBRID,
      // T21 (2026-10-10): aligned with every qualified SMT profile (int2_l3,
      // smt2, smt2_ooo_int: 128 / 64). At 4 / 16 the anti-starvation leg
      // handed the core to the spinning sibling every 16 cycles during the
      // cold boot: 52.6 K drained handoffs in the first 1.3 M cycles, 44 % of
      // the cycles in the drain, the boot hart's share 11 %. The 1.3 M A/B
      // with quantum 128 alone (`t21/T21-FOLLOWUP-REPORT.md`) reached
      // fdt_next_node 39 % earlier and retired 83 % more boot-hart
      // instructions; the starve limit is the binding trigger at 16.
      SmtFetchQuantum: unsigned'(128),
      SmtStarveLimit: unsigned'(64),
      // 4-core coherent cluster
      NrCores: unsigned'(4),
      CohPolicy: config_pkg::COH_FILTERED,
      SnoopFilterEn: bit'(1),
      SnoopFilterEntries: unsigned'(0),  // auto → 64×NrCores
      CohInvalDepth: unsigned'(4),
      CohAxiStarveLimit: unsigned'(16),
      CohMaxOutstanding: unsigned'(0),
      WayPredEn: bit'(1),
      WayPredEntries: unsigned'(128),
      ReplPolicy: config_pkg::REPL_RRIP,
      HwPrefetchEn: bit'(1),
      HwPrefetchStreams: unsigned'(4),
      DcacheMshrDepth: unsigned'(0),
      FtqDepth: unsigned'(16),
      FdipEn: bit'(1),
      FdipDistance: unsigned'(2),
      LoopBufEn: bit'(1),
      LoopBufEntries: unsigned'(16),
      SliceOoOEn: bit'(0),
      SliceIstEntries: unsigned'(0),
      SliceAiqDepth: unsigned'(0),
      SliceBiqDepth: unsigned'(0),
      SliceMaxRunahead: unsigned'(0),
      // 4-issue full OoO (depths 0 → scale with issue width in build_config)
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
      L3En: bit'(1),
      L3ByteSize: unsigned'(0),
      L3SetAssoc: unsigned'(0),
      L3LineWidth: unsigned'(0),
      L3MshrDepth: unsigned'(0),
      L3DataBanks: unsigned'(0),
      ServerPrefetchEn: bit'(1),
      ServerPfStreams: unsigned'(0),  // auto → max(4, 2×NrCores)
      ServerPfDistance: unsigned'(2),
      WtAxiAllocEn: bit'(0),
      L3InclusiveEn: bit'(1),
      L2TagSramEn: bit'(0),
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
      SharedTlbDepth: int'(128),

      NrLoadPipeRegs: int'(CVA6ConfigNrLoadPipeRegs),
      NrStorePipeRegs: int'(CVA6ConfigNrStorePipeRegs),
      DcacheIdWidth: int'(CVA6ConfigDcacheIdWidth)
  };

endpackage
