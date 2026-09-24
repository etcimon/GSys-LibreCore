// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One sample, one triangle. +x is right and +y is up. The three weights are
// the integer edge functions and sum to the signed area. A zero-area triangle
// misses. A zero weight is inside only on a top or left edge of the CCW
// winding (horizontal directed left, or vertical directed down). Color is
// copied onto the fragment record and is not a function of the triangle.
// Enable=0 elaborates no datapath. This is not a rasterizer and not a surface.

module g6lc_apu_cover
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_cover_req_t req_i,
  output logic frag_valid_o,
  input  logic frag_ready_i,
  output apu_cover_frag_t frag_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign frag_valid_o = 1'b0;
    assign frag_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | frag_ready_i | (|req_i);
  end else begin : gen_on
    typedef enum logic { Idle, Hold } state_e;
    state_e state_q;
    apu_cover_frag_t frag_q, frag_c;

    function automatic logic signed [47:0] edge_at(
      input logic signed [15:0] ax, ay, bx, by, px, py
    );
      logic signed [16:0] dx, dy, rx, ry;
      logic signed [33:0] left, right;
      dx = 17'(bx) - 17'(ax);
      dy = 17'(by) - 17'(ay);
      rx = 17'(px) - 17'(ax);
      ry = 17'(py) - 17'(ay);
      left = 34'(dx) * 34'(ry);
      right = 34'(dy) * 34'(rx);
      return 48'(left) - 48'(right);
    endfunction

    // Top: horizontal, directed left. Left: vertical, directed down.
    function automatic bit top_or_left(
      input logic signed [15:0] ax, ay, bx, by
    );
      logic signed [16:0] dx, dy;
      dx = 17'(bx) - 17'(ax);
      dy = 17'(by) - 17'(ay);
      return (dy == 0 && dx < 0) || (dx == 0 && dy < 0);
    endfunction

    function automatic bit accept_half(
      input logic signed [47:0] w,
      input logic signed [15:0] ax, ay, bx, by
    );
      if (w > 0) return 1'b1;
      if (w < 0) return 1'b0;
      return top_or_left(ax, ay, bx, by);
    endfunction

    function automatic apu_cover_frag_t eval_req(input apu_cover_req_t req);
      logic signed [47:0] area, w0, w1, w2;
      apu_cover_xy_t a, b, c, p;
      eval_req = '0;
      a = req.v0;
      b = req.v1;
      c = req.v2;
      p = req.sample;
      area = edge_at(a.x, a.y, b.x, b.y, c.x, c.y);
      w0 = edge_at(b.x, b.y, c.x, c.y, p.x, p.y);
      w1 = edge_at(c.x, c.y, a.x, a.y, p.x, p.y);
      w2 = edge_at(a.x, a.y, b.x, b.y, p.x, p.y);
      eval_req.w0 = w0;
      eval_req.w1 = w1;
      eval_req.w2 = w2;
      eval_req.area = area;
      eval_req.color = req.color;
      if (area > 0) begin
        eval_req.covered = accept_half(w0, b.x, b.y, c.x, c.y) &&
                           accept_half(w1, c.x, c.y, a.x, a.y) &&
                           accept_half(w2, a.x, a.y, b.x, b.y);
      end else if (area < 0) begin
        eval_req.covered = accept_half(-w0, c.x, c.y, b.x, b.y) &&
                           accept_half(-w1, a.x, a.y, c.x, c.y) &&
                           accept_half(-w2, b.x, b.y, a.x, a.y);
      end else begin
        eval_req.covered = 1'b0;
      end
    endfunction

    assign frag_c = eval_req(req_i);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign frag_valid_o = state_q == Hold;
    assign frag_o = frag_valid_o ? frag_q : apu_cover_frag_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        frag_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          frag_q <= frag_c;
          state_q <= Hold;
        end
        Hold: if (frag_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      frag_valid_o && !frag_ready_i |=> frag_valid_o && $stable(frag_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      frag_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      frag_valid_o |-> frag_o.w0 + frag_o.w1 + frag_o.w2 == frag_o.area);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      frag_valid_o && frag_o.covered |-> frag_o.area != 0);
    `endif
  end
endmodule

module g6lc_apu_cover_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_cover_req_t req_i,
  output logic frag_valid_o,
  input  logic frag_ready_i,
  output apu_cover_frag_t frag_o
);
  g6lc_apu_cover #(.Enable(Enable)) i_dut (.*);
endmodule
