// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
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
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_dram_timing  region=6960  makespan=24.350 FO4  cycle_count=4  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ar_busy_q  ready_cycle=4  ready_fo4=24.350  OpenSTA: report_timing -from clk_i -to ar_busy_q
// order expect: ar_wait_q  ready_cycle=4  ready_fo4=24.350  OpenSTA: report_timing -from clk_i -to ar_wait_q
// order expect: aw_busy_q  ready_cycle=4  ready_fo4=24.350  OpenSTA: report_timing -from clk_i -to aw_busy_q
// order expect: aw_wait_q  ready_cycle=4  ready_fo4=24.350  OpenSTA: report_timing -from clk_i -to aw_wait_q
// order expect: open_row_q  ready_cycle=4  ready_fo4=24.350  OpenSTA: report_timing -from clk_i -to open_row_q
// order expect: open_v_q  ready_cycle=4  ready_fo4=24.350  OpenSTA: report_timing -from clk_i -to open_v_q
// --- factor stage 1/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node25023 c=3.50 slack=20.85 */
//     /* node25024 c=3.50 slack=20.85 */
//     /* node25025 c=3.50 slack=20.85 */
//     /* node25026 c=3.50 slack=20.85 */
//     /* node25027 c=3.50 slack=20.85 */
//     /* node25028 c=3.50 slack=20.85 */
//   end
// end
// --- factor stage 2/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 2: no capture on this edge (slack) */
//   end
// end
// --- factor stage 3/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 3: no capture on this edge (slack) */
//     /* node25029 c=23.35 slack=1.00 */
//     /* node25030 c=23.85 slack=0.50 */
//     /* node25036 c=23.35 slack=1.00 */
//     /* node25037 c=23.85 slack=0.50 */
//   end
// end
// --- factor stage 4/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ar_busy_q <= …; // sv-timing: cycle 4/4 on clk_i
//     ar_wait_q <= …; // sv-timing: cycle 4/4 on clk_i
//     aw_busy_q <= …; // sv-timing: cycle 4/4 on clk_i
//     aw_wait_q <= …; // sv-timing: cycle 4/4 on clk_i
//     open_row_q <= …; // sv-timing: cycle 4/4 on clk_i
//     open_v_q <= …; // sv-timing: cycle 4/4 on clk_i
//     /* node25031 c=24.35 slack=0.00 */
//     /* node25032 c=24.35 slack=0.00 */
//     /* node25033 c=24.35 slack=0.00 */
//     /* node25034 c=24.35 slack=0.00 */
//     /* node25035 c=24.35 slack=0.00 */
//     /* node25038 c=24.35 slack=0.00 */
//     /* node25039 c=24.35 slack=0.00 */
//     /* node25040 c=24.35 slack=0.00 */
//     /* node25041 c=24.35 slack=0.00 */
//     /* node25042 c=24.35 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
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
      // Three cases in DDR4 cost order: page hit pays CAS only, a wrong open
      // row pays a precharge first (tRP + tRCD + CAS), a closed bank pays
      // activate + CAS. Getting the middle case wrong is what makes the model
      // look optimistic on strided GEMM traffic.
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
      // Only the address-phase valid/ready pair is gated. R/W/B pass straight
      // through, so this adds command latency without touching data timing or
      // the SRAM backing store behind it.
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
