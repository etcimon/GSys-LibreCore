// Focused check for the depth-tiled g6lc_apu_fwram gen_hex preload.
// Loads a hex image through HexFile, then verifies each tile's sram[]
// holds {hex32[2r+1],hex32[2r]} for flat row r = t*4096 + local.
`timescale 1ns/1ps
module tb_fwpre;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic testmode = 1;
  logic [31:0] aw_hart = 0, ar_hart = 0;
  apu_dma_axi_req_t slv_req;
  apu_dma_axi_resp_t slv_rsp;
  axi_pkg::xbar_rule_64_t ram_rule;
  logic [63:0] ram_base, ram_end;
  logic fault;
  string hexfile;
  logic [31:0] hex32 [0:131071];   // up to 256 KiB image -> 65536 words; headroom

  g6lc_apu_fwram #(
    .ApuCfg(ApuHarness),
    .RamIdx(12),
    .HexFile("fwpre.hex")
  ) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(testmode),
    .aw_hart_i(aw_hart), .ar_hart_i(ar_hart),
    .slv_req_i(slv_req), .slv_rsp_o(slv_rsp),
    .ram_rule_o(ram_rule), .ram_base_o(ram_base), .ram_end_o(ram_end),
    .fault_o(fault)
  );

  always #5 clk = ~clk;
  initial begin rst_ni = 0; slv_req = '0; #30; rst_ni = 1; end

  initial begin
    hexfile = "fwpre.hex";
    void'($value$plusargs("HEX=%s", hexfile));
    $readmemh(hexfile, hex32);
  end

  int errors = 0, checks = 0;
  task automatic check_row(input int r);
    int t, lr;
    logic [63:0] exp, got;
    t  = r / 4096;
    lr = r % 4096;
    exp = {hex32[2*r+1], hex32[2*r]};
    case (t)
      0: got = i_dut.gen_on.g_fw[0].i_ram.sram[lr];
      1: got = i_dut.gen_on.g_fw[1].i_ram.sram[lr];
      2: got = i_dut.gen_on.g_fw[2].i_ram.sram[lr];
      3: got = i_dut.gen_on.g_fw[3].i_ram.sram[lr];
      4: got = i_dut.gen_on.g_fw[4].i_ram.sram[lr];
      5: got = i_dut.gen_on.g_fw[5].i_ram.sram[lr];
      6: got = i_dut.gen_on.g_fw[6].i_ram.sram[lr];
      default: got = i_dut.gen_on.g_fw[7].i_ram.sram[lr];
    endcase
    checks++;
    if (got !== exp) begin
      errors++;
      $display("MISMATCH row=%0d tile=%0d local=%0d exp=%h got=%h",
               r, t, lr, exp, got);
    end
  endtask

  initial begin
    int r;
    #400;   // let the time-0 gen_hex preload finish
    // sample: head, tile-boundary rows, tail, plus stride coverage
    check_row(0); check_row(1); check_row(2);
    for (r = 0; r < 400; r += 37) check_row(r);          // tile 0 dense-ish
    for (r = 4096; r < 4400; r += 61) check_row(r);       // tile 1 head
    for (r = 8192; r < 8500; r += 67) check_row(r);       // tile 2
    for (r = 12288; r < 12600; r += 71) check_row(r);     // tile 3
    for (r = 16384; r < 16700; r += 73) check_row(r);     // tile 4
    for (r = 20480; r < 20800; r += 79) check_row(r);     // tile 5
    for (r = 24576; r < 24900; r += 83) check_row(r);     // tile 6
    for (r = 28672; r < 30000; r += 89) check_row(r);     // tile 7
    check_row(4095); check_row(4096); check_row(8191); check_row(8192);
    if (errors == 0)
      $display("PASS tb_fwpre checks=%0d errors=0", checks);
    else
      $fatal(1, "tb_fwpre errors=%0d checks=%0d", errors, checks);
    $finish;
  end
endmodule
