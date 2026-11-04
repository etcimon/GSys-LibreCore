// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_storamic #(
  parameter int unsigned MaxSticks = 3,
  parameter bit Enable = 1'b1,
  parameter bit Skeleton = 1'b1,
  parameter logic [31:0] RequestedCaps = 0
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_cfg_pkg::*;
  localparam storamic_cfg_t Cfg = '{
    Enable: Enable, Profile: Enable && Skeleton ? ProfileRefuse : ProfileOff,
    MaxSticks: MaxSticks, RequestedMediaCaps: 32'(RequestedCaps),
    ModelBase: '0, ModelBytes: '0
  };
  localparam int unsigned Slots = MaxSticks > 0 ? MaxSticks : 1;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;
  axi_req_t req;
  axi_resp_t resp;
  axil_req_t ctrl_req;
  axil_resp_t ctrl_resp;
  logic init_done;
  logic model_ready, exhausted, mem_req, mem_we;
  logic [2:0] faults;
  model_events_t events;
  logic [63:0] mem_addr, mem_data;
  logic [7:0] mem_be;
  txn_id_t mem_tag;
  logic [Slots-1:0] media_ready;
  g6lc_storamic_pad_pkg::pad_out_t [Slots-1:0] pads;

  g6lc_storamic_top #(.Cfg(Cfg)) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .req_i(req), .resp_o(resp), .ctrl_req_i(ctrl_req),
    .ctrl_resp_o(ctrl_resp), .init_done_o(init_done),
    .service_ready_o(), .model_ready_o(model_ready),
    .sequence_exhausted_o(exhausted), .faults_o(faults), .events_o(events),
    .source_i('1), .reset_generation_i('1),
    .mem_ready_i(1'b1), .mem_req_o(mem_req), .mem_gnt_i(1'b1),
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_data),
    .mem_be_o(mem_be), .mem_tag_o(mem_tag),
    .mem_rvalid_i(1'b1), .mem_rdata_i('1), .mem_error_i(1'b0), .mem_tag_i('1), .irq_o(), .stray_i(1'b0),
    .media_ready_o(media_ready), .pad_o(pads)
  );
  // An apparently ready external binding must never select the model implicitly.
  always @(posedge clk) begin
    if (rst_n)
      assert (!model_ready && !exhausted && faults == 0 && events == '0 &&
              !mem_req && !mem_we && mem_addr == 0 && mem_data == 0 &&
              mem_be == 0 && mem_tag == '0)
        else $fatal(1, "STORAMIC_IMPLICIT_MODEL");
  end

  task automatic tick;
    @(negedge clk);
  endtask

  task automatic read_burst(input int beats, input logic [7:0] id);
    req.ar.id = id;
    req.ar.len = 8'(beats - 1);
    req.ar.addr = 64'h8000_0038;
    req.ar.size = 3'd3;
    req.ar.burst = 2'b01;
    req.ar_valid = 1'b1;
    #1;
    assert (resp.ar_ready) else $fatal(1, "STORAMIC_AR_READY");
    tick();
    req.ar_valid = 1'b0;
    for (int beat = 0; beat < beats; beat++) begin
      repeat (2) begin
        assert (resp.r_valid && resp.r.id == id && resp.r.resp == RespSlvErr &&
                resp.r.data == 0 && resp.r.last == (beat == beats-1))
          else $fatal(1, "STORAMIC_READ_SHAPE");
        tick();
      end
      req.r_ready = 1'b1;
      tick();
      req.r_ready = 1'b0;
    end
    assert (!resp.r_valid) else $fatal(1, "STORAMIC_EXTRA_READ");
  endtask

  task automatic write_burst(input int beats, input logic [7:0] id);
    req.w_valid = 1'b1;
    repeat (2) begin
      #1;
      assert (!resp.w_ready) else $fatal(1, "STORAMIC_W_BEFORE_AW");
      tick();
    end
    req.aw.id = id;
    req.aw.len = 8'(beats - 1);
    req.aw.addr = 64'h8000_0038;
    req.aw.size = 3'd3;
    req.aw.burst = 2'b01;
    req.aw_valid = 1'b1;
    #1;
    assert (resp.aw_ready) else $fatal(1, "STORAMIC_AW_READY");
    tick();
    req.aw_valid = 1'b0;
    for (int beat = 0; beat < beats; beat++) begin
      req.w.last = beat == beats-1;
      req.w.strb = 8'(beat);
      #1;
      assert (resp.w_ready && !resp.b_valid) else $fatal(1, "STORAMIC_WRITE_DRAIN");
      tick();
    end
    req.w_valid = 1'b0;
    repeat (3) begin
      assert (resp.b_valid && resp.b.id == id && resp.b.resp == RespSlvErr &&
              !resp.aw_ready && !resp.w_ready)
        else $fatal(1, "STORAMIC_B_STABLE");
      tick();
    end
    req.b_ready = 1'b1;
    tick();
    req.b_ready = 1'b0;
    assert (!resp.b_valid) else $fatal(1, "STORAMIC_EXTRA_B");
  endtask

  initial begin
    req = '0;
    ctrl_req = '0;
    repeat (3) tick();
    rst_n = 1'b1;
    tick();
    assert (ContractVersion == 4 &&
            cfg_legal(StoramicOff) && cfg_legal(StoramicSkeleton) && cfg_legal(StoramicModel) &&
            cfg_legal(StoramicMapped) &&
            !backend_legal(1'b1, 1'b1) && backend_legal(1'b0, 1'b1))
      else $fatal(1, "STORAMIC_LEGALITY");
    if ($test$plusargs("oracle_negative"))
      assert (init_done) else $fatal(1, "STORAMIC_ORACLE_NEGATIVE");
    assert (!init_done && media_ready == 0) else $fatal(1, "STORAMIC_FALSE_READY");
    for (int slot = 0; slot < Slots; slot++)
      assert (pads[slot] == g6lc_storamic_pad_pkg::PadSafe)
        else $fatal(1, "STORAMIC_PAD_UNSAFE");
    fork
      begin
        read_burst(1, 8'hA5);
        read_burst(16, 8'h03);
        read_burst(256, 8'hFF);
      end
      begin
        write_burst(256, 8'h5A);
        write_burst(1, 8'hF0);
        write_burst(16, 8'h01);
      end
    join
    ctrl_req.ar.addr = 64'h0;
    ctrl_req.aw.addr = 64'h0;
    ctrl_req.ar_valid = 1'b1;
    ctrl_req.aw_valid = 1'b1;
    tick();
    ctrl_req.ar_valid = 1'b0;
    ctrl_req.aw_valid = 1'b0;
    repeat (3) begin
      // ID is mapped in every profile: OKAY with the magic, not a refusal.
      assert (ctrl_resp.r_valid && ctrl_resp.r.resp == 2'b00 &&
              ctrl_resp.r.data == 32'h5354_524D && !ctrl_resp.b_valid)
        else $fatal(1, "STORAMIC_CTRL_READ");
      tick();
    end
    // Retire the held ID response, then an unmapped ctrl read still refuses.
    ctrl_req.r_ready = 1'b1;
    tick();
    ctrl_req.r_ready = 1'b0;
    ctrl_req.ar.addr = 64'h014;
    ctrl_req.ar_valid = 1'b1;
    tick();
    ctrl_req.ar_valid = 1'b0;
    repeat (3) begin
      assert (ctrl_resp.r_valid && ctrl_resp.r.resp == RespSlvErr &&
              ctrl_resp.r.data == 0)
        else $fatal(1, "STORAMIC_CTRL_READ_UNMAPPED");
      tick();
    end
    ctrl_req.w_valid = 1'b1;
    tick();
    ctrl_req.w_valid = 1'b0;
    repeat (3) begin
      assert (ctrl_resp.b_valid && ctrl_resp.b.resp == RespSlvErr)
        else $fatal(1, "STORAMIC_CTRL_WRITE");
      tick();
    end
    req.ar_valid = 1'b1;
    req.ar.len = 8'hFF;
    req.aw_valid = 1'b1;
    req.aw.len = 8'hFF;
    tick();
    req = '0;
    rst_n = 1'b0;
    #1;
    assert (!resp.r_valid && !resp.b_valid &&
            !ctrl_resp.r_valid && !ctrl_resp.b_valid)
      else $fatal(1, "STORAMIC_RESET_ABORT");
    repeat (2) tick();
    ctrl_req = '0;
    rst_n = 1'b1;
    tick();
    read_burst(1, 8'h37);
    write_burst(1, 8'h73);
    $display("STORAMIC_FOUNDATION_PASS sticks=%0d enable=%0d", MaxSticks, Enable);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "STORAMIC_TEST_TIMEOUT");
  end
endmodule
