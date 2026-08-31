// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: the fetch GEOMETRY layer (I12 and the window algebra) over
// the cfg-parameterised pure functions of `g6lc_fetch_pkg`.
//
// This is the configurability contract of core-fetch/SPEC.md s1 and sF stated
// as properties instead of as prose. Every other fetch proof is deliberately
// geometry-free (free inputs, no cfg); this one is the opposite -- it is the
// single place where FETCH_WIDTH / FETCH_ALIGN_BITS / RVC are pinned, and it is
// swept across the legal envelope by the task list in g6lc_fetch_geo.sby.
//
// Why it matters: `win_tag`, `win_base`, `same_win`, `hw_off`, `next_block` and
// `ilen_of` are "the ONLY encoding knowledge in L1-L4" (SPEC s1). If any of them
// disagrees with the others at some width, every layer above inherits the error,
// and the symptom appears as a firmware hang many layers away (P4: the distance
// between a broken promise and its observation is the cost multiplier).
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_geo.sby
//      cva6-build verify --formal

module g6lc_fetch_geo_props #(
    // One point of the geometry envelope. The .sby sweeps these.
    parameter int unsigned FW  = 64,  // FETCH_WIDTH bits
    parameter int unsigned AB  = 3,   // FETCH_ALIGN_BITS = log2(FW/8)
    parameter bit          RVC = 1'b1
) (
    input logic        clk_i,
    input logic        rst_ni,
    input logic [63:0] pc_a,
    input logic [63:0] pc_b,
    input logic [15:0] hw
);

`ifdef FORMAL
  import g6lc_fetch_pkg::*;

  // Build a config that carries only the geometry fields these functions read.
  // Seeded from cva6_cfg_empty so a future field cannot silently arrive as X.
  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c                      = config_pkg::cva6_cfg_empty;
    c.FETCH_WIDTH          = FW;
    c.FETCH_ALIGN_BITS     = AB;
    c.INSTR_PER_FETCH      = RVC ? (FW / 16) : (FW / 32);
    c.LOG2_INSTR_PER_FETCH = $clog2(RVC ? (FW / 16) : (FW / 32));
    c.RVC                  = RVC;
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();
  localparam logic [63:0] WBytes = 64'(FW) / 64'd8;

  logic [63:0] base_a, base_b, tag_a, tag_b, nxt;
  logic [7:0]  off_a;
  logic        same;

  always_comb begin
    base_a = win_base(Cfg, pc_a);
    base_b = win_base(Cfg, pc_b);
    tag_a  = win_tag(Cfg, pc_a);
    tag_b  = win_tag(Cfg, pc_b);
    off_a  = hw_off(Cfg, pc_a);
    nxt    = next_block(Cfg, pc_a);
    same   = same_win(Cfg, pc_a, pc_b);
  end

  // No reset assumption: stateless, combinational implications over free inputs.

  // One host constraint, stated rather than papered over. The window step is
  // address-space arithmetic: at the very top of the 64-bit space
  // `win_base(pc) + W_BYTES` wraps to 0, so forward progress genuinely does not
  // hold for a PC in the final window. The core cannot fetch there -- VLEN is
  // 39 or 64 with the upper bits sign-extended, and no PMA execute region
  // reaches the top of the space -- so the honest move is to exclude that
  // window and keep the strong property, not to weaken the property to
  // accommodate an address the machine cannot produce.
  always_ff @(posedge clk_i) begin
    if (rst_ni) assume (pc_a < (64'hFFFF_FFFF_FFFF_FFFF - WBytes));
  end

  // --- the geometry is self-consistent -------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // A window base is window-aligned, and lands inside its own window.
      assert ((base_a & (WBytes - 64'd1)) == 64'd0);
      assert (win_base(Cfg, base_a) == base_a);
      // Tag and base are two views of the same partition.
      assert ((tag_a == tag_b) == (base_a == base_b));
      // `same_win` IS that partition -- no third definition may drift from it.
      assert (same == (base_a == base_b));
      assert (same == (tag_a == tag_b));
      // An address never leaves its own window downwards.
      assert (base_a <= pc_a);
      assert ((pc_a - base_a) < WBytes);
    end
  end

  // --- I12: the sequential step is exactly one window ----------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (nxt == base_a + WBytes);
      // Strictly forward: a step can never stall or go backwards.
      assert (nxt > pc_a);
      // ...and it lands in the NEXT window, never the same one (the +2 bug
      // class: a step of one instruction instead of one window).
      assert (!same_win(Cfg, pc_a, nxt));
      assert (win_base(Cfg, nxt) == nxt);
      // Stepping is idempotent on the window, not on the offset within it.
      assert (next_block(Cfg, base_a) == nxt);
    end
  end

  // --- halfword cursor stays inside the window -----------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // hw_off indexes halfwords of this window and cannot address past it.
      assert (64'(off_a) < (WBytes / 64'd2));
      // Offset 0 exactly at the base.
      if (pc_a == base_a) assert (off_a == 8'd0);
    end
  end

  // --- ilen is the only encoding knowledge, and it is width-independent ----
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (!RVC) assert (ilen_of(Cfg, hw) == 4);
      if (RVC) assert (ilen_of(Cfg, hw) == (hw[1:0] == 2'b11 ? 4 : 2));
      // rvi_prefix and ilen_of must agree; they are used interchangeably.
      assert (rvi_prefix(hw) == (hw[1:0] == 2'b11));
      if (RVC) assert ((ilen_of(Cfg, hw) == 4) == rvi_prefix(hw));
      // pc_ilen is ilen_of widened; a mismatch would desynchronise the cursor.
      assert (pc_ilen(Cfg, hw) == 64'(ilen_of(Cfg, hw)));
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (same);
      cover (!same);
      cover (off_a != 8'd0);
    end
  end
`endif

endmodule
