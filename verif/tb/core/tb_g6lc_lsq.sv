// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// T6b-3 exit leaf: the LSQ must scope ordering, forwarding, replay and the
// completed-load hold to the allocating op's own hart (LSQ_HART_OWN). The
// architectural smt_mixed_probe cannot reach this seam — stl_data_o is not
// connected in g6lc_ooo_dispatch, so cross-hart leakage only manifests as
// stalls/replays, never as a data mismatch — so the isolation contract is
// checked here where every input is directly drivable.
// G6LC_MUT_LSQ_NO_HART drops the hart tags; every cross-hart scenario must
// then diverge.
module tb_g6lc_lsq;
  function automatic config_pkg::g6lc_cfg_t cfg();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.PLEN = 56;
    c.NrHarts = 2;
    c.NrCommitPorts = 2;
    c.NrWbPorts = 2;
    c.NR_SB_ENTRIES = 64;
    c.TRANS_ID_BITS = 6;
    return c;
  endfunction

  localparam config_pkg::g6lc_cfg_t CFG = cfg();
  localparam int unsigned LD_ENTRIES = 8;
  localparam int unsigned ST_ENTRIES = 8;
  localparam int unsigned NR_ALLOC = 2;
  localparam int unsigned NR_UPDATE = 2;
  localparam int unsigned HID_W = 1;
  localparam int unsigned TID_W = CFG.TRANS_ID_BITS;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [CFG.NR_SB_ENTRIES-1:0] cancelled_mask, sb_live;
  logic [NR_ALLOC-1:0] ld_alloc, st_alloc;
  logic [NR_ALLOC-1:0][TID_W-1:0] alloc_id;
  logic [NR_ALLOC-1:0][HID_W-1:0] alloc_hart;
  logic [NR_ALLOC-1:0][CFG.VLEN-1:0] alloc_pc;
  logic [NR_UPDATE-1:0] addr_valid, addr_is_st, st_data_valid;
  logic [NR_UPDATE-1:0][TID_W-1:0] addr_id, st_data_id;
  logic [NR_UPDATE-1:0][CFG.PLEN-1:0] addr;
  logic [NR_UPDATE-1:0][1:0] addr_size;
  logic [NR_UPDATE-1:0][CFG.XLEN-1:0] st_data;
  logic [CFG.NrWbPorts-1:0] complete_valid, complete_is_st;
  logic [CFG.NrWbPorts-1:0][TID_W-1:0] complete_id;
  logic [CFG.NrCommitPorts-1:0] commit_st;
  logic [CFG.NrCommitPorts-1:0][TID_W-1:0] commit_id;
  logic [TID_W-1:0] commit_ptr;
  logic ld_query;
  logic [CFG.PLEN-1:0] ld_query_addr;
  logic [1:0] ld_query_size;
  logic [TID_W-1:0] ld_query_id;
  logic [HID_W-1:0] ld_query_hart;

  logic ld_full, st_full;
  logic [$clog2(LD_ENTRIES+1)-1:0] ld_free;
  logic [$clog2(ST_ENTRIES+1)-1:0] st_free;
  logic [CFG.NR_SB_ENTRIES-1:0] st_live_mask, st_unresolved_mask;
  logic [CFG.NrHarts-1:0][CFG.NR_SB_ENTRIES-1:0] st_hart_mask;
  logic store_pending, stl_forward, stl_stall, lsq_busy, mem_violation;
  logic [CFG.XLEN-1:0] stl_data;
  logic [TID_W-1:0] mem_violation_id;
  logic [CFG.VLEN-1:0] mem_violation_pc;

  g6lc_lsq #(.G6LCCfg(CFG), .HypCfg(g6lc_hyp_pkg::Hyp8), .LD_ENTRIES(LD_ENTRIES), .ST_ENTRIES(ST_ENTRIES),
             .NR_ALLOC(NR_ALLOC), .NR_UPDATE(NR_UPDATE)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .cancelled_mask_i(cancelled_mask), .sb_live_i(sb_live),
    .phys_valid_i('0), .phys_addr_i('0), .phys_id_i('0), .phys_hart_i('0), .phys_size_i('0),
    .commit_ld_i('0), .mod_valid_i('0), .mod_addr_i('0), .phys_pending_o(), .phys_replay_o(),
    .ld_alloc_i(ld_alloc), .st_alloc_i(st_alloc),
    .alloc_id_i(alloc_id), .alloc_hart_i(alloc_hart), .alloc_pc_i(alloc_pc),
    .ld_full_o(ld_full), .st_full_o(st_full),
    .ld_free_o(ld_free), .st_free_o(st_free),
    .addr_valid_i(addr_valid), .addr_id_i(addr_id), .addr_i(addr),
    .addr_is_st_i(addr_is_st), .addr_size_i(addr_size),
    .st_data_valid_i(st_data_valid), .st_data_id_i(st_data_id),
    .st_data_i(st_data),
    .complete_valid_i(complete_valid), .complete_id_i(complete_id),
    .complete_is_st_i(complete_is_st),
    .commit_st_i(commit_st), .commit_id_i(commit_id),
    .commit_ptr_i(commit_ptr),
    .ld_query_i(ld_query), .ld_query_addr_i(ld_query_addr),
    .ld_query_size_i(ld_query_size), .ld_query_id_i(ld_query_id),
    .ld_query_hart_i(ld_query_hart),
    .st_live_mask_o(st_live_mask), .st_unresolved_mask_o(st_unresolved_mask),
    .st_hart_mask_o(st_hart_mask),
    .store_pending_o(store_pending),
    .stl_forward_o(stl_forward), .stl_data_o(stl_data),
    .stl_stall_o(stl_stall), .lsq_busy_o(lsq_busy),
    .mem_violation_o(mem_violation),
    .mem_violation_id_o(mem_violation_id),
    .mem_violation_pc_o(mem_violation_pc)
  );

  task automatic idle;
    ld_alloc = '0; st_alloc = '0; alloc_id = '0; alloc_hart = '0; alloc_pc = '0;
    addr_valid = '0; addr_id = '0; addr = '0; addr_is_st = '0; addr_size = '0;
    st_data_valid = '0; st_data_id = '0; st_data = '0;
    complete_valid = '0; complete_id = '0; complete_is_st = '0;
    commit_st = '0; commit_id = '0;
    ld_query = 1'b0; ld_query_addr = '0; ld_query_size = '0;
    ld_query_id = '0; ld_query_hart = '0;
  endtask

  task automatic tick;
    @(posedge clk); #2;
  endtask

  task automatic settle;
    #2;
  endtask

  // The verdict outputs (stl_forward/stl_stall/mem_violation) are
  // registered one-cycle pulses several stages after the presenting
  // event; capture them across a bounded wait.
  logic fwd_seen, stall_seen, viol_seen;
  logic [TID_W-1:0] viol_id_seen;
  task automatic wait_verdict;
    fwd_seen = 1'b0; stall_seen = 1'b0; viol_seen = 1'b0;
    viol_id_seen = '0;
    for (int unsigned w = 0; w < 8; w++) begin
      tick();
      if (stl_forward)   fwd_seen   = 1'b1;
      if (stl_stall)     stall_seen = 1'b1;
      if (mem_violation && !viol_seen) begin
        viol_seen    = 1'b1;
        viol_id_seen = mem_violation_id;   // id is only valid on the pulse
      end
    end
    settle();
  endtask

  task automatic do_alloc(input bit is_st, input logic [TID_W-1:0] id,
                          input logic [HID_W-1:0] hart,
                          input logic [CFG.VLEN-1:0] pc);
    idle();
    if (is_st) st_alloc[0] = 1'b1; else ld_alloc[0] = 1'b1;
    alloc_id[0] = id; alloc_hart[0] = hart; alloc_pc[0] = pc;
    tick(); idle(); settle();
  endtask

  task automatic do_addr(input bit is_st, input logic [TID_W-1:0] id,
                         input logic [CFG.PLEN-1:0] a, input logic [1:0] sz);
    idle();
    addr_valid[0] = 1'b1; addr_id[0] = id; addr[0] = a;
    addr_is_st[0] = is_st; addr_size[0] = sz;
    tick(); idle(); settle();
  endtask

  task automatic do_sdata(input logic [TID_W-1:0] id,
                          input logic [CFG.XLEN-1:0] d);
    idle();
    st_data_valid[0] = 1'b1; st_data_id[0] = id; st_data[0] = d;
    tick(); idle(); settle();
  endtask

  task automatic do_query(input logic [TID_W-1:0] id,
                          input logic [HID_W-1:0] hart,
                          input logic [CFG.PLEN-1:0] a, input logic [1:0] sz);
    idle();
    ld_query = 1'b1; ld_query_id = id; ld_query_hart = hart;
    ld_query_addr = a; ld_query_size = sz;
    // The query is captured as an event at the next edge and the
    // answer crosses the E-C-R-V registered stages; present it for one
    // cycle, then wait out the pipeline before the caller checks the
    // registered verdict (6 ticks covers both reduce stage counts).
    tick(); idle(); wait_verdict();
  endtask

  task automatic flush_all;
    // Reuse the synchronous reset to clear both queues between scenarios.
    rst_n = 0; tick(); rst_n = 1; tick(); idle(); settle();
  endtask

  bit negative;

  initial begin
    negative = $test$plusargs("oracle_negative");
    idle();
    cancelled_mask = '0;
    sb_live = '1;          // all tids live: the sim-only SB-live asserts hold
    commit_ptr = '0;
    rst_n = 0;
    repeat (3) @(posedge clk);
    #2 rst_n = 1;
    tick();

    // A: cross-hart unresolved-store stall isolation. hart-0 store id=4 has no
    //    address; a younger hart-1 load (id=6) must NOT stall on it. The mask
    //    self-check follows the query so the mutant dies on LSQ_XHART_STALL,
    //    the same check the inverted oracle exercises.
    do_alloc(1'b1, 6'd4, 1'b0, 64'h0);               // hart-0 store, unresolved
    do_query(6'd6, 1'b1, 56'h1000, 2'b11);
    if (negative ? !stall_seen : stall_seen)
      $fatal(1, "LSQ_XHART_STALL h1-ld vs h0-unresolved-st stall=%b", stl_stall);
    idle(); settle();
    if (!(st_unresolved_mask[4] && st_hart_mask[0][4] && !st_hart_mask[1][4]))
      $fatal(1, "LSQ_MASK_H0 unresolved=%b mask0=%b mask1=%b",
             st_unresolved_mask[4], st_hart_mask[0][4], st_hart_mask[1][4]);

    // B: cross-hart forward isolation. hart-0 store resolves addr+data; the
    //    hart-1 load must not forward from it.
    do_addr(1'b1, 6'd4, 56'h1000, 2'b11);
    do_sdata(6'd4, 64'hdead_beef);
    do_query(6'd6, 1'b1, 56'h1000, 2'b11);
    if (negative ? !fwd_seen : fwd_seen)
      $fatal(1, "LSQ_XHART_FWD h1-ld fwd=%b data=%h", stl_forward, stl_data);
    idle(); settle();
    //    Same-hart control: a hart-1 store id=5 (younger than the hart-0
    //    store? id 5 < 6 still older than load 6) resolved+data must forward.
    do_alloc(1'b1, 6'd5, 1'b1, 64'h0);
    do_addr(1'b1, 6'd5, 56'h1000, 2'b11);
    do_sdata(6'd5, 64'hcafe_f00d);
    do_query(6'd6, 1'b1, 56'h1000, 2'b11);
    if (!(fwd_seen && stl_data == 64'hcafe_f00d))
      $fatal(1, "LSQ_SAMEHART_FWD fwd=%b data=%h want cafe_f00d",
             stl_forward, stl_data);
    idle(); settle();
    flush_all();

    // C: cross-hart violation isolation. hart-1 load id=6 resolved; a hart-0
    //    store id=4 (older, cp=0) resolving an overlapping address must not
    //    flag a memory-order violation on the peer's load.
    do_alloc(1'b1, 6'd4, 1'b0, 64'h0);
    do_alloc(1'b0, 6'd6, 1'b1, 64'h8000_0100);
    do_addr(1'b0, 6'd6, 56'h1000, 2'b11);
    // Present the store's address update: violation scan is combinational.
    idle();
    addr_valid[0] = 1'b1; addr_id[0] = 6'd4; addr[0] = 56'h1000;
    addr_is_st[0] = 1'b1; addr_size[0] = 2'b11;
    tick(); idle(); wait_verdict();
    if (negative ? !viol_seen : viol_seen)
      $fatal(1, "LSQ_XHART_VIOL h0-st-addr vs h1-ld viol=%b id=%0d",
             viol_seen, mem_violation_id);
    tick(); idle(); settle();
    //    Same-hart control: replay with a hart-1 store must flag.
    do_alloc(1'b0, 6'd7, 1'b1, 64'h8000_0200);
    do_addr(1'b0, 6'd7, 56'h2000, 2'b11);
    do_alloc(1'b1, 6'd5, 1'b1, 64'h0);   // hart-1 store, older than ld id=7
    idle();
    addr_valid[0] = 1'b1; addr_id[0] = 6'd5; addr[0] = 56'h2000;
    addr_is_st[0] = 1'b1; addr_size[0] = 2'b11;
    tick(); idle(); wait_verdict();
    if (!viol_seen)
      $fatal(1, "LSQ_SAMEHART_VIOL h1-st-addr vs h1-ld viol=%b", viol_seen);
    tick(); idle(); settle();
    flush_all();

    // D: completed-load hold isolation. hart-1 load id=6 completes while an
    //    older hart-0 store id=4 is still unresolved: the peer store must not
    //    hold the completed load's entry.
    do_alloc(1'b1, 6'd4, 1'b0, 64'h0);   // hart-0 store, unresolved
    do_alloc(1'b0, 6'd6, 1'b1, 64'h8000_0300);
    if (ld_free != LD_ENTRIES - 1)
      $fatal(1, "LSQ_FREE_PRE free=%0d want %0d", ld_free, LD_ENTRIES - 1);
    idle();
    complete_valid[0] = 1'b1; complete_id[0] = 6'd6; complete_is_st[0] = 1'b0;
    tick(); idle(); wait_verdict();
    if (negative ? (ld_free == LD_ENTRIES) : (ld_free != LD_ENTRIES))
      $fatal(1, "LSQ_XHART_HOLD free=%0d want %0d (peer unresolved st)",
             ld_free, LD_ENTRIES);
    flush_all();

    // E: same-hart hold control — same-hart older unresolved store DOES hold.
    do_alloc(1'b1, 6'd4, 1'b1, 64'h0);   // hart-1 store, unresolved
    do_alloc(1'b0, 6'd6, 1'b1, 64'h8000_0400);
    idle();
    complete_valid[0] = 1'b1; complete_id[0] = 6'd6; complete_is_st[0] = 1'b0;
    tick(); idle(); wait_verdict();
    if (ld_free != LD_ENTRIES - 1)
      $fatal(1, "LSQ_SAMEHART_HOLD free=%0d want %0d", ld_free, LD_ENTRIES - 1);
    flush_all();

    // F: youngest-of-two pick (B6 oracle). Two same-hart stores cover one
    //    word, ids 3 and 5, both older than load id=6: the youngest older
    //    store must supply the forward data (DIR=0 pick).
    do_alloc(1'b1, 6'd3, 1'b1, 64'h0);
    do_alloc(1'b1, 6'd5, 1'b1, 64'h0);
    do_addr(1'b1, 6'd3, 56'h3000, 2'b11);
    do_sdata(6'd3, 64'haaaa_1111);
    do_addr(1'b1, 6'd5, 56'h3000, 2'b11);
    do_sdata(6'd5, 64'hbbbb_2222);
    do_query(6'd6, 1'b1, 56'h3000, 2'b11);
    if (!(fwd_seen && stl_data == 64'hbbbb_2222))
      $fatal(1, "LSQ_YOUNGEST_PICK fwd=%b data=%h want bbbb_2222",
             fwd_seen, stl_data);
    idle(); settle();
    flush_all();

    // G: oldest-of-two violators (B6 DIR=1 oracle). hart-1 loads 6 and 7
    //    are both resolved on one word; older store id=5 (same hart)
    //    presenting its address must flag the OLDEST violating load (6).
    do_alloc(1'b0, 6'd6, 1'b1, 64'h8000_0500);
    do_alloc(1'b0, 6'd7, 1'b1, 64'h8000_0600);
    do_addr(1'b0, 6'd6, 56'h4000, 2'b11);
    do_addr(1'b0, 6'd7, 56'h4000, 2'b11);
    do_alloc(1'b1, 6'd5, 1'b1, 64'h0);
    idle();
    addr_valid[0] = 1'b1; addr_id[0] = 6'd5; addr[0] = 56'h4000;
    addr_is_st[0] = 1'b1; addr_size[0] = 2'b11;
    tick(); idle(); wait_verdict();
    if (!(viol_seen && viol_id_seen == 6'd6))
      $fatal(1, "LSQ_OLDEST_VIOL viol=%b id=%0d want 6",
             viol_seen, viol_id_seen);
    idle(); settle();
    flush_all();

    $display("LSQ_HART_PASS");
    $finish;
  end
endmodule
