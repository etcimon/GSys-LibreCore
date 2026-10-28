// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Command recorder (§5a G3b-iii + §6/§7b of
// architecture/uncore/apu-vulkan-engine.md).  Command buffers live
// entirely in PayMem: a 64-word descriptor block per buffer (parked
// in the object's aux[63:32]; the request `cbd` is its word address)
// plus two bump-allocated 1024-word chunk chains — records (w0 = next
// chunk, rows 1..63, one 16-word record per row) and payloads (w0 =
// next chunk, words bump-allocated from w1; a record's payload never
// straddles a chunk).  A record's payload base rides imm[7] as an
// ABSOLUTE PayMem word address — the executor reads it straight
// through ObjPay; the old PAYREAD op is retired.
//
// Ops (ready/valid request, one or more completions):
//   BEGIN   (cbd, flags)   implicit reset: frees any old chains,
//                          allocates the first record chunk, records
//                          usage bits {one_time, simultaneous,
//                          rp_continue} in w0[5:3]; w0[2] secondary is
//                          alloc-time and preserved.  FULL on ObjPay
//                          ALLOC failure (-> VK_ERROR_OUT_OF_DEVICE_MEMORY)
//   APPEND  (cbd, rec, pay_n) : row-allocates the record (new linked
//                          chunk on row overflow), reserves payload
//                          space (new chunk when the tail remainder
//                          doesn't fit), stamps imm[7] <- pay_top,
//                          writes the record, then streams pay_n words
//                          on the pay port.  FULL/PAY_FULL when a
//                          chain ALLOC fails (record not appended;
//                          the declared stream is still drained), and
//                          FULL at count == 65,535 — the executor's
//                          per-buffer record index is 16-bit
//   END     (cbd)          seal (recording -> 0, sealed -> 1)
//   RESET   (cbd)          free both chains, clear w0..w7 (secondary
//                          kept), write-back + drop the cache entry
//   READ    (cbd, idx)     return record; needs sealed, idx < count;
//                          sequential cursor + 2-record prefetch FIFO
//   COUNT   (cbd)          return current fill
//   RESET_POOL (cbd=head)  walk the pool chain: RESET each descriptor,
//                          one SWEEP interim completion per buffer
//                          (pdata = its w9 own handle), final OK
//   DESTROY_POOL (cbd=head): same walk + FREE each descriptor block
// Statuses: OK, FULL, NOT_RECORDING, NOT_SEALED, BAD_IDX, BAD_BUF,
// PAY_FULL, SWEEP.
//
// ObjPay op engine: one outstanding request at a time; a successful
// READN returns one completion per word in order, and a non-OK
// completion ends the op after that single beat (e.g. BOUNDS on a
// descriptor block already freed) — the requester reads opc_st_q.
//
// The CbOpen-entry write-back descriptor cache holds w0..w7 plus the
// sequential-read cursor {cidx, caddr}; w8..w11 (pool links, handles)
// belong to vnfront and are read on demand, never cached.  RESET and
// the pool walks evict the entry after write-back (the descriptor may
// be freed next, and evict-before-alloc ordering keeps a write-back
// write from ever landing inside a chunk an APPEND will allocate).
//
// Timing impact: every micro-step is one ObjPay op; the widest cones
// are the 512-bit record/line muxes.  Descriptor cache and prefetch
// FIFO are flops; no SRAM.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; Enable=0 elaborates no datapath; req/cpl are the objtab
// ready/valid shape; interim SWEEP completions carry pdata.

