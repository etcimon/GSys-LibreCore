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
// §7b payload handling (5a-i): the decoder's KEEP stream lands in a
// staging tc_sram (PayStageWords); overflow reports
// APU_VN_FAULT_PAYLOAD and kills the command like any decode fault.
// After decode:
//   ALLOC     VkDescriptorSetLayout/VkPipelineLayout allocate an
//             ObjPay extent first (FULL -> OUT_OF_DEVICE_MEMORY, no
//             object), then copy staging -> ObjPay (the count words
//             riding the op record are prepended) and park
//             aux[63:32] = {base,words} via SETAUXHI.  Compute
//             pipelines store the whole payload extent once and the
//             first created pipeline object parks it.
//             vkAllocateDescriptorSets resolves each staged layout
//             id, reads bindingCount from the layout payload, then
//             ObjPay-allocates nbind*4 words of set storage and marks
//             bindings whose descriptorCount > 1 or type is not a
//             buffer type (6/7) with word3 bit31 at allocation.
//   RETIRE    payload kinds free their ObjPay extent from aux[63:32]
//   UPDATE    vkUpdateDescriptorSets walks the staged writes: each
//             {dstSet, dstBinding, descriptorCount, type, buffer
//             infos} resolves the set storage and each buffer through
//             ObjTab and writes {handle, offset lo, range lo,
//             type|unsupported<<31} entries.  A buffer MISS or a
//             dstBinding+k >= nbind marks the entry unsupported
//             (clamped to the last entry for out-of-range indices)
//             rather than faulting.  dstArrayElement is ignored in
//             5a-i (binding index == position).
//   RECORD    vkCmdPushConstants/vkCmdBindDescriptorSets stream their
//             payloads into the cmdrec per-buffer arena; the record's
//             imm[7] carries the arena base.  BindDescriptorSets
//             resolves each staged set id through ObjTab at record
//             time (a MISS stores a null handle).  pValues over 128 B
//             takes the INVALID path.
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
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Fences = 16,
  parameter int unsigned CbBufs = 16,
  // §7b: decoder payload staging (a decode-class PAYLOAD fault when
  // a single command's KEEP stream exceeds this window)
  parameter int unsigned PayStageWords = 1024
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
  // shared command-stream read port, handshake form (front reads
  // blob ids while the engines are idle; decoder wins, then rep)
  output logic               cs_re_o,
  output logic [15:0]        cs_addr_o,
  input  logic               cs_ready_i,
  input  logic               cs_rvalid_i,
  input  logic [31:0]        cs_rdata_i,
  input  logic               cs_err_i,
  // reply write port (vnrep writes through; held until rep_ready_i,
  // completed by rep_done_i)
  output logic               rep_we_o,
  output logic [15:0]        rep_addr_o,
  output logic [31:0]        rep_wdata_o,
  input  logic               rep_ready_i,
  input  logic               rep_done_i,
  input  logic               rep_err_i,
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
  // CmdRec payload stream (APPEND payload producer, §7b)
  output logic               cr_pay_valid_o,
  output logic [31:0]        cr_pay_data_o,
  input  logic               cr_pay_ready_i,
  // ObjPay port (§7b object payload store)
  output logic               op_req_valid_o,
  input  logic               op_req_ready_i,
  output apu_objpay_req_t    op_req_o,
  input  logic               op_cpl_valid_i,
  output logic               op_cpl_ready_o,
  input  apu_objpay_cpl_t    op_cpl_i,
  // ShaderCore slot manager + module staging + commit (§7b/5a-ii)
  output logic               sm_req_o,
  output apu_sh_sm_req_t     sm_req_pl_o,
  input  logic               sm_cpl_i,
  input  apu_sh_sm_cpl_t     sm_cpl_pl_i,
  output logic               sh_wr_en_o,
  output logic [2:0]         sh_wr_slot_o,
  output logic [15:0]        sh_wr_addr_o,
  output logic [31:0]        sh_wr_data_o,
  output logic               sh_commit_o,
  output apu_sh_commit_t     sh_commit_pl_o,
  input  logic               sh_c_done_i,
  input  apu_sh_cpl_t        sh_c_done_pl_i,
  // aperture page allocator (§7b/5a-ii, arbitrated in vgtop)
  output logic               pg_req_valid_o,
  input  logic               pg_req_ready_i,
  output apu_vgpages_req_t   pg_req_o,
  input  logic               pg_cpl_valid_i,
  output logic               pg_cpl_ready_o,
  input  apu_vgpages_cpl_t   pg_cpl_i,
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
    assign cr_pay_valid_o = 1'b0; assign cr_pay_data_o = '0;
    assign op_req_valid_o = 1'b0; assign op_req_o = '0;
    assign op_cpl_ready_o = 1'b0;
    assign sm_req_o = 1'b0;        assign sm_req_pl_o = '0;
    assign sh_wr_en_o = 1'b0;      assign sh_wr_slot_o = '0;
    assign sh_wr_addr_o = '0;      assign sh_wr_data_o = '0;
    assign sh_commit_o = 1'b0;     assign sh_commit_pl_o = '0;
    assign pg_req_valid_o = 1'b0;  assign pg_req_o = '0;
    assign pg_cpl_ready_o = 1'b0;
    assign ex_submit_valid_o = 1'b0; assign ex_submit_o = '0;
    assign ex_fence_clr_o = '0;
    assign busy_o = 1'b0;         assign done_o = 1'b0;
    assign result_o = '0;         assign rep_words_o = '0;
    assign fault_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | start_i |
                    cs_rdata_i[0] | cs_ready_i | cs_rvalid_i |
                    cs_err_i | rep_ready_i | rep_done_i | rep_err_i |
                    ot_req_ready_i | ot_cpl_valid_i |
                    (|ot_cpl_i) | cr_req_ready_i | cr_cpl_valid_i |
                    (|cr_cpl_i) | cr_pay_ready_i | op_req_ready_i |
                    op_cpl_valid_i | (|op_cpl_i) |
                    sm_cpl_i | (|sm_cpl_pl_i) |
                    sh_c_done_i | (|sh_c_done_pl_i) |
                    pg_req_ready_i | pg_cpl_valid_i | (|pg_cpl_i) |
                    ex_submit_ready_i | (|ex_done_seq_i) |
                    (|ex_fence_signaled_i) | (|ex_fence_lost_i) |
                    (|cs_base_i) | (|cs_len_i) | (|rep_base_i) |
                    (|rep_len_i);
  end else begin : gen_on
    localparam logic [4:0] FENCE_NONE = 5'd31;

    typedef enum logic [6:0] {
      StIdle, StDec, StDecWait, StResolve, StResCpl, StAct,
      StOtReq, StOtCpl, StCrReq, StCrCpl, StCsRd, StCsCap,
      StBlobRd, StBlobLo, StBlobHi,
      StElemAlloc, StElemAllocCpl, StElemAuxCpl,
      StElemPd, StElemPdCpl,
      StElemSub, StElemSubCpl,
      StElemFenc, StElemFencCpl,
      StElemRec, StElemRecCpl,
      StElemRetL, StElemRetR, StElemRetCpl, StElemRetPay,
      StAllocGo, StAllocCpl, StAllocAux, StRetCpl, StRetPre,
      StBindMemCk,
      StCbGo, StCbCrCpl, StCbSetCpl,
      StRecFill, StRecApp, StAppendCpl,
      StSubPush, StSubState, StSubStateNext,
      StWaitIdle, StFencPoll, StFencClr,
      StPoolLoop, StPoolSet, StPoolNext,
      // §7b: payload machinery
      StOpReq, StOpCpl, StStgRd, StStgCap,
      StPayAlcCpl, StPayLoop, StPayNext, StPayWr, StAuxSet,
      StAuxHiCpl,
      StDSetLayLo, StDSetLayHi, StDSetLayId, StDSetLayCpl,
      StDSetNbCpl, StDSetAlcCpl, StDSetObj, StDSetOCpl,
      StDSetFill, StDSetFillT, StDSetFillC, StDSetWr, StDSetWrC,
      StUpdHdrC, StUpdSetCpl, StUpdInfo, StUpdInfoC,
      StUpdBufGo, StUpdBufCpl, StUpdWr, StUpdWrC, StUpdInfoNext,
      StPayProd, StPayResLo, StPayResHi, StPayResCpl, StPayCapW,
      StPaySend,
      // §7b/5a-ii: slot manager, module staging, pipeline commit,
      // aperture pages
      StSmReq, StSmCpl,
      StShRd, StShWr, StShCommit, StShCWait,
      StPgReq, StPgCpl,
      StShModObj, StShModCpl,
      StPipeH0, StPipeH1, StPipeH2, StPipeH3, StPipeH4,
      StPipeLay0, StPipeModCpl, StPipeLayCpl, StPipeAllocC,
      StPipeAuxC, StPipeAuxCpl, StPipeAuxHiC, StPipeFail,
      StRetSm,
      StRep, StRepKick, StRepWait, StDone
    } state_e;
    state_e              state_q, ot_ret_q, cr_ret_q, cs_ret_q;
    state_e              blob_ret_q, blob_done_q;
    state_e              op_ret_q, stg_ret_q, auxhi_ret_q,
                         pro_ret_q, pay_done_q;
    state_e              sm_ret_q, sh_ret_q, shc_ret_q, pg_ret_q;

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
    apu_objpay_req_t     opr_q;
    logic [15:0]         csa_q;
    logic [31:0]         csw_q;

    // §7b payload staging: the decoder's KEEP stream lands in a
    // staging tc_sram; post-decode flows read it back through
    // StStgRd/StStgCap and copy it into ObjPay or the cmdrec arena.
    localparam int unsigned StgBits = $clog2(PayStageWords);
    logic                stg_req, stg_we;
    logic [StgBits-1:0]  stg_addr;
    logic [31:0]         stg_wdata, stg_rdata;
    logic [StgBits:0]    stg_n_q;      // staged word count
    logic                pay_ovf_q;    // KEEP stream > PayStageWords
    logic [StgBits-1:0]  stg_i_q;      // staged read cursor
    logic [31:0]         stg_word_q;   // captured staged word

    logic [15:0]         op_base_q;    // held ObjPay extent {base,words}
    logic [15:0]         op_words_q;
    logic [15:0]         pay_i_q;      // objpay write cursor
    logic [1:0]          prepend_n_q;  // count words prepended to payload
    logic [31:0]         prepend_w_q [2];
    logic [31:0]         hnd_pay_q;    // object {gen,slot} for SETAUXHI
    logic                payf_q;       // retire frees a payload extent
    logic [15:0]         payf_base_q, payf_words_q;

    // descriptor-set allocation element chain
    logic [31:0]         lay_lo_q;     // staged layout id low word
    logic [15:0]         lay_base_q;   // layout payload extent
    logic [15:0]         lay_words_q;
    logic [15:0]         lay_nbind_q;  // bindingCount from layout
    logic [15:0]         ent_j_q;      // binding/entry cursor
    logic [1:0]          ent_k_q;      // word within the 4-word entry
    logic [3:0][31:0]    entw_q;       // entry words being written
    logic [31:0]         lay_type_q;   // layout descriptorType word

    // vkUpdateDescriptorSets staged walk
    logic [15:0]         upd_i_q;      // write index
    logic [2:0]          upd_h_q;      // header/info word cursor
    logic [63:0]         upd_dst_q;    // dstSet id
    logic [63:0]         upd_buf_q;    // buffer id
    logic [63:0]         upd_off_q, upd_rng_q;
    logic [31:0]         upd_dstb_q, upd_arr_q, upd_dcnt_q,
                         upd_type_q;
    logic [15:0]         dset_base_q, dset_words_q;
    logic [15:0]         upd_idx_q;    // entry index (dstBinding+k)

    // cmdrec payload producer
    logic [15:0]         pay_send_q;   // stream index
    logic [15:0]         pay_send_n_q; // total words
    logic [31:0]         pay_word_q;   // current cr_pay_data_o
    logic [15:0]         pay_nset_q;   // BindDS resolved-handle count
    logic                pay_bind_q;   // stream mode: resolve sets

    // §7b/5a-ii: ShaderCore slot manager / staging / commit + pages
    apu_sh_sm_op_e       sm_op_q;
    logic [2:0]          sm_slot_q;
    logic                sm_ok_q;
    logic [2:0]          sm_rslot_q;
    logic [15:0]         shw_i_q;      // pCode stream cursor
    logic [15:0]         shw_n_q;      // pCode word count
    logic [2:0]          sh_slot_q;    // committed/alloc'd slot
    logic [15:0]         sh_nw_q;      // module nwords
    logic                shc_ok_q;     // commit result
    apu_vgpages_op_e     pg_op_q;
    logic [31:0]         pg_base_q, pg_bytes_q;
    logic                pg_ok_q;
    logic [31:0]         pg_res_q;
    logic [31:0]         rep_null_mask_q; // failed-element null echo
    // vkCreateComputePipelines element state (5-word staged payload)
    logic [63:0]         pl_modid_q, pl_layid_q;
    logic                pl_spec_q;
    logic [31:0]         pl_layh_q;    // layout {gen,slot}
    logic                pl_errv_q;    // first error latched
    logic [31:0]         auxhi_val_q;  // generic SETAUXHI value

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
    logic        dec_rdy, rep_cs_rdy, front_rdy;

    logic        dec_pay_v;
    logic [31:0] dec_pay_d;
    g6lc_apu_vndec #(.Enable(1'b1)) i_dec (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .start_i(dec_start), .cs_base_i(cs_base_q), .cs_len_i(cs_len_q),
      .cs_re_o(dec_re), .cs_addr_o(dec_addr), .cs_ready_i(dec_rdy),
      .cs_rvalid_i(cs_rvalid_i), .cs_rdata_i(cs_rdata_i),
      .cs_err_i(cs_err_i),
      .busy_o(dec_busy), .done_o(dec_done), .op_o(dec_op),
      .pay_valid_o(dec_pay_v), .pay_data_o(dec_pay_d));

    // §7b payload staging: KEEP words land here while the decoder
    // runs; post-decode flows read them through StStgRd/StStgCap.
    tc_sram #(.NumWords(PayStageWords), .DataWidth(32), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_pay_stage (
      .clk_i, .rst_ni, .req_i(stg_req), .we_i(stg_we),
      .addr_i(stg_addr), .wdata_i(stg_wdata), .be_i('1),
      .rdata_o(stg_rdata));

    g6lc_apu_vnrep #(.Enable(1'b1)) i_rep (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .start_i(rep_start), .op_i(op_q), .result_i(result_q),
      .exec_w_i(exec_w_q), .exec_n_i(7'd64),
      .rep_null_mask_i(rep_null_mask_q),
      .rep_base_i(rep_base_q), .rep_len_i(rep_len_q),
      .cs_base_i(cs_base_q),
      .cs_re_o(rep_re), .cs_addr_o(rep_addr), .cs_ready_i(rep_cs_rdy),
      .cs_rvalid_i(cs_rvalid_i), .cs_rdata_i(cs_rdata_i),
      .cs_err_i(cs_err_i),
      .rep_we_o(rep_we_o), .rep_addr_o(rep_addr_o),
      .rep_wdata_o(rep_wdata_o),
      .rep_ready_i(rep_ready_i), .rep_done_i(rep_done_i),
      .rep_err_i(rep_err_i),
      .busy_o(rep_busy), .done_o(rep_done), .rep_words_o(rep_n),
      .fault_o(rep_fault));

    // CS port arbitration: engines win while running; the front reads
    // blob ids in between.  Requests are held until the shared
    // cs_ready_i; every accepted requester sees exactly one rvalid.
    assign cs_re_o   = dec_re | rep_re | front_re;
    assign cs_addr_o = dec_re ? dec_addr :
                       rep_re ? rep_addr : front_addr;
    assign dec_rdy    = dec_re && cs_ready_i;
    assign rep_cs_rdy = !dec_re && rep_re && cs_ready_i;
    assign front_rdy  = !dec_re && !rep_re && front_re && cs_ready_i;

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

    // §7b: object kinds that carry an ObjPay payload extent in
    // aux[63:32] = {base[15:0], words[15:0]}
    function automatic logic is_pay_kind(input logic [5:0] k);
      // §7b/5a-ii: pipelines no longer park an ObjPay extent — the
      // staged payload is consumed at creation and the object keeps
      // {slot, layout} in aux instead
      return k == 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT) ||
             k == 6'(APU_VN_KIND_VK_PIPELINE_LAYOUT) ||
             k == 6'(APU_VN_KIND_VK_DESCRIPTOR_SET);
    endfunction
    // 5a-ii: kinds whose retire needs a pre-LOOKUP (aux carries a
    // ShaderCore slot or a vgpages extent)
    function automatic logic is_auxret_kind(input logic [5:0] k);
      return k == 6'(APU_VN_KIND_VK_SHADER_MODULE) ||
             k == 6'(APU_VN_KIND_VK_PIPELINE) ||
             k == 6'(APU_VN_KIND_VK_DEVICE_MEMORY);
    endfunction
    // prepend words ahead of the staged payload copy
    function automatic int prepend_n(input logic [5:0] k);
      if (k == 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT)) return 1;
      if (k == 6'(APU_VN_KIND_VK_PIPELINE_LAYOUT))       return 2;
      return 0;
    endfunction

    // ---- port steering -----------------------------------------------
    always_comb begin
      ot_req_valid_o = 1'b0;    ot_req_o = '0;
      cr_req_valid_o = 1'b0;    cr_req_o = '0;
      op_req_valid_o = 1'b0;    op_req_o = '0;
      cr_pay_valid_o = 1'b0;    cr_pay_data_o = '0;
      ex_submit_valid_o = 1'b0; ex_submit_o = '0;
      sm_req_o = 1'b0;          sm_req_pl_o = '0;
      sh_wr_en_o = 1'b0;        sh_wr_slot_o = '0;
      sh_wr_addr_o = '0;        sh_wr_data_o = '0;
      sh_commit_o = 1'b0;       sh_commit_pl_o = '0;
      pg_req_valid_o = 1'b0;    pg_req_o = '0;
      front_re = 1'b0;          front_addr = '0;
      dec_start = 1'b0;         rep_start = 1'b0;
      stg_req = 1'b0;           stg_we = 1'b0;
      stg_addr = '0;            stg_wdata = '0;
      // decoder KEEP stream wins the staging port while decoding;
      // StStgRd issues one staged-word read otherwise
      if (dec_pay_v) begin
        stg_req   = stg_n_q < (StgBits+1)'(PayStageWords);
        stg_we    = stg_req;
        stg_addr  = stg_n_q[StgBits-1:0];
        stg_wdata = dec_pay_d;
      end else if (state_q == StStgRd) begin
        stg_req  = 1'b1;
        stg_addr = stg_i_q;
      end
      case (state_q)
        StOtReq:   begin ot_req_valid_o = 1'b1; ot_req_o = otr_q; end
        StCrReq:   begin cr_req_valid_o = 1'b1; cr_req_o = crr_q; end
        StOpReq:   begin op_req_valid_o = 1'b1; op_req_o = opr_q; end
        StPaySend: begin cr_pay_valid_o = 1'b1;
                         cr_pay_data_o  = pay_word_q;            end
        StCsRd:    begin front_re = 1'b1; front_addr = csa_q;     end
        StSmReq:   begin sm_req_o = 1'b1;
                         sm_req_pl_o = '{op: sm_op_q,
                                        slot: sm_slot_q};       end
        StShWr:    begin sh_wr_en_o   = 1'b1;
                         sh_wr_slot_o = sh_slot_q;
                         sh_wr_addr_o = shw_i_q;
                         sh_wr_data_o = csw_q;                   end
        StShCommit: begin sh_commit_o = 1'b1;
                         sh_commit_pl_o = '{slot: sh_slot_q,
                                           nwords: sh_nw_q};     end
        StPgReq:   begin pg_req_valid_o = 1'b1;
                         pg_req_o = '{op: pg_op_q,
                                     base: pg_base_q,
                                     bytes: pg_bytes_q};         end
        StSubPush: begin ex_submit_valid_o = 1'b1;
                         ex_submit_o = sub_q;                     end
        StDec:     dec_start = 1'b1;
        StRepKick: rep_start = 1'b1;
        default: ;
      endcase
    end

    assign op_cpl_ready_o = 1'b1;
    assign pg_cpl_ready_o = 1'b1;

    // ---- sequential ---------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        ot_ret_q <= StIdle; cr_ret_q <= StIdle; cs_ret_q <= StIdle;
        blob_ret_q <= StIdle; blob_done_q <= StIdle;
        op_ret_q <= StIdle; stg_ret_q <= StIdle;
        auxhi_ret_q <= StIdle; pro_ret_q <= StIdle;
        pay_done_q <= StIdle;
        cs_base_q <= '0; cs_len_q <= '0;
        rep_base_q <= '0; rep_len_q <= '0;
        op_q <= '{fault: APU_VN_FAULT_NONE, default: '0};
        act_q <= '0; result_q <= '0; rep_skip_q <= 1'b0;
        rep_words_q <= '0; fault_q <= '0;
        res_i_q <= '0; watch_q <= '0;
        for (int i = 0; i < 8; i++) hnd_q[i] <= '0;
        ent_q <= '0;
        otr_q <= '0; crr_q <= '0; csa_q <= '0; csw_q <= '0;
        opr_q <= '0;
        stg_n_q <= '0; pay_ovf_q <= 1'b0;
        stg_i_q <= '0; stg_word_q <= '0;
        op_base_q <= '0; op_words_q <= '0; pay_i_q <= '0;
        prepend_n_q <= '0;
        for (int i = 0; i < 2; i++) prepend_w_q[i] <= '0;
        hnd_pay_q <= '0; payf_q <= 1'b0;
        payf_base_q <= '0; payf_words_q <= '0;
        lay_lo_q <= '0; lay_base_q <= '0; lay_words_q <= '0;
        lay_nbind_q <= '0; lay_type_q <= '0;
        ent_j_q <= '0; ent_k_q <= '0; entw_q <= '0;
        upd_i_q <= '0; upd_h_q <= '0;
        upd_dst_q <= '0; upd_buf_q <= '0;
        upd_off_q <= '0; upd_rng_q <= '0;
        upd_dstb_q <= '0; upd_arr_q <= '0;
        upd_dcnt_q <= '0; upd_type_q <= '0;
        dset_base_q <= '0; dset_words_q <= '0; upd_idx_q <= '0;
        pay_send_q <= '0; pay_send_n_q <= '0; pay_word_q <= '0;
        pay_nset_q <= '0; pay_bind_q <= 1'b0;
        sm_op_q <= APU_SH_SM_ALLOC; sm_slot_q <= '0;
        sm_ok_q <= 1'b0; sm_rslot_q <= '0;
        shw_i_q <= '0; shw_n_q <= '0;
        sh_slot_q <= '0; sh_nw_q <= '0; shc_ok_q <= 1'b0;
        pg_op_q <= APU_VGPAGES_OP_ALLOC;
        pg_base_q <= '0; pg_bytes_q <= '0;
        pg_ok_q <= 1'b0; pg_res_q <= '0;
        rep_null_mask_q <= '0;
        pl_modid_q <= '0; pl_layid_q <= '0; pl_spec_q <= 1'b0;
        pl_layh_q <= '0; pl_errv_q <= 1'b0; auxhi_val_q <= '0;
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
        // decoder KEEP stream → staging SRAM (any state while the
        // decoder runs); overflow is reported at decode done
        if (dec_pay_v) begin
          if (stg_n_q < (StgBits+1)'(PayStageWords))
            stg_n_q <= stg_n_q + 1'b1;
          else
            pay_ovf_q <= 1'b1;
        end
        case (state_q)
          StIdle: if (start_i) begin
            cs_base_q  <= cs_base_i;
            cs_len_q   <= cs_len_i;
            rep_base_q <= rep_base_i;
            rep_len_q  <= rep_len_i;
            fault_q <= '0; rep_words_q <= '0; rep_skip_q <= 1'b0;
            result_q <= APU_VK_SUCCESS;
            rep_null_mask_q <= '0;
            stg_n_q <= '0; pay_ovf_q <= 1'b0;
            payf_q <= 1'b0;
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
            end else if (pay_ovf_q) begin
              // §7b: staging overflow is a decode-class fault; the
              // ring goes FATAL like any decode fault
              result_q   <= APU_VK_ERROR_UNKNOWN;
              fault_q    <= APU_VN_FAULT_PAYLOAD;
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
              end else if (APU_VN_ACT[dec_op.cmd_type[
                      $clog2(APU_VN_DEC_TYPE_MAX+1)-1:0]].act_class
                           == APU_VN_ACT_BIND) begin
                // watch the bound resource so ent_q.size is its
                // declared size for the SETBIND below
                automatic int rs = lu_slot(dec_op, 1);
                watch_q <= rs < 0 ? 4'hF : 4'(rs);
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
              APU_VN_ACT_NOP_OK, APU_VN_ACT_MAP:
                state_q <= StRep;
              APU_VN_ACT_UPDATE: begin
                // §7b: vkUpdateDescriptorSets walks the staged writes
                if (op_q.cmd_type ==
                    APU_VN_TYPE_VK_UPDATE_DESCRIPTOR_SETS_EXT &&
                    op_q.imm[0] != 32'h0) begin
                  upd_i_q   <= '0;
                  upd_h_q   <= '0;
                  stg_i_q   <= '0;
                  stg_ret_q <= StUpdHdrC;
                  state_q   <= StStgRd;
                end else begin
                  state_q <= StRep;
                end
              end
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
                  // §7b: layout objects park a payload extent first —
                  // an ObjPay FULL means the object is never created
                  if (act_q.obj_kind ==
                      6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT) ||
                      act_q.obj_kind ==
                      6'(APU_VN_KIND_VK_PIPELINE_LAYOUT)) begin
                    prepend_w_q[0] <= op_q.imm[1];
                    prepend_w_q[1] <= op_q.imm[2];
                    prepend_n_q    <= 2'(prepend_n(act_q.obj_kind));
                    op_words_q     <= 16'(op_q.pay_words) +
                                      16'(prepend_n(act_q.obj_kind));
                    opr_q    <= '{op: APU_OBJPAY_OP_ALLOC,
                                  words: 32'(op_q.pay_words) +
                                          32'(prepend_n(act_q.obj_kind)),
                                  default: '0};
                    op_ret_q <= StPayAlcCpl;
                    state_q  <= StOpReq;
                  end else if (act_q.obj_kind ==
                               6'(APU_VN_KIND_VK_SHADER_MODULE)) begin
                    // §7b/5a-ii: claim a ShaderCore slot, then stream
                    // blob[0] (pCode) from the CS into wr_* for it
                    sm_op_q   <= APU_SH_SM_ALLOC;
                    sm_slot_q <= '0;
                    sm_ret_q  <= StShModObj;
                    state_q   <= StSmReq;
                  end else if (act_q.obj_kind ==
                               6'(APU_VN_KIND_VK_DEVICE_MEMORY)) begin
                    // §7b/5a-ii: aperture pages first; the object is
                    // created only if pages exist
                    automatic int ds = data_slot(op_q);
                    pg_op_q    <= APU_VGPAGES_OP_ALLOC;
                    pg_base_q  <= '0;
                    pg_bytes_q <= ds < 0 ? 32'h0 : 32'(op_q.q[ds]);
                    pg_ret_q   <= StAllocGo;
                    state_q    <= StPgReq;
                  end else begin
                    state_q <= StAllocGo;
                  end
                end else if (act_q.obj_kind ==
                             6'(APU_VN_KIND_VK_DESCRIPTOR_SET)) begin
                  // §7b: vkAllocateDescriptorSets elements need the
                  // staged layout ids — descriptor-set chain
                  blob_sel_q  <= act_q.flags[1];
                  blob_i_q    <= '0;
                  blob_n_q    <= 5'(op_q.blob[act_q.flags[1]].words
                                    >> 1);
                  blob_ret_q  <= StDSetLayLo;
                  blob_done_q <= StRep;
                  state_q     <= StBlobRd;
                end else if (act_q.obj_kind ==
                             6'(APU_VN_KIND_VK_PIPELINE) &&
                             op_q.pay_words != 16'h0) begin
                  // §7b/5a-ii: per-element {module id, spec, layout id}
                  // in the staging SRAM; out-ids in the flags[1] blob.
                  // No ObjPay extent — the object keeps {slot,layout}
                  // in aux and failed elements echo VK_NULL_HANDLE.
                  blob_sel_q  <= act_q.flags[1];
                  blob_i_q    <= '0;
                  blob_n_q    <= 5'(op_q.blob[act_q.flags[1]].words
                                    >> 1);
                  pl_errv_q   <= 1'b0;
                  blob_ret_q  <= StPipeH0;
                  blob_done_q <= StRep;
                  state_q     <= StBlobRd;
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
                             6'(APU_VN_KIND_VK_FENCE) ||
                             is_pay_kind(act_q.obj_kind) ||
                             is_auxret_kind(act_q.obj_kind)) begin
                  // pre-LOOKUP: aux[7:0] frees the arena bit for
                  // CB/FENCE; aux[63:32] frees the ObjPay extent for
                  // payload kinds
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
                if (rs < 0 || ms < 0) begin
                  result_q <= APU_VK_ERROR_UNKNOWN;
                  state_q  <= StRep;
                end else begin
                  // §7b: fetch the memory entry first — a bind whose
                  // memoryOffset + resource size overruns the memory's
                  // extent is invalid usage and is refused
                  otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                               id: {32'h0, hnd_q[ms]},
                               kind: op_q.qkind[ms], default: '0};
                  ot_ret_q <= StBindMemCk;
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
          StCrReq: if (cr_req_ready_i)
            state_q <= crr_q.pay_n != 16'h0 ? StPaySend : StCrCpl;
          StCrCpl: if (cr_cpl_valid_i) state_q <= cr_ret_q;
          StOpReq: if (op_req_ready_i) state_q <= StOpCpl;
          StOpCpl: if (op_cpl_valid_i) state_q <= op_ret_q;
          // one staged payload word -> stg_word_q -> stg_ret_q
          StStgRd:  state_q <= StStgCap;
          StStgCap: begin
            stg_word_q <= stg_rdata;
            state_q    <= stg_ret_q;
          end
          StCsRd:  if (front_rdy) state_q <= StCsCap;
          StCsCap: begin
            if (cs_rvalid_i) begin
              if (cs_err_i) begin
                // CS word outside the window: fail like a decode fault
                fault_q <= APU_VN_FAULT_BOUND;
                state_q <= StDone;
              end else begin
                csw_q   <= cs_rdata_i;
                state_q <= cs_ret_q;
              end
            end
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
            end else if (act_q.obj_kind ==
                         6'(APU_VN_KIND_VK_DEVICE_MEMORY) &&
                         !pg_ok_q) begin
              // §7b/5a-ii: vgpages FULL -> OOM, no object created
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
                         // §7b/5a-ii: entry.size feeds descriptor
                         // dispatch (buffer size) and the memory FREE
                         size: ds < 0 ? 64'h0 : op_q.q[ds],
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StAllocCpl;
              state_q  <= StOtReq;
            end
          end
          StAllocCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              if (is_pay_kind(act_q.obj_kind)) begin
                // object not created: release the payload extent
                opr_q    <= '{op: APU_OBJPAY_OP_FREE,
                              addr: {16'h0, op_base_q},
                              words: {16'h0, op_words_q},
                              default: '0};
                op_ret_q <= StRep;
                state_q  <= StOpReq;
              end else if (act_q.obj_kind ==
                           6'(APU_VN_KIND_VK_SHADER_MODULE)) begin
                // release the held ShaderCore slot
                sm_op_q  <= APU_SH_SM_UNREF;
                sm_ret_q <= StRep;
                state_q  <= StSmReq;
              end else if (act_q.obj_kind ==
                           6'(APU_VN_KIND_VK_DEVICE_MEMORY)) begin
                // release the held aperture pages
                pg_op_q  <= APU_VGPAGES_OP_FREE;
                pg_ret_q <= StRep;
                state_q  <= StPgReq;
              end else begin
                state_q <= StRep;
              end
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
            end else if (act_q.obj_kind ==
                         6'(APU_VN_KIND_VK_SHADER_MODULE)) begin
              // §7b/5a-ii: aux[2:0]=slot, aux[31:16]=nwords
              otr_q <= '{op: APU_OBJTAB_OP_SETAUX,
                         id: {32'h0, ot_cpl_i.handle},
                         kind: act_q.obj_kind,
                         mask: 32'hFFFF_0007,
                         value: {sh_nw_q, 13'h0, sh_slot_q},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StAllocAux;
              state_q  <= StOtReq;
            end else if (act_q.obj_kind ==
                         6'(APU_VN_KIND_VK_DEVICE_MEMORY)) begin
              // §7b/5a-ii: aux[63:32] = aperture page base
              hnd_pay_q   <= ot_cpl_i.handle;
              auxhi_val_q <= pg_res_q;
              auxhi_ret_q <= StRep;
              state_q     <= StAuxSet;
            end else if (is_pay_kind(act_q.obj_kind)) begin
              // §7b: copy staging -> ObjPay, then SETAUXHI {base,words}
              hnd_pay_q   <= ot_cpl_i.handle;
              auxhi_val_q <= {op_base_q, op_words_q};
              pay_i_q     <= '0;
              pay_done_q  <= StAuxSet;
              auxhi_ret_q <= StRep;
              state_q     <= StPayLoop;
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
              state_q <= StRep;
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
                          pay_n: pay_send_n_q,
                          rec: rec_q};
            cr_ret_q <= StAppendCpl;
            if (pay_send_n_q != 16'h0) begin
              // produce the first payload word while the request is
              // presented; streaming starts after the APPEND accept
              pay_send_q <= '0;
              pro_ret_q  <= StCrReq;
              state_q    <= StPayProd;
            end else begin
              state_q <= StCrReq;
            end
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
              // §7b: payload kinds free their ObjPay extent on retire
              payf_q       <= is_pay_kind(act_q.obj_kind);
              payf_base_q  <= ot_cpl_i.entry.aux[63:48];
              payf_words_q <= ot_cpl_i.entry.aux[47:32];
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
            end else if (payf_q && payf_words_q != 16'h0) begin
              if (aux_free_v_q) aux_free_v_q <= 1'b0;
              payf_q <= 1'b0;
              opr_q    <= '{op: APU_OBJPAY_OP_FREE,
                            addr: {16'h0, payf_base_q},
                            words: {16'h0, payf_words_q}, default: '0};
              op_ret_q <= StElemRetPay;
              state_q  <= StOpReq;
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
          StElemRetPay: begin
            blob_i_q <= blob_i_q + 5'd1;
            state_q  <= StBlobRd;
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
              aux_free_v_q <= (act_q.obj_kind ==
                               6'(APU_VN_KIND_VK_COMMAND_BUFFER) ||
                               act_q.obj_kind ==
                               6'(APU_VN_KIND_VK_FENCE)) &&
                              ot_cpl_i.entry.aux[7:0] <
                              (act_q.obj_kind == 6'(APU_VN_KIND_VK_FENCE)
                               ? 8'(Fences) : 8'(CbBufs));
              // §7b: payload kinds free their ObjPay extent on retire
              payf_q       <= is_pay_kind(act_q.obj_kind);
              payf_base_q  <= ot_cpl_i.entry.aux[63:48];
              payf_words_q <= ot_cpl_i.entry.aux[47:32];
              if (act_q.obj_kind ==
                  6'(APU_VN_KIND_VK_DEVICE_MEMORY)) begin
                // §7b/5a-ii: hold the aperture extent for the
                // post-retire FREE
                pg_base_q  <= ot_cpl_i.entry.aux[63:32];
                pg_bytes_q <= 32'(ot_cpl_i.entry.size);
              end
              if (act_q.obj_kind ==
                  6'(APU_VN_KIND_VK_SHADER_MODULE) ||
                  act_q.obj_kind == 6'(APU_VN_KIND_VK_PIPELINE)) begin
                // §7b/5a-ii: release the ShaderCore slot reference
                // first, then retire the object
                sm_op_q   <= APU_SH_SM_UNREF;
                sm_slot_q <= ot_cpl_i.entry.aux[2:0];
                sm_ret_q  <= StRetSm;
                state_q   <= StSmReq;
              end else begin
                otr_q    <= '{op: APU_OBJTAB_OP_RETIRE,
                             id: op_q.q[
                                 role_slot(op_q, APU_VN_ROLE_RETIRE)],
                             kind: act_q.obj_kind, default: '0};
                ot_ret_q <= StRetCpl;
                state_q  <= StOtReq;
              end
            end
          end
          StRetCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else begin
              if (aux_free_v_q) begin
                if (aux_fence_q)
                  falloc_q[aux_free_q[$clog2(Fences)-1:0]] <= 1'b0;
                else begin
                  cb_alloc_q[aux_free_q[$clog2(CbBufs)-1:0]] <= 1'b0;
                  cb_pool_q [aux_free_q[$clog2(CbBufs)-1:0]] <= '0;
                  cb_hnd_q  [aux_free_q[$clog2(CbBufs)-1:0]] <= '0;
                end
                aux_free_v_q <= 1'b0;
              end
              if (payf_q && payf_words_q != 16'h0) begin
                payf_q <= 1'b0;
                opr_q    <= '{op: APU_OBJPAY_OP_FREE,
                              addr: {16'h0, payf_base_q},
                              words: {16'h0, payf_words_q},
                              default: '0};
                op_ret_q <= StRep;
                state_q  <= StOpReq;
              end else if (act_q.obj_kind ==
                           6'(APU_VN_KIND_VK_DEVICE_MEMORY)) begin
                // §7b/5a-ii: vkFreeMemory returns its aperture pages
                pg_op_q    <= APU_VGPAGES_OP_FREE;
                pg_ret_q   <= StRep;
                state_q    <= StPgReq;
              end else begin
                state_q <= StRep;
              end
            end
          end
          // §7b: BIND's memory LOOKUP — refuse memoryOffset + resource
          // size past the memory's extent (invalid usage)
          StBindMemCk: begin
            automatic int rs = lu_slot(op_q, 1);
            automatic int ms = lu_slot(op_q, 2);
            automatic int os = data_slot(op_q);
            automatic logic [63:0] moff =
                os < 0 ? 64'h0 : op_q.q[os];
            // subtractive form: refuses memoryOffset + size past the
            // memory extent without 64-bit wraparound in the sum
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                moff > ot_cpl_i.entry.size ||
                ent_q.size > ot_cpl_i.entry.size - moff) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              otr_q <= '{op: APU_OBJTAB_OP_SETBIND,
                         id: {32'h0, hnd_q[rs]},
                         kind: op_q.qkind[rs],
                         mem_id: {32'h0, hnd_q[ms]},
                         offset: moff,
                         // ent_q = the bound resource (watched
                         // above): keep its declared size as the
                         // bound extent for §7b dispatch
                         size: ent_q.size,
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StRetCpl;   // same status mapping
              state_q  <= StOtReq;
            end
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
                              rec: '0, pay_n: '0};
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
                              rec: '0, pay_n: '0};
                cr_ret_q <= StCbCrCpl;
                state_q  <= StCrReq;
              end
            end else if (act_q.act_class == APU_VN_ACT_CB_RESET) begin
              crr_q    <= '{op: APU_CMDREC_OP_RESET,
                            cbuf: 8'(ent_q.aux[7:0]), idx: '0,
                            rec: '0, pay_n: '0};
              cr_ret_q <= StCbCrCpl;
              state_q  <= StCrReq;
            end else begin
              // RECORD: requires RECORDING, not PENDING/INVALID
              if ((ent_q.state & APU_CB_RECORDING) == 0 ||
                  (ent_q.state & (APU_CB_INVALID | APU_CB_PENDING)) != 0 ||
                  (op_q.cmd_type ==
                   APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT &&
                   op_q.imm[2] > 32'd128)) begin
                // §7b: pValues over 128 B joins the INVALID path
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
                // §7b: payload-arena word counts per record
                pay_bind_q <= op_q.cmd_type ==
                              APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT;
                pay_nset_q <= 16'(op_q.imm[2]);
                pay_send_n_q <=
                    op_q.cmd_type ==
                    APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT
                    ? 16'(op_q.imm[2] + op_q.imm[3])
                    : op_q.cmd_type ==
                      APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT
                      ? 16'(op_q.pay_words) : 16'h0;
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
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              // §7b: a failed append (arena FULL, payload PAY_FULL)
              // leaves the command buffer INVALID
              otr_q    <= '{op: APU_OBJTAB_OP_SETSTATE,
                            id: {32'h0,
                                 hnd_q[int'(act_q.cmdbuf_qslot)]},
                            kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                            mask: APU_CB_STATE_MASK,
                            value: APU_CB_INVALID, default: '0};
              ot_ret_q <= StRep;
              state_q  <= StOtReq;
            end else begin
              state_q <= StRep;
            end
          end

          // ---- §7b: ObjPay ALLOC completion ---------------------------------
          StPayAlcCpl: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
              state_q  <= StRep;
            end else begin
              op_base_q <= 16'(op_cpl_i.base);
              if (act_q.obj_kind == 6'(APU_VN_KIND_VK_PIPELINE)) begin
                // pipeline payload: copy now, attach at first element
                pay_i_q    <= '0;
                pay_done_q <= StBlobRd;
                state_q    <= StPayLoop;
              end else begin
                // DSL/PL: ObjTab.ALLOC next, copy in StAllocCpl
                state_q <= StAllocGo;
              end
            end
          end

          // ---- §7b: staging -> ObjPay copy ----------------------------------
          StPayLoop: begin
            if (pay_i_q >= op_words_q) begin
              state_q <= pay_done_q;
            end else if (pay_i_q < {14'h0, prepend_n_q}) begin
              opr_q    <= '{op: APU_OBJPAY_OP_WRITE,
                            addr: {16'h0, op_base_q} +
                                  {16'h0, pay_i_q},
                            wdata: prepend_w_q[pay_i_q[0]],
                            default: '0};
              op_ret_q <= StPayNext;
              state_q  <= StOpReq;
            end else begin
              stg_i_q   <= StgBits'(pay_i_q - {14'h0, prepend_n_q});
              stg_ret_q <= StPayWr;
              state_q   <= StStgRd;
            end
          end
          StPayWr: begin
            opr_q    <= '{op: APU_OBJPAY_OP_WRITE,
                          addr: {16'h0, op_base_q} +
                                {16'h0, pay_i_q},
                          wdata: stg_word_q, default: '0};
            op_ret_q <= StPayNext;
            state_q  <= StOpReq;
          end
          StPayNext: begin
            pay_i_q <= pay_i_q + 16'd1;
            state_q <= StPayLoop;
          end

          // ---- §7b: SETAUXHI {base,words} ------------------------------------
          StAuxSet: begin
            otr_q    <= '{op: APU_OBJTAB_OP_SETAUXHI,
                         id: {32'h0, hnd_pay_q},
                         kind: act_q.obj_kind,
                         mask: 32'hFFFF_FFFF,
                         value: auxhi_val_q,
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StAuxHiCpl;
            state_q  <= StOtReq;
          end
          StAuxHiCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              state_q <= auxhi_ret_q;
            end
          end

          // ---- §7b: vkAllocateDescriptorSets element chain -------------------
          // staged layout id for set blob_i_q -> LOOKUP -> bindingCount
          StDSetLayLo: begin
            stg_i_q   <= StgBits'({2'b0, blob_i_q} << 1);
            stg_ret_q <= StDSetLayHi;
            state_q   <= StStgRd;
          end
          StDSetLayHi: begin
            lay_lo_q  <= stg_word_q;
            stg_i_q   <= stg_i_q + 1'b1;
            stg_ret_q <= StDSetLayId;
            state_q   <= StStgRd;
          end
          StDSetLayId: begin
            otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                         id: {stg_word_q, lay_lo_q},
                         kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT),
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StDSetLayCpl;
            state_q  <= StOtReq;
          end
          StDSetLayCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              lay_base_q  <= ot_cpl_i.entry.aux[63:48];
              lay_words_q <= ot_cpl_i.entry.aux[47:32];
              opr_q    <= '{op: APU_OBJPAY_OP_READ,
                            addr: {16'h0, ot_cpl_i.entry.aux[63:48]},
                            default: '0};
              op_ret_q <= StDSetNbCpl;
              state_q  <= StOpReq;
            end
          end
          StDSetNbCpl: begin
            // layout payload word 0 = bindingCount
            lay_nbind_q <= op_cpl_i.rdata[15:0];
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else if (op_cpl_i.rdata == 32'h0) begin
              op_base_q  <= '0;
              op_words_q <= '0;
              state_q    <= StDSetObj;
            end else begin
              opr_q    <= '{op: APU_OBJPAY_OP_ALLOC,
                            words: op_cpl_i.rdata << 2, default: '0};
              op_ret_q <= StDSetAlcCpl;
              state_q  <= StOpReq;
            end
          end
          StDSetAlcCpl: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
              state_q  <= StRep;
            end else begin
              op_base_q  <= 16'(op_cpl_i.base);
              op_words_q <= lay_nbind_q << 2;
              state_q    <= StDSetObj;
            end
          end
          StDSetObj: begin
            otr_q    <= '{op: APU_OBJTAB_OP_ALLOC,
                         id: blob_id_q,
                         kind: act_q.obj_kind,
                         parent_id: act_q.parent_qslot ==
                                    APU_VN_QSLOT_NONE
                                    ? 64'h0
                                    : {32'h0,
                                       hnd_q[int'(act_q.parent_qslot)]},
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StDSetOCpl;
            state_q  <= StOtReq;
          end
          StDSetOCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              if (op_words_q != 16'h0) begin
                opr_q    <= '{op: APU_OBJPAY_OP_FREE,
                              addr: {16'h0, op_base_q},
                              words: {16'h0, op_words_q},
                              default: '0};
                op_ret_q <= StRep;
                state_q  <= StOpReq;
              end else begin
                state_q <= StRep;
              end
            end else begin
              hnd_pay_q <= ot_cpl_i.handle;
              ent_j_q   <= '0;
              state_q   <= StDSetFill;
            end
          end
          // per binding: read {type,count} from the layout payload,
          // write the zeroed entry with the unsupported flag set when
          // descriptorCount > 1 or the type is not a buffer type
          StDSetFill: begin
            if (ent_j_q >= lay_nbind_q) begin
              blob_i_q    <= blob_i_q + 5'd1;
              auxhi_val_q <= {op_base_q, op_words_q};
              auxhi_ret_q <= StBlobRd;
              state_q     <= StAuxSet;
            end else begin
              opr_q    <= '{op: APU_OBJPAY_OP_READ,
                            addr: {16'h0, lay_base_q} +
                                  32'd1 + (32'(ent_j_q) << 2) + 32'd1,
                            default: '0};
              op_ret_q <= StDSetFillT;
              state_q  <= StOpReq;
            end
          end
          StDSetFillT: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              lay_type_q <= op_cpl_i.rdata;
              opr_q    <= '{op: APU_OBJPAY_OP_READ,
                            addr: {16'h0, lay_base_q} +
                                  32'd1 + (32'(ent_j_q) << 2) + 32'd2,
                            default: '0};
              op_ret_q <= StDSetFillC;
              state_q  <= StOpReq;
            end
          end
          StDSetFillC: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              // entry {handle, offset, range, flags}; only word 3 is
              // non-zero at allocation time
              entw_q  <= '{(op_cpl_i.rdata > 32'd1 ||
                            (lay_type_q != 32'd6 &&
                             lay_type_q != 32'd7))
                           ? 32'h8000_0000 : 32'h0,
                           32'h0, 32'h0, 32'h0};
              ent_k_q <= '0;
              state_q <= StDSetWr;
            end
          end
          StDSetWr: begin
            opr_q    <= '{op: APU_OBJPAY_OP_WRITE,
                          addr: {16'h0, op_base_q} +
                                (32'(ent_j_q) << 2) + 32'(ent_k_q),
                          wdata: entw_q[ent_k_q], default: '0};
            op_ret_q <= StDSetWrC;
            state_q  <= StOpReq;
          end
          StDSetWrC: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else if (ent_k_q == 2'd3) begin
              ent_j_q <= ent_j_q + 16'd1;
              state_q <= StDSetFill;
            end else begin
              ent_k_q <= ent_k_q + 2'd1;
              state_q <= StDSetWr;
            end
          end

          // ---- §7b: vkUpdateDescriptorSets staged walk -----------------------
          // write header {dstSet(2), dstBinding, dstArrayElement,
          // descriptorCount, descriptorType} then descriptorCount buffer
          // infos {buffer(2), offset(2), range(2)} for buffer types
          StUpdHdrC: begin
            case (upd_h_q)
              3'd0: upd_dst_q[31:0]  <= stg_word_q;
              3'd1: upd_dst_q[63:32] <= stg_word_q;
              3'd2: upd_dstb_q       <= stg_word_q;
              3'd3: upd_arr_q        <= stg_word_q;
              3'd4: upd_dcnt_q       <= stg_word_q;
              default: upd_type_q    <= stg_word_q;
            endcase
            stg_i_q <= stg_i_q + 1'b1;
            upd_h_q <= upd_h_q + 3'd1;
            if (upd_h_q == 3'd5) begin
              otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                           id: upd_dst_q,
                           kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StUpdSetCpl;
              state_q  <= StOtReq;
            end else begin
              stg_ret_q <= StUpdHdrC;
              state_q   <= StStgRd;
            end
          end
          StUpdSetCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              dset_base_q  <= ot_cpl_i.entry.aux[63:48];
              dset_words_q <= ot_cpl_i.entry.aux[47:32];
              ent_j_q      <= '0;
              state_q      <= StUpdInfo;
            end
          end
          StUpdInfo: begin
            if (ent_j_q >= upd_dcnt_q[15:0]) begin
              // next write
              if (upd_i_q + 16'd1 >= op_q.imm[0][15:0]) begin
                state_q <= StRep;
              end else begin
                upd_i_q   <= upd_i_q + 16'd1;
                upd_h_q   <= '0;
                stg_ret_q <= StUpdHdrC;
                state_q   <= StStgRd;
              end
            end else if (upd_type_q != 32'd6 && upd_type_q != 32'd7) begin
              // non-buffer descriptor type: no staged infos; the
              // binding's entry is marked unsupported
              entw_q     <= '{upd_type_q | 32'h8000_0000,
                              32'h0, 32'h0, 32'h0};
              ent_k_q    <= '0;
              upd_idx_q  <= 32'(upd_dstb_q) + 32'(ent_j_q) <
                            {16'h0, dset_words_q[15:2]}
                            ? upd_dstb_q[15:0] + ent_j_q
                            : dset_words_q[15:2] - 16'd1;
              state_q    <= dset_words_q != 16'h0
                            ? StUpdWr : StUpdInfoNext;
            end else begin
              upd_h_q   <= '0;
              stg_ret_q <= StUpdInfoC;
              state_q   <= StStgRd;
            end
          end
          StUpdInfoC: begin
            case (upd_h_q)
              3'd0: upd_buf_q[31:0]  <= stg_word_q;
              3'd1: upd_buf_q[63:32] <= stg_word_q;
              3'd2: upd_off_q[31:0]  <= stg_word_q;
              3'd3: upd_off_q[63:32] <= stg_word_q;
              3'd4: upd_rng_q[31:0]  <= stg_word_q;
              default: upd_rng_q[63:32] <= stg_word_q;
            endcase
            stg_i_q <= stg_i_q + 1'b1;
            upd_h_q <= upd_h_q + 3'd1;
            if (upd_h_q == 3'd5) begin
              state_q <= StUpdBufGo;
            end else begin
              stg_ret_q <= StUpdInfoC;
              state_q   <= StStgRd;
            end
          end
          StUpdBufGo: begin
            otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                         id: upd_buf_q,
                         kind: 6'(APU_VN_KIND_VK_BUFFER),
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StUpdBufCpl;
            state_q  <= StOtReq;
          end
          StUpdBufCpl: begin
            if (32'(upd_dstb_q) + 32'(ent_j_q) >=
                {16'h0, dset_words_q[15:2]}) begin
              // dstBinding+k out of range: the set's last entry is
              // marked unsupported rather than faulting
              entw_q    <= '{upd_type_q | 32'h8000_0000,
                             32'h0, 32'h0, 32'h0};
              upd_idx_q <= dset_words_q[15:2] - 16'd1;
            end else begin
              entw_q    <= '{(ot_cpl_i.status != APU_OBJTAB_OK ||
                              upd_type_q != 32'd6 &&
                              upd_type_q != 32'd7)
                            ? upd_type_q | 32'h8000_0000 : upd_type_q,
                            upd_rng_q[31:0], upd_off_q[31:0],
                            ot_cpl_i.status == APU_OBJTAB_OK
                            ? ot_cpl_i.handle : 32'h0};
              upd_idx_q <= upd_dstb_q[15:0] + ent_j_q;
            end
            ent_k_q <= '0;
            state_q <= dset_words_q != 16'h0
                       ? StUpdWr : StUpdInfoNext;
          end
          StUpdWr: begin
            opr_q    <= '{op: APU_OBJPAY_OP_WRITE,
                          addr: {16'h0, dset_base_q} +
                                (32'(upd_idx_q) << 2) + 32'(ent_k_q),
                          wdata: entw_q[ent_k_q], default: '0};
            op_ret_q <= StUpdWrC;
            state_q  <= StOpReq;
          end
          StUpdWrC: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else if (ent_k_q == 2'd3) begin
              state_q <= StUpdInfoNext;
            end else begin
              ent_k_q <= ent_k_q + 2'd1;
              state_q <= StUpdWr;
            end
          end
          StUpdInfoNext: begin
            ent_j_q <= ent_j_q + 16'd1;
            state_q <= StUpdInfo;
          end

          // ---- §7b: cmdrec payload producer ----------------------------------
          // produce stream word pay_send_q into pay_word_q:
          // PushConstants streams staged words verbatim;
          // BindDescriptorSets resolves each staged set id through
          // ObjTab (LOOKUP at record time) then streams the offsets
          StPayProd: begin
            if (pay_bind_q && pay_send_q < pay_nset_q) begin
              stg_i_q   <= StgBits'(pay_send_q << 1);
              stg_ret_q <= StPayResLo;
            end else if (pay_bind_q) begin
              stg_i_q   <= StgBits'((pay_nset_q << 1) +
                                    (pay_send_q - pay_nset_q));
              stg_ret_q <= StPayCapW;
            end else begin
              stg_i_q   <= StgBits'(pay_send_q);
              stg_ret_q <= StPayCapW;
            end
            state_q <= StStgRd;
          end
          StPayResLo: begin
            lay_lo_q  <= stg_word_q;
            stg_i_q   <= stg_i_q + 1'b1;
            stg_ret_q <= StPayResHi;
            state_q   <= StStgRd;
          end
          StPayResHi: begin
            otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                         id: {stg_word_q, lay_lo_q},
                         kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StPayResCpl;
            state_q  <= StOtReq;
          end
          StPayResCpl: begin
            // a set that misses at record time stores a null handle;
            // the dispatch-time re-resolve refuses it
            pay_word_q <= ot_cpl_i.status == APU_OBJTAB_OK
                          ? ot_cpl_i.handle : 32'h0;
            state_q    <= pro_ret_q;
          end
          StPayCapW: begin
            pay_word_q <= stg_word_q;
            state_q    <= pro_ret_q;
          end
          StPaySend: begin
            if (cr_pay_ready_i) begin
              if (pay_send_q + 16'd1 >= pay_send_n_q) begin
                state_q <= StCrCpl;
              end else begin
                pay_send_q <= pay_send_q + 16'd1;
                pro_ret_q  <= StPaySend;
                state_q    <= StPayProd;
              end
            end
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
                            cbuf: {3'h0, are_i_q}, idx: '0, rec: '0,
                            pay_n: '0};
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

          // ---- §7b/5a-ii: ShaderCore slot manager --------------------
          StSmReq:  state_q <= StSmCpl;
          StSmCpl: if (sm_cpl_i) begin
            sm_ok_q    <= sm_cpl_pl_i.ok;
            sm_rslot_q <= sm_cpl_pl_i.slot;
            state_q    <= sm_ret_q;
          end

          // ---- §7b/5a-ii: aperture page allocator --------------------
          StPgReq: if (pg_req_ready_i) state_q <= StPgCpl;
          StPgCpl: if (pg_cpl_valid_i) begin
            pg_ok_q  <= pg_cpl_i.status == APU_VGPAGES_OK;
            pg_res_q <= pg_cpl_i.base;
            state_q  <= pg_ret_q;
          end

          // ---- §7b/5a-ii: vkCreateShaderModule ------------------------
          // sm ALLOC completion -> pCode staging (blob[0])
          StShModObj: begin
            if (!sm_ok_q) begin
              result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
              state_q  <= StRep;
            end else begin
              sh_slot_q <= sm_rslot_q;
              sh_nw_q   <= 16'(op_q.blob[0].words);
              shw_i_q   <= '0;
              shw_n_q   <= 16'(op_q.blob[0].words);
              if (op_q.blob[0].words == 17'h0) begin
                state_q <= StShModCpl;
              end else begin
                state_q <= StShRd;
              end
            end
          end
          // stream blob[0] words: CS read (StCsRd->StCsCap->csw_q),
          // then a sh_wr pulse in StShWr
          StShRd: begin
            csa_q    <= cs_base_q + op_q.blob[0].off + shw_i_q;
            cs_ret_q <= StShWr;
            state_q  <= StCsRd;
          end
          StShWr: begin
            shw_i_q <= shw_i_q + 16'd1;
            state_q <= (shw_i_q + 16'd1 >= shw_n_q)
                       ? StShModCpl : StShRd;
          end
          // staging done: ObjTab.ALLOC the module object
          StShModCpl: begin
            automatic int ns = role_slot(op_q, APU_VN_ROLE_NEW);
            automatic int ps = act_q.parent_qslot != APU_VN_QSLOT_NONE
                               ? int'(act_q.parent_qslot) : -1;
            otr_q <= '{op: APU_OBJTAB_OP_ALLOC,
                       id: op_q.q[ns],
                       kind: act_q.obj_kind,
                       parent_id: ps < 0 ? 64'h0
                                         : {32'h0, hnd_q[ps]},
                       ctx: ctx_i, default: '0};
            ot_ret_q <= StAllocCpl;
            state_q  <= StOtReq;
          end
          // ---- §7b/5a-ii: vkCreateComputePipelines element -----------
          // staged payload: 5 words per element {module id(2),
          // spec presence(1), layout id(2)} at staging offset 5*i
          StPipeH0: begin
            stg_i_q   <= StgBits'({2'b0, blob_i_q} * 3'd5);
            stg_ret_q <= StPipeH1;
            state_q   <= StStgRd;
          end
          StPipeH1: begin
            pl_modid_q[31:0] <= stg_word_q;
            stg_i_q <= stg_i_q + 1'b1;
            stg_ret_q <= StPipeH2;
            state_q   <= StStgRd;
          end
          StPipeH2: begin
            pl_modid_q[63:32] <= stg_word_q;
            stg_i_q <= stg_i_q + 1'b1;
            stg_ret_q <= StPipeH3;
            state_q   <= StStgRd;
          end
          StPipeH3: begin
            pl_spec_q <= stg_word_q != 32'h0;
            stg_i_q <= stg_i_q + 1'b1;
            stg_ret_q <= StPipeH4;
            state_q   <= StStgRd;
          end
          StPipeH4: begin
            pl_layid_q[31:0] <= stg_word_q;
            stg_i_q <= stg_i_q + 1'b1;
            stg_ret_q <= StPipeLay0;
            state_q   <= StStgRd;
          end
          StPipeLay0: begin
            pl_layid_q[63:32] <= stg_word_q;
            if (pl_spec_q) begin
              state_q <= StPipeFail;
            end else begin
              // LOOKUP the shader module -> {slot, nwords} in aux
              otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                           id: pl_modid_q,
                           kind: 6'(APU_VN_KIND_VK_SHADER_MODULE),
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StPipeModCpl;
              state_q  <= StOtReq;
            end
          end
          StPipeModCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              state_q <= StPipeFail;
            end else begin
              sh_slot_q <= ot_cpl_i.entry.aux[2:0];
              sh_nw_q   <= ot_cpl_i.entry.aux[31:16];
              otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                           id: pl_layid_q,
                           kind: 6'(APU_VN_KIND_VK_PIPELINE_LAYOUT),
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StPipeLayCpl;
              state_q  <= StOtReq;
            end
          end
          StPipeLayCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              state_q <= StPipeFail;
            end else begin
              pl_layh_q <= ot_cpl_i.handle;
              state_q   <= StShCommit;
            end
          end
          // commit the module's code into its slot; wait sh_c_done
          StShCommit: state_q <= StShCWait;
          StShCWait: if (sh_c_done_i) begin
            shc_ok_q <= sh_c_done_pl_i.ok;
            if (!sh_c_done_pl_i.ok) begin
              state_q <= StPipeFail;
            end else begin
              // commit ok: the pipeline holds a slot reference
              sm_op_q   <= APU_SH_SM_REF;
              sm_ret_q  <= StPipeAllocC;
              state_q   <= StSmReq;
            end
          end
          // REF ok -> ObjTab.ALLOC the pipeline object
          StPipeAllocC: begin
            if (!sm_ok_q) begin
              state_q <= StPipeFail;
            end else begin
              otr_q <= '{op: APU_OBJTAB_OP_ALLOC,
                         id: blob_id_q,
                         kind: act_q.obj_kind,
                         parent_id: act_q.parent_qslot ==
                                    APU_VN_QSLOT_NONE
                                    ? 64'h0
                                    : {32'h0,
                                       hnd_q[int'(act_q.parent_qslot)]},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StPipeAuxC;
              state_q  <= StOtReq;
            end
          end
          StPipeAuxC: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              // no object: release the reference we just took
              sm_op_q  <= APU_SH_SM_UNREF;
              sm_ret_q <= StPipeFail;
              state_q  <= StSmReq;
            end else begin
              hnd_pay_q <= ot_cpl_i.handle;
              otr_q <= '{op: APU_OBJTAB_OP_SETAUX,
                         id: {32'h0, ot_cpl_i.handle},
                         kind: act_q.obj_kind,
                         mask: 32'h7,
                         value: {29'h0, sh_slot_q},
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StPipeAuxCpl;
              state_q  <= StOtReq;
            end
          end
          StPipeAuxCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              state_q <= StPipeFail;
            end else begin
              // aux[63:32] = pipeline-layout handle {gen,slot}
              auxhi_val_q <= pl_layh_q;
              auxhi_ret_q <= StPipeAuxHiC;
              state_q     <= StAuxSet;
            end
          end
          StPipeAuxHiC: begin
            blob_i_q <= blob_i_q + 5'd1;
            state_q  <= StBlobRd;
          end
          // failed element: first error + VK_NULL_HANDLE echo
          StPipeFail: begin
            if (!pl_errv_q) begin
              pl_errv_q <= 1'b1;
              result_q  <= APU_VK_ERROR_UNKNOWN;
            end
            rep_null_mask_q[blob_i_q] <= 1'b1;
            blob_i_q <= blob_i_q + 5'd1;
            state_q  <= StBlobRd;
          end

          // ---- §7b/5a-ii: retire continuation after sm UNREF ----------
          StRetSm: begin
            otr_q    <= '{op: APU_OBJTAB_OP_RETIRE,
                         id: op_q.q[
                             role_slot(op_q, APU_VN_ROLE_RETIRE)],
                         kind: act_q.obj_kind, default: '0};
            ot_ret_q <= StRetCpl;
            state_q  <= StOtReq;
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
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(parameter bit Enable = 1'b0,
  parameter int unsigned Fences = 16,
  parameter int unsigned CbBufs = 16,
  parameter int unsigned PayStageWords = 1024) (
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
  input  logic               cs_ready_i,
  input  logic               cs_rvalid_i,
  input  logic [31:0]        cs_rdata_i,
  input  logic               cs_err_i,
  output logic               rep_we_o,
  output logic [15:0]        rep_addr_o,
  output logic [31:0]        rep_wdata_o,
  input  logic               rep_ready_i,
  input  logic               rep_done_i,
  input  logic               rep_err_i,
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
  output logic               cr_pay_valid_o,
  output logic [31:0]        cr_pay_data_o,
  input  logic               cr_pay_ready_i,
  output logic               op_req_valid_o,
  input  logic               op_req_ready_i,
  output apu_objpay_req_t    op_req_o,
  input  logic               op_cpl_valid_i,
  output logic               op_cpl_ready_o,
  input  apu_objpay_cpl_t    op_cpl_i,
  output logic               sm_req_o,
  output apu_sh_sm_req_t     sm_req_pl_o,
  input  logic               sm_cpl_i,
  input  apu_sh_sm_cpl_t     sm_cpl_pl_i,
  output logic               sh_wr_en_o,
  output logic [2:0]         sh_wr_slot_o,
  output logic [15:0]        sh_wr_addr_o,
  output logic [31:0]        sh_wr_data_o,
  output logic               sh_commit_o,
  output apu_sh_commit_t     sh_commit_pl_o,
  input  logic               sh_c_done_i,
  input  apu_sh_cpl_t        sh_c_done_pl_i,
  output logic               pg_req_valid_o,
  input  logic               pg_req_ready_i,
  output apu_vgpages_req_t   pg_req_o,
  input  logic               pg_cpl_valid_i,
  output logic               pg_cpl_ready_o,
  input  apu_vgpages_cpl_t   pg_cpl_i,
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
                     .CbBufs(CbBufs),
                     .PayStageWords(PayStageWords)) i_dut (.*);
endmodule
