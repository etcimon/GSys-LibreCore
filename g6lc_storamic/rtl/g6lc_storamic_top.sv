// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_storamic_top #(
  parameter g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg =
      g6lc_storamic_cfg_pkg::StoramicOff,
  parameter type req_t = g6lc_storamic_pkg::axi_req_t,
  parameter type resp_t = g6lc_storamic_pkg::axi_resp_t,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned SeqWidth = 32,
  parameter int unsigned Slots = Cfg.MaxSticks > 0 ? Cfg.MaxSticks : 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input req_t req_i,
  output resp_t resp_o,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  output logic init_done_o,
  output logic service_ready_o,
  output logic [Slots-1:0] media_ready_o,
  output g6lc_storamic_pad_pkg::pad_out_t [Slots-1:0] pad_o,
  input logic [7:0] source_i,
  input logic [31:0] reset_generation_i,
  output logic model_ready_o,
  output logic sequence_exhausted_o,
  output logic [2:0] faults_o,
  output g6lc_storamic_pkg::model_events_t events_o,
  input logic mem_ready_i,
  output logic mem_req_o,
  input logic mem_gnt_i,
  output logic mem_we_o,
  output logic [63:0] mem_addr_o,
  output logic [DataWidth-1:0] mem_wdata_o,
  output logic [(DataWidth >= 8 ? DataWidth/8 : 1)-1:0] mem_be_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  input logic mem_rvalid_i,
  input logic [DataWidth-1:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i
);
  localparam bit CfgLegal = g6lc_storamic_cfg_pkg::cfg_legal(Cfg) &&
      Slots == (Cfg.MaxSticks > 0 ? Cfg.MaxSticks : 1);
  g6lc_storamic_pkg::axi_req_t ctrl_req;
  g6lc_storamic_pkg::axi_resp_t ctrl_resp;

  if (!CfgLegal) begin : gen_illegal
    // pragma translate_off
    initial $fatal(1, "STORAMIC_CONFIG_ILLEGAL");
    // pragma translate_on
  end

  assign init_done_o = model_ready_o;
  assign media_ready_o = '0;
  for (genvar slot = 0; slot < Slots; slot++) begin : gen_pad
    assign pad_o[slot] = g6lc_storamic_pad_pkg::PadSafe;
  end

  if (CfgLegal && Cfg.Profile == g6lc_storamic_cfg_pkg::ProfileModel) begin : gen_model
    assign model_ready_o = service_ready_o && mem_ready_i;
    g6lc_storamic_axi_memory #(
      .DataWidth(DataWidth), .SeqWidth(SeqWidth), .BaseAddr(Cfg.ModelBase),
      .RegionBytes(Cfg.ModelBytes), .req_t(req_t), .resp_t(resp_t)
    ) i_data (
      .clk_i, .rst_ni, .testmode_i, .req_i, .resp_o,
      .source_i, .reset_generation_i, .service_ready_o,
      .sequence_exhausted_o, .faults_o, .events_o,
      .mem_ready_i, .mem_req_o, .mem_gnt_i, .mem_we_o, .mem_addr_o,
      .mem_wdata_o, .mem_be_o, .mem_tag_o,
      .mem_rvalid_i, .mem_rdata_i, .mem_error_i, .mem_tag_i
    );
  end else begin : gen_refuse
    assign service_ready_o = rst_ni && CfgLegal;
    assign model_ready_o = 1'b0;
    assign sequence_exhausted_o = 1'b0;
    assign faults_o = '0;
    assign events_o = '0;
    assign mem_req_o = 1'b0;
    assign mem_we_o = 1'b0;
    assign mem_addr_o = '0;
    assign mem_wdata_o = '0;
    assign mem_be_o = '0;
    assign mem_tag_o = '0;
    g6lc_storamic_axi_refuse #(.req_t(req_t), .resp_t(resp_t)) i_data (
      .clk_i, .rst_ni, .req_i, .resp_o
    );
  end

  always_comb begin
    ctrl_req = '0;
    ctrl_req.aw_valid = ctrl_req_i.aw_valid;
    ctrl_req.w_valid = ctrl_req_i.w_valid;
    ctrl_req.w.last = 1'b1;
    ctrl_req.b_ready = ctrl_req_i.b_ready;
    ctrl_req.ar_valid = ctrl_req_i.ar_valid;
    ctrl_req.r_ready = ctrl_req_i.r_ready;
    ctrl_resp_o = '0;
    ctrl_resp_o.aw_ready = ctrl_resp.aw_ready;
    ctrl_resp_o.w_ready = ctrl_resp.w_ready;
    ctrl_resp_o.b.resp = ctrl_resp.b.resp;
    ctrl_resp_o.b_valid = ctrl_resp.b_valid;
    ctrl_resp_o.ar_ready = ctrl_resp.ar_ready;
    ctrl_resp_o.r.resp = ctrl_resp.r.resp;
    ctrl_resp_o.r_valid = ctrl_resp.r_valid;
  end

  g6lc_storamic_axi_refuse i_control (
    .clk_i, .rst_ni, .req_i(ctrl_req), .resp_o(ctrl_resp)
  );
endmodule
