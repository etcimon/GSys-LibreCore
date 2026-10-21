// Purpose: return-ACK legality register for wt_dcache_wbuffer.
//
// The parent still computes fixup_hold, the fixup candidate, and the
// L1 word-write decision from the snapshot (the same predicates as
// core/cache_subsystem/wt_dcache_wbuffer.sv). This module is the only
// place those decisions become a clock edge.
//
// Callers of the result are inside the parent: TX pop, the L1 word
// write, and the fixup-queue push. wt_dcache uses empty_o / not_ni_o.
// core/load_unit waits on those before a non-idempotent load. An ACK
// that frees the last entry does so one cycle later, so that wait is
// longer, not early. Store retirement itself happens when the store
// enters the buffer, which this edge does not move.
//
// go_q is one cycle, then it drops, unless the word write lost the
// cache port (ack_wr_lost). That retry is the parent's "hold the
// return id" rule. l1_q is the registered "this return writes L1"
// decision, so the write port does not re-read the tag check.

module wt_dcache_wbuffer_leg #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic snap_v_i,
    input  logic fixup_hold_i,
    input  logic ack_wr_lost_i,
    // Candidate, L1 decision, and bytes. Computed in the parent from
    // the live snapshot and captured here.
    input  logic                                     fire_i,
    input  logic                                     l1_i,
    input  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0]      l1_oh_i,
    input  logic [G6LCCfg.PLEN-1:0]                  paddr_i,
    input  logic [(G6LCCfg.XLEN/8)-1:0]              be_i,
    input  logic [G6LCCfg.XLEN-1:0]                  data_i,
    input  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]     user_i,
    output logic                                     go_q,
    output logic                                     fire_q,
    output logic                                     l1_q,
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0]      l1_oh_q,
    output logic [G6LCCfg.PLEN-1:0]                  paddr_q,
    output logic [(G6LCCfg.XLEN/8)-1:0]              be_q,
    output logic [G6LCCfg.XLEN-1:0]                  data_q,
    output logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]     user_q,
    // Push is one cycle after a granted fixup candidate. The payload
    // is the candidate's registers, copied here so a newer return can
    // refill paddr_q without overwriting the word the queue accepts.
    output logic                                     push_q,
    output logic [G6LCCfg.PLEN-1:0]                  push_paddr_q,
    output logic [(G6LCCfg.XLEN/8)-1:0]              push_be_q,
    output logic [G6LCCfg.XLEN-1:0]                  push_data_q,
    output logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]     push_user_q
);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      go_q         <= 1'b0;
      fire_q       <= 1'b0;
      l1_q         <= 1'b0;
      l1_oh_q      <= '0;
      paddr_q      <= '0;
      be_q         <= '0;
      data_q       <= '0;
      user_q       <= '0;
      push_q       <= 1'b0;
      push_paddr_q <= '0;
      push_be_q    <= '0;
      push_data_q  <= '0;
      push_user_q  <= '0;
    end else begin
      go_q   <= snap_v_i && !fixup_hold_i && (!go_q || ack_wr_lost_i);
      fire_q <= fire_i && (!go_q || ack_wr_lost_i);
      l1_q   <= l1_i && (!go_q || ack_wr_lost_i);
      // fire_q / paddr_q on the RHS are this cycle's candidate. A lost
      // grant does not push; the retry keeps the return id.
      push_q <= fire_q && !ack_wr_lost_i;
      if (fire_q && !ack_wr_lost_i) begin
        push_paddr_q <= paddr_q;
        push_be_q    <= be_q;
        push_data_q  <= data_q;
        push_user_q  <= user_q;
      end
      if (fire_i || l1_i) begin
        l1_oh_q <= l1_oh_i;
        paddr_q <= paddr_i;
        be_q    <= be_i;
        data_q  <= data_i;
        user_q  <= user_i;
      end
    end
  end
endmodule
