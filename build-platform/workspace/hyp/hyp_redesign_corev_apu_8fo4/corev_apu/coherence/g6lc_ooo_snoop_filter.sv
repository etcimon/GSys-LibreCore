// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
module g6lc_ooo_snoop_filter #(
    parameter int unsigned NR_CORES = 2,
    parameter int unsigned NR_ENTRIES = 128,
    parameter int unsigned LINE_BYTES = 16,
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned CID_W = NR_CORES <= 1 ? 1 : $clog2(NR_CORES),
    parameter int unsigned IDX_W = NR_ENTRIES <= 1 ? 1 : $clog2(NR_ENTRIES)
) (
    input logic clk_i,
    input logic rst_ni,
    input logic alloc_valid_i,
    input logic [ADDR_WIDTH-1:0] alloc_addr_i,
    input logic [CID_W-1:0] alloc_core_i,
    output logic alloc_ready_o,
    input logic lookup_valid_i,
    input logic [ADDR_WIDTH-1:0] lookup_addr_i,
    output logic lookup_ready_o,
    output logic result_valid_o,
    output logic [NR_CORES-1:0] present_o,
    output logic ready_o
);
  localparam int unsigned OFF = $clog2(LINE_BYTES);
  localparam int unsigned STORAGE_WIDTH = 32 * ((NR_CORES + 3) / 4);
  logic initialized_q;
  logic [IDX_W-1:0] init_index_q, address;
  logic request, write_enable;
  logic [STORAGE_WIDTH-1:0] write_data, read_data;
  logic [STORAGE_WIDTH/8-1:0] byte_enable;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ooo_snoop_filter  region=6089  makespan=8.146 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: init_index_q  ready_cycle=2  ready_fo4=8.146  OpenSTA: report_timing -from clk_i -to init_index_q
// order expect: initialized_q  ready_cycle=2  ready_fo4=8.146  OpenSTA: report_timing -from clk_i -to initialized_q
// order expect: result_valid_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to result_valid_o
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     result_valid_o <= …; // sv-timing: cycle 1/2 on clk_i
//     /* node21363 c=3.50 slack=4.65 */
//     /* node21364 c=3.50 slack=4.65 */
//     /* node21365 c=3.50 slack=4.65 */
//     /* node21366 c=3.50 slack=4.65 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     init_index_q <= …; // sv-timing: cycle 2/2 on clk_i
//     initialized_q <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node21367 c=8.15 slack=0.00 */
//     /* node21368 c=8.15 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign ready_o = initialized_q;
  assign lookup_ready_o = initialized_q;
  assign alloc_ready_o = initialized_q && !lookup_valid_i;
  for (genvar c = 0; c < NR_CORES; c++) begin : gen_present
    assign present_o[c] = result_valid_o ? read_data[8*c] : 1'b1;
  end

  always_comb begin
    request = 1'b0;
    write_enable = 1'b0;
    address = '0;
    write_data = '1;
    byte_enable = '0;
    if (!initialized_q) begin
      request = rst_ni;
      write_enable = 1'b1;
      address = init_index_q;
      write_data = '0;
      byte_enable = '1;
    end else if (lookup_valid_i) begin
      request = 1'b1;
      address = NR_ENTRIES <= 1 ? '0 : lookup_addr_i[OFF +: IDX_W];
    end else if (alloc_valid_i) begin
      request = 1'b1;
      write_enable = 1'b1;
      address = NR_ENTRIES <= 1 ? '0 : alloc_addr_i[OFF +: IDX_W];
      byte_enable[alloc_core_i] = 1'b1;
    end
  end

  tc_sram #(
      .NumWords(NR_ENTRIES), .DataWidth(STORAGE_WIDTH), .ByteWidth(8),
      .NumPorts(1), .Latency(1), .SimInit("none"), .ImplKey("g6lc_coh_signature")
  ) i_presence (
      .clk_i, .rst_ni, .req_i(request), .we_i(write_enable),
      .addr_i(address), .wdata_i(write_data), .be_i(byte_enable), .rdata_o(read_data)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      initialized_q <= 1'b0;
      init_index_q <= '0;
      result_valid_o <= 1'b0;
    end else begin
      result_valid_o <= lookup_valid_i && lookup_ready_o;
      if (!initialized_q) begin
        if (init_index_q == IDX_W'(NR_ENTRIES - 1)) initialized_q <= 1'b1;
        else init_index_q <= init_index_q + 1'b1;
      end
    end
  end

  if (NR_CORES < 1 || NR_ENTRIES < 1 || LINE_BYTES < 1 ||
      (NR_ENTRIES & (NR_ENTRIES - 1)) != 0 ||
      (LINE_BYTES & (LINE_BYTES - 1)) != 0 || OFF + IDX_W > ADDR_WIDTH) begin : gen_bad_geometry
    $error("invalid OoO snoop-signature geometry");
  end
endmodule
