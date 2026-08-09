// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// APB3 slave in front of g6lc_ai_island_top (simple reg port).
// Setup phase arms the request; access phase waits for rvalid (1–2 cycles).
// Optional AXI DMA master for descriptor fetch (EnableDmaFetch).

module g6lc_ai_island_apb
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter ai_island_cfg_t IslandCfg = AiIslandLatencyDefault,
    parameter bit             EnableDmaFetch = 1'b1,
    parameter int unsigned    AxiDataWidth = 64,
    parameter int unsigned    AxiIdWidth   = 4,
    parameter type            axi_req_t    = logic,
    parameter type            axi_resp_t   = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,
    // APB
    input  logic        psel_i,
    input  logic        penable_i,
    input  logic        pwrite_i,
    input  logic [31:0] paddr_i,
    input  logic [31:0] pwdata_i,
    output logic [31:0] prdata_o,
    output logic        pready_o,
    output logic        pslverr_o,
    output logic        irq_o,
    // Core sideband (optional; tie 0 when unused)
    input  logic        sb_enq_valid_i,
    input  logic [7:0]  sb_qid_i,
    input  logic [31:0] sb_ticket_i,
    output logic [31:0] sb_last_ticket_o,
    output logic [15:0] sb_last_status_o,
    output logic        sb_has_completion_o,
    // AXI DMA (desc fetch)
    output axi_req_t    axi_dma_req_o,
    input  axi_resp_t   axi_dma_resp_i
);

  logic        is_req, is_we;
  logic [15:0] is_addr;
  logic [31:0] is_wdata, is_rdata;
  logic        is_rvalid;

  typedef enum logic [1:0] { S_IDLE, S_REQ, S_WAIT } state_e;
  state_e state_q, state_d;

  g6lc_ai_island_top #(
      .IslandCfg     (IslandCfg),
      .EnableDmaFetch(EnableDmaFetch),
      .AxiDataWidth  (AxiDataWidth),
      .AxiIdWidth    (AxiIdWidth),
      .axi_req_t     (axi_req_t),
      .axi_resp_t    (axi_resp_t)
  ) i_island (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .testmode_i(testmode_i),
      .req_i     (is_req),
      .we_i      (is_we),
      .addr_i    (is_addr),
      .wdata_i   (is_wdata),
      .rdata_o   (is_rdata),
      .rvalid_o  (is_rvalid),
      .irq_o     (irq_o),
      .sb_enq_valid_i      (sb_enq_valid_i),
      .sb_qid_i            (sb_qid_i),
      .sb_ticket_i         (sb_ticket_i),
      .sb_last_ticket_o    (sb_last_ticket_o),
      .sb_last_status_o    (sb_last_status_o),
      .sb_has_completion_o (sb_has_completion_o),
      .axi_dma_req_o       (axi_dma_req_o),
      .axi_dma_resp_i      (axi_dma_resp_i)
  );

  always_comb begin
    state_d   = state_q;
    is_req    = 1'b0;
    is_we     = 1'b0;
    is_addr   = paddr_i[15:0];
    is_wdata  = pwdata_i;
    pready_o  = 1'b0;
    pslverr_o = 1'b0;
    prdata_o  = is_rdata;

    unique case (state_q)
      S_IDLE: begin
        if (psel_i && !penable_i) begin
          // SETUP — arm for ACCESS
          state_d = S_REQ;
        end
      end
      S_REQ: begin
        if (psel_i && penable_i) begin
          is_req = 1'b1;
          is_we  = pwrite_i;
          state_d = S_WAIT;
        end else if (!psel_i) begin
          state_d = S_IDLE;
        end
      end
      S_WAIT: begin
        // Keep req low after first cycle; wait for registered rvalid
        if (is_rvalid || pwrite_i) begin
          // Writes also complete after 1 cycle of processing
          pready_o = 1'b1;
          prdata_o = is_rdata;
          state_d  = S_IDLE;
        end
      end
      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= S_IDLE;
    else state_q <= state_d;
  end

endmodule
