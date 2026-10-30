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
    while (fw < min_bits && fw < config_pkg::G6LC_MAX_FETCH_WIDTH) fw = fw << 1;
    return fw;
  endfunction

  function automatic config_pkg::g6lc_cfg_t build_config(config_pkg::g6lc_user_cfg_t G6LCCfg);
    bit IS_XLEN32 = (G6LCCfg.XLEN == 32) ? 1'b1 : 1'b0;
    bit IS_XLEN64 = (G6LCCfg.XLEN == 32) ? 1'b0 : 1'b1;
    bit FpPresent = G6LCCfg.RVF | G6LCCfg.RVD | G6LCCfg.XF16 | G6LCCfg.XF16ALT | G6LCCfg.XF8;
    bit NSX = G6LCCfg.XF16 | G6LCCfg.XF16ALT | G6LCCfg.XF8 | G6LCCfg.XFVec;  // Are non-standard extensions present?
    int unsigned FLen = G6LCCfg.RVD ? 64 :  // D ext.
    G6LCCfg.RVF ? 32 :  // F ext.
    G6LCCfg.XF16 ? 16 :  // Xf16 ext.
    G6LCCfg.XF16ALT ? 16 :  // Xf16alt ext.
    G6LCCfg.XF8 ? 8 :  // Xf8 ext.
    1;  // Unused in case of no FP

    // Transprecision floating-point extensions configuration
    bit RVFVec     = G6LCCfg.RVF     & G6LCCfg.XFVec & FLen>32; // FP32 vectors available if vectors and larger fmt enabled
    bit XF16Vec    = G6LCCfg.XF16    & G6LCCfg.XFVec & FLen>16; // FP16 vectors available if vectors and larger fmt enabled
    bit XF16ALTVec = G6LCCfg.XF16ALT & G6LCCfg.XFVec & FLen>16; // FP16ALT vectors available if vectors and larger fmt enabled
    bit XF8Vec     = G6LCCfg.XF8     & G6LCCfg.XFVec & FLen>8;  // FP8 vectors available if vectors and larger fmt enabled

    bit EnableAccelerator = G6LCCfg.RVV;  // Currently only used by V extension (Ara)
    // The AI overlay (+define+G6LC_AI_OVERLAY, see the AiCfg block below) turns the
    // CVXIF seam on for the selected package; the writeback-port count must see
    // that decision here, before the derived widths are fixed.
`ifdef G6LC_AI_OVERLAY
    bit CvxifEnEff = 1'b1;
`else
    bit CvxifEnEff = G6LCCfg.CvxifEn;
