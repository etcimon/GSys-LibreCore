// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Side-by-side harness: the live fetch_B `instr_realign` (parallel prefix,
// sv-timing A110) against the serial-walk revision renamed `instr_realign_old`.
// Random halfword streams; fetch blocks mostly sequential so split RVIs carry
// across blocks; every output compared each cycle.
module tb_rl_sbs;
  import ariane_pkg::*;
  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  logic clk = 1'b0, rst_ni = 1'b0;
  always #1 clk = ~clk;
  logic flush_i;
  logic kill_i;
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i;
  logic valid_i;
  logic [CVA6Cfg.VLEN-1:0] address_i;
  logic [CVA6Cfg.FETCH_WIDTH-1:0] data_i;
  logic serving_unaligned_o_old, serving_unaligned_o_new;
  logic leftover_pending_o_old, leftover_pending_o_new;
  logic leftover_valid_o_old, leftover_valid_o_new;
  logic [CVA6Cfg.VLEN-1:0] leftover_pc_o_old, leftover_pc_o_new;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] valid_o_old, valid_o_new;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr_o_old, addr_o_new;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] base_o_old, base_o_new;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] off_o_old, off_o_new;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][31:0] instr_o_old, instr_o_new;
  instr_realign_old #(.CVA6Cfg(CVA6Cfg)) u_old (.clk_i(clk), .rst_ni(rst_ni), .flush_i(flush_i), .kill_i(kill_i), .hart_i(hart_i), .valid_i(valid_i), .address_i(address_i), .data_i(data_i), .serving_unaligned_o(serving_unaligned_o_old), .leftover_pending_o(leftover_pending_o_old), .leftover_valid_o(leftover_valid_o_old), .leftover_pc_o(leftover_pc_o_old), .valid_o(valid_o_old), .addr_o(addr_o_old), .base_o(base_o_old), .off_o(off_o_old), .instr_o(instr_o_old));
  instr_realign     #(.CVA6Cfg(CVA6Cfg)) u_new (.clk_i(clk), .rst_ni(rst_ni), .flush_i(flush_i), .kill_i(kill_i), .hart_i(hart_i), .valid_i(valid_i), .address_i(address_i), .data_i(data_i), .serving_unaligned_o(serving_unaligned_o_new), .leftover_pending_o(leftover_pending_o_new), .leftover_valid_o(leftover_valid_o_new), .leftover_pc_o(leftover_pc_o_new), .valid_o(valid_o_new), .addr_o(addr_o_new), .base_o(base_o_new), .off_o(off_o_new), .instr_o(instr_o_new));

  function automatic logic [255:0] rnd256();
    rnd256 = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
  endfunction
  int unsigned cyc = 0, errors = 0, carries = 0, seed = 1;
  logic [CVA6Cfg.VLEN-1:0] next_addr = '0;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    #7 rst_ni = 1'b1;
  end
  always @(negedge clk) begin
    logic [255:0] r;
    r = rnd256(); flush_i = $bits(flush_i)'(r);
    r = rnd256(); kill_i = $bits(kill_i)'(r);
    r = rnd256(); hart_i = $bits(hart_i)'(r);
    r = rnd256(); data_i = $bits(data_i)'(r);

    r = rnd256();
    // 70 %: the next sequential block (carry completes); 20 %: a jump to a
    // random halfword-aligned address (carry dropped / unaligned start);
    // 10 %: the same block again
    if (r[7:0] < 8'd180) address_i = next_addr;
    else if (r[7:0] < 8'd230) address_i = {$bits(address_i)'(r[127:64]) & ~$bits(address_i)'(1)};
    valid_i = (r[15:8] < 8'd220);
    // bias the halfword stream: ~45 % compressed (low two bits != 11)
    for (int h = 0; h < CVA6Cfg.FETCH_WIDTH / 16; h++) begin
      if (r[16 + h]) data_i[16*h +: 2] = 2'b11; else data_i[16*h +: 2] = 2'(r[40 + 2*h +: 2]) % 3;
    end
  end
  always @(posedge clk) begin
    if (rst_ni) begin
      cyc++;
      // the following block starts where this one ends
      next_addr <= (address_i & ~$bits(address_i)'(CVA6Cfg.FETCH_WIDTH / 8 - 1)) + $bits(address_i)'(CVA6Cfg.FETCH_WIDTH / 8);
      if (u_old.carry_valid_d) carries++;
      #0.2;
        if (serving_unaligned_o_old !== serving_unaligned_o_new) begin $display("MISMATCH cyc=%0d serving_unaligned_o old=%h new=%h", cyc, serving_unaligned_o_old, serving_unaligned_o_new); errors++; end
        if (leftover_pending_o_old !== leftover_pending_o_new) begin $display("MISMATCH cyc=%0d leftover_pending_o old=%h new=%h", cyc, leftover_pending_o_old, leftover_pending_o_new); errors++; end
        if (leftover_valid_o_old !== leftover_valid_o_new) begin $display("MISMATCH cyc=%0d leftover_valid_o old=%h new=%h", cyc, leftover_valid_o_old, leftover_valid_o_new); errors++; end
        if (leftover_pc_o_old !== leftover_pc_o_new) begin $display("MISMATCH cyc=%0d leftover_pc_o old=%h new=%h", cyc, leftover_pc_o_old, leftover_pc_o_new); errors++; end
        if (valid_o_old !== valid_o_new) begin $display("MISMATCH cyc=%0d valid_o old=%h new=%h", cyc, valid_o_old, valid_o_new); errors++; end
        if (addr_o_old !== addr_o_new) begin $display("MISMATCH cyc=%0d addr_o old=%h new=%h", cyc, addr_o_old, addr_o_new); errors++; end
        if (base_o_old !== base_o_new) begin $display("MISMATCH cyc=%0d base_o old=%h new=%h", cyc, base_o_old, base_o_new); errors++; end
        if (off_o_old !== off_o_new) begin $display("MISMATCH cyc=%0d off_o old=%h new=%h", cyc, off_o_old, off_o_new); errors++; end
        if (instr_o_old !== instr_o_new) begin $display("MISMATCH cyc=%0d instr_o old=%h new=%h", cyc, instr_o_old, instr_o_new); errors++; end
      if (errors > 5) begin $display("FAIL tb_rl_sbs cyc=%0d errors=%0d", cyc, errors); $finish; end
      if (cyc == 500000) begin
        $display("%s tb_rl_sbs cycles=%0d carries=%0d errors=%0d", errors == 0 ? "PASS" : "FAIL", cyc, carries, errors);
        $finish;
      end
    end
  end
endmodule
