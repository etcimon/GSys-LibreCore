// hyp8 port of verif/tb/core/tb_g6lc_zcmop.sv (89d3dadd0).
// compressed_decoder Zcmop: c.mop.n (odd n, zero-imm C.LUI) expands to
// addi x0,x0,0 when RVZcmop=1 and stays illegal when the knob is off.
// Config adapted cva6_cfg_t/CVA6Cfg -> g6lc_cfg_t/G6LCCfg.
module tb_g6lc_zcmop;
  function automatic config_pkg::g6lc_cfg_t cfg_of(input bit on);
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64;
    c.IS_XLEN64 = 1'b1;
    c.RVC = 1'b1;
`ifdef G6LC_MUT_ZCMOP_OFF
    c.RVZcmop = 1'b0;
`else
    c.RVZcmop = on;
`endif
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C_ON = cfg_of(1'b1);
  localparam config_pkg::g6lc_cfg_t C_OFF = cfg_of(1'b0);

  logic [15:0] cin;
  logic [31:0] cout_on, cout_off;
  logic ill_on, ill_off, mac_on, mac_off, cmp_on, cmp_off, zc_on, zc_off;

  compressed_decoder #(.G6LCCfg(C_ON)) dut_on (
    .instr_i(cin), .instr_o(cout_on), .illegal_instr_o(ill_on),
    .is_macro_instr_o(mac_on), .is_compressed_o(cmp_on), .is_zcmt_instr_o(zc_on));
  compressed_decoder #(.G6LCCfg(C_OFF)) dut_off (
    .instr_i(cin), .instr_o(cout_off), .illegal_instr_o(ill_off),
    .is_macro_instr_o(mac_off), .is_compressed_o(cmp_off), .is_zcmt_instr_o(zc_off));

  // c.mop.1 = 0x6081, c.mop.15 = 0x6781, c.lui x1,1 = 0x6085 (nzimm bit2)
  localparam logic [15:0] C_MOP1  = 16'h6081;
  localparam logic [15:0] C_MOP15 = 16'h6781;
  localparam logic [15:0] C_LUI1  = 16'h6085;

  initial begin
    cin = C_MOP1;
    #1;
    if (ill_on || cout_on != 32'h00000013)
      $fatal(1, "ZCMOP_ON c.mop.1 ill=%0d out=%h", ill_on, cout_on);
    if (!ill_off)
      $fatal(1, "ZCMOP_OFF c.mop.1 not illegal");
    cin = C_MOP15;
    #1;
    if (ill_on || cout_on != 32'h00000013)
      $fatal(1, "ZCMOP_ON c.mop.15");
    cin = C_LUI1;
    #1;
    if (ill_on || ill_off)
      $fatal(1, "ZCMOP live C.LUI x1,1 became illegal");
    $display("PASS tb_g6lc_zcmop");
    $finish;
  end
endmodule
