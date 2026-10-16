// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Loop-walk fixtures (ALGORITHMS-EXPERTS A101): the three serial-walk idioms
// the LoopRewrite pass replaces with exact parallel forms, plus a module that
// is already parallel and must be left alone (low FO4 is not lost).
module loop_walks (
    input  logic        clk_i, rst_ni,
    input  logic [31:0] free_i, hit_i, ok_i,
    input  logic [4:0]  after_i, ip_i,
    output logic [4:0]  pick_o, cnt_o,
    output logic        found_o,
    output logic [31:0] mask_o
);
  logic [4:0]  pick_d, cnt_d;
  logic        found_d;
  logic [31:0] mask_d;

  // FindFirst, `pick == '0` guard form (lower bound 1: physical 0 is reserved).
  always_comb begin
    pick_d = '0;
    for (int unsigned i = 1; i < 32; i++) begin
      if (free_i[i] && pick_d == '0) pick_d = 5'(i);
    end
  end

  // FindFirst, flag form.
  always_comb begin
    found_d = 1'b0;
    for (int unsigned i = 0; i < 32; i++) begin
      if (hit_i[i] && !found_d) begin
        found_d = 1'b1;
      end
    end
  end

  // CondCount.
  always_comb begin
    cnt_d = '0;
    for (int unsigned k = 0; k < 31; k++) begin
      if (ok_i[k] && hit_i[k]) cnt_d = cnt_d + 1'b1;
    end
  end

  // RingWalk: the scoreboard cancel window.
  always_comb begin
    logic [4:0] cid;
    mask_d = '0;
    cid = after_i;
    for (int unsigned k = 0; k < 32; k++) begin
      if (cid == ip_i) break;
      if (ok_i[cid]) mask_d[cid] = 1'b1;
      cid = cid + 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pick_o <= '0; cnt_o <= '0; found_o <= 1'b0; mask_o <= '0;
    end else begin
      pick_o <= pick_d; cnt_o <= cnt_d; found_o <= found_d; mask_o <= mask_d;
    end
  end
endmodule

// Already parallel: nothing here is a walk; the pass must leave it untouched.
module loop_walks_parallel (
    input  logic        clk_i, rst_ni,
    input  logic [31:0] free_i, ok_i,
    output logic [4:0]  pick_o, cnt_o,
    output logic [31:0] copy_o
);
  logic [31:0] lowest;
  logic [4:0]  pick_d, cnt_d;
  logic [31:0] copy_d;
  always_comb begin
    lowest = free_i & (~free_i + 1'b1);
    pick_d = '0;
    for (int unsigned i = 0; i < 32; i++) if (lowest[i]) pick_d = pick_d | 5'(i);
    cnt_d = 5'($countones(ok_i));
    for (int unsigned i = 0; i < 32; i++) copy_d[i] = ok_i[i] & free_i[i];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin pick_o <= '0; cnt_o <= '0; copy_o <= '0; end
    else begin pick_o <= pick_d; cnt_o <= cnt_d; copy_o <= copy_d; end
  end
endmodule
