// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ALLOC CMDBUF, BEGIN LOOKUP, CREATE MODULE, DISPATCH SpirvSubset.
// NumCapsets stays 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_bru;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq;
  logic [7:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata, in_a = 0, in_b = 0, result;
  apu_bru_req_t req;
  apu_bru_cpl_t cpl;
  apu_bru_t rec;
  logic off_rdy, off_v, off_irq;
  apu_bru_cpl_t off_cpl;
  apu_bru_t off_rec;
  logic [31:0] off_rdata, off_res;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_bru #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .bru_o(rec),
    .irq_o(irq), .result_o(result)
  );
  g6lc_apu_bru_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .bru_o(off_rec),
    .irq_o(off_irq), .result_o(off_res)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "bru timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 ||
        off_irq !== 1'b0 || off_res !== '0)
      $fatal(1, "disabled bru active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d st=%0d", name, cases, cycles, cpl.status);
    end
  endtask

  task automatic poke(input int unsigned idx, input logic [31:0] w);
    @(negedge clk);
    cs_we = 1'b1;
    cs_idx = 8'(idx);
    cs_wdata = w;
    @(posedge clk);
    @(negedge clk);
    cs_we = 1'b0;
  endtask

  task automatic peek(input int unsigned idx, output logic [31:0] w);
    cs_idx = 8'(idx);
    @(negedge clk);
    w = cs_rdata;
  endtask

  task automatic poke64(input int unsigned idx, input logic [63:0] v);
    poke(idx, v[31:0]);
    poke(idx + 1, v[63:32]);
  endtask

  task automatic fire(input apu_bru_req_t r);
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

  task automatic do_reset;
    cs_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0; req = '0;
    in_a = '0; in_b = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_bru_req_t mk_op(input apu_bru_op_e op);
    mk_op = '0;
    mk_op.op = op;
  endfunction

  function automatic apu_bru_req_t mk_gnh(
      input apu_gnh_op_e op, input apu_gnh_kind_e kind,
      input logic [31:0] oid, input logic [31:0] h);
    mk_gnh = '0;
    mk_gnh.op = APU_BRU_GNH;
    mk_gnh.gnh.op = op;
    mk_gnh.gnh.kind = kind;
    mk_gnh.gnh.object_id = oid;
    mk_gnh.gnh.handle = h;
  endfunction

  function automatic logic [31:0] enc(input int unsigned wc, input int unsigned op);
    return {16'(wc), 16'(op)};
  endfunction

  task automatic fill_alu(input logic [15:0] alu, ref logic [31:0] mem [0:127],
                          output int unsigned n);
    n = 0;
    mem[n++] = APU_SPIRV_MAGIC;
    mem[n++] = 32'h00010000;
    mem[n++] = 32'h0;
    mem[n++] = 32'd13;
    mem[n++] = 32'h0;
    mem[n++] = enc(2, 17); mem[n++] = 32'd1;
    mem[n++] = enc(3, 14); mem[n++] = 32'd0; mem[n++] = 32'd1;
    mem[n++] = enc(5, 15); mem[n++] = 32'd5; mem[n++] = 32'd8;
    mem[n++] = 32'h6E69616D; mem[n++] = 32'h0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd5; mem[n++] = 32'd33; mem[n++] = 32'd0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd6; mem[n++] = 32'd33; mem[n++] = 32'd1;
    mem[n++] = enc(4, 71); mem[n++] = 32'd7; mem[n++] = 32'd33; mem[n++] = 32'd2;
    mem[n++] = enc(2, 19); mem[n++] = 32'd1;
    mem[n++] = enc(4, 21); mem[n++] = 32'd2; mem[n++] = 32'd32; mem[n++] = 32'd0;
    mem[n++] = enc(4, 32); mem[n++] = 32'd3; mem[n++] = 32'd12; mem[n++] = 32'd2;
    mem[n++] = enc(3, 33); mem[n++] = 32'd4; mem[n++] = 32'd1;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd5; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd6; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(5, 54); mem[n++] = 32'd1; mem[n++] = 32'd8; mem[n++] = 32'd0;
    mem[n++] = 32'd4;
    mem[n++] = enc(2, 248); mem[n++] = 32'd9;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd10; mem[n++] = 32'd5;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd11; mem[n++] = 32'd6;
    mem[n++] = enc(5, alu); mem[n++] = 32'd2; mem[n++] = 32'd12; mem[n++] = 32'd10;
    mem[n++] = 32'd11;
    mem[n++] = enc(3, 62); mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(1, 253);
    mem[n++] = enc(1, 56);
  endtask

  task automatic load_create(input logic [31:0] mem [0:127], input int unsigned n,
                             input logic [63:0] module_id);
    int unsigned i;
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    poke(1, 32'd0);
    poke64(2, 64'hA1);
    poke64(4, 64'd1);
    poke(6, APU_VNENC_STYPE_SHADER_MODULE);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke64(10, 64'(n * 4));
    poke64(12, 64'(n));
    for (i = 0; i < n; i++) poke(APU_VNENC_CODE0 + i, mem[i]);
    poke64(APU_VNENC_CODE0 + n, 64'd0);
    poke64(APU_VNENC_CODE0 + n + 2, 64'd1);
    poke64(APU_VNENC_CODE0 + n + 4, module_id);
  endtask

  task automatic load_alloc(input logic [31:0] flags, input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VAC_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VAC_CMD_ALLOC);
    poke(1, flags);
    poke64(2, 64'hD1);
    poke64(4, 64'd1);
    poke(6, APU_VAC_STYPE_ALLOC);
    poke64(7, 64'd0);
    poke64(9, 64'hA1);
    poke(11, APU_VAC_LEVEL_PRIMARY);
    poke(12, 32'd1);
    poke64(13, 64'd1);
    poke64(15, guest);
  endtask

  task automatic load_begin(input logic [31:0] flags, input logic [63:0] cmdbuf,
                            input logic [31:0] bflags);
    poke(0, APU_VBG_CMD_BEGIN);
    poke(1, flags);
    poke64(2, cmdbuf);
    poke64(4, 64'd1);
    poke(6, APU_VBG_STYPE_BEGIN);
    poke64(7, 64'd0);
    poke(9, bflags);
    poke64(10, 64'd0);
  endtask

  task automatic load_dispatch(input logic [63:0] cmdbuf);
    poke(0, APU_VND_CMD_DISPATCH);
    poke(1, 32'd0);
    poke64(2, cmdbuf);
    poke(4, 32'd1);
    poke(5, 32'd1);
    poke(6, 32'd1);
  endtask

  task automatic load_end(input logic [31:0] flags, input logic [63:0] cmdbuf);
    poke(0, APU_VEN_CMD_END);
    poke(1, flags);
    poke64(2, cmdbuf);
  endtask

  task automatic load_submit(input logic [31:0] flags, input logic [63:0] queue,
                             input logic [63:0] cmdbuf);
    integer i;
    for (i = 0; i < APU_VQS_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VQS_CMD_SUBMIT);
    poke(1, flags);
    poke64(2, queue);
    poke(4, 32'd1);
    poke64(5, 64'd1);
    poke(7, APU_VQS_STYPE_SUBMIT);
    poke64(8, 64'd0);
    poke(10, 32'd0);
    poke64(11, 64'd0);
    poke64(13, 64'd0);
    poke(15, 32'd1);
    poke64(16, 64'd1);
    poke64(18, cmdbuf);
    poke(20, 32'd0);
    poke64(21, 64'd0);
    poke64(23, 64'd0);
  endtask

  task automatic load_wait(input logic [31:0] flags, input logic [63:0] qh);
    poke(0, APU_VWI_CMD_WAIT);
    poke(1, flags);
    poke64(2, qh);
  endtask

  task automatic load_queue(input logic [31:0] flags, input logic [63:0] device);
    poke(0, APU_VGQ_CMD_QUEUE);
    poke(1, flags);
    poke64(2, device);
    poke(4, 32'd0);
    poke(5, 32'd0);
  endtask

  task automatic load_device(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_VCD_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VCD_CMD_DEVICE);
    poke(1, flags);
    poke64(2, phys);
    poke64(4, 64'd1);
    poke(6, APU_VCD_STYPE_DEVICE);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke(10, 32'd1);
    poke64(11, 64'd1);
    poke(13, APU_VCD_STYPE_QUEUE);
    poke64(14, 64'd0);
    poke(16, 32'd0);
    poke(17, 32'd0);
    poke(18, 32'd1);
    poke64(19, 64'd1);
    poke(21, APU_VCD_PRIORITY_ONE);
    poke(22, 32'd0);
    poke64(23, 64'd0);
    poke(25, 32'd0);
    poke64(26, 64'd0);
    poke64(28, 64'd0);
    poke64(30, 64'd0);
  endtask

  task automatic load_instance(input logic [31:0] flags, input logic [63:0] info);
    integer i;
    for (i = 0; i < APU_VCI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VCI_CMD_INSTANCE);
    poke(1, flags);
    poke64(2, info);
    poke(4, APU_VCI_STYPE_INSTANCE);
    poke64(5, 64'd0);
    poke(7, 32'd0);
    poke64(8, 64'd0);
    poke(10, 32'd0);
    poke64(11, 64'd0);
    poke(13, 32'd0);
    poke64(14, 64'd0);
    poke64(16, 64'd0);
  endtask

  task automatic load_enum(input logic [31:0] flags, input logic [63:0] inst);
    integer i;
    for (i = 0; i < APU_VEP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VEP_CMD_ENUM);
    poke(1, flags);
    poke64(2, inst);
    poke64(4, 64'd1);
    poke(6, 32'd1);
    poke64(7, 64'd1);
    poke64(9, 64'd1);
  endtask

  task automatic load_qfam(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_VQF_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VQF_CMD_QFAM);
    poke(1, flags);
    poke64(2, phys);
    poke64(4, 64'd1);
    poke(6, APU_VQF_FAMILY_COUNT);
    poke64(7, 64'd1);
    poke64(9, 64'd1);
  endtask

  task automatic load_feat(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_VPF_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VPF_CMD_FEAT);
    poke(1, flags);
    poke64(2, phys);
    poke64(4, 64'd1);
  endtask

  task automatic load_props(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_VPP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VPP_CMD_PROPS);
    poke(1, flags);
    poke64(2, phys);
    poke64(4, 64'd1);
  endtask

  task automatic load_mem(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_VMP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VMP_CMD_MEM);
    poke(1, flags);
    poke64(2, phys);
    poke64(4, 64'd1);
  endtask

  task automatic load_vkmem(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [31:0] tidx, input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VAM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VAM_CMD_MEMORY);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, 64'd1);
    poke(6, APU_VAM_STYPE_ALLOC);
    poke64(7, 64'd0);
    poke64(9, 64'd4096);
    poke(11, tidx);
    poke64(12, 64'd0);
    poke64(14, guest);
  endtask

  task automatic load_buffer(input logic [31:0] flags, input logic [63:0] dev,
                             input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VXB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VXB_CMD_BUFFER);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, 64'd1);
    poke(6, APU_VXB_STYPE_BUFFER);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke64(10, 64'd4096);
    poke(12, APU_VXB_USAGE_STORAGE);
    poke(13, 32'd0);
    poke(14, 32'd0);
    poke64(15, 64'd0);
    poke64(17, 64'd0);
    poke64(19, guest);
  endtask

  task automatic load_bind(input logic [31:0] flags, input logic [63:0] dev,
                           input logic [63:0] bufh, input logic [63:0] memh);
    integer i;
    for (i = 0; i < APU_VBB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VBB_CMD_BIND);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, bufh);
    poke64(6, memh);
    poke64(8, 64'd0);
  endtask

  task automatic load_map(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] memh, input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VMM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VMM_CMD_MAP);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, memh);
    poke64(6, 64'd0);
    poke64(8, 64'd4096);
    poke(10, 32'd0);
    poke64(11, guest);
  endtask

  task automatic load_unmap(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [63:0] memh);
    integer i;
    for (i = 0; i < APU_VUM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VUM_CMD_UNMAP);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, memh);
  endtask

  task automatic load_bufreq(input logic [31:0] flags, input logic [63:0] dev,
                             input logic [63:0] bufh);
    integer i;
    for (i = 0; i < APU_VBM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VBM_CMD_BUFREQ);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, bufh);
    poke64(6, 64'd1);
  endtask

  task automatic load_flush(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [63:0] memh);
    integer i;
    for (i = 0; i < APU_VFM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VFM_CMD_FLUSH);
    poke(1, flags);
    poke64(2, dev);
    poke(4, 32'd1);
    poke64(5, 64'd1);
    poke(7, APU_VFM_STYPE_RANGE);
    poke64(8, 64'd0);
    poke64(10, memh);
    poke64(12, 64'd0);
    poke64(14, 64'd4096);
  endtask

  task automatic load_inval(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [63:0] memh);
    integer i;
    for (i = 0; i < APU_VIM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VIM_CMD_INVAL);
    poke(1, flags);
    poke64(2, dev);
    poke(4, 32'd1);
    poke64(5, 64'd1);
    poke(7, APU_VIM_STYPE_RANGE);
    poke64(8, 64'd0);
    poke64(10, memh);
    poke64(12, 64'd0);
    poke64(14, 64'd4096);
  endtask

  task automatic load_memc(input logic [31:0] flags, input logic [63:0] dev,
                           input logic [63:0] memh);
    integer i;
    for (i = 0; i < APU_VMC_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VMC_CMD_MEMC);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, memh);
    poke64(6, 64'd1);
  endtask

  task automatic load_dsl(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VDL_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VDL_CMD_DSLAYOUT);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, 64'd1);
    poke(6, APU_VDL_STYPE);
    poke64(7, 64'd0);
    poke(9, 32'd1);
    poke(10, 32'd0);
    poke(11, APU_VDL_STORAGE);
    poke(12, 32'd1);
    poke(13, APU_VDL_COMPUTE);
    poke64(14, 64'd0);
    poke64(16, guest);
  endtask

  task automatic load_pl(input logic [31:0] flags, input logic [63:0] dev,
                         input logic [63:0] setl, input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VPL_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VPL_CMD_PLAYOUT);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, 64'd1);
    poke(6, APU_VPL_STYPE);
    poke64(7, 64'd0);
    poke(9, 32'd1);
    poke64(10, setl);
    poke(12, 32'd0);
    poke64(13, 64'd0);
    poke64(15, guest);
  endtask

  task automatic load_cp(input logic [31:0] flags, input logic [63:0] dev,
                         input logic [63:0] shader, input logic [63:0] layout,
                         input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VCP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VCP_CMD_CPIPE);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, 64'd0);
    poke(6, 32'd1);
    poke64(7, 64'd1);
    poke(9, APU_VCP_STYPE);
    poke64(10, 64'd0);
    poke(12, APU_VDL_COMPUTE);
    poke64(13, shader);
    poke64(15, layout);
    poke64(17, 64'd0);
    poke64(19, guest);
  endtask

  task automatic load_dset(input logic [31:0] flags, input logic [63:0] dev,
                           input logic [63:0] layout, input logic [63:0] poolh,
                           input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VDA_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VDA_CMD_DESCSET);
    poke(1, flags);
    poke64(2, dev);
    poke64(4, 64'd1);
    poke(6, APU_VDA_STYPE);
    poke64(7, 64'd0);
    poke64(9, poolh);
    poke(11, 32'd1);
    poke64(12, layout);
    poke64(14, guest);
  endtask

  task automatic load_pool(input logic [31:0] flags, input logic [63:0] dev,
                           input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VPO_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VPO_CMD_POOL); poke(1, flags); poke64(2, dev); poke64(4, 64'd1);
    poke(6, APU_VPO_STYPE); poke64(7, 64'd0); poke(9, 32'd0); poke(10, 32'd1);
    poke(11, 32'd1); poke64(12, 64'd1); poke(14, APU_VDL_STORAGE); poke(15, 32'd1);
    poke64(16, 64'd0); poke64(18, guest);
  endtask

  task automatic load_image(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VXI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VXI_CMD_IMAGE); poke(1, flags); poke64(2, dev); poke64(4, 64'd1);
    poke(6, APU_VXI_STYPE); poke64(7, 64'd0); poke(9, 32'd0);
    poke(10, APU_VXI_TYPE_2D); poke(11, APU_VXI_FORMAT);
    poke(12, APU_VXI_WIDTH); poke(13, APU_VXI_HEIGHT); poke(14, 32'd1);
    poke(15, 32'd1); poke(16, 32'd1); poke(17, 32'd1);
    poke(18, APU_VXI_TILING_LINEAR); poke(19, APU_VXI_USAGE_STORAGE);
    poke(20, 32'd0); poke(21, 32'd0); poke64(22, 64'd0); poke(24, 32'd0);
    poke64(25, 64'd0); poke64(27, guest);
  endtask

  task automatic load_bindimg(input logic [31:0] flags, input logic [63:0] dev,
                              input logic [63:0] imgh, input logic [63:0] memh);
    integer i;
    for (i = 0; i < APU_VBI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VBI_CMD_BINDIMG); poke(1, flags); poke64(2, dev);
    poke64(4, imgh); poke64(6, memh); poke64(8, 64'd0);
  endtask

  task automatic load_imgreq(input logic [31:0] flags, input logic [63:0] dev,
                             input logic [63:0] imgh);
    integer i;
    for (i = 0; i < APU_VMI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VMI_CMD_IMGREQ); poke(1, flags); poke64(2, dev);
    poke64(4, imgh); poke64(6, 64'd1);
  endtask

  task automatic load_view(input logic [31:0] flags, input logic [63:0] dev,
                           input logic [63:0] imgh, input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VXV_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VXV_CMD_VIEW); poke(1, flags); poke64(2, dev); poke64(4, 64'd1);
    poke(6, APU_VXV_STYPE); poke64(7, 64'd0); poke(9, 32'd0); poke64(10, imgh);
    poke(12, APU_VXV_TYPE_2D); poke(13, APU_VXI_FORMAT);
    poke(14, 32'd0); poke(15, 32'd0); poke(16, 32'd0); poke(17, 32'd0);
    poke(18, APU_VXV_ASPECT_COLOR); poke(19, 32'd0); poke(20, 32'd1);
    poke(21, 32'd0); poke(22, 32'd1); poke64(23, 64'd0); poke64(25, guest);
  endtask

  task automatic load_sampler(input logic [31:0] flags, input logic [63:0] dev,
                              input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VSM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VSM_CMD_SAMPLER); poke(1, flags); poke64(2, dev); poke64(4, 64'd1);
    poke(6, APU_VSM_STYPE); poke64(7, 64'd0); poke(9, 32'd0);
    poke(10, APU_VSM_LINEAR); poke(11, APU_VSM_LINEAR); poke(12, APU_VSM_LINEAR);
    poke(13, 32'd0); poke(14, 32'd0); poke(15, 32'd0);
    poke64(16, 64'd0); poke64(18, guest);
  endtask

  task automatic load_rpass(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VRP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VRP_CMD_RPASS); poke(1, flags); poke64(2, dev); poke64(4, 64'd1);
    poke(6, APU_VRP_STYPE); poke64(7, 64'd0); poke(9, 32'd0); poke(10, 32'd1);
    poke(11, APU_VXI_FORMAT); poke(12, 32'd1); poke(13, 32'd1); poke(14, 32'd0);
    poke(15, 32'd0); poke64(16, 64'd0); poke64(18, guest);
  endtask


  task automatic load_fbuf(input logic [31:0] flags, input logic [63:0] dev,
                           input logic [63:0] rpass, input logic [63:0] viewh,
                           input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VFB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VFB_CMD_FBUF); poke(1, flags); poke64(2, dev); poke64(4, 64'd1);
    poke(6, APU_VFB_STYPE); poke64(7, 64'd0); poke(9, 32'd0); poke64(10, rpass);
    poke(12, 32'd1); poke64(13, viewh); poke(15, APU_VXI_WIDTH);
    poke(16, APU_VXI_HEIGHT); poke(17, 32'd1); poke64(18, 64'd0); poke64(20, guest);
  endtask

  task automatic load_beginrp(input logic [31:0] flags, input logic [63:0] cbuf,
                              input logic [63:0] rpass, input logic [63:0] fbuf);
    integer i;
    for (i = 0; i < APU_VRB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VRB_CMD_BEGINRP); poke(1, flags); poke64(2, cbuf); poke64(4, 64'd1);
    poke(6, APU_VRB_STYPE); poke64(7, 64'd0); poke64(9, rpass); poke64(11, fbuf);
    poke(13, 32'd0); poke(14, 32'd0); poke(15, APU_VXI_WIDTH);
    poke(16, APU_VXI_HEIGHT); poke(17, 32'd1); poke(18, APU_VRB_INLINE);
  endtask

  task automatic load_draw(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_VDW_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VDW_CMD_DRAW); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_VDW_VERTS); poke(5, 32'd1); poke(6, 32'd0); poke(7, 32'd0);
  endtask

  task automatic load_endrp(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_VRE_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VRE_CMD_ENDRP); poke(1, flags); poke64(2, cbuf);
  endtask


  task automatic load_bindvtx(input logic [31:0] flags, input logic [63:0] cbuf,
                              input logic [63:0] bufh);
    integer i;
    for (i = 0; i < APU_VVB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VVB_CMD_BINDVTX); poke(1, flags); poke64(2, cbuf);
    poke(4, 32'd0); poke(5, 32'd1); poke64(6, bufh); poke64(8, 64'd0);
  endtask

  task automatic load_bindidx(input logic [31:0] flags, input logic [63:0] cbuf,
                              input logic [63:0] bufh);
    integer i;
    for (i = 0; i < APU_VIB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VIB_CMD_BINDIDX); poke(1, flags); poke64(2, cbuf);
    poke64(4, bufh); poke64(6, 64'd0); poke(8, APU_VIB_UINT16);
  endtask

  task automatic load_drawidx(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_VDI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VDI_CMD_DRAWIDX); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_VDI_INDICES); poke(5, 32'd1); poke(6, 32'd0); poke(7, 32'd0);
    poke(8, 32'd0);
  endtask


  task automatic load_setvp(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_VVP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VVP_CMD_SETVP); poke(1, flags); poke64(2, cbuf);
    poke(4, 32'd0); poke(5, 32'd1); poke64(6, 64'd1);
    poke(8, 32'd0); poke(9, 32'd0); poke(10, APU_VVP_F64); poke(11, APU_VVP_F64);
    poke(12, 32'd0); poke(13, APU_VVP_F1);
  endtask

  task automatic load_setsc(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_VSI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VSI_CMD_SETSC); poke(1, flags); poke64(2, cbuf);
    poke(4, 32'd0); poke(5, 32'd1); poke64(6, 64'd1);
    poke(8, 32'd0); poke(9, 32'd0); poke(10, APU_VXI_WIDTH); poke(11, APU_VXI_HEIGHT);
  endtask

  task automatic load_barrier(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_VPB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VPB_CMD_BARRIER); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_VPB_TOP); poke(5, APU_VPB_TOP); poke(6, 32'd0);
    poke(7, 32'd0); poke(8, 32'd0); poke(9, 32'd0);
  endtask

  task automatic load_slw(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_SLW_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_SLW_CMD_SLW); poke(1, flags); poke64(2, cbuf); poke(4, APU_VVP_F1);
  endtask

  task automatic load_sdb(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_SDB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_SDB_CMD_SDB); poke(1, flags); poke64(2, cbuf);
    poke(4, 32'd0); poke(5, 32'd0); poke(6, 32'd0);
  endtask

  task automatic load_sbc(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_SBC_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_SBC_CMD_SBC); poke(1, flags); poke64(2, cbuf);
    poke(4, 32'd0); poke(5, 32'd0); poke(6, 32'd0); poke(7, 32'd0);
  endtask

  task automatic load_sbb(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_SBB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_SBB_CMD_SBB); poke(1, flags); poke64(2, cbuf);
    poke(4, 32'd0); poke(5, APU_VVP_F1);
  endtask

  task automatic load_scm(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_SCM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_SCM_CMD_SCM); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_SCM_FACE); poke(5, APU_SCM_MASK);
  endtask

  task automatic load_swm(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_SWM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_SWM_CMD_SWM); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_SCM_FACE); poke(5, APU_SCM_MASK);
  endtask

  task automatic load_srf(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_SRF_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_SRF_CMD_SRF); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_SCM_FACE); poke(5, APU_SRF_REF);
  endtask

  task automatic load_ccb(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_CCB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CCB_CMD_CCB); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst); poke(8, APU_CCB_COUNT);
    poke64(9, 64'(APU_CCB_SRC_OFF)); poke64(11, 64'(APU_CCB_DST_OFF));
    poke64(13, 64'(APU_CCB_SIZE));
  endtask

  task automatic load_cci(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_CCI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CCI_CMD_CCI); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst);
    poke(8, APU_CCI_SRC_LAYOUT); poke(9, APU_CCI_DST_LAYOUT); poke(10, APU_CCI_COUNT);
    poke(11, APU_CCI_ASPECT); poke(14, 32'd1);
    poke(18, APU_CCI_ASPECT); poke(21, 32'd1); poke(22, APU_CCI_DST_X);
    poke(25, APU_CCI_EXT_W); poke(26, APU_CCI_EXT_H); poke(27, APU_CCI_EXT_D);
  endtask

  task automatic load_bli(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_BLI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_BLI_CMD_BLI); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst);
    poke(8, APU_CCI_SRC_LAYOUT); poke(9, APU_CCI_DST_LAYOUT); poke(10, APU_CCI_COUNT);
    poke(11, APU_CCI_ASPECT); poke(14, 32'd1);
    poke(18, APU_BLI_SRC1_X); poke(19, APU_BLI_SRC1_Y); poke(20, APU_BLI_SRC1_Z);
    poke(21, APU_CCI_ASPECT); poke(24, 32'd1);
    poke(25, APU_BLI_DST0_X); poke(28, APU_BLI_DST1_X);
    poke(29, APU_BLI_DST1_Y); poke(30, APU_BLI_DST1_Z); poke(31, APU_BLI_FILTER);
  endtask

  task automatic load_cbi(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_CBI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CBI_CMD_CBI); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst);
    poke(8, APU_CCI_DST_LAYOUT); poke(9, APU_CCI_COUNT);
    poke(14, APU_CCI_ASPECT); poke(17, 32'd1);
    poke(21, APU_CBI_EXT_W); poke(22, APU_CBI_EXT_H); poke(23, APU_CCI_EXT_D);
  endtask

  task automatic load_cib(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_CIB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CIB_CMD_CIB); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst);
    poke(8, APU_CCI_SRC_LAYOUT); poke(9, APU_CCI_COUNT);
    poke(14, APU_CCI_ASPECT); poke(17, 32'd1);
    poke(21, APU_CBI_EXT_W); poke(22, APU_CBI_EXT_H); poke(23, APU_CCI_EXT_D);
  endtask

  task automatic load_ubf(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_UBF_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_UBF_CMD_UBF); poke(1, flags); poke64(2, cbuf);
    poke64(4, dst); poke64(8, 64'(APU_UBF_SIZE)); poke(10, APU_UBF_DATA);
  endtask

  task automatic load_fil(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_FIL_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_FIL_CMD_FIL); poke(1, flags); poke64(2, cbuf);
    poke64(4, dst); poke64(8, 64'(APU_VBM_SIZE)); poke(10, APU_FIL_DATA);
  endtask

  task automatic load_ccl(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_CCL_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CCL_CMD_CCL); poke(1, flags); poke64(2, cbuf);
    poke64(4, dst); poke(6, APU_CCI_DST_LAYOUT);
    poke(11, APU_CCI_COUNT); poke(12, APU_CCI_ASPECT);
    poke(14, 32'd1); poke(16, 32'd1);
  endtask

  task automatic load_dri(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_DRI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DRI_CMD_DRI); poke(1, flags); poke64(2, cbuf);
    poke64(4, dst); poke(8, APU_DRI_COUNT); poke(9, APU_DRI_STRIDE);
  endtask

  task automatic load_ixi(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_IXI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_IXI_CMD_IXI); poke(1, flags); poke64(2, cbuf);
    poke64(4, dst); poke(8, APU_IXI_COUNT); poke(9, APU_IXI_STRIDE);
  endtask

  task automatic load_cds(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_CDS_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CDS_CMD_CDS); poke(1, flags); poke64(2, cbuf);
    poke64(4, dst); poke(6, APU_CCI_DST_LAYOUT); poke(7, APU_VVP_F1);
    poke(9, APU_CCI_COUNT); poke(10, APU_CDS_ASPECT);
    poke(12, 32'd1); poke(14, 32'd1);
  endtask

  task automatic load_cat(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_CAT_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CAT_CMD_CAT); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_CAT_COUNT); poke(5, APU_CAT_ASPECT);
    poke(11, APU_CAT_COUNT); poke(14, APU_CAT_EXT); poke(15, APU_CAT_EXT);
    poke(17, 32'd1);
  endtask

  task automatic load_dsi(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_DSI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DSI_CMD_DSI); poke(1, flags); poke64(2, cbuf); poke64(4, dst);
  endtask

  task automatic load_rsi(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i;
    for (i = 0; i < APU_RSI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_RSI_CMD_RSI); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst);
    poke(8, APU_CCI_SRC_LAYOUT); poke(9, APU_CCI_DST_LAYOUT); poke(10, APU_CCI_COUNT);
    poke(11, APU_CCI_ASPECT); poke(14, 32'd1);
    poke(18, APU_CCI_ASPECT); poke(21, 32'd1); poke(22, APU_RSI_DST_X);
    poke(25, APU_RSI_EXT); poke(26, APU_RSI_EXT); poke(27, APU_CCI_EXT_D);
  endtask







  task automatic load_nextsp(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i;
    for (i = 0; i < APU_VNS_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VNS_CMD_NEXTSP); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_VRB_INLINE);
  endtask

  task automatic load_dfb(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DFB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DFB_CMD_DFB); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dvw(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DVW_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DVW_CMD_DVW); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dsm(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DSM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DSM_CMD_DSM); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_drp(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DRP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DRP_CMD_DRP); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dbf(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DBF_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DBF_CMD_DBF); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dim(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DIM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DIM_CMD_DIM); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_fme(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_FME_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_FME_CMD_FME); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dmd(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DMD_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DMD_CMD_DMD); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dpl(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DPL_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DPL_CMD_DPL); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dyo(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DYO_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DYO_CMD_DYO); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dds(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DDS_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DDS_CMD_DDS); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_dpo(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_DPO_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DPO_CMD_DPO); poke(1, flags); poke64(2, dev);
    poke64(4, objh); poke64(6, 64'd0);
  endtask

  task automatic load_fds(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] pool, input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_FDS_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_FDS_CMD_FDS); poke(1, flags); poke64(2, dev);
    poke64(4, pool); poke(6, 32'd1); poke(7, 32'd1); poke64(8, objh);
  endtask

  task automatic load_rcb(input logic [31:0] flags, input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_RCB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_RCB_CMD_RCB); poke(1, flags); poke64(2, objh); poke(4, 32'd0);
  endtask

  task automatic load_fcb(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] pool, input logic [63:0] objh);
    integer i;
    for (i = 0; i < APU_FCB_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_FCB_CMD_FCB); poke(1, flags); poke64(2, dev);
    poke64(4, pool); poke(6, 32'd1); poke(7, 32'd1); poke64(8, objh);
  endtask

  task automatic load_ddv(input logic [31:0] flags, input logic [63:0] dev);
    integer i;
    for (i = 0; i < APU_DDV_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DDV_CMD_DDV); poke(1, flags); poke64(2, dev); poke64(4, 64'd0);
  endtask

  task automatic load_rcp(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] pool);
    integer i;
    for (i = 0; i < APU_RCP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_RCP_CMD_RCP); poke(1, flags); poke64(2, dev);
    poke64(4, pool); poke(6, 32'd0);
  endtask

  task automatic load_dcp(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] pool);
    integer i;
    for (i = 0; i < APU_DCP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DCP_CMD_DCP); poke(1, flags); poke64(2, dev);
    poke64(4, pool); poke64(6, 64'd0);
  endtask

  task automatic load_din(input logic [31:0] flags, input logic [63:0] insth);
    integer i;
    for (i = 0; i < APU_DIN_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DIN_CMD_DIN); poke(1, flags); poke64(2, insth); poke64(4, 64'd0);
  endtask

  task automatic load_gfp(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_GFP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_GFP_CMD_GFP); poke(1, flags); poke64(2, phys);
    poke(4, APU_GFP_FORMAT); poke64(5, 64'd1);
  endtask

  task automatic load_ifp(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_IFP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_IFP_CMD_IFP); poke(1, flags); poke64(2, phys);
    poke(4, APU_GFP_FORMAT); poke(5, APU_IFP_TYPE_2D);
    poke(6, APU_IFP_TILING_LINEAR); poke(7, APU_IFP_USAGE_STORAGE);
    poke(8, 32'd0); poke64(9, 64'd1);
  endtask

  task automatic load_dex(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_DEX_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DEX_CMD_DEX); poke(1, flags); poke64(2, phys);
    poke64(4, 64'd0); poke64(6, 64'd1); poke(8, 32'd0);
  endtask

  task automatic load_rdp(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] pool);
    integer i;
    for (i = 0; i < APU_RDP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_RDP_CMD_RDP); poke(1, flags); poke64(2, dev);
    poke64(4, pool); poke(6, 32'd0);
  endtask

  task automatic load_iex(input logic [31:0] flags);
    integer i;
    for (i = 0; i < APU_IEX_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_IEX_CMD_IEX); poke(1, flags);
    poke64(2, 64'd0); poke64(4, 64'd1); poke(6, 32'd0);
  endtask

  task automatic load_dwi(input logic [31:0] flags, input logic [63:0] dev);
    integer i;
    for (i = 0; i < APU_DWI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DWI_CMD_DWI); poke(1, flags); poke64(2, dev);
  endtask

  task automatic load_gfs(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] obj);
    integer i;
    for (i = 0; i < APU_GFS_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_GFS_CMD_GFS); poke(1, flags); poke64(2, dev); poke64(4, obj);
  endtask

  task automatic load_wfe(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] obj);
    integer i;
    for (i = 0; i < APU_WFE_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_WFE_CMD_WFE); poke(1, flags); poke64(2, dev);
    poke(4, APU_WFE_COUNT); poke64(5, obj); poke(7, APU_WFE_WAITALL);
  endtask

  task automatic load_rfe(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] obj);
    integer i;
    for (i = 0; i < APU_RFE_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_RFE_CMD_RFE); poke(1, flags); poke64(2, dev);
    poke(4, APU_RFE_COUNT); poke64(5, obj);
  endtask

  task automatic load_dfe(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] obj);
    integer i;
    for (i = 0; i < APU_DFE_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_DFE_CMD_DFE); poke(1, flags); poke64(2, dev); poke64(4, obj);
  endtask


  task automatic load_isl(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] img);
    integer i;
    for (i = 0; i < APU_ISL_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_ISL_CMD_ISL); poke(1, flags); poke64(2, dev); poke64(4, img);
    poke(6, APU_VXV_ASPECT_COLOR); poke(7, 32'd0); poke(8, 32'd0); poke64(9, 64'd1);
  endtask

  task automatic load_rag(input logic [31:0] flags, input logic [63:0] dev,
                          input logic [63:0] rp);
    integer i;
    for (i = 0; i < APU_RAG_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_RAG_CMD_RAG); poke(1, flags); poke64(2, dev); poke64(4, rp);
    poke64(6, 64'd1);
  endtask








  task automatic load_gpipe(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [63:0] shader, input logic [63:0] layout,
                            input logic [63:0] rpass, input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VGP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VGP_CMD_GPIPE); poke(1, flags); poke64(2, dev); poke64(4, 64'd0);
    poke(6, 32'd1); poke64(7, 64'd1); poke(9, APU_VGP_STYPE); poke64(10, 64'd0);
    poke(12, APU_VGP_VERTEX); poke64(13, shader); poke64(15, layout);
    poke64(17, rpass); poke(19, 32'd0); poke64(20, 64'd0); poke64(22, guest);
  endtask

  task automatic load_update(input logic [31:0] flags, input logic [63:0] dev,
                             input logic [63:0] dset, input logic [63:0] bufh);
    integer i;
    for (i = 0; i < APU_VUD_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VUD_CMD_UPDATE);
    poke(1, flags);
    poke64(2, dev);
    poke(4, 32'd1);
    poke64(5, 64'd1);
    poke(7, APU_VUD_STYPE);
    poke64(8, dset);
    poke(10, APU_VDL_STORAGE);
    poke64(11, 64'd1);
    poke64(13, bufh);
    poke64(15, 64'd0);
    poke64(17, 64'd4096);
    poke(19, 32'd0);
  endtask

  task automatic load_bindpipe(input logic [31:0] flags, input logic [63:0] cbuf,
                               input logic [63:0] pipeh);
    integer i;
    for (i = 0; i < APU_VBP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VBP_CMD_BINDPIPE);
    poke(1, flags);
    poke64(2, cbuf);
    poke(4, APU_VBP_COMPUTE);
    poke64(5, pipeh);
  endtask

  task automatic load_binddesc(input logic [31:0] flags, input logic [63:0] cbuf,
                               input logic [63:0] lay, input logic [63:0] dset);
    integer i;
    for (i = 0; i < APU_VBD_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VBD_CMD_BINDDESC);
    poke(1, flags);
    poke64(2, cbuf);
    poke(4, APU_VBP_COMPUTE);
    poke64(5, lay);
    poke(7, 32'd0);
    poke(8, 32'd1);
    poke64(9, dset);
    poke(11, 32'd0);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] mem [0:127];
    logic [31:0] hc, hq, hd, hi, hp, hb, hm, hl, hk, hg, hs, ho, hj, hv, ha, hr, hy, hf, hu, t0, t1, t4;
    int unsigned n;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep bru off",
          !ApuOff.BruEn && !ApuP1Transport.BruEn && !ApuHarness.BruEn);
    cfg = ApuP1Transport;
    cfg.BruEn = 1'b1;
    check("bru does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.BruEn = 1'b1;
    check("bru does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);
    check("mesa ids", APU_VAC_CMD_ALLOC == 32'd88 &&
          APU_VBG_CMD_BEGIN == 32'd90 &&
          APU_VNENC_CMD_CREATE_SHADER_MODULE == 32'd59 &&
          APU_VND_CMD_DISPATCH == 32'd110 &&
          APU_VEN_CMD_END == 32'd91 &&
          APU_VQS_CMD_SUBMIT == 32'd18 &&
          APU_VGQ_CMD_QUEUE == 32'd17 &&
          APU_VCD_CMD_DEVICE == 32'd11 &&
          APU_VCI_CMD_INSTANCE == 32'd0 &&
          APU_VEP_CMD_ENUM == 32'd2 &&
          APU_VQF_CMD_QFAM == 32'd7 &&
          APU_VPF_CMD_FEAT == 32'd3 &&
          APU_VPP_CMD_PROPS == 32'd6 &&
          APU_VMP_CMD_MEM == 32'd8 &&
          APU_VAM_CMD_MEMORY == 32'd21 &&
          APU_VXB_CMD_BUFFER == 32'd50 &&
          APU_VBB_CMD_BIND == 32'd28 &&
          APU_VMM_CMD_MAP == 32'd23 &&
          APU_VUM_CMD_UNMAP == 32'd24 &&
          APU_VBM_CMD_BUFREQ == 32'd30 &&
          APU_VFM_CMD_FLUSH == 32'd25 &&
          APU_VIM_CMD_INVAL == 32'd26 &&
          APU_VMC_CMD_MEMC == 32'd27 &&
          APU_VDL_CMD_DSLAYOUT == 32'd72 &&
          APU_VPL_CMD_PLAYOUT == 32'd68 &&
          APU_VCP_CMD_CPIPE == 32'd66 &&
          APU_VDA_CMD_DESCSET == 32'd77 &&
          APU_VUD_CMD_UPDATE == 32'd79 &&
          APU_VBP_CMD_BINDPIPE == 32'd93 &&
          APU_VBD_CMD_BINDDESC == 32'd103 &&
          APU_VPO_CMD_POOL == 32'd74 &&
          APU_VXI_CMD_IMAGE == 32'd54 &&
          APU_VBI_CMD_BINDIMG == 32'd29 &&
          APU_VMI_CMD_IMGREQ == 32'd31 &&
          APU_VXV_CMD_VIEW == 32'd57 &&
          APU_VSM_CMD_SAMPLER == 32'd70 &&
          APU_VRP_CMD_RPASS == 32'd82 &&
          APU_VGP_CMD_GPIPE == 32'd65 &&
          APU_VFB_CMD_FBUF == 32'd80 &&
          APU_VRB_CMD_BEGINRP == 32'd133 &&
          APU_VDW_CMD_DRAW == 32'd106 &&
          APU_VRE_CMD_ENDRP == 32'd135 &&
          APU_VVB_CMD_BINDVTX == 32'd105 &&
          APU_VIB_CMD_BINDIDX == 32'd104 &&
          APU_VDI_CMD_DRAWIDX == 32'd107 &&
          APU_VVP_CMD_SETVP == 32'd94 &&
          APU_VSI_CMD_SETSC == 32'd95 &&
          APU_VPB_CMD_BARRIER == 32'd126 &&
          APU_VNS_CMD_NEXTSP == 32'd134);

    cases++;
    load_begin(32'd0, 64'hC1, 32'd0);
    fire(mk_op(APU_BRU_BEGIN));
    check("begin before alloc faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_queue(APU_VGQ_GENERATE_REPLY, 64'hD1);
    fire(mk_op(APU_BRU_QUEUE));
    check("get queue before device faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_device(APU_VCD_GENERATE_REPLY, 64'hA1);
    fire(mk_op(APU_BRU_DEVICE));
    check("create device before instance faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_enum(APU_VEP_GENERATE_REPLY, 64'hE1);
    fire(mk_op(APU_BRU_ENUM));
    check("enum before instance faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_buffer(APU_VXB_GENERATE_REPLY, 64'hD1, 64'hB3);
    fire(mk_op(APU_BRU_BUFFER));
    check("create buffer before device faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_bind(APU_VBB_GENERATE_REPLY, 64'hD1, 64'hB3, 64'hB1);
    fire(mk_op(APU_BRU_BIND));
    check("bind before buffer faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_map(APU_VMM_GENERATE_REPLY, 64'hD1, 64'hB1, 64'hC5);
    fire(mk_op(APU_BRU_MAP));
    check("map before memory faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_unmap(APU_VUM_GENERATE_REPLY, 64'hD1, 64'hB1);
    fire(mk_op(APU_BRU_UNMAP));
    check("unmap before map faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_bufreq(APU_VBM_GENERATE_REPLY, 64'hD1, 64'hB3);
    fire(mk_op(APU_BRU_BUFREQ));
    check("bufreq before buffer faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_flush(APU_VFM_GENERATE_REPLY, 64'hD1, 64'hB1);
    fire(mk_op(APU_BRU_FLUSH));
    check("flush before map faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_inval(APU_VIM_GENERATE_REPLY, 64'hD1, 64'hB1);
    fire(mk_op(APU_BRU_INVAL));
    check("inval before map faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_memc(APU_VMC_GENERATE_REPLY, 64'hD1, 64'hB1);
    fire(mk_op(APU_BRU_MEMC));
    check("memc before memory faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_dsl(APU_VDL_GENERATE_REPLY, 64'hD1, 64'hB4);
    fire(mk_op(APU_BRU_DSLAYOUT));
    check("dslayout before device faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_pl(APU_VPL_GENERATE_REPLY, 64'hD1, 64'hB4, 64'hB5);
    fire(mk_op(APU_BRU_PLAYOUT));
    check("playout before dslayout faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_cp(APU_VCP_GENERATE_REPLY, 64'hD1, 64'hB2, 64'hB5, 64'hB6);
    fire(mk_op(APU_BRU_CPIPE));
    check("cpipe before playout faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();

    cases++;
    do_reset;
    fill_alu(16'd128, mem, n);
    load_create(mem, n, 64'hB2);
    fire(mk_op(APU_BRU_CREATE));
    hu = rec.handle;
    check("create module", cpl.status == APU_BRU_OK && rec.valid && rec.create &&
          rec.loaded && rec.kind == APU_GNH_MODULE && rec.object_id == 32'hB2 &&
          !rec.dispatch && !rec.alloc && !rec.begin_cmd && !rec.begun && !irq);
    ack();
    load_instance(APU_VCI_GENERATE_REPLY, 64'hE1);
    fire(mk_op(APU_BRU_INSTANCE));
    hi = rec.handle;
    check("create instance", cpl.status == APU_BRU_OK && rec.valid &&
          rec.create_instance && rec.kind == APU_GNH_INSTANCE &&
          rec.object_id == 32'hE1 && rec.handle != 32'd0);
    peek(APU_VCI_BRU_REPLY, t0);
    peek(APU_VCI_BRU_REPLY + 4, t4);
    check("instance reply", t0 == 32'd0 && t4 == hi);
    ack();
    load_enum(APU_VEP_GENERATE_REPLY, 64'(hi));
    fire(mk_op(APU_BRU_ENUM));
    hp = rec.handle;
    check("enum phys", cpl.status == APU_BRU_OK && rec.valid && rec.enum_phys &&
          rec.kind == APU_GNH_PHYS && rec.object_id == hi &&
          rec.handle != 32'd0 && rec.handle != hi);
    peek(APU_VEP_BRU_REPLY, t0);
    peek(APU_VEP_BRU_REPLY + 4, t4);
    check("enum reply", t0 == 32'd2 && t4 == hp);
    ack();
    load_device(APU_VCD_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_DEVICE));
    check("create device before qfam faults", cpl.status == APU_BRU_FAULT &&
          !rec.valid);
    ack();
    load_feat(APU_VPF_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_FEAT));
    check("get feat", cpl.status == APU_BRU_OK && rec.valid && rec.get_feat &&
          rec.kind == APU_GNH_PHYS && rec.handle == hp &&
          rec.result == APU_VPF_FRAGMENT_STORES);
    peek(APU_VPF_BRU_REPLY, t0);
    peek(APU_VPF_BRU_REPLY + 2, t1);
    check("feat reply", t0 == 32'd3 && t1 == APU_VPF_FRAGMENT_STORES);
    ack();
    load_props(APU_VPP_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_PROPS));
    check("get props", cpl.status == APU_BRU_OK && rec.valid && rec.get_props &&
          rec.kind == APU_GNH_PHYS && rec.handle == hp &&
          rec.result == APU_VPP_MAX_BOUND_DESCRIPTOR_SETS);
    peek(APU_VPP_BRU_REPLY, t0);
    peek(APU_VPP_BRU_REPLY + 2, t1);
    peek(APU_VPP_BRU_REPLY + 4, t4);
    check("props reply", t0 == 32'd6 && t1 == APU_VPP_API_VERSION &&
          t4 == APU_VPP_MAX_BOUND_DESCRIPTOR_SETS);
    ack();
    load_mem(APU_VMP_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_MEM));
    check("get mem", cpl.status == APU_BRU_OK && rec.valid && rec.get_mem &&
          rec.kind == APU_GNH_PHYS && rec.handle == hp &&
          rec.result == APU_VMP_TYPE_COUNT);
    peek(APU_VMP_BRU_REPLY, t0);
    peek(APU_VMP_BRU_REPLY + 2, t1);
    peek(APU_VMP_BRU_REPLY + 3, t4);
    check("mem reply", t0 == 32'd8 && t1 == APU_VMP_TYPE_COUNT &&
          t4 == APU_VMP_DEVICE_LOCAL);
    ack();
    load_qfam(APU_VQF_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_QFAM));
    check("get qfam", cpl.status == APU_BRU_OK && rec.valid && rec.get_qfam &&
          rec.kind == APU_GNH_PHYS && rec.handle == hp &&
          rec.result == APU_VQF_FAMILY_COUNT);
    peek(APU_VQF_BRU_REPLY, t0);
    peek(APU_VQF_BRU_REPLY + 4, t4);
    check("qfam reply", t0 == 32'd7 && t4 == APU_VQF_QUEUE_FLAGS);
    ack();
    load_device(APU_VCD_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_DEVICE));
    hd = rec.handle;
    check("create device", cpl.status == APU_BRU_OK && rec.valid &&
          rec.create_device && rec.kind == APU_GNH_DEVICE &&
          rec.object_id == hp && rec.handle != 32'd0 && rec.handle != hp);
    peek(APU_VCD_REPLY, t0);
    peek(APU_VCD_REPLY + 4, t4);
    check("device reply", t0 == 32'd11 && t4 == hd);
    ack();
    load_queue(APU_VGQ_GENERATE_REPLY, 64'(hd));
    fire(mk_op(APU_BRU_QUEUE));
    hq = rec.handle;
    check("get queue", cpl.status == APU_BRU_OK && rec.valid && rec.get_queue &&
          rec.kind == APU_GNH_QUEUE && rec.object_id == hd &&
          rec.handle != 32'd0 && rec.handle != hd);
    peek(APU_VGQ_REPLY, t0);
    peek(APU_VGQ_REPLY + 1, t1);
    check("queue reply", t0 == 32'd17 && t1 == hq);
    ack();
    load_vkmem(APU_VAM_GENERATE_REPLY, 64'(hd), 32'd0, 64'hB1);
    fire(mk_op(APU_BRU_VKMEM));
    hm = rec.handle;
    check("alloc memory", cpl.status == APU_BRU_OK && rec.valid && rec.alloc_mem &&
          rec.kind == APU_GNH_MEMORY && rec.object_id == 32'hB1 &&
          rec.handle != 32'd0 && rec.handle != hd && rec.handle != hq);
    peek(APU_VAM_BRU_REPLY, t0);
    peek(APU_VAM_BRU_REPLY + 4, t4);
    check("memory reply", t0 == 32'd21 && t4 == hm);
    ack();
    load_buffer(APU_VXB_GENERATE_REPLY, 64'(hd), 64'hB3);
    fire(mk_op(APU_BRU_BUFFER));
    hb = rec.handle;
    check("create buffer", cpl.status == APU_BRU_OK && rec.valid && rec.create_buffer &&
          rec.kind == APU_GNH_BUFFER && rec.object_id == 32'hB3 &&
          rec.handle != 32'd0 && rec.handle != hd && rec.handle != hq &&
          rec.handle != hm);
    peek(APU_VXB_BRU_REPLY, t0);
    peek(APU_VXB_BRU_REPLY + 4, t4);
    check("buffer reply", t0 == 32'd50 && t4 == hb);
    ack();
    load_bufreq(APU_VBM_GENERATE_REPLY, 64'(hd), 64'(hb));
    fire(mk_op(APU_BRU_BUFREQ));
    check("buffer req", cpl.status == APU_BRU_OK && rec.valid && rec.buf_req &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb &&
          rec.result == APU_VBM_SIZE);
    peek(APU_VBM_BRU_REPLY, t0);
    peek(APU_VBM_BRU_REPLY + 2, t1);
    peek(APU_VBM_BRU_REPLY + 4, t4);
    check("bufreq reply", t0 == 32'd30 && t1 == APU_VBM_SIZE &&
          t4 == APU_VBM_ALIGN);
    ack();
    load_bind(APU_VBB_GENERATE_REPLY, 64'(hd), 64'(hb), 64'(hm));
    fire(mk_op(APU_BRU_BIND));
    check("bind buffer", cpl.status == APU_BRU_OK && rec.valid && rec.bind_buffer &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb &&
          rec.object_id == hm);
    peek(APU_VBB_BRU_REPLY, t0);
    peek(APU_VBB_BRU_REPLY + 1, t1);
    check("bind reply", t0 == 32'd28 && t1 == 32'd0);
    ack();
    load_map(APU_VMM_GENERATE_REPLY, 64'(hd), 64'(hm), 64'hC5);
    fire(mk_op(APU_BRU_MAP));
    check("map memory", cpl.status == APU_BRU_OK && rec.valid && rec.map_mem &&
          rec.kind == APU_GNH_MEMORY && rec.handle == hm &&
          rec.result == APU_SHM_BASE[31:0]);
    peek(APU_VMM_BRU_REPLY, t0);
    peek(APU_VMM_BRU_REPLY + 2, t1);
    check("map reply", t0 == 32'd23 && t1 == APU_SHM_BASE[31:0]);
    ack();
    load_flush(APU_VFM_GENERATE_REPLY, 64'(hd), 64'(hm));
    fire(mk_op(APU_BRU_FLUSH));
    check("flush map", cpl.status == APU_BRU_OK && rec.valid && rec.flush_mem &&
          rec.kind == APU_GNH_MEMORY && rec.handle == hm &&
          rec.result == 32'd0);
    peek(APU_VFM_BRU_REPLY, t0);
    peek(APU_VFM_BRU_REPLY + 1, t1);
    check("flush reply", t0 == 32'd25 && t1 == 32'd0);
    ack();
    load_inval(APU_VIM_GENERATE_REPLY, 64'(hd), 64'(hm));
    fire(mk_op(APU_BRU_INVAL));
    check("invalidate map", cpl.status == APU_BRU_OK && rec.valid && rec.inval_mem &&
          rec.kind == APU_GNH_MEMORY && rec.handle == hm &&
          rec.result == 32'd0);
    peek(APU_VIM_BRU_REPLY, t0);
    peek(APU_VIM_BRU_REPLY + 1, t1);
    check("inval reply", t0 == 32'd26 && t1 == 32'd0);
    ack();
    load_unmap(APU_VUM_GENERATE_REPLY, 64'(hd), 64'(hm));
    fire(mk_op(APU_BRU_UNMAP));
    check("unmap memory", cpl.status == APU_BRU_OK && rec.valid && rec.unmap_mem &&
          rec.kind == APU_GNH_MEMORY && rec.handle == hm &&
          rec.result == 32'd0);
    peek(APU_VUM_BRU_REPLY, t0);
    check("unmap reply", t0 == 32'd24);
    ack();
    load_memc(APU_VMC_GENERATE_REPLY, 64'(hd), 64'(hm));
    fire(mk_op(APU_BRU_MEMC));
    check("memory commit", cpl.status == APU_BRU_OK && rec.valid && rec.mem_commit &&
          rec.kind == APU_GNH_MEMORY && rec.handle == hm &&
          rec.result == APU_VMC_COMMITTED);
    peek(APU_VMC_BRU_REPLY, t0);
    peek(APU_VMC_BRU_REPLY + 2, t1);
    check("memc reply", t0 == 32'd27 && t1 == APU_VMC_COMMITTED);
    ack();
    load_image(APU_VXI_GENERATE_REPLY, 64'(hd), 64'hB9);
    fire(mk_op(APU_BRU_IMAGE));
    hj = rec.handle;
    check("create image", cpl.status == APU_BRU_OK && rec.valid && rec.create_image &&
          rec.kind == APU_GNH_IMAGE && rec.object_id == 32'hB9 &&
          rec.handle != 32'd0);
    peek(APU_VXI_BRU_REPLY, t0);
    peek(APU_VXI_BRU_REPLY + 4, t4);
    check("image reply", t0 == 32'd54 && t4 == hj);
    ack();
    load_imgreq(APU_VMI_GENERATE_REPLY, 64'(hd), 64'(hj));
    fire(mk_op(APU_BRU_IMGREQ));
    check("image req", cpl.status == APU_BRU_OK && rec.valid && rec.img_req &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj &&
          rec.result == APU_VMI_SIZE);
    peek(APU_VMI_BRU_REPLY, t0);
    peek(APU_VMI_BRU_REPLY + 2, t1);
    check("imgreq reply", t0 == 32'd31 && t1 == APU_VMI_SIZE);
    ack();
    load_bindimg(APU_VBI_GENERATE_REPLY, 64'(hd), 64'(hj), 64'(hm));
    fire(mk_op(APU_BRU_BINDIMG));
    check("bind image", cpl.status == APU_BRU_OK && rec.valid && rec.bind_image &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj);
    peek(APU_VBI_BRU_REPLY, t0);
    check("bindimg reply", t0 == 32'd29);
    ack();
    load_view(APU_VXV_GENERATE_REPLY, 64'(hd), 64'(hj), 64'hBA);
    fire(mk_op(APU_BRU_VIEW));
    hv = rec.handle;
    check("create view", cpl.status == APU_BRU_OK && rec.valid && rec.create_view &&
          rec.kind == APU_GNH_VIEW && rec.object_id == 32'hBA &&
          rec.handle != 32'd0);
    peek(APU_VXV_BRU_REPLY, t0);
    peek(APU_VXV_BRU_REPLY + 4, t4);
    check("view reply", t0 == 32'd57 && t4 == hv);
    ack();
    load_dsl(APU_VDL_GENERATE_REPLY, 64'(hd), 64'hB4);
    fire(mk_op(APU_BRU_DSLAYOUT));
    hl = rec.handle;
    check("desc layout", cpl.status == APU_BRU_OK && rec.valid && rec.create_dslayout &&
          rec.kind == APU_GNH_DSLAYOUT && rec.object_id == 32'hB4 &&
          rec.handle != 32'd0);
    peek(APU_VDL_BRU_REPLY, t0);
    peek(APU_VDL_BRU_REPLY + 4, t4);
    check("dsl reply", t0 == 32'd72 && t4 == hl);
    ack();
    load_pool(APU_VPO_GENERATE_REPLY, 64'(hd), 64'hB7);
    fire(mk_op(APU_BRU_POOL));
    ho = rec.handle;
    check("desc pool", cpl.status == APU_BRU_OK && rec.valid && rec.create_pool &&
          rec.kind == APU_GNH_POOL && rec.object_id == 32'hB7 &&
          rec.handle != 32'd0);
    peek(APU_VPO_BRU_REPLY, t0);
    peek(APU_VPO_BRU_REPLY + 4, t4);
    check("pool reply", t0 == 32'd74 && t4 == ho);
    ack();
    load_sampler(APU_VSM_GENERATE_REPLY, 64'(hd), 64'hBB);
    fire(mk_op(APU_BRU_SAMPLER));
    ha = rec.handle;
    check("create sampler", cpl.status == APU_BRU_OK && rec.valid && rec.create_sampler &&
          rec.kind == APU_GNH_SAMPLER && rec.object_id == 32'hBB &&
          rec.handle != 32'd0);
    peek(APU_VSM_BRU_REPLY, t0);
    peek(APU_VSM_BRU_REPLY + 4, t4);
    check("sampler reply", t0 == 32'd70 && t4 == ha);
    ack();
    load_pl(APU_VPL_GENERATE_REPLY, 64'(hd), 64'(hl), 64'hB5);
    fire(mk_op(APU_BRU_PLAYOUT));
    hk = rec.handle;
    check("pipe layout", cpl.status == APU_BRU_OK && rec.valid && rec.create_playout &&
          rec.kind == APU_GNH_PLAYOUT && rec.object_id == 32'hB5 &&
          rec.handle != 32'd0 && rec.handle != hl);
    peek(APU_VPL_BRU_REPLY, t0);
    peek(APU_VPL_BRU_REPLY + 4, t4);
    check("pl reply", t0 == 32'd68 && t4 == hk);
    ack();
    load_rpass(APU_VRP_GENERATE_REPLY, 64'(hd), 64'hBC);
    fire(mk_op(APU_BRU_RPASS));
    hr = rec.handle;
    check("create rpass", cpl.status == APU_BRU_OK && rec.valid && rec.create_rpass &&
          rec.kind == APU_GNH_RPASS && rec.object_id == 32'hBC &&
          rec.handle != 32'd0);
    peek(APU_VRP_BRU_REPLY, t0);
    peek(APU_VRP_BRU_REPLY + 4, t4);
    check("rpass reply", t0 == 32'd82 && t4 == hr);
    ack();
    load_cp(APU_VCP_GENERATE_REPLY, 64'(hd), 64'hB2, 64'(hk), 64'hB6);
    fire(mk_op(APU_BRU_CPIPE));
    hg = rec.handle;
    check("compute pipe", cpl.status == APU_BRU_OK && rec.valid && rec.create_cpipe &&
          rec.kind == APU_GNH_PIPELINE && rec.object_id == 32'hB6 &&
          rec.handle != 32'd0 && rec.handle != hl && rec.handle != hk);
    peek(APU_VCP_BRU_REPLY, t0);
    peek(APU_VCP_BRU_REPLY + 4, t4);
    check("cp reply", t0 == 32'd66 && t4 == hg);
    ack();
    load_gpipe(APU_VGP_GENERATE_REPLY, 64'(hd), 64'hB2, 64'(hk), 64'(hr), 64'hBD);
    fire(mk_op(APU_BRU_GPIPE));
    hy = rec.handle;
    check("create gpipe", cpl.status == APU_BRU_OK && rec.valid && rec.create_gpipe &&
          rec.kind == APU_GNH_PIPELINE && rec.object_id == 32'hBD &&
          rec.handle != 32'd0 && rec.handle != hg);
    peek(APU_VGP_BRU_REPLY, t0);
    peek(APU_VGP_BRU_REPLY + 4, t4);
    check("gpipe reply", t0 == 32'd65 && t4 == hy);
    ack();
    load_fbuf(APU_VFB_GENERATE_REPLY, 64'(hd), 64'(hr), 64'(hv), 64'hBE);
    fire(mk_op(APU_BRU_FBUF));
    hf = rec.handle;
    check("create fbuf", cpl.status == APU_BRU_OK && rec.valid && rec.create_fbuf &&
          rec.kind == APU_GNH_FBUF && rec.object_id == 32'hBE &&
          rec.handle != 32'd0);
    peek(APU_VFB_BRU_REPLY, t0);
    peek(APU_VFB_BRU_REPLY + 4, t4);
    check("fbuf reply", t0 == 32'd80 && t4 == hf);
    ack();
    load_dset(APU_VDA_GENERATE_REPLY, 64'(hd), 64'(hl), 64'(ho), 64'hB8);
    fire(mk_op(APU_BRU_DESCSET));
    hs = rec.handle;
    check("descset", cpl.status == APU_BRU_OK && rec.valid && rec.alloc_descset &&
          rec.kind == APU_GNH_DESCSET && rec.object_id == 32'hB8 &&
          rec.handle != 32'd0 && rec.handle != hl);
    peek(APU_VDA_BRU_REPLY, t0);
    peek(APU_VDA_BRU_REPLY + 4, t4);
    check("dset reply", t0 == 32'd77 && t4 == hs);
    ack();
    load_update(APU_VUD_GENERATE_REPLY, 64'(hd), 64'(hs), 64'(hb));
    fire(mk_op(APU_BRU_UPDATE));
    check("update desc", cpl.status == APU_BRU_OK && rec.valid && rec.update_desc &&
          rec.kind == APU_GNH_DESCSET && rec.handle == hs);
    peek(APU_VUD_BRU_REPLY, t0);
    check("upd reply", t0 == 32'd79);
    ack();
    load_unmap(APU_VUM_GENERATE_REPLY, 64'(hd), 64'(hm));
    fire(mk_op(APU_BRU_UNMAP));
    check("second unmap faults", cpl.status == APU_BRU_FAULT && !rec.valid);
    ack();
    load_alloc(32'd0, 64'hC1);
    fire(mk_op(APU_BRU_ALLOC));
    hc = rec.handle;
    check("alloc cmdbuf", cpl.status == APU_BRU_OK && rec.valid && rec.alloc &&
          rec.kind == APU_GNH_CMDBUF && rec.object_id == 32'hC1 &&
          rec.handle != 32'hC1 && rec.loaded && !rec.begun);
    ack();
    load_dispatch(64'(hc));
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_op(APU_BRU_DISPATCH));
    check("dispatch before begin faults", cpl.status == APU_BRU_FAULT && !irq);
    ack();
    load_begin(32'd0, 64'(hc), 32'd1);
    fire(mk_op(APU_BRU_BEGIN));
    check("begin lookup", cpl.status == APU_BRU_OK && rec.valid &&
          rec.begin_cmd && rec.begun && rec.handle == hc &&
          rec.kind == APU_GNH_CMDBUF && rec.begin_flags == 32'd1);
    ack();
    load_dispatch(64'(hc));
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_op(APU_BRU_DISPATCH));
    check("dispatch before bind faults", cpl.status == APU_BRU_FAULT && !irq);
    ack();
    load_bindpipe(APU_VBP_GENERATE_REPLY, 64'(hc), 64'(hg));
    fire(mk_op(APU_BRU_BINDPIPE));
    check("bind pipe", cpl.status == APU_BRU_OK && rec.valid && rec.bind_pipe &&
          rec.kind == APU_GNH_PIPELINE && rec.handle == hg);
    peek(APU_VBP_BRU_REPLY, t0);
    check("bp reply", t0 == 32'd93);
    ack();
    load_binddesc(APU_VBD_GENERATE_REPLY, 64'(hc), 64'(hk), 64'(hs));
    fire(mk_op(APU_BRU_BINDDESC));
    check("bind desc", cpl.status == APU_BRU_OK && rec.valid && rec.bind_desc &&
          rec.kind == APU_GNH_DESCSET && rec.handle == hs);
    peek(APU_VBD_BRU_REPLY, t0);
    check("bd reply", t0 == 32'd103);
    ack();
    load_bindvtx(APU_VVB_GENERATE_REPLY, 64'(hc), 64'(hb));
    fire(mk_op(APU_BRU_BINDVTX));
    check("bind vtx", cpl.status == APU_BRU_OK && rec.valid && rec.bind_vtx &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb);
    peek(APU_VVB_BRU_REPLY, t0);
    check("vvb reply", t0 == 32'd105);
    ack();
    load_bindidx(APU_VIB_GENERATE_REPLY, 64'(hc), 64'(hb));
    fire(mk_op(APU_BRU_BINDIDX));
    check("bind idx", cpl.status == APU_BRU_OK && rec.valid && rec.bind_idx &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb);
    peek(APU_VIB_BRU_REPLY, t0);
    check("vib reply", t0 == 32'd104);
    ack();
    load_setvp(APU_VVP_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SETVP));
    check("set vp", cpl.status == APU_BRU_OK && rec.valid && rec.set_vp &&
          rec.kind == APU_GNH_CMDBUF && rec.handle == hc);
    peek(APU_VVP_BRU_REPLY, t0);
    check("vvp reply", t0 == 32'd94);
    ack();
    load_setsc(APU_VSI_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SETSC));
    check("set sc", cpl.status == APU_BRU_OK && rec.valid && rec.set_sc &&
          rec.handle == hc);
    peek(APU_VSI_BRU_REPLY, t0);
    check("vsi reply", t0 == 32'd95);
    ack();
    load_barrier(APU_VPB_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_BARRIER));
    check("barrier", cpl.status == APU_BRU_OK && rec.valid && rec.barrier &&
          rec.handle == hc);
    peek(APU_VPB_BRU_REPLY, t0);
    check("vpb reply", t0 == 32'd126);
    ack();
    load_slw(APU_SLW_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SLW));
    check("set lw", cpl.status == APU_BRU_OK && rec.valid && rec.set_lw &&
          rec.kind == APU_GNH_CMDBUF && rec.handle == hc);
    peek(APU_SLW_BRU_REPLY, t0);
    check("vlw reply", t0 == 32'd96);
    ack();
    load_sdb(APU_SDB_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SDB));
    check("set bias", cpl.status == APU_BRU_OK && rec.valid && rec.set_bias &&
          rec.handle == hc);
    peek(APU_SDB_BRU_REPLY, t0);
    check("vzb reply", t0 == 32'd97);
    ack();
    load_sbc(APU_SBC_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SBC));
    check("set blend", cpl.status == APU_BRU_OK && rec.valid && rec.set_blend &&
          rec.handle == hc);
    peek(APU_SBC_BRU_REPLY, t0);
    check("vbc reply", t0 == 32'd98);
    ack();
    load_sbb(APU_SBB_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SBB));
    check("set bounds", cpl.status == APU_BRU_OK && rec.valid && rec.set_bounds &&
          rec.handle == hc);
    peek(APU_SBB_BRU_REPLY, t0);
    check("vbo reply", t0 == 32'd99);
    ack();
    load_scm(APU_SCM_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SCM));
    check("set scmp", cpl.status == APU_BRU_OK && rec.valid && rec.set_scmp &&
          rec.kind == APU_GNH_CMDBUF && rec.handle == hc);
    peek(APU_SCM_BRU_REPLY, t0);
    check("vcm reply", t0 == 32'd100);
    ack();
    load_swm(APU_SWM_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SWM));
    check("set swm", cpl.status == APU_BRU_OK && rec.valid && rec.set_swm &&
          rec.handle == hc);
    peek(APU_SWM_BRU_REPLY, t0);
    check("vwm reply", t0 == 32'd101);
    ack();
    load_srf(APU_SRF_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_SRF));
    check("set sref", cpl.status == APU_BRU_OK && rec.valid && rec.set_sref &&
          rec.handle == hc);
    peek(APU_SRF_BRU_REPLY, t0);
    check("vrf reply", t0 == 32'd102);
    ack();
    load_ccb(APU_CCB_GENERATE_REPLY, 64'(hc), 64'(hb), 64'(hb));
    fire(mk_op(APU_BRU_CCB));
    check("copy buf", cpl.status == APU_BRU_OK && rec.valid && rec.copy_buf &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb);
    peek(APU_CCB_BRU_REPLY, t0);
    check("vcc reply", t0 == 32'd112);
    ack();
    load_cci(APU_CCI_GENERATE_REPLY, 64'(hc), 64'(hj), 64'(hj));
    fire(mk_op(APU_BRU_CCI));
    check("copy img", cpl.status == APU_BRU_OK && rec.valid && rec.copy_img &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj);
    peek(APU_CCI_BRU_REPLY, t0);
    check("vcy reply", t0 == 32'd113);
    ack();
    load_bli(APU_BLI_GENERATE_REPLY, 64'(hc), 64'(hj), 64'(hj));
    fire(mk_op(APU_BRU_BLI));
    check("blit img", cpl.status == APU_BRU_OK && rec.valid && rec.blit_img &&
          rec.handle == hj);
    peek(APU_BLI_BRU_REPLY, t0);
    check("vbl reply", t0 == 32'd114);
    ack();
    load_cbi(APU_CBI_GENERATE_REPLY, 64'(hc), 64'(hb), 64'(hj));
    fire(mk_op(APU_BRU_CBI));
    check("copy b2i", cpl.status == APU_BRU_OK && rec.valid && rec.copy_b2i &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj);
    peek(APU_CBI_BRU_REPLY, t0);
    check("vbt reply", t0 == 32'd115);
    ack();
    load_cib(APU_CIB_GENERATE_REPLY, 64'(hc), 64'(hj), 64'(hb));
    fire(mk_op(APU_BRU_CIB));
    check("copy i2b", cpl.status == APU_BRU_OK && rec.valid && rec.copy_i2b &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb);
    peek(APU_CIB_BRU_REPLY, t0);
    check("vic reply", t0 == 32'd116);
    ack();
    load_ubf(APU_UBF_GENERATE_REPLY, 64'(hc), 64'(hb));
    fire(mk_op(APU_BRU_UBF));
    check("update buf", cpl.status == APU_BRU_OK && rec.valid && rec.update_buf &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb);
    peek(APU_UBF_BRU_REPLY, t0);
    check("vub reply", t0 == 32'd117);
    ack();
    load_fil(APU_FIL_GENERATE_REPLY, 64'(hc), 64'(hb));
    fire(mk_op(APU_BRU_FIL));
    check("fill buf", cpl.status == APU_BRU_OK && rec.valid && rec.fill_buf &&
          rec.handle == hb);
    peek(APU_FIL_BRU_REPLY, t0);
    check("vfl reply", t0 == 32'd118);
    ack();
    load_ccl(APU_CCL_GENERATE_REPLY, 64'(hc), 64'(hj));
    fire(mk_op(APU_BRU_CCL));
    check("clear col", cpl.status == APU_BRU_OK && rec.valid && rec.clear_col &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj);
    peek(APU_CCL_BRU_REPLY, t0);
    check("vcl reply", t0 == 32'd119);
    ack();
    load_cds(APU_CDS_GENERATE_REPLY, 64'(hc), 64'(hj));
    fire(mk_op(APU_BRU_CDS));
    check("clear ds", cpl.status == APU_BRU_OK && rec.valid && rec.clear_ds &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj);
    peek(APU_CDS_BRU_REPLY, t0);
    check("vds reply", t0 == 32'd120);
    ack();
    load_rsi(APU_RSI_GENERATE_REPLY, 64'(hc), 64'(hj), 64'(hj));
    fire(mk_op(APU_BRU_RSI));
    check("resolve img", cpl.status == APU_BRU_OK && rec.valid && rec.resolve_img &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj);
    peek(APU_RSI_BRU_REPLY, t0);
    check("vrs reply", t0 == 32'd122);
    ack();
    load_beginrp(APU_VRB_GENERATE_REPLY, 64'(hc), 64'(hr), 64'(hf));
    fire(mk_op(APU_BRU_BEGINRP));
    check("begin rp", cpl.status == APU_BRU_OK && rec.valid && rec.begin_rp &&
          rec.kind == APU_GNH_CMDBUF && rec.handle == hc);
    peek(APU_VRB_BRU_REPLY, t0);
    check("beginrp reply", t0 == 32'd133);
    ack();
    load_nextsp(APU_VNS_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_NEXTSP));
    check("next subpass one-pass faults", cpl.status == APU_BRU_FAULT);
    ack();
    load_draw(APU_VDW_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_DRAW));
    check("draw", cpl.status == APU_BRU_OK && rec.valid && rec.draw_cmd &&
          rec.handle == hc && rec.result == APU_VDW_VERTS);
    peek(APU_VDW_BRU_REPLY, t0);
    peek(APU_VDW_BRU_REPLY + 2, t1);
    check("draw reply", t0 == 32'd106 && t1 == APU_VDW_VERTS);
    ack();
    load_drawidx(APU_VDI_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_DRAWIDX));
    check("draw idx", cpl.status == APU_BRU_OK && rec.valid && rec.draw_idx &&
          rec.handle == hc && rec.result == APU_VDI_INDICES);
    peek(APU_VDI_BRU_REPLY, t0);
    peek(APU_VDI_BRU_REPLY + 2, t1);
    check("drawidx reply", t0 == 32'd107 && t1 == APU_VDI_INDICES);
    ack();
    load_dri(APU_DRI_GENERATE_REPLY, 64'(hc), 64'(hb));
    fire(mk_op(APU_BRU_DRI));
    check("draw indr", cpl.status == APU_BRU_OK && rec.valid && rec.draw_indr &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb &&
          rec.result == APU_DRI_COUNT);
    peek(APU_DRI_BRU_REPLY, t0);
    check("vio reply", t0 == 32'd108);
    ack();
    load_ixi(APU_IXI_GENERATE_REPLY, 64'(hc), 64'(hb));
    fire(mk_op(APU_BRU_DXI));
    check("draw iindr", cpl.status == APU_BRU_OK && rec.valid && rec.draw_iindr &&
          rec.handle == hb && rec.result == APU_IXI_COUNT);
    peek(APU_IXI_BRU_REPLY, t0);
    check("vix reply", t0 == 32'd109);
    ack();
    load_cat(APU_CAT_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_CAT));
    check("clear att", cpl.status == APU_BRU_OK && rec.valid && rec.clear_att &&
          rec.kind == APU_GNH_CMDBUF && rec.handle == hc);
    peek(APU_CAT_BRU_REPLY, t0);
    check("vat reply", t0 == 32'd121);
    ack();
    load_endrp(APU_VRE_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_ENDRP));
    check("end rp", cpl.status == APU_BRU_OK && rec.valid && rec.end_rp &&
          rec.handle == hc);
    peek(APU_VRE_BRU_REPLY, t0);
    check("endrp reply", t0 == 32'd135);
    ack();
    load_dispatch(64'(hc));
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_op(APU_BRU_DISPATCH));
    check("dispatch add", cpl.status == APU_BRU_OK && rec.valid && rec.dispatch &&
          irq && result == 32'd5 && rec.result == 32'd5 && rec.loaded &&
          rec.begun);
    ack();
    load_dsi(APU_DSI_GENERATE_REPLY, 64'(hc), 64'(hb));
    fire(mk_op(APU_BRU_DSI));
    check("disp indr", cpl.status == APU_BRU_OK && rec.valid && rec.disp_indr &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb);
    peek(APU_DSI_BRU_REPLY, t0);
    check("vin reply", t0 == 32'd111);
    ack();

    cases++;
    load_dispatch(64'(hc));
    in_a = 32'd4;
    in_b = 32'd5;
    fire(mk_op(APU_BRU_DISPATCH));
    check("second dispatch", cpl.status == APU_BRU_OK && rec.valid && irq &&
          result == 32'd9 && rec.begun);
    ack();
    load_end(APU_VEN_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_END));
    check("end lookup", cpl.status == APU_BRU_OK && rec.valid && rec.end_cmd &&
          !rec.begin_cmd && !rec.dispatch && rec.handle == hc && !rec.begun);
    peek(APU_VEN_REPLY, t0);
    peek(APU_VEN_REPLY + 1, t1);
    check("end reply words", t0 == 32'd91 && t1 == 32'd0);
    ack();
    load_submit(APU_VQS_GENERATE_REPLY, 64'(hq), 64'(hc));
    fire(mk_op(APU_BRU_SUBMIT));
    check("submit lookup", cpl.status == APU_BRU_OK && rec.valid && rec.submit &&
          !rec.end_cmd && rec.handle == hc && !rec.begun);
    peek(APU_VQS_REPLY, t0);
    peek(APU_VQS_REPLY + 1, t1);
    check("submit reply words", t0 == 32'd18 && t1 == 32'd0);
    ack();
    load_wait(32'd0, 64'(hq));
    fire(mk_op(APU_BRU_WAIT));
    check("wait idle", cpl.status == APU_BRU_OK && rec.valid && rec.wait_idle &&
          !rec.submit);
    ack();
    load_iex(APU_IEX_GENERATE_REPLY);
    fire(mk_op(APU_BRU_IEX));
    check("instance ext", cpl.status == APU_BRU_OK && rec.valid && rec.get_iext &&
          rec.result == APU_IEX_COUNT);
    peek(APU_IEX_BRU_REPLY, t0);
    check("vie reply", t0 == 32'd13);
    ack();
    load_dwi(APU_DWI_GENERATE_REPLY, 64'(hd));
    fire(mk_op(APU_BRU_DWI));
    check("device wait", cpl.status == APU_BRU_OK && rec.valid && rec.wait_dev &&
          rec.kind == APU_GNH_DEVICE && rec.handle == hd);
    peek(APU_DWI_BRU_REPLY, t0);
    check("vwl reply", t0 == 32'd20);
    ack();
    load_gfs(APU_GFS_GENERATE_REPLY, 64'(hd), 64'hF1);
    fire(mk_op(APU_BRU_GFS));
    check("get fence", cpl.status == APU_BRU_OK && rec.valid && rec.get_fence &&
          rec.kind == APU_GNH_DEVICE && rec.handle == hd);
    peek(APU_GFS_BRU_REPLY, t0);
    check("vgs reply", t0 == 32'd38);
    ack();
    load_wfe(APU_WFE_GENERATE_REPLY, 64'(hd), 64'hF1);
    fire(mk_op(APU_BRU_WFE));
    check("wait fence", cpl.status == APU_BRU_OK && rec.valid && rec.wait_fence &&
          rec.handle == hd);
    peek(APU_WFE_BRU_REPLY, t0);
    check("vwf reply", t0 == 32'd39);
    ack();
    load_rfe(APU_RFE_GENERATE_REPLY, 64'(hd), 64'hF1);
    fire(mk_op(APU_BRU_RFE));
    check("reset fence", cpl.status == APU_BRU_OK && rec.valid && rec.reset_fence &&
          rec.handle == hd);
    peek(APU_RFE_BRU_REPLY, t0);
    check("vfr reply", t0 == 32'd37);
    ack();
    load_dfe(APU_DFE_GENERATE_REPLY, 64'(hd), 64'hF1);
    fire(mk_op(APU_BRU_DFE));
    check("dest fence", cpl.status == APU_BRU_OK && rec.valid && rec.dest_fence &&
          rec.handle == hd);
    peek(APU_DFE_BRU_REPLY, t0);
    check("vfn reply", t0 == 32'd36);
    ack();
    load_isl(APU_ISL_GENERATE_REPLY, 64'(hd), 64'(hj));
    fire(mk_op(APU_BRU_ISL));
    check("subresource layout", cpl.status == APU_BRU_OK && rec.valid && rec.get_isl &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj &&
          rec.result == APU_VMI_SIZE);
    peek(APU_ISL_BRU_REPLY, t0);
    check("vsl reply", t0 == 32'd56);
    ack();
    load_rag(APU_RAG_GENERATE_REPLY, 64'(hd), 64'(hr));
    fire(mk_op(APU_BRU_RAG));
    check("render gran", cpl.status == APU_BRU_OK && rec.valid && rec.get_rag &&
          rec.kind == APU_GNH_RPASS && rec.handle == hr &&
          rec.result == APU_RAG_GRAN);
    peek(APU_RAG_BRU_REPLY, t0);
    check("vrg reply", t0 == 32'd84);
    ack();
    load_dfb(APU_DFB_GENERATE_REPLY, 64'(hd), 64'(hf));
    fire(mk_op(APU_BRU_DFB));
    check("destroy fbuf", cpl.status == APU_BRU_OK && rec.valid && rec.dest_fbuf &&
          rec.kind == APU_GNH_FBUF && rec.handle == hf);
    peek(APU_DFB_BRU_REPLY, t0);
    check("vdf reply", t0 == 32'd81);
    ack();
    load_dvw(APU_DVW_GENERATE_REPLY, 64'(hd), 64'(hv));
    fire(mk_op(APU_BRU_DVW));
    check("destroy view", cpl.status == APU_BRU_OK && rec.valid && rec.dest_view &&
          rec.kind == APU_GNH_VIEW && rec.handle == hv);
    peek(APU_DVW_BRU_REPLY, t0);
    check("vdx reply", t0 == 32'd58);
    ack();
    load_dsm(APU_DSM_GENERATE_REPLY, 64'(hd), 64'(ha));
    fire(mk_op(APU_BRU_DSM));
    check("destroy sampler", cpl.status == APU_BRU_OK && rec.valid && rec.dest_samp &&
          rec.kind == APU_GNH_SAMPLER && rec.handle == ha);
    peek(APU_DSM_BRU_REPLY, t0);
    check("vdk reply", t0 == 32'd71);
    ack();
    load_drp(APU_DRP_GENERATE_REPLY, 64'(hd), 64'(hr));
    fire(mk_op(APU_BRU_DRP));
    check("destroy rpass", cpl.status == APU_BRU_OK && rec.valid && rec.dest_rpass &&
          rec.kind == APU_GNH_RPASS && rec.handle == hr);
    peek(APU_DRP_BRU_REPLY, t0);
    check("vdr reply", t0 == 32'd83);
    ack();
    load_dbf(APU_DBF_GENERATE_REPLY, 64'(hd), 64'(hb));
    fire(mk_op(APU_BRU_DBF));
    check("destroy buf", cpl.status == APU_BRU_OK && rec.valid && rec.dest_buf &&
          rec.kind == APU_GNH_BUFFER && rec.handle == hb);
    peek(APU_DBF_BRU_REPLY, t0);
    check("vdb reply", t0 == 32'd51);
    ack();
    load_dim(APU_DIM_GENERATE_REPLY, 64'(hd), 64'(hj));
    fire(mk_op(APU_BRU_DIM));
    check("destroy img", cpl.status == APU_BRU_OK && rec.valid && rec.dest_img &&
          rec.kind == APU_GNH_IMAGE && rec.handle == hj);
    peek(APU_DIM_BRU_REPLY, t0);
    check("vdg reply", t0 == 32'd55);
    ack();
    load_fme(APU_FME_GENERATE_REPLY, 64'(hd), 64'(hm));
    fire(mk_op(APU_BRU_FME));
    check("free memory", cpl.status == APU_BRU_OK && rec.valid && rec.free_mem &&
          rec.kind == APU_GNH_MEMORY && rec.handle == hm);
    peek(APU_FME_BRU_REPLY, t0);
    check("vfe reply", t0 == 32'd22);
    ack();
    load_dmd(APU_DMD_GENERATE_REPLY, 64'(hd), 64'(hu));
    fire(mk_op(APU_BRU_DMD));
    check("destroy module", cpl.status == APU_BRU_OK && rec.valid && rec.dest_mod &&
          rec.kind == APU_GNH_MODULE && rec.handle == hu);
    peek(APU_DMD_BRU_REPLY, t0);
    check("vdm reply", t0 == 32'd60);
    ack();
    load_dpl(APU_DPL_GENERATE_REPLY, 64'(hd), 64'(hy));
    fire(mk_op(APU_BRU_DPL));
    check("destroy gpipe", cpl.status == APU_BRU_OK && rec.valid && rec.dest_pipe &&
          rec.kind == APU_GNH_PIPELINE && rec.handle == hy);
    peek(APU_DPL_BRU_REPLY, t0);
    check("vdp gpipe reply", t0 == 32'd67);
    ack();
    load_dpl(APU_DPL_GENERATE_REPLY, 64'(hd), 64'(hg));
    fire(mk_op(APU_BRU_DPL));
    check("destroy cpipe", cpl.status == APU_BRU_OK && rec.valid && rec.dest_pipe &&
          rec.kind == APU_GNH_PIPELINE && rec.handle == hg);
    peek(APU_DPL_BRU_REPLY, t0);
    check("vdp cpipe reply", t0 == 32'd67);
    ack();
    load_dyo(APU_DYO_GENERATE_REPLY, 64'(hd), 64'(hk));
    fire(mk_op(APU_BRU_DYO));
    check("destroy playout", cpl.status == APU_BRU_OK && rec.valid && rec.dest_play &&
          rec.kind == APU_GNH_PLAYOUT && rec.handle == hk);
    peek(APU_DYO_BRU_REPLY, t0);
    check("vdy reply", t0 == 32'd69);
    ack();
    load_dds(APU_DDS_GENERATE_REPLY, 64'(hd), 64'(hl));
    fire(mk_op(APU_BRU_DDS));
    check("destroy dsl", cpl.status == APU_BRU_OK && rec.valid && rec.dest_dsl &&
          rec.kind == APU_GNH_DSLAYOUT && rec.handle == hl);
    peek(APU_DDS_BRU_REPLY, t0);
    check("vdt reply", t0 == 32'd73);
    ack();
    load_rdp(APU_RDP_GENERATE_REPLY, 64'(hd), 64'(ho));
    fire(mk_op(APU_BRU_RDP));
    check("reset desc pool", cpl.status == APU_BRU_OK && rec.valid && rec.reset_dpool &&
          rec.kind == APU_GNH_POOL && rec.handle == ho);
    peek(APU_RDP_BRU_REPLY, t0);
    check("vrd reply", t0 == 32'd76);
    ack();
    load_dpo(APU_DPO_GENERATE_REPLY, 64'(hd), 64'(ho));
    fire(mk_op(APU_BRU_DPO));
    check("destroy pool", cpl.status == APU_BRU_OK && rec.valid && rec.dest_pool &&
          rec.kind == APU_GNH_POOL && rec.handle == ho);
    peek(APU_DPO_BRU_REPLY, t0);
    check("vdq reply", t0 == 32'd75);
    ack();
    load_fds(APU_FDS_GENERATE_REPLY, 64'(hd), 64'(ho), 64'(hs));
    fire(mk_op(APU_BRU_FDS));
    check("free descset", cpl.status == APU_BRU_OK && rec.valid && rec.free_dset &&
          rec.kind == APU_GNH_DESCSET && rec.handle == hs);
    peek(APU_FDS_BRU_REPLY, t0);
    check("vfs reply", t0 == 32'd78);
    ack();
    load_rcb(APU_RCB_GENERATE_REPLY, 64'(hc));
    fire(mk_op(APU_BRU_RCB));
    check("reset cmdbuf", cpl.status == APU_BRU_OK && rec.valid && rec.reset_cbuf &&
          rec.kind == APU_GNH_CMDBUF && rec.handle == hc);
    peek(APU_RCB_BRU_REPLY, t0);
    check("vrc reply", t0 == 32'd92);
    ack();
    load_fcb(APU_FCB_GENERATE_REPLY, 64'(hd), 64'hA1, 64'(hc));
    fire(mk_op(APU_BRU_FCB));
    check("free cmdbuf", cpl.status == APU_BRU_OK && rec.valid && rec.free_cbuf &&
          rec.kind == APU_GNH_CMDBUF && rec.handle == hc);
    peek(APU_FCB_BRU_REPLY, t0);
    check("vfc reply", t0 == 32'd89);
    ack();
    load_rcp(APU_RCP_GENERATE_REPLY, 64'(hd), 64'hA1);
    fire(mk_op(APU_BRU_RCP));
    check("reset cmd pool", cpl.status == APU_BRU_OK && rec.valid && rec.reset_cpool &&
          rec.kind == APU_GNH_DEVICE && rec.handle == hd);
    peek(APU_RCP_BRU_REPLY, t0);
    check("vpc reply", t0 == 32'd87);
    ack();
    load_dcp(APU_DCP_GENERATE_REPLY, 64'(hd), 64'hA1);
    fire(mk_op(APU_BRU_DCP));
    check("destroy cmd pool", cpl.status == APU_BRU_OK && rec.valid && rec.dest_cpool &&
          rec.kind == APU_GNH_DEVICE && rec.handle == hd);
    peek(APU_DCP_BRU_REPLY, t0);
    check("vdc reply", t0 == 32'd86);
    ack();
    load_ddv(APU_DDV_GENERATE_REPLY, 64'(hd));
    fire(mk_op(APU_BRU_DDV));
    check("destroy device", cpl.status == APU_BRU_OK && rec.valid && rec.dest_dev &&
          rec.kind == APU_GNH_DEVICE && rec.handle == hd);
    peek(APU_DDV_BRU_REPLY, t0);
    check("vdd reply", t0 == 32'd12);
    ack();
    load_din(APU_DIN_GENERATE_REPLY, 64'(hi));
    fire(mk_op(APU_BRU_DIN));
    check("destroy instance", cpl.status == APU_BRU_OK && rec.valid && rec.dest_inst &&
          rec.kind == APU_GNH_INSTANCE && rec.handle == hi);
    peek(APU_DIN_BRU_REPLY, t0);
    check("vdn reply", t0 == 32'd1);
    ack();
    load_gfp(APU_GFP_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_GFP));
    check("format props", cpl.status == APU_BRU_OK && rec.valid && rec.get_fmt &&
          rec.kind == APU_GNH_PHYS && rec.handle == hp &&
          rec.result == APU_GFP_FEATURES);
    peek(APU_GFP_BRU_REPLY, t0);
    peek(APU_GFP_BRU_REPLY+1, t1);
    check("vgf reply", t0 == 32'd4 && t1 == APU_GFP_FEATURES);
    ack();
    load_ifp(APU_IFP_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_IFP));
    check("image format", cpl.status == APU_BRU_OK && rec.valid && rec.get_ifmt &&
          rec.kind == APU_GNH_PHYS && rec.handle == hp &&
          rec.result == APU_IFP_MAX_EXTENT);
    peek(APU_IFP_BRU_REPLY, t0);
    check("vip reply", t0 == 32'd5);
    ack();
    load_dex(APU_DEX_GENERATE_REPLY, 64'(hp));
    fire(mk_op(APU_BRU_DEX));
    check("device ext", cpl.status == APU_BRU_OK && rec.valid && rec.get_dext &&
          rec.kind == APU_GNH_PHYS && rec.handle == hp &&
          rec.result == APU_DEX_COUNT);
    peek(APU_DEX_BRU_REPLY, t0);
    check("vxe reply", t0 == 32'd14);
    ack();
    load_dispatch(64'(hc));
    in_a = 32'd4;
    in_b = 32'd5;
    fire(mk_op(APU_BRU_DISPATCH));
    check("dispatch after end faults", cpl.status == APU_BRU_FAULT && !irq);
    ack();
    load_end(32'd0, 64'(hc));
    fire(mk_op(APU_BRU_END));
    check("second end faults", cpl.status == APU_BRU_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(APU_VAC_GENERATE_REPLY, 64'hC2);
    fire(mk_op(APU_BRU_ALLOC));
    hc = rec.handle;
    check("reply alloc", cpl.status == APU_BRU_OK && rec.valid && rec.reply &&
          rec.object_id == 32'hC2);
    peek(APU_VAC_REPLY, t0);
    peek(APU_VAC_REPLY + 4, t4);
    check("reply type", t0 == 32'd88 && t4 == hc);
    ack();
    load_begin(APU_VBG_GENERATE_REPLY, 64'(hc), 32'd0);
    fire(mk_op(APU_BRU_BEGIN));
    check("reply begin", cpl.status == APU_BRU_OK && rec.valid && rec.reply &&
          rec.begin_cmd && rec.handle == hc);
    peek(APU_VBG_REPLY, t0);
    peek(APU_VBG_REPLY + 1, t1);
    check("begin reply words", t0 == 32'd90 && t1 == 32'd0);
    ack();

    cases++;
    do_reset;
    load_dispatch(64'hB1);
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_op(APU_BRU_DISPATCH));
    check("dispatch before create faults", cpl.status == APU_BRU_FAULT && !irq);
    ack();

    cases++;
    fill_alu(16'd128, mem, n);
    load_create(mem, n, 64'hB2);
    fire(mk_op(APU_BRU_CREATE));
    ack();
    load_begin(32'd0, 64'(rec.handle), 32'd0);
    fire(mk_op(APU_BRU_BEGIN));
    check("module as cmdbuf faults", cpl.status == APU_BRU_FAULT);
    ack();

    cases++;
    do_reset;
    fire(mk_gnh(APU_GNH_ALLOC, APU_GNH_MODULE, 32'hB3, 32'd0));
    hc = rec.handle;
    ack();
    load_begin(32'd0, 64'(hc), 32'd0);
    fire(mk_op(APU_BRU_BEGIN));
    check("gnh module begin faults", cpl.status == APU_BRU_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    poke(0, 32'd0);
    poke(1, 32'd0);
    poke64(2, 64'hA1);
    poke64(4, 64'd1);
    poke(6, APU_VNENC_STYPE_SHADER_MODULE);
    fire(mk_op(APU_BRU_CREATE));
    check("instance create faults", cpl.status == APU_BRU_FAULT);
    ack();

    cases++;
    do_reset;
    poke(0, APU_VBG_CMD_END);
    poke(1, 32'd0);
    poke64(2, 64'hC1);
    poke64(4, 64'd1);
    poke(6, APU_VBG_STYPE_BEGIN);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke64(10, 64'd0);
    fire(mk_op(APU_BRU_BEGIN));
    check("end as begin faults", cpl.status == APU_BRU_FAULT);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hC1);
    fire(mk_op(APU_BRU_ALLOC));
    hc = rec.handle;
    ack();
    load_end(32'd0, 64'(hc));
    fire(mk_op(APU_BRU_END));
    check("end before begin faults", cpl.status == APU_BRU_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hC1);
    fire(mk_op(APU_BRU_ALLOC));
    hc = rec.handle;
    ack();
    load_begin(32'd0, 64'(hc), 32'd0);
    fire(mk_op(APU_BRU_BEGIN));
    ack();
    load_submit(32'd0, 64'hA1, 64'(hc));
    fire(mk_op(APU_BRU_SUBMIT));
    check("submit before end faults", cpl.status == APU_BRU_FAULT && !rec.valid);
    ack();
    load_wait(32'd0, 64'hA1);
    fire(mk_op(APU_BRU_WAIT));
    check("wait before submit faults", cpl.status == APU_BRU_FAULT && !rec.valid);
    ack();

    if (errors != 0) $fatal(1, "APU bru errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_bru cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
