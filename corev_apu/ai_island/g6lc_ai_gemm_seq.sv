// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1/I3-lite: INT8 GEMM over AXI with banked tc_sram tiles + PE array.
//
//   C[i,j] (i32) = sum_t A[i,t]*B[j,t]
//
// AI-X9 operand layout (descriptor ContractVersion 2):
//   A row-major   [m][k], lda strides i, contiguous along t
//   B **k-major** [n][k], ldb strides j, contiguous along t
//   C row-major   [m][n], ldc = n
//
// Both operands have the REDUCTION axis contiguous. That is what lets one
// traversal and one format-scaling rule serve both, and it is what makes a
// sub-byte format expressible: two INT4 elements packed in a byte must feed the
// same C[i,j] accumulator, so they must be consecutive t. Rationale and the
// rejected alternatives: architecture/ai-matrix/numeric-formats-datapath.md §8.
//
// Phases:
//   1) Load A → banked tile SRAM (bank = t % PeLanes)
//      Multi-byte unpack; AXI INCR burst (up to MaxBurstBeats) along the row.
//   2) Load B → banked tile SRAM (bank = t % PeLanes), identical traversal to
//      A with j as the row index. One beat spreads across PeLanes banks at one
//      address each, so the tile is 1R1W like A's.
//   3) MAC: PeLanes parallel products/cycle via g6lc_ai_pe_dot
//   4) Store C: one 8-byte pair (or one 4-byte tail) per W beat, placed at
//      addr % BytesPerBeat. On a 64-bit bus that lane is 0. A wider bus keeps
//      aw.size at 8 (or 4) bytes so the pair does not fill the beat.
//      Multi-beat INCR AW (up to MaxBurstBeats pair-beats) along a C row;
//      dual-bank combo read so each W is one cycle when PeLanes>=2.
//      I3: trail-store completed rows during MAC (stc_i < mac_i) so C AW/W
//      rides free AXI cycles; drain tail after last MAC row.
//
// C multi-banked (j % PeLanes). Beat packing parameterized by DataWidth.
// Bursts stay within a single A row (k), B row (k), or C row (n); never cross.
//
// Bounds: m,n,k ∈ [1, MaxM/MaxN/MaxK], or MaxDim when those are 0.
// (MaxAROut) hides inter-burst memory latency on A/B loads; one AW.

