// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_storamic_top #(
  parameter g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg =
      g6lc_storamic_cfg_pkg::StoramicOff,
  parameter type req_t = g6lc_storamic_pkg::axi_req_t,
  parameter type resp_t = g6lc_storamic_pkg::axi_resp_t,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned SeqWidth = 32,
  parameter int unsigned Slots = Cfg.MaxSticks > 0 ? Cfg.MaxSticks : 1,
  parameter int unsigned Regions = 1,
  parameter g6lc_storamic_region_pkg::slot_map_t SlotMap = '0,
  parameter g6lc_storamic_region_pkg::region_map_t RegionMap = '0,
  // ST-010B: BootMapEn=0 defers the map to runtime commit via MAP_CTRL;
  // SlotMap/RegionMap then serve only as the synthetic discovery fixture.
  parameter bit BootMapEn = 1'b1
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
  output logic irq_o,
  input logic mem_ready_i,
  output logic mem_req_o,
  input logic mem_gnt_i,
  output logic mem_we_o,
  output logic [63:0] mem_addr_o,
  output logic [DataWidth-1:0] mem_wdata_o,
  output logic [(DataWidth >= 8 ? DataWidth/8 : 1)-1:0] mem_be_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  output logic [7:0] mem_slot_o,
  input logic mem_rvalid_i,
  input logic [DataWidth-1:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  input logic stray_i
);
  localparam bit CfgLegal = g6lc_storamic_cfg_pkg::cfg_legal(Cfg) &&
      Slots == (Cfg.MaxSticks > 0 ? Cfg.MaxSticks : 1);
  // ST-010A transaction counters feed the register block. An R burst counts
  // once as errored when any retired beat was SLVERR.
  logic inflight;
  logic map_valid;
  g6lc_storamic_region_pkg::slot_map_t map_slots;
  g6lc_storamic_region_pkg::region_map_t map_regions;
  logic [1:0] txn_accept, txn_refuse, txn_retire, txn_error;
  logic r_erred_q;
  logic r_last_hs;
  assign r_last_hs = events_o.r_retire && resp_o.r.last;
  assign txn_accept = 2'(events_o.aw_accept) + 2'(events_o.ar_accept);
  assign txn_refuse = 2'(events_o.aw_refuse) + 2'(events_o.ar_refuse);
  assign txn_retire = 2'(events_o.b_retire) + 2'(r_last_hs);
  assign txn_error = 2'(events_o.b_error) +
                     2'(r_last_hs && (events_o.r_error || r_erred_q));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) r_erred_q <= 1'b0;
    else if (events_o.r_error) r_erred_q <= 1'b1;
    else if (events_o.ar_accept) r_erred_q <= 1'b0;
  end

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
      .quiesce_i(1'b0), .quiesced_o(),
      .source_i, .reset_generation_i, .service_ready_o,
      .sequence_exhausted_o, .faults_o, .events_o, .inflight_o(inflight),
      .mem_ready_i, .mem_req_o, .mem_gnt_i, .mem_we_o, .mem_addr_o,
      .mem_wdata_o, .mem_be_o, .mem_tag_o, .mem_slot_o,
      .mem_rvalid_i, .mem_rdata_i, .mem_error_i, .mem_tag_i,
      .map_valid_i(1'b0), .slot_map_i('0), .region_map_i('0)
    );
  end else if (CfgLegal && Cfg.Profile == g6lc_storamic_cfg_pkg::ProfileMapped) begin : gen_mapped
    // The slot mux is an external binding helper consuming mem_slot_o; the
    // top keeps only the single mem_* seam plus the slot index. A runtime
    // map is ready only after a successful commit.
    assign model_ready_o = service_ready_o && mem_ready_i &&
                           (BootMapEn || map_valid);
    g6lc_storamic_axi_memory #(
      .DataWidth(DataWidth), .SeqWidth(SeqWidth), .MapEn(1'b1),
      .Slots(Cfg.MaxSticks), .Regions(Regions), .SlotMap(SlotMap),
      .RegionMap(RegionMap), .BootMapEn(BootMapEn),
      .req_t(req_t), .resp_t(resp_t)
    ) i_data (
      .clk_i, .rst_ni, .testmode_i, .req_i, .resp_o,
      .quiesce_i(1'b0), .quiesced_o(),
      .source_i, .reset_generation_i, .service_ready_o,
      .sequence_exhausted_o, .faults_o, .events_o, .inflight_o(inflight),
      .mem_ready_i, .mem_req_o, .mem_gnt_i, .mem_we_o, .mem_addr_o,
      .mem_wdata_o, .mem_be_o, .mem_tag_o, .mem_slot_o,
      .mem_rvalid_i, .mem_rdata_i, .mem_error_i, .mem_tag_i,
      .map_valid_i(map_valid), .slot_map_i(map_slots),
      .region_map_i(map_regions)
    );
  end else begin : gen_refuse
    assign service_ready_o = rst_ni && CfgLegal;
    assign inflight = 1'b0;
    assign mem_slot_o = '0;
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

  // ST-010A control registers for every profile. The discovery view is a
  // synthetic fixture derived from the SlotMap parameter in the mapped
  // profile (present slots read Ready); ST-014 replaces it with the real
  // pad binding.
  logic [Slots-1:0][3:0] disc_state;
  g6lc_storamic_region_pkg::slot_map_t disc_map;
  always_comb begin
    disc_state = '0;
    disc_map = '0;
    if (Cfg.Profile == g6lc_storamic_cfg_pkg::ProfileMapped) begin
      disc_map = SlotMap;
      for (int s = 0; s < Slots && s <
           g6lc_storamic_cfg_pkg::MaxSupportedSticks; s++)
        if (SlotMap[s].present)
          disc_state[s] = 4'd7; // discovery_pkg::Ready
    end
  end
  g6lc_storamic_regs #(
    .Cfg(Cfg), .Slots(Slots), .Regions(Regions), .DataWidth(DataWidth),
    .BootMapEn(BootMapEn)
  ) i_control (
    .clk_i, .rst_ni, .testmode_i,
    .ctrl_req_i, .ctrl_resp_o,
    .service_ready_i(service_ready_o), .model_ready_i(model_ready_o),
    .sequence_exhausted_i(sequence_exhausted_o), .faults_i(faults_o),
    .stray_i(stray_i),
    .txn_accept_i(txn_accept), .txn_refuse_i(txn_refuse),
    .txn_retire_i(txn_retire), .txn_error_i(txn_error),
    .inflight_i(inflight),
    .slot_state_i(disc_state), .slot_fault_i('0), .slot_dup_i('0),
    .slot_map_i(disc_map),
    .slot_fault_event_i('0), .slot_ready_event_i('0),
    .slot_quiesce_o(), .slot_fault_clear_o(),
    .irq_o,
    .map_valid_o(map_valid), .slot_map_o(map_slots),
    .region_map_o(map_regions)
  );
endmodule
