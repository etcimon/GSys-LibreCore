// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: freelist invariants against live `g6lc_freelist`.
// Multi-port rename free/busy/map is covered by `g6lc_ooo_rename.sby`
// (rename embeds its own free vector; this proves the shared freelist module).
//
// Run: sby -f core/ooo/formal/g6lc_ooo_freelist.sby
//      cva6-build verify --formal

module g6lc_ooo_freelist_props #(
    parameter int unsigned PRF_ENTRIES = 16,
    parameter int unsigned PRF_W       = $clog2(PRF_ENTRIES)
) (
    input  logic             clk_i,
    input  logic             rst_ni,
    input  logic             flush_i,
    input  logic             alloc_i,
    input  logic             free_i,
    input  logic [PRF_W-1:0] free_prd_i
);

`ifdef FORMAL
  logic [PRF_W-1:0] alloc_prd_o;
  logic             empty_o;

  g6lc_freelist #(
      .PRF_ENTRIES(PRF_ENTRIES),
      .PRF_W      (PRF_W)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_i,
      .alloc_prd_o,
      .empty_o,
      .free_i,
      .free_prd_i
  );

  // Force a reset in the first cycle. `initial assume (!rst_ni)` is rejected by
  // the slang frontend ("reading net state during design initialization"), and
  // this module is stateful, so the constraint cannot be dropped: without it the
  // solver starts free_q in an arbitrary state and the invariants are trivially
  // violable. Drive it from an initialised register instead.
  logic rst_init_q = 1'b1;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  always_ff @(posedge clk_i) begin
    if (rst_init_q) assume (!rst_ni);
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) assume (free_prd_i < PRF_ENTRIES[PRF_W-1:0]);
  end

  // phys 0 is never returned as an allocation (priority encoder starts at 1).
  // free_q[0] stays free/hardwired after reset and flush.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (alloc_i && !empty_o) assert (alloc_prd_o != '0);
      if (empty_o) assert (alloc_prd_o == '0);
      assert (dut.free_q[0] == 1'b1);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) cover (alloc_i && !empty_o);
  end
`endif

endmodule
