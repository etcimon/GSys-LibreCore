// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Port-identical wrappers for the side-by-side harness / bounded miter
// (sb_miter_super is the elaboration top for the yosys miter flow).
module sb_wrap_new
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg),
    localparam type cbo_t = logic [7:0],
    localparam type dcache_req_i_t = struct packed {
      logic [G6LCCfg.DCACHE_INDEX_WIDTH-1:0] address_index;
      logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
      logic [G6LCCfg.XLEN-1:0]               data_wdata;
      logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]  data_wuser;
      logic                                  data_req;
      logic                                  data_we;
      logic [(G6LCCfg.XLEN/8)-1:0]           data_be;
      logic [1:0]                            data_size;
      logic [G6LCCfg.DcacheIdWidth-1:0]      data_id;
      logic                                  kill_req;
      logic                                  tag_valid;
      cbo_t                                  cbo_op;
    },
    localparam type dcache_req_o_t = struct packed {
      logic                                 data_gnt;
      logic                                 data_rvalid;
      logic [G6LCCfg.DcacheIdWidth-1:0]     data_rid;
      logic [G6LCCfg.XLEN-1:0]              data_rdata;
      logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] data_ruser;
    }
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // full flush: drop all speculative stores
    // FSE S4: younger-only cancel (SB cancelled TIDs); does not touch commit queue
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Scoreboard issued mask: an OoO speculative entry is a reservation whose
    // scoreboard slot must still be live (assertion only)
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_live_i,
    input logic stall_st_pending_i,  // Stall issuing non-speculative request
    output logic         no_st_pending_o, // non-speculative queue is empty (e.g.: everything is committed to the memory hierarchy)
    output logic         store_buffer_empty_o, // there is no store pending in neither the speculative unit or the non-speculative queue

    input  logic [11:0]  page_offset_i,         // load VA/PA[11:0] (always available)
    // R3a: full load paddr when DTLB has translated; required for exact STQ match.
    input  logic [G6LCCfg.PLEN-1:0] load_paddr_i,
    input  logic                    load_paddr_valid_i,
    // U5.4 OoO program-order keys. A store may only be observed by a load that
    // follows it in program order, and stores must reach memory in that order.
    // Index order is not age once scoreboard slots are reused, so age is the
    // circular trans_id distance from the oldest live instruction. Both inputs
    // are inert when OoOEn is 0.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] load_trans_id_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_trans_id_i,
    // T6b-4b: the scoreboard reclaim pointer — the oldest live slot. This is
    // the program-age anchor for the speculative queue's circular ordering;
    // commit_trans_id_i stays the *committing* tid (port-0 slot) for the
    // head-match gate below. Aliases commit_trans_id_i under legacy order.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
    // N1d: the commit head is an unpublished load (phys_pending — it needs
    // this LSU to make progress). A speculative-queue stall can only clear
    // through commit, so holding a younger load on it is a circular wait;
    // release it and let the LSQ phys_replay scan arbitrate any true alias
    // when the released load publishes its physical address. Constant 0
    // unless the OoO physical-tracking policy (COH_OOO) is live.
    input  logic                          head_phys_pending_i,
    // T6b: hart of the querying load. Under OoO multi-hart a load forwards
    // only from its OWN hart's speculative stores; a peer hart's store is not
    // visible until commit. Constant-0 otherwise (single hart / in-order).
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] load_hart_i,
    // R3a cont.13: D$ write buffer empty — sticky [11:0] match must outlive
    // STQ→wbuffer handoff so post-return loads of *nextoffset see the store.
    input  logic                    dcache_wbuffer_empty_i,
    output logic         page_offset_matches_o, // hazard: stall load until STQ drains / forward
    // T33: the live match comes from the SPECULATIVE queue only (no committed
    // entry, no sticky drain window). Such a store can only leave after every
    // older instruction retires, so a load parked on it in WAIT_PAGE_OFFSET
    // must not hold the load unit against an older load -- the load unit
    // replays it instead (see load_unit.sv).
    output logic         page_offset_spec_only_o,
    // R3a: store→load data forward (byte-merge, oldest→youngest). When a load's
    // BE is fully covered, the load unit may complete without a D$ request.
    output logic                              st_fwd_valid_o,
    output logic [G6LCCfg.XLEN-1:0]           st_fwd_data_o,
    output logic [(G6LCCfg.XLEN/8)-1:0]       st_fwd_be_o,

    input logic commit_i,  // commit the instruction which was placed there most recently
    output logic commit_ready_o,  // commit queue is ready to accept another commit request
    output logic ready_o,  // the store queue is ready to accept a new request
                           // it is only ready if it can unconditionally commit the instruction, e.g.:
                           // the commit buffer needs to be empty
    input logic valid_i,  // this is a valid store
    input  logic         valid_without_flush_i, // just tell if the address is valid which we are current putting and do not take any further action

    input  logic [G6LCCfg.PLEN-1:0]  paddr_i,         // physical address of store which needs to be placed in the queue
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i, // scoreboard tid (FSE S4 younger cancel)
    // T6b: hart of the arriving store, recorded on its speculative entry.
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] st_hart_i,
    output logic [G6LCCfg.PLEN-1:0] rvfi_mem_paddr_o,
    input logic [G6LCCfg.XLEN-1:0] data_i,  // data which is placed in the queue
    input logic [(G6LCCfg.XLEN/8)-1:0] be_i,  // byte enable in
    input logic [1:0] data_size_i,  // type of request we are making (e.g.: bytes to write)
    input cbo_t cbo_op_i,  // type of cache block operation

    // D$ interface
    input  dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o
);
  logic [G6LCCfg.PLEN-1:0] paddr_raw;
  store_buffer #(.G6LCCfg(G6LCCfg), .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t), .cbo_t(cbo_t)) u (.rvfi_mem_paddr_o(paddr_raw), .*);
  // the head slot's address is don't-care while the speculative queue is
  // empty (stale data of an invalid slot); compare it only when live
  assign rvfi_mem_paddr_o = (u.speculative_status_cnt_q != '0) ? paddr_raw : '0;
  // Sample acceptance at the clock edge. ready_o describes next-state
  // capacity, so a legal final-slot push can deassert it in this cycle.
  always_ff @(posedge clk_i) if (rst_ni) begin
    assume (!commit_i || (u.speculative_status_cnt_q != '0 && !flush_i &&
                         u.commit_status_cnt_q < u.DEPTH_COMMIT));
    assume (!valid_i || u.speculative_status_cnt_q < u.DEPTH_SPEC);
  end
endmodule
module sb_wrap_old
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg),
    localparam type cbo_t = logic [7:0],
    localparam type dcache_req_i_t = struct packed {
      logic [G6LCCfg.DCACHE_INDEX_WIDTH-1:0] address_index;
      logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
      logic [G6LCCfg.XLEN-1:0]               data_wdata;
      logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]  data_wuser;
      logic                                  data_req;
      logic                                  data_we;
      logic [(G6LCCfg.XLEN/8)-1:0]           data_be;
      logic [1:0]                            data_size;
      logic [G6LCCfg.DcacheIdWidth-1:0]      data_id;
      logic                                  kill_req;
      logic                                  tag_valid;
      cbo_t                                  cbo_op;
    },
    localparam type dcache_req_o_t = struct packed {
      logic                                 data_gnt;
      logic                                 data_rvalid;
      logic [G6LCCfg.DcacheIdWidth-1:0]     data_rid;
      logic [G6LCCfg.XLEN-1:0]              data_rdata;
      logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] data_ruser;
    }
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // full flush: drop all speculative stores
    // FSE S4: younger-only cancel (SB cancelled TIDs); does not touch commit queue
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Scoreboard issued mask: an OoO speculative entry is a reservation whose
    // scoreboard slot must still be live (assertion only)
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_live_i,
    input logic stall_st_pending_i,  // Stall issuing non-speculative request
    output logic         no_st_pending_o, // non-speculative queue is empty (e.g.: everything is committed to the memory hierarchy)
    output logic         store_buffer_empty_o, // there is no store pending in neither the speculative unit or the non-speculative queue

    input  logic [11:0]  page_offset_i,         // load VA/PA[11:0] (always available)
    // R3a: full load paddr when DTLB has translated; required for exact STQ match.
    input  logic [G6LCCfg.PLEN-1:0] load_paddr_i,
    input  logic                    load_paddr_valid_i,
    // U5.4 OoO program-order keys. A store may only be observed by a load that
    // follows it in program order, and stores must reach memory in that order.
    // Index order is not age once scoreboard slots are reused, so age is the
    // circular trans_id distance from the oldest live instruction. Both inputs
    // are inert when OoOEn is 0.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] load_trans_id_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_trans_id_i,
    // T6b-4b: the scoreboard reclaim pointer — the oldest live slot. This is
    // the program-age anchor for the speculative queue's circular ordering;
    // commit_trans_id_i stays the *committing* tid (port-0 slot) for the
    // head-match gate below. Aliases commit_trans_id_i under legacy order.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
    // N1d: the commit head is an unpublished load (phys_pending — it needs
    // this LSU to make progress). A speculative-queue stall can only clear
    // through commit, so holding a younger load on it is a circular wait;
    // release it and let the LSQ phys_replay scan arbitrate any true alias
    // when the released load publishes its physical address. Constant 0
    // unless the OoO physical-tracking policy (COH_OOO) is live.
    input  logic                          head_phys_pending_i,
    // T6b: hart of the querying load. Under OoO multi-hart a load forwards
    // only from its OWN hart's speculative stores; a peer hart's store is not
    // visible until commit. Constant-0 otherwise (single hart / in-order).
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] load_hart_i,
    // R3a cont.13: D$ write buffer empty — sticky [11:0] match must outlive
    // STQ→wbuffer handoff so post-return loads of *nextoffset see the store.
    input  logic                    dcache_wbuffer_empty_i,
    output logic         page_offset_matches_o, // hazard: stall load until STQ drains / forward
    // T33: the live match comes from the SPECULATIVE queue only (no committed
    // entry, no sticky drain window). Such a store can only leave after every
    // older instruction retires, so a load parked on it in WAIT_PAGE_OFFSET
    // must not hold the load unit against an older load -- the load unit
    // replays it instead (see load_unit.sv).
    output logic         page_offset_spec_only_o,
    // R3a: store→load data forward (byte-merge, oldest→youngest). When a load's
    // BE is fully covered, the load unit may complete without a D$ request.
    output logic                              st_fwd_valid_o,
    output logic [G6LCCfg.XLEN-1:0]           st_fwd_data_o,
    output logic [(G6LCCfg.XLEN/8)-1:0]       st_fwd_be_o,

    input logic commit_i,  // commit the instruction which was placed there most recently
    output logic commit_ready_o,  // commit queue is ready to accept another commit request
    output logic ready_o,  // the store queue is ready to accept a new request
                           // it is only ready if it can unconditionally commit the instruction, e.g.:
                           // the commit buffer needs to be empty
    input logic valid_i,  // this is a valid store
    input  logic         valid_without_flush_i, // just tell if the address is valid which we are current putting and do not take any further action

    input  logic [G6LCCfg.PLEN-1:0]  paddr_i,         // physical address of store which needs to be placed in the queue
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i, // scoreboard tid (FSE S4 younger cancel)
    // T6b: hart of the arriving store, recorded on its speculative entry.
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] st_hart_i,
    output logic [G6LCCfg.PLEN-1:0] rvfi_mem_paddr_o,
    input logic [G6LCCfg.XLEN-1:0] data_i,  // data which is placed in the queue
    input logic [(G6LCCfg.XLEN/8)-1:0] be_i,  // byte enable in
    input logic [1:0] data_size_i,  // type of request we are making (e.g.: bytes to write)
    input cbo_t cbo_op_i,  // type of cache block operation

    // D$ interface
    input  dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o
);
  logic [G6LCCfg.PLEN-1:0] paddr_raw;
  store_buffer_old #(.G6LCCfg(G6LCCfg), .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t), .cbo_t(cbo_t)) u (.rvfi_mem_paddr_o(paddr_raw), .*);
  // the head slot's address is don't-care while the speculative queue is
  // empty (stale data of an invalid slot); compare it only when live
  assign rvfi_mem_paddr_o = (u.speculative_status_cnt_q != '0) ? paddr_raw : '0;
  // Same clocked contract as sb_wrap_new; no post-edge assertion on inputs
  // that have just been consumed.
  always_ff @(posedge clk_i) if (rst_ni) begin
    assume (!commit_i || (u.speculative_status_cnt_q != '0 && !flush_i &&
                         u.commit_status_cnt_q < u.DEPTH_COMMIT));
    assume (!valid_i || u.speculative_status_cnt_q < u.DEPTH_SPEC);
  end
endmodule
module sb_miter_super
  import g6lc_core_pkg::*;
();
  sb_wrap_new u_new ();
  sb_wrap_old u_old ();
endmodule
