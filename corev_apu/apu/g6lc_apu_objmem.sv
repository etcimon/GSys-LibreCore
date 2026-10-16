// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Object memory (§5a G3b-i): the device-private DRAM backing for
// ObjTab-V and ObjPay-V, behind one APU_MP_OBJ apu_mp requester.
//
// The carve lives in the SHM aperture above the vgpages-managed
// window (geometry from g6lc_apu_objtab_pkg):
//   entries  ObjEntries x 64 B   @ APU_OBJMEM_OFF
//   dir      2*ObjEntries x 8 B  @ apu_objmem_dir_off()
//   stack    ObjEntries x 2 B    @ apu_objmem_stk_off()
//   magic    2 x 8 B             @ stack end (pattern + epoch)
//   paymem   PayMemBytes         @ apu_objmem_pay_off() (64 KiB align)
//
// On-chip state (payload SRAMs via tc_sram):
//   - directory cache: DirCacheSets x 4 ways of {valid,id[63:0],
//     entry[15:0]}, set = low bits of the Fibonacci hash of the id.
//     Lookup accelerator only — a hit is still verified against the
//     entry record (RT-P2: identity precedes correlation).
//   - entry cache: EntCacheLines x 64 B lines, write-back, per-line
//     dirty in flop tags, round-robin victim.  A full-line write
//     allocates without a fill.
//   - payload cache: PayCacheLines x 64 B lines, write-back.
//   - free-stack top: 32 entry indices in flops over a DRAM stack,
//     plus a `bump` watermark that mints never-written entries
//     (gen 0, no DRAM read).  The DRAM stack is abandoned at reset —
//     reset empties the whole table anyway.
//
// Epoch (reset semantics): the table is EMPTY after every reset —
// the old SRAM ObjTab re-zeroed all slots on rst_ni; this one does
// the same lazily: the magic pair at the stack end stores
// {pattern, epoch[31:0]}; each reset reads the pair, bumps and
// writes the epoch (3 beats), and every directory row and entry
// record is valid only for its epoch.  Bucket rows carry epoch[2:0]
// in spare tag bits; a row whose epoch differs from the current one
// is rewritten as a tombstone on sight (probing continues — it may
// sit mid-chain).  Entry records carry the full 32-bit epoch in
// w15; the entry verify requires an epoch match, so an 8-reset-old
// bucket that aliases the 3-bit epoch still dies at the entry
// check.  Cold boot (magic pattern absent) runs the one-time dir
// zero sweep, then publishes epoch 1.
//
// Directory semantics identical to the SRAM ObjTab: valid/tomb
// rows, Fibonacci hash, linear probe; cap widened 8 -> 32.  A row
// whose 42-bit tag matches but whose entry is dead, re-idd or
// epoch-stale is lazily tombstoned and probing continues.
//
// Write-back ordering (§5a "Ordering and lifetime"): all readers go
// through these caches, so coherence holds without flushes; the
// documented write-back *points* still exist as client ops —
// APU_OMT_EWB (RETIRE), APU_OMT_FLUSH (RESET_CTX) — for the direct-
// DRAM readers G3b-ii adds.
//
// Timing impact: client ops are multi-cycle by design (DRAM
// latency); the widest cones are the 4-way dir-cache compare, the
// line-tag OR-match and the probe-tag compare.  The mp port is one
// requester: at most one beat outstanding, round-robin between the
// two service FSMs.
//
// Review checklist: async active-low reset; no latches; two service
// FSMs + one beat arbiter; SRAMs behind tc_sram; Enable=0
// elaborates no datapath; one rsp per client request.

