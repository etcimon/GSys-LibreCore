// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Venus system composition (§6c Settled bullet 5 of
// architecture/uncore/apu-vulkan-engine.md): g6lc_apu_vqwalk +
// g6lc_apu_vgtop + g6lc_apu_apmem — a virtqueue walker, the engine
// composition, and one shared AXI4 master serving all five apu_mp
// requesters.
//
// apu_mp port map (fixed priority, index 0 highest):
//   0 PUB  — unused here (vqwalk publishes the used ring itself)
//   1 VQ   — g6lc_apu_vqwalk (guest, dom=0)
//   2 CTL  — vgtop mp[0] (vgctl, guest, dom=0)
//   3 PUMP — vgtop mp[1] (vnpump, dom selects aperture/execbuffer)
//   4 SH   — vgtop mp[2] (ShaderCore LSU, aperture, dom=1)
//
// Reset (§6c bullet 5): reset_req_i flushes apmem (non-issued requests
// dropped, issued transactions always complete) and clears the walker
// immediately; once apmem reports no transaction in flight, a
// registered soft_q holds the engine reset eng_rst_n = rst_ni & ~soft_q
// low for 4 cycles (vgtop and everything under it take eng_rst_n as
// their rst_ni — the one sanctioned registered-reset exception).
// reset_done_o is a level that rises after those 4 cycles and stays
// until reset_req_i drops.  idle_o = walker idle && engines drained
// && no AXI outstanding.
//
// Timing impact: the mp fan-in is apmem's fixed-priority mux; vgsys
// adds only the 2-bit reset FSM and eng_rst_n gating.  No new clock.
// Review checklist: always_ff/always_comb split, async active-low
// reset only (eng_rst_n registered per §6c), no latches, Enable=0
// constant-zero netlist, no initial outside translate_off.
module g6lc_apu_vgsys
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_mp_pkg::*;
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
  // vgtop geometry, passed through
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
  parameter int unsigned ShaderBudget  = 32'h0010_0000,
  // 1: non-dispatch cmdexec records go to the external work_* port (TB
  // sink).  0 (§6c F1 SoC seam): refuse them truthfully — answered
  // APU_SH_DONE_UNSUPPORTED one cycle after accept, so cmdexec marks
  // the submission DEVICE_LOST exactly like an unsupported dispatch.
  parameter bit          WorkSink = 1'b1,
  // §12.3 C/5a: the Xfer engine derives its internal DMA view from this
  parameter g6lc_apu_cfg_pkg::apu_cfg_t ApuCfg = g6lc_apu_cfg_pkg::ApuVenus
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  // virtqueue snapshots + doorbells
  input  g6lc_apu_pkg::apu_vq_state_t vq0_i,
  input  g6lc_apu_pkg::apu_vq_state_t vq1_i,
  input  logic [1:0]      queue_enable_i,
  input  logic [1:0]      notify_i,          // level: pending until clear
  output logic [1:0]      notify_clear_o,
  // used-ring publication event (after the used.idx beat's response)
  output logic            used_valid_o,
  output logic [31:0]     used_qid_o,
  output logic [31:0]     used_len_o,
  input  logic            used_ready_i,
  output logic [1:0][15:0] last_avail_o,   // TB observation
  // engine reset (§6c): level request / level done
  input  logic            reset_req_i,
  output logic            reset_done_o,
  output logic            idle_o,
  output logic            bus_fault_o,     // walker ring fault or
                                           // engine write fault,
                                           // sticky until reset_req_i
  // shared AXI4 master (single outstanding, single beat)
  output apu_dma_axi_req_t dma_req_o,
  input  apu_dma_axi_resp_t dma_rsp_i,
  // window descriptors
  input  logic [63:0]     guest_base_i,
  input  logic [63:0]     guest_bytes_i,
  input  logic [63:0]     ap_base_i,
  input  logic [63:0]     ap_bytes_i,
  output logic [31:0]     fault_cnt_o,
  // command-executor work port (TB work sink; dispatch-class records
  // are consumed internally by the ShaderCore)
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  // engine observability, passed through from vgtop
  output logic            done_o,
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
    assign notify_clear_o = '0;
    assign used_valid_o   = 1'b0;
    assign used_qid_o     = '0;
    assign used_len_o     = '0;
    assign last_avail_o   = '0;
    assign reset_done_o   = 1'b0;
    assign idle_o         = 1'b1;
    assign bus_fault_o    = 1'b0;
    assign dma_req_o      = '0;
    assign fault_cnt_o    = '0;
    assign work_valid_o   = 1'b0;
    assign work_o         = '0;
    assign done_o         = 1'b0;
    assign fence_pulse_o  = 1'b0;
    assign fence_id_o     = '0;
    assign fence_ring_o   = '0;
    for (genvar g = 0; g < Rings; g++) begin : g_off_ring
      assign ring_active_o[g] = 1'b0;
      assign ring_status_o[g] = '0;
      assign ring_head_o[g]   = '0;
      assign ring_extra_w_o[g] = '0;
    end
    assign objtab_live_o  = '0;
    assign dbg_ot_ready_o = 1'b0;
    assign dbg_ot_cpl_valid_o = 1'b0;
    assign dbg_ot_cpl_o   = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | reset_req_i |
                    (|vq0_i) | (|vq1_i) | (|queue_enable_i) |
                    (|notify_i) | used_ready_i | (|dma_rsp_i) |
                    (|guest_base_i) | (|guest_bytes_i) |
                    (|ap_base_i) | (|ap_bytes_i) |
                    work_ready_i | work_done_i | (|work_done_pl_i) |
                    dbg_ot_valid_i | dbg_ot_cpl_ready_i |
                    (|dbg_ot_req_i);
  end else begin : gen_on

    // ---- engine reset sequencer -------------------------------------
    typedef enum logic [1:0] { RIdle, RFlush, RSoft, RDone } rst_e;
    rst_e       rst_q;
    logic [2:0] soft_cnt_q;
    logic       soft_q;
    logic       eng_rst_n;

    assign eng_rst_n    = rst_ni & ~soft_q;
    assign reset_done_o = rst_q == RDone;

    // ---- mp bus -----------------------------------------------------
    logic [APU_MP_N-1:0]      mp_req_valid, mp_req_ready, mp_rsp_valid;
    apu_mp_req_t [APU_MP_N-1:0] mp_req;
    apu_mp_rsp_t [APU_MP_N-1:0] mp_rsp;
    logic                     mem_outst, mem_idle;
    logic                     apflush;
    // xfer join signals are declared before first use (slang strict
    // ordering); see the tdma join below.
    logic                     xfer_busy;
    logic                     xf_flush;
    apu_dma_axi_req_t         mem_axi_req, xf_axi_req;
    apu_dma_axi_resp_t        mem_axi_rsp, xf_axi_rsp;

    // port 0 (PUB) is unused: vqwalk publishes used elements itself
    assign mp_req_valid[APU_MP_PUB] = 1'b0;
    assign mp_req[APU_MP_PUB]       = '0;

    g6lc_apu_apmem #(.Enable(1'b1), .N(APU_MP_N)) i_mem (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .flush_i(apflush),
      .req_valid_i(mp_req_valid), .req_ready_o(mp_req_ready),
      .req_i(mp_req),
      .rsp_valid_o(mp_rsp_valid), .rsp_o(mp_rsp),
      .guest_base_i(guest_base_i), .guest_bytes_i(guest_bytes_i),
      .ap_base_i(ap_base_i), .ap_bytes_i(ap_bytes_i),
      .axi_req_o(mem_axi_req), .axi_rsp_i(mem_axi_rsp),
      .outstanding_o(mem_outst), .fault_cnt_o(fault_cnt_o),
      .idle_o(mem_idle));

    // ---- Xfer AXI join (§12.3 C/5a) -----------------------------------
    // xfer's checked-DMA pair presents one AXI master; g6lc_apu_tdma
    // joins it with apmem's — apmem keeps the winning (a) port and xfer
    // takes (b), waiting for an idle window.  tdma locks the granted
    // port for the whole transaction, so ports serialize per burst
    // while xfer's own read burst and write round trips still overlap
    // inside port b.
    g6lc_apu_tdma #(.Enable(1'b1)) i_tdma (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .a_req_i(mem_axi_req), .a_rsp_o(mem_axi_rsp),
      .b_req_i(xf_axi_req),  .b_rsp_o(xf_axi_rsp),
      .mst_req_o(dma_req_o), .mst_rsp_i(dma_rsp_i));

    // ---- virtqueue walker -------------------------------------------
    logic        vw_idle, vw_cpl_rdy, vw_fault;
    logic        vw_chain_v, vw_chain_rdy;
    logic [15:0] vw_chain_id;
    logic [3:0]  vw_chain_n;
    apu_vg_desc_t [APU_VG_MAX_DESC-1:0] vw_chain_desc;
    logic        vg_cpl_v;
    logic [31:0] vg_cpl_len;
    logic        vg_busy, vg_fault;

    g6lc_apu_vqwalk #(.Enable(1'b1)) i_vq (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .reset_req_i(reset_req_i),
      .vq0_i(vq0_i), .vq1_i(vq1_i),
      .queue_enable_i(queue_enable_i),
      .notify_i(notify_i), .notify_clear_o(notify_clear_o),
      .mp_req_valid_o(mp_req_valid[APU_MP_VQ]),
      .mp_req_ready_i(mp_req_ready[APU_MP_VQ]),
      .mp_req_o(mp_req[APU_MP_VQ]),
      .mp_rsp_valid_i(mp_rsp_valid[APU_MP_VQ]),
      .mp_rsp_i(mp_rsp[APU_MP_VQ]),
      .chain_valid_o(vw_chain_v), .chain_ready_i(vw_chain_rdy),
      .chain_id_o(vw_chain_id), .chain_n_o(vw_chain_n),
      .chain_desc_o(vw_chain_desc),
      .cpl_valid_i(vg_cpl_v), .cpl_ready_o(vw_cpl_rdy),
      .cpl_len_i(vg_cpl_len),
      .used_valid_o(used_valid_o), .used_qid_o(used_qid_o),
      .used_len_o(used_len_o), .used_ready_i(used_ready_i),
      .bus_fault_o(vw_fault), .idle_o(vw_idle),
      .last_avail_o(last_avail_o));

    // ---- work port ---------------------------------------------------
    logic              ws_v, ws_rdy, ws_done;
    apu_cmdexec_work_t ws_work;
    apu_sh_done_t      ws_done_pl;

    if (WorkSink) begin : gen_ws_ext
      assign work_valid_o = ws_v;
      assign work_o       = ws_work;
      assign ws_rdy       = work_ready_i;
      assign ws_done      = work_done_i;
      assign ws_done_pl   = work_done_pl_i;
    end else begin : gen_ws_refuse
      // One outstanding refusal: ready while no done is pending, the
      // registered pulse carries the same payload shcore emits for a
      // DispatchIndirect record (UNSUPPORTED -> DEVICE_LOST).
      logic refuse_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) refuse_q <= 1'b0;
        else         refuse_q <= ws_v && ws_rdy;
      end
      assign work_valid_o = 1'b0;
      assign work_o       = '0;
      assign ws_rdy       = !refuse_q;
      assign ws_done      = refuse_q;
      assign ws_done_pl   = '{code: APU_SH_DONE_UNSUPPORTED, wave: '0,
                             pc: '0, robust: '0, work_id: '0};
      logic unused_ws;
      assign unused_ws = work_ready_i | work_done_i | (|work_done_pl_i) |
                         (|ws_work);
    end

    // ---- engine composition ------------------------------------------
    // vgtop mp[0..2] map onto apmem ports CTL=2, PUMP=3, SH=4.
    g6lc_apu_vgtop #(
      .Enable(1'b1), .Rings(Rings), .Fences(Fences),
      .PayWords(PayWords), .VgPages(VgPages), .VgPageBytes(VgPageBytes),
      .ShaderRegs(ShaderRegs), .MaxWaves(MaxWaves),
      .ShaderIds(ShaderIds), .ShaderSlots(ShaderSlots),
      .ShaderWords(ShaderWords), .ShaderInit(ShaderInit),
      .ShaderMembers(ShaderMembers), .ScratchBytes(ScratchBytes),
      .SlabBytes(SlabBytes), .ShaderBudget(ShaderBudget),
      .ApuCfg(ApuCfg)) i_top (
      .clk_i(clk_i), .rst_ni(eng_rst_n), .testmode_i(testmode_i),
      .chain_valid_i(vw_chain_v), .chain_ready_o(vw_chain_rdy),
      .chain_id_i(vw_chain_id), .chain_n_i(vw_chain_n),
      .chain_desc_i(vw_chain_desc),
      .cpl_valid_o(vg_cpl_v), .cpl_ready_i(vw_cpl_rdy),
      .cpl_len_o(vg_cpl_len), .mem_fault_o(vg_fault),
      .mp_req_valid_o(mp_req_valid[APU_MP_SH:APU_MP_CTL]),
      .mp_req_ready_i(mp_req_ready[APU_MP_SH:APU_MP_CTL]),
      .mp_req_o(mp_req[APU_MP_SH:APU_MP_CTL]),
      .mp_rsp_valid_i(mp_rsp_valid[APU_MP_SH:APU_MP_CTL]),
      .mp_rsp_i(mp_rsp[APU_MP_SH:APU_MP_CTL]),
      .work_valid_o(ws_v), .work_ready_i(ws_rdy),
      .work_o(ws_work),
      .work_done_i(ws_done), .work_done_pl_i(ws_done_pl),
      .xf_axi_req_o(xf_axi_req), .xf_axi_rsp_i(xf_axi_rsp),
      .ap_base_i(ap_base_i), .xf_flush_i(xf_flush),
      .xfer_busy_o(xfer_busy),
      .done_o(done_o), .busy_o(vg_busy),
      .fence_pulse_o(fence_pulse_o), .fence_id_o(fence_id_o),
      .fence_ring_o(fence_ring_o),
      .ring_active_o(ring_active_o), .ring_status_o(ring_status_o),
      .ring_head_o(ring_head_o), .ring_extra_w_o(ring_extra_w_o),
      .objtab_live_o(objtab_live_o),
      .dbg_ot_valid_i(dbg_ot_valid_i), .dbg_ot_ready_o(dbg_ot_ready_o),
      .dbg_ot_req_i(dbg_ot_req_i),
      .dbg_ot_cpl_valid_o(dbg_ot_cpl_valid_o),
      .dbg_ot_cpl_ready_i(dbg_ot_cpl_ready_i),
      .dbg_ot_cpl_o(dbg_ot_cpl_o));

    assign apflush = rst_q == RFlush || reset_req_i;
    // §12.3 C/5a: the Xfer engine gets the same cancel-and-drain as
    // apmem; its busy stays up until both DMA legs have retired or
    // halted, which is what RFlush waits on before eng_rst_n falls
    assign xf_flush = apflush;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rst_q      <= RIdle;
        soft_q     <= 1'b0;
        soft_cnt_q <= '0;
      end else begin
        unique case (rst_q)
          RIdle: begin
            soft_q <= 1'b0;
            if (reset_req_i) rst_q <= RFlush;
          end
          RFlush: begin
            // apmem drops non-issued requests; an in-flight AXI
            // transaction must drain before the engines reset — same
            // for the Xfer engine's DMA pair (§12.3 C/5a)
            if (!mem_outst && !xfer_busy) begin
              soft_q     <= 1'b1;
              soft_cnt_q <= 3'd4;
              rst_q      <= RSoft;
            end
          end
          RSoft: begin
            if (soft_cnt_q <= 3'd1) begin
              soft_q <= 1'b0;
              rst_q  <= RDone;
            end else
              soft_cnt_q <= soft_cnt_q - 3'd1;
          end
          RDone: begin
            if (!reset_req_i) rst_q <= RIdle;
          end
          default: rst_q <= RIdle;
        endcase
      end
    end

    // either fault source is sticky until its owner resets: the
    // walker on reset_req_i, vgctl's write fault on eng_rst_n
    assign bus_fault_o = vw_fault | vg_fault;

    assign idle_o = vw_idle && !vg_busy && !mem_outst && mem_idle &&
                    rst_q == RIdle;
  end
endmodule

// Fixture wrapper for the *_SYNTH=1 screens.
module g6lc_apu_vgsys_fixture
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_mp_pkg::*;
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
  parameter int unsigned ShaderBudget  = 32'h0010_0000,
  parameter bit          WorkSink = 1'b1
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  g6lc_apu_pkg::apu_vq_state_t vq0_i,
  input  g6lc_apu_pkg::apu_vq_state_t vq1_i,
  input  logic [1:0]      queue_enable_i,
  input  logic [1:0]      notify_i,
  output logic [1:0]      notify_clear_o,
  output logic            used_valid_o,
  output logic [31:0]     used_qid_o,
  output logic [31:0]     used_len_o,
  input  logic            used_ready_i,
  output logic [1:0][15:0] last_avail_o,
  input  logic            reset_req_i,
  output logic            reset_done_o,
  output logic            idle_o,
  output logic            bus_fault_o,
  output apu_dma_axi_req_t dma_req_o,
  input  apu_dma_axi_resp_t dma_rsp_i,
  input  logic [63:0]     guest_base_i,
  input  logic [63:0]     guest_bytes_i,
  input  logic [63:0]     ap_base_i,
  input  logic [63:0]     ap_bytes_i,
  output logic [31:0]     fault_cnt_o,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  input  apu_sh_done_t       work_done_pl_i,
  output logic            done_o,
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
  g6lc_apu_vgsys #(
    .Enable(Enable), .Rings(Rings), .Fences(Fences),
    .PayWords(PayWords), .VgPages(VgPages), .VgPageBytes(VgPageBytes),
    .ShaderRegs(ShaderRegs), .MaxWaves(MaxWaves),
    .ShaderIds(ShaderIds), .ShaderSlots(ShaderSlots),
    .ShaderWords(ShaderWords), .ShaderInit(ShaderInit),
    .ShaderMembers(ShaderMembers), .ScratchBytes(ScratchBytes),
    .SlabBytes(SlabBytes), .ShaderBudget(ShaderBudget),
    .WorkSink(WorkSink)) i_dut (.*);
endmodule
