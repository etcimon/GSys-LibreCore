// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales
// Server-math + RVV/Ara variant (U10ᵇ) — Etienne Cimon 2026
//
// Select as active cva6_config_pkg ONLY when Ara (or equivalent vector IP) is on
// the flist and EnableAccelerator is satisfied. See architecture/ara-vector-attach.md.
// Without vector RTL, build will elaborate but vector ops need the accelerator path.

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: server-math + RVV/Ara profile derived from the Thales config package template.
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

  // Ara is mutually exclusive with CVXIF (core/cva6.sv assert CvxifEn && EnableAccelerator)
  localparam CVA6ConfigCvxifEn = 0;
  localparam CVA6ConfigCExtEn = 1;
  localparam CVA6ConfigZcbExtEn = 1;
  localparam CVA6ConfigZcmpExtEn = 0;
  localparam CVA6ConfigAExtEn = 1;
  localparam CVA6ConfigHExtEn = 1;  // U9: hypervisor for KVM/Bao
  localparam CVA6ConfigBExtEn = 1;
  localparam CVA6ConfigVExtEn = 1;  // U10ᵇ: RVV — requires Ara/vector IP on flist
  localparam CVA6ConfigRVZiCond = 1;

  localparam CVA6ConfigAxiIdWidth = 4;
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

  localparam CVA6ConfigDcacheIdWidth = 3;
  localparam CVA6ConfigMemTidWidth = 4;

  localparam CVA6ConfigWtDcacheWbufDepth = 8;
  localparam CVA6ConfigWtDcacheFixupDepth = 0;
  localparam CVA6ConfigWtDcacheFixupVoidKeepEn = 1'b1;

  localparam CVA6ConfigNrScoreboardEntries = 16;

  localparam CVA6ConfigNrLoadPipeRegs = 1;
  localparam CVA6ConfigNrStorePipeRegs = 0;
  localparam CVA6ConfigNrLoadBufEntries = 8;

  // S4: RAS=16 + TAGE_LITE + ckpt=16 SIGSEGV'd Variane (rc=-11). Live is
  // BHT + FtqDepth=0 (TAGE off). smt2 is RAS=16 + BHT + ckpt=0. TRACE
  // s4-slc-trace: slc returned to 14182 then IAF fetch-0 (ra stayed
  // 14182) — RAS=2 underflow / unfiltered SRC_MISP to 0. Raise to 16.
  localparam CVA6ConfigRASDepth = 16;
  localparam CVA6ConfigBTBEntries = 32;
  localparam CVA6ConfigBHTEntries = 128;

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
      NrIssuePorts: unsigned'(2),
      ALUBypass: bit'(0),
      NrCommitPorts: unsigned'(2),
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
      // S4: 2jr closed with execute-region D$ uncached. TAGE_LITE+prefetch
      // (s4-v-tage-minis) SIGSEGV rc=-11 all minis even with RAS=2 —
      // keep BHT. Restore TAGE_LITE only after Variane SIGSEGV is gone.
      BPType: config_pkg::BHT,
      BHTEntries: unsigned'(CVA6ConfigBHTEntries),
      BHTHist: unsigned'(3),
      BPGhistLen: unsigned'(24),
      BPTageTables: unsigned'(3),
      BPTageTableEntries: unsigned'(64),
      BPTageTagBits: unsigned'(8),
      BPLoopEn: bit'(1),
      BPIndirectEn: bit'(1),
      BPIndirectEntries: unsigned'(32),
      BPStatCorEn: bit'(1),
      // Hang-7 pair with RAS=2. Ckpt=0 diagnostic (s4-v-ckpt0-minis)
      // same stock HANG @40000 ld ra@e0 as ckpt=16 — not the hang.
      BPCkptDepth: unsigned'(16),
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
      // S4 / I4ag analog: 1 GiB execute made OpenSBI scratch/stack
      // (mepc=ra=0x80046f2c, past .bss/_fw_end) a legal fetch. Boot hart
      // then illegal-decoded zeros with mtvec still _start_hang
      // (coldboot_done=0, pre-sbi_init fw_platform_init). I4v only
      // suppresses JumpR into *non*-execute; widen-DRAM hid the ra poison.
      // .text of fw_payload_r3a_v4 ends 0x1d870; .rodata/FDT at 0x8001e000
      // must stay non-X. Payload/Image at 0x80200000 gets 32 MiB (R3a is
      // 0x178; Linux Image must fit below 0x82200000 — I4w 0x82200000 was
      // payload|bit25). Sign-ext aliases match smt2 I4l. No page-0 window.
      // Cached stays 1 GiB. Config constants only; no new combo/flop.
      NrExecuteRegionRules: unsigned'(5),
      ExecuteRegionAddrBase: 1024'({
        64'hffff_ffff_8020_0000, 64'h8020_0000,
        64'hffff_ffff_8000_0000, 64'h8000_0000,
        64'h1_0000
      }),
      ExecuteRegionLength: 1024'({
        64'h200_0000, 64'h200_0000,
        64'h1e000, 64'h1e000,
        64'h1_0000
      }),
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
      InstrTlbEntries: int'(16),
      DataTlbEntries: int'(16),
      UseSharedTlb: bit'(0),
      SvnapotEn: bit'(1),
      SstcEn: bit'(1),
      SscofpmfEn: bit'(1),
      ZihintpauseEn: bit'(1),
      SvpbmtEn: bit'(1),
      ZawrsEn: bit'(1),
      L2En: bit'(1),
      L2ByteSize: unsigned'(0),
      L2SetAssoc: unsigned'(0),
      L2LineWidth: unsigned'(0),
      L2MshrDepth: unsigned'(0),
      L2DataBanks: unsigned'(0),
      L2RoundRobinEn: bit'(0),
      NrHarts: unsigned'(2),  // SMT2 rail: Linux-boot ladder stays NrHarts>1
      SmtPolicy: config_pkg::SMT_HYBRID,
      SmtFetchQuantum: unsigned'(4),
      SmtStarveLimit: unsigned'(16),
      NrCores: unsigned'(2),
      CohPolicy: config_pkg::COH_FILTERED,
      SnoopFilterEn: bit'(1),
      SnoopFilterEntries: unsigned'(0),
      CohInvalDepth: unsigned'(4),
      CohAxiStarveLimit: unsigned'(16),
      WayPredEn: bit'(1),
      WayPredEntries: unsigned'(128),
      ReplPolicy: config_pkg::REPL_RRIP,
      HwPrefetchEn: bit'(0),  // pair with BHT; TAGE+prefetch SIGSEGV rc=-11
      HwPrefetchStreams: unsigned'(4),
      DcacheMshrDepth: unsigned'(0),
      FtqDepth: unsigned'(0),  // S4: with BHT/Fdip=0, FTQ skips nt_begin (stock HANG @140). smt2 is 0. Restore 8 with TAGE.
      FdipEn: bit'(0),
      FdipDistance: unsigned'(2),
      LoopBufEn: bit'(0),
      LoopBufEntries: unsigned'(8),
      SliceOoOEn: bit'(0),
      SliceIstEntries: unsigned'(0),
      SliceAiqDepth: unsigned'(0),
      SliceBiqDepth: unsigned'(0),
      SliceMaxRunahead: unsigned'(0),
      OoOEn: bit'(0),
      DeepSpecEn: bit'(0),
      RobEntries: unsigned'(0),
      PrfEntries: unsigned'(0),
      IqEntries: unsigned'(0),
      LsqLoadEntries: unsigned'(0),
      LsqStoreEntries: unsigned'(0),
      MemDepPredEn: bit'(0),
      OoORetireWidth: unsigned'(0),
      L3En: bit'(0),
      L3ByteSize: unsigned'(0),
      L3SetAssoc: unsigned'(0),
      L3LineWidth: unsigned'(0),
      L3MshrDepth: unsigned'(0),
      L3DataBanks: unsigned'(0),
      ServerPrefetchEn: bit'(0),
      ServerPfStreams: unsigned'(0),
      ServerPfDistance: unsigned'(0),
      SharedTlbDepth: int'(64),

      NrLoadPipeRegs: int'(CVA6ConfigNrLoadPipeRegs),
      NrStorePipeRegs: int'(CVA6ConfigNrStorePipeRegs),
      DcacheIdWidth: int'(CVA6ConfigDcacheIdWidth)
  };

endpackage
