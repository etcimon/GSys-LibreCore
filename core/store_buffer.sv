// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 25.04.2017
// Description: Store queue persists store requests and pushes them to memory
//              if they are no longer speculative


module store_buffer
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg        = config_pkg::cva6_cfg_empty,
    parameter type                   dcache_req_i_t = logic,
    parameter type                   dcache_req_o_t = logic,
    parameter type                   cbo_t          = logic
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // full flush: drop all speculative stores
    // FSE S4: younger-only cancel (SB cancelled TIDs); does not touch commit queue
    input logic [CVA6Cfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    input logic stall_st_pending_i,  // Stall issuing non-speculative request
    output logic         no_st_pending_o, // non-speculative queue is empty (e.g.: everything is committed to the memory hierarchy)
    output logic         store_buffer_empty_o, // there is no store pending in neither the speculative unit or the non-speculative queue

    input  logic [11:0]  page_offset_i,         // load VA/PA[11:0] (always available)
    // R3a: full load paddr when DTLB has translated; required for exact STQ match.
    input  logic [CVA6Cfg.PLEN-1:0] load_paddr_i,
    input  logic                    load_paddr_valid_i,
    // R3a cont.13: D$ write buffer empty — sticky [11:0] match must outlive
    // STQ→wbuffer handoff so post-return loads of *nextoffset see the store.
    input  logic                    dcache_wbuffer_empty_i,
    output logic         page_offset_matches_o, // hazard: stall load until STQ drains / forward
    // R3a: store→load data forward (byte-merge, oldest→youngest). When a load's
    // BE is fully covered, the load unit may complete without a D$ request.
    output logic                              st_fwd_valid_o,
    output logic [CVA6Cfg.XLEN-1:0]           st_fwd_data_o,
    output logic [(CVA6Cfg.XLEN/8)-1:0]       st_fwd_be_o,

    input logic commit_i,  // commit the instruction which was placed there most recently
    output logic commit_ready_o,  // commit queue is ready to accept another commit request
    output logic ready_o,  // the store queue is ready to accept a new request
                           // it is only ready if it can unconditionally commit the instruction, e.g.:
                           // the commit buffer needs to be empty
    input logic valid_i,  // this is a valid store
    input  logic         valid_without_flush_i, // just tell if the address is valid which we are current putting and do not take any further action

    input  logic [CVA6Cfg.PLEN-1:0]  paddr_i,         // physical address of store which needs to be placed in the queue
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_i, // scoreboard tid (FSE S4 younger cancel)
    output logic [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr_o,
    input logic [CVA6Cfg.XLEN-1:0] data_i,  // data which is placed in the queue
    input logic [(CVA6Cfg.XLEN/8)-1:0] be_i,  // byte enable in
    input logic [1:0] data_size_i,  // type of request we are making (e.g.: bytes to write)
    input cbo_t cbo_op_i,  // type of cache block operation

    // D$ interface
    input  dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o
);

  // FSE S1: speculative/commit queue depths.
  // DeepSpecEn=0 → legacy ariane_pkg::DEPTH_SPEC/COMMIT (4) for netlist identity.
  // DeepSpecEn=1 → next power-of-two of MaxOutstandingStores (capped 16).
  function automatic int unsigned fse_next_pow2(input int unsigned n);
    if (n <= 1) return 1;
    if (n <= 2) return 2;
    if (n <= 4) return 4;
    if (n <= 8) return 8;
    if (n <= 16) return 16;
    return 32;
  endfunction
  localparam int unsigned DEPTH_SPEC = CVA6Cfg.DeepSpecEn
      ? fse_next_pow2(
            (CVA6Cfg.MaxOutstandingStores < 4) ? 4 :
            (CVA6Cfg.MaxOutstandingStores > 16) ? 16 : CVA6Cfg.MaxOutstandingStores)
      : int'(ariane_pkg::DEPTH_SPEC);
  localparam int unsigned DEPTH_COMMIT = CVA6Cfg.DeepSpecEn
      ? fse_next_pow2(
            (CVA6Cfg.MaxOutstandingStores < 4) ? 4 :
            (CVA6Cfg.MaxOutstandingStores > 8) ? 8 : CVA6Cfg.MaxOutstandingStores)
      : int'(ariane_pkg::DEPTH_COMMIT);

  // the store queue has two parts:
  // 1. Speculative queue
  // 2. Commit queue which is non-speculative, e.g.: the store will definitely happen.
  struct packed {
    logic [CVA6Cfg.PLEN-1:0] address;
    logic [CVA6Cfg.XLEN-1:0] data;
    logic [(CVA6Cfg.XLEN/8)-1:0] be;
    logic [1:0] data_size;
    cbo_t cbo_op;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;  // FSE S4: for younger-only cancel
    logic valid;  // this entry is valid, we need this for checking if the address offset matches
    logic wait_rvalid;  // need to wait for rvalid...
  }
      speculative_queue_n[DEPTH_SPEC-1:0],
      speculative_queue_q[DEPTH_SPEC-1:0],
      commit_queue_n[DEPTH_COMMIT-1:0],
      commit_queue_q[DEPTH_COMMIT-1:0];

  // keep a status count for both buffers
  logic [$clog2(DEPTH_SPEC):0] speculative_status_cnt_n, speculative_status_cnt_q;
  logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt_n, commit_status_cnt_q;
  // Speculative queue
  logic [$clog2(DEPTH_SPEC)-1:0] speculative_read_pointer_n, speculative_read_pointer_q;
  logic [$clog2(DEPTH_SPEC)-1:0] speculative_write_pointer_n, speculative_write_pointer_q;
  // Commit Queue
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_read_pointer_n, commit_read_pointer_q;
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_write_pointer_n, commit_write_pointer_q;

  assign store_buffer_empty_o = (speculative_status_cnt_q == 0) & no_st_pending_o;
  // ----------------------------------------
  // Speculative Queue - Core Interface
  // ----------------------------------------
  always_comb begin : core_if
    automatic logic [$clog2(DEPTH_SPEC):0] speculative_status_cnt;
    speculative_status_cnt      = speculative_status_cnt_q;

    // default assignments
    speculative_read_pointer_n  = speculative_read_pointer_q;
    speculative_write_pointer_n = speculative_write_pointer_q;
    speculative_queue_n         = speculative_queue_q;
    // LSU interface
    // we are ready to accept a new entry and the input data is valid
    // (skip if this TID is already cancelled — FSE S4)
    if (valid_i && !cancelled_mask_i[trans_id_i]) begin
      speculative_queue_n[speculative_write_pointer_q].address = paddr_i;
      speculative_queue_n[speculative_write_pointer_q].data = data_i;
      speculative_queue_n[speculative_write_pointer_q].be = be_i;
      speculative_queue_n[speculative_write_pointer_q].data_size = data_size_i;
      speculative_queue_n[speculative_write_pointer_q].valid = 1'b1;
      speculative_queue_n[speculative_write_pointer_q].cbo_op = cbo_op_i;
      speculative_queue_n[speculative_write_pointer_q].trans_id = trans_id_i;
      speculative_queue_n[speculative_write_pointer_q].wait_rvalid = 1'b0;
      // advance the write pointer
      speculative_write_pointer_n = speculative_write_pointer_q + 1'b1;
      speculative_status_cnt++;
    end

    // evict the current entry out of this queue, the commit queue will thankfully take it and commit it
    // to the memory hierarchy
    if (commit_i) begin
      // invalidate
      speculative_queue_n[speculative_read_pointer_q].valid = 1'b0;
      // advance the read pointer
      speculative_read_pointer_n = speculative_read_pointer_q + 1'b1;
      speculative_status_cnt--;
    end

    speculative_status_cnt_n = speculative_status_cnt;

    // FSE S4: younger-only cancel — keep older stores, drop cancelled TIDs.
    // Snapshot then rewrite dense [0 .. live) so pointers match status_cnt.
    if (|cancelled_mask_i && !flush_i) begin
      automatic logic [$clog2(DEPTH_SPEC)-1:0] src, dst;
      automatic logic [$clog2(DEPTH_SPEC):0] live, old_cnt;
      automatic logic [DEPTH_SPEC-1:0][CVA6Cfg.PLEN-1:0] a_addr;
      automatic logic [DEPTH_SPEC-1:0][CVA6Cfg.XLEN-1:0] a_data;
      automatic logic [DEPTH_SPEC-1:0][(CVA6Cfg.XLEN/8)-1:0] a_be;
      automatic logic [DEPTH_SPEC-1:0][1:0] a_sz;
      automatic logic [DEPTH_SPEC-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] a_tid;
      automatic logic [DEPTH_SPEC-1:0] a_wr;
      automatic cbo_t a_cbo[DEPTH_SPEC];
      old_cnt = speculative_status_cnt_n;
      live = '0;
      dst  = '0;
      a_addr = '0;
      a_data = '0;
      a_be   = '0;
      a_sz   = '0;
      a_tid  = '0;
      a_wr   = '0;
      for (int unsigned i = 0; i < DEPTH_SPEC; i++) a_cbo[i] = cbo_t'('0);
      for (int unsigned k = 0; k < DEPTH_SPEC; k++) begin
        if (k < unsigned'(old_cnt)) begin
          src = speculative_read_pointer_n + $clog2(DEPTH_SPEC)'(k);
          if (speculative_queue_n[src].valid &&
              !cancelled_mask_i[speculative_queue_n[src].trans_id]) begin
            a_addr[dst] = speculative_queue_n[src].address;
            a_data[dst] = speculative_queue_n[src].data;
            a_be[dst]   = speculative_queue_n[src].be;
            a_sz[dst]   = speculative_queue_n[src].data_size;
            a_cbo[dst]  = speculative_queue_n[src].cbo_op;
            a_tid[dst]  = speculative_queue_n[src].trans_id;
            a_wr[dst]   = speculative_queue_n[src].wait_rvalid;
            dst  = dst + 1'b1;
            live = live + 1'b1;
          end
        end
      end
      for (int unsigned k = 0; k < DEPTH_SPEC; k++) begin
        speculative_queue_n[k].valid = 1'b0;
        if (k < unsigned'(live)) begin
          speculative_queue_n[k].address     = a_addr[k];
          speculative_queue_n[k].data        = a_data[k];
          speculative_queue_n[k].be          = a_be[k];
          speculative_queue_n[k].data_size   = a_sz[k];
          speculative_queue_n[k].cbo_op      = a_cbo[k];
          speculative_queue_n[k].trans_id    = a_tid[k];
          speculative_queue_n[k].wait_rvalid = a_wr[k];
          speculative_queue_n[k].valid       = 1'b1;
        end
      end
      speculative_read_pointer_n  = '0;
      speculative_write_pointer_n = dst;
      speculative_status_cnt_n    = live;
    end

    // when we flush evict the speculative stores
    if (flush_i) begin
      // reset all valid flags
      for (int unsigned i = 0; i < DEPTH_SPEC; i++) speculative_queue_n[i].valid = 1'b0;

      speculative_write_pointer_n = speculative_read_pointer_q;
      // also reset the status count
      speculative_status_cnt_n = 'b0;
    end

    // we are ready if the speculative and the commit queue have a space left
    ready_o = (speculative_status_cnt_n < (DEPTH_SPEC)) || commit_i;
  end

  // ----------------------------------------
  // Commit Queue - Memory Interface
  // ----------------------------------------

  // we will never kill a request in the store buffer since we already know that the translation is valid
  // e.g.: a kill request will only be necessary if we are not sure if the requested memory address will result in a TLB fault
  assign req_port_o.kill_req = 1'b0;
  assign req_port_o.data_we = 1'b1;  // we will always write in the store queue
  assign req_port_o.tag_valid = 1'b0;

  // we do not require an acknowledgement for writes, thus we do not need to identify uniquely the responses
  assign req_port_o.data_id = '0;
  // those signals can directly be output to the memory
  assign req_port_o.address_index = commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
  // if we got a new request we already saved the tag from the previous cycle
  assign req_port_o.address_tag   = commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_TAG_WIDTH     +
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH-1 :
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH];
  assign req_port_o.data_wdata = commit_queue_q[commit_read_pointer_q].data;
  assign req_port_o.data_wuser = '0;
  assign req_port_o.data_be = commit_queue_q[commit_read_pointer_q].be;
  assign req_port_o.data_size = commit_queue_q[commit_read_pointer_q].data_size;

  assign rvfi_mem_paddr_o = speculative_queue_q[speculative_read_pointer_q].address;

  always_comb begin : store_if
    automatic logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt;
    commit_status_cnt      = commit_status_cnt_q;

    commit_ready_o         = (commit_status_cnt_q < DEPTH_COMMIT);
    // no store is pending if we don't have any element in the commit queue e.g.: it is empty
    no_st_pending_o        = (commit_status_cnt_q == 0);
    // default assignments
    commit_read_pointer_n  = commit_read_pointer_q;
    commit_write_pointer_n = commit_write_pointer_q;

    commit_queue_n         = commit_queue_q;

    req_port_o.data_req    = 1'b0;
    req_port_o.cbo_op      = commit_queue_q[commit_read_pointer_q].cbo_op;

    // there should be no commit when we are flushing
    // if the entry in the commit queue is valid and not speculative anymore we can issue this instruction
    if (commit_queue_q[commit_read_pointer_q].valid && !stall_st_pending_i && !commit_queue_q[commit_read_pointer_q].wait_rvalid) begin
      req_port_o.data_req = 1'b1;
      if (req_port_i.data_gnt) begin
        if (commit_queue_q[commit_read_pointer_q].cbo_op == ariane_pkg::CBO_NONE || req_port_i.data_rvalid) begin
          // not CBO or rvalid as well -> we can evict it from the commit buffer
          // check for rvalid is technically superfluous, as CBO latency is >= 1 cycle, but check it anyway just to be safe
          commit_queue_n[commit_read_pointer_q].valid = 1'b0;
          // advance the read_pointer
          commit_read_pointer_n = commit_read_pointer_q + 1'b1;
          commit_status_cnt--;
        end else if (commit_queue_q[commit_read_pointer_q].cbo_op != ariane_pkg::CBO_NONE) begin
          // CBO and have gotten data grant -> proceed to wait for rvalid
          commit_queue_n[commit_read_pointer_q].wait_rvalid = 1'b1;
        end
      end
    end

    if(commit_queue_q[commit_read_pointer_q].valid && commit_queue_q[commit_read_pointer_q].wait_rvalid)
    begin
      // wait for rvalid, but no need to raise another request / wait for grant
      if (req_port_i.data_rvalid) begin
        // CMO did commit
        // we can evict the entry from the commit buffer
        commit_queue_n[commit_read_pointer_q].valid = 1'b0;
        // advance the read_pointer
        commit_read_pointer_n = commit_read_pointer_q + 1'b1;
        commit_status_cnt--;
      end
    end

    // we ignore the rvalid signal for now as we assume that the store
    // happened if we got a grant

    // shift the store request from the speculative buffer to the non-speculative
    if (commit_i) begin
      commit_queue_n[commit_write_pointer_q] = speculative_queue_q[speculative_read_pointer_q];
      commit_write_pointer_n = commit_write_pointer_n + 1'b1;
      commit_status_cnt++;
    end

    commit_status_cnt_n = commit_status_cnt;
  end

  // ------------------
  // Address Checker
  // ------------------
  // The load should return the data stored by the most recent store to the
  // same physical address.  The most direct way to implement this is to
  // maintain physical addresses in the store buffer.

  // Of course, there are other micro-architectural techniques to accomplish
  // the same thing: you can interlock and wait for the store buffer to
  // drain if the load VA matches any store VA modulo the page size (i.e.
  // bits 11:0).  As a special case, it is correct to bypass if the full VA
  // matches, and no younger stores' VAs match in bits 11:0.
  //
  // checks if the requested load is in the store buffer
  // page offsets are virtually and physically the same
  //
  // R3a: also hold a 1-cycle sticky match after the STQ entry leaves so the
  // load unit does not race the commit-queue → D$ wbuffer handoff. Without
  // this, WAIT_PAGE_OFFSET can release the cycle the store is granted into
  // the wbuffer and the load can sample stale D$ data (libfdt *nextoffset
  // stays 0 → OpenSBI FDT walk stuck). D$ wbuffer already forwards on hit;
  // the sticky covers the grant/accept bubble.
  // R3a: hazard detect uses full paddr when available (DTLB hit). [11:0]-only
  // matching false-aliased stack SW vs FDT structure loads across pages and
  // either stalled forever or STQ-forwarded the wrong bytes (*nextoff=-11).
  logic page_offset_matches_now;
  logic [CVA6Cfg.PLEN-1:0] page_offset_sticky_pa_q;
  logic                    page_offset_sticky_v_q;
  logic                    page_offset_sticky_po_v_q;  // [11:0]-only sticky
  logic [11:0]             page_offset_sticky_po_q;

  // Exact paddr equality helper
  function automatic logic pa_eq(input logic [CVA6Cfg.PLEN-1:0] a,
                                 input logic [CVA6Cfg.PLEN-1:0] b);
    return a == b;
  endfunction

  always_comb begin : address_checker
    // R3a: **stall** on [11:0] always (classic Ariane — never miss stack RAW).
    // load_paddr is vaddr (see load_unit); full-PA-only stall missed stack RAW
    // when store queue holds paddr form. Forward remains full-PA only.
    // cont.11 false-alias FDT vs stack is still open (next_tag tag=9).
    page_offset_matches_now = 1'b0;

    for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
      if (commit_queue_q[i].valid &&
          (commit_queue_q[i].address[11:0] == page_offset_i)) begin
        page_offset_matches_now = 1'b1;
        break;
      end
    end
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      if (speculative_queue_q[i].valid &&
          (speculative_queue_q[i].address[11:0] == page_offset_i)) begin
        page_offset_matches_now = 1'b1;
        break;
      end
    end
    if (valid_without_flush_i && (paddr_i[11:0] == page_offset_i)) begin
      page_offset_matches_now = 1'b1;
    end

    page_offset_matches_o = page_offset_matches_now ||
        (page_offset_sticky_po_v_q && (page_offset_sticky_po_q == page_offset_i)) ||
        (page_offset_sticky_v_q && load_paddr_valid_i &&
         pa_eq(page_offset_sticky_pa_q, load_paddr_i));
  end

  // Forward only on full paddr match (never on [11:0] alone).
  always_comb begin : st_fwd_merge
    automatic logic [CVA6Cfg.XLEN-1:0]     data_m;
    automatic logic [(CVA6Cfg.XLEN/8)-1:0] be_m;
    automatic logic [$clog2(DEPTH_COMMIT)-1:0] cidx;
    automatic logic [$clog2(DEPTH_SPEC)-1:0]   sidx;
    data_m = '0;
    be_m   = '0;

    if (load_paddr_valid_i) begin
      for (int unsigned k = 0; k < DEPTH_COMMIT; k++) begin
        cidx = commit_read_pointer_q + $clog2(DEPTH_COMMIT)'(k);
        if (commit_queue_q[cidx].valid &&
            pa_eq(commit_queue_q[cidx].address, load_paddr_i)) begin
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
            if (commit_queue_q[cidx].be[b]) begin
              data_m[8*b+:8] = commit_queue_q[cidx].data[8*b+:8];
              be_m[b]        = 1'b1;
            end
          end
        end
      end
      for (int unsigned k = 0; k < DEPTH_SPEC; k++) begin
        sidx = speculative_read_pointer_q + $clog2(DEPTH_SPEC)'(k);
        if (speculative_queue_q[sidx].valid &&
            pa_eq(speculative_queue_q[sidx].address, load_paddr_i)) begin
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
            if (speculative_queue_q[sidx].be[b]) begin
              data_m[8*b+:8] = speculative_queue_q[sidx].data[8*b+:8];
              be_m[b]        = 1'b1;
            end
          end
        end
      end
      if (valid_without_flush_i && pa_eq(paddr_i, load_paddr_i)) begin
        for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
          if (be_i[b]) begin
            data_m[8*b+:8] = data_i[8*b+:8];
            be_m[b]        = 1'b1;
          end
        end
      end
    end

    st_fwd_data_o  = data_m;
    st_fwd_be_o    = be_m;
    // R3a cont.13: keep STQ forward on; nofwd + store-side sticky still −4,
    // so residual is not STQ→wbuffer *nextoffset alone.
    // Soft-ladder iter-012: STQ-nofwd under SuperscalarEn was PEEL_FDT-negative
    // (fw64d, same mepc=0x12eb2 mtval=0x12b2a) — re-enabled forward.
    st_fwd_valid_o = |be_m;
  end

  // R3a cont.13: **store-side** sticky on STQ→D$ grant.
  // Load-side sticky only armed when a load was checking during STQ occupancy;
  // the caller's post-return load of libfdt *nextoffset often issues after the
  // store left the STQ, so match_now was never seen and sticky never set.
  // Capture the store address when it is granted into the D$ wbuffer and hold
  // until wbuffer_empty so load_unit condition (2) covers the handoff.
  logic st_to_wbuf_grant;
  assign st_to_wbuf_grant =
      commit_queue_q[commit_read_pointer_q].valid && !stall_st_pending_i &&
      !commit_queue_q[commit_read_pointer_q].wait_rvalid && req_port_i.data_gnt &&
      (commit_queue_q[commit_read_pointer_q].cbo_op == ariane_pkg::CBO_NONE ||
       req_port_i.data_rvalid);

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_page_offset_sticky
    if (~rst_ni) begin
      page_offset_sticky_v_q    <= 1'b0;
      page_offset_sticky_pa_q   <= '0;
      page_offset_sticky_po_v_q <= 1'b0;
      page_offset_sticky_po_q   <= '0;
    end else if (flush_i) begin
      page_offset_sticky_v_q    <= 1'b0;
      page_offset_sticky_po_v_q <= 1'b0;
    end else if (st_to_wbuf_grant) begin
      // Store accepted into D$ hierarchy — remember its [11:0]/full PA
      page_offset_sticky_po_v_q <= 1'b1;
      page_offset_sticky_po_q   <= commit_queue_q[commit_read_pointer_q].address[11:0];
      page_offset_sticky_v_q    <= 1'b1;
      page_offset_sticky_pa_q   <= commit_queue_q[commit_read_pointer_q].address;
    end else if (page_offset_matches_now) begin
      // Also arm while load is matching STQ (covers same-cycle forward path)
      page_offset_sticky_po_v_q <= 1'b1;
      page_offset_sticky_po_q   <= page_offset_i;
      if (load_paddr_valid_i) begin
        page_offset_sticky_v_q  <= 1'b1;
        page_offset_sticky_pa_q <= load_paddr_i;
      end
    end else if (page_offset_sticky_po_v_q && !dcache_wbuffer_empty_i) begin
      // Keep sticky until D$ wbuffer drains
    end else begin
      page_offset_sticky_v_q    <= 1'b0;
      page_offset_sticky_po_v_q <= 1'b0;
    end
  end


  // registers
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_spec
    if (~rst_ni) begin
      speculative_queue_q         <= '{default: 0};
      speculative_read_pointer_q  <= '0;
      speculative_write_pointer_q <= '0;
      speculative_status_cnt_q    <= '0;
    end else begin
      speculative_queue_q         <= speculative_queue_n;
      speculative_read_pointer_q  <= speculative_read_pointer_n;
      speculative_write_pointer_q <= speculative_write_pointer_n;
      speculative_status_cnt_q    <= speculative_status_cnt_n;
    end
  end

  // registers
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_commit
    if (~rst_ni) begin
      commit_queue_q         <= '{default: 0};
      commit_read_pointer_q  <= '0;
      commit_write_pointer_q <= '0;
      commit_status_cnt_q    <= '0;
    end else begin
      commit_queue_q         <= commit_queue_n;
      commit_read_pointer_q  <= commit_read_pointer_n;
      commit_write_pointer_q <= commit_write_pointer_n;
      commit_status_cnt_q    <= commit_status_cnt_n;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  // assert that commit is never set when we are flushing this would be counter intuitive
  // as flush and commit is decided in the same stage
  commit_and_flush :
  assert property (@(posedge clk_i) rst_ni && flush_i |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit and flush in the same cycle");

  speculative_buffer_overflow :
  assert property (@(posedge clk_i) rst_ni && (speculative_status_cnt_q == DEPTH_SPEC) |-> !valid_i)
  else
    $error("[Speculative Queue] You are trying to push new data although the buffer is not ready");

  speculative_buffer_underflow :
  assert property (@(posedge clk_i) rst_ni && (speculative_status_cnt_q == 0) |-> !commit_i)
  else $error("[Speculative Queue] You are committing although there are no stores to commit");

  commit_buffer_overflow :
  assert property (@(posedge clk_i) rst_ni && (commit_status_cnt_q == DEPTH_COMMIT) |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit a store although the buffer is full");
  //pragma translate_on
endmodule



