// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Venus transport composition (§6b of
// architecture/uncore/apu-vulkan-engine.md): vgctl control-queue
// processor -> vnpump ring pump -> vnfront, over a shared ObjTab,
// CmdRec and CmdExec, plus the used-publication path.
//
// §6c: all three memory consumers (vgctl control path, vnpump
// aperture/execbuffer lanes, ShaderCore LSU) issue on separate apu_mp
// requester ports — hold-valid-until-ready, one response per request,
// writes included.  Used-ring publication moved out of this module
// into g6lc_apu_vqwalk: vgtop reports a chain completion on
// cpl_valid_o/cpl_len_o, held until cpl_ready_i, and the walker owns
// the used-ring geometry and ordering.
//
// ObjTab arbitration: three requesters — pump (incl. vnfront), the
// vgctl control path, and cmdexec (submit PIN / completion UNPIN /
// stale-handle re-resolve).  Fixed priority pump > cmdexec > vgctl >
// debug; the grant is held until the completion is consumed.
// CmdRec arbitration: pump (front recording ops) > cmdexec (record
// reads), same grant scheme.
//
// Timing impact: arbitration adds no pipeline stages; the mp request
// structs are a static select from each engine's held outputs.
//
// Review checklist: async active-low reset; no latches; Enable=0
// elaborates no datapath.  The debug ObjTab port is for TB teardown
// checks (RESET_CTX count); it is only granted while every engine is
// idle.

