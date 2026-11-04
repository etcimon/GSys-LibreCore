// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_storamic_attach #(
  parameter bit Enable = 1'b0,
  parameter int unsigned DramClass = 0,
  parameter int unsigned NrChannels = 1,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned AddrWidth = 64,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned UserWidth = 1,
  // ST-011B: model-profile window (absolute base) and sim-mem depth in words.
  parameter logic [63:0] ModelBase = 64'h8000_0000,
  parameter int unsigned ModelWords = 8192
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  AXI_BUS.Slave slave,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  output logic irq_o,
  output logic init_done_o,
  output logic service_ready_o
);
  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg =
      g6lc_storamic_soc_cfg_pkg::make_cfg(
          Enable, ModelBase, 64'(ModelWords) * 64'(DataWidth / 8));

  // pragma translate_off
  if (g6lc_storamic_soc_cfg_pkg::SimModel &&
      g6lc_storamic_soc_cfg_pkg::Skeleton) begin : gen_profile_conflict
    initial $fatal(1, "STORAMIC_PROFILE_CONFLICT");
  end
  // pragma translate_on

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

  // mem_* command seam: bound to the simulation model memory under the
  // ST-011B model profile, tied off in every other profile.
  logic mem_ready, mem_req, mem_gnt, mem_we, mem_rvalid, mem_error;
  logic [63:0] mem_addr;
  logic [DataWidth-1:0] mem_wdata, mem_rdata;
  logic [DataWidth/8-1:0] mem_be;
  g6lc_storamic_pkg::txn_id_t mem_tag_out, mem_tag_in;

  if (g6lc_storamic_cfg_pkg::cfg_legal(Cfg) &&
      Cfg.Profile == g6lc_storamic_cfg_pkg::ProfileModel)
  begin : gen_model_mem
    g6lc_storamic_sim_mem #(
      .DataWidth(DataWidth), .NumWords(ModelWords),
      .ModelBytes(Cfg.ModelBytes)
    ) i_sim_mem (
      .clk_i, .rst_ni,
      .mem_ready_o(mem_ready), .mem_req_i(mem_req), .mem_gnt_o(mem_gnt),
      .mem_we_i(mem_we), .mem_addr_i(mem_addr), .mem_wdata_i(mem_wdata),
      .mem_be_i(mem_be), .mem_tag_i(mem_tag_out),
      .mem_rvalid_o(mem_rvalid), .mem_rdata_o(mem_rdata),
      .mem_error_o(mem_error), .mem_tag_o(mem_tag_in)
    );
  end else begin : gen_no_model_mem
    assign mem_ready = 1'b0;
    assign mem_gnt = 1'b0;
    assign mem_rvalid = 1'b0;
    assign mem_rdata = '0;
    assign mem_error = 1'b0;
    assign mem_tag_in = '0;
  end

  g6lc_storamic_top #(.Cfg(Cfg), .req_t(req_t), .resp_t(resp_t),
                      .DataWidth(DataWidth)) i_storamic (
    .clk_i, .rst_ni, .testmode_i, .req_i(req), .resp_o(resp),
    .ctrl_req_i, .ctrl_resp_o, .init_done_o, .service_ready_o,
    .media_ready_o(), .pad_o(),
    .source_i('0), .reset_generation_i('0), .model_ready_o(),
    .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i(mem_ready), .mem_req_o(mem_req), .mem_gnt_i(mem_gnt),
    .mem_we_o(mem_we),
    .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata), .mem_be_o(mem_be),
    .mem_tag_o(mem_tag_out), .mem_slot_o(),
    .mem_rvalid_i(mem_rvalid), .mem_rdata_i(mem_rdata),
    .mem_error_i(mem_error), .mem_tag_i(mem_tag_in), .irq_o, .stray_i(1'b0)
  );

  // Simulation-only AXI/seam trace, enabled by +g6lc_storamic_mem_trace.
  // pragma translate_off
`ifndef SYNTHESIS
  bit trace_en;
  initial trace_en = $test$plusargs("g6lc_storamic_mem_trace");
  always @(posedge clk_i) begin
    if (trace_en && rst_ni) begin
      if (req.aw_valid && resp.aw_ready)
        $display("[sto-axi] t=%0t AW id=%0h a=%h len=%0d size=%0d burst=%0d", $time,
                 req.aw.id, req.aw.addr, req.aw.len, req.aw.size, req.aw.burst);
      if (req.w_valid && resp.w_ready)
        $display("[sto-axi] t=%0t W d=%h strb=%h last=%0d", $time, req.w.data,
                 req.w.strb, req.w.last);
      if (resp.b_valid && req.b_ready)
        $display("[sto-axi] t=%0t B id=%0h resp=%0d", $time, resp.b.id, resp.b.resp);
      if (req.ar_valid && resp.ar_ready)
        $display("[sto-axi] t=%0t AR id=%0h a=%h len=%0d size=%0d burst=%0d", $time,
                 req.ar.id, req.ar.addr, req.ar.len, req.ar.size, req.ar.burst);
      if (resp.r_valid && req.r_ready)
        $display("[sto-axi] t=%0t R id=%0h d=%h resp=%0d last=%0d", $time, resp.r.id,
                 resp.r.data, resp.r.resp, resp.r.last);
      if (mem_req && mem_gnt)
        $display("[sto-mem] t=%0t %s a=%h d=%h be=%h", $time, mem_we ? "W" : "R",
                 mem_addr, mem_wdata, mem_be);
      if (mem_rvalid)
        $display("[sto-mem] t=%0t rsp d=%h err=%0d", $time, mem_rdata, mem_error);
    end
  end
`endif
  // pragma translate_on
endmodule