`endif
    int unsigned NrWbPorts = (CvxifEnEff || EnableAccelerator) ? 5 : 4;

    int unsigned ICACHE_INDEX_WIDTH = $clog2(G6LCCfg.IcacheByteSize / G6LCCfg.IcacheSetAssoc);
    int unsigned DCACHE_INDEX_WIDTH = $clog2(G6LCCfg.DcacheByteSize / G6LCCfg.DcacheSetAssoc);
    int unsigned DCACHE_OFFSET_WIDTH = $clog2(G6LCCfg.DcacheLineWidth / 8);

    // MMU
    int unsigned VpnLen = IS_XLEN64 ? (G6LCCfg.RVH ? 29 : 27) : 20;
    int unsigned PtLevels = IS_XLEN64 ? 3 : 2;

    config_pkg::g6lc_cfg_t cfg;

    cfg.XLEN = G6LCCfg.XLEN;
    cfg.VLEN = G6LCCfg.VLEN;
    cfg.PLEN = IS_XLEN32 ? 34 : 56;
    cfg.GPLEN = IS_XLEN32 ? 34 : 41;
    cfg.IS_XLEN32 = IS_XLEN32;
    cfg.IS_XLEN64 = IS_XLEN64;
    cfg.XLEN_ALIGN_BYTES = $clog2(G6LCCfg.XLEN / 8);
    cfg.ASID_WIDTH = IS_XLEN64 ? 16 : 1;
    cfg.VMID_WIDTH = IS_XLEN64 ? 14 : 1;

    cfg.FpgaEn = G6LCCfg.FpgaEn;
    cfg.FpgaAlteraEn = G6LCCfg.FpgaAlteraEn;
    cfg.TechnoCut = G6LCCfg.TechnoCut;

    cfg.SuperscalarEn = G6LCCfg.SuperscalarEn;
    // Issue width: explicit 1..8, or auto from SuperscalarEn (legacy: SS→2, else 1).
    // This is a pipeline width, never a software-visible hart: the logical hart
    // count the DTS and OpenSBI see is NrCores * NrHarts.
    if (G6LCCfg.NrIssuePorts == 0) begin
      cfg.NrIssuePorts = unsigned'(G6LCCfg.SuperscalarEn ? 2 : 1);
    end else begin
      cfg.NrIssuePorts = G6LCCfg.NrIssuePorts;
    end
    // Commit ports: keep user value if wide enough; else match issue width under SS.
    // Hang-6: NrCommitPorts=1 under dual still BADOFFSET — not dual-commit residual.
    if (G6LCCfg.SuperscalarEn) begin
      if (G6LCCfg.NrCommitPorts >= cfg.NrIssuePorts)
        cfg.NrCommitPorts = G6LCCfg.NrCommitPorts;
      else if (G6LCCfg.NrCommitPorts >= 2)
        cfg.NrCommitPorts = G6LCCfg.NrCommitPorts;  // allow commit < issue
      else
        cfg.NrCommitPorts = cfg.NrIssuePorts > 2 ? cfg.NrIssuePorts : unsigned'(2);
    end else begin
      cfg.NrCommitPorts = G6LCCfg.NrCommitPorts;
    end
    // Speculative SB: younger cancel + speculative-load LSU gates.
    // cont.14: do NOT couple SpeculativeSb to SuperscalarEn alone.
    // True SI (SS=0 ⇒ SpeculativeSb was 0) advances OpenSBI past path_offset;
    // DI+force-SI with SpeculativeSb=1 still returned -4. Speculative LSU
    // gating (is_speculative_load / STQ interlocks) is the residual. Keep
    // SpeculativeSb for OoO/DeepSpec only until the FDT walk is clean under SS.
    // Hang-6 note: SpeculativeSb alone was not the *only* BADOFFSET cause then;
    // cont.14 shows it is necessary for stock /cpus with current STQ RTL.
    cfg.SpeculativeSb = G6LCCfg.SliceOoOEn || G6LCCfg.OoOEn || G6LCCfg.DeepSpecEn;
    cfg.DeepSpecEn = G6LCCfg.DeepSpecEn;

    // Dual ALU minimum under SS; scale toward issue width (cap 4 for area).
    // Hang-6: NrALUs=1 under dual still BADOFFSET — not dual-ALU residual.
    if (G6LCCfg.SuperscalarEn) begin
      cfg.NrALUs = (cfg.NrIssuePorts >= 4) ? unsigned'(4) :
                   (cfg.NrIssuePorts >= 2) ? unsigned'(2) : unsigned'(1);
    end else begin
      cfg.NrALUs = unsigned'(1);
    end
    cfg.ALUBypass = G6LCCfg.SuperscalarEn ? bit'(G6LCCfg.ALUBypass) : bit'(0);

    cfg.NrLoadPipeRegs = G6LCCfg.NrLoadPipeRegs;
    cfg.NrStorePipeRegs = G6LCCfg.NrStorePipeRegs;
    cfg.AxiAddrWidth = G6LCCfg.AxiAddrWidth;
    cfg.AxiDataWidth = G6LCCfg.AxiDataWidth;
    cfg.AxiIdWidth = G6LCCfg.AxiIdWidth;
    cfg.AxiUserWidth = G6LCCfg.AxiUserWidth;
    cfg.MEM_TID_WIDTH = G6LCCfg.MemTidWidth;
    cfg.NrLoadBufEntries = G6LCCfg.NrLoadBufEntries;
    // FSE S1: raise load-buffer floor for MLP when DeepSpecEn (B2).
    if (G6LCCfg.DeepSpecEn) begin
      automatic int unsigned load_floor = cfg.NrIssuePorts * 4;
      if (load_floor < 8) load_floor = 8;
      if (cfg.NrLoadBufEntries < load_floor) cfg.NrLoadBufEntries = load_floor;
    end
    cfg.RVF = G6LCCfg.RVF;
    cfg.RVD = G6LCCfg.RVD;
    cfg.XF16 = G6LCCfg.XF16;
    cfg.XF16ALT = G6LCCfg.XF16ALT;
    cfg.XF8 = G6LCCfg.XF8;
    cfg.RVA = G6LCCfg.RVA;
    // Zacas requires Zaamo/A (RVA). Illegal if set without RVA — check_cfg asserts.
    cfg.RVZacas = G6LCCfg.RVZacas && G6LCCfg.RVA;
    cfg.RVB = G6LCCfg.RVB || G6LCCfg.ZKN; // ZKN requires RVB
    cfg.ZKN = G6LCCfg.ZKN;
    cfg.RVV = G6LCCfg.RVV;
    cfg.RVC = G6LCCfg.RVC;
    cfg.RVH = G6LCCfg.RVH;
    cfg.RVZCB = G6LCCfg.RVZCB;
    cfg.RVZCMT = G6LCCfg.RVZCMT;
    cfg.RVZCMP = G6LCCfg.RVZCMP;
    cfg.XFVec = G6LCCfg.XFVec;
    cfg.CvxifEn = CvxifEnEff;
    cfg.CoproType = G6LCCfg.CoproType;
    // Xg6lcai AI matrix plane. Copied through, then normalised so a package can
    // leave sizing at 0 and get a legal default. When MatrixEn is 0 the whole
    // group stays zero, which is what every non-AI package elaborates with.
    cfg.AiCfg = G6LCCfg.AiCfg;
    // AI overlay (2026-10-01): `+define+G6LC_AI_OVERLAY` gives ANY package the
    // canonical island plane (config_pkg::AiCfgIsland, or the integer strip with
    // +define+G6LC_AI_OVERLAY_INT / on a core without RVF+RVD) and the CVXIF
    // coprocessor that drives it. The macro lives here, in the derivation, never
    // in a *_config_pkg.sv: the QEMU / sv-timing readers parse packages without
    // evaluating macros, and a package must state exactly one design. Pinned
    // `<pkg>_ai` packages (generated by build-platform `ai-overlay pin`) are the
    // shareable form of an overlay build.
`ifdef G6LC_AI_OVERLAY
    if (!G6LCCfg.AiCfg.MatrixEn) begin
