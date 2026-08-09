// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales
// U10 server-math / hypervisor profile (Etienne Cimon 2026)
// C-light production: H+Sstc, RVB/ZKN/Zicbo*, HPDCACHE+HWPF, L2 auto, NrCores=2.
// RVV=0 until Ara is on the flist (use g6lc64_server_math_v_config_pkg then).

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: server-math / hypervisor profile derived from the Thales config package template.
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
  localparam CVA6ConfigHExtEn = 1;  // U9: hypervisor for KVM/Bao
  localparam CVA6ConfigBExtEn = 1;
  localparam CVA6ConfigVExtEn = 0;  // RVV needs Ara; enable when vector IP attached
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

  // HPDCACHE MSHR/wbuf need memId ≥4 with 8 load-buf + wbuf-8
  localparam CVA6ConfigDcacheIdWidth = 3;
  localparam CVA6ConfigMemTidWidth = 4;

  localparam CVA6ConfigWtDcacheWbufDepth = 8;

  localparam CVA6ConfigNrScoreboardEntries = 16;

  localparam CVA6ConfigNrLoadPipeRegs = 1;
  localparam CVA6ConfigNrStorePipeRegs = 0;
  // Hang-7 bisect: NrLoadBufEntries=1 still hung (MEMCHR_LO / hart_cnt=0x80).
  // Multi-outstanding ldbuf ID mismatch ruled out as sole cause.
  localparam CVA6ConfigNrLoadBufEntries = 8;

  // Hang-7 note: RASDepth=2 is tiny vs FDT call depth; raising to 16 regressed
  // to earlier load-misalign @ fdt_getprop (mtval=0x8001e8fb). Keep 2 until
  // RAS/ckpt restore is validated; hang-7 residual is c.jr fallthrough after
  // path_offset error ret (see monorepo-soak/L2-OPENSBI-HANG-PROGRESS.md).
  localparam CVA6ConfigRASDepth = 2;
  localparam CVA6ConfigBTBEntries = 32;
  localparam CVA6ConfigBHTEntries = 128;

  localparam CVA6ConfigTvalEn = 1;

  localparam CVA6ConfigNrPMPEntries = 8;

  localparam CVA6ConfigPerfCounterEn = 1;

  // HPDCACHE for CMO + HW prefetch (U7/U10); not deprecated std WT
  localparam config_pkg::cache_type_t CVA6ConfigDcacheType = config_pkg::HPDCACHE_WT;

  localparam CVA6ConfigMmuPresent = 1;

  localparam CVA6ConfigRvfiTrace = 1;

  localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{
      XLEN: unsigned'(CVA6ConfigXlen),
      VLEN: unsigned'(64),
      FpgaEn: bit'(0),  // for Xilinx and Altera
      FpgaAlteraEn: bit'(0),  // for Altera (only)
      TechnoCut: bit'(0),
      // Hang-6 temporary: single-issue until dual residual is fixed.
      // Dual (ports=2) fails fdt_path_offset("/cpus") BADOFFSET; single
      // clears hang-6 (later _start_hang BADPATH is a different issue).
      // Hang-4 stored-PC + realign 2'b01 kept for dual re-enable.
      SuperscalarEn: bit'(0),
      NrIssuePorts: unsigned'(1),
      ALUBypass: bit'(0),
      NrCommitPorts: unsigned'(1),
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
      BPTageTableEntries: unsigned'(64),
      BPTageTagBits: unsigned'(8),
      BPLoopEn: bit'(1),
      BPIndirectEn: bit'(1),
      BPIndirectEntries: unsigned'(32),
      BPStatCorEn: bit'(1),
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
      // L2 size 0 → build_config infers max(256 KiB, NrCores×128 KiB) for N=2 → 256 KiB
      // Hang-7: L2En=0 bisect deadlocked on stack store in path_offset (not clean).
      L2En: bit'(1),
      L2ByteSize: unsigned'(0),
      L2SetAssoc: unsigned'(0),
      L2LineWidth: unsigned'(0),  // 512b (64 B) after infer — Zic64b-class line
      L2MshrDepth: unsigned'(0),
      L2DataBanks: unsigned'(0),
      NrHarts: unsigned'(1),
      SmtPolicy: config_pkg::SMT_HYBRID,
      SmtFetchQuantum: unsigned'(4),
      SmtStarveLimit: unsigned'(16),
      NrCores: unsigned'(2),
      CohPolicy: config_pkg::COH_FILTERED,
      SnoopFilterEn: bit'(1),
      SnoopFilterEntries: unsigned'(0),  // auto 64×NrCores
      CohInvalDepth: unsigned'(4),
      CohAxiStarveLimit: unsigned'(16),
      WayPredEn: bit'(1),
      WayPredEntries: unsigned'(128),
      ReplPolicy: config_pkg::REPL_RRIP,
      HwPrefetchEn: bit'(1),
      HwPrefetchStreams: unsigned'(4),
      DcacheMshrDepth: unsigned'(0),
      // Hang-5 bisect: U2 frontend off (FTQ/FDIP/LoopBuf). Dual-issue +
      // stored-PC still hits fw_fdt_bin; isolate U2 vs base dual-issue.
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
      // U10 is C-light (in-order multi-issue); full OoO is ooo_server package
      OoOEn: bit'(0),
      // Same STQ deepen as imafdc FORCE_IMAFDC smoke: DEPTH_COMMIT=4 with
      // DeepSpecEn=0 hangs fill→verify ≥40 B; raise STQ for CRT stream residual
      // under HPDCACHE_WT + L2 (NrCores=2). Couples SpeculativeSb in build_config.
      DeepSpecEn: bit'(1),
      RobEntries: unsigned'(0),
      PrfEntries: unsigned'(0),
      IqEntries: unsigned'(0),
      LsqLoadEntries: unsigned'(0),
      LsqStoreEntries: unsigned'(0),
      MemDepPredEn: bit'(0),
      OoORetireWidth: unsigned'(0),
      // Stream plane × multicore (U6/p6): L2 miss-edge multi-stream PF on.
      // L3 stays optional (ooo_server enables L3 + inclusive L1/L2 back-inval).
      L3En: bit'(0),
      L3ByteSize: unsigned'(0),
      L3SetAssoc: unsigned'(0),
      L3LineWidth: unsigned'(0),
      L3MshrDepth: unsigned'(0),
      L3DataBanks: unsigned'(0),
      // Disabled until PF R-absorb path is soak-proven on MC+L2+ROM boot;
      // re-enable after mc-mini-veri green on server_math.
      ServerPrefetchEn: bit'(0),
      ServerPfStreams: unsigned'(0),  // auto → max(4, 2×NrCores)
      ServerPfDistance: unsigned'(2),
      SharedTlbDepth: int'(64),

      NrLoadPipeRegs: int'(CVA6ConfigNrLoadPipeRegs),
      NrStorePipeRegs: int'(CVA6ConfigNrStorePipeRegs),
      DcacheIdWidth: int'(CVA6ConfigDcacheIdWidth)
  };

endpackage
