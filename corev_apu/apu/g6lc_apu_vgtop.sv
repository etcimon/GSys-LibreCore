// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Venus transport composition (§6b of
// architecture/uncore/apu-vulkan-engine.md): vgctl control-queue
// processor -> vnpump ring pump -> vnfront, over a shared ObjTab,
// CmdRec and CmdExec, plus the used-publication path.
//
// Publication: response -> used element {id,len} -> used.idx -> ISR.
// g6lc_apu_avu/g6lc_apu_uir are NOT reused here: avu's request record
// is a whole-queue avail-ring walk whose result (apu_avu_t) carries
// only {first_addr,last_addr,count}, not the per-descriptor
// {addr,len,write} triples g6lc_apu_vgctl consumes, so it cannot feed
// this interface without edits.  The thin FSM below publishes the
// used element, the used index and ISR bit 0 in order through the
// guest-memory port; the TB sink observes the writes.
//
// Guest-memory port arbitration: vgctl (request reads / response
// writes), the pump's execbuffer reads, and the publication writes
// are mutually exclusive in this fixture (the pump reads guest memory
// only while a SUBMIT_3D hand-off owns the stream and vgctl waits;
// publication runs after vgctl's done).  The mux is static with
// publication write > pump read > vgctl priority.
//
// ObjTab arbitration: three requesters — pump (incl. vnfront), the
// vgctl control path, and cmdexec (submit PIN / completion UNPIN /
// stale-handle re-resolve).  Fixed priority pump > cmdexec > vgctl >
// debug; the grant is held until the completion is consumed.
// CmdRec arbitration: pump (front recording ops) > cmdexec (record
// reads), same grant scheme.
//
// Timing impact: arbitration adds no pipeline stages; the mem port
// mux is a static select.  Publication is three word-writes + ISR.
//
// Review checklist: async active-low reset; no latches; Enable=0
// elaborates no datapath.  The debug ObjTab port is for TB teardown
// checks (RESET_CTX count); it is only granted while every engine is
// idle.

