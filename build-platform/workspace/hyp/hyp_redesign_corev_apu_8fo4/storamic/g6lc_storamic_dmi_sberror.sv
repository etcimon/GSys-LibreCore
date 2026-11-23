// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Debug System Bus Access error reporting at the DMI boundary.
//
// The vendored debug module (corev_apu/riscv-dbg, an upstream submodule) has
// no bus-error input: an SBA access answered with SLVERR/DECERR completes with
// sbcs.sberror = 0, so a debugger cannot tell a refused access (for instance a
// Storamic window or checkpoint control refusal) from a successful one. The
// submodule is not modified. This shim sits between the DTM and dm_top and
// supplies the missing behaviour of the Debug Specification 0.13 sbcs.sberror
// field for bus errors:
//   - bus_err_i (one pulse per SBA response that carried an error) latches the
//     error; it reads back as sberror = 2 (bad address) in sbcs unless the
//     debug module reports an error of its own;
//   - a write of 1 to sbcs.sberror[1] clears it (W1C), like the real field;
//   - while it is set no new system bus access is started: writes to
//     sbaddress0/sbdata0 and reads of sbdata0, the three SBA triggers, are
//     forwarded as DMI no-ops.
// Every DMI request still gets exactly one response, in order; a small tag
// queue marks which responses are sbcs reads.
// Timing: one flop and a four-entry one-bit queue; the DMI data path gains a
// 3-bit mux on the response and a 2-bit mux on the request op.
module g6lc_storamic_dmi_sberror (
  input  logic          clk_i,
  input  logic          rst_ni,
  // DTM side
  input  logic          dtm_req_valid_i,
  output logic          dtm_req_ready_o,
  input  dm::dmi_req_t  dtm_req_i,
  output logic          dtm_resp_valid_o,
  input  logic          dtm_resp_ready_i,
  output dm::dmi_resp_t dtm_resp_o,
  // debug module side
  output logic          dm_req_valid_o,
  input  logic          dm_req_ready_i,
  output dm::dmi_req_t  dm_req_o,
  input  logic          dm_resp_valid_i,
  output logic          dm_resp_ready_o,
  input  dm::dmi_resp_t dm_resp_i,
  // SBA master response with an error (SLVERR or DECERR), one pulse each
  input  logic          bus_err_i,
  output logic          sberror_o
);
  localparam logic [6:0] AddrSbcs = 7'h38, AddrSbAddr0 = 7'h39, AddrSbData0 = 7'h3C;
  localparam logic [2:0] SbErrBadAddr = 3'd2;
  localparam int unsigned Depth = 4;

  logic err_q;
  logic [Depth-1:0] tag_q;
  logic [$clog2(Depth):0] cnt_q;
  logic [$clog2(Depth)-1:0] rd_q, wr_q;
  logic full, accept, pop, trigger, clear;

  assign sberror_o = err_q;
  assign full = cnt_q == ($clog2(Depth) + 1)'(Depth);
  assign dm_req_valid_o = dtm_req_valid_i && !full;
  assign dtm_req_ready_o = dm_req_ready_i && !full;
  assign accept = dtm_req_valid_i && dtm_req_ready_o;
  assign trigger =
      (dtm_req_i.op == dm::DTM_WRITE &&
       (dtm_req_i.addr == AddrSbAddr0 || dtm_req_i.addr == AddrSbData0)) ||
      (dtm_req_i.op == dm::DTM_READ && dtm_req_i.addr == AddrSbData0);
  assign clear = accept && dtm_req_i.op == dm::DTM_WRITE &&
                 dtm_req_i.addr == AddrSbcs && dtm_req_i.data[13];

  always_comb begin
    dm_req_o = dtm_req_i;
    if (err_q && trigger) dm_req_o.op = dm::DTM_NOP;
  end

  assign dtm_resp_valid_o = dm_resp_valid_i;
  assign dm_resp_ready_o = dtm_resp_ready_i;
  assign pop = dm_resp_valid_i && dtm_resp_ready_i;
  always_comb begin
    dtm_resp_o = dm_resp_i;
    if (err_q && tag_q[rd_q] && cnt_q != '0 && dm_resp_i.data[14:12] == '0)
      dtm_resp_o.data[14:12] = SbErrBadAddr;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      err_q <= 1'b0;
      tag_q <= '0;
      cnt_q <= '0;
      rd_q <= '0;
      wr_q <= '0;
    end else begin
      // A new error wins over a clear in the same cycle.
      if (bus_err_i) err_q <= 1'b1;
      else if (clear) err_q <= 1'b0;
      if (accept) begin
        tag_q[wr_q] <= dtm_req_i.op == dm::DTM_READ && dtm_req_i.addr == AddrSbcs;
        wr_q <= wr_q + 1'b1;
      end
      if (pop && cnt_q != '0) rd_q <= rd_q + 1'b1;
      cnt_q <= cnt_q + ($clog2(Depth) + 1)'(accept) -
               ($clog2(Depth) + 1)'(pop && cnt_q != '0);
    end
  end
endmodule
