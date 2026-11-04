// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-008C bounded safety + reachability for the mapped profile. Free AXI and
// memory-side inputs under the same assumptions as the model wrapper; no
// eventual-grant claim. Completion is assumed to arrive at least one cycle
// after grant with the offered tag echoed.
module formal_g6lc_storamic_map (
  input logic clk_i,
  input logic rst_ni,
  input g6lc_storamic_pkg::axi_req_t req_i,
  input logic mem_ready_i,
  input logic mem_gnt_i,
  input logic mem_rvalid_i,
  input logic [63:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic cover_w0_o,
  output logic cover_r1_o,
  output logic cover_awref_o,
  output logic cover_arref_o
);
  import g6lc_storamic_region_pkg::*;
  import g6lc_storamic_pkg::*;

  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg = '{
    Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
    MaxSticks: 2, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0};
  localparam slot_map_t SMap = '{
    0: '{present: 1'b1, identity: 32'hA1, ram_bytes: 64'h4000,
        reserved_bytes: '0},
    1: '{present: 1'b1, identity: 32'hB2, ram_bytes: 64'h8000,
        reserved_bytes: '0},
    default: '0};
  // r0 RW slot0, r1 RO slot1, hole 0xC00..0x1000, r2 WO slot0, r3 RW slot1.
  localparam region_map_t RMap = '{
    0: '{valid: 1'b1, base: 64'h0, bytes: 64'h800, slot: 8'd0,
        slot_identity: 32'hA1, offset: 64'h0, read: 1'b1, write: 1'b1},
    1: '{valid: 1'b1, base: 64'h800, bytes: 64'h400, slot: 8'd1,
        slot_identity: 32'hB2, offset: 64'h200, read: 1'b1, write: 1'b0},
    2: '{valid: 1'b1, base: 64'h1000, bytes: 64'h400, slot: 8'd0,
        slot_identity: 32'hA1, offset: 64'h800, read: 1'b0, write: 1'b1},
    3: '{valid: 1'b1, base: 64'h1800, bytes: 64'h400, slot: 8'd1,
        slot_identity: 32'hB2, offset: 64'h1000, read: 1'b1, write: 1'b1},
    default: '0};

  axi_resp_t resp;
  logic mem_req, mem_we;
  logic [63:0] mem_addr, mem_wdata;
  logic [7:0] mem_be, mem_slot;
  txn_id_t mem_tag;

  g6lc_storamic_top #(
    .Cfg(Cfg), .DataWidth(64), .Slots(2), .Regions(4), .SlotMap(SMap),
    .RegionMap(RMap), .req_t(axi_req_t), .resp_t(axi_resp_t)
  ) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0), .req_i, .resp_o(resp),
    .ctrl_req_i('0), .ctrl_resp_o(), .init_done_o(), .service_ready_o(),
    .media_ready_o(), .pad_o(),
    .source_i(8'h3a), .reset_generation_i(32'b0), .model_ready_o(),
    .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i, .mem_req_o(mem_req), .mem_gnt_i, .mem_we_o(mem_we),
    .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata), .mem_be_o(mem_be),
    .mem_tag_o(mem_tag), .mem_slot_o(mem_slot),
    .mem_rvalid_i, .mem_rdata_i, .mem_error_i, .mem_tag_i, .irq_o(), .stray_i(1'b0)
  );

  // Completions only from an in-flight offer, one or more cycles after grant.
  logic inflight;
  txn_id_t inflight_tag;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      inflight <= 1'b0;
      inflight_tag <= '0;
    end else begin
      if (mem_req && mem_gnt_i) begin
        inflight <= 1'b1;
        inflight_tag <= mem_tag;
      end else if (mem_rvalid_i) inflight <= 1'b0;
    end
  end
  // pragma translate_off
  always @(posedge clk_i)
    if (rst_ni && mem_rvalid_i) begin
      assert (inflight) else $fatal(1, "STORAMIC_MAP_F_NOINFLIGHT");
      assume (mem_tag_i == inflight_tag);
    end
  // pragma translate_on

  // (a) Offered commands name a legal slot.
  always @(posedge clk_i)
    if (rst_ni && mem_req) assert (mem_slot < 8'd2);

  // (b) Every offer lies inside a mapped region of its slot with a matching
  //     permission: offset <= mem_addr < offset+bytes.
  function automatic bit mapped_offer();
    for (int i = 0; i < 4; i++)
      if (RMap[i].slot == mem_slot &&
          RMap[i].offset <= mem_addr &&
          mem_addr < RMap[i].offset + RMap[i].bytes &&
          (mem_we ? RMap[i].write : RMap[i].read))
        return 1'b1;
    return 1'b0;
  endfunction
  always @(posedge clk_i)
    if (rst_ni && mem_req) assert (mapped_offer());

  // (c) A held offer is never retargeted: all command fields stable.
  logic [63:0] prev_addr, prev_data;
  logic [7:0] prev_be, prev_slot;
  logic prev_we;
  txn_id_t prev_tag;
  logic held;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) held <= 1'b0;
    else begin
      if (mem_req && !mem_gnt_i) begin
        if (held) begin
          assert (mem_addr == prev_addr && mem_wdata == prev_data &&
                  mem_be == prev_be && mem_slot == prev_slot &&
                  mem_we == prev_we && mem_tag == prev_tag);
        end
        held <= 1'b1;
        prev_addr <= mem_addr; prev_data <= mem_wdata; prev_be <= mem_be;
        prev_slot <= mem_slot; prev_we <= mem_we; prev_tag <= mem_tag;
      end else held <= 1'b0;
    end
  end

  // Covers: granted write slot0, granted read slot1, AW and AR refusals.
  logic cov_w0, cov_r1, cov_awref, cov_arref;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cov_w0 <= 0; cov_r1 <= 0; cov_awref <= 0; cov_arref <= 0;
    end else begin
      if (mem_req && mem_gnt_i && mem_we && mem_slot == 0) cov_w0 <= 1;
      if (mem_req && mem_gnt_i && !mem_we && mem_slot == 1) cov_r1 <= 1;
      if (resp.b_valid && resp.b.resp == 2'b10 && req_i.b_ready) cov_awref <= 1;
      if (resp.r_valid && resp.r.resp == 2'b10 && req_i.r_ready) cov_arref <= 1;
    end
  end
  assign cover_w0_o = cov_w0;
  assign cover_r1_o = cov_r1;
  assign cover_awref_o = cov_awref;
  assign cover_arref_o = cov_arref;
endmodule