module g6lc_apu_vgtop
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Rings  = 64,
  parameter int unsigned Fences = 16,
  // ring ALIVE watchdog refresh period: 2**AliveTickLog2 cycles
  parameter int unsigned AliveTickLog2 = 20,
  // §7b exception contract: cmdexec per-work-item watchdog —
  // 2**WorkBudgetLog2 cycles without issue/completion progress while
  // work is outstanding declares the device dead (ring FATAL)
  parameter int unsigned WorkBudgetLog2 = 30,
  // cmdrec record-payload arena per command buffer, in 32-bit
  // words.  The 256-word default overflowed on
  // vkCmdCopyBufferToImage of a 4-layer mipmapped array image —
  // 448 words of copy regions (dEQP texture.*_sampler2darray_*)
  // hit PAY_FULL, the command buffer went INVALID and the guest
  // hung waiting on a fence the failed submit never posted.
  parameter int unsigned CrPayWords = 1024,
  // §5a G3b-i ObjTab-V/ObjPay-V: entry table + payload arena in
  // objmem (the static carve above the managed window)
  parameter int unsigned ObjEntries    = 65536,
  parameter int unsigned ObjMaxCtx     = 32,
  parameter int unsigned PayMemBytes   = 16 * 1024 * 1024,
  parameter int unsigned DirCacheSets  = 256,
  parameter int unsigned EntCacheLines = 64,
  parameter int unsigned PayCacheLines = 32,
  // §7b/5a-ii: aperture page allocator + ShaderCore geometry
  parameter int unsigned VgPages      = APU_VG_PAGES,
  parameter int unsigned VgPageBytes  = APU_VG_PAGE_BYTES,
  // §12.3 F5: pages below VgGuestPages are the guest-mappable window;
  // [VgGuestPages, VgPages) is the device-private arena
  parameter int unsigned VgGuestPages = APU_VG_GUEST_PAGES,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000,
  // §12.3 C/5a: the Xfer engine derives its internal DMA view from this
  parameter g6lc_apu_cfg_pkg::apu_cfg_t ApuCfg = g6lc_apu_cfg_pkg::ApuVenus
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  // one descriptor chain (the virtqueue walker drives this)
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [15:0]     chain_id_i,      // avail element id -> used elem
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  // chain completion to the walker (it owns used-ring publication):
  // cpl_valid_o is held until cpl_ready_i, so a consumer not yet in
  // its wait state cannot miss the completion
  output logic            cpl_valid_o,     // held until cpl_ready_i
  input  logic            cpl_ready_i,
  output logic [31:0]     cpl_len_o,       // truthful used len
  // shared memory ports (§6c apu_mp handshake): [0]=CTL (vgctl,
  // guest), [1]=PUMP (vnpump, aperture+guest), [2]=SH (shader LSU,
  // aperture), [3]=RAST (raster gather/record/ROP, aperture),
  // [4]=OBJ (objmem: ObjTab/ObjPay backing, aperture) — mapped onto
  // APU_MP_{CTL,PUMP,SH,RAST,OBJ} by vgsys.
  // Requests hold until mp_req_ready_i; one mp_rsp_valid_i
  // returns per accepted request, writes included.
  output logic [4:0]         mp_req_valid_o,
  input  logic [4:0]         mp_req_ready_i,
  output apu_mp_req_t [4:0]  mp_req_o,
  input  logic [4:0]         mp_rsp_valid_i,
  input  apu_mp_rsp_t [4:0]  mp_rsp_i,
  // command-executor work port (TB work sink; dispatch-class records
  // are consumed internally by the ShaderCore, §7b/5a-ii; Xfer-class
  // records — CopyBuffer/FillBuffer/UpdateBuffer — go to the xfer
  // engine, §12.3 C/5a)
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  // §5a: Xfer engine — checked-DMA AXI master (joined with apmem by
  // g6lc_apu_tdma in vgsys), aperture base for mapping construction,
  // engine reset drain, and a non-idle indication
  output g6lc_apu_bus_pkg::apu_dma_axi_req_t  xf_axi_req_o,
  input  g6lc_apu_bus_pkg::apu_dma_axi_resp_t xf_axi_rsp_i,
  input  logic [63:0]      ap_base_i,
  input  logic             xf_flush_i,
  output logic             xfer_busy_o,
  // completion + idle observability
  output logic            done_o,          // pulse at chain completion
  output logic            busy_o,          // any engine busy
  output logic            mem_fault_o,     // sticky engine write fault
                                           // (clears with the engine
                                           // reset, §6c bullet 5)
  output logic            fence_pulse_o,
  output logic [63:0]     fence_id_o,
  output logic [7:0]      fence_ring_o,
  output logic [Rings-1:0]       ring_active_o,
  output logic [Rings-1:0][31:0] ring_status_o,
  output logic [Rings-1:0][31:0] ring_head_o,
  output logic [Rings-1:0][APU_VG_AP_WORD_W-1:0] ring_extra_w_o,
  output logic [15:0]     objtab_live_o,
  // debug ObjTab pass-through (granted only when engines are idle)
  input  logic            dbg_ot_valid_i,
  output logic            dbg_ot_ready_o,
  input  apu_objtab_req_t dbg_ot_req_i,
  output logic            dbg_ot_cpl_valid_o,
  input  logic            dbg_ot_cpl_ready_i,
  output apu_objtab_cpl_t dbg_ot_cpl_o
);
  if (!Enable) begin : gen_off
    assign chain_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0; assign cpl_len_o = '0;
    assign mem_fault_o = 1'b0;
    assign mp_req_valid_o = '0; assign mp_req_o = '{default: '0};
    assign work_valid_o = 1'b0; assign work_o = '0;
    assign xf_axi_req_o = '0;
    assign xfer_busy_o  = 1'b0;
    assign done_o = 1'b0;   assign busy_o = 1'b0;
    assign fence_pulse_o = 1'b0; assign fence_id_o = '0;
    assign fence_ring_o = '0;
    for (genvar g = 0; g < Rings; g++) begin : g_off_ring
      assign ring_active_o[g] = 1'b0;
      assign ring_status_o[g] = '0;
      assign ring_head_o[g] = '0;
      assign ring_extra_w_o[g] = '0;
    end
    assign objtab_live_o = '0;
    assign dbg_ot_ready_o = 1'b0; assign dbg_ot_cpl_valid_o = 1'b0;
    assign dbg_ot_cpl_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | chain_valid_i |
                    (|chain_id_i) | (|chain_n_i) | cpl_ready_i |
                    (|mp_req_ready_i) | (|mp_rsp_valid_i) |
                    (|mp_rsp_i[0]) | (|mp_rsp_i[1]) | (|mp_rsp_i[2]) |
                    (|mp_rsp_i[3]) | (|mp_rsp_i[4]) |
                    work_ready_i | work_done_i | (|work_done_pl_i) |
                    (|xf_axi_rsp_i) | (|ap_base_i) | xf_flush_i |
                    dbg_ot_valid_i | dbg_ot_cpl_ready_i | (|dbg_ot_req_i) |
                    (|chain_desc_i[0]) | (|chain_desc_i[1]) |
                    (|chain_desc_i[2]) | (|chain_desc_i[3]);
  end else begin : gen_on

    // shared engine interconnect — declared before the instances that
    // use them (slang requires declaration before use)
    logic            ot_req_valid, ot_cpl_valid;
    logic            ot_req_ready, ot_cpl_ready;
    apu_objtab_req_t ot_req;
    apu_objtab_cpl_t ot_cpl;
    logic            cr_req_valid, cr_cpl_valid;
    logic            cr_req_ready, cr_cpl_ready;
    apu_cmdrec_req_t cr_req;
    apu_cmdrec_cpl_t cr_cpl;
    logic [15:0]     ex_done_seq, ex_fence_sig, ex_fence_lost,
                     ex_fence_clr, ex_fence_fail;
    // §7b/5a-ii: shared ObjPay (front > exec) and vgpages (front > ctl)
    logic            op_req_valid, op_cpl_valid;
    logic            op_req_ready, op_cpl_ready;
    apu_objpay_req_t op_req;
    apu_objpay_cpl_t op_cpl;
    logic            pg_req_valid, pg_cpl_valid;
    logic            pg_req_ready, pg_cpl_ready;
    apu_vgpages_req_t pg_req;
    apu_vgpages_cpl_t pg_cpl;
    typedef enum logic [1:0] { OPG_PUMP, OPG_EXEC, OPG_CTL } opg_e;
    // raster is the third, lowest-priority vgpages requester
    typedef enum logic [1:0] { PGG_PUMP, PGG_CTL, PGG_RAST } pgg_e;
    opg_e opg_q;
    pgg_e pgg_q;

    // ---- vgctl -------------------------------------------------------------
    logic         vc_busy, vc_done, vc_mem_req, vc_mem_we, vc_mem_fault;
    logic         vc_mem_dom;
    logic [63:0]  vc_mem_addr, vc_mem_wdata;
    logic [7:0]   vc_mem_wstrb;
    logic [31:0]  vc_used_len;
    logic         vc_ot_v, vc_ot_rdy, vc_cpl_rdy;
    apu_objtab_req_t vc_ot_req;
    logic         vc_xs_v, vc_xs_rdy, vc_xs_done, vc_xs_fault;
    apu_vg_desc_t [APU_VG_MAX_DESC-1:0] vc_xs_desc;
    logic [3:0]   vc_xs_n;
    logic [31:0]  vc_xs_off, vc_xs_bytes;
    logic [7:0]   vc_xs_ctx;
    // §7b/5a-ii: vgctl's aperture page requests (arbitrated below)
    logic         vc_pg_v, vc_pg_rdy, vc_pg_cpl_rdy;
    apu_vgpages_req_t vc_pg_req;
    // RESET_CTX reap ports (arbitrated below): ObjPay extent frees and
    // ShaderCore slot unrefs for entries the ctx sweep tombstones
    logic         vc_op_v, vc_op_rdy, vc_op_cpl_rdy;
    apu_objpay_req_t vc_op_req;
    logic         vc_sm_req, vc_sm_gnt;
    apu_sh_sm_req_t vc_sm_req_pl;
    // §7b/5a-ii: the shared ShaderCore SM completion back to whichever
    // port was granted (vnpump drives it; vgctl consumes it)
    logic         vp_sm_cpl;
    apu_sh_sm_cpl_t vp_sm_cpl_pl;
    logic         vc_ctx_kill_v;
    logic [7:0]   vc_ctx_kill_id;
    // §12.3 3d-d: relocation hold + engine-drain aggregation
    // (drain_idle is driven after the sh/xfer declarations below)
    logic         vc_hold, ex_idle, drain_idle;

    g6lc_apu_vgctl #(.Enable(1'b1)) i_ctl (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .chain_valid_i(chain_valid_i), .chain_ready_o(chain_ready_o),
      .chain_n_i(chain_n_i), .chain_desc_i(chain_desc_i),
      .mem_req_o(vc_mem_req), .mem_we_o(vc_mem_we),
      .mem_dom_o(vc_mem_dom),
      .mem_addr_o(vc_mem_addr), .mem_wdata_o(vc_mem_wdata),
      .mem_wstrb_o(vc_mem_wstrb),
      .mem_ready_i(mp_req_ready_i[0]),
      .mem_rvalid_i(mp_rsp_valid_i[0]),
      .mem_rdata_i(mp_rsp_i[0].rdata), .mem_err_i(mp_rsp_i[0].err),
      .mem_fault_o(vc_mem_fault),
      .ot_req_valid_o(vc_ot_v), .ot_req_ready_i(vc_ot_rdy),
      .ot_req_o(vc_ot_req),
      .ot_cpl_valid_i(ot_cpl_valid), .ot_cpl_ready_o(vc_cpl_rdy),
      .ot_cpl_i(ot_cpl),
      .xs_valid_o(vc_xs_v), .xs_ready_i(vc_xs_rdy),
      .xs_desc_o(vc_xs_desc), .xs_ndesc_o(vc_xs_n),
      .xs_off_o(vc_xs_off), .xs_bytes_o(vc_xs_bytes),
      .xs_ctx_o(vc_xs_ctx),
      .xs_done_i(vc_xs_done), .xs_fault_i(vc_xs_fault),
      .pg_req_valid_o(vc_pg_v), .pg_req_ready_i(vc_pg_rdy),
      .pg_req_o(vc_pg_req),
      .pg_cpl_valid_i(pg_cpl_valid && pgg_q == PGG_CTL),
      .pg_cpl_ready_o(vc_pg_cpl_rdy), .pg_cpl_i(pg_cpl),
      .op_req_valid_o(vc_op_v), .op_req_ready_i(vc_op_rdy),
      .op_req_o(vc_op_req),
      .op_cpl_valid_i(op_cpl_valid && opg_q == OPG_CTL),
      .op_cpl_ready_o(vc_op_cpl_rdy), .op_cpl_i(op_cpl),
      .sm_req_o(vc_sm_req), .sm_req_pl_o(vc_sm_req_pl),
      .sm_gnt_i(vc_sm_gnt),
      .sm_cpl_i(vp_sm_cpl), .sm_cpl_pl_i(vp_sm_cpl_pl),
      .ctx_kill_valid_o(vc_ctx_kill_v), .ctx_kill_id_o(vc_ctx_kill_id),
      .hold_o(vc_hold), .drain_idle_i(drain_idle),
      .busy_o(vc_busy), .done_o(vc_done), .used_len_o(vc_used_len),
      .fence_done_o(fence_pulse_o), .fence_id_o(fence_id_o),
      .fence_ring_o(fence_ring_o));

    // ---- vnpump --------------------------------------------------------------
    logic        vp_busy, vp_xs_active;
    logic        vp_mp_req, vp_mp_we, vp_mp_dom;
    logic [63:0] vp_mp_addr, vp_mp_wdata;
    logic [7:0]  vp_mp_wstrb;
    logic        vp_ot_v, vp_ot_rdy, vp_cpl_rdy;
    apu_objtab_req_t vp_ot_req;
    logic        vp_cr_v, vp_cr_rdy, vp_cr_cpl_rdy;
    apu_cmdrec_req_t vp_cr_req;
    logic        vp_pay_v, vp_pay_rdy;
    logic [31:0] vp_pay_d;
    logic        vp_op_v, vp_op_rdy, vp_op_cpl_rdy;
    apu_objpay_req_t vp_op_req;
    // §7b/5a-ii: vnfront's ShaderCore + vgports (inside the pump)
    logic        vp_sm_req;
    apu_sh_sm_req_t vp_sm_req_pl;
    logic        vp_sh_wr_en;
    logic [2:0]  vp_sh_wr_slot;
    logic [15:0] vp_sh_wr_addr;
    logic [31:0] vp_sh_wr_data;
    logic        vp_sh_commit;
    apu_sh_commit_t vp_sh_commit_pl;
    logic        vp_sh_cdone;
    apu_sh_cpl_t vp_sh_cpl;
    logic        vp_pg_v, vp_pg_rdy, vp_pg_cpl_rdy;
    apu_vgpages_req_t vp_pg_req;
    logic        vp_ex_v, vp_ex_rdy;
    apu_cmdexec_submit_t vp_ex_submit;
    // §7b exception contract: cmdexec watchdog device-loss pulse —
    // the context's rings go FATAL in the pump
    logic        ex_devlost_v;
    logic [7:0]  ex_devlost_ctx;
    logic        ex_dead;

    g6lc_apu_vnpump #(.Enable(1'b1), .Rings(Rings),
                      .AliveTickLog2(AliveTickLog2)) i_pump (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .xs_valid_i(vc_xs_v), .xs_ready_o(vc_xs_rdy),
      .xs_desc_i(vc_xs_desc), .xs_ndesc_i(vc_xs_n),
      .xs_off_i(vc_xs_off), .xs_bytes_i(vc_xs_bytes),
      .xs_ctx_i(vc_xs_ctx),
      .xs_done_o(vc_xs_done), .xs_fault_o(vc_xs_fault),
      .xs_active_o(vp_xs_active),
      .mp_req_o(vp_mp_req), .mp_we_o(vp_mp_we),
      .mp_dom_o(vp_mp_dom), .mp_addr_o(vp_mp_addr),
      .mp_wdata_o(vp_mp_wdata), .mp_wstrb_o(vp_mp_wstrb),
      .mp_ready_i(mp_req_ready_i[1]),
      .mp_rvalid_i(mp_rsp_valid_i[1]),
      .mp_rdata_i(mp_rsp_i[1].rdata), .mp_err_i(mp_rsp_i[1].err),
      .ot_req_valid_o(vp_ot_v), .ot_req_ready_i(vp_ot_rdy),
      .ot_req_o(vp_ot_req),
      .ot_cpl_valid_i(ot_cpl_valid), .ot_cpl_ready_o(vp_cpl_rdy),
      .ot_cpl_i(ot_cpl),
      .cr_req_valid_o(vp_cr_v), .cr_req_ready_i(vp_cr_rdy),
      .cr_req_o(vp_cr_req),
      .cr_cpl_valid_i(cr_cpl_valid), .cr_cpl_ready_o(vp_cr_cpl_rdy),
      .cr_cpl_i(cr_cpl),
      .cr_pay_valid_o(vp_pay_v), .cr_pay_data_o(vp_pay_d),
      .cr_pay_ready_i(vp_pay_rdy),
      .op_req_valid_o(vp_op_v), .op_req_ready_i(vp_op_rdy),
      .op_req_o(vp_op_req),
      .op_cpl_valid_i(op_cpl_valid && opg_q == OPG_PUMP),
      .op_cpl_ready_o(vp_op_cpl_rdy),
      .op_cpl_i(op_cpl),
      .sm_req_o(vp_sm_req), .sm_req_pl_o(vp_sm_req_pl),
      .sm_cpl_i(vp_sm_cpl), .sm_cpl_pl_i(vp_sm_cpl_pl),
      .sh_wr_en_o(vp_sh_wr_en), .sh_wr_slot_o(vp_sh_wr_slot),
      .sh_wr_addr_o(vp_sh_wr_addr), .sh_wr_data_o(vp_sh_wr_data),
      .sh_commit_o(vp_sh_commit), .sh_commit_pl_o(vp_sh_commit_pl),
      .sh_c_done_i(vp_sh_cdone), .sh_c_done_pl_i(vp_sh_cpl),
      .pg_req_valid_o(vp_pg_v), .pg_req_ready_i(vp_pg_rdy),
      .pg_req_o(vp_pg_req),
      .pg_cpl_valid_i(pg_cpl_valid && pgg_q == PGG_PUMP),
      .pg_cpl_ready_o(vp_pg_cpl_rdy), .pg_cpl_i(pg_cpl),
      .ex_submit_valid_o(vp_ex_v), .ex_submit_ready_i(vp_ex_rdy),
      .ex_submit_o(vp_ex_submit),
      .ex_done_seq_i(ex_done_seq), .ex_fence_signaled_i(ex_fence_sig),
      .ex_fence_lost_i(ex_fence_lost), .ex_fence_clr_o(ex_fence_clr),
      .ex_fence_fail_o(ex_fence_fail),
      .ctx_kill_valid_i(vc_ctx_kill_v), .ctx_kill_id_i(vc_ctx_kill_id),
      .devlost_valid_i(ex_devlost_v), .devlost_ctx_i(ex_devlost_ctx),
            .busy_o(vp_busy),
      .ring_active_o(ring_active_o), .ring_status_o(ring_status_o),
      .ring_head_o(ring_head_o), .ring_extra_w_o(ring_extra_w_o));

    // ---- cmdexec --------------------------------------------------------------
    logic        ex_busy;
    logic        ex_cr_v, ex_cr_rdy, ex_cr_cpl_rdy;
    apu_cmdrec_req_t ex_cr_req;
    logic        ex_ot_v, ex_ot_rdy, ex_ot_cpl_rdy;
    apu_objtab_req_t ex_ot_req;
    logic        ex_op_v, ex_op_rdy, ex_op_cpl_rdy;
    apu_objpay_req_t ex_op_req;
    // §7b/5a-ii: dispatch-class records go to the ShaderCore instead
    // of the TB work sink; the done payload routes back
    logic        ex_work_v, ex_work_rdy;
    logic        sh_done;
    apu_sh_done_t sh_done_pl;
    logic        sh_work_rdy;
    wire         work_is_disp = work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT);
    // §12.3 C/5a+5b: Xfer-class records go to the internal DMA engine
    wire         work_is_xfer = work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_TO_BUFFER_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_CLEAR_COLOR_IMAGE_EXT);
    // draw-class records route to the raster engine: vkCmdDraw,
    // vkCmdDrawIndexed, and in-render-pass vkCmdClearAttachments
    // (CLEAR_COLOR_IMAGE stays on the Xfer DMA path)
    wire         work_is_draw = work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_DRAW_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT) ||
                       work_o.ctype ==
                       32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT);
    logic        xf_done, xf_work_rdy;
    apu_sh_done_t xf_done_pl;
    apu_xfer_desc_t ex_xfer;
    logic [2:0]         ex_disp_slot;
    apu_sh_desc_t           ex_desc;
    logic [5:0]         ex_push_n;
    logic [1023:0]      ex_push;
    logic               ex_done_v;
    apu_sh_done_t       ex_done_pl;

    assign work_valid_o = ex_work_v && !work_is_disp && !work_is_xfer &&
                          !work_is_draw;
    assign ex_work_rdy  = work_is_disp ? (sh_work_rdy && !rast_sh_own) :
                          work_is_xfer ? xf_work_rdy :
                          work_is_draw ? rs_work_rdy : work_ready_i;

    g6lc_apu_cmdexec #(.Enable(1'b1), .Fences(Fences),
                       .WorkBudgetLog2(WorkBudgetLog2)) i_exec (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .submit_valid_i(vp_ex_v), .submit_ready_o(vp_ex_rdy),
      .submit_i(vp_ex_submit),
      .cr_req_valid_o(ex_cr_v), .cr_req_ready_i(ex_cr_rdy),
      .cr_req_o(ex_cr_req),
      .cr_cpl_valid_i(cr_cpl_valid), .cr_cpl_ready_o(ex_cr_cpl_rdy),
      .cr_cpl_i(cr_cpl),
      .ot_req_valid_o(ex_ot_v), .ot_req_ready_i(ex_ot_rdy),
      .ot_req_o(ex_ot_req),
      .ot_cpl_valid_i(ot_cpl_valid), .ot_cpl_ready_o(ex_ot_cpl_rdy),
      .ot_cpl_i(ot_cpl),
      .op_req_valid_o(ex_op_v), .op_req_ready_i(ex_op_rdy),
      .op_req_o(ex_op_req),
      .op_cpl_valid_i(op_cpl_valid && opg_q == OPG_EXEC),
      .op_cpl_ready_o(ex_op_cpl_rdy), .op_cpl_i(op_cpl),
      .work_valid_o(ex_work_v), .work_ready_i(ex_work_rdy),
      .work_o(work_o), .xf_o(ex_xfer), .rd_o(rs_rd),
      .work_done_i(ex_done_v),
      .work_done_pl_i(ex_done_pl),
      .disp_slot_o(ex_disp_slot), .desc_o(ex_desc),
      .push_n_o(ex_push_n), .push_o(ex_push),
      .done_seq_o(ex_done_seq),
      .fence_signaled_o(ex_fence_sig), .fence_lost_o(ex_fence_lost),
      .fence_clr_i(ex_fence_clr), .fence_fail_i(ex_fence_fail),
      // §12.3 3d-d: vgctl's relocation hold blocks new dequeues;
      // ex_idle reports nothing in flight for the drain wait
      .hold_i(vc_hold), .idle_o(ex_idle),
      // §7b exception contract: watchdog device loss -> ring FATAL
      .devlost_valid_o(ex_devlost_v), .devlost_ctx_o(ex_devlost_ctx),
      .dead_o(ex_dead),
      .busy_o(ex_busy));

    // ---- cmdrec -----------------------------------------------------------------
    g6lc_apu_cmdrec #(.Enable(1'b1),
                      .PayWordsPerBuf(CrPayWords)) i_rec (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(cr_req_valid), .req_ready_o(cr_req_ready),
      .req_i(cr_req),
      .cpl_valid_o(cr_cpl_valid), .cpl_ready_i(cr_cpl_ready),
      .cpl_o(cr_cpl),
      .pay_valid_i(vp_pay_v), .pay_data_i(vp_pay_d),
      .pay_ready_o(vp_pay_rdy));

    // ---- objmem: ObjTab/ObjPay private DRAM backing -----------------------
    // §5a G3b-i: entries, directory and free stack in the carve at
    // APU_OBJMEM_BASE, payloads in the carve at
    // APU_OBJMEM_PAY_OFF — both behind their caches, one apu_mp
    // requester (port 4 here, APU_MP_OBJ in vgsys).
    logic         omt_req_v, omt_req_rdy, omt_rsp_v;
    apu_omt_req_t omt_req;
    apu_omt_rsp_t omt_rsp;
    logic         omp_req_v, omp_req_rdy, omp_rsp_v;
    apu_omp_req_t omp_req;
    apu_omp_rsp_t omp_rsp;

    localparam int unsigned ObjPayByteOff =
        int'(apu_objmem_pay_off(ObjEntries));

