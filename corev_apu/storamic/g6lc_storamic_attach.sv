// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_storamic_attach #(
  parameter bit Enable = 1'b0,
  parameter int unsigned DramClass = 0,
  parameter int unsigned NrChannels = 1,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AddrWidth = 64,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned UserWidth = 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  AXI_BUS.Slave slave,
  output logic init_done_o,
  output logic service_ready_o
);
  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg =
      g6lc_storamic_soc_cfg_pkg::make_cfg(Enable);

  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [AddrWidth-1:0] addr;
    logic [7:0] len;
    logic [2:0] size;
    logic [1:0] burst;
    logic lock;
    logic [3:0] cache;
    logic [2:0] prot;
    logic [3:0] qos;
    logic [3:0] region;
    logic [5:0] atop;
    logic [UserWidth-1:0] user;
  } aw_t;
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [AddrWidth-1:0] addr;
    logic [7:0] len;
    logic [2:0] size;
    logic [1:0] burst;
    logic lock;
    logic [3:0] cache;
    logic [2:0] prot;
    logic [3:0] qos;
    logic [3:0] region;
    logic [UserWidth-1:0] user;
  } ar_t;
  typedef struct packed {
    logic [DataWidth-1:0] data;
    logic [DataWidth/8-1:0] strb;
    logic last;
    logic [UserWidth-1:0] user;
  } write_t;
  typedef struct packed {
    aw_t aw;
    logic aw_valid;
    write_t w;
    logic w_valid;
    logic b_ready;
    ar_t ar;
    logic ar_valid;
    logic r_ready;
  } req_t;
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [1:0] resp;
    logic [UserWidth-1:0] user;
  } b_t;
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [DataWidth-1:0] data;
    logic [1:0] resp;
    logic last;
    logic [UserWidth-1:0] user;
  } r_t;
  typedef struct packed {
    logic aw_ready;
    logic w_ready;
    b_t b;
    logic b_valid;
    logic ar_ready;
    r_t r;
    logic r_valid;
  } resp_t;
  req_t req;
  resp_t resp;

  if (!g6lc_storamic_cfg_pkg::backend_legal(Enable,
      g6lc_storamic_soc_cfg_pkg::DirectBackendSelected ||
      DramClass != 0 || NrChannels != 1)) begin : gen_conflict
    initial $fatal(1, "STORAMIC_BACKEND_CONFLICT");
  end
  if (IdWidth == 0 || AddrWidth == 0 || AddrWidth > 64 || UserWidth == 0 ||
      DataWidth < 8 || DataWidth > 1024 ||
      (DataWidth & (DataWidth - 1)) != 0) begin : gen_width
    initial $fatal(1, "STORAMIC_WIDTH_ILLEGAL");
  end
  // Validate the bound interface in simulation; synthesis uses the validated
  // configuration and the structural wrapper. Dotted $bits cannot be used
  // in a parameter-resolved generate condition on the pinned simulator.
  // pragma translate_off
`ifndef SYNTHESIS
  begin : gen_shape
    initial begin
      if ($bits(slave.aw_addr) != AddrWidth || $bits(slave.ar_addr) != AddrWidth ||
          $bits(slave.aw_id) != IdWidth || $bits(slave.ar_id) != IdWidth ||
          $bits(slave.w_data) != DataWidth || $bits(slave.r_data) != DataWidth ||
          $bits(slave.w_strb) != DataWidth/8 ||
          $bits(slave.aw_user) != UserWidth || $bits(slave.ar_user) != UserWidth ||
          $bits(slave.w_user) != UserWidth) $fatal(1, "STORAMIC_INTERFACE_SHAPE");
    end
  end
`endif
  // pragma translate_on

  // Preserve the native payload; this does not grant memory or ATOP semantics.
  assign req.aw = '{id: slave.aw_id, addr: slave.aw_addr, len: slave.aw_len,
    size: slave.aw_size, burst: slave.aw_burst, lock: slave.aw_lock,
    cache: slave.aw_cache, prot: slave.aw_prot, qos: slave.aw_qos,
    region: slave.aw_region, atop: slave.aw_atop, user: slave.aw_user};
  assign req.w = '{data: slave.w_data, strb: slave.w_strb,
    last: slave.w_last, user: slave.w_user};
  assign req.ar = '{id: slave.ar_id, addr: slave.ar_addr, len: slave.ar_len,
    size: slave.ar_size, burst: slave.ar_burst, lock: slave.ar_lock,
    cache: slave.ar_cache, prot: slave.ar_prot, qos: slave.ar_qos,
    region: slave.ar_region, user: slave.ar_user};
  assign req.aw_valid = slave.aw_valid;
  assign req.w_valid = slave.w_valid;
  assign req.b_ready = slave.b_ready;
  assign req.ar_valid = slave.ar_valid;
  assign req.r_ready = slave.r_ready;
  assign slave.aw_ready = resp.aw_ready;
  assign slave.w_ready = resp.w_ready;
  assign slave.b_id = resp.b.id;
  assign slave.b_resp = resp.b.resp;
  assign slave.b_user = resp.b.user;
  assign slave.b_valid = resp.b_valid;
  assign slave.ar_ready = resp.ar_ready;
  assign slave.r_id = resp.r.id;
  assign slave.r_data = resp.r.data;
  assign slave.r_resp = resp.r.resp;
  assign slave.r_last = resp.r.last;
  assign slave.r_user = resp.r.user;
  assign slave.r_valid = resp.r_valid;

  g6lc_storamic_top #(.Cfg(Cfg), .req_t(req_t), .resp_t(resp_t),
                      .DataWidth(DataWidth)) i_storamic (
    .clk_i, .rst_ni, .testmode_i, .req_i(req), .resp_o(resp),
    .ctrl_req_i('0), .ctrl_resp_o(), .init_done_o, .service_ready_o,
    .media_ready_o(), .pad_o(),
    .source_i('0), .reset_generation_i('0), .model_ready_o(),
    .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i(1'b0), .mem_req_o(), .mem_gnt_i(1'b0), .mem_we_o(),
    .mem_addr_o(), .mem_wdata_o(), .mem_be_o(), .mem_tag_o(),
    .mem_rvalid_i(1'b0), .mem_rdata_i('0), .mem_error_i(1'b0), .mem_tag_i('0)
  );
endmodule
