// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.1 banked integer register file for SMT.
//
// When NR_HARTS==1 this is a thin wrapper around a single ariane_regfile
// instance (same ports as the legacy path; hart_id inputs are ignored).
// When NR_HARTS>1 each hart owns a private 32-entry bank — eliminates
// cross-hart RF write-port contention and keeps architectural isolation.
//
// Read/write ports carry a per-port hart tag so dual-issue within one hart
// and dual-commit across harts (future) map cleanly. x0 remains hardwired 0
// in every bank.

module g6lc_smt_regfile #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg       = config_pkg::cva6_cfg_empty,
    parameter int unsigned           DATA_WIDTH    = 32,
    parameter int unsigned           NR_READ_PORTS = 2,
    parameter int unsigned           NR_HARTS      = 1,
    parameter bit                    ZERO_REG_ZERO = 0
) (
    input  logic                                             clk_i,
    input  logic                                             rst_ni,
    input  logic                                             test_en_i,
    // Read
    input  logic [NR_READ_PORTS-1:0][4:0]                    raddr_i,
    input  logic [NR_READ_PORTS-1:0][$clog2(NR_HARTS > 1 ? NR_HARTS : 2)-1:0] rhart_i,
    output logic [NR_READ_PORTS-1:0][DATA_WIDTH-1:0]         rdata_o,
    // Write
    input  logic [CVA6Cfg.NrCommitPorts-1:0][4:0]            waddr_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0][DATA_WIDTH-1:0] wdata_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0]                 we_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0][$clog2(NR_HARTS > 1 ? NR_HARTS : 2)-1:0] whart_i
);

  localparam int unsigned NH    = (NR_HARTS < 1) ? 1 : NR_HARTS;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  if (NH <= 1) begin : gen_single_bank
    // Bit-identical path to legacy ariane_regfile for NrHarts==1
    ariane_regfile #(
        .CVA6Cfg      (CVA6Cfg),
        .DATA_WIDTH   (DATA_WIDTH),
        .NR_READ_PORTS(NR_READ_PORTS),
        .ZERO_REG_ZERO(ZERO_REG_ZERO)
    ) i_rf (
        .clk_i,
        .rst_ni,
        .test_en_i,
        .raddr_i,
        .rdata_o,
        .waddr_i,
        .wdata_i,
        .we_i
    );
    // rhart_i / whart_i unused
    logic _unused_harts;
    assign _unused_harts = |rhart_i | |whart_i;
  end else begin : gen_banked
    // One physical bank per hart — no cross-hart port conflicts.
    logic [NH-1:0][NR_READ_PORTS-1:0][DATA_WIDTH-1:0] bank_rdata;
    logic [NH-1:0][CVA6Cfg.NrCommitPorts-1:0]         bank_we;

    for (genvar h = 0; h < NH; h++) begin : gen_hart_bank
      // Write enables gated by hart tag
      for (genvar w = 0; w < CVA6Cfg.NrCommitPorts; w++) begin : gen_we
        assign bank_we[h][w] = we_i[w] & (whart_i[w] == HID_W'(h));
      end

      ariane_regfile #(
          .CVA6Cfg      (CVA6Cfg),
          .DATA_WIDTH   (DATA_WIDTH),
          .NR_READ_PORTS(NR_READ_PORTS),
          .ZERO_REG_ZERO(ZERO_REG_ZERO)
      ) i_rf_bank (
          .clk_i,
          .rst_ni,
          .test_en_i,
          .raddr_i(raddr_i),
          .rdata_o(bank_rdata[h]),
          .waddr_i(waddr_i),
          .wdata_i(wdata_i),
          .we_i   (bank_we[h])
      );
    end

    // Read mux by per-port hart tag
    for (genvar r = 0; r < NR_READ_PORTS; r++) begin : gen_rmux
      assign rdata_o[r] = bank_rdata[rhart_i[r]][r];
    end
  end

endmodule
