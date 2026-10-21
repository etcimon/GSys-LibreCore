// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
module g6lc_ai_cmd_fifo #(
    parameter int unsigned Depth = 64,
    parameter int unsigned DataWidth = 128,
    parameter int unsigned AddrWidth = Depth > 1 ? $clog2(Depth) : 1,
    parameter int unsigned CountWidth = Depth > 1 ? $clog2(Depth + 1) : 1
) (
    input logic clk_i, rst_ni, testmode_i,
    input logic push_valid_i,
    output logic push_ready_o,
    input logic [DataWidth-1:0] push_data_i,
    output logic pop_valid_o,
    input logic pop_ready_i,
    output logic [DataWidth-1:0] pop_data_o,
    output logic [CountWidth-1:0] count_o
);
  localparam int BeWidth = (DataWidth + 7) / 8;
  logic [AddrWidth-1:0] read_ptr_q, write_ptr_q;
  logic [CountWidth-1:0] count_q;
  logic head_valid_q, push_fire, pop_fire, read_request;
  logic [1:0] mem_request, mem_write;
  logic [1:0][AddrWidth-1:0] mem_address;
  logic [1:0][DataWidth-1:0] mem_write_data, mem_read_data;
  logic [1:0][BeWidth-1:0] mem_byte_enable;

  function automatic logic [AddrWidth-1:0] next_ptr(input logic [AddrWidth-1:0] ptr);
    if (Depth == 1) return '0;
    if ((Depth & (Depth - 1)) == 0) return ptr + AddrWidth'(1);
    return ptr == AddrWidth'(Depth - 1) ? '0 : ptr + AddrWidth'(1);
  endfunction

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_cmd_fifo  region=6983  makespan=13.000 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: count_q  ready_cycle=1  ready_fo4=4.746  OpenSTA: report_timing -from clk_i -to count_q
// order expect: head_valid_q  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to head_valid_q
// order expect: read_ptr_q  ready_cycle=2  ready_fo4=13.000  OpenSTA: report_timing -from clk_i -to read_ptr_q
// order expect: write_ptr_q  ready_cycle=2  ready_fo4=13.000  OpenSTA: report_timing -from clk_i -to write_ptr_q
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     count_q <= …; // sv-timing: cycle 1/2 on clk_i
//     head_valid_q <= …; // sv-timing: cycle 1/2 on clk_i
//     /* node25082 c=3.50 slack=9.50 */
//     /* node25083 c=3.50 slack=9.50 */
//     /* node25084 c=3.50 slack=9.50 */
//     /* node25085 c=3.50 slack=9.50 */
//     /* node25086 c=4.50 slack=8.50 */
//     /* node25087 c=5.50 slack=7.50 */
//     /* node25090 c=4.75 slack=8.25 */
//     /* node25091 c=4.75 slack=8.25 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     read_ptr_q <= …; // sv-timing: cycle 2/2 on clk_i
//     write_ptr_q <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node25088 c=13.00 slack=0.00 */
//     /* node25089 c=13.00 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign pop_valid_o = head_valid_q;
  assign pop_fire = pop_valid_o && pop_ready_i;
  assign push_ready_o = 32'(count_q) < Depth || pop_fire;
  assign push_fire = push_valid_i && push_ready_o;
  assign count_o = count_q;
  assign read_request = count_q != 0 && (!head_valid_q || (pop_fire && count_q > 1));
  assign pop_data_o = mem_read_data[0];
  assign mem_request = {push_fire, read_request};
  assign mem_write = 2'b10;
  assign mem_address[0] = pop_fire ? next_ptr(read_ptr_q) : read_ptr_q;
  assign mem_address[1] = write_ptr_q;
  assign mem_write_data[0] = '0;
  assign mem_write_data[1] = push_data_i;
  assign mem_byte_enable[0] = '0;
  assign mem_byte_enable[1] = '1;

  tc_sram #(
      .NumWords(Depth), .DataWidth(DataWidth), .ByteWidth(8), .NumPorts(2),
      .Latency(1), .SimInit("none"), .PrintSimCfg(1'b0), .ImplKey("g6lc_ai_commands")
  ) i_storage (
      .clk_i, .rst_ni, .req_i(mem_request), .we_i(mem_write), .addr_i(mem_address),
      .wdata_i(mem_write_data), .be_i(mem_byte_enable), .rdata_o(mem_read_data)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_ptr_q <= '0;
      write_ptr_q <= '0;
      count_q <= '0;
      head_valid_q <= 1'b0;
    end else begin
      if (read_request) head_valid_q <= 1'b1;
      else if (pop_fire) head_valid_q <= 1'b0;
      if (push_fire) write_ptr_q <= next_ptr(write_ptr_q);
      if (pop_fire) read_ptr_q <= next_ptr(read_ptr_q);
      case ({push_fire, pop_fire})
        2'b10: count_q <= count_q + CountWidth'(1);
        2'b01: count_q <= count_q - CountWidth'(1);
        default: ;
      endcase
    end
  end

  // pragma translate_off
  initial begin
    assert (Depth >= 1 && DataWidth > 0 && DataWidth % 8 == 0 &&
            AddrWidth == (Depth > 1 ? $clog2(Depth) : 1) &&
            CountWidth >= $clog2(64'(Depth) + 64'd1))
      else $error("g6lc_ai_cmd_fifo: invalid geometry");
  end
  always @(posedge clk_i) begin
    if (rst_ni) begin
      assert (32'(count_q) <= Depth && 32'(read_ptr_q) < Depth && 32'(write_ptr_q) < Depth);
      assert (!(read_request && push_fire && mem_address[0] == mem_address[1]));
    end
  end
  // pragma translate_on

  logic unused_testmode;
  assign unused_testmode = testmode_i;
endmodule
