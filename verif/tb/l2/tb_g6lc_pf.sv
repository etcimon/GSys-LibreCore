// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_pf — response-ownership contract for g6lc_server_prefetcher.
//
// The prefetcher injects its own AR under a reserved id and absorbs the
// matching R burst. The properties that matter at this seam are ownership
// properties, not prefetch accuracy:
//   * a demand burst is never consumed by the prefetch absorb path, whatever
//     id it carries,
//   * a demand read that cannot alias the reserved id is not held off while a
//     prefetch is outstanding,
//   * no prefetch is injected while an upstream read already owns the
//     reserved id.
//
// Upstream data is checked against an independent reference function. The
// injected-prefetch count is derived as (downstream ARs - upstream ARs), so it
// never depends on the DUT's own id decisions.

`timescale 1ns/1ps

`ifdef L2TB_SYNTH
module g6lc_pf_fixture
  import g6lc_l2_tb_pkg::*;
#(
  parameter int unsigned NR_STREAMS  = 4,
  parameter int unsigned PF_DISTANCE = 2,
  parameter int unsigned LINE_BYTES  = 64
)(
  input  logic  clk_i, rst_ni,
  input  req_t  up_req_i,
  output resp_t up_resp_o,
  output req_t  dn_req_o,
  input  resp_t dn_resp_i,
  output logic  pf_issue_o, pf_train_o
);
  g6lc_server_prefetcher #(
    .Enable(1'b1), .NR_STREAMS(NR_STREAMS), .PF_DISTANCE(PF_DISTANCE),
    .LINE_BYTES(LINE_BYTES), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
    .AXI_ID_WIDTH(IDW), .AXI_USER_WIDTH(UW), .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) i_pf (
    .clk_i, .rst_ni, .up_req_i, .up_resp_o, .dn_req_o, .dn_resp_i,
    .pf_issue_o, .pf_train_o
  );
