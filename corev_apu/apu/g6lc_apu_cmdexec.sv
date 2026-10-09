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
  output apu_sh_desc_t       desc_o, // §12.3 F5 descriptor sideband
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
    assign desc_o          = '0;
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
      // §7b/5a-ii + §12.3 F5: dispatch assembly — pipeline -> pipeline
      // layout -> per bound set {layout compat, pool liveness, poison,
      // binding rows}; resolves into the desc sideband, no flop bind
      // table
      StDsPipeReq, StDsPipeCpl,
      StDsLayReq, StDsLayCpl,
      StDsSetCk, StDsSetCkN,
      StDsSlRd, StDsSlRdC, StDsSlHi, StDsSlHiC,
      StDsSlReq, StDsSlCpl,
      StDsSetReq, StDsSetCpl,
      StDsDslReq, StDsDslCpl,
      StDsPoolReq, StDsPoolCpl,
      StDsRowNb, StDsRowNbC,
      StDsRowRd, StDsRowRdC,
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
    logic [6:0]          pay_i_q;       // §7b arena read cursor
    logic [6:0]          pay_n_q;       // §7b arena reads left
    logic                pay_push_q;    // walk feeds the push shadow
    logic [5:0]          pay_dst_q;     // push shadow word offset
    logic [2:0]          pay_nset_q;    // bind walk: sets in the call
    logic [3:0][4:0]     pay_dnb_q;     // bind walk: ndyn per set
                                        // (call order)
    logic [3:0]          pinned_q;      // per-buffer pin success
    logic                lost_q;        // DEVICE_LOST on this submit
    logic [7:0]          outst_q;       // outstanding work items
    logic [15:0]         done_seq_q;
    logic [Fences-1:0]   fsig_q, flost_q;
    apu_cmdexec_state_t  snap_q;
    // §7b/5a-ii + §12.3 F5: dispatch assembly state
    logic [2:0]          ds_slot_q;     // resolved module slot
    logic [1:0]          ds_set_q;      // set index 0..3
    logic [15:0]         ds_pl_q;       // pipeline-layout slot
    logic [15:0]         ds_plg_q;      // pipeline-layout generation
    logic [15:0]         ds_plpay_q;    // pipeline-layout pay base
    logic [15:0]         ds_plw_q;      // pipeline-layout pay words
    logic [63:0]         ds_slid_q;     // setLayout client id
    logic [31:0]         ds_slo_q;      // setLayout objectpay base
    logic [15:0]         ds_slw_q;      // setLayout payload words
    logic [31:0]         ds_slh_q;      // setLayout handle {gen,slot}
    // §12.3 F5-d: content-hash compatibility — the pipeline layout's
    // DSL carries its FNV-1a row hash in state[31:0]; the bound set's
    // DSL (aux[63:32] {gen,slot}) is READSLOT'd and must hash equal
    logic [31:0]         ds_slhash_q;   // pipeline DSL content hash
    logic [15:0]         ds_sdsl_q;     // set's DSL slot
    logic [15:0]         ds_sdg_q;      // set's DSL generation
    logic [31:0]         ds_pool_q;     // bound set's pool handle
    logic [15:0]         ds_epoch_q;    // bound set's pool epoch
    logic [4:0]          ds_i_q;        // binding-row cursor
    logic [4:0]          ds_nb_q;       // layout binding count
    logic                ds_rh_q;       // row word half (0/1)
    logic [31:0]         ds_rw0_q;      // row word0 {binding,pad,count}
    apu_sh_desc_t        desc_q;        // F5 sideband being assembled
    logic [1023:0]       push_sh_q;     // 32-word push shadow
    logic [5:0]          push_max_q;    // highest written word + 1
    // bind-descriptor-set arena walk cursor
    logic                pay_bind_q;
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
    assign desc_o         = desc_q;
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
        StDsLayReq: begin
          ot_req_valid_o = 1'b1;
          // §12.3 F5: the pipeline layout slot recorded on the
          // pipeline object; no generation tag on READSLOT — the gen
          // check is done against ds_plg_q in the completion
          ot_req_o       = '{op: APU_OBJTAB_OP_READSLOT,
                             id: {48'h0, ds_pl_q},
                             kind: 6'(APU_VN_KIND_VK_PIPELINE_LAYOUT),
                             default: '0};
        end
        StDsSlRd: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: {16'h0, ds_plpay_q} + 32'd2 +
                                   (32'(ds_set_q) << 1),
                             default: '0};
        end
        StDsSlHi: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: {16'h0, ds_plpay_q} + 32'd3 +
                                   (32'(ds_set_q) << 1),
                             default: '0};
        end
        StDsSlReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: APU_VN_ID_TAG | ds_slid_q,
                             kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT),
                             default: '0};
        end
        StDsSetReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, snap_q.dset[ds_set_q]},
                             kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                             default: '0};
        end
        StDsDslReq: begin
          ot_req_valid_o = 1'b1;
          // §12.3 F5-d: the set's own DSL — content hash vs the
          // pipeline layout's (identical-layout objects are
          // Vulkan-compatible; the generation still pins liveness)
          ot_req_o       = '{op: APU_OBJTAB_OP_READSLOT,
                             id: {48'h0, ds_sdsl_q},
                             kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT),
                             default: '0};
        end
        StDsPoolReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_READSLOT,
                             id: {48'h0, ds_pool_q[15:0]},
                             kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_POOL),
                             default: '0};
        end
        StDsRowNb, StDsRowRd: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: state_q == StDsRowNb
                                   ? {16'h0, ds_slo_q[15:0]}
                                   : {16'h0, ds_slo_q[15:0]} + 32'd1 +
                                     (32'(ds_i_q) << 1) +
                                     32'(ds_rh_q),
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
        ds_pl_q     <= '0;   ds_plg_q <= '0;
        ds_plpay_q  <= '0;   ds_plw_q <= '0;
        ds_slid_q   <= '0;   ds_slo_q <= '0;
        ds_slw_q    <= '0;   ds_slh_q <= '0;
        ds_slhash_q <= '0;
        ds_sdsl_q   <= '0;   ds_sdg_q <= '0;
        ds_pool_q   <= '0;   ds_epoch_q <= '0;
        ds_i_q      <= '0;   ds_nb_q <= '0;
        ds_rw0_q    <= '0;
        desc_q      <= '0;
        ds_rh_q     <= '0;
        pay_bind_q  <= 1'b0;
        pay_nset_q  <= '0;   pay_dnb_q <= '0;
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
                push_sh_q[32*(pay_dst_q + pay_i_q[5:0]) +: 32] <=
                    cr_cpl_i.pdata;
                if (pay_dst_q + pay_i_q[5:0] + 6'd1 > push_max_q)
                  push_max_q <= pay_dst_q + pay_i_q[5:0] + 6'd1;
              end else if (pay_bind_q) begin
                // §12.3 F5 bind stream: {set handle, ndyn} pairs for
                // each bound set, then the call's dynamic-offset
                // words — consumed per set in call order
                if (pay_i_q < {pay_nset_q, 1'b0}) begin
                  if (pay_i_q[0] == 1'b0) begin
                    snap_q.dset[2'(rec_q.imm[1] +
                                    {25'h0, pay_i_q[6:1]})] <=
                        cr_cpl_i.pdata;
                  end else begin
                    pay_dnb_q[2'(pay_i_q[6:1])] <=
                        cr_cpl_i.pdata[4:0];
                  end
                end else begin
                  // dynamic-offset word: ordinal w maps to the w-th
                  // dynamic element across the call's sets in order —
                  // sets with ndyn=0 consume no words
                  begin
                    logic [6:0] w;
                    logic [4:0] c1, c2, c3;
                    logic [1:0] bs;
                    logic [4:0] bk;
                    w  = pay_i_q - {1'b0, pay_nset_q, 1'b0};
                    c1 = pay_dnb_q[0];
                    c2 = c1 + pay_dnb_q[1];
                    c3 = c2 + pay_dnb_q[2];
                    if (w < {2'h0, c1}) begin
                      bs = 2'd0; bk = 5'(w);
                    end else if (w < {2'h0, c2}) begin
                      bs = 2'd1; bk = 5'(w - {2'h0, c1});
                    end else if (w < {2'h0, c3}) begin
                      bs = 2'd2; bk = 5'(w - {2'h0, c2});
                    end else begin
                      bs = 2'd3; bk = 5'(w - {2'h0, c3});
                    end
                    if ({1'b0, bs} < {1'b0, pay_nset_q} && bk < 5'd16)
                      snap_q.dyn[2'(rec_q.imm[1] + {30'h0, bs})]
                              [bk[3:0]] <= cr_cpl_i.pdata;
                  end
                end
              end else begin
                snap_q.dset[2'(rec_q.imm[1] + {24'h0, pay_i_q})] <=
                    cr_cpl_i.pdata;
              end
              pay_i_q <= pay_i_q + 7'd1;
              state_q <= pay_i_q + 7'd1 >= pay_n_q
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
                    // §7b/F5: arena stream = {hnd×nset, ndyn×nset,
                    // dyn words}.  firstSet..firstSet+count-1 land in
                    // snap.dset; each set's dynamic offsets refill
                    // snap.dyn[set] wholesale (cleared first).
                    pay_i_q    <= '0;
                    pay_push_q <= 1'b0;
                    pay_dst_q  <= '0;
                    pay_bind_q <= 1'b1;
                    pay_dnb_q  <= '0;
                    pay_nset_q <=
                      3'(rec_q.imm[1] < 32'd4
                         ? (rec_q.imm[2] < 32'd4 - rec_q.imm[1]
                            ? rec_q.imm[2] : 32'd4 - rec_q.imm[1])
                         : 32'd0);
                    pay_n_q    <=
                      7'(2 * (rec_q.imm[1] < 32'd4
                              ? (rec_q.imm[2] < 32'd4 - rec_q.imm[1]
                                 ? rec_q.imm[2] : 32'd4 - rec_q.imm[1])
                              : 32'd0) +
                          (rec_q.imm[3] > 32'd64 ? 32'd64
                                                 : rec_q.imm[3]));
                    for (int i = 0; i < 4; i++)
                      if (rec_q.imm[1] + 32'(i) < 32'd4 &&
                          32'(i) < rec_q.imm[2])
                        snap_q.dyn[2'(rec_q.imm[1] + 32'(i))] <= '0;
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
                    pay_bind_q <= 1'b0;
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
                    desc_q  <= '0;
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
            outst_q <= outst_q + 8'h1 -
                       ((work_done_i && outst_q != 8'h0) ? 8'h1 : 8'h0);
            state_q <= StNextBuf;
          end

          // ---- §7b/5a-ii + §12.3 F5: dispatch assembly ---------------
          // pipeline -> {slot, pipeline-layout {slot,gen}}
          StDsPipeReq: if (ot_req_ready_i) state_q <= StDsPipeCpl;
          StDsPipeCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_slot_q <= ot_cpl_i.entry.aux[2:0];
              ds_pl_q   <= ot_cpl_i.entry.aux[47:32];
              ds_plg_q  <= ot_cpl_i.entry.aux[63:48];
              desc_q    <= '0;
              state_q   <= StDsLayReq;
            end
          end
          // pipeline layout object: live + right generation -> its
          // ObjPay payload {setLayoutCount, pushRangeCount, setLayout
          // ids (2w each), push ranges (3w each)}
          StDsLayReq: if (ot_req_ready_i) state_q <= StDsLayCpl;
          StDsLayCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.kind !=
                    6'(APU_VN_KIND_VK_PIPELINE_LAYOUT) ||
                ot_cpl_i.entry.gen != ds_plg_q) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_plpay_q <= ot_cpl_i.entry.aux[63:48];
              ds_plw_q   <= ot_cpl_i.entry.aux[47:32];
              ds_set_q   <= '0;
              state_q    <= StDsSetCk;
            end
          end
          // sets 0..3: skip the unbound and the set indices the
          // pipeline layout does not declare (setLayoutCount cap is
          // the payload's word count: ids need 2 + 2*s + 1 words)
          StDsSetCk: begin
            if (snap_q.dset[ds_set_q] == 32'h0 ||
                {16'h0, ds_plw_q} <
                    32'd4 + (32'(ds_set_q) << 1)) begin
              if (ds_set_q == 2'd3) state_q <= StDsIssue;
              else                  ds_set_q <= ds_set_q + 2'd1;
            end else begin
              state_q <= StDsSlRd;
            end
          end
          // advance after a resolved/skipped set
          StDsSetCkN: begin
            if (ds_set_q == 2'd3) begin
              state_q <= StDsIssue;
            end else begin
              ds_set_q <= ds_set_q + 2'd1;
              state_q  <= StDsSetCk;
            end
          end
          // pipeline-layout slot s -> setLayout client id (2 objpay
          // words) -> DSL handle {gen,slot}
          StDsSlRd:  if (op_req_ready_i) state_q <= StDsSlRdC;
          StDsSlRdC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_slid_q[31:0] <= op_cpl_i.rdata;
              state_q         <= StDsSlHi;
            end
          end
          StDsSlHi:  if (op_req_ready_i) state_q <= StDsSlHiC;
          StDsSlHiC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_slid_q[63:32] <= op_cpl_i.rdata;
              state_q          <= StDsSlReq;
            end
          end
          StDsSlReq: if (ot_req_ready_i) state_q <= StDsSlCpl;
          StDsSlCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_slh_q <= ot_cpl_i.handle;
              ds_slo_q <= {16'h0, ot_cpl_i.entry.aux[63:48]};
              ds_slw_q <= ot_cpl_i.entry.aux[47:32];
              // §12.3 F5-d: content hash minted at create — the
              // compatibility key against the set's own layout
              ds_slhash_q <= ot_cpl_i.entry.state;
              state_q  <= StDsSetReq;
            end
          end
          // bound set: live, unpoisoned; layout compatibility is by
          // content hash (checked at StDsDslCpl), not object identity
          StDsSetReq: if (ot_req_ready_i) state_q <= StDsSetCpl;
          StDsSetCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.aux[APU_DESC_POISON]) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              desc_q.set_base[ds_set_q] <=
                  {7'h0, ot_cpl_i.entry.aux[24:0]};
              desc_q.dyn_off[ds_set_q]  <= snap_q.dyn[ds_set_q];
              ds_sdsl_q  <= ot_cpl_i.entry.aux[47:32];
              ds_sdg_q   <= ot_cpl_i.entry.aux[63:48];
              ds_pool_q  <= ot_cpl_i.entry.size[31:0];
              ds_epoch_q <= ot_cpl_i.entry.state[15:0];
              state_q    <= StDsDslReq;
            end
          end
          // the set's DSL must still live at its minted generation and
          // hash-identical to the pipeline's layout for this slot
          StDsDslReq: if (ot_req_ready_i) state_q <= StDsDslCpl;
          StDsDslCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.kind !=
                    6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT) ||
                ot_cpl_i.entry.gen != ds_sdg_q ||
                ot_cpl_i.entry.state != ds_slhash_q) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              state_q <= StDsPoolReq;
            end
          end
          // pool liveness: slot resolves, generation and reset epoch
          // still match the values sampled when the set was minted
          StDsPoolReq: if (ot_req_ready_i) state_q <= StDsPoolCpl;
          StDsPoolCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.kind !=
                    6'(APU_VN_KIND_VK_DESCRIPTOR_POOL) ||
                ot_cpl_i.entry.gen != ds_pool_q[31:16] ||
                ot_cpl_i.entry.state[15:0] != ds_epoch_q) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              state_q <= StDsRowNb;
            end
          end
          // layout payload word0 = {pad, nbind}; rows are
          // apu_sh_bindrow_t-packed pairs
          StDsRowNb:  if (op_req_ready_i) state_q <= StDsRowNbC;
          StDsRowNbC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_nb_q <= op_cpl_i.rdata[20:16] != 5'h0
                         ? 5'd16 : 5'(op_cpl_i.rdata[15:0]);
              ds_i_q  <= '0;
              ds_rh_q <= '0;
              state_q <= op_cpl_i.rdata[15:0] == 16'h0
                         ? StDsSetCkN : StDsRowRd;
            end
          end
          StDsRowRd:  if (op_req_ready_i) state_q <= StDsRowRdC;
          StDsRowRdC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else if (!ds_rh_q) begin
              ds_rw0_q <= op_cpl_i.rdata;
              ds_rh_q  <= 1'b1;
              state_q  <= StDsRowRd;
            end else begin
              desc_q.boff[ds_set_q][ds_i_q[3:0]] <=
                  apu_sh_bindrow_t'{binding: ds_rw0_q[31:24],
                                    count:   ds_rw0_q[15:0],
                                    off32:   op_cpl_i.rdata[31:12],
                                    dyn:     op_cpl_i.rdata[11],
                                    dynbase: op_cpl_i.rdata[3:0]};
              ds_rh_q <= 1'b0;
              if (ds_i_q + 5'd1 >= ds_nb_q) begin
                state_q <= StDsSetCkN;
              end else begin
                ds_i_q  <= ds_i_q + 5'd1;
                state_q <= StDsRowRd;
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
                // §12.3 C: an unbacked (lazy type-1, not yet MAP_BLOB'd)
                // memory has no aperture base — the transfer fails
                // truthfully, never silently to a fabricaed offset
                ot_cpl_i.entry.aux[63:32] == APU_MEM_UNBACKED ||
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
  output apu_sh_desc_t       desc_o,
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
