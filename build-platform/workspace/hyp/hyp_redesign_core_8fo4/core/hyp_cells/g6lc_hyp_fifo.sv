// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_hyp_fifo — the hyp8 replacement for the vendor g6lc_fifo_v3 cell.
// Port and parameter list are identical so an instantiation only changes the
// module name. FIFO semantics are preserved; the timing departure is on the
// read path only:
//   * data_o comes from a registered head copy that is refreshed on an
//     accepted pop or a push-into-empty: the popped entry's successor is
//     visible one cycle after the pop (hyp8: +1 pop visibility, rank 4 on
//     the value path — the deep array mux is off the read cone).
//   * With FALL_THROUGH=1 the upstream same-cycle bypass of data_i when
//     empty is kept as one 2:1 mux after the head register, and the upstream
//     empty_o qualification `~(FALL_THROUGH & push_i)` is kept (a single AND
//     gate, not a deep path).
// FPGA_EN / FPGA_ALTERA are accepted for signature compatibility and
// ignored — this cell has a single implementation (no vendor RAM shim).
// testmode_i is accepted for signature compatibility; there is no internal
// clock gate to bypass.

module g6lc_hyp_fifo #(
    parameter bit FALL_THROUGH = 1'b0,  // fifo is in fall-through mode
    parameter bit FPGA_ALTERA = 1'b0,   // accepted, ignored (single impl)
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned DEPTH = 8,
    parameter type dtype = logic [DATA_WIDTH-1:0],
    parameter bit FPGA_EN = 1'b0,       // accepted, ignored (single impl)
    // DO NOT OVERWRITE THIS PARAMETER
    parameter int unsigned ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                  clk_i,       // Clock
    input  logic                  rst_ni,      // Asynchronous reset active low
    input  logic                  flush_i,     // flush the queue
    input  logic                  testmode_i,  // accepted; no clock gate here
    // status flags
    output logic                  full_o,      // queue is full
    output logic                  empty_o,     // queue is empty
    output logic [ADDR_DEPTH-1:0] usage_o,     // fill pointer
    // as long as the queue is not full we can push new data
    input  dtype                  data_i,      // data to push into the queue
    input  logic                  push_i,      // data is valid and can be pushed
    // as long as the queue is not empty we can pop new elements
    output dtype                  data_o,      // output data
    input  logic                  pop_i        // pop head from queue
);

  localparam int unsigned FifoDepth = (DEPTH > 0) ? DEPTH : 1;
  // hyp8: LastIdx is computed in ADDR_DEPTH bits — evaluating
  // `FifoDepth[ADDR_DEPTH-1:0] - 1` in the self-determined context wraps
  // power-of-two depths to '1...1 and the pointers would never wrap.
  localparam logic [ADDR_DEPTH-1:0] LastIdx = ADDR_DEPTH'(FifoDepth - 1);

  if (DEPTH == 0) begin : gen_pass_through
    // degenerate FIFO is a pass-through by contract
    assign empty_o = ~push_i;
    assign full_o  = ~pop_i;
    assign usage_o = '0;
    assign data_o  = data_i;
  end else begin : gen_fifo

    dtype                  mem_q   [FifoDepth];
    logic [ADDR_DEPTH-1:0] rptr_q, wptr_q;
    logic [ADDR_DEPTH:0]   cnt_q;
    dtype                  head_q;

    // status flags from the registered status counter; the fall-through
    // suppression of empty_o on a push is upstream behaviour (one AND gate).
    assign full_o  = (cnt_q == FifoDepth[ADDR_DEPTH:0]);
    assign empty_o = (cnt_q == '0) & ~(FALL_THROUGH & push_i);
    assign usage_o = cnt_q[ADDR_DEPTH-1:0];

    // hyp8: +1 pop visibility (rank 4, value path) — a single 2:1 mux after
    // the registered head copy instead of the whole array mux on data_o.
    assign data_o = (FALL_THROUGH && (cnt_q == '0)) ? data_i : head_q;

    wire push = push_i & ~full_o;
    wire pop  = pop_i  & ~empty_o;
    // a fall-through push+pop on an empty queue bypasses storage entirely:
    // the word is consumed through the data_o mux and is never stored.
    wire bypass = FALL_THROUGH && (cnt_q == '0) && push && pop;
    wire store  = push && !bypass;
    wire take   = pop  && !bypass;

    wire [ADDR_DEPTH-1:0] rptr_next = (rptr_q == LastIdx) ? '0
                                                          : rptr_q + 1'b1;
    wire [ADDR_DEPTH-1:0] wptr_next = (wptr_q == LastIdx) ? '0
                                                          : wptr_q + 1'b1;

    // payload array: no reset (upstream convention; reset cost x depth)
    always_ff @(posedge clk_i) begin
      if (store) mem_q[wptr_q] <= data_i;
    end

    // status + head: async-reset control state
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rptr_q <= '0;
        wptr_q <= '0;
        cnt_q  <= '0;
        head_q <= '0;
      end else if (flush_i) begin
        rptr_q <= '0;
        wptr_q <= '0;
        cnt_q  <= '0;
      end else begin
        if (store) wptr_q <= wptr_next;
        if (take)  rptr_q <= rptr_next;
        cnt_q <= cnt_q + {{ADDR_DEPTH{1'b0}}, store} - {{ADDR_DEPTH{1'b0}}, take};
        // head-copy refresh: on an accepted pop take the successor (for
        // cnt_q==1 with a simultaneous stored push the successor is the
        // arriving word — wptr_q equals rptr_next exactly when cnt_q==1);
        // on a stored push into an empty queue take the arriving word.
        if (take) begin
          if (cnt_q == 1 && store) head_q <= data_i;
          else if (cnt_q > 1)      head_q <= mem_q[rptr_next];
        end else if (store && (cnt_q == '0)) begin
          head_q <= data_i;
        end
      end
    end

  end

endmodule