module g6lc_apu_vgtop
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Rings  = 4,
  parameter int unsigned Fences = 16,
  parameter int unsigned PayWords = 16384,
  // §7b/5a-ii: aperture page allocator + ShaderCore geometry
  parameter int unsigned VgPages      = 256,
  parameter int unsigned VgPageBytes  = 4096,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  // one descriptor chain (TB walks the avail ring)
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [15:0]     chain_id_i,      // avail element id -> used elem
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  input  logic [63:0]     chain_uelem_addr_i,  // used-elem slot address
  input  logic [63:0]     chain_uidx_addr_i,   // used.idx address
  // guest memory word port
  output logic            mem_re_o,
  output logic            mem_we_o,
  output logic [63:0]     mem_addr_o,
  output logic [31:0]     mem_wdata_o,
  input  logic [31:0]     mem_rdata_i,
  // aperture word port (Venus shared-memory window, 1R1W)
  output logic            ap_re_o,
  output logic [17:0]     ap_raddr_o,
  output logic            ap_we_o,
  output logic [17:0]     ap_waddr_o,
  output logic [31:0]     ap_wdata_o,
  input  logic [31:0]     ap_rdata_i,
  // command-executor work port (TB work sink; dispatch-class records
  // are consumed internally by the ShaderCore, §7b/5a-ii)
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  // ShaderCore guest memory port (64-bit; the TB aperture model
  // serves it — unification with the ring/reply memory is 3c)
  output logic               sh_mem_re_o,
  output logic               sh_mem_we_o,
  output logic [63:0]        sh_mem_addr_o,
  output logic [63:0]        sh_mem_wdata_o,
  output logic [7:0]         sh_mem_wstrb_o,
  input  logic [63:0]        sh_mem_rdata_i,
  // completion + publication observability
  output logic            done_o,          // pulse after ISR published
  output logic            irq_o,
  output logic [31:0]     isr_o,
  input  logic            isr_ack_i,       // TB ISR write-ack
  output logic            fence_pulse_o,
  output logic [63:0]     fence_id_o,
  output logic [7:0]      fence_ring_o,
  output logic [Rings-1:0]       ring_active_o,
  output logic [Rings-1:0][31:0] ring_status_o,
  output logic [Rings-1:0][31:0] ring_head_o,
  output logic [Rings-1:0][17:0] ring_extra_w_o,
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
    assign mem_re_o = 1'b0; assign mem_we_o = 1'b0;
    assign mem_addr_o = '0; assign mem_wdata_o = '0;
    assign ap_re_o = 1'b0;  assign ap_we_o = 1'b0;
    assign ap_raddr_o = '0; assign ap_waddr_o = '0;
    assign ap_wdata_o = '0;
    assign work_valid_o = 1'b0; assign work_o = '0;
    assign sh_mem_re_o = 1'b0; assign sh_mem_we_o = 1'b0;
    assign sh_mem_addr_o = '0; assign sh_mem_wdata_o = '0;
    assign sh_mem_wstrb_o = '0;
    assign done_o = 1'b0;   assign irq_o = 1'b0; assign isr_o = '0;
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
                    (|chain_id_i) | (|chain_n_i) | (|chain_uelem_addr_i) |
                    (|chain_uidx_addr_i) | (|mem_rdata_i) | (|ap_rdata_i) |
                    work_ready_i | work_done_i | (|work_done_pl_i) |
                    (|sh_mem_rdata_i) | isr_ack_i |
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
                     ex_fence_clr;
    // §7b/5a-ii: shared ObjPay (front > exec) and vgpages (front > ctl)
    logic            op_req_valid, op_cpl_valid;
    logic            op_req_ready, op_cpl_ready;
    apu_objpay_req_t op_req;
    apu_objpay_cpl_t op_cpl;
    logic            pg_req_valid, pg_cpl_valid;
    logic            pg_req_ready, pg_cpl_ready;
    apu_vgpages_req_t pg_req;
    apu_vgpages_cpl_t pg_cpl;
    typedef enum logic [0:0] { OPG_PUMP, OPG_EXEC } opg_e;
    typedef enum logic [0:0] { PGG_PUMP, PGG_CTL } pgg_e;
    opg_e opg_q;
    pgg_e pgg_q;

    // ---- vgctl -------------------------------------------------------------
    logic         vc_busy, vc_done, vc_mem_re, vc_mem_we;
    logic [63:0]  vc_mem_addr;
    logic [31:0]  vc_mem_wdata, vc_used_len;
    logic         vc_ot_v, vc_ot_rdy, vc_cpl_rdy;
    apu_objtab_req_t vc_ot_req;
    logic         vc_xs_v, vc_xs_rdy, vc_xs_done, vc_xs_fault;
    apu_vg_desc_t [APU_VG_MAX_DESC-1:0] vc_xs_desc;
    logic [3:0]   vc_xs_n;
    logic [31:0]  vc_xs_off, vc_xs_bytes;
    logic [7:0]   vc_xs_ctx;
    logic [63:0]  uelem_addr_q, uidx_addr_q;
    logic [15:0]  chain_id_q;
    // §7b/5a-ii: vgctl's aperture page requests (arbitrated below)
    logic         vc_pg_v, vc_pg_rdy, vc_pg_cpl_rdy;
    apu_vgpages_req_t vc_pg_req;

    g6lc_apu_vgctl #(.Enable(1'b1)) i_ctl (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .chain_valid_i(chain_valid_i), .chain_ready_o(chain_ready_o),
      .chain_n_i(chain_n_i), .chain_desc_i(chain_desc_i),
      .mem_re_o(vc_mem_re), .mem_we_o(vc_mem_we),
      .mem_addr_o(vc_mem_addr), .mem_wdata_o(vc_mem_wdata),
      .mem_rdata_i(mem_rdata_i),
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
      .busy_o(vc_busy), .done_o(vc_done), .used_len_o(vc_used_len),
      .fence_done_o(fence_pulse_o), .fence_id_o(fence_id_o),
      .fence_ring_o(fence_ring_o));

    // ---- vnpump --------------------------------------------------------------
    logic        vp_busy, vp_xs_active;
    logic        vp_ap_re, vp_ap_we;
    logic [17:0] vp_ap_raddr, vp_ap_waddr;
    logic [31:0] vp_ap_wdata;
    logic        vp_gm_re;
    logic [63:0] vp_gm_addr;
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
    logic        vp_sm_cpl;
    apu_sh_sm_cpl_t vp_sm_cpl_pl;
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

    g6lc_apu_vnpump #(.Enable(1'b1), .Rings(Rings)) i_pump (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .xs_valid_i(vc_xs_v), .xs_ready_o(vc_xs_rdy),
      .xs_desc_i(vc_xs_desc), .xs_ndesc_i(vc_xs_n),
      .xs_off_i(vc_xs_off), .xs_bytes_i(vc_xs_bytes),
      .xs_ctx_i(vc_xs_ctx),
      .xs_done_o(vc_xs_done), .xs_fault_o(vc_xs_fault),
      .xs_active_o(vp_xs_active),
      .ap_re_o(vp_ap_re), .ap_we_o(vp_ap_we),
      .ap_raddr_o(vp_ap_raddr), .ap_waddr_o(vp_ap_waddr),
      .ap_wdata_o(vp_ap_wdata),
      .ap_rdata_i(ap_rdata_i),
      .gm_re_o(vp_gm_re), .gm_addr_o(vp_gm_addr),
      .gm_rdata_i(mem_rdata_i),
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
            .busy_o(vp_busy),
      .ring_active_o(ring_active_o), .ring_status_o(ring_status_o),
      .ring_head_o(ring_head_o), .ring_extra_w_o(ring_extra_w_o));

    // ---- cmdexec --------------------------------------------------------------
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
    logic [2:0]         ex_disp_slot;
    logic [16*113-1:0]  ex_binds;
    logic [5:0]         ex_push_n;
    logic [1023:0]      ex_push;

    assign work_valid_o = ex_work_v && !work_is_disp;
    assign ex_work_rdy  = work_is_disp ? sh_work_rdy : work_ready_i;

    g6lc_apu_cmdexec #(.Enable(1'b1), .Fences(Fences)) i_exec (
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
      .work_o(work_o),
      .work_done_i(sh_done | work_done_i),
      .work_done_pl_i(sh_done ? sh_done_pl : work_done_pl_i),
      .disp_slot_o(ex_disp_slot), .binds_o(ex_binds),
      .push_n_o(ex_push_n), .push_o(ex_push),
      .done_seq_o(ex_done_seq),
      .fence_signaled_o(ex_fence_sig), .fence_lost_o(ex_fence_lost),
      .fence_clr_i(ex_fence_clr));

    // ---- cmdrec -----------------------------------------------------------------
    g6lc_apu_cmdrec #(.Enable(1'b1)) i_rec (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(cr_req_valid), .req_ready_o(cr_req_ready),
      .req_i(cr_req),
      .cpl_valid_o(cr_cpl_valid), .cpl_ready_i(cr_cpl_ready),
      .cpl_o(cr_cpl),
      .pay_valid_i(vp_pay_v), .pay_data_i(vp_pay_d),
      .pay_ready_o(vp_pay_rdy));

    // ---- objpay -------------------------------------------------------------------
    // §7b/5a-ii: two requesters — vnfront (inside the pump) has
    // priority over cmdexec's dispatch-assembly reads; the grant is
    // held until the completion is consumed (same scheme as ObjTab).
    g6lc_apu_objpay #(.Enable(1'b1), .PayWords(PayWords)) i_pay (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(op_req_valid), .req_ready_o(op_req_ready),
      .req_i(op_req),
      .cpl_valid_o(op_cpl_valid), .cpl_ready_i(op_cpl_ready),
      .cpl_o(op_cpl));

    assign op_req_valid = vp_op_v | ex_op_v;
    assign op_req = vp_op_v ? vp_op_req : ex_op_req;
    assign vp_op_rdy = vp_op_v & op_req_ready;
    assign ex_op_rdy = !vp_op_v & ex_op_v & op_req_ready;
    assign op_cpl_ready = (opg_q == OPG_PUMP) ? vp_op_cpl_rdy
                                            : ex_op_cpl_rdy;

    // ---- vgpages -------------------------------------------------------------------
    // §7b/5a-ii: one aperture page allocator, arbitrated between the
    // vnfront (vkAllocateMemory/vkFreeMemory) and vgctl
    // (RESOURCE_CREATE_BLOB blob_id != 0 / RESOURCE_UNREF).  Front has
    // priority; the grant is held until the completion is consumed.
    g6lc_apu_vgpages #(.Enable(1'b1), .Pages(VgPages),
                       .PageBytes(VgPageBytes)) i_vgp (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(pg_req_valid), .req_ready_o(pg_req_ready),
      .req_i(pg_req),
      .cpl_valid_o(pg_cpl_valid), .cpl_ready_i(pg_cpl_ready),
      .cpl_o(pg_cpl));

    assign pg_req_valid = vp_pg_v | vc_pg_v;
    assign pg_req = vp_pg_v ? vp_pg_req : vc_pg_req;
    assign vp_pg_rdy = vp_pg_v & pg_req_ready;
    assign vc_pg_rdy = !vp_pg_v & vc_pg_v & pg_req_ready;
    assign pg_cpl_ready = (pgg_q == PGG_PUMP) ? vp_pg_cpl_rdy
                                            : vc_pg_cpl_rdy;

    // ---- ShaderCore ---------------------------------------------------------------
    // §7b/5a-ii: module slots (sm), pCode staging (wr_*) and pipeline
    // commits come from vnfront; dispatch-class work records from
    // cmdexec issue on the work port; the 64-bit guest memory port is
    // exposed as sh_mem_* for the TB aperture model.
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
      .sm_req_i(vp_sm_req), .sm_req_pl_i(vp_sm_req_pl),
      .sm_cpl_o(vp_sm_cpl), .sm_cpl_pl_o(vp_sm_cpl_pl),
      .work_i(ex_work_v && work_is_disp), .work_ready_o(sh_work_rdy),
      .work_ctype_i(work_o.ctype), .work_imm_i(work_o.rec.imm),
      .disp_slot_i(ex_disp_slot), .binds_i(ex_binds),
      .push_n_i(ex_push_n), .push_i(ex_push),
      .busy_o(), .done_o(sh_done), .done_pl_o(sh_done_pl),
      .mem_re_o(sh_mem_re_o), .mem_we_o(sh_mem_we_o),
      .mem_addr_o(sh_mem_addr_o), .mem_wdata_o(sh_mem_wdata_o),
      .mem_wstrb_o(sh_mem_wstrb_o), .mem_rdata_i(sh_mem_rdata_i));

    // ---- objtab -------------------------------------------------------------------
    g6lc_apu_objtab #(.Enable(1'b1)) i_tab (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .req_valid_i(ot_req_valid), .req_ready_o(ot_req_ready),
      .req_i(ot_req),
      .cpl_valid_o(ot_cpl_valid), .cpl_ready_i(ot_cpl_ready),
      .cpl_o(ot_cpl), .live_o(objtab_live_o));

    // ---- ObjTab arbitration: pump > cmdexec > vgctl > debug ----------------------
    typedef enum logic [2:0] { OG_NONE, OG_PUMP, OG_EXEC, OG_CTL, OG_DBG }
      og_e;
    og_e og_q;   // completion owner
    logic ot_grant_pump, ot_grant_exec, ot_grant_ctl, ot_grant_dbg;

    assign ot_grant_pump = vp_ot_v;
    assign ot_grant_exec = !vp_ot_v && ex_ot_v;
    assign ot_grant_ctl  = !vp_ot_v && !ex_ot_v && vc_ot_v;
    assign ot_grant_dbg  = !vp_ot_v && !ex_ot_v && !vc_ot_v &&
                           dbg_ot_valid_i && !vc_busy && !vp_busy;

    assign ot_req_valid = vp_ot_v | ex_ot_v | vc_ot_v |
                          (ot_grant_dbg & dbg_ot_valid_i);
    assign ot_req = vp_ot_v ? vp_ot_req :
                    ex_ot_v ? ex_ot_req :
                    vc_ot_v ? vc_ot_req : dbg_ot_req_i;

    assign vp_ot_rdy = ot_grant_pump & ot_req_ready;
    assign ex_ot_rdy = ot_grant_exec & ot_req_ready;
    assign vc_ot_rdy = ot_grant_ctl  & ot_req_ready;
    assign dbg_ot_ready_o = ot_grant_dbg & ot_req_ready;

    // completion routing: owner latched at request acceptance
    assign ot_cpl_ready = (og_q == OG_PUMP) ? vp_cpl_rdy :
                          (og_q == OG_EXEC) ? ex_ot_cpl_rdy :
                          (og_q == OG_CTL)  ? vc_cpl_rdy :
                          (og_q == OG_DBG)  ? dbg_ot_cpl_ready_i : 1'b0;
    assign dbg_ot_cpl_valid_o = ot_cpl_valid && og_q == OG_DBG;
    assign dbg_ot_cpl_o = ot_cpl;

    // ---- CmdRec arbitration: pump (front) > cmdexec -----------------------------
    typedef enum logic [0:0] { CG_PUMP, CG_EXEC } cg_e;
    cg_e cg_q;
    assign cr_req_valid = vp_cr_v | ex_cr_v;
    assign cr_req = vp_cr_v ? vp_cr_req : ex_cr_req;
    assign vp_cr_rdy = vp_cr_v & cr_req_ready;
    assign ex_cr_rdy = !vp_cr_v & ex_cr_v & cr_req_ready;
    assign cr_cpl_ready = (cg_q == CG_PUMP) ? vp_cr_cpl_rdy
                                          : ex_cr_cpl_rdy;

    // ---- guest-memory port mux -----------------------------------------------------
    // consumers: vgctl mem (re+we), pump execbuffer reads (re), the
    // publication FSM (we).  Mutually exclusive in this fixture.
    logic        pub_we_q;
    logic [63:0] pub_addr_q;
    logic [31:0] pub_data_q;

    assign mem_re_o = pub_we_q ? 1'b0 : (vp_gm_re | vc_mem_re);
    assign mem_we_o = pub_we_q | vc_mem_we;
    assign mem_addr_o = pub_we_q ? pub_addr_q :
                        vp_gm_re ? vp_gm_addr : vc_mem_addr;
    assign mem_wdata_o = pub_we_q ? pub_data_q : vc_mem_wdata;
    // both readers observe the same rdata (never in flight together)

    // ---- aperture port (pump only) --------------------------------------------------
    assign ap_re_o = vp_ap_re;
    assign ap_raddr_o = vp_ap_raddr;
    assign ap_we_o = vp_ap_we;
    assign ap_waddr_o = vp_ap_waddr;
    assign ap_wdata_o = vp_ap_wdata;

    // ---- publication FSM: response(done) -> used elem -> used idx -> ISR ----------
    typedef enum logic [2:0] { P_IDLE, P_ELEM, P_LEN,
                               P_IDX, P_ISR } pub_e;
    pub_e pub_q;
    logic [15:0] uidx_q;
    logic [31:0] isr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pub_q <= P_IDLE; pub_we_q <= 1'b0;
        pub_addr_q <= '0; pub_data_q <= '0;
        uelem_addr_q <= '0; uidx_addr_q <= '0; chain_id_q <= '0;
        uidx_q <= '0; isr_q <= '0;
        og_q <= OG_NONE; cg_q <= CG_PUMP;
        opg_q <= OPG_PUMP; pgg_q <= PGG_PUMP;
      end else begin
        // latch publication addresses with the chain
        if (chain_valid_i && chain_ready_o) begin
          chain_id_q <= chain_id_i;
          uelem_addr_q <= chain_uelem_addr_i;
          uidx_addr_q <= chain_uidx_addr_i;
        end
        // ObjTab grant owner: set at request accept, cleared at cpl
        if (ot_req_valid && ot_req_ready) begin
          og_q <= vp_ot_v ? OG_PUMP : ex_ot_v ? OG_EXEC :
                  vc_ot_v ? OG_CTL : OG_DBG;
        end
        if (ot_cpl_valid && ot_cpl_ready) og_q <= OG_NONE;
        if (cr_req_valid && cr_req_ready)
          cg_q <= vp_cr_v ? CG_PUMP : CG_EXEC;
        // §7b/5a-ii: ObjPay/vgpages grant owners, same latch scheme
        if (op_req_valid && op_req_ready)
          opg_q <= vp_op_v ? OPG_PUMP : OPG_EXEC;
        if (pg_req_valid && pg_req_ready)
          pgg_q <= vp_pg_v ? PGG_PUMP : PGG_CTL;

        // ISR sticky bit
        if (isr_ack_i) isr_q <= '0;

        unique case (pub_q)
          P_IDLE: begin
            pub_we_q <= 1'b0;
            if (vc_done) begin
              // split-virtqueue used elem {le32 id, le32 len}
              pub_addr_q <= uelem_addr_q;
              pub_data_q <= 32'(chain_id_q);
              pub_we_q <= 1'b1;
              pub_q <= P_ELEM;
            end
          end
          P_ELEM: begin
            // used elem word 1: len
            pub_addr_q <= uelem_addr_q + 64'd4;
            pub_data_q <= vc_used_len;
            pub_q <= P_LEN;
          end
          P_LEN: begin
            // used.idx
            pub_addr_q <= uidx_addr_q;
            pub_data_q <= 32'(uidx_q);
            uidx_q <= uidx_q + 16'd1;
            pub_q <= P_IDX;
          end
          P_IDX: pub_q <= P_ISR;
          P_ISR: begin
            pub_we_q <= 1'b0;
            isr_q <= isr_q | 32'd1;
            pub_q <= P_IDLE;
          end
          default: pub_q <= P_IDLE;
        endcase
      end
    end

    // irq pulses while a new ISR bit is set; isr_o is the sticky
    // register the TB acks
    assign irq_o = pub_q == P_ISR;
    assign isr_o = isr_q;
    assign done_o = pub_q == P_ISR;
  end