module g6lc_ai_gemm_seq #(
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned DataWidth = 64,
    parameter int unsigned IdWidth   = 4,
    parameter int unsigned MaxDim    = 8,
    // 0 keeps the square MaxDim bound. The live island sets these apart
    // so 1024×128 and 512×256 fit without a 1024-cube.
    parameter int unsigned MaxM      = 0,
    parameter int unsigned MaxN      = 0,
    parameter int unsigned MaxK      = 0,
    parameter int unsigned PeLanes   = 4,  // K lanes per dot (power of two)
    // V2 column array: OutCols dot units share one A word and each reads its own
    // B row, so OutCols consecutive output columns complete per K step and the
    // MAC rate is OutCols x PeLanes. B is banked by column group (j % OutCols),
    // each group OperandWordsB/OutCols words, so the byte capacity is unchanged.
    // 1 is the single-dot engine (bit- and cycle-identical to the pre-V2 RTL).
    // Accumulate-mode jobs run one column at a time (their seed read owns the
    // single C read port); columns past n are masked.
    parameter int unsigned OutCols   = 1,
    parameter bit          DotPipeFloat = 1'b0, // 0: combinational g6lc_ai_pe_dot_float; 1: pipelined dot product with valid handshake
    parameter int unsigned MaxAROut  = 2,  // I3: multi-outstanding AR; live = 2
    // Shared DRAM stripe (g6lc_ai_island_cfg_pkg). N=1 leaves MaxBurstBeats
    // at 255 so the live 256³ fixture stays bit-identical. N>1 caps each
    // INCR at the 64 B stripe so GEMM and core L2 fills share one map.
    parameter int unsigned NrChannels = 1,
    parameter int unsigned ChanShift  = 6,
    parameter bit          ReuseBEn  = 1'b0,
    // Resident-B directory depth (VA-Turbo). With 2 slots the B bank is split in
    // halves and two panels that each fit a half stay resident together, so a
    // layer whose N spans two panels (the decode case that alternates them every
    // token) still hits. A panel that needs more than a half takes the whole bank
    // ("big") and evicts the other slot. 1 = the single resident key.
    parameter int unsigned ReuseBSlots = 2,
    parameter bit          ReuseAEn   = 1'b0,
    parameter int unsigned MaxElementBytes = 4,
    parameter type         axi_req_t  = logic,
    parameter type         axi_resp_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,
    input  logic        start_i,
    input  logic [31:0] m_i,
    input  logic [31:0] n_i,
    input  logic [31:0] k_i,
    input  logic [15:0] lda_i,
    input  logic [15:0] ldb_i,
    // C row pitch in elements (0 = n, the single-engine contract). A cluster
    // dispatch hands each engine a column slice of one C panel, so the slice's
    // rows are `ldc` apart while its width is the slice's n.
    input  logic [15:0] ldc_i,
    input  logic [2:0]  numfmt_i,
    // flags.accmode == 01: seed every C[i][j] reduction from the word already in
    // memory (ST_LC loads the C tile first). The top grants/refuses; this only executes.
    input  logic        accumulate_i,
    input  logic [3:0]  ar_max_i,  // 0 = use parameter MaxAROut
    input  logic [AddrWidth-1:0] ptr_a_i,
    input  logic [AddrWidth-1:0] ptr_b_i,
    input  logic [AddrWidth-1:0] ptr_c_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        err_o,
    // I3 PMU: sticky after last job (cleared on next start)
    output logic [31:0] pmu_r_beats_o,
    output logic [31:0] pmu_w_beats_o,
    output logic [31:0] pmu_cycles_o,
    // Stage-2 characterization: per-job cycles in each phase and stalled handshakes.
    // {STC, MAC, LB, LA} phase cycles; AR held without ready, R valid without ready
    // (MAC-side backpressure), W held without ready. Reset at job start like the others.
    output logic [3:0][31:0] pmu_phase_o,
    output logic [2:0][31:0] pmu_stall_o,
    input  logic        reuse_b_i,
    input  logic [31:0] reuse_b_epoch_i,
    input  logic        reuse_b_invalidate_i,
    output logic        pmu_reuse_b_hit_o,
    input  logic        reuse_a_i,
    input  logic [31:0] reuse_a_epoch_i,
    input  logic        reuse_a_invalidate_i,
    output logic        pmu_reuse_a_hit_o,
    output axi_req_t    axi_req_o,
    input  axi_resp_t   axi_resp_i
);

  // Bit-granular copies of the AXI aggregates. The master's ready signals may depend
  // on the slave's valids (legal), but on a whole-struct view that reads as a
  // request<->response loop; splitting keeps Verilator's cycle check exact.
  axi_req_t  axi_req_d /*verilator split_var*/;
  axi_resp_t axi_resp_s /*verilator split_var*/;
  assign axi_req_o  = axi_req_d;
  assign axi_resp_s = axi_resp_i;

  localparam int unsigned LimM = (MaxM != 0) ? MaxM : MaxDim;
  localparam int unsigned LimN = (MaxN != 0) ? MaxN : MaxDim;
  localparam int unsigned LimK = (MaxK != 0) ? MaxK : MaxDim;
  localparam int unsigned LimHi = (LimM > LimN) ?
      ((LimM > LimK) ? LimM : LimK) : ((LimN > LimK) ? LimN : LimK);
  // C: j runs to LimN. A rows are LimM, B rows are LimN, K is LimK.
  localparam int unsigned KPerBank     = (LimN + PeLanes - 1) / PeLanes;
  localparam int unsigned BankWords    = LimM * KPerBank;
  localparam int unsigned BankAddrW    = (BankWords > 1) ? $clog2(BankWords) : 1;
  localparam int unsigned OperandKPerBank = (MaxElementBytes * LimK + PeLanes - 1) / PeLanes;
  localparam int unsigned OperandWordsA = LimM * OperandKPerBank;
  localparam int unsigned OperandWordsB = LimN * OperandKPerBank;
  localparam int unsigned OperandBankWords = (OperandWordsA > OperandWordsB) ?
      OperandWordsA : OperandWordsB;
  localparam int unsigned OperandBankAddrW = (OperandBankWords > 1) ? $clog2(OperandBankWords) : 1;
  localparam int unsigned LaneW        = (PeLanes > 1) ? $clog2(PeLanes) : 1;
  localparam int unsigned ColShift     = (OutCols > 1) ? $clog2(OutCols) : 0;
  localparam int unsigned ColW         = (OutCols > 1) ? $clog2(OutCols) : 1;
  // B bank words per column group (the flat pitch applies per group).
  localparam int unsigned OperandWordsBGrp = OperandWordsB >> ColShift;
  // Flat panel mapping (K-split-to-residency): operand rows are stored at a
  // per-job pitch of 2^pitch_sh_q bank words (pitch = next power of two of
  // ceil(k_bytes / PeLanes)), not at the fixed LimK pitch. The K box therefore
  // becomes a BYTE capacity -- n * pitch <= OperandWordsB and m * pitch <=
  // OperandWordsA -- so a 256 x 1024 INT8 panel occupies the same bank as a
  // 512 x 512 one and is one job (one resident key) instead of two chained K
  // blocks. The power-of-two pitch keeps the row address a shift (no runtime
  // multiplier); its cost is up to 2x row slack for k_bytes that are not a
  // power-of-two multiple of PeLanes. PeLanes must be a power of two.
  localparam int unsigned LaneShift    = (PeLanes > 1) ? $clog2(PeLanes) : 0;
  localparam int unsigned PitchShW     = $clog2(OperandBankAddrW + 1);
  // VA-turbo reuse keys must hold every accepted m and n; k is 16 bits (lda/ldb width).
  localparam int unsigned DimW = $clog2(LimHi + 1);
  // AXI beat geometry (I3: wider DataWidth raises BytesPerBeat without RTL rewrite)
  localparam int unsigned BytesPerBeat  = DataWidth / 8;
  localparam int unsigned ElemsPerBeat  = (BytesPerBeat > PeLanes) ? PeLanes : BytesPerBeat;
  localparam int unsigned ElemsPerBeatShift = (ElemsPerBeat > 1) ? $clog2(ElemsPerBeat) : 0;
  localparam int unsigned BeatAlignW    = (BytesPerBeat > 1) ? $clog2(BytesPerBeat) : 1;
  localparam int unsigned BeatLaneW     = (BytesPerBeat > 1) ? $clog2(BytesPerBeat) : 1;
  // Max beats per AR/AW (AXI4 max 256 → len=255; keep ≤255 for 8-bit counters)
  localparam int unsigned MaxBurstBeats = 255;
  // Inflight counter width; live MaxAROut=2 → AROutW=2 (bit-identical).
  localparam int unsigned AROutW = (MaxAROut <= 1) ? 1 : $clog2(MaxAROut + 1);
  // Dynamic AR cap from policy prefetch_depth (0 = fall back to MaxAROut)
  logic [AROutW-1:0] ar_max_eff;
  // The runtime input can only LOWER the depth, never raise it past the
  // parameterised MaxAROut the AR bookkeeping (ar_slot_q, ar_lane_mem_q) is
  // sized for; out-of-range and zero both fall back to the parameter.
  assign ar_max_eff = (ar_max_i != '0 && ar_max_i <= AROutW'(MaxAROut))
                      ? AROutW'(ar_max_i)
                      : AROutW'(MaxAROut);
  // N=1 keeps a single AXI ID (cookie / HARD identity). N>1 with a full-beat
  // drain uses one ID per outstanding AR so UNIQUE_IDS=1 can issue into two
  // channels at once. PeLanes < BytesPerBeat keeps the leftover-beat path
  // and therefore the in-order single-ID sequence.
  localparam bit          SplitArId = (NrChannels > 1) && (PeLanes >= BytesPerBeat);
  localparam int unsigned ARSlotW   = (MaxAROut <= 1) ? 1 : $clog2(MaxAROut);
  localparam logic [IdWidth-1:0] ArIdBase = IdWidth'(2);
  // pragma translate_off
  initial begin
    assert (MaxElementBytes inside {1, 2, 4})
      else $error("g6lc_ai_gemm_seq: MaxElementBytes must be 1, 2 or 4");
    assert (MaxAROut >= 1 && MaxAROut <= 8)
      else $error("g6lc_ai_gemm_seq: MaxAROut=%0d not in [1,8] (I3)", MaxAROut);
    assert (g6lc_ai_island_cfg_pkg::dram_channels_ok(NrChannels))
      else $error("g6lc_ai_gemm_seq: NrChannels=%0d not in {1,2,4,8}", NrChannels);
    assert (ChanShift >= 3 && ChanShift <= 16)
      else $error("g6lc_ai_gemm_seq: ChanShift=%0d out of range", ChanShift);
    // The held-beat absorber was removed with the B oct-drain. A beat wider
    // than PeLanes would drop the bytes this cycle does not take.
    assert (PeLanes >= (DataWidth / 8))
      else $error("g6lc_ai_gemm_seq: PeLanes=%0d < %0d bytes/beat",
                  PeLanes, DataWidth / 8);
    assert ((PeLanes & (PeLanes - 1)) == 0)
      else $error("g6lc_ai_gemm_seq: PeLanes=%0d must be a power of two (flat panel pitch is a shift)", PeLanes);
    assert (OutCols >= 1 && (OutCols & (OutCols - 1)) == 0 && OutCols <= PeLanes && OutCols <= LimN)
      else $error("g6lc_ai_gemm_seq: OutCols=%0d must be a power of two, <= PeLanes and <= LimN", OutCols);
  end
  // pragma translate_on

  typedef enum logic [3:0] {
    ST_IDLE  = 4'd0,
    ST_CHK   = 4'd1,
    ST_LA    = 4'd2,
    ST_LB    = 4'd3,
    ST_MAC   = 4'd4,
    ST_STC   = 4'd5,
    ST_DONE  = 4'd6,
    ST_LC    = 4'd7   // accumulate: load the existing C tile before the MAC
  } state_e;

  state_e state_q, state_d;
  logic [31:0] m_q, n_q, k_q;
  logic [15:0] lda_q, ldb_q;
  logic [2:0]  numfmt_q;
  logic [31:0] mac_step;
  logic [31:0] k_bytes;
  logic [AddrWidth-1:0] pa_q, pb_q, pc_q;

  // i,j element indices; t is reduction base (multiple of PeLanes during MAC
  // for INT8, multiple of 2*PeLanes for INT4)
  logic [31:0] i_q, j_q, t_q;
  logic [15:0] ldc_q;
  logic [31:0] ldc_eff;
  assign ldc_eff = (ldc_q == 16'd0) ? n_q : 32'(ldc_q);
  logic [31:0] acc_q [OutCols];
  logic [31:0] acc_d [OutCols];
  // F0b-2: one-cycle pipeline between the PE's pure reduction and the
  // accumulator. The pipeline carries not just the sum, but the i/j address
  // and first/last flags, because the C write and accumulator reset now happen
  // one cycle after the operands were issued.
  logic [31:0] sum_q [OutCols];
  logic [31:0] sum_d [OutCols];
  logic        sum_cv_q [OutCols];  // column g of the drained group is a real column
  logic        sum_cv_d [OutCols];
  logic        sum_v_q, sum_v_d;
  logic        sum_first_q, sum_first_d;
  logic        sum_last_q, sum_last_d;
  logic [31:0] sum_i_q, sum_i_d;
  logic [31:0] sum_j_q, sum_j_d;
  logic        err_q, err_d;
  logic        done_q;
  // Accumulate mode (latched from accumulate_i at start).
  logic        acc_mode_q;
  // ST_LC loader: one outstanding burst, one 32-bit C word written per cycle.
  localparam int unsigned WordsPerBeat = (DataWidth >= 32) ? DataWidth / 32 : 1;
  localparam int unsigned LcWordW      = (WordsPerBeat > 1) ? $clog2(WordsPerBeat) : 1;
  logic [31:0]            lc_total_q, lc_beats_q;   // words, beats
  logic [31:0]            lc_issued_q, lc_recv_q;   // beats issued / received
  logic [7:0]             lc_burst_left_q;
  logic                   lc_ar_busy_q;
  logic [DataWidth-1:0]   lc_buf_q;
  logic                   lc_buf_v_q;
  logic [LcWordW-1:0]     lc_word_q;
  logic [31:0]            lc_e_q, lc_i_q, lc_j_q;
  // next-state (driven in the main process)
  logic                   lc_ar_fire, lc_r_fire, lc_w_fire;
  logic [7:0]             lc_ar_beats;
  // Multi-outstanding AR count (0..MaxAROut); AW still single-outstanding
  logic [AROutW-1:0] ar_inflight_q, ar_inflight_d;
  logic        aw_sent_q, aw_sent_d;
  logic        w_sent_q, w_sent_d;
  // First R of head outstanding AR uses stored lane0; later Rs beat-aligned
  logic        burst_first_q, burst_first_d;
  // Issue cursor (AR address) vs receive cursor (i_q/j_q/t_q write position)
  logic [31:0] ar_i_q, ar_t_q, ar_j_q;  // A: (ar_i,ar_t); B: (ar_t,ar_j)
  logic        ar_i_en, ar_t_en, ar_j_en;
  logic [31:0] ar_i_d, ar_t_d, ar_j_d;
  // Per-outstanding first-byte lane (in-order R, same AR id)
  logic [BeatLaneW-1:0] ar_lane_mem_q [MaxAROut];
  logic [BeatLaneW-1:0] ar_lane_push;
  logic                 ar_lane_push_en;
  logic                 ar_lane_pop_en;
  logic [BeatLaneW-1:0] ar_head_lane;
  // N>1: per-outstanding write cursor so R may complete out of order.
  typedef struct packed {
    logic                 valid;
    logic                 first;
    logic [BeatLaneW-1:0] lane0;
    logic [31:0]          row;
    logic [31:0]          col;
  } ar_slot_t;
  ar_slot_t             ar_slot_q [MaxAROut];
  logic                 ar_slot_we;
  logic [ARSlotW-1:0]   ar_slot_widx;
  logic [31:0]          ar_slot_push_row, ar_slot_push_col;
  logic                 ar_slot_r_en;
  logic                 ar_slot_r_last;
  logic [ARSlotW-1:0]   ar_slot_ridx;
  logic [31:0]          ar_slot_ntake;
  logic                 ar_hold_q;
  logic [ARSlotW-1:0]   ar_hold_slot_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_hold_q <= 1'b0;
      ar_hold_slot_q <= '0;
    end else if (state_q == ST_IDLE && start_i) begin
      ar_hold_q <= 1'b0;
      ar_hold_slot_q <= '0;
    end else if (axi_req_d.ar_valid) begin
      if (axi_resp_s.ar_ready) ar_hold_q <= 1'b0;
      else if (!ar_hold_q) begin
        ar_hold_q <= 1'b1;
        ar_hold_slot_q <= SplitArId ? ARSlotW'(axi_req_d.ar.id - ArIdBase) : '0;
      end
    end
  end

  // Multi-byte unpack count for this R cycle. AI-X9 made the two loads the same
  // shape, so lb_n_d is now the same width as la_n_d (it was [3:0], capped at 8
  // by the deleted oct-drain) and both count elements along t.
  logic [7:0]  la_n_d;
  logic [7:0]  lb_n_d;

  // C dual-store: dual-bank combo read of C[j],C[j+1] → one W/cycle (PeLanes≥2).
  // Multi-beat: AW once with len=nbeats-1; stream W; advance j on B by stc_elem.
  // PeLanes==1 falls back to pair-hold (same bank for j and j+1).
  // Trail cursor (stc_i/stc_j) is independent of MAC (i_q/j_q): store only rows
  // whose C writes have committed; i_q==m means issue, not retirement, finished.
  localparam int unsigned RowCountW = (LimM < 2) ? 1 : $clog2(64'(LimM) + 64'd1);
  logic [RowCountW-1:0] c_rows_done_q;
  // Intra-row trailing (single-row / decode jobs): the C row being computed is
  // stored pair by pair behind the MAC. `c_cols_row_q` is the row of the last C
  // write and `c_cols_done_q` the number of its columns written so far (the MAC
  // writes columns in order), so a burst may cover pairs strictly below that
  // count. Only the even-n pair path trails inside a row; odd n keeps the
  // row-complete rule (AI-X8 kept its single/pair transition out of the MAC).
  logic [RowCountW-1:0] c_cols_row_q;
  logic [31:0]          c_cols_done_q;
  logic        c_pair_hold_q, c_pair_hold_d;
  logic [31:0] c_lo_q;
  logic        c_lo_we_d;
  logic [8:0]  stc_w_left_q, stc_w_left_d;  // remaining W beats (1..256)
  logic [15:0] stc_elem_q, stc_elem_d;      // elements covered by open AW
  logic [15:0] stc_n_d;                     // elements retired on B
  logic [31:0] stc_i_q, stc_j_q;            // store cursor (row/col)
  logic        stc_i_en, stc_j_en;          // advance store cursor this cycle
  logic [31:0] stc_i_d, stc_j_d;
  localparam bit DualCRead = (PeLanes >= 2);
  // Wide C store (V1/V2): on a bus wider than 64 bits a C beat can carry
  // DataWidth/32 consecutive columns (read from as many distinct banks) instead of
  // one 8-byte pair. Taken per job when the row pitch keeps every row base beat-
  // aligned (n % StoreWordsMax == 0 and ptr_c aligned); otherwise the pair path.
  // Words per beat are a shift (wsh: 1 = pair, StoreShMax = wide), so the 64-bit
  // path is arithmetically the pre-change one.
  localparam int unsigned StoreWordsMax = (DataWidth >= 64) ? DataWidth / 32 : 2;
  localparam int unsigned StoreShMax    = $clog2(StoreWordsMax);
  localparam int unsigned StoreShW      = (StoreShMax > 1) ? $clog2(StoreShMax + 1) : 1;
  localparam bit          WideCStore    = DualCRead && (StoreWordsMax > 2) && (PeLanes >= StoreWordsMax);
  logic [StoreShW-1:0] wsh_q;      // words-per-beat shift for this job's C store
  logic                wide_c_q;   // this job's rows are beat-aligned: use the wide store

  // ---- Banked A/B tile ports ----
  logic                 a_r_req  [PeLanes];
  logic [OperandBankAddrW-1:0] a_r_addr [PeLanes];
  logic [7:0]           a_r_data [PeLanes];
  logic                 a_w_req  [PeLanes];
  logic [OperandBankAddrW-1:0] a_w_addr [PeLanes];
  logic [7:0]           a_w_data [PeLanes];

  logic                 b_r_req  [OutCols][PeLanes];
  logic [OperandBankAddrW-1:0] b_r_addr [OutCols][PeLanes];
  logic [7:0]           b_r_data [OutCols][PeLanes];
  logic                 b_w_req  [OutCols][PeLanes];
  logic [OperandBankAddrW-1:0] b_w_addr [OutCols][PeLanes];
  logic [7:0]           b_w_data [OutCols][PeLanes];
  // AI-X9: the I3 same-bank multi-write ports (w2..w8) are gone. They existed
  // only because a row-major B burst ran along j and therefore landed a whole
  // beat in ONE bank. k-major B spreads a beat across PeLanes banks at one
  // address each, so 1W is enough -- same as A.

  // C multi-bank (bank = j % PeLanes). Dual concurrent reads for pair-store:
  // j and j+1 always hit different banks when PeLanes >= 2 (live: 128).
  logic                 c_r0_req, c_r1_req, c_w_req;
  // Extra C write ports for output columns 1..OutCols-1 (column 0 uses c_w_*).
  // Consecutive columns land in distinct banks (OutCols <= PeLanes), so every
  // bank sees at most one writer per cycle.
  logic                 c_wx_req  [OutCols];
  logic [LaneW-1:0]     c_wx_bank [OutCols];
  logic [BankAddrW-1:0] c_wx_addr [OutCols];
  logic [31:0]          c_wx_data [OutCols];
  logic [LaneW-1:0]     c_r0_bank, c_r1_bank, c_w_bank;
  logic [BankAddrW-1:0] c_r0_addr, c_r1_addr, c_w_addr;
  logic [31:0]          c_r0_data, c_r1_data, c_w_data;
  logic [31:0]          c_r_data_b [PeLanes];
  // Wide-store read ports for columns 2..StoreWordsMax-1 (0 and 1 are c_r0/c_r1).
  logic                 c_rx_req  [StoreWordsMax];
  logic [LaneW-1:0]     c_rx_bank [StoreWordsMax];
  logic [BankAddrW-1:0] c_rx_addr [StoreWordsMax];
  logic [31:0]          c_rx_data [StoreWordsMax];
  logic                 c_wp_req  [PeLanes];
  logic [BankAddrW-1:0] c_wp_addr [PeLanes];
  logic [31:0]          c_wp_data [PeLanes];
  always_comb begin
    for (int unsigned p = 0; p < PeLanes; p++) begin
      c_wp_req[p]  = c_w_req && (c_w_bank == LaneW'(p));
      c_wp_addr[p] = c_w_addr;
      c_wp_data[p] = c_w_data;
      for (int unsigned g = 1; g < OutCols; g++)
        if (c_wx_req[g] && c_wx_bank[g] == LaneW'(p)) begin
          c_wp_req[p]  = 1'b1;
          c_wp_addr[p] = c_wx_addr[g];
          c_wp_data[p] = c_wx_data[g];
        end
    end
  end
  // Alias for single-element paths (single store / MAC write uses r0)
  logic                 c_r_req;
  logic [LaneW-1:0]     c_r_bank;
  logic [BankAddrW-1:0] c_r_addr;
  logic [31:0]          c_r_data;
  assign c_r_req  = c_r0_req;
  assign c_r_bank = c_r0_bank;
  assign c_r_addr = c_r0_addr;
  assign c_r_data = c_r0_data;

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_a_banks
    g6lc_ai_tile_sram #(
        .NumWords (OperandWordsA),
        .DataWidth(8),
        .NumPorts (2),
        .ImplKey  ("g6lc_ai_tile_a")
    ) i_tile_a (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (a_r_req[p]), .r_addr_i(a_r_addr[p]), .r_data_o(a_r_data[p]),
        .w_req_i (a_w_req[p]), .w_addr_i(a_w_addr[p]), .w_data_i(a_w_data[p]),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0),
        .w3_req_i(1'b0), .w3_addr_i('0), .w3_data_i('0),
        .w4_req_i(1'b0), .w4_addr_i('0), .w4_data_i('0),
        .w5_req_i(1'b0), .w5_addr_i('0), .w5_data_i('0),
        .w6_req_i(1'b0), .w6_addr_i('0), .w6_data_i('0),
        .w7_req_i(1'b0), .w7_addr_i('0), .w7_data_i('0),
        .w8_req_i(1'b0), .w8_addr_i('0), .w8_data_i('0)
    );
  end

  for (genvar g = 0; g < int'(OutCols); g++) begin : gen_b_grp
  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_b_banks
    g6lc_ai_tile_sram #(
        .NumWords (OperandWordsBGrp),
        .DataWidth(8),
        .NumPorts (2),  // AI-X9: 1R1W, same as A (was 8 for the oct drain)
        .ImplKey  ("g6lc_ai_tile_b")
    ) i_tile_b (
        .clk_i, .rst_ni, .testmode_i,
        .r_req_i (b_r_req[g][p]), .r_addr_i(b_r_addr[g][p]), .r_data_o(b_r_data[g][p]),
        .w_req_i (b_w_req[g][p]), .w_addr_i(b_w_addr[g][p]), .w_data_i(b_w_data[g][p]),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0),
        .w3_req_i(1'b0), .w3_addr_i('0), .w3_data_i('0),
        .w4_req_i(1'b0), .w4_addr_i('0), .w4_data_i('0),
        .w5_req_i(1'b0), .w5_addr_i('0), .w5_data_i('0),
        .w6_req_i(1'b0), .w6_addr_i('0), .w6_data_i('0),
        .w7_req_i(1'b0), .w7_addr_i('0), .w7_data_i('0),
        .w8_req_i(1'b0), .w8_addr_i('0), .w8_data_i('0)
    );
  end
  end

  for (genvar p = 0; p < int'(PeLanes); p++) begin : gen_c_banks
    g6lc_ai_tile_sram #(
        .NumWords (BankWords),
        .DataWidth(32),
        .NumPorts (2),
        .ImplKey  ("g6lc_ai_tile_c")
    ) i_tile_c (
        .clk_i, .rst_ni, .testmode_i,
        // Multi-read: r0/r1 (pair j, j+1) and the wide-store ports select
        // different banks (consecutive columns, StoreWordsMax <= PeLanes).
        .r_req_i (c_rp_req[p]),
        .r_addr_i(c_rp_addr[p]),
        .r_data_o(c_r_data_b[p]),
        .w_req_i (c_wp_req[p]),
        .w_addr_i(c_wp_addr[p]),
        .w_data_i(c_wp_data[p]),
        .w2_req_i(1'b0), .w2_addr_i('0), .w2_data_i('0),
        .w3_req_i(1'b0), .w3_addr_i('0), .w3_data_i('0),
        .w4_req_i(1'b0), .w4_addr_i('0), .w4_data_i('0),
        .w5_req_i(1'b0), .w5_addr_i('0), .w5_data_i('0),
        .w6_req_i(1'b0), .w6_addr_i('0), .w6_data_i('0),
        .w7_req_i(1'b0), .w7_addr_i('0), .w7_data_i('0),
        .w8_req_i(1'b0), .w8_addr_i('0), .w8_data_i('0)
    );
  end

  // Per-bank read request: r0, r1 or one of the wide ports (at most one per bank).
  logic                 c_rp_req  [PeLanes];
  logic [BankAddrW-1:0] c_rp_addr [PeLanes];
  always_comb begin
    for (int unsigned p = 0; p < PeLanes; p++) begin
      c_rp_req[p]  = (c_r0_req && (c_r0_bank == LaneW'(p))) || (c_r1_req && (c_r1_bank == LaneW'(p)));
      c_rp_addr[p] = (c_r1_req && (c_r1_bank == LaneW'(p))) ? c_r1_addr : c_r0_addr;
      for (int unsigned w = 2; w < StoreWordsMax; w++)
        if (c_rx_req[w] && c_rx_bank[w] == LaneW'(p)) begin
          c_rp_req[p]  = 1'b1;
          c_rp_addr[p] = c_rx_addr[w];
        end
    end
  end

  // Latency=0 read muxes
  always_comb begin
    c_r0_data = c_r_data_b[0];
    c_r1_data = c_r_data_b[0];
    for (int unsigned p = 1; p < PeLanes; p++) begin
      if (c_r0_bank == LaneW'(p))
        c_r0_data = c_r_data_b[p];
      if (c_r1_bank == LaneW'(p))
        c_r1_data = c_r_data_b[p];
    end
    for (int unsigned w = 0; w < StoreWordsMax; w++) begin
      c_rx_data[w] = c_r_data_b[0];
      for (int unsigned p = 1; p < PeLanes; p++)
        if (c_rx_bank[w] == LaneW'(p)) c_rx_data[w] = c_r_data_b[p];
    end
    c_rx_data[0] = c_r0_data;
    if (StoreWordsMax > 1) c_rx_data[1] = c_r1_data;
  end


  // PE: multi-lane MAC (driven only in ST_MAC)
  logic signed [7:0] pe_a [PeLanes];
  logic signed [7:0] pe_b [OutCols][PeLanes];
  logic        [31:0] pe_a_float [PeLanes];
  logic        [31:0] pe_b_float [OutCols][PeLanes];
  logic              pe_v [PeLanes];
  logic       [31:0] pe_sum [OutCols];
  logic       [31:0] pe_sum_int [OutCols];
  logic       [31:0] pe_sum_float [OutCols];
  // Column g of the current group is a real output column (masked past n; a
  // single column in accumulate mode).
  logic              col_v [OutCols];
  logic [31:0]       cols_eff;
  assign cols_eff = acc_mode_q ? 32'd1 : 32'(OutCols);
  // B column group feeding dot g: col_grp(j_q + g). With the OutCols stride this
  // is g itself; accumulate mode advances one column at a time, so dot 0 must
  // follow the column's own group.
  logic [ColW-1:0]   grp_of [OutCols];
  always_comb for (int unsigned g = 0; g < OutCols; g++) grp_of[g] = col_grp(j_q + 32'(g));
  // Registers only (j_q, n_q, acc_mode_q): its own process so no read-data path
  // feeds back into the bank-request process through it.
  always_comb for (int unsigned g = 0; g < OutCols; g++)
    col_v[g] = (32'(g) < cols_eff) && (j_q + 32'(g) < n_q);

  for (genvar g = 0; g < int'(OutCols); g++) begin : gen_pe_cols
    // Integer/INT4 path
    g6lc_ai_pe_dot #(.Lanes(PeLanes)) i_pe_int (
        .a_i     (pe_a),
        .b_i     (pe_b[g]),
        .valid_i (pe_v),
        .numfmt_i(numfmt_q),
        .sum_o   (pe_sum_int[g])
    );

    // Floating path (FP8/FP16/BF16/FP32) — combinational baseline
    g6lc_ai_pe_dot_float #(.Lanes(PeLanes)) i_pe_float (
        .a_i     (pe_a_float),
        .b_i     (pe_b_float[g]),
        .valid_i (pe_v),
        .numfmt_i(numfmt_q),
        .sum_o   (pe_sum_float[g]),
        .flags_o ()
    );
  end

  // Pipelined floating dot-product handshake
  // dot_start is asserted with each MAC issue; dot_sum/dot_first/... are valid
  // DOT_LATENCY-1 cycles later, matching dot_valid_o.  DOT_LATENCY is the
  // dot product's registered Latency plus the one-cycle output register.
  localparam int unsigned DOT_LATENCY = DotPipeFloat ?
      ($clog2(PeLanes < 1 ? 1 : PeLanes) + 5) : 1;

  logic dot_start;
  logic dot_valid;
  logic [31:0] dot_sum [OutCols];
  logic        dot_cv_out [OutCols];
  logic dot_first_out, dot_last_out;
  logic [31:0] dot_i_out, dot_j_out;
  logic dot_first_issue, dot_last_issue;
  logic [31:0] dot_i_issue, dot_j_issue;
  // F0b-2: outstanding dot-product transactions so the MAC does not exit before
  // all pipelined results have returned and their C writes have been issued.
  logic [$clog2(PeLanes)+4:0] dot_pending_q;

  generate
    if (DotPipeFloat) begin : gen_dot_pipe
      logic dot_valid_col [OutCols];
      for (genvar g = 0; g < int'(OutCols); g++) begin : gen_dot_pipe_cols
        g6lc_ai_pe_dot_float_pipe #(.Lanes(PeLanes)) i_pe_float_pipe (
            .clk_i    (clk_i),
            .rst_ni   (rst_ni),
            .start_i  (dot_start),
            .a_i      (pe_a_float),
            .b_i      (pe_b_float[g]),
            .valid_i  (pe_v),
            .numfmt_i (numfmt_q),
            .sum_o    (dot_sum[g]),
            .flags_o  (),
            .valid_o  (dot_valid_col[g])
        );
      end
      // All column pipes share start and latency; column 0 is the handshake.
      assign dot_valid = dot_valid_col[0];

      logic [DOT_LATENCY-1:0] dot_first_pipe, dot_last_pipe;
      logic [DOT_LATENCY-1:0][31:0] dot_i_pipe, dot_j_pipe;
      logic [DOT_LATENCY-1:0][OutCols-1:0] dot_cv_pipe;
      logic [OutCols-1:0] col_v_vec;
      always_comb for (int unsigned g = 0; g < OutCols; g++) col_v_vec[g] = col_v[g];

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          dot_first_pipe <= '0;
          dot_last_pipe  <= '0;
          dot_i_pipe     <= '0;
          dot_j_pipe     <= '0;
          dot_cv_pipe    <= '0;
        end else begin
          dot_first_pipe <= {dot_first_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_first_issue : 1'b0};
          dot_last_pipe  <= {dot_last_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_last_issue : 1'b0};
          dot_i_pipe     <= {dot_i_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_i_issue : 32'd0};
          dot_j_pipe     <= {dot_j_pipe[DOT_LATENCY-2:0],
                             dot_start ? dot_j_issue : 32'd0};
          dot_cv_pipe    <= {dot_cv_pipe[DOT_LATENCY-2:0],
                             dot_start ? col_v_vec : {OutCols{1'b0}}};
        end
      end

      assign dot_first_out = dot_first_pipe[DOT_LATENCY-1];
      assign dot_last_out  = dot_last_pipe[DOT_LATENCY-1];
      assign dot_i_out     = dot_i_pipe[DOT_LATENCY-1];
      assign dot_j_out     = dot_j_pipe[DOT_LATENCY-1];
      always_comb for (int unsigned g = 0; g < OutCols; g++) dot_cv_out[g] = dot_cv_pipe[DOT_LATENCY-1][g];
    end else begin : gen_dot_float_comb
      assign dot_valid     = 1'b0;
      always_comb for (int unsigned g = 0; g < OutCols; g++) begin dot_sum[g] = '0; dot_cv_out[g] = 1'b0; end
      assign dot_first_out = 1'b0;
      assign dot_last_out  = 1'b0;
      assign dot_i_out     = '0;
      assign dot_j_out     = '0;
    end
  endgenerate

  // Format selection: integer/INT4 vs floating.
  // numfmt_q is constant for a tile, so the mux is a per-job static select.
  localparam logic [2:0] AI_FMT_INT  = 3'd0;
  localparam logic [2:0] AI_FMT_INT4 = 3'd1;
  logic pe_float_en;
  // Only dispatch to the float dot for implemented FP families
  // (FP8 E4M3/E5M2, FP16, BF16, FP32).  SP24 and reserved codes stay on the
  // integer path where the sequencer's numfmt check / descriptor grant will
  // reject them before the MAC.
  // Static per job (numfmt_q is latched at start), so this is a configuration
  // select rather than a per-cycle mux in the MAC's critical path.
  assign pe_float_en = (numfmt_q inside {3'd3, 3'd4, 3'd5, 3'd6, 3'd7});
  always_comb for (int unsigned g = 0; g < OutCols; g++)
    pe_sum[g] = pe_float_en ? pe_sum_float[g] : pe_sum_int[g];

  // ---------------------------------------------------------------------------
  // F1-F5 format scaling: bytes per element for the live numerical formats.
  // INT4 packs two elements per byte; all other live formats use the natural
  // byte width. This is a local copy so g6lc_ai_gemm_seq stays unit-testable
  // without pulling config_pkg into every backend runner.
  function automatic logic [31:0] ai_fmt_bytes();
    return g6lc_ai_island_cfg_pkg::ai_elem_bytes(numfmt_q);
  endfunction
  // Element size as a shift (0/1/2): byte<->element scaling in the datapath is a
  // shift, never a multiply or divide by the runtime element size.
  function automatic logic [1:0] ai_fmt_shift();
    return g6lc_ai_island_cfg_pkg::ai_elem_shift(numfmt_q);
  endfunction

  // F1: number of elements issued per MAC cycle (PeLanes byte lanes / element bytes).
  assign mac_step = (numfmt_q == 3'd1) ? 32'(2 * PeLanes)
                                       : (32'(PeLanes) >> ai_fmt_shift());

  // F1: bytes in one operand row (k elements). This is the bound the LOAD states
  // run to; ST_MAC still bounds against k_q in elements. For INT8 the two are
  // equal, which is why the INT8 path is bit-identical.
  assign k_bytes = fmt_row_bytes(k_q);

  // Row pitch of the operand banks for this job (see the flat-panel note above).
  // The arithmetic is g6lc_ai_island_cfg_pkg's flat-panel functions, proven bounded
  // in corev_apu/ai_island/formal/g6lc_ai_gemm_flat_props.sv.
  logic [PitchShW-1:0] pitch_sh_c, pitch_sh_q;
  logic                cap_ok_c;
  assign pitch_sh_c  = PitchShW'(g6lc_ai_island_cfg_pkg::ai_flat_pitch_shift(k_bytes, LaneShift));
  // Byte-capacity box: both operand panels must fit their banks at this pitch,
  // and k must fit the 16-bit lda/ldb it is compared against.
  // B rows are spread over OutCols groups of OperandWordsBGrp words each.
  logic [31:0] n_grp_c;
  assign n_grp_c = (n_q + 32'(OutCols) - 32'd1) >> ColShift;
  assign cap_ok_c = k_q <= 32'h0000_FFFF &&
                    g6lc_ai_island_cfg_pkg::ai_flat_fits(n_grp_c, pitch_sh_c, OperandWordsBGrp) &&
                    g6lc_ai_island_cfg_pkg::ai_flat_fits(m_q, pitch_sh_c, OperandWordsA);

  // F0b-2: the accumulator is now fed from the PIPELINE register, so
  // `mac_acc_next` is a function of state (sum_q, acc_q) rather than of the
  // live combinational tree output. The cycle-accurate expression:
  //   sum_q   is pe_sum from one cycle ago
  //   first_q is (t_q == 0) from one cycle ago, i.e. a new element
  //   acc_q   is the running sum after the previous drain
  //   acc_d   = (first_q ? '0 : acc_q) + sum_q
  //
  // This is the structural pipeline. Timing closure (depth, retiming,
  // placement) is sv-timing's job later; this is just the state-machine split.
  //
  // Bit-identical to the previous pe_acc_out only if the pipeline is empty at
  // the start and the FSM drains before changing state.
  // purpose is structural: `acc_q <= acc_q + tree` is a recurrence, so a
  // pipeline register cannot be placed on `acc_o` without feeding a stale
  // `acc_i` back into the next step and silently dropping terms. Splitting the
  // reduction (a pure function) from the accumulator (state) puts the register
  // site inside this module, where the sequencer can also delay the matching
  // C-write address and the element's first/last flags.
  //
  // F0b-2 replaces this with:
  //   sum_q <= pe_sum;  acc_d = (first_q ? '0 : acc_q) + sum_q;
  // plus delayed i/j for the C write and a one-cycle drain before leaving
  // ST_MAC. Landing that needs its own verification pass: the C-write port is
  // shared with the trail-store path in ST_MAC, so moving the MAC write one
  // cycle later changes that arbitration.
  logic [31:0] mac_acc_next [OutCols];
  logic [36:0] mac_fp32_add [OutCols];
  // Float tiles accumulate with RNE FP32 addition; integer tiles with i32 add.
  // Timing note: fp32_add is a combinational decode/align/add/normalise block.
  // Together with the multi-byte gather mux it lengthens the MAC combinational
  // path vs the integer path. A future pass should either retime it around the
  // existing one-cycle pe_sum -> acc_q pipeline or pipeline fp32_add itself;
  // this is not a throughput change and does not affect the load/store FSM.
  // Accumulate mode: the first partial of an element is added onto the C word
  // that ST_LC placed in the tile (read on port r0 in the drain cycle) instead of
  // starting from zero, so a K-split chained through C is one ordered reduction.
  logic [31:0] mac_seed;
  logic [36:0] mac_fp32_seed_add;
  // The seed (accumulate mode) belongs to column 0: accumulate jobs run one
  // column at a time, so no other column ever needs it.
  assign mac_seed          = acc_mode_q ? c_r0_data : 32'd0;
  assign mac_fp32_seed_add = g6lc_ai_fp_pkg::fp32_add(mac_seed, sum_q[0]);
  always_comb begin
    for (int unsigned g = 0; g < OutCols; g++) begin
      mac_fp32_add[g] = g6lc_ai_fp_pkg::fp32_add(acc_q[g], sum_q[g]);
      mac_acc_next[g] = pe_float_en
          ? (sum_first_q ? ((acc_mode_q && g == 0) ? mac_fp32_seed_add[31:0] : sum_q[g]) : mac_fp32_add[g][31:0])
          : ((sum_first_q ? ((g == 0) ? mac_seed : 32'd0) : acc_q[g]) + sum_q[g]);
    end
  end

  logic reuse_b_skip_q, reuse_b_safe;
  // Row base of the B panel in the operand bank: 0, or the slot's half when the
  // resident-B directory placed this job's panel in a slot (see gen_reuse_b).
  logic [OperandBankAddrW-1:0] b_base_q;
  if (ReuseBEn) begin : gen_reuse_b
    localparam int unsigned SlotsB     = (ReuseBSlots < 1) ? 1 : ReuseBSlots;
    // Slot words are group-local (each column group holds 1/OutCols of a panel).
    localparam int unsigned SlotWordsB = OperandWordsBGrp / SlotsB;
    localparam int unsigned SlotW      = (SlotsB > 1) ? $clog2(SlotsB) : 1;
    logic [SlotsB-1:0] valid_q, big_q, hit_vec;
    logic cacheable_q, invalidated_q, hit_any;
    logic [AddrWidth-1:0] ptr_q [SlotsB];
    logic [DimW-1:0] n_saved_q [SlotsB];
    logic [15:0]     k_saved_q [SlotsB];
    logic [15:0]     ldb_saved_q [SlotsB];
    logic [2:0]      fmt_q [SlotsB];
    logic [31:0]     epoch_q [SlotsB];
    logic [SlotW-1:0] cur_q, victim_q, hit_idx;
    logic [31:0] job_epoch_q;
    logic [31:0] b_span, c_span;
    logic [AddrWidth:0] b_end, c_end;
    logic geometry_ok, disjoint, response_error, small_c;

    // The incoming job's key against every slot; the first hit wins (keys are
    // unique per slot because a slot is invalidated before it is refilled).
    always_comb begin
      hit_idx = '0;
      for (int unsigned s = 0; s < SlotsB; s++)
        hit_vec[s] = valid_q[s] && ptr_q[s] == ptr_b_i &&
                     32'(n_saved_q[s]) == n_i && 32'(k_saved_q[s]) == k_i &&
                     ldb_saved_q[s] == ldb_i && fmt_q[s] == numfmt_i &&
                     epoch_q[s] == reuse_b_epoch_i;
      for (int s = SlotsB - 1; s >= 0; s--)
        if (hit_vec[s]) hit_idx = SlotW'(s);
    end
    assign hit_any = |hit_vec;
    // Fits one slot at this job's pitch; otherwise the panel takes the whole bank.
    assign small_c = SlotsB > 1 && g6lc_ai_island_cfg_pkg::ai_slot_small(n_grp_c, pitch_sh_c, SlotWordsB);

    assign b_span = 32'(n_q - 32'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes;
    assign c_span = ((32'(m_q) - 32'd1) * ldc_eff + 32'(n_q)) << 2;
    assign b_end = {1'b0, pb_q} + (AddrWidth+1)'(b_span);
    assign c_end = {1'b0, pc_q} + (AddrWidth+1)'(c_span);
    assign geometry_ok = m_q > 0 && m_q <= LimM && n_q > 0 && n_q <= LimN &&
                         k_q > 0 && cap_ok_c && ldb_q >= k_q[15:0] &&
                         numfmt_q inside {3'd0, 3'd1, 3'd3, 3'd4, 3'd5, 3'd6, 3'd7};
    assign disjoint = !b_end[AddrWidth] && !c_end[AddrWidth] &&
                      ({1'b0, pc_q} >= b_end || {1'b0, pb_q} >= c_end);
    // Combinational, not `cacheable_q`: the skip is now decided in ST_CHK too
    // (when A is also resident) and `cacheable_q` is still clear at that point.
    // The job's shape and pointers are latched at start and do not move, so this
    // is the same value `cacheable_q` carries from ST_CHK onward.
    assign reuse_b_safe = geometry_ok && disjoint && !invalidated_q;
    assign response_error = (axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1]) ||
                            (axi_resp_s.b_valid && axi_req_d.b_ready && axi_resp_s.b.resp[1]);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_q <= '0;
        big_q <= '0;
        cacheable_q <= 1'b0;
        invalidated_q <= 1'b0;
        for (int unsigned s = 0; s < SlotsB; s++) begin
          ptr_q[s] <= '0;
          n_saved_q[s] <= '0;
          k_saved_q[s] <= '0;
          ldb_saved_q[s] <= '0;
          fmt_q[s] <= '0;
          epoch_q[s] <= '0;
        end
        cur_q <= '0;
        victim_q <= '0;
        b_base_q <= '0;
        job_epoch_q <= '0;
        reuse_b_skip_q <= 1'b0;
        pmu_reuse_b_hit_o <= 1'b0;
      end else begin
        if (state_q == ST_IDLE && start_i) begin
          job_epoch_q <= reuse_b_epoch_i;
          reuse_b_skip_q <= reuse_b_i && hit_any;
          // The job owns the slot it hit, else the round-robin victim; that slot's
          // key is dropped now (its rows are rewritten unless the skip is taken)
          // and re-established at ST_DONE with this job's key.
          cur_q <= hit_any ? hit_idx : victim_q;
          valid_q[hit_any ? hit_idx : victim_q] <= 1'b0;
          cacheable_q <= 1'b0;
          invalidated_q <= 1'b0;
          pmu_reuse_b_hit_o <= 1'b0;
        end
        if (state_q == ST_CHK) begin
          cacheable_q <= geometry_ok && disjoint;
          // Placement: a panel that fits a slot lives at the slot's half; a bigger
          // one takes the whole bank and evicts every other slot. A small panel
          // landing next to a "big" resident also evicts it (they overlap).
          if (small_c) begin
            b_base_q <= OperandBankAddrW'(g6lc_ai_island_cfg_pkg::ai_slot_base(cur_q, SlotWordsB));
            big_q[cur_q] <= 1'b0;
            for (int unsigned s = 0; s < SlotsB; s++)
              if (SlotW'(s) != cur_q && big_q[s]) valid_q[s] <= 1'b0;
          end else begin
            b_base_q <= '0;
            big_q[cur_q] <= 1'b1;
            for (int unsigned s = 0; s < SlotsB; s++)
              if (SlotW'(s) != cur_q) valid_q[s] <= 1'b0;
          end
        end
        // ST_LA -> ST_MAC is a B skip with A loaded; ST_CHK -> ST_MAC is a B
        // skip with A resident too.  Both must report, or the counter would
        // under-report exactly when the engine saved the most traffic.
        if ((state_q == ST_LA || state_q == ST_CHK) && state_d == ST_MAC)
          pmu_reuse_b_hit_o <= 1'b1;
        if (state_q == ST_DONE) begin
          valid_q[cur_q] <= cacheable_q && !invalidated_q && !err_q;
          ptr_q[cur_q] <= pb_q;
          n_saved_q[cur_q] <= n_q[DimW-1:0];
          k_saved_q[cur_q] <= k_q[15:0];
          ldb_saved_q[cur_q] <= ldb_q;
          fmt_q[cur_q] <= numfmt_q;
          epoch_q[cur_q] <= job_epoch_q;
          // Round robin after use: with two slots this is exactly LRU.
          victim_q <= (32'(cur_q) + 1 >= SlotsB) ? '0 : cur_q + SlotW'(1);
        end
        if (reuse_b_invalidate_i || response_error) begin
          valid_q <= '0;
          reuse_b_skip_q <= 1'b0;
          invalidated_q <= 1'b1;
        end
      end
    end
  end else begin : gen_no_reuse_b
    assign reuse_b_skip_q = 1'b0;
    assign reuse_b_safe = 1'b0;
    assign pmu_reuse_b_hit_o = 1'b0;
    assign b_base_q = '0;
  end

  // Resident A, the mirror of the B path above and the same recipe 16.  B
  // residency serves one weight tile against many activations; A residency
  // serves one activation tile against many weight tiles, which is the other
  // half of the workload and costs the same key registers.  N is deliberately
  // absent from the A key exactly as M is absent from the B key: neither
  // dimension addresses the tile it is excluded from.
  logic reuse_a_skip_q, reuse_a_safe;
  if (ReuseAEn) begin : gen_reuse_a
    logic valid_q, cacheable_q, invalidated_q;
    logic [AddrWidth-1:0] ptr_q;
    logic [DimW-1:0] m_saved_q;
    logic [15:0]     k_saved_q;
    logic [15:0] lda_saved_q;
    logic [2:0] fmt_q;
    logic [31:0] epoch_q, job_epoch_q;
    logic [31:0] a_span, c_span;
    logic [AddrWidth:0] a_end, c_end;
    logic geometry_ok, disjoint, response_error;

    assign a_span = 32'(m_q - 32'd1) * fmt_row_bytes({16'd0, lda_q}) + k_bytes;
    assign c_span = ((32'(m_q) - 32'd1) * ldc_eff + 32'(n_q)) << 2;
    assign a_end = {1'b0, pa_q} + (AddrWidth+1)'(a_span);
    assign c_end = {1'b0, pc_q} + (AddrWidth+1)'(c_span);
    assign geometry_ok = m_q > 0 && m_q <= LimM && n_q > 0 && n_q <= LimN &&
                         k_q > 0 && cap_ok_c && lda_q >= k_q[15:0] &&
                         numfmt_q inside {3'd0, 3'd1, 3'd3, 3'd4, 3'd5, 3'd6, 3'd7};
    assign disjoint = !a_end[AddrWidth] && !c_end[AddrWidth] &&
                      ({1'b0, pc_q} >= a_end || {1'b0, pa_q} >= c_end);
    // Combinational for the same reason as the B side, and here it is load
    // bearing: A's skip is decided in ST_CHK, where `cacheable_q` has just been
    // cleared by the start handshake, so keying off it would make the skip dead
    // code while the PMU still claimed a hit.
    assign reuse_a_safe = geometry_ok && disjoint && !invalidated_q;
    assign response_error = (axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1]) ||
                            (axi_resp_s.b_valid && axi_req_d.b_ready && axi_resp_s.b.resp[1]);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_q <= 1'b0;
        cacheable_q <= 1'b0;
        invalidated_q <= 1'b0;
        ptr_q <= '0;
        m_saved_q <= '0;
        k_saved_q <= '0;
        lda_saved_q <= '0;
        fmt_q <= '0;
        epoch_q <= '0;
        job_epoch_q <= '0;
        reuse_a_skip_q <= 1'b0;
        pmu_reuse_a_hit_o <= 1'b0;
      end else begin
        if (state_q == ST_IDLE && start_i) begin
          job_epoch_q <= reuse_a_epoch_i;
          reuse_a_skip_q <= reuse_a_i && valid_q && ptr_q == ptr_a_i &&
                            32'(m_saved_q) == m_i && 32'(k_saved_q) == k_i &&
                            lda_saved_q == lda_i && fmt_q == numfmt_i && epoch_q == reuse_a_epoch_i;
          valid_q <= 1'b0;
          cacheable_q <= 1'b0;
          invalidated_q <= 1'b0;
          pmu_reuse_a_hit_o <= 1'b0;
        end
        if (state_q == ST_CHK) begin
          cacheable_q <= geometry_ok && disjoint;
          // Exactly the FSM's skip condition, so the flag cannot disagree.
          if (reuse_a_skip_q && reuse_a_safe && !reuse_a_invalidate_i)
            pmu_reuse_a_hit_o <= 1'b1;
        end
        if (state_q == ST_DONE) begin
          valid_q <= cacheable_q && !invalidated_q && !err_q;
          ptr_q <= pa_q;
          m_saved_q <= m_q[DimW-1:0];
          k_saved_q <= k_q[15:0];
          lda_saved_q <= lda_q;
          fmt_q <= numfmt_q;
          epoch_q <= job_epoch_q;
        end
        if (reuse_a_invalidate_i || response_error) begin
          valid_q <= 1'b0;
          reuse_a_skip_q <= 1'b0;
          invalidated_q <= 1'b1;
          pmu_reuse_a_hit_o <= 1'b0;
        end
      end
    end
  end else begin : gen_no_reuse_a
    assign reuse_a_skip_q = 1'b0;
    assign reuse_a_safe = 1'b0;
    assign pmu_reuse_a_hit_o = 1'b0;
  end

  // I3 PMU accumulators (active while not IDLE/DONE)
  logic [31:0] pmu_r_q, pmu_w_q, pmu_cy_q;

  assign ready_o       = (state_q == ST_IDLE);
  assign done_o        = done_q;
  assign err_o         = err_q;
  assign pmu_r_beats_o = pmu_r_q;
  assign pmu_w_beats_o = pmu_w_q;
  assign pmu_cycles_o  = pmu_cy_q;

  logic [3:0][31:0] pmu_phase_q;
  logic [2:0][31:0] pmu_stall_q;
  assign pmu_phase_o = pmu_phase_q;
  assign pmu_stall_o = pmu_stall_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pmu_phase_q <= '0;
      pmu_stall_q <= '0;
    end else if (state_q == ST_IDLE && start_i) begin
      pmu_phase_q <= '0;
      pmu_stall_q <= '0;
    end else begin
      // ST_LC (accumulate seed load) is a load phase too; it is billed to the A bucket
      // so the four published words stay {STC, MAC, LB, LA} without a fifth register.
      if (state_q == ST_LA || state_q == ST_LC) pmu_phase_q[0] <= pmu_phase_q[0] + 32'd1;
      if (state_q == ST_LB)  pmu_phase_q[1] <= pmu_phase_q[1] + 32'd1;
      if (state_q == ST_MAC) pmu_phase_q[2] <= pmu_phase_q[2] + 32'd1;
      if (state_q == ST_STC) pmu_phase_q[3] <= pmu_phase_q[3] + 32'd1;
      if (axi_req_d.ar_valid && !axi_resp_s.ar_ready) pmu_stall_q[0] <= pmu_stall_q[0] + 32'd1;
      if (axi_resp_s.r_valid && !axi_req_d.r_ready)   pmu_stall_q[1] <= pmu_stall_q[1] + 32'd1;
      if (axi_req_d.w_valid && !axi_resp_s.w_ready)   pmu_stall_q[2] <= pmu_stall_q[2] + 32'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // F1 format scaling. TWO cursor conventions, deliberately:
  //
  //   * the LOAD states (ST_LA/ST_LB) count t in **BYTES** along the row;
  //   * ST_MAC counts t in **ELEMENTS**, because only elements bound against k
  //     and only elements decide nibble validity on an odd-k tail.
  //
  // `t_q` is reset at every state transition, so the two meanings never overlap
  // -- the same reuse `i_q`/`j_q` already rely on. Making the load count bytes
  // is what makes the ENTIRE load path format-agnostic: the tile stores bytes
  // keyed by byte position (bank = byte % PeLanes, addr = row*KPerBank +
  // byte/PeLanes), which is exactly what the MAC reads back. So a format only
  // has to say how many bytes a row of k elements occupies, and neither loader
  // needs a per-format branch. FP8 reuses this unchanged; BF16/FP16/FP32 will
  // need only their MAC-side gather, not a new loader.
  function automatic logic [31:0] fmt_row_bytes(
      input logic [31:0] elems
  );
    // INT4 packs two elements per byte; ceil so an odd count keeps its last
    // element. FP8/INT8 are one byte. FP16/BF16 are two bytes. FP32 is four.
    return g6lc_ai_island_cfg_pkg::ai_row_bytes(numfmt_q, elems);
  endfunction

  function automatic logic [31:0] fmt_ld_to_stride(
      input logic [15:0] ld
  );
    return fmt_row_bytes(32'(ld));
  endfunction

  // `t` is a BYTE offset within the row (load-state convention above), so no
  // conversion happens here -- the caller already scaled it.
  function automatic logic [AddrWidth-1:0] a_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] i, t,
      input logic [15:0] lda
  );
    return base + AddrWidth'((i * fmt_ld_to_stride(lda) + t));
  endfunction

  // AI-X9: B is k-major. `ldb` strides j; elements run contiguously along t,
  // exactly like A. So this is a_addr with the row index swapped, which is what
  // lets one traversal and one format-scaling rule serve both operands, and what
  // makes sub-byte packing expressible (two INT4 elements in a byte are
  // consecutive t and therefore feed the same C[i,j]).
  function automatic logic [AddrWidth-1:0] b_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] t, j,
      input logic [15:0] ldb
  );
    return base + AddrWidth'((j * fmt_ld_to_stride(ldb) + t));
  endfunction

  function automatic logic [AddrWidth-1:0] c_addr(
      input logic [AddrWidth-1:0] base,
      input logic [31:0] i, j, n
  );
    return base + AddrWidth'(((i * n + j) << 2));
  endfunction

  function automatic logic signed [7:0] byte_from_beat(
      input logic [DataWidth-1:0] data,
      input logic [BeatLaneW-1:0] lane
  );
    return data[8*lane +: 8];
  endfunction

  // Align AR address to beat boundary
  function automatic logic [AddrWidth-1:0] beat_align(input logic [AddrWidth-1:0] a);
    return {a[AddrWidth-1:BeatAlignW], BeatAlignW'(0)};
  endfunction

  // Beats needed to transfer `rem` elements starting at byte offset `lane0`
  // (row-contiguous). Caps at MaxBurstBeats. Assumes PeLanes >= BytesPerBeat
  // so each full beat is absorbed in one cycle for A; B oct-drain does the same
  // at DataWidth=64 (up to 8 B/cycle).
  function automatic logic [7:0] beats_for_rem(
      input logic [31:0] rem,
      input logic [BeatLaneW-1:0] lane0
  );
    // Elements absorbed per beat is min(BytesPerBeat, PeLanes), both powers of
    // two, so the ceiling division is a constant shift (no divider cell).
    return 8'(g6lc_ai_island_cfg_pkg::ai_beats_for_rem(rem, 32'(lane0), BytesPerBeat,
                                                       ElemsPerBeatShift, MaxBurstBeats));
  endfunction

  // N=1: identity (return nb). N>1: do not cross DramChanShift stripe.
  function automatic logic [7:0] cap_beats_to_stripe(
      input logic [AddrWidth-1:0] addr,
      input logic [7:0] nb
  );
    automatic int unsigned maxb;
    maxb = g6lc_ai_island_cfg_pkg::dram_beats_in_stripe(
        NrChannels, ChanShift, BytesPerBeat, 64'(addr));
    if (32'(nb) > maxb) return maxb[7:0];
    return nb;
  endfunction

  function automatic logic [31:0] cap_nbeats_to_stripe(
      input logic [AddrWidth-1:0] addr,
      input logic [31:0] nbeats
  );
    automatic int unsigned maxb;
    maxb = g6lc_ai_island_cfg_pkg::dram_beats_in_stripe(
        NrChannels, ChanShift, BytesPerBeat, 64'(addr));
    if (nbeats > maxb) return 32'(maxb);
    return nbeats;
  endfunction

  // C beats are 8 bytes (aw.size=3), not the A/B beat. At DataWidth=64 the
  // two widths match, so the stripe cap is the same number as cap_nbeats.
  function automatic logic [31:0] cap_c_nbeats(
      input logic [AddrWidth-1:0] addr,
      input logic [31:0] nbeats
  );
    automatic int unsigned maxb;
    maxb = g6lc_ai_island_cfg_pkg::dram_beats_in_stripe(
        NrChannels, ChanShift, 8, 64'(addr));
    if (nbeats > maxb) return 32'(maxb);
    return nbeats;
  endfunction

  typedef struct packed {
    logic [DataWidth-1:0]   data;
    logic [DataWidth/8-1:0] strb;
  } wbeat_t;

  // Put `nbytes` (4 or 8) of `payload` on the byte lane `addr` selects.
  // DataWidth=64 and an 8-byte-aligned pair lands in [63:0] with strobe 8'hFF.
  function automatic wbeat_t wbeat_at(
      input logic [63:0] payload,
      input int unsigned nbytes,
      input logic [31:0] addr
  );
    automatic wbeat_t b;
    automatic int unsigned lane, i, at;
    b.data = '0;
    b.strb = '0;
    lane = unsigned'(addr) & (BytesPerBeat - 1);
    for (i = 0; i < 8; i++) begin
      at = lane + i;
      if (i < nbytes && at < BytesPerBeat) begin
        b.data[8*at +: 8] = payload[8*i +: 8];
        b.strb[at]        = 1'b1;
      end
    end
    return b;
  endfunction

  // One C beat: the `nwords` (a power of two, 2 or StoreWordsMax) consecutive
  // 32-bit words placed at the byte lane the address selects (0 when aligned).
  function automatic wbeat_t wbeat_words(
      input logic [31:0] addr,
      input int unsigned nwords
  );
    automatic wbeat_t bt;
    automatic int unsigned lane, w, at;
    bt.data = '0;
    bt.strb = '0;
    lane = unsigned'(addr) & (BytesPerBeat - 1);
    for (w = 0; w < StoreWordsMax; w++) begin
      at = lane + 4 * w;
      if (w < nwords && at + 3 < BytesPerBeat) begin
        bt.data[8*at +: 32] = c_rx_data[w];
        bt.strb[at +: 4]    = 4'hF;
      end
    end
    return bt;
  endfunction

  // Elements covered by `nb` beats starting at byte lane `lane0`, cap `rem`
  function automatic logic [31:0] elems_for_burst(
      input logic [31:0] rem,
      input logic [BeatLaneW-1:0] lane0,
      input logic [7:0] nb
  );
    automatic logic [31:0] first, cap, nbb;
    if (rem == 0) return 32'd0;
    first = 32'(BytesPerBeat) - 32'(lane0);
    if (first > rem) first = rem;
    nbb = 32'(nb);
    if (nbb <= 32'd1) return first;
    cap = first + (nbb - 32'd1) * 32'(BytesPerBeat);
    if (cap > rem) cap = rem;
    return cap;
  endfunction

  // Bank map: bank = t % PeLanes (or t for A / B along reduction);
  // local index = i * KPerBank + t / PeLanes  (A); for B: j * KPerBank + t / PeLanes
  // PeLanes is a power of two (asserted): bank select is a mask, row index a shift,
  // so no $div/$mod cell survives synthesis on the bank address paths.
  function automatic logic [LaneW-1:0] t_bank(input logic [31:0] t);
    return LaneW'(t & 32'(PeLanes - 1));
  endfunction

  // Flat panel: row i of A (row j of B) starts at i << pitch_sh_q bank words;
  // `t` is the byte offset in the row, PeLanes bytes per word.
  function automatic logic [OperandBankAddrW-1:0] a_bank_addr(
      input logic [31:0] i, t
  );
    return OperandBankAddrW'(g6lc_ai_island_cfg_pkg::ai_flat_row_word(i, pitch_sh_q, t, LaneShift));
  endfunction

  // Column group of B row j and its row index inside the group.
  function automatic logic [ColW-1:0] col_grp(input logic [31:0] j);
    return ColW'(j & 32'(OutCols - 1));
  endfunction
  function automatic logic [OperandBankAddrW-1:0] b_bank_addr(
      input logic [31:0] t, j
  );
    return OperandBankAddrW'(g6lc_ai_island_cfg_pkg::ai_flat_row_word(j >> ColShift, pitch_sh_q, t, LaneShift)) + b_base_q;
  endfunction

  // C bank map: bank = j % PeLanes; local = i * KPerBank + j / PeLanes
  function automatic logic [LaneW-1:0] c_bank(input logic [31:0] j);
    return LaneW'(j & 32'(PeLanes - 1));
  endfunction

  function automatic logic [BankAddrW-1:0] c_bank_addr(
      input logic [31:0] i, j
  );
    return BankAddrW'(int'(i) * KPerBank + int'(j >> LaneShift));
  endfunction

  logic [AddrWidth-1:0] a_cur, b_cur, a_ar_cur, b_ar_cur, c_store_addr;
  // The trail store may run: the cursor row is complete, or (even n) it is the
  // row under computation and at least one whole pair beyond the cursor is written.
  // A burst inside the row waits for TrailMinPairs written pairs, and rows shorter
  // than TrailMinCols are stored only once complete: on a 16-column row the split
  // into two AWs cost 2-5 cycles on the 8-lane bench, while a 512-column decode row
  // hides its whole ~n/2-beat store tail behind the MAC (778 -> ~530 cycles).
  localparam int unsigned TrailMinPairs = 4;
  localparam int unsigned TrailMinCols  = 32;
  logic trail_ready;
  assign trail_ready = stc_i_q < 32'(c_rows_done_q) ||
                       (!n_q[0] && n_q >= 32'(TrailMinCols) &&
                        32'(c_cols_row_q) == stc_i_q &&
                        c_cols_done_q >= stc_j_q + 32'(2 * TrailMinPairs));
  // Receive cursors (tile write / MAC)
  assign a_cur        = a_addr(pa_q, i_q, t_q, lda_q);
  assign b_cur        = b_addr(pb_q, t_q, j_q, ldb_q);
  // Issue cursors (AR address may run ahead of receive)
  assign a_ar_cur     = a_addr(pa_q, ar_i_q, ar_t_q, lda_q);
  assign b_ar_cur     = b_addr(pb_q, ar_t_q, ar_j_q, ldb_q);
  // Store address uses trail cursor (not MAC i/j)
  assign c_store_addr = c_addr(pc_q, stc_i_q, stc_j_q, ldc_eff);
  assign ar_head_lane = ar_lane_mem_q[0];

  always_comb begin
    logic [31:0] byte_base, byte_idx;
    byte_base = numfmt_q == 3'd1 ? t_q >> 1 : t_q << ai_fmt_shift();
    byte_idx = '0;
    for (int unsigned p = 0; p < PeLanes; p++) begin
      a_r_req[p] = 1'b0;
      a_r_addr[p] = '0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        b_r_req[g][p] = 1'b0;
        b_r_addr[g][p] = '0;
      end
      byte_idx = byte_base + 32'(p);
      if (state_q == ST_MAC && i_q < m_q &&
          ((numfmt_q == 3'd1) ? t_q + 32'(p << 1) < k_q : byte_idx < k_bytes)) begin
        a_r_req[p] = 1'b1;
        a_r_addr[p] = a_bank_addr(i_q, byte_idx);
        // Static destination index (a dynamic first index on the write side is a
        // read-modify-write of the array to a synthesis frontend -> logic loop).
        for (int unsigned g = 0; g < OutCols; g++)
          for (int unsigned gg = 0; gg < OutCols; gg++)
            if (col_v[g] && grp_of[g] == ColW'(gg)) begin
              b_r_req[gg][p] = 1'b1;
              b_r_addr[gg][p] = b_bank_addr(byte_idx, j_q + 32'(g));
            end
      end
    end
  end

  always_comb begin
    logic trail, pair_store;
    logic [31:0] beats_done, column;
    pair_store = DataWidth >= 64 && !n_q[0];
    trail = state_q == ST_MAC && DualCRead && DataWidth >= 64 && dot_pending_q == '0 &&
        !acc_mode_q && trail_ready;
    beats_done = 32'(stc_elem_q >> wsh_q) - 32'(stc_w_left_q);
    column = stc_j_q + (beats_done << wsh_q);
    c_r0_req = 1'b0;
    c_r0_bank = '0;
    c_r0_addr = '0;
    c_r1_req = 1'b0;
    c_r1_bank = '0;
    c_r1_addr = '0;
    for (int unsigned w = 0; w < StoreWordsMax; w++) begin
      c_rx_req[w]  = 1'b0;
      c_rx_bank[w] = '0;
      c_rx_addr[w] = '0;
    end
    if (state_q == ST_MAC && acc_mode_q && sum_v_q && sum_first_q) begin
      // Seed read for the element whose first partial drains this cycle.
      c_r0_req  = 1'b1;
      c_r0_bank = c_bank(sum_j_q);
      c_r0_addr = c_bank_addr(sum_i_q, sum_j_q);
    end else if (trail || state_q == ST_STC) begin
      if (!pair_store) begin
        c_r0_req = 1'b1;
        c_r0_bank = c_bank(stc_j_q);
        c_r0_addr = c_bank_addr(stc_i_q, stc_j_q);
      end else if (aw_sent_q && stc_w_left_q != 0) begin
        c_r0_req = 1'b1;
        if (DualCRead) begin
          c_r0_bank = c_bank(column);
          c_r0_addr = c_bank_addr(stc_i_q, column);
          c_r1_req = 1'b1;
          c_r1_bank = c_bank(column + 32'd1);
          c_r1_addr = c_bank_addr(stc_i_q, column + 32'd1);
          // Wide beat: columns 2..W-1 of the beat as well.
          if (wide_c_q)
            for (int unsigned w = 2; w < StoreWordsMax; w++) begin
              c_rx_req[w]  = 1'b1;
              c_rx_bank[w] = c_bank(column + 32'(w));
              c_rx_addr[w] = c_bank_addr(stc_i_q, column + 32'(w));
            end
        end else begin
          c_r0_bank = c_bank(column + 32'(c_pair_hold_q));
          c_r0_addr = c_bank_addr(stc_i_q, column + 32'(c_pair_hold_q));
        end
      end
    end
  end

  always_comb begin
    logic [31:0] t_byte_base;
    t_byte_base = numfmt_q == 3'd1 ? t_q >> 1 : t_q << ai_fmt_shift();
    for (int unsigned p = 0; p < PeLanes; p++) begin
      pe_a[p] = '0;
      pe_a_float[p] = '0;
      pe_v[p] = 1'b0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        pe_b[g][p] = '0;
        pe_b_float[g][p] = '0;
      end
    end
    if (state_q == ST_MAC && i_q < m_q) begin
      for (int unsigned p = 0; p < PeLanes; p++) begin
        if (numfmt_q == 3'd1) begin
          // INT4: two elements per byte. Lane p covers elements
          // (t_q + 2p) and (t_q + 2p + 1) in the same byte.
          automatic logic [31:0] e0, e1;
          e0 = t_q + 32'(p << 1);
          e1 = e0 + 32'd1;
          if (e0 < k_q) begin
            // Mask the invalid nibble(s) to 0; the PE sign-extends the
            // remaining nibble and computes two products, one of which is 0.
            pe_a[p] = {(e1 < k_q) ? a_r_data[p][7:4] : 4'b0000,
                       (e0 < k_q) ? a_r_data[p][3:0] : 4'b0000};
            for (int unsigned g = 0; g < OutCols; g++)
              pe_b[g][p] = {(e1 < k_q) ? b_r_data[grp_of[g]][p][7:4] : 4'b0000,
                            (e0 < k_q) ? b_r_data[grp_of[g]][p][3:0] : 4'b0000};
            pe_v[p] = 1'b1;
          end
        end else begin
          // INT8/FP8/BF16/FP16/FP32: load bytes, then assemble elements
          // into 32-bit float lanes.  `byte_idx` is the byte position
          // along the K row; `k_bytes` comes from fmt_row_bytes().
          automatic logic [31:0] byte_idx;
          byte_idx = t_byte_base + 32'(p);
          if (byte_idx < k_bytes) begin
            pe_a[p] = $signed(a_r_data[p]);
            for (int unsigned g = 0; g < OutCols; g++)
              pe_b[g][p] = $signed(b_r_data[grp_of[g]][p]);
          end
        end
      end

      // Assemble multi-byte floating operands (BF16/FP16/FP32) from the
      // byte-lane read data. For INT8/FP8 this is a zero-extend; for
      // FP16/BF16 it is two bytes little-endian; for FP32 it is four.
      // INT4 stays in its own branch above.
      if (numfmt_q != 3'd1) begin
        // Bounded by the PeLanes parameter, not by the runtime mac_step:
        // on this branch (numfmt != INT4) mac_step is PeLanes/bytes, so it
        // can never exceed PeLanes and the extra iterations are inert.  A
        // constant bound is what makes this loop elaborate under an open
        // synthesis frontend -- with the runtime bound, Yosys read_slang
        // tries to unroll it and exhausts its limit, which left the whole
        // GEMM datapath without any gate-level area or timing evidence.
        for (int unsigned e = 0; e < PeLanes; e++) begin
          automatic logic [31:0] elem_t;
          automatic logic [31:0] off;
          elem_t = t_q + 32'(e);
          off = 32'(e) << ai_fmt_shift();
          if (int'(e) < int'(mac_step) && elem_t < k_q) begin
            case (ai_fmt_bytes())
              32'd1: begin
                pe_a_float[e] = {24'b0, a_r_data[off]};
                for (int unsigned g = 0; g < OutCols; g++)
                  pe_b_float[g][e] = {24'b0, b_r_data[grp_of[g]][off]};
              end
              32'd2: begin
                pe_a_float[e] = {16'b0, a_r_data[off+1], a_r_data[off]};
                for (int unsigned g = 0; g < OutCols; g++)
                  pe_b_float[g][e] = {16'b0, b_r_data[grp_of[g]][off+1], b_r_data[grp_of[g]][off]};
              end
              32'd4: begin
                pe_a_float[e] = {a_r_data[off+3], a_r_data[off+2], a_r_data[off+1], a_r_data[off]};
                for (int unsigned g = 0; g < OutCols; g++)
                  pe_b_float[g][e] = {b_r_data[grp_of[g]][off+3], b_r_data[grp_of[g]][off+2],
                                      b_r_data[grp_of[g]][off+1], b_r_data[grp_of[g]][off]};
              end
              default: begin
                pe_a_float[e] = 32'd0;
                for (int unsigned g = 0; g < OutCols; g++) pe_b_float[g][e] = 32'd0;
              end
            endcase
            pe_v[e] = 1'b1;
          end
        end
      end
    end
  end

  always_comb begin
    // defaults: idle banks + AXI
    for (int unsigned p = 0; p < PeLanes; p++) begin
      a_w_req[p]  = 1'b0;
      a_w_addr[p] = '0;
      a_w_data[p] = '0;
      for (int unsigned g = 0; g < OutCols; g++) begin
        b_w_req[g][p]  = 1'b0;
        b_w_addr[g][p] = '0;
        b_w_data[g][p] = '0;
      end
    end
    c_w_req  = 1'b0;
    c_w_bank = '0;
    c_w_addr = '0;
    c_w_data = '0;
    for (int unsigned g = 0; g < OutCols; g++) begin
      c_wx_req[g]  = 1'b0;
      c_wx_bank[g] = '0;
      c_wx_addr[g] = '0;
      c_wx_data[g] = '0;
    end

    axi_req_d = '0;
    axi_req_d.b_ready  = 1'b0;
    axi_req_d.r_ready  = 1'b0;
    axi_req_d.ar_valid = 1'b0;
    axi_req_d.aw_valid = 1'b0;
    axi_req_d.w_valid  = 1'b0;
    axi_req_d.ar.id    = IdWidth'(2);
    axi_req_d.ar.len   = '0;
    axi_req_d.ar.size  = axi_pkg::size_t'($clog2(DataWidth / 8));
    axi_req_d.ar.burst = axi_pkg::BURST_INCR;
    axi_req_d.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    axi_req_d.aw.id    = IdWidth'(2);
    axi_req_d.aw.len   = '0;
    axi_req_d.aw.size  = axi_pkg::size_t'(2);  // default 4B; pair path uses 8B
    axi_req_d.aw.burst = axi_pkg::BURST_INCR;
    axi_req_d.aw.cache = '0;
    axi_req_d.w.last   = 1'b1;
    axi_req_d.w.strb   = '0;

    state_d     = state_q;
    for (int unsigned g = 0; g < OutCols; g++) begin
      acc_d[g]    = acc_q[g];
      sum_d[g]    = '0;
      sum_cv_d[g] = 1'b0;
    end
    // F0b-2: pipeline defaults (and empty-pipe on state entry).
    sum_v_d     = 1'b0;
    sum_first_d = 1'b0;
    sum_last_d  = 1'b0;
    sum_i_d     = '0;
    sum_j_d     = '0;
    // Dot-product issue metadata defaults (used only when DotPipeFloat is set).
    dot_start       = 1'b0;
    dot_first_issue = 1'b0;
    dot_last_issue  = 1'b0;
    dot_i_issue     = '0;
    dot_j_issue     = '0;
    // acc_d keeps the current accumulator unless a drain overrides it.
    err_d       = err_q;
    ar_inflight_d = ar_inflight_q;
    aw_sent_d   = aw_sent_q;
    w_sent_d    = w_sent_q;
    ar_i_en     = 1'b0;
    ar_t_en     = 1'b0;
    ar_j_en     = 1'b0;
    ar_i_d      = ar_i_q;
    ar_t_d      = ar_t_q;
    ar_j_d      = ar_j_q;
    ar_lane_push    = '0;
    ar_lane_push_en = 1'b0;
    ar_lane_pop_en  = 1'b0;
    ar_slot_we         = 1'b0;
    ar_slot_widx       = '0;
    ar_slot_push_row   = '0;
    ar_slot_push_col   = '0;
    ar_slot_r_en       = 1'b0;
    ar_slot_r_last     = 1'b0;
    ar_slot_ridx       = '0;
    ar_slot_ntake      = '0;
    la_n_d          = 8'd0;
    lb_n_d          = 8'd0;
    burst_first_d   = burst_first_q;
    c_pair_hold_d   = c_pair_hold_q;
    c_lo_we_d       = 1'b0;
    stc_w_left_d    = stc_w_left_q;
    stc_elem_d      = stc_elem_q;
    // Default is the FULL open-AW element count: one B response retires the
    // whole multi-beat burst, so the cursor advance must match what the AW
    // covered rather than a single element.
    stc_n_d         = stc_elem_q;  // default: retire full open AW on B
    stc_i_en        = 1'b0;
    stc_j_en        = 1'b0;
    stc_i_d         = stc_i_q;
    stc_j_d         = stc_j_q;
    lc_ar_fire      = 1'b0;
    lc_r_fire       = 1'b0;
    lc_w_fire       = 1'b0;
    lc_ar_beats     = 8'd0;

    unique case (state_q)
      ST_IDLE: begin
        ar_inflight_d = '0;
        aw_sent_d     = 1'b0;
        w_sent_d      = 1'b0;
        burst_first_d = 1'b0;
        c_pair_hold_d = 1'b0;
        stc_w_left_d  = 8'd0;
        stc_elem_d    = 8'd0;
        if (start_i) begin
          err_d   = 1'b0;
          state_d = ST_CHK;
        end
      end

      ST_CHK: begin
        // AI-X9: B is k-major, so ldb must hold a row of k elements (was n).
        // A/B must be aligned to the element. Even n stores 8-byte C pairs;
        // odd n stores 4-byte C words.
        if (m_q == 0 || n_q == 0 || k_q == 0
            || m_q > LimM || n_q > LimN || !cap_ok_c
            || ai_fmt_bytes() > MaxElementBytes
            || lda_q < k_q[15:0] || ldb_q < k_q[15:0]
            || !g6lc_ai_island_cfg_pkg::ai_elem_aligned(pa_q, numfmt_q)
            || !g6lc_ai_island_cfg_pkg::ai_elem_aligned(pb_q, numfmt_q)
            || !g6lc_ai_island_cfg_pkg::ai_c_aligned(pc_q, n_q[0])) begin
          err_d   = 1'b1;
          state_d = ST_DONE;
        end else begin
          ar_inflight_d = '0;
          burst_first_d = 1'b0;
          ar_i_en = 1'b1; ar_i_d = '0;
          ar_t_en = 1'b1; ar_t_d = '0;
          ar_j_en = 1'b1; ar_j_d = '0;
          state_d       = ST_LA;
          // A resident: skip its load.  If B is resident too there is nothing
          // left to fetch, so go straight to the MAC with a cleared
          // accumulator, which is what ST_LB's exit would otherwise do.
          if (ReuseAEn && reuse_a_skip_q && reuse_a_safe && !reuse_a_invalidate_i) begin
            if (ReuseBEn && reuse_b_skip_q && reuse_b_safe && !reuse_b_invalidate_i) begin
              state_d = ST_MAC;
              for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            end else
              state_d = ST_LB;
          end
        end
      end

      // Load A: multi-beat INCR + multi-outstanding AR (issue runs ahead of R)
      ST_LA: begin
        begin
          automatic logic       ar_push, r_fire, r_match;
          automatic logic [7:0] nb;
          automatic logic [31:0] elems;
          automatic logic [ARSlotW-1:0] free_s, match_s;
          ar_push = 1'b0;
          r_fire  = 1'b0;
          r_match = 1'b0;
          free_s  = '0;
          match_s = '0;
          if (SplitArId) begin
            automatic logic found_free;
            found_free = 1'b0;
            for (int unsigned s = 0; s < MaxAROut; s++) begin
              if (!ar_slot_q[s].valid && !found_free) begin
                found_free = 1'b1;
                free_s = ARSlotW'(s);
              end
              if (ar_slot_q[s].valid &&
                  axi_resp_s.r.id == (ArIdBase + IdWidth'(s))) begin
                r_match = 1'b1;
                match_s = ARSlotW'(s);
              end
            end
          end
          // ---- Issue AR (may run concurrent with R) ----
          if (ar_hold_q) free_s = ar_hold_slot_q;
          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_i_q < m_q) begin
            axi_req_d.ar.addr  = beat_align(a_ar_cur);
            nb                 = cap_beats_to_stripe(
                beat_align(a_ar_cur),
                beats_for_rem(k_bytes - ar_t_q, a_ar_cur[BeatAlignW-1:0]));
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = a_ar_cur[BeatAlignW-1:0];
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_i_q;
              ar_slot_push_col = ar_t_q;
              elems = elems_for_burst(k_bytes - ar_t_q, a_ar_cur[BeatAlignW-1:0], nb);
              if (ar_t_q + elems >= k_bytes) begin
                ar_t_en = 1'b1; ar_t_d = '0;
                ar_i_en = 1'b1; ar_i_d = ar_i_q + 32'd1;
              end else begin
                ar_t_en = 1'b1; ar_t_d = ar_t_q + elems;
              end
            end
          end
          // ---- Receive R ----
          axi_req_d.r_ready = (ar_inflight_q != '0) &&
                              (!SplitArId || !axi_resp_s.r_valid || r_match);
          if (ar_inflight_q != '0 && axi_resp_s.r_valid &&
              (!SplitArId || r_match)) begin
            automatic logic [BeatLaneW-1:0] lane0;
            automatic logic [31:0] n_take, rem_k, rem_beat, recv_i, recv_t;
            automatic logic recv_first;
            r_fire   = 1'b1;
            recv_i   = SplitArId ? ar_slot_q[match_s].row : i_q;
            recv_t   = SplitArId ? ar_slot_q[match_s].col : t_q;
            recv_first = SplitArId ? ar_slot_q[match_s].first : burst_first_q;
            lane0    = recv_first
                     ? (SplitArId ? ar_slot_q[match_s].lane0 : ar_head_lane)
                     : BeatLaneW'(0);
            rem_k    = k_bytes - recv_t;
            rem_beat = 32'(BytesPerBeat) - 32'(lane0);
            n_take   = rem_k;
            if (n_take > rem_beat) n_take = rem_beat;
            if (n_take > PeLanes)  n_take = PeLanes;
            la_n_d = n_take[7:0];
            ar_slot_r_en   = SplitArId;
            ar_slot_ridx   = match_s;
            ar_slot_r_last = axi_resp_s.r.last;
            ar_slot_ntake  = n_take;
            for (int unsigned p = 0; p < PeLanes; p++) begin
              if (32'(p) < n_take) begin
                automatic logic [31:0] tt;
                tt = recv_t + 32'(p);
                a_w_req [t_bank(tt)] = 1'b1;
                a_w_addr[t_bank(tt)] = a_bank_addr(recv_i, tt);
                a_w_data[t_bank(tt)] = byte_from_beat(
                    axi_resp_s.r.data, BeatLaneW'(unsigned'(lane0) + p));
              end
            end
            if (axi_resp_s.r.last)
              ar_lane_pop_en = 1'b1;
            if (!SplitArId && (t_q + n_take >= k_bytes) && (i_q + 1 == m_q)) begin
              ar_t_en = 1'b1; ar_t_d = '0;
              ar_j_en = 1'b1; ar_j_d = '0;
              ar_i_en = 1'b1; ar_i_d = '0;
              state_d = ST_LB;
            end else
              state_d = ST_LA;
          end
          // Net inflight + burst_first (handles AR+R same cycle)
          unique case ({ar_push, r_fire && axi_resp_s.r.last})
            2'b10: begin
              ar_inflight_d = ar_inflight_q + AROutW'(1);
              if (ar_inflight_q == '0) burst_first_d = 1'b1;
            end
            2'b01: begin
              ar_inflight_d = ar_inflight_q - AROutW'(1);
              burst_first_d = (ar_inflight_q > AROutW'(1));
            end
            2'b11: begin
              ar_inflight_d = ar_inflight_q;  // pop+push
              burst_first_d = 1'b1;           // new head (pushed or shifted)
            end
            default: ;
          endcase
          if (r_fire && !axi_resp_s.r.last)
            burst_first_d = 1'b0;
          if (SplitArId) begin
            if ((ar_i_en ? ar_i_d : ar_i_q) >= m_q && ar_inflight_d == '0)
              state_d = ST_LB;
          end else if (state_d == ST_LB)
            ar_inflight_d = '0;
          if (state_d == ST_LB && ReuseBEn && reuse_b_skip_q && reuse_b_safe &&
              !reuse_b_invalidate_i && !err_q &&
              !(axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1])) begin
            state_d = ST_MAC;
            for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            ar_inflight_d = '0;
            ar_i_en = 1'b1; ar_i_d = '0;
            ar_j_en = 1'b1; ar_j_d = '0;
            ar_t_en = 1'b1; ar_t_d = '0;
          end
        end
      end

      // Load B: k-major (AI-X9), so this is ST_LA with the row index swapped --
      // the burst runs along t (contiguous) and the row cursor is j.
      //
      // The oct-drain that used to live here is DELETED. When B was row-major
      // the burst ran along j, so one 64-bit beat landed in ONE bank at up to 8
      // different local addresses; that is the only reason the B tile needed
      // NumPorts(8) and the only reason a held-beat path
      // (beat_q/beat_lane_q/beat_left_q) existed. Under k-major a beat spreads
      // across PeLanes DIFFERENT banks at one address each -- exactly what A
      // already sustains with a single write port -- so the 8 ports and the
      // whole leftover path were buying nothing. Byte traffic is unchanged:
      // k bursts of row_bytes(n) becomes n bursts of row_bytes(k).
      ST_LB: begin
        begin
          automatic logic       ar_push, r_fire, r_match;
          automatic logic [7:0] nb;
          automatic logic [31:0] elems;
          automatic logic [ARSlotW-1:0] free_s, match_s;
          ar_push = 1'b0;
          r_fire  = 1'b0;
          r_match = 1'b0;
          free_s  = '0;
          match_s = '0;
          if (SplitArId) begin
            automatic logic found_free;
            found_free = 1'b0;
            for (int unsigned s = 0; s < MaxAROut; s++) begin
              if (!ar_slot_q[s].valid && !found_free) begin
                found_free = 1'b1;
                free_s = ARSlotW'(s);
              end
              if (ar_slot_q[s].valid &&
                  axi_resp_s.r.id == (ArIdBase + IdWidth'(s))) begin
                r_match = 1'b1;
                match_s = ARSlotW'(s);
              end
            end
          end
          // ---- Issue AR (may run concurrent with R) ----
          if (ar_hold_q) free_s = ar_hold_slot_q;
          if ((ar_hold_q || ar_inflight_q < ar_max_eff) && ar_j_q < n_q) begin
            axi_req_d.ar.addr  = beat_align(b_ar_cur);
            nb                 = cap_beats_to_stripe(
                beat_align(b_ar_cur),
                beats_for_rem(k_bytes - ar_t_q, b_ar_cur[BeatAlignW-1:0]));
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            if (SplitArId)
              axi_req_d.ar.id = ArIdBase + IdWidth'(free_s);
            axi_req_d.ar_valid = 1'b1;
            if (axi_resp_s.ar_ready) begin
              ar_push         = 1'b1;
              ar_lane_push_en = 1'b1;
              ar_lane_push    = b_ar_cur[BeatAlignW-1:0];
              ar_slot_we       = SplitArId;
              ar_slot_widx     = free_s;
              ar_slot_push_row = ar_j_q;
              ar_slot_push_col = ar_t_q;
              elems = elems_for_burst(k_bytes - ar_t_q, b_ar_cur[BeatAlignW-1:0], nb);
              if (ar_t_q + elems >= k_bytes) begin
                ar_t_en = 1'b1; ar_t_d = '0;
                ar_j_en = 1'b1; ar_j_d = ar_j_q + 32'd1;
              end else begin
                ar_t_en = 1'b1; ar_t_d = ar_t_q + elems;
              end
            end
          end
          // ---- Receive R ----
          axi_req_d.r_ready = (ar_inflight_q != '0) &&
                              (!SplitArId || !axi_resp_s.r_valid || r_match);
          if (ar_inflight_q != '0 && axi_resp_s.r_valid &&
              (!SplitArId || r_match)) begin
            automatic logic [BeatLaneW-1:0] lane0;
            automatic logic [31:0] n_take, rem_k, rem_beat, recv_j, recv_t;
            automatic logic recv_first;
            r_fire   = 1'b1;
            recv_j   = SplitArId ? ar_slot_q[match_s].row : j_q;
            recv_t   = SplitArId ? ar_slot_q[match_s].col : t_q;
            recv_first = SplitArId ? ar_slot_q[match_s].first : burst_first_q;
            lane0    = recv_first
                     ? (SplitArId ? ar_slot_q[match_s].lane0 : ar_head_lane)
                     : BeatLaneW'(0);
            rem_k    = k_bytes - recv_t;
            rem_beat = 32'(BytesPerBeat) - 32'(lane0);
            n_take   = rem_k;
            if (n_take > rem_beat) n_take = rem_beat;
            if (n_take > PeLanes)  n_take = PeLanes;
            lb_n_d = n_take[7:0];
            ar_slot_r_en   = SplitArId;
            ar_slot_ridx   = match_s;
            ar_slot_r_last = axi_resp_s.r.last;
            ar_slot_ntake  = n_take;
            for (int unsigned p = 0; p < PeLanes; p++) begin
              if (32'(p) < n_take) begin
                automatic logic [31:0] tt;
                tt = recv_t + 32'(p);
                for (int unsigned gg = 0; gg < OutCols; gg++)
                  if (col_grp(recv_j) == ColW'(gg)) begin
                    b_w_req [gg][t_bank(tt)] = 1'b1;
                    b_w_addr[gg][t_bank(tt)] = b_bank_addr(tt, recv_j);
                    b_w_data[gg][t_bank(tt)] = byte_from_beat(
                        axi_resp_s.r.data, BeatLaneW'(unsigned'(lane0) + p));
                  end
              end
            end
            if (axi_resp_s.r.last)
              ar_lane_pop_en = 1'b1;
            if (!SplitArId && (t_q + n_take >= k_bytes) && (j_q + 1 == n_q)) begin
              state_d = ST_MAC;
              for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            end else
              state_d = ST_LB;
          end
          // Net inflight + burst_first (handles AR+R same cycle)
          unique case ({ar_push, r_fire && axi_resp_s.r.last})
            2'b10: begin
              ar_inflight_d = ar_inflight_q + AROutW'(1);
              if (ar_inflight_q == '0) burst_first_d = 1'b1;
            end
            2'b01: begin
              ar_inflight_d = ar_inflight_q - AROutW'(1);
              burst_first_d = (ar_inflight_q > AROutW'(1));
            end
            2'b11: begin
              ar_inflight_d = ar_inflight_q;  // pop+push
              burst_first_d = 1'b1;           // new head (pushed or shifted)
            end
            default: ;
          endcase
          if (r_fire && !axi_resp_s.r.last)
            burst_first_d = 1'b0;
          if (SplitArId) begin
            if ((ar_j_en ? ar_j_d : ar_j_q) >= n_q && ar_inflight_d == '0) begin
              state_d = ST_MAC;
              for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
            end
          end else if (state_d == ST_MAC)
            ar_inflight_d = '0;
        end
      end

      // Parallel MAC: lanes cover t_q .. t_q+PeLanes-1
      // Trail-store: when DualCRead and stc_i < i_q, stream completed rows on
      // free AXI (MAC does not use AXI). i_q==m means MAC finished all rows.
      //
      // F0b-2: the PE is one stage ahead of the accumulator. In each cycle:
      //   * issue operands from (i_q,j_q,t_q) and capture pe_sum as sum_d;
      //   * drain the previous cycle's sum_q into acc_q and, if it was the
      //     last step of (sum_i_q,sum_j_q), write the tile C at that address.
      //   * index (i,j,t) advance at issue rate.
      //
      // Throughput is preserved: operands issue every cycle. Only the C write
      // and accumulator update are delayed by one cycle. The drain uses the
      // captured (sum_i_q,sum_j_q) because (i_q,j_q) have already advanced.
      ST_MAC: begin
        begin
          automatic logic mac_active;
          automatic logic can_trail;
          automatic logic        can_pair;
          automatic logic [31:0] pairs_rem, nbeats, beats_done, j_eff;
          automatic logic [31:0] t_next;
          automatic logic        last_step;
          mac_active = (i_q < m_q);
          t_next     = t_q + mac_step;
          last_step  = (t_next >= k_q);
          // Trail-store only when no float dot is in flight: a pending result
          // still has to write its C bank, and that write must not race an AXI
          // read of the same bank from the store side.
          can_trail  = DualCRead && (DataWidth >= 64) && !acc_mode_q &&
                       (dot_pending_q == '0) && trail_ready;

          // ---- drain the previous issue -----------------------------------
          // The previous cycle's sum is now stable; add it to the accumulator
          // and write the tile if that issue completed an element.
          //
          // This is intentionally OUTSIDE the `mac_active` guard, so the last
          // in-flight sum drains even when the issue cursor has already
          // reached i_q == m and no new operands are being fed.
          if (sum_v_q) begin
            for (int unsigned g = 0; g < OutCols; g++) begin
              if (sum_cv_q[g]) begin
                acc_d[g] = mac_acc_next[g];
                if (sum_last_q) begin
                  if (g == 0) begin
                    c_w_req  = 1'b1;
                    c_w_bank = c_bank(sum_j_q);
                    c_w_addr = c_bank_addr(sum_i_q, sum_j_q);
                    c_w_data = mac_acc_next[0];
                  end else begin
                    c_wx_req[g]  = 1'b1;
                    c_wx_bank[g] = c_bank(sum_j_q + 32'(g));
                    c_wx_addr[g] = c_bank_addr(sum_i_q, sum_j_q + 32'(g));
                    c_wx_data[g] = mac_acc_next[g];
                  end
                end
              end
            end
          end

          // ---- issue the next step ----------------------------------------
          if (mac_active) begin
            // Tag the pipelined dot product when this is a float tile.
            dot_start      = mac_active && pe_float_en;
            dot_first_issue= (t_q == 0);
            dot_last_issue = last_step;
            dot_i_issue    = i_q;
            dot_j_issue    = j_q;

            // Capture what the PE produced this cycle. (i,j,t) are the issue
            // coordinates; they advance in the index logic below.
            if (DotPipeFloat && pe_float_en) begin
              // Dot output is captured directly in the main always_ff below;
              // these always_comb values are not used for the pipelined path.
              for (int unsigned g = 0; g < OutCols; g++) sum_d[g] = '0;
              sum_v_d    = 1'b0;
              sum_first_d= 1'b0;
              sum_last_d = 1'b0;
              sum_i_d    = '0;
              sum_j_d    = '0;
            end else begin
              for (int unsigned g = 0; g < OutCols; g++) begin
                sum_d[g]    = pe_sum[g];
                sum_cv_d[g] = col_v[g];
              end
              sum_v_d    = 1'b1;
              sum_first_d= (t_q == 0);
              sum_last_d = last_step;
              sum_i_d    = i_q;
              sum_j_d    = j_q;
            end
          end

          // Trail C-store (same pair path as ST_STC, cursor stc_i/stc_j)
          if (can_trail) begin
            // AI-X8: pair on EVEN n only, decided per ROW rather than per
            // position, so a row never transitions pair -> single midway.
            //
            // The old predicate was `!stc_j_q[0] && (stc_j_q + 1 < n_q)`, which
            // for odd n stores ceil(n/2)-1 pairs and then one single, i.e. TWO
            // AW transactions for one row. That transition is the AI-X8 defect:
            // m=2/n=3 returned a wrong C[0][2] with ST_OK and a correct ticket.
            // Bisected on one unchanged netlist:
            //   n=1     (single path only)          PASS
            //   n=4/n=6 (pair path only)            PASS
            //   m=1 n=3 (transition, no trailing)   PASS
            //   m=2 n=3 (transition, trailing)      FAIL
            // So neither path is wrong alone, and ST_STC's identical transition
            // is fine; only the trail store racing an active MAC breaks. The
            // race itself is NOT root-caused -- this removes the construct
            // rather than explaining it, which is why the fixtures stay.
            //
            // Cost: an odd-n C row now takes n beats instead of ceil(n/2).
            // C store is overlapped with MAC and is not the bottleneck, and odd
            // n is the rare shape, so this is the cheap side of the trade.
            can_pair = !n_q[0];
            if (can_pair) begin
              if (!aw_sent_q) begin
                pairs_rem = (n_q - stc_j_q) >> wsh_q;
                nbeats    = pairs_rem;
                // Inside the row still being computed only the beats whose C words
                // are already written may be burst; the AW length is fixed at issue.
                if (!(stc_i_q < 32'(c_rows_done_q)) && nbeats > ((c_cols_done_q - stc_j_q) >> wsh_q))
                  nbeats = (c_cols_done_q - stc_j_q) >> wsh_q;
                if (nbeats > MaxBurstBeats) nbeats = MaxBurstBeats;
                nbeats    = wide_c_q ? cap_nbeats_to_stripe(c_store_addr, nbeats)
                                     : cap_c_nbeats(c_store_addr, nbeats);
                if (nbeats == 0) nbeats = 1;
                axi_req_d.aw.addr  = c_store_addr;
                axi_req_d.aw.len   = axi_pkg::len_t'(nbeats - 32'd1);
                axi_req_d.aw.size  = axi_pkg::size_t'(32'd2 + 32'(wsh_q));
                axi_req_d.aw_valid = 1'b1;
                if (axi_resp_s.aw_ready) begin
                  aw_sent_d     = 1'b1;
                  stc_w_left_d  = nbeats[8:0];
                  stc_elem_d    = nbeats[15:0] << wsh_q;
                  w_sent_d      = 1'b0;
                  c_pair_hold_d = 1'b0;
                end
              end else if (stc_w_left_q != 9'd0) begin
                beats_done = 32'(stc_elem_q >> wsh_q) - 32'(stc_w_left_q);
                j_eff      = stc_j_q + (beats_done << wsh_q);
                begin
                  automatic wbeat_t wb;
                  wb = wbeat_words(32'(c_store_addr) + (beats_done << (32'd2 + 32'(wsh_q))),
                                   wide_c_q ? StoreWordsMax : 2);
                  axi_req_d.w.data = wb.data;
                  axi_req_d.w.strb = wb.strb;
                end
                axi_req_d.w.last  = (stc_w_left_q == 9'd1);
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) begin
                  stc_w_left_d = stc_w_left_q - 9'd1;
                  if (stc_w_left_q == 9'd1)
                    w_sent_d = 1'b1;
                end
              end else begin
                axi_req_d.b_ready = 1'b1;
                stc_n_d = stc_elem_q;
                if (axi_resp_s.b_valid) begin
                  if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR,
                                                axi_pkg::RESP_SLVERR})
                    err_d = 1'b1;
                  aw_sent_d     = 1'b0;
                  w_sent_d      = 1'b0;
                  c_pair_hold_d = 1'b0;
                  stc_elem_d    = '0;
                  // advance store cursor
                  if (stc_j_q + 32'(stc_elem_q) >= n_q) begin
                    stc_j_en = 1'b1;
                    stc_j_d  = '0;
                    stc_i_en = 1'b1;
                    stc_i_d  = stc_i_q + 32'd1;
                  end else begin
                    stc_j_en = 1'b1;
                    stc_j_d  = stc_j_q + 32'(stc_elem_q);
                  end
                end
              end
            end else begin
              // Single i32 (odd n tail)
              axi_req_d.aw.addr = c_store_addr;
              axi_req_d.aw.size = axi_pkg::size_t'(2);
              begin
                automatic wbeat_t wb;
                wb = wbeat_at(64'(c_r0_data), 4, 32'(c_store_addr));
                axi_req_d.w.data = wb.data;
                axi_req_d.w.strb = wb.strb;
              end
              stc_n_d = 16'd1;
              if (!aw_sent_q) begin
                axi_req_d.aw_valid = 1'b1;
                if (axi_resp_s.aw_ready) begin
                  aw_sent_d  = 1'b1;
                  stc_elem_d = 16'd1;
                end
              end
              if (!w_sent_q) begin
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) w_sent_d = 1'b1;
              end
              axi_req_d.b_ready = 1'b1;
              if (aw_sent_q && w_sent_q && axi_resp_s.b_valid) begin
                if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR,
                                              axi_pkg::RESP_SLVERR})
                  err_d = 1'b1;
                aw_sent_d     = 1'b0;
                w_sent_d      = 1'b0;
                c_pair_hold_d = 1'b0;
                stc_elem_d    = '0;
                if (stc_j_q + 1 >= n_q) begin
                  stc_j_en = 1'b1;
                  stc_j_d  = '0;
                  stc_i_en = 1'b1;
                  stc_i_d  = stc_i_q + 32'd1;
                end else begin
                  stc_j_en = 1'b1;
                  stc_j_d  = stc_j_q + 32'd1;
                end
              end
            end
          end

          // Exit: MAC done (i>=m) and store done (stc_i>=m). The pipeline
          // must be empty before leaving: a valid in-flight sum has its C
          // write one cycle later and cannot be cancelled.
          if (i_q >= m_q && stc_i_q >= m_q && !aw_sent_q && !sum_v_q &&
              dot_pending_q == '0)
            state_d = ST_DONE;
          else if (i_q >= m_q && stc_i_q >= m_q && aw_sent_q &&
                   dot_pending_q == '0)
            state_d = ST_MAC;  // finish open AW/B
          else if ((!DualCRead || acc_mode_q) && i_q >= m_q && dot_pending_q == '0) begin
            // PeLanes==1 (or accumulate mode, whose seed reads own port r0 during
            // the MAC): fall back to dedicated ST_STC
            state_d       = ST_STC;
            aw_sent_d     = 1'b0;
            w_sent_d      = 1'b0;
            c_pair_hold_d = 1'b0;
            stc_w_left_d  = '0;
            stc_elem_d    = '0;
          end else
            state_d = ST_MAC;
        end
      end

      // Accumulate: stream the existing C tile (contiguous, ldc = n) into the C
      // banks. One outstanding burst; each received beat is drained one 32-bit
      // word per cycle through the single C write port (R is held meanwhile).
      ST_LC: begin
        begin
          automatic logic [AddrWidth-1:0] lc_addr;
          automatic logic [31:0] beats_left;
          automatic logic [7:0]  nb;
          lc_addr    = beat_align(pc_q) + AddrWidth'(lc_issued_q) * AddrWidth'(BytesPerBeat);
          beats_left = lc_beats_q - lc_issued_q;
          nb         = (beats_left > MaxBurstBeats) ? 8'(MaxBurstBeats) : beats_left[7:0];
          nb         = cap_beats_to_stripe(lc_addr, nb);
          if (!lc_ar_busy_q && lc_issued_q < lc_beats_q) begin
            axi_req_d.ar.addr  = lc_addr;
            axi_req_d.ar.len   = axi_pkg::len_t'(nb - 8'd1);
            axi_req_d.ar_valid = 1'b1;
            lc_ar_beats        = nb;
            if (axi_resp_s.ar_ready) lc_ar_fire = 1'b1;
          end
          axi_req_d.r_ready = lc_ar_busy_q && !lc_buf_v_q;
          if (lc_ar_busy_q && !lc_buf_v_q && axi_resp_s.r_valid) begin
            lc_r_fire = 1'b1;
            if (axi_resp_s.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
              err_d = 1'b1;
          end
          if (lc_buf_v_q && lc_e_q < lc_total_q) begin
            c_w_req   = 1'b1;
            c_w_bank  = c_bank(lc_j_q);
            c_w_addr  = c_bank_addr(lc_i_q, lc_j_q);
            c_w_data  = lc_buf_q[32 * lc_word_q +: 32];
            lc_w_fire = 1'b1;
          end
          if (err_q) begin
            if (!lc_ar_busy_q) state_d = ST_DONE;
          end else if (lc_e_q >= lc_total_q && !lc_buf_v_q && !lc_ar_busy_q) begin
            state_d = ST_MAC;
            for (int unsigned g = 0; g < OutCols; g++) acc_d[g] = '0;
          end
        end
      end

      ST_STC: begin
        // Fallback single-lane / non-trail path (also used if trail disabled).
        // Multi-beat pair path (≥64-bit) on stc_i/stc_j cursor.
        begin
          automatic logic        can_pair;
          automatic logic [31:0] pairs_rem, nbeats, beats_done, j_eff;
          // AI-X8: even n only, per row -- see the trail-store copy in ST_MAC.
          // Kept identical to the trail predicate so the two store sites cannot
          // disagree about how a row is chunked.
          can_pair = (DataWidth >= 64) && !n_q[0];

          if (can_pair) begin
            if (!aw_sent_q) begin
              pairs_rem = (n_q - stc_j_q) >> wsh_q;
              nbeats    = pairs_rem;
              if (nbeats > MaxBurstBeats) nbeats = MaxBurstBeats;
              nbeats    = wide_c_q ? cap_nbeats_to_stripe(c_store_addr, nbeats)
                                   : cap_c_nbeats(c_store_addr, nbeats);
              if (nbeats == 0) nbeats = 1;
              axi_req_d.aw.addr  = c_store_addr;
              axi_req_d.aw.len   = axi_pkg::len_t'(nbeats - 32'd1);
              axi_req_d.aw.size  = axi_pkg::size_t'(32'd2 + 32'(wsh_q));
              axi_req_d.aw_valid = 1'b1;
              if (axi_resp_s.aw_ready) begin
                aw_sent_d     = 1'b1;
                stc_w_left_d  = nbeats[8:0];
                stc_elem_d    = nbeats[15:0] << wsh_q;
                w_sent_d      = 1'b0;
                c_pair_hold_d = 1'b0;
              end
            end else if (stc_w_left_q != 9'd0) begin
              beats_done = 32'(stc_elem_q >> wsh_q) - 32'(stc_w_left_q);
              j_eff      = stc_j_q + (beats_done << wsh_q);
              if (DualCRead) begin
                begin
                  automatic wbeat_t wb;
                  wb = wbeat_words(32'(c_store_addr) + (beats_done << (32'd2 + 32'(wsh_q))),
                                   wide_c_q ? StoreWordsMax : 2);
                  axi_req_d.w.data = wb.data;
                  axi_req_d.w.strb = wb.strb;
                end
                axi_req_d.w.last  = (stc_w_left_q == 9'd1);
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) begin
                  stc_w_left_d = stc_w_left_q - 9'd1;
                  if (stc_w_left_q == 9'd1)
                    w_sent_d = 1'b1;
                end
              end else if (!c_pair_hold_q) begin
                c_lo_we_d     = 1'b1;
                c_pair_hold_d = 1'b1;
              end else begin
                begin
                  automatic wbeat_t wb;
                  wb = wbeat_at({c_r0_data, c_lo_q}, 8,
                                32'(c_store_addr) + (beats_done << 3));
                  axi_req_d.w.data = wb.data;
                  axi_req_d.w.strb = wb.strb;
                end
                axi_req_d.w.last  = (stc_w_left_q == 9'd1);
                axi_req_d.w_valid = 1'b1;
                if (axi_resp_s.w_ready) begin
                  stc_w_left_d  = stc_w_left_q - 9'd1;
                  c_pair_hold_d = 1'b0;
                  if (stc_w_left_q == 9'd1)
                    w_sent_d = 1'b1;
                end
              end
            end else begin
              axi_req_d.b_ready = 1'b1;
              stc_n_d = stc_elem_q;
              if (axi_resp_s.b_valid) begin
                if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
                  err_d = 1'b1;
                aw_sent_d     = 1'b0;
                w_sent_d      = 1'b0;
                c_pair_hold_d = 1'b0;
                stc_elem_d    = '0;
                if (stc_j_q + 32'(stc_elem_q) >= n_q) begin
                  stc_j_en = 1'b1;
                  stc_j_d  = '0;
                  stc_i_en = 1'b1;
                  stc_i_d  = stc_i_q + 32'd1;
                  if (stc_i_q + 1 >= m_q)
                    state_d = ST_DONE;
                  else
                    state_d = ST_STC;
                end else begin
                  stc_j_en = 1'b1;
                  stc_j_d  = stc_j_q + 32'(stc_elem_q);
                  state_d  = ST_STC;
                end
              end
            end
          end else begin
            axi_req_d.aw.addr = c_store_addr;
            axi_req_d.aw.size = axi_pkg::size_t'(2);
            begin
              automatic wbeat_t wb;
              wb = wbeat_at(64'(c_r0_data), 4, 32'(c_store_addr));
              axi_req_d.w.data = wb.data;
              axi_req_d.w.strb = wb.strb;
            end
            stc_n_d = 16'd1;
            if (!aw_sent_q) begin
              axi_req_d.aw_valid = 1'b1;
              if (axi_resp_s.aw_ready) begin
                aw_sent_d  = 1'b1;
                stc_elem_d = 16'd1;
              end
            end
            if (!w_sent_q) begin
              axi_req_d.w_valid = 1'b1;
              if (axi_resp_s.w_ready) w_sent_d = 1'b1;
            end
            axi_req_d.b_ready = 1'b1;
            if (aw_sent_q && w_sent_q && axi_resp_s.b_valid) begin
              if (axi_resp_s.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
                err_d = 1'b1;
              aw_sent_d     = 1'b0;
              w_sent_d      = 1'b0;
              c_pair_hold_d = 1'b0;
              stc_elem_d    = '0;
              if (stc_j_q + 1 >= n_q) begin
                stc_j_en = 1'b1;
                stc_j_d  = '0;
                stc_i_en = 1'b1;
                stc_i_d  = stc_i_q + 32'd1;
                if (stc_i_q + 1 >= m_q)
                  state_d = ST_DONE;
                else
                  state_d = ST_STC;
              end else begin
                stc_j_en = 1'b1;
                stc_j_d  = stc_j_q + 32'd1;
                state_d  = ST_STC;
              end
            end
          end
        end
      end

      ST_DONE: state_d = ST_IDLE;
      default: state_d = ST_IDLE;
    endcase
    // Accumulate mode enters the MAC through ST_LC so the tile holds C first.
    if (acc_mode_q && state_d == ST_MAC && state_q != ST_MAC && state_q != ST_LC)
      state_d = ST_LC;

  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= ST_IDLE;
      m_q <= '0; n_q <= '0; k_q <= '0;
      lda_q <= '0; ldb_q <= '0; ldc_q <= '0;
      numfmt_q <= '0;
      acc_mode_q <= 1'b0;
      pa_q <= '0; pb_q <= '0; pc_q <= '0;
      i_q <= '0; j_q <= '0; t_q <= '0;
      for (int unsigned g = 0; g < OutCols; g++) begin acc_q[g] <= '0; sum_q[g] <= '0; sum_cv_q[g] <= 1'b0; end
      pitch_sh_q <= '0;
      err_q <= 1'b0;
      done_q <= 1'b0;
      ar_inflight_q <= '0;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
      burst_first_q <= 1'b0;
      ar_i_q <= '0;
      ar_t_q <= '0;
      ar_j_q <= '0;
      // F0b-2: the reduction pipeline is empty at reset.
      sum_v_q    <= 1'b0;
      wide_c_q   <= 1'b0;
      wsh_q      <= StoreShW'(1);
      sum_first_q<= 1'b0;
      sum_last_q <= 1'b0;
      sum_i_q    <= '0;
      sum_j_q    <= '0;
      for (int unsigned k = 0; k < MaxAROut; k++) begin
        ar_lane_mem_q[k] <= '0;
        ar_slot_q[k]     <= '0;
      end
      c_pair_hold_q <= 1'b0;
      c_lo_q <= '0;
      stc_w_left_q <= '0;
      stc_elem_q <= '0;
      stc_i_q <= '0;
      stc_j_q <= '0;
      c_rows_done_q <= '0;
      c_cols_row_q <= '0;
      c_cols_done_q <= '0;
      dot_pending_q <= '0;
      pmu_r_q  <= '0;
      pmu_w_q  <= '0;
      pmu_cy_q <= '0;
    end else begin
      state_q       <= state_d;
      for (int unsigned g = 0; g < OutCols; g++) acc_q[g] <= acc_d[g];
      // F0b-2: advance the pipeline stage. For the pipelined floating path the
      // dot product valid/data are sampled directly from the pipe output; the
      // integer path continues to use the combinational `sum_*_d` values.
      if (DotPipeFloat && pe_float_en) begin
        for (int unsigned g = 0; g < OutCols; g++) begin
          sum_q[g]    <= dot_valid ? dot_sum[g] : '0;
          sum_cv_q[g] <= dot_valid ? dot_cv_out[g] : 1'b0;
        end
        sum_v_q     <= dot_valid;
        sum_first_q <= dot_valid ? dot_first_out : 1'b0;
        sum_last_q  <= dot_valid ? dot_last_out  : 1'b0;
        sum_i_q     <= dot_valid ? dot_i_out     : '0;
        sum_j_q     <= dot_valid ? dot_j_out     : '0;
      end else begin
        for (int unsigned g = 0; g < OutCols; g++) begin
          sum_q[g]    <= sum_d[g];
          sum_cv_q[g] <= sum_cv_d[g];
        end
        sum_v_q     <= sum_v_d;
        sum_first_q <= sum_first_d;
        sum_last_q  <= sum_last_d;
        sum_i_q     <= sum_i_d;
        sum_j_q     <= sum_j_d;
      end
      err_q       <= err_d;
      // The pitch is fixed for the job at ST_CHK; every bank address from ST_LA on
      // uses the registered value (the reuse key compares k, so a resident panel
      // always carries the pitch the new job computes).
      if (state_q == ST_CHK) pitch_sh_q <= pitch_sh_c;
      // Wide C store when every row base is beat-aligned: n a multiple of the
      // words per beat (ldc = n) and ptr_c aligned to the beat. Pairs otherwise.
      if (state_q == ST_CHK) begin
        wide_c_q <= WideCStore && !n_q[0] &&
                    ((n_q & 32'(StoreWordsMax - 1)) == 32'd0) &&
                    ((ldc_eff & 32'(StoreWordsMax - 1)) == 32'd0) &&
                    ((pc_q & AddrWidth'(BytesPerBeat - 1)) == '0);
        wsh_q    <= (WideCStore && !n_q[0] &&
                     ((n_q & 32'(StoreWordsMax - 1)) == 32'd0) &&
                     ((ldc_eff & 32'(StoreWordsMax - 1)) == 32'd0) &&
                     ((pc_q & AddrWidth'(BytesPerBeat - 1)) == '0)) ? StoreShW'(StoreShMax) : StoreShW'(1);
      end
      ar_inflight_q <= ar_inflight_d;
      aw_sent_q     <= aw_sent_d;
      w_sent_q      <= w_sent_d;
      burst_first_q <= burst_first_d;
      if (ar_i_en) ar_i_q <= ar_i_d;
      if (ar_t_en) ar_t_q <= ar_t_d;
      if (ar_j_en) ar_j_q <= ar_j_d;
      // Lane FIFO: push on AR accept, pop on r.last (shift-register depth MaxAROut)
      if (ar_lane_push_en && ar_lane_pop_en) begin
        // pop head, push new at tail; depth unchanged (= ar_inflight_q)
        for (int unsigned k = 0; k < MaxAROut - 1; k++)
          ar_lane_mem_q[k] <= ar_lane_mem_q[k + 1];
        // after shift, free slot index is ar_inflight_q-1 (depth stays same)
        if (ar_inflight_q != '0)
          ar_lane_mem_q[ar_inflight_q - AROutW'(1)] <= ar_lane_push;
        else
          ar_lane_mem_q[0] <= ar_lane_push;
      end else if (ar_lane_push_en) begin
        ar_lane_mem_q[ar_inflight_q] <= ar_lane_push;
      end else if (ar_lane_pop_en) begin
        for (int unsigned k = 0; k < MaxAROut - 1; k++)
          ar_lane_mem_q[k] <= ar_lane_mem_q[k + 1];
      end
      if (SplitArId) begin
        if (ar_slot_we) begin
          ar_slot_q[ar_slot_widx].valid <= 1'b1;
          ar_slot_q[ar_slot_widx].first <= 1'b1;
          ar_slot_q[ar_slot_widx].lane0 <= ar_lane_push;
          ar_slot_q[ar_slot_widx].row   <= ar_slot_push_row;
          ar_slot_q[ar_slot_widx].col   <= ar_slot_push_col;
        end
        if (ar_slot_r_en) begin
          if (ar_slot_r_last)
            ar_slot_q[ar_slot_ridx].valid <= 1'b0;
          else begin
            ar_slot_q[ar_slot_ridx].first <= 1'b0;
            // AI-X9/F1: `col` is a BYTE offset along the operand row in BOTH load
            // states now, so both bound against k_bytes. ST_LB used to bound
            // against n_q because row-major B ran along j -- keeping that after
            // the k-major rewrite retired the slot's column at the wrong point
            // and corrupted C whenever a row straddled a beat boundary. It only
            // showed on SplitArId (NrChannels>1) with a row stride that does not
            // divide BytesPerBeat, which no power-of-two fixture produces;
            // ai_gemm_s8_asym_smoke (k=6) on ai-sc2 is the gate.
            if (ar_slot_q[ar_slot_ridx].col + ar_slot_ntake >= k_bytes) begin
              ar_slot_q[ar_slot_ridx].col <= '0;
              ar_slot_q[ar_slot_ridx].row <=
                  ar_slot_q[ar_slot_ridx].row + 32'd1;
            end else
              ar_slot_q[ar_slot_ridx].col <=
                  ar_slot_q[ar_slot_ridx].col + ar_slot_ntake;
          end
        end
      end
      c_pair_hold_q <= c_pair_hold_d;
      stc_w_left_q  <= stc_w_left_d;
      stc_elem_q    <= stc_elem_d;
      // Outstanding pipelined dot transactions. This is the ONLY thing that
      // keeps ST_MAC from exiting while results are still in the FP pipe --
      // i_q reaching m only means issue finished, not that C is written.
      dot_pending_q <= DotPipeFloat && pe_float_en
                       ? dot_pending_q
                         + (dot_start ? 1'd1 : 1'd0)
                         - ((dot_valid && dot_pending_q != '0) ? 1'd1 : 1'd0)
                       : '0;
      if (c_lo_we_d)   c_lo_q <= c_r_data;
      // Column 0 of a group always writes when the group completes, and the
      // group's valid columns are consecutive from sum_j_q, so the written count
      // is min(sum_j_q + cols_eff, n) -- except in ST_LC, whose C writes are the
      // seed load and not MAC progress.
      if (state_q == ST_MAC && c_w_req && sum_j_q + cols_eff >= n_q)
        c_rows_done_q <= RowCountW'(sum_i_q) + RowCountW'(1);
      if (state_q == ST_MAC && c_w_req) begin
        c_cols_row_q  <= RowCountW'(sum_i_q);
        c_cols_done_q <= (sum_j_q + cols_eff > n_q) ? n_q : sum_j_q + cols_eff;
      end
      done_q        <= (state_q == ST_DONE);

      // I3: accumulate traffic while job is running
      // W counts data beats (w handshake), not B responses — multi-beat AW safe
      if (state_q != ST_IDLE && state_q != ST_DONE)
        pmu_cy_q <= pmu_cy_q + 32'd1;
      if (state_q != ST_IDLE && state_q != ST_DONE &&
          axi_req_d.r_ready && axi_resp_s.r_valid)
        pmu_r_q <= pmu_r_q + 32'd1;
      // Count W handshakes, not B responses: a multi-beat AW produces one B for
      // many beats, so counting B would understate write traffic in the PMU.
      if (state_q != ST_IDLE && state_q != ST_DONE &&
          axi_req_d.w_valid && axi_resp_s.w_ready)
        pmu_w_q <= pmu_w_q + 32'd1;

      if (state_q == ST_IDLE && start_i) begin
        m_q   <= m_i;
        n_q   <= n_i;
        k_q   <= k_i;
        lda_q <= lda_i;
        ldb_q <= ldb_i;
        ldc_q <= ldc_i;
        numfmt_q <= numfmt_i;
        acc_mode_q <= accumulate_i;
        pa_q  <= ptr_a_i;
        pb_q  <= ptr_b_i;
        pc_q  <= ptr_c_i;
        i_q   <= '0;
        j_q   <= '0;
        t_q   <= '0;
        burst_first_q <= 1'b0;
        ar_inflight_q <= '0;
        ar_i_q <= '0;
        ar_t_q <= '0;
        ar_j_q <= '0;
        for (int unsigned s = 0; s < MaxAROut; s++)
          ar_slot_q[s] <= '0;
        c_pair_hold_q <= 1'b0;
        stc_w_left_q  <= '0;
        stc_elem_q    <= '0;
        stc_i_q  <= '0;
        stc_j_q  <= '0;
        c_rows_done_q <= '0;
        c_cols_row_q <= '0;
        c_cols_done_q <= '0;
        pmu_r_q  <= '0;
        pmu_w_q  <= '0;
        pmu_cy_q <= '0;
      end

      if (state_q == ST_CHK && (state_d == ST_LB || state_d == ST_MAC)) begin
        i_q <= '0;
        j_q <= '0;
        t_q <= '0;
      end
      if (state_q == ST_LA && (state_d == ST_LB || state_d == ST_MAC)) begin
        i_q <= '0;
        j_q <= '0;
        t_q <= '0;
      end
      if (state_q == ST_LB && state_d == ST_MAC) begin
        i_q <= '0;
        j_q <= '0;
        t_q <= '0;
      end

      // A load: advance t by la_n_d (multi-byte unpack)
      if (!SplitArId && state_q == ST_LA && ar_inflight_q != '0 && axi_resp_s.r_valid) begin
        if (axi_resp_s.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
        if (t_q + 32'(la_n_d) >= k_bytes) begin
          t_q <= '0;
          if (i_q + 1 != m_q)
            i_q <= i_q + 1;
          else begin
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
          end
        end else
          t_q <= t_q + 32'(la_n_d);
      end

      // B load: advance t by lb_n_d, then j -- the same shape as the A load
      // above, because AI-X9 made B k-major. There is no held-beat term any
      // more; the oct-drain that needed one is gone.
      if (!SplitArId && state_q == ST_LB && ar_inflight_q != '0 && axi_resp_s.r_valid) begin
        if (axi_resp_s.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR})
          err_q <= 1'b1;
        if (t_q + 32'(lb_n_d) >= k_bytes) begin
          t_q <= '0;
          if (j_q + 1 != n_q)
            j_q <= j_q + 1;
          else begin
            i_q <= '0;
            j_q <= '0;
            t_q <= '0;
          end
        end else
          t_q <= t_q + 32'(lb_n_d);
      end

      // MAC: t_q is reduction base; advance by PeLanes, then (i,j).
      // When last cell finishes, i_q := m (one past end) so trail store sees
      // stc_i < i_q for all rows; j_q stays 0.
      //
      // F0b-2: the accumulator is NOT reset here anymore. Reset is now
      // `sum_first_q` in the next drain, which adds the first partial to 0.
      // Resetting acc_q at the element boundary would clear the running total
      // before the last partial has been drained into it.
      if (state_q == ST_MAC && i_q < m_q) begin
        if (t_q + mac_step >= k_q) begin
          t_q   <= '0;
          if (j_q + cols_eff >= n_q) begin
            j_q <= '0;
            i_q <= i_q + 1;  // becomes m when last row completes
          end else
            j_q <= j_q + cols_eff;
        end else
          t_q <= t_q + mac_step;
      end

      // Store cursor (trail during MAC or dedicated ST_STC)
      if (stc_i_en) stc_i_q <= stc_i_d;
      if (stc_j_en) stc_j_q <= stc_j_d;
      if (SplitArId && axi_resp_s.r_valid && axi_req_d.r_ready && axi_resp_s.r.resp[1])
        err_q <= 1'b1;
    end
  end

  // ST_LC loader state. Idle outside ST_LC so entry always starts clean.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lc_total_q <= '0; lc_beats_q <= '0; lc_issued_q <= '0; lc_recv_q <= '0;
      lc_burst_left_q <= '0; lc_ar_busy_q <= 1'b0; lc_buf_q <= '0; lc_buf_v_q <= 1'b0;
      lc_word_q <= '0; lc_e_q <= '0; lc_i_q <= '0; lc_j_q <= '0;
    end else if (state_q != ST_LC) begin
      lc_total_q <= m_q * n_q;
      lc_beats_q <= (32'((pc_q >> 2) & AddrWidth'(WordsPerBeat - 1)) + m_q * n_q
                     + 32'(WordsPerBeat) - 32'd1) >> LcWordW;
      lc_issued_q <= '0; lc_recv_q <= '0; lc_burst_left_q <= '0; lc_ar_busy_q <= 1'b0;
      lc_buf_q <= '0; lc_buf_v_q <= 1'b0; lc_word_q <= '0;
      lc_e_q <= '0; lc_i_q <= '0; lc_j_q <= '0;
    end else begin
      if (lc_ar_fire) begin
        lc_ar_busy_q    <= 1'b1;
        lc_burst_left_q <= lc_ar_beats;
        lc_issued_q     <= lc_issued_q + 32'(lc_ar_beats);
      end
      if (lc_r_fire) begin
        lc_buf_q   <= axi_resp_s.r.data;
        lc_buf_v_q <= 1'b1;
        // First beat starts at the word lane of ptr_c; later beats at lane 0.
        lc_word_q  <= (lc_recv_q == 32'd0) ? LcWordW'((pc_q >> 2) & AddrWidth'(WordsPerBeat - 1)) : '0;
        lc_recv_q  <= lc_recv_q + 32'd1;
        lc_burst_left_q <= lc_burst_left_q - 8'd1;
        if (lc_burst_left_q == 8'd1 || axi_resp_s.r.last) lc_ar_busy_q <= 1'b0;
      end
      if (lc_w_fire) begin
        lc_e_q <= lc_e_q + 32'd1;
        if (lc_j_q + 32'd1 >= n_q) begin lc_j_q <= '0; lc_i_q <= lc_i_q + 32'd1; end
        else lc_j_q <= lc_j_q + 32'd1;
        if (lc_word_q == LcWordW'(WordsPerBeat - 1) || lc_e_q + 32'd1 >= lc_total_q)
          lc_buf_v_q <= 1'b0;
        else
          lc_word_q <= lc_word_q + LcWordW'(1);
      end else if (lc_buf_v_q && lc_e_q >= lc_total_q) begin
        lc_buf_v_q <= 1'b0;  // trailing pad words of the last beat
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Layer contracts (L3 of the feedback-latency ladder): fire on the cycle of the
  // violation in every simulation -- backend bench, island gates, SoC suite --
  // instead of surfacing as a wrong C word or a stray AXI beat downstream. Each
  // rule is the run-time face of a property proven over the pure functions in
  // corev_apu/ai_island/formal/g6lc_ai_gemm_flat_props.sv. Simulation only.
  // ---------------------------------------------------------------------------
  // pragma translate_off
  always_ff @(posedge clk_i) if (rst_ni) begin
    // C1  Operand bank writes/reads stay inside the panel banks.
    for (int unsigned p = 0; p < PeLanes; p++) begin
      if (a_w_req[p]) assert (32'(a_w_addr[p]) < OperandWordsA)
        else $error("g6lc_ai_gemm_seq C1: A bank write %0d beyond OperandWordsA %0d", a_w_addr[p], OperandWordsA);
      for (int unsigned g = 0; g < OutCols; g++)
        if (b_w_req[g][p]) assert (32'(b_w_addr[g][p]) < OperandWordsBGrp)
          else $error("g6lc_ai_gemm_seq C1: B bank write %0d beyond OperandWordsBGrp %0d", b_w_addr[g][p], OperandWordsBGrp);
      if (a_r_req[p] && state_q == ST_MAC) assert (32'(a_r_addr[p]) < OperandWordsA)
        else $error("g6lc_ai_gemm_seq C1: A bank read %0d beyond OperandWordsA", a_r_addr[p]);
      for (int unsigned g = 0; g < OutCols; g++)
        if (b_r_req[g][p] && state_q == ST_MAC) assert (32'(b_r_addr[g][p]) < OperandWordsBGrp)
          else $error("g6lc_ai_gemm_seq C1: B bank read %0d beyond OperandWordsBGrp", b_r_addr[g][p]);
    end
    // C2  C bank writes stay inside the result bank.
    if (c_w_req) assert (32'(c_w_addr) < BankWords)
      else $error("g6lc_ai_gemm_seq C2: C bank write %0d beyond BankWords %0d", c_w_addr, BankWords);
    // C3  No AXI burst crosses a DRAM channel stripe (N>1 only; N=1 is one channel).
    if (NrChannels > 1 && axi_req_d.ar_valid)
      assert (g6lc_ai_island_cfg_pkg::dram_burst_fits_stripe(NrChannels, ChanShift, 64'(axi_req_d.ar.addr),
                                                   (32'(axi_req_d.ar.len) + 32'd1) << axi_req_d.ar.size))
        else $error("g6lc_ai_gemm_seq C3: AR burst at %h len %0d crosses the %0d B stripe",
                    axi_req_d.ar.addr, axi_req_d.ar.len, 1 << ChanShift);
    if (NrChannels > 1 && axi_req_d.aw_valid)
      assert (g6lc_ai_island_cfg_pkg::dram_burst_fits_stripe(NrChannels, ChanShift, 64'(axi_req_d.aw.addr),
                                                   (32'(axi_req_d.aw.len) + 32'd1) << axi_req_d.aw.size))
        else $error("g6lc_ai_gemm_seq C3: AW burst at %h len %0d crosses the %0d B stripe",
                    axi_req_d.aw.addr, axi_req_d.aw.len, 1 << ChanShift);
    // C4  The trail store never reads a C pair the MAC has not written yet (intra-row
    //     trailing is bounded by the written-column count).
    if (state_q == ST_MAC && c_r0_req && !acc_mode_q && !(stc_i_q < 32'(c_rows_done_q)))
      assert (32'(c_cols_row_q) == stc_i_q && 32'(c_r0_addr) <= c_bank_addr(stc_i_q, c_cols_done_q - 32'd1))
        else $error("g6lc_ai_gemm_seq C4: trail store reads C row %0d word %0d beyond %0d written columns",
                    stc_i_q, c_r0_addr, c_cols_done_q);
  end
  // pragma translate_on

endmodule
