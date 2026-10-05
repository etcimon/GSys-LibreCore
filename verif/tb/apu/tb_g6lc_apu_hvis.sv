// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// HOST_VISIBLE SHM id 1, blob map into that window, Venus context_init.
// RESOURCE_BLOB and CONTEXT_INIT stay outside APU_IMPL_FEATURES.

`timescale 1ns/1ps

module tb_g6lc_apu_hvis;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic mmio_req = 0, mmio_we = 0;
  logic [15:0] mmio_addr = 0;
  logic [31:0] mmio_wdata = 0, mmio_rdata;
  logic [3:0] mmio_wstrb = 4'hf;
  logic mmio_rvalid, mmio_err, mmio_irq;
  apu_vq_state_t vq [APU_NUM_QUEUES];
  logic [APU_NUM_QUEUES-1:0] qen, nfy, nfy_clr = '0, stop_req, stop_ack = '0;
  logic fw_pulse, fw_req, fw_ack = 1'b1;
  logic used_v = 0, used_rdy;
  logic [31:0] used_qid = 0, used_ctx = 0, used_len = 0, last_qid, last_ctx, last_len;
  logic [63:0] used_fence = 0, last_fence;
  logic cfg_ev = 0;
  logic [31:0] dbg;

  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_hvis_req_t req;
  apu_hvis_cpl_t cpl;
  apu_hvis_t hvis;
  logic off_rdy, off_v;
  apu_hvis_cpl_t off_cpl;
  apu_hvis_t off_hvis;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  function automatic apu_cfg_t shm_on_cfg();
    apu_cfg_t cfg;
    cfg = ApuP1Transport;
    cfg.ShmEn = 1'b1;
    return cfg;
  endfunction

  g6lc_apu_virtio_mmio #(.ApuCfg(shm_on_cfg())) i_mmio (
    .clk_i(clk), .rst_ni, .testmode_i(1'b0),
    .req_i(mmio_req), .we_i(mmio_we), .addr_i(mmio_addr), .wdata_i(mmio_wdata),
    .wstrb_i(mmio_wstrb), .rdata_o(mmio_rdata), .rvalid_o(mmio_rvalid),
    .error_o(mmio_err), .irq_o(mmio_irq), .vq_state_o(vq), .queue_enable_o(qen),
    .notify_pending_o(nfy), .fw_notify_clear_i(nfy_clr),
    .fw_reset_pulse_o(fw_pulse), .fw_reset_req_o(fw_req), .fw_reset_ack_i(fw_ack),
    .fw_queue_stop_req_o(stop_req), .fw_queue_stop_ack_i(stop_ack),
    .used_valid_i(used_v), .used_qid_i(used_qid), .used_context_i(used_ctx),
    .used_fence_i(used_fence), .used_len_i(used_len), .used_ready_o(used_rdy),
    .last_used_qid_o(last_qid), .last_used_context_o(last_ctx),
    .last_used_fence_o(last_fence), .last_used_len_o(last_len),
    .cfg_display_event_i(cfg_ev), .debug_status_o(dbg)
  );

  g6lc_apu_hvis #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .hvis_o(hvis)
  );
  g6lc_apu_hvis_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .hvis_o(off_hvis)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "hvis timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_hvis !== '0 || off_cpl !== '0)
      $fatal(1, "disabled hvis active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic mmio_write(input logic [15:0] a, input logic [31:0] d);
    @(negedge clk);
    mmio_req = 1'b1; mmio_we = 1'b1; mmio_addr = a; mmio_wdata = d;
    @(posedge clk);
    @(negedge clk);
    mmio_req = 1'b0; mmio_we = 1'b0;
  endtask

  task automatic mmio_read(input logic [15:0] a, output logic [31:0] d);
    @(negedge clk);
    mmio_req = 1'b1; mmio_we = 1'b0; mmio_addr = a;
    @(posedge clk);
    d = mmio_rdata;
    @(negedge clk);
    mmio_req = 1'b0;
  endtask

  task automatic fire(input apu_hvis_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  initial begin
    apu_cfg_t cfg;
    apu_hvis_req_t r;
    logic [31:0] d;
    logic [63:0] feats;

    req = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);

    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep shm and hvis off",
          !ApuOff.ShmEn && !ApuOff.HvisEn &&
          !ApuP1Transport.ShmEn && !ApuP1Transport.HvisEn &&
          !ApuHarness.ShmEn && !ApuHarness.HvisEn);
    cfg = ApuP1Transport;
    cfg.ShmEn = 1'b1;
    cfg.HvisEn = 1'b1;
    check("shm/hvis do not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.ShmEn = 1'b1;
    cfg.HvisEn = 1'b1;
    check("shm/hvis do not legalize virgl", !apu_cfg_legal(cfg));
    feats = apu_device_features(shm_on_cfg());
    check("blob/ctxinit not advertised",
          feats[VIRTIO_GPU_F_RESOURCE_BLOB] == 1'b0 &&
          feats[VIRTIO_GPU_F_CONTEXT_INIT] == 1'b0 &&
          feats[0] == 1'b0);

    cases++;
    mmio_write(VREG_SHM_SEL, 32'd0);
    mmio_read(VREG_SHM_LEN_LO, d);
    check("sel0 len lo absent", d == 32'hffff_ffff);
    mmio_read(VREG_SHM_BASE_LO, d);
    check("sel0 base lo absent", d == 32'hffff_ffff);

    cases++;
    mmio_write(VREG_SHM_SEL, APU_SHM_ID_HOST_VISIBLE);
    mmio_read(VREG_SHM_SEL, d);
    check("sel1 stored", d == APU_SHM_ID_HOST_VISIBLE);
    mmio_read(VREG_SHM_LEN_LO, d);
    check("sel1 len lo", d == APU_SHM_BYTES[31:0]);
    mmio_read(VREG_SHM_LEN_HI, d);
    check("sel1 len hi", d == APU_SHM_BYTES[63:32]);
    mmio_read(VREG_SHM_BASE_LO, d);
    check("sel1 base lo", d == APU_SHM_BASE[31:0]);
    mmio_read(VREG_SHM_BASE_HI, d);
    check("sel1 base hi", d == APU_SHM_BASE[63:32]);

    cases++;
    mmio_write(VREG_SHM_SEL, 32'd2);
    mmio_read(VREG_SHM_LEN_LO, d);
    check("sel2 absent", d == 32'hffff_ffff);

    cases++;
    r = '0;
    r.op = APU_HVIS_BLOB;
    r.resource_id = 32'd7;
    r.size = 64'h0000_1000;
    r.blob_mem = APU_BLOB_MEM_HOST3D;
    r.blob_flags = APU_BLOB_FLAG_MAPPABLE;
    fire(r);
    check("blob ok", cpl.status == APU_HVIS_OK);
    ack();
    r.op = APU_HVIS_MAP;
    r.map_offset = 64'h0000_2000;
    fire(r);
    check("map ok", cpl.status == APU_HVIS_OK && hvis.valid &&
          hvis.resource_id == 32'd7 && hvis.size == 64'h1000 &&
          hvis.map_offset == 64'h2000);
    ack();
    r.op = APU_HVIS_CTX;
    r.ctx_id = 32'd3;
    r.context_init = APU_VGPU_CAPSET_VENUS;
    fire(r);
    check("venus ctx ok", cpl.status == APU_HVIS_OK &&
          hvis.ctx_id == 32'd3 && hvis.capset_id == APU_VGPU_CAPSET_VENUS);
    ack();

    cases++;
    r.context_init = APU_VGPU_CAPSET_VIRGL;
    fire(r);
    check("virgl ctx faults", cpl.status == APU_HVIS_FAULT &&
          hvis.capset_id == APU_VGPU_CAPSET_VENUS);
    ack();

    cases++;
    r = '0;
    r.op = APU_HVIS_BLOB;
    r.resource_id = 32'd8;
    r.size = 64'h0000_1000;
    r.blob_mem = APU_BLOB_MEM_HOST3D;
    r.blob_flags = APU_BLOB_FLAG_MAPPABLE;
    fire(r);
    check("second blob faults", cpl.status == APU_HVIS_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU hvis errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_hvis cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
