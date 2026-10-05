// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Venus capset id 4 INFO/GET. Virgl id 1 faults. NumCapsets stays 0.

`timescale 1ns/1ps

module tb_g6lc_apu_vcap;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_vcap_req_t req;
  apu_vcap_cpl_t cpl;
  apu_vcap_t vcap;
  logic [5:0] blob_idx = 0;
  logic [31:0] blob_word;
  logic off_rdy, off_v;
  apu_vcap_cpl_t off_cpl;
  apu_vcap_t off_vcap;
  logic [31:0] off_word;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vcap #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vcap_o(vcap),
    .blob_idx_i(blob_idx), .blob_word_o(blob_word)
  );
  g6lc_apu_vcap_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vcap_o(off_vcap),
    .blob_idx_i(blob_idx), .blob_word_o(off_word)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vcap timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_vcap !== '0 ||
        off_cpl !== '0 || off_word !== '0)
      $fatal(1, "disabled vcap active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic fire(input apu_vcap_req_t r);
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
    apu_vcap_req_t r;
    logic [63:0] feats;
    int unsigned i;

    req = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);

    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vcap off",
          !ApuOff.VcapEn && !ApuP1Transport.VcapEn && !ApuHarness.VcapEn);
    check("num capsets stays 0", ApuP1Transport.NumCapsets == 0 &&
          ApuOff.NumCapsets == 0);
    cfg = ApuP1Transport;
    cfg.VcapEn = 1'b1;
    check("vcap does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl &&
          cfg.NumCapsets == 0);
    cfg = ApuBadVirglGrant;
    cfg.VcapEn = 1'b1;
    check("vcap does not legalize virgl", !apu_cfg_legal(cfg));
    feats = apu_device_features(ApuP1Transport);
    check("blob/ctxinit still off",
          feats[VIRTIO_GPU_F_RESOURCE_BLOB] == 1'b0 &&
          feats[VIRTIO_GPU_F_CONTEXT_INIT] == 1'b0 && feats[0] == 1'b0);

    cases++;
    r = '0;
    r.op = APU_VCAP_INFO;
    r.capset_id = APU_VGPU_CAPSET_VENUS;
    fire(r);
    check("info ok", cpl.status == APU_VCAP_OK && vcap.capset_id == APU_VGPU_CAPSET_VENUS &&
          vcap.max_version == 32'd1 && vcap.max_size == 32'(APU_VCAP_BYTES) &&
          !vcap.valid);
    ack();

    cases++;
    r.op = APU_VCAP_GET;
    r.capset_version = 32'd1;
    fire(r);
    check("get ok", cpl.status == APU_VCAP_OK && vcap.valid);
    blob_idx = 6'd0; #1;
    check("word0 wire fmt", blob_word == APU_VCAP_WIRE_FMT);
    blob_idx = 6'd1; #1;
    check("word1 vk xml", blob_word == APU_VCAP_VK_XML);
    blob_idx = 6'd5; #1;
    check("mask valid bit", blob_word == 32'd1);
    blob_idx = 6'd6; #1;
    check("mask1[1] zero", blob_word == 32'd0);
    blob_idx = 6'd37; #1;
    check("allow wait syncs", blob_word == 32'd1);
    blob_idx = 6'd39; #1;
    check("use guest vram", blob_word == 32'd1);
    for (i = 0; i < APU_VCAP_WORDS; i++) begin
      blob_idx = 6'(i); #1;
      check("rom matches helper", blob_word == apu_vcap_word(6'(i)));
    end
    ack();

    cases++;
    r.op = APU_VCAP_INFO;
    r.capset_id = APU_VGPU_CAPSET_VIRGL;
    fire(r);
    check("virgl info faults", cpl.status == APU_VCAP_FAULT);
    ack();

    cases++;
    r.op = APU_VCAP_GET;
    r.capset_id = APU_VGPU_CAPSET_VIRGL;
    fire(r);
    check("virgl get faults", cpl.status == APU_VCAP_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vcap errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vcap cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
