// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// I3 island-DMA DRAM page-command delay. Not LiteDRAM and not a backing store.
// Testharness SRAM still holds data; this only stalls AR/AW issue so the
// island PMU sees DDR4-class command latency (page hit = Cas, miss =
// tRP+tRCD+Cas, empty bank = tRCD+Cas). Core fetch/LSU is unaffected because
// the wrapper sits on the island AXI master, not the xbar DRAM slave.
//
// CasCycles==0 is a combinational passthrough (live I3-lite identity).
// Timing: one 8-bit countdown per AR/AW; no extra combinational cone on
// the SRAM data path.

module g6lc_ai_dram_timing #(
    parameter int unsigned CasCycles  = 0,
    parameter int unsigned TrcdCycles = 0,
    parameter int unsigned TrpCycles  = 0,
    parameter int unsigned AddrWidth  = 64,
    parameter int unsigned PageBits   = 12,
    parameter int unsigned BankBits   = 3,
    parameter type         axi_req_t  = logic,
    parameter type         axi_resp_t = logic
) (
    input  logic      clk_i,
    input  logic      rst_ni,
    input  axi_req_t  slv_req_i,
    output axi_resp_t slv_resp_o,
    output axi_req_t  mst_req_o,
    input  axi_resp_t mst_resp_i
);

  localparam int unsigned NBanks   = 1 << BankBits;
  localparam int unsigned RowLSB   = PageBits + BankBits;
  localparam int unsigned WaitW    = 8;
  localparam bit          Bypass   = (CasCycles == 0);

  if (Bypass) begin : gen_bypass
    assign mst_req_o  = slv_req_i;
    assign slv_resp_o = mst_resp_i;
  end else begin : gen_page
    typedef logic [WaitW-1:0] wait_t;

    logic               ar_busy_q, aw_busy_q;
    wait_t              ar_wait_q, aw_wait_q;
    logic [NBanks-1:0]  open_v_q;
    logic [AddrWidth-RowLSB-1:0] open_row_q [NBanks];

    function automatic logic [BankBits-1:0] bank_of(input logic [AddrWidth-1:0] a);
      return a[PageBits +: BankBits];
    endfunction

    function automatic logic [AddrWidth-RowLSB-1:0] row_of(input logic [AddrWidth-1:0] a);
      return a[AddrWidth-1:RowLSB];
    endfunction

    function automatic wait_t page_delay(
        input logic [AddrWidth-1:0] a
    );
      logic [BankBits-1:0] b;
      b = bank_of(a);
      if (open_v_q[b] && open_row_q[b] == row_of(a))
        return wait_t'(CasCycles);
      else if (open_v_q[b])
        return wait_t'(TrpCycles + TrcdCycles + CasCycles);
      else
        return wait_t'(TrcdCycles + CasCycles);
    endfunction

    logic  ar_go, aw_go;
    assign ar_go = ar_busy_q && (ar_wait_q == '0);
    assign aw_go = aw_busy_q && (aw_wait_q == '0);

    always_comb begin
      mst_req_o          = slv_req_i;
      slv_resp_o         = mst_resp_i;
      mst_req_o.ar_valid = slv_req_i.ar_valid && ar_go;
      mst_req_o.aw_valid = slv_req_i.aw_valid && aw_go;
      slv_resp_o.ar_ready = mst_resp_i.ar_ready && ar_go;
      slv_resp_o.aw_ready = mst_resp_i.aw_ready && aw_go;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ar_busy_q <= 1'b0;
        aw_busy_q <= 1'b0;
        ar_wait_q <= '0;
        aw_wait_q <= '0;
        open_v_q  <= '0;
        for (int unsigned i = 0; i < NBanks; i++)
          open_row_q[i] <= '0;
      end else begin
        if (slv_req_i.ar_valid && !ar_busy_q) begin
          ar_busy_q <= 1'b1;
          // Load delay-1 so Cas=N is N island cycles from capture to issue.
          ar_wait_q <= page_delay(AddrWidth'(slv_req_i.ar.addr)) - wait_t'(1);
        end else if (ar_go && slv_req_i.ar_valid && mst_resp_i.ar_ready) begin
          ar_busy_q <= 1'b0;
          ar_wait_q <= '0;
          open_v_q[bank_of(AddrWidth'(slv_req_i.ar.addr))] <= 1'b1;
          open_row_q[bank_of(AddrWidth'(slv_req_i.ar.addr))] <=
              row_of(AddrWidth'(slv_req_i.ar.addr));
        end else if (ar_busy_q && ar_wait_q != '0) begin
          ar_wait_q <= ar_wait_q - wait_t'(1);
        end

        if (slv_req_i.aw_valid && !aw_busy_q) begin
          aw_busy_q <= 1'b1;
          aw_wait_q <= page_delay(AddrWidth'(slv_req_i.aw.addr)) - wait_t'(1);
        end else if (aw_go && slv_req_i.aw_valid && mst_resp_i.aw_ready) begin
          aw_busy_q <= 1'b0;
          aw_wait_q <= '0;
          open_v_q[bank_of(AddrWidth'(slv_req_i.aw.addr))] <= 1'b1;
          open_row_q[bank_of(AddrWidth'(slv_req_i.aw.addr))] <=
              row_of(AddrWidth'(slv_req_i.aw.addr));
        end else if (aw_busy_q && aw_wait_q != '0) begin
          aw_wait_q <= aw_wait_q - wait_t'(1);
        end
      end
    end
  end

endmodule