endmodule
`endif

module tb_g6lc_pf;
  import g6lc_l2_tb_pkg::*;

  parameter int unsigned NR_STREAMS  = 4;
  parameter int unsigned PF_DISTANCE = 2;
  parameter int unsigned LINE_BYTES  = 64;
  parameter int unsigned MEM_LATENCY = 6;

  localparam id_t PF_ID = '1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  req_t  up_req;
  resp_t up_resp;
  req_t  dn_req;
  resp_t dn_resp;
  logic  pf_issue, pf_train;

  g6lc_server_prefetcher #(
      .Enable        (1'b1),
      .NR_STREAMS    (NR_STREAMS),
      .PF_DISTANCE   (PF_DISTANCE),
      .LINE_BYTES    (LINE_BYTES),
      .AXI_ADDR_WIDTH(AW),
      .AXI_DATA_WIDTH(DW),
      .AXI_ID_WIDTH  (IDW),
      .AXI_USER_WIDTH(UW),
      .axi_req_t     (req_t),
      .axi_resp_t    (resp_t)
  ) dut (
      .clk_i    (clk),
      .rst_ni   (rst_n),
      .up_req_i (up_req),
      .up_resp_o(up_resp),
      .dn_req_o (dn_req),
      .dn_resp_i(dn_resp),
      .pf_issue_o(pf_issue),
      .pf_train_o(pf_train)
  );

  // ---- independent reference memory ---------------------------------------
  function automatic data_t reference_word(input addr_t a);
    return data_t'((a >> 3) * 64'h9E37_79B9_7F4A_7C15 ^ 64'h5DEE_CE6B_1357_0F0F);
  endfunction

  // ---- downstream memory: in-order multi-outstanding read service --------
  localparam int RD_DEPTH = 16;
  typedef struct packed {
    addr_t       addr;
    id_t         id;
    logic [7:0]  len;
    int unsigned beat;
    int unsigned delay_cycles;
  } read_job_t;
  read_job_t jobs[RD_DEPTH];
  int unsigned rd_head = 0, rd_tail = 0, rd_count = 0;
  int unsigned mem_ar_count = 0;
  logic memory_hold = 1'b0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dn_resp <= '0;
      rd_head = 0; rd_tail = 0; rd_count = 0;
      mem_ar_count = 0;
      for (int i = 0; i < RD_DEPTH; i++) jobs[i] = '0;
    end else begin
      automatic bit take_ar = dn_req.ar_valid && dn_resp.ar_ready;
      for (int i = 0; i < RD_DEPTH; i++)
        if (jobs[i].delay_cycles != 0) jobs[i].delay_cycles--;
      if (!dn_resp.r_valid || dn_req.r_ready) begin
        dn_resp.r_valid <= 1'b0;
        if (rd_count != 0 && jobs[rd_head].delay_cycles == 0 && !memory_hold) begin
          dn_resp.r_valid <= 1'b1;
          dn_resp.r.id    <= jobs[rd_head].id;
          dn_resp.r.resp  <= axi_pkg::RESP_OKAY;
          dn_resp.r.data  <= reference_word(jobs[rd_head].addr +
                                            addr_t'(jobs[rd_head].beat * 8));
          dn_resp.r.last  <= (jobs[rd_head].beat == int'(jobs[rd_head].len));
          if (jobs[rd_head].beat == int'(jobs[rd_head].len)) begin
            rd_head = (rd_head + 1) % RD_DEPTH; rd_count--;
          end else jobs[rd_head].beat++;
        end
      end
      if (take_ar) begin
        if (rd_count >= RD_DEPTH) $fatal(1, "PF_MEMORY_OVERFLOW");
        jobs[rd_tail] = '{addr: dn_req.ar.addr, id: dn_req.ar.id,
                          len: dn_req.ar.len, beat: 0, delay_cycles: MEM_LATENCY};
        rd_tail = (rd_tail + 1) % RD_DEPTH; rd_count++;
        mem_ar_count++;
      end
      dn_resp.ar_ready <= (rd_count < RD_DEPTH);
    end
  end

  assert property (@(posedge clk) disable iff (!rst_n)
      dn_req.ar_valid && !dn_resp.ar_ready |=> dn_req.ar_valid && $stable(dn_req.ar))
      else $fatal(1, "PF_DN_AR_STABILITY");
  assert property (@(posedge clk) disable iff (!rst_n)
      up_resp.r_valid && !up_req.r_ready |=> up_resp.r_valid && $stable(up_resp.r))
      else $fatal(1, "PF_UP_R_STABILITY");

  // ---- upstream request driver / independent scoreboard -------------------
  typedef struct {
    id_t         id;
    addr_t       addr;
    int unsigned len;
  } stim_t;

  stim_t pending[$];
  stim_t expected[16][32];
  int unsigned exp_head[16], exp_tail[16], beats_seen[16];
  int unsigned requested = 0, completed = 0, up_ar_count = 0;
  bit negative;
  int scenario;

  function automatic int unsigned pf_extra();
    return mem_ar_count - up_ar_count;
  endfunction

  task automatic push(input id_t id, input addr_t a, input int unsigned len);
    stim_t s;
    s.id = id; s.addr = a; s.len = len;
    pending.push_back(s);
    requested++;
  endtask

  stim_t s;
  initial begin
    up_req = '0;
    up_req.r_ready = 1'b1;
    @(posedge rst_n);
    forever begin
      @(negedge clk);
      if (pending.size() != 0) begin
        s = pending[0];
        up_req.ar_valid = 1'b1;
        up_req.ar.id    = s.id;
        up_req.ar.addr  = s.addr;
        up_req.ar.len   = 8'(s.len);
        up_req.ar.size  = 3'd3;
        up_req.ar.burst = 2'b01;
        up_req.ar.cache = 4'hf;
        do @(posedge clk); while (!up_resp.ar_ready);
        if (exp_tail[s.id] >= 32) $fatal(1, "PF_EXPECTED_CAPACITY");
        expected[s.id][exp_tail[s.id]] = s;
        exp_tail[s.id]++;
        up_ar_count++;
        void'(pending.pop_front());
        @(negedge clk);
        up_req.ar_valid = 1'b0;
      end
    end
  end

  always_ff @(posedge clk) if (rst_n) begin
    if (up_resp.r_valid && up_req.r_ready) begin
      automatic id_t rid = up_resp.r.id;
      automatic data_t want;
      if (exp_head[rid] >= exp_tail[rid]) $fatal(1, "PF_UNEXPECTED_ID id=%0d", rid);
      want = reference_word(expected[rid][exp_head[rid]].addr +
                            addr_t'(beats_seen[rid] * 8));
      if (negative) want ^= 64'd1;
      if (up_resp.r.data !== want)
        $fatal(1, "PF_DATA id=%0d beat=%0d got=%h want=%h",
               rid, beats_seen[rid], up_resp.r.data, want);
      if (up_resp.r.last !== (beats_seen[rid] == expected[rid][exp_head[rid]].len))
        $fatal(1, "PF_LAST id=%0d beat=%0d", rid, beats_seen[rid]);
      if (up_resp.r.last) begin
        completed++; exp_head[rid]++; beats_seen[rid] = 0;
      end else beats_seen[rid]++;
    end
  end

  task automatic wait_done(input int unsigned limit = 2000);
    int unsigned guard = 0;
    while (completed != requested && guard < limit) begin
      @(posedge clk); guard++;
    end
    if (guard >= limit) $fatal(1, "PF_TIMEOUT completed=%0d of %0d", completed, requested);
  endtask

  task automatic wait_prefetch(input int unsigned limit = 200);
    int unsigned guard = 0;
    while (pf_extra() == 0 && guard < limit) begin
      @(posedge clk); guard++;
    end
    if (guard >= limit) $fatal(1, "PF_NOT_ISSUED");
  endtask

  initial begin
    scenario = 0;
    for (int i = 0; i < 16; i++) begin
      exp_head[i] = 0; exp_tail[i] = 0; beats_seen[i] = 0;
    end
    negative = $test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d", scenario));
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    case (scenario)
      // Trained stream injects a prefetch that is absorbed here, and no
      // upstream burst is disturbed.
      0: begin
        push(4'd2, 64'h8000, 0); wait_done();
        push(4'd2, 64'h8040, 0); wait_done();
        push(4'd2, 64'h8080, 0); wait_done();
        repeat (60) @(negedge clk);
        if (pf_extra() == 0) $fatal(1, "PF_NOT_ISSUED");
        if (completed != requested) $fatal(1, "PF_UPSTREAM_LOST");
      end
      // A demand burst under the reserved id must not be consumed by the
      // prefetch absorb path.
      1: begin
        memory_hold = 1'b1;
        push(4'd2, 64'h9000, 0);
        push(4'd2, 64'h9040, 0);
        wait_prefetch();
        push(PF_ID, 64'ha000, 0);
        repeat (20) @(negedge clk);
        memory_hold = 1'b0;
        wait_done();
      end
      // A demand read that cannot alias the reserved id is not held off while
      // a prefetch is outstanding.
      2: begin
        memory_hold = 1'b1;
        push(4'd2, 64'hb000, 0);
        push(4'd2, 64'hb040, 0);
        wait_prefetch();
        push(4'd3, 64'hc000, 0);
        repeat (25) @(negedge clk);
        if (up_ar_count != 3) $fatal(1, "PF_DEMAND_BLOCKED accepted=%0d", up_ar_count);
        memory_hold = 1'b0;
        wait_done();
      end
      // No prefetch may be injected while an upstream read owns the reserved
      // id: its response would be indistinguishable from the demand burst.
      3: begin
        memory_hold = 1'b1;
        push(PF_ID, 64'hd000, 0);
        push(PF_ID, 64'hd040, 0);
        repeat (40) @(negedge clk);
        if (pf_extra() != 0) $fatal(1, "PF_ID_COLLIDE extra=%0d", pf_extra());
        memory_hold = 1'b0;
        wait_done();
        repeat (40) @(negedge clk);
      end
      default: $fatal(1, "PF_SCENARIO");
    endcase

    $display("PF_METRICS scenario=%0d dn_ar=%0d up_ar=%0d extra=%0d responses=%0d",
             scenario, mem_ar_count, up_ar_count, pf_extra(), completed);
    $display("RTL_REVIEW_PASS pf scenario=%0d", scenario);
    $finish;
  end

  initial begin
    #500us;
    $fatal(1, "PF_WATCHDOG");
  end

endmodule
