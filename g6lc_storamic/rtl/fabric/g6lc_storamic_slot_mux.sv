// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-008B per-beat slot router. Completions are only routed when they arrive
// at least one cycle after the command grant.
// Forwards at most one memory command in flight
// to the slot named by the frontend's validated slot index; accepts the
// completion only from the latched slot and pulses stray_o on any other
// rvalid. No data storage, one registered in-flight selector.
module g6lc_storamic_slot_mux #(
  parameter int unsigned Slots = 1,
  parameter int unsigned DataWidth = 64,
  parameter g6lc_storamic_region_pkg::slot_map_t SlotMap = '0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  output logic mem_ready_o,
  input logic mem_req_i,
  input logic [7:0] mem_slot_i,
  output logic mem_gnt_o,
  input logic mem_we_i,
  input logic [63:0] mem_addr_i,
  input logic [DataWidth-1:0] mem_wdata_i,
  input logic [(DataWidth >= 8 ? DataWidth/8 : 1)-1:0] mem_be_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic mem_rvalid_o,
  output logic [DataWidth-1:0] mem_rdata_o,
  output logic mem_error_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  input logic [Slots-1:0] slot_ready_i,
  output logic [Slots-1:0] slot_req_o,
  input logic [Slots-1:0] slot_gnt_i,
  output logic slot_we_o,
  output logic [63:0] slot_addr_o,
  output logic [DataWidth-1:0] slot_wdata_o,
  output logic [(DataWidth >= 8 ? DataWidth/8 : 1)-1:0] slot_be_o,
  output g6lc_storamic_pkg::txn_id_t slot_tag_o,
  input logic [Slots-1:0] slot_rvalid_i,
  input logic [Slots-1:0][DataWidth-1:0] slot_rdata_i,
  input logic [Slots-1:0] slot_error_i,
  input g6lc_storamic_pkg::txn_id_t [Slots-1:0] slot_tag_i,
  output logic stray_o
);
  logic [Slots-1:0] present;
  logic inflight_q, inflight_d;
  logic [7:0] inflight_slot_q, inflight_slot_d;
  logic stray_q, stray_d;
  logic [Slots-1:0] expected;

  for (genvar i = 0; i < Slots; i++) begin : gen_present
    assign present[i] = SlotMap[i].present;
  end

  assign mem_ready_o = &(slot_ready_i | ~present);
  assign mem_gnt_o = int'(mem_slot_i) < Slots ? slot_gnt_i[mem_slot_i] : 1'b0;

  for (genvar i = 0; i < Slots; i++) begin : gen_req
    assign slot_req_o[i] = mem_req_i && int'(mem_slot_i) == i;
  end
  // pragma translate_off
  always @(posedge clk_i)
    if (rst_ni && mem_req_i && int'(mem_slot_i) >= Slots)
      $fatal(1, "STORAMIC_MUX_SLOT_RANGE");
  // pragma translate_on

  assign slot_we_o = mem_we_i;
  assign slot_addr_o = mem_addr_i;
  assign slot_wdata_o = mem_wdata_i;
  assign slot_be_o = mem_be_i;
  assign slot_tag_o = mem_tag_i;

  always_comb begin
    expected = '0;
    if (inflight_q && int'(inflight_slot_q) < Slots)
      expected[inflight_slot_q] = 1'b1;
    stray_d = |(slot_rvalid_i & ~expected);
    inflight_d = inflight_q;
    inflight_slot_d = inflight_slot_q;
    if (mem_req_i && mem_gnt_o) begin
      inflight_d = 1'b1;
      inflight_slot_d = mem_slot_i;
    end
    if (inflight_q && |(slot_rvalid_i & expected)) inflight_d = 1'b0;
  end

  assign mem_rvalid_o = inflight_q && |(slot_rvalid_i & expected);
  assign mem_rdata_o = inflight_q && int'(inflight_slot_q) < Slots ?
      slot_rdata_i[inflight_slot_q] : '0;
  assign mem_error_o = inflight_q && int'(inflight_slot_q) < Slots ?
      slot_error_i[inflight_slot_q] : '0;
  assign mem_tag_o = inflight_q && int'(inflight_slot_q) < Slots ?
      slot_tag_i[inflight_slot_q] : '0;
  assign stray_o = stray_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      inflight_q <= 1'b0;
      inflight_slot_q <= '0;
      stray_q <= 1'b0;
    end else begin
      inflight_q <= inflight_d;
      inflight_slot_q <= inflight_slot_d;
      stray_q <= stray_d;
    end
  end
endmodule
