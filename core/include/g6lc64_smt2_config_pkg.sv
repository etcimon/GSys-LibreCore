// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales
// U6.1 experimental SMT2 profile — Etienne Cimon 2026
//
// Select as active cva6_config_pkg for dual-thread coarse-grain SMT bring-up.
// Default production packages keep NrHarts=1 (identity path).

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: dual-hart coarse-grain SMT profile derived from the Thales config package template.
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

  localparam CVA6ConfigCvxifEn = 1;
  localparam CVA6ConfigCExtEn = 1;
  localparam CVA6ConfigZcbExtEn = 1;
  localparam CVA6ConfigZcmpExtEn = 0;
  localparam CVA6ConfigAExtEn = 1;
  localparam CVA6ConfigHExtEn = 0;
  localparam CVA6ConfigBExtEn = 1;
  localparam CVA6ConfigVExtEn = 0;
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

  localparam CVA6ConfigDcacheIdWidth = 1;
  localparam CVA6ConfigMemTidWidth = 2;

  localparam CVA6ConfigWtDcacheWbufDepth = 8;

  localparam CVA6ConfigNrScoreboardEntries = 8;

  localparam CVA6ConfigNrLoadPipeRegs = 1;
  localparam CVA6ConfigNrStorePipeRegs = 0;
  // Hang-7 bisect (server_math): ldbuf=1 still hung; 8 matches multi-outstanding
  // FDT walks. smt2 was left at 2 during dual-issue bring-up — raise with RAS.
  localparam CVA6ConfigNrLoadBufEntries = 8;

  // Hang-7: RASDepth=2 is tiny vs OpenSBI FDT call depth. Depth 16 previously
  // unmasked load-misalign under server_math TAGE+ckpt; smt2 has BPCkptDepth=0
  // and RAS-miss is now NoCF (frontend) so EX always corrects empty RAS. Use 16.
  localparam CVA6ConfigRASDepth = 16;
  localparam CVA6ConfigBTBEntries = 32;
  localparam CVA6ConfigBHTEntries = 128;

  localparam CVA6ConfigTvalEn = 1;

  localparam CVA6ConfigNrPMPEntries = 8;

  localparam CVA6ConfigPerfCounterEn = 1;

  localparam config_pkg::cache_type_t CVA6ConfigDcacheType = config_pkg::WT;

  localparam CVA6ConfigMmuPresent = 1;

  localparam CVA6ConfigRvfiTrace = 1;

  localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{
      XLEN: unsigned'(CVA6ConfigXlen),
      VLEN: unsigned'(64),
      FpgaEn: bit'(0),
      FpgaAlteraEn: bit'(0),
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
      RVZacas: bit'(1),  // Zacas AMOCAS.W/D — Linux-boot DTS advertises zacas
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
      BPType: config_pkg::BHT,
      BHTEntries: unsigned'(CVA6ConfigBHTEntries),
      BHTHist: unsigned'(3),
      BPGhistLen: unsigned'(0),
      BPTageTables: unsigned'(0),
      BPTageTableEntries: unsigned'(0),
      BPTageTagBits: unsigned'(0),
      BPLoopEn: bit'(0),
      BPIndirectEn: bit'(0),
      BPIndirectEntries: unsigned'(0),
      BPStatCorEn: bit'(0),
      BPCkptDepth: unsigned'(0),
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
      MaxOutstandingStores: unsigned'(7),
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
      L2ByteSize: unsigned'(262144),
      L2SetAssoc: unsigned'(8),
      L2LineWidth: unsigned'(512),
      L2MshrDepth: unsigned'(16),
      L2DataBanks: unsigned'(4),
      // U6.1 SMT2
      NrHarts: unsigned'(2),
      SmtPolicy: config_pkg::SMT_HYBRID,
      SmtFetchQuantum: unsigned'(128),  // dual-ready RR; OpenSBI-scale (miss thrash fix)
      SmtStarveLimit: unsigned'(64),
      NrCores: unsigned'(1),
      CohPolicy: config_pkg::COH_FILTERED,
      SnoopFilterEn: bit'(0),
      SnoopFilterEntries: unsigned'(0),
      CohInvalDepth: unsigned'(0),
      CohAxiStarveLimit: unsigned'(0),
      WayPredEn: bit'(0),
      WayPredEntries: unsigned'(0),
      ReplPolicy: config_pkg::REPL_PLRU,
      HwPrefetchEn: bit'(0),
      HwPrefetchStreams: unsigned'(0),
      DcacheMshrDepth: unsigned'(0),
      FtqDepth: unsigned'(0),
      FdipEn: bit'(0),
      FdipDistance: unsigned'(0),
      LoopBufEn: bit'(0),
      LoopBufEntries: unsigned'(0),
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
