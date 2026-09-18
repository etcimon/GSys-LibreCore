// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// External-invalidation retention for the HPDCACHE read-response seam.
//
// HPDCACHE only acts on an invalidation that arrives with a read response, because
// `mem_resp_read_miss_valid` is only ever asserted inside
// `if (mem_resp_read_valid_i)` (hpdcache.sv). An invalidation delivered on its own
// therefore has nowhere to land, and the integration used to paper over that by
// asserting unconditional readiness — so an invalidation arriving while the
// observer had no read response in flight was acknowledged and dropped, and a hart
// spinning on a line it already cached never saw the update.
//
// This block holds such an invalidation and presents it on a read-response cycle of
// its own. An invalidation-only response is a first-class case downstream: the miss
// handler writes its metadata FIFO on `mem_resp_inval_i` regardless of `r_last`,
// explicitly does NOT write the data FIFO, and routes `is_inval` to REFILL_INVAL
// without touching the MSHR. So the injected cycle needs no data, no `r_last` and no
// MSHR entry.
//
// CONTRACT (what the unit bench checks):
//   1. Conservation — every invalidation accepted (`valid & ready`) is injected
//      exactly once; none is lost, none is duplicated.
//   2. Honest backpressure — `inval_ready_o` is low exactly while the storage is
//      full, so the producer holds its request instead of having it discarded.
//   3. A real response always wins the channel: `inject_o` is never asserted in a
//      cycle where `resp_valid_i` is high. This is not an optimisation — `is_inval`
//      diverts the consumer's FSM INSTEAD of refilling, so piggybacking an
//      invalidation onto a real response would drop that refill.
//   4. Order is preserved across entries (FIFO), so a later invalidation of a line
//      cannot be overtaken by an earlier one for the same line.
//
// DEPTH is a parameter because the correct depth is a system property, not a local
// one: the upstream inval bus already buffers per core, so 1 is sufficient in the
// configurations measured so far. Making it a parameter means raising it is a
// config change rather than a redesign.

module g6lc_inval_retain #(
    parameter type         nline_t = logic,
    parameter int unsigned DEPTH   = 1
) (
    input logic clk_i,
    input logic rst_ni,

    //  Producer side (coherence hub -> L1)
    input  logic   inval_valid_i,
    input  nline_t inval_nline_i,
    output logic   inval_ready_o,

    //  Consumer side: the read-response channel toward HPDCACHE.
    //  resp_valid_i is a REAL read response occupying the channel this cycle.
    input  logic   resp_valid_i,
    input  logic   resp_ready_i,
    output logic   inject_o,
    output nline_t inject_nline_o,

    //  Observation (PMU / bench). Single-cycle pulses.
    output logic evt_injected_o,
    output logic evt_backpressured_o
);

  localparam int unsigned D = (DEPTH < 1) ? 1 : DEPTH;
  localparam int unsigned PTR_W = (D <= 1) ? 1 : $clog2(D);
  localparam int unsigned CNT_W = $clog2(D + 1);

  nline_t             mem_q[D];
  logic [PTR_W-1:0]   wptr_q, rptr_q;
  logic [CNT_W-1:0]   cnt_q;

  logic full, empty, push, pop;

  assign full  = (cnt_q == CNT_W'(D));
  assign empty = (cnt_q == '0);

  //  Honest backpressure: refuse only when there is genuinely no room.
  assign inval_ready_o = ~full;

  //  A real response always wins the channel (contract 3).
  assign inject_o       = ~empty & ~resp_valid_i;
  assign inject_nline_o = mem_q[rptr_q];

  assign push = inval_valid_i & inval_ready_o;
  assign pop  = inject_o & resp_ready_i;

  assign evt_injected_o      = pop;
  assign evt_backpressured_o = inval_valid_i & ~inval_ready_o;

  //  Wrap in the pointer's own width rather than with `%`. The modulo form forced
  //  the increment to be evaluated in 32 bits, which warns (WIDTHEXPAND) on every
  //  configuration where the pointer is narrower. Note: no comment line here may
  //  begin with the word "Verilator" -- it is then parsed as a pragma and the build
  //  fails with "Unknown verilator comment".
  logic [PTR_W-1:0] wptr_next, rptr_next;
  always_comb begin
    wptr_next = (wptr_q == PTR_W'(D - 1)) ? PTR_W'(0) : PTR_W'(wptr_q + 1'b1);
    rptr_next = (rptr_q == PTR_W'(D - 1)) ? PTR_W'(0) : PTR_W'(rptr_q + 1'b1);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wptr_q <= '0;
      rptr_q <= '0;
      cnt_q  <= '0;
      for (int unsigned i = 0; i < D; i++) mem_q[i] <= '0;
    end else begin
      if (push) begin
        mem_q[wptr_q] <= inval_nline_i;
        wptr_q        <= wptr_next;
      end
      if (pop) rptr_q <= rptr_next;
      //  Same-cycle push and pop leave the count unchanged.
      if (push && !pop) cnt_q <= cnt_q + 1'b1;
      else if (pop && !push) cnt_q <= cnt_q - 1'b1;
    end
  end

  //pragma translate_off
  //  Contract 3 as an assertion, since violating it silently drops refills.
  always_ff @(posedge clk_i) begin
    if (rst_ni && inject_o)
      assert (!resp_valid_i)
      else $error("g6lc_inval_retain: injected over a real read response");
  end

  //  The occupancy bound is only a meaningful check when the counter can actually
  //  represent an out-of-range value; at DEPTH=1 it is constant-true and Verilator
  //  says so (CMPCONST). Guarding it keeps the check where it bites without adding
  //  a warning everywhere else.
  if (D > 1) begin : gen_occupancy_check
    always_ff @(posedge clk_i) begin
      if (rst_ni)
        assert (cnt_q <= CNT_W'(D))
        else $error("g6lc_inval_retain: count %0d exceeded depth %0d", cnt_q, D);
    end
  end
  //pragma translate_on

endmodule
