// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.0 L2 banked data array.
// Contention opt: NUM_BANKS independent single-port SRAMs so a hit read and a
// fill write to different banks proceed in parallel (bank conflict only when
// index hashes collide).

module g6lc_l2_data #(
    parameter int unsigned NUM_SETS      = 512,
    parameter int unsigned SET_ASSOC     = 8,
    parameter int unsigned LINE_WIDTH    = 512,
    parameter int unsigned NUM_BANKS     = 4,
    parameter int unsigned IDX_WIDTH     = 9,
    // Words of LINE_WIDTH stored: sets * ways
    parameter int unsigned NUM_WORDS     = NUM_SETS * SET_ASSOC
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // Port A — hit path (core demand)
    input  logic                          a_req_i,
    input  logic                          a_we_i,
    input  logic [IDX_WIDTH-1:0]          a_index_i,
    input  logic [$clog2(SET_ASSOC)-1:0]  a_way_i,
    input  logic [LINE_WIDTH-1:0]         a_wdata_i,
    input  logic [LINE_WIDTH/8-1:0]       a_be_i,
    output logic [LINE_WIDTH-1:0]         a_rdata_o,
    // Port B — fill path (memory return)
    input  logic                          b_req_i,
    input  logic                          b_we_i,
    input  logic [IDX_WIDTH-1:0]          b_index_i,
    input  logic [$clog2(SET_ASSOC)-1:0]  b_way_i,
    input  logic [LINE_WIDTH-1:0]         b_wdata_i,
    input  logic [LINE_WIDTH/8-1:0]       b_be_i,
    output logic [LINE_WIDTH-1:0]         b_rdata_o,
    // Bank conflict (both ports same bank) — parent stalls B
    output logic                          bank_conflict_o
);

  localparam int unsigned WAY_W   = (SET_ASSOC <= 1) ? 1 : $clog2(SET_ASSOC);
  localparam int unsigned BANK_W  = (NUM_BANKS <= 1) ? 1 : $clog2(NUM_BANKS);
  localparam int unsigned WORDS_PER_BANK = (NUM_WORDS + NUM_BANKS - 1) / NUM_BANKS;
  localparam int unsigned BADDR_W = (WORDS_PER_BANK <= 1) ? 1 : $clog2(WORDS_PER_BANK);

  // Linearize (index, way) → word address, then bank
  function automatic logic [31:0] word_addr(
      input logic [IDX_WIDTH-1:0] idx,
      input logic [WAY_W-1:0] way
  );
    return 32'(idx) * SET_ASSOC + 32'(way);
  endfunction

  function automatic logic [BANK_W-1:0] bank_of(input logic [31:0] waddr);
    return BANK_W'(waddr % NUM_BANKS);
  endfunction

  function automatic logic [BADDR_W-1:0] baddr_of(input logic [31:0] waddr);
    return BADDR_W'(waddr / NUM_BANKS);
  endfunction

  logic [31:0] a_waddr, b_waddr;
  logic [BANK_W-1:0] a_bank, b_bank;
  logic [BADDR_W-1:0] a_baddr, b_baddr;

  assign a_waddr = word_addr(a_index_i, a_way_i);
  assign b_waddr = word_addr(b_index_i, b_way_i);
  assign a_bank  = bank_of(a_waddr);
  assign b_bank  = bank_of(b_waddr);
  assign a_baddr = baddr_of(a_waddr);
  assign b_baddr = baddr_of(b_waddr);

  assign bank_conflict_o = a_req_i && b_req_i && (a_bank == b_bank);

  // Per-bank ports: mux A/B with A priority on conflict
  logic [NUM_BANKS-1:0] bank_req, bank_we;
  logic [NUM_BANKS-1:0][BADDR_W-1:0] bank_addr;
  logic [NUM_BANKS-1:0][LINE_WIDTH-1:0] bank_wdata, bank_rdata;
  logic [NUM_BANKS-1:0][LINE_WIDTH/8-1:0] bank_be;

  always_comb begin
    bank_req   = '0;
    bank_we    = '0;
    bank_addr  = '0;
    bank_wdata = '0;
    bank_be    = '0;
    // Port A always wins its bank
    if (a_req_i) begin
      bank_req[a_bank]   = 1'b1;
      bank_we[a_bank]    = a_we_i;
      bank_addr[a_bank]  = a_baddr;
      bank_wdata[a_bank] = a_wdata_i;
      bank_be[a_bank]    = a_be_i;
    end
    // Port B only if no conflict
    if (b_req_i && !(a_req_i && a_bank == b_bank)) begin
      bank_req[b_bank]   = 1'b1;
      bank_we[b_bank]    = b_we_i;
      bank_addr[b_bank]  = b_baddr;
      bank_wdata[b_bank] = b_wdata_i;
      bank_be[b_bank]    = b_be_i;
    end
  end

  for (genvar b = 0; b < NUM_BANKS; b++) begin : gen_bank
    tc_sram #(
        .NumWords (WORDS_PER_BANK),
        .DataWidth(LINE_WIDTH),
        .ByteWidth(8),
        .NumPorts (1),
        .Latency  (1)
    ) i_bank (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (bank_req[b]),
        .we_i   (bank_we[b]),
        .addr_i (bank_addr[b]),
        .wdata_i(bank_wdata[b]),
        .be_i   (bank_be[b]),
        .rdata_o(bank_rdata[b])
    );
  end

  // Registered bank select for rdata (1-cycle latency)
  logic [BANK_W-1:0] a_bank_q, b_bank_q;
  logic a_req_q, b_req_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_bank_q <= '0;
      b_bank_q <= '0;
      a_req_q  <= 1'b0;
      b_req_q  <= 1'b0;
    end else begin
      a_bank_q <= a_bank;
      b_bank_q <= b_bank;
      a_req_q  <= a_req_i;
      b_req_q  <= b_req_i && !bank_conflict_o;
    end
  end

  assign a_rdata_o = a_req_q ? bank_rdata[a_bank_q] : '0;
  assign b_rdata_o = b_req_q ? bank_rdata[b_bank_q] : '0;

endmodule
