package build_config_pkg;

  // Scale FETCH_WIDTH with issue width: min bits for N×{16,32}-bit instrs, pot.
  // Soft-ladder iter-011 / PEEL_STRLEN: dual-issue + RVC with FETCH_WIDTH=32
  // (2×16) uses realign_bp_32, which can desync mid-RVI PCs in tight mixed
  // C/I loops (OpenSBI sbi_strlen: mepc=0x4a50 into `add` @0x4a4e). Prefer
  // the hang-6-hardened 64-bit realign path whenever multi-issue and RVC.
  function automatic int unsigned build_fetch_width(int unsigned n_issue, bit rvc);
    int unsigned min_bits;
    int unsigned fw;
    min_bits = n_issue * (rvc ? 16 : 32);
    if (min_bits < 32) min_bits = 32;
    if (n_issue >= 2 && rvc && min_bits < 64) min_bits = 64;
    fw = 32;
    while (fw < min_bits && fw < config_pkg::CVA6_MAX_FETCH_WIDTH) fw = fw << 1;
    return fw;
  endfunction

  function automatic config_pkg::cva6_cfg_t build_config(config_pkg::cva6_user_cfg_t CVA6Cfg);
    bit IS_XLEN32 = (CVA6Cfg.XLEN == 32) ? 1'b1 : 1'b0;
    bit IS_XLEN64 = (CVA6Cfg.XLEN == 32) ? 1'b0 : 1'b1;
    bit FpPresent = CVA6Cfg.RVF | CVA6Cfg.RVD | CVA6Cfg.XF16 | CVA6Cfg.XF16ALT | CVA6Cfg.XF8;
    bit NSX = CVA6Cfg.XF16 | CVA6Cfg.XF16ALT | CVA6Cfg.XF8 | CVA6Cfg.XFVec;  // Are non-standard extensions present?
    int unsigned FLen = CVA6Cfg.RVD ? 64 :  // D ext.
    CVA6Cfg.RVF ? 32 :  // F ext.
    CVA6Cfg.XF16 ? 16 :  // Xf16 ext.
    CVA6Cfg.XF16ALT ? 16 :  // Xf16alt ext.
    CVA6Cfg.XF8 ? 8 :  // Xf8 ext.
    1;  // Unused in case of no FP

    // Transprecision floating-point extensions configuration
    bit RVFVec     = CVA6Cfg.RVF     & CVA6Cfg.XFVec & FLen>32; // FP32 vectors available if vectors and larger fmt enabled
    bit XF16Vec    = CVA6Cfg.XF16    & CVA6Cfg.XFVec & FLen>16; // FP16 vectors available if vectors and larger fmt enabled
    bit XF16ALTVec = CVA6Cfg.XF16ALT & CVA6Cfg.XFVec & FLen>16; // FP16ALT vectors available if vectors and larger fmt enabled
    bit XF8Vec     = CVA6Cfg.XF8     & CVA6Cfg.XFVec & FLen>8;  // FP8 vectors available if vectors and larger fmt enabled

    bit EnableAccelerator = CVA6Cfg.RVV;  // Currently only used by V extension (Ara)
    int unsigned NrWbPorts = (CVA6Cfg.CvxifEn || EnableAccelerator) ? 5 : 4;

    int unsigned ICACHE_INDEX_WIDTH = $clog2(CVA6Cfg.IcacheByteSize / CVA6Cfg.IcacheSetAssoc);
    int unsigned DCACHE_INDEX_WIDTH = $clog2(CVA6Cfg.DcacheByteSize / CVA6Cfg.DcacheSetAssoc);
    int unsigned DCACHE_OFFSET_WIDTH = $clog2(CVA6Cfg.DcacheLineWidth / 8);

    // MMU
    int unsigned VpnLen = IS_XLEN64 ? (CVA6Cfg.RVH ? 29 : 27) : 20;
    int unsigned PtLevels = IS_XLEN64 ? 3 : 2;

    config_pkg::cva6_cfg_t cfg;

    cfg.XLEN = CVA6Cfg.XLEN;
    cfg.VLEN = CVA6Cfg.VLEN;
    cfg.PLEN = IS_XLEN32 ? 34 : 56;
    cfg.GPLEN = IS_XLEN32 ? 34 : 41;
    cfg.IS_XLEN32 = IS_XLEN32;
    cfg.IS_XLEN64 = IS_XLEN64;
    cfg.XLEN_ALIGN_BYTES = $clog2(CVA6Cfg.XLEN / 8);
    cfg.ASID_WIDTH = IS_XLEN64 ? 16 : 1;
    cfg.VMID_WIDTH = IS_XLEN64 ? 14 : 1;

    cfg.FpgaEn = CVA6Cfg.FpgaEn;
    cfg.FpgaAlteraEn = CVA6Cfg.FpgaAlteraEn;
    cfg.TechnoCut = CVA6Cfg.TechnoCut;

    cfg.SuperscalarEn = CVA6Cfg.SuperscalarEn;
    // Issue width: explicit 1..8, or auto from SuperscalarEn (legacy: SS→2, else 1).
    if (CVA6Cfg.NrIssuePorts == 0) begin
      cfg.NrIssuePorts = unsigned'(CVA6Cfg.SuperscalarEn ? 2 : 1);
    end else begin
      cfg.NrIssuePorts = CVA6Cfg.NrIssuePorts;
    end
    // Commit ports: keep user value if wide enough; else match issue width under SS.
    // Hang-6: NrCommitPorts=1 under dual still BADOFFSET — not dual-commit residual.
    if (CVA6Cfg.SuperscalarEn) begin
      if (CVA6Cfg.NrCommitPorts >= cfg.NrIssuePorts)
        cfg.NrCommitPorts = CVA6Cfg.NrCommitPorts;
      else if (CVA6Cfg.NrCommitPorts >= 2)
        cfg.NrCommitPorts = CVA6Cfg.NrCommitPorts;  // allow commit < issue
      else
        cfg.NrCommitPorts = cfg.NrIssuePorts > 2 ? cfg.NrIssuePorts : unsigned'(2);
    end else begin
      cfg.NrCommitPorts = CVA6Cfg.NrCommitPorts;
    end
    // Speculative SB: younger cancel + speculative-load LSU gates.
    // cont.14: do NOT couple SpeculativeSb to SuperscalarEn alone.
    // True SI (SS=0 ⇒ SpeculativeSb was 0) advances OpenSBI past path_offset;
    // DI+force-SI with SpeculativeSb=1 still returned -4. Speculative LSU
    // gating (is_speculative_load / STQ interlocks) is the residual. Keep
    // SpeculativeSb for OoO/DeepSpec only until the FDT walk is clean under SS.
    // Hang-6 note: SpeculativeSb alone was not the *only* BADOFFSET cause then;
    // cont.14 shows it is necessary for stock /cpus with current STQ RTL.
    cfg.SpeculativeSb = CVA6Cfg.SliceOoOEn || CVA6Cfg.OoOEn || CVA6Cfg.DeepSpecEn;
    cfg.DeepSpecEn = CVA6Cfg.DeepSpecEn;

    // Dual ALU minimum under SS; scale toward issue width (cap 4 for area).
    // Hang-6: NrALUs=1 under dual still BADOFFSET — not dual-ALU residual.
    if (CVA6Cfg.SuperscalarEn) begin
      cfg.NrALUs = (cfg.NrIssuePorts >= 4) ? unsigned'(4) :
                   (cfg.NrIssuePorts >= 2) ? unsigned'(2) : unsigned'(1);
    end else begin
      cfg.NrALUs = unsigned'(1);
    end
    cfg.ALUBypass = CVA6Cfg.SuperscalarEn ? bit'(CVA6Cfg.ALUBypass) : bit'(0);

    cfg.NrLoadPipeRegs = CVA6Cfg.NrLoadPipeRegs;
    cfg.NrStorePipeRegs = CVA6Cfg.NrStorePipeRegs;
    cfg.AxiAddrWidth = CVA6Cfg.AxiAddrWidth;
    cfg.AxiDataWidth = CVA6Cfg.AxiDataWidth;
    cfg.AxiIdWidth = CVA6Cfg.AxiIdWidth;
    cfg.AxiUserWidth = CVA6Cfg.AxiUserWidth;
    cfg.MEM_TID_WIDTH = CVA6Cfg.MemTidWidth;
    cfg.NrLoadBufEntries = CVA6Cfg.NrLoadBufEntries;
    // FSE S1: raise load-buffer floor for MLP when DeepSpecEn (B2).
    if (CVA6Cfg.DeepSpecEn) begin
      automatic int unsigned load_floor = cfg.NrIssuePorts * 4;
      if (load_floor < 8) load_floor = 8;
      if (cfg.NrLoadBufEntries < load_floor) cfg.NrLoadBufEntries = load_floor;
    end
    cfg.RVF = CVA6Cfg.RVF;
    cfg.RVD = CVA6Cfg.RVD;
    cfg.XF16 = CVA6Cfg.XF16;
    cfg.XF16ALT = CVA6Cfg.XF16ALT;
    cfg.XF8 = CVA6Cfg.XF8;
    cfg.RVA = CVA6Cfg.RVA;
    // Zacas requires Zaamo/A (RVA). Illegal if set without RVA — check_cfg asserts.
    cfg.RVZacas = CVA6Cfg.RVZacas && CVA6Cfg.RVA;
    cfg.RVB = CVA6Cfg.RVB || CVA6Cfg.ZKN; // ZKN requires RVB
    cfg.ZKN = CVA6Cfg.ZKN;
    cfg.RVV = CVA6Cfg.RVV;
    cfg.RVC = CVA6Cfg.RVC;
    cfg.RVH = CVA6Cfg.RVH;
    cfg.RVZCB = CVA6Cfg.RVZCB;
    cfg.RVZCMT = CVA6Cfg.RVZCMT;
    cfg.RVZCMP = CVA6Cfg.RVZCMP;
    cfg.XFVec = CVA6Cfg.XFVec;
    cfg.CvxifEn = CVA6Cfg.CvxifEn;
    cfg.CoproType = CVA6Cfg.CoproType;
    cfg.RVZiCond = CVA6Cfg.RVZiCond;
    cfg.RVZiCbom = CVA6Cfg.RVZiCbom;
    cfg.RVZiCboz = CVA6Cfg.RVZiCboz;
    cfg.RVZiCbop = CVA6Cfg.RVZiCbop;
    cfg.RVZicntr = CVA6Cfg.RVZicntr;
    cfg.RVZihpm = CVA6Cfg.RVZihpm;
    cfg.NR_SB_ENTRIES = CVA6Cfg.NrScoreboardEntries;
    // FSE S1: deepen in-flight window floor when DeepSpecEn (B3 companion).
    if (CVA6Cfg.DeepSpecEn) begin
      automatic int unsigned sb_floor = cfg.NrIssuePorts * 8;
      if (sb_floor < 16) sb_floor = 16;
      if (cfg.NR_SB_ENTRIES < sb_floor) cfg.NR_SB_ENTRIES = sb_floor;
    end
    cfg.TRANS_ID_BITS = $clog2(cfg.NR_SB_ENTRIES);

    cfg.FpPresent = bit'(FpPresent);
    cfg.NSX = bit'(NSX);
    cfg.FLen = unsigned'(FLen);
    cfg.RVFVec = bit'(RVFVec);
    cfg.XF16Vec = bit'(XF16Vec);
    cfg.XF16ALTVec = bit'(XF16ALTVec);
    cfg.XF8Vec = bit'(XF8Vec);
    // 2 read ports per issue slot (rs1/rs2). Zacas AMOCAS needs rd as a third
    // source (expected value) → 3 ports/slot when RVZacas. CVXIF also uses
    // OPERANDS_PER_INSTR==3 when NrRgprPorts/NrIssuePorts == 3.
    if (CVA6Cfg.RVZacas)
      cfg.NrRgprPorts = unsigned'(cfg.NrIssuePorts * 3);
    else
      cfg.NrRgprPorts = unsigned'(cfg.NrIssuePorts * 2);
    cfg.NrWbPorts = unsigned'(NrWbPorts);
    cfg.EnableAccelerator = bit'(EnableAccelerator);
    cfg.PerfCounterEn = CVA6Cfg.PerfCounterEn;
    cfg.MmuPresent = CVA6Cfg.MmuPresent;
    cfg.RVS = CVA6Cfg.RVS;
    cfg.RVU = CVA6Cfg.RVU;
    cfg.SoftwareInterruptEn = CVA6Cfg.SoftwareInterruptEn;

    cfg.HaltAddress = CVA6Cfg.HaltAddress;
    cfg.ExceptionAddress = CVA6Cfg.ExceptionAddress;
    cfg.RASDepth = CVA6Cfg.RASDepth;
    cfg.BTBEntries = CVA6Cfg.BTBEntries;
    cfg.BPType = CVA6Cfg.BPType;
    cfg.BHTEntries = CVA6Cfg.BHTEntries;
    cfg.BHTHist = CVA6Cfg.BHTHist;
    cfg.BPGhistLen = CVA6Cfg.BPGhistLen;
    cfg.BPTageTables = CVA6Cfg.BPTageTables;
    cfg.BPTageTableEntries = CVA6Cfg.BPTageTableEntries;
    cfg.BPTageTagBits = CVA6Cfg.BPTageTagBits;
    cfg.BPLoopEn = CVA6Cfg.BPLoopEn;
    cfg.BPIndirectEn = CVA6Cfg.BPIndirectEn;
    cfg.BPIndirectEntries = CVA6Cfg.BPIndirectEntries;
    cfg.BPStatCorEn = CVA6Cfg.BPStatCorEn;
    cfg.BPCkptDepth = CVA6Cfg.BPCkptDepth;
    // FSE S1: BP checkpoints must cover the speculative window.
    if (CVA6Cfg.DeepSpecEn) begin
      if (cfg.BPCkptDepth == 0 || cfg.BPCkptDepth < cfg.NR_SB_ENTRIES)
        cfg.BPCkptDepth = cfg.NR_SB_ENTRIES;
    end
    cfg.DmBaseAddress = CVA6Cfg.DmBaseAddress;
    cfg.TvalEn = CVA6Cfg.TvalEn;
    cfg.DirectVecOnly = CVA6Cfg.DirectVecOnly;
    cfg.NrPMPEntries = CVA6Cfg.NrPMPEntries;
    cfg.PMPCfgRstVal = CVA6Cfg.PMPCfgRstVal;
    cfg.PMPAddrRstVal = CVA6Cfg.PMPAddrRstVal;
    cfg.PMPEntryReadOnly = CVA6Cfg.PMPEntryReadOnly;
    cfg.PMPNapotEn = CVA6Cfg.PMPNapotEn;
    cfg.NOCType = CVA6Cfg.NOCType;
    cfg.NrNonIdempotentRules = CVA6Cfg.NrNonIdempotentRules;
    cfg.NonIdempotentAddrBase = CVA6Cfg.NonIdempotentAddrBase;
    cfg.NonIdempotentLength = CVA6Cfg.NonIdempotentLength;
    cfg.NrExecuteRegionRules = CVA6Cfg.NrExecuteRegionRules;
    cfg.ExecuteRegionAddrBase = CVA6Cfg.ExecuteRegionAddrBase;
    cfg.ExecuteRegionLength = CVA6Cfg.ExecuteRegionLength;
    cfg.NrCachedRegionRules = CVA6Cfg.NrCachedRegionRules;
    cfg.CachedRegionAddrBase = CVA6Cfg.CachedRegionAddrBase;
    cfg.CachedRegionLength = CVA6Cfg.CachedRegionLength;
    cfg.MaxOutstandingStores = CVA6Cfg.MaxOutstandingStores;
    // FSE S1: store outstanding floor (B1 companion; STQ depth derived in store_buffer).
    if (CVA6Cfg.DeepSpecEn) begin
      automatic int unsigned st_floor = cfg.NrIssuePorts * 4;
      if (st_floor < 8) st_floor = 8;
      if (st_floor > 16) st_floor = 16;  // check_cfg + STQ CAM cap
      if (cfg.MaxOutstandingStores < st_floor) cfg.MaxOutstandingStores = st_floor;
    end
    cfg.DebugEn = CVA6Cfg.DebugEn;
    cfg.SDTRIG = CVA6Cfg.SDTRIG;
    cfg.Mcontrol6 = CVA6Cfg.Mcontrol6;
    cfg.Icount = CVA6Cfg.Icount;
    cfg.Etrigger = CVA6Cfg.Etrigger;
    cfg.Itrigger = CVA6Cfg.Itrigger;
    cfg.NonIdemPotenceEn = (CVA6Cfg.NrNonIdempotentRules > 0) && (CVA6Cfg.NonIdempotentLength > 0);
    cfg.AxiBurstWriteEn = CVA6Cfg.AxiBurstWriteEn;

    cfg.ICACHE_SET_ASSOC = CVA6Cfg.IcacheSetAssoc;
    cfg.ICACHE_SET_ASSOC_WIDTH = CVA6Cfg.IcacheSetAssoc > 1 ? $clog2(CVA6Cfg.IcacheSetAssoc) :
        CVA6Cfg.IcacheSetAssoc;
    cfg.ICACHE_INDEX_WIDTH = ICACHE_INDEX_WIDTH;
    cfg.ICACHE_TAG_WIDTH = cfg.PLEN - ICACHE_INDEX_WIDTH;
    cfg.ICACHE_LINE_WIDTH = CVA6Cfg.IcacheLineWidth;
    cfg.ICACHE_USER_LINE_WIDTH = (CVA6Cfg.AxiUserWidth == 1) ? 4 : CVA6Cfg.IcacheLineWidth;
    cfg.DCacheType = CVA6Cfg.DCacheType;
    cfg.DcacheIdWidth = CVA6Cfg.DcacheIdWidth;
    cfg.DCACHE_SET_ASSOC = CVA6Cfg.DcacheSetAssoc;
    cfg.DCACHE_SET_ASSOC_WIDTH = CVA6Cfg.DcacheSetAssoc > 1 ? $clog2(CVA6Cfg.DcacheSetAssoc) :
        CVA6Cfg.DcacheSetAssoc;
    cfg.DCACHE_INDEX_WIDTH = DCACHE_INDEX_WIDTH;
    cfg.DCACHE_TAG_WIDTH = cfg.PLEN - DCACHE_INDEX_WIDTH;
    cfg.DCACHE_LINE_WIDTH = CVA6Cfg.DcacheLineWidth;
    cfg.DCACHE_USER_LINE_WIDTH = (CVA6Cfg.AxiUserWidth == 1) ? 4 : CVA6Cfg.DcacheLineWidth;
    cfg.DCACHE_USER_WIDTH = CVA6Cfg.AxiUserWidth;
    cfg.DCACHE_OFFSET_WIDTH = DCACHE_OFFSET_WIDTH;
    cfg.DCACHE_NUM_WORDS = 2 ** (DCACHE_INDEX_WIDTH - DCACHE_OFFSET_WIDTH);

    cfg.DCACHE_MAX_TX = unsigned'(2 ** CVA6Cfg.MemTidWidth);

    cfg.DcacheFlushOnFence = CVA6Cfg.DcacheFlushOnFence;
    cfg.DcacheFlushOnFenceI = CVA6Cfg.DcacheFlushOnFenceI;
    cfg.DcacheInvalidateOnFlush = CVA6Cfg.DcacheInvalidateOnFlush;

    cfg.DATA_USER_EN = CVA6Cfg.DataUserEn;
    cfg.WtDcacheWbufDepth = CVA6Cfg.WtDcacheWbufDepth;
    cfg.FETCH_USER_WIDTH = CVA6Cfg.FetchUserWidth;
    cfg.FETCH_USER_EN = CVA6Cfg.FetchUserEn;
    // Non-zero enables (DataUserEn/FetchUserEn are int unsigned enables).
    cfg.AXI_USER_EN = (CVA6Cfg.DataUserEn != 0) || (CVA6Cfg.FetchUserEn != 0);

    // Front-end bus: enough bits for NrIssuePorts compressed (16b) or full (32b)
    // instructions, rounded up to the next supported power-of-two width.
    // Hang-6: dual+FETCH32 still BADOFFSET — residual is issue/commit, not width.
    cfg.FETCH_WIDTH = build_fetch_width(cfg.NrIssuePorts, CVA6Cfg.RVC);
    cfg.FETCH_ALIGN_BITS = $clog2(cfg.FETCH_WIDTH / 8);
    cfg.INSTR_PER_FETCH = cfg.FETCH_WIDTH / (CVA6Cfg.RVC ? 16 : 32);
    cfg.LOG2_INSTR_PER_FETCH = cfg.INSTR_PER_FETCH > 1 ? $clog2(cfg.INSTR_PER_FETCH) : 1;

    cfg.ModeW = IS_XLEN32 ? 1 : 4;
    cfg.ASIDW = IS_XLEN32 ? 9 : 16;
    cfg.VMIDW = IS_XLEN32 ? 7 : 14;
    cfg.PPNW = IS_XLEN32 ? 22 : 44;
    cfg.GPPNW = IS_XLEN32 ? 22 : 29;
    cfg.MODE_SV = IS_XLEN32 ? config_pkg::ModeSv32 : config_pkg::ModeSv39;
    cfg.SV = (cfg.MODE_SV == config_pkg::ModeSv32) ? 32 : 39;
    cfg.SVX = (cfg.MODE_SV == config_pkg::ModeSv32) ? 34 : 41;
    cfg.InstrTlbEntries = CVA6Cfg.InstrTlbEntries;
    cfg.DataTlbEntries = CVA6Cfg.DataTlbEntries;
    cfg.UseSharedTlb = CVA6Cfg.UseSharedTlb;
    cfg.SvnapotEn = CVA6Cfg.SvnapotEn;
    cfg.SstcEn = CVA6Cfg.SstcEn;
    cfg.SscofpmfEn = CVA6Cfg.SscofpmfEn;
    cfg.ZihintpauseEn = CVA6Cfg.ZihintpauseEn;
    cfg.SvpbmtEn = CVA6Cfg.SvpbmtEn;
    cfg.ZawrsEn = CVA6Cfg.ZawrsEn;
    cfg.L2En = CVA6Cfg.L2En;
    // L2/L3 geometry filled later (auto-infer when 0); placeholder until then.
    cfg.L2ByteSize = CVA6Cfg.L2ByteSize;
    cfg.L2SetAssoc = CVA6Cfg.L2SetAssoc;
    cfg.L2LineWidth = CVA6Cfg.L2LineWidth;
    cfg.L2MshrDepth = CVA6Cfg.L2MshrDepth;
    cfg.L2DataBanks = CVA6Cfg.L2DataBanks;
    cfg.NrHarts = (CVA6Cfg.NrHarts == 0) ? unsigned'(1) : CVA6Cfg.NrHarts;
    cfg.SmtPolicy = CVA6Cfg.SmtPolicy;
    // Quantum 0 → 1 so NrHarts==1 configs stay legal without every package listing it.
    cfg.SmtFetchQuantum = (CVA6Cfg.SmtFetchQuantum == 0) ? unsigned'(1)
                                                         : CVA6Cfg.SmtFetchQuantum;
    cfg.SmtStarveLimit = CVA6Cfg.SmtStarveLimit;
    // Cluster size: 0 → 1 (single-core identity). Cap at CVA6_MAX_CORES.
    if (CVA6Cfg.NrCores == 0)
      cfg.NrCores = unsigned'(1);
    else if (CVA6Cfg.NrCores > config_pkg::CVA6_MAX_CORES)
      cfg.NrCores = config_pkg::CVA6_MAX_CORES;
    else
      cfg.NrCores = CVA6Cfg.NrCores;
    cfg.CohPolicy = CVA6Cfg.CohPolicy;
    cfg.SnoopFilterEn = CVA6Cfg.SnoopFilterEn;
    cfg.SnoopFilterEntries = CVA6Cfg.SnoopFilterEntries;
    // Multi-core defaults when depths left zero.
    cfg.CohInvalDepth = (CVA6Cfg.CohInvalDepth == 0 && cfg.NrCores > 1)
                            ? unsigned'(4) : CVA6Cfg.CohInvalDepth;
    cfg.CohAxiStarveLimit = (CVA6Cfg.CohAxiStarveLimit == 0 && cfg.NrCores > 1)
                            ? unsigned'(16) : CVA6Cfg.CohAxiStarveLimit;
    cfg.WayPredEn = CVA6Cfg.WayPredEn;
    cfg.WayPredEntries = CVA6Cfg.WayPredEntries;
    cfg.ReplPolicy = CVA6Cfg.ReplPolicy;
    cfg.HwPrefetchEn = CVA6Cfg.HwPrefetchEn;
    cfg.HwPrefetchStreams = CVA6Cfg.HwPrefetchStreams;
    cfg.DcacheMshrDepth = CVA6Cfg.DcacheMshrDepth;
    cfg.FtqDepth = CVA6Cfg.FtqDepth;
    cfg.FdipEn = CVA6Cfg.FdipEn;
    cfg.FdipDistance = CVA6Cfg.FdipDistance;
    cfg.LoopBufEn = CVA6Cfg.LoopBufEn;
    cfg.LoopBufEntries = CVA6Cfg.LoopBufEntries;
    cfg.SliceOoOEn = CVA6Cfg.SliceOoOEn;
    cfg.SliceIstEntries = CVA6Cfg.SliceIstEntries;
    cfg.SliceAiqDepth = CVA6Cfg.SliceAiqDepth;
    cfg.SliceBiqDepth = CVA6Cfg.SliceBiqDepth;
    cfg.SliceMaxRunahead = CVA6Cfg.SliceMaxRunahead;
    cfg.OoOEn = CVA6Cfg.OoOEn;
    // U5 geometry defaults when enabled and left zero.
    // Scale ROB/IQ/LSQ with issue width so 4-issue is not starved by 2-issue depths.
    if (CVA6Cfg.OoOEn) begin
      automatic int unsigned base_rob = CVA6Cfg.NrScoreboardEntries;
      automatic int unsigned wide_rob = cfg.NrIssuePorts * 16;
      if (wide_rob > base_rob) base_rob = wide_rob;
      cfg.RobEntries = (CVA6Cfg.RobEntries == 0) ? base_rob : CVA6Cfg.RobEntries;
      cfg.PrfEntries = (CVA6Cfg.PrfEntries == 0)
                           ? unsigned'(32 + cfg.RobEntries + cfg.NrIssuePorts * 4)
                           : CVA6Cfg.PrfEntries;
      cfg.IqEntries = (CVA6Cfg.IqEntries == 0)
                          ? ((cfg.RobEntries * 3) / 4)
                          : CVA6Cfg.IqEntries;
      if (cfg.IqEntries < cfg.NrIssuePorts * 4)
        cfg.IqEntries = cfg.NrIssuePorts * 4;
      cfg.LsqLoadEntries = (CVA6Cfg.LsqLoadEntries == 0)
                               ? (CVA6Cfg.NrLoadBufEntries > cfg.NrIssuePorts * 4
                                      ? CVA6Cfg.NrLoadBufEntries
                                      : cfg.NrIssuePorts * 4)
                               : CVA6Cfg.LsqLoadEntries;
      cfg.LsqStoreEntries = (CVA6Cfg.LsqStoreEntries == 0)
                                ? (CVA6Cfg.MaxOutstandingStores > cfg.NrIssuePorts * 4
                                       ? CVA6Cfg.MaxOutstandingStores
                                       : cfg.NrIssuePorts * 4)
                                : CVA6Cfg.LsqStoreEntries;
      cfg.OoORetireWidth = (CVA6Cfg.OoORetireWidth == 0) ? cfg.NrCommitPorts
                                                         : CVA6Cfg.OoORetireWidth;
    end else begin
      cfg.RobEntries = CVA6Cfg.RobEntries;
      cfg.PrfEntries = CVA6Cfg.PrfEntries;
      cfg.IqEntries = CVA6Cfg.IqEntries;
      cfg.LsqLoadEntries = CVA6Cfg.LsqLoadEntries;
      cfg.LsqStoreEntries = CVA6Cfg.LsqStoreEntries;
      cfg.OoORetireWidth = CVA6Cfg.OoORetireWidth;
    end
    // FSE S3 / U5 production: store-set on by default whenever full OoO is enabled
    // (can still force-off only by also disabling OoO). Explicit MemDepPredEn=1 keeps on for slice/etc.
    cfg.MemDepPredEn = CVA6Cfg.MemDepPredEn || CVA6Cfg.OoOEn;
    cfg.L3En = CVA6Cfg.L3En;
    // --- Shared L2/L3 geometry inference (0 = auto from NrCores) -------------
    // Model: shared inclusive L2 below private L1s, shared L3 below L2.
    //   L2 ≈ max(256 KiB, NrCores × 128 KiB), 8-way, 64 B line, MSHR ~ 4×cores
    //   L3 ≈ max(2 MiB,  NrCores × 1 MiB),   16-way, match L2 line, MSHR ~ 4×cores
    //   Prefetch streams ≈ max(4, 2×NrCores); snoop-filter entries ≈ 64×NrCores
    if (CVA6Cfg.L2En) begin
      if (CVA6Cfg.L2ByteSize == 0) begin
        automatic int unsigned l2 = cfg.NrCores * 32'd131072; // 128 KiB / core
        if (l2 < 32'd262144) l2 = 32'd262144;
        cfg.L2ByteSize = l2;
      end else begin
        cfg.L2ByteSize = CVA6Cfg.L2ByteSize;
      end
      cfg.L2SetAssoc = (CVA6Cfg.L2SetAssoc == 0) ? unsigned'(8) : CVA6Cfg.L2SetAssoc;
      cfg.L2LineWidth = (CVA6Cfg.L2LineWidth == 0) ? unsigned'(512) : CVA6Cfg.L2LineWidth;
      cfg.L2MshrDepth = (CVA6Cfg.L2MshrDepth == 0)
                            ? ((cfg.NrCores * 4) < 8 ? unsigned'(8) : cfg.NrCores * 4)
                            : CVA6Cfg.L2MshrDepth;
      cfg.L2DataBanks = (CVA6Cfg.L2DataBanks == 0)
                            ? ((cfg.NrCores < 4) ? unsigned'(4) : cfg.NrCores)
                            : CVA6Cfg.L2DataBanks;
    end else begin
      cfg.L2ByteSize = CVA6Cfg.L2ByteSize;
      cfg.L2SetAssoc = CVA6Cfg.L2SetAssoc;
      cfg.L2LineWidth = CVA6Cfg.L2LineWidth;
      cfg.L2MshrDepth = CVA6Cfg.L2MshrDepth;
      cfg.L2DataBanks = CVA6Cfg.L2DataBanks;
    end
    if (CVA6Cfg.L3En) begin
      if (CVA6Cfg.L3ByteSize == 0) begin
        automatic int unsigned l3 = cfg.NrCores * 32'd1048576; // 1 MiB / core
        if (l3 < 32'd2097152) l3 = 32'd2097152;
        cfg.L3ByteSize = l3;
      end else begin
        cfg.L3ByteSize = CVA6Cfg.L3ByteSize;
      end
      cfg.L3SetAssoc = (CVA6Cfg.L3SetAssoc == 0) ? unsigned'(16) : CVA6Cfg.L3SetAssoc;
      // Match L2 line when either side is auto/0
      if (CVA6Cfg.L3LineWidth == 0)
        cfg.L3LineWidth = cfg.L2LineWidth != 0 ? cfg.L2LineWidth : unsigned'(512);
      else
        cfg.L3LineWidth = CVA6Cfg.L3LineWidth;
      cfg.L3MshrDepth = (CVA6Cfg.L3MshrDepth == 0)
                            ? ((cfg.NrCores * 4) < 16 ? unsigned'(16) : cfg.NrCores * 4)
                            : CVA6Cfg.L3MshrDepth;
      cfg.L3DataBanks = (CVA6Cfg.L3DataBanks == 0)
                            ? ((cfg.NrCores * 2) < 8 ? unsigned'(8) : cfg.NrCores * 2)
                            : CVA6Cfg.L3DataBanks;
    end else begin
      cfg.L3ByteSize = CVA6Cfg.L3ByteSize;
      cfg.L3SetAssoc = CVA6Cfg.L3SetAssoc;
      cfg.L3LineWidth = CVA6Cfg.L3LineWidth;
      cfg.L3MshrDepth = CVA6Cfg.L3MshrDepth;
      cfg.L3DataBanks = CVA6Cfg.L3DataBanks;
    end
    // Multi-core snoop-filter / prefetch defaults when left zero
    if (cfg.NrCores > 1 && CVA6Cfg.SnoopFilterEn && CVA6Cfg.SnoopFilterEntries == 0)
      cfg.SnoopFilterEntries = cfg.NrCores * 64;
    else
      cfg.SnoopFilterEntries = CVA6Cfg.SnoopFilterEntries;
    cfg.ServerPrefetchEn = CVA6Cfg.ServerPrefetchEn;
    if (CVA6Cfg.ServerPrefetchEn && CVA6Cfg.ServerPfStreams == 0) begin
      automatic int unsigned pfs = cfg.NrCores * 2;
      cfg.ServerPfStreams = (pfs < 4) ? unsigned'(4) : pfs;
    end else begin
      cfg.ServerPfStreams = CVA6Cfg.ServerPfStreams;
    end
    cfg.ServerPfDistance = (CVA6Cfg.ServerPfDistance == 0 && CVA6Cfg.ServerPrefetchEn)
                               ? unsigned'(2) : CVA6Cfg.ServerPfDistance;
    cfg.SharedTlbDepth = CVA6Cfg.SharedTlbDepth;
    cfg.VpnLen = VpnLen;
    cfg.PtLevels = PtLevels;

    cfg.X_NUM_RS = cfg.NrRgprPorts / cfg.NrIssuePorts;
    cfg.X_ID_WIDTH = cfg.TRANS_ID_BITS;
    cfg.X_RFR_WIDTH = cfg.XLEN;
    cfg.X_RFW_WIDTH = cfg.XLEN;
    cfg.X_NUM_HARTS = 1;
    cfg.X_HARTID_WIDTH = cfg.XLEN;
    cfg.X_DUALREAD = 0;
    cfg.X_DUALWRITE = 0;
    cfg.X_ISSUE_REGISTER_SPLIT = 0;

    return cfg;
  endfunction

endpackage
