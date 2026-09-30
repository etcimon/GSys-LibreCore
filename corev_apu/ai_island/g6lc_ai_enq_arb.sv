// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// ai.enq sideband arbiter: NC cores' held kicks onto the island's one sideband.
//
// A core holds {qid, ticket, desc_ptr} valid until it is granted (the
// coprocessor's ST_ENQ waits on ready). One kick is offered to the island per
// cycle; the grant is round-robin from the pointer past the last accepted
// winner, so no core can be starved by a neighbour that kicks every cycle. The
// island allocates the ticket (g6lc_ai_island_top SbTicketAlloc) and broadcasts
// it; the proposed ticket is forwarded only for the legacy single-producer
// contract. NC == 1 is a wire.

module g6lc_ai_enq_arb #(
    parameter int unsigned NC    = 1,
    parameter int unsigned QidW  = 8,
    parameter int unsigned AddrW = 64
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic [NC-1:0]        valid_i,
    input  logic [NC-1:0][QidW-1:0]  qid_i,
    input  logic [NC-1:0][31:0]      ticket_i,
    input  logic [NC-1:0][AddrW-1:0] ptr_i,
    output logic [NC-1:0]        gnt_o,          // ready to core c = gnt_o[c] & ready_i
    output logic                 valid_o,
    output logic [QidW-1:0]      qid_o,
    output logic [31:0]          ticket_o,
    output logic [AddrW-1:0]     ptr_o,
    input  logic                 ready_i
);
  if (NC == 1) begin : gen_one
    assign gnt_o    = 1'b1;
    assign valid_o  = valid_i[0];
    assign qid_o    = qid_i[0];
    assign ticket_o = ticket_i[0];
    assign ptr_o    = ptr_i[0];
  end else begin : gen_rr
    localparam int unsigned SW = $clog2(NC);
    logic [SW-1:0] rr_q, sel;
    logic          any;
    always_comb begin
      sel = rr_q;
      any = 1'b0;
      for (int unsigned k = 0; k < NC; k++) begin
        automatic int unsigned c = (int'(rr_q) + k) % NC;
        if (!any && valid_i[c]) begin
          sel = SW'(c);
          any = 1'b1;
        end
      end
      gnt_o = '0;
      if (any) gnt_o[sel] = 1'b1;
    end
    assign valid_o  = any;
    assign qid_o    = qid_i[sel];
    assign ticket_o = ticket_i[sel];
    assign ptr_o    = ptr_i[sel];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) rr_q <= '0;
`ifdef G6LC_MUT_ENQ_ARB_FIXED
      // Review mutation: the pointer never rotates (fixed priority). The leaf's
      // starvation check must fail on this build.
      else rr_q <= '0;
`else
      else if (any && ready_i) rr_q <= (int'(sel) == NC - 1) ? '0 : sel + SW'(1);
`endif
    end
  end

  // pragma translate_off
  always_ff @(posedge clk_i) if (rst_ni) begin
    assert ($countones(gnt_o) <= 1) else $error("g6lc_ai_enq_arb: two grants in one cycle");
    assert (!(valid_o && (gnt_o & valid_i) == '0)) else $error("g6lc_ai_enq_arb: offer without a valid requester");
  end
  // pragma translate_on
endmodule
