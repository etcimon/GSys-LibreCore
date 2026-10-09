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
//             object).  §12.3 F5: the layout's payload is a row table,
//             word0={pad,nbind} then per binding {binding,type,count} +
//             {off32,dyn,dynbase} built from the staged quad; aux =
//             {{base,words}, {ndyn, set_bytes}}.  VkPipelineLayout
//             copies staging verbatim (count words prepended) and
//             parks aux[63:32] = {base,words} via SETAUXHI.  Compute
//             pipelines store the whole payload extent once and the
//             first created pipeline object parks it.
//             vkCreateDescriptorPool sums pPoolSizes.descriptorCount
//             into dsum_q, vgpages-allocates dsum*APU_DESC_BYTES of
//             record storage, and mints aux = {{nsets,bump}, base},
//             size = capacity bytes, state = {maxSets, epoch}.
//             vkAllocateDescriptorSets bump-allocates each set's table
//             from the pool (dead pool / maxSets / capacity ->
//             VK_ERROR_OUT_OF_POOL_MEMORY and the rest of the elements
//             echo VK_NULL_HANDLE), zeroes the records through the
//             ap_* port, and mints aux = {layout {gen,slot},
//             poison|ndyn|set_base}, size = pool {gen,slot},
//             state[15:0] = pool epoch.
//   RETIRE    payload kinds free their ObjPay extent from aux[63:32];
//             descriptor pools free their vgpages extent (aux[31:0],
//             size bytes) — minted sets stay in ObjTab but their
//             pool-gen/epoch check turns a dispatch into DEVICE_LOST
//   UPDATE    vkUpdateDescriptorSets writes 32-byte records through
//             ap_*: for each staged write it resolves the set, its
//             pool (epoch + generation — a dead pool skips the write
//             silently) and its layout row (binding-number scan), then
//             per element resolves the buffer, its bound memory
//             (READSLOT) and writes {base,size,kind,flags} at
//             set_base + (off32 + dstArrayElement + i)*32.  Any
//             row miss, type mismatch, array overrun or failed buffer
//             bound-write sets the set's poison bit (aux[31]) so the
//             dispatch is DEVICE_LOST.  Copies resolve src and dst
//             sets the same way and move the record bytes.
//   RECORD    vkCmdPushConstants/vkCmdBindDescriptorSets stream their
//             payloads into the cmdrec per-buffer arena; the record's
//             imm[7] carries the arena base.  BindDescriptorSets
//             resolves each staged set id through ObjTab at record
//             time (a MISS stores a null handle) and emits {handle,
//             ndyn} pairs ahead of the dynamic-offset words.
//             pValues over 128 B takes the INVALID path.
//   POOL_RESET vkResetDescriptorPool bumps the pool's epoch and
//             clears {nsets,bump} — minted sets become dead for any
//             later dispatch (their ObjTab slots persist until
//             destroy/context reset; documented device limit).
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
  // §12.3 F5: descriptor-record aperture port — vnpump arbitrates
  // this onto the shared mp port (dom=1, aperture-relative byte
  // address, 8-byte beats).  ap_req_o is held until ap_ready_i; every
  // accepted request sees exactly one ap_done_i.
  output logic               ap_req_o,
  output logic               ap_we_o,
  output logic [31:0]        ap_addr_o,
  output logic [63:0]        ap_wdata_o,
  output logic [7:0]         ap_wstrb_o,
  input  logic               ap_ready_i,
  input  logic               ap_done_i,
  input  logic [63:0]        ap_rdata_i,
  input  logic               ap_err_i,
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
    assign ap_req_o = 1'b0;   assign ap_we_o = 1'b0;
    assign ap_addr_o = '0;    assign ap_wdata_o = '0;
    assign ap_wstrb_o = '0;
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

    typedef enum logic [7:0] {
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
      StRetKids,
      StBindMemCk,
      StBind2Rd, StBind2ResC, StBind2MemC, StBind2SetC,
      StCbGo, StCbCrCpl, StCbSetCpl,
      StRecFill, StRecApp, StAppendCpl,
      StSubPush, StSubState, StSubStateNext,
      StWaitIdle, StFencPoll, StFencClr,
      StPoolLoop, StPoolSet, StPoolNext,
      // §7b: payload machinery
      StOpReq, StOpCpl, StStgRd, StStgCap,
      StPayAlcCpl, StPayLoop, StPayNext, StPayWr, StAuxSet,
      StAuxHiCpl,
      // §12.3 F5: generic SETAUX-lo / SETSTATE subroutines
      StAuxLo, StAuxLoCpl, StStSet, StStSetCpl,
      // §12.3 F5: aperture-record port subroutine
      StApReq, StApCpl,
      // §12.3 F5: descriptor-pool create (pPoolSizes sum -> pages)
      //           and reset (epoch++)
      StDPoolSum, StDPoolSumC, StDPoolPgC, StDPoolAuxH,
      StDPoolAuxS,
      StDPoolRs, StDPoolRsK, StDPoolRsHi,
      // §12.3 F5: descriptor-set-layout row build in objpay
      StDslHdrC, StDslRd, StDslWr, StDslWrC, StDslAuxL, StDslHash,
      // §12.3 F5: descriptor-set allocation element chain
      StDSetLayLo, StDSetLayHi, StDSetLayId, StDSetLayCpl,
      StDSetPoolC, StDSetObj, StDSetOCpl, StDSetAuxH,
      StDSetEpoch, StDSetZero, StDSetZeroC, StDSetBump, StDSetBumpC,
      // §12.3 F5: vkUpdateDescriptorSets — resolve-set and
      // binding-row-scan subroutines, then record writes/copies
      StRsvLuC, StRsvPoolC, StRsvLayC,
      StRowSc, StRowW0C, StRowW1C,
      StUpdHdrC, StUpdSetCpl, StUpdWBegin, StUpdWBad, StUpdWNext,
      StUpdInfo, StUpdInfoC, StUpdBufGo, StUpdBufCpl, StUpdMemCpl,
      StUpdWr0, StUpdWr1, StUpdElemCk, StUpdPoisC,
      StUpdCpRd, StUpdCpS, StUpdCpD, StUpdCpDSet, StUpdCpGo,
      StUpdCpPC, StUpdCpRC, StUpdCpBC, StUpdCpNext,
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
                         auxlo_ret_q, stv_ret_q, ap_ret_q,
                         pro_ret_q, pay_done_q;
    state_e              sm_ret_q, sh_ret_q, shc_ret_q, pg_ret_q,
                         rsv_ret_q, row_ret_q;

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
    logic [31:0]         hnd_pay_q;    // object {gen,slot} for aux writes
    logic                payf_q;       // retire frees a payload extent
    logic [15:0]         payf_base_q, payf_words_q;
    logic [31:0]         auxlo_val_q, auxlo_mask_q; // SETAUX operand
    logic [31:0]         stv_val_q, stv_mask_q;     // SETSTATE operand

    // §12.3 F5: descriptor-record aperture port request operand
    logic                ap_we_q;
    logic [31:0]         ap_addr_q;
    logic [63:0]         ap_wdata_q;
    logic [7:0]          ap_wstrb_q;
    logic [63:0]         ap_rd_q;      // read data captured at ap_done_i

    // §12.3 F5: descriptor-pool create (Σ pPoolSizes.descriptorCount)
    logic [15:0]         ds_i_q;       // pPoolSizes element cursor
    logic [63:0]         dsum_q;       // running descriptor count

    // §12.3 F5: descriptor-set-layout row build (§16 record format)
    logic [15:0]         dsl_i_q;      // binding cursor
    logic [2:0]          dsl_h_q;      // staged word cursor (4/binding)
    logic                dsl_k_q;      // row word cursor (2/row)
    logic [7:0]          dsl_b_q, dsl_t_q;
    logic [15:0]         dsl_c_q;
    logic [19:0]         dsl_off_q;    // running record offset
    logic [15:0]         dsl_dn_q;     // dynamic descriptor count
    logic [15:0]         dsl_recs_q;   // total record count
    // §12.3 F5-d: FNV-1a content hash over the row words (word-step:
    // h = (h ^ w) * 0x01000193 per emitted word, then the final ndyn
    // word) — stored in the DSL entry state[31:0]; dispatch compares
    // content, not object identity
    logic [31:0]         dsl_hash_q;

    // descriptor-set allocation element chain
    logic [31:0]         lay_lo_q;     // staged layout id low word
    logic [15:0]         ent_j_q;      // generic element cursor
    logic [63:0]         ds_layh_q;    // allocated set's layout {gen,slot}
    logic [15:0]         ds_layb_q, ds_layw_q; // layout payload extent
    logic [15:0]         ds_sbyt_q;    // layout set-table byte extent
    logic [15:0]         ds_ndyn_q;    // layout dynamic count
    logic [24:0]         ds_sbase_q;   // allocated set-table base
    logic [15:0]         ds_z_i_q;     // record-zeroing beat cursor
    logic [15:0]         ds_z_n_q;     // record-zeroing beat count
    apu_objtab_entry_t   ds_pent_q;    // pool entry sampled at alloc
    logic                ds_err_q;     // a set element already failed

    // §12.3 F5: resolve-descriptor-set subroutine (rsv_*) — LOOKUP set,
    // READSLOT pool (epoch), READSLOT layout → rsv_ok/dead/base/nbind
    logic [31:0]         rsv_hnd_q;    // resolved set {gen,slot}
    logic [24:0]         rsv_base_q;   // set_table_base
    logic [63:0]         rsv_layh_q;   // set's layout {gen,slot}
    logic [31:0]         rsv_phnd_q;   // set's pool {gen,slot}
    logic [15:0]         rsv_ep_q;     // set's pool epoch
    logic [15:0]         rsv_layb_q;   // layout payload base
    logic [15:0]         rsv_nbnd_q;   // layout binding count
    logic                rsv_ok_q, rsv_dead_q;

    // §12.3 F5: binding-row scan subroutine — finds the row whose
    // binding number matches in the layout's objpay table
    logic [15:0]         rw_i_q;       // row cursor
    logic [7:0]          rw_bind_q;    // wanted binding number
    logic                rw_ok_q;
    logic [19:0]         rw_off_q;     // record offset (32B units)
    logic [15:0]         rw_cnt_q;     // array count
    logic [7:0]          rw_typ_q;     // descriptor type

    // vkUpdateDescriptorSets staged walk
    logic [15:0]         upd_i_q;      // write index
    logic [3:0]          upd_h_q;      // header/info word cursor
    logic [63:0]         upd_dst_q;    // dstSet id
    logic [63:0]         upd_buf_q;    // buffer id
    logic [63:0]         upd_off_q, upd_rng_q;
    logic [31:0]         upd_dstb_q, upd_arr_q, upd_dcnt_q,
                         upd_type_q;
    logic [31:0]         upd_rec_q;    // current record byte address
    logic                upd_bad_q;    // write-level row/type/bounds fail
    logic                upd_pois_q;   // an element needs the poison bit
    logic                upd_elok_q;   // current element resolves clean
    logic [31:0]         upd_eb_q, upd_esz_q; // element {base,size}
    logic [15:0]         ud_mslot_q;   // buffer's bound memory slot

    // vkUpdateDescriptorSets copies
    logic [15:0]         cp_i_q;       // copy index
    logic [63:0]         cp_src_q, cp_dsid_q; // src/dst set ids
    logic [31:0]         cp_sb_q, cp_sa_q, cp_db_q, cp_da_q, cp_n_q;
    logic [24:0]         cp_sbase_q, cp_dbase_q;
    logic [19:0]         cp_soff_q, cp_doff_q;
    logic [15:0]         cp_scnt_q, cp_dcnt2_q;
    logic [3:0]          cp_b_q;       // 8-byte beat cursor
    logic [31:0]         cp_dhnd_q;    // dst set {gen,slot} for poison
    logic                cp_srcbad_q, cp_dead_q;

    // bind-stream producer: {set handle, ndyn} pairs then dyn offsets
    logic [15:0]         pay_pbnd_q;   // 2×bound-set count
    logic [4:0]          pay_ndyn_q;   // ndyn of the set being emitted

    // 3d-b: vkBind{Buffer,Image}Memory2 staged walk — the resource and
    // memory handles live inside the pBindInfos elements (6 staged
    // words each: {res(2), mem(2), off(2)}); imm[0] = bindInfoCount.
    logic [15:0]         b2_i_q;       // element index
    logic [2:0]          b2_h_q;       // staged word cursor
    logic [63:0]         b2_res_q;     // staged resource handle
    logic [63:0]         b2_mem_q;     // staged memory handle
    logic [63:0]         b2_off_q;     // staged memoryOffset
    logic [31:0]         b2_rid_q;     // resolved resource {gen,slot}
    logic [63:0]         b2_rsz_q;     // resource declared size

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
    logic [APU_VN_EXEC_WORDS*32-1:0] exec_w_q;
    logic [63:0]         pd_id_q;      // last ALLOC'd VkPhysicalDevice id
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
      .exec_w_i(exec_w_q), .exec_n_i(8'(APU_VN_EXEC_WORDS)),
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
    // §12.3 F5-d: FNV-1a 32-bit step over one emitted row word
    function automatic logic [31:0] fnv1a_w(input logic [31:0] h,
                                            input logic [31:0] w);
      return (h ^ w) * 32'h0100_0193;
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
                 ExecEnumPd = 3, ExecEnumExt = 4, ExecMres = 5,
                 ExecEnumQf2 = 6, ExecEnumQGrp = 7, ExecExtBuf = 8,
                 ExecExtZero = 9, ExecSparse = 10, ExecFmt = 11,
                 ExecImgFmt = 12;
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
        // 3d-b stock-stack gates
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_QUEUE_FAMILY_PROPERTIES_2_EXT:
          return ExecEnumQf2;
        APU_VN_TYPE_VK_ENUMERATE_PHYSICAL_DEVICE_GROUPS_EXT:
          return ExecEnumQGrp;
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_EXTERNAL_BUFFER_PROPERTIES_EXT:
          return ExecExtBuf;
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_EXTERNAL_FENCE_PROPERTIES_EXT,
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_PROPERTIES_EXT:
          return ExecExtZero;
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_SPARSE_IMAGE_FORMAT_PROPERTIES_2_EXT:
          return ExecSparse;
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_FORMAT_PROPERTIES_EXT,
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_FORMAT_PROPERTIES_2_EXT:
          return ExecFmt;
        APU_VN_TYPE_VK_GET_PHYSICAL_DEVICE_IMAGE_FORMAT_PROPERTIES_2_EXT:
          return ExecImgFmt;
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
      // {slot, layout} in aux instead.  §12.3 F5: descriptor sets
      // store their records in aperture memory, not ObjPay — only the
      // layout tables still carry an extent.
      return k == 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT) ||
             k == 6'(APU_VN_KIND_VK_PIPELINE_LAYOUT);
    endfunction
    // 5a-ii/§12.3 F5: kinds whose retire needs a pre-LOOKUP (aux
    // carries a ShaderCore slot, a vgpages extent or a payload extent)
    function automatic logic is_auxret_kind(input logic [5:0] k);
      return k == 6'(APU_VN_KIND_VK_SHADER_MODULE) ||
             k == 6'(APU_VN_KIND_VK_PIPELINE) ||
             k == 6'(APU_VN_KIND_VK_DEVICE_MEMORY) ||
             k == 6'(APU_VN_KIND_VK_DESCRIPTOR_POOL) ||
             k == 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT);
    endfunction
    // §12.3 F5: descriptor types that carry pBufferInfo staged words
    // (UNIFORM/STORAGE_BUFFER + their *_DYNAMIC forms)
    function automatic logic is_buf_typ(input logic [7:0] t);
      return t == 8'd6 || t == 8'd7 || t == 8'd8 || t == 8'd9;
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
      ap_req_o = 1'b0;          ap_we_o = ap_we_q;
      ap_addr_o = ap_addr_q;    ap_wdata_o = ap_wdata_q;
      ap_wstrb_o = ap_wstrb_q;
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
        StApReq:   ap_req_o = 1'b1;
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
        auxlo_val_q <= '0; auxlo_mask_q <= '0;
        stv_val_q <= '0; stv_mask_q <= '0;
        ap_we_q <= 1'b0; ap_addr_q <= '0; ap_wdata_q <= '0;
        ap_wstrb_q <= '0; ap_rd_q <= '0;
        ds_i_q <= '0; dsum_q <= '0;
        dsl_i_q <= '0; dsl_h_q <= '0; dsl_k_q <= 1'b0;
        dsl_b_q <= '0; dsl_t_q <= '0; dsl_c_q <= '0;
        dsl_off_q <= '0; dsl_dn_q <= '0; dsl_recs_q <= '0;
        dsl_hash_q <= '0;
        lay_lo_q <= '0;
        ent_j_q <= '0;
        ds_layh_q <= '0; ds_layb_q <= '0; ds_layw_q <= '0;
        ds_sbyt_q <= '0; ds_ndyn_q <= '0; ds_sbase_q <= '0;
        ds_z_i_q <= '0; ds_z_n_q <= '0; ds_pent_q <= '0;
        ds_err_q <= 1'b0;
        rsv_hnd_q <= '0; rsv_base_q <= '0;
        rsv_layh_q <= '0; rsv_phnd_q <= '0; rsv_ep_q <= '0;
        rsv_layb_q <= '0; rsv_nbnd_q <= '0;
        rsv_ok_q <= 1'b0; rsv_dead_q <= 1'b0;
        rsv_ret_q <= StIdle; row_ret_q <= StIdle;
        rw_i_q <= '0; rw_bind_q <= '0; rw_ok_q <= 1'b0;
        rw_off_q <= '0; rw_cnt_q <= '0; rw_typ_q <= '0;
        upd_i_q <= '0; upd_h_q <= '0;
        upd_dst_q <= '0; upd_buf_q <= '0;
        upd_off_q <= '0; upd_rng_q <= '0;
        upd_dstb_q <= '0; upd_arr_q <= '0;
        upd_dcnt_q <= '0; upd_type_q <= '0;
        upd_rec_q <= '0; upd_bad_q <= 1'b0; upd_pois_q <= 1'b0;
        upd_elok_q <= 1'b0; upd_eb_q <= '0; upd_esz_q <= '0;
        ud_mslot_q <= '0;
        cp_i_q <= '0; cp_src_q <= '0; cp_dsid_q <= '0;
        cp_sb_q <= '0; cp_sa_q <= '0; cp_db_q <= '0;
        cp_da_q <= '0; cp_n_q <= '0;
        cp_sbase_q <= '0; cp_dbase_q <= '0;
        cp_soff_q <= '0; cp_doff_q <= '0;
        cp_scnt_q <= '0; cp_dcnt2_q <= '0; cp_b_q <= '0;
        cp_dhnd_q <= '0;
        cp_srcbad_q <= 1'b0; cp_dead_q <= 1'b0;
        pay_send_q <= '0; pay_send_n_q <= '0; pay_word_q <= '0;
        pay_nset_q <= '0; pay_bind_q <= 1'b0;
        pay_pbnd_q <= '0; pay_ndyn_q <= '0;
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
        blob_id_q <= '0; pd_id_q <= '0;
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
            for (int i = 0; i < APU_VN_EXEC_WORDS; i++)
              exec_w_q[32*i +: 32] <= i < APU_VN_PROFILE_WORDS
                                      ? APU_VN_PROFILE[i] : 32'h0;
            state_q <= StDec;
          end

          StDec: state_q <= StDecWait;
          StDecWait: if (dec_done) begin
            op_q <= dec_op;
            if (dec_op.fault == APU_VN_FAULT_FLAGS &&
                dec_op.cmd_type ==
                APU_VN_TYPE_VK_CREATE_DEVICE_EXT) begin
              // 3d-b: a feature bit set outside the profile mask is an
              // unimplemented-feature request, not a malformed command —
              // answer VK_ERROR_FEATURE_NOT_PRESENT with a real reply
              // (pDevice = NULL handle) instead of faulting the ring
              result_q <= APU_VK_ERROR_FEATURE_NOT_PRESENT;
              state_q  <= StRep;
            end else if (dec_op.fault != APU_VN_FAULT_NONE) begin
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
                          id: APU_VN_ID_TAG | op_q.q[res_i_q[2:0]],
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
                // §12.3 F5: vkUpdateDescriptorSets walks the staged
                // writes, then the staged copies
                if (op_q.cmd_type ==
                    APU_VN_TYPE_VK_UPDATE_DESCRIPTOR_SETS_EXT &&
                    op_q.imm[0] != 32'h0) begin
                  upd_i_q   <= '0;
                  upd_h_q   <= '0;
                  stg_i_q   <= '0;
                  stg_ret_q <= StUpdHdrC;
                  state_q   <= StStgRd;
                end else if (op_q.cmd_type ==
                             APU_VN_TYPE_VK_UPDATE_DESCRIPTOR_SETS_EXT &&
                             op_q.imm[1] != 32'h0) begin
                  cp_i_q    <= '0;
                  upd_h_q   <= '0;
                  stg_i_q   <= '0;
                  stg_ret_q <= StUpdCpRd;
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
                    // RU32 count + REXBUF elements from the generated
                    // [device_extensions] payload (one VkExtension-
                    // Properties each: u64 name-size + 64 name words
                    // + spec version); the element count mirrors the
                    // client's capacity word (imm[0]) like EnumPd
                    exec_w_q[0*32 +: 32] <= 32'(APU_VN_DEV_EXT_COUNT);
                    exec_w_q[1*32 +: 32] <= op_q.imm[0] != 32'h0
                        ? 32'(APU_VN_DEV_EXT_COUNT) : 32'h0;
                    if (APU_VN_EXT_PROPS_WORDS != 0)
                      exec_w_q[2*32 +: $bits(APU_VN_EXT_PROPS)]
                          <= APU_VN_EXT_PROPS;
                    state_q     <= StRep;
                  end
                  ExecEnumQf2: begin
                    // one queue family: RU32 count + REXBUF element
                    // {sType, u64 pNext, VkQueueFamilyProperties}
                    exec_w_q[0*32 +: 32] <= 32'd1;
                    exec_w_q[1*32 +: 32] <= op_q.imm[0] != 32'h0
                        ? 32'd1 : 32'h0;
                    exec_w_q[2*32 +: $bits(APU_VN_QF2_ELT)]
                        <= APU_VN_QF2_ELT;
                    state_q     <= StRep;
                  end
                  ExecEnumQGrp: begin
                    // one group holding the registered physical device:
                    // RU32 count + REXBUF element
                    exec_w_q[0*32 +: 32] <= 32'd1;
                    exec_w_q[1*32 +: 32] <= op_q.imm[0] != 32'h0
                        ? 32'd1 : 32'h0;
                    exec_w_q[2*32 +: $bits(APU_VN_PDGRP_ELT)]
                        <= APU_VN_PDGRP_ELT;
                    exec_w_q[APU_VN_PDGRP_PD_LO*32 +: 32]
                        <= pd_id_q[31:0];
                    exec_w_q[APU_VN_PDGRP_PD_HI*32 +: 32]
                        <= pd_id_q[63:32];
                    state_q     <= StRep;
                  end
                  ExecExtBuf: begin
                    // OPAQUE_FD (0x1) buffers are export+import capable
                    // through the aperture blob; anything else -> zero
                    if (op_q.immv[2] && op_q.imm[2] == 32'h1) begin
                      exec_w_q[0*32 +: 32] <= 32'd3;
                      exec_w_q[1*32 +: 32] <= 32'd1;
                      exec_w_q[2*32 +: 32] <= 32'd1;
                    end else begin
                      exec_w_q[0*32 +: 32] <= '0;
                      exec_w_q[1*32 +: 32] <= '0;
                      exec_w_q[2*32 +: 32] <= '0;
                    end
                    state_q     <= StRep;
                  end
                  ExecExtZero: begin
                    // no external sync: three zero property words
                    exec_w_q[0*32 +: 32] <= '0;
                    exec_w_q[1*32 +: 32] <= '0;
                    exec_w_q[2*32 +: 32] <= '0;
                    state_q     <= StRep;
                  end
                  ExecSparse: begin
                    // sparse residency unimplemented: zero elements
                    exec_w_q[0*32 +: 32] <= '0;
                    exec_w_q[1*32 +: 32] <= '0;
                    state_q     <= StRep;
                  end
                  ExecFmt: begin
                    // per-format {linear, optimal, buffer} from the
                    // generated APU_VN_FMT3 table; format = imm[0]
                    exec_w_q[0*32 +: 32] <=
                        APU_VN_FMT3[3*int'(op_q.imm[0][7:0]) + 0];
                    exec_w_q[1*32 +: 32] <=
                        APU_VN_FMT3[3*int'(op_q.imm[0][7:0]) + 1];
                    exec_w_q[2*32 +: 32] <=
                        APU_VN_FMT3[3*int'(op_q.imm[0][7:0]) + 2];
                    state_q     <= StRep;
                  end
                  ExecImgFmt: begin
                    // chained output REXEC bodies consume exec words in
                    // reverse chain order (vnrep nests reply bodies):
                    // VkExternalImageFormatProperties ->
                    //   VkExternalMemoryProperties {3,1,1},
                    // VkSamplerYcbcrConversionImageFormatProperties ->
                    //   combinedFormatSamplerDescriptorCount = 0;
                    // then the main VkImageFormatProperties body.
                    automatic int unsigned wp = 0;
                    for (int i = 7; i >= 0; i--) begin
                      if (i < int'(op_q.chain_n)) begin
                        automatic logic [31:0] st = (32'(op_q.chain[i])
                            < APU_VN_CHAIN_WORDS)
                            ? APU_VN_CHAIN[op_q.chain[i]
                                          [APU_VN_CHAIN_AW-1:0]][31:0]
                            : 32'h0;
                        if (st == APU_VN_STYPE_VK_EXTERNAL_IMAGE_FORMAT_PROPERTIES) begin
                          exec_w_q[wp*32 + 0*32 +: 32] <= 32'd3;
                          exec_w_q[wp*32 + 1*32 +: 32] <= 32'd1;
                          exec_w_q[wp*32 + 2*32 +: 32] <= 32'd1;
                          wp += 3;
                        end else if (st == APU_VN_STYPE_VK_SAMPLER_YCBCR_CONVERSION_IMAGE_FORMAT_PROPERTIES) begin
                          exec_w_q[wp*32 +: 32] <= '0;
                          wp += 1;
                        end
                      end
                    end
                    exec_w_q[wp*32 +: $bits(APU_VN_IMGPROPS)]
                        <= APU_VN_IMGPROPS;
                    // refuse formats outside the profile table, and any
                    // {type, tiling, usage, flags} we do not implement:
                    // type must be 2D, tiling OPTIMAL or LINEAR, no
                    // create flags, usage within the format's
                    // feature-derived mask (APU_VN_FMT_USAGE).
                    if (APU_VN_FMT3[3*int'(op_q.imm[0][7:0]) + 1] ==
                        32'h0 ||
                        op_q.imm[1] != 32'd1 ||
                        op_q.imm[2] > 32'd1 ||
                        op_q.imm[4] != 32'h0 ||
                        (op_q.imm[3] &
                         ~APU_VN_FMT_USAGE[int'(op_q.imm[0][7:0])]) !=
                        32'h0)
                      result_q <= APU_VK_ERROR_FORMAT_NOT_SUPPORTED;
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
                      6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT)) begin
                    // §12.3 F5: bindings become two-word {binding,type,
                    // count}/{off,dyn,dynbase} rows behind a header
                    // word; <= APU_DESC_BND bindings is a device limit
                    if (op_q.imm[1] > 32'(APU_DESC_BND)) begin
                      result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
                      state_q  <= StRep;
                    end else begin
                      prepend_n_q <= '0;
                      op_words_q  <= 16'd1 + 2*16'(op_q.imm[1]);
                      opr_q    <= '{op: APU_OBJPAY_OP_ALLOC,
                                    words: 32'd1 + 2*op_q.imm[1],
                                    default: '0};
                      op_ret_q <= StPayAlcCpl;
                      state_q  <= StOpReq;
                    end
                  end else if (act_q.obj_kind ==
                               6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)) begin
                    // §12.3 F5: Σ pPoolSizes.descriptorCount ×
                    // APU_DESC_BYTES of aperture record backing,
                    // allocated through vgpages after the staged
                    // {type,count} pairs are summed
                    ds_i_q  <= '0;
                    dsum_q  <= '0;
                    state_q <= StDPoolSum;
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
                    // 3d-b: pNext policy before any allocation —
                    //   VkExportMemoryAllocateInfo     : handleTypes must
                    //     subset VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD
                    //   VkMemoryAllocateFlagsInfo    : flags must be 0
                    //   VkMemoryDedicatedAllocateInfo: hint, ignored
                    //   VkImportMemoryFdInfoKHR /
                    //   VkImportMemoryResourceInfoMESA: refused
                    automatic logic ext_bad = 1'b0;
                    automatic logic feat_bad = 1'b0;
                    for (int i = 0; i < 8; i++) begin
                      if (i < int'(op_q.chain_n)) begin
                        automatic logic [31:0] st = (32'(op_q.chain[i])
                            < APU_VN_CHAIN_WORDS)
                            ? APU_VN_CHAIN[op_q.chain[i]
                                          [APU_VN_CHAIN_AW-1:0]][31:0]
                            : 32'h0;
                        if (st ==
                            APU_VN_STYPE_VK_IMPORT_MEMORY_RESOURCE_INFO_MESA ||
                            st ==
                            APU_VN_STYPE_VK_IMPORT_MEMORY_FD_INFO_KHR)
                          ext_bad = 1'b1;
                      end
                    end
                    if (op_q.immv[
                        APU_VN_CVAL_VK_EXPORT_MEMORY_ALLOCATE_INFO_HANDLE_TYPES] &&
                        (op_q.imm[
                          APU_VN_CVAL_VK_EXPORT_MEMORY_ALLOCATE_INFO_HANDLE_TYPES]
                         & ~32'h1) != 32'h0)
                      ext_bad = 1'b1;
                    if (op_q.immv[
                        APU_VN_CVAL_VK_MEMORY_ALLOCATE_FLAGS_INFO_FLAGS] &&
                        op_q.imm[
                          APU_VN_CVAL_VK_MEMORY_ALLOCATE_FLAGS_INFO_FLAGS]
                        != 32'h0)
                      feat_bad = 1'b1;
                    if (ext_bad) begin
                      result_q <= APU_VK_ERROR_INVALID_EXTERNAL_HANDLE;
                      state_q  <= StRep;
                    end else if (feat_bad) begin
                      result_q <= APU_VK_ERROR_FEATURE_NOT_PRESENT;
                      state_q  <= StRep;
                    end else if (op_q.imm[2] == 32'd1) begin
                      // §12.3 C: type-1 (heap-1, host-visible)
                      // memory is LAZY — no aperture backing at
                      // vkAllocateMemory; MAP_BLOB establishes it at
                      // the kernel's window offset (ALLOC_AT) and
                      // UNMAP_BLOB returns it to the unbacked
                      // sentinel.  aux[63:32] = APU_MEM_UNBACKED
                      pg_ok_q  <= 1'b1;
                      pg_res_q <= APU_MEM_UNBACKED;
                      state_q  <= StAllocGo;
                    end else begin
                      // §7b/5a-ii: type-0 (heap-0, device-local) is
                      // eager — aperture pages from the private arena
                      // first; the object is created only if pages
                      // exist.  Guest window placement happens only
                      // at MAP_BLOB, so an unmapped VkDeviceMemory can
                      // never collide with the kernel's shm drm_mm
                      // choices
                      automatic int ds = data_slot(op_q);
                      pg_op_q    <= APU_VGPAGES_OP_ALLOC_PRIV;
                      pg_base_q  <= '0;
                      pg_bytes_q <= ds < 0 ? 32'h0 : 32'(op_q.q[ds]);
                      pg_ret_q   <= StAllocGo;
                      state_q    <= StPgReq;
                    end
                  end else begin
                    state_q <= StAllocGo;
                  end
                end else if (act_q.obj_kind ==
                             6'(APU_VN_KIND_VK_DESCRIPTOR_SET)) begin
                  // §12.3 F5: vkAllocateDescriptorSets elements need
                  // the staged layout ids — descriptor-set chain;
                  // the first failure latches ds_err_q so the
                  // remaining elements echo VK_NULL_HANDLE without
                  // further pool consumption
                  ds_err_q    <= 1'b0;
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
                               id: APU_VN_ID_TAG | op_q.q[
                                   role_slot(op_q, APU_VN_ROLE_RETIRE)],
                               kind: act_q.obj_kind, default: '0};
                  ot_ret_q <= StRetPre;
                  state_q  <= StOtReq;
                end else begin
                  otr_q    <= '{op: APU_OBJTAB_OP_RETIRE,
                               id: APU_VN_ID_TAG | op_q.q[
                                   role_slot(op_q, APU_VN_ROLE_RETIRE)],
                               kind: act_q.obj_kind, default: '0};
                  ot_ret_q <= StRetCpl;
                  state_q  <= StOtReq;
                end
              end
              APU_VN_ACT_BIND: begin
                if (op_q.cmd_type ==
                    APU_VN_TYPE_VK_BIND_BUFFER_MEMORY_2_EXT ||
                    op_q.cmd_type ==
                    APU_VN_TYPE_VK_BIND_IMAGE_MEMORY_2_EXT) begin
                  // 3d-b: the *Memory2 array elements stage
                  // {res, mem, off} triples — walk them
                  if (op_q.imm[0][15:0] == 16'h0) begin
                    state_q <= StRep;
                  end else begin
                    b2_i_q    <= '0;
                    b2_h_q    <= '0;
                    stg_i_q   <= '0;
                    stg_ret_q <= StBind2Rd;
                    state_q   <= StStgRd;
                  end
                end else begin
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
                if (op_q.cmd_type ==
                    APU_VN_TYPE_VK_RESET_DESCRIPTOR_POOL_EXT) begin
                  // §12.3 F5: bump the pool epoch so sets minted from
                  // it become dead at dispatch; bump/counters clear
                  automatic int ps = lu_slot(op_q, 1);
                  if (ps < 0) begin
                    result_q <= APU_VK_ERROR_UNKNOWN;
                    state_q  <= StRep;
                  end else begin
                    otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                                 id: {32'h0, hnd_q[ps]},
                                 kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_POOL),
                                 default: '0};
                    ot_ret_q <= StDPoolRs;
                    state_q  <= StOtReq;
                  end
                end else begin
                  are_i_q <= '0;
                  state_q <= StPoolLoop;
                end
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
            // blob u64s are client object ids: tag them into the
            // client-id namespace so ObjTab resolves them through the
            // directory and never the {gen,slot} handle fast path
            blob_id_q[63:32] <= csw_q | APU_VN_ID_TAG[63:32];
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
            end else if ((act_q.obj_kind ==
                          6'(APU_VN_KIND_VK_DEVICE_MEMORY) ||
                          act_q.obj_kind ==
                          6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)) &&
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
                         id: APU_VN_ID_TAG | op_q.q[ns],
                         kind: act_q.obj_kind,
                         parent_id: ps < 0 ? 64'h0
                                           : {32'h0, hnd_q[ps]},
                         // §7b/5a-ii: entry.size feeds descriptor
                         // dispatch (buffer size) and the memory FREE;
                         // §12.3 F5: for pools it is the record-store
                         // byte capacity Σcount×APU_DESC_BYTES
                         size: act_q.obj_kind ==
                              6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)
                              ? 64'(dsum_q << 5)
                              : ds < 0 ? 64'h0 : op_q.q[ds],
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
              end else if ((act_q.obj_kind ==
                            6'(APU_VN_KIND_VK_DEVICE_MEMORY) &&
                            pg_res_q != APU_MEM_UNBACKED) ||
                           act_q.obj_kind ==
                           6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)) begin
                // release the held aperture pages — §12.3 C: a lazy
                // type-1 allocation holds none
                pg_op_q  <= APU_VGPAGES_OP_FREE;
                pg_ret_q <= StRep;
                state_q  <= StPgReq;
              end else begin
                state_q <= StRep;
              end
            end else if (act_q.obj_kind ==
                         6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)) begin
              // §12.3 F5: aux[31:0] = record-store aperture byte base,
              // aux[63:32] = {nsets[19:0], bump[11:0]},
              // state = {maxSets[15:0], epoch[15:0]}
              hnd_pay_q   <= ot_cpl_i.handle;
              auxlo_val_q <= pg_res_q;
              auxlo_mask_q <= 32'hFFFF_FFFF;
              auxlo_ret_q <= StDPoolAuxH;
              state_q     <= StAuxLo;
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
              // §7b: copy staging -> ObjPay, then SETAUXHI
              // {base,words}; §12.3 F5: the descriptor-set-layout's
              // row table is already written — auxhi, then the
              // {ndyn,set_bytes} aux half
              hnd_pay_q   <= ot_cpl_i.handle;
              auxhi_val_q <= {op_base_q, op_words_q};
              if (act_q.obj_kind ==
                  6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT)) begin
                auxhi_ret_q <= StDslAuxL;
                state_q     <= StAuxSet;
              end else begin
                pay_i_q     <= '0;
                pay_done_q  <= StAuxSet;
                auxhi_ret_q <= StRep;
                state_q     <= StPayLoop;
              end
            end else begin
              state_q <= StRep;
            end
          end
          StAllocAux: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK)
              result_q <= APU_VK_ERROR_UNKNOWN;
            else if (op_q.cmd_type == APU_VN_TYPE_VK_CREATE_FENCE_EXT) begin
              falloc_q[are_i_q[$clog2(Fences)-1:0]] <= 1'b1;
              // a fresh fence object owns a clean executor slot: drop
              // signaled/lost state a destroyed fence left behind
              // (fence bits survive the object's lifetime otherwise)
              ex_fence_clr_o[are_i_q[$clog2(Fences)-1:0]] <= 1'b1;
            end
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
              // remember the client id for
              // vkEnumeratePhysicalDeviceGroups' physicalDevices[] —
              // blob_id_q is tagged, strip APU_VN_ID_TAG
              pd_id_q  <= blob_id_q & ~APU_VN_ID_TAG;
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
                  6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)) begin
                // §12.3 F5: pool's record store lives at aux[31:0]
                // (aux[63:32] is {nsets,bump}); §12.3 F5-d: retire
                // the pool's live descriptor sets first — they own
                // nothing outside the pool arena and must not hold
                // the table entry past the parent's death
                pg_base_q  <= ot_cpl_i.entry.aux[31:0];
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
              end else if (act_q.obj_kind ==
                           6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)) begin
                // §12.3 F5-d: kill live sets first so the pool's own
                // RETIRE cannot report BUSY_CHILDREN
                otr_q    <= '{op: APU_OBJTAB_OP_RETIRE_KIDS,
                             id: {48'h0, ot_cpl_i.handle[15:0]},
                             default: '0};
                ot_ret_q <= StRetKids;
                state_q  <= StOtReq;
              end else begin
                otr_q    <= '{op: APU_OBJTAB_OP_RETIRE,
                             id: APU_VN_ID_TAG | op_q.q[
                                 role_slot(op_q, APU_VN_ROLE_RETIRE)],
                             kind: act_q.obj_kind, default: '0};
                ot_ret_q <= StRetCpl;
                state_q  <= StOtReq;
              end
            end
          end
          // §12.3 F5-d: descriptor-pool retire tail — sets are dead,
          // the parent's refcnt was zeroed wholesale; now retire the
          // pool itself
          StRetKids: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              otr_q    <= '{op: APU_OBJTAB_OP_RETIRE,
                           id: APU_VN_ID_TAG | op_q.q[
                               role_slot(op_q, APU_VN_ROLE_RETIRE)],
                           kind: act_q.obj_kind, default: '0};
              ot_ret_q <= StRetCpl;
              state_q  <= StOtReq;
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
              end else if ((act_q.obj_kind ==
                            6'(APU_VN_KIND_VK_DEVICE_MEMORY) &&
                            pg_base_q != APU_MEM_UNBACKED) ||
                           act_q.obj_kind ==
                           6'(APU_VN_KIND_VK_DESCRIPTOR_POOL)) begin
                // §7b/5a-ii/§12.3 F5: vkFreeMemory/vkDestroyDescriptor-
                // Pool returns its aperture pages; §12.3 C: an
                // unbacked memory frees nothing
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

          // ---- 3d-b: vkBind{Buffer,Image}Memory2 staged elements ---------
          // Each pBindInfos element staged {resource(2w), memory(2w),
          // memoryOffset(2w)} — array-element handles cannot ride the
          // fixed q slots, so the front resolves each itself.
          StBind2Rd: begin
            case (b2_h_q)
              3'd0:    b2_res_q[31:0]  <= stg_word_q;
              3'd1:    b2_res_q[63:32] <= stg_word_q;
              3'd2:    b2_mem_q[31:0]  <= stg_word_q;
              3'd3:    b2_mem_q[63:32] <= stg_word_q;
              3'd4:    b2_off_q[31:0]  <= stg_word_q;
              default: b2_off_q[63:32] <= stg_word_q;
            endcase
            stg_i_q <= stg_i_q + 1'b1;
            b2_h_q  <= b2_h_q + 3'd1;
            if (b2_h_q == 3'd5) begin
              otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                           id: APU_VN_ID_TAG | b2_res_q,
                           kind: op_q.cmd_type ==
                                 APU_VN_TYPE_VK_BIND_BUFFER_MEMORY_2_EXT
                                 ? 6'(APU_VN_KIND_VK_BUFFER)
                                 : 6'(APU_VN_KIND_VK_IMAGE),
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StBind2ResC;
              state_q  <= StOtReq;
            end else begin
              stg_ret_q <= StBind2Rd;
              state_q   <= StStgRd;
            end
          end
          StBind2ResC: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              b2_rid_q <= ot_cpl_i.handle;
              b2_rsz_q <= ot_cpl_i.entry.size;
              otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                           id: APU_VN_ID_TAG | b2_mem_q,
                           kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StBind2MemC;
              state_q  <= StOtReq;
            end
          end
          StBind2MemC: begin
            // same subtractive extent check as the single-bind path
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                b2_off_q > ot_cpl_i.entry.size ||
                b2_rsz_q > ot_cpl_i.entry.size - b2_off_q) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              otr_q <= '{op: APU_OBJTAB_OP_SETBIND,
                         id: {32'h0, b2_rid_q},
                         kind: op_q.cmd_type ==
                               APU_VN_TYPE_VK_BIND_BUFFER_MEMORY_2_EXT
                               ? 6'(APU_VN_KIND_VK_BUFFER)
                               : 6'(APU_VN_KIND_VK_IMAGE),
                         mem_id: {32'h0, ot_cpl_i.handle},
                         offset: b2_off_q,
                         // the resource's declared size is the bound
                         // extent for §7b dispatch
                         size: b2_rsz_q,
                         ctx: ctx_i, default: '0};
              ot_ret_q <= StBind2SetC;
              state_q  <= StOtReq;
            end
          end
          StBind2SetC: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else if (b2_i_q + 16'd1 >= op_q.imm[0][15:0]) begin
              state_q <= StRep;
            end else begin
              b2_i_q    <= b2_i_q + 16'd1;
              b2_h_q    <= '0;
              stg_ret_q <= StBind2Rd;
              state_q   <= StStgRd;
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
                // §7b/§12.3 F5: payload-arena word counts per record —
                // BindDS emits {set handle, ndyn} pairs (2×sets)
                // ahead of the verbatim dynamic-offset words
                pay_bind_q <= op_q.cmd_type ==
                              APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT;
                pay_nset_q <= 16'(op_q.imm[2]);
                pay_pbnd_q <=
                    16'(op_q.imm[2] > 32'd4 - op_q.imm[1]
                        ? 32'd4 - op_q.imm[1] : op_q.imm[2]) << 1;
                pay_send_n_q <=
                    op_q.cmd_type ==
                    APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT
                    ? 16'(2*(op_q.imm[2] > 32'd4 - op_q.imm[1]
                             ? 32'd4 - op_q.imm[1] : op_q.imm[2])
                          + (op_q.imm[3] > 32'd64
                             ? 32'd64 : op_q.imm[3]))
                    : op_q.cmd_type ==
                      APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT ||
                      // §12.3 C/5a: Xfer operand payloads (copy
                      // regions, fill/update headers, update data)
                      // stream verbatim like push constants
                      op_q.cmd_type ==
                      APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT ||
                      op_q.cmd_type ==
                      APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT ||
                      op_q.cmd_type ==
                      APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT
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
              end else if (act_q.obj_kind ==
                           6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT)) begin
                // §12.3 F5: header {pad,nbind}, then binding rows are
                // built from the staged {bind,type,cnt,flags} words
                opr_q    <= '{op: APU_OBJPAY_OP_WRITE,
                              addr: {16'h0, 16'(op_cpl_i.base)},
                              wdata: {16'h0, 16'(op_q.imm[1])},
                              default: '0};
                op_ret_q <= StDslHdrC;
                state_q  <= StOpReq;
              end else begin
                // PL: ObjTab.ALLOC next, copy in StAllocCpl
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

          // ---- §12.3 F5: generic aux-lo / state writers ----------------
          // SETAUX (aux[31:0]) on hnd_pay_q, then auxlo_ret_q
          StAuxLo: begin
            otr_q    <= '{op: APU_OBJTAB_OP_SETAUX,
                         id: {32'h0, hnd_pay_q},
                         kind: act_q.obj_kind,
                         mask: auxlo_mask_q, value: auxlo_val_q,
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StAuxLoCpl;
            state_q  <= StOtReq;
          end
          StAuxLoCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else begin
              state_q <= auxlo_ret_q;
            end
          end
          // SETSTATE on hnd_pay_q, then stv_ret_q
          StStSet: begin
            otr_q    <= '{op: APU_OBJTAB_OP_SETSTATE,
                         id: {32'h0, hnd_pay_q},
                         kind: act_q.obj_kind,
                         mask: stv_mask_q, value: stv_val_q,
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StStSetCpl;
            state_q  <= StOtReq;
          end
          StStSetCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else begin
              state_q <= stv_ret_q;
            end
          end

          // ---- §12.3 F5: descriptor-record aperture port -----------------
          // ap_*_q holds the request; one accepted request = one done
          StApReq: if (ap_ready_i) state_q <= StApCpl;
          StApCpl: if (ap_done_i) begin
            ap_rd_q <= ap_rdata_i;
            state_q <= ap_ret_q;
          end

          // ---- §12.3 F5: vkCreateDescriptorPool ----------------------------
          // Σ pPoolSizes[i].descriptorCount (staged {type,count} pairs,
          // count rides the odd word) -> dsum_q records -> vgpages
          StDPoolSum: begin
            if (32'(ds_i_q) >= op_q.imm[2]) begin
              // sum complete: hand the byte count to vgpages; the
              // record store is device-internal so it comes from the
              // private arena — the guest kernel's shm drm_mm can
              // never collide with it at MAP_BLOB
              pg_op_q    <= APU_VGPAGES_OP_ALLOC_PRIV;
              pg_base_q  <= '0;
              pg_bytes_q <= dsum_q > 64'h7FF_FFFF
                            ? 32'hFFFF_FFFF : 32'(dsum_q << 5);
              pg_ret_q   <= StDPoolPgC;
              state_q    <= StPgReq;
            end else begin
              stg_i_q   <= StgBits'({16'h0, ds_i_q} << 1) + 10'd1;
              stg_ret_q <= StDPoolSumC;
              state_q   <= StStgRd;
            end
          end
          StDPoolSumC: begin
            dsum_q  <= dsum_q + 64'(stg_word_q);
            ds_i_q  <= ds_i_q + 16'd1;
            state_q <= StDPoolSum;
          end
          // vgpages completion rides pg_ok_q/pg_res_q; StAllocGo's
          // pool branch refuses on !pg_ok_q
          StDPoolPgC: state_q <= StAllocGo;
          // after the object exists: aux[31:0]=page base was written
          // via StAuxLo; auxhi={nsets,bump}=0, then
          // state={maxSets,epoch=0}
          StDPoolAuxH: begin
            auxhi_val_q <= '0;
            auxhi_ret_q <= StDPoolAuxS;
            state_q     <= StAuxSet;
          end
          StDPoolAuxS: begin
            stv_val_q  <= {16'(op_q.imm[1]), 16'h0};
            stv_mask_q <= 32'hFFFF_FFFF;
            stv_ret_q  <= StRep;
            state_q    <= StStSet;
          end

          // ---- §12.3 F5: vkResetDescriptorPool ----------------------------
          // RETIRE_KIDS kills every set minted from the pool
          // (per-frame-reset leak fix; epoch++ stays as defence in
          // depth), then {nsets,bump} -> 0 reclaims the record store
          StDPoolRs: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              ds_pent_q <= ot_cpl_i.entry;
              otr_q    <= '{op: APU_OBJTAB_OP_RETIRE_KIDS,
                           id: {48'h0, ot_cpl_i.handle[15:0]},
                           default: '0};
              ot_ret_q <= StDPoolRsK;
              state_q  <= StOtReq;
            end
          end
          // children dead -> bump the epoch (defence in depth) then
          // {nsets,bump} -> 0 via the auxhi write
          StDPoolRsK: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else begin
              automatic int ps = lu_slot(op_q, 1);
              hnd_pay_q   <= hnd_q[ps];
              stv_val_q   <= {ds_pent_q.state[31:16],
                              ds_pent_q.state[15:0] + 16'd1};
              stv_mask_q  <= 32'hFFFF_FFFF;
              stv_ret_q   <= StDPoolRsHi;
              state_q     <= StStSet;
            end
          end
          StDPoolRsHi: begin
            auxhi_val_q <= '0;
            auxhi_ret_q <= StRep;
            state_q     <= StAuxSet;
          end

          // ---- §12.3 F5: vkCreateDescriptorSetLayout row build -----------
          // StPayAlcCpl already wrote {pad,nbind}; walk the staged
          // {binding,type,count,stageFlags} quads and emit two-word
          // apu_sh_bindrow_t-compatible rows at op_base+1+2j
          StDslHdrC: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
              state_q  <= StRep;
            end else if (op_q.imm[1] == 32'h0) begin
              state_q <= StAllocGo;
            end else begin
              dsl_i_q    <= '0;
              dsl_h_q    <= '0;
              dsl_off_q  <= '0;
              dsl_dn_q   <= '0;
              dsl_recs_q <= '0;
              dsl_hash_q <= 32'h811C_9DC5;   // FNV-1a offset basis
              stg_i_q    <= '0;
              stg_ret_q  <= StDslRd;
              state_q    <= StStgRd;
            end
          end
          StDslRd: begin
            case (dsl_h_q)
              3'd0: dsl_b_q <= stg_word_q[7:0];
              3'd1: dsl_t_q <= stg_word_q[7:0];
              3'd2: dsl_c_q <= stg_word_q[15:0];
              default: ;                    // stageFlags: unused
            endcase
            if (dsl_h_q != 3'd3) begin
              dsl_h_q   <= dsl_h_q + 3'd1;
              stg_i_q   <= stg_i_q + 1'b1;
              stg_ret_q <= StDslRd;
              state_q   <= StStgRd;
            end else begin
              // the whole quad is captured: refuse on the device
              // limits (>APU_DESC_DYN dynamics, >2047 records), else
              // emit the two row words
              automatic logic bad =
                  ((dsl_t_q == 8'd8 || dsl_t_q == 8'd9) &&
                   20'(dsl_dn_q) + 20'(dsl_c_q)
                          > 20'(APU_DESC_DYN)) ||
                  (20'(dsl_recs_q) + 20'(dsl_c_q) > 20'd2047);
              if (bad) begin
                opr_q    <= '{op: APU_OBJPAY_OP_FREE,
                             addr: {16'h0, op_base_q},
                             words: {16'h0, op_words_q},
                             default: '0};
                op_ret_q <= StRep;
                result_q <= APU_VK_ERROR_OUT_OF_DEVICE_MEMORY;
                state_q  <= StOpReq;
              end else begin
                dsl_k_q <= 1'b0;
                state_q <= StDslWr;
              end
            end
          end
          StDslWr: begin
            opr_q    <= '{op: APU_OBJPAY_OP_WRITE,
                         addr: {16'h0, op_base_q} + 32'd1 +
                               (32'(dsl_i_q) << 1) + 32'(dsl_k_q),
                         wdata: dsl_k_q == 1'b0
                                ? {dsl_b_q, dsl_t_q, dsl_c_q}
                                : {dsl_off_q,
                                   dsl_t_q == 8'd8 || dsl_t_q == 8'd9,
                                   7'b0, dsl_dn_q[3:0]},
                         default: '0};
            op_ret_q <= StDslWrC;
            state_q  <= StOpReq;
          end
          StDslWrC: begin
            automatic logic dyn = dsl_t_q == 8'd8 || dsl_t_q == 8'd9;
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              result_q <= APU_VK_ERROR_UNKNOWN;
              state_q  <= StRep;
            end else if (dsl_k_q == 1'b0) begin
              dsl_k_q    <= 1'b1;
              dsl_hash_q <= fnv1a_w(dsl_hash_q,
                                    {dsl_b_q, dsl_t_q, dsl_c_q});
              state_q <= StDslWr;
            end else begin
              dsl_hash_q <= fnv1a_w(
                  dsl_hash_q,
                  {dsl_off_q, dsl_t_q == 8'd8 || dsl_t_q == 8'd9,
                   7'b0, dsl_dn_q[3:0]});
              dsl_off_q  <= dsl_off_q + 20'(dsl_c_q);
              dsl_recs_q <= dsl_recs_q + dsl_c_q;
              if (dyn) dsl_dn_q <= dsl_dn_q + dsl_c_q;
              dsl_i_q <= dsl_i_q + 16'd1;
              dsl_h_q <= '0;
              if (dsl_i_q + 16'd1 >= 16'(op_q.imm[1])) begin
                state_q <= StAllocGo;
              end else begin
                stg_i_q   <= stg_i_q + 1'b1;   // skip stageFlags
                stg_ret_q <= StDslRd;
                state_q   <= StStgRd;
              end
            end
          end
          // DSL aux[31:0] = {ndyn[15:0], set_bytes[15:0]} then reply
          StDslAuxL: begin
            auxlo_val_q  <= {dsl_dn_q, 16'(dsl_off_q << 5)};
            auxlo_mask_q <= 32'hFFFF_FFFF;
            auxlo_ret_q  <= StDslHash;
            state_q      <= StAuxLo;
          end
          // §12.3 F5-d: DSL state[31:0] = FNV-1a content hash over the
          // emitted row words plus the final ndyn count — dispatch
          // compatibility is by content, not object identity
          StDslHash: begin
            stv_val_q  <= fnv1a_w(dsl_hash_q, {16'h0, dsl_dn_q});
            stv_mask_q <= 32'hFFFF_FFFF;
            stv_ret_q  <= StRep;
            state_q    <= StStSet;
          end

          // ---- §12.3 F5: vkAllocateDescriptorSets element chain ----------
          // staged layout id for set blob_i_q -> LOOKUP -> READSLOT pool
          // (capacity + epoch) -> ALLOC -> aux -> zero records -> bump
          StDSetLayLo: begin
            if (ds_err_q) begin
              // an earlier element failed: null the rest without
              // further pool consumption
              rep_null_mask_q[blob_i_q] <= 1'b1;
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end else begin
              stg_i_q   <= StgBits'({2'b0, blob_i_q} << 1);
              stg_ret_q <= StDSetLayHi;
              state_q   <= StStgRd;
            end
          end
          StDSetLayHi: begin
            lay_lo_q  <= stg_word_q;
            stg_i_q   <= stg_i_q + 1'b1;
            stg_ret_q <= StDSetLayId;
            state_q   <= StStgRd;
          end
          StDSetLayId: begin
            otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                         id: APU_VN_ID_TAG | {stg_word_q, lay_lo_q},
                         kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT),
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StDSetLayCpl;
            state_q  <= StOtReq;
          end
          StDSetLayCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              // dead/foreign layout id: the element fails
              result_q <= APU_VK_ERROR_UNKNOWN;
              ds_err_q <= 1'b1;
              rep_null_mask_q[blob_i_q] <= 1'b1;
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end else begin
              ds_layh_q <= ot_cpl_i.handle;
              ds_ndyn_q <= ot_cpl_i.entry.aux[31:16];
              ds_sbyt_q <= ot_cpl_i.entry.aux[15:0];
              // pool entry for the capacity / maxSets checks
              otr_q    <= '{op: APU_OBJTAB_OP_READSLOT,
                           id: {48'h0, hnd_q[lu_slot(op_q, 1)][15:0]},
                           kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_POOL),
                           default: '0};
              ot_ret_q <= StDSetPoolC;
              state_q  <= StOtReq;
            end
          end
          StDSetPoolC: begin
            automatic int ps = lu_slot(op_q, 1);
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.kind !=
                    6'(APU_VN_KIND_VK_DESCRIPTOR_POOL) ||
                ot_cpl_i.entry.gen != hnd_q[ps][31:16] ||
                32'(ot_cpl_i.entry.aux[63:44]) >=
                    ot_cpl_i.entry.state[31:16] ||
                64'(ot_cpl_i.entry.aux[43:32]) * 64'd32 +
                    64'(ds_sbyt_q) > ot_cpl_i.entry.size) begin
              // dead pool, maxSets reached, or the record store is
              // exhausted — Vulkan OUT_OF_POOL_MEMORY; later elements
              // of this call fail the same way
              result_q <= APU_VK_ERROR_OUT_OF_POOL_MEMORY;
              ds_err_q <= 1'b1;
              rep_null_mask_q[blob_i_q] <= 1'b1;
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end else begin
              ds_pent_q  <= ot_cpl_i.entry;
              ds_sbase_q <= 25'(ot_cpl_i.entry.aux[31:0] +
                                 (ot_cpl_i.entry.aux[43:32] << 5));
              state_q    <= StDSetObj;
            end
          end
          StDSetObj: begin
            otr_q    <= '{op: APU_OBJTAB_OP_ALLOC,
                         id: blob_id_q,
                         kind: act_q.obj_kind,
                         // §12.3 F5-d: sets are pool children — the
                         // first LOOKUP arg (device) is pq=0, so the
                         // pool is lu_slot 1; RETIRE_KIDS on the pool
                         // sweeps them at reset/destroy
                         parent_id: {32'h0, hnd_q[lu_slot(op_q, 1)]},
                         // entry.size[31:0] = minting pool {gen,slot}
                         size: {32'h0, hnd_q[lu_slot(op_q, 1)]},
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StDSetOCpl;
            state_q  <= StOtReq;
          end
          StDSetOCpl: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              ds_err_q <= 1'b1;
              rep_null_mask_q[blob_i_q] <= 1'b1;
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end else begin
              // aux[63:32] = layout {gen,slot},
              // aux[31:0]  = {poison=0, ndyn[5:0], set_base[24:0]}
              hnd_pay_q    <= ot_cpl_i.handle;
              auxlo_val_q  <= {1'b0, ds_ndyn_q[5:0], ds_sbase_q};
              auxlo_mask_q <= 32'hFFFF_FFFF;
              auxlo_ret_q  <= StDSetAuxH;
              state_q      <= StAuxLo;
            end
          end
          StDSetAuxH: begin
            auxhi_val_q <= ds_layh_q[31:0];
            auxhi_ret_q <= StDSetEpoch;
            state_q     <= StAuxSet;
          end
          StDSetEpoch: begin
            // state[15:0] = the pool epoch the set was minted under
            stv_val_q  <= {16'h0, ds_pent_q.state[15:0]};
            stv_mask_q <= 32'h0000_FFFF;
            stv_ret_q  <= StDSetZero;
            state_q    <= StStSet;
          end
          // zero the record store: ds_sbyt_q bytes, 8 per beat
          StDSetZero: begin
            ds_z_i_q <= '0;
            ds_z_n_q <= ds_sbyt_q >> 3;
            if (ds_sbyt_q == 16'h0) begin
              state_q <= StDSetBump;
            end else begin
              ap_we_q    <= 1'b1;
              ap_addr_q  <= {7'h0, ds_sbase_q};
              ap_wdata_q <= '0;
              ap_wstrb_q <= 8'hFF;
              ap_ret_q   <= StDSetZeroC;
              state_q    <= StApReq;
            end
          end
          StDSetZeroC: begin
            ds_z_i_q <= ds_z_i_q + 16'd1;
            if (ds_z_i_q + 16'd1 >= ds_z_n_q) begin
              state_q <= StDSetBump;
            end else begin
              ap_addr_q <= ap_addr_q + 32'd8;
              ap_ret_q  <= StDSetZeroC;
              state_q   <= StApReq;
            end
          end
          // hand {nsets+1, bump+records} to the pool and finish
          StDSetBump: begin
            otr_q    <= '{op: APU_OBJTAB_OP_SETAUXHI,
                         id: {32'h0, hnd_q[lu_slot(op_q, 1)]},
                         kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_POOL),
                         mask: 32'hFFFF_FFFF,
                         value: {ds_pent_q.aux[63:44] + 20'd1,
                                 ds_pent_q.aux[43:32] +
                                 12'(ds_sbyt_q >> 5)},
                         default: '0};
            ot_ret_q <= StDSetBumpC;
            state_q  <= StOtReq;
          end
          StDSetBumpC: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              result_q <= err_of(ot_cpl_i.status);
              state_q  <= StRep;
            end else begin
              blob_i_q <= blob_i_q + 5'd1;
              state_q  <= StBlobRd;
            end
          end

          // ---- §12.3 F5: resolve-descriptor-set subroutine -----------------
          // Caller issues the set LOOKUP with ot_ret_q=StRsvLuC and
          // rsv_ret_q=continuation; outputs rsv_ok/dead/base/layb/nbnd
          StRsvLuC: begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              rsv_ok_q   <= 1'b0;
              rsv_dead_q <= 1'b0;
              state_q    <= rsv_ret_q;
            end else begin
              rsv_ok_q   <= 1'b1;
              rsv_hnd_q  <= ot_cpl_i.handle;
              rsv_base_q <= ot_cpl_i.entry.aux[24:0];
              rsv_layh_q <= ot_cpl_i.entry.aux[63:32];
              rsv_phnd_q <= ot_cpl_i.entry.size[31:0];
              rsv_ep_q   <= ot_cpl_i.entry.state[15:0];
              otr_q    <= '{op: APU_OBJTAB_OP_READSLOT,
                           id: {48'h0, ot_cpl_i.entry.size[15:0]},
                           kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_POOL),
                           default: '0};
              ot_ret_q <= StRsvPoolC;
              state_q  <= StOtReq;
            end
          end
          StRsvPoolC: begin
            rsv_dead_q <= !(ot_cpl_i.status == APU_OBJTAB_OK &&
                            ot_cpl_i.entry.kind ==
                            6'(APU_VN_KIND_VK_DESCRIPTOR_POOL) &&
                            ot_cpl_i.handle == rsv_phnd_q &&
                            ot_cpl_i.entry.state[15:0] == rsv_ep_q);
            otr_q    <= '{op: APU_OBJTAB_OP_READSLOT,
                         id: {48'h0, rsv_layh_q[15:0]},
                         kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT),
                         default: '0};
            ot_ret_q <= StRsvLayC;
            state_q  <= StOtReq;
          end
          StRsvLayC: begin
            rsv_dead_q <= rsv_dead_q ||
                          !(ot_cpl_i.status == APU_OBJTAB_OK &&
                            ot_cpl_i.entry.kind ==
                            6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT) &&
                            ot_cpl_i.handle == rsv_layh_q);
            rsv_layb_q <= ot_cpl_i.status == APU_OBJTAB_OK
                          ? ot_cpl_i.entry.aux[63:48] : 16'h0;
            rsv_nbnd_q <= ot_cpl_i.status == APU_OBJTAB_OK
                          ? (ot_cpl_i.entry.aux[47:32] - 16'd1) >> 1
                          : 16'h0;
            state_q <= rsv_ret_q;
          end

          // ---- §12.3 F5: binding-row scan subroutine -----------------------
          // rsv_layb_q/rsv_nbnd_q + rw_bind_q -> rw_ok/off/cnt/typ, then
          // row_ret_q
          StRowSc: begin
            if (rw_i_q >= rsv_nbnd_q) begin
              rw_ok_q <= 1'b0;
              state_q <= row_ret_q;
            end else begin
              opr_q    <= '{op: APU_OBJPAY_OP_READ,
                           addr: {16'h0, rsv_layb_q} + 32'd1 +
                                 (32'(rw_i_q) << 1),
                           default: '0};
              op_ret_q <= StRowW0C;
              state_q  <= StOpReq;
            end
          end
          StRowW0C: begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              rw_ok_q <= 1'b0;
              state_q <= row_ret_q;
            end else if (op_cpl_i.rdata[31:24] == rw_bind_q) begin
              rw_cnt_q <= op_cpl_i.rdata[15:0];
              rw_typ_q <= op_cpl_i.rdata[23:16];
              opr_q    <= '{op: APU_OBJPAY_OP_READ,
                           addr: {16'h0, rsv_layb_q} + 32'd2 +
                                 (32'(rw_i_q) << 1),
                           default: '0};
              op_ret_q <= StRowW1C;
              state_q  <= StOpReq;
            end else begin
              rw_i_q  <= rw_i_q + 16'd1;
              state_q <= StRowSc;
            end
          end
          StRowW1C: begin
            rw_off_q <= op_cpl_i.status == APU_OBJPAY_OK
                        ? op_cpl_i.rdata[31:12] : 20'h0;
            rw_ok_q  <= op_cpl_i.status == APU_OBJPAY_OK;
            state_q  <= row_ret_q;
          end

          // ---- §12.3 F5: vkUpdateDescriptorSets staged walk ----------------
          // write header {dstSet(2), dstBinding, dstArrayElement,
          // descriptorCount, descriptorType} then descriptorCount buffer
          // infos {buffer(2), offset(2), range(2)} for buffer types;
          // copies follow the writes: {srcSet(2), srcBinding,
          // srcArrayElement, dstSet(2), dstBinding, dstArrayElement,
          // descriptorCount}
          StUpdHdrC: begin
            case (upd_h_q)
              4'd0: upd_dst_q[31:0]  <= stg_word_q;
              4'd1: upd_dst_q[63:32] <= stg_word_q;
              4'd2: upd_dstb_q       <= stg_word_q;
              4'd3: upd_arr_q        <= stg_word_q;
              4'd4: upd_dcnt_q       <= stg_word_q;
              default: upd_type_q    <= stg_word_q;
            endcase
            stg_i_q <= stg_i_q + 1'b1;
            upd_h_q <= upd_h_q + 4'd1;
            if (upd_h_q == 4'd5) begin
              otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                           id: APU_VN_ID_TAG | upd_dst_q,
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
              // dst set resolved: enter the shared pool/layout chain
              rsv_ok_q   <= 1'b1;
              rsv_hnd_q  <= ot_cpl_i.handle;
              rsv_base_q <= ot_cpl_i.entry.aux[24:0];
              rsv_layh_q <= ot_cpl_i.entry.aux[63:32];
              rsv_phnd_q <= ot_cpl_i.entry.size[31:0];
              rsv_ep_q   <= ot_cpl_i.entry.state[15:0];
              rsv_ret_q  <= StUpdWBegin;
              otr_q    <= '{op: APU_OBJTAB_OP_READSLOT,
                           id: {48'h0, ot_cpl_i.entry.size[15:0]},
                           kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_POOL),
                           default: '0};
              ot_ret_q <= StRsvPoolC;
              state_q  <= StOtReq;
            end
          end
          StUpdWBegin: begin
            upd_pois_q <= 1'b0;
            if (rsv_dead_q) begin
              // dead pool or layout: the records are unreachable —
              // consume this write's staged infos and move on
              if (is_buf_typ(upd_type_q[7:0]))
                stg_i_q <= stg_i_q + StgBits'(upd_dcnt_q[15:0] * 6);
              state_q <= StUpdWNext;
            end else begin
              rw_bind_q <= upd_dstb_q[7:0];
              rw_i_q    <= '0;
              row_ret_q <= StUpdWBad;
              state_q   <= StRowSc;
            end
          end
          StUpdWBad: begin
            // write-level failures poison the set at WNext; the
            // element loop only covers the in-range prefix
            upd_bad_q <= !rw_ok_q || rw_typ_q != upd_type_q[7:0];
            if (!rw_ok_q || rw_typ_q != upd_type_q[7:0] ||
                upd_arr_q + upd_dcnt_q > {16'h0, rw_cnt_q})
              upd_pois_q <= 1'b1;
            if (!rw_ok_q || rw_typ_q != upd_type_q[7:0]) begin
              if (is_buf_typ(upd_type_q[7:0]))
                stg_i_q <= stg_i_q + StgBits'(upd_dcnt_q[15:0] * 6);
              state_q <= StUpdWNext;
            end else begin
              ent_j_q <= '0;
              state_q <= StUpdInfo;
            end
          end
          StUpdInfo: begin
            if (32'(ent_j_q) >= upd_dcnt_q ||
                upd_arr_q + 32'(ent_j_q) >= {16'h0, rw_cnt_q}) begin
              // elements beyond the binding's array bound were already
              // poisoned at WBad — consume their staged infos in bulk
              automatic logic [31:0] left =
                  upd_dcnt_q > {16'h0, ent_j_q}
                  ? upd_dcnt_q - {16'h0, ent_j_q} : 32'h0;
              if (is_buf_typ(upd_type_q[7:0]))
                stg_i_q <= stg_i_q + StgBits'(left[15:0] * 6);
              state_q <= StUpdWNext;
            end else if (is_buf_typ(upd_type_q[7:0])) begin
              upd_h_q   <= '0;
              stg_ret_q <= StUpdInfoC;
              state_q   <= StStgRd;
            end else begin
              // non-buffer descriptor record: no staged info; write a
              // null record carrying the declared kind (image/sampler
              // execution stays refused downstream — F6)
              upd_elok_q <= 1'b0;
              upd_eb_q   <= '0;
              upd_esz_q  <= '0;
              upd_rec_q  <= {7'h0, rsv_base_q} +
                            ((32'(rw_off_q) + upd_arr_q +
                              32'(ent_j_q)) << 5);
              state_q    <= StUpdWr0;
            end
          end
          StUpdInfoC: begin
            case (upd_h_q)
              4'd0: upd_buf_q[31:0]  <= stg_word_q;
              4'd1: upd_buf_q[63:32] <= stg_word_q;
              4'd2: upd_off_q[31:0]  <= stg_word_q;
              4'd3: upd_off_q[63:32] <= stg_word_q;
              4'd4: upd_rng_q[31:0]  <= stg_word_q;
              default: upd_rng_q[63:32] <= stg_word_q;
            endcase
            stg_i_q <= stg_i_q + 1'b1;
            upd_h_q <= upd_h_q + 4'd1;
            if (upd_h_q == 4'd5) begin
              state_q <= StUpdBufGo;
            end else begin
              stg_ret_q <= StUpdInfoC;
              state_q   <= StStgRd;
            end
          end
          StUpdBufGo: begin
            otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                         id: APU_VN_ID_TAG | upd_buf_q,
                         kind: 6'(APU_VN_KIND_VK_BUFFER),
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StUpdBufCpl;
            state_q  <= StOtReq;
          end
          StUpdBufCpl: begin
            upd_rec_q <= {7'h0, rsv_base_q} +
                         ((32'(rw_off_q) + upd_arr_q +
                           32'(ent_j_q)) << 5);
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.bind_mem_slot == APU_OBJTAB_SLOT_NONE) begin
              upd_elok_q <= 1'b0;
              state_q    <= StUpdWr0;
            end else begin
              ud_mslot_q <= ot_cpl_i.entry.bind_mem_slot;
              upd_eb_q   <= ot_cpl_i.entry.bind_offset[31:0];
              upd_esz_q  <= ot_cpl_i.entry.size[31:0];
              otr_q    <= '{op: APU_OBJTAB_OP_READSLOT,
                           id: {48'h0, ot_cpl_i.entry.bind_mem_slot},
                           kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
                           default: '0};
              ot_ret_q <= StUpdMemCpl;
              state_q  <= StOtReq;
            end
          end
          StUpdMemCpl: begin
            // buffer {bind_offset,size} in upd_eb/upd_esz, memory in
            // ot_cpl_i: aperture address = mem_base + bind_off +
            // info.offset; visible range = info.range (VK_WHOLE_SIZE
            // -> buf.size - info.offset), bounded by the buffer extent
            automatic logic [63:0] rng_eff =
                upd_rng_q == 64'hFFFF_FFFF_FFFF_FFFF
                ? 64'(upd_esz_q) - upd_off_q : upd_rng_q;
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.kind !=
                    6'(APU_VN_KIND_VK_DEVICE_MEMORY) ||
                // §12.3 C: unbacked memory (type-1 not yet MAP_BLOB'd)
                // must fail the record, not fabricate a base
                ot_cpl_i.entry.aux[63:32] == APU_MEM_UNBACKED ||
                upd_off_q > 64'(upd_esz_q) ||
                rng_eff > 64'(upd_esz_q) - upd_off_q ||
                64'(upd_eb_q) + upd_off_q + rng_eff >
                    ot_cpl_i.entry.size) begin
              upd_elok_q <= 1'b0;
            end else begin
              upd_elok_q <= 1'b1;
              upd_eb_q   <= 32'(64'(ot_cpl_i.entry.aux[63:32]) +
                                64'(upd_eb_q) + upd_off_q);
              upd_esz_q  <= rng_eff[31:0];
            end
            state_q <= StUpdWr0;
          end
          // record beats: {size,base} then {flags,kind} at [15:8]
          StUpdWr0: begin
            ap_we_q    <= 1'b1;
            ap_addr_q  <= upd_rec_q;
            ap_wdata_q <= {upd_elok_q ? upd_esz_q : 32'h0,
                           upd_elok_q ? upd_eb_q : 32'h0};
            ap_wstrb_q <= 8'hFF;
            ap_ret_q   <= StUpdWr1;
            state_q    <= StApReq;
          end
          StUpdWr1: begin
            ap_we_q    <= 1'b1;
            ap_addr_q  <= upd_rec_q + 32'd8;
            // record byte8 = kind, byte9 = flags (LSU W_DS4 parse)
            ap_wdata_q <= {32'h0, 16'h0, 7'h0, upd_elok_q,
                           upd_type_q[7:0]};
            ap_wstrb_q <= 8'h03;
            ap_ret_q   <= StUpdElemCk;
            state_q    <= StApReq;
          end
          StUpdElemCk: begin
            // a failed buffer-descriptor element poisons the set;
            // image/sampler records are written with flags=0 (kind
            // preserved — refused at the LSU, not at dispatch)
            if (!upd_elok_q && is_buf_typ(upd_type_q[7:0]))
              upd_pois_q <= 1'b1;
            ent_j_q <= ent_j_q + 16'd1;
            state_q <= StUpdInfo;
          end
          // write end: apply the poison bit, then advance / copies
          StUpdPoisC: begin
            upd_pois_q <= 1'b0;
            state_q    <= StUpdWNext;
          end
          StUpdWNext: begin
            if (upd_pois_q) begin
              otr_q    <= '{op: APU_OBJTAB_OP_SETAUX,
                           id: {32'h0, rsv_hnd_q},
                           kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                           mask: 32'h8000_0000, value: 32'h8000_0000,
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StUpdPoisC;
              state_q  <= StOtReq;
            end else if (32'(upd_i_q) + 32'd1 < op_q.imm[0]) begin
              upd_i_q   <= upd_i_q + 16'd1;
              upd_h_q   <= '0;
              stg_ret_q <= StUpdHdrC;
              state_q   <= StStgRd;
            end else if (op_q.imm[1] != 32'h0) begin
              cp_i_q    <= '0;
              upd_h_q   <= '0;
              stg_ret_q <= StUpdCpRd;
              state_q   <= StStgRd;
            end else begin
              state_q <= StRep;
            end
          end

          // ---- §12.3 F5: vkUpdateDescriptorSets copies ---------------------
          StUpdCpRd: begin
            case (upd_h_q)
              4'd0: cp_src_q[31:0]   <= stg_word_q;
              4'd1: cp_src_q[63:32]  <= stg_word_q;
              4'd2: cp_sb_q          <= stg_word_q;
              4'd3: cp_sa_q          <= stg_word_q;
              4'd4: cp_dsid_q[31:0]  <= stg_word_q;
              4'd5: cp_dsid_q[63:32] <= stg_word_q;
              4'd6: cp_db_q          <= stg_word_q;
              4'd7: cp_da_q          <= stg_word_q;
              default: cp_n_q        <= stg_word_q;
            endcase
            stg_i_q <= stg_i_q + 1'b1;
            upd_h_q <= upd_h_q + 4'd1;
            if (upd_h_q == 4'd8) begin
              otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                           id: APU_VN_ID_TAG | cp_src_q,
                           kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StRsvLuC;
              rsv_ret_q <= StUpdCpS;
              state_q  <= StOtReq;
            end else begin
              stg_ret_q <= StUpdCpRd;
              state_q   <= StStgRd;
            end
          end
          // src set resolved: snapshot and scan its row for srcBinding
          StUpdCpS: begin
            cp_srcbad_q <= !rsv_ok_q || rsv_dead_q;
            cp_sbase_q  <= rsv_base_q;
            rw_bind_q   <= cp_sb_q[7:0];
            rw_i_q      <= '0;
            row_ret_q   <= StUpdCpD;
            state_q     <= StRowSc;
          end
          // src row done: resolve the dst set
          StUpdCpD: begin
            if (!rw_ok_q) begin
              cp_srcbad_q <= 1'b1;
            end else begin
              cp_soff_q <= rw_off_q;
              cp_scnt_q <= rw_cnt_q;
            end
            otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                         id: APU_VN_ID_TAG | cp_dsid_q,
                         kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StRsvLuC;
            rsv_ret_q <= StUpdCpDSet;
            state_q  <= StOtReq;
          end
          // dst resolved: scan its row for dstBinding
          StUpdCpDSet: begin
            cp_dbase_q <= rsv_base_q;
            cp_dhnd_q  <= rsv_hnd_q;
            cp_dead_q  <= !rsv_ok_q || rsv_dead_q;
            rw_bind_q  <= cp_db_q[7:0];
            rw_i_q     <= '0;
            row_ret_q  <= StUpdCpGo;
            state_q    <= StRowSc;
          end
          // both rows resolved: bounds-check then copy record beats
          StUpdCpGo: begin
            automatic logic bad =
                cp_srcbad_q || !rw_ok_q ||
                cp_sa_q + cp_n_q > {16'h0, cp_scnt_q} ||
                cp_da_q + cp_n_q > {16'h0, rw_cnt_q};
            cp_doff_q  <= rw_off_q;
            cp_dcnt2_q <= rw_cnt_q;
            if (cp_dead_q) begin
              // destination's pool/layout is dead: nothing to touch
              state_q <= StUpdCpNext;
            end else if (bad) begin
              // poison the dst set; the copy writes nothing
              otr_q    <= '{op: APU_OBJTAB_OP_SETAUX,
                           id: {32'h0, rsv_hnd_q},
                           kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                           mask: 32'h8000_0000, value: 32'h8000_0000,
                           ctx: ctx_i, default: '0};
              ot_ret_q <= StUpdCpPC;
              state_q  <= StOtReq;
            end else if (cp_n_q == 32'h0) begin
              state_q <= StUpdCpNext;
            end else begin
              ent_j_q   <= '0;
              cp_b_q    <= '0;
              ap_we_q   <= 1'b0;
              ap_addr_q <= {7'h0, cp_sbase_q} +
                           ((32'(cp_soff_q) + cp_sa_q) << 5);
              ap_ret_q  <= StUpdCpRC;
              state_q   <= StApReq;
            end
          end
          StUpdCpPC: begin
            state_q <= StUpdCpNext;
          end
          // read beat done -> write it to the dst record
          StUpdCpRC: begin
            ap_we_q    <= 1'b1;
            ap_addr_q  <= {7'h0, cp_dbase_q} +
                          ((32'(cp_doff_q) + cp_da_q +
                            32'(ent_j_q)) << 5) +
                          {28'h0, cp_b_q} * 32'd8;
            ap_wdata_q <= ap_rd_q;
            ap_wstrb_q <= 8'hFF;
            ap_ret_q   <= StUpdCpBC;
            state_q    <= StApReq;
          end
          StUpdCpBC: begin
            if (cp_b_q == 4'd3) begin
              // element done
              if (32'(ent_j_q) + 32'd1 >= cp_n_q) begin
                state_q <= StUpdCpNext;
              end else begin
                ent_j_q   <= ent_j_q + 16'd1;
                cp_b_q    <= '0;
                ap_we_q   <= 1'b0;
                ap_addr_q <= {7'h0, cp_sbase_q} +
                             ((32'(cp_soff_q) + cp_sa_q +
                               32'(ent_j_q) + 32'd1) << 5);
                ap_ret_q  <= StUpdCpRC;
                state_q   <= StApReq;
              end
            end else begin
              cp_b_q    <= cp_b_q + 4'd1;
              ap_we_q   <= 1'b0;
              ap_addr_q <= {7'h0, cp_sbase_q} +
                           ((32'(cp_soff_q) + cp_sa_q +
                             32'(ent_j_q)) << 5) +
                           {26'h0, cp_b_q + 4'd1} * 32'd8;
              ap_ret_q  <= StUpdCpRC;
              state_q   <= StApReq;
            end
          end
          StUpdCpNext: begin
            if (32'(cp_i_q) + 32'd1 >= op_q.imm[1]) begin
              state_q <= StRep;
            end else begin
              cp_i_q    <= cp_i_q + 16'd1;
              upd_h_q   <= '0;
              stg_ret_q <= StUpdCpRd;
              state_q   <= StStgRd;
            end
          end

          // ---- §7b/§12.3 F5: cmdrec payload producer -------------------------
          // produce stream word pay_send_q into pay_word_q:
          // PushConstants streams staged words verbatim;
          // BindDescriptorSets emits {set handle, ndyn} pairs (the set
          // id resolves through ObjTab, ndyn rides the set's aux) then
          // streams the verbatim dynamic-offset words
          StPayProd: begin
            if (pay_bind_q && pay_send_q < pay_pbnd_q) begin
              if (!pay_send_q[0]) begin
                // even send index = handle word: staged set id for
                // set s sits at words 2s/2s+1 — send == 2s here
                stg_i_q   <= StgBits'(pay_send_q);
                stg_ret_q <= StPayResLo;
                state_q   <= StStgRd;
              end else begin
                // odd send index = the set's dynamic-descriptor count
                pay_word_q <= {27'h0, pay_ndyn_q};
                state_q    <= pro_ret_q;
              end
            end else if (pay_bind_q) begin
              stg_i_q   <= StgBits'((pay_nset_q << 1) +
                                    (pay_send_q - pay_pbnd_q));
              stg_ret_q <= StPayCapW;
              state_q   <= StStgRd;
            end else begin
              stg_i_q   <= StgBits'(pay_send_q);
              stg_ret_q <= StPayCapW;
              state_q   <= StStgRd;
            end
          end
          StPayResLo: begin
            lay_lo_q  <= stg_word_q;
            stg_i_q   <= stg_i_q + 1'b1;
            stg_ret_q <= StPayResHi;
            state_q   <= StStgRd;
          end
          StPayResHi: begin
            otr_q    <= '{op: APU_OBJTAB_OP_LOOKUP,
                         id: APU_VN_ID_TAG | {stg_word_q, lay_lo_q},
                         kind: 6'(APU_VN_KIND_VK_DESCRIPTOR_SET),
                         ctx: ctx_i, default: '0};
            ot_ret_q <= StPayResCpl;
            state_q  <= StOtReq;
          end
          StPayResCpl: begin
            // a set that misses at record time stores a null handle;
            // the dispatch-time re-resolve refuses it.  ndyn comes
            // from aux[30:25] so the executor can group the following
            // dynamic-offset words per set
            pay_word_q <= ot_cpl_i.status == APU_OBJTAB_OK
                          ? ot_cpl_i.handle : 32'h0;
            pay_ndyn_q <= ot_cpl_i.status == APU_OBJTAB_OK
                          ? ot_cpl_i.entry.aux[29:25] : 5'h0;
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
                       id: APU_VN_ID_TAG | op_q.q[ns],
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
                           id: APU_VN_ID_TAG | pl_modid_q,
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
                           id: APU_VN_ID_TAG | pl_layid_q,
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
                         id: APU_VN_ID_TAG | op_q.q[
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
  output logic               ap_req_o,
  output logic               ap_we_o,
  output logic [31:0]        ap_addr_o,
  output logic [63:0]        ap_wdata_o,
  output logic [7:0]         ap_wstrb_o,
  input  logic               ap_ready_i,
  input  logic               ap_done_i,
  input  logic [63:0]        ap_rdata_i,
  input  logic               ap_err_i,
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
