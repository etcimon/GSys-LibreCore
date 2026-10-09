// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Reusable apu_mp slave model for the 3c-i gate benches.  Backs both
// address domains with word arrays the parent TB pokes hierarchically
// (i_mem.gmem / i_mem.apm): dom=0 -> gmem (guest), dom=1 -> apm
// (aperture).  One in-flight request per port; per-port ready dice and
// response latency are plusarg-controlled:
//   +mp_lat_min=<n>   (default 1)
//   +mp_lat_max=<n>   (default 1)
//   +mp_ready_pct=<n> (default 100 — percentage of cycles ready is up)
// Ready is combinational; a request accepted at cycle T responds at
// T+lat (writes commit at response time — matching the apmem "B beat"
// ordering).  The model never answers twice and never errs; address
// classification/bounds checking is apmem's job upstream.
module tb_apu_mp_mem
  import g6lc_apu_mp_pkg::*;
#(
  parameter int unsigned N   = 3,
  parameter int unsigned GMW = 32'h40000,   // guest words (1 MiB)
  parameter int unsigned APW = 32'h40000,   // aperture words (1 MiB)
  // §12.3 F5: the aperture word range [PWB, PWB+PPW) is the
  // device-private arena; the dense model covers [0,APW) plus that
  // range, addressed through the compressed apix() view
  parameter int unsigned PWB = 0,
  parameter int unsigned PPW = 0
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic [N-1:0]       req_valid_i,
  output logic [N-1:0]       req_ready_o,
  input  apu_mp_req_t [N-1:0] req_i,
  output logic [N-1:0]       rsp_valid_o,
  output apu_mp_rsp_t [N-1:0] rsp_o
);
  // backing stores, 32-bit words; the parent TB reads/writes these
  // directly for tape loads and result checks
  logic [31:0] gmem [GMW];
  logic [31:0] apm  [APW + PPW];

  // compressed aperture index: [0,APW) is the dense low window and
  // [APW,APW+PPW) maps the device-private arena [PWB,PWB+PPW)
  function automatic int unsigned apix(input int unsigned w);
    if (w < APW) return w;
    if (w >= PWB && w < PWB + PPW) return APW + (w - PWB);
    $fatal(1, "aperture word %0d past dense model", w);
    return 0;
  endfunction

  int unsigned lat_min, lat_max, rdy_pct;
  initial begin
    lat_min = 1; lat_max = 1; rdy_pct = 100;
    void'($value$plusargs("mp_lat_min=%d", lat_min));
    void'($value$plusargs("mp_lat_max=%d", lat_max));
    void'($value$plusargs("mp_ready_pct=%d", rdy_pct));
    if (lat_min == 0) lat_min = 1;
    if (lat_max < lat_min) lat_max = lat_min;
    for (int i = 0; i < GMW; i++) gmem[i] = '0;
    for (int i = 0; i < APW + PPW; i++) apm[i] = '0;
  end

  // per-port state: one outstanding per requester
  logic [N-1:0]  pend_q;
  int unsigned   cnt_q  [N];
  apu_mp_req_t   rq_q   [N];
  int unsigned   dice_q [N];

  // combinational ready; the dice register rotates every cycle so a
  // low duty cycle still passes eventually
  always_comb begin
    req_ready_o = '0;
    for (int p = 0; p < N; p++)
      req_ready_o[p] = !pend_q[p] &&
                       (rdy_pct >= 100 || dice_q[p] < rdy_pct);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_q      <= '0;
      rsp_valid_o <= '0;
      rsp_o       <= '{default: '0};
      for (int p = 0; p < N; p++) begin
        cnt_q[p]  <= 0;
        dice_q[p] <= 0;
        rq_q[p]   <= '0;
      end
    end else begin
      rsp_valid_o <= '0;
      for (int p = 0; p < N; p++) begin
        dice_q[p] <= $urandom_range(99);
        if (req_valid_i[p] && req_ready_o[p]) begin
          pend_q[p] <= 1'b1;
          rq_q[p]   <= req_i[p];
          cnt_q[p]  <= lat_min +
                       ((lat_max > lat_min)
                        ? $urandom_range(lat_max - lat_min) : 0);
        end else if (pend_q[p]) begin
          if (cnt_q[p] <= 1) begin
            pend_q[p]      <= 1'b0;
            rsp_valid_o[p] <= 1'b1;
            rsp_o[p].err   <= 1'b0;
            if (rq_q[p].we) begin
              automatic logic [63:0] a = rq_q[p].addr & ~64'h7;
              rsp_o[p].rdata <= '0;
              for (int b = 0; b < 8; b++) begin
                automatic int unsigned byt = int'(a) + b;
                if (rq_q[p].wstrb[b]) begin
                  // dense arrays are smaller than the real windows;
                  // first-fit keeps every session low — a genuine
                  // over-run is a tape/model bug, never wrap it
                  if (rq_q[p].dom) begin
                    apm[apix(byt >> 2)][8*(byt[1:0]) +: 8] <=
                      rq_q[p].wdata[b*8 +: 8];
                  end else begin
                    if ((byt >> 2) >= GMW)
                      $fatal(1, "guest word %0d past dense model",
                             byt >> 2);
                    gmem[byt >> 2][8*(byt[1:0]) +: 8] <=
                      rq_q[p].wdata[b*8 +: 8];
                  end
                end
              end
            end else begin
              automatic logic [63:0] a = rq_q[p].addr & ~64'h7;
              automatic logic [63:0] d = '0;
              for (int b = 0; b < 8; b++) begin
                automatic int unsigned byt = int'(a) + b;
                if (rq_q[p].dom) begin
                  d[b*8 +: 8] = apm[apix(byt >> 2)][8*(byt[1:0]) +: 8];
                end else begin
                  if ((byt >> 2) >= GMW)
                    $fatal(1, "guest word %0d past dense model",
                           byt >> 2);
                  d[b*8 +: 8] = gmem[byt >> 2][8*(byt[1:0]) +: 8];
                end
              end
              rsp_o[p].rdata <= d;
            end
          end else
            cnt_q[p] <= cnt_q[p] - 1;
        end
      end
    end
  end
endmodule
