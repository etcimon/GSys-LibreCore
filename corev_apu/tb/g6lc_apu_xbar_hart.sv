// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Hart id from the crossbar's prepended slave-port index. The low ID bits
// belong to the master and are not a hart. PROT is not an input. Only the
// cluster port is the firmware hart. Every other port is presented as hart 0.

module g6lc_apu_xbar_hart #(
  parameter int unsigned IdxW = 2,
  parameter int unsigned IdW = 6,
  parameter logic [31:0] FwHart = 32'd1,
  parameter int unsigned ClusterPort = 0
) (
  input  logic [IdW-1:0] aw_id_i,
  input  logic [IdW-1:0] ar_id_i,
  output logic [31:0] aw_hart_o,
  output logic [31:0] ar_hart_o
);
  localparam int unsigned PortW = (IdxW < 1) ? 1 : IdxW;
  logic [PortW-1:0] aw_port, ar_port;
  assign aw_port = aw_id_i[IdW-1 -: PortW];
  assign ar_port = ar_id_i[IdW-1 -: PortW];
  assign aw_hart_o = (aw_port == PortW'(ClusterPort)) ? FwHart : 32'h0;
  assign ar_hart_o = (ar_port == PortW'(ClusterPort)) ? FwHart : 32'h0;
endmodule