`ifndef SYNTHESIS
    // §5a carve legality: the object table + free stack + payload
    // arena must fit inside the private carve above the managed window
    // window (asserted at elaboration, before any gate runs)
    initial begin
      assert (ObjEntries >= 256 && ObjEntries <= 65536 &&
              (ObjEntries & (ObjEntries - 1)) == 0)
        else $fatal(1, "vgtop: ObjEntries %0d out of range/not pow2",
                    ObjEntries);
      assert (ObjMaxCtx >= 1 && ObjMaxCtx <= 32)
        else $fatal(1, "vgtop: ObjMaxCtx %0d out of range", ObjMaxCtx);
      assert (ObjPayByteOff + PayMemBytes <=
              64'(g6lc_apu_pkg::APU_SHM_BYTES))
        else $fatal(1, {"vgtop: objmem+pay carve overflows SHM ",
                        "(%0d + %0d > %0d)"}, ObjPayByteOff,
                    PayMemBytes, g6lc_apu_pkg::APU_SHM_BYTES);
    end
`endif

    g6lc_apu_objmem #(
        .Enable(1'b1), .ObjEntries(ObjEntries),
        .DirCacheSets(DirCacheSets), .EntCacheLines(EntCacheLines),
        .PayCacheLines(PayCacheLines)) i_objmem (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .omt_req_valid_i(omt_req_v), .omt_req_ready_o(omt_req_rdy),
      .omt_req_i(omt_req),
      .omt_rsp_valid_o(omt_rsp_v), .omt_rsp_o(omt_rsp),
      .omp_req_valid_i(omp_req_v), .omp_req_ready_o(omp_req_rdy),
      .omp_req_i(omp_req),
      .omp_rsp_valid_o(omp_rsp_v), .omp_rsp_o(omp_rsp),
      .mp_req_valid_o(mp_req_valid_o[4]),
      .mp_req_ready_i(mp_req_ready_i[4]),
      .mp_req_o(mp_req_o[4]),
      .mp_rsp_valid_i(mp_rsp_valid_i[4]),
      .mp_rsp_i(mp_rsp_i[4]));

    // ---- objpay -------------------------------------------------------------------
    // §7b/5a-ii: two requesters — vnfront (inside the pump) has
    // priority over cmdexec's dispatch-assembly reads; the grant is
    // held until the completion is consumed (same scheme as ObjTab).
    g6lc_apu_objpay #(.Enable(1'b1),
                      .PayMemBytes(PayMemBytes)) i_pay (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(op_req_valid), .req_ready_o(op_req_ready),
      .req_i(op_req),
      .cpl_valid_o(op_cpl_valid), .cpl_ready_i(op_cpl_ready),
      .cpl_o(op_cpl),
      .omp_req_valid_o(omp_req_v), .omp_req_ready_i(omp_req_rdy),
      .omp_req_o(omp_req),
      .omp_rsp_valid_i(omp_rsp_v), .omp_rsp_i(omp_rsp));

    // §6c: vgctl's RESET_CTX reap frees join as a third, lowest-priority
    // requester
    assign op_req_valid = vp_op_v | ex_op_v | vc_op_v;
    assign op_req = vp_op_v ? vp_op_req :
                    ex_op_v ? ex_op_req : vc_op_req;
    assign vp_op_rdy = vp_op_v & op_req_ready;
    assign ex_op_rdy = !vp_op_v & ex_op_v & op_req_ready;
    assign vc_op_rdy = !vp_op_v & !ex_op_v & vc_op_v & op_req_ready;
    assign op_cpl_ready = (opg_q == OPG_PUMP) ? vp_op_cpl_rdy :
                          (opg_q == OPG_EXEC) ? ex_op_cpl_rdy
                                              : vc_op_cpl_rdy;

    // ---- vgpages -------------------------------------------------------------------
    // §7b/5a-ii: one aperture page allocator, arbitrated between the
    // vnfront (vkAllocateMemory/vkFreeMemory), vgctl
    // (RESOURCE_CREATE_BLOB blob_id != 0 / RESOURCE_UNREF), and the
    // raster engine's one-time private scratch allocation (lowest
    // priority).  Front has priority; the grant is held until the
    // completion is consumed.
    g6lc_apu_vgpages #(.Enable(1'b1), .Pages(VgPages),
                       .PageBytes(VgPageBytes),
                       .GuestPages(VgGuestPages)) i_vgp (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(pg_req_valid), .req_ready_o(pg_req_ready),
      .req_i(pg_req),
      .cpl_valid_o(pg_cpl_valid), .cpl_ready_i(pg_cpl_ready),
      .cpl_o(pg_cpl));

    assign pg_req_valid = vp_pg_v | vc_pg_v | rs_pg_v;
    assign pg_req = vp_pg_v ? vp_pg_req :
                    vc_pg_v ? vc_pg_req : rs_pg_req;
    assign vp_pg_rdy = vp_pg_v & pg_req_ready;
    assign vc_pg_rdy = !vp_pg_v & vc_pg_v & pg_req_ready;
    assign rs_pg_rdy = !vp_pg_v & !vc_pg_v & rs_pg_v & pg_req_ready;
    assign pg_cpl_ready = (pgg_q == PGG_PUMP) ? vp_pg_cpl_rdy :
                          (pgg_q == PGG_CTL)  ? vc_pg_cpl_rdy
                                              : rs_pg_cpl_rdy;
    assign vc_sm_gnt = vc_sm_req & ~vp_sm_req;

    // ---- ShaderCore ---------------------------------------------------------------
    // §7b/5a-ii: module slots (sm), pCode staging (wr_*) and pipeline
    // commits come from vnfront; dispatch-class work records from
    // cmdexec issue on the work port; the LSU port is mp port 2 —
    // aperture-relative byte offsets, dom=1.
    logic        sh_busy;
    logic        sh_mem_req, sh_mem_we;
    logic [63:0] sh_mem_addr, sh_mem_wdata;
    logic [7:0]  sh_mem_wstrb;
    // §12.3 3d-d: the wave engine's descriptor memory-handle
    // resolution joins the ObjTab mux as the 5th, lowest-priority
    // requester
    logic        sh_ot_v, sh_ot_rdy, sh_cpl_rdy;
    apu_objtab_req_t sh_ot_req;
    // ---- raster engine (G1b) -------------------------------------------------
    // Draw-class records route here instead of the TB work sink; the
    // engine emits its VS/FS wave batches on the shared ShaderCore
    // work port and owns mp port 3.  rast_sh_own marks the cycles the
    // shcore sidebands carry the raster's latched desc/push: the wave
    // issue itself and the whole time a raster wave is in flight
    // (shwave reads desc_i live during LSU descriptor resolution).
    // A graphics wave's done payload carries work_id = the pseudo-ctype
    // (APU_SH_WORK_VS/FS) so it routes back here, never to cmdexec.
    logic              rs_work_rdy, rs_done, rs_busy;
    apu_sh_done_t      rs_done_pl;
    apu_rast_draw_t    rs_rd;
    logic              rast_sh_v, rast_sh_own, rast_shown_q;
    logic [31:0]       rast_sh_ctype;
    logic [7:0][31:0]  rast_sh_imm;
    logic [2:0]        rast_sh_slot;
    apu_sh_desc_t      rast_sh_desc;
    logic [5:0]        rast_sh_push_n;
    logic [1023:0]     rast_sh_push;
    wire               gfx_done = sh_done &&
                       (sh_done_pl.work_id == APU_SH_WORK_VS ||
                        sh_done_pl.work_id == APU_SH_WORK_FS);

    // cmdexec counts one work_done_i per completion, but engine done_o
    // pulses are single-cycle and engines run concurrently — two
    // coincident pulses (e.g. a raster draw finishing the same cycle
    // as an xfer readback) would collapse into one decrement and
    // strand outst_q forever (StDrain livelock, fence never signals).
    // Queue the completions and emit one work_done_i per cycle.  The
    // depth derives from the worst-case outstanding set — MaxWaves
    // shader waves + 1 raster + 1 xfer + 1 external — plus one slot of
    // slack so head != tail still distinguishes a full queue.
    localparam int unsigned Dqn = 1 << $clog2(MaxWaves + 4);
    localparam int unsigned DqW = $clog2(Dqn);
    apu_sh_done_t          dq_q   [Dqn];
    logic [DqW-1:0]        dq_head_q, dq_tail_q;
    wire                   dq_p_sh = sh_done && !gfx_done;
    wire                   dq_p_xf = xf_done;
    wire                   dq_p_rs = rs_done;
    wire                   dq_p_ex = work_done_i;
    wire [DqW-1:0]         dq_nsh = DqW'(dq_p_sh);
    wire [DqW-1:0]         dq_nxf = DqW'(dq_p_xf);
    wire [DqW-1:0]         dq_nrs = DqW'(dq_p_rs);
    wire [DqW:0]           dq_push_n = {1'b0, dq_p_sh} + {1'b0, dq_p_xf} +
                                       {1'b0, dq_p_rs} + {1'b0, dq_p_ex};
    wire                   dq_pop = dq_head_q != dq_tail_q;
    wire [DqW-1:0]         dq_occ = dq_tail_q - dq_head_q;
    assign ex_done_v  = dq_pop;
    assign ex_done_pl = dq_q[dq_head_q];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        dq_head_q <= '0;
        dq_tail_q <= '0;
      end else begin
        if (dq_p_sh) dq_q[dq_tail_q] <= sh_done_pl;
        if (dq_p_xf) dq_q[dq_tail_q + dq_nsh] <= xf_done_pl;
        if (dq_p_rs) dq_q[dq_tail_q + dq_nsh + dq_nxf] <= rs_done_pl;
        if (dq_p_ex) dq_q[dq_tail_q + dq_nsh + dq_nxf + dq_nrs]
                       <= work_done_pl_i;
        dq_tail_q <= dq_tail_q + dq_push_n[DqW-1:0];
        dq_head_q <= dq_head_q + DqW'(dq_pop);
      end
    end
    // pragma translate_off
    // Occupancy bound: at most MaxWaves+3 completions can ever be in
    // flight, so pushes may never take the queue to Dqn — occupancy
    // equal to the depth would alias head == tail back to empty and
    // silently drop a completion.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        ({1'b0, dq_occ} + dq_push_n - {{DqW{1'b0}}, dq_pop})
        <= (DqW+1)'(Dqn - 1))
      else $fatal(1, "g6lc_apu_vgtop: done-queue overflow");
    // pragma translate_on
