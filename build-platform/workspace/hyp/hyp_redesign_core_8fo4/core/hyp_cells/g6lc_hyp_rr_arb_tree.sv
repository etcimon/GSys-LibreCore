// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_hyp_rr_arb_tree — the hyp8 replacement for the vendor rr_arb_tree
// cell. Port and parameter list are identical so an instantiation only
// changes the module name.
//
// hyp8: +1 arbitration latency (rank 4, value path), full throughput. The
// cell is a 2-entry queue arbiter:
//   capture side — can_capture comes from the registered occupancy only;
//   the grant is computed combinationally from the live request vector and
//   the round-robin base (as in the vendor cell); gnt_o is a one-cycle pulse
//   per captured request and does not depend on gnt_i. A request must stay
//   asserted until granted (AxiVldRdy semantics).
//   output side — the presented head (data_o/idx_o) never changes until
//   gnt_i, so LockIn holds by construction; a handshake pops the head.
// FairArb controls the round-robin pointer advance on CAPTURE; ExtPrio takes
// the base from rr_i and keeps no pointer state; flush_i empties the queue
// (and rr_q when not ExtPrio).

module g6lc_hyp_rr_arb_tree #(
    parameter int unsigned NumIn      = 64,
    parameter int unsigned DataWidth  = 32,
    parameter type         DataType   = logic [DataWidth-1:0],
    parameter bit          ExtPrio    = 1'b0,
    parameter bit          AxiVldRdy  = 1'b0,
    parameter bit          LockIn     = 1'b0,
    parameter bit          FairArb    = 1'b1,
    parameter int unsigned IdxWidth   = (NumIn > 32'd1) ? unsigned'($clog2(NumIn)) : 32'd1,
    parameter type         idx_t      = logic [IdxWidth-1:0]
) (
    input  logic                clk_i,
    input  logic                rst_ni,
    input  logic                flush_i,
    input  idx_t                rr_i,
    input  logic    [NumIn-1:0] req_i,
    output logic    [NumIn-1:0] gnt_o,
    input  DataType [NumIn-1:0] data_i,
    output logic                req_o,
    input  logic                gnt_i,
    output DataType             data_o,
    output idx_t                idx_o
);

  // degenerate case: pass through, unchanged from the vendor cell
  if (NumIn == unsigned'(1)) begin : gen_pass_through
    assign req_o    = req_i[0];
    assign gnt_o[0] = gnt_i;
    assign data_o   = data_i[0];
    assign idx_o    = '0;
  end else begin : gen_arbiter

    // grant one-hot: rotate req so that `base` is bit 0, take the lowest
    // set bit, rotate back. Same priority rule as the vendor cell.
    function automatic logic [NumIn-1:0] grant_from(input logic [NumIn-1:0] req,
                                                    input idx_t            base);
      logic [2*NumIn-1:0] wide_rot, wide_gnt;
      logic [NumIn-1:0]   rot, lowest;
      wide_rot = {req, req} >> base;
      rot      = wide_rot[NumIn-1:0];
      lowest   = rot & (~rot + 1'b1);
      wide_gnt = {lowest, lowest} << base;
      return wide_gnt[2*NumIn-1 -: NumIn];
    endfunction

    function automatic idx_t idx_of(input logic [NumIn-1:0] onehot);
      idx_t r = '0;
      for (int unsigned i = 0; i < NumIn; i++)
        if (onehot[i]) r = idx_t'(i);
      return r;
    endfunction

    idx_t                 rr_q;
    logic    [1:0]        occ_q;                    // queue occupancy 0..2
    DataType              qdata_q [2];
    idx_t                 qidx_q  [2];

    wire idx_t                base     = ExtPrio ? rr_i : rr_q;
    wire logic [NumIn-1:0]    gnt_vec  = grant_from(req_i, base);
    wire idx_t                gnt_idx  = idx_of(gnt_vec);
    // capture while the queue is not full — registered occupancy only
    wire logic                can_capture = (occ_q < 2);
    wire logic                capture     = can_capture & (|req_i);
    wire logic                head_pop    = (occ_q != 0) & gnt_i;

    // gnt_o pulses for exactly the cycle a request is captured; it does not
    // depend on gnt_i, so a held request cannot double-transfer.
    assign gnt_o  = can_capture ? gnt_vec : '0;
    assign req_o  = (occ_q != 0);
    assign data_o = qdata_q[0];
    assign idx_o  = qidx_q[0];

    // FairArb: after a capture the base moves to the next requester after
    // the granted index (re-arbitrate req_i with the granted one masked);
    // unfair mode just advances by one; ExtPrio keeps no pointer.
    wire logic [NumIn-1:0] next_vec = grant_from(req_i & ~gnt_vec,
                                                 idx_t'(gnt_idx + 1'b1));
    wire idx_t next_base = (req_i & ~gnt_vec) != '0 ? idx_of(next_vec)
                                                   : idx_t'(gnt_idx + 1'b1);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        occ_q    <= '0;
        qdata_q  <= '{'0, '0};
        qidx_q   <= '{'0, '0};
        rr_q     <= '0;
      end else if (flush_i) begin
        occ_q <= '0;
        if (!ExtPrio) rr_q <= '0;
      end else begin
        unique case ({capture, head_pop})
          // pop only: shift entry 1 down
          2'b01: begin
            occ_q       <= occ_q - 1'b1;
            qdata_q[0]  <= qdata_q[1];
            qidx_q[0]   <= qidx_q[1];
          end
          // capture only: occupancy grows; entry lands via capture_tail below
          2'b10: occ_q <= occ_q + 1'b1;
          // capture + pop: head leaves, new entry fills the slot the head
          // vacated — occupancy unchanged
          2'b11: begin
            qdata_q[0] <= qdata_q[1];
            qidx_q[0]  <= qidx_q[1];
          end
          default: ;
        endcase

        if (capture) begin
          qdata_q[capture_tail(occ_q, head_pop)] <= data_i[gnt_idx];
          qidx_q [capture_tail(occ_q, head_pop)] <= gnt_idx;
          if (!ExtPrio) begin
            rr_q <= FairArb ? next_base : idx_t'(gnt_idx + 1'b1);
          end
        end
      end
    end

    // write slot for a captured entry: tail index, accounting for a
    // simultaneous head pop which frees slot 0 first (shift happens first)
    function automatic int unsigned capture_tail(input logic [1:0] occ,
                                                 input logic        pop);
      return pop ? occ - 1 : occ;
    endfunction

  end

endmodule