module g6lc_apu_cmdrec
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objpay_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned CbOpen = 4
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_cmdrec_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_cmdrec_cpl_t cpl_o,
  // payload stream for APPEND (and drain on rejected appends)
  input  logic            pay_valid_i,
  input  logic [31:0]     pay_data_i,
  output logic            pay_ready_o,
  // ObjPay client port
  output logic            op_req_valid_o,
  input  logic            op_req_ready_i,
  output apu_objpay_req_t op_req_o,
  input  logic            op_cpl_valid_i,
  output logic            op_cpl_ready_o,
  input  apu_objpay_cpl_t op_cpl_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o    = 1'b0;
    assign cpl_valid_o    = 1'b0;
    assign cpl_o          = '0;
    assign pay_ready_o    = 1'b0;
    assign op_req_valid_o = 1'b0;
    assign op_req_o       = '0;
    assign op_cpl_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i |
                    cpl_ready_i | (|req_i) | pay_valid_i |
                    (|pay_data_i) | op_req_ready_i |
                    op_cpl_valid_i | (|op_cpl_i);
  end else begin : gen_on
    localparam int unsigned CW     = APU_CB_CHUNK_WORDS;  // 1024
    localparam int unsigned ROWS   = APU_CB_REC_ROWS;     // 63
    localparam int unsigned RFIRST = APU_CB_REC_FIRST;    // 16
    localparam int unsigned CSel   = CbOpen > 1 ? $clog2(CbOpen) : 1;

    typedef enum logic [5:0] {
      StIdle,
      StOReq, StOWait,            // ObjPay op engine
      StOpenGo, StOpenGo2,        // descriptor-open subroutine
      StFillDone,
      StEvW,                      // write-back w0..w7 then invalidate
      StBody,                     // per-op body dispatch
      StFrTop, StFrDo,            // chain-free subroutine
      StBeginAlloc, StBeginAlloc2, StBeginZ,
      StApRecOk, StApRecZ, StApRecLink, // record-chunk alloc + link
      StAppPay,                   // payload-space check
      StApPayOk, StApPayZ, StApPayLink, // payload-chunk alloc + link
      StApRecW,                   // write the 16 record words
      StPayW, StPayDone,          // payload stream + finalize
      StPayDrain,                 // rejected append drain
      StRead, StRdWk, StRdHop, StRdFetch,
      StResetDone, StResetCpl,
      StPoolRd, StPoolDsc, StPoolFr, StPoolClr, StPoolSweep,
      StPoolNext,
      StPfHop, StPfRd,            // prefetch background fill
      StCpl
    } state_e;

    state_e          state_q;
    apu_cmdrec_req_t req_q;
    apu_cmdrec_cpl_t cpl_q;

    // ---- ObjPay op engine ------------------------------------------
    apu_objpay_req_t    opq_q;         // request in flight
    state_e             opret_q;       // state after final beat
    logic [4:0]         opn_q;         // READN beats expected
    logic [4:0]         obi_q;         // beat index
    logic [511:0]       lb_q;          // beat staging (16 words)
    apu_objpay_status_e opc_st_q;      // last-beat status
    logic [31:0]        opc_rd_q;      // last-beat rdata / alloc base

    // ---- open subroutine -------------------------------------------
    logic [31:0]        ob_q;          // descriptor to open
    state_e             ob_ret_q;
    // ---- evict subroutine ------------------------------------------
    logic [3:0]         ev_i_q;
    state_e             ev_ret_q;
    // ---- chain-free subroutine --------------------------------------
    logic [31:0]        fr_head_q;     // chunk under free
    logic               fr_pay_q;      // then free the pay chain too
    state_e             fr_ret_q;
    // ---- record-walk ------------------------------------------------
    logic [31:0]        wk_chunk_q;
    logic [31:0]        wk_i_q;
    logic [31:0]        wk_addr_q;
    // ---- pool walk --------------------------------------------------
    logic [31:0]        pl_cur_q;
    logic [31:0]        pl_own_q;
    logic [31:0]        pl_next_q;
    // ---- append scratch ---------------------------------------------
    logic [4:0]         rw_i_q;        // record word index
    logic [15:0]        ps_i_q;        // payload stream index
    logic [31:0]        pt_q;          // frozen ptop for this append
    apu_cmdrec_status_e dead_st_q;     // drain-report status
    logic [31:0]        newc_q;        // freshly allocated chunk base
    // ---- prefetch scratch -------------------------------------------
    logic [31:0]        pf_pa_q;       // record addr being fetched

    // ---- descriptor cache (w0..w7 write-back) -----------------------
    logic        cv_q  [CbOpen];
    logic        cd_q  [CbOpen];
    logic [31:0] cc_q  [CbOpen];
    logic [31:0] cw_q  [CbOpen][8];
    logic        cxv_q [CbOpen];       // cursor valid
    logic [31:0] cx_q  [CbOpen];       // last-read record index
    logic [31:0] ca_q  [CbOpen];       // its word address
    logic [31:0] ck_q  [CbOpen];       //   chunk base holding it —
                                       //   ALLOC bases are 64-word
                                       //   aligned, never CW-aligned
    logic [CSel-1:0] vic_q;            // round-robin victim
    logic [CSel-1:0] ce_q;             // open entry index
    // ---- prefetch FIFO (depth 2) ------------------------------------
    logic [1:0]   pf_n_q;
    logic [31:0]  pf_a_q [2];
    logic [31:0]  pf_b_q [2];          // chunk base per entry
    logic [511:0] pf_d_q [2];
    logic [31:0]  pf_ck_q;             // chunk base of pf_pa_q

    function automatic int cbd_hit(input logic [31:0] a);
      int r;
      r = -1;
      for (int i = 0; i < CbOpen; i++)
        if (cv_q[i] && cc_q[i] == a) r = i;
      return r;
    endfunction

    // issue one ObjPay op, resume at `ret` after its final beat
    task automatic op_go(input apu_objpay_op_e o, input logic [31:0] a,
                         input logic [31:0] w, input logic [31:0] d,
                         input state_e ret);
      opq_q   <= '{op: o, addr: a, words: w, wdata: d};
      opn_q   <= 5'(w);
      obi_q   <= '0;
      opret_q <= ret;
      state_q <= StOReq;
    endtask

    wire [31:0] d_flags = cw_q[ce_q][APU_CBD_W0];
    wire [31:0] d_count = cw_q[ce_q][APU_CBD_COUNT];
    wire [31:0] d_rech  = cw_q[ce_q][APU_CBD_RECH];
    wire [31:0] d_rect  = cw_q[ce_q][APU_CBD_RECT];
    wire [31:0] d_row   = cw_q[ce_q][APU_CBD_ROW];
    wire [31:0] d_payh  = cw_q[ce_q][APU_CBD_PAYH];
    wire [31:0] d_payt  = cw_q[ce_q][APU_CBD_PAYT];
    wire [31:0] d_ptop  = cw_q[ce_q][APU_CBD_PTOP];

    // record-at-`a` has an in-chunk successor when its row < 63 —
    // `chk` is the base of the chunk holding `a` (ALLOC bases are
    // only 64-word aligned, so chunk membership cannot be derived
    // from the address itself)
    function automatic logic in_chunk_next(input logic [31:0] a,
                                           input logic [31:0] chk);
      return (a - chk) < 32'(CW - RFIRST);
    endfunction

    assign req_ready_o    = state_q == StIdle;
    assign cpl_valid_o    = state_q == StCpl || state_q == StPoolSweep;
    assign cpl_o          = cpl_q;
    assign pay_ready_o    = state_q == StPayW || state_q == StPayDrain;
    assign op_req_valid_o = state_q == StOReq;
    assign op_req_o       = opq_q;
    assign op_cpl_ready_o = 1'b1;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        req_q <= '0; cpl_q <= '0;
        opq_q <= '0; opret_q <= StIdle; opn_q <= '0; obi_q <= '0;
        lb_q <= '0; opc_st_q <= APU_OBJPAY_OK; opc_rd_q <= '0;
        ob_q <= '0; ob_ret_q <= StIdle;
        ev_i_q <= '0; ev_ret_q <= StIdle;
        fr_head_q <= '0; fr_pay_q <= 1'b0; fr_ret_q <= StIdle;
        wk_chunk_q <= '0; wk_i_q <= '0; wk_addr_q <= '0;
        pl_cur_q <= '0; pl_own_q <= '0; pl_next_q <= '0;
        rw_i_q <= '0; ps_i_q <= '0; pt_q <= '0;
        dead_st_q <= APU_CMDREC_OK; newc_q <= '0; pf_pa_q <= '0;
        vic_q <= '0; ce_q <= '0; pf_n_q <= '0;
        for (int i = 0; i < CbOpen; i++) begin
          cv_q[i] <= 1'b0; cd_q[i] <= 1'b0; cc_q[i] <= '0;
          cxv_q[i] <= 1'b0; cx_q[i] <= '0; ca_q[i] <= '0;
          ck_q[i] <= '0;
          for (int j = 0; j < 8; j++) cw_q[i][j] <= '0;
        end
        pf_ck_q <= '0;
        for (int i = 0; i < 2; i++) begin
          pf_a_q[i] <= '0; pf_b_q[i] <= '0; pf_d_q[i] <= '0;
        end
      end else begin
        unique case (state_q)
        // ================ request accept / background prefetch =======
        StIdle: begin
          if (req_valid_i) begin
            req_q <= req_i;
            unique case (req_i.op)
              APU_CMDREC_OP_RESET_POOL,
              APU_CMDREC_OP_DESTROY_POOL: begin
                pl_cur_q <= req_i.cbd;
                state_q  <= StPoolRd;
              end
              default: begin
                if (req_i.cbd == 32'h0) begin
                  cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                               pdata: '0, rec: '0};
                  state_q <= StCpl;
                end else begin
                  ob_q     <= req_i.cbd;
                  ob_ret_q <= StBody;
                  state_q  <= StOpenGo;
                end
              end
            endcase
          end else if (pf_n_q != 2'd2 && cv_q[ce_q] && cxv_q[ce_q] &&
                       cx_q[ce_q] + 32'(pf_n_q) + 32'd1 < d_count) begin
            // fill one FIFO slot behind the sequential cursor
            automatic logic [31:0] base, bck;
            base = pf_n_q == 2'd0 ? ca_q[ce_q]
                                  : pf_a_q[1'(pf_n_q - 2'd1)];
            bck  = pf_n_q == 2'd0 ? ck_q[ce_q]
                                  : pf_b_q[1'(pf_n_q - 2'd1)];
            if (in_chunk_next(base, bck)) begin
              pf_pa_q <= base + 32'd16;
              pf_ck_q <= bck;
              op_go(APU_OBJPAY_OP_READN, base + 32'd16, 32'd16, '0,
                    StPfRd);
            end else begin
              // w0 of the chunk holding `base` is the next-chunk link
              pf_ck_q <= bck;
              op_go(APU_OBJPAY_OP_READN, bck, 32'd1, '0, StPfHop);
            end
          end
        end

        // ================ ObjPay op engine ==========================
        StOReq: begin
          if (op_req_ready_i) state_q <= StOWait;
