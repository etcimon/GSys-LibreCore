// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-010A formal wrapper for the register block: free AXI-Lite master,
// free observation inputs. Safety: response stability, no effect on
// IRQ_ENABLE/DRAIN_TOKEN/FAULTS from RO/unmapped writes, irq_o equals the
// previous cycle's |(pending & enable). Covers: SLVERR read, IRQ_ENABLE
// write + read-back, drain done.
module formal_g6lc_storamic_regs (
  input logic clk_i,
  input logic rst_ni,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  input logic service_ready_i,
  input logic model_ready_i,
  input logic sequence_exhausted_i,
  input logic [2:0] faults_i,
  input logic stray_i,
  input logic [1:0] txn_accept_i,
  input logic [1:0] txn_refuse_i,
  input logic [1:0] txn_retire_i,
  input logic [1:0] txn_error_i,
  input logic inflight_i,
  input logic [2:0][3:0] slot_state_i,
  input logic [2:0][3:0] slot_fault_i,
  input logic [2:0] slot_dup_i,
  input g6lc_storamic_region_pkg::slot_map_t slot_map_i,
  input logic [2:0] slot_fault_event_i,
  input logic [2:0] slot_ready_event_i,
  output logic cover_slverr_o,
  output logic cover_irqen_o,
  output logic cover_drain_o,
  output logic cover_commit_ok_o,
  output logic cover_commit_fail_o
);
  g6lc_storamic_pkg::axil_resp_t cresp;
  logic [2:0] squi, sfcl;
  logic irq;

  g6lc_storamic_regs #(
    .Cfg(g6lc_storamic_cfg_pkg::StoramicModel), .Slots(3), .Regions(4),
    .DataWidth(64)
  ) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0), .ctrl_req_i, .ctrl_resp_o(cresp),
    .service_ready_i, .model_ready_i, .sequence_exhausted_i, .faults_i,
    .stray_i, .txn_accept_i, .txn_refuse_i, .txn_retire_i, .txn_error_i,
    .inflight_i, .slot_state_i, .slot_fault_i, .slot_dup_i, .slot_map_i,
    .slot_fault_event_i, .slot_ready_event_i,
    .slot_quiesce_o(squi), .slot_fault_clear_o(sfcl), .irq_o(irq)
  );

  // Master handshake discipline (assumptions on the free inputs): a held
  // channel keeps its payload stable until accepted.
  logic prev_awh, prev_wh, prev_arh;
  logic [63:0] prev_aw_addr, prev_ar_addr;
  logic [31:0] prev_wdata;
  logic [3:0] prev_wstrb;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_awh <= 0; prev_wh <= 0; prev_arh <= 0;
    end else begin
      prev_awh <= ctrl_req_i.aw_valid && !cresp.aw_ready;
      prev_wh <= ctrl_req_i.w_valid && !cresp.w_ready;
      prev_arh <= ctrl_req_i.ar_valid && !cresp.ar_ready;
      prev_aw_addr <= ctrl_req_i.aw.addr;
      prev_ar_addr <= ctrl_req_i.ar.addr;
      prev_wdata <= ctrl_req_i.w.data;
      prev_wstrb <= ctrl_req_i.w.strb;
      if (prev_awh) begin
        assume (ctrl_req_i.aw_valid && ctrl_req_i.aw.addr == prev_aw_addr);
      end
      if (prev_wh) begin
        assume (ctrl_req_i.w_valid && ctrl_req_i.w.data == prev_wdata &&
                ctrl_req_i.w.strb == prev_wstrb);
      end
      if (prev_arh) begin
        assume (ctrl_req_i.ar_valid && ctrl_req_i.ar.addr == prev_ar_addr);
      end
    end
  end

  logic wr_go;
  logic [11:0] wr_addr;
  assign wr_go = (dut.aw_v || ctrl_req_i.aw_valid) &&
                 (dut.w_v || ctrl_req_i.w_valid) && !dut.b_v;
  assign wr_addr = dut.aw_v ? dut.aw_a : ctrl_req_i.aw.addr[11:0];

  // Held responses are stable; illegal writes are answered SLVERR; irq_o is
  // the registered level of pending & enable.
  logic prev_bhold, prev_rhold, prev_pend_en;
  logic [1:0] prev_bresp, prev_rresp;
  logic [31:0] prev_rdata;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_bhold <= 0; prev_rhold <= 0; prev_pend_en <= 0;
      prev_bresp <= 0; prev_rresp <= 0; prev_rdata <= 0;
    end else begin
      prev_bhold <= cresp.b_valid && !ctrl_req_i.b_ready;
      prev_rhold <= cresp.r_valid && !ctrl_req_i.r_ready;
      prev_bresp <= cresp.b.resp; prev_rresp <= cresp.r.resp;
      prev_rdata <= cresp.r.data;
      prev_pend_en <= |(dut.irq_pending_q & dut.irq_enable_q);
      if (prev_bhold)
        assert (cresp.b_valid && cresp.b.resp == prev_bresp);
      if (prev_rhold)
        assert (cresp.r_valid && cresp.r.resp == prev_rresp &&
                cresp.r.data == prev_rdata);
      // A write to an unmapped or RO offset must be answered SLVERR (which
      // also means it cannot modify IRQ_ENABLE/DRAIN_TOKEN/FAULTS).
      if (wr_go && !(wr_addr == 12'h018 || wr_addr == 12'h024 ||
                     wr_addr == 12'h014 || wr_addr == 12'h01C ||
                     (wr_addr >= 12'h100 && wr_addr < 12'h400 &&
                      wr_addr[4:0] == 5'h18 && dut.w_slot < 3)))
        assert (dut.wr_err);
      assert (irq == prev_pend_en);
    end
  end

  // Covers.
  logic cov_slverr, cov_irqen, cov_drain;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cov_slverr <= 0; cov_irqen <= 0; cov_drain <= 0;
    end else begin
      if (cresp.r_valid && cresp.r.resp == 2'b10) cov_slverr <= 1;
      if (wr_go && wr_addr == 12'h018 && !dut.wr_err &&
          dut.wr_data[3:0] != 0)
        cov_irqen <= 1;
      if (dut.drain_done_ev) cov_drain <= 1;
    end
  end
  assign cover_slverr_o = cov_slverr;
  assign cover_irqen_o = cov_irqen;
  assign cover_drain_o = cov_drain;

  // ST-010B runtime-map instance: mapped profile, BootMapEn=0, 2 slots.
  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t RtCfg = '{
    Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
    MaxSticks: 2, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0};
  g6lc_storamic_pkg::axil_resp_t rresp;
  logic rt_mv;
  g6lc_storamic_region_pkg::slot_map_t rt_so;
  g6lc_storamic_region_pkg::region_map_t rt_ro;
  g6lc_storamic_regs #(
    .Cfg(RtCfg), .Slots(2), .Regions(2), .DataWidth(64), .BootMapEn(1'b0)
  ) dut_rt (
    .clk_i, .rst_ni, .testmode_i(1'b0),
    .ctrl_req_i, .ctrl_resp_o(rresp),
    .service_ready_i, .model_ready_i, .sequence_exhausted_i, .faults_i,
    .stray_i, .txn_accept_i, .txn_refuse_i, .txn_retire_i, .txn_error_i,
    .inflight_i, .slot_state_i('0), .slot_fault_i('0), .slot_dup_i('0),
    .slot_map_i, .slot_fault_event_i(slot_fault_event_i[1:0]),
    .slot_ready_event_i(slot_ready_event_i[1:0]),
    .slot_quiesce_o(), .slot_fault_clear_o(), .irq_o(),
    .map_valid_o(rt_mv), .slot_map_o(rt_so), .region_map_o(rt_ro)
  );

  // After commit the committed map and map_valid are immutable; map_valid
  // implies committed.
  g6lc_storamic_region_pkg::region_map_t prev_cmap;
  g6lc_storamic_region_pkg::slot_map_t prev_cslots;
  logic prev_committed, was_committed;
  logic cov_commit_ok, cov_commit_fail;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_committed <= 0; was_committed <= 0;
      cov_commit_ok <= 0; cov_commit_fail <= 0;
    end else begin
      was_committed <= was_committed || dut_rt.committed_q;
      prev_committed <= dut_rt.committed_q;
      prev_cmap <= dut_rt.committed_map_q;
      prev_cslots <= dut_rt.committed_slots_q;
      if (dut_rt.committed_q) begin
        assert (rt_mv);
        if (was_committed) begin
          assert (dut_rt.committed_map_q == prev_cmap);
          assert (dut_rt.committed_slots_q == prev_cslots);
        end
      end
      // Staged writes have no effect while busy or committed.
      if ((dut_rt.busy_q || dut_rt.committed_q) && dut_rt.wr_go &&
          dut_rt.wr_addr >= 12'h400)
        assert (dut_rt.wr_err);
      if (dut_rt.committed_q && !prev_committed &&
          dut_rt.status_q == g6lc_storamic_region_pkg::MapOk)
        cov_commit_ok <= 1;
      if (dut_rt.commit_evt_q && dut_rt.commit_err_q)
        cov_commit_fail <= 1;
    end
  end
  assign cover_commit_ok_o = cov_commit_ok;
  assign cover_commit_fail_o = cov_commit_fail;
endmodule
