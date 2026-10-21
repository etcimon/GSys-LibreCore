// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_hyp_lfsr -- the hyp8 replacement for the vendor lfsr cell. Port and
// parameter list are identical so an instantiation only changes the module
// name. Function is identical to the vendor cell for the configuration
// every consumer uses (CipherLayers == 0): a Galois LFSR that right-shifts
// on en_i with the feedback XOR tree folding back through the Koopman mask
// for LfsrWidth, out_o reading the low OutWidth bits of the register.
//
// hyp8 timing note: out_o IS the registered boundary the plan calls for --
// the feedback tree sits entirely in the D-input of the state register, so
// the observable output carries no combinational cone from en_i. The
// Present-cipher layers of the vendor cell are NOT implemented here (no
// consumer uses them); CipherLayers > 0 trips an elaboration-time check
// under translate_off.

module g6lc_hyp_lfsr #(
  parameter int unsigned          LfsrWidth     = 64,   // [4,64]
  parameter int unsigned          OutWidth      = 8,    // [1,LfsrWidth]
  parameter logic [LfsrWidth-1:0] RstVal        = '1,   // [1,2^LfsrWidth-1]
  // unsupported in this cell -- kept for drop-in parameter compatibility
  parameter int unsigned          CipherLayers  = 0,
  parameter bit                   CipherReg     = 1'b1
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic                 en_i,
  output logic [OutWidth-1:0]  out_o
);

  // Galois LFSR feedback masks (Koopman maximal-length polynomials),
  // identical to the vendor cell's table.
  localparam logic [63:0] Masks [4:64] = '{64'hC,
                                           64'h1E,
                                           64'h39,
                                           64'h7E,
                                           64'hFA,
                                           64'h1FD,
                                           64'h3FC,
                                           64'h64B,
                                           64'hD8F,
                                           64'h1296,
                                           64'h2496,
                                           64'h4357,
                                           64'h8679,
                                           64'h1030E,
                                           64'h206CD,
                                           64'h403FE,
                                           64'h807B8,
                                           64'h1004B2,
                                           64'h2006A8,
                                           64'h4004B2,
                                           64'h800B87,
                                           64'h10004F3,
                                           64'h200072D,
                                           64'h40006AE,
                                           64'h80009E3,
                                           64'h10000583,
                                           64'h20000C92,
                                           64'h400005B6,
                                           64'h80000EA6,
                                           64'h1000007A3,
                                           64'h200000ABF,
                                           64'h400000842,
                                           64'h80000123E,
                                           64'h100000074E,
                                           64'h2000000AE9,
                                           64'h400000086A,
                                           64'h8000001213,
                                           64'h1000000077E,
                                           64'h2000000123B,
                                           64'h40000000877,
                                           64'h8000000108D,
                                           64'h100000000AE9,
                                           64'h200000000E9F,
                                           64'h4000000008A6,
                                           64'h80000000191E,
                                           64'h100000000090E,
                                           64'h2000000000FB3,
                                           64'h4000000000D7D,
                                           64'h80000000016A5,
                                           64'h10000000000B4B,
                                           64'h200000000010AF,
                                           64'h4000000000DDE,
                                           64'h8000000000181A,
                                           64'h100000000000B65,
                                           64'h20000000000102D,
                                           64'h40000000000CD5,
                                           64'h8000000000024C1,
                                           64'h1000000000000EF6,
                                           64'h2000000000001363,
                                           64'h4000000000000FCD,
                                           64'h80000000000019E2};

  logic [LfsrWidth-1:0] lfsr_d, lfsr_q;

  assign lfsr_d =
    (en_i) ? (lfsr_q>>1) ^ ({LfsrWidth{lfsr_q[0]}} & Masks[LfsrWidth][LfsrWidth-1:0])
           : lfsr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      lfsr_q <= LfsrWidth'(RstVal);
    end else begin
      lfsr_q <= lfsr_d;
    end
  end

  // registered boundary: the output is the state register itself
  assign out_o = lfsr_q[OutWidth-1:0];

  // pragma translate_off
  initial begin
    assert(OutWidth <= LfsrWidth) else
      $fatal(1, "OutWidth must be smaller equal the LfsrWidth.");
    assert(RstVal > unsigned'(0)) else
      $fatal(1, "RstVal must be nonzero.");
    assert((LfsrWidth >= $low(Masks)) && (LfsrWidth <= $high(Masks))) else
      $fatal(1, "Unsupported LfsrWidth (supported range: 4 to 64).");
    assert(CipherLayers == 0) else
      $fatal(1, "g6lc_hyp_lfsr does not implement the vendor cipher layers.");
  end
  // pragma translate_on

endmodule
