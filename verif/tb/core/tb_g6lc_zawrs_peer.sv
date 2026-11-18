// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// SMT Zawrs wait-for-peer snoop. Mutation +define+G6LC_MUT_ZAWRS_PEER_OFF
// must fail ZAWRS_PEER_ON.
`timescale 1ns / 1ps
module tb_g6lc_zawrs_peer;
`ifdef G6LC_MUT_ZAWRS_PEER_OFF
  localparam bit PEER = 1'b0;
`else
  localparam bit PEER = 1'b1;
`endif

  logic [1:0] store, snoop_on, snoop_off;

  g6lc_zawrs_peer #(.N(2), .PeerEn(PEER)) dut_on (
      .store_i(store), .snoop_o(snoop_on)
  );
  g6lc_zawrs_peer #(.N(2), .PeerEn(1'b0)) dut_off (
      .store_i(store), .snoop_o(snoop_off)
  );

  initial begin
    store = 2'b00;
    #1;
    if (snoop_on != 2'b00) $fatal(1, "idle snoop %b", snoop_on);
    if (snoop_off != 2'b00) $fatal(1, "off idle snoop");

    store = 2'b01;
    #1;
    if (snoop_on != 2'b10)
      $fatal(1, "ZAWRS_PEER_ON hart0 store snoops %b", snoop_on);
    if (snoop_off != 2'b00)
      $fatal(1, "off-knob snooped on hart0 store");

    store = 2'b10;
    #1;
    if (snoop_on != 2'b01)
      $fatal(1, "ZAWRS_PEER_ON hart1 store snoops %b", snoop_on);

    store = 2'b11;
    #1;
    if (snoop_on != 2'b11)
      $fatal(1, "ZAWRS_PEER_ON both stores snoops %b", snoop_on);

    $display("PASS tb_g6lc_zawrs_peer");
    $finish;
  end
endmodule
