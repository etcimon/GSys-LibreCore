// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Submit-time command executor (§6 of
// architecture/uncore/apu-vulkan-engine.md).  A depth-4 submit FIFO
// carries {fence slot, up to 4 command buffers}; each buffer's records
// are read back from cmdrec, every stored handle re-resolved through
// objtab LOOKUP by {gen,slot} so a destroyed object between record and
// submit loses the submission (DEVICE_LOST on the fence).  State
// records update the executor state registers; work records are issued
// on work_valid_o/work_ready_i with a state snapshot; PipelineBarrier
// and submit end drain outstanding work via work_done_i.  Buffers are
// PINned at submit and UNPINned when their records complete.
//
// done_seq_o counts completed submissions; fence_signaled_o /
// fence_lost_o give the WAIT class per-fence OK / DEVICE_LOST;
// fence_clr_i (one-cycle mask pulse) implements vkResetFences.
//
// Timing impact: one objtab or cmdreq transaction per micro-step, all
// handshakes registered; the widest cones are the 512-bit record
// unpacking and the state-register update mux.  The submit FIFO and
// state registers are flops; no SRAM.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; Enable=0 elaborates no datapath; done_seq wraps mod 2^16.

module g6lc_apu_cmdexec
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Fences = 16
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               testmode_i,
  input  logic               submit_valid_i,
  output logic               submit_ready_o,
  input  apu_cmdexec_submit_t submit_i,
  output logic               cr_req_valid_o,
  input  logic               cr_req_ready_i,
  output apu_cmdrec_req_t    cr_req_o,
  input  logic               cr_cpl_valid_i,
  output logic               cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t    cr_cpl_i,
  output logic               ot_req_valid_o,
  input  logic               ot_req_ready_i,
  output apu_objtab_req_t    ot_req_o,
  input  logic               ot_cpl_valid_i,
  output logic               ot_cpl_ready_o,
  input  apu_objtab_cpl_t    ot_cpl_i,
  // §7b/5a-ii: ObjPay port (descriptor-set storage reads during
  // dispatch assembly; grant-arbitrated with vnfront in vgtop)
  output logic               op_req_valid_o,
  input  logic               op_req_ready_i,
  output apu_objpay_req_t    op_req_o,
  input  logic               op_cpl_valid_i,
  output logic               op_cpl_ready_o,
  input  apu_objpay_cpl_t    op_cpl_i,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  // §7b/5a-ii: shcore dispatch sideband (valid with work_o)
  output apu_xfer_desc_t     xf_o,   // §12.3 C/5a: Xfer operand desc
  output logic [2:0]         disp_slot_o,
  output logic [16*113-1:0]  binds_o,
  output logic [5:0]         push_n_o,
  output logic [1023:0]      push_o,
  output logic [15:0]        done_seq_o,
  output logic [Fences-1:0]  fence_signaled_o,
  output logic [Fences-1:0]  fence_lost_o,
  input  logic [Fences-1:0]  fence_clr_i,
  // drained indication: FSM idle, submit FIFO empty, no outstanding
  // work items (used by the vgsys idle_o / reset sequencer)
  output logic               busy_o
);
  if (!Enable) begin : gen_off
    assign submit_ready_o  = 1'b0;
    assign busy_o          = 1'b0;
    assign cr_req_valid_o  = 1'b0;
    assign cr_req_o        = '0;
    assign cr_cpl_ready_o  = 1'b0;
    assign ot_req_valid_o  = 1'b0;
    assign ot_req_o        = '0;
    assign ot_cpl_ready_o  = 1'b0;
    assign op_req_valid_o  = 1'b0;
    assign op_req_o        = '0;
    assign op_cpl_ready_o  = 1'b0;
    assign work_valid_o    = 1'b0;
    assign work_o          = '0;
    assign xf_o            = '0;
    assign disp_slot_o     = '0;
    assign binds_o         = '0;
    assign push_n_o        = '0;
    assign push_o          = '0;
    assign done_seq_o      = '0;
    assign fence_signaled_o = '0;
    assign fence_lost_o    = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | submit_valid_i |
                    cr_req_ready_i | cr_cpl_valid_i | (|cr_cpl_i) |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    op_req_ready_i | op_cpl_valid_i | (|op_cpl_i) |
                    work_ready_i | work_done_i | (|work_done_pl_i) |
                    (|fence_clr_i) | (|submit_i);
  end else begin : gen_on
    localparam int unsigned Fifo = 4;
    localparam logic [4:0]   FENCE_NONE = 5'd31;

    typedef enum logic [5:0] {
      StIdle, StPinReq, StPinCpl, StCntReq, StCntCpl,
      StRdReq, StRdCpl, StResReq, StResCpl, StDispatch,
      StWork, StDrain, StUnpReq, StUnpCpl, StNextBuf,
      StBufDone, StFinalDrain, StDone,
      StPayReq, StPayCpl,
      // §7b/5a-ii: dispatch assembly
      StDsPipeReq, StDsPipeCpl,
      StDsSetCk, StDsSetCkN, StDsSetReq, StDsSetCpl,
      StDsBndRd, StDsBndCpl, StDsBufChk,
      StDsBufReq, StDsBufCpl,
      StDsMemReq, StDsMemCpl,
      StDsIssue, StDsDone,
      // §12.3 C/5a: Xfer operand assembly (buffer LOOKUP + bound-memory
      // READSLOT per operand, then the record issues on StWork)
      StXfBufReq, StXfBufCpl, StXfMemReq, StXfMemCpl
    } state_e;
    state_e              state_q;
    // submit FIFO (flops)
    apu_cmdexec_submit_t fifo_q [Fifo];
    logic [2:0]          fifo_head_q, fifo_tail_q, fifo_n_q;
    // execution registers
    apu_cmdexec_submit_t cur_q;
    logic [2:0]          buf_i_q;       // buffer index within submit
    logic [2:0]          pin_i_q;       // pin substep
    logic [7:0]          rec_i_q;       // record cursor
    logic [7:0]          rec_n_q;       // record count
    apu_cmdrec_rec_t     rec_q;         // current record
    logic [2:0]          h_i_q;         // handle resolve cursor
    logic [5:0]          pay_i_q;       // §7b arena read cursor
    logic [5:0]          pay_n_q;       // §7b arena reads left
    logic                pay_push_q;    // walk feeds the push shadow
    logic [5:0]          pay_dst_q;     // push shadow word offset
    logic [3:0]          pinned_q;      // per-buffer pin success
    logic                lost_q;        // DEVICE_LOST on this submit
    logic [7:0]          outst_q;       // outstanding work items
    logic [15:0]         done_seq_q;
    logic [Fences-1:0]   fsig_q, flost_q;
    apu_cmdexec_state_t  snap_q;
    // §7b/5a-ii: dispatch assembly state
    logic [2:0]          ds_slot_q;     // resolved module slot
    logic [1:0]          ds_set_q;      // set index 0..3
    logic [15:0]         ds_base_q, ds_words_q; // set storage extent
    logic [15:0]         ds_j_q;        // binding position cursor
    logic [1:0]          ds_k_q;        // entry word cursor 0..3
    logic [3:0][31:0]    ds_ent_q;      // {handle,off,rng,type|unsup}
    logic [4:0]          ds_n_q;        // bind-table count (<=16)
    logic [63:0]         ds_eoff_q;     // bind_offset + descriptor offset
    logic [63:0]         ds_bsz_q;      // buffer size
    logic [15:0]         ds_memslot_q;  // bound memory slot
    logic [16*113-1:0]   binds_q;       // {set,binding,base,size,valid}×16
    logic [1023:0]       push_sh_q;     // 32-word push shadow
    logic [5:0]          push_max_q;    // highest written word + 1
    // §12.3 C/5a: Xfer assembly — operand cursor and resolved extents
    logic                xf_opnd_q;     // 0 = src (COPY) / dst (others)
    logic [15:0]         xf_ms_q;       // bound memory slot
    logic [63:0]         xf_bo_q;       // buffer bind_offset
    logic [63:0]         xf_bs_q;       // buffer size
    logic [31:0]         xf_src_base_q, xf_src_size_q;
    logic [31:0]         xf_dst_base_q, xf_dst_size_q;

    // XFER-class record types, assembled through the StXf* states
    wire work_is_xfer = rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT);
    // operand 0 resolves handle[0] (src for COPY, dst otherwise);
    // operand 1 is COPY's dst at handle[1] — record handles pack the
    // non-commandBuffer lookup slots sequentially from 0 (the same
    // packing StRecFill/StDispatch rely on, e.g. pipeline at [0])
    wire [1:0] xf_hsel = rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT)
                        ? {1'b0, xf_opnd_q} : 2'd0;

    // ---- record classification --------------------------------------
    function automatic apu_cmdexec_cls_e rec_cls(logic [31:0] t);
      case (t)
        APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT,
        APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT,
        APU_VN_TYPE_VK_CMD_BIND_VERTEX_BUFFERS_EXT,
        APU_VN_TYPE_VK_CMD_BIND_INDEX_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT,
        APU_VN_TYPE_VK_CMD_SET_VIEWPORT_EXT,
        APU_VN_TYPE_VK_CMD_SET_SCISSOR_EXT,
        APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT,
        APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_2_EXT,
        APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT,
        APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT,
        APU_VN_TYPE_VK_CMD_END_RENDER_PASS_2_EXT,
        APU_VN_TYPE_VK_CMD_RESET_QUERY_POOL_EXT,
        APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT,
        APU_VN_TYPE_VK_CMD_END_QUERY_EXT,
        APU_VN_TYPE_VK_CMD_WRITE_TIMESTAMP_EXT:
          return APU_CMDEXEC_CLS_STATE;
        APU_VN_TYPE_VK_CMD_PIPELINE_BARRIER_EXT:
          return APU_CMDEXEC_CLS_BARRIER;
        APU_VN_TYPE_VK_CMD_DRAW_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_DISPATCH_EXT,
        APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_COPY_IMAGE_TO_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_BLIT_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_CLEAR_COLOR_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_CLEAR_DEPTH_STENCIL_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT,
        APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_EXECUTE_COMMANDS_EXT:
          return APU_CMDEXEC_CLS_WORK;
        default: return APU_CMDEXEC_CLS_NOP;
      endcase
    endfunction

    // ---- port steering -----------------------------------------------
    assign submit_ready_o = fifo_n_q != 3'(Fifo);
    assign busy_o         = state_q != StIdle || fifo_n_q != 3'd0 ||
                            outst_q != 8'd0;
    assign done_seq_o     = done_seq_q;
    assign fence_signaled_o = fsig_q;
    assign fence_lost_o   = flost_q;
    assign cr_cpl_ready_o = 1'b1;
    assign ot_cpl_ready_o = 1'b1;
    assign op_cpl_ready_o = 1'b1;
    assign disp_slot_o    = ds_slot_q;
    // §12.3 C/5a: assembled Xfer descriptor — valid with work_o for
    // XFER-class records (the engine replays the U64 operands out of
    // the record's payload arena at pay_base = imm[7])
    assign xf_o = '{op: rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT)
                        ? APU_XFER_OP_COPY :
                    rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT)
                        ? APU_XFER_OP_FILL : APU_XFER_OP_UPDATE,
                   cbuf:     cur_q.crec[buf_i_q[1:0]],
                   pay_base: rec_q.imm[7][15:0],
                   regions:  rec_q.imm[0][15:0],
                   src_base: xf_src_base_q, src_size: xf_src_size_q,
                   dst_base: xf_dst_base_q, dst_size: xf_dst_size_q};
    assign binds_o        = binds_q;
    assign push_n_o       = push_max_q;
    assign push_o         = push_sh_q;

    always_comb begin
      cr_req_valid_o = 1'b0;
      cr_req_o       = '0;
      ot_req_valid_o = 1'b0;
      ot_req_o       = '0;
      op_req_valid_o = 1'b0;
      op_req_o       = '0;
      work_valid_o   = 1'b0;
      work_o         = '0;
      case (state_q)
        StPinReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_PIN,
                             id: {32'h0, cur_q.chndl[pin_i_q[1:0]]},
                             kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                             default: '0};
        end
        StCntReq: begin
          cr_req_valid_o = 1'b1;
          cr_req_o       = '{op: APU_CMDREC_OP_COUNT,
                             cbuf: cur_q.crec[buf_i_q[1:0]],
                             default: '0};
        end
        StRdReq: begin
          cr_req_valid_o = 1'b1;
          cr_req_o       = '{op: APU_CMDREC_OP_READ,
                             cbuf: cur_q.crec[buf_i_q[1:0]],
                             idx: rec_i_q, default: '0};
        end
        StResReq: begin
          ot_req_valid_o = h_i_q != 3'd4 &&
                           rec_q.handle[h_i_q[1:0]] != 32'h0;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, rec_q.handle[h_i_q[1:0]]},
                             kind: 6'(rec_q.kind[h_i_q[1:0]]),
                             default: '0};
        end
        StPayReq: begin
          cr_req_valid_o = 1'b1;
          // the PushConstants arena payload keeps the offset+size
          // header words (pay[0..1]); the values start at +2
          cr_req_o       = '{op: APU_CMDREC_OP_PAYREAD,
                             cbuf: cur_q.crec[buf_i_q[1:0]],
                             idx: 16'(rec_q.imm[7] + 32'(pay_i_q) +
                                      (pay_push_q ? 32'd2 : 32'd0)),
                             default: '0};
        end
        StDsPipeReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, snap_q.pipeline},
                             kind: 6'(APU_VN_KIND_VK_PIPELINE),
                             default: '0};
        end
        StDsSetReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, snap_q.dset[ds_set_q]},
                             kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                             default: '0};
        end
        StDsBndRd: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: {16'h0, ds_base_q} +
                                   (32'(ds_j_q) << 2) + 32'(ds_k_q),
                             default: '0};
        end
        StDsBufReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, ds_ent_q[0]},
                             kind: 6'(APU_VN_KIND_VK_BUFFER),
                             default: '0};
        end
        StDsMemReq: begin
          ot_req_valid_o = 1'b1;
          // §7b: READSLOT must be live && kind == VkDeviceMemory
          ot_req_o       = '{op: APU_OBJTAB_OP_READSLOT,
                             id: {48'h0, ds_memslot_q},
                             kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
                             default: '0};
        end
        StDsIssue: begin
          work_valid_o = 1'b1;
          work_o       = '{ctype: rec_q.ctype, snap: snap_q, rec: rec_q};
        end
        StXfBufReq: begin
          // §5a: re-resolve the operand buffer (kind already proven by
          // the StRes walk; we need the live entry fields)
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, rec_q.handle[xf_hsel]},
                             kind: 6'(APU_VN_KIND_VK_BUFFER),
                             default: '0};
        end
        StXfMemReq: begin
          ot_req_valid_o = 1'b1;
          // same seam as the dispatch path: READSLOT the bound memory
          ot_req_o       = '{op: APU_OBJTAB_OP_READSLOT,
                             id: {48'h0, xf_ms_q},
                             kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
                             default: '0};
        end
        StUnpReq: begin
          ot_req_valid_o = pinned_q[buf_i_q[1:0]];
          ot_req_o       = '{op: APU_OBJTAB_OP_UNPIN,
                             id: {32'h0, cur_q.chndl[buf_i_q[1:0]]},
                             kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                             default: '0};
        end
        StWork: begin
          work_valid_o = 1'b1;
          work_o       = '{ctype: rec_q.ctype, snap: snap_q, rec: rec_q};
        end
        default: ;
      endcase
    end

    // ---- sequential --------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q     <= StIdle;
        for (int i = 0; i < Fifo; i++) fifo_q[i] <= '0;
        fifo_head_q <= '0;
        fifo_tail_q <= '0;
        fifo_n_q    <= '0;
        cur_q       <= '0;
        buf_i_q     <= '0;
        pin_i_q     <= '0;
        rec_i_q     <= '0;
        rec_n_q     <= '0;
        rec_q       <= '0;
        h_i_q       <= '0;
        pay_i_q     <= '0;
        pay_n_q     <= '0;
        pinned_q    <= '0;
        lost_q      <= 1'b0;
        outst_q     <= '0;
        done_seq_q  <= '0;
        fsig_q      <= '0;
        flost_q     <= '0;
        snap_q      <= '0;
        ds_slot_q   <= '0;
        ds_set_q    <= '0;
        ds_base_q   <= '0;
        ds_words_q  <= '0;
        ds_j_q      <= '0;
        ds_k_q      <= '0;
        ds_ent_q    <= '0;
        ds_n_q      <= '0;
        ds_eoff_q   <= '0;
        ds_bsz_q    <= '0;
        ds_memslot_q <= '0;
        binds_q     <= '0;
        push_sh_q   <= '0;
        push_max_q  <= '0;
        pay_push_q  <= 1'b0;
        pay_dst_q   <= '0;
        xf_opnd_q   <= '0;
        xf_ms_q     <= '0;
        xf_bo_q     <= '0;
        xf_bs_q     <= '0;
        xf_src_base_q <= '0; xf_src_size_q <= '0;
        xf_dst_base_q <= '0; xf_dst_size_q <= '0;
      end else begin
        // work completions retire outstanding items; a non-OK done
        // code (§7b/5a-ii: FAULT/BUDGET/UNSUPPORTED from shcore)
        // marks the submission lost
        if (work_done_i && outst_q != 8'h0) outst_q <= outst_q - 8'h1;
        if (work_done_i && work_done_pl_i.code != 8'(APU_SH_DONE_OK))
          lost_q <= 1'b1;
`ifdef G6LC_CEX_TRACE
        if (work_done_i)
          $display("[cex] work done code=%0d outst=%0d",
                   work_done_pl_i.code, outst_q);
`endif
        // fence clear mask (vkResetFences)
        fsig_q  <= fsig_q & ~fence_clr_i;
        flost_q <= flost_q & ~fence_clr_i;
        // submit FIFO push
        if (submit_valid_i && submit_ready_o) begin
          fifo_q[fifo_tail_q[1:0]] <= submit_i;
          fifo_tail_q <= fifo_tail_q + 3'd1;
          fifo_n_q    <= fifo_n_q + 3'd1;
        end

        case (state_q)
          StIdle: begin
            if (fifo_n_q != 3'd0) begin
`ifdef G6LC_CEX_TRACE
              $display("[cex] submit pop nbufs=%0d fence=%0d crec=%p chndl=%p",
                       fifo_q[fifo_head_q[1:0]].nbufs,
                       fifo_q[fifo_head_q[1:0]].fence_idx,
                       fifo_q[fifo_head_q[1:0]].crec,
                       fifo_q[fifo_head_q[1:0]].chndl);
`endif
              cur_q       <= fifo_q[fifo_head_q[1:0]];
              fifo_head_q <= fifo_head_q + 3'd1;
              fifo_n_q    <= fifo_n_q - 3'd1;
              pin_i_q     <= '0;
              buf_i_q     <= '0;
              pinned_q    <= '0;
              lost_q      <= 1'b0;
              state_q     <= fifo_q[fifo_head_q[1:0]].nbufs == 3'd0
                             ? StDone : StPinReq;
            end
          end

          // ---- pin each buffer's objtab handle ----------------------
          StPinReq: if (ot_req_ready_i) state_q <= StPinCpl;
          StPinCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status == APU_OBJTAB_OK)
              pinned_q[pin_i_q[1:0]] <= 1'b1;
            else
              lost_q <= 1'b1;
            if (pin_i_q + 3'd1 >= {2'b0, cur_q.nbufs}) begin
              state_q <= StCntReq;
            end else begin
              pin_i_q <= pin_i_q + 3'd1;
              state_q <= StPinReq;
            end
          end

          // ---- per-buffer record walk --------------------------------
          StCntReq: if (cr_req_ready_i) state_q <= StCntCpl;
          StCntCpl: if (cr_cpl_valid_i) begin
`ifdef G6LC_CEX_TRACE
            $display("[cex] cnt cbuf=%0d status=%0d count=%0d",
                     cur_q.crec[buf_i_q[1:0]], cr_cpl_i.status,
                     cr_cpl_i.count);
`endif
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else if (cr_cpl_i.count == 8'h0) begin
              state_q <= StUnpReq;
            end else begin
              rec_n_q <= cr_cpl_i.count;
              rec_i_q <= '0;
              state_q <= StRdReq;
            end
          end
          StRdReq: if (cr_req_ready_i) state_q <= StRdCpl;
          StRdCpl: if (cr_cpl_valid_i) begin
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
`ifdef G6LC_CEX_TRACE
              $display("[cex] rec buf=%0d idx=%0d ctype=%08x",
                       buf_i_q, rec_i_q, cr_cpl_i.rec.ctype);
`endif
              rec_q   <= cr_cpl_i.rec;
              h_i_q   <= '0;
              state_q <= StResReq;
            end
          end

          // ---- re-resolve stored handles -----------------------------
          StResReq: begin
            if (h_i_q == 3'd4) begin
              state_q <= StDispatch;
            end else if (rec_q.handle[h_i_q[1:0]] == 32'h0) begin
              h_i_q <= h_i_q + 3'd1;
            end else if (ot_req_valid_o && ot_req_ready_i) begin
              state_q <= StResCpl;
            end
          end
          StResCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              // stale generation / dead object: submission lost
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              h_i_q   <= h_i_q + 3'd1;
              state_q <= StResReq;
            end
          end

          // ---- §7b: BindDescriptorSets arena walk ---------------------
          StPayReq: if (cr_req_ready_i) state_q <= StPayCpl;
          StPayCpl: if (cr_cpl_valid_i) begin
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              if (pay_push_q) begin
                // §7b: merge the PushConstants payload into the
                // 32-word shadow at the imm[1] word offset
                push_sh_q[32*(pay_dst_q + pay_i_q) +: 32] <=
                    cr_cpl_i.pdata;
                if (pay_dst_q + pay_i_q + 6'd1 > push_max_q)
                  push_max_q <= pay_dst_q + pay_i_q + 6'd1;
              end else begin
                snap_q.dset[2'(rec_q.imm[1] + {26'h0, pay_i_q})] <=
                    cr_cpl_i.pdata;
              end
              pay_i_q <= pay_i_q + 6'd1;
              state_q <= pay_i_q + 6'd1 >= pay_n_q
                         ? StNextBuf : StPayReq;
            end
          end

          // ---- dispatch ----------------------------------------------
          StDispatch: begin
            case (rec_cls(rec_q.ctype))
              APU_CMDEXEC_CLS_STATE: begin
                case (rec_q.ctype)
                  APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT:
                    snap_q.pipeline <= rec_q.handle[0];
                  APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT: begin
                    // §7b: resolved set handles live in the payload
                    // arena at imm[7]; write firstSet..firstSet+count-1
                    pay_i_q    <= '0;
                    pay_push_q <= 1'b0;
                    pay_dst_q  <= '0;
                    pay_n_q    <= 6'(rec_q.imm[1] < 32'd4
                                  ? (rec_q.imm[2] < 32'd4 - rec_q.imm[1]
                                     ? rec_q.imm[2] : 32'd4 - rec_q.imm[1])
                                  : 32'd0);
                  end
                  APU_VN_TYPE_VK_CMD_BIND_VERTEX_BUFFERS_EXT:
                    snap_q.vtx <= rec_q.handle[1];
                  APU_VN_TYPE_VK_CMD_BIND_INDEX_BUFFER_EXT:
                    snap_q.ibo <= rec_q.handle[1];
                  APU_VN_TYPE_VK_CMD_SET_VIEWPORT_EXT:
                    snap_q.vp <= rec_q.imm[0];
                  APU_VN_TYPE_VK_CMD_SET_SCISSOR_EXT:
                    snap_q.sc <= rec_q.imm[0];
                  APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT: begin
                    snap_q.push      <= rec_q.imm[0][15:0];
                    // imm[7] = payload arena base (forced by cmdrec)
                    snap_q.push_base <= rec_q.imm[7][15:0];
                    snap_q.push_len  <= rec_q.imm[2][15:0];
                    // §7b/5a-ii: merge the arena words into the push
                    // shadow at the imm[1] byte offset (word units),
                    // clamped to the 32-word shadow
                    pay_i_q    <= '0;
                    pay_push_q <= 1'b1;
                    pay_dst_q  <= 6'(rec_q.imm[1] >> 2);
                    pay_n_q    <= rec_q.imm[1] >= 32'd128
                                  ? 6'd0
                                  : (rec_q.imm[2] >> 2) >
                                    32'd32 - (rec_q.imm[1] >> 2)
                                    ? 6'(32'd32 - (rec_q.imm[1] >> 2))
                                    : 6'(rec_q.imm[2] >> 2);
                  end
                  APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT,
                  APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_2_EXT: begin
                    snap_q.rp_active <= 1'b1;
                    snap_q.subpass   <= '0;
                  end
                  APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT:
                    snap_q.subpass <= snap_q.subpass + 4'd1;
                  APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT,
                  APU_VN_TYPE_VK_CMD_END_RENDER_PASS_2_EXT:
                    snap_q.rp_active <= 1'b0;
                  default: ;
                endcase
                state_q <=
                    (rec_q.ctype ==
                         APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT &&
                     rec_q.imm[1] < 32'd4 && rec_q.imm[2] != 32'h0) ||
                    (rec_q.ctype ==
                         APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT &&
                     rec_q.imm[1] < 32'd128 && rec_q.imm[2] >= 32'd4)
                    ? StPayReq : StNextBuf;
              end
              APU_CMDEXEC_CLS_WORK: begin
                if (rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT)) begin
                  // §7b/5a-ii: no bound pipeline -> DEVICE_LOST, no
                  // dispatch is issued
                  if (snap_q.pipeline == 32'h0) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else begin
                    binds_q <= '0;
                    state_q <= StDsPipeReq;
                  end
                end else if (work_is_xfer) begin
                  // §12.3 C/5a: resolve the operands before issue
                  xf_opnd_q <= 1'b0;
                  state_q   <= StXfBufReq;
                end else begin
                  state_q <= StWork;
                end
              end
              APU_CMDEXEC_CLS_BARRIER:  state_q <= StDrain;
              default:                  state_q <= StNextBuf;
            endcase
          end
          StWork: if (work_ready_i) begin
`ifdef G6LC_CEX_TRACE
            $display("[cex] work issue ctype=%08x dst=%08x+%08x src=%08x+%08x",
                     rec_q.ctype, xf_dst_base_q, xf_dst_size_q,
                     xf_src_base_q, xf_src_size_q);
`endif
            outst_q <= outst_q + 8'h1 -
                       ((work_done_i && outst_q != 8'h0) ? 8'h1 : 8'h0);
            state_q <= StNextBuf;
          end

          // ---- §7b/5a-ii: dispatch assembly --------------------------
          // pipeline -> {slot, layout}
          StDsPipeReq: if (ot_req_ready_i) state_q <= StDsPipeCpl;
          StDsPipeCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_slot_q <= ot_cpl_i.entry.aux[2:0];
              ds_set_q  <= '0;
              ds_n_q    <= '0;
              state_q   <= StDsSetCk;
            end
          end
          // sets 0..3 from snap.dset: null entries are skipped
          StDsSetCk: begin
            if (ds_set_q == 2'd3) begin
              state_q <= snap_q.dset[2'd3] == 32'h0
                         ? StDsIssue : StDsSetReq;
            end else if (snap_q.dset[ds_set_q] == 32'h0) begin
              ds_set_q <= ds_set_q + 2'd1;
            end else begin
              state_q <= StDsSetReq;
            end
          end
          // zero-binding set: advance without a binding loop
          StDsSetCkN: begin
            if (ds_set_q == 2'd3) begin
              state_q <= StDsIssue;
            end else begin
              ds_set_q <= ds_set_q + 2'd1;
              state_q  <= StDsSetCk;
            end
          end
          StDsSetReq: if (ot_req_ready_i) state_q <= StDsSetCpl;
          StDsSetCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              // aux[63:32] = {objpay base, words}; entries are 4 words
              ds_base_q  <= ot_cpl_i.entry.aux[63:48];
              ds_words_q <= ot_cpl_i.entry.aux[47:32];
              ds_j_q     <= '0;
              ds_k_q     <= '0;
              state_q    <= ot_cpl_i.entry.aux[47:32] == 16'h0
                            ? StDsSetCkN : StDsBndRd;
            end
          end
          // per binding: 4-word entry {handle, offset, range, type|unsup}
          StDsBndRd:  if (op_req_ready_i) state_q <= StDsBndCpl;
          StDsBndCpl: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_ent_q[ds_k_q] <= op_cpl_i.rdata;
              if (ds_k_q == 2'd3) begin
                ds_k_q  <= '0;
                state_q <= StDsBufChk;
              end else begin
                ds_k_q  <= ds_k_q + 2'd1;
                state_q <= StDsBndRd;
              end
            end
          end
          StDsBufChk: begin
            // unsupported flag (word3 bit31), unbound handle, or a
            // full bind table -> DEVICE_LOST
            if (ds_ent_q[3][31] || ds_ent_q[0] == 32'h0 ||
                ds_n_q == 5'd16) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              state_q <= StDsBufReq;
            end
          end
          // buffer -> {bind_mem_slot, bind_offset, size}
          StDsBufReq: if (ot_req_ready_i) state_q <= StDsBufCpl;
          StDsBufCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else if (ot_cpl_i.entry.bind_mem_slot == 16'hFFFF) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_memslot_q <= ot_cpl_i.entry.bind_mem_slot;
              ds_eoff_q    <= ot_cpl_i.entry.bind_offset +
                              {32'h0, ds_ent_q[1]};
              ds_bsz_q     <= ot_cpl_i.entry.size;
              state_q      <= StDsMemReq;
            end
          end
          // memory slot -> aperture base in aux[63:32]
          StDsMemReq: if (ot_req_ready_i) state_q <= StDsMemCpl;
          StDsMemCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              automatic logic [63:0] base =
                  {32'h0, ot_cpl_i.entry.aux[63:32]} + ds_eoff_q;
              // bind extent = min(range, buffer.size-eoff,
              // memory.size-eoff): a buffer bound past its memory's
              // end must not let the shader reach the next
              // allocation's pages (defence in depth — BIND also
              // refuses such binds)
              automatic logic [63:0] rem_b =
                  ds_eoff_q >= ds_bsz_q ? 64'h0
                                        : ds_bsz_q - ds_eoff_q;
              automatic logic [63:0] rem_m =
                  ds_eoff_q >= ot_cpl_i.entry.size
                  ? 64'h0 : ot_cpl_i.entry.size - ds_eoff_q;
              automatic logic [63:0] rem   =
                  rem_b < rem_m ? rem_b : rem_m;
              automatic logic [31:0] sz   =
                  {32'h0, ds_ent_q[2]} < rem ? ds_ent_q[2]
                                             : 32'(rem);
              binds_q[16'(ds_n_q) * 113 +: 113] <=
                  {8'(ds_set_q), 8'(ds_j_q[7:0]), base, sz, 1'b1};
              ds_n_q <= ds_n_q + 5'd1;
              if (ds_j_q + 16'd1 >= {2'h0, ds_words_q[15:2]}) begin
                // set's binding list done: advance or issue
                if (ds_set_q == 2'd3) begin
                  state_q <= StDsIssue;
                end else begin
                  ds_set_q <= ds_set_q + 2'd1;
                  state_q  <= StDsSetCk;
                end
              end else begin
                ds_j_q  <= ds_j_q + 16'd1;
                state_q <= StDsBndRd;
              end
            end
          end
          // issue on the shcore work port; wait work_done
          StDsIssue: if (work_ready_i) state_q <= StDsDone;
          StDsDone: if (work_done_i) begin
            state_q <= lost_q || work_done_pl_i.code !=
                       8'(APU_SH_DONE_OK) ? StUnpReq : StNextBuf;
          end
          StDrain: if (outst_q == 8'h0 ||
                       (outst_q == 8'h1 && work_done_i)) begin
            state_q <= StNextBuf;
          end

          // ---- §12.3 C/5a: Xfer operand assembly ----------------------
          // operand buffer -> {bind_mem_slot, bind_offset, size}
          StXfBufReq: if (ot_req_ready_i) state_q <= StXfBufCpl;
          StXfBufCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.bind_mem_slot == APU_OBJTAB_SLOT_NONE ||
                |ot_cpl_i.entry.size[63:32]) begin
              // dead/unbound/over-4 GiB operand: submission lost
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              xf_ms_q <= ot_cpl_i.entry.bind_mem_slot;
              xf_bo_q <= ot_cpl_i.entry.bind_offset;
              xf_bs_q <= ot_cpl_i.entry.size;
              state_q <= StXfMemReq;
            end
          end
          // bound memory slot -> aperture page base (aux[63:32])
          StXfMemReq: if (ot_req_ready_i) state_q <= StXfMemCpl;
          StXfMemCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.kind != 6'(APU_VN_KIND_VK_DEVICE_MEMORY) ||
                |ot_cpl_i.entry.size[63:32] ||
                xf_bo_q > ot_cpl_i.entry.size) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              // operand extent = min(buffer.size, memory.size -
              // bind_offset) — the same defence-in-depth clamp the
              // dispatch path applies; all values are < 4 GiB here
              automatic logic [63:0] rem_m =
                  ot_cpl_i.entry.size - xf_bo_q;
              automatic logic [31:0] xs =
                  xf_bs_q < rem_m ? xf_bs_q[31:0] : rem_m[31:0];
              automatic logic [31:0] xb =
                  ot_cpl_i.entry.aux[63:32] + xf_bo_q[31:0];
              if (rec_q.ctype ==
                  32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT) &&
                  xf_opnd_q == 1'b0) begin
                xf_src_base_q <= xb;
                xf_src_size_q <= xs;
                xf_opnd_q     <= 1'b1;
                state_q       <= StXfBufReq;
              end else begin
                xf_dst_base_q <= xb;
                xf_dst_size_q <= xs;
                state_q       <= StWork;
              end
            end
          end

          // ---- next record / buffer -----------------------------------
          StNextBuf: begin
            if (rec_i_q + 8'h1 < rec_n_q) begin
              rec_i_q <= rec_i_q + 8'h1;
              state_q <= StRdReq;
            end else begin
              state_q <= StUnpReq;
            end
          end
          StUnpReq: begin
            if (!pinned_q[buf_i_q[1:0]]) begin
              state_q <= StBufDone;      // nothing pinned: skip UNPIN
            end else if (ot_req_ready_i) begin
              state_q <= StUnpCpl;
            end
          end
          StUnpCpl: if (ot_cpl_valid_i) state_q <= StBufDone;
          StBufDone: begin
            if (buf_i_q + 3'd1 < {2'b0, cur_q.nbufs}) begin
              buf_i_q <= buf_i_q + 3'd1;
              rec_i_q <= '0;
              state_q <= StCntReq;
            end else begin
              state_q <= StFinalDrain;
            end
          end
          // a submit is complete when all its issued work is done
          StFinalDrain: begin
            if (outst_q == 8'h0 ||
                (outst_q == 8'h1 && work_done_i)) begin
              state_q <= StDone;
            end
          end

          StDone: begin
`ifdef G6LC_CEX_TRACE
            $display("[cex] submit done seq=%0d lost=%0d fence=%0d",
                     done_seq_q + 16'h1, lost_q, cur_q.fence_idx);
`endif
            done_seq_q <= done_seq_q + 16'h1;
            if (cur_q.fence_idx != FENCE_NONE &&
                cur_q.fence_idx < 5'(Fences)) begin
              fsig_q[cur_q.fence_idx[$clog2(Fences)-1:0]] <= 1'b1;
              if (lost_q)
                flost_q[cur_q.fence_idx[$clog2(Fences)-1:0]] <= 1'b1;
            end
            state_q <= StIdle;
          end

          default: state_q <= StIdle;
        endcase
      end
    end
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_cmdexec_fixture
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(parameter bit Enable = 1'b0,
  parameter int unsigned Fences = 16) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               testmode_i,
  input  logic               submit_valid_i,
  output logic               submit_ready_o,
  input  apu_cmdexec_submit_t submit_i,
  output logic               cr_req_valid_o,
  input  logic               cr_req_ready_i,
  output apu_cmdrec_req_t    cr_req_o,
  input  logic               cr_cpl_valid_i,
  output logic               cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t    cr_cpl_i,
  output logic               ot_req_valid_o,
  input  logic               ot_req_ready_i,
  output apu_objtab_req_t    ot_req_o,
  input  logic               ot_cpl_valid_i,
  output logic               ot_cpl_ready_o,
  input  apu_objtab_cpl_t    ot_cpl_i,
  output logic               op_req_valid_o,
  input  logic               op_req_ready_i,
  output apu_objpay_req_t    op_req_o,
  input  logic               op_cpl_valid_i,
  output logic               op_cpl_ready_o,
  input  apu_objpay_cpl_t    op_cpl_i,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  output logic [2:0]         disp_slot_o,
  output logic [16*113-1:0]  binds_o,
  output logic [5:0]         push_n_o,
  output logic [1023:0]      push_o,
  output logic [15:0]        done_seq_o,
  output logic [Fences-1:0]  fence_signaled_o,
  output logic [Fences-1:0]  fence_lost_o,
  input  logic [Fences-1:0]  fence_clr_i,
  output apu_xfer_desc_t     xf_o,
  output logic               busy_o
);
  g6lc_apu_cmdexec #(.Enable(Enable), .Fences(Fences)) i_dut (.*);
endmodule
