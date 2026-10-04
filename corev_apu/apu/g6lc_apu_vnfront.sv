// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Venus command front-end sequencer (§4c/§6 of
// architecture/uncore/apu-vulkan-engine.md).  One command at a time:
// `start_i` points at the serialized command stream window and the
// reply window; the sequencer runs vndec, classifies through the
// generated APU_VN_ACT table, performs the ObjTab/CmdRec/cmdexec
// side effects of the action class, then runs vnrep when the command
// carries GENERATE_REPLY.  `done_o` reports {result, rep_words,
// fault}; the queue path publishes the consumed element after done.
//
// Class behaviour:
//   ALLOC      ObjTab.ALLOC of the NEW-role id (or each id of the
//              out-handle blob for multi-creates); parent = first
//              LOOKUP handle; vkCreateBuffer/Image record the created
//              size/extent product in entry.size;
//              vkAllocateCommandBuffers also assigns a cmdrec arena
//              index into aux[7:0] (FULL arena ->
//              VK_ERROR_OUT_OF_DEVICE_MEMORY)
//   RETIRE     ObjTab.RETIRE of the RETIRE-role id; CMDBUF retires
//              also free the arena bit (pre-LOOKUP for aux)
//   BIND       ObjTab.SETBIND(resource, memory, offset)
//   QUERY      LOOKUP validation; exec_w filled for the
//              memory-requirements commands (buffer: size rounded up
//              to 256, align 256, typeBits 3; image: w*h*4 rounded up
//              to 4096, align 4096, typeBits 3), vkEnumeratePhysical
//              Devices (registers the client-supplied PD id, exec
//              count) and vkEnumerateDeviceExtensionProperties
//              (count 0)
//   CB_*       CmdRec.BEGIN/END/RESET + lifecycle SETSTATE
//   RECORD     requires RECORDING; appends the resolved record;
//              vkCmd* on a non-recording buffer marks it INVALID
//   SUBMIT     every blob CB id LOOKUPed, EXECUTABLE required;
//              pushes {fence, crec, chndl} to the executor; marks
//              buffers PENDING
//   WAIT       WaitIdle polls pushed==done_seq; WaitForFences polls
//              the fence mask; GetFenceStatus/ResetFences use the
//              executor's signaled/lost/clear vectors
//   POOL_RESET CmdRec.RESET + state clear for every CB of the pool
//   MAP/NOP_OK LOOKUP validation / no-op
//   UNSUPPORTED VK_ERROR_FEATURE_NOT_PRESENT, no reply program
//
// exec_w contract (vnrep EXEC words): filled from the front of the
// device profile (APU_VN_PROFILE[0..63]) at command start, then
// overridden by the semantic fills above in reply-program order.
// REXEC chain bodies for arbitrary chained property structs are a
// follow-up (needs a generated skeleton table); the session only
// exercises chains whose reply bodies are RCONST.
//
// Timing impact: one ObjTab/CmdRec/CS transaction per micro-step; the
// widest cones are the 64-word exec fill and the resolve scan.  No
// SRAM; the CB arena bitmap and pool shadow table are flops.
//
// Review checklist: async active-low reset; no latches; single
// always_ff for state; Enable=0 elaborates no datapath.

