// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// SMT wait-for-peer: a store/AMO on hart j snoops every other hart's
// Zawrs reservation replica. Conservative (address-blind): a peer store
// to a different address still wakes WRS, which the ISA allows.
// N=1 or PeerEn=0: snoop_o is 0.

module g6lc_zawrs_peer #(
    parameter int unsigned N = 2,
    parameter bit          PeerEn = 1'b1
) (
    input  logic [N-1:0] store_i,
    output logic [N-1:0] snoop_o
);

  if (PeerEn && N > 1) begin : gen_on
    for (genvar h = 0; h < int'(N); h++) begin : gen_h
      assign snoop_o[h] = |(store_i & ~(N'(1) << h));
    end
  end else begin : gen_off
    assign snoop_o = '0;
  end

endmodule
