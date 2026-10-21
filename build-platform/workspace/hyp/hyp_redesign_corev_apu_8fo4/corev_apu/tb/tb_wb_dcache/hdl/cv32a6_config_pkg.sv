// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales


package g6lc_config_pkg;

  localparam G6LCConfigXlen = 32;

  localparam G6LCConfigRVF = 0;
  localparam G6LCConfigF16En = 0;
  localparam G6LCConfigF16AltEn = 0;
  localparam G6LCConfigF8En = 0;
  localparam G6LCConfigFVecEn = 0;

  localparam G6LCConfigCvxifEn = 0;
  localparam G6LCConfigCExtEn = 1;
  localparam G6LCConfigZcbExtEn = 0;
  localparam G6LCConfigZcmpExtEn = 0;
  localparam G6LCConfigAExtEn = 1;
  localparam G6LCConfigHExtEn = 0;  // always disabled
  localparam G6LCConfigBExtEn = 0;
  localparam G6LCConfigVExtEn = 0;
  localparam G6LCConfigRVZiCond = 0;

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

  localparam G6LCConfigDcacheIdWidth = 1;
  localparam G6LCConfigMemTidWidth = 2;

  localparam G6LCConfigWtDcacheWbufDepth = 8;

  localparam G6LCConfigSuperscalarEn = 0;
  localparam G6LCConfigNrCommitPorts = 2;
  localparam G6LCConfigNrScoreboardEntries = 8;

  localparam G6LCConfigFpgaEn = 0;

  localparam G6LCConfigNrLoadPipeRegs = 1;
  localparam G6LCConfigNrStorePipeRegs = 0;
  localparam G6LCConfigNrLoadBufEntries = 2;

  localparam G6LCConfigRASDepth = 2;
  localparam G6LCConfigBTBEntries = 32;
  localparam G6LCConfigBHTEntries = 128;

  localparam G6LCConfigTvalEn = 1;

  localparam G6LCConfigNrPMPEntries = 8;

  localparam G6LCConfigPerfCounterEn = 1;

  localparam config_pkg::cache_type_t G6LCConfigDcacheType = config_pkg::WB;

  localparam G6LCConfigMmuPresent = 1;

  localparam G6LCConfigRvfiTrace = 1;

  // memory configuration (XLEN words)
  localparam MemBytes          = G6LCConfigDcacheByteSize / G6LCConfigDcacheSetAssoc * 4 * 32;
  localparam MemWords          = MemBytes>>($clog2(G6LCConfigXlen/8));

  // noncacheable portion
  localparam CachedAddrBeg = MemBytes >> ($clog2(G6LCConfigXlen/8));

  localparam config_pkg::g6lc_user_cfg_t g6lc_cfg = '{
      XLEN: unsigned'(G6LCConfigXlen),
      FpgaEn: bit'(G6LCConfigFpgaEn),
      NrCommitPorts: unsigned'(G6LCConfigNrCommitPorts),
      AxiAddrWidth: unsigned'(G6LCConfigAxiAddrWidth),
      AxiDataWidth: unsigned'(G6LCConfigAxiDataWidth),
      AxiIdWidth: unsigned'(G6LCConfigAxiIdWidth),
      AxiUserWidth: unsigned'(G6LCConfigDataUserWidth),
      MemTidWidth: unsigned'(G6LCConfigMemTidWidth),
      NrLoadBufEntries: unsigned'(G6LCConfigNrLoadBufEntries),
      RVF: bit'(G6LCConfigRVF),
      RVD: bit'(G6LCConfigRVF),
      XF16: bit'(G6LCConfigF16En),
      XF16ALT: bit'(G6LCConfigF16AltEn),
      XF8: bit'(G6LCConfigF8En),
      RVA: bit'(G6LCConfigAExtEn),
      RVB: bit'(G6LCConfigBExtEn),
      RVV: bit'(G6LCConfigVExtEn),
      RVC: bit'(G6LCConfigCExtEn),
      RVH: bit'(G6LCConfigHExtEn),
      RVZCB: bit'(G6LCConfigZcbExtEn),
      RVZCMP: bit'(G6LCConfigZcmpExtEn),
      XFVec: bit'(G6LCConfigFVecEn),
      CvxifEn: bit'(G6LCConfigCvxifEn),
      RVZiCond: bit'(G6LCConfigRVZiCond),
      NrScoreboardEntries: unsigned'(G6LCConfigNrScoreboardEntries),
      PerfCounterEn: bit'(G6LCConfigPerfCounterEn),
      MmuPresent: bit'(G6LCConfigMmuPresent),
      RVS: bit'(1),
      RVU: bit'(1),
      HaltAddress: 64'h800,
      ExceptionAddress: 64'h808,
      RASDepth: unsigned'(G6LCConfigRASDepth),
      BTBEntries: unsigned'(G6LCConfigBTBEntries),
      BHTEntries: unsigned'(G6LCConfigBHTEntries),
      DmBaseAddress: 64'h0,
      TvalEn: bit'(G6LCConfigTvalEn),
      NrPMPEntries: unsigned'(G6LCConfigNrPMPEntries),
      PMPCfgRstVal: {64{64'h0}},
      PMPAddrRstVal: {64{64'h0}},
      PMPEntryReadOnly: 64'd0,
      NOCType: config_pkg::NOC_TYPE_AXI4_ATOP,
      NrNonIdempotentRules: unsigned'(2),
      NonIdempotentAddrBase: 1024'({64'b0, 64'b0}),
      NonIdempotentLength: 1024'({64'b0, 64'b0}),
      NrExecuteRegionRules: unsigned'(3),
      ExecuteRegionAddrBase: 1024'({64'h8000_0000, 64'h1_0000, 64'h0}),
      ExecuteRegionLength: 1024'({64'h40000000, 64'h10000, 64'h1000}),
      NrCachedRegionRules: unsigned'(1),
      CachedRegionAddrBase: 1024'(CachedAddrBeg),
      CachedRegionLength: 1024'({64'h40000000}),
      MaxOutstandingStores: unsigned'(7),
      DebugEn: bit'(1),
      AxiBurstWriteEn: bit'(0),
      IcacheByteSize: unsigned'(G6LCConfigIcacheByteSize),
      IcacheSetAssoc: unsigned'(G6LCConfigIcacheSetAssoc),
      IcacheLineWidth: unsigned'(G6LCConfigIcacheLineWidth),
      DCacheType: G6LCConfigDcacheType,
      DcacheByteSize: unsigned'(G6LCConfigDcacheByteSize),
      DcacheSetAssoc: unsigned'(G6LCConfigDcacheSetAssoc),
      DcacheLineWidth: unsigned'(G6LCConfigDcacheLineWidth),
      DataUserEn: unsigned'(G6LCConfigDataUserEn),
      WtDcacheWbufDepth: int'(G6LCConfigWtDcacheWbufDepth),
      FetchUserWidth: unsigned'(G6LCConfigFetchUserWidth),
      FetchUserEn: unsigned'(G6LCConfigFetchUserEn),
      InstrTlbEntries: int'(2),
      DataTlbEntries: int'(2),
      UseSharedTlb: bit'(1),
      SharedTlbDepth: int'(64),
      NrLoadPipeRegs: int'(G6LCConfigNrLoadPipeRegs),
      NrStorePipeRegs: int'(G6LCConfigNrStorePipeRegs),
      DcacheIdWidth: int'(G6LCConfigDcacheIdWidth)
  };

endpackage