module g6lc_apu_objmem
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_mp_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ObjEntries    = 65536,
  parameter int unsigned PayMemBytes   = 16 * 1024 * 1024,
  parameter int unsigned DirCacheSets  = 256,
  parameter int unsigned EntCacheLines = 64,
  parameter int unsigned PayCacheLines = 32
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  logic          testmode_i,
  input  logic          omt_req_valid_i,
  output logic          omt_req_ready_o,
  input  apu_omt_req_t  omt_req_i,
  output logic          omt_rsp_valid_o,
  output apu_omt_rsp_t  omt_rsp_o,
  input  logic          omp_req_valid_i,
  output logic          omp_req_ready_o,
  input  apu_omp_req_t  omp_req_i,
  output logic          omp_rsp_valid_o,
  output apu_omp_rsp_t  omp_rsp_o,
  output logic          mp_req_valid_o,
  input  logic          mp_req_ready_i,
  output apu_mp_req_t   mp_req_o,
  input  logic          mp_rsp_valid_i,
  input  apu_mp_rsp_t   mp_rsp_i
);
  if (!Enable) begin : gen_off
    assign omt_req_ready_o = 1'b0;
    assign omt_rsp_valid_o = 1'b0;
    assign omt_rsp_o       = '0;
    assign omp_req_ready_o = 1'b0;
    assign omp_rsp_valid_o = 1'b0;
    assign omp_rsp_o       = '0;
    assign mp_req_valid_o  = 1'b0;
    assign mp_req_o        = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | omt_req_valid_i |
                    omp_req_valid_i | mp_req_ready_i | mp_rsp_valid_i |
                    (|omt_req_i) | (|omp_req_i) | (|mp_rsp_i);
  end else begin : gen_on
    localparam int unsigned EntBits    = $clog2(ObjEntries);
    localparam int unsigned DirBuckets = 2 * ObjEntries;
    localparam int unsigned DirBits    = $clog2(DirBuckets);
    localparam int unsigned DcSetBits  = $clog2(DirCacheSets);
    localparam int unsigned EcIdxBits  = $clog2(EntCacheLines);
    localparam int unsigned PcIdxBits  = $clog2(PayCacheLines);
    localparam int unsigned PcLnBits   = $clog2(PayMemBytes / 64);
    localparam int unsigned FskDepth   = 32;

    localparam logic [63:0] ENT_OFF = APU_OBJMEM_OFF;
    localparam logic [63:0] DIR_OFF = apu_objmem_dir_off(ObjEntries);
    localparam logic [63:0] STK_OFF = apu_objmem_stk_off(ObjEntries);
    localparam logic [63:0] MAG_OFF = STK_OFF + 64'(ObjEntries) * 2;
    localparam logic [63:0] PAY_OFF = apu_objmem_pay_off(ObjEntries);
    localparam logic [63:0] MAG_PAT = 64'h6F62_6A5F_6D65_6D21; // "obj_mem!"

    function automatic logic [DirBits-1:0] dir_hash(logic [63:0] id);
      return DirBits'((id * 64'h9E37_79B9_7F4A_7C15) >>
                      (64 - DirBits));
    endfunction
    function automatic logic [DcSetBits-1:0] dc_hash(logic [63:0] id);
      return DcSetBits'((id * 64'h9E37_79B9_7F4A_7C15) >>
                        (64 - DcSetBits));
    endfunction

    // ---- cache state -----------------------------------------------------
    logic [15:0] ec_tag_q [EntCacheLines];
    logic        ec_vld_q [EntCacheLines];
    logic        ec_dty_q [EntCacheLines];
    logic [EcIdxBits-1:0] ec_rr_q;
    logic [PcLnBits-1:0] pc_ln_q [PayCacheLines];
    logic        pc_vld_q [PayCacheLines];
    logic        pc_dty_q [PayCacheLines];
    logic [PcIdxBits-1:0] pc_rr_q;
    logic [63:0] dc_id_q [DirCacheSets][4];
    logic [15:0] dc_en_q [DirCacheSets][4];
    logic        dc_vl_q [DirCacheSets][4];
    logic [1:0]  dc_rr_q [DirCacheSets];

    logic                 ec_req, ec_we;
    logic [EcIdxBits-1:0] ec_addr;
    logic [511:0]         ec_wdata, ec_rdata;
    logic                 pc_req, pc_we;
    logic [PcIdxBits-1:0] pc_addr;
    logic [511:0]         pc_wdata, pc_rdata;

    tc_sram #(.NumWords(EntCacheLines), .DataWidth(512), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_ec (
      .clk_i, .rst_ni, .req_i(ec_req), .we_i(ec_we), .addr_i(ec_addr),
      .wdata_i(ec_wdata), .be_i('1), .rdata_o(ec_rdata));
    tc_sram #(.NumWords(PayCacheLines), .DataWidth(512), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_pc (
      .clk_i, .rst_ni, .req_i(pc_req), .we_i(pc_we), .addr_i(pc_addr),
      .wdata_i(pc_wdata), .be_i('1), .rdata_o(pc_rdata));

    // entry-index under test
    logic [15:0]          eg_idx_q;
    logic                 ec_hit;
    logic [EcIdxBits-1:0] ec_hitway;
    always_comb begin
      ec_hit    = 1'b0;
      ec_hitway = '0;
      for (int i = 0; i < EntCacheLines; i++)
        if (ec_vld_q[i] && ec_tag_q[i] == eg_idx_q) begin
          ec_hit    = 1'b1;
          ec_hitway = EcIdxBits'(i);
        end
    end
    logic [PcLnBits-1:0]  pc_qline;
    logic                 pc_hit;
    logic [PcIdxBits-1:0] pc_hitway;
    always_comb begin
      pc_hit    = 1'b0;
      pc_hitway = '0;
      for (int i = 0; i < PayCacheLines; i++)
        if (pc_vld_q[i] && pc_ln_q[i] == pc_qline) begin
          pc_hit    = 1'b1;
          pc_hitway = PcIdxBits'(i);
        end
    end
    // ---- mp arbiter -----------------------------------------------------
    // One outstanding beat total; grants alternate on ties.
    logic        ot_mp_v, op_mp_v;
    apu_mp_req_t ot_mp_req, op_mp_req;
    logic        mp_busy_q, mp_ot_own_q, mp_rr_q;
    wire         mp_grt_ot = ot_mp_v && (!op_mp_v || mp_rr_q);
    assign mp_req_valid_o = mp_busy_q ? 1'b0 : (ot_mp_v | op_mp_v);
    assign mp_req_o       = mp_grt_ot ? ot_mp_req : op_mp_req;
    wire mp_acc     = mp_req_valid_o && mp_req_ready_i;
    wire ot_mp_done = mp_rsp_valid_i &&  mp_ot_own_q;
    wire op_mp_done = mp_rsp_valid_i && !mp_ot_own_q;

    // ---- ot engine -------------------------------------------------------
    typedef enum logic [5:0] {
      OT_INIT_RD, OT_INIT_RD2, OT_INIT_SW, OT_INIT_MW,
      OT_IDLE, OT_RSP,
      OT_FP_DC, OT_FP_VER,
      OT_PR_RD, OT_PR_VER, OT_PR_TOMB,
      OT_DWR,
      OT_EG_LK, OT_EG_HRD, OT_EG_HRDC,
      OT_EG_VIC, OT_EG_VICR, OT_EG_WB,
      OT_EG_FILL, OT_EG_FST, OT_EG_WR, OT_EG_HAVE,
      OT_EWB_LK, OT_EWB_RD, OT_EWB_RDC, OT_EWB_WB,
      OT_FL_LK, OT_FL_RD, OT_FL_RDC, OT_FL_WB,
      OT_POP_RD, OT_POP_FILL,
      OT_PUSH_W
    } ot_state_e;

    ot_state_e      ot_q, eg_ret_q;
    apu_omt_req_t   ot_req_q;
    apu_omt_rsp_t   ot_rsp_q;
    logic [DirBits-1:0] pr_base_q;
    logic [5:0]         pr_i_q;
    logic [DirBits-1:0] pr_tomb_q;
    logic               pr_tomb_v_q;
    logic [1:0]         pr_mode_q;   // 0=find 1=claim 2=dtomb
    logic [DirBits-1:0] pr_bk_q;
    logic [EcIdxBits-1:0] eg_way_q, eg_vic_q;
    logic [2:0]           eg_beat_q;
    logic [511:0]         eg_line_q;   // working line / fill buffer
    logic [511:0]         wb_line_q;   // victim write-back buffer
    logic                 eg_wr_q;
    logic [15:0]      fsk_q [FskDepth];
    logic [5:0]       fsk_n_q;
    logic [EntBits-1:0] stk_sp_q;
    logic [EntBits:0]   bump_q;
    logic [63:0]        ref_word_q;
    logic [1:0]         ref_hi_q;
    logic [DirBits:0]   init_q;
    logic [31:0]        epoch_q;

    // dir cache probe of the request id
    wire  [DcSetBits-1:0] dc_qset = dc_hash(ot_req_q.id);
    logic                 dc_hit;
    logic [1:0]           dc_hitway;
    always_comb begin
      dc_hit    = 1'b0;
      dc_hitway = '0;
      for (int w = 0; w < 4; w++)
        if (dc_vl_q[dc_qset][w] &&
            dc_id_q[dc_qset][w] == ot_req_q.id) begin
          dc_hit    = 1'b1;
          dc_hitway = 2'(w);
        end
    end

    // bucket read fields: {v[63], t[62], ep[61:59], pad[58],
    //                      tag[57:16], en[15:0]}
    wire [63:0] mp_rdata_w = mp_rsp_i.rdata;
    wire        bk_v    = mp_rdata_w[63];
    wire        bk_t    = mp_rdata_w[62];
    wire        bk_ep   = mp_rdata_w[61:59] != epoch_q[2:0];
    wire [41:0] bk_tag  = mp_rdata_w[57:16];
    wire [15:0] bk_en   = mp_rdata_w[15:0];

    function automatic logic [63:0] dir_row(logic t, logic [63:0] id,
                                            logic [15:0] en);
      return {1'b1, t, epoch_q[2:0], 1'b0, id[41:0], en};
    endfunction

    // line under test after a get/fill (epoch + id verify)
    wire apu_objent_mem_t eg_rec  = apu_objent_mem_t'(eg_line_q);
    wire eg_rec_ok  = eg_line_q[0] && (eg_rec.epoch == epoch_q) &&
                      (eg_rec.id == ot_req_q.id);
    // ERD masks the epoch so a stale entry reads dead
    wire apu_objent_mem_t erd_rec = apu_objent_mem_t'(
        {eg_line_q[511:1], eg_line_q[0] & (eg_rec.epoch == epoch_q)});

    // ---- op engine (ObjPay payload cache) --------------------------------
    typedef enum logic [3:0] {
      OP_IDLE, OP_LK, OP_HRD, OP_HRDC, OP_HWR, OP_RSP,
      OP_VIC, OP_VICR, OP_WB, OP_FILL, OP_FST
    } op_state_e;
    op_state_e      op_q;
    apu_omp_req_t   op_req_q;
    apu_omp_rsp_t   op_rsp_q;
    logic [PcIdxBits-1:0] op_way_q;
    logic [2:0]         op_beat_q;
    logic [511:0]       op_line_q;
    logic [511:0]       wb2_line_q;

    // line-level client port: we=1 writes the whole 512-bit line (no
    // merge — ObjPay owns word packing); we=0 reads the line.  dir=0
    // is reserved (no client) and answers err rather than aliasing a
    // region.

    assign omt_req_ready_o = ot_q == OT_IDLE;
    assign omp_req_ready_o = op_q == OP_IDLE;
    assign omt_rsp_valid_o = ot_q == OT_RSP;
    assign omt_rsp_o       = ot_rsp_q;
    assign omp_rsp_valid_o = op_q == OP_RSP;
    assign omp_rsp_o       = op_rsp_q;

    // ---------------------------------------------------------------------
    // combinational SRAM/mp steering
    // ---------------------------------------------------------------------
    always_comb begin
      ot_mp_v = 1'b0; ot_mp_req = '0;
      ec_req = 1'b0; ec_we = 1'b0; ec_addr = '0;
      ec_wdata = {epoch_q, eg_line_q[479:0]};   // stamp epoch on writes
      unique case (ot_q)
        OT_INIT_RD, OT_INIT_RD2: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b0,
                        addr: MAG_OFF +
                              (ot_q == OT_INIT_RD2 ? 64'd8 : 64'd0),
                        wdata: '0, wstrb: '0};
        end
        OT_INIT_SW: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b1,
                        addr: DIR_OFF + 64'(init_q[DirBits-1:0]) * 8,
                        wdata: '0, wstrb: 8'hFF};
        end
        OT_INIT_MW: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b1,
                        addr: MAG_OFF + 64'(init_q[0]) * 8,
                        wdata: init_q[0] ? 64'(epoch_q) : MAG_PAT,
                        wstrb: 8'hFF};
        end
        OT_PR_RD: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b0,
                        addr: DIR_OFF + 64'(pr_bk_q) * 8,
                        wdata: '0, wstrb: '0};
        end
        OT_PR_TOMB: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b1,
                        addr: DIR_OFF + 64'(pr_bk_q) * 8,
                        wdata: dir_row(1'b1, ot_req_q.id, 16'h0),
                        wstrb: 8'hFF};
        end
        OT_DWR: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b1,
                        addr: DIR_OFF + 64'(ot_req_q.bucket
                                            [DirBits-1:0]) * 8,
                        wdata: dir_row(1'b0, ot_req_q.id,
                                       ot_req_q.entry),
                        wstrb: 8'hFF};
        end
        OT_EG_HRD, OT_EG_VIC, OT_EWB_RD, OT_FL_RD: begin
          ec_req  = 1'b1;
          ec_addr = ot_q == OT_EG_VIC ? eg_vic_q : eg_way_q;
        end
        OT_EG_WB, OT_EWB_WB, OT_FL_WB: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b1,
                        addr: ENT_OFF +
                              64'(ec_tag_q[ot_q == OT_EG_WB ? eg_vic_q
                                                           : eg_way_q])
                              * 64 + eg_beat_q * 8,
                        wdata: (ot_q == OT_EG_WB ? wb_line_q[eg_beat_q*64 +: 64] :
                                eg_line_q[eg_beat_q*64 +: 64]),
                        wstrb: 8'hFF};
        end
        OT_EG_FILL: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b0,
                        addr: ENT_OFF + 64'(eg_idx_q) * 64 +
                              eg_beat_q * 8,
                        wdata: '0, wstrb: '0};
        end
        OT_EG_WR: begin
          ec_req  = 1'b1;
          ec_we   = 1'b1;
          ec_addr = eg_way_q;
        end
        OT_EG_FST: begin
          // commit the DRAM-filled line verbatim (it already carries
          // its stamped epoch) into the installed row
          ec_req   = 1'b1;
          ec_we    = 1'b1;
          ec_addr  = eg_way_q;
          ec_wdata = eg_line_q;
        end
        OT_PUSH_W: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b1,
                        addr: STK_OFF +
                              ((64'(stk_sp_q) * 2) & ~64'h7),
                        wdata: 64'(ot_req_q.entry) <<
                                (stk_sp_q[1:0] * 16),
                        wstrb: 8'h3 << (stk_sp_q[1:0] * 2)};
        end
        OT_POP_RD: begin
          ot_mp_v = 1'b1;
          ot_mp_req = '{dom: 1'b1, we: 1'b0,
                        addr: STK_OFF +
                              (((64'(stk_sp_q) - 1) * 2) & ~64'h7),
                        wdata: '0, wstrb: '0};
        end
        default: ;
      endcase

      op_mp_v = 1'b0; op_mp_req = '0;
      pc_req = 1'b0; pc_we = 1'b0; pc_addr = '0; pc_wdata = '0;
      unique case (op_q)
        OP_HRD, OP_VIC: begin
          pc_req  = 1'b1;
          pc_addr = op_way_q;
        end
        OP_HWR: begin
          pc_req   = 1'b1;
          pc_we    = 1'b1;
          pc_addr  = op_way_q;
          pc_wdata = op_req_q.wdata;
        end
        OP_WB: begin
          op_mp_v = 1'b1;
          op_mp_req = '{dom: 1'b1, we: 1'b1,
                        addr: PAY_OFF + 64'(pc_ln_q[op_way_q]) * 64 +
                              op_beat_q * 8,
                        wdata: wb2_line_q[op_beat_q*64 +: 64],
                        wstrb: 8'hFF};
        end
        OP_FILL: begin
          op_mp_v = 1'b1;
          op_mp_req = '{dom: 1'b1, we: 1'b0,
                        addr: PAY_OFF +
                              64'(pc_qline) * 64 + op_beat_q * 8,
                        wdata: '0, wstrb: '0};
        end
        OP_FST: begin
          // commit the filled line into the victim row so later hits
          // return this line, not the evicted victim's data
          pc_req   = 1'b1;
          pc_we    = 1'b1;
          pc_addr  = op_way_q;
          pc_wdata = op_line_q;
        end
        default: ;
      endcase
    end

    // ---------------------------------------------------------------------
    // sequential
    // ---------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ot_q <= OT_INIT_RD; eg_ret_q <= OT_IDLE;
        ot_req_q <= '0; ot_rsp_q <= '0;
        pr_base_q <= '0; pr_i_q <= '0; pr_tomb_q <= '0;
        pr_tomb_v_q <= 1'b0; pr_mode_q <= '0; pr_bk_q <= '0;
        eg_idx_q <= '0; eg_way_q <= '0; eg_vic_q <= '0;
        eg_beat_q <= '0; eg_line_q <= '0; wb_line_q <= '0;
        wb2_line_q <= '0; eg_wr_q <= 1'b0;
        fsk_n_q <= '0; stk_sp_q <= '0; bump_q <= '0;
        ref_word_q <= '0; ref_hi_q <= '0;
        init_q <= '0; epoch_q <= '0;
        ec_rr_q <= '0; pc_rr_q <= '0;
        mp_busy_q <= 1'b0; mp_ot_own_q <= 1'b0; mp_rr_q <= 1'b0;
        op_q <= OP_IDLE; op_req_q <= '0; op_rsp_q <= '0;
        op_way_q <= '0; op_beat_q <= '0; op_line_q <= '0;
        pc_qline <= '0;
        for (int i = 0; i < EntCacheLines; i++) begin
          ec_tag_q[i] <= '0; ec_vld_q[i] <= 1'b0; ec_dty_q[i] <= 1'b0;
        end
        for (int i = 0; i < PayCacheLines; i++) begin
          pc_ln_q[i] <= '0; pc_vld_q[i] <= 1'b0; pc_dty_q[i] <= 1'b0;
        end
        for (int s = 0; s < DirCacheSets; s++) dc_rr_q[s] = '0;
        for (int i = 0; i < DirCacheSets * 4; i++) begin
          dc_vl_q[i / 4][i % 4] = 1'b0;
          dc_id_q[i / 4][i % 4] = '0;
          dc_en_q[i / 4][i % 4] = '0;
        end
        for (int i = 0; i < FskDepth; i++) fsk_q[i] <= '0;
      end else begin
        if (mp_acc) begin
          mp_busy_q   <= 1'b1;
          mp_ot_own_q <= mp_grt_ot;
          mp_rr_q     <= ~mp_rr_q;
        end
        if (mp_rsp_valid_i) mp_busy_q <= 1'b0;

        // ================= ot engine =================================
        unique case (ot_q)
        // ---- epoch handshake / one-time dir zero -------------------
        OT_INIT_RD: if (ot_mp_done) begin
          if (mp_rdata_w == MAG_PAT) ot_q <= OT_INIT_RD2;
          else begin
            init_q <= '0;
            ot_q   <= OT_INIT_SW;
          end
        end
        OT_INIT_RD2: if (ot_mp_done) begin
          epoch_q <= mp_rdata_w[31:0] + 32'd1;
          init_q  <= '0;
          ot_q    <= OT_INIT_MW;
        end
        OT_INIT_SW: if (ot_mp_done) begin
          if (init_q == DirBits'(DirBuckets - 1)) begin
            epoch_q <= 32'd1;
            init_q  <= '0;
            ot_q    <= OT_INIT_MW;
          end else begin
            init_q <= init_q + 1'b1;
          end
        end
        OT_INIT_MW: if (ot_mp_done) begin
          if (init_q[0]) ot_q <= OT_IDLE;
          else           init_q <= init_q + 1'b1;
        end

        // ---- request accept -------------------------------------------
        OT_IDLE: if (omt_req_valid_i) begin
          ot_req_q <= omt_req_i;
          unique case (omt_req_i.op)
            APU_OMT_FIND: begin
              pr_base_q   <= dir_hash(omt_req_i.id);
              pr_i_q      <= '0;
              pr_tomb_v_q <= 1'b0;
              pr_mode_q   <= 2'd0;
              ot_q        <= OT_FP_DC;
            end
            APU_OMT_CLAIM, APU_OMT_DTOMB: begin
              pr_base_q   <= dir_hash(omt_req_i.id);
              pr_i_q      <= '0;
              pr_tomb_v_q <= 1'b0;
              pr_mode_q   <= omt_req_i.op == APU_OMT_CLAIM ? 2'd1
                                                          : 2'd2;
              pr_bk_q     <= dir_hash(omt_req_i.id);
              ot_q        <= OT_PR_RD;
            end
            APU_OMT_DWR: ot_q <= OT_DWR;
            APU_OMT_ERD, APU_OMT_EWR: begin
              eg_idx_q  <= omt_req_i.entry;
              eg_line_q <= omt_req_i.rec;
              eg_wr_q   <= omt_req_i.op == APU_OMT_EWR;
              eg_ret_q  <= OT_RSP;
              ot_q      <= OT_EG_LK;
            end
            APU_OMT_EWB: begin
              eg_idx_q <= omt_req_i.entry;
              ot_q     <= OT_EWB_LK;
            end
            APU_OMT_FLUSH: begin
              eg_way_q <= '0;
              ot_q     <= OT_FL_LK;
            end
            APU_OMT_POP: begin
              if (fsk_n_q != 6'd0) begin
                fsk_n_q  <= fsk_n_q - 6'd1;
                ot_rsp_q <= '{status: APU_OMT_OK,
                              entry: fsk_q[5'(fsk_n_q - 6'd1)],
                              bucket: '0, rec: '0, fresh: 1'b0};
                ot_q     <= OT_RSP;
              end else if (stk_sp_q != '0) begin
                ot_q <= OT_POP_RD;
              end else if (bump_q < (EntBits+1)'(ObjEntries)) begin
                ot_rsp_q <= '{status: APU_OMT_OK,
                              entry: EntBits'(bump_q),
                              bucket: '0, rec: '0, fresh: 1'b1};
                bump_q   <= bump_q + 1'b1;
                ot_q     <= OT_RSP;
              end else begin
                ot_rsp_q <= '{status: APU_OMT_FULL, entry: '0,
                              bucket: '0, rec: '0, fresh: 1'b0};
                ot_q     <= OT_RSP;
              end
            end
            APU_OMT_PUSH: begin
              if (fsk_n_q < 6'(FskDepth)) begin
                fsk_q[fsk_n_q[4:0]] <= omt_req_i.entry;
                fsk_n_q  <= fsk_n_q + 6'd1;
                ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                              bucket: '0, rec: '0, fresh: 1'b0};
                ot_q     <= OT_RSP;
              end else begin
                ot_q <= OT_PUSH_W;
              end
            end
            default: begin
              ot_rsp_q <= '{status: APU_OMT_ERR, entry: '0,
                            bucket: '0, rec: '0, fresh: 1'b0};
              ot_q     <= OT_RSP;
            end
          endcase
        end

        // ---- FIND dir-cache fast path ----------------------------------
        OT_FP_DC: begin
          if (dc_hit) begin
            eg_idx_q <= dc_en_q[dc_qset][dc_hitway];
            eg_wr_q  <= 1'b0;
            eg_ret_q <= OT_FP_VER;
            ot_q     <= OT_EG_LK;
          end else begin
            pr_bk_q <= pr_base_q;
            ot_q    <= OT_PR_RD;
          end
        end
        OT_FP_VER: begin
          if (eg_rec_ok) begin
            ot_rsp_q <= '{status: APU_OMT_OK, entry: eg_idx_q,
                          bucket: '0, rec: eg_rec, fresh: 1'b0};
            ot_q     <= OT_RSP;
          end else begin
            dc_vl_q[dc_qset][dc_hitway] <= 1'b0;
            pr_bk_q <= pr_base_q;
            ot_q    <= OT_PR_RD;
          end
        end

        // ---- directory probe --------------------------------------------
        OT_PR_RD: if (ot_mp_done) begin
          if (!bk_v) begin
            // never-used bucket: probe ends
            unique case (pr_mode_q)
              2'd1:    ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                                     bucket: 32'(pr_tomb_v_q ?
                                                 pr_tomb_q : pr_bk_q),
                                     rec: '0, fresh: 1'b0};
              2'd2:    ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                                     bucket: '0, rec: '0, fresh: 1'b0};
              default: ot_rsp_q <= '{status: APU_OMT_MISS, entry: '0,
                                     bucket: 32'(pr_bk_q), rec: '0, fresh: 1'b0};
            endcase
            ot_q <= OT_RSP;
          end else if (!bk_t && !bk_ep &&
                       bk_tag == ot_req_q.id[41:0]) begin
            // candidate live row: verify through the entry cache
            eg_idx_q <= bk_en;
            eg_wr_q  <= 1'b0;
            eg_ret_q <= OT_PR_VER;
            ot_q     <= OT_EG_LK;
          end else if (bk_t && !bk_ep) begin
            // current-epoch tombstone: claimable, keep probing
            if (!pr_tomb_v_q) begin
              pr_tomb_v_q <= 1'b1;
              pr_tomb_q   <= pr_bk_q;
            end
            if (pr_i_q == 6'd31) begin
              unique case (pr_mode_q)
                2'd1:    ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                                       bucket: 32'(pr_tomb_v_q ?
                                                   pr_tomb_q : pr_bk_q),
                                       rec: '0, fresh: 1'b0};
                2'd2:    ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                                       bucket: '0, rec: '0, fresh: 1'b0};
                default: ot_rsp_q <= '{status: APU_OMT_MISS, entry: '0,
                                       bucket: 32'(pr_bk_q), rec: '0, fresh: 1'b0};
              endcase
              ot_q <= OT_RSP;
            end else begin
              pr_i_q  <= pr_i_q + 6'd1;
              pr_bk_q <= pr_base_q + DirBits'(pr_i_q + 6'd1);
              ot_q    <= OT_PR_RD;
            end
          end else if (bk_ep) begin
            // stale-epoch row: claimable, rewritten as a current tomb
            if (!pr_tomb_v_q) begin
              pr_tomb_v_q <= 1'b1;
              pr_tomb_q   <= pr_bk_q;
            end
            ot_q <= OT_PR_TOMB;
          end else begin
            // foreign live row (tag mismatch): skip
            if (pr_i_q == 6'd31) begin
              unique case (pr_mode_q)
                2'd1:    ot_rsp_q <= '{status: pr_tomb_v_q ?
                                             APU_OMT_OK : APU_OMT_FULL,
                                       entry: '0,
                                       bucket: 32'(pr_tomb_v_q ?
                                                   pr_tomb_q : '0),
                                       rec: '0, fresh: 1'b0};
                2'd2:    ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                                       bucket: '0, rec: '0, fresh: 1'b0};
                default: ot_rsp_q <= '{status: APU_OMT_MISS, entry: '0,
                                       bucket: 32'(pr_bk_q), rec: '0, fresh: 1'b0};
              endcase
              ot_q <= OT_RSP;
            end else begin
              pr_i_q  <= pr_i_q + 6'd1;
              pr_bk_q <= pr_base_q + DirBits'(pr_i_q + 6'd1);
              ot_q    <= OT_PR_RD;
            end
          end
        end
        OT_PR_VER: begin
          if (eg_rec_ok) begin
            unique case (pr_mode_q)
              2'd1: begin
                ot_rsp_q <= '{status: APU_OMT_DUP, entry: eg_idx_q,
                              bucket: 32'(pr_bk_q), rec: eg_rec, fresh: 1'b0};
                ot_q     <= OT_RSP;
              end
              2'd2: ot_q <= OT_PR_TOMB;
              default: begin
                if (!dc_hit) begin
                  dc_vl_q[dc_qset][dc_rr_q[dc_qset]] <= 1'b1;
                  dc_id_q[dc_qset][dc_rr_q[dc_qset]] <= ot_req_q.id;
                  dc_en_q[dc_qset][dc_rr_q[dc_qset]] <= eg_idx_q;
                  dc_rr_q[dc_qset] <= dc_rr_q[dc_qset] + 2'd1;
                end
                ot_rsp_q <= '{status: APU_OMT_OK, entry: eg_idx_q,
                              bucket: 32'(pr_bk_q), rec: eg_rec, fresh: 1'b0};
                ot_q     <= OT_RSP;
              end
            endcase
          end else begin
            // dead, re-idd or epoch-stale row: tombstone, keep probing
            if (!pr_tomb_v_q) begin
              pr_tomb_v_q <= 1'b1;
              pr_tomb_q   <= pr_bk_q;
            end
            if (dc_hit) dc_vl_q[dc_qset][dc_hitway] <= 1'b0;
            ot_q <= OT_PR_TOMB;
          end
        end
        OT_PR_TOMB: if (ot_mp_done) begin
          if (pr_mode_q == 2'd2) begin
            if (dc_hit) dc_vl_q[dc_qset][dc_hitway] <= 1'b0;
            ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                          bucket: '0, rec: '0, fresh: 1'b0};
            ot_q     <= OT_RSP;
          end else if (pr_i_q == 6'd31) begin
            unique case (pr_mode_q)
              2'd1:    ot_rsp_q <= '{status: pr_tomb_v_q ? APU_OMT_OK
                                                        : APU_OMT_FULL,
                                     entry: '0,
                                     bucket: 32'(pr_tomb_v_q ?
                                                 pr_tomb_q : '0),
                                     rec: '0, fresh: 1'b0};
              default: ot_rsp_q <= '{status: APU_OMT_MISS, entry: '0,
                                     bucket: 32'(pr_bk_q), rec: '0, fresh: 1'b0};
            endcase
            ot_q <= OT_RSP;
          end else begin
            pr_i_q  <= pr_i_q + 6'd1;
            pr_bk_q <= pr_base_q + DirBits'(pr_i_q + 6'd1);
            ot_q    <= OT_PR_RD;
          end
        end

        // ---- directory row write -----------------------------------------
        OT_DWR: if (ot_mp_done) begin
          if (dc_hit) dc_vl_q[dc_qset][dc_hitway] <= 1'b0;
          dc_vl_q[dc_qset][dc_rr_q[dc_qset]] <= 1'b1;
          dc_id_q[dc_qset][dc_rr_q[dc_qset]] <= ot_req_q.id;
          dc_en_q[dc_qset][dc_rr_q[dc_qset]] <= ot_req_q.entry;
          dc_rr_q[dc_qset] <= dc_rr_q[dc_qset] + 2'd1;
          ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                        bucket: '0, rec: '0, fresh: 1'b0};
          ot_q     <= OT_RSP;
        end

        // ---- entry get / write --------------------------------------------
        OT_EG_LK: begin
          if (ec_hit) begin
            eg_way_q <= ec_hitway;
            if (eg_wr_q) begin
              ec_dty_q[ec_hitway] <= 1'b1;
              ot_q <= OT_EG_WR;
            end else begin
              ot_q <= OT_EG_HRD;
            end
          end else begin
            eg_vic_q <= ec_rr_q;
            ec_rr_q  <= ec_rr_q + 1'b1;
            if (ec_vld_q[ec_rr_q] && ec_dty_q[ec_rr_q]) begin
              ot_q <= OT_EG_VIC;
            end else begin
              ec_vld_q[ec_rr_q] <= 1'b1;
              ec_tag_q[ec_rr_q] <= eg_idx_q;
              ec_dty_q[ec_rr_q] <= eg_wr_q;
              eg_way_q <= ec_rr_q;
              if (eg_wr_q) begin
                ot_q <= OT_EG_WR;       // full-line write, no fill
              end else begin
                eg_beat_q <= '0;
                ot_q      <= OT_EG_FILL;
              end
            end
          end
        end
        OT_EG_HRD:  ot_q <= OT_EG_HRDC; // read issued; rdata next cycle
        OT_EG_HRDC: begin
          eg_line_q <= ec_rdata;
          ot_q      <= eg_ret_q == OT_RSP ? OT_EG_HAVE : eg_ret_q;
        end
        OT_EG_VIC:  ot_q <= OT_EG_VICR;
        OT_EG_VICR: begin
          wb_line_q <= ec_rdata;
          eg_beat_q <= '0;
          ot_q      <= OT_EG_WB;
        end
        OT_EG_WB: if (ot_mp_done) begin
          if (eg_beat_q == 3'd7) begin
            ec_dty_q[eg_vic_q] <= eg_wr_q;
            ec_vld_q[eg_vic_q] <= 1'b1;
            ec_tag_q[eg_vic_q] <= eg_idx_q;
            eg_way_q  <= eg_vic_q;
            eg_beat_q <= '0;
            ot_q      <= eg_wr_q ? OT_EG_WR : OT_EG_FILL;
          end else begin
            eg_beat_q <= eg_beat_q + 3'd1;
          end
        end
        OT_EG_FILL: if (ot_mp_done) begin
          eg_line_q[eg_beat_q*64 +: 64] <= mp_rdata_w;
          if (eg_beat_q == 3'd7) begin
            eg_beat_q <= '0;
            ot_q      <= OT_EG_FST;
          end else begin
            eg_beat_q <= eg_beat_q + 3'd1;
          end
        end
        OT_EG_FST: ot_q <= eg_ret_q == OT_RSP ? OT_EG_HAVE : eg_ret_q;
        OT_EG_WR: ot_q <= OT_EG_HAVE;   // line store issued
        OT_EG_HAVE: begin
          if (ot_req_q.op == APU_OMT_ERD) begin
            ot_rsp_q <= '{status: APU_OMT_OK, entry: eg_idx_q,
                          bucket: '0, rec: erd_rec, fresh: 1'b0};
          end else begin
            ot_rsp_q <= '{status: APU_OMT_OK, entry: eg_idx_q,
                          bucket: '0, rec: '0, fresh: 1'b0};
          end
          ot_q <= OT_RSP;
        end

        // ---- write-back one line iff dirty (RETIRE point) -------------
        OT_EWB_LK: begin
          if (ec_hit && ec_dty_q[ec_hitway]) begin
            eg_way_q  <= ec_hitway;
            eg_beat_q <= '0;
            ot_q      <= OT_EWB_RD;
          end else begin
            ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                          bucket: '0, rec: '0, fresh: 1'b0};
            ot_q     <= OT_RSP;
          end
        end
        OT_EWB_RD:  ot_q <= OT_EWB_RDC;
        OT_EWB_RDC: begin
          eg_line_q <= ec_rdata;
          ot_q      <= OT_EWB_WB;
        end
        OT_EWB_WB: if (ot_mp_done) begin
          if (eg_beat_q == 3'd7) begin
            ec_dty_q[eg_way_q] <= 1'b0;
            ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                          bucket: '0, rec: '0, fresh: 1'b0};
            ot_q     <= OT_RSP;
          end else begin
            eg_beat_q <= eg_beat_q + 3'd1;
          end
        end

        // ---- write back all dirty entry lines (RESET_CTX point) ------
        OT_FL_LK: begin
          if (eg_way_q == EcIdxBits'(EntCacheLines)) begin
            ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                          bucket: '0, rec: '0, fresh: 1'b0};
            ot_q     <= OT_RSP;
          end else if (ec_vld_q[eg_way_q] && ec_dty_q[eg_way_q]) begin
            eg_beat_q <= '0;
            ot_q      <= OT_FL_RD;
          end else begin
            eg_way_q <= eg_way_q + 1'b1;
          end
        end
        OT_FL_RD:  ot_q <= OT_FL_RDC;
        OT_FL_RDC: begin
          eg_line_q <= ec_rdata;
          ot_q      <= OT_FL_WB;
        end
        OT_FL_WB: if (ot_mp_done) begin
          if (eg_beat_q == 3'd7) begin
            ec_dty_q[eg_way_q] <= 1'b0;
            eg_beat_q <= '0;
            eg_way_q  <= eg_way_q + 1'b1;
            ot_q      <= OT_FL_LK;
          end else begin
            eg_beat_q <= eg_beat_q + 3'd1;
          end
        end

        // ---- free-stack refill -------------------------------------------
        OT_POP_RD: if (ot_mp_done) begin
          ref_word_q <= mp_rdata_w;
          ref_hi_q   <= 2'((stk_sp_q - 1'b1) & 2'h3);
          stk_sp_q   <= stk_sp_q -
                        (EntBits'((stk_sp_q - 1'b1) & 2'h3) + 1'b1);
          ot_q       <= OT_POP_FILL;
        end
        OT_POP_FILL: begin
          // entries [sp-1-hi .. sp-1] push ascending so the highest
          // index lands on the flop top; serve the POP from it
          for (int k = 0; k < 4; k++)
            if (k <= ref_hi_q)
              fsk_q[fsk_n_q[4:0] + 5'(k)] <= ref_word_q[k*16 +: 16];
          fsk_n_q <= fsk_n_q + 6'(ref_hi_q);
          ot_rsp_q <= '{status: APU_OMT_OK,
                        entry: ref_word_q[ref_hi_q*16 +: 16],
                        bucket: '0, rec: '0, fresh: 1'b0};
          ot_q     <= OT_RSP;
        end
        OT_PUSH_W: if (ot_mp_done) begin
          stk_sp_q <= stk_sp_q + 1'b1;
          ot_rsp_q <= '{status: APU_OMT_OK, entry: '0,
                        bucket: '0, rec: '0, fresh: 1'b0};
          ot_q     <= OT_RSP;
        end

        OT_RSP: ot_q <= OT_IDLE;
        default: ot_q <= OT_IDLE;
        endcase

        // ================= op engine =================================
        unique case (op_q)
        OP_IDLE: if (omp_req_valid_i) begin
          op_req_q <= omp_req_i;
          pc_qline <= PcLnBits'(omp_req_i.line_addr);
          if (!omp_req_i.dir) begin
            op_rsp_q <= '{err: 1'b1, rdata: '0};
            op_q     <= OP_RSP;
          end else begin
            op_q <= OP_LK;
          end
        end
        OP_LK: begin
          if (pc_hit) begin
            op_way_q <= pc_hitway;
            op_q     <= OP_HRD;
          end else begin
            op_way_q <= pc_rr_q;
            if (pc_vld_q[pc_rr_q] && pc_dty_q[pc_rr_q]) begin
              op_q <= OP_VIC;
            end else if (op_req_q.we) begin
              // full-line write allocates without a fill
              pc_vld_q[pc_rr_q] <= 1'b1;
              pc_ln_q[pc_rr_q]  <= pc_qline;
              pc_dty_q[pc_rr_q] <= 1'b0;
              op_q <= OP_HWR;
            end else begin
              pc_vld_q[pc_rr_q] <= 1'b1;
              pc_ln_q[pc_rr_q]  <= pc_qline;
              pc_dty_q[pc_rr_q] <= 1'b0;
              op_beat_q <= '0;
              op_q      <= OP_FILL;
            end
            pc_rr_q <= pc_rr_q + 1'b1;
          end
        end
        OP_HRD:  op_q <= OP_HRDC;
        OP_HRDC: begin
          op_line_q <= pc_rdata;
          if (op_req_q.we) op_q <= OP_HWR;
          else begin
            op_rsp_q <= '{err: 1'b0, rdata: pc_rdata};
            op_q     <= OP_RSP;
          end
        end
        OP_HWR: begin
          // whole-line write committed by the comb block this cycle
          pc_dty_q[op_way_q] <= 1'b1;
          op_rsp_q <= '{err: 1'b0, rdata: '0};
          op_q     <= OP_RSP;
        end
        OP_VIC:  op_q <= OP_VICR;
        OP_VICR: begin
          wb2_line_q <= pc_rdata;
          op_beat_q  <= '0;
          op_q       <= OP_WB;
        end
        OP_WB: if (op_mp_done) begin
          if (op_beat_q == 3'd7) begin
            pc_vld_q[op_way_q] <= 1'b1;
            pc_ln_q[op_way_q]  <= pc_qline;
            pc_dty_q[op_way_q] <= 1'b0;
            if (op_req_q.we) begin
              // still a full-line write — the victim is written back
              // and the new line installs wdata without a fill
              op_q <= OP_HWR;
            end else begin
              op_beat_q <= '0;
              op_q      <= OP_FILL;
            end
          end else begin
            op_beat_q <= op_beat_q + 3'd1;
          end
        end
        OP_FILL: if (op_mp_done) begin
          op_line_q[op_beat_q*64 +: 64] <= mp_rdata_w;
          if (op_beat_q == 3'd7) begin
            op_beat_q <= '0;
            op_rsp_q  <= '{err: 1'b0,
                          rdata: {mp_rdata_w, op_line_q[447:0]}};
            op_q      <= OP_FST;
          end else begin
            op_beat_q <= op_beat_q + 3'd1;
          end
        end
        OP_FST:  op_q <= OP_RSP;   // line store issued by comb block
        OP_RSP: op_q <= OP_IDLE;
        default: op_q <= OP_IDLE;
        endcase
      end
    end

`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      mp_rsp_valid_i |-> mp_busy_q);
`endif
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_objmem_fixture
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_mp_pkg::*;
#(parameter bit          Enable        = 1'b0,
  parameter int unsigned ObjEntries    = 1024,
  parameter int unsigned PayMemBytes   = 262144,
  parameter int unsigned DirCacheSets  = 64,
  parameter int unsigned EntCacheLines = 16,
  parameter int unsigned PayCacheLines = 8) (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  logic          testmode_i,
  input  logic          omt_req_valid_i,
  output logic          omt_req_ready_o,
  input  apu_omt_req_t  omt_req_i,
  output logic          omt_rsp_valid_o,
  output apu_omt_rsp_t  omt_rsp_o,
  input  logic          omp_req_valid_i,
  output logic          omp_req_ready_o,
  input  apu_omp_req_t  omp_req_i,
  output logic          omp_rsp_valid_o,
  output apu_omp_rsp_t  omp_rsp_o,
  output logic          mp_req_valid_o,
  input  logic          mp_req_ready_i,
  output apu_mp_req_t   mp_req_o,
  input  logic          mp_rsp_valid_i,
  input  apu_mp_rsp_t   mp_rsp_i
);
  g6lc_apu_objmem #(.Enable(Enable), .ObjEntries(ObjEntries),
                    .PayMemBytes(PayMemBytes),
                    .DirCacheSets(DirCacheSets),
                    .EntCacheLines(EntCacheLines),
                    .PayCacheLines(PayCacheLines)) i_dut (.*);
endmodule