module g6lc_apu_vnfront
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Fences = 16,
  parameter int unsigned CbBufs = 16
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               testmode_i,
  input  logic               start_i,
  input  logic [15:0]        cs_base_i,
  input  logic [15:0]        cs_len_i,
  input  logic [15:0]        rep_base_i,
  input  logic [15:0]        rep_len_i,
  input  logic [7:0]         ctx_i,      // ObjTab ctx tag for this stream
  // shared command-stream read port (front reads blob ids while the
  // engines are idle)
  output logic               cs_re_o,
  output logic [15:0]        cs_addr_o,
  input  logic [31:0]        cs_rdata_i,
  // reply write port (vnrep writes through)
  output logic               rep_we_o,
  output logic [15:0]        rep_addr_o,
  output logic [31:0]        rep_wdata_o,
  // ObjTab port
  output logic               ot_req_valid_o,
  input  logic               ot_req_ready_i,
  output apu_objtab_req_t    ot_req_o,
  input  logic               ot_cpl_valid_i,
  output logic               ot_cpl_ready_o,
  input  apu_objtab_cpl_t    ot_cpl_i,
  // CmdRec port
  output logic               cr_req_valid_o,
  input  logic               cr_req_ready_i,
  output apu_cmdrec_req_t    cr_req_o,
  input  logic               cr_cpl_valid_i,
  output logic               cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t    cr_cpl_i,
  // cmdexec submit + fence interface
  output logic               ex_submit_valid_o,
  input  logic               ex_submit_ready_i,
  output apu_cmdexec_submit_t ex_submit_o,
  input  logic [15:0]        ex_done_seq_i,
  input  logic [Fences-1:0]  ex_fence_signaled_i,
  input  logic [Fences-1:0]  ex_fence_lost_i,
  output logic [Fences-1:0]  ex_fence_clr_o,
  // completion
  output logic               busy_o,
  output logic               done_o,
  output logic [31:0]        result_o,
  output logic [15:0]        rep_words_o,
  output logic [3:0]         fault_o
);
  if (!Enable) begin : gen_off
    assign cs_re_o = 1'b0;        assign cs_addr_o = '0;
    assign rep_we_o = 1'b0;       assign rep_addr_o = '0;
    assign rep_wdata_o = '0;
    assign ot_req_valid_o = 1'b0; assign ot_req_o = '0;
    assign ot_cpl_ready_o = 1'b0;
    assign cr_req_valid_o = 1'b0; assign cr_req_o = '0;
    assign cr_cpl_ready_o = 1'b0;
    assign ex_submit_valid_o = 1'b0; assign ex_submit_o = '0;
    assign ex_fence_clr_o = '0;
    assign busy_o = 1'b0;         assign done_o = 1'b0;
    assign result_o = '0;         assign rep_words_o = '0;
    assign fault_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | start_i |
                    cs_rdata_i[0] | ot_req_ready_i | ot_cpl_valid_i |
                    (|ot_cpl_i) | cr_req_ready_i | cr_cpl_valid_i |
                    (|cr_cpl_i) | ex_submit_ready_i | (|ex_done_seq_i) |
                    (|ex_fence_signaled_i) | (|ex_fence_lost_i) |
                    (|cs_base_i) | (|cs_len_i) | (|rep_base_i) |
                    (|rep_len_i);
  end else begin : gen_on
    localparam logic [4:0] FENCE_NONE = 5'd31;

    typedef enum logic [5:0] {
      StIdle, StDec, StDecWait, StResolve, StResCpl, StAct,
      StOtReq, StOtCpl, StCrReq, StCrCpl, StCsRd, StCsCap,
      StBlobRd, StBlobLo, StBlobHi,
      StElemAlloc, StElemAllocCpl, StElemAuxCpl,
      StElemPd, StElemPdCpl,
      StElemSub, StElemSubCpl,
      StElemFenc, StElemFencCpl,
      StElemRec, StElemRecCpl,
      StElemRetL, StElemRetR, StElemRetCpl,
      StAllocGo, StAllocCpl, StAllocAux, StRetCpl, StRetPre,
      StCbGo, StCbCrCpl, StCbSetCpl,
      StRecFill, StRecApp, StAppendCpl,
      StSubPush, StSubState, StSubStateNext,
      StWaitIdle, StFencPoll, StFencClr,
      StPoolLoop, StPoolSet, StPoolNext,
      StRep, StRepKick, StRepWait, StDone
    } state_e;
    state_e              state_q, ot_ret_q, cr_ret_q, cs_ret_q;
    state_e              blob_ret_q, blob_done_q;

    logic [15:0]         cs_base_q, cs_len_q, rep_base_q, rep_len_q;
    apu_vn_op_t          op_q;
    apu_vn_act_t         act_q;
    logic [31:0]         result_q;
    logic                rep_skip_q;
    logic [15:0]         rep_words_q;
    logic [3:0]          fault_q;

    logic [3:0]          res_i_q;      // resolve / record scan cursor
    logic [3:0]          watch_q;      // q slot whose entry to latch
    logic [31:0]         hnd_q [8];    // resolved {gen,slot} per q slot
    apu_objtab_entry_t   ent_q;        // watched entry

    apu_objtab_req_t     otr_q;
    apu_cmdrec_req_t     crr_q;
    logic [15:0]         csa_q;
    logic [31:0]         csw_q;

    logic [4:0]          blob_i_q;     // current blob element
    logic [4:0]          blob_n_q;     // element count
    logic                blob_sel_q;
    logic [63:0]         blob_id_q;
    logic [4:0]          are_i_q;      // pool / sub-state cursor
    logic [23:0]         aux_size_q;   // created size blocks for SETAUX
    logic [7:0]          aux_free_q;   // arena idx freed by a CB retire
    logic                aux_free_v_q;
    apu_cmdexec_submit_t sub_q;
    apu_cmdrec_rec_t     rec_q;
    logic [3:0]          rhi_q;
    logic [Fences-1:0]   fmask_q;
    logic                wall_q;
    logic [15:0]         pushed_q;

    logic [CbBufs-1:0]   cb_alloc_q;
    logic [31:0]         cb_pool_q [CbBufs];
    logic [31:0]         cb_hnd_q  [CbBufs];
    // fence arena: vkCreateFence claims an executor fence index into
    // aux[7:0] (ObjTab slots are global, not per-kind); wait/status/
    // submit resolve the index back out of the entry's aux
    logic [Fences-1:0]   falloc_q;
    logic                aux_fence_q;  // aux_free_q targets falloc_q

    // ---- engines -----------------------------------------------------
    logic        dec_start, dec_re, dec_done, dec_busy;
    logic [15:0] dec_addr;
    apu_vn_op_t  dec_op;
    logic        rep_start, rep_re, rep_done, rep_busy, rep_fault;
    logic [15:0] rep_addr, rep_n;
    logic [64*32-1:0] exec_w_q;
    logic        front_re;
    logic [15:0] front_addr;

    g6lc_apu_vndec #(.Enable(1'b1)) i_dec (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .start_i(dec_start), .cs_base_i(cs_base_q), .cs_len_i(cs_len_q),
      .cs_re_o(dec_re), .cs_addr_o(dec_addr), .cs_rdata_i(cs_rdata_i),
      .busy_o(dec_busy), .done_o(dec_done), .op_o(dec_op));
    g6lc_apu_vnrep #(.Enable(1'b1)) i_rep (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .start_i(rep_start), .op_i(op_q), .result_i(result_q),
      .exec_w_i(exec_w_q), .exec_n_i(7'd64),
      .rep_base_i(rep_base_q), .rep_len_i(rep_len_q),
      .cs_base_i(cs_base_q),
      .cs_re_o(rep_re), .cs_addr_o(rep_addr), .cs_rdata_i(cs_rdata_i),
      .rep_we_o(rep_we_o), .rep_addr_o(rep_addr_o),
      .rep_wdata_o(rep_wdata_o),
      .busy_o(rep_busy), .done_o(rep_done), .rep_words_o(rep_n),
      .fault_o(rep_fault));

    // CS port arbitration: engines win while running; the front reads
    // blob ids in between.
    assign cs_re_o   = dec_re | rep_re | front_re;
    assign cs_addr_o = dec_re ? dec_addr :
                       rep_re ? rep_addr : front_addr;

    assign busy_o      = state_q != StIdle;
    assign done_o      = state_q == StDone;
    assign result_o    = result_q;
    assign rep_words_o = rep_words_q;
    assign fault_o     = fault_q;
    assign ot_cpl_ready_o = 1'b1;
    assign cr_cpl_ready_o = 1'b1;

    // ---- helpers (all take the op record explicitly) -----------------
    function automatic logic need_res(input apu_vn_op_t o, input int i);
      return o.qv[i] && o.qkind[i] != 6'd0 && o.q[i] != 64'h0 &&
             (o.qrole[i] == APU_VN_ROLE_LOOKUP ||
              o.qrole[i] == APU_VN_ROLE_OPTIONAL);
    endfunction
    // nth (0-based) resolve-eligible q slot, -1 if absent
    function automatic int lu_slot(input apu_vn_op_t o, input int n);
      int c = 0;
      for (int i = 0; i < 8; i++)
        if (o.qv[i] && o.qkind[i] != 6'd0 &&
            (o.qrole[i] == APU_VN_ROLE_LOOKUP ||
             o.qrole[i] == APU_VN_ROLE_OPTIONAL)) begin
          if (c == n) return i;
          c++;
        end
      return -1;
    endfunction
    function automatic int role_slot(input apu_vn_op_t o,
                                     input logic [2:0] r);
      for (int i = 0; i < 8; i++)
        if (o.qv[i] && o.qrole[i] == r) return i;
      return -1;
    endfunction
    function automatic int data_slot(input apu_vn_op_t o);
      for (int i = 0; i < 8; i++)
        if (o.qv[i] && o.qkind[i] == 6'd0) return i;
      return -1;
    endfunction
    function automatic logic [7:0] arena_free();
      for (int i = 0; i < CbBufs; i++)
        if (!cb_alloc_q[i]) return 8'(i);
      return 8'hFF;
    endfunction
    function automatic logic [7:0] fence_free();
      for (int i = 0; i < Fences; i++)
        if (!falloc_q[i]) return 8'(i);
      return 8'hFF;
    endfunction

    localparam int ExecNone = 0, ExecBufReq = 1, ExecImgReq = 2,
                 ExecEnumPd = 3, ExecEnumExt = 4, ExecMres = 5;
    function automatic int exec_kind(input logic [31:0] t);
      case (t)
        APU_VN_TYPE_VK_GET_BUFFER_MEMORY_REQUIREMENTS_EXT,
        APU_VN_TYPE_VK_GET_BUFFER_MEMORY_REQUIREMENTS_2_EXT:
          return ExecBufReq;
        APU_VN_TYPE_VK_GET_IMAGE_MEMORY_REQUIREMENTS_EXT,
        APU_VN_TYPE_VK_GET_IMAGE_MEMORY_REQUIREMENTS_2_EXT:
          return ExecImgReq;
        APU_VN_TYPE_VK_ENUMERATE_PHYSICAL_DEVICES_EXT:
          return ExecEnumPd;
        APU_VN_TYPE_VK_ENUMERATE_DEVICE_EXTENSION_PROPERTIES_EXT:
          return ExecEnumExt;
        APU_VN_TYPE_VK_GET_MEMORY_RESOURCE_PROPERTIES_MESA_EXT:
          return ExecMres;
        default: return ExecNone;
      endcase
    endfunction

    function automatic logic [31:0] err_of(apu_objtab_status_e s);
      return s == APU_OBJTAB_FULL ? APU_VK_ERROR_OUT_OF_DEVICE_MEMORY
                                  : APU_VK_ERROR_UNKNOWN;
    endfunction

    // ---- port steering -----------------------------------------------
    always_comb begin
      ot_req_valid_o = 1'b0;    ot_req_o = '0;
      cr_req_valid_o = 1'b0;    cr_req_o = '0;
      ex_submit_valid_o = 1'b0; ex_submit_o = '0;
      front_re = 1'b0;          front_addr = '0;
      dec_start = 1'b0;         rep_start = 1'b0;
      case (state_q)
        StOtReq:   begin ot_req_valid_o = 1'b1; ot_req_o = otr_q; end
        StCrReq:   begin cr_req_valid_o = 1'b1; cr_req_o = crr_q; end
        StCsRd:    begin front_re = 1'b1; front_addr = csa_q;     end
        StSubPush: begin ex_submit_valid_o = 1'b1;
                         ex_submit_o = sub_q;                     end
        StDec:     dec_start = 1'b1;
        StRepKick: rep_start = 1'b1;
        default: ;
      endcase
    end

    // ---- sequential ---------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        ot_ret_q <= StIdle; cr_ret_q <= StIdle; cs_ret_q <= StIdle;
        blob_ret_q <= StIdle; blob_done_q <= StIdle;
        cs_base_q <= '0; cs_len_q <= '0;
        rep_base_q <= '0; rep_len_q <= '0;
        op_q <= '{fault: APU_VN_FAULT_NONE, default: '0};
        act_q <= '0; result_q <= '0; rep_skip_q <= 1'b0;
        rep_words_q <= '0; fault_q <= '0;
        res_i_q <= '0; watch_q <= '0;
        for (int i = 0; i < 8; i++) hnd_q[i] <= '0;
        ent_q <= '0;
        otr_q <= '0; crr_q <= '0; csa_q <= '0; csw_q <= '0;
        blob_i_q <= '0; blob_n_q <= '0; blob_sel_q <= 1'b0;
        blob_id_q <= '0;
        are_i_q <= '0; aux_free_q <= '0; aux_free_v_q <= 1'b0;
        aux_size_q <= '0;
        sub_q <= '0; rec_q <= '0; rhi_q <= '0;
        fmask_q <= '0; wall_q <= 1'b0; pushed_q <= '0;
        cb_alloc_q <= '0; falloc_q <= '0; aux_fence_q <= 1'b0;
        for (int i = 0; i < CbBufs; i++) begin
          cb_pool_q[i] <= '0; cb_hnd_q[i] <= '0;
        end
        exec_w_q <= '0;
        ex_fence_clr_o <= '0;
      end else begin
        ex_fence_clr_o <= '0;
        case (state_q)
          StIdle: if (start_i) begin
            cs_base_q  <= cs_base_i;
            cs_len_q   <= cs_len_i;
            rep_base_q <= rep_base_i;
            rep_len_q  <= rep_len_i;
            fault_q <= '0; rep_words_q <= '0; rep_skip_q <= 1'b0;
            result_q <= APU_VK_SUCCESS;
            for (int i = 0; i < 8; i++) hnd_q[i] <= '0;
            for (int i = 0; i < 64; i++)
              exec_w_q[32*i +: 32] <= APU_VN_PROFILE[i];
            state_q <= StDec;
          end

          StDec: state_q <= StDecWait;
          StDecWait: if (dec_done) begin
            op_q <= dec_op;
            if (dec_op.fault != APU_VN_FAULT_NONE) begin
              result_q   <= APU_VK_ERROR_UNKNOWN;
              fault_q    <= dec_op.fault;
              rep_skip_q <= 1'b1;
              state_q    <= StDone;
            end else if (dec_op.cmd_type > 32'(APU_VN_DEC_TYPE_MAX) ||
                         APU_VN_ACT[dec_op.cmd_type[
                             $clog2(APU_VN_DEC_TYPE_MAX+1)-1:0]]
                             .act_class == APU_VN_ACT_UNSUPPORTED) begin
              result_q   <= APU_VK_ERROR_FEATURE_NOT_PRESENT;
              rep_skip_q <= 1'b1;
              state_q    <= StDone;
            end else begin
              act_q   <= APU_VN_ACT[dec_op.cmd_type[
                           $clog2(APU_VN_DEC_TYPE_MAX+1)-1:0]];
              res_i_q <= '0;
              if (APU_VN_ACT[dec_op.cmd_type[
                      $clog2(APU_VN_DEC_TYPE_MAX+1)-1:0]].act_class
                  inside {APU_VN_ACT_CB_BEGIN, APU_VN_ACT_CB_END,
                          APU_VN_ACT_CB_RESET, APU_VN_ACT_RECORD}) begin
                watch_q <= {1'b0, APU_VN_ACT[dec_op.cmd_type[
                                $clog2(APU_VN_DEC_TYPE_MAX+1)-1:0]]
                                .cmdbuf_qslot};
              end else if (exec_kind(dec_op.cmd_type) == ExecBufReq ||
                           exec_kind(dec_op.cmd_type) == ExecImgReq ||
                           dec_op.cmd_type ==
                           APU_VN_TYPE_VK_GET_FENCE_STATUS_EXT) begin
                automatic int ls = lu_slot(dec_op, 1);
                watch_q <= ls < 0 ? 4'hF : 4'(ls);
              end else if (dec_op.cmd_type ==
                           APU_VN_TYPE_VK_QUEUE_SUBMIT_EXT) begin
                // watch the OPTIONAL fence slot so ent_q.aux carries
                // the executor fence index at submit time
                automatic int fs = -1;
                for (int i = 0; i < 8; i++)
                  if (dec_op.qv[i] &&
                      dec_op.qrole[i] == APU_VN_ROLE_OPTIONAL &&
                      dec_op.q[i] != 64'h0) fs = i;
                watch_q <= fs < 0 ? 4'hF : 4'(fs);
              end else begin
                watch_q <= 4'hF;
              end
              state_q <= StResolve;
            end
          end

          // ---- resolve LOOKUP/OPTIONAL handles -------------------------
          StResolve: begin
            if (res_i_q == 4'd8) begin
              state_q <= StAct;
            end else if (need_res(op_q, res_i_q)) begin
              otr_q  <= '{op: APU_OBJTAB_OP_LOOKUP,
                          id: op_q.q[res_i_q[2:0]],
                          kind: op_q.qkind[res_i_q[2:0]], default: '0};
              ot_ret_q <= StResCpl;
              state_q  <= StOtReq;
            end else begin
              res_i_q <= res_i_q + 4'd1;
            end
          end
          StResCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              hnd_q[res_i_q[2:0]] <= ot_cpl_i.handle;
              if (res_i_q == watch_q) ent_q <= ot_cpl_i.entry;
              res_i_q <= res_i_q + 4'd1;
              state_q <= StResolve;
            end
          end

          // ---- class dispatch -------------------------------------------
          StAct: begin
            unique case (act_q.act_class)
              APU_VN_ACT_NOP_OK, APU_VN_ACT_MAP, APU_VN_ACT_UPDATE:
                state_q <= StRep;
              APU_VN_ACT_QUERY: begin
                case (exec_kind(op_q.cmd_type))
                  // aux[31:8] holds the created size in 256B blocks
                  // (buffers) or 4KiB blocks (images); ALLOC parked it
                  // there via SETAUX.
                  ExecBufReq: begin
                    exec_w_q[0*32 +: 32] <= {ent_q.aux[31:8], 8'h0};
                    exec_w_q[1*32 +: 32] <= '0;
                    exec_w_q[2*32 +: 32] <= 32'd256;
                    exec_w_q[3*32 +: 32] <= '0;
                    exec_w_q[4*32 +: 32] <= 32'd3;
                    state_q <= StRep;
                  end
                  ExecImgReq: begin
                    exec_w_q[0*32 +: 32] <= {ent_q.aux[27:8], 12'h0};
                    exec_w_q[1*32 +: 32] <= {28'h0, ent_q.aux[31:28]};
                    exec_w_q[2*32 +: 32] <= 32'd4096;
                    exec_w_q[3*32 +: 32] <= '0;
                    exec_w_q[4*32 +: 32] <= 32'd3;
                    state_q <= StRep;
                  end
                  ExecEnumPd: begin
                    exec_w_q[0*32 +: 32] <= 32'd1;   // one physical device
                    blob_sel_q  <= 1'b0;
                    blob_i_q    <= '0;
                    blob_n_q    <= op_q.imm[0] != 32'h0 &&
                                   op_q.blob[0].words >= 17'd2
                                   ? 5'd1 : 5'd0;
                    blob_ret_q  <= StElemPd;
                    blob_done_q <= StRep;
                    state_q     <= StBlobRd;
                  end
                  ExecEnumExt: begin
                    // zero extensions: RU32 count + REXBUF count
                    exec_w_q[0*32 +: 32] <= '0;
                    exec_w_q[1*32 +: 32] <= '0;
                    state_q     <= StRep;
                  end
                  ExecMres: begin
                    // vkGetMemoryResourcePropertiesMESA:
                    // memoryTypeBits = 3 (types 0+1 from the profile)
                    exec_w_q[0*32 +: 32] <= 32'd3;
                    state_q     <= StRep;
                  end
                  default: state_q <= StRep;
                endcase
              end
              APU_VN_ACT_ALLOC: begin
                if (role_slot(op_q, APU_VN_ROLE_NEW) >= 0) begin
                  state_q <= StAllocGo;
                end else begin
                  // act flags[1] names the blob slot holding the
                  // out ids (vkAllocateDescriptorSets emits its
                  // pDescriptorSets in blob 1, behind pSetLayouts).
                  blob_sel_q  <= act_q.flags[1];
                  blob_i_q    <= '0;
                  blob_n_q    <= 5'(op_q.blob[act_q.flags[1]].words
                                    >> 1);
                  blob_ret_q  <= StElemAlloc;
                  blob_done_q <= StRep;
                  state_q     <= StBlobRd;
                end
              end
              APU_VN_ACT_RETIRE: begin
                if (role_slot(op_q, APU_VN_ROLE_RETIRE) < 0) begin
                  // blob-carried retire (vkFreeCommandBuffers /
                  // vkFreeDescriptorSets): per-id LOOKUP+RETIRE
                  blob_sel_q  <= 1'b0;
                  blob_i_q    <= '0;
                  blob_n_q    <= 5'(op_q.blob[0].words >> 1);
                  blob_ret_q  <= StElemRetL;
                  blob_done_q <= StRep;
                  state_q     <= StBlobRd;
                end else if (act_q.obj_kind ==
                             6'(APU_VN_KIND_VK_COMMAND_BUFFER) ||
                             act_q.obj_kind ==
                             6'(APU_VN_KIND_VK_FENCE)) begin
                  // pre-LOOKUP: aux[7:0] frees the arena bit
                  otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                               id: op_q.q[
                                   role_slot(op_q, APU_VN_ROLE_RETIRE)],
                               kind: act_q.obj_kind, default: '0};
                  ot_ret_q <= StRetPre;
                  state_q  <= StOtReq;
                end else begin
                  otr_q    <= '{op: APU_OBJTAB_OP_RETIRE,
                               id: op_q.q[
                                   role_slot(op_q, APU_VN_ROLE_RETIRE)],
                               kind: act_q.obj_kind, default: '0};
                  ot_ret_q <= StRetCpl;
                  state_q  <= StOtReq;
                end
              end
              APU_VN_ACT_BIND: begin
                automatic int rs = lu_slot(op_q, 1);
                automatic int ms = lu_slot(op_q, 2);
                automatic int os = data_slot(op_q);
                if (rs < 0 || ms < 0) begin
                  result_q <= APU_VK_ERROR_UNKNOWN;
                  state_q  <= StRep;
                end else begin
                  otr_q <= '{op: APU_OBJTAB_OP_SETBIND,
                             id: {32'h0, hnd_q[rs]},
                             kind: op_q.qkind[rs],
                             mem_id: {32'h0, hnd_q[ms]},
                             offset: os < 0 ? 64'h0 : op_q.q[os],
                             ctx: ctx_i, default: '0};
                  ot_ret_q <= StRetCpl;   // same status mapping
                  state_q  <= StOtReq;
                end
              end
              APU_VN_ACT_CB_BEGIN, APU_VN_ACT_CB_END,
              APU_VN_ACT_CB_RESET, APU_VN_ACT_RECORD:
                state_q <= StCbGo;
              APU_VN_ACT_SUBMIT: begin
                automatic int fs = -1;
                for (int i = 0; i < 8; i++)
                  if (op_q.qv[i] &&
                      op_q.qrole[i] == APU_VN_ROLE_OPTIONAL &&
                      op_q.q[i] != 64'h0) fs = i;
                blob_sel_q  <= 1'b1;
                blob_i_q    <= '0;
                blob_n_q    <= 5'(op_q.blob[1].words >> 1);
                sub_q       <= '{fence_idx:
                                (fs >= 0 &&
                                 ent_q.aux[7:0] < 8'(Fences))
                                ? 5'(ent_q.aux[7:0]) : FENCE_NONE,
                                nbufs: '0, crec: '0, chndl: '0};
                blob_ret_q  <= StElemSub;
                blob_done_q <= StSubPush;
                state_q     <= StBlobRd;
              end
              APU_VN_ACT_WAIT: begin
                case (op_q.cmd_type)
                  APU_VN_TYPE_VK_DEVICE_WAIT_IDLE_EXT,
                  APU_VN_TYPE_VK_QUEUE_WAIT_IDLE_EXT:
                    state_q <= StWaitIdle;
                  APU_VN_TYPE_VK_WAIT_FOR_FENCES_EXT,
                  APU_VN_TYPE_VK_RESET_FENCES_EXT: begin
                    blob_sel_q  <= 1'b0;
                    blob_i_q    <= '0;
                    blob_n_q    <= 5'(op_q.blob[0].words >> 1);
                    fmask_q     <= '0;
                    wall_q      <= op_q.imm[1] != 32'h0;
                    blob_ret_q  <= StElemFenc;
                    blob_done_q <= op_q.cmd_type ==
                                   APU_VN_TYPE_VK_RESET_FENCES_EXT
                                   ? StFencClr : StFencPoll;
                    state_q     <= StBlobRd;
                  end
                  APU_VN_TYPE_VK_GET_FENCE_STATUS_EXT: begin
                    automatic int fs = lu_slot(op_q, 1);
                    if (fs < 0 ||
                        ent_q.aux[7:0] >= 8'(Fences)) begin
                      result_q <= APU_VK_ERROR_UNKNOWN;
                    end else begin
                      automatic int fsb = int'(ent_q.aux[
                                          $clog2(Fences)-1:0]);
                      result_q <= ex_fence_lost_i[fsb]
                          ? APU_VK_ERROR_DEVICE_LOST
                          : ex_fence_signaled_i[fsb]
                            ? APU_VK_SUCCESS : APU_VK_NOT_READY;
                    end
                    state_q <= StRep;
                  end
                  default: state_q <= StRep;
                endcase
              end
              APU_VN_ACT_POOL_RESET: begin
                are_i_q <= '0;
                state_q <= StPoolLoop;
              end
              default: begin
                result_q <= APU_VK_ERROR_UNKNOWN;
                state_q  <= StRep;
              end
            endcase
          end

          // ---- generic subroutines --------------------------------------
          StOtReq: if (ot_req_ready_i) state_q <= StOtCpl;
          StOtCpl: if (ot_cpl_valid_i) state_q <= ot_ret_q;
          StCrReq: if (cr_req_ready_i) state_q <= StCrCpl;
          StCrCpl: if (cr_cpl_valid_i) state_q <= cr_ret_q;
          StCsRd:  state_q <= StCsCap;
          StCsCap: begin
            csw_q   <= cs_rdata_i;
            state_q <= cs_ret_q;
          end

          // ---- blob u64 reader: -> blob_id_q then blob_ret_q ------------
          StBlobRd: begin
            if (blob_i_q >= blob_n_q) begin
              state_q <= blob_done_q;
            end else begin
              csa_q    <= cs_base_q + op_q.blob[blob_sel_q].off +
                          16'(blob_i_q << 1);
              cs_ret_q <= StBlobLo;
              state_q  <= StCsRd;
            end
          end
          StBlobLo: begin
            blob_id_q[31:0] <= csw_q;
            csa_q    <= csa_q + 16'h1;
            cs_ret_q <= StBlobHi;
            state_q  <= StCsRd;
          end
          StBlobHi: begin
            blob_id_q[63:32] <= csw_q;
            state_q <= blob_ret_q;
          end

          // ---- ALLOC single NEW-slot ------------------------------------
          StAllocGo: begin
            automatic int ns = role_slot(op_q, APU_VN_ROLE_NEW);
            automatic int ps = act_q.parent_qslot != APU_VN_QSLOT_NONE
                               ? int'(act_q.parent_qslot) : -1;
            automatic int ds = data_slot(op_q);
            if (op_q.cmd_type == APU_VN_TYPE_VK_CREATE_FENCE_EXT &&
                fence_free() == 8'hFF) begin
              result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
              state_q  <= StRep;
            end else begin
              // created size -> aux[31:8] blocks (ObjTab.ALLOC ignores
              // req.size); buffers in 256B units, images in 4KiB units
              if (op_q.cmd_type == APU_VN_TYPE_VK_CREATE_BUFFER_EXT)
                aux_size_q <= 24'((ds < 0 ? 64'h0 : op_q.q[ds]) +
                                  64'd255 >> 8);
              else if (op_q.cmd_type == APU_VN_TYPE_VK_CREATE_IMAGE_EXT)
                aux_size_q <= 24'((64'(op_q.imm[3]) * 64'(op_q.imm[4]) *
                                  64'd4 + 64'd4095) >> 12);
              else
                aux_size_q <= '0;
              // executor fence index -> aux[7:0] via SETAUX (are_i_q
              // carries it to StAllocAux)
              if (op_q.cmd_type == APU_VN_TYPE_VK_CREATE_FENCE_EXT)
                are_i_q <= 5'(fence_free());
              otr_q <= '{op: APU_OBJTAB_OP_ALLOC,
                         id: op_q.q[ns],
                         kind: act_q.obj_kind,
                         parent_id: ps < 0 ? 64'h0
                                           : {32'h0, hnd_q[ps]},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StAllocCpl;
              state_q  <= StOtReq;
            end
          end
          StAllocCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else if (op_q.cmd_type ==
                             APU_VN_TYPE_VK_CREATE_BUFFER_EXT ||
                         op_q.cmd_type ==
                             APU_VN_TYPE_VK_CREATE_IMAGE_EXT) begin
              otr_q <= '{op: APU_OBJTAB_OP_SETAUX,
                         id: {32'h0, ot_cpl_i.handle},
                         kind: act_q.obj_kind,
                         mask: 32'hFFFF_FF00,
                         value: {aux_size_q, 8'h0},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StAllocAux;
              state_q  <= StOtReq;
            end else if (op_q.cmd_type ==
                         APU_VN_TYPE_VK_CREATE_FENCE_EXT) begin
              otr_q <= '{op: APU_OBJTAB_OP_SETAUX,
                         id: {32'h0, ot_cpl_i.handle},
                         kind: act_q.obj_kind,
                         mask: 32'hFF,
                         value: {27'h0, are_i_q},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StAllocAux;
              state_q  <= StOtReq;
            end else begin
              state_q <= StRep;
            end
          end
          StAllocAux: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK)
              result_q <= APU_VK_ERROR_UNKNOWN;
            else if (op_q.cmd_type == APU_VN_TYPE_VK_CREATE_FENCE_EXT)
              falloc_q[are_i_q[$clog2(Fences)-1:0]] <= 1'b1;
            state_q <= StRep;
          end

          // ---- blob element handlers ------------------------------------
          // multi-create ALLOC of blob_id_q
          StElemAlloc: begin
            automatic logic [7:0] af = arena_free();
            if (act_q.obj_kind == 6'(APU_VN_KIND_VK_COMMAND_BUFFER) &&
                af == 8'hFF) begin
              result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
              state_q  <= StRep;
            end else begin
              if (act_q.obj_kind ==
                  6'(APU_VN_KIND_VK_COMMAND_BUFFER))
                are_i_q <= 5'(af[3:0]);
              otr_q <= '{op: APU_OBJTAB_OP_ALLOC,
                         id: blob_id_q,
                         kind: act_q.obj_kind,
                         parent_id: act_q.parent_qslot ==
                                    APU_VN_QSLOT_NONE
                                    ? 64'h0
                                    : {32'h0,
                                       hnd_q[int'(act_q.parent_qslot)]},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StElemAllocCpl;
              state_q  <= StOtReq;
            end
          end
          StElemAllocCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else if (act_q.obj_kind ==
                         6'(APU_VN_KIND_VK_COMMAND_BUFFER)) begin
              cb_hnd_q[are_i_q[$clog2(CbBufs)-1:0]] <= ot_cpl_i.handle;
              otr_q <= '{op: APU_OBJTAB_OP_SETAUX,
                         id: {32'h0, ot_cpl_i.handle},
                         kind: act_q.obj_kind,
                         mask: 32'hFF,
                         value: {27'h0, are_i_q},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StElemAuxCpl;
              state_q  <= StOtReq;
            end else begin
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end
          end
          StElemAuxCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              cb_alloc_q[are_i_q[$clog2(CbBufs)-1:0]] <= 1'b1;
              // lifetime parent is the command pool: the second
              // LOOKUP handle (device is the first / refcnt parent)
              cb_pool_q[are_i_q[$clog2(CbBufs)-1:0]] <=
                  lu_slot(op_q, 1) < 0 ? 32'h0
                                       : hnd_q[lu_slot(op_q, 1)];
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end
          end

          // vkEnumeratePhysicalDevices: register the client ids
          StElemPd: begin
            otr_q <= '{op: APU_OBJTAB_OP_ALLOC,
                       id: blob_id_q,
                       kind: 6'(APU_VN_KIND_VK_PHYSICAL_DEVICE),
                       parent_id: act_q.parent_qslot ==
                                  APU_VN_QSLOT_NONE ? 64'h0
                                  : {32'h0,
                                     hnd_q[int'(act_q.parent_qslot)]},
                       ctx: ctx_i, default: '0};
            ot_ret_q <= StElemPdCpl;
            state_q  <= StOtReq;
          end
          StElemPdCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else begin
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end
          end

          // SUBMIT: LOOKUP each CB id -> EXECUTABLE + aux
          StElemSub: begin
            otr_q <= '{op: APU_OBJTAB_OP_LOOKUP,
                       id: blob_id_q,
                       kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                       ctx: ctx_i, default: '0};
            ot_ret_q <= StElemSubCpl;
            state_q  <= StOtReq;
          end
          StElemSubCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                (ot_cpl_i.entry.state & APU_CB_EXECUTABLE) == 0 ||
                ot_cpl_i.entry.aux[7:0] >= 8'(CbBufs) ||
                sub_q.nbufs == 3'd4) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              sub_q.crec[sub_q.nbufs[1:0]]  <=
                  8'(ot_cpl_i.entry.aux[7:0]);
              sub_q.chndl[sub_q.nbufs[1:0]] <= ot_cpl_i.handle;
              sub_q.nbufs <= sub_q.nbufs + 3'd1;
              blob_i_q    <= blob_i_q + 5'd1;
              state_q     <= StBlobRd;
            end
          end

          // WAIT/RESET fences: LOOKUP each fence id -> mask
          StElemFenc: begin
            otr_q <= '{op: APU_OBJTAB_OP_LOOKUP,
                       id: blob_id_q,
                       kind: 6'(APU_VN_KIND_VK_FENCE), ctx: ctx_i, default: '0};
            ot_ret_q <= StElemFencCpl;
            state_q  <= StOtReq;
          end
          StElemFencCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.aux[7:0] >= 8'(Fences)) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              fmask_q[ot_cpl_i.entry.aux[$clog2(Fences)-1:0]] <= 1'b1;
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end
          end

          // RECORD: first blob-carried handle into the record
          StElemRec: begin
            otr_q <= '{op: APU_OBJTAB_OP_LOOKUP, id: blob_id_q,
                       kind: op_q.cmd_type ==
                             APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT
                             ? 6'(APU_VN_KIND_VK_DESCRIPTOR_SET)
                             : 6'(APU_VN_KIND_VK_BUFFER),
                       ctx: ctx_i, default: '0};
            ot_ret_q <= StElemRecCpl;
            state_q  <= StOtReq;
          end
          StElemRecCpl: begin
            if (ot_cpl_i.status == APU_OBJTAB_OK &&
                rhi_q < 4'd4) begin
              rec_q.handle[rhi_q[1:0]] <= ot_cpl_i.handle;
              rec_q.kind[rhi_q[1:0]]   <= {2'b0,
                                           ot_cpl_i.entry.kind};
              rhi_q <= rhi_q + 4'd1;
            end
            state_q <= StRecApp;
          end
          StRecApp: begin
            crr_q    <= '{op: APU_CMDREC_OP_APPEND,
                          cbuf: 8'(ent_q.aux[7:0]), idx: '0,
                          rec: rec_q};
            cr_ret_q <= StAppendCpl;
            state_q  <= StCrReq;
          end

          // ---- blob retire (vkFreeCommandBuffers/DescriptorSets) ----------
          StElemRetL: begin
            otr_q <= '{op: APU_OBJTAB_OP_LOOKUP, id: blob_id_q,
                       kind: act_q.obj_kind, ctx: ctx_i, default: '0};
            ot_ret_q <= StElemRetR;
            state_q  <= StOtReq;
          end
          StElemRetR: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              aux_free_q   <= ot_cpl_i.entry.aux[7:0];
              aux_free_v_q <= act_q.obj_kind ==
                              6'(APU_VN_KIND_VK_COMMAND_BUFFER) &&
                              ot_cpl_i.entry.aux[7:0] < 8'(CbBufs);
              otr_q    <= '{op: APU_OBJTAB_OP_RETIRE, id: blob_id_q,
                           kind: act_q.obj_kind, default: '0};
              ot_ret_q <= StElemRetCpl;
              state_q  <= StOtReq;
            end
          end
          StElemRetCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else begin
              if (aux_free_v_q) begin
                cb_alloc_q[aux_free_q[$clog2(CbBufs)-1:0]] <= 1'b0;
                cb_pool_q [aux_free_q[$clog2(CbBufs)-1:0]] <= '0;
                cb_hnd_q  [aux_free_q[$clog2(CbBufs)-1:0]] <= '0;
                aux_free_v_q <= 1'b0;
              end
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end
          end

          // ---- RETIRE ----------------------------------------------------
          StRetPre: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              aux_free_q   <= ot_cpl_i.entry.aux[7:0];
              aux_fence_q  <= act_q.obj_kind ==
                              6'(APU_VN_KIND_VK_FENCE);
              aux_free_v_q <= ot_cpl_i.entry.aux[7:0] <
                              (act_q.obj_kind == 6'(APU_VN_KIND_VK_FENCE)
                               ? 8'(Fences) : 8'(CbBufs));
              otr_q    <= '{op: APU_OBJTAB_OP_RETIRE,
                           id: op_q.q[
                               role_slot(op_q, APU_VN_ROLE_RETIRE)],
                           kind: act_q.obj_kind, default: '0};
              ot_ret_q <= StRetCpl;
              state_q  <= StOtReq;
            end
          end
          StRetCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
            end else if (aux_free_v_q) begin
              if (aux_fence_q)
                falloc_q[aux_free_q[$clog2(Fences)-1:0]] <= 1'b0;
              else begin
                cb_alloc_q[aux_free_q[$clog2(CbBufs)-1:0]] <= 1'b0;
                cb_pool_q [aux_free_q[$clog2(CbBufs)-1:0]] <= '0;
                cb_hnd_q  [aux_free_q[$clog2(CbBufs)-1:0]] <= '0;
              end
              aux_free_v_q <= 1'b0;
            end
            state_q <= StRep;
          end

          // ---- CB_BEGIN/END/RESET + RECORD dispatch ----------------------
          StCbGo: begin
            if (act_q.act_class == APU_VN_ACT_CB_BEGIN) begin
              if (ent_q.state != 32'h0) begin
                result_q <= APU_VK_ERROR_UNKNOWN;
                state_q  <= StRep;
              end else begin
                crr_q    <= '{op: APU_CMDREC_OP_BEGIN,
                              cbuf: 8'(ent_q.aux[7:0]), idx: '0,
                              rec: '0};
                cr_ret_q <= StCbCrCpl;
                state_q  <= StCrReq;
              end
            end else if (act_q.act_class == APU_VN_ACT_CB_END) begin
              if ((ent_q.state & APU_CB_RECORDING) == 0) begin
                result_q <= APU_VK_ERROR_UNKNOWN;
                state_q  <= StRep;
              end else begin
                crr_q    <= '{op: APU_CMDREC_OP_END,
                              cbuf: 8'(ent_q.aux[7:0]), idx: '0,
                              rec: '0};
                cr_ret_q <= StCbCrCpl;
                state_q  <= StCrReq;
              end
            end else if (act_q.act_class == APU_VN_ACT_CB_RESET) begin
              crr_q    <= '{op: APU_CMDREC_OP_RESET,
                            cbuf: 8'(ent_q.aux[7:0]), idx: '0,
                            rec: '0};
              cr_ret_q <= StCbCrCpl;
              state_q  <= StCrReq;
            end else begin
              // RECORD: requires RECORDING, not PENDING/INVALID
              if ((ent_q.state & APU_CB_RECORDING) == 0 ||
                  (ent_q.state & (APU_CB_INVALID | APU_CB_PENDING)) != 0) begin
                result_q <= APU_VK_ERROR_UNKNOWN;
                otr_q    <= '{op: APU_OBJTAB_OP_SETSTATE,
                              id: {32'h0,
                                   hnd_q[int'(act_q.cmdbuf_qslot)]},
                              kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                              mask: APU_CB_STATE_MASK,
                              value: APU_CB_INVALID, default: '0};
                ot_ret_q <= StRep;
                state_q  <= StOtReq;
              end else begin
                rec_q <= '{ctype: op_q.cmd_type, flags: op_q.cmd_flags,
                           handle: '0, kind: '0,
                           imm: {op_q.imm[7], op_q.imm[6], op_q.imm[5],
                                 op_q.imm[4], op_q.imm[3], op_q.imm[2],
                                 op_q.imm[1], op_q.imm[0]},
                           spare: '0};
                res_i_q <= '0;
                rhi_q   <= '0;
                state_q <= StRecFill;
              end
            end
          end
          StCbCrCpl: begin
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              otr_q <= '{op: APU_OBJTAB_OP_SETSTATE,
                         id: {32'h0, hnd_q[int'(act_q.cmdbuf_qslot)]},
                         kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                         mask: APU_CB_STATE_MASK,
                         value: act_q.act_class == APU_VN_ACT_CB_BEGIN
                                ? APU_CB_RECORDING
                                : act_q.act_class == APU_VN_ACT_CB_END
                                  ? APU_CB_EXECUTABLE : 32'h0,
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StCbSetCpl;
              state_q  <= StOtReq;
            end
          end
          StCbSetCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK)
              result_q <= APU_VK_ERROR_UNKNOWN;
            state_q <= StRep;
          end

          // ---- RECORD: fill handle slots, then append -------------------
          StRecFill: begin
            if (rhi_q == 4'd4 || res_i_q == 4'd8) begin
              if ((op_q.cmd_type ==
                   APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT ||
                   op_q.cmd_type ==
                   APU_VN_TYPE_VK_CMD_BIND_VERTEX_BUFFERS_EXT) &&
                  op_q.blob[0].words >= 17'd2 && rhi_q < 4'd4) begin
                blob_sel_q  <= 1'b0;
                blob_i_q    <= '0;
                blob_n_q    <= 5'd1;
                blob_ret_q  <= StElemRec;
                blob_done_q <= StRep;
                state_q     <= StBlobRd;
              end else begin
                state_q <= StRecApp;
              end
            end else if (res_i_q == 4'(act_q.cmdbuf_qslot) ||
                         !need_res(op_q, res_i_q)) begin
              res_i_q <= res_i_q + 4'd1;
            end else begin
              rec_q.handle[rhi_q[1:0]] <= hnd_q[res_i_q[2:0]];
              rec_q.kind[rhi_q[1:0]]   <= {2'b0, op_q.qkind[res_i_q[2:0]]};
              rhi_q   <= rhi_q + 4'd1;
              res_i_q <= res_i_q + 4'd1;
            end
          end
          StAppendCpl: begin
            if (cr_cpl_i.status != APU_CMDREC_OK)
              result_q <= APU_VK_ERROR_UNKNOWN;
            state_q <= StRep;
          end

          // ---- SUBMIT: push, mark PENDING ---------------------------------
          StSubPush: begin
            if (sub_q.nbufs == 3'd0) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else if (ex_submit_ready_i) begin
              pushed_q <= pushed_q + 16'h1;
              are_i_q  <= '0;
              state_q  <= StSubState;
            end
          end
          StSubState: begin
            if (are_i_q >= {2'b0, sub_q.nbufs}) begin
              state_q <= StRep;
            end else begin
              otr_q    <= '{op: APU_OBJTAB_OP_SETSTATE,
                           id: {32'h0, sub_q.chndl[are_i_q[1:0]]},
                           kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                           mask: APU_CB_STATE_MASK,
                           value: APU_CB_PENDING, default: '0};
              ot_ret_q <= StSubStateNext;
              state_q  <= StOtReq;
            end
          end
          StSubStateNext: begin
            are_i_q <= are_i_q + 5'd1;
            state_q <= StSubState;
          end

          // ---- WAIT --------------------------------------------------------
          StWaitIdle: begin
            if (pushed_q == ex_done_seq_i) state_q <= StRep;
          end
          StFencPoll: begin
            if ((ex_fence_lost_i & fmask_q) != '0) begin
              result_q <= APU_VK_ERROR_DEVICE_LOST;
              state_q  <= StRep;
            end else if (wall_q
                         ? (ex_fence_signaled_i & fmask_q) == fmask_q
                         : (ex_fence_signaled_i & fmask_q) != '0) begin
              state_q <= StRep;
            end
          end
          StFencClr: begin
            ex_fence_clr_o <= fmask_q;
            state_q        <= StRep;
          end

          // ---- POOL_RESET ---------------------------------------------------
          StPoolLoop: begin
            if (are_i_q >= 5'(CbBufs)) begin
              state_q <= StRep;
            end else if (cb_alloc_q[are_i_q[$clog2(CbBufs)-1:0]] &&
                         act_q.parent_qslot != APU_VN_QSLOT_NONE &&
                         cb_pool_q[are_i_q[$clog2(CbBufs)-1:0]] ==
                         hnd_q[int'(act_q.parent_qslot)]) begin
              crr_q    <= '{op: APU_CMDREC_OP_RESET,
                            cbuf: {3'h0, are_i_q}, idx: '0, rec: '0};
              cr_ret_q <= StPoolSet;
              state_q  <= StCrReq;
            end else begin
              are_i_q <= are_i_q + 5'd1;
            end
          end
          StPoolSet: begin
            // RESET completion -> SETSTATE clear
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              otr_q    <= '{op: APU_OBJTAB_OP_SETSTATE,
                           id: {32'h0,
                                cb_hnd_q[are_i_q[$clog2(CbBufs)-1:0]]},
                           kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                           mask: APU_CB_STATE_MASK, value: '0,
                           default: '0};
              ot_ret_q <= StPoolNext;
              state_q  <= StOtReq;
            end
          end
          StPoolNext: begin
            are_i_q <= are_i_q + 5'd1;
            state_q <= StPoolLoop;
          end

          // ---- reply --------------------------------------------------------
          StRep: begin
            if (rep_skip_q || !op_q.cmd_flags[0] ||
                (act_q.flags & APU_VN_ACT_F_REPLY) == 0) begin
              rep_words_q <= '0;
              state_q <= StDone;
            end else begin
              state_q <= StRepKick;
            end
          end
          StRepKick: state_q <= StRepWait;
          StRepWait: if (rep_done) begin
            rep_words_q <= rep_n;
            fault_q     <= {3'b0, rep_fault};
            state_q     <= StDone;
          end

          StDone:  state_q <= StIdle;
          default: state_q <= StIdle;
        endcase
      end
    end
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_vnfront_fixture
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
#(parameter bit Enable = 1'b0,
  parameter int unsigned Fences = 16,
  parameter int unsigned CbBufs = 16) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               testmode_i,
  input  logic               start_i,
  input  logic [15:0]        cs_base_i,
  input  logic [15:0]        cs_len_i,
  input  logic [15:0]        rep_base_i,
  input  logic [15:0]        rep_len_i,
  input  logic [7:0]         ctx_i,
  output logic               cs_re_o,
  output logic [15:0]        cs_addr_o,
  input  logic [31:0]        cs_rdata_i,
  output logic               rep_we_o,
  output logic [15:0]        rep_addr_o,
  output logic [31:0]        rep_wdata_o,
  output logic               ot_req_valid_o,
  input  logic               ot_req_ready_i,
  output apu_objtab_req_t    ot_req_o,
  input  logic               ot_cpl_valid_i,
  output logic               ot_cpl_ready_o,
  input  apu_objtab_cpl_t    ot_cpl_i,
  output logic               cr_req_valid_o,
  input  logic               cr_req_ready_i,
  output apu_cmdrec_req_t    cr_req_o,
  input  logic               cr_cpl_valid_i,
  output logic               cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t    cr_cpl_i,
  output logic               ex_submit_valid_o,
  input  logic               ex_submit_ready_i,
  output apu_cmdexec_submit_t ex_submit_o,
  input  logic [15:0]        ex_done_seq_i,
  input  logic [Fences-1:0]  ex_fence_signaled_i,
  input  logic [Fences-1:0]  ex_fence_lost_i,
  output logic [Fences-1:0]  ex_fence_clr_o,
  output logic               busy_o,
  output logic               done_o,
  output logic [31:0]        result_o,
  output logic [15:0]        rep_words_o,
  output logic [3:0]         fault_o
);
  g6lc_apu_vnfront #(.Enable(Enable), .Fences(Fences),
                     .CbBufs(CbBufs)) i_dut (.*);
endmodule