`ifdef G6LC_AI_OVERLAY_INT
      cfg.AiCfg = config_pkg::ai_cfg_overlay(G6LCCfg.RVF, G6LCCfg.RVD, 1'b1);
`else
      cfg.AiCfg = config_pkg::ai_cfg_overlay(G6LCCfg.RVF, G6LCCfg.RVD, 1'b0);
`endif
      cfg.CvxifEn = 1'b1;
      cfg.CoproType = config_pkg::COPRO_G6LC_AI;
    end
`endif
    if (cfg.AiCfg.MatrixEn) begin
      if (cfg.AiCfg.TileM == 0) cfg.AiCfg.TileM = unsigned'(8);
      if (cfg.AiCfg.TileN == 0) cfg.AiCfg.TileN = unsigned'(8);
      if (cfg.AiCfg.TileK == 0) cfg.AiCfg.TileK = unsigned'(8);
      if (cfg.AiCfg.TileCount == 0) cfg.AiCfg.TileCount = unsigned'(8);
      if (cfg.AiCfg.AccDepth == 0) cfg.AiCfg.AccDepth = unsigned'(4);
      // One accumulator bank per hart: an AI-heavy hart must not be able to
      // starve the control hart (architecture/ai-matrix/README.md s5).
      if (cfg.AiCfg.AccBanks < G6LCCfg.NrHarts) cfg.AiCfg.AccBanks = G6LCCfg.NrHarts;
      if (cfg.AiCfg.AccBanks == 0) cfg.AiCfg.AccBanks = unsigned'(1);
      // Rings are optional; size them only if the package asked for any.
      if (cfg.AiCfg.Queues > 0 && cfg.AiCfg.QueueDepth == 0)
        cfg.AiCfg.QueueDepth = unsigned'(64);
      // At least one scheduling class exists wherever rings do, so the s7.1
      // arbiter always has a well-defined default (plain round-robin).
      if (cfg.AiCfg.Queues > 0 && cfg.AiCfg.QosClasses == 0)
        cfg.AiCfg.QosClasses = unsigned'(1);
      if (cfg.AiCfg.Queues == 0) cfg.AiCfg.QosClasses = unsigned'(0);
      // Native tile load/store requires the accelerator memory port; the CVXIF
      // seam has none (core/cvxif_fu.sv), so force it off rather than trapping
      // a legal-looking package at check_cfg.
      if (!cfg.AiCfg.AccelEn) cfg.AiCfg.TileLdEn = 1'b0;
    end
    cfg.RVZiCond = G6LCCfg.RVZiCond;
    cfg.RVZiCbom = G6LCCfg.RVZiCbom;
    cfg.RVZiCboz = G6LCCfg.RVZiCboz;
    cfg.RVZiCbop = G6LCCfg.RVZiCbop;
    cfg.RVZicntr = G6LCCfg.RVZicntr;
    cfg.RVZihpm = G6LCCfg.RVZihpm;
    cfg.NR_SB_ENTRIES = G6LCCfg.NrScoreboardEntries;
    // FSE S1: deepen in-flight window floor when DeepSpecEn (B3 companion).
    if (G6LCCfg.DeepSpecEn) begin
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
    if (G6LCCfg.RVZacas)
      cfg.NrRgprPorts = unsigned'(cfg.NrIssuePorts * 3);
    else
      cfg.NrRgprPorts = unsigned'(cfg.NrIssuePorts * 2);
    cfg.NrWbPorts = unsigned'(NrWbPorts);
    cfg.EnableAccelerator = bit'(EnableAccelerator);
    cfg.PerfCounterEn = G6LCCfg.PerfCounterEn;
    cfg.MmuPresent = G6LCCfg.MmuPresent;
    cfg.RVS = G6LCCfg.RVS;
    cfg.RVU = G6LCCfg.RVU;
    cfg.SoftwareInterruptEn = G6LCCfg.SoftwareInterruptEn;

    cfg.HaltAddress = G6LCCfg.HaltAddress;
    cfg.ExceptionAddress = G6LCCfg.ExceptionAddress;
    cfg.RASDepth = G6LCCfg.RASDepth;
    cfg.BTBEntries = G6LCCfg.BTBEntries;
    cfg.BPType = G6LCCfg.BPType;
    cfg.BHTEntries = G6LCCfg.BHTEntries;
    cfg.BHTHist = G6LCCfg.BHTHist;
    cfg.BPGhistLen = G6LCCfg.BPGhistLen;
    cfg.BPTageTables = G6LCCfg.BPTageTables;
    cfg.BPTageTableEntries = G6LCCfg.BPTageTableEntries;
    cfg.BPTageTagBits = G6LCCfg.BPTageTagBits;
    cfg.BPLoopEn = G6LCCfg.BPLoopEn;
    cfg.BPIndirectEn = G6LCCfg.BPIndirectEn;
    cfg.BPIndirectEntries = G6LCCfg.BPIndirectEntries;
    cfg.BPStatCorEn = G6LCCfg.BPStatCorEn;
    cfg.BPCkptDepth = G6LCCfg.BPCkptDepth;
    cfg.BPBaseHash = G6LCCfg.BPBaseHash;
    // FSE S1: BP checkpoints must cover the speculative window.
    if (G6LCCfg.DeepSpecEn) begin
      if (cfg.BPCkptDepth == 0 || cfg.BPCkptDepth < cfg.NR_SB_ENTRIES)
        cfg.BPCkptDepth = cfg.NR_SB_ENTRIES;
    end
    cfg.DmBaseAddress = G6LCCfg.DmBaseAddress;
    cfg.TvalEn = G6LCCfg.TvalEn;
    cfg.DirectVecOnly = G6LCCfg.DirectVecOnly;
    cfg.NrPMPEntries = G6LCCfg.NrPMPEntries;
    cfg.PMPCfgRstVal = G6LCCfg.PMPCfgRstVal;
    cfg.PMPAddrRstVal = G6LCCfg.PMPAddrRstVal;
    cfg.PMPEntryReadOnly = G6LCCfg.PMPEntryReadOnly;
    cfg.PMPNapotEn = G6LCCfg.PMPNapotEn;
    cfg.NOCType = G6LCCfg.NOCType;
    cfg.NrNonIdempotentRules = G6LCCfg.NrNonIdempotentRules;
    cfg.NonIdempotentAddrBase = G6LCCfg.NonIdempotentAddrBase;
    cfg.NonIdempotentLength = G6LCCfg.NonIdempotentLength;
    cfg.NrExecuteRegionRules = G6LCCfg.NrExecuteRegionRules;
    cfg.ExecuteRegionAddrBase = G6LCCfg.ExecuteRegionAddrBase;
    cfg.ExecuteRegionLength = G6LCCfg.ExecuteRegionLength;
    cfg.NrCachedRegionRules = G6LCCfg.NrCachedRegionRules;
    cfg.CachedRegionAddrBase = G6LCCfg.CachedRegionAddrBase;
    cfg.CachedRegionLength = G6LCCfg.CachedRegionLength;
    cfg.MaxOutstandingStores = G6LCCfg.MaxOutstandingStores;
    // FSE S1: store outstanding floor (B1 companion; STQ depth derived in store_buffer).
    if (G6LCCfg.DeepSpecEn) begin
      automatic int unsigned st_floor = cfg.NrIssuePorts * 4;
      if (st_floor < 8) st_floor = 8;
      if (st_floor > 16) st_floor = 16;  // check_cfg + STQ CAM cap
      if (cfg.MaxOutstandingStores < st_floor) cfg.MaxOutstandingStores = st_floor;
    end
    cfg.DebugEn = G6LCCfg.DebugEn;
    cfg.SDTRIG = G6LCCfg.SDTRIG;
    cfg.Mcontrol6 = G6LCCfg.Mcontrol6;
    cfg.Icount = G6LCCfg.Icount;
    cfg.Etrigger = G6LCCfg.Etrigger;
    cfg.Itrigger = G6LCCfg.Itrigger;
    cfg.NonIdemPotenceEn = (G6LCCfg.NrNonIdempotentRules > 0) && (G6LCCfg.NonIdempotentLength > 0);
    cfg.AxiBurstWriteEn = G6LCCfg.AxiBurstWriteEn;

    cfg.ICACHE_SET_ASSOC = G6LCCfg.IcacheSetAssoc;
    cfg.ICACHE_SET_ASSOC_WIDTH = G6LCCfg.IcacheSetAssoc > 1 ? $clog2(G6LCCfg.IcacheSetAssoc) :
        G6LCCfg.IcacheSetAssoc;
    cfg.ICACHE_INDEX_WIDTH = ICACHE_INDEX_WIDTH;
    cfg.ICACHE_TAG_WIDTH = cfg.PLEN - ICACHE_INDEX_WIDTH;
    cfg.ICACHE_LINE_WIDTH = G6LCCfg.IcacheLineWidth;
    cfg.ICACHE_USER_LINE_WIDTH = (G6LCCfg.AxiUserWidth == 1) ? 4 : G6LCCfg.IcacheLineWidth;
    cfg.DCacheType = G6LCCfg.DCacheType;
    cfg.DcacheIdWidth = G6LCCfg.DcacheIdWidth;
    cfg.DCACHE_SET_ASSOC = G6LCCfg.DcacheSetAssoc;
    cfg.DCACHE_SET_ASSOC_WIDTH = G6LCCfg.DcacheSetAssoc > 1 ? $clog2(G6LCCfg.DcacheSetAssoc) :
        G6LCCfg.DcacheSetAssoc;
    cfg.DCACHE_INDEX_WIDTH = DCACHE_INDEX_WIDTH;
    cfg.DCACHE_TAG_WIDTH = cfg.PLEN - DCACHE_INDEX_WIDTH;
    cfg.DCACHE_LINE_WIDTH = G6LCCfg.DcacheLineWidth;
    cfg.DCACHE_USER_LINE_WIDTH = (G6LCCfg.AxiUserWidth == 1) ? 4 : G6LCCfg.DcacheLineWidth;
    cfg.DCACHE_USER_WIDTH = G6LCCfg.AxiUserWidth;
    cfg.DCACHE_OFFSET_WIDTH = DCACHE_OFFSET_WIDTH;
    cfg.DCACHE_NUM_WORDS = 2 ** (DCACHE_INDEX_WIDTH - DCACHE_OFFSET_WIDTH);

    cfg.DCACHE_MAX_TX = unsigned'(2 ** G6LCCfg.MemTidWidth);

    cfg.DcacheFlushOnFence = G6LCCfg.DcacheFlushOnFence;
    cfg.DcacheFlushOnFenceI = G6LCCfg.DcacheFlushOnFenceI;
    cfg.DcacheInvalidateOnFlush = G6LCCfg.DcacheInvalidateOnFlush;

    cfg.DATA_USER_EN = G6LCCfg.DataUserEn;
    cfg.WtDcacheWbufDepth = G6LCCfg.WtDcacheWbufDepth;
    cfg.WtDcacheFixupDepth = G6LCCfg.WtDcacheFixupDepth;
    cfg.WtDcacheFixupVoidKeepEn = G6LCCfg.WtDcacheFixupVoidKeepEn;
    cfg.FETCH_USER_WIDTH = G6LCCfg.FetchUserWidth;
    cfg.FETCH_USER_EN = G6LCCfg.FetchUserEn;
    // Non-zero enables (DataUserEn/FetchUserEn are int unsigned enables).
    cfg.AXI_USER_EN = ((G6LCCfg.DataUserEn != 0) || (G6LCCfg.FetchUserEn != 0)) ? 1 : 0;

    // Front-end bus: enough bits for NrIssuePorts compressed (16b) or full (32b)
    // instructions, rounded up to the next supported power-of-two width.
    // Hang-6: dual+FETCH32 still BADOFFSET — residual is issue/commit, not width.
    cfg.FETCH_WIDTH = (G6LCCfg.FetchWidth != 0) ? G6LCCfg.FetchWidth
                                               : build_fetch_width(cfg.NrIssuePorts, G6LCCfg.RVC);
    cfg.FETCH_ALIGN_BITS = $clog2(cfg.FETCH_WIDTH / 8);
    cfg.INSTR_PER_FETCH = cfg.FETCH_WIDTH / (G6LCCfg.RVC ? 16 : 32);
    cfg.LOG2_INSTR_PER_FETCH = cfg.INSTR_PER_FETCH > 1 ? $clog2(cfg.INSTR_PER_FETCH) : 1;

    cfg.ModeW = IS_XLEN32 ? 1 : 4;
    cfg.ASIDW = IS_XLEN32 ? 9 : 16;
    cfg.VMIDW = IS_XLEN32 ? 7 : 14;
    cfg.PPNW = IS_XLEN32 ? 22 : 44;
    cfg.GPPNW = IS_XLEN32 ? 22 : 29;
    cfg.MODE_SV = IS_XLEN32 ? config_pkg::ModeSv32 : config_pkg::ModeSv39;
    cfg.SV = (cfg.MODE_SV == config_pkg::ModeSv32) ? 32 : 39;
    cfg.SVX = (cfg.MODE_SV == config_pkg::ModeSv32) ? 34 : 41;
    cfg.InstrTlbEntries = G6LCCfg.InstrTlbEntries;
    cfg.DataTlbEntries = G6LCCfg.DataTlbEntries;
    cfg.UseSharedTlb = G6LCCfg.UseSharedTlb;
    cfg.SvnapotEn = G6LCCfg.SvnapotEn;
    cfg.SstcEn = G6LCCfg.SstcEn;
    cfg.SscofpmfEn = G6LCCfg.SscofpmfEn;
    cfg.ZihintpauseEn = G6LCCfg.ZihintpauseEn;
    cfg.SvpbmtEn = G6LCCfg.SvpbmtEn;
    cfg.ZawrsEn = G6LCCfg.ZawrsEn;
    cfg.L2En = G6LCCfg.L2En;
    // L2/L3 geometry filled later (auto-infer when 0); placeholder until then.
    cfg.L2ByteSize = G6LCCfg.L2ByteSize;
    cfg.L2SetAssoc = G6LCCfg.L2SetAssoc;
    cfg.L2LineWidth = G6LCCfg.L2LineWidth;
    cfg.L2MshrDepth = G6LCCfg.L2MshrDepth;
    cfg.L2DataBanks = G6LCCfg.L2DataBanks;
    cfg.L2RoundRobinEn = G6LCCfg.L2RoundRobinEn;
    cfg.NrHarts = (G6LCCfg.NrHarts == 0) ? unsigned'(1) : G6LCCfg.NrHarts;
    cfg.SmtPolicy = G6LCCfg.SmtPolicy;
    // Quantum 0 → 1 so NrHarts==1 configs stay legal without every package listing it.
    cfg.SmtFetchQuantum = (G6LCCfg.SmtFetchQuantum == 0) ? unsigned'(1)
                                                         : G6LCCfg.SmtFetchQuantum;
    cfg.SmtStarveLimit = G6LCCfg.SmtStarveLimit;
    cfg.CoreSleepGate = G6LCCfg.CoreSleepGate;
    // Cluster size: 0 → 1 (single-core identity). Cap at G6LC_MAX_CORES.
    if (G6LCCfg.NrCores == 0)
      cfg.NrCores = unsigned'(1);
    else if (G6LCCfg.NrCores > config_pkg::G6LC_MAX_CORES)
      cfg.NrCores = config_pkg::G6LC_MAX_CORES;
    else
      cfg.NrCores = G6LCCfg.NrCores;
    cfg.CohPolicy = G6LCCfg.CohPolicy;
    cfg.SnoopFilterEn = G6LCCfg.SnoopFilterEn;
    cfg.SnoopFilterEntries = G6LCCfg.SnoopFilterEntries;
    // Multi-core defaults when depths left zero.
    cfg.CohInvalDepth = (G6LCCfg.CohInvalDepth == 0 && cfg.NrCores > 1)
                            ? unsigned'(4) : G6LCCfg.CohInvalDepth;
    cfg.CohAxiStarveLimit = (G6LCCfg.CohAxiStarveLimit == 0 && cfg.NrCores > 1)
                            ? unsigned'(16) : G6LCCfg.CohAxiStarveLimit;
    // Hub shared AR/AW slots. 0 selects max(4, 2 per core), capped at 14
    // so FILL_ID and one spare stay free in the 4-bit mem-side ID space.
    // A single core and a 2-core stream stay at 4. Four cores get 8.
    // Eight cores get 14. An explicit package value is left alone.
    begin
      int unsigned coh_slots;
      coh_slots = cfg.NrCores * 2;
      if (coh_slots < 4) coh_slots = 4;
      if (coh_slots > 14) coh_slots = 14;
      cfg.CohMaxOutstanding = (G6LCCfg.CohMaxOutstanding == 0)
                            ? coh_slots : G6LCCfg.CohMaxOutstanding;
    end
    cfg.WayPredEn = G6LCCfg.WayPredEn;
    cfg.WayPredEntries = G6LCCfg.WayPredEntries;
    cfg.ReplPolicy = G6LCCfg.ReplPolicy;
    cfg.HwPrefetchEn = G6LCCfg.HwPrefetchEn;
    cfg.HwPrefetchStreams = G6LCCfg.HwPrefetchStreams;
    cfg.DcacheMshrDepth = G6LCCfg.DcacheMshrDepth;
    cfg.FtqDepth = G6LCCfg.FtqDepth;
    cfg.FdipEn = G6LCCfg.FdipEn;
    cfg.FdipDistance = G6LCCfg.FdipDistance;
    cfg.LoopBufEn = G6LCCfg.LoopBufEn;
    cfg.LoopBufEntries = G6LCCfg.LoopBufEntries;
    cfg.SliceOoOEn = G6LCCfg.SliceOoOEn;
    cfg.SliceIstEntries = G6LCCfg.SliceIstEntries;
    cfg.SliceAiqDepth = G6LCCfg.SliceAiqDepth;
    cfg.SliceBiqDepth = G6LCCfg.SliceBiqDepth;
    cfg.SliceMaxRunahead = G6LCCfg.SliceMaxRunahead;
    cfg.OoOEn = G6LCCfg.OoOEn;
    cfg.SmtDrainedHandoff = G6LCCfg.SmtDrainedHandoff;
    cfg.SmtDrainForceCycles = G6LCCfg.SmtDrainForceCycles;
    // U5 geometry defaults when enabled and left zero.
    // Scale ROB/IQ/load-LSQ with issue width; store credits follow reservation depth.
    if (G6LCCfg.OoOEn) begin
      automatic int unsigned base_rob = G6LCCfg.NrScoreboardEntries;
      automatic int unsigned wide_rob = cfg.NrIssuePorts * 16;
      automatic int unsigned spec_store_n;
      if (wide_rob > base_rob) base_rob = wide_rob;
      cfg.RobEntries = (G6LCCfg.RobEntries == 0) ? base_rob : G6LCCfg.RobEntries;
      cfg.PrfEntries = (G6LCCfg.PrfEntries == 0)
                           ? unsigned'(32 + cfg.RobEntries + cfg.NrIssuePorts * 4)
                           : G6LCCfg.PrfEntries;
      cfg.IqEntries = (G6LCCfg.IqEntries == 0)
                          ? ((cfg.RobEntries * 3) / 4)
                          : G6LCCfg.IqEntries;
      if (cfg.IqEntries < cfg.NrIssuePorts * 4)
        cfg.IqEntries = cfg.NrIssuePorts * 4;
      cfg.LsqLoadEntries = (G6LCCfg.LsqLoadEntries == 0)
                               ? (G6LCCfg.NrLoadBufEntries > cfg.NrIssuePorts * 4
                                      ? G6LCCfg.NrLoadBufEntries
                                      : cfg.NrIssuePorts * 4)
                               : G6LCCfg.LsqLoadEntries;
      spec_store_n = !cfg.DeepSpecEn ? 4 :
                     (cfg.MaxOutstandingStores <= 4) ? 4 :
                     (cfg.MaxOutstandingStores <= 8) ? 8 : 16;
      cfg.LsqStoreEntries = (G6LCCfg.LsqStoreEntries == 0)
                                ? spec_store_n
                                : G6LCCfg.LsqStoreEntries;
      cfg.OoORetireWidth = (G6LCCfg.OoORetireWidth == 0) ? cfg.NrCommitPorts
                                                         : G6LCCfg.OoORetireWidth;
    end else begin
      cfg.RobEntries = G6LCCfg.RobEntries;
      cfg.PrfEntries = G6LCCfg.PrfEntries;
      cfg.IqEntries = G6LCCfg.IqEntries;
      cfg.LsqLoadEntries = G6LCCfg.LsqLoadEntries;
      cfg.LsqStoreEntries = G6LCCfg.LsqStoreEntries;
      cfg.OoORetireWidth = G6LCCfg.OoORetireWidth;
    end
    // A115: 0 = the single-register multiplier
    cfg.MultStages = (G6LCCfg.MultStages == 0) ? 1 : G6LCCfg.MultStages;
    // FSE S3 / U5 production: store-set on by default whenever full OoO is enabled
    // (can still force-off only by also disabling OoO). Explicit MemDepPredEn=1 keeps on for slice/etc.
    cfg.MemDepPredEn = G6LCCfg.MemDepPredEn || G6LCCfg.OoOEn;
    cfg.L3En = G6LCCfg.L3En;
    // --- Shared L2/L3 geometry inference (0 = auto from NrCores) -------------
    // Model: shared inclusive L2 below private L1s, shared L3 below L2.
    //   L2 ≈ max(256 KiB, NrCores × 128 KiB), 8-way, 64 B line, MSHR ~ 4×cores
    //   L3 ≈ max(2 MiB,  NrCores × 1 MiB),   16-way, match L2 line, MSHR ~ 4×cores
    //   Prefetch streams ≈ max(4, 2×NrCores); snoop-filter entries ≈ 64×NrCores
    if (G6LCCfg.L2En) begin
      if (G6LCCfg.L2ByteSize == 0) begin
        automatic int unsigned l2 = cfg.NrCores * 32'd131072; // 128 KiB / core
        if (l2 < 32'd262144) l2 = 32'd262144;
        cfg.L2ByteSize = l2;
      end else begin
        cfg.L2ByteSize = G6LCCfg.L2ByteSize;
      end
      cfg.L2SetAssoc = (G6LCCfg.L2SetAssoc == 0) ? unsigned'(8) : G6LCCfg.L2SetAssoc;
      cfg.L2LineWidth = (G6LCCfg.L2LineWidth == 0) ? unsigned'(512) : G6LCCfg.L2LineWidth;
      cfg.L2MshrDepth = (G6LCCfg.L2MshrDepth == 0)
                            ? ((cfg.NrCores * 4) < 8 ? unsigned'(8) : cfg.NrCores * 4)
                            : G6LCCfg.L2MshrDepth;
      cfg.L2DataBanks = (G6LCCfg.L2DataBanks == 0)
                            ? ((cfg.NrCores < 4) ? unsigned'(4) : cfg.NrCores)
                            : G6LCCfg.L2DataBanks;
    end else begin
      cfg.L2ByteSize = G6LCCfg.L2ByteSize;
      cfg.L2SetAssoc = G6LCCfg.L2SetAssoc;
      cfg.L2LineWidth = G6LCCfg.L2LineWidth;
      cfg.L2MshrDepth = G6LCCfg.L2MshrDepth;
      cfg.L2DataBanks = G6LCCfg.L2DataBanks;
    end
    if (G6LCCfg.L3En) begin
      if (G6LCCfg.L3ByteSize == 0) begin
        automatic int unsigned l3 = cfg.NrCores * 32'd1048576; // 1 MiB / core
        if (l3 < 32'd2097152) l3 = 32'd2097152;
        cfg.L3ByteSize = l3;
      end else begin
        cfg.L3ByteSize = G6LCCfg.L3ByteSize;
      end
      cfg.L3SetAssoc = (G6LCCfg.L3SetAssoc == 0) ? unsigned'(16) : G6LCCfg.L3SetAssoc;
      // Match L2 line when either side is auto/0
      if (G6LCCfg.L3LineWidth == 0)
        cfg.L3LineWidth = cfg.L2LineWidth != 0 ? cfg.L2LineWidth : unsigned'(512);
      else
        cfg.L3LineWidth = G6LCCfg.L3LineWidth;
      cfg.L3MshrDepth = (G6LCCfg.L3MshrDepth == 0)
                            ? ((cfg.NrCores * 4) < 16 ? unsigned'(16) : cfg.NrCores * 4)
                            : G6LCCfg.L3MshrDepth;
      cfg.L3DataBanks = (G6LCCfg.L3DataBanks == 0)
                            ? ((cfg.NrCores * 2) < 8 ? unsigned'(8) : cfg.NrCores * 2)
                            : G6LCCfg.L3DataBanks;
    end else begin
      cfg.L3ByteSize = G6LCCfg.L3ByteSize;
      cfg.L3SetAssoc = G6LCCfg.L3SetAssoc;
      cfg.L3LineWidth = G6LCCfg.L3LineWidth;
      cfg.L3MshrDepth = G6LCCfg.L3MshrDepth;
      cfg.L3DataBanks = G6LCCfg.L3DataBanks;
    end
    // U6.3 memory-side feature plane: plain pass-through (defaults stay 0).
    cfg.WtAxiAllocEn = G6LCCfg.WtAxiAllocEn;
    cfg.L3InclusiveEn = G6LCCfg.L3InclusiveEn;
    cfg.L2TagSramEn = G6LCCfg.L2TagSramEn;
    cfg.L2WriteUpdateEn = G6LCCfg.L2WriteUpdateEn;
    cfg.L2CmoEn = G6LCCfg.L2CmoEn;
    // T9b posted writes: 0 means "auto" (4-entry trackers), matching the
    // other geometry fields' convention.
    cfg.L2PostedWriteEn = G6LCCfg.L2PostedWriteEn;
    cfg.L2WriteTrackDepth =
        (G6LCCfg.L2WriteTrackDepth != 0) ? G6LCCfg.L2WriteTrackDepth : 4;
    cfg.L2ReadTrackDepth =
        (G6LCCfg.L2ReadTrackDepth != 0) ? G6LCCfg.L2ReadTrackDepth : 4;
    // T9h/M5: L2 prefetcher geometry defaults (engine off unless enabled).
    cfg.L2PrefetchEn   = G6LCCfg.L2PrefetchEn;
    cfg.L2PfStreams    = (G6LCCfg.L2PfStreams != 0) ? G6LCCfg.L2PfStreams : 4;
    cfg.L2PfDistance   = (G6LCCfg.L2PfDistance != 0) ? G6LCCfg.L2PfDistance : 2;
    // bit field — 0 is a real choice (next-line only); packages enabling
    // L2PrefetchEn set L2PfStrideEn explicitly.
    cfg.L2PfStrideEn   = G6LCCfg.L2PfStrideEn;
    cfg.L2PfMshrReserve= (G6LCCfg.L2PfMshrReserve != 0) ? G6LCCfg.L2PfMshrReserve
                                                      : 1;
    // T10b/N3: burst-throttling defaults — one armed candidate per stream
    // and an 8-cycle quiet window after every demand miss commit.
    cfg.L2PfMaxOutstanding = (G6LCCfg.L2PfMaxOutstanding != 0)
                             ? G6LCCfg.L2PfMaxOutstanding : 1;
    cfg.L2PfQuiet    = (G6LCCfg.L2PfQuiet != 0) ? G6LCCfg.L2PfQuiet : 8;
    cfg.L3PrefetchEn   = G6LCCfg.L3PrefetchEn;
    // Multi-core snoop-filter / prefetch defaults when left zero
    if (cfg.NrCores > 1 && G6LCCfg.SnoopFilterEn && G6LCCfg.SnoopFilterEntries == 0)
      cfg.SnoopFilterEntries = cfg.NrCores * 64;
    else
      cfg.SnoopFilterEntries = G6LCCfg.SnoopFilterEntries;
    cfg.ServerPrefetchEn = G6LCCfg.ServerPrefetchEn;
    if (G6LCCfg.ServerPrefetchEn && G6LCCfg.ServerPfStreams == 0) begin
      automatic int unsigned pfs = cfg.NrCores * 2;
      cfg.ServerPfStreams = (pfs < 4) ? unsigned'(4) : pfs;
    end else begin
      cfg.ServerPfStreams = G6LCCfg.ServerPfStreams;
    end
    cfg.ServerPfDistance = (G6LCCfg.ServerPfDistance == 0 && G6LCCfg.ServerPrefetchEn)
                               ? unsigned'(2) : G6LCCfg.ServerPfDistance;
    cfg.SharedTlbDepth = G6LCCfg.SharedTlbDepth;
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
