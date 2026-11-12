// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`include "axi/typedef.svh"
// Separate test wrapper: existing non-debug model identities remain intact.
module g6lc_storamic_cpu_debug_netlist #(
  parameter bit OriginEnabled = 1,
  // When 1, enable SDTRIG + Mcontrol6 so mcontrol6 tdata triggers can enter
  // debug mode. Default 0 preserves the existing cpu-debug/cpu-origin image.
  parameter bit Sdtrig = 0
) (
  input logic clk, rst_n, debug_req,
  output logic awv, input logic awr,
  output logic [63:0] awa,
  output logic [7:0] awid, awlen,
  output logic [2:0] awprot, awsize,
  output logic [5:0] awatop,
  output logic wv, input logic wr,
  output logic [63:0] wd,
  output logic [7:0] ws,
  output logic wl,
  input logic bv, output logic br,
  input logic [7:0] bid,
  input logic [1:0] bresp,
  output logic arv, input logic arr,
  output logic [63:0] ara,
  output logic [7:0] arid, arlen,
  output logic [2:0] arprot, arsize,
  input logic rv, output logic rr,
  input logic [63:0] rd,
  input logic [7:0] rid,
  input logic rl,
  input logic [1:0] rresp
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
    if (OriginEnabled) begin
      c.StoramicEn = 1;
      c.StoramicIoEn = 1;
      c.StoramicCheckpointEn = 1;
    end
    if (Sdtrig) begin
      c.SDTRIG = 1;
      c.Mcontrol6 = 1;
    end
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  typedef logic [Cfg.AxiAddrWidth-1:0] addr_t;
  typedef logic [Cfg.AxiIdWidth-1:0] id_t;
  typedef logic [Cfg.AxiDataWidth-1:0] data_t;
  typedef logic [Cfg.AxiDataWidth/8-1:0] strb_t;
  typedef logic [Cfg.AxiUserWidth-1:0] user_t;
  `AXI_TYPEDEF_ALL(cpu, addr_t, id_t, data_t, strb_t, user_t)
  cpu_req_t req;
  cpu_resp_t resp;
  assign awv = req.aw_valid;
  assign awa = req.aw.addr;
  assign awid = 8'(req.aw.id);
  assign awlen = req.aw.len;
  assign awprot = req.aw.prot;
  assign awsize = req.aw.size;
  assign awatop = req.aw.atop;
  assign wv = req.w_valid;
  assign wd = req.w.data;
  assign ws = req.w.strb;
  assign wl = req.w.last;
  assign br = req.b_ready;
  assign arv = req.ar_valid;
  assign ara = req.ar.addr;
  assign arid = 8'(req.ar.id);
  assign arlen = req.ar.len;
  assign arprot = req.ar.prot;
  assign arsize = req.ar.size;
  assign rr = req.r_ready;
  always_comb begin
    resp = '0;
    resp.aw_ready = awr;
    resp.w_ready = wr;
    resp.b_valid = bv;
    resp.b.id = id_t'(bid);
    resp.b.resp = bresp;
    resp.ar_ready = arr;
    resp.r_valid = rv;
    resp.r.id = id_t'(rid);
    resp.r.data = rd;
    resp.r.last = rl;
    resp.r.resp = rresp;
  end
  cva6 #(.CVA6Cfg(Cfg), .noc_req_t(cpu_req_t), .noc_resp_t(cpu_resp_t)) cpu (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(64'h8000_0000), .hart_id_i('0),
    .irq_i('0), .ipi_i('0), .time_irq_i('0), .rtc_time_i('0), .debug_req_i(debug_req),
    .core_wfi_all_o(), .core_wake_o(), .rvfi_probes_o(), .cvxif_req_o(), .cvxif_resp_i('0),
    .ai_aicfg_o(), .ai_ais_o(), .ai_issue_ok_o(), .ai_q_en_o(), .ai_qid_o(),
    .dirty_ai_state_i(1'b0), .ai_setcfg_we_i(1'b0), .ai_setcfg_wdata_i('0),
    .ai_pmu_op_i(1'b0), .ai_pmu_mma_i(1'b0), .ai_pmu_post_i(1'b0),
    .ai_pmu_t0_i(1'b0), .ai_pmu_busy_i(1'b0), .noc_req_o(req), .noc_resp_i(resp),
    .l1_inval_addr_i('0), .l1_inval_valid_i(1'b0), .l1_inval_ready_o(),
    .cmo_valid_o(), .cmo_op_o(), .cmo_addr_o(), .cmo_ready_i(1'b0), .cmo_done_i(1'b0),
    .l2_miss_i(1'b0), .l3_hit_i(1'b0), .l3_miss_i(1'b0), .pf_issue_i(1'b0),
    .pf_train_i(1'b0), .l2_pwhold_i(1'b0), .l3_pwhold_i(1'b0),
    .l2_pf_issue_i(1'b0), .l2_pf_useful_i(1'b0),
    .coh_sf_filtered_i(1'b0), .coh_sf_broadcast_i(1'b0),
    .storamic_pause_i(1'b0), .storamic_drained_o()
  );
  initial begin
    assert(Cfg.FpPresent)
      else $fatal(1, "CPU_DEBUG_FIXTURE_CONFIGURED_FPU_REQUIRED");
    assert(Cfg.AxiAddrWidth == 64 && Cfg.AxiDataWidth == 64 && Cfg.AxiIdWidth <= 8)
      else $fatal(1, "CPU_DEBUG_FIXTURE_GEOMETRY");
    assert(Cfg.DebugEn && Cfg.DmBaseAddress == 0 &&
           Cfg.HaltAddress == 'h800 && Cfg.ExceptionAddress == 'h808)
      else $fatal(1, "CPU_DEBUG_FIXTURE_ADDRESS_PROFILE");
    assert(!OriginEnabled || config_pkg::g6lc_storamic_origin_supported(Cfg))
      else $fatal(1, "CPU_DEBUG_FIXTURE_ORIGIN_PROFILE");
  end
endmodule