//pragma translate_off
`ifdef CMDREC_TRACE
          if (op_req_ready_i)
            $display("[%0t] CR-OP op=%0d addr=%0d w=%0d d=%08x st=%0d",
                     $time, opq_q.op, opq_q.addr, opq_q.words,
                     opq_q.wdata, state_q);
`endif
//pragma translate_on
        end
        StOWait: if (op_cpl_valid_i) begin
          opc_st_q <= op_cpl_i.status;
          // ALLOC answers its extent base in `base`; READ/READN beats
          // carry the word in `rdata`
          opc_rd_q <= opq_q.op == APU_OBJPAY_OP_ALLOC
                      ? op_cpl_i.base : op_cpl_i.rdata;
          if (op_cpl_i.status != APU_OBJPAY_OK) begin
            // a failed beat ends the op: ObjPay answers an out-of-
            // bounds READN with a single completion, not a beat
            // stream (e.g. RESET on a descriptor block the first
            // free already reclaimed)
            obi_q   <= '0;
            state_q <= opret_q;
          end else if (opq_q.op == APU_OBJPAY_OP_READN) begin
            lb_q[obi_q * 32 +: 32] <= op_cpl_i.rdata;
            if (obi_q == opn_q - 5'd1) begin
              obi_q   <= '0;
              state_q <= opret_q;
            end else begin
              obi_q <= obi_q + 5'd1;
            end
          end else begin
            state_q <= opret_q;
          end
        end

        // ================ descriptor-open subroutine ================
        StOpenGo: begin
          automatic int h = cbd_hit(ob_q);
          if (h >= 0) begin
            ce_q    <= CSel'(h);
            state_q <= ob_ret_q;
          end else begin
            ce_q <= vic_q;
            if (cv_q[vic_q] && cd_q[vic_q]) begin
              ev_i_q   <= '0;
              ev_ret_q <= StOpenGo2;
              state_q  <= StEvW;
            end else begin
              cv_q[vic_q] <= 1'b0;
              vic_q <= vic_q + CSel'(1);
              op_go(APU_OBJPAY_OP_READN, ob_q, 32'd8, '0,
                    StFillDone);
            end
          end
        end
        StOpenGo2: begin
          // dirty victim evicted by StEvW; now fill the freed slot
          vic_q <= vic_q + CSel'(1);
          op_go(APU_OBJPAY_OP_READN, ob_q, 32'd8, '0, StFillDone);
        end
        StEvW: begin
          // write back w0..w7 of entry ce_q, drop it, then ev_ret_q
          if (ev_i_q == 4'd8) begin
            cv_q[ce_q]  <= 1'b0;
            cd_q[ce_q]  <= 1'b0;
            cxv_q[ce_q] <= 1'b0;
            state_q <= ev_ret_q;
          end else begin
            op_go(APU_OBJPAY_OP_WRITE, cc_q[ce_q] + 32'(ev_i_q),
                  32'd0, cw_q[ce_q][ev_i_q[2:0]], StEvW);
            ev_i_q <= ev_i_q + 4'd1;
          end
        end
        StFillDone: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
          $display("[DBG] crfill ce=%0d ob=%08x lb={%08x %08x %08x %08x %08x %08x %08x %08x} t=%0t",
                   ce_q, ob_q, lb_q[31:0], lb_q[63:32], lb_q[95:64],
                   lb_q[127:96], lb_q[159:128], lb_q[191:160],
                   lb_q[223:192], lb_q[255:224], $time);
`endif
// pragma translate_on
          if (opc_st_q != APU_OBJPAY_OK) begin
            cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                         pdata: '0, rec: '0};
            state_q <= StCpl;
          end else begin
            cv_q[ce_q]  <= 1'b1;
            cd_q[ce_q]  <= 1'b0;
            cc_q[ce_q]  <= ob_q;
            cxv_q[ce_q] <= 1'b0;
            for (int j = 0; j < 8; j++)
              cw_q[ce_q][j] <= lb_q[j * 32 +: 32];
            state_q <= ob_ret_q;
          end
        end

        // ================ per-op bodies =============================
        StBody: begin
          unique case (req_q.op)
            APU_CMDREC_OP_BEGIN: begin
              if (d_rech != 32'h0 || d_payh != 32'h0) begin
                // implicit reset: free old chains, then alloc fresh
                fr_head_q <= d_rech;
                fr_pay_q  <= 1'b1;
                fr_ret_q  <= StBeginAlloc;
                state_q   <= StFrTop;
              end else begin
                op_go(APU_OBJPAY_OP_ALLOC, '0, 32'(CW), '0,
                      StBeginAlloc2);
              end
            end
            APU_CMDREC_OP_APPEND: begin
              if ((d_flags & (32'h1 << APU_CBF_RECORDING)) == 32'h0) begin
                dead_st_q <= APU_CMDREC_NOT_RECORDING;
                ps_i_q    <= '0;
                cpl_q     <= '{status: APU_CMDREC_NOT_RECORDING,
                               count: d_count, pdata: '0, rec: '0};
                state_q   <= req_q.pay_n == 16'h0 ? StCpl
                                                  : StPayDrain;
              end else if (d_count >= 32'h0000_FFFF) begin
                // the executor's per-buffer record index is 16-bit —
                // refuse the append that would mint record 65,536
                dead_st_q <= APU_CMDREC_FULL;
                ps_i_q    <= '0;
                cpl_q     <= '{status: APU_CMDREC_FULL,
                               count: d_count, pdata: '0, rec: '0};
                state_q   <= req_q.pay_n == 16'h0 ? StCpl
                                                  : StPayDrain;
              end else if (d_rect == 32'h0 || d_row > 32'(ROWS)) begin
                op_go(APU_OBJPAY_OP_ALLOC, '0, 32'(CW), '0,
                      StApRecOk);
              end else begin
                state_q <= StAppPay;
              end
            end
            APU_CMDREC_OP_END: begin
              if ((d_flags & (32'h1 << APU_CBF_RECORDING)) == 32'h0) begin
                cpl_q   <= '{status: APU_CMDREC_NOT_RECORDING,
                             count: d_count, pdata: '0, rec: '0};
                state_q <= StCpl;
              end else begin
                cw_q[ce_q][APU_CBD_W0] <=
                    (d_flags & ~(32'h1 << APU_CBF_RECORDING)) |
                    (32'h1 << APU_CBF_SEALED);
                cd_q[ce_q] <= 1'b1;
                cpl_q   <= '{status: APU_CMDREC_OK, count: d_count,
                             pdata: '0, rec: '0};
                state_q <= StCpl;
              end
            end
            APU_CMDREC_OP_RESET: begin
              fr_head_q <= d_rech;
              fr_pay_q  <= 1'b1;
              fr_ret_q  <= StResetDone;
              state_q   <= StFrTop;
            end
            APU_CMDREC_OP_COUNT: begin
              cpl_q   <= '{status: APU_CMDREC_OK, count: d_count,
                           pdata: '0, rec: '0};
              state_q <= StCpl;
            end
            APU_CMDREC_OP_READ: begin
              if ((d_flags & (32'h1 << APU_CBF_SEALED)) == 32'h0) begin
                cpl_q   <= '{status: APU_CMDREC_NOT_SEALED,
                             count: d_count, pdata: '0, rec: '0};
                state_q <= StCpl;
              end else if (32'(req_q.idx) >= d_count) begin
                cpl_q   <= '{status: APU_CMDREC_BAD_IDX,
                             count: d_count, pdata: '0, rec: '0};
                state_q <= StCpl;
              end else begin
                state_q <= StRead;
              end
            end
            default: begin
              cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                           pdata: '0, rec: '0};
              state_q <= StCpl;
            end
          endcase
        end

        // ================ chain-free subroutine =====================
        // frees the chunk chain headed at fr_head_q; fr_pay_q says
        // the open descriptor's pay chain follows; then fr_ret_q
        StFrTop: begin
          if (fr_head_q != 32'h0) begin
            op_go(APU_OBJPAY_OP_READN, fr_head_q, 32'd1, '0, StFrDo);
          end else if (fr_pay_q && d_payh != 32'h0) begin
            fr_head_q <= d_payh;
            fr_pay_q  <= 1'b0;
          end else begin
            state_q <= fr_ret_q;
          end
        end
        StFrDo: begin
          // opc_rd_q = next chunk (0 at tail); a corrupt link stops
          // the walk — the rest of the reset still proceeds
          fr_head_q <= opc_st_q == APU_OBJPAY_OK ? opc_rd_q : 32'h0;
          op_go(APU_OBJPAY_OP_FREE, opq_q.addr, 32'(CW), '0, StFrTop);
        end

        // ================ BEGIN continuations =======================
        StBeginAlloc: begin
          // reached once the old chains are gone
          op_go(APU_OBJPAY_OP_ALLOC, '0, 32'(CW), '0, StBeginAlloc2);
        end
        StBeginAlloc2: begin
          if (opc_st_q != APU_OBJPAY_OK) begin
            // the free-walk already dropped both chains — the
            // descriptor must not keep pointers into freed chunks or
            // the next BEGIN/RESET/RESET_POOL would double-free them.
            // Clear the chain state and RECORDING/SEALED (SECONDARY
            // and the pool/owner fields persist), write back, then
            // report FULL.
            cw_q[ce_q][APU_CBD_W0]    <=
                d_flags & (32'h1 << APU_CBF_SECONDARY);
            cw_q[ce_q][APU_CBD_COUNT] <= '0;
            cw_q[ce_q][APU_CBD_RECH]  <= '0;
            cw_q[ce_q][APU_CBD_RECT]  <= '0;
            cw_q[ce_q][APU_CBD_ROW]   <= '0;
            cw_q[ce_q][APU_CBD_PAYH]  <= '0;
            cw_q[ce_q][APU_CBD_PAYT]  <= '0;
            cw_q[ce_q][APU_CBD_PTOP]  <= '0;
            cd_q[ce_q]  <= 1'b1;
            cxv_q[ce_q] <= 1'b0;
            pf_n_q      <= '0;
            cpl_q   <= '{status: APU_CMDREC_FULL, count: '0,
                         pdata: '0, rec: '0};
            state_q <= StCpl;
          end else begin
            // clear the fresh chunk's w0 (next link) — a recycled
            // extent may carry a stale pointer the free-walk would
            // follow into live or double-freed storage
            newc_q <= opc_rd_q;
            op_go(APU_OBJPAY_OP_WRITE, opc_rd_q, 32'd0, 32'h0,
                  StBeginZ);
          end
        end
        StBeginZ: begin
            cw_q[ce_q][APU_CBD_W0] <=
                (d_flags & (32'h1 << APU_CBF_SECONDARY)) |
                (32'h1 << APU_CBF_RECORDING) |
                (req_q.flags & 32'h38);
            cw_q[ce_q][APU_CBD_COUNT] <= '0;
            cw_q[ce_q][APU_CBD_RECH]  <= newc_q;
            cw_q[ce_q][APU_CBD_RECT]  <= newc_q;
            cw_q[ce_q][APU_CBD_ROW]   <= 32'd1;
            cw_q[ce_q][APU_CBD_PAYH]  <= '0;
            cw_q[ce_q][APU_CBD_PAYT]  <= '0;
            cw_q[ce_q][APU_CBD_PTOP]  <= '0;
            cd_q[ce_q]  <= 1'b1;
            cxv_q[ce_q] <= 1'b0;
            pf_n_q      <= '0;
            cpl_q   <= '{status: APU_CMDREC_OK, count: '0, pdata: '0,
                         rec: '0};
            state_q <= StCpl;
        end

        // ================ APPEND continuations =======================
        // record-chunk ALLOC returned; link or set head
        StApRecOk: begin
          if (opc_st_q != APU_OBJPAY_OK) begin
            dead_st_q <= APU_CMDREC_FULL;
            ps_i_q    <= '0;
            cpl_q     <= '{status: APU_CMDREC_FULL, count: d_count,
                           pdata: '0, rec: '0};
            state_q   <= req_q.pay_n == 16'h0 ? StCpl : StPayDrain;
          end else begin
            // clear the fresh chunk's w0 first — a recycled extent may
            // carry a stale next-pointer the free-walk would follow
            newc_q <= opc_rd_q;
            op_go(APU_OBJPAY_OP_WRITE, opc_rd_q, 32'd0, 32'h0,
                  StApRecZ);
          end
        end
        StApRecZ: begin
          if (d_rect == 32'h0) begin
            cw_q[ce_q][APU_CBD_RECH] <= newc_q;
            cw_q[ce_q][APU_CBD_RECT] <= newc_q;
            cw_q[ce_q][APU_CBD_ROW]  <= 32'd1;
            cd_q[ce_q] <= 1'b1;
            state_q    <= StAppPay;
          end else begin
            // write the old tail chunk's w0 = new base, then advance
            op_go(APU_OBJPAY_OP_WRITE, d_rect, 32'd0, newc_q,
                  StApRecLink);
          end
        end
        StApRecLink: begin
          cw_q[ce_q][APU_CBD_RECT] <= newc_q;
          cw_q[ce_q][APU_CBD_ROW]  <= 32'd1;
          cd_q[ce_q] <= 1'b1;
          state_q    <= StAppPay;
        end
        // payload-space check (reached once the record row exists)
        StAppPay: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
          $display("[DBG] apppay ce=%0d payn=%0d w={%08x %08x %08x %08x %08x %08x %08x %08x} t=%0t",
                   ce_q, req_q.pay_n, cw_q[ce_q][0], cw_q[ce_q][1],
                   cw_q[ce_q][2], cw_q[ce_q][3], cw_q[ce_q][4],
                   cw_q[ce_q][5], cw_q[ce_q][6], cw_q[ce_q][7], $time);
`endif
// pragma translate_on
          if (req_q.pay_n == 16'h0) begin
            pt_q    <= '0;
            rw_i_q  <= '0;
            state_q <= StApRecW;
          end else if (d_payt == 32'h0 ||
                       d_ptop + 32'(req_q.pay_n) > d_payt + 32'(CW)) begin
            op_go(APU_OBJPAY_OP_ALLOC, '0, 32'(CW), '0, StApPayOk);
          end else begin
            pt_q    <= d_ptop;
            rw_i_q  <= '0;
            state_q <= StApRecW;
          end
        end
        StApPayOk: begin
          if (opc_st_q != APU_OBJPAY_OK) begin
            dead_st_q <= APU_CMDREC_PAY_FULL;
            ps_i_q    <= '0;
            cpl_q     <= '{status: APU_CMDREC_PAY_FULL,
                           count: d_count, pdata: '0, rec: '0};
            state_q   <= req_q.pay_n == 16'h0 ? StCpl : StPayDrain;
          end else begin
            // clear the fresh chunk's w0 first — a recycled extent may
            // carry a stale next-pointer the free-walk would follow
            newc_q <= opc_rd_q;
            op_go(APU_OBJPAY_OP_WRITE, opc_rd_q, 32'd0, 32'h0,
                  StApPayZ);
          end
        end
        StApPayZ: begin
          if (d_payt == 32'h0) begin
            cw_q[ce_q][APU_CBD_PAYH] <= newc_q;
            cw_q[ce_q][APU_CBD_PAYT] <= newc_q;
            cw_q[ce_q][APU_CBD_PTOP] <= newc_q + 32'd1;
            cd_q[ce_q] <= 1'b1;
            pt_q    <= newc_q + 32'd1;
            rw_i_q  <= '0;
            state_q <= StApRecW;
          end else begin
            op_go(APU_OBJPAY_OP_WRITE, d_payt, 32'd0, newc_q,
                  StApPayLink);
          end
        end
        StApPayLink: begin
          cw_q[ce_q][APU_CBD_PAYT] <= newc_q;
          cw_q[ce_q][APU_CBD_PTOP] <= newc_q + 32'd1;
          cd_q[ce_q] <= 1'b1;
          pt_q    <= newc_q + 32'd1;
          rw_i_q  <= '0;
          state_q <= StApRecW;
        end
        // write the 16 record words at rect + row*16 (imm[7] = pt_q)
        StApRecW: begin
          if (rw_i_q == 5'd16) begin
            if (req_q.pay_n == 16'h0) begin
              state_q <= StPayDone;
            end else begin
              ps_i_q  <= '0;
              state_q <= StPayW;
            end
          end else begin
            automatic apu_cmdrec_rec_t rr;
            rr = req_q.rec;
            if (req_q.pay_n != 16'h0) rr.imm[7] = pt_q;
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] recw row=%0d i=%0d pt=%08x imm7=%08x payn=%0d ct=%0d t=%0t",
                     d_row, rw_i_q, pt_q, rr.imm[7], req_q.pay_n,
                     rr.ctype, $time);
`endif
// pragma translate_on
            op_go(APU_OBJPAY_OP_WRITE,
                  d_rect + d_row * 32'd16 + 32'(rw_i_q), 32'd0,
                  rr[rw_i_q * 32 +: 32], StApRecW);
            rw_i_q <= rw_i_q + 5'd1;
          end
        end
        // payload stream: one accepted word = one ObjPay WRITE; the
        // last write returns to StPayDone
        StPayW: begin
          if (pay_valid_i) begin
            if (ps_i_q == req_q.pay_n - 16'd1) begin
              op_go(APU_OBJPAY_OP_WRITE, pt_q + 32'(ps_i_q), 32'd0,
                    pay_data_i, StPayDone);
            end else begin
              op_go(APU_OBJPAY_OP_WRITE, pt_q + 32'(ps_i_q), 32'd0,
                    pay_data_i, StPayW);
            end
            ps_i_q <= ps_i_q + 16'd1;
          end
        end
        StPayDone: begin
          cw_q[ce_q][APU_CBD_ROW]   <= d_row + 32'd1;
          cw_q[ce_q][APU_CBD_COUNT] <= d_count + 32'd1;
          // a payload-less append leaves pt_q at 0 — advancing PTOP
          // with it would reset the chain bump pointer to the start
          // of reserved chunk 0
          if (req_q.pay_n != 16'h0)
            cw_q[ce_q][APU_CBD_PTOP] <= pt_q + 32'(req_q.pay_n);
          cd_q[ce_q]  <= 1'b1;
          cxv_q[ce_q] <= 1'b0;
          pf_n_q      <= '0;
          cpl_q   <= '{status: APU_CMDREC_OK, count: d_count + 32'd1,
                       pdata: '0, rec: '0};
          state_q <= StCpl;
        end
        // rejected append: drain the producer's declared stream, then
        // report the staged status
        StPayDrain: begin
          if (pay_valid_i) begin
            if (ps_i_q == req_q.pay_n - 16'd1) begin
              state_q <= StCpl;
            end else begin
              ps_i_q <= ps_i_q + 16'd1;
            end
          end
        end

        // ================ READ ======================================
        StRead: begin : read_resolve
          automatic logic [31:0] cand;
          automatic logic        have;
          cand = '0; have = 1'b0;
          if (cxv_q[ce_q] && 32'(req_q.idx) == cx_q[ce_q]) begin
            cand = ca_q[ce_q]; have = 1'b1;
          end else if (cxv_q[ce_q] &&
                       32'(req_q.idx) == cx_q[ce_q] + 32'd1 &&
                       in_chunk_next(ca_q[ce_q], ck_q[ce_q])) begin
            cand = ca_q[ce_q] + 32'd16; have = 1'b1;
          end else if (req_q.idx == 16'h0) begin
            cand = d_rech + 32'(RFIRST); have = 1'b1;
          end
          if (cxv_q[ce_q] && 32'(req_q.idx) == cx_q[ce_q] + 32'd1 &&
              !in_chunk_next(ca_q[ce_q], ck_q[ce_q])) begin
            // sequential read across a chunk boundary — never a head
            // walk: the prefetch hop line is by construction record
            // cx+1 (serve it and adopt its chunk base); without it,
            // follow this chunk's w0 link once and let StRdWk serve
            // the new head directly
            if (pf_n_q != 2'd0) begin
              cpl_q <= '{status: APU_CMDREC_OK, count: d_count,
                         pdata: '0,
                         rec: apu_cmdrec_rec_t'(pf_d_q[0])};
              pf_a_q[0] <= pf_a_q[1];
              pf_b_q[0] <= pf_b_q[1];
              pf_d_q[0] <= pf_d_q[1];
              pf_n_q    <= pf_n_q - 2'd1;
              cx_q[ce_q] <= req_q.idx;
              ca_q[ce_q] <= pf_a_q[0];
              ck_q[ce_q] <= pf_b_q[0];
              state_q    <= StCpl;
            end else begin
              pf_n_q <= '0;
              wk_i_q <= cx_q[ce_q];
              op_go(APU_OBJPAY_OP_READN, ck_q[ce_q], 32'd1, '0,
                    StRdHop);
            end
          end else if (have && pf_n_q != 2'd0 && pf_a_q[0] == cand) begin
            // prefetch FIFO hit — serve the held line, pop
            cpl_q <= '{status: APU_CMDREC_OK, count: d_count,
                       pdata: '0,
                       rec: apu_cmdrec_rec_t'(pf_d_q[0])};
            pf_a_q[0] <= pf_a_q[1];
            pf_b_q[0] <= pf_b_q[1];
            pf_d_q[0] <= pf_d_q[1];
            pf_n_q    <= pf_n_q - 2'd1;
            cx_q[ce_q] <= req_q.idx;
            ca_q[ce_q] <= cand;
            ck_q[ce_q] <= req_q.idx == 16'h0 ? d_rech : ck_q[ce_q];
            state_q    <= StCpl;
          end else if (have) begin
            pf_n_q    <= '0;
            wk_addr_q <= cand;
            wk_chunk_q <= req_q.idx == 16'h0 ? d_rech
                                             : ck_q[ce_q];
            op_go(APU_OBJPAY_OP_READN, cand, 32'd16, '0, StRdFetch);
          end else begin
            // walk the chain from the head
            pf_n_q     <= '0;
            wk_chunk_q <= d_rech;
            wk_i_q     <= '0;
            wk_addr_q  <= d_rech + 32'(RFIRST);
            state_q    <= StRdWk;
          end
        end
        StRdWk: begin
          if (wk_i_q == 32'(req_q.idx)) begin
            op_go(APU_OBJPAY_OP_READN, wk_addr_q, 32'd16, '0,
                  StRdFetch);
          end else if (in_chunk_next(wk_addr_q, wk_chunk_q)) begin
            wk_addr_q <= wk_addr_q + 32'd16;
            wk_i_q    <= wk_i_q + 32'd1;
          end else begin
            op_go(APU_OBJPAY_OP_READN, wk_chunk_q, 32'd1, '0,
                  StRdHop);
          end
        end
        StRdHop: begin
          if (opc_st_q != APU_OBJPAY_OK || opc_rd_q == 32'h0) begin
            cpl_q   <= '{status: APU_CMDREC_BAD_IDX, count: d_count,
                         pdata: '0, rec: '0};
            state_q <= StCpl;
          end else begin
            wk_chunk_q <= opc_rd_q;
            wk_addr_q  <= opc_rd_q + 32'(RFIRST);
            wk_i_q     <= wk_i_q + 32'd1;
            state_q    <= StRdWk;
          end
        end
        StRdFetch: begin
          if (opc_st_q != APU_OBJPAY_OK) begin
            cpl_q   <= '{status: APU_CMDREC_BAD_IDX, count: d_count,
                         pdata: '0, rec: '0};
            state_q <= StCpl;
          end else begin
            cpl_q <= '{status: APU_CMDREC_OK, count: d_count,
                       pdata: '0,
                       rec: apu_cmdrec_rec_t'(lb_q)};
            cx_q[ce_q]  <= req_q.idx;
            ca_q[ce_q]  <= wk_addr_q;
            ck_q[ce_q]  <= wk_chunk_q;
            cxv_q[ce_q] <= 1'b1;
            pf_n_q      <= '0;
            state_q     <= StCpl;
          end
        end

        // ================ RESET post-free ============================
        StResetDone: begin
          // chains are gone; clear w0..w7 (keep secondary), write the
          // entry back and drop it — the descriptor may be freed next
          cw_q[ce_q][APU_CBD_W0]    <= d_flags &
                                       (32'h1 << APU_CBF_SECONDARY);
          cw_q[ce_q][APU_CBD_COUNT] <= '0;
          cw_q[ce_q][APU_CBD_RECH]  <= '0;
          cw_q[ce_q][APU_CBD_RECT]  <= '0;
          cw_q[ce_q][APU_CBD_ROW]   <= '0;
          cw_q[ce_q][APU_CBD_PAYH]  <= '0;
          cw_q[ce_q][APU_CBD_PAYT]  <= '0;
          cw_q[ce_q][APU_CBD_PTOP]  <= '0;
          cxv_q[ce_q] <= 1'b0;
          pf_n_q      <= '0;
          ev_i_q   <= '0;
          ev_ret_q <= StResetCpl;
          state_q  <= StEvW;
        end
        StResetCpl: begin
          cpl_q   <= '{status: APU_CMDREC_OK, count: '0, pdata: '0,
                       rec: '0};
          state_q <= StCpl;
        end

        // ================ pool walks =================================
        StPoolRd: begin
          if (pl_cur_q == 32'h0) begin
            cpl_q   <= '{status: APU_CMDREC_OK, count: '0, pdata: '0,
                         rec: '0};
            state_q <= StCpl;
          end else begin
            op_go(APU_OBJPAY_OP_READN, pl_cur_q + 32'd8, 32'd4, '0,
                  StPoolDsc);
          end
        end
        StPoolDsc: begin
          if (opc_st_q != APU_OBJPAY_OK) begin
            cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                         pdata: '0, rec: '0};
            state_q <= StCpl;
          end else begin
            pl_own_q  <= lb_q[32 +: 32];   // w9 own handle
            pl_next_q <= lb_q[96 +: 32];   // w11 pool_next
            ob_q      <= pl_cur_q;
            ob_ret_q  <= StPoolFr;
            state_q   <= StOpenGo;
          end
        end
        StPoolFr: begin
          fr_head_q <= d_rech;
          fr_pay_q  <= 1'b1;
          fr_ret_q  <= StPoolClr;
          state_q   <= StFrTop;
        end
        StPoolClr: begin
          cxv_q[ce_q] <= 1'b0;
          pf_n_q      <= '0;
          // register the SWEEP interim (w9 handle in pdata) — it is
          // presented through cpl_o while StPoolSweep runs, matching
          // objtab's registered-SWEEP convention; a combinational
          // drive would vanish the cycle after the handshake
          cpl_q <= '{status: APU_CMDREC_SWEEP, count: '0,
                     pdata: pl_own_q, rec: '0};
          if (req_q.op == APU_CMDREC_OP_RESET_POOL) begin
            // clear fields and write back — the buffer survives
            cw_q[ce_q][APU_CBD_W0]    <= d_flags &
                                         (32'h1 << APU_CBF_SECONDARY);
            cw_q[ce_q][APU_CBD_COUNT] <= '0;
            cw_q[ce_q][APU_CBD_RECH]  <= '0;
            cw_q[ce_q][APU_CBD_RECT]  <= '0;
            cw_q[ce_q][APU_CBD_ROW]   <= '0;
            cw_q[ce_q][APU_CBD_PAYH]  <= '0;
            cw_q[ce_q][APU_CBD_PAYT]  <= '0;
            cw_q[ce_q][APU_CBD_PTOP]  <= '0;
            ev_i_q   <= '0;
            ev_ret_q <= StPoolSweep;
            state_q  <= StEvW;
          end else begin
            // destroy: descriptor dies with this op — drop the entry
            cv_q[ce_q] <= 1'b0;
            cd_q[ce_q] <= 1'b0;
            state_q    <= StPoolSweep;
          end
        end
        StPoolSweep: begin
          // one SWEEP interim completion per buffer (cpl_o carries
          // pdata = its w9 handle combinationally); on accept, DESTROY
          // frees the descriptor block
          if (cpl_ready_i) begin
            if (req_q.op == APU_CMDREC_OP_DESTROY_POOL) begin
              op_go(APU_OBJPAY_OP_FREE, pl_cur_q,
                    32'(APU_CBD_WORDS), '0, StPoolNext);
            end else begin
              state_q <= StPoolNext;
            end
          end
        end
        StPoolNext: begin
          pl_cur_q <= pl_next_q;
          state_q  <= StPoolRd;
        end

        // ================ prefetch ==================================
        StPfHop: begin
          // w0 read of the previous chunk returned opc_rd_q = next
          if (opc_st_q == APU_OBJPAY_OK && opc_rd_q != 32'h0) begin
            pf_pa_q <= opc_rd_q + 32'(RFIRST);
            pf_ck_q <= opc_rd_q;
            op_go(APU_OBJPAY_OP_READN, opc_rd_q + 32'(RFIRST),
                  32'd16, '0, StPfRd);
          end else begin
            state_q <= StIdle;
          end
        end
        StPfRd: begin
          if (opc_st_q == APU_OBJPAY_OK) begin
            pf_a_q[pf_n_q[0]] <= pf_pa_q;
            pf_b_q[pf_n_q[0]] <= pf_ck_q;
            pf_d_q[pf_n_q[0]] <= lb_q;
            pf_n_q         <= pf_n_q + 2'd1;
          end
          state_q <= StIdle;
        end

        // ================ completion ================================
        StCpl: if (cpl_ready_i) state_q <= StIdle;

        default: state_q <= StIdle;
        endcase
      end
    end
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_cmdrec_fixture
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objpay_pkg::*;
#(parameter bit Enable = 1'b0,
  parameter int unsigned CbOpen = 4) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_cmdrec_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_cmdrec_cpl_t cpl_o,
  input  logic            pay_valid_i,
  input  logic [31:0]     pay_data_i,
  output logic            pay_ready_o,
  output logic            op_req_valid_o,
  input  logic            op_req_ready_i,
  output apu_objpay_req_t op_req_o,
  input  logic            op_cpl_valid_i,
  output logic            op_cpl_ready_o,
  input  apu_objpay_cpl_t op_cpl_i
);
  g6lc_apu_cmdrec #(.Enable(Enable), .CbOpen(CbOpen)) i_dut (.*);
endmodule
