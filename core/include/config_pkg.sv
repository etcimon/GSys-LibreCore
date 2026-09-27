// Copyright 2023 Thales DIS France SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales
// Modified by: Etienne Cimon — optional AI island policy codec configuration.

package config_pkg;

  // ---------------
  // Global Config
  // ---------------
  localparam int unsigned ILEN = 32;
  localparam int unsigned NRET = 1;
  /// Maximum in-order multi-issue width (superscalar precursor to U5 OoO).
  /// Used for static bounds; the live width is `cva6_cfg_t.NrIssuePorts` (1 or 2..8).
  localparam int unsigned CVA6_MAX_ISSUE_PORTS = 8;
  /// Supported FETCH_WIDTH values once multi-issue scales the front-end bus.
  localparam int unsigned CVA6_MAX_FETCH_WIDTH = 256;
  /// Maximum coherent cluster size (U6.2 multi-core). Live width is
  /// `cva6_cfg_t.NrCores` ∈ {1..CVA6_MAX_CORES}. CLINT/PLIC/snoop scale to this.
  /// Overridable at compile time: `+define+CVA6_MAX_CORES=4` (must be power-of-two-friendly ≤8).
`ifdef CVA6_MAX_CORES
  localparam int unsigned CVA6_MAX_CORES = `CVA6_MAX_CORES;
