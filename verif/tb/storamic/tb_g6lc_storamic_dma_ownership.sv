// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_dma_ownership #(parameter int unsigned Case = 0);
  import g6lc_storamic_pkg::*;
  localparam logic [63:0] UpAddr = 64'h1000, DmaAddr = 64'h9000;
  localparam logic [63:0] UpData = 64'hCAFE_1234_ABCD_5678;
  localparam logic [63:0] DmaData = 64'hDEAD_9876_0123_4567;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask
  axi_req_t up, mst;
  axi_resp_t rsp, back, back_q;
  logic request = 0, grant, done, error, inflight;
  logic aw_full, w_full;
  logic [63:0] aw_addr, w_data, up_memory, dma_memory;
  logic [7:0] aw_id;
  logic up_w_seen, up_aw_seen, up_b_seen, grant_seen, done_seen;
  logic up_r_seen, aw_gate = 1, ar_gate = 1;
  int aw_accepts, ar_accepts;
  wire capacity_case = Case == 3 || Case == 4;
  g6lc_storamic_dma_axi #(
    .IdWidth(8), .DmaId(8'h05), .axi_req_t(axi_req_t), .axi_resp_t(axi_resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .inflight_o(inflight),
    .dma_req_i(request), .dma_gnt_o(grant), .dma_we_i(1'b1),
    .dma_addr_i(DmaAddr), .dma_wdata_i(DmaData), .dma_be_i(8'hFF),
    .dma_rvalid_o(done), .dma_rdata_o(), .dma_err_o(error),
    .up_req_i(up), .up_resp_o(rsp), .mst_req_o(mst), .mst_resp_i(back),
    .inval_valid_o(), .inval_addr_o(), .inval_ready_i(1'b0), .inval_done_i(1'b0)
  );
  always_comb begin
    back = back_q;
    back.aw_ready = capacity_case ||
                    (aw_gate && !aw_full && !back_q.b_valid && (Case != 5 || mst.w_valid));
    back.w_ready = !capacity_case && !w_full && !back_q.b_valid;
    back.ar_ready = capacity_case || (ar_gate && !back_q.r_valid);
  end
  // A legal slave buffers AW and W independently, including W before AW.
  always @(posedge clk) begin
    if (!rst_n) begin
      aw_full <= 0; w_full <= 0; back_q <= '0;
      aw_addr <= 0; aw_id <= 0; w_data <= 0;
      up_memory <= 0; dma_memory <= 0;
      up_w_seen <= 0; up_aw_seen <= 0; up_b_seen <= 0;
      grant_seen <= 0; done_seen <= 0; up_r_seen <= 0;
      aw_accepts <= 0; ar_accepts <= 0;
    end else begin
      if (!capacity_case && mst.aw_valid && back.aw_ready) begin
        aw_full <= 1; aw_addr <= mst.aw.addr; aw_id <= mst.aw.id;
      end
      if (!capacity_case && mst.w_valid && back.w_ready) begin
        w_full <= 1; w_data <= mst.w.data;
      end
      if (aw_full && w_full && !back.b_valid) begin
        if (aw_addr == UpAddr) up_memory <= w_data;
        if (aw_addr == DmaAddr) dma_memory <= w_data;
        aw_full <= 0; w_full <= 0; back_q.b_valid <= 1;
        back_q.b.id <= aw_id; back_q.b.resp <= 0;
        $display("DMA_OWNERSHIP_WRITE address=%h id=%h data=%h", aw_addr, aw_id, w_data);
        if (aw_addr == DmaAddr && w_data != DmaData)
          $fatal(1, "DMA_OWNERSHIP_FAIL leading-W-cannot-cross-master-boundary");
      end
      if (back.b_valid && mst.b_ready) back_q.b_valid <= 0;
      if (up.w_valid && rsp.w_ready) up_w_seen <= 1;
      if (up.aw_valid && rsp.aw_ready) up_aw_seen <= 1;
      if (rsp.b_valid && up.b_ready) up_b_seen <= 1;
      if (up.aw_valid && rsp.aw_ready) aw_accepts <= aw_accepts + 1;
      if (up.ar_valid && rsp.ar_ready) ar_accepts <= ar_accepts + 1;
      if (!capacity_case && mst.ar_valid && back.ar_ready) begin
        back_q.r_valid <= 1; back_q.r.id <= mst.ar.id;
        back_q.r.data <= UpData; back_q.r.last <= 1;
      end
      if (back.r_valid && mst.r_ready) back_q.r_valid <= 0;
      if (rsp.r_valid && up.r_ready) begin
        if (rsp.r.data != UpData || rsp.r.id != 1)
          $fatal(1, "DMA_OWNERSHIP_FAIL read-response-owner");
        up_r_seen <= 1;
      end
      if (grant) begin
        grant_seen <= 1;
        $display("DMA_OWNERSHIP_GRANT upstream_w_accepted=%b upstream_aw_accepted=%b inflight=%b",
                 up_w_seen, up_aw_seen, inflight);
      end
      if (done) begin
        if (error) $fatal(1, "DMA_OWNERSHIP_FAIL unexpected-DMA-error");
        done_seen <= 1;
      end
    end
  end
  initial begin
    up = '0;
    repeat (3) tick(); rst_n = 1; tick();
    up.aw.addr = UpAddr; up.aw.id = 1; up.aw.size = 3; up.aw.burst = 1;
    up.ar.addr = UpAddr; up.ar.id = 1; up.ar.size = 3; up.ar.burst = 1;
    up.w.data = UpData; up.w.strb = '1; up.w.last = 1;
    up.b_ready = 1;
    if (capacity_case) begin
      up.aw_valid = Case == 3; up.ar_valid = Case == 4;
      repeat (256) tick();
      $display("DMA_OWNERSHIP_CAPACITY aw=%0d ar=%0d inflight=%b",
               aw_accepts, ar_accepts, inflight);
      if ((Case == 3 ? aw_accepts : ar_accepts) != 255 || !inflight)
        $fatal(1, "DMA_OWNERSHIP_FAIL address-credit-does-not-wrap");
      request = 1;
      repeat (4) begin
        tick();
        if (grant) $fatal(1, "DMA_OWNERSHIP_FAIL capacity-retains-owner");
      end
    end else begin
    if (Case == 0 || Case == 5 || Case == 6) up.w_valid = 1;
    if (Case == 1 || Case == 6) begin aw_gate = 0; up.aw_valid = 1; end
    if (Case == 2) begin ar_gate = 0; up.ar_valid = 1; end
    repeat (4) begin
      tick();
      if (up_w_seen) up.w_valid = 0;
      if (up_aw_seen) up.aw_valid = 0;
    end
    request = 1;
    for (int cycle = 0; cycle < 100; cycle++) begin
      tick();
      if ((Case == 1 || Case == 6) && !up_aw_seen && !mst.aw_valid)
        $fatal(1, "DMA_OWNERSHIP_FAIL held-AW-survives-DMA-request");
      if (Case == 2 && !up_r_seen && !rsp.r_valid && !mst.ar_valid && cycle < 6)
        $fatal(1, "DMA_OWNERSHIP_FAIL held-AR-survives-DMA-request");
      if (grant_seen) request = 0;
      if (up_w_seen) up.w_valid = 0;
      if (up_aw_seen) up.aw_valid = 0;
      if (Case == 2 && ar_accepts != 0) up.ar_valid = 0;
      if (cycle == 6) begin aw_gate = 1; ar_gate = 1; end
      if (Case == 1 && cycle == 8) up.w_valid = 1;
      if (Case == 2 && cycle == 16) up.r_ready = 1;
      // Fixed delay, independent of WREADY: the master obeys AXI dependencies.
      if ((Case == 0 || Case == 5) && cycle == 12) up.aw_valid = 1;
      if (done_seen && (Case == 2 ? up_r_seen : up_b_seen)) break;
    end
    if (!done_seen || !(Case == 2 ? up_r_seen : up_b_seen))
      $fatal(1, "DMA_OWNERSHIP_FAIL bounded-completion");
    $display("DMA_OWNERSHIP_RESULT upstream=%h DMA=%h", up_memory, dma_memory);
    if ((Case != 2 && up_memory != UpData) || dma_memory != DmaData)
      $fatal(1, "DMA_OWNERSHIP_FAIL leading-W-cannot-cross-master-boundary");
    end
    if ($test$plusargs("oracle_negative")) $fatal(1, "DMA_OWNERSHIP_FAIL negative-oracle");
    $display("DMA_OWNERSHIP_PASS case=%0d", Case);
    $finish;
  end
  initial begin #100000; $fatal(1, "DMA_OWNERSHIP_FAIL global-timeout"); end
endmodule
