// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal against the LIVE realigner (`core/fetch_B/instr_realign.sv`).
//
// The other fetch proofs are over pure functions. This one instantiates the real
// module, which is what makes two invariants reachable that a pure-function
// proof cannot express, because both quantify over module state or over the I$
// line rather than over a closed argument tuple:
//
//   I1/I2  no fabricate: every emitted slot's halfword is the halfword actually
//          present in `data_i` at that slot's own address. core-fetch/SPEC.md
//          s10 previously recorded this as "L3 is leftmost feasible"; that was
//          too pessimistic -- one window is a bounded free input, so the
//          quantifier IS closed and this belongs at L2.
//   I4     leftover is per-hart: a window fetched for one hart must not disturb
//          any other hart's carry. R1 lets a parked hart run with sp==0, so a
//          cross-hart carry corruption is indistinguishable from a hart that is
//          simply not ready yet -- the reason this is worth a proof and not a
//          code reading.
//
// Mirrors core/ooo/formal, which likewise proves against live modules.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_realign.sby
//      cva6-build verify --formal

module g6lc_fetch_realign_props #(
    parameter int unsigned FW = 64,  // FETCH_WIDTH bits
    parameter int unsigned AB = 3,   // FETCH_ALIGN_BITS = log2(FW/8)
    parameter int unsigned NH = 2    // NrHarts (>=2 exercises the bank)
) (
    input logic clk_i,
    input logic flush_i, kill_i, valid_i,
    input logic [(NH > 1 ? $clog2(NH) : 1)-1:0] hart_i,
    input logic [31:0] address_i,
    input logic [FW-1:0] data_i
);

`ifdef FORMAL
  localparam int unsigned VLEN   = 32;
  localparam int unsigned SLOTS  = FW / 16;
  localparam int unsigned HWPW   = FW / 16;
  localparam int unsigned HARTW  = (NH > 1) ? $clog2(NH) : 1;

  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c                      = config_pkg::cva6_cfg_empty;
    c.XLEN                 = 32;
    c.VLEN                 = VLEN;
    c.FETCH_WIDTH          = FW;
    c.FETCH_ALIGN_BITS     = AB;
    c.INSTR_PER_FETCH      = SLOTS;
    c.LOG2_INSTR_PER_FETCH = $clog2(SLOTS);
    c.RVC                  = 1'b1;
    c.NrHarts              = NH;
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();

  // --- free stimulus --------------------------------------------------------

  logic              serving_unaligned, leftover_pending, leftover_valid;
  logic [VLEN-1:0]   leftover_pc;
  logic [SLOTS-1:0]  valid_o;
  logic [SLOTS-1:0][VLEN-1:0] addr_o;
  logic [SLOTS-1:0][31:0]     instr_o;

  // Reset: held low on the first cycle only. `initial assume` is rejected by the
  // slang frontend (reading a net during design initialization), so the reset is
  // generated from an initialised register instead.
  logic init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) init_q <= 1'b0;
  assign rst_ni = ~init_q;

  instr_realign #(
      .CVA6Cfg(Cfg)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,
      .kill_i,
      .hart_i,
      .valid_i,
      .serving_unaligned_o(serving_unaligned),
      .leftover_pending_o (leftover_pending),
      .leftover_valid_o   (leftover_valid),
      .leftover_pc_o      (leftover_pc),
      .address_i,
      .data_i,
      .valid_o,
      .addr_o,
      .instr_o
  );

  // Host contract: the I$ delivers window-aligned addresses. Without this the
  // realigner is being asked a question the cache never asks, and the cursor
  // arithmetic legitimately has no meaning.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (address_i[AB-1:0] == '0);
      assume (int'(hart_i) < NH);
    end
  end

  // --- I1/I2: no fabricate, against the live line --------------------------
  // Slot 0 is excluded while `serving_unaligned` because it is deliberately the
  // PREVIOUS window's carry completing here -- its low half comes from the bank,
  // not from this line. That exclusion is the contract, not a waiver.
  always_ff @(posedge clk_i) begin
    if (rst_ni && valid_i) begin
      for (int unsigned k = 0; k < SLOTS; k++) begin
        if (valid_o[k] && !(k == 0 && serving_unaligned)) begin
          automatic logic [VLEN-1:0] off;
          off = addr_o[k] - address_i;
          if (off < VLEN'(FW / 8)) begin
            assert (instr_o[k][15:0] == data_i[16*off[AB-1:1]+:16]);
          end
        end
      end
    end
  end

  // --- I2: emitted PCs step by their own ilen ------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && valid_i) begin
      for (int unsigned k = 0; k + 1 < SLOTS; k++) begin
        if (valid_o[k] && valid_o[k+1]) begin
          assert (addr_o[k+1] ==
                  addr_o[k] + VLEN'(g6lc_fetch_pkg::ilen_of(Cfg, instr_o[k][15:0])));
        end
      end
    end
  end

  // --- I4: leftover is per-hart -------------------------------------------
  // A window is presented for exactly one hart, so no other hart's carry may
  // move. Compare the bank against its own previous value, keyed on the hart
  // that owned the window which produced the update.
  logic [NH-1:0]     bank_v;
  logic [NH-1:0]     bank_v_q;
  logic [HARTW-1:0]  hart_q;
  logic              armed_q;

  always_comb begin
    for (int unsigned i = 0; i < NH; i++) bank_v[i] = dut.carry_valid_bank_q[i];
  end

  always_ff @(posedge clk_i) begin
    bank_v_q <= bank_v;
    hart_q   <= hart_i;
    armed_q  <= rst_ni;
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && armed_q) begin
      for (int unsigned i = 0; i < NH; i++) begin
        if (HARTW'(i) != hart_q) assert (bank_v[i] == bank_v_q[i]);
      end
    end
  end

  // --- reachability --------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (serving_unaligned);
      cover (leftover_pending);
      cover (|bank_v);
      cover (serving_unaligned && hart_i == HARTW'(1));
      cover (armed_q && hart_i != hart_q && |bank_v);
    end
  end
`endif

endmodule
