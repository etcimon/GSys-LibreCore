// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AvailNext GET_CAPSET/INFO Venus blob, then used.idx and ISR.
// NumCapsets stays 0. Not advertised GET_CAPSET. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_gcs;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [31:0] isr, ack_w = 0;
  apu_avu_req_t req;
  apu_gcs_cpl_t cpl;
  apu_gcs_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, wr_addr;
  logic [31:0] rd_len, rsp_len = 0, wr_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0, wr_data;
  logic [63:0] wr_a [0:15];
  logic [31:0] wr_l [0:15], wr_d0 [0:15], wr_d6 [0:15];
  logic off_rdy, off_v, off_rd, off_wr, off_irq, off_rr, off_wr_r;
  logic [31:0] off_isr;
  apu_gcs_cpl_t off_cpl;
  apu_gcs_t off_rec;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0;
  logic [31:0] req_type, req_arg, req_ver, write_len;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] UsedA  = 64'h0000_0000_0000_0600;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1   = 64'h0000_0000_8800_A800;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_gcs #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .gcs_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_gcs_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .gcs_o(off_rec),
    .irq_o(off_irq), .isr_o(off_isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(off_rd), .rd_ready_i(rd_rdy), .rd_addr_o(), .rd_len_o(),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rr), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(off_wr), .wr_ready_i(wr_rdy), .wr_addr_o(), .wr_len_o(),
    .wr_data_o(), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(off_wr_r),
    .wr_rsp_ok_i(wr_ok)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "gcs timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_wr !== 1'b0 ||
        off_irq !== 1'b0 || off_isr !== '0)
      $fatal(1, "disabled gcs active");
  end

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_desc(
      input logic [63:0] addr, input logic [31:0] len,
      input logic [15:0] flags, input logic [15:0] nxt);
    pack_desc = '0;
    pack_desc[63:0] = addr;
    pack_desc[95:64] = len;
    pack_desc[111:96] = flags;
    pack_desc[127:112] = nxt;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_word(input logic [31:0] w);
    pack_word = '0;
    pack_word[31:0] = w;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_cmd;
    pack_cmd = '0;
    pack_cmd[31:0]    = req_type;
    pack_cmd[63:32]   = 32'd1;
    pack_cmd[95:64]   = 32'h5566_7788;
    pack_cmd[127:96]  = 32'h1122_3344;
    pack_cmd[159:128] = 32'd0;
    pack_cmd[191:160] = 32'd0;
    pack_cmd[223:192] = req_arg;
    pack_cmd[255:224] = req_ver;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] lookup(input logic [63:0] addr);
    lookup = '0;
    if (addr == Avail1)
      lookup = pack_word(32'h0001_0000);
    else if (addr == Avail1 + 64'd4)
      lookup = pack_word(32'h0000_0000);
    else if (addr == BaseA + 64'd0)
      lookup = pack_desc(Pay0, 32'(APU_CMS_BYTES), VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup = pack_desc(Pay1, write_len, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == Pay0)
      lookup = pack_cmd();
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
    end else begin
      if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
      else if (rd_v && rd_rdy) begin
        rsp_addr <= rd_addr;
        rsp_len <= rd_len;
        rsp_data <= lookup(rd_addr);
        rsp_ok <= (rd_len == 32'd4) || (rd_len == 32'(APU_CHAIN_DESC_BYTES)) ||
                  (rd_len == 32'(APU_CMS_BYTES));
        rsp_v <= 1'b1;
      end
      if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
      else if (wr_v && wr_rdy) begin
        if (nwrite < 16) begin
          wr_a[nwrite] <= wr_addr;
          wr_l[nwrite] <= wr_len;
          wr_d0[nwrite] <= wr_data[31:0];
          wr_d6[nwrite] <= wr_data[223:192];
        end
        wr_ok <= 1'b1;
        nwrite <= nwrite + 1;
        wr_rsp_v <= 1'b1;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d nw=%0d", name, cases, cycles, nwrite);
    end
  endtask

  task automatic do_reset;
    req_v = 1'b0; cpl_r = 1'b0; ack_v = 1'b0; req = '0; ack_w = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic fire(input apu_avu_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack_cpl;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  task automatic ack_irq;
    @(negedge clk);
    ack_v = 1'b1;
    ack_w = APU_UIR_ISR_VRING;
    @(posedge clk);
    @(negedge clk);
    ack_v = 1'b0;
    ack_w = '0;
    @(posedge clk);
  endtask

  task automatic prep_req(output apu_avu_req_t r);
    r = '0;
    r.avail_base = Avail1;
    r.desc_base = BaseA;
    r.used_base = UsedA;
    r.queue_size = 8'd4;
    r.device_idx = 16'd0;
    r.used_idx = 16'd0;
    r.max_chain = 4'd8;
  endtask

  initial begin
    apu_avu_req_t r;
    apu_cfg_t cfg;
    int unsigned w0;

    req_type = VGPU_CMD_GET_CAPSET_INFO;
    req_arg = 32'd0;
    req_ver = 32'd0;
    write_len = 32'(APU_GCS_INFO_BYTES);

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_irq == 1'b0 && req_rdy == 1'b1);
    check("profiles keep gcs off",
          !ApuOff.GcsEn && !ApuP1Transport.GcsEn && !ApuHarness.GcsEn);
    cfg = ApuP1Transport;
    cfg.GcsEn = 1'b1;
    check("gcs does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GcsEn = 1'b1;
    check("gcs does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    w0 = nwrite;
    prep_req(r);
    fire(r);
    check("info ok", cpl.status == APU_GCS_OK && rec.valid && rec.info &&
          rec.irq && irq && rec.used_idx == 16'd1 && rec.resp_addr == Pay1 &&
          rec.capset_id == APU_VGPU_CAPSET_VENUS &&
          rec.resp_word0 == VGPU_RESP_OK_CAPSET_INFO);
    check("info order", (nwrite - w0) == 4 && wr_a[0] == Pay1 &&
          wr_l[0] == 32'(APU_VGPU_BEAT_BYTES) &&
          wr_d0[0] == VGPU_RESP_OK_CAPSET_INFO &&
          wr_d6[0] == APU_VGPU_CAPSET_VENUS &&
          wr_a[1] == Pay1 + 64'(APU_VGPU_BEAT_BYTES) && wr_l[1] == 32'd8 &&
          wr_d0[1] == 32'(APU_VCAP_BYTES) &&
          wr_a[2] == UsedA + 64'd4 && wr_l[2] == 32'd8 &&
          wr_a[3] == UsedA && wr_l[3] == 32'd4);
    ack_cpl();
    ack_irq();
    check("info ack lowers", !irq && isr == 32'd0);

    cases++;
    do_reset;
    req_type = VGPU_CMD_GET_CAPSET;
    req_arg = APU_VGPU_CAPSET_VENUS;
    req_ver = 32'd0;
    write_len = 32'(APU_GCS_GET_BYTES);
    w0 = nwrite;
    prep_req(r);
    fire(r);
    check("get ok", cpl.status == APU_GCS_OK && rec.valid && !rec.info &&
          rec.irq && irq && rec.used_idx == 16'd1 && rec.resp_addr == Pay1 &&
          rec.capset_id == APU_VGPU_CAPSET_VENUS &&
          rec.resp_word0 == VGPU_RESP_OK_CAPSET);
    check("get blob", (nwrite - w0) == 8 && wr_a[0] == Pay1 &&
          wr_l[0] == 32'(APU_VGPU_BEAT_BYTES) &&
          wr_d0[0] == VGPU_RESP_OK_CAPSET &&
          wr_d6[0] == APU_VCAP_WIRE_FMT &&
          wr_a[1] == Pay1 + 64'(APU_VGPU_BEAT_BYTES) &&
          wr_d0[1] == APU_VCAP_CMD_SER &&
          wr_a[5] == Pay1 + 64'd160 && wr_l[5] == 32'd24 &&
          wr_a[6] == UsedA + 64'd4 && wr_a[7] == UsedA);
    ack_cpl();
    ack_irq();

    cases++;
    do_reset;
    req_type = VGPU_CMD_GET_CAPSET;
    req_arg = APU_VGPU_CAPSET_VIRGL;
    req_ver = 32'd0;
    write_len = 32'(APU_GCS_GET_BYTES);
    w0 = nwrite;
    prep_req(r);
    fire(r);
    check("virgl faults", cpl.status == APU_GCS_FAULT && !rec.valid &&
          !irq && (nwrite - w0) == 0);
    ack_cpl();

    cases++;
    do_reset;
    req_type = VGPU_CMD_GET_CAPSET_INFO;
    req_arg = 32'd0;
    req_ver = 32'd0;
    write_len = 32'(APU_GCS_INFO_BYTES);
    w0 = nwrite;
    prep_req(r);
    r.device_idx = 16'd1;
    r.used_idx = 16'd1;
    fire(r);
    check("empty", cpl.status == APU_GCS_EMPTY && !rec.valid && !irq &&
          (nwrite - w0) == 0);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU gcs errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_gcs cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
