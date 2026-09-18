// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_axi_2to1_mux — response ownership for the core/Ara AXI mux.
//
// This mux merges the Ara vector unit's AXI (slv0) and the core's own memory
// port (slv1) onto the single NoC port under CVA6_ARA_ATTACH. It locks to one
// master at a time and carries no ID remapping, which is sound only while the
// lock is held for the WHOLE transaction. The contract tested here:
//
//   * every response beat reaches the master that issued the request, and
//   * the lock is not released while a response is still owed.
//
// Ownership is decided by construction, not by inspecting the DUT: the memory
// model answers a read with data derived from the requester's own id, and each
// slave port checks the beats it receives against the id IT issued. A beat that
// arrives at the wrong port is therefore a hard failure, not a warning.
//
// `timescale matches the other uncore benches.

`timescale 1ns/1ps

module tb_g6lc_axi_2to1_mux;
  import g6lc_l2_tb_pkg::*;

  // Cycles between AR acceptance and the first R beat. Any real memory has
  // latency; the defect this bench targets needs only latency > 0.
  parameter int unsigned MEM_LATENCY = 6;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  req_t  s0_req, s1_req, m_req;
  resp_t s0_resp, s1_resp, m_resp;

  int unsigned errors = 0;
  int unsigned s0_beats = 0, s1_beats = 0;
  bit negative;
  int scenario;

  // Injected-error control. The first version of this bench had +oracle_negative
  // merely require errors != 0, which a correct DUT can never produce — so the
  // "control" only proved the harness complains when asked to find an error that
  // is not there. It never showed that the ID comparison is what catches a
  // misroute. Flipping the OBSERVED id under negative perturbs the observation,
  // exactly as the snoop-filter bench does, so a correct DUT must fail the check.
  id_t neg_id_flip;
  assign neg_id_flip = negative ? '1 : '0;

  g6lc_axi_2to1_mux #(.axi_req_t(req_t), .axi_resp_t(resp_t)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .slv0_req_i(s0_req), .slv0_resp_o(s0_resp),
      .slv1_req_i(s1_req), .slv1_resp_o(s1_resp),
      .mst_req_o(m_req), .mst_resp_i(m_resp)
  );

  // ---- memory model -------------------------------------------------------
  // One outstanding read, answered after MEM_LATENCY cycles. The payload is a
  // function of the accepted id, so a misrouted beat is detectable.
  typedef struct packed { logic busy; id_t id; int unsigned left; int unsigned wait_n; } rd_t;
  rd_t rd;
  logic b_pend = 1'b0;
  id_t  b_id = '0;

  function automatic data_t payload(input id_t id, input int unsigned beat);
    payload = {32'hA5A50000 + 32'(id), 32'h1000 + 32'(beat)};
  endfunction

  always_comb begin
    m_resp = '0;
    m_resp.ar_ready = !rd.busy;
    m_resp.aw_ready = !b_pend;
    m_resp.w_ready  = 1'b1;
    if (rd.busy && rd.wait_n == 0) begin
      m_resp.r_valid = 1'b1;
      m_resp.r.id    = rd.id;
      m_resp.r.data  = payload(rd.id, rd.left);
      m_resp.r.last  = (rd.left == 0);
      m_resp.r.resp  = '0;
    end
    if (b_pend) begin
      m_resp.b_valid = 1'b1;
      m_resp.b.id    = b_id;
      m_resp.b.resp  = '0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd <= '0; b_pend <= 1'b0; b_id <= '0;
    end else begin
      if (!rd.busy && m_req.ar_valid && m_resp.ar_ready) begin
        rd.busy <= 1'b1; rd.id <= m_req.ar.id;
        rd.left <= int'(m_req.ar.len); rd.wait_n <= MEM_LATENCY;
      end else if (rd.busy && rd.wait_n != 0) begin
        rd.wait_n <= rd.wait_n - 1;
      end else if (rd.busy && m_req.r_ready) begin
        if (rd.left == 0) rd.busy <= 1'b0;
        else              rd.left <= rd.left - 1;
      end
      if (!b_pend && m_req.aw_valid && m_resp.aw_ready) begin
        b_pend <= 1'b1; b_id <= m_req.aw.id;
      end else if (b_pend && m_req.b_ready) begin
        b_pend <= 1'b0;
      end
    end
  end

  // ---- per-port response checkers ----------------------------------------
  // Each port records the id it issued; a beat carrying any other id, or a beat
  // arriving with nothing outstanding, is a misrouted response.
  id_t s0_id = '0, s1_id = '0;
  bit  s0_out = 1'b0, s1_out = 1'b0;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (s0_resp.r_valid && s0_req.r_ready) begin
        s0_beats <= s0_beats + 1;
        if (!s0_out) begin
          errors <= errors + 1;
          $display("MUX_R_ORPHAN port=0 id=%0d", s0_resp.r.id);
        end else if ((s0_resp.r.id ^ neg_id_flip) !== s0_id ||
                     s0_resp.r.data !== payload(s0_id, 0)) begin
          errors <= errors + 1;
          // Print the COMPARED id, not the raw one: under +oracle_negative the
          // observed id is deliberately flipped, and printing the raw value made
          // the control's output read "got_id=3 want_id=3", i.e. like a false alarm.
          $display("MUX_R_MISROUTED port=0 got_id=%0d want_id=%0d data=%h",
                   s0_resp.r.id ^ neg_id_flip, s0_id, s0_resp.r.data);
        end
      end
      if (s1_resp.r_valid && s1_req.r_ready) begin
        s1_beats <= s1_beats + 1;
        if (!s1_out) begin
          errors <= errors + 1;
          $display("MUX_R_ORPHAN port=1 id=%0d", s1_resp.r.id);
        end else if ((s1_resp.r.id ^ neg_id_flip) !== s1_id ||
                     s1_resp.r.data !== payload(s1_id, 0)) begin
          errors <= errors + 1;
          $display("MUX_R_MISROUTED port=1 got_id=%0d want_id=%0d data=%h",
                   s1_resp.r.id ^ neg_id_flip, s1_id, s1_resp.r.data);
        end
      end
    end
  end

  task automatic idle_ports;
    s0_req = '0; s1_req = '0;
    s0_req.r_ready = 1'b1; s0_req.b_ready = 1'b1;
    s1_req.r_ready = 1'b1; s1_req.b_ready = 1'b1;
  endtask

  // Offer a single-beat read on one port and hold it until accepted.
  task automatic read_on(input bit port, input int unsigned id);
    if (port) begin
      s1_req.ar_valid = 1'b1; s1_req.ar = '0;
      s1_req.ar.id = id_t'(id); s1_req.ar.addr = 64'h8000 + 64'(id) * 64;
      s1_req.ar.len = '0; s1_req.ar.size = 3'd3; s1_req.ar.burst = 2'b01;
      s1_id = id_t'(id); s1_out = 1'b1;
      while (!(s1_req.ar_valid && s1_resp.ar_ready)) @(negedge clk);
      @(negedge clk); s1_req.ar_valid = 1'b0;
    end else begin
      s0_req.ar_valid = 1'b1; s0_req.ar = '0;
      s0_req.ar.id = id_t'(id); s0_req.ar.addr = 64'h9000 + 64'(id) * 64;
      s0_req.ar.len = '0; s0_req.ar.size = 3'd3; s0_req.ar.burst = 2'b01;
      s0_id = id_t'(id); s0_out = 1'b1;
      while (!(s0_req.ar_valid && s0_resp.ar_ready)) @(negedge clk);
      @(negedge clk); s0_req.ar_valid = 1'b0;
    end
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    scenario = 0;
    void'($value$plusargs("scenario=%d", scenario));
    idle_ports();
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    case (scenario)
      // The core (port 1) has a read outstanding when the other master offers
      // its own request. Releasing the lock before the response returns hands
      // the core's data to the vector unit.
      0: begin
        read_on(1'b1, 3);
        // The other master now wants the bus. It must not receive port 1's data.
        read_on(1'b0, 5);
        // Drain: both reads must complete on their own ports.
        repeat (MEM_LATENCY * 6 + 40) @(negedge clk);
        if (s1_beats == 0) begin
          errors = errors + 1;
          $display("MUX_R_LOST port=1 never received its beat");
        end
        if (s0_beats == 0) begin
          errors = errors + 1;
          $display("MUX_R_LOST port=0 never received its beat");
        end
      end
      // Same shape with the roles swapped, so the result cannot depend on which
      // port holds priority.
      1: begin
        read_on(1'b0, 7);
        read_on(1'b1, 9);
        repeat (MEM_LATENCY * 6 + 40) @(negedge clk);
        if (s0_beats == 0 || s1_beats == 0) begin
          errors = errors + 1;
          $display("MUX_R_LOST s0=%0d s1=%0d", s0_beats, s1_beats);
        end
      end
      // Sequential, non-overlapping traffic: the uncontended case must keep
      // working, so a fix cannot simply block the second master forever.
      2: begin
        read_on(1'b1, 2);
        repeat (MEM_LATENCY + 12) @(negedge clk);
        read_on(1'b0, 4);
        repeat (MEM_LATENCY + 12) @(negedge clk);
        if (s0_beats != 1 || s1_beats != 1) begin
          errors = errors + 1;
          $display("MUX_SEQ s0=%0d s1=%0d", s0_beats, s1_beats);
        end
      end
      default: $fatal(1, "MUX_SCENARIO");
    endcase

    if (negative) begin
      // Expected-failure convention, matching the L2 and snoop-filter reviews: a
      // negative trial must FAIL with a distinct token, so the control does not
      // depend on the simulator's $finish exit status.
      if (errors == 0) $fatal(1, "MUX_NEGATIVE_NOT_DETECTED");
      $fatal(1, "MUX_NEGATIVE_CAUGHT %0d", errors);
    end
    if (errors != 0) $fatal(1, "MUX_ERRORS %0d", errors);
    $display("MUX_METRICS scenario=%0d s0_beats=%0d s1_beats=%0d",
             scenario, s0_beats, s1_beats);
    $display("RTL_REVIEW_PASS mux scenario=%0d", scenario);
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "MUX_TIMEOUT");
  end

endmodule
