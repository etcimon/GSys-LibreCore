// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Untrusted word-port bound for a reserved-media layout. The trusted
// maintenance port bypasses this guard; it is not selectable by user traffic.
// Flush ownership is independent and must be drained by the enclosing owner.
module g6lc_storamic_store_guard (
  input logic clk_i, rst_ni,
  input logic enable_i,
  input logic [63:0] capacity_bytes_i,
  output logic idle_o, refuse_event_o,
  output logic [2:0] phase_o,
  input logic st_req_i,
  output logic st_gnt_o,
  input logic st_we_i,
  input logic [63:0] st_addr_i, st_wdata_i,
  input logic [7:0] st_be_i,
  output logic st_rvalid_o,
  output logic [63:0] st_rdata_o,
  output logic st_error_o,
  output logic down_req_o,
  input logic down_gnt_i,
  output logic down_we_o,
  output logic [63:0] down_addr_o, down_wdata_o,
  output logic [7:0] down_be_o,
  input logic down_rvalid_i,
  input logic [63:0] down_rdata_i,
  input logic down_error_i
);
  typedef enum logic [2:0] {GIdle, GCheckHi, GCheckLo, GOffer, GWait, GResponse} state_e;
  typedef struct packed {
    state_e state;
    logic enabled, write_word, error, refuse;
    logic [63:0] addr, data, response_data;
    logic [60:0] words;
    logic [7:0] be;
  } control_t;
  control_t q, d;
  assign idle_o = q.state == GIdle && !st_req_i;
  assign st_gnt_o = q.state == GIdle && st_req_i && !down_rvalid_i;
  assign st_rvalid_o = q.state == GResponse;
  assign st_rdata_o = q.response_data;
  assign st_error_o = q.error;
  assign down_req_o = q.state == GOffer;
  assign down_we_o = q.write_word;
  assign down_addr_o = q.addr;
  assign down_wdata_o = q.data;
  assign down_be_o = q.be;
  assign refuse_event_o = q.refuse;
  assign phase_o = q.state;

  always_comb begin
    d = q; d.refuse = 0;
    case (q.state)
      GIdle: if (st_gnt_o) begin
        d.enabled = enable_i; d.words = capacity_bytes_i[63:3];
        d.addr = st_addr_i; d.data = st_wdata_i; d.be = st_be_i;
        d.write_word = st_we_i; d.error = 0; d.response_data = 0; d.state = GCheckHi;
      end
      // Compare aligned word indexes, avoiding an overflowing addr+8. The
      // two stages also keep a full-width comparator off the admission cone.
      GCheckHi: begin
        if (!q.enabled || q.addr[2:0] != 0 || q.addr[63:32] > q.words[60:29]) begin
          d.error = 1; d.refuse = 1; d.state = GResponse;
        end else if (q.addr[63:32] < q.words[60:29]) d.state = GOffer;
        else d.state = GCheckLo;
      end
      GCheckLo: if (q.addr[31:3] < q.words[28:0]) d.state = GOffer;
                  else begin d.error = 1; d.refuse = 1; d.state = GResponse; end
      GOffer: if (down_gnt_i) d.state = GWait;
      GWait: if (down_rvalid_i) begin
        d.error = down_error_i;
        d.response_data = down_error_i ? 64'd0 : down_rdata_i;
        d.state = GResponse;
      end
      GResponse: d.state = GIdle;
      default: begin d.error = 1; d.refuse = 1; d.state = GResponse; end
    endcase
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) q <= '0;
    else q <= d;
  end
endmodule