`ifdef G6LC_APU_DBG_LOST
    // debug probe: every done-queue push/pop with its payload —
    // catches lost or phantom completions (temporary bring-up aid)
    always_ff @(posedge clk_i) begin
      if (dq_p_sh)
        $display("[DBG] dqv push sh code=%0d wid=%08x t=%0t",
                 sh_done_pl.code, sh_done_pl.work_id, $time);
      if (dq_p_xf)
        $display("[DBG] dqv push xf code=%0d t=%0t",
                 xf_done_pl.code, $time);
      if (dq_p_rs)
        $display("[DBG] dqv push rs code=%0d wid=%08x t=%0t",
                 rs_done_pl.code, rs_done_pl.work_id, $time);
      if (dq_p_ex)
        $display("[DBG] dqv push ex code=%0d t=%0t",
                 work_done_pl_i.code, $time);
      if (dq_pop)
        $display("[DBG] dqv pop  code=%0d wid=%08x t=%0t",
                 ex_done_pl.code, ex_done_pl.work_id, $time);
    end
`endif
    logic              rs_pg_v, rs_pg_rdy, rs_pg_cpl_rdy;
    apu_vgpages_req_t  rs_pg_req;
    logic              rs_mp_v;
    apu_mp_req_t       rs_mp_req;

    // G1c: rs_rd is driven by cmdexec's draw assembly (rd_o)
    g6lc_apu_shcore #(
      .Enable(1'b1), .ShaderRegs(ShaderRegs), .MaxWaves(MaxWaves),
      .ShaderIds(ShaderIds), .ShaderSlots(ShaderSlots),
      .ShaderWords(ShaderWords), .ShaderInit(ShaderInit),
      .ShaderMembers(ShaderMembers), .ScratchBytes(ScratchBytes),
      .SlabBytes(SlabBytes), .ShaderBudget(ShaderBudget)) i_sh (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .wr_en_i(vp_sh_wr_en), .wr_slot_i(vp_sh_wr_slot),
      .wr_addr_i(vp_sh_wr_addr), .wr_data_i(vp_sh_wr_data),
      .commit_i(vp_sh_commit), .commit_pl_i(vp_sh_commit_pl),
      .c_busy_o(), .c_done_o(vp_sh_cdone), .c_done_pl_o(vp_sh_cpl),
      .retire_i(1'b0), .retire_slot_i('0),
      // §6c: vgctl's RESET_CTX reap joins the slot-manager port; the
      // pump's one-cycle pulses win, vgctl level-holds its request
      // until vc_sm_gnt marks the accepted cycle
      .sm_req_i(vp_sm_req | vc_sm_req),
      .sm_req_pl_i(vp_sm_req ? vp_sm_req_pl : vc_sm_req_pl),
      .sm_cpl_o(vp_sm_cpl), .sm_cpl_pl_o(vp_sm_cpl_pl),
      // G1b: the raster's VS/FS wave batches win the work port over
      // cmdexec dispatches; while a raster wave is issued/in flight
      // the sidebands (desc live-read by the LSU; push latched at
      // dispatch) come from the raster's copies
      .work_i(rast_sh_v | (ex_work_v && work_is_disp && !rast_sh_own)),
      .work_ready_o(sh_work_rdy),
      .work_ctype_i(rast_sh_own ? rast_sh_ctype : work_o.ctype),
      .work_imm_i(rast_sh_own ? rast_sh_imm : work_o.rec.imm),
      .disp_slot_i(rast_sh_own ? rast_sh_slot : ex_disp_slot),
      .desc_i(rast_sh_own ? rast_sh_desc : ex_desc),
      .push_n_i(rast_sh_own ? rast_sh_push_n : ex_push_n),
      .push_i(rast_sh_own ? rast_sh_push : ex_push),
      .busy_o(sh_busy), .done_o(sh_done), .done_pl_o(sh_done_pl),
      .mem_re_o(sh_mem_req), .mem_we_o(sh_mem_we),
      .mem_addr_o(sh_mem_addr), .mem_wdata_o(sh_mem_wdata),
      .mem_wstrb_o(sh_mem_wstrb),
      .mem_ready_i(mp_req_ready_i[2]),
      .mem_rvalid_i(mp_rsp_valid_i[2]),
      .mem_rdata_i(mp_rsp_i[2].rdata), .mem_err_i(mp_rsp_i[2].err),
      .ot_req_valid_o(sh_ot_v), .ot_req_ready_i(sh_ot_rdy),
      .ot_req_o(sh_ot_req),
      .ot_cpl_valid_i(ot_cpl_valid), .ot_cpl_ready_o(sh_cpl_rdy),
      .ot_cpl_i(ot_cpl));

    // ---- Xfer engine (§12.3 C/5a) --------------------------------------
    // CopyBuffer/FillBuffer/UpdateBuffer records arrive with the operand
    // descriptor cmdexec assembled (ex_xfer); the U64 operands are
    // replayed from the cmdrec payload arena (a third, lowest-priority
    // requester).  The checked-DMA pair inside presents one AXI master —
    // vgsys joins it with apmem's through g6lc_apu_tdma.
    logic xf_cr_v, xf_cr_rdy, xf_cr_cpl_rdy;
    apu_cmdrec_req_t xf_cr_req;
    g6lc_apu_xfer #(.Enable(1'b1), .ApuCfg(ApuCfg)) i_xf (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .work_valid_i(ex_work_v && work_is_xfer),
      .work_ready_o(xf_work_rdy),
      .work_i(work_o), .xf_i(ex_xfer),
      .done_o(xf_done), .done_pl_o(xf_done_pl),
      .cr_req_valid_o(xf_cr_v), .cr_req_ready_i(xf_cr_rdy),
      .cr_req_o(xf_cr_req),
      .cr_cpl_valid_i(cr_cpl_valid),
      .cr_cpl_ready_o(xf_cr_cpl_rdy), .cr_cpl_i(cr_cpl),
      .ap_base_i(ap_base_i), .flush_i(xf_flush_i),
      .busy_o(xfer_busy_o),
      .axi_req_o(xf_axi_req_o), .axi_rsp_i(xf_axi_rsp_i));

    g6lc_apu_rast #(.Enable(1'b1)) i_rast (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .work_valid_i(ex_work_v && work_is_draw),
      .work_ready_o(rs_work_rdy),
      .work_i(work_o), .rd_i(rs_rd),
      .desc_i(ex_desc), .push_n_i(ex_push_n), .push_i(ex_push),
      .done_o(rs_done), .done_pl_o(rs_done_pl),
      .sh_work_valid_o(rast_sh_v), .sh_work_ready_i(sh_work_rdy),
      .sh_ctype_o(rast_sh_ctype), .sh_imm_o(rast_sh_imm),
      .sh_slot_o(rast_sh_slot), .sh_desc_o(rast_sh_desc),
      .sh_push_n_o(rast_sh_push_n), .sh_push_o(rast_sh_push),
      .sh_done_i(gfx_done), .sh_done_pl_i(sh_done_pl),
      .mp_req_valid_o(rs_mp_v),
      .mp_req_ready_i(mp_req_ready_i[3]),
      .mp_req_o(rs_mp_req),
      .mp_rsp_valid_i(mp_rsp_valid_i[3]), .mp_rsp_i(mp_rsp_i[3]),
      .pg_req_valid_o(rs_pg_v), .pg_req_ready_i(rs_pg_rdy),
      .pg_req_o(rs_pg_req),
      .pg_cpl_valid_i(pg_cpl_valid && pgg_q == PGG_RAST),
      .pg_cpl_ready_o(rs_pg_cpl_rdy), .pg_cpl_i(pg_cpl),
      .busy_o(rs_busy));

    // wave-in-flight latch (clocked with the grant owners below):
    // while set, the shcore sidebands carry the raster's copies —
    // shwave reads desc_i live during LSU descriptor resolution
    assign rast_sh_own = rast_sh_v | rast_shown_q;

    // §12.3 3d-d: relocation drain — nothing in flight anywhere the
    // aperture data could move under (cmdexec FSM+outstanding work,
    // a running dispatch, an in-flight DMA, a raster chain)
    assign drain_idle = ex_idle & ~sh_busy & ~xfer_busy_o & ~rs_busy;

    // ---- objtab -------------------------------------------------------------------
    g6lc_apu_objtab #(.Enable(1'b1), .ObjEntries(ObjEntries),
                      .MaxCtx(ObjMaxCtx),
                      .KindListKind(APU_VN_KIND_VK_DEVICE_MEMORY))
        i_tab (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(ot_req_valid), .req_ready_o(ot_req_ready),
      .req_i(ot_req),
      .cpl_valid_o(ot_cpl_valid), .cpl_ready_i(ot_cpl_ready),
      .cpl_o(ot_cpl), .live_o(objtab_live_o),
      .omt_req_valid_o(omt_req_v), .omt_req_ready_i(omt_req_rdy),
      .omt_req_o(omt_req),
      .omt_rsp_valid_i(omt_rsp_v), .omt_rsp_i(omt_rsp));

    // ---- ObjTab arbitration: pump > cmdexec > vgctl > debug > shwave --------
    // §12.3 3d-d: shwave's record-handle READSLOTs are the lowest-
    // priority requester — they wait behind every control-plane user
    typedef enum logic [2:0] { OG_NONE, OG_PUMP, OG_EXEC, OG_CTL,
                               OG_DBG, OG_SH } og_e;
    og_e og_q;   // completion owner
    logic ot_grant_pump, ot_grant_exec, ot_grant_ctl, ot_grant_dbg,
          ot_grant_sh;

    assign ot_grant_pump = vp_ot_v;
    assign ot_grant_exec = !vp_ot_v && ex_ot_v;
    assign ot_grant_ctl  = !vp_ot_v && !ex_ot_v && vc_ot_v;
    assign ot_grant_dbg  = !vp_ot_v && !ex_ot_v && !vc_ot_v &&
                           dbg_ot_valid_i && !vc_busy && !vp_busy;
    assign ot_grant_sh   = !vp_ot_v && !ex_ot_v && !vc_ot_v &&
                           !ot_grant_dbg && sh_ot_v;

    assign ot_req_valid = vp_ot_v | ex_ot_v | vc_ot_v |
                          (ot_grant_dbg & dbg_ot_valid_i) |
                          (ot_grant_sh & sh_ot_v);
    assign ot_req = vp_ot_v ? vp_ot_req :
                    ex_ot_v ? ex_ot_req :
                    vc_ot_v ? vc_ot_req :
                    ot_grant_dbg ? dbg_ot_req_i : sh_ot_req;

    assign vp_ot_rdy = ot_grant_pump & ot_req_ready;
    assign ex_ot_rdy = ot_grant_exec & ot_req_ready;
    assign vc_ot_rdy = ot_grant_ctl  & ot_req_ready;
    assign dbg_ot_ready_o = ot_grant_dbg & ot_req_ready;
    assign sh_ot_rdy = ot_grant_sh & ot_req_ready;

    // completion routing: owner latched at request acceptance
    assign ot_cpl_ready = (og_q == OG_PUMP) ? vp_cpl_rdy :
                          (og_q == OG_EXEC) ? ex_ot_cpl_rdy :
                          (og_q == OG_CTL)  ? vc_cpl_rdy :
                          (og_q == OG_SH)   ? sh_cpl_rdy :
                          (og_q == OG_DBG)  ? dbg_ot_cpl_ready_i : 1'b0;
    assign dbg_ot_cpl_valid_o = ot_cpl_valid && og_q == OG_DBG;
    assign dbg_ot_cpl_o = ot_cpl;

    // ---- CmdRec arbitration: pump (front) > cmdexec > xfer ----------------
    // §12.3 C/5a: the Xfer engine is the lowest-priority PAYREAD
    // requester (replay of region/operand words and UpdateBuffer data)
    typedef enum logic [1:0] { CG_PUMP, CG_EXEC, CG_XFER } cg_e;
    cg_e cg_q;
    assign cr_req_valid = vp_cr_v | ex_cr_v | xf_cr_v;
    assign cr_req = vp_cr_v ? vp_cr_req :
                    ex_cr_v ? ex_cr_req : xf_cr_req;
    assign vp_cr_rdy = vp_cr_v & cr_req_ready;
    assign ex_cr_rdy = !vp_cr_v & ex_cr_v & cr_req_ready;
    assign xf_cr_rdy = !vp_cr_v & !ex_cr_v & xf_cr_v & cr_req_ready;
    assign cr_cpl_ready = (cg_q == CG_PUMP) ? vp_cr_cpl_rdy :
                          (cg_q == CG_EXEC) ? ex_cr_cpl_rdy :
                                              xf_cr_cpl_rdy;

    // ---- shared memory ports (apu_mp) ----------------------------------------
    // [0] CTL: vgctl request/response words, guest absolute (dom=0);
    //     the MAP_BLOB word mover raises dom for aperture-relative
    //     beats (§12.3 3d-d DEVBACKED relocation)
    // [1] PUMP: vnpump aperture words + execbuffer guest reads (dom)
    // [2] SH: shader LSU, aperture-relative (dom=1)
    // [3] RAST: raster engine, aperture-relative (dom=1), the engine
    //     already drives a full apu_mp_req_t
    // [4] OBJ is driven by i_objmem above
    assign mp_req_valid_o[3:0] = {rs_mp_v, sh_mem_req | sh_mem_we,
                                  vp_mp_req, vc_mem_req};
    assign mp_req_o[0] = '{dom: vc_mem_dom, we: vc_mem_we,
                          addr: vc_mem_addr, wdata: vc_mem_wdata,
                          wstrb: vc_mem_wstrb};
    assign mp_req_o[1] = '{dom: vp_mp_dom, we: vp_mp_we,
                          addr: vp_mp_addr, wdata: vp_mp_wdata,
                          wstrb: vp_mp_wstrb};
    assign mp_req_o[2] = '{dom: 1'b1, we: sh_mem_we,
                          addr: sh_mem_addr, wdata: sh_mem_wdata,
                          wstrb: sh_mem_wstrb};
    assign mp_req_o[3] = rs_mp_req;

    // grant-owner tracking for the arbitrated internal ports
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        og_q <= OG_NONE; cg_q <= CG_PUMP;
        opg_q <= OPG_PUMP; pgg_q <= PGG_PUMP;
        rast_shown_q <= 1'b0;
      end else begin
        // ObjTab grant owner: set at request accept, cleared at cpl
        if (ot_req_valid && ot_req_ready) begin
          og_q <= vp_ot_v ? OG_PUMP : ex_ot_v ? OG_EXEC :
                  vc_ot_v ? OG_CTL :
                  ot_grant_dbg ? OG_DBG : OG_SH;
        end
        // RESET_CTX streams interim SWEEP completions — the grant stays
        // with the owner until the final (non-SWEEP) completion so the
        // whole reap stream is routed to the requester
        if (ot_cpl_valid && ot_cpl_ready &&
            ot_cpl.status != APU_OBJTAB_SWEEP) og_q <= OG_NONE;
        if (cr_req_valid && cr_req_ready)
          cg_q <= vp_cr_v ? CG_PUMP :
                  ex_cr_v ? CG_EXEC : CG_XFER;
        // §7b/5a-ii: ObjPay/vgpages grant owners, same latch scheme
        if (op_req_valid && op_req_ready)
          opg_q <= vp_op_v ? OPG_PUMP : ex_op_v ? OPG_EXEC : OPG_CTL;
        if (pg_req_valid && pg_req_ready)
          pgg_q <= vp_pg_v ? PGG_PUMP : vc_pg_v ? PGG_CTL : PGG_RAST;
        // raster wave in flight on the shcore work port
        if (rast_sh_v && sh_work_rdy) rast_shown_q <= 1'b1;
        if (gfx_done)                 rast_shown_q <= 1'b0;
      end
    end

    // completion hand-off to the virtqueue walker (which publishes
    // the used element and used.idx): registered on vgctl's done and
    // held until cpl_ready_i; len is the truthful used length
    logic        cpl_q;
    logic [31:0] cpl_len_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cpl_q     <= 1'b0;
        cpl_len_q <= '0;
      end else begin
        if (vc_done) begin
          cpl_q     <= 1'b1;
          cpl_len_q <= vc_used_len;
        end else if (cpl_q && cpl_ready_i) begin
          cpl_q <= 1'b0;
        end
      end
    end
    assign cpl_valid_o = cpl_q;
    assign cpl_len_o   = cpl_len_q;
    assign done_o      = vc_done;
    assign mem_fault_o = vc_mem_fault;
    assign busy_o      = vc_busy | vp_busy | sh_busy | ex_busy |
                         xfer_busy_o | rs_busy;
    // chain_id is published by the walker, not consumed here
    logic unused_chain;
    assign unused_chain = |chain_id_i;
  end
