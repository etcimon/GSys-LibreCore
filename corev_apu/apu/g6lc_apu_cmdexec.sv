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
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_mp_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Fences = 16,
  // §7b exception contract (2026-10-16): per-work-item watchdog — if
  // 2**WorkBudgetLog2 cycles pass with work outstanding and neither a
  // work issue nor a completion, an engine did not return: true
  // device loss.  The default (~1 s at 1 GHz) sits far above any
  // legal work item; verification fixtures override it.
  parameter int unsigned WorkBudgetLog2 = 30,
  // sticky execution-fault registers, one per context tag
  parameter int unsigned FaultCtxs = 32
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
  // G3b-ii: ShaderCore residency-manager client — pipeline module
  // handle -> slot resolve (LOOKUP / FILL) and slot pin release
  // (UNPIN).  sm_req_o is level-held until sm_gnt_i; a completion
  // pulses sm_cpl_i with sm_cpl_pl_i.  Shares the shcore manager
  // port with vnfront through the vgtop arbiter.
  output logic               sm_req_o,
  output apu_sh_sm_req_t     sm_req_pl_o,
  input  logic               sm_gnt_i,
  input  logic               sm_cpl_i,
  input  apu_sh_sm_cpl_t     sm_cpl_pl_i,
  // §5a G3b-iii: dedicated aperture word port (vgtop mp index 5 /
  // APU_MP_EXEC) — indirect-command operand words are fetched from
  // the bound buffer's aperture extent at issue time, the same path
  // xfer uses for bulk transfers
  output logic               mp_req_valid_o,
  input  logic               mp_req_ready_i,
  output apu_mp_req_t        mp_req_o,
  input  logic               mp_rsp_valid_i,
  input  apu_mp_rsp_t        mp_rsp_i,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  // §7b/5a-ii: shcore dispatch sideband (valid with work_o)
  output apu_xfer_desc_t     xf_o,   // §12.3 C/5a: Xfer operand desc
  // G1c: resolved raster draw sideband — valid alongside work_o for
  // vkCmdDraw/vkCmdDrawIndexed and the internal BeginRenderPass CLEAR
  // work (issued under ctype VK_CMD_CLEAR_ATTACHMENTS_EXT)
  output apu_rast_draw_t     rd_o,
  output logic [2:0]         disp_slot_o,
  output apu_sh_desc_t       desc_o, // §12.3 F5 descriptor sideband
  output logic [5:0]         push_n_o,
  output logic [1023:0]      push_o,
  output logic [15:0]        done_seq_o,
  output logic [Fences-1:0]  fence_signaled_o,
  output logic [Fences-1:0]  fence_lost_o,
  input  logic [Fences-1:0]  fence_clr_i,
  // §7b exception contract: vnfront pulses a fence's bit when the
  // submit that carried it failed before reaching the executor —
  // the slot goes signaled+lost so the guest's vkWaitForFences
  // terminates (DEVICE_LOST) instead of waiting on an unarmed fence
  input  logic [Fences-1:0]  fence_fail_i,
  // §12.3 3d-d: vgctl relocation hold — while high the executor
  // dequeues and issues no NEW submission; an in-flight submission
  // runs to completion.  idle_o = nothing in flight (FSM at rest and
  // no outstanding work); queued FIFO submissions stay held, so
  // idle_o deliberately does not consult fifo_n_q.
  input  logic               hold_i,
  output logic               idle_o,
  // §7b exception contract (2026-10-16): watchdog device loss — a
  // one-cycle pulse with the faulting submission's ctx tag; vnpump
  // marks that context's rings FATAL.  dead_o is the sticky level.
  output logic               devlost_valid_o,
  output logic [7:0]         devlost_ctx_o,
  output logic               dead_o,
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
    assign sm_req_o        = 1'b0;
    assign sm_req_pl_o     = '0;
    assign mp_req_valid_o  = 1'b0;
    assign mp_req_o        = '0;
    assign work_valid_o    = 1'b0;
    assign work_o          = '0;
    assign xf_o            = '0;
    assign rd_o            = '0;
    assign disp_slot_o     = '0;
    assign desc_o          = '0;
    assign push_n_o        = '0;
    assign push_o          = '0;
    assign done_seq_o      = '0;
    assign fence_signaled_o = '0;
    assign fence_lost_o    = '0;
    assign idle_o          = 1'b1;
    assign devlost_valid_o = 1'b0;
    assign devlost_ctx_o   = '0;
    assign dead_o          = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | submit_valid_i |
                    hold_i |
                    cr_req_ready_i | cr_cpl_valid_i | (|cr_cpl_i) |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    op_req_ready_i | op_cpl_valid_i | (|op_cpl_i) |
                    mp_req_ready_i | mp_rsp_valid_i | (|mp_rsp_i) |
                    sm_gnt_i | sm_cpl_i | (|sm_cpl_pl_i) |
                    work_ready_i | work_done_i | (|work_done_pl_i) |
                    (|fence_clr_i) | (|submit_i) | (|fence_fail_i);
  end else begin : gen_on
    localparam int unsigned Fifo = 4;
    localparam logic [4:0]   FENCE_NONE = 5'd31;

    typedef enum logic [6:0] {
      StIdle, StPinReq, StPinCpl, StCntReq, StCntCpl,
      StRdReq, StRdCpl, StResReq, StResCpl, StDispatch,
      StWork, StDrain, StUnpReq, StUnpCpl, StNextBuf,
      StBufDone, StFinalDrain, StCbRes, StCbResCpl, StDone,
      // G3b-ii: shcore residency-manager client + module resolver —
      // StSmReq/StSmCpl are the request subroutine (level-held req,
      // gnt accept, cpl); StRsReq/..C resolve {handle,park} -> slot
      // via LOOKUP, FILL on miss (pinning the slot for the record),
      // execution-fault on a scan-faulting fill; StUnpD drains the
      // completed-work pending-UNPIN queue (FILL-BUSY backoff and
      // per-buffer hygiene); StPBR/StPBRC read one ObjPay word of a
      // pipeline module-handle block
      StSmReq, StSmCpl, StRsReq, StRsLookC, StRsFillC, StUnpD,
      StPBR, StPBRC,
      StDsModR0, StDsModR1, StDsModR2, StDsModRC,
      StDrModR0, StDrModR1, StDrModR2, StDrModR3,
      StDrModRC0, StDrModRC1,
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
      // READSLOT per operand, then the record issues on StWork); G1c
      // shares the same states for the draw vertex/index buffers and
      // the BeginRenderPass attachment image (xf_for_q selects)
      StXfBufReq, StXfBufCpl, StXfMemReq, StXfMemCpl,
      // G1c/G2a: BeginRenderPass attachment resolve — rp LOOKUP ->
      // ObjPay parse (attachment table + subpass refs) -> fb LOOKUP ->
      // per-attachment view id -> view LOOKUP -> shared image operand
      // resolver (XF mode IMG) -> one CLEAR work per loadOp-CLEAR
      // attachment -> subpass attachment snapshot
      StBrpRpReq, StBrpRpCpl, StBrpPayReq, StBrpPayCpl,
      StBrpFbReq, StBrpFbCpl, StBrpVwLo, StBrpVwLoC,
      StBrpVwHi, StBrpVwHiC, StBrpVwReq, StBrpVwCpl,
      StBrpIssue, StBrpClrN,
      // G1c/G2a: draw assembly tail — 44-word pipeline-state ObjPay
      // read, then per-binding buffer resolves through StXf* (mode VB/IB)
      StDrPay, StDrPayCpl, StDrVbN, StDrIbN,
      // §5a G3b-iii: vkCmdExecuteCommands — one-deep {cbd,cursor}
      // stack; the secondary's ObjTab handle arrives on the record's
      // ObjPay payload stream (imm[7] + i), its cbd is the live
      // entry's aux[63:32]; the pop restores the outer cursor but
      // deliberately NOT the dynamic-state snapshot
      StXcFetch, StXcFetchC, StXcLk, StXcLkC, StXcPop,
      // §5a G3b-iii: command-buffer events — Set/ResetEvent ride the
      // barrier drain then SETSTATE the event's bit 0; WaitEvents
      // drains, then polls each listed event's state[0] every 64
      // cycles (the issue/completion watchdog bounds the drain)
      StEvSet, StEvSetC, StWvRd, StWvRdC, StWvLk, StWvLkC, StWvWait,
      // §5a G3b-iii: indirect operand fetch — aperture beats of the
      // bound buffer stream into ind_w_q, then the resolved record
      // takes the direct-command assembly path
      StIndRd, StIndRdC
    } state_e;
    state_e              state_q;
    // submit FIFO (flops)
    apu_cmdexec_submit_t fifo_q [Fifo];
    logic [2:0]          fifo_head_q, fifo_tail_q, fifo_n_q;
    // execution registers
    apu_cmdexec_submit_t cur_q;
    logic [2:0]          buf_i_q;       // buffer index within submit
    logic [2:0]          pin_i_q;       // pin substep
    logic [15:0]         rec_i_q;       // record cursor (chunked
                                        // buffers exceed 8 bits)
    logic [15:0]         rec_n_q;       // record count
    logic [31:0]         cur_cbd_q;     // current buffer's descriptor
                                        // word address (§5a G3b-iii)
    // §5a G3b-iii: one-deep secondary-command-buffer stack —
    // {cbd, cursor, count} of the suspended primary
    logic                sec_v_q;
    logic [31:0]         sec_cbd_q;
    logic [31:0]         sec_payb_q;  // ExecuteCommands payload base
    logic [15:0]         sec_ri_q, sec_rn_q;
    logic [15:0]         sxc_i_q, sxc_n_q;  // ExecuteCommands list walk
    logic [31:0]         xc_hnd_q;          // secondary handle fetched
    logic [31:0]         xc_cbd_q;          // resolved secondary cbd
    // §5a G3b-iii: command-buffer event machinery — pending action
    // after the barrier drain (0 none, 1 set, 2 reset, 3 wait)
    logic [1:0]          bar_act_q;
    logic [15:0]         wv_i_q, wv_n_q;    // WaitEvents list walk
    logic [6:0]          wv_cyc_q;          // 64-cycle poll divider
    logic [31:0]         wv_hnd_q;          // event under poll
    // §5a G3b-iii: indirect-command operand fetch — the bound
    // buffer's resolved aperture base + byte span, beat cursor, and
    // the fetched words (up to 4 aligned 64-bit beats cover the
    // 12/16/20-byte command at any 4-byte-aligned offset)
    logic                ind_q;             // record is indirect
    logic                ind_idx_q;         // DrawIndexedIndirect
    logic [63:0]         ind_base_q;        // aperture byte base
    logic [2:0]          ind_i_q, ind_nb_q; // beat cursor / count
    logic [7:0][31:0]    ind_w_q;           // raw beat halves
    apu_cmdrec_rec_t     rec_q;         // current record
    logic [2:0]          h_i_q;         // handle resolve cursor
    logic [6:0]          pay_i_q;       // §7b arena read cursor
    logic [6:0]          pay_n_q;       // §7b arena reads left
    logic                pay_push_q;    // walk feeds the push shadow
    logic [5:0]          pay_dst_q;     // push shadow word offset
    logic [4:0]          pay_nset_q;    // bind walk: sets/bindings in the call
    logic [3:0][4:0]     pay_dnb_q;     // bind walk: ndyn per set
                                        // (call order)
    logic [3:0]          pinned_q;      // per-buffer pin success
    logic                lost_q;        // DEVICE_LOST on this submit
    logic [7:0]          outst_q;       // outstanding work items
    logic [7:0]          dsd_skip_q;    // dones owed to older works
    logic [15:0]         done_seq_q;
    logic [Fences-1:0]   fsig_q, flost_q;
    // §7b exception contract (2026-10-16): sticky per-context
    // execution-fault registers — {count, work_id[7:0], code, pc,
    // wave}; the debug tap and the bridge stats() read them
    // hierarchically.  Once a watchdog expiry declares the device
    // dead every later submission is retired lost.
    logic [FaultCtxs-1:0][63:0] fault_q;
    logic [WorkBudgetLog2-1:0]  wb_cnt_q;
    logic                dead_q;
    logic                devlost_q;
    logic [7:0]          devlost_ctx_q;
    wire                 wd_fire = (&wb_cnt_q) && outst_q != 8'h0 &&
                                   !dead_q;
    apu_cmdexec_state_t  snap_q;
    // §7b/5a-ii + §12.3 F5: dispatch assembly state
    logic [2:0]          ds_slot_q;     // resolved module slot
    // G3b-ii: module-resolver operand ({handle, {chunk,words}} from
    // the pipeline's ObjPay block), resolved slot, fill-fault flag,
    // and subroutine returns; sm client request/completion holding
    logic [31:0]         ds_mh_q;       // compute module handle
    logic [31:0]         ds_mc_q;       // compute module {chunk,words}
    logic [31:0]         rs_hnd_q, rs_cw_q, rs_spec_q;
    logic [2:0]          rs_slot_q;
    logic                rs_fault_q;
    state_e              rs_ret_q;
    apu_sh_sm_op_e       sm_op_q;
    logic                sm_pin_q;
    logic [2:0]          sm_slot_q;
    logic [31:0]         sm_hnd_q;
    logic [15:0]         sm_chk_q, sm_nw_q;
    logic                sm_ok_q, sm_busy_q;
    logic [2:0]          sm_rslot_q;
    logic [7:0]          sm_flt_q;
    state_e              sm_ret_q, unp_ret_q;
    // pin bookkeeping: every issued work pushes the record's pin
    // bundle {bvalid,bslot,avalid,aslot}; a work_done pops the oldest
    // bundle into the pending-UNPIN ring, drained at FILL-BUSY backoff
    // and per buffer end so residency pins track true in-flight work
    localparam int unsigned PinQ = 16;  // ring depth caps the works in
                                        // flight per drain window —
                                        // issue stalls, never drops
    logic [7:0]          rec_pin_q;
    logic [15:0][7:0]    pinq_q;
    logic [4:0]          pinq_h_q, pinq_t_q;
    logic [4:0]          pinq_due_q;    // done-but-unpopped bundles
    logic [15:0][7:0]    unpq_q;
    logic [4:0]          unp_h_q, unp_t_q;
    logic                unp_ph_q;      // drain: a-slot done phase
    logic                unp_src_q;     // StUnpD drains rec_pin_q
    wire                 pinq_full = (pinq_t_q - pinq_h_q) == 5'(PinQ);
    wire                 unpq_full = (unp_t_q - unp_h_q) == 5'(PinQ);
    // generic pipeline-block ObjPay read (module {handle,park} words)
    logic [31:0]         pbr_addr_q;
    logic [31:0]         pbr_data_q;
    state_e              pbr_ret_q;
    logic [31:0]         gp_mh_q [2];   // draw stage module handles
    logic [31:0]         gp_mc_q [2];   // draw stage {chunk,words}
    logic [1:0]          ds_set_q;      // set index 0..3
    logic [15:0]         ds_pl_q;       // pipeline-layout slot
    logic [15:0]         ds_plg_q;      // pipeline-layout generation
    logic [31:0]         ds_plpay_q;    // pipeline-layout pay base
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
    logic [1:0]          xf_opnd_q;     // operand walk cursor (0/1)
    logic [15:0]         xf_ms_q;       // bound memory slot
    logic [15:0]         xf_mg_q;       // §12.3 3d-d: bound memory gen
    logic [63:0]         xf_bo_q;       // resource bind_offset
    logic [63:0]         xf_bs_q;       // resource bound size
    logic [31:0]         xf_src_base_q, xf_src_size_q;
    logic [31:0]         xf_dst_base_q, xf_dst_size_q;
    apu_xfer_img_t       xf_img0_q, xf_img1_q;
    // G1c: graphics executor state — the raster gets these via rd_o,
    // not the work snapshot (the work record stays compute-shaped)
    logic [15:0][31:0]   vb_hnd_q;        // bound vb {gen,slot}
    logic [15:0][31:0]   vb_off_q;        // vkCmdBindVertexBuffers offset
    logic [31:0]         ib_hnd_q;
    logic [31:0]         ib_off_q;
    logic [1:0]          ib_type_q;       // 1 UINT16, 2 UINT32
    logic [5:0][31:0]    vp_q;            // viewport f32 words
    logic [3:0][31:0]    sc_q;            // scissor {x,y,w,h}
    // G2a: per-attachment clear values — flat 4-word VkClearValue per
    // attachment index (4 colour + 1 depth slots, indexed by the
    // render pass's attachment index, not the subpass position)
    logic [19:0][31:0]   clearv_q;
    apu_xfer_img_t [4:0] att_img_q;       // resolved image per att idx
    logic [4:0][1:0]     att_ld_q;        // per-attachment loadOp
    apu_xfer_img_t [3:0] ca_q;            // subpass color attachments
    logic [3:0]          ca_valid_q;
    apu_xfer_img_t       da_q;            // subpass depth attachment
    logic                da_valid_q;
    logic [3:0][31:0]    bconst_q;        // vkCmdSetBlendConstants f32
    apu_rast_draw_t      rd_q;            // draw sideband in assembly
    // G1c: Xfer operand resolver modes — 0 record operand (xfer), 1 vb
    // binding dr_bq, 2 index buffer, 3 attachment image (READSLOT)
    logic [1:0]          xf_for_q;
    logic [31:0]         xf_xoff_q;       // operand extra offset
    logic [4:0]          dr_bq;           // vb binding resolve cursor
    logic [15:0]         dr_vbmask_q;     // valid binding bits (pipe w1..16)
    logic [5:0]          dr_pi_q;         // pipeline ObjPay read cursor
    logic                dr_bcdyn_q;      // w25: BLEND_CONSTANTS dynamic
    // w25[17:16] static-state flags + w34..43 baked viewport/scissor:
    // when set they override the streamed SetViewport/SetScissor
    // shadows at the end of the ObjPay walk
    logic                dr_vpsta_q, dr_scsta_q;
    logic [5:0][31:0]    dr_vp_q;
    logic [3:0][31:0]    dr_sc_q;
    logic [31:0]         rd_gpay_q;       // pipeline ObjPay base (aux[31:16])
    logic [31:0]         brp_rpay_q;      // render-pass ObjPay base
    logic [15:0]         brp_rpw_q;       // render-pass ObjPay word count
    logic [31:0]         brp_fpay_q;      // framebuffer ObjPay base
    logic [4:0]          brp_pi_q;        // rp ObjPay word cursor
    logic [2:0]          brp_ph_q;        // rp parse phase
    logic [2:0]          brp_att_q;       // attachmentCount (1..5)
    logic [2:0]          brp_ncl_q;       // subpass colorAttachmentCount
    logic [2:0]          brp_ak_q;        // attachment resolve/clear idx
    logic [1:0]          brp_ai_q;        // per-attachment word cursor
    logic [1:0]          brp_cj_q;        // subpass color-ref cursor
    logic [3:0][3:0]     brp_cref_q;      // subpass colour refs (att idx, F=unused)
    logic [3:0]          brp_dref_q;      // depth ref (F = none)
    logic [63:0]         brp_viewid_q;    // framebuffer view id in flight
    logic [15:0]         brp_islot_q;     // view's image slot
    // pay-walk selector (exactly one): push merge, bind-sets stream,
    // vb bind stream, viewport, scissor, BeginRP clear values,
    // blend constants, BindIndexBuffer's u64 offset
    logic                pay_vb_q, pay_vp_q, pay_sc_q, pay_clr_q,
                         pay_ib_q, pay_bc_q, clr_ok_q;
    state_e              pay_ret_q;       // post-walk continuation

    // XFER-class record types, assembled through the StXf* states
    wire work_is_xfer = rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_TO_BUFFER_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT) ||
                        rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_CLEAR_COLOR_IMAGE_EXT);
    // operand handles pack the non-commandBuffer lookup slots
    // sequentially: {srcBuffer,dstImage}, {srcImage,dstBuffer},
    // {srcImage,dstImage}, {image} — operand n rides handle[n].
    wire [1:0] xf_hsel = xf_opnd_q;
    // operand n is an image for every image-class type except the
    // B2I buffer (op 0) and the I2B buffer (op 1); the BeginRP
    // attachment resolve (xf_for_q == IMG) is always an image
    wire xf_op_img =
        xf_for_q == 2'd3 ||
        (xf_for_q == 2'd0 &&
         ((rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_CLEAR_COLOR_IMAGE_EXT)) ||
          (rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT)) ||
          (rec_q.ctype ==
              32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT)
           && xf_opnd_q == 2'd1) ||
          (rec_q.ctype ==
              32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_TO_BUFFER_EXT)
           && xf_opnd_q == 2'd0)));
    // image-desc slot: I2I's second operand lands in img1
    wire xf_img_sel = rec_q.ctype ==
                      32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT) &&
                      xf_opnd_q == 2'd1;
    // two-operand records revisit the walk once (record mode only)
    wire xf_two_ops = xf_for_q == 2'd0 && rec_q.ctype ==
                      32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT) ||
                      rec_q.ctype ==
                      32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT) ||
                      rec_q.ctype ==
                      32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_TO_BUFFER_EXT) ||
                      rec_q.ctype ==
                      32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT);

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
        APU_VN_TYPE_VK_CMD_SET_BLEND_CONSTANTS_EXT,
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
        APU_VN_TYPE_VK_CMD_PIPELINE_BARRIER_EXT,
        // §5a G3b-iii: event records ride the drain — the action
        // (set/reset/wait) runs after outstanding work retires
        APU_VN_TYPE_VK_CMD_SET_EVENT_EXT,
        APU_VN_TYPE_VK_CMD_RESET_EVENT_EXT,
        APU_VN_TYPE_VK_CMD_WAIT_EVENTS_EXT:
          return APU_CMDEXEC_CLS_BARRIER;
        APU_VN_TYPE_VK_CMD_DRAW_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_DISPATCH_EXT,
        APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_DISPATCH_BASE_EXT,
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
    // §12.3 3d-d: "nothing in flight" for the relocation drain — the
    // FIFO may hold a queued submission hold_i is blocking, so it is
    // deliberately not consulted here
    assign idle_o         = state_q == StIdle && outst_q == 8'd0;
    assign done_seq_o     = done_seq_q;
    assign fence_signaled_o = fsig_q;
    assign fence_lost_o   = flost_q;
    assign devlost_valid_o = devlost_q;
    assign devlost_ctx_o   = devlost_ctx_q;
    assign dead_o         = dead_q;
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
                        ? APU_XFER_OP_FILL :
                    rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT)
                        ? APU_XFER_OP_UPDATE :
                    rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT)
                        ? APU_XFER_OP_B2I :
                    rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_TO_BUFFER_EXT)
                        ? APU_XFER_OP_I2B :
                    rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT)
                        ? APU_XFER_OP_I2I : APU_XFER_OP_CLEARI,
                   // §5a G3b-iii: payloads are PayMem-resident — the
                   // absolute word address stamped into imm[7] at
                   // record time; the engine streams it over its own
                   // ObjPay client (PAYREAD is retired)
                   pay_base: rec_q.imm[7],
                   // region/range count rides imm[2] (CopyImage),
                   // imm[1] (B2I/I2B/CLEAR behind imageLayout) or
                   // imm[0] (CopyBuffer)
                   regions:  rec_q.ctype ==
                             32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT)
                             ? rec_q.imm[2][15:0]
                             : rec_q.ctype ==
                               32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT) ||
                               rec_q.ctype ==
                               32'(APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT) ||
                               rec_q.ctype ==
                               32'(APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT)
                               ? rec_q.imm[0][15:0] : rec_q.imm[1][15:0],
                   src_base: xf_src_base_q, src_size: xf_src_size_q,
                   dst_base: xf_dst_base_q, dst_size: xf_dst_size_q,
                   img0: xf_img0_q, img1: xf_img1_q};
    assign desc_o         = desc_q;
    assign push_n_o       = push_max_q;
    assign push_o         = push_sh_q;
    // G1c: assembled raster draw sideband — rd_q is assembled during
    // the BeginRP / Draw resolve chains and is valid with work_o
    assign rd_o           = rd_q;
    wire rec_is_draw =
        rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT) ||
        rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT) ||
        // §5a G3b-iii: resolved indirect draws assemble identically —
        // the operand words were fetched into ind_w_q first
        rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_DRAW_INDIRECT_EXT) ||
        rec_q.ctype == 32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT);
    // fetched indirect-command word w (the operand can start on the
    // second half of an aligned aperture beat).  The word arriving on
    // this cycle's response beat must read through — the ind_w_q
    // writes are nonblocking, so without the bypass the operand's
    // trailing word would read one fetch stale (last-beat race: a
    // DispatchIndirect operand issued gz=0 -> silent zero-dimension
    // retire).
    function automatic logic [31:0] f_iw(input logic [2:0] w);
      automatic logic [2:0] iw = w + {2'b0, ind_base_q[2]};
      if (iw == {ind_i_q, 1'b0}) return mp_rsp_i.rdata[31:0];
      if (iw == {ind_i_q, 1'b1}) return mp_rsp_i.rdata[63:32];
      return ind_w_q[iw];
    endfunction

    always_comb begin
      cr_req_valid_o = 1'b0;
      cr_req_o       = '0;
      ot_req_valid_o = 1'b0;
      ot_req_o       = '0;
      op_req_valid_o = 1'b0;
      op_req_o       = '0;
      mp_req_valid_o = 1'b0;
      mp_req_o       = '0;
      sm_req_o       = 1'b0;
      sm_req_pl_o    = '0;
      work_valid_o   = 1'b0;
      work_o         = '0;
      case (state_q)
        // G3b-ii: level-held sm client request until the arbiter
        // grants; the payload rides smr_q's staged fields
        StSmReq: begin
          sm_req_o    = 1'b1;
          sm_req_pl_o = '{op: sm_op_q, pin: sm_pin_q,
                          slot: sm_slot_q, handle: sm_hnd_q,
                          chunk: sm_chk_q, words: sm_nw_q,
                          spec: rs_spec_q};
        end
        StPBR: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: pbr_addr_q, default: '0};
        end
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
                             cbd: cur_cbd_q, default: '0};
        end
        StRdReq: begin
          cr_req_valid_o = 1'b1;
          cr_req_o       = '{op: APU_CMDREC_OP_READ,
                             cbd: cur_cbd_q, idx: rec_i_q,
                             default: '0};
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
          // §5a G3b-iii: payloads are PayMem-resident — one ObjPay
          // READ per word at the record's absolute payload base
          // (imm[7]).  The PushConstants payload keeps the offset+size
          // header words (pay[0..1]); the values start at +2
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: rec_q.imm[7] + 32'(pay_i_q) +
                                   (pay_push_q ? 32'd2 :
                                    // BeginRP stream leads with
                                    // {rp id, fb id, area} — 8 words
                                    // before clearValueCount
                                    pay_clr_q ? 32'd8 : 32'd0),
                             default: '0};
        end
        // §5a G3b-iii: vkCmdExecuteCommands — the secondary-buffer
        // {gen,slot} handles stream from the record's ObjPay payload;
        // sec_payb_q holds the ExecuteCommands imm[7] because rec_q is
        // overwritten by each secondary's own records
        StXcFetch: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: sec_payb_q + 32'(sxc_i_q),
                             default: '0};
        end
        StXcLk: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, xc_hnd_q},
                             kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                             default: '0};
        end
        // §5a G3b-iii: CmdSetEvent/CmdResetEvent — after the drain the
        // event's ObjTab state bit 0 is written (EVENT_SET=1)
        StEvSet: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_SETSTATE,
                             id: {32'h0, rec_q.handle[0]},
                             kind: 6'(APU_VN_KIND_VK_EVENT),
                             mask: 32'h1,
                             value: bar_act_q == 2'd2 ? 32'h0
                                                      : 32'h1,
                             default: '0};
        end
        // §5a G3b-iii: CmdWaitEvents — event {gen,slot} handles stream
        // from the record's ObjPay payload (imm[7] + i)
        StWvRd: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: rec_q.imm[7] + 32'(wv_i_q),
                             default: '0};
        end
        StWvLk: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, wv_hnd_q},
                             kind: 6'(APU_VN_KIND_VK_EVENT),
                             default: '0};
        end
        // §5a G3b-iii: indirect operand fetch — one aligned 64-bit
        // aperture beat per request (dom=1, byte address)
        StIndRd: begin
          mp_req_valid_o = 1'b1;
          mp_req_o       = '{dom: 1'b1, we: 1'b0,
                            addr: {ind_base_q[63:3], 3'b000} +
                                  {58'h0, ind_i_q, 3'b000},
                            wdata: '0, wstrb: '0};
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
                             addr: ds_plpay_q + 32'd2 +
                                   (32'(ds_set_q) << 1),
                             default: '0};
        end
        StDsSlHi: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: ds_plpay_q + 32'd3 +
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
          // ds_slo_q is the layout payload word base
          // (aux[63:48] << 6), a 22-bit address.  The header and the
          // bind rows sit at that base; a 16-bit slice aliases every
          // layout whose chunk index is >= 1024.
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: state_q == StDsRowNb
                                   ? ds_slo_q
                                   : ds_slo_q + 32'd1 +
                                     (32'(ds_i_q) << 1) +
                                     32'(ds_rh_q),
                             default: '0};
        end
        StDsIssue: begin
          work_valid_o = !pinq_full;
          work_o       = '{ctype: rec_q.ctype, snap: snap_q, rec: rec_q};
        end
        StXfBufReq: begin
          // §5a: re-resolve the operand resource (kind already proven
          // by the StRes walk; we need the live entry fields).
          // G1c: xf_for_q == VB/IB resolves a bound vertex/index
          // buffer by its recorded {gen,slot}; == IMG READSLOTs the
          // BeginRP attachment's image by slot (no record handle).
          ot_req_valid_o = 1'b1;
          if (xf_for_q == 2'd3) begin
            ot_req_o     = '{op: APU_OBJTAB_OP_READSLOT,
                             id: {48'h0, brp_islot_q},
                             kind: 6'(APU_VN_KIND_VK_IMAGE),
                             default: '0};
          end else begin
            ot_req_o     = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0,
                                  xf_for_q == 2'd1
                                      ? vb_hnd_q[dr_bq[3:0]] :
                                  xf_for_q == 2'd2
                                      ? ib_hnd_q :
                                        rec_q.handle[xf_hsel]},
                             kind: xf_op_img
                                  ? 6'(APU_VN_KIND_VK_IMAGE)
                                  : 6'(APU_VN_KIND_VK_BUFFER),
                             default: '0};
          end
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
        StCbRes: begin
          // §12.3 3d-d: execution complete — the command buffer leaves
          // PENDING and is EXECUTABLE again; a resubmit after the
          // fence is the stock frame-loop pattern
          ot_req_valid_o = buf_i_q < {2'b0, cur_q.nbufs};
          ot_req_o       = '{op: APU_OBJTAB_OP_SETSTATE,
                             id: {32'h0, cur_q.chndl[buf_i_q[1:0]]},
                             kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                             mask: 32'hF, value: 32'h2,
                             default: '0};
        end
        // ---- G1c: BeginRenderPass attachment resolve -----------------
        StBrpRpReq: begin
          // record handles pack in q-slot order: [0] = renderPass,
          // [1] = framebuffer (the commandBuffer q-slot is skipped)
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, rec_q.handle[0]},
                             kind: 6'(APU_VN_KIND_VK_RENDER_PASS),
                             default: '0};
        end
        StBrpPayReq: begin
          // G2a: rp ObjPay word brp_pi_q — the phase machine in
          // StBrpPayCpl walks {attachmentCount, {format,loadOp,
          // storeOp}×A, subpassCount, colorAttachmentCount,
          // colour refs×C, depth ref}
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: brp_rpay_q + 32'(brp_pi_q),
                             default: '0};
        end
        StBrpFbReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, rec_q.handle[1]},
                             kind: 6'(APU_VN_KIND_VK_FRAMEBUFFER),
                             default: '0};
        end
        // fb ObjPay: {rp id 2w, attachmentCount, view ids 2w each,
        // width, height, layers} — attachment brp_ak's view id at
        // w3+2ak/w4+2ak
        StBrpVwLo: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: brp_fpay_q + 32'd3 +
                                   32'({brp_ak_q, 1'b0}),
                             default: '0};
        end
        StBrpVwHi: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: brp_fpay_q + 32'd4 +
                                   32'({brp_ak_q, 1'b0}),
                             default: '0};
        end
        StBrpVwReq: begin
          // framebuffer payload carries raw 64-bit client ids
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: APU_VN_ID_TAG | brp_viewid_q,
                             kind: 6'(APU_VN_KIND_VK_IMAGE_VIEW),
                             default: '0};
        end
        // G1c: graphics-pipeline ObjPay — 44-word state block
        StDrPay: begin
          op_req_valid_o = 1'b1;
          op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: rd_gpay_q +
                                   32'(dr_pi_q),
                             default: '0};
        end
        // the internal render-pass CLEAR rides the work port with the
        // CLEAR_ATTACHMENTS carrier so vgtop routes it to the raster
        StBrpIssue: begin
          work_valid_o = !pinq_full;
          work_o       = '{ctype:
                              32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT),
                          snap: snap_q, rec: rec_q};
        end
        StWork: begin
          work_valid_o = !pinq_full;
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
        cur_cbd_q   <= '0;
        sec_v_q     <= 1'b0;
        sec_cbd_q   <= '0;
        sec_payb_q  <= '0;
        sec_ri_q    <= '0;
        sec_rn_q    <= '0;
        sxc_i_q     <= '0;
        sxc_n_q     <= '0;
        xc_hnd_q    <= '0;
        xc_cbd_q    <= '0;
        bar_act_q   <= '0;
        wv_i_q      <= '0;
        wv_n_q      <= '0;
        wv_cyc_q    <= '0;
        wv_hnd_q    <= '0;
        ind_q       <= 1'b0;
        ind_idx_q   <= 1'b0;
        ind_base_q  <= '0;
        ind_i_q     <= '0;
        ind_nb_q    <= '0;
        ind_w_q     <= '0;
        rec_q       <= '0;
        h_i_q       <= '0;
        pay_i_q     <= '0;
        pay_n_q     <= '0;
        pinned_q    <= '0;
        lost_q      <= 1'b0;
        outst_q     <= '0;
        dsd_skip_q  <= '0;
        rec_pin_q   <= '0;
        pinq_h_q    <= '0;
        pinq_t_q    <= '0;
        pinq_due_q  <= '0;
        unp_h_q     <= '0;
        unp_t_q     <= '0;
        unp_ph_q    <= 1'b0;
        unp_src_q   <= 1'b0;
        ds_mh_q     <= '0;
        ds_mc_q     <= '0;
        rs_hnd_q    <= '0;
        rs_cw_q     <= '0;
        rs_spec_q   <= '0;
        rs_slot_q   <= '0;
        rs_fault_q  <= 1'b0;
        rs_ret_q    <= StIdle;
        sm_op_q     <= APU_SH_SM_LOOKUP;
        sm_pin_q    <= 1'b0;
        sm_slot_q   <= '0;
        sm_hnd_q    <= '0;
        sm_chk_q    <= '0;
        sm_nw_q     <= '0;
        sm_ok_q     <= 1'b0;
        sm_busy_q   <= 1'b0;
        sm_rslot_q  <= '0;
        sm_flt_q    <= '0;
        sm_ret_q    <= StIdle;
        unp_ret_q   <= StIdle;
        pbr_addr_q  <= '0;
        pbr_data_q  <= '0;
        pbr_ret_q   <= StIdle;
        gp_mh_q     <= '{default: '0};
        gp_mc_q     <= '{default: '0};
        done_seq_q  <= '0;
        fsig_q      <= '0;
        flost_q     <= '0;
        fault_q     <= '0;
        wb_cnt_q    <= '0;
        dead_q      <= 1'b0;
        devlost_q   <= 1'b0;
        devlost_ctx_q <= '0;
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
        xf_mg_q     <= '0;
        xf_bo_q     <= '0;
        xf_bs_q     <= '0;
        xf_src_base_q <= '0; xf_src_size_q <= '0;
        xf_dst_base_q <= '0; xf_dst_size_q <= '0;
        xf_img0_q   <= '0; xf_img1_q <= '0;
        vb_hnd_q    <= '0; vb_off_q <= '0;
        ib_hnd_q    <= '0; ib_off_q <= '0; ib_type_q <= '0;
        vp_q        <= '0; sc_q <= '0;
        clearv_q    <= '0;
        att_img_q   <= '0; att_ld_q <= '0;
        ca_q        <= '0; ca_valid_q <= '0;
        da_q        <= '0; da_valid_q <= 1'b0;
        bconst_q    <= '0;
        rd_q        <= '0;
        xf_for_q    <= '0; xf_xoff_q <= '0;
        dr_bq       <= '0; dr_vbmask_q <= '0; dr_pi_q <= '0;
        dr_bcdyn_q  <= 1'b0;
        dr_vpsta_q  <= 1'b0; dr_scsta_q <= 1'b0;
        dr_vp_q     <= '0; dr_sc_q <= '0;
        rd_gpay_q   <= '0;
        brp_rpay_q  <= '0; brp_rpw_q <= '0; brp_fpay_q <= '0;
        brp_pi_q    <= '0; brp_ph_q <= '0;
        brp_att_q   <= '0; brp_ncl_q <= '0; brp_ak_q <= '0;
        brp_ai_q    <= '0; brp_cj_q <= '0;
        brp_cref_q  <= '0; brp_dref_q <= 4'hF;
        brp_viewid_q <= '0; brp_islot_q <= '0;
        pay_vb_q    <= 1'b0; pay_vp_q <= 1'b0;
        pay_sc_q    <= 1'b0; pay_clr_q <= 1'b0;
        pay_ib_q    <= 1'b0; pay_bc_q <= 1'b0; clr_ok_q <= 1'b0;
        pay_ret_q   <= StNextBuf;
      end else begin
        // work completions retire outstanding items.  A non-OK done
        // code (FAULT/BUDGET/UNSUPPORTED) is an EXECUTION-TIME fault:
        // the work item retires with undefined results, the
        // submission continues through its remaining records and
        // command buffers (Mesa's feedback write still lands and the
        // fence signals normally), and the fault is recorded in the
        // context's sticky fault register — it never loses the
        // submission.  Submit-level failures set lost_q directly.
        if (work_done_i && outst_q != 8'h0) outst_q <= outst_q - 8'h1;
        // G3b-ii: residency-pin FIFO — every accepted work pushes the
        // record's pin bundle {bv,bs[2:0],av,as[2:0]} (zero for
        // pin-less records so the FIFO stays aligned with outst_q);
        // a work_done pops the oldest bundle into the pending-UNPIN
        // ring, which StUnpD drains (FILL-BUSY backoff + buffer end)
        if (work_valid_o && work_ready_i) begin
          pinq_q[pinq_t_q[3:0]] <= rec_pin_q;
          pinq_t_q              <= pinq_t_q + 5'd1;
          // the queue owns the bundle now — a record that faults after
          // issue must not release it a second time
          rec_pin_q             <= '0;
        end
        // a completion owes the oldest bundle a pop; the pop is
        // level-triggered so a full UNPIN ring only defers it — a
        // dropped bundle would pin a residency slot forever.  EVERY
        // work completion owes a pop: dispatch/draw works wait in
        // StDsDone and never count into outst_q, so gating on outst
        // would orphan their bundles (a pinned slot forever).  The
        // count never exceeds the pushed-but-unpopped entries, so a
        // stray done after a watchdog clear cannot phantom-pop a stale
        // bundle into the UNPIN ring.
        pinq_due_q <= pinq_due_q +
                      ((work_done_i &&
                        (pinq_t_q - pinq_h_q) > pinq_due_q)
                           ? 5'd1 : 5'd0) -
                      ((pinq_due_q != 5'd0 &&
                        (pinq_q[pinq_h_q[3:0]] == 8'h0 ||
                         !unpq_full)) ? 5'd1 : 5'd0);
        if (pinq_due_q != 5'd0 &&
            (pinq_q[pinq_h_q[3:0]] == 8'h0 || !unpq_full)) begin
          if (pinq_q[pinq_h_q[3:0]] != 8'h0) begin
            unpq_q[unp_t_q[3:0]] <= pinq_q[pinq_h_q[3:0]];
            unp_t_q              <= unp_t_q + 5'd1;
          end
          pinq_h_q <= pinq_h_q + 5'd1;
        end
// pragma translate_off
`ifdef G6LC_APU_DBG_PINQ
        if (work_valid_o && work_ready_i)
          $display("[PQ] push rec_pin=%02x t=%0t", rec_pin_q, $time);
        if (work_done_i)
          $display("[PQ] done outst=%0d st=%0d due=%0d t=%0t",
                   outst_q, state_q, pinq_due_q, $time);
        if (pinq_due_q != 5'd0 &&
            (pinq_q[pinq_h_q[3:0]] == 8'h0 || !unpq_full))
          $display("[PQ] pop head=%02x unp=%0d/%0d t=%0t",
                   pinq_q[pinq_h_q[3:0]], unp_h_q, unp_t_q, $time);
        if (state_q == StUnpD)
          $display("[PQ] unpd src=%0d rec=%02x unp=%0d/%0d due=%0d ret=%0d t=%0t",
                   unp_src_q, rec_pin_q, unp_h_q, unp_t_q, pinq_due_q,
                   unp_ret_q, $time);
`endif
// pragma translate_on
        if (work_done_i &&
            work_done_pl_i.code != 8'(APU_SH_DONE_OK) &&
            cur_q.ctx < 8'(FaultCtxs))
          fault_q[5'(cur_q.ctx)] <=
              {fault_q[5'(cur_q.ctx)][63:48] == 16'hFFFF
                   ? 16'hFFFF
                   : fault_q[5'(cur_q.ctx)][63:48] + 16'h1,
               work_done_pl_i.work_id[7:0], work_done_pl_i.code,
               work_done_pl_i.pc, work_done_pl_i.wave};
        // watchdog: a bounded stall between work issue/completion
        // while items are outstanding is true device loss
        if (outst_q == 8'h0 || (work_valid_o && work_ready_i) ||
            work_done_i)
          wb_cnt_q <= '0;
        else if (!dead_q)
          wb_cnt_q <= wb_cnt_q + WorkBudgetLog2'(1);
        devlost_q <= 1'b0;
        if (wd_fire) begin
          // the engine never returned: drain — abandon the outstanding
          // items, retire this submission lost, pulse devlost so
          // vnpump marks the context's rings FATAL, and stay dead
          // until the context is destroyed
          dead_q        <= 1'b1;
          lost_q        <= 1'b1;
          outst_q       <= '0;
          devlost_q     <= 1'b1;
          devlost_ctx_q <= cur_q.ctx;
          // abandon the pin bookkeeping too — the dead context's
          // pinned slots are released by the CTX_DESTROY sweep
          rec_pin_q  <= '0;
          pinq_h_q   <= '0;
          pinq_t_q   <= '0;
          pinq_due_q <= '0;
          unp_h_q    <= '0;
          unp_t_q    <= '0;
          unp_ph_q   <= 1'b0;
          unp_src_q  <= 1'b0;
        end
        // fence clear mask (vkResetFences)
        fsig_q  <= fsig_q & ~fence_clr_i;
        flost_q <= flost_q & ~fence_clr_i;
        // §7b exception contract: a submit that vnfront rejected
        // never reaches the FIFO below — pulse its fence signaled +
        // lost here so the guest wait terminates DEVICE_LOST
        fsig_q  <= (fsig_q & ~fence_clr_i) | fence_fail_i;
        flost_q <= (flost_q & ~fence_clr_i) | fence_fail_i;
        // submit FIFO push
        if (submit_valid_i && submit_ready_o) begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
          $display("[DBG] submit fidx=%0d nb=%0d t=%0t",
                   submit_i.fence_idx, submit_i.nbufs, $time);
`endif
// pragma translate_on
          fifo_q[fifo_tail_q[1:0]] <= submit_i;
          fifo_tail_q <= fifo_tail_q + 3'd1;
          fifo_n_q    <= fifo_n_q + 3'd1;
        end

        // watchdog expiry abandons the in-flight submission wherever
        // the FSM is parked — the outstanding count is dropped above
        // so StUnpReq → StFinalDrain → StDone retires the fence lost
        if (wd_fire)
          state_q <= StUnpReq;
        else
        case (state_q)
          StIdle: begin
            // §12.3 3d-d: the relocation hold blocks dequeue — the
            // queued submission starts once hold_i drops.  On a dead
            // device every submission retires immediately with the
            // fence lost; the context is unusable until CTX_DESTROY.
            if (fifo_n_q != 3'd0 && !hold_i) begin
              cur_q       <= fifo_q[fifo_head_q[1:0]];
              fifo_head_q <= fifo_head_q + 3'd1;
              fifo_n_q    <= fifo_n_q - 3'd1;
              pin_i_q     <= '0;
              buf_i_q     <= '0;
              pinned_q    <= '0;
              lost_q      <= dead_q;
              state_q     <= fifo_q[fifo_head_q[1:0]].nbufs == 3'd0 ||
                             dead_q ? StDone : StPinReq;
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
              // §5a G3b-iii: first buffer's descriptor block
              cur_cbd_q <= cur_q.crec[0];
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
            end else if (cr_cpl_i.count == 32'h0) begin
              // §5a G3b-iii: an empty SECONDARY retires its
              // ExecuteCommands step (pop), only a primary ends the
              // buffer walk
              state_q <= sec_v_q ? StXcPop : StUnpReq;
            end else begin
              rec_n_q <= cr_cpl_i.count[15:0];
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
              // G3b-ii: this record's issued works carry no residency
              // pins until a module resolve deposits them
              rec_pin_q <= '0;
              // G1c: clear the pay-walk mode selectors — the dispatch
              // case arms re-arm the one the record needs
              pay_push_q <= 1'b0;
              pay_bind_q <= 1'b0;
              pay_vb_q   <= 1'b0;
              pay_vp_q   <= 1'b0;
              pay_sc_q   <= 1'b0;
              pay_clr_q  <= 1'b0;
              pay_ib_q   <= 1'b0;
              pay_bc_q   <= 1'b0;
              clr_ok_q   <= 1'b0;
              pay_ret_q  <= StNextBuf;
              xf_for_q   <= 2'd0;
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

          // ---- §7b: record-payload walk (§5a G3b-iii: ObjPay) -------
          StPayReq: if (op_req_ready_i) state_q <= StPayCpl;
          StPayCpl: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
              $display("[DBG] pay rd i=%0d imm7=%08x rd=%08x vb=%0d push=%0d st=%0d t=%0t",
                       pay_i_q, rec_q.imm[7], op_cpl_i.rdata, pay_vb_q,
                       pay_push_q, op_cpl_i.status, $time);
`endif
// pragma translate_on
              if (pay_push_q) begin
                // §7b: merge the PushConstants payload into the
                // 32-word shadow at the imm[1] word offset
                push_sh_q[32*(pay_dst_q + pay_i_q[5:0]) +: 32] <=
                    op_cpl_i.rdata;
                if (pay_dst_q + pay_i_q[5:0] + 6'd1 > push_max_q)
                  push_max_q <= pay_dst_q + pay_i_q[5:0] + 6'd1;
              end else if (pay_vb_q) begin
                // G1c: arena = [nbind resolved handles][nbind u64
                // offsets] — handles land in vb_hnd at firstBinding+i,
                // offset lo words in vb_off (hi words dropped: offsets
                // < 4 GiB).  The lo/hi test is on the RELATIVE index:
                // nbind odd shifts the absolute parity.
                if (32'(pay_i_q) < pay_nset_q) begin
                  if (rec_q.imm[0] + 32'(pay_i_q) < 32'd16)
                    vb_hnd_q[4'(rec_q.imm[0] + 32'(pay_i_q))] <=
                        op_cpl_i.rdata;
                end else if (pay_i_q[0] == pay_nset_q[0] &&
                             rec_q.imm[0] +
                                 32'((pay_i_q - 7'(pay_nset_q)) >> 1) <
                                 32'd16) begin
                  vb_off_q[4'(rec_q.imm[0] +
                              32'((pay_i_q - 7'(pay_nset_q)) >> 1))] <=
                      op_cpl_i.rdata;
                end
              end else if (pay_ib_q) begin
                // G1c: BindIndexBuffer's u64 offset — lo word only
                if (pay_i_q == 7'd0) ib_off_q <= op_cpl_i.rdata;
              end else if (pay_vp_q) begin
                if (pay_i_q < 7'd6) vp_q[3'(pay_i_q)] <= op_cpl_i.rdata;
              end else if (pay_sc_q) begin
                if (pay_i_q < 7'd4) sc_q[2'(pay_i_q)] <= op_cpl_i.rdata;
              end else if (pay_bc_q) begin
                // G2a: vkCmdSetBlendConstants — four f32 words
                if (pay_i_q < 7'd4)
                  bconst_q[2'(pay_i_q)] <= op_cpl_i.rdata;
              end else if (pay_clr_q) begin
                // word 0 of the walk is clearValueCount; the per-
                // attachment 4-word clear values follow (G2a)
                if (pay_i_q == 7'd0)
                  clr_ok_q <= op_cpl_i.rdata != 32'h0;
                else if (clr_ok_q)
                  clearv_q[5'(pay_i_q - 7'd1)] <= op_cpl_i.rdata;
              end else if (pay_bind_q) begin
                // §12.3 F5 bind stream: {set handle, ndyn} pairs for
                // each bound set, then the call's dynamic-offset
                // words — consumed per set in call order
                if (pay_i_q < {pay_nset_q, 1'b0}) begin
                  if (pay_i_q[0] == 1'b0) begin
                    snap_q.dset[2'(rec_q.imm[1] +
                                    {25'h0, pay_i_q[6:1]})] <=
                        op_cpl_i.rdata;
                  end else begin
                    pay_dnb_q[2'(pay_i_q[6:1])] <=
                        op_cpl_i.rdata[4:0];
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
                              [bk[3:0]] <= op_cpl_i.rdata;
                  end
                end
              end else begin
                snap_q.dset[2'(rec_q.imm[1] + {24'h0, pay_i_q})] <=
                    op_cpl_i.rdata;
              end
              pay_i_q <= pay_i_q + 7'd1;
              state_q <= pay_i_q + 7'd1 >= pay_n_q
                         ? pay_ret_q : StPayReq;
            end
          end

          // ---- dispatch ----------------------------------------------
          StDispatch: begin
            case (rec_cls(rec_q.ctype))
              APU_CMDEXEC_CLS_STATE: begin
                case (rec_q.ctype)
                  APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT: begin
                    snap_q.pipeline <= rec_q.handle[0];
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
                    $display("[DBG] bind-pipe: hnd=%08x bufidx=%0d t=%0t",
                             rec_q.handle[0], buf_i_q, $time);
`endif
// pragma translate_on
                  end
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
                      5'(rec_q.imm[1] < 32'd4
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
                  APU_VN_TYPE_VK_CMD_BIND_VERTEX_BUFFERS_EXT: begin
                    snap_q.vtx <= rec_q.handle[0];
                    // G1c: arena = [bindingCount resolved handles]
                    // [bindingCount u64 offsets]; walk all of it
                    pay_vb_q   <= 1'b1;
                    pay_ret_q  <= StNextBuf;
                    pay_i_q    <= '0;
                    pay_nset_q <= 5'(rec_q.imm[1]);
                    pay_n_q    <= 7'(rec_q.imm[1] * 32'd3);
                  end
                  APU_VN_TYPE_VK_CMD_BIND_INDEX_BUFFER_EXT: begin
                    snap_q.ibo <= rec_q.handle[0];
                    ib_hnd_q   <= rec_q.handle[0];
                    // the u64 offset is a kept payload word pair on the
                    // record arena — walk it through the pay path
                    // (ib_off takes the lo word; < 4 GiB)
                    pay_ib_q   <= 1'b1;
                    pay_ret_q  <= StNextBuf;
                    pay_i_q    <= '0;
                    pay_n_q    <= 7'd2;
                    // VkIndexType: 0 UINT16, 1 UINT32 -> rd coding 1/2
                    ib_type_q  <= 2'(rec_q.imm[0][1:0]) + 2'd1;
                  end
                  APU_VN_TYPE_VK_CMD_SET_VIEWPORT_EXT: begin
                    snap_q.vp  <= rec_q.imm[0];
                    // G1c: viewport words stream through the arena
                    // (6 per viewport; maxViewports = 1)
                    pay_vp_q   <= 1'b1;
                    pay_ret_q  <= StNextBuf;
                    pay_i_q    <= '0;
                    pay_n_q    <= 7'd6;
                  end
                  APU_VN_TYPE_VK_CMD_SET_SCISSOR_EXT: begin
                    snap_q.sc  <= rec_q.imm[0];
                    pay_sc_q   <= 1'b1;
                    pay_ret_q  <= StNextBuf;
                    pay_i_q    <= '0;
                    pay_n_q    <= 7'd4;
                  end
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
                  APU_VN_TYPE_VK_CMD_SET_BLEND_CONSTANTS_EXT: begin
                    // G2a: four f32 words sit at the record's arena
                    // base (imm[7]); they land in bconst_q
                    pay_bc_q  <= 1'b1;
                    pay_i_q   <= '0;
                    pay_n_q   <= 7'd4;
                    pay_ret_q <= StNextBuf;
                  end
                  APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT,
                  APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_2_EXT: begin
                    snap_q.rp_active <= 1'b1;
                    snap_q.subpass   <= '0;
                    ca_valid_q       <= '0;
                    da_valid_q       <= 1'b0;
                    // G2a: attachment resolve runs on the rp/fb record
                    // handles; the walk reads clearValueCount (arena
                    // word 8, also imm[4]) then count*4 clear words —
                    // clipped to 5 attachments' worth
                    if (rec_q.handle[0] == 32'h0 ||
                        rec_q.handle[1] == 32'h0)
                      lost_q <= 1'b1;
                    clearv_q  <= '0;
                    att_ld_q  <= '0;
                    att_img_q <= '0;
                    pay_clr_q <= 1'b1;
                    pay_ret_q <= StBrpRpReq;
                    pay_i_q   <= '0;
                    pay_n_q   <= 7'd1 +
                                 7'(rec_q.imm[4] > 32'd5
                                    ? 32'd20 : rec_q.imm[4] << 2);
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
                     rec_q.imm[1] < 32'd128 && rec_q.imm[2] >= 32'd4) ||
                    (rec_q.ctype ==
                         APU_VN_TYPE_VK_CMD_BIND_VERTEX_BUFFERS_EXT &&
                     rec_q.imm[1] != 32'h0) ||
                    // BindIndexBuffer always walks its 2-word u64
                    // offset out of the record arena
                    rec_q.ctype ==
                        APU_VN_TYPE_VK_CMD_BIND_INDEX_BUFFER_EXT ||
                    (rec_q.ctype ==
                         APU_VN_TYPE_VK_CMD_SET_VIEWPORT_EXT &&
                     rec_q.imm[0] == 32'h0 && rec_q.imm[1] != 32'h0) ||
                    (rec_q.ctype ==
                         APU_VN_TYPE_VK_CMD_SET_SCISSOR_EXT &&
                     rec_q.imm[0] == 32'h0 && rec_q.imm[1] != 32'h0) ||
                    rec_q.ctype ==
                        APU_VN_TYPE_VK_CMD_SET_BLEND_CONSTANTS_EXT ||
                    rec_q.ctype ==
                        APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT ||
                    rec_q.ctype ==
                        APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_2_EXT
                    ? ((rec_q.ctype ==
                            32'(APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT)
                        || rec_q.ctype ==
                            32'(APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_2_EXT))
                       && (rec_q.handle[0] == 32'h0 ||
                           rec_q.handle[1] == 32'h0)
                       // a null rp/fb record handle (record-time
                       // resolve miss) loses the submission like a
                       // dead pipeline
                       ? StUnpReq : StPayReq)
                    : StNextBuf;
              end
              APU_CMDEXEC_CLS_WORK: begin
                if (rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT) ||
                    rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_DISPATCH_BASE_EXT)) begin
                  // §7b/5a-ii: no bound pipeline -> DEVICE_LOST, no
                  // dispatch is issued.  §5a G3b-iii: DispatchBase
                  // assembles identically — its imm carries
                  // {baseX,Y,Z} at [0..2] and {gx,gy,gz} at [3..5],
                  // which shcore decodes directly
                  if (snap_q.pipeline == 32'h0) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else begin
                    desc_q  <= '0;
                    state_q <= StDsPipeReq;
                  end
                end else if (rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT)) begin
                  // §5a G3b-iii: fetch the 12-byte
                  // VkDispatchIndirectCommand from the bound buffer
                  // (record handle[0]) at aperture offset imm[2:3]
                  if (snap_q.pipeline == 32'h0) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else begin
                    ind_q     <= 1'b1;
                    ind_idx_q <= 1'b0;
                    xf_for_q  <= 2'd0;
                    xf_opnd_q <= 2'd0;
                    state_q   <= StXfBufReq;
                  end
                end else if (rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_DRAW_INDIRECT_EXT) ||
                    rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT)) begin
                  // §5a G3b-iii: same guards as a direct draw, then
                  // the operand fetch.  drawCount (imm[0]) is clamped
                  // to <= 1 — 0 is a no-op, >1 honours only the first
                  // command
                  if (snap_q.pipeline == 32'h0 ||
                      (ca_valid_q == 4'h0 && !da_valid_q)) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else if (rec_q.imm[0] == 32'h0) begin
                    state_q <= StNextBuf;
                  end else begin
                    ind_q     <= 1'b1;
                    ind_idx_q <= rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT);
                    xf_for_q  <= 2'd0;
                    xf_opnd_q <= 2'd0;
                    state_q   <= StXfBufReq;
                  end
                end else if (rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_EXECUTE_COMMANDS_EXT)) begin
                  // §5a G3b-iii: one-deep {cbd,cursor} stack — the
                  // primary suspends while each listed secondary runs
                  // to its own count; dynamic state deliberately does
                  // NOT restore on the pop
                  if (sec_v_q) begin
                    // a secondary inside a secondary: beyond the
                    // settled one-deep stack
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else if (rec_q.imm[0] == 32'h0) begin
                    state_q <= StNextBuf;
                  end else begin
                    sec_v_q   <= 1'b1;
                    sec_cbd_q <= cur_cbd_q;
                    sec_payb_q <= rec_q.imm[7];
                    sec_ri_q  <= rec_i_q;
                    sec_rn_q  <= rec_n_q;
                    sxc_i_q   <= '0;
                    sxc_n_q   <= 16'(rec_q.imm[0]);
                    state_q   <= StXcFetch;
                  end
                end else if (rec_is_draw) begin
                  // G1c/G2a: draw needs a bound graphics pipeline (the
                  // aux[6] check lands at StDsPipeCpl) and at least one
                  // active attachment (colour or depth) — either
                  // missing loses the submission like the no-pipeline
                  // dispatch
                  if (snap_q.pipeline == 32'h0 ||
                      (ca_valid_q == 4'h0 && !da_valid_q)) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else begin
                    desc_q  <= '0;
                    rd_q.op          <= APU_RAST_OP_DRAW;
                    rd_q.ca          <= ca_q;
                    rd_q.ca_valid    <= ca_valid_q;
                    rd_q.da          <= da_q;
                    rd_q.da_valid    <= da_valid_q;
                    rd_q.vp          <= '{x: vp_q[0], y: vp_q[1],
                                          w: vp_q[2], h: vp_q[3],
                                          minz: vp_q[4], maxz: vp_q[5]};
                    rd_q.sc_x        <= sc_q[0][15:0];
                    rd_q.sc_y        <= sc_q[1][15:0];
                    rd_q.sc_w        <= sc_q[2][15:0];
                    rd_q.sc_h        <= sc_q[3][15:0];
                    rd_q.vb_base     <= '0;
                    rd_q.vb_size     <= '0;
                    rd_q.vb_stride   <= '0;
                    rd_q.vb_rate     <= '0;
                    rd_q.attr        <= '0;
                    rd_q.ib_base     <= '0;
                    rd_q.ib_size     <= '0;
                    rd_q.ib_type     <=
                        rec_q.ctype ==
                            32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT)
                        ? ib_type_q : 2'd0;
                    rd_q.vertex_count   <= rec_q.imm[0];
                    rd_q.instance_count <= rec_q.imm[1];
                    if (rec_q.ctype ==
                            32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT)) begin
                      rd_q.first_vertex   <= '0;
                      rd_q.first_index    <= rec_q.imm[2];
                      rd_q.vertex_offset  <= rec_q.imm[3];
                      rd_q.first_instance <= rec_q.imm[4];
                    end else begin
                      rd_q.first_vertex   <= rec_q.imm[2];
                      rd_q.first_index    <= '0;
                      rd_q.vertex_offset  <= '0;
                      rd_q.first_instance <= rec_q.imm[3];
                    end
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
              APU_CMDEXEC_CLS_BARRIER: begin
                // §5a G3b-iii: the drain's post-action — 0 plain
                // barrier, 1 SetEvent, 2 ResetEvent, 3 WaitEvents
                bar_act_q <=
                    rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_SET_EVENT_EXT)   ? 2'd1 :
                    rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_RESET_EVENT_EXT) ? 2'd2 :
                    rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_WAIT_EVENTS_EXT) ? 2'd3 :
                                                                2'd0;
                state_q   <= StDrain;
              end
              default:                  state_q <= StNextBuf;
            endcase
          end
          StWork: if (pinq_full && unpq_full) begin
            // both pin rings saturated: drain the UNPIN ring to open
            // room, then retry the issue — never drop a bundle
            unp_ret_q <= StWork;
            unp_ph_q  <= 1'b0;
            state_q   <= StUnpD;
          end else if (work_ready_i && !pinq_full) begin
            outst_q <= outst_q + 8'h1 -
                       ((work_done_i && outst_q != 8'h0) ? 8'h1 : 8'h0);
            state_q <= StNextBuf;
          end

          // ---- §7b/5a-ii + §12.3 F5: dispatch assembly ---------------
          // pipeline -> {ObjPay module block, pipeline-layout
          // {slot,gen}}; G3b-ii: slots are a residency cache — the
          // module {handle,park} words are read from the pipeline's
          // ObjPay block (w0/1 compute, w44..47 graphics) and
          // resolved through the shcore manager (LOOKUP/FILL)
          StDsPipeReq: if (ot_req_ready_i) state_q <= StDsPipeCpl;
          StDsPipeCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else if (rec_is_draw && !ot_cpl_i.entry.aux[6]) begin
              // G1c: a draw bound to a compute pipeline loses the
              // submission (aux[6] marks a graphics pipeline)
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ds_pl_q   <= ot_cpl_i.entry.aux[47:32];
              ds_plg_q  <= ot_cpl_i.entry.aux[63:48];
              // §5a: the ObjPay block base is a 64-word chunk index —
              // compute parks {handle,park} at w0/1; graphics carries
              // the state block there and the stage descriptors at
              // w44..47
              rd_gpay_q   <= 32'(ot_cpl_i.entry.aux[31:16]) << 6;
              dr_vbmask_q <= '0;
              dr_pi_q     <= '0;
              desc_q      <= '0;
              rs_fault_q  <= 1'b0;
              rs_spec_q   <= '0;
              pbr_addr_q  <= (32'(ot_cpl_i.entry.aux[31:16]) << 6) +
                             (rec_is_draw ? 32'd44 : 32'd0);
              pbr_ret_q   <= rec_is_draw ? StDrModR0 : StDsModR0;
              state_q     <= StPBR;
            end
          end
          // module-handle block reads: compute needs w0..1; a draw
          // needs w44..47 ({VS handle,VS park,FS handle,FS park})
          StDsModR0: begin
            ds_mh_q    <= pbr_data_q;
            pbr_addr_q <= pbr_addr_q + 32'd1;
            pbr_ret_q  <= StDsModR1;
            state_q    <= StPBR;
          end
          StDsModR1: begin
            ds_mc_q    <= pbr_data_q;
            rs_hnd_q   <= ds_mh_q;
            rs_cw_q    <= pbr_data_q;
            pbr_addr_q <= pbr_addr_q + 32'd1;
            pbr_ret_q  <= StDsModR2;
            state_q    <= StPBR;
          end
          StDsModR2: begin
            rs_spec_q <= pbr_data_q;
            rs_ret_q  <= StDsModRC;
            state_q   <= StRsReq;
          end
          StDsModRC: begin
            if (rs_fault_q) begin
              // execution-time fault: the dispatch retires undefined;
              // the sticky register records it and the submission
              // continues (§7b contract — the fence still signals)
              if (cur_q.ctx < 8'(FaultCtxs))
                fault_q[5'(cur_q.ctx)] <=
                    {fault_q[5'(cur_q.ctx)][63:48] == 16'hFFFF
                         ? 16'hFFFF
                         : fault_q[5'(cur_q.ctx)][63:48] + 16'h1,
                     rec_i_q, sm_flt_q, 8'h0, 16'h0};
              if (rec_pin_q != 8'h0) begin
                // no work was issued — the bundle never reached pinq;
                // release the slot pins before the next record
                unp_src_q <= 1'b1;
                unp_ph_q  <= 1'b0;
                unp_ret_q <= StNextBuf;
                state_q   <= StUnpD;
              end else begin
                state_q <= StNextBuf;
              end
            end else begin
              ds_slot_q         <= rs_slot_q;
              rec_pin_q[3:0]    <= {1'b1, rs_slot_q};
              state_q           <= StDsLayReq;
            end
          end
          StDrModR0: begin
            gp_mh_q[0] <= pbr_data_q;
            pbr_addr_q <= pbr_addr_q + 32'd1;
            pbr_ret_q  <= StDrModR1;
            state_q    <= StPBR;
          end
          StDrModR1: begin
            gp_mc_q[0] <= pbr_data_q;
            pbr_addr_q <= pbr_addr_q + 32'd1;
            pbr_ret_q  <= StDrModR2;
            state_q    <= StPBR;
          end
          StDrModR2: begin
            gp_mh_q[1] <= pbr_data_q;
            pbr_addr_q <= pbr_addr_q + 32'd1;
            pbr_ret_q  <= StDrModR3;
            state_q    <= StPBR;
          end
          StDrModR3: begin
            gp_mc_q[1] <= pbr_data_q;
            rs_hnd_q   <= gp_mh_q[0];
            rs_cw_q    <= gp_mc_q[0];
            rs_ret_q   <= StDrModRC0;
            state_q    <= StRsReq;
          end
          StDrModRC0: begin
            if (rs_fault_q) begin
              if (cur_q.ctx < 8'(FaultCtxs))
                fault_q[5'(cur_q.ctx)] <=
                    {fault_q[5'(cur_q.ctx)][63:48] == 16'hFFFF
                         ? 16'hFFFF
                         : fault_q[5'(cur_q.ctx)][63:48] + 16'h1,
                     rec_i_q, sm_flt_q, 8'h0, 16'h0};
              if (rec_pin_q != 8'h0) begin
                // no work was issued — release the slot pins before
                // the next record (the bundle never reached pinq)
                unp_src_q <= 1'b1;
                unp_ph_q  <= 1'b0;
                unp_ret_q <= StNextBuf;
                state_q   <= StUnpD;
              end else begin
                state_q <= StNextBuf;
              end
            end else begin
              rd_q.vs_slot      <= rs_slot_q;
              rec_pin_q[3:0]    <= {1'b1, rs_slot_q};
              rs_hnd_q          <= gp_mh_q[1];
              rs_cw_q           <= gp_mc_q[1];
              rs_ret_q          <= StDrModRC1;
              state_q           <= StRsReq;
            end
          end
          StDrModRC1: begin
            if (rs_fault_q) begin
              if (cur_q.ctx < 8'(FaultCtxs))
                fault_q[5'(cur_q.ctx)] <=
                    {fault_q[5'(cur_q.ctx)][63:48] == 16'hFFFF
                         ? 16'hFFFF
                         : fault_q[5'(cur_q.ctx)][63:48] + 16'h1,
                     rec_i_q, sm_flt_q, 8'h0, 16'h0};
              if (rec_pin_q != 8'h0) begin
                // the VS resolve already pinned its slot — release it;
                // no work was issued so the bundle never reached pinq
                unp_src_q <= 1'b1;
                unp_ph_q  <= 1'b0;
                unp_ret_q <= StNextBuf;
                state_q   <= StUnpD;
              end else begin
                state_q <= StNextBuf;
              end
            end else begin
              rd_q.fs_slot      <= rs_slot_q;
              rec_pin_q[7:4]    <= {1'b1, rs_slot_q};
              state_q           <= StDsLayReq;
            end
          end
          // ---- G3b-ii: shcore residency-manager subroutine ---------
          // StRsReq resolves {rs_hnd_q,rs_cw_q} -> rs_slot_q with the
          // slot pinned for the record's work; a faulting FILL sets
          // rs_fault_q and returns.  StSmReq/StSmCpl are the generic
          // level-held request/completion arm.
          StRsReq: begin
            sm_op_q  <= APU_SH_SM_LOOKUP;
            sm_pin_q <= 1'b1;
            sm_hnd_q <= rs_hnd_q;
            sm_ret_q <= StRsLookC;
            state_q  <= StSmReq;
          end
          StRsLookC: begin
            if (sm_ok_q) begin
              rs_slot_q <= sm_rslot_q;
              state_q   <= rs_ret_q;
            end else if (sm_busy_q) begin
              state_q <= StRsReq;             // defensive: retry
            end else begin
              // miss: FILL streams the module's parked pCode from
              // ObjPay through the shmod scanner into an LRU slot
              sm_op_q  <= APU_SH_SM_FILL;
              sm_pin_q <= 1'b1;
              sm_chk_q <= rs_cw_q[31:16];
              sm_nw_q  <= rs_cw_q[15:0];
              sm_ret_q <= StRsFillC;
              state_q  <= StSmReq;
            end
          end
          StRsFillC: begin
            if (sm_ok_q) begin
              rs_slot_q <= sm_rslot_q;
              state_q   <= rs_ret_q;
            end else if (sm_busy_q) begin
              // every slot pinned: free completed-work pins, then
              // retry — in-flight works release theirs as their done
              // pulses land in the pending-UNPIN ring
              unp_ret_q <= StRsReq;
              state_q   <= StUnpD;
            end else begin
              rs_fault_q <= 1'b1;
              state_q    <= rs_ret_q;
            end
          end
          StUnpD: begin
            if (unp_src_q) begin
              // rec_pin_q holds a bundle taken by a record that never
              // issued work (fill fault or lost submit): release its
              // slots here — it never enters the queue
              if (rec_pin_q == 8'h0) begin
                unp_src_q <= 1'b0;
                unp_ph_q  <= 1'b0;
                state_q   <= unp_ret_q;
              end else if (rec_pin_q[3]) begin
                sm_op_q        <= APU_SH_SM_UNPIN;
                sm_pin_q       <= 1'b0;
                sm_slot_q      <= rec_pin_q[2:0];
                rec_pin_q[3:0] <= 4'h0;
                sm_ret_q       <= StUnpD;
                state_q        <= StSmReq;
              end else begin
                sm_op_q        <= APU_SH_SM_UNPIN;
                sm_pin_q       <= 1'b0;
                sm_slot_q      <= rec_pin_q[6:4];
                rec_pin_q[7:4] <= 4'h0;
                sm_ret_q       <= StUnpD;
                state_q        <= StSmReq;
              end
            end else if (unp_h_q == unp_t_q && pinq_due_q == 5'd0) begin
              // due>0 entries still owe a pop — wait for them so a
              // deferred bundle is not left behind
              unp_ph_q <= 1'b0;
              state_q  <= unp_ret_q;
            end else if (unp_h_q != unp_t_q &&
                         unpq_q[unp_h_q[3:0]][3] && !unp_ph_q) begin
              sm_op_q   <= APU_SH_SM_UNPIN;
              sm_pin_q  <= 1'b0;
              sm_slot_q <= unpq_q[unp_h_q[3:0]][2:0];
              unp_ph_q  <= 1'b1;
              sm_ret_q  <= StUnpD;
              state_q   <= StSmReq;
            end else if (unp_h_q != unp_t_q &&
                         unpq_q[unp_h_q[3:0]][7]) begin
              sm_op_q   <= APU_SH_SM_UNPIN;
              sm_pin_q  <= 1'b0;
              sm_slot_q <= unpq_q[unp_h_q[3:0]][6:4];
              unp_ph_q  <= 1'b0;
              unp_h_q   <= unp_h_q + 5'd1;
              sm_ret_q  <= StUnpD;
              state_q   <= StSmReq;
            end else if (unp_h_q != unp_t_q) begin
              unp_ph_q <= 1'b0;
              unp_h_q  <= unp_h_q + 5'd1;
            end
          end
          StSmReq: if (sm_gnt_i) state_q <= StSmCpl;
          StSmCpl: if (sm_cpl_i) begin
            sm_ok_q    <= sm_cpl_pl_i.ok;
            sm_busy_q  <= sm_cpl_pl_i.busy;
            sm_rslot_q <= sm_cpl_pl_i.slot;
            sm_flt_q   <= sm_cpl_pl_i.fault.code;
            state_q    <= sm_ret_q;
// pragma translate_off
            if ($test$plusargs("smtrace"))
              $display("[sm t=%0d] op=%0d hnd=%08x slot=%0d ok=%0d busy=%0d rslot=%0d flt=%02x",
                       $time, sm_op_q, sm_hnd_q, sm_slot_q,
                       sm_cpl_pl_i.ok, sm_cpl_pl_i.busy,
                       sm_cpl_pl_i.slot, sm_cpl_pl_i.fault.code);
// pragma translate_on
          end
          // one-word ObjPay read of a pipeline module block
          StPBR:  if (op_req_ready_i) state_q <= StPBRC;
          StPBRC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              // a corrupt pipeline block is a submit-level failure
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              pbr_data_q <= op_cpl_i.rdata;
              state_q    <= pbr_ret_q;
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
              // §5a: parked payload base is a 64-word chunk index
              ds_plpay_q <= 32'(ot_cpl_i.entry.aux[63:48]) << 6;
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
              if (ds_set_q == 2'd3)
                state_q <= rec_is_draw ? StDrPay : StDsIssue;
              else                  ds_set_q <= ds_set_q + 2'd1;
            end else begin
              state_q <= StDsSlRd;
            end
          end
          // advance after a resolved/skipped set
          StDsSetCkN: begin
            if (ds_set_q == 2'd3) begin
              state_q <= rec_is_draw ? StDrPay : StDsIssue;
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
              // §5a: parked payload base is a 64-word chunk index
              ds_slo_q <= 32'(ot_cpl_i.entry.aux[63:48]) << 6;
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
                  {5'h0, ot_cpl_i.entry.aux[24:0], 2'b00};
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
          StDsIssue: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] dsissue ctype=%08x rd_vb={b=%08x s=%08x st=%0d} a0v=%0d vs=%0d fs=%0d t=%0t",
                     rec_q.ctype, rd_q.vb_base[0], rd_q.vb_size[0],
                     rd_q.vb_stride[0], rd_q.attr[0].valid,
                     rd_q.vs_slot, rd_q.fs_slot, $time);
`endif
// pragma translate_on
            if (pinq_full && unpq_full) begin
              // both pin rings saturated: drain the UNPIN ring to open
              // room, then retry the issue — never drop a bundle
              unp_ret_q <= StDsIssue;
              unp_ph_q  <= 1'b0;
              state_q   <= StUnpD;
            end else if (work_ready_i && !pinq_full) begin
              // work_done_i pulses are unordered across engines: the
              // next outst_q completions retire older works (a
              // serialized done queue may deliver them cycles after the
              // engine pulse).  Skip them so StDsDone only consumes the
              // done for THIS record's work.
              dsd_skip_q <= outst_q -
                            ((work_done_i && outst_q != 8'h0) ? 8'h1
                                                              : 8'h0);
              state_q <= StDsDone;
            end
          end
          StDsDone: if (work_done_i) begin
            if (dsd_skip_q != 8'h0)
              dsd_skip_q <= dsd_skip_q - 8'h1;
            else
              // §7b exception contract: a faulted work item retires
              // (undefined results) and execution continues with the
              // next record — only a submit-level failure aborts
              state_q <= lost_q ? StUnpReq : StNextBuf;
          end
          StDrain: if (outst_q == 8'h0 ||
                       (outst_q == 8'h1 && work_done_i)) begin
            // §5a G3b-iii: a barrier record may carry an event action
            if (bar_act_q == 2'd1 || bar_act_q == 2'd2) begin
              state_q <= StEvSet;
            end else if (bar_act_q == 2'd3) begin
              wv_i_q   <= '0;
              wv_cyc_q <= '0;
              wv_n_q   <= 16'(rec_q.imm[0]);
              state_q  <= rec_q.imm[0] == 32'h0 ? StNextBuf : StWvRd;
            end else begin
              state_q <= StNextBuf;
            end
          end
          // set/reset: ObjTab SETSTATE on the record's event handle —
          // a dead event between the resolve and the write loses the
          // submission like any stale object
          StEvSet:  if (ot_req_ready_i) state_q <= StEvSetC;
          StEvSetC: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              state_q <= StNextBuf;
            end
          end
          // wait-events: fetch the i-th event handle from the record's
          // ObjPay payload, LOOKUP it, poll state[0] every 64 cycles
          StWvRd:  if (op_req_ready_i) state_q <= StWvRdC;
          StWvRdC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              wv_hnd_q <= op_cpl_i.rdata;
              state_q  <= StWvLk;
            end
          end
          StWvLk:  if (ot_req_ready_i) state_q <= StWvLkC;
          StWvLkC: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              // a dead event handle loses the submission like any
              // stale record-time object
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else if (ot_cpl_i.entry.state[0]) begin
              // event set — advance to the next listed event
              if (wv_i_q + 16'd1 < wv_n_q) begin
                wv_i_q  <= wv_i_q + 16'd1;
                state_q <= StWvRd;
              end else begin
                state_q <= StNextBuf;
              end
            end else begin
              wv_cyc_q <= '0;
              state_q  <= StWvWait;
            end
          end
          StWvWait: begin
            if (wv_cyc_q == 7'd63) begin
              wv_cyc_q <= '0;
              state_q  <= StWvLk;   // re-poll state[0]
            end else begin
              wv_cyc_q <= wv_cyc_q + 7'd1;
            end
          end
          // indirect operand fetch: one aligned 64-bit aperture beat
          // per request; the two halves land as flat stream words and
          // f_iw extracts the command's word w
          StIndRd:  if (mp_req_ready_i) state_q <= StIndRdC;
          StIndRdC: if (mp_rsp_valid_i) begin
            if (mp_rsp_i.err) begin
              // out-of-window aperture read: submission lost, never a
              // silent fabricated operand
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              ind_w_q[{ind_i_q, 1'b0}] <= mp_rsp_i.rdata[31:0];
              ind_w_q[{ind_i_q, 1'b1}] <= mp_rsp_i.rdata[63:32];
`ifdef G6LC_APU_DEBUG
              $display("[ind t=%0d] base=%x i=%0d rd=%x", $time,
                       ind_base_q, ind_i_q, mp_rsp_i.rdata);
`endif
              if (ind_i_q + 3'd1 >= ind_nb_q) begin
                ind_q   <= 1'b0;
                case (rec_q.ctype)
                  APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT: begin
                    rec_q.imm[0] <= f_iw(3'd0);
                    rec_q.imm[1] <= f_iw(3'd1);
                    rec_q.imm[2] <= f_iw(3'd2);
                    desc_q  <= '0;
                    state_q <= StDsPipeReq;
                  end
                  // VkDrawIndirectCommand / VkDrawIndexedIndirect-
                  // Command — the rd_q prelude mirrors the direct
                  // draw arm; the pipeline/attachment guard already
                  // ran before the fetch
                  APU_VN_TYPE_VK_CMD_DRAW_INDIRECT_EXT,
                  APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT: begin
                    desc_q  <= '0;
                    rd_q.op          <= APU_RAST_OP_DRAW;
                    rd_q.ca          <= ca_q;
                    rd_q.ca_valid    <= ca_valid_q;
                    rd_q.da          <= da_q;
                    rd_q.da_valid    <= da_valid_q;
                    rd_q.vp          <= '{x: vp_q[0], y: vp_q[1],
                                          w: vp_q[2], h: vp_q[3],
                                          minz: vp_q[4], maxz: vp_q[5]};
                    rd_q.sc_x        <= sc_q[0][15:0];
                    rd_q.sc_y        <= sc_q[1][15:0];
                    rd_q.sc_w        <= sc_q[2][15:0];
                    rd_q.sc_h        <= sc_q[3][15:0];
                    rd_q.vb_base     <= '0;
                    rd_q.vb_size     <= '0;
                    rd_q.vb_stride   <= '0;
                    rd_q.vb_rate     <= '0;
                    rd_q.attr        <= '0;
                    rd_q.ib_base     <= '0;
                    rd_q.ib_size     <= '0;
                    rd_q.ib_type     <= ind_idx_q ? ib_type_q : 2'd0;
                    rd_q.vertex_count   <= f_iw(3'd0);
                    rd_q.instance_count <= f_iw(3'd1);
                    if (ind_idx_q) begin
                      rd_q.first_vertex   <= '0;
                      rd_q.first_index    <= f_iw(3'd2);
                      rd_q.vertex_offset  <= f_iw(3'd3);
                      rd_q.first_instance <= f_iw(3'd4);
                    end else begin
                      rd_q.first_vertex   <= f_iw(3'd2);
                      rd_q.first_index    <= '0;
                      rd_q.vertex_offset  <= '0;
                      rd_q.first_instance <= f_iw(3'd3);
                    end
                    state_q <= StDsPipeReq;
                  end
                  default: begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end
                endcase
              end else begin
                ind_i_q <= ind_i_q + 3'd1;
                state_q <= StIndRd;
              end
            end
          end
          // ---- §5a G3b-iii: secondary command buffers ---------------
          // the record's payload streams {gen,slot} handle words; each
          // is re-resolved live to its descriptor-block cbd
          StXcFetch: if (op_req_ready_i) state_q <= StXcFetchC;
          StXcFetchC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              xc_hnd_q <= op_cpl_i.rdata;
              state_q  <= StXcLk;
            end
          end
          StXcLk:   if (ot_req_ready_i) state_q <= StXcLkC;
          StXcLkC: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              // the secondary's descriptor block rides its aux[63:32]
              cur_cbd_q <= ot_cpl_i.entry.aux[63:32];
              rec_i_q   <= '0;
              state_q   <= StCntReq;
            end
          end
          // a secondary ran to its count: fetch the next listed
          // secondary, or restore the primary and advance past the
          // ExecuteCommands record — no dynamic-state restore
          StXcPop: begin
            if (sxc_i_q + 16'd1 < sxc_n_q) begin
              sxc_i_q <= sxc_i_q + 16'd1;
              state_q <= StXcFetch;
            end else begin
              cur_cbd_q <= sec_cbd_q;
              rec_i_q   <= sec_ri_q;
              rec_n_q   <= sec_rn_q;
              sec_v_q   <= 1'b0;
              state_q   <= StNextBuf;
            end
          end

          // ---- §12.3 C/5a: Xfer operand assembly ----------------------
          // operand resource -> {bind_mem{gen,slot}, bind_offset,
          // size};
          // §12.3 C/5b: image operands additionally carry the layout
          // vnfront packed into aux={usage,layers,mips,fmt,h,w} and
          // state=layer_bytes>>6
          StXfBufReq: if (ot_req_ready_i) state_q <= StXfBufCpl;
          StXfBufCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.bind_mem[15:0] == APU_OBJTAB_SLOT_NONE ||
                |ot_cpl_i.entry.size[63:32]) begin
              // dead/unbound/over-4 GiB operand: submission lost
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              xf_ms_q  <= ot_cpl_i.entry.bind_mem[15:0];
              // §12.3 3d-d: the bind recorded the memory's generation —
              // a slot recycled under a different memory must fail the
              // operand, never retarget silently
              xf_mg_q  <= ot_cpl_i.entry.bind_mem[31:16];
              xf_bo_q <= ot_cpl_i.entry.bind_offset;
              xf_bs_q <= ot_cpl_i.entry.size;
              // G1c: vertex/index buffer operands carry the recorded
              // bind offset on top of the resource bind_offset
              xf_xoff_q <= xf_for_q == 2'd1 ? vb_off_q[dr_bq[3:0]] :
                           xf_for_q == 2'd2 ? ib_off_q : 32'h0;
              if (xf_for_q == 2'd3) begin
                // attachment image: layout fields land in the
                // attachment-indexed resolve slot (G2a)
                att_img_q[brp_ak_q].w           <=
                    ot_cpl_i.entry.aux[15:0];
                att_img_q[brp_ak_q].h           <=
                    ot_cpl_i.entry.aux[31:16];
                att_img_q[brp_ak_q].fmt         <=
                    ot_cpl_i.entry.aux[39:32];
                att_img_q[brp_ak_q].mips        <=
                    ot_cpl_i.entry.aux[44:40];
                att_img_q[brp_ak_q].layers      <=
                    ot_cpl_i.entry.aux[53:45];
                att_img_q[brp_ak_q].itype       <=
                    ot_cpl_i.entry.state[20:19];
                att_img_q[brp_ak_q].layer_bytes <=
                    {7'h0, ot_cpl_i.entry.state[18:0], 6'h0};
              end else if (xf_op_img) begin
                if (xf_img_sel) begin
                  xf_img1_q.w           <= ot_cpl_i.entry.aux[15:0];
                  xf_img1_q.h           <= ot_cpl_i.entry.aux[31:16];
                  xf_img1_q.fmt         <= ot_cpl_i.entry.aux[39:32];
                  xf_img1_q.mips        <= ot_cpl_i.entry.aux[44:40];
                  xf_img1_q.layers      <= ot_cpl_i.entry.aux[53:45];
                  xf_img1_q.itype       <= ot_cpl_i.entry.state[20:19];
                  xf_img1_q.layer_bytes <=
                      {7'h0, ot_cpl_i.entry.state[18:0], 6'h0};
                end else begin
                  xf_img0_q.w           <= ot_cpl_i.entry.aux[15:0];
                  xf_img0_q.h           <= ot_cpl_i.entry.aux[31:16];
                  xf_img0_q.fmt         <= ot_cpl_i.entry.aux[39:32];
                  xf_img0_q.mips        <= ot_cpl_i.entry.aux[44:40];
                  xf_img0_q.layers      <= ot_cpl_i.entry.aux[53:45];
                  xf_img0_q.itype       <= ot_cpl_i.entry.state[20:19];
                  xf_img0_q.layer_bytes <=
                      {7'h0, ot_cpl_i.entry.state[18:0], 6'h0};
                end
              end
              state_q <= StXfMemReq;
            end
          end
          // bound memory slot -> aperture page base (aux[63:32])
          StXfMemReq: if (ot_req_ready_i) state_q <= StXfMemCpl;
          StXfMemCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK ||
                ot_cpl_i.entry.kind != 6'(APU_VN_KIND_VK_DEVICE_MEMORY) ||
                |ot_cpl_i.entry.size[63:32] ||
                // §12.3 3d-d: the bound memory's generation must still
                // be the one the bind recorded (recycled slot -> lost)
                ot_cpl_i.entry.gen != xf_mg_q ||
                // §12.3 C: an unbacked (lazy type-1, not yet MAP_BLOB'd)
                // memory has no aperture base — the transfer fails
                // truthfully, never silently to a fabricaed offset
                ot_cpl_i.entry.aux[63:32] == APU_MEM_UNBACKED ||
                xf_bo_q > ot_cpl_i.entry.size) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              // operand extent = min(res.size, memory.size -
              // bind_offset) — the same defence-in-depth clamp the
              // dispatch path applies; all values are < 4 GiB here
              automatic logic [63:0] rem_m =
                  ot_cpl_i.entry.size - xf_bo_q;
              automatic logic [31:0] xs =
                  xf_bs_q < rem_m ? xf_bs_q[31:0] : rem_m[31:0];
              automatic logic [31:0] xb =
                  ot_cpl_i.entry.aux[63:32] + xf_bo_q[31:0];
              if (ind_q) begin
                // §5a G3b-iii: the bound buffer's resolved aperture
                // base carries the record's u64 offset (imm[2:3]);
                // the operand must fit inside the operand extent —
                // else the submission is lost, never a silent fetch
                automatic logic [4:0]  lenb =
                    ind_idx_q ? 5'd20 :
                    rec_q.ctype ==
                        32'(APU_VN_TYPE_VK_CMD_DRAW_INDIRECT_EXT)
                        ? 5'd16 : 5'd12;
                automatic logic [63:0] ib =
                    64'(xb) + {32'h0, rec_q.imm[2]};
                if (rec_q.imm[2] > xs ||
                    xs - rec_q.imm[2] < 32'(lenb)) begin
                  lost_q  <= 1'b1;
                  state_q <= StUnpReq;
                end else begin
                  ind_base_q <= ib;
                  ind_nb_q   <= 3'((32'(lenb) +
                                    (ib[2] ? 32'd4 : 32'd0) + 7) >> 3);
                  ind_i_q    <= '0;
                  state_q    <= StIndRd;
                end
              end else if (xf_for_q == 2'd1) begin
                // G1c: bound vertex buffer — aperture base += the
                // recorded bind offset; effective bytes shrink alike
                rd_q.vb_base[dr_bq[3:0]] <= xb + xf_xoff_q;
                rd_q.vb_size[dr_bq[3:0]] <= xs > xf_xoff_q
                                       ? xs - xf_xoff_q : 32'h0;
                dr_bq   <= dr_bq + 5'd1;
                state_q <= StDrVbN;
              end else if (xf_for_q == 2'd2) begin
                // G1c: bound index buffer
                rd_q.ib_base <= xb + xf_xoff_q;
                rd_q.ib_size <= xs > xf_xoff_q
                                ? xs - xf_xoff_q : 32'h0;
                state_q <= StDsIssue;
              end else if (xf_for_q == 2'd3) begin
                // G2a: attachment image resolved — base/size land in
                // the indexed slot, then the next attachment's view
                // resolves; the CLEAR-issue loop runs after all views
                att_img_q[brp_ak_q].base <= xb;
                att_img_q[brp_ak_q].size <= xs;
                if (brp_ak_q + 3'd1 < brp_att_q) begin
                  brp_ak_q <= brp_ak_q + 3'd1;
                  state_q  <= StBrpVwLo;
                end else begin
                  brp_ak_q <= '0;
                  state_q  <= StBrpClrN;
                end
              end else if (xf_op_img) begin
                if (xf_img_sel) begin
                  xf_img1_q.base <= xb;
                  xf_img1_q.size <= xs;
                end else begin
                  xf_img0_q.base <= xb;
                  xf_img0_q.size <= xs;
                end
                if (xf_two_ops && xf_opnd_q == 2'd0) begin
                  xf_opnd_q <= 2'd1;
                  state_q   <= StXfBufReq;
                end else begin
                  state_q <= StWork;
                end
              end else if (xf_two_ops && xf_opnd_q == 2'd0 &&
                           rec_q.ctype ==
                           32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT)) begin
                xf_src_base_q <= xb;
                xf_src_size_q <= xs;
                xf_opnd_q     <= 2'd1;
                state_q       <= StXfBufReq;
              end else begin
                // single-operand records land their buffer in dst; a
                // B2I source buffer / I2B destination buffer lands in
                // src/dst respectively per the op direction
                if (rec_q.ctype ==
                    32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT)) begin
                  xf_src_base_q <= xb;
                  xf_src_size_q <= xs;
                end else begin
                  xf_dst_base_q <= xb;
                  xf_dst_size_q <= xs;
                end
                if (xf_two_ops && xf_opnd_q == 2'd0) begin
                  xf_opnd_q <= 2'd1;
                  state_q   <= StXfBufReq;
                end else begin
                  state_q <= StWork;
                end
              end
            end
          end

          // ---- G1c/G2a: BeginRenderPass attachment resolve -----------
          // rp LOOKUP -> ObjPay parse (attachment table, subpass
          // colour/depth refs) -> fb LOOKUP -> per-attachment view id
          // -> view LOOKUP -> shared image operand resolver
          // (xf_for=IMG) -> per-attachment CLEAR issues -> ca/da snap
          StBrpRpReq: if (ot_req_ready_i) state_q <= StBrpRpCpl;
          StBrpRpCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              // §5a: parked payload base is a 64-word chunk index
              brp_rpay_q <= 32'(ot_cpl_i.entry.aux[63:48]) << 6;
              brp_rpw_q  <= ot_cpl_i.entry.aux[47:32];
              brp_pi_q   <= '0;
              brp_ph_q   <= '0;
              state_q    <= StBrpPayReq;
            end
          end
          StBrpPayReq: if (op_req_ready_i) state_q <= StBrpPayCpl;
          StBrpPayCpl: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              brp_pi_q <= brp_pi_q + 5'd1;
              state_q  <= StBrpPayReq;
              unique case (brp_ph_q)
                3'd0: begin
                  // attachmentCount — v1: 1..5 (4 colour + 1 depth)
                  if (op_cpl_i.rdata == 32'd0 ||
                      op_cpl_i.rdata > 32'd5) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else begin
                    brp_att_q <= 3'(op_cpl_i.rdata);
                    brp_ak_q  <= '0;
                    brp_ai_q  <= '0;
                    brp_ph_q  <= 3'd1;
                  end
                end
                3'd1: begin
                  // {format, loadOp, storeOp} per attachment — only
                  // loadOp is consumed (format/usage were validated
                  // at image+view creation)
                  if (brp_ai_q == 2'd1)
                    att_ld_q[brp_ak_q] <= op_cpl_i.rdata[1:0];
                  if (brp_ai_q == 2'd2) begin
                    brp_ai_q <= '0;
                    brp_ak_q <= brp_ak_q + 3'd1;
                    if (brp_ak_q + 3'd1 >= brp_att_q) begin
                      brp_ph_q <= 3'd2;
                      brp_cj_q <= '0;
                    end
                  end else begin
                    brp_ai_q <= brp_ai_q + 2'd1;
                  end
                end
                3'd2: begin
                  // subpassCount — v1 draws use subpass 0 only
                  if (op_cpl_i.rdata != 32'd1) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else begin
                    brp_ph_q <= 3'd3;
                  end
                end
                3'd3: begin
                  // subpass colorAttachmentCount (0..4)
                  if (op_cpl_i.rdata > 32'd4) begin
                    lost_q  <= 1'b1;
                    state_q <= StUnpReq;
                  end else begin
                    brp_ncl_q <= 3'(op_cpl_i.rdata);
                    if (op_cpl_i.rdata == 32'd0) begin
                      // no colour refs — straight to the depth check
                      if (32'(brp_pi_q + 5'd1) < {16'h0, brp_rpw_q})
                        brp_ph_q <= 3'd5;
                      else begin
                        brp_dref_q <= 4'hF;
                        brp_ak_q   <= '0;
                        state_q    <= StBrpFbReq;
                      end
                    end else begin
                      brp_ph_q <= 3'd4;
                    end
                  end
                end
                3'd4: begin
                  // pColorAttachments[j].attachment (F = UNUSED)
                  brp_cref_q[brp_cj_q[1:0]] <=
                      op_cpl_i.rdata == 32'hFFFF_FFFF
                      ? 4'hF : op_cpl_i.rdata[3:0];
                  if (brp_cj_q + 2'd1 >= {1'b0, brp_ncl_q}) begin
                    if (32'(brp_pi_q + 5'd1) < {16'h0, brp_rpw_q}) begin
                      brp_ph_q <= 3'd5;
                    end else begin
                      brp_dref_q <= 4'hF;
                      brp_ak_q   <= '0;
                      state_q    <= StBrpFbReq;
                    end
                  end else begin
                    brp_cj_q <= brp_cj_q + 2'd1;
                  end
                end
                default: begin
                  // pDepthStencilAttachment.attachment (F = UNUSED);
                  // the next word (if any) is unused preserve data
                  brp_dref_q <= op_cpl_i.rdata == 32'hFFFF_FFFF
                                ? 4'hF : op_cpl_i.rdata[3:0];
                  brp_ak_q   <= '0;
                  state_q    <= StBrpFbReq;
                end
              endcase
            end
          end
          StBrpFbReq: if (ot_req_ready_i) state_q <= StBrpFbCpl;
          StBrpFbCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              // §5a: parked payload base is a 64-word chunk index
              brp_fpay_q <= 32'(ot_cpl_i.entry.aux[63:48]) << 6;
              brp_ak_q   <= '0;
              state_q    <= StBrpVwLo;
            end
          end
          StBrpVwLo:  if (op_req_ready_i) state_q <= StBrpVwLoC;
          StBrpVwLoC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              brp_viewid_q[31:0] <= op_cpl_i.rdata;
              state_q            <= StBrpVwHi;
            end
          end
          StBrpVwHi:  if (op_req_ready_i) state_q <= StBrpVwHiC;
          StBrpVwHiC: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              brp_viewid_q[63:32] <= op_cpl_i.rdata;
              state_q             <= StBrpVwReq;
            end
          end
          StBrpVwReq: if (ot_req_ready_i) state_q <= StBrpVwCpl;
          StBrpVwCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              // view aux[15:0] = the image's ObjTab slot; the shared
              // resolver takes it from there (bind_mem -> memory base)
              brp_islot_q <= ot_cpl_i.entry.aux[15:0];
              xf_for_q    <= 2'd3;
              state_q     <= StXfBufReq;
            end
          end
          // internal render-pass clear work: one issued work item per
          // loadOp-CLEAR attachment
          StBrpIssue: if (pinq_full && unpq_full) begin
            // both pin rings saturated: drain the UNPIN ring to open
            // room, then retry the issue — never drop a bundle
            unp_ret_q <= StBrpIssue;
            unp_ph_q  <= 1'b0;
            state_q   <= StUnpD;
          end else if (work_ready_i && !pinq_full) begin
            outst_q <= outst_q + 8'h1 -
                       ((work_done_i && outst_q != 8'h0) ? 8'h1 : 8'h0);
            brp_ak_q <= brp_ak_q + 3'd1;
            state_q  <= StBrpClrN;
          end
          // G2a: per-attachment CLEAR issue, then the subpass
          // attachment snapshot — subpass colour refs land at
          // ca[location] (v1 identity mapping); a malformed ref loses
          // the submission like a dead object
          StBrpClrN: begin
            if (brp_ak_q >= brp_att_q) begin
              ca_q       <= '0;
              ca_valid_q <= '0;
              da_q       <= '0;
              da_valid_q <= 1'b0;
              for (int l = 0; l < 4; l++)
                if (3'(l) < brp_ncl_q && brp_cref_q[l] != 4'hF) begin
                  if (brp_cref_q[l] < 4'(brp_att_q)) begin
                    ca_q[l]       <= att_img_q[brp_cref_q[l]];
                    ca_valid_q[l] <= 1'b1;
                  end else begin
                    lost_q <= 1'b1;
                  end
                end
              if (brp_dref_q != 4'hF) begin
                if (brp_dref_q < 4'(brp_att_q)) begin
                  da_q       <= att_img_q[brp_dref_q];
                  da_valid_q <= 1'b1;
                end else begin
                  lost_q <= 1'b1;
                end
              end
              state_q <= StNextBuf;
            end else if (att_ld_q[brp_ak_q] == 2'd1) begin
              // loadOp CLEAR — one rast CLEAR work per attachment:
              // the subpass's depth ref clears through da and
              // clear_color[0]; a colour attachment clears through
              // ca[0] and the vec4 clear_color
              rd_q.op          <= APU_RAST_OP_CLEAR;
              rd_q.ca          <= '0;
              rd_q.ca_valid    <= '0;
              rd_q.da          <= '0;
              rd_q.da_valid    <= 1'b0;
              rd_q.clear_color <= '0;
              if ({1'b0, brp_dref_q} == {1'b0, brp_ak_q}) begin
                rd_q.da             <= att_img_q[brp_ak_q];
                rd_q.da_valid       <= 1'b1;
                rd_q.clear_color[0] <= clearv_q[{brp_ak_q, 2'b00}];
              end else begin
                rd_q.ca[0]       <= att_img_q[brp_ak_q];
                rd_q.ca_valid[0] <= 1'b1;
                rd_q.clear_color <=
                    {clearv_q[{brp_ak_q, 2'b00} + 5'd3],
                     clearv_q[{brp_ak_q, 2'b00} + 5'd2],
                     clearv_q[{brp_ak_q, 2'b00} + 5'd1],
                     clearv_q[{brp_ak_q, 2'b00}]};
              end
              state_q <= StBrpIssue;
            end else begin
              brp_ak_q <= brp_ak_q + 3'd1;
              state_q  <= StBrpClrN;
            end
          end

          // ---- G1c/G2a: draw assembly tail -----------------------------
          // 44-word graphics-pipeline ObjPay block -> rd_q
          StDrPay:  if (op_req_ready_i) state_q <= StDrPayCpl;
          StDrPayCpl: if (op_cpl_valid_i) begin
            if (op_cpl_i.status != APU_OBJPAY_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              case (dr_pi_q)
                6'd0: begin
                  rd_q.fs_in_mask <= op_cpl_i.rdata[31:24];
                  rd_q.topology   <= op_cpl_i.rdata[23:16];
                  rd_q.cull       <= op_cpl_i.rdata[3:2];
                  rd_q.front_ccw  <= op_cpl_i.rdata[1];
                  rd_q.fs_fdepth  <= op_cpl_i.rdata[5];
                  rd_q.fs_late    <= op_cpl_i.rdata[4];
                end
                6'd1, 6'd2, 6'd3, 6'd4, 6'd5, 6'd6, 6'd7, 6'd8,
                6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15,
                6'd16: begin
                  // key by the description's Vk binding number — rast
                  // selects vb_* with attr.binding, not the table index.
                  // Invalid entries carry binding 0 — they must not
                  // clobber a valid entry that already claimed it
                  if (op_cpl_i.rdata[20]) begin
                    dr_vbmask_q[op_cpl_i.rdata[19:16]] <= 1'b1;
                    rd_q.vb_stride[op_cpl_i.rdata[19:16]] <=
                        op_cpl_i.rdata[15:0];
                    // G2a: binding word bit 21 = inputRate INSTANCE
                    rd_q.vb_rate[op_cpl_i.rdata[19:16]] <=
                        op_cpl_i.rdata[21];
                  end
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
                  $display("[DBG] gpaybind i=%0d rd=%08x idx=%0d t=%0t",
                           dr_pi_q, op_cpl_i.rdata, op_cpl_i.rdata[19:16],
                           $time);
`endif
// pragma translate_on
                end
                6'd17, 6'd18, 6'd19, 6'd20,
                6'd21, 6'd22, 6'd23, 6'd24: begin
                  rd_q.attr[3'(dr_pi_q - 6'd17)].valid   <=
                      op_cpl_i.rdata[31];
                  rd_q.attr[3'(dr_pi_q - 6'd17)].loc     <=
                      op_cpl_i.rdata[26:24];
                  rd_q.attr[3'(dr_pi_q - 6'd17)].binding <=
                      op_cpl_i.rdata[23:20];
                  rd_q.attr[3'(dr_pi_q - 6'd17)].fmt     <=
                      op_cpl_i.rdata[19:12];
                  rd_q.attr[3'(dr_pi_q - 6'd17)].offset  <=
                      op_cpl_i.rdata[11:0];
                end
                6'd25: begin
                  // G2a: depth state + dynamic-blend-constants flag +
                  // w25[17:16] static-viewport/scissor flags
                  rd_q.depth_test  <= op_cpl_i.rdata[0];
                  rd_q.depth_write <= op_cpl_i.rdata[1];
                  rd_q.depth_op    <= op_cpl_i.rdata[6:4];
                  dr_bcdyn_q       <= op_cpl_i.rdata[2];
                  dr_vpsta_q       <= op_cpl_i.rdata[16];
                  dr_scsta_q       <= op_cpl_i.rdata[17];
                end
                6'd26, 6'd27, 6'd28, 6'd29: begin
                  // per-attachment blend state, apu_rast_blend_t layout
                  rd_q.blend[2'(dr_pi_q - 6'd26)] <=
                      apu_rast_blend_t'(op_cpl_i.rdata);
                end
                6'd30, 6'd31, 6'd32, 6'd33: begin
                  // w30..33: static blendConstants (dynamic ones are
                  // overlaid from bconst_q at the walk's end)
                  if (!dr_bcdyn_q)
                    rd_q.blend_const[2'(dr_pi_q - 6'd30)] <=
                        op_cpl_i.rdata;
                end
                6'd34, 6'd35, 6'd36, 6'd37, 6'd38, 6'd39:
                  // w34..39: baked static VkViewport f32[6]
                  dr_vp_q[3'(dr_pi_q - 6'd34)] <= op_cpl_i.rdata;
                default:
                  // w40..43: baked static VkRect2D i32[4]
                  dr_sc_q[2'(dr_pi_q - 6'd40)] <= op_cpl_i.rdata;
              endcase
              dr_pi_q <= dr_pi_q + 6'd1;
              if (dr_pi_q == 6'd43) begin
                if (dr_bcdyn_q) rd_q.blend_const <= bconst_q;
                // static-state override: the pipeline baked viewport /
                // scissor at create time (no matching dynamic state),
                // so its ObjPay words replace the streamed shadows
                if (dr_vpsta_q)
                  rd_q.vp <= '{x: dr_vp_q[0], y: dr_vp_q[1],
                               w: dr_vp_q[2], h: dr_vp_q[3],
                               minz: dr_vp_q[4], maxz: dr_vp_q[5]};
                if (dr_scsta_q) begin
                  rd_q.sc_x <= dr_sc_q[0][15:0];
                  rd_q.sc_y <= dr_sc_q[1][15:0];
                  rd_q.sc_w <= dr_sc_q[2][15:0];
                  // w43 lands this same completion — bypass the just-
                  // written dr_sc_q[3] which still reads its old value
                  rd_q.sc_h <= op_cpl_i.rdata[15:0];
                end
                dr_bq   <= '0;
                state_q <= StDrVbN;
              end else begin
                state_q <= StDrPay;
              end
            end
          end
          // next valid vertex binding -> shared buffer resolver
          StDrVbN: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] drvb n bq=%0d mask=%04x vbh=%08x stride0=%0d t=%0t",
                     dr_bq, dr_vbmask_q, vb_hnd_q[dr_bq[3:0]],
                     rd_q.vb_stride[0], $time);
`endif
// pragma translate_on
            if (dr_bq == 5'd16) begin
              state_q <= StDrIbN;
            end else if (dr_vbmask_q[dr_bq[3:0]] &&
                         vb_hnd_q[dr_bq[3:0]] != 32'h0) begin
              xf_for_q <= 2'd1;
              state_q  <= StXfBufReq;
            end else begin
              dr_bq   <= dr_bq + 5'd1;
              state_q <= StDrVbN;
            end
          end
          StDrIbN: begin
            if ((rec_q.ctype ==
                     32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT) ||
                 rec_q.ctype ==
                     32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT)) &&
                ib_hnd_q != 32'h0) begin
              xf_for_q <= 2'd2;
              state_q  <= StXfBufReq;
            end else begin
              state_q <= StDsIssue;
            end
          end

          // ---- next record / buffer -----------------------------------
          StNextBuf: begin
            if (rec_i_q + 16'h1 < rec_n_q) begin
              rec_i_q <= rec_i_q + 16'h1;
              state_q <= StRdReq;
            end else if (sec_v_q) begin
              // §5a G3b-iii: the running secondary hit its count —
              // return to the suspended primary or the next listed
              // secondary
              state_q <= StXcPop;
            end else begin
              state_q <= StUnpReq;
            end
          end
          StUnpReq: begin
            if (rec_pin_q != 8'h0) begin
              // a record abandoned mid-walk (lost submit) may still
              // hold module pins — its work never issued so the
              // bundle never reached pinq; release before the
              // buffer's own UNPIN
              unp_src_q <= 1'b1;
              unp_ph_q  <= 1'b0;
              unp_ret_q <= StUnpReq;
              state_q   <= StUnpD;
            end else if (!pinned_q[buf_i_q[1:0]]) begin
              state_q <= StBufDone;      // nothing pinned: skip UNPIN
            end else if (ot_req_ready_i) begin
              state_q <= StUnpCpl;
            end
          end
          StUnpCpl: if (ot_cpl_valid_i) state_q <= StBufDone;
          StBufDone: begin
            if (unp_h_q != unp_t_q) begin
              // G3b-ii: release residency pins of completed works
              // before the next buffer — pins must not outlive the
              // works that took them
              unp_ret_q <= StBufDone;
              state_q   <= StUnpD;
            end else if (buf_i_q + 3'd1 < {2'b0, cur_q.nbufs}) begin
              buf_i_q   <= buf_i_q + 3'd1;
              cur_cbd_q <= cur_q.crec[buf_i_q + 3'd1];
              rec_i_q   <= '0;
              state_q   <= StCntReq;
            end else begin
              state_q <= StFinalDrain;
            end
          end
          // a submit is complete when all its issued work is done
          StFinalDrain: begin
            if (outst_q == 8'h0 ||
                (outst_q == 8'h1 && work_done_i)) begin
              buf_i_q <= '0;
              // G3b-ii: the last works can complete inside the drain —
              // their pin bundles landed in the UNPIN ring and must
              // drain before the submission completes, else a pinned
              // slot outlives the submit and a later module-create FILL
              // can starve forever on an all-pinned victim set
              unp_ph_q  <= 1'b0;
              unp_ret_q <= StCbRes;
              state_q   <= StUnpD;
            end
          end

          // restore each command buffer's EXECUTABLE bit (PENDING was
          // set at submit); a dead slot answers MISS — harmless, the
          // object is gone anyway
          StCbRes: begin
            if (buf_i_q >= {2'b0, cur_q.nbufs}) begin
              state_q <= StDone;
            end else if (ot_req_ready_i) begin
              state_q <= StCbResCpl;
            end
          end
          StCbResCpl: if (ot_cpl_valid_i) begin
            buf_i_q <= buf_i_q + 3'd1;
            state_q <= StCbRes;
          end

          StDone: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] subdone fidx=%0d lost=%0d seq=%0d t=%0t",
                     cur_q.fence_idx, lost_q, done_seq_q, $time);
`endif
// pragma translate_on
            done_seq_q <= done_seq_q + 16'h1;
            // a submission that ended mid-secondary (lost) clears the
            // stack — the next submission must not pop into it
            sec_v_q <= 1'b0;
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

// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
    // debug probe: report the record/state that loses a submission and
    // any non-OK work completion (temporary G1c bring-up aid)
    logic        dbg_lost_q;
    logic [7:0]  dbg_state_q;
    logic [31:0] dbg_ctype_q;
    logic [7:0]  dbg_otst_q;
    logic [31:0] dbg_othnd_q, dbg_otrid_q;
    logic [63:0] dbg_otaux_q;
    logic [2:0]  dbg_hi_q;
    always_ff @(posedge clk_i) begin
      if (lost_q && !dbg_lost_q)
        $display("[DBG] cmdexec lost: state=%0d ctype=%08x wdcode=%0d otst=%0d othnd=%08x otid=%08x otaux=%016x hi=%0d t=%0t",
                 dbg_state_q, dbg_ctype_q, work_done_pl_i.code,
                 dbg_otst_q, dbg_othnd_q, dbg_otrid_q, dbg_otaux_q,
                 dbg_hi_q, $time);
      if (work_done_i && work_done_pl_i.code != 8'(APU_SH_DONE_OK))
        $display("[DBG] cmdexec work fault: code=%0d outst=%0d wid=%08x t=%0t",
                 work_done_pl_i.code, outst_q, work_done_pl_i.work_id, $time);
      if (work_valid_o && work_ready_i)
        $display("[DBG] cmdexec work issue: ctype=%08x rdop=%0d cafmt=%0d cawh=%0dx%0d outst=%0d t=%0t",
                 work_o.ctype, rd_q.op, rd_q.ca[0].fmt, rd_q.ca[0].w,
                 rd_q.ca[0].h,
                 outst_q, $time);
      if (state_q == StDsPipeCpl && ot_cpl_valid_i)
        $display("[DBG] pipecpl: status=%0d kind=%0d aux=%016x phnd=%08x chnd=%08x t=%0t",
                 ot_cpl_i.status, ot_cpl_i.entry.kind, ot_cpl_i.entry.aux,
                 snap_q.pipeline, ot_cpl_i.handle,
                 $time);
      if (state_q == StDrPayCpl && op_cpl_valid_i)
        $display("[DBG] gpay[%0d] = %08x (gpay=%04x) t=%0t",
                 dr_pi_q, op_cpl_i.rdata, rd_gpay_q, $time);
      if (state_q == StBrpPayCpl && op_cpl_valid_i)
        $display("[DBG] rp loadOp=%08x rpay=%04x t=%0t",
                 op_cpl_i.rdata, brp_rpay_q, $time);
      if ((state_q == StBrpVwLoC || state_q == StBrpVwHiC) &&
          op_cpl_valid_i)
        $display("[DBG] fb viewid rd st=%0d = %08x (fpay=%04x) t=%0t",
                 state_q, op_cpl_i.rdata, brp_fpay_q, $time);
      dbg_lost_q  <= lost_q;
      dbg_state_q <= 8'(state_q);
      dbg_ctype_q <= rec_q.ctype;
      dbg_otst_q  <= ot_cpl_i.status;
      dbg_othnd_q <= ot_cpl_i.handle;
      dbg_otrid_q <= ot_req_o.id[31:0];
      dbg_otaux_q <= ot_cpl_i.entry.aux;
      dbg_hi_q    <= h_i_q;
    end
`endif
// pragma translate_on
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
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_mp_pkg::*;
#(parameter bit Enable = 1'b0,
  parameter int unsigned Fences = 16,
  parameter int unsigned WorkBudgetLog2 = 30,
  parameter int unsigned FaultCtxs = 32) (
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
  output logic               sm_req_o,
  output apu_sh_sm_req_t     sm_req_pl_o,
  input  logic               sm_gnt_i,
  input  logic               sm_cpl_i,
  input  apu_sh_sm_cpl_t     sm_cpl_pl_i,
  output logic               mp_req_valid_o,
  input  logic               mp_req_ready_i,
  output apu_mp_req_t        mp_req_o,
  input  logic               mp_rsp_valid_i,
  input  apu_mp_rsp_t        mp_rsp_i,
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
  input  logic [Fences-1:0]  fence_fail_i,
  output apu_xfer_desc_t     xf_o,
  output apu_rast_draw_t     rd_o,
  input  logic               hold_i,
  output logic               idle_o,
  output logic               devlost_valid_o,
  output logic [7:0]         devlost_ctx_o,
  output logic               dead_o,
  output logic               busy_o
);
  g6lc_apu_cmdexec #(.Enable(Enable), .Fences(Fences),
                     .WorkBudgetLog2(WorkBudgetLog2),
                     .FaultCtxs(FaultCtxs)) i_dut (.*);
endmodule