`else
  localparam int unsigned CVA6_MAX_CORES = 8;
`endif
  /// Max SMT hardware threads *per core* (U6.1). Cluster hart count ≈ NrCores×NrHarts.
  localparam int unsigned CVA6_MAX_SMT_HARTS = 2;
  /// Max *software* harts in the cluster: S = NrCores × NrHarts. Bounding the
  /// factors separately is not enough — the uncore scales with the product.
  /// `corev_apu/tb/ariane_testharness.sv` slices the PLIC vector as two
  /// contexts (M and S) per software hart against `ariane_soc::NumTargets`,
  /// which `ariane_soc_pkg.sv` fixes at 16 (`gen_plic_addrmap.py -t 16`), so
  /// the keepable bound is 2·S ≤ 16. Kept core-side because `config_pkg`
  /// cannot see an APU/TB package; it is the same cross-package lockstep
  /// discipline `ariane_soc_pkg.sv` already documents for `CVA6_MAX_CORES`.
  /// Without this the product is constant-foldable but unchecked, so
  /// `NrCores=8, NrHarts=2` elaborates cleanly and is only discovered when the
  /// wrong CPU takes an interrupt under Linux.
  localparam int unsigned CVA6_MAX_SW_HARTS = 8;

  /// The NoC type is a top-level parameter, hence we need a bit more
  /// information on what protocol those type parameters are supporting.
  /// Currently two values are supported"
  typedef enum {
    /// The "classic" AXI4 protocol.
    NOC_TYPE_AXI4_ATOP,
    /// In the OpenPiton setting the WT cache is connected to the L15.
    NOC_TYPE_L15_BIG_ENDIAN,
    NOC_TYPE_L15_LITTLE_ENDIAN
  } noc_type_e;

  /// Cache type parameter
  typedef enum logic [2:0] {
    WB = 0,
    WT = 1,
    HPDCACHE_WT = 2,
    HPDCACHE_WB = 3,
    HPDCACHE_WT_WB = 4
  } cache_type_t;

  /// Branch predictor parameter (U1 fabric; BHT/PH_BHT are the legacy paths)
  typedef enum logic [1:0] {
    BHT       = 2'd0,  // Bimodal predictor (default, bit-identical to pre-U1)
    PH_BHT    = 2'd1,  // Private History Bimodal predictor
    GSHARE    = 2'd2,  // Global-history XOR index (U1)
    TAGE_LITE = 2'd3   // TAGE-SC-lite fabric via g6lc_bp_top (U1)
  } bp_type_t;

  /// U3 L1 replacement policy (HPDCACHE victim select; WT keeps LFSR/random)
  typedef enum logic [1:0] {
    REPL_PLRU  = 2'd0,
    REPL_RANDOM = 2'd1,
    REPL_RRIP  = 2'd2,  // SRRIP — scan-resistant (best for skb streaming)
    REPL_DRRIP = 2'd3   // set-dueling SRRIP/BRRIP
  } repl_policy_t;

  /// U6.1 SMT thread-select policy (contention-aware; ignored when NrHarts==1)
  typedef enum logic [1:0] {
    SMT_RR             = 2'd0,  // pure round-robin after SmtFetchQuantum
    SMT_SWITCH_ON_MISS = 2'd1,  // switch immediately when active hart D$/I$ miss
    SMT_HYBRID         = 2'd2   // miss-prefer + quantum RR + anti-starvation
  } smt_policy_t;

  /// U6.2 multi-core coherence policy (SoC; ignored when NrCores==1)
  typedef enum logic [1:0] {
    COH_OOO         = 2'd3,
    COH_WRITE_INVAL  = 2'd0,  // WT: remote write → invalidate peer L1(s)
    COH_BROADCAST    = 2'd1,  // always broadcast inv (filter off / debug)
    COH_FILTERED     = 2'd2   // snoop-filter guided inv (default when NrCores>1)
  } coh_policy_t;

  /// Data and Address length
  typedef enum logic [3:0] {
    ModeOff  = 0,
    ModeSv32 = 1,
    ModeSv39 = 8,
    ModeSv48 = 9,
    ModeSv57 = 10,
    ModeSv64 = 11
  } vm_mode_t;

  /// Coprocessor type parameter
  typedef enum {
    COPRO_NONE,
    COPRO_EXAMPLE,
    /// Xg6lcai AI matrix plane on the CVXIF seam (option B).
    /// architecture/ai-matrix/README.md s2; instantiated in corev_apu/src/ariane.sv.
    COPRO_G6LC_AI
  } copro_type_t;

  /// AI matrix acceleration (Xg6lcai). Interface contract:
  /// architecture/ai-matrix/isa-encoding.md; sizing model for the throughput
  /// plane: architecture/ai-matrix/scaling-100tops.md.
  ///
  /// These knobs size the CORE-ATTACHED plane only (T0/T1: a small, fixed tile
  /// unit at the CVXIF or accelerator seam). The scaled T2 island is uncore and
  /// is sized by its own package, never from here -- see scaling-100tops.md s8.
  /// Do not add cluster counts or MAC rates to this struct.
  ///
  /// Grouped in a nested struct rather than flattened like the U5/U6 knobs
  /// below: a flat addition costs one line per member in each of the ~24
  /// config packages, a nested one costs exactly one line.
  ///
  /// ---------------------------------------------------------------------
  /// Numeric formats (AiFmt* below) -- one bitmap, two planes
  /// ---------------------------------------------------------------------
  /// `Int4En` and `Sparse24En` were the first two arithmetic grants and are
  /// kept because software already reads them back from `aicfg`. They do not
  /// generalise: they are named bits, so every new format would add a field
  /// here and a line to every package, and neither the island capability
  /// window nor the descriptor could express "this part does BF16".
  ///
  /// `FormatMask` replaces that with a grant BITMAP over `AiFmt*` positions.
  /// One field carries every present and future format, `check_cfg` keeps it
  /// consistent with the legacy bits, and the same bitmap is what the island
  /// publishes at `CAP_OFF_DTYPE_MASK` and what a descriptor's `numfmt` field
  /// is checked against. A format that is not granted is REFUSED, never
  /// silently demoted to INT8 -- a wrong-format GEMM returns plausible
  /// numbers, which is the worst possible failure for a tensor engine.
  typedef struct packed {
    bit          MatrixEn;    // master enable: custom-2 opcode + AI CSRs
    bit          AccelEn;     // seam D (accelerator port); 0 => seam B (CVXIF)
    bit          TileLdEn;    // native ai.ldt/ai.stt (needs a memory port)
    bit          RequantEn;   // funct3=100 requantise / activate group
    bit          SparseEn;    // funct3=110 gather / expert-select group
    bit          UmodeEn;     // allow U-mode issue (aiperm[0] reset value)
    bit          PolicyCodecEn;
    bit          PolicyBenefitEn;
    bit          PolicySubcodeEn;
    bit          PolicySubcodeCacheEn;
    // V/A-Turbo (Virtual Analog Turbo): the compartment for per-job precision
    // and lane-group selection. Gated separately from the sub-code because it
    // is the only policy feature that may CHANGE ARITHMETIC, so it can never be
    // reached by enabling steering alone. See architecture/ai-matrix/va-turbo.md.
    bit          VaTurboEn;
    bit          IslandFpEn;
    // Datatype options. These are GRANT gates, not encodings: aicfg carries the
    // request, and ai.setcfg downgrades to the nearest supported value rather
    // than trapping (isa-encoding.md s3.1), so software is portable across
    // parts that do and do not implement them.
    bit          Int4En;      // grant aicfg.ew=01 (4-bit elements)
    bit          Sparse24En;  // grant aicfg.sp24 (structured 2:4 sparsity on A)
    /// Granted numeric formats, as a bitmap of AiFmt* positions.
    ///
    /// Bit 0 (INT8 dense) is mandatory whenever MatrixEn: it is the format the
    /// golden, the requant rule (isa-encoding.md s3.5) and every directed test
    /// are written in, so a part that grants no format at all would have no
    /// reference to be correct against. Everything above bit 0 is optional and
    /// independently discoverable, so a minimal SKU stays small.
    int unsigned FormatMask;
    int unsigned TileM;       // native tile rows
    int unsigned TileN;       // native tile columns
    int unsigned TileK;       // native reduction depth
    int unsigned TileCount;   // addressable tile registers
    int unsigned AccBanks;    // accumulator banks (>= NrHarts under SMT)
    int unsigned AccDepth;    // accumulators per bank
    int unsigned Queues;      // T2 descriptor rings (0 disables T2)
    int unsigned QueueDepth;  // entries per ring (power of two)
    // T2 scheduling priority classes (isa-encoding.md s7.1, descriptor
    // flags[19:16]). 1 = single class, i.e. plain round-robin. Bounds what the
    // core clamps a descriptor's requested class to; the island reports the
    // same number in its capability window.
    int unsigned QosClasses;
  } ai_cfg_t;

  /// Default for every package that does not implement the AI plane.
  localparam ai_cfg_t AiCfgOff = ai_cfg_t'(0);

  /// -------------------------------------------------------------------------
  /// Numeric-format bit positions (`ai_cfg_t.FormatMask`, `aicfg.numfmt`,
  /// descriptor `flags.numfmt`, island `CAP_OFF_DTYPE_MASK`).
  /// -------------------------------------------------------------------------
  /// ONE enumeration, four consumers. The bit position in the grant mask and
  /// the value of the request field are deliberately the SAME number, so a
  /// grant check is `mask[request]` rather than a translation table that can
  /// disagree with itself.
  ///
  /// `AI_FMT_INT` is 0 so that a descriptor or `aicfg` written by software that
  /// predates this field -- i.e. with the whole `numfmt` field zero -- keeps its
  /// old meaning exactly: integer, element width from `ew`, signedness from
  /// `dtype`. That is what makes this an extension into reserved space rather
  /// than a contract version bump (isa-encoding.md s9).
  localparam int unsigned AI_FMT_INT      = 0;  // width from ew, sign from dtype
  localparam int unsigned AI_FMT_INT4     = 1;  // == ew=01; mirrors Int4En
  localparam int unsigned AI_FMT_SP24     = 2;  // structured 2:4 sparsity on A
  localparam int unsigned AI_FMT_FP8_E4M3 = 3;
  localparam int unsigned AI_FMT_FP8_E5M2 = 4;
  localparam int unsigned AI_FMT_FP16     = 5;  // IEEE 754 binary16
  localparam int unsigned AI_FMT_BF16     = 6;  // bfloat16
  localparam int unsigned AI_FMT_FP32     = 7;  // IEEE 754 binary32
  localparam int unsigned AI_FMT_WIDTH    = 8;  // bits of FormatMask defined

  /// Convenience masks. A SKU should name one of these rather than a hex
  /// literal, so that adding a format updates every package that wanted it.
  localparam int unsigned AiFmtMaskInt8      = 1 << AI_FMT_INT;
  localparam int unsigned AiFmtMaskInt8Int4  = AiFmtMaskInt8 | (1 << AI_FMT_INT4);
  /// Inference card: dense INT8 + INT4 + 2:4 sparsity + the three 16-bit-and-
  /// below float formats a serving stack actually asks for.
  localparam int unsigned AiFmtMaskInfer     = AiFmtMaskInt8Int4
                                             | (1 << AI_FMT_SP24)
                                             | (1 << AI_FMT_FP8_E4M3)
                                             | (1 << AI_FMT_FP8_E5M2)
                                             | (1 << AI_FMT_FP16)
                                             | (1 << AI_FMT_BF16);
  /// Adds FP32 for training / reference paths.
  localparam int unsigned AiFmtMaskAll       = AiFmtMaskInfer | (1 << AI_FMT_FP32);

  /// True when `mask` grants format index `fmt`.
  function automatic bit ai_fmt_granted(input int unsigned mask, input int unsigned fmt);
    if (fmt >= AI_FMT_WIDTH) return 1'b0;
    return bit'((mask >> fmt) & 1);
  endfunction

  /// Widest operand element in bytes for a granted format.
  ///
  /// Used to size operand fetch and to reject a descriptor whose leading
  /// dimension cannot hold its own row. It is a function of the format rather
  /// than of `ew` alone, because a float format fixes its own width.
  function automatic int unsigned ai_fmt_bytes(input int unsigned fmt);
    case (fmt)
      AI_FMT_INT4:     return 1;  // packed two per byte; a row is still bytes
      AI_FMT_FP8_E4M3,
      AI_FMT_FP8_E5M2: return 1;
      AI_FMT_FP16,
      AI_FMT_BF16:     return 2;
      AI_FMT_FP32:     return 4;
      default:         return 1;  // AI_FMT_INT: 8-bit unless ew says otherwise
    endcase
  endfunction

  localparam NrMaxRules = 16;

  typedef struct packed {
    // General Purpose Register Size (in bits)
    int unsigned                 XLEN;
    // Virtual address Size (in bits)
    int unsigned                 VLEN;
    // Atomic RISC-V extension
    bit                          RVA;
    // Zacas: atomic compare-and-swap (AMOCAS.W/D; depends on RVA/Zaamo)
    bit                          RVZacas;
    // Bit manipulation RISC-V extension
    bit                          RVB;
    // Scalar Cryptography RISC-V extension
    bit                          ZKN;
    // Vector RISC-V extension
    bit                          RVV;
    // Compress RISC-V extension
    bit                          RVC;
    // Hypervisor RISC-V extension
    bit                          RVH;
    // Zcb RISC-V extension
    bit                          RVZCB;
    // Zcmp RISC-V extension
    bit                          RVZCMP;
    // Zcmt RISC-V extension
    bit                          RVZCMT;
    // Zicond RISC-V extension
    bit                          RVZiCond;
    // Zicbom RISC-V extension (cache management / CBO)
    bit                          RVZiCbom;
    // Zicboz: cbo.zero (requires RVZiCbom for menvcfg CBIE/CBCFE machinery optional)
    bit                          RVZiCboz;
    // Zicbop: prefetch.i / prefetch.r / prefetch.w HINTs
    bit                          RVZiCbop;
    // Zicntr RISC-V extension
    bit                          RVZicntr;
    // Zihpm RISC-V extension
    bit                          RVZihpm;
    // Floating Point
    bit                          RVF;
    // Floating Point
    bit                          RVD;
    // Non standard 16bits Floating Point extension
    bit                          XF16;
    // Non standard 16bits Floating Point Alt extension
    bit                          XF16ALT;
    // Non standard 8bits Floating Point extension
    bit                          XF8;
    // Non standard Vector Floating Point extension
    bit                          XFVec;
    // Perf counters
    bit                          PerfCounterEn;
    // MMU
    bit                          MmuPresent;
    // Supervisor mode
    bit                          RVS;
    // User mode
    bit                          RVU;
    // Software interrupts are enabled
    bit                          SoftwareInterruptEn;
    // Debug support
    bit                          DebugEn;
    // Base address of the debug module
    logic [63:0]                 DmBaseAddress;
    // Address to jump when halt request
    logic [63:0]                 HaltAddress;
    // Address to jump when exception
    logic [63:0]                 ExceptionAddress;
    // Trigger Module Sdtrig Extension
    bit                          SDTRIG;
    bit                          Mcontrol6;
    bit                          Icount;
    bit                          Etrigger;
    bit                          Itrigger;
    // Tval Support Enable
    bit                          TvalEn;
    // MTVEC CSR supports only direct mode
    bit                          DirectVecOnly;
    // PMP entries number
    int unsigned                 NrPMPEntries;
    // PMP CSR configuration reset values
    logic [63:0][63:0]           PMPCfgRstVal;
    // PMP CSR address reset values
    logic [63:0][63:0]           PMPAddrRstVal;
    // PMP CSR read-only bits
    bit [63:0]                   PMPEntryReadOnly;
    // PMP NA4 and NAPOT mode enable
    bit                          PMPNapotEn;
    // PMA non idempotent rules number
    int unsigned                 NrNonIdempotentRules;
    // PMA NonIdempotent region base address
    logic [NrMaxRules-1:0][63:0] NonIdempotentAddrBase;
    // PMA NonIdempotent region length
    logic [NrMaxRules-1:0][63:0] NonIdempotentLength;
    // PMA regions with execute rules number
    int unsigned                 NrExecuteRegionRules;
    // PMA Execute region base address
    logic [NrMaxRules-1:0][63:0] ExecuteRegionAddrBase;
    // PMA Execute region address base
    logic [NrMaxRules-1:0][63:0] ExecuteRegionLength;
    // PMA regions with cache rules number
    int unsigned                 NrCachedRegionRules;
    // PMA cache region base address
    logic [NrMaxRules-1:0][63:0] CachedRegionAddrBase;
    // PMA cache region rules
    logic [NrMaxRules-1:0][63:0] CachedRegionLength;
    // CV-X-IF coprocessor interface enable
    bit                          CvxifEn;
    // Coprocessor type
    copro_type_t                 CoproType;
    // NOC bus type
    noc_type_e                   NOCType;
    // AXI address width
    int unsigned                 AxiAddrWidth;
    // AXI data width
    int unsigned                 AxiDataWidth;
    // AXI ID width
    int unsigned                 AxiIdWidth;
    // AXI User width
    int unsigned                 AxiUserWidth;
    // AXI burst in write
    bit                          AxiBurstWriteEn;
    // TODO
    int unsigned                 MemTidWidth;
    // Instruction cache size (in bytes)
    int unsigned                 IcacheByteSize;
    // Instruction cache associativity (number of ways)
    int unsigned                 IcacheSetAssoc;
    // Instruction cache line width
    int unsigned                 IcacheLineWidth;
    // Cache Type
    cache_type_t                 DCacheType;
    // Data cache ID
    int unsigned                 DcacheIdWidth;
    // Data cache size (in bytes)
    int unsigned                 DcacheByteSize;
    // Data cache associativity (number of ways)
    int unsigned                 DcacheSetAssoc;
    // Data cache line width
    int unsigned                 DcacheLineWidth;
    // three configurations for cache coherency after flush:
    // DcacheFlushOnFence causes dcache flush for every fence instruction
    // DcacheFlushOnFenceI causes dcache flush for every fence.I instruction
    // DcacheInvalidateOnFlush causes dcache to also be invalidated when flushed
    // tradeoff between coherence and efficiency, depending on remaining configuration:

    // DcacheFlushOnFenceI is required for write-back caches - otherwise, 
    // no way to reliably write instruction memory with store instructions, 
    // as data and instruction cache are currently not coherent
    // DcacheFlushOnFence is required for write-back caches to ensure coherency
    // with other harts or DMA devices --> a fence forces all stores to commit to memory
    // DcacheInvalidateOnFlush causes all dcache entries to become invalid, forcing the CPU
    // to fetch data from memory after each fence --> make writes from other harts or DMAs
    // visible to the CPU
    // thus, DcacheFlushOnFence and DcacheInvalidateOnFlush can ensure DMA coherency at high performance cost
    // using RVZiCbom can achieve the same effect at significantly lower performance cost
    // hence, on uniprocessor or not cache-coherent multiprocessor SoCs, one might want to disable both and use
    // explicit CBO operations for better overall performance
    bit          DcacheFlushOnFence;
    bit          DcacheFlushOnFenceI;
    bit          DcacheInvalidateOnFlush;
    // User field on data bus enable
    int unsigned DataUserEn;
    // Write-through data cache write buffer depth
    int unsigned WtDcacheWbufDepth;
    // Post-ACK L1 fixup queue depth (0 = disabled)
    int unsigned WtDcacheFixupDepth;
    bit          WtDcacheFixupVoidKeepEn;
    // User field on fetch bus enable
    int unsigned FetchUserEn;
    // Width of fetch user field
    int unsigned FetchUserWidth;
    // Is FPGA optimization of CV32A6 for Xilinx and Altera
    bit          FpgaEn;
    // Is FPGA optimization for Altera FPGA
    bit          FpgaAlteraEn;
    // Is Techno Cut instantiated
    bit          TechnoCut;
    // Enable superscalar multi-issue (in-order). Width is NrIssuePorts (2..8).
    bit          SuperscalarEn;
    // Issue width: 0 = auto (SuperscalarEn ? 2 : 1); else 1, or 2..CVA6_MAX_ISSUE_PORTS
    // when SuperscalarEn. Precursor knob for U5 multi-issue OoO scaling.
    int unsigned NrIssuePorts;
    // Enable ALU-ALU bypass (superscalar mode only)
    bit          ALUBypass;
    // Number of commit ports. When SuperscalarEn and 0/under-sized, raised to
    // match issue width (capped by check_cfg).
    int unsigned NrCommitPorts;
    // Load cycle latency number
    int unsigned NrLoadPipeRegs;
    // Store cycle latency number
    int unsigned NrStorePipeRegs;
    // Scoreboard length
    int unsigned NrScoreboardEntries;
    // Load buffer entry buffer
    int unsigned NrLoadBufEntries;
    // Maximum number of outstanding stores
    int unsigned MaxOutstandingStores;
    // Return address stack depth
    int unsigned RASDepth;
    // Branch target buffer entries
    int unsigned BTBEntries;
    // Branch predictor type
    bp_type_t    BPType;
    // Branch history entries
    int unsigned BHTEntries;
    // Branch history bits
    int unsigned BHTHist;
    // U1 prediction fabric knobs (used when BPType is GSHARE or TAGE_LITE).
    // Zero / disabled defaults keep BHT/PH_BHT configs bit-identical.
    int unsigned BPGhistLen;          // global / folded history length (≤ 64)
    int unsigned BPTageTables;        // number of tagged TAGE components (0..8)
    int unsigned BPTageTableEntries;  // entries per tagged table (0 or power-of-two)
    int unsigned BPTageTagBits;       // tag width per TAGE entry
    bit          BPLoopEn;            // loop (trip-count) predictor
    bit          BPIndirectEn;        // ITTAGE / indirect target predictor
    int unsigned BPIndirectEntries;   // ITTAGE entries (0 or power-of-two)
    bit          BPStatCorEn;         // statistical corrector
    int unsigned BPCkptDepth;         // prediction checkpoint FIFO depth (U4/U5)
    // MMU instruction TLB entries
    int unsigned InstrTlbEntries;
    // MMU data TLB entries
    int unsigned DataTlbEntries;
    // MMU option to use shared TLB
    bit unsigned UseSharedTlb;
    // MMU depth of shared TLB
    int unsigned SharedTlbDepth;
    // Option to enable Svnapot extension
    bit          SvnapotEn;
    // Option to enable Sstc extension (stimecmp/vstimecmp supervisor timer).
    // Requires RVS, and requires the platform to supply the mtime value on
    // cva6's rtc_time_i port (the CLINT owns the counter, the hart owns the
    // comparator). Also enables the in-core time/timeh CSRs.
    bit          SstcEn;
    // Sscofpmf: counter-overflow interrupt (LCOFI), mhpmeventN.OF + privilege
    // filtering (MINH/SINH/UINH), and the scountovf CSR. Requires PerfCounterEn.
    bit          SscofpmfEn;
    // Zihintpause: decode the PAUSE HINT (FENCE with pred=W,succ=0,rd=x0,rs1=x0)
    // as a NOP rather than a full D$ fence flush.
    bit          ZihintpauseEn;
    // U7ᵇ: Svpbmt — page-based memory types (PTE[62:61]); menvcfg.PBMTE
    bit          SvpbmtEn;
    // U7ᵇ: Zawrs — wrs.nto / wrs.sto wait-on-reservation-set
    bit          ZawrsEn;
    // U6 — L2 / SMT / multi-core (memory-side L2 + precursor knobs)
    bit          L2En;                // instantiate AXI L2 in SoC (corev_apu)
    int unsigned L2ByteSize;          // e.g. 262144 = 256 KiB
    int unsigned L2SetAssoc;          // ways
    int unsigned L2LineWidth;         // bits; must match D$ / 512 for 64 B
    int unsigned L2MshrDepth;         // outstanding misses (MLP)
    int unsigned L2DataBanks;         // banked data array
    bit          L2RoundRobinEn;
    int unsigned NrHarts;             // SMT threads per core: 1 baseline, ≤CVA6_MAX_SMT_HARTS
    // U6.1 SMT contention policy (inert when NrHarts==1)
    smt_policy_t SmtPolicy;           // RR / switch-on-miss / hybrid
    int unsigned SmtFetchQuantum;     // consecutive fetch grants before RR (0→1)
    int unsigned SmtStarveLimit;      // force switch after N idle cycles (0=off)
    // U6.2 coherent multi-core cluster (SoC; inert when NrCores==1)
    int unsigned NrCores;             // physical cores: 1..CVA6_MAX_CORES (2–8 multi-core)
    coh_policy_t CohPolicy;           // write-inval / broadcast / filtered
    bit          SnoopFilterEn;       // filter useless L1 snoops
    int unsigned SnoopFilterEntries;  // SF entries (0 or power-of-two)
    int unsigned CohInvalDepth;       // per-core inv FIFO depth
    int unsigned CohAxiStarveLimit;   // multi-master AXI anti-starve cycles
    // U3 energy-first L1
    bit          WayPredEn;           // MRU way prediction (I$ data-array CE)
    int unsigned WayPredEntries;      // way-predictor table entries (0 or pot)
    repl_policy_t ReplPolicy;         // PLRU/RANDOM/RRIP/DRRIP (HPDCACHE)
    bit          HwPrefetchEn;        // enable HPDCACHE stride prefetcher
    int unsigned HwPrefetchStreams;   // number of stride streams
    int unsigned DcacheMshrDepth;     // MSHR entries hint (0 = IP default)
    // U2 decoupled front-end (0 FTQ depth ⇒ today's direct NPC→I$ path)
    int unsigned FtqDepth;            // fetch-target queue depth (0 = off)
    bit          FdipEn;              // fetch-directed I-prefetch
    int unsigned FdipDistance;        // FTQ entries of run-ahead for FDIP
    bit          LoopBufEn;           // loop buffer
    int unsigned LoopBufEntries;      // max fetch blocks in the loop body
    // U4 slice-out-of-order (mutually exclusive with U5 OoOEn)
    bit          SliceOoOEn;          // LSC-style A/B queue steering
    int unsigned SliceIstEntries;     // instruction-slice table entries
    int unsigned SliceAiqDepth;       // address-slice issue queue depth
    int unsigned SliceBiqDepth;       // main (B) issue queue depth
    int unsigned SliceMaxRunahead;    // max A-ahead-of-B in-flight
    // U5 full OoO production path (config-gated; illegal with SliceOoOEn)
    bit          OoOEn;
    // T6b: when 1 the SMT thread selector switches only on a drained backend
    // (scoreboard and store queues empty); 0 permits mixed residency.
    bit          SmtDrainedHandoff;
    // FSE: deep speculation depth plane (architecture/speculative-execution/)
    // 0 = legacy STQ depth 4 + package-stated buffers; 1 = auto floors + deeper STQ
    bit          DeepSpecEn;
    int unsigned RobEntries;          // ROB depth (0 → NrScoreboardEntries when OoOEn)
    int unsigned PrfEntries;          // physical RF size (0 → 32+RobEntries)
    int unsigned IqEntries;           // unified IQ depth (0 → RobEntries)
    int unsigned LsqLoadEntries;      // load queue (0 → NrLoadBufEntries)
    int unsigned LsqStoreEntries;     // store queue (0 → MaxOutstandingStores)
    bit          MemDepPredEn;        // store-set memory dependence predictor
    int unsigned OoORetireWidth;      // max retire/cycle (0 → NrCommitPorts)
    // U5/U6 memory hierarchy: optional L3 + server-ready prefetch (SoC, not L1)
    bit          L3En;                // AXI L3 below L2 (requires L2En)
    int unsigned L3ByteSize;          // e.g. 2 MiB
    int unsigned L3SetAssoc;
    int unsigned L3LineWidth;         // bits; must match L2 / 64 B Zic64b
    int unsigned L3MshrDepth;
    int unsigned L3DataBanks;
    bit          ServerPrefetchEn;    // multi-stream + next-line at L3 boundary
    int unsigned ServerPfStreams;     // concurrent stream trackers
    int unsigned ServerPfDistance;    // next-line look-ahead (lines)
    // U6.3 memory-side feature plane (phased; 0 keeps today's behaviour)
    bit          WtAxiAllocEn;        // WT adapter emits BUFFERABLE|MODIFIABLE|RD_ALLOC|WR_ALLOC
                                      // for cacheable requests (nc/lock/ATOP stay MODIFIABLE);
                                      // default 0 = today's modifiable-only stream
    bit          L3InclusiveEn;       // L3 victim back-invalidates L1s and the L2 tag (Phase 2)
    bit          L2TagSramEn;         // L2/L3 tag array behind tc_sram launched read (Phase 3)
    bit          L2WriteUpdateEn;     // L2 merges a WT write into a resident line (T8f)
    // Xg6lcai AI matrix plane (off in every package but g6lc64_ai)
    ai_cfg_t     AiCfg;
  } cva6_user_cfg_t;

  typedef struct packed {
    int unsigned XLEN;
    int unsigned VLEN;
    int unsigned PLEN;
    int unsigned GPLEN;
    bit IS_XLEN32;
    bit IS_XLEN64;
    int unsigned XLEN_ALIGN_BYTES;
    int unsigned ASID_WIDTH;
    int unsigned VMID_WIDTH;

    bit FpgaEn;
    bit FpgaAlteraEn;
    bit TechnoCut;

    bit          SuperscalarEn;
    int unsigned NrCommitPorts;
    int unsigned NrIssuePorts;
    bit          SpeculativeSb;
    bit          DeepSpecEn;          // FSE depth plane (STQ/load/ckpt floors)

    int unsigned NrALUs;
    bit          ALUBypass;

    int unsigned NrLoadPipeRegs;
    int unsigned NrStorePipeRegs;
    /// AXI parameters.
    int unsigned AxiAddrWidth;
    int unsigned AxiDataWidth;
    int unsigned AxiIdWidth;
    int unsigned AxiUserWidth;
    int unsigned MEM_TID_WIDTH;
    int unsigned NrLoadBufEntries;
    bit          RVF;
    bit          RVD;
    bit          XF16;
    bit          XF16ALT;
    bit          XF8;
    bit          RVA;
    bit          RVZacas;  // Zacas AMOCAS.W/D (implies RVA)
    bit          RVB;
    bit          ZKN;
    bit          RVV;
    bit          RVC;
    bit          RVH;
    bit          RVZCB;
    bit          RVZCMP;
    bit          RVZCMT;
    bit          XFVec;
    bit          CvxifEn;
    copro_type_t CoproType;
    bit          RVZiCond;
    bit          RVZiCbom;
    bit          RVZiCboz;
    bit          RVZiCbop;
    bit          RVZicntr;
    bit          RVZihpm;

    int unsigned NR_SB_ENTRIES;
    int unsigned TRANS_ID_BITS;

    bit          FpPresent;
    bit          NSX;
    int unsigned FLen;
    bit          RVFVec;
    bit          XF16Vec;
    bit          XF16ALTVec;
    bit          XF8Vec;
    int unsigned NrRgprPorts;
    int unsigned NrWbPorts;
    bit          EnableAccelerator;
    bit          PerfCounterEn;
    bit          MmuPresent;
    bit          RVS;                  //Supervisor mode
    bit          RVU;                  //User mode
    bit          SoftwareInterruptEn;

    logic [63:0] HaltAddress;
    logic [63:0] ExceptionAddress;
    int unsigned RASDepth;
    int unsigned BTBEntries;
    bp_type_t    BPType;
    int unsigned BHTEntries;
    int unsigned BHTHist;
    int unsigned BPGhistLen;
    int unsigned BPTageTables;
    int unsigned BPTageTableEntries;
    int unsigned BPTageTagBits;
    bit          BPLoopEn;
    bit          BPIndirectEn;
    int unsigned BPIndirectEntries;
    bit          BPStatCorEn;
    int unsigned BPCkptDepth;
    int unsigned InstrTlbEntries;
    int unsigned DataTlbEntries;
    bit unsigned UseSharedTlb;
    bit SvnapotEn;
    bit SstcEn;
    bit SscofpmfEn;
    bit ZihintpauseEn;
    bit SvpbmtEn;
    bit ZawrsEn;
    bit L2En;
    int unsigned L2ByteSize;
    int unsigned L2SetAssoc;
    int unsigned L2LineWidth;
    int unsigned L2MshrDepth;
    int unsigned L2DataBanks;
    bit L2RoundRobinEn;
    int unsigned NrHarts;
    smt_policy_t SmtPolicy;
    int unsigned SmtFetchQuantum;
    int unsigned SmtStarveLimit;
    int unsigned NrCores;
    coh_policy_t CohPolicy;
    bit SnoopFilterEn;
    int unsigned SnoopFilterEntries;
    int unsigned CohInvalDepth;
    int unsigned CohAxiStarveLimit;
    bit WayPredEn;
    int unsigned WayPredEntries;
    repl_policy_t ReplPolicy;
    bit HwPrefetchEn;
    int unsigned HwPrefetchStreams;
    int unsigned DcacheMshrDepth;
    int unsigned FtqDepth;
    bit          FdipEn;
    int unsigned FdipDistance;
    bit          LoopBufEn;
    int unsigned LoopBufEntries;
    bit          SliceOoOEn;
    int unsigned SliceIstEntries;
    int unsigned SliceAiqDepth;
    int unsigned SliceBiqDepth;
    int unsigned SliceMaxRunahead;
    bit          OoOEn;
    bit          SmtDrainedHandoff;
    int unsigned RobEntries;
    int unsigned PrfEntries;
    int unsigned IqEntries;
    int unsigned LsqLoadEntries;
    int unsigned LsqStoreEntries;
    bit          MemDepPredEn;
    int unsigned OoORetireWidth;
    bit          L3En;
    int unsigned L3ByteSize;
    int unsigned L3SetAssoc;
    int unsigned L3LineWidth;
    int unsigned L3MshrDepth;
    int unsigned L3DataBanks;
    bit          WtAxiAllocEn;
    bit          L3InclusiveEn;
    bit          L2TagSramEn;
    bit          L2WriteUpdateEn;
    bit          ServerPrefetchEn;
    int unsigned ServerPfStreams;
    int unsigned ServerPfDistance;
    int unsigned SharedTlbDepth;
    int unsigned VpnLen;
    int unsigned PtLevels;

    logic [63:0]                 DmBaseAddress;
    bit                          TvalEn;
    bit                          DirectVecOnly;
    int unsigned                 NrPMPEntries;
    logic [63:0][63:0]           PMPCfgRstVal;
    logic [63:0][63:0]           PMPAddrRstVal;
    bit [63:0]                   PMPEntryReadOnly;
    bit                          PMPNapotEn;
    noc_type_e                   NOCType;
    int unsigned                 NrNonIdempotentRules;
    logic [NrMaxRules-1:0][63:0] NonIdempotentAddrBase;
    logic [NrMaxRules-1:0][63:0] NonIdempotentLength;
    int unsigned                 NrExecuteRegionRules;
    logic [NrMaxRules-1:0][63:0] ExecuteRegionAddrBase;
    logic [NrMaxRules-1:0][63:0] ExecuteRegionLength;
    int unsigned                 NrCachedRegionRules;
    logic [NrMaxRules-1:0][63:0] CachedRegionAddrBase;
    logic [NrMaxRules-1:0][63:0] CachedRegionLength;
    int unsigned                 MaxOutstandingStores;
    bit                          DebugEn;
    bit                          SDTRIG;
    bit                          Mcontrol6;
    bit                          Icount;
    bit                          Etrigger;
    bit                          Itrigger;
    bit                          NonIdemPotenceEn;       // Currently only used by V extension (Ara)
    bit                          AxiBurstWriteEn;

    int unsigned ICACHE_SET_ASSOC;
    int unsigned ICACHE_SET_ASSOC_WIDTH;
    int unsigned ICACHE_INDEX_WIDTH;
    int unsigned ICACHE_TAG_WIDTH;
    int unsigned ICACHE_LINE_WIDTH;
    int unsigned ICACHE_USER_LINE_WIDTH;
    cache_type_t DCacheType;
    int unsigned DcacheIdWidth;
    int unsigned DCACHE_SET_ASSOC;
    int unsigned DCACHE_SET_ASSOC_WIDTH;
    int unsigned DCACHE_INDEX_WIDTH;
    int unsigned DCACHE_TAG_WIDTH;
    int unsigned DCACHE_LINE_WIDTH;
    int unsigned DCACHE_USER_LINE_WIDTH;
    int unsigned DCACHE_USER_WIDTH;
    int unsigned DCACHE_OFFSET_WIDTH;
    int unsigned DCACHE_NUM_WORDS;

    int unsigned DCACHE_MAX_TX;

    bit DcacheFlushOnFence;
    bit DcacheFlushOnFenceI;
    bit DcacheInvalidateOnFlush;

    int unsigned DATA_USER_EN;
    int unsigned WtDcacheWbufDepth;
    int unsigned WtDcacheFixupDepth;
    bit WtDcacheFixupVoidKeepEn;
    int unsigned FETCH_USER_WIDTH;
    int unsigned FETCH_USER_EN;
    // Match TB `parameter int unsigned AXI_USER_EN` (was bit; width mismatch
    // tripped vlt 5.020 internal fault on ariane_testharness default).
    int unsigned AXI_USER_EN;

    int unsigned FETCH_WIDTH;
    int unsigned FETCH_ALIGN_BITS;
    int unsigned INSTR_PER_FETCH;
    int unsigned LOG2_INSTR_PER_FETCH;

    int unsigned ModeW;
    int unsigned ASIDW;
    int unsigned VMIDW;
    int unsigned PPNW;
    int unsigned GPPNW;
    vm_mode_t MODE_SV;
    int unsigned SV;
    int unsigned SVX;

    int unsigned X_NUM_RS;
    int unsigned X_ID_WIDTH;
    int unsigned X_RFR_WIDTH;
    int unsigned X_RFW_WIDTH;
    int unsigned X_NUM_HARTS;
    int unsigned X_HARTID_WIDTH;
    int unsigned X_DUALREAD;
    int unsigned X_DUALWRITE;
    int unsigned X_ISSUE_REGISTER_SPLIT;

    ai_cfg_t AiCfg;

  } cva6_cfg_t;

  /// Empty configuration to sanity check proper parameter passing. Whenever
  /// you develop a module that resides within the core, assign this constant.
  localparam cva6_cfg_t cva6_cfg_empty = cva6_cfg_t'(0);

  /// Utility function being called to check parameters. Not all values make
  /// sense for all parameters, here is the place to sanity check them.
  function automatic void check_cfg(cva6_cfg_t Cfg);
    // pragma translate_off
    assert (Cfg.RASDepth > 0);
    assert (Cfg.BTBEntries == 0 || (2 ** $clog2(Cfg.BTBEntries) == Cfg.BTBEntries));
    assert (Cfg.BHTEntries == 0 || (2 ** $clog2(Cfg.BHTEntries) == Cfg.BHTEntries));
    assert (Cfg.NrNonIdempotentRules <= NrMaxRules);
    assert (Cfg.NrExecuteRegionRules <= NrMaxRules);
    assert (Cfg.NrCachedRegionRules <= NrMaxRules);
    assert (Cfg.NrPMPEntries <= 64);
    assert (Cfg.FETCH_WIDTH == 32 || Cfg.FETCH_WIDTH == 64 ||
            Cfg.FETCH_WIDTH == 128 || Cfg.FETCH_WIDTH == 256)
    else $fatal(1, "[frontend] fetch width not supported");
    // Multi-issue width (superscalar precursor to OoO).
    assert (Cfg.NrIssuePorts >= 1 && Cfg.NrIssuePorts <= CVA6_MAX_ISSUE_PORTS);
    assert (!(Cfg.NrIssuePorts > 1 && !Cfg.SuperscalarEn));
    assert (!(Cfg.SuperscalarEn && Cfg.NrIssuePorts < 2));
    assert (Cfg.NrCommitPorts >= 1 && Cfg.NrCommitPorts <= CVA6_MAX_ISSUE_PORTS);
    assert (!(Cfg.SuperscalarEn && Cfg.NrCommitPorts < 2));
    assert (Cfg.NrALUs >= 1 && Cfg.NrALUs <= CVA6_MAX_ISSUE_PORTS);
    assert (!(Cfg.SuperscalarEn && Cfg.NrALUs < 2));
    assert (Cfg.NrIssuePorts <= Cfg.NR_SB_ENTRIES);
    // CVXIF offload is wired for issue port 0 only, and with CvxifEn the decoder
    // deliberately withholds `ex.valid` for an illegal instruction
    // (core/decoder.sv:1976) so the coprocessor can claim the encoding first;
    // the exception is then re-raised from the rejection
    // (core/cvxif_fu.sv:69, driven by x_transaction_rejected). But every gate on
    // that path keys off `issue_instr_i[0]`
    // (core/issue_read_operands.sv:288, and its own "TODO check only for 1st
    // instruction ??"). So on a multi-issue core an illegal instruction that
    // lands on any port != 0 gets fu=CVXIF, no ex.valid, no CVXIF transaction,
    // and cvxif_fu never returns valid: it neither traps nor retires, and the
    // machine wedges. That is an ISA violation, so it must not be reachable by
    // choosing a parameter combination -- fail elaboration instead of building a
    // core that silently drops illegal-instruction exceptions. Lift this once the
    // offload path covers all NrIssuePorts.
    assert (!(Cfg.CvxifEn && Cfg.NrIssuePorts > 1))
    else
      $fatal(1,
             "[cfg] CvxifEn with NrIssuePorts>1 is unsound: CVXIF offload is port-0 only, so an illegal instruction on another port never traps");
    assert (Cfg.INSTR_PER_FETCH >= 1);
    // Support for disabling MIP.MSIP and MIE.MSIE in Hypervisor and Supervisor mode is not supported
    // Software Interrupt can be disabled when there is only M machine mode in CVA6.
    assert (!(Cfg.RVS && !Cfg.SoftwareInterruptEn));
    assert (!(Cfg.RVH && !Cfg.SoftwareInterruptEn));
    assert (!(Cfg.RVZCMT && ~Cfg.MmuPresent));
    // Sstc places stimecmp in S-mode; without supervisor mode the CSRs have no home.
    assert (!(Cfg.SstcEn && !Cfg.RVS));
    // U9.0: Sstc under H is legal when RVH is on — needs vstimecmp + henvcfg.STCE
    // (implemented in csr_regfile). RVH without Sstc is fine (legacy HS).
    assert (!(Cfg.RVH && !Cfg.RVS));
    // Sscofpmf needs the HPM counters that carry the OF bits.
    assert (!(Cfg.SscofpmfEn && !Cfg.PerfCounterEn));
    // U7ᵇ extension legality.
    // Svpbmt is an Sv39+ feature (PTE bits 62:61); only meaningful with an MMU on RV64.
    assert (!(Cfg.SvpbmtEn && !Cfg.MmuPresent));
    assert (!(Cfg.SvpbmtEn && Cfg.IS_XLEN32));
    // Zacas (AMOCAS.W/D) depends on Zaamo / RVA atomics.
    assert (!(Cfg.RVZacas && !Cfg.RVA));
    // U6 L2 / multi-hart (SMT) / multi-core legality.
    assert (Cfg.NrHarts >= 1 && Cfg.NrHarts <= CVA6_MAX_SMT_HARTS);
    assert (!(Cfg.NrHarts > 1 && !Cfg.RVS));
    assert (!(Cfg.NrHarts > 1 && !Cfg.MmuPresent));
    // U6.1 SMT: when multi-hart, require a quantum ≥1 and a legal policy.
    assert (Cfg.SmtPolicy inside {SMT_RR, SMT_SWITCH_ON_MISS, SMT_HYBRID});
    assert (!(Cfg.NrHarts > 1 && Cfg.SmtFetchQuantum == 0));
    // Multi-hart needs checkpoint depth for per-hart BP recovery (if ckpts used).
    assert (!(Cfg.NrHarts > 1 && Cfg.SpeculativeSb && Cfg.BPCkptDepth != 0 &&
              Cfg.BPCkptDepth < Cfg.NR_SB_ENTRIES));
    // U6.2 multi-core cluster (1..CVA6_MAX_CORES; multi-core path is 2–8).
    assert (Cfg.NrCores >= 1 && Cfg.NrCores <= CVA6_MAX_CORES);
    // Software hart count is the PRODUCT of the two topology axes; the PLIC
    // context budget scales with it, not with either factor. Both operands are
    // compile-time constants, so this belongs at elaboration.
    assert (Cfg.NrCores * Cfg.NrHarts <= CVA6_MAX_SW_HARTS);
    assert (Cfg.CohPolicy inside {COH_WRITE_INVAL, COH_BROADCAST, COH_FILTERED, COH_OOO});
    assert (Cfg.CohPolicy != COH_OOO ||
            (Cfg.OoOEn && !Cfg.FpPresent && Cfg.L2En && Cfg.NrCores > 1 && Cfg.DCacheType == WT &&
             Cfg.ICACHE_LINE_WIDTH == Cfg.DCACHE_LINE_WIDTH));
    assert (!(Cfg.NrCores > 1 && Cfg.SnoopFilterEn && Cfg.SnoopFilterEntries == 0));
    assert (Cfg.SnoopFilterEntries == 0 ||
            (2 ** $clog2(Cfg.SnoopFilterEntries) == Cfg.SnoopFilterEntries));
    assert (Cfg.CohInvalDepth == 0 ||
            (2 ** $clog2(Cfg.CohInvalDepth) == Cfg.CohInvalDepth));
    // SL-W write-buffer fixup queue must not exceed the write buffer and must
    // be a power of two (or zero) when enabled.
    assert (Cfg.WtDcacheFixupDepth <= Cfg.WtDcacheWbufDepth);
    assert (Cfg.WtDcacheFixupDepth == 0 ||
            (2 ** $clog2(Cfg.WtDcacheFixupDepth) == Cfg.WtDcacheFixupDepth));
    // Multi-core needs supervisor + MMU for SMP Linux (same gate as multi-hart).
    assert (!(Cfg.NrCores > 1 && !Cfg.RVS));
    assert (!(Cfg.NrCores > 1 && !Cfg.MmuPresent));
    assert (!(Cfg.L2En && Cfg.L2ByteSize == 0));
    assert (!(Cfg.L2En && Cfg.L2SetAssoc == 0));
    assert (!Cfg.L2RoundRobinEn || Cfg.L2En);
    assert (!Cfg.L2RoundRobinEn || Cfg.L2SetAssoc >= 2);
    assert (!Cfg.L2RoundRobinEn || (2 ** $clog2(Cfg.L2SetAssoc) == Cfg.L2SetAssoc));
    // L2 line width: 0 → inferred 512 (64 B / Zic64b), explicit 512, or match L1
    // DCACHE_LINE_WIDTH. L1 may be 128b (16 B) while L2 is 64 B — that is legal.
    assert (!(Cfg.L2En && Cfg.L2LineWidth != 0 && Cfg.L2LineWidth != 512 &&
              Cfg.DCACHE_LINE_WIDTH != 0 && Cfg.L2LineWidth != Cfg.DCACHE_LINE_WIDTH));
    assert (Cfg.L2MshrDepth == 0 || (2 ** $clog2(Cfg.L2MshrDepth) == Cfg.L2MshrDepth));
    assert (Cfg.L2DataBanks == 0 || (2 ** $clog2(Cfg.L2DataBanks) == Cfg.L2DataBanks));
    // scountovf is an S-mode CSR; without RVS there is no supervisor observer.
    assert (!(Cfg.SscofpmfEn && !Cfg.RVS));
    // U1 prediction fabric legality.
    assert (Cfg.BPGhistLen <= 64);
    assert (Cfg.BPTageTables <= 8);
    assert (Cfg.BPTageTableEntries == 0 ||
            (2 ** $clog2(Cfg.BPTageTableEntries) == Cfg.BPTageTableEntries));
    assert (Cfg.BPIndirectEntries == 0 ||
            (2 ** $clog2(Cfg.BPIndirectEntries) == Cfg.BPIndirectEntries));
    assert (!(Cfg.BPIndirectEn && Cfg.BTBEntries == 0));
    assert (!(Cfg.BPType == TAGE_LITE && Cfg.BPTageTables == 0));
    assert (!(Cfg.BPType == GSHARE && Cfg.BHTEntries == 0));
    assert (!(Cfg.BPType == GSHARE && Cfg.BPGhistLen == 0 && Cfg.BHTHist == 0));
    // Checkpoint depth must cover the in-flight window when the scoreboard is speculative.
    assert (!(Cfg.SpeculativeSb && Cfg.BPCkptDepth != 0 &&
              Cfg.BPCkptDepth < Cfg.NR_SB_ENTRIES));
    // U3 L1 energy / MLP legality.
    assert (!(Cfg.WayPredEn && Cfg.ICACHE_SET_ASSOC <= 1));
    assert (Cfg.WayPredEntries == 0 ||
            (2 ** $clog2(Cfg.WayPredEntries) == Cfg.WayPredEntries));
    assert (!(Cfg.HwPrefetchEn &&
              !(Cfg.DCacheType inside {HPDCACHE_WT, HPDCACHE_WB, HPDCACHE_WT_WB})));
    // U2 decoupled front-end legality.
    assert (!(Cfg.FdipEn && Cfg.FtqDepth < 2));
    assert (!(Cfg.FtqDepth == 0 && (Cfg.FdipEn || Cfg.LoopBufEn)));
    assert (Cfg.LoopBufEntries == 0 ||
            (2 ** $clog2(Cfg.LoopBufEntries) == Cfg.LoopBufEntries));
    assert (Cfg.FtqDepth == 0 || (2 ** $clog2(Cfg.FtqDepth) == Cfg.FtqDepth));
    // U4 slice-OoO legality (mutually exclusive with U5; needs speculative SB + non-blocking D$).
    assert (!(Cfg.SliceOoOEn && Cfg.OoOEn));
    assert (!(Cfg.SliceOoOEn && !Cfg.SpeculativeSb));
    assert (!(Cfg.SliceOoOEn && Cfg.BPCkptDepth != 0 &&
              Cfg.BPCkptDepth < Cfg.SliceAiqDepth));
    assert (!(Cfg.SliceOoOEn &&
              !(Cfg.DCacheType inside {HPDCACHE_WT, HPDCACHE_WB, HPDCACHE_WT_WB})));
    assert (!(Cfg.SliceOoOEn && Cfg.SliceAiqDepth == 0));
    assert (!(Cfg.SliceOoOEn && Cfg.SliceBiqDepth == 0));
    assert (Cfg.SliceIstEntries == 0 ||
            (2 ** $clog2(Cfg.SliceIstEntries) == Cfg.SliceIstEntries));
    assert (Cfg.SliceAiqDepth == 0 ||
            (2 ** $clog2(Cfg.SliceAiqDepth) == Cfg.SliceAiqDepth));
    assert (Cfg.SliceBiqDepth == 0 ||
            (2 ** $clog2(Cfg.SliceBiqDepth) == Cfg.SliceBiqDepth));
    // U5 full OoO legality (production path). OoOEn=0 must remain bit-identical.
    assert (!(Cfg.OoOEn && Cfg.SliceOoOEn));
    assert (!(Cfg.OoOEn && !Cfg.SpeculativeSb));
    assert (!(Cfg.OoOEn && Cfg.RobEntries == 0));
    assert (!(Cfg.OoOEn && Cfg.PrfEntries != 0 && Cfg.PrfEntries <= 32 + Cfg.RobEntries));
    assert (!(Cfg.OoOEn && Cfg.BPCkptDepth != 0 && Cfg.BPCkptDepth < Cfg.RobEntries));
    // The OoO rename/PRF path has no notion of a hart or of a floating-point
    // register class, and these are not conservative gaps but aliasing ones:
    //  * core/ooo/** contains no hart signal at all. g6lc_rename keeps a single
    //    32-entry architectural map indexed by rd[4:0], so with NrHarts > 1 the
    //    two harts' architectural registers occupy the SAME map entries and
    //    silently clobber each other.
    //  * need_rd excludes FP destinations from renaming, so with FpPresent the FP
    //    results are neither renamed nor tracked in the busy table, and an FP
    //    consumer can read a stale value.
    // UPDATED 2026-09-19: both reasons are now narrower than when written, and
    // the duplicate copies of these guards live in g6lc_ooo_dispatch.
    //  * NrHarts: g6lc_rename IS per-hart now (maps, checkpoints, ownership,
    //    per-hart flush, tested at NR_HARTS=2). What remains is that the IQ,
    //    ROB and LSQ contain no hart signal at all, so memory ordering and
    //    store-to-load forwarding still alias across harts.
    //  * FpPresent: the split FP register class EXISTS and is tested at module
    //    level, and the FP-enabled full core elaborates and synthesises clean.
    //    What is missing is behavioural evidence — no FP simulation, no
    //    independent-reference comparison.
    // g6lc64_ooo_server sets OoOEn=1 with NrHarts=2 and RVF/RVD=1, so it trips
    // both deliberately. See architecture/out-of-order/README.md.
    // Integer multi-hart OoO is legal under the drained handoff: the thread
    // selector switches only when the scoreboard and store queues are empty
    // (asserted at the switch in cva6.sv as ooo_switch_drained), so the
    // hart-blind IQ/ROB/LSQ never hold two harts' work at once. Qualified
    // 2026-09-23 (T6a): the protected dual-hart OpenSBI/HSM profile completes
    // strictDual on g6lc64_smt2_ooo_int and the in-order anchor is exact.
    // FP multi-hart is refused pending hart-tagged lazy-FS (T6b).
    assert (!(Cfg.OoOEn && Cfg.NrHarts > 1 && Cfg.FpPresent));
    // Mixed residency is T6b and stays qualification-gated: clearing the drain
    // gate is legal only on an OoO multi-hart configuration, and until the T6b
    // exit only behind the G6LC_OOO_SMT_MIXED_QUALIFY define.
    assert (Cfg.SmtDrainedHandoff || (Cfg.OoOEn && Cfg.NrHarts > 1));