endmodule

// Fixture wrapper for the *_SYNTH=1 screens.
module g6lc_apu_vgtop_fixture
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vnfront_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Rings  = 4,
  parameter int unsigned Fences = 16,
  parameter int unsigned PayWords = 16384,
  parameter int unsigned VgPages      = 256,
  parameter int unsigned VgPageBytes  = 4096,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [15:0]     chain_id_i,
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  input  logic [63:0]     chain_uelem_addr_i,
  input  logic [63:0]     chain_uidx_addr_i,
  output logic            mem_re_o,
  output logic            mem_we_o,
  output logic [63:0]     mem_addr_o,
  output logic [31:0]     mem_wdata_o,
  input  logic [31:0]     mem_rdata_i,
  output logic            ap_re_o,
  output logic [17:0]     ap_raddr_o,
  output logic            ap_we_o,
  output logic [17:0]     ap_waddr_o,
  output logic [31:0]     ap_wdata_o,
  input  logic [31:0]     ap_rdata_i,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  output logic               sh_mem_re_o,
  output logic               sh_mem_we_o,
  output logic [63:0]        sh_mem_addr_o,
  output logic [63:0]        sh_mem_wdata_o,
  output logic [7:0]         sh_mem_wstrb_o,
  input  logic [63:0]        sh_mem_rdata_i,
  output logic            done_o,
  output logic            irq_o,
  output logic [31:0]     isr_o,
  input  logic            isr_ack_i,
  output logic            fence_pulse_o,
  output logic [63:0]     fence_id_o,
  output logic [7:0]      fence_ring_o,
  output logic [Rings-1:0]       ring_active_o,
  output logic [Rings-1:0][31:0] ring_status_o,
  output logic [Rings-1:0][31:0] ring_head_o,
  output logic [Rings-1:0][17:0] ring_extra_w_o,
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
    .PayWords(PayWords), .VgPages(VgPages), .VgPageBytes(VgPageBytes),
    .ShaderRegs(ShaderRegs), .MaxWaves(MaxWaves),
    .ShaderIds(ShaderIds), .ShaderSlots(ShaderSlots),
    .ShaderWords(ShaderWords), .ShaderInit(ShaderInit),
    .ShaderMembers(ShaderMembers), .ScratchBytes(ScratchBytes),
    .SlabBytes(SlabBytes), .ShaderBudget(ShaderBudget)) i_dut (.*);
endmodule
