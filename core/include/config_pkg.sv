// Copyright 2023 Thales DIS France SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales

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
    COPRO_EXAMPLE
  } copro_type_t;

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
    assert (Cfg.CohPolicy inside {COH_WRITE_INVAL, COH_BROADCAST, COH_FILTERED});
    assert (!(Cfg.NrCores > 1 && Cfg.SnoopFilterEn && Cfg.SnoopFilterEntries == 0));
    assert (Cfg.SnoopFilterEntries == 0 ||
            (2 ** $clog2(Cfg.SnoopFilterEntries) == Cfg.SnoopFilterEntries));
    assert (Cfg.CohInvalDepth == 0 ||
            (2 ** $clog2(Cfg.CohInvalDepth) == Cfg.CohInvalDepth));
    // Multi-core needs supervisor + MMU for SMP Linux (same gate as multi-hart).
    assert (!(Cfg.NrCores > 1 && !Cfg.RVS));
    assert (!(Cfg.NrCores > 1 && !Cfg.MmuPresent));
    assert (!(Cfg.L2En && Cfg.L2ByteSize == 0));
    assert (!(Cfg.L2En && Cfg.L2SetAssoc == 0));
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
