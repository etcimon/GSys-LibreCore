// hyp8 provenance: REWRITTEN (sv-timing emit at the 8-FO4 budget)
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright 2026 GSys — LibreCore hypothesis core (8-FO4 redesign).
// Description: store buffer commit-queue drain (emit store_if kernel).
//   Program-order write-through issue: the commit head drives the D$
//   request port, retires on data_gnt (or, for CBO ops, on the CBO
//   rvalid handshake with the U7c multi-beat expansion for cbo.zero).
//   The pend push from stb_commit appends one cycle after commit_i, so
//   stores reach memory in commit (program) order.

module stb_drain
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned           DEPTH_COMMIT = 4,
    parameter int unsigned           CBOZ_BEATS   = 1,
    parameter int unsigned           CBOZ_STRIDE  = 8,
    parameter int unsigned           CBOZ_BEAT_W  = (CBOZ_BEATS <= 1) ? 1 : $clog2(CBOZ_BEATS),
    parameter type                   entry_t      = logic,
    parameter type                   cbo_t        = logic,
    parameter type                   dcache_req_i_t = logic,
    parameter type                   dcache_req_o_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    // commit queue state (registered in the wrapper)
    input  entry_t [DEPTH_COMMIT-1:0]      commit_queue_i,
    input  logic [$clog2(DEPTH_COMMIT)-1:0] rd_ptr_i,
    input  logic [$clog2(DEPTH_COMMIT)-1:0] wr_ptr_i,
    input  logic [$clog2(DEPTH_COMMIT):0]  cmt_cnt_i,
    input  logic [CBOZ_BEAT_W-1:0]         cboz_beat_i,
    // staged commit push (stb_commit pend record)
    input  logic                           push_valid_i,
    input  entry_t                         push_entry_i,
    input  logic                           head_mismatch_i,
    input  logic                           stall_st_pending_i,
    // D$ request port
    input  dcache_req_o_t                  req_port_i,
    output dcache_req_i_t                  req_port_o,
    // next-state view (wrapper registers it)
    output entry_t [DEPTH_COMMIT-1:0]      commit_queue_o,
    output logic [$clog2(DEPTH_COMMIT)-1:0] rd_ptr_o,
    output logic [$clog2(DEPTH_COMMIT)-1:0] wr_ptr_o,
    output logic [$clog2(DEPTH_COMMIT):0]  cmt_cnt_o,
    output logic [CBOZ_BEAT_W-1:0]         cboz_beat_o,
    output logic                           commit_ready_o,
    output logic                           no_st_pending_o,
    output logic                           drain_gnt_o   // head grant this cycle (sticky arm)
);

  // static request-port fields (emit verbatim): writes never kill, never
  // tag, and need no response identity — a grant retires the head.
  assign req_port_o.kill_req = 1'b0;
  assign req_port_o.data_we = 1'b1;
  assign req_port_o.tag_valid = 1'b0;
  assign req_port_o.data_id = '0;
  assign req_port_o.address_index =
      commit_queue_i[rd_ptr_i].address[G6LCCfg.DCACHE_INDEX_WIDTH-1:0] +
      G6LCCfg.DCACHE_INDEX_WIDTH'(cboz_beat_i * CBOZ_STRIDE);
  assign req_port_o.address_tag   = commit_queue_i[rd_ptr_i].address[G6LCCfg.DCACHE_TAG_WIDTH     +
                                                                    G6LCCfg.DCACHE_INDEX_WIDTH-1 :
                                                                    G6LCCfg.DCACHE_INDEX_WIDTH];
  assign req_port_o.data_wdata = commit_queue_i[rd_ptr_i].data;
  assign req_port_o.data_wuser = '0;
  assign req_port_o.data_be = commit_queue_i[rd_ptr_i].be;
  assign req_port_o.data_size = commit_queue_i[rd_ptr_i].data_size;

  always_comb begin : store_if
    automatic logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt;
    commit_status_cnt      = cmt_cnt_i;

    commit_ready_o         = (cmt_cnt_i < $bits(cmt_cnt_i)'(DEPTH_COMMIT)) &&
                             !head_mismatch_i;
    no_st_pending_o        = (cmt_cnt_i == 0);

    rd_ptr_o               = rd_ptr_i;
    wr_ptr_o               = wr_ptr_i;
    cboz_beat_o            = cboz_beat_i;
    commit_queue_o         = commit_queue_i;
    drain_gnt_o            = 1'b0;

    req_port_o.data_req    = 1'b0;
    req_port_o.cbo_op      = commit_queue_i[rd_ptr_i].cbo_op;

    // there should be no commit when we are flushing
    // if the entry in the commit queue is valid and not speculative anymore we can issue this instruction
    if (commit_queue_i[rd_ptr_i].valid && !stall_st_pending_i && !commit_queue_i[rd_ptr_i].wait_rvalid) begin
      req_port_o.data_req = 1'b1;
      if (req_port_i.data_gnt) begin
        drain_gnt_o = 1'b1;
        if (commit_queue_i[rd_ptr_i].cbo_op == CBO_NONE || req_port_i.data_rvalid) begin
          // not CBO or rvalid as well -> we can evict it from the commit buffer
          // check for rvalid is technically superfluous, as CBO latency is >= 1 cycle, but check it anyway just to be safe
          commit_queue_o[rd_ptr_i].valid = 1'b0;
          rd_ptr_o = rd_ptr_i + 1'b1;
          commit_status_cnt--;
          cboz_beat_o = '0;
        end else if (commit_queue_i[rd_ptr_i].cbo_op != CBO_NONE) begin
          // CBO and have gotten data grant -> proceed to wait for rvalid
          commit_queue_o[rd_ptr_i].wait_rvalid = 1'b1;
        end
      end
    end

    if (commit_queue_i[rd_ptr_i].valid && commit_queue_i[rd_ptr_i].wait_rvalid)
    begin
      // wait for rvalid, but no need to raise another request / wait for grant
      if (req_port_i.data_rvalid) begin
        // CMO did commit — for a CBO_ZERO entry this is one beat of the
        // drain expansion: clear wait_rvalid and advance to the next beat,
        // or retire the (single) architectural entry after the last beat.
        if (G6LCCfg.RVZiCboz &&
            commit_queue_i[rd_ptr_i].cbo_op == CBO_ZERO &&
            cboz_beat_i != CBOZ_BEAT_W'(CBOZ_BEATS - 1)) begin
          commit_queue_o[rd_ptr_i].wait_rvalid = 1'b0;
          cboz_beat_o = cboz_beat_i + 1'b1;
        end else begin
          // we can evict the entry from the commit buffer
          commit_queue_o[rd_ptr_i].valid = 1'b0;
          rd_ptr_o = rd_ptr_i + 1'b1;
          commit_status_cnt--;
          cboz_beat_o = '0;
        end
      end
    end

    // hyp8: the staged commit push (one cycle after commit_i) appends at
    // the write pointer — program-order store drain preserved.
    if (push_valid_i) begin
      commit_queue_o[wr_ptr_i] = push_entry_i;
      wr_ptr_o = wr_ptr_i + 1'b1;
      commit_status_cnt++;
    end

    cmt_cnt_o = commit_status_cnt;
  end

endmodule