endmodule

// Fixture wrapper for the *_SYNTH=1 screens.
module g6lc_apu_vgtop_fixture
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Rings  = 64,
  parameter int unsigned Fences = 16,
  // ring ALIVE watchdog refresh period: 2**AliveTickLog2 cycles
  parameter int unsigned AliveTickLog2 = 20,
  // §7b exception contract: cmdexec work watchdog — see g6lc_apu_cmdexec
  parameter int unsigned WorkBudgetLog2 = 30,
  parameter int unsigned CrPayWords = 1024,
  parameter int unsigned ObjEntries    = 65536,
  parameter int unsigned ObjMaxCtx     = 32,
  parameter int unsigned PayMemBytes   = 16 * 1024 * 1024,
  parameter int unsigned DirCacheSets  = 256,
  parameter int unsigned EntCacheLines = 64,
  parameter int unsigned PayCacheLines = 32,
  parameter int unsigned VgPages      = APU_VG_PAGES,
  parameter int unsigned VgPageBytes  = APU_VG_PAGE_BYTES,
  parameter int unsigned VgGuestPages = APU_VG_GUEST_PAGES,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000,
  parameter g6lc_apu_cfg_pkg::apu_cfg_t ApuCfg = g6lc_apu_cfg_pkg::ApuVenus
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [15:0]     chain_id_i,
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output logic [31:0]     cpl_len_o,
  output logic            mem_fault_o,
  output logic [4:0]         mp_req_valid_o,
  input  logic [4:0]         mp_req_ready_i,
  output apu_mp_req_t [4:0]  mp_req_o,
  input  logic [4:0]         mp_rsp_valid_i,
  input  apu_mp_rsp_t [4:0]  mp_rsp_i,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  output g6lc_apu_bus_pkg::apu_dma_axi_req_t  xf_axi_req_o,
  input  g6lc_apu_bus_pkg::apu_dma_axi_resp_t xf_axi_rsp_i,
  input  logic [63:0]      ap_base_i,
  input  logic             xf_flush_i,
  output logic             xfer_busy_o,
  output logic            done_o,
  output logic            busy_o,
  output logic            fence_pulse_o,
  output logic [63:0]     fence_id_o,
  output logic [7:0]      fence_ring_o,
  output logic [Rings-1:0]       ring_active_o,
  output logic [Rings-1:0][31:0] ring_status_o,
  output logic [Rings-1:0][31:0] ring_head_o,
  output logic [Rings-1:0][APU_VG_AP_WORD_W-1:0] ring_extra_w_o,
  output logic [15:0]     objtab_live_o,
  input  logic            dbg_ot_valid_i,
  output logic            dbg_ot_ready_o,
  input  apu_objtab_req_t dbg_ot_req_i,
  output logic            dbg_ot_cpl_valid_o,
  input  logic            dbg_ot_cpl_ready_i,
  output apu_objtab_cpl_t dbg_ot_cpl_o
);
  g6lc_apu_vgtop #(
    .Enable(Enable), .Rings(Rings), .Fences(Fences),
    .AliveTickLog2(AliveTickLog2), .WorkBudgetLog2(WorkBudgetLog2),
    .CrPayWords(CrPayWords),
    .ObjEntries(ObjEntries), .ObjMaxCtx(ObjMaxCtx),
    .PayMemBytes(PayMemBytes), .DirCacheSets(DirCacheSets),
    .EntCacheLines(EntCacheLines), .PayCacheLines(PayCacheLines),
    .VgPages(VgPages), .VgPageBytes(VgPageBytes),
    .VgGuestPages(VgGuestPages),
    .ShaderRegs(ShaderRegs), .MaxWaves(MaxWaves),
    .ShaderIds(ShaderIds), .ShaderSlots(ShaderSlots),
    .ShaderWords(ShaderWords), .ShaderInit(ShaderInit),
    .ShaderMembers(ShaderMembers), .ScratchBytes(ScratchBytes),
    .SlabBytes(SlabBytes), .ShaderBudget(ShaderBudget),
    .ApuCfg(ApuCfg)) i_dut (.*);
endmodule