`ifndef G6LC_OOO_SMT_MIXED_QUALIFY
    assert (Cfg.SmtDrainedHandoff);
`endif
`ifndef G6LC_OOO_FP_QUALIFY
    // Single-hart FP stays illegal in production. G6LC_OOO_FP_QUALIFY exists
    // only for the T5 qualification build that produces the behavioural
    // evidence; it is removed by the T5 commit once the suite passes.
    // Multi-hart FP remains illegal regardless via the NrHarts leg above.
    assert (!(Cfg.OoOEn && Cfg.FpPresent));
`endif
    // The OoO FP writeback narrows the XLEN-wide writeback bus to FLen
    // (g6lc_ooo_dispatch: fprf_wdata = wb_data_i[FLen-1:0]), so an FP result
    // wider than the integer datapath cannot be delivered. RV32+D is legal
    // RISC-V and would hit this; no configured target does it today, and the
    // IN-ORDER path carries the identical construct
    // (issue_read_operands: fp_wdata_pack = wdata_i[FLen-1:0]), so the limit is
    // pre-existing rather than introduced here. Stated explicitly for the OoO
    // path so such a configuration cannot be created silently; widening the
    // writeback bus is the fix if RV32+D is ever wanted.
    assert (!(Cfg.OoOEn && Cfg.FpPresent && Cfg.FLen > Cfg.XLEN));
    // FSE deep speculation (DeepSpecEn=0 keeps legacy STQ depth / package depths).
    assert (!(Cfg.DeepSpecEn && !Cfg.SpeculativeSb));
    assert (!(Cfg.DeepSpecEn && Cfg.BPCkptDepth != 0 &&
              Cfg.BPCkptDepth < Cfg.NR_SB_ENTRIES));
    assert (!(Cfg.DeepSpecEn && Cfg.MaxOutstandingStores > 16)); // STQ CAM cap v1
    // L3 sits below L2; line size must match for inclusive hierarchy.
    assert (!(Cfg.L3En && !Cfg.L2En));
    assert (!(Cfg.L3En && Cfg.L3ByteSize == 0));
    assert (!(Cfg.L3En && Cfg.L2LineWidth != 0 && Cfg.L3LineWidth != 0 &&
              Cfg.L3LineWidth != Cfg.L2LineWidth));
    assert (!(Cfg.ServerPrefetchEn && !Cfg.L2En && !Cfg.L3En));
    // WT boundary allocation attributes only mean something with the WT L1 and a memory-side L2.
    assert (!(Cfg.WtAxiAllocEn && (Cfg.DCacheType != WT || !Cfg.L2En)));
    // L3 geometry legality mirrors L2: zero (auto-infer) or a power of two.
    assert (Cfg.L3MshrDepth == 0 || (2 ** $clog2(Cfg.L3MshrDepth) == Cfg.L3MshrDepth));
    assert (Cfg.L3DataBanks == 0 || (2 ** $clog2(Cfg.L3DataBanks) == Cfg.L3DataBanks));
    assert (Cfg.L3SetAssoc == 0 || (2 ** $clog2(Cfg.L3SetAssoc) == Cfg.L3SetAssoc));
    // Inclusion needs an L3 at least as large as the L2 it back-invalidates.
    assert (!(Cfg.L3InclusiveEn && (!Cfg.L3En || Cfg.L3ByteSize < Cfg.L2ByteSize)));
    assert (!(Cfg.L2TagSramEn && !Cfg.L2En));
    assert (!(Cfg.L2WriteUpdateEn && !Cfg.L2En));

    // --- Xg6lcai AI matrix plane (architecture/ai-matrix/isa-encoding.md) ---
    // Seam exclusivity. CVXIF and the accelerator port are already mutually
    // exclusive (cva6.sv gen_err_xif_and_acc); the AI plane must pick exactly
    // one of them, and the accelerator seam is incompatible with RVV because
    // EnableAccelerator is derived from it (build_config_pkg).
    assert (!(Cfg.AiCfg.MatrixEn && Cfg.AiCfg.AccelEn && Cfg.CvxifEn));
    assert (!(Cfg.AiCfg.MatrixEn && !Cfg.AiCfg.AccelEn && !Cfg.CvxifEn));
    assert (!(Cfg.AiCfg.AccelEn && Cfg.RVV));
    // Native tile load/store needs a memory port. The CVXIF seam has none, so
    // under seam B these are synthesised by the compiler (isa-encoding s3.3).
    assert (!(Cfg.AiCfg.TileLdEn && !Cfg.AiCfg.AccelEn));
    // Optional instruction groups and U-mode issue imply the master enable.
    assert (!((Cfg.AiCfg.RequantEn || Cfg.AiCfg.SparseEn || Cfg.AiCfg.UmodeEn) &&
              !Cfg.AiCfg.MatrixEn));
    assert (!(Cfg.AiCfg.Queues > 0 && !Cfg.AiCfg.MatrixEn));
    assert (!(Cfg.AiCfg.PolicyCodecEn && (!Cfg.AiCfg.MatrixEn || Cfg.AiCfg.Queues == 0)))
      else $error("AiCfg.PolicyCodecEn requires the matrix plane and a T2 queue");
    assert (!(Cfg.AiCfg.PolicyBenefitEn && !Cfg.AiCfg.PolicyCodecEn))
      else $error("AiCfg.PolicyBenefitEn requires the policy codec");
    assert (!(Cfg.AiCfg.PolicySubcodeEn && !Cfg.AiCfg.PolicyBenefitEn))
      else $error("AiCfg.PolicySubcodeEn requires policy benefit steering");
    assert (!(Cfg.AiCfg.PolicySubcodeCacheEn && !Cfg.AiCfg.PolicySubcodeEn))
      else $error("AiCfg.PolicySubcodeCacheEn requires policy subcode evaluation");
    // V/A-Turbo needs the sub-code to carry its (groups_log2, precision_class)
    // word, and it needs the float plane because its measured-best step is FP16.
    // No datapath consumes it yet, so the gate exists to keep an
    // arithmetic-changing feature unreachable rather than to switch it on.
    assert (!(Cfg.AiCfg.VaTurboEn && !Cfg.AiCfg.PolicySubcodeEn))
      else $error("AiCfg.VaTurboEn requires policy subcode evaluation");
    assert (!(Cfg.AiCfg.VaTurboEn && !Cfg.AiCfg.IslandFpEn))
      else $error("AiCfg.VaTurboEn requires the island floating-point plane");
    assert (!(Cfg.AiCfg.IslandFpEn && (!Cfg.AiCfg.MatrixEn || Cfg.AiCfg.Queues == 0 ||
              !Cfg.RVF || !Cfg.RVD)))
      else $error("AiCfg.IslandFpEn requires the matrix plane, a T2 queue, RVF and RVD");
    assert (!((Cfg.AiCfg.Int4En || Cfg.AiCfg.Sparse24En) && !Cfg.AiCfg.MatrixEn));
    // Numeric formats. The mask and the two legacy grant bits describe the same
    // thing, so they must not disagree: software may read either, and a part
    // that answered "INT4" through one and "no INT4" through the other would be
    // undiscoverable rather than merely wrong.
    assert (!(Cfg.AiCfg.MatrixEn &&
              !ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_INT)))
      else $error("AiCfg.FormatMask must grant AI_FMT_INT (dense INT8): it is the format the golden and the requant rule are written in");
    assert (ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_INT4) == Cfg.AiCfg.Int4En)
      else $error("AiCfg.FormatMask AI_FMT_INT4 disagrees with AiCfg.Int4En");
    assert (ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_SP24) == Cfg.AiCfg.Sparse24En)
      else $error("AiCfg.FormatMask AI_FMT_SP24 disagrees with AiCfg.Sparse24En");
    // No format bit outside the defined enumeration.
    assert ((Cfg.AiCfg.FormatMask >> AI_FMT_WIDTH) == 0)
      else $error("AiCfg.FormatMask sets a bit above AI_FMT_WIDTH");
    // A part granting no format at all must not claim the plane.
    assert (!(!Cfg.AiCfg.MatrixEn && Cfg.AiCfg.FormatMask != 0));
    // Float formats need a float-capable core to move operands and to hold the
    // requant scale: the core-attached plane sources scales through the FP
    // register file, and a descriptor asking for FP16/BF16/FP32 on an
    // integer-only part could not be honoured even by the island, because the
    // host has no way to build the operands.
    assert (!((ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_FP16) ||
               ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_BF16) ||
               ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_FP32) ||
               ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_FP8_E4M3) ||
               ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_FP8_E5M2)) && !Cfg.RVF))
      else $error("AiCfg.FormatMask grants a float format but RVF is 0");
    // FP32 accumulation over a 32-bit accumulator leaves no headroom, so a part
    // granting FP32 must also carry RVD for the host-side reference path.
    assert (!(ai_fmt_granted(Cfg.AiCfg.FormatMask, AI_FMT_FP32) && !Cfg.RVD))
      else $error("AiCfg.FormatMask grants AI_FMT_FP32 but RVD is 0");
    // Geometry: non-zero and power-of-two when the plane is enabled.
    assert (!(Cfg.AiCfg.MatrixEn && (Cfg.AiCfg.TileM == 0 ||
              2 ** $clog2(Cfg.AiCfg.TileM) != Cfg.AiCfg.TileM)));
    assert (!(Cfg.AiCfg.MatrixEn && (Cfg.AiCfg.TileN == 0 ||
              2 ** $clog2(Cfg.AiCfg.TileN) != Cfg.AiCfg.TileN)));
    assert (!(Cfg.AiCfg.MatrixEn && (Cfg.AiCfg.TileK == 0 ||
              2 ** $clog2(Cfg.AiCfg.TileK) != Cfg.AiCfg.TileK)));
    assert (!(Cfg.AiCfg.MatrixEn && Cfg.AiCfg.TileCount == 0));
    assert (!(Cfg.AiCfg.MatrixEn && Cfg.AiCfg.AccDepth == 0));
    // Accumulators bank per hart so an AI-heavy hart cannot starve the control
    // hart under SMT (architecture/ai-matrix/README.md s5).
    assert (!(Cfg.AiCfg.MatrixEn && Cfg.AiCfg.AccBanks < Cfg.NrHarts));
    // Rings are power-of-two and must be sized when present.
    assert (!(Cfg.AiCfg.Queues > 0 && Cfg.AiCfg.QueueDepth == 0));
    assert (Cfg.AiCfg.QueueDepth == 0 ||
            2 ** $clog2(Cfg.AiCfg.QueueDepth) == Cfg.AiCfg.QueueDepth);
    // Priority classes exist only alongside rings, and there is always at
    // least one class when rings are present.
    assert (!(Cfg.AiCfg.Queues > 0 && Cfg.AiCfg.QosClasses == 0));
    assert (!(Cfg.AiCfg.Queues == 0 && Cfg.AiCfg.QosClasses > 0));
    // The CVXIF seam must actually select the AI coprocessor, and no other
    // coprocessor may squat the seam while the AI plane owns it.
    assert (!(Cfg.AiCfg.MatrixEn && Cfg.CvxifEn &&
              Cfg.CoproType != COPRO_G6LC_AI));
    assert (!(!Cfg.AiCfg.MatrixEn && Cfg.CoproType == COPRO_G6LC_AI));
    // pragma translate_on
  endfunction

  function automatic logic range_check(logic [63:0] base, logic [63:0] len, logic [63:0] address);
    // if len is a power of two, and base is properly aligned, this check could be simplified
    // Extend base by one bit to prevent an overflow.
    return (address >= base) && (({1'b0, address}) < (65'(base) + len));
  endfunction : range_check


  function automatic logic is_inside_nonidempotent_regions(cva6_cfg_t Cfg, logic [63:0] address);
    logic [NrMaxRules-1:0] pass;
    pass = '0;
    for (int unsigned k = 0; k < Cfg.NrNonIdempotentRules; k++) begin
      pass[k] = range_check(Cfg.NonIdempotentAddrBase[k], Cfg.NonIdempotentLength[k], address);
    end
    return |pass;
  endfunction : is_inside_nonidempotent_regions

  function automatic logic is_inside_execute_regions(cva6_cfg_t Cfg, logic [63:0] address);
    // if we don't specify any region we assume everything is accessible
    logic [NrMaxRules-1:0] pass;
    if (Cfg.NrExecuteRegionRules != 0) begin
      pass = '0;
      for (int unsigned k = 0; k < Cfg.NrExecuteRegionRules; k++) begin
        pass[k] = range_check(Cfg.ExecuteRegionAddrBase[k], Cfg.ExecuteRegionLength[k], address);
      end
      return |pass;
    end else begin
      return 1;
    end
  endfunction : is_inside_execute_regions

  function automatic logic is_inside_cacheable_regions(cva6_cfg_t Cfg, logic [63:0] address);
    automatic logic [NrMaxRules-1:0] pass;
    pass = '0;
    for (int unsigned k = 0; k < Cfg.NrCachedRegionRules; k++) begin
      pass[k] = range_check(Cfg.CachedRegionAddrBase[k], Cfg.CachedRegionLength[k], address);
    end
    return |pass;
  endfunction : is_inside_cacheable_regions

endpackage
