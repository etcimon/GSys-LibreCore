// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.0 memory-side L2 cache — AXI slave (core) ↔ AXI master (memory).
//
// Contention-oriented features:
//   * Multi-MSHR with line-merge (no duplicate fills for same line)
//   * Banked data array (hit || fill in parallel when banks differ)
//   * Combinational non-cacheable bypass (MMIO never enters tags)
//   * Write-through + read-allocate (matches WT L1)
//   * Parallel SET_ASSOC tag compare
//
// When Enable=0 the module is not instantiated (caller wires AXI identity).
// Line size must equal L1 / Zic64b (64 B default).

module g6lc_l2_top
  import g6lc_l2_pkg::*;
#(
    parameter bit          Enable      = 1'b1,
    parameter int unsigned BYTE_SIZE   = L2_DEFAULT_BYTE_SIZE,
    parameter int unsigned SET_ASSOC   = L2_DEFAULT_SET_ASSOC,
    parameter int unsigned LINE_WIDTH  = L2_DEFAULT_LINE_WIDTH,
    parameter int unsigned MSHR_DEPTH  = L2_DEFAULT_MSHR_DEPTH,
    parameter int unsigned DATA_BANKS  = L2_DEFAULT_DATA_BANKS,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    // AXI channel types (inject from SoC)
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    // Toward core (L2 is slave)
    input  axi_req_t  slv_req_i,
    output axi_resp_t slv_resp_o,
    // Toward memory (L2 is master)
    output axi_req_t  mst_req_o,
    input  axi_resp_t mst_resp_i,
    // Observability
    output logic      l2_hit_o,
    output logic      l2_miss_o,
    output logic      l2_bypass_o,
    output logic      l2_mshr_full_o,
    output logic      l2_bank_conflict_o,
    // Victim replace (valid way overwritten on miss) — inclusive LLC back-inval
    output logic                          l2_evict_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0]     l2_evict_addr_o,
    // L3→L2 inclusive back-invalidate (address of victim line at L3). Always
    // ready (single-cycle tag match). Tie valid low when unused.
    input  logic                          l2_back_inval_valid_i,
    input  logic [AXI_ADDR_WIDTH-1:0]     l2_back_inval_addr_i,
    output logic                          l2_back_inval_ready_o
);

  // Identity when disabled (should not be instantiated; safety net)
  if (!Enable) begin : gen_identity
    assign mst_req_o  = slv_req_i;
    assign slv_resp_o = mst_resp_i;
    assign l2_hit_o = 1'b0;
    assign l2_miss_o = 1'b0;
    assign l2_bypass_o = 1'b1;
    assign l2_mshr_full_o = 1'b0;
    assign l2_bank_conflict_o = 1'b0;
    assign l2_evict_valid_o = 1'b0;
    assign l2_evict_addr_o  = '0;
    assign l2_back_inval_ready_o = 1'b1;
  end else begin : gen_l2

  localparam int unsigned LINE_BYTES  = LINE_WIDTH / 8;
  localparam int unsigned NUM_SETS    = l2_num_sets(BYTE_SIZE, SET_ASSOC, LINE_WIDTH);
  localparam int unsigned OFF_BITS    = l2_offset_bits(LINE_WIDTH);
  localparam int unsigned IDX_BITS    = l2_index_bits(NUM_SETS);
  localparam int unsigned TAG_BITS    = AXI_ADDR_WIDTH - IDX_BITS - OFF_BITS;
  localparam int unsigned BEATS       = LINE_WIDTH / AXI_DATA_WIDTH;
  localparam int unsigned WAY_W       = (SET_ASSOC <= 1) ? 1 : $clog2(SET_ASSOC);
  localparam int unsigned MSHR_W      = (MSHR_DEPTH <= 1) ? 1 : $clog2(MSHR_DEPTH);
  localparam int unsigned STRB_W      = AXI_DATA_WIDTH / 8;

  // --------------------
  // Address decode
  // --------------------
  function automatic logic [AXI_ADDR_WIDTH-1:0] line_align(input logic [AXI_ADDR_WIDTH-1:0] a);
    return {a[AXI_ADDR_WIDTH-1:OFF_BITS], {OFF_BITS{1'b0}}};
  endfunction

  function automatic logic [IDX_BITS-1:0] idx_of(input logic [AXI_ADDR_WIDTH-1:0] a);
    return a[OFF_BITS +: IDX_BITS];
  endfunction

  function automatic logic [TAG_BITS-1:0] tag_of(input logic [AXI_ADDR_WIDTH-1:0] a);
    return a[OFF_BITS+IDX_BITS +: TAG_BITS];
  endfunction

  // --------------------
  // Tag / data / MSHR
  // --------------------
  logic tag_lookup, tag_hit;
  logic [WAY_W-1:0] tag_way;
  logic [SET_ASSOC-1:0] tag_way_valid;
  logic tag_write, tag_inval, tag_match_inval;
  logic [IDX_BITS-1:0] tag_windex, tag_iindex, tag_match_index;
  logic [WAY_W-1:0] tag_wway, tag_iway, tag_probe_way;
  logic [TAG_BITS-1:0] tag_wtag, tag_ltag, tag_probe_tag, tag_match_tag;
  logic tag_wvalid, tag_probe_valid;

  // L3→L2 back-inval always single-cycle (no MSHR interaction).
  // Also used for write-through self-inval: WT bypass must drop a cached
  // line that covers the write address, else a later read hits stale L2 data
  // (store@+0 then store@+16 on same 64 B line → second load returned 0).
  assign l2_back_inval_ready_o = 1'b1;
  logic wr_self_inval;
  logic [AXI_ADDR_WIDTH-1:0] wr_self_inval_addr;
  assign tag_match_inval = l2_back_inval_valid_i | wr_self_inval;
  assign tag_match_index = idx_of(l2_back_inval_valid_i ? l2_back_inval_addr_i
                                                        : wr_self_inval_addr);
  assign tag_match_tag   = tag_of(l2_back_inval_valid_i ? l2_back_inval_addr_i
                                                        : wr_self_inval_addr);

  g6lc_l2_tag #(
      .NUM_SETS  (NUM_SETS),
      .SET_ASSOC (SET_ASSOC),
      .TAG_WIDTH (TAG_BITS),
      .IDX_WIDTH (IDX_BITS)
  ) i_tag (
      .clk_i,
      .rst_ni,
      .lookup_i     (tag_lookup),
      .index_i      (tag_iindex),
      .tag_i        (tag_ltag),
      .hit_o        (tag_hit),
      .way_o        (tag_way),
      .way_valid_o  (tag_way_valid),
      .probe_way_i  (tag_probe_way),
      .probe_tag_o  (tag_probe_tag),
      .probe_valid_o(tag_probe_valid),
      .write_i      (tag_write),
      .write_index_i(tag_windex),
      .write_way_i  (tag_wway),
      .write_tag_i  (tag_wtag),
      .write_valid_i(tag_wvalid),
      .inval_i      (tag_inval),
      .inval_index_i(tag_iindex),
      .inval_way_i  (tag_iway),
      .inval_match_i      (tag_match_inval),
      .inval_match_index_i(tag_match_index),
      .inval_match_tag_i  (tag_match_tag)
  );

  logic data_a_req, data_a_we, data_b_req, data_b_we, bank_conflict;
  logic [IDX_BITS-1:0] data_a_idx, data_b_idx;
  logic [WAY_W-1:0] data_a_way, data_b_way;
  logic [LINE_WIDTH-1:0] data_a_wdata, data_a_rdata, data_b_wdata, data_b_rdata;
  logic [LINE_WIDTH/8-1:0] data_a_be, data_b_be;

  g6lc_l2_data #(
      .NUM_SETS  (NUM_SETS),
      .SET_ASSOC (SET_ASSOC),
      .LINE_WIDTH(LINE_WIDTH),
      .NUM_BANKS (DATA_BANKS),
      .IDX_WIDTH (IDX_BITS)
  ) i_data (
      .clk_i,
      .rst_ni,
      .a_req_i   (data_a_req),
      .a_we_i    (data_a_we),
      .a_index_i (data_a_idx),
      .a_way_i   (data_a_way),
      .a_wdata_i (data_a_wdata),
      .a_be_i    (data_a_be),
      .a_rdata_o (data_a_rdata),
      .b_req_i   (data_b_req),
      .b_we_i    (data_b_we),
      .b_index_i (data_b_idx),
      .b_way_i   (data_b_way),
      .b_wdata_i (data_b_wdata),
      .b_be_i    (data_b_be),
      .b_rdata_o (data_b_rdata),
      .bank_conflict_o(bank_conflict)
  );
  assign l2_bank_conflict_o = bank_conflict;

  logic mshr_alloc, mshr_ready, mshr_merged, mshr_complete, mshr_full, mshr_empty;
  logic [MSHR_W-1:0] mshr_alloc_idx, mshr_complete_idx;
  logic [AXI_ADDR_WIDTH-1:0] mshr_alloc_line;

  g6lc_l2_mshr #(
      .DEPTH       (MSHR_DEPTH),
      .ADDR_WIDTH  (AXI_ADDR_WIDTH),
      .ID_WIDTH    (AXI_ID_WIDTH),
      .MAX_WAITERS (4)  // multi-core same-line attach depth
  ) i_mshr (
      .clk_i,
      .rst_ni,
      .flush_i           (1'b0),
      .alloc_i           (mshr_alloc),
      .alloc_line_addr_i (mshr_alloc_line),
      .alloc_id_i        (slv_req_i.ar.id),
      .alloc_is_write_i  (1'b0),
      .alloc_ready_o     (mshr_ready),
      .alloc_merged_o    (mshr_merged),
      .alloc_idx_o       (mshr_alloc_idx),
      .lookup_line_addr_i(mshr_alloc_line),
      .lookup_hit_o      (),
      .lookup_idx_o      (),
      .complete_i        (mshr_complete),
      .complete_idx_i    (mshr_complete_idx),
      .complete_id_o     (),
      .waiter_valid_o    (),
      .waiter_id_o       (),
      .waiter_pop_i      (1'b0),  // multi-waiter drain wired when multi-miss resp path lands
      .empty_o           (mshr_empty),
      .full_o            (mshr_full),
      .merge_full_o      (),
      .count_o           ()
  );
  assign l2_mshr_full_o = mshr_full;

  // --------------------
  // Controller FSM
  // --------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_TAG,
    S_HIT_WAIT,
    S_HIT_RESP,
    S_MISS_AR,
    S_MISS_R,
    S_MISS_INSTALL,
    S_BYPASS_AR,
    S_BYPASS_R,
    S_BYPASS_AW,
    S_BYPASS_W,
    S_BYPASS_B
  } state_e;

  state_e state_q, state_d;

  // Captured request
  logic [AXI_ADDR_WIDTH-1:0] addr_q, addr_d;
  logic [AXI_ID_WIDTH-1:0]   id_q, id_d;
  logic [7:0]                len_q, len_d;
  logic [2:0]                size_q, size_d;
  logic [3:0]                cache_q, cache_d;
  logic [5:0]                atop_q, atop_d;  // AXI ATOP (AMOs / AMOCAS)
  logic                      lock_q, lock_d;
  logic                      is_write_q, is_write_d;
  logic                      cacheable_q, cacheable_d;
  logic [WAY_W-1:0]          way_q, way_d;
  logic [LINE_WIDTH-1:0]     line_q, line_d;
  // beat_q dual use: fill index in S_MISS_R; response *count* (0..len) in S_HIT_RESP
  logic [$clog2(BEATS+1)-1:0] beat_q, beat_d;
  logic [MSHR_W-1:0]         mshr_idx_q, mshr_idx_d;
  // Master R outstanding: after AR handshake we MUST drain R until r_last, even if
  // the FSM leaves S_MISS_R/S_BYPASS_R early. Otherwise axi2mem stays in READ with
  // r_valid && !r_ready and all subsequent DRAM traffic deadlocks (OpenSBI hang
  // after MaxMstTrans fix: a2m=READ @0x80000080, L2 IDLE).
  logic mst_r_ot_q, mst_r_ot_d;

  // First AXI beat index within the L2 line for the captured AR address.
  // Without this, a hit on a 64 B line always returned beats from offset 0,
  // so I$ fills at +16/+32/... re-read the first 16 B of the line.
  localparam int unsigned BEAT_ADDR_LSB = $clog2(AXI_DATA_WIDTH / 8);
  localparam int unsigned BEAT_IDX_W    = (BEATS <= 1) ? 1 : $clog2(BEATS);
  logic [BEAT_IDX_W-1:0] beat_base;
  logic [BEAT_IDX_W-1:0] beat_idx;
  assign beat_base = addr_q[OFF_BITS-1:BEAT_ADDR_LSB];
  assign beat_idx  = beat_base + BEAT_IDX_W'(beat_q);

  // AXI slave defaults
  always_comb begin
    // Slave response
    slv_resp_o = '0;
    slv_resp_o.aw_ready = 1'b0;
    slv_resp_o.w_ready  = 1'b0;
    slv_resp_o.b_valid  = 1'b0;
    slv_resp_o.ar_ready = 1'b0;
    slv_resp_o.r_valid  = 1'b0;

    // Master request
    mst_req_o = '0;
    mst_req_o.aw_valid = 1'b0;
    mst_req_o.w_valid  = 1'b0;
    mst_req_o.b_ready  = 1'b0;
    mst_req_o.ar_valid = 1'b0;
    mst_req_o.r_ready  = 1'b0;

    // Tag/data/mshr defaults
    tag_lookup = 1'b0;
    tag_write  = 1'b0;
    tag_inval  = 1'b0;
    tag_iindex = idx_of(addr_q);
    tag_ltag   = tag_of(addr_q);
    tag_windex = idx_of(addr_q);
    tag_wway   = way_q;
    tag_wtag   = tag_of(addr_q);
    tag_wvalid = 1'b1;
    tag_iway   = way_q;
    tag_probe_way = way_q;

    data_a_req = 1'b0;
    data_a_we  = 1'b0;
    data_a_idx = idx_of(addr_q);
    data_a_way = way_q;
    data_a_wdata = '0;
    data_a_be    = '1;
    data_b_req = 1'b0;
    data_b_we  = 1'b0;
    data_b_idx = idx_of(addr_q);
    data_b_way = way_q;
    data_b_wdata = line_q;
    data_b_be    = '1;

    mshr_alloc       = 1'b0;
    mshr_alloc_line  = line_align(addr_q);
    mshr_complete    = 1'b0;
    mshr_complete_idx = mshr_idx_q;

    state_d     = state_q;
    addr_d      = addr_q;
    id_d        = id_q;
    len_d       = len_q;
    size_d      = size_q;
    cache_d     = cache_q;
    atop_d      = atop_q;
    lock_d      = lock_q;
    is_write_d  = is_write_q;
    cacheable_d = cacheable_q;
    way_d       = way_q;
    line_d      = line_q;
    beat_d      = beat_q;
    mshr_idx_d  = mshr_idx_q;

    l2_hit_o    = 1'b0;
    l2_miss_o   = 1'b0;
    l2_bypass_o = 1'b0;
    l2_evict_valid_o = 1'b0;
    l2_evict_addr_o  = '0;
    wr_self_inval      = 1'b0;
    wr_self_inval_addr = addr_q;

    unique case (state_q)
      // ---------------- IDLE: accept AR (reads) or AW (writes) ----------------
      S_IDLE: begin
        // Drain any late ATOP/AMO R before starting a new request. Accepting a
        // miss-fill AR while amos is still injecting R (mst_r_ready=0) is the
        // hang-2 failure mode: L2 can see the injected r_last as a fill done
        // while axi2mem still holds the real multi-beat READ.
        if (mst_resp_i.r_valid) begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end else if (slv_req_i.ar_valid) begin
          // Prefer reads (MLP); accept write when no AR
          slv_resp_o.ar_ready = 1'b1;
          addr_d      = slv_req_i.ar.addr;
          id_d        = slv_req_i.ar.id;
          len_d       = slv_req_i.ar.len;
          size_d      = slv_req_i.ar.size;
          cache_d     = slv_req_i.ar.cache;
          atop_d      = '0;
          lock_d      = 1'b0;
          is_write_d  = 1'b0;
          cacheable_d = l2_is_cacheable(slv_req_i.ar.cache);
          beat_d      = '0;
          if (l2_is_cacheable(slv_req_i.ar.cache)) begin
            state_d = S_TAG;
          end else begin
            l2_bypass_o = 1'b1;
            state_d = S_BYPASS_AR;
          end
        end else if (slv_req_i.aw_valid) begin
          // Writes: write-through bypass (always push to memory); optional allocate
          slv_resp_o.aw_ready = 1'b1;
          addr_d      = slv_req_i.aw.addr;
          id_d        = slv_req_i.aw.id;
          len_d       = slv_req_i.aw.len;
          size_d      = slv_req_i.aw.size;
          cache_d     = slv_req_i.aw.cache;
          // Preserve ATOP/lock — dropping them turns AMOCAS into a plain store
          // and the HPDCACHE UC FSM hangs waiting for the atomic R beat.
          atop_d      = slv_req_i.aw.atop;
          lock_d      = slv_req_i.aw.lock;
          is_write_d  = 1'b1;
          cacheable_d = l2_is_cacheable(slv_req_i.aw.cache);
          beat_d      = '0;
          l2_bypass_o = 1'b1;
          state_d     = S_BYPASS_AW;
        end
      end

      // ---------------- TAG lookup ----------------
      S_TAG: begin
        tag_lookup = 1'b1;
        tag_iindex = idx_of(addr_q);
        tag_ltag   = tag_of(addr_q);
        if (tag_hit) begin
          l2_hit_o = 1'b1;
          way_d    = tag_way;
          // Kick data read
          data_a_req = 1'b1;
          data_a_we  = 1'b0;
          data_a_idx = idx_of(addr_q);
          data_a_way = tag_way;
          state_d    = S_HIT_WAIT;
        end else begin
          l2_miss_o = 1'b1;
          // Victim: first invalid way (lowest index), else way 0
          begin
            logic found_inv;
            found_inv = 1'b0;
            way_d = '0;
            for (int w = 0; w < int'(SET_ASSOC); w++) begin
              if (!found_inv && !tag_way_valid[w]) begin
                way_d = WAY_W'(w);
                found_inv = 1'b1;
              end
            end
          end
          // Inclusive path: report replace of a valid victim line
          tag_probe_way = way_d;
          if (tag_way_valid[way_d]) begin
            l2_evict_valid_o = 1'b1;
            l2_evict_addr_o  = {
              tag_probe_tag,
              idx_of(addr_q),
              {OFF_BITS{1'b0}}
            };
          end
          if (mshr_ready) begin
            mshr_alloc = 1'b1;
            mshr_idx_d = mshr_alloc_idx;
            if (!mshr_merged) state_d = S_MISS_AR;
            else state_d = S_MISS_R;  // wait on in-flight fill
          end
          // else stall in S_TAG until MSHR free
        end
      end

      // ---------------- HIT: wait 1-cycle SRAM ----------------
      S_HIT_WAIT: begin
        state_d = S_HIT_RESP;
        line_d  = data_a_rdata;
      end

      S_HIT_RESP: begin
        // Return beats from captured line starting at the AR address offset
        // (beat_base), not always at line beat 0.
        slv_resp_o.r_valid = 1'b1;
        slv_resp_o.r.id    = id_q;
        slv_resp_o.r.resp  = axi_pkg::RESP_OKAY;
        slv_resp_o.r.last  = (beat_q == len_q);
        slv_resp_o.r.data  = line_q[beat_idx*AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
        if (slv_req_i.r_ready) begin
          if (beat_q == len_q) begin
            state_d = S_IDLE;
            beat_d  = '0;
          end else begin
            beat_d = beat_q + 1'b1;
          end
        end
      end

      // ---------------- MISS: issue line fill ----------------
      S_MISS_AR: begin
        mst_req_o.ar_valid = 1'b1;
        mst_req_o.ar.id    = id_q;
        mst_req_o.ar.addr  = line_align(addr_q);
        mst_req_o.ar.len   = axi_pkg::len_t'(BEATS - 1);
        mst_req_o.ar.size  = axi_pkg::size_t'($clog2(AXI_DATA_WIDTH/8));
        mst_req_o.ar.burst = axi_pkg::BURST_INCR;
        mst_req_o.ar.cache = 4'b1111;
        mst_req_o.ar.prot  = 3'b000;
        if (mst_resp_i.ar_ready) begin
          beat_d  = '0;
          line_d  = '0;
          state_d = S_MISS_R;
        end
      end

      S_MISS_R: begin
        mst_req_o.r_ready = 1'b1;
        if (mst_resp_i.r_valid) begin
          // Full line fill is always BEATS beats (len=BEATS-1). A spurious early
          // r_last (classic: axi_riscv_amos injects a 1-beat R with last=1 on the
          // slave side while holding mst_r_ready=0 during AMO/invalid-ATOP R
          // injection — often under a shared id) must NOT complete the miss:
          // that leaves the real DRAM burst orphaned in axi2mem forever.
          if (mst_resp_i.r.last && (beat_q != $bits(beat_q)'(BEATS - 1))) begin
            // Discard injected/short last; stay in S_MISS_R until full line arrives.
          end else begin
            line_d[beat_q*AXI_DATA_WIDTH +: AXI_DATA_WIDTH] = mst_resp_i.r.data;
            if (mst_resp_i.r.last) begin
              state_d = S_MISS_INSTALL;
            end else begin
              beat_d = beat_q + 1'b1;
            end
          end
        end
      end

      S_MISS_INSTALL: begin
        // Write tag + data (port B); handle bank conflict by stalling
        tag_write  = 1'b1;
        tag_windex = idx_of(addr_q);
        tag_wway   = way_q;
        tag_wtag   = tag_of(addr_q);
        tag_wvalid = 1'b1;

        data_b_req   = 1'b1;
        data_b_we    = 1'b1;
        data_b_idx   = idx_of(addr_q);
        data_b_way   = way_q;
        data_b_wdata = line_q;
        data_b_be    = '1;

        if (!bank_conflict) begin
          mshr_complete = 1'b1;
          mshr_complete_idx = mshr_idx_q;
          // Serve core from line_q; beat_q is response count from 0, index via beat_base
          beat_d  = '0;
          state_d = S_HIT_RESP;
        end
      end

      // ---------------- Non-cacheable / write bypass ----------------
      S_BYPASS_AR: begin
        mst_req_o.ar_valid = 1'b1;
        mst_req_o.ar       = slv_req_i.ar;
        // override with captured
        mst_req_o.ar.addr  = addr_q;
        mst_req_o.ar.id    = id_q;
        mst_req_o.ar.len   = len_q;
        mst_req_o.ar.size  = size_q;
        mst_req_o.ar.cache = cache_q;
        if (mst_resp_i.ar_ready) state_d = S_BYPASS_R;
      end

      S_BYPASS_R: begin
        slv_resp_o.r_valid = mst_resp_i.r_valid;
        slv_resp_o.r       = mst_resp_i.r;
        mst_req_o.r_ready  = slv_req_i.r_ready;
        if (mst_resp_i.r_valid && slv_req_i.r_ready && mst_resp_i.r.last)
          state_d = S_IDLE;
      end

      S_BYPASS_AW: begin
        mst_req_o.aw_valid = 1'b1;
        mst_req_o.aw.addr  = addr_q;
        mst_req_o.aw.id    = id_q;
        mst_req_o.aw.len   = len_q;
        mst_req_o.aw.size  = size_q;
        mst_req_o.aw.burst = axi_pkg::BURST_INCR;
        mst_req_o.aw.cache = cache_q;
        mst_req_o.aw.atop  = atop_q;
        mst_req_o.aw.lock  = lock_q;
        // Drop any L2 copy of this line (WT does not update data array)
        wr_self_inval      = 1'b1;
        wr_self_inval_addr = addr_q;
        // ATOP/AMO may already be fetching old data — never block R.
        if (mst_resp_i.r_valid) begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end
        if (mst_resp_i.aw_ready) state_d = S_BYPASS_W;
      end

      S_BYPASS_W: begin
        slv_resp_o.w_ready = mst_resp_i.w_ready;
        mst_req_o.w_valid  = slv_req_i.w_valid;
        mst_req_o.w        = slv_req_i.w;
        // Keep self-inval asserted through W so multi-beat writes still snoop
        wr_self_inval      = 1'b1;
        wr_self_inval_addr = addr_q;
        // Forward ATOP load/compare R beats while W is in flight
        if (mst_resp_i.r_valid) begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end
        if (slv_req_i.w_valid && mst_resp_i.w_ready && slv_req_i.w.last)
          state_d = S_BYPASS_B;
      end

      S_BYPASS_B: begin
        slv_resp_o.b_valid = mst_resp_i.b_valid;
        slv_resp_o.b       = mst_resp_i.b;
        mst_req_o.b_ready  = slv_req_i.b_ready;
        // AXI ATOP (AMOCAS/AMOLOAD/…) returns old data on R with the AW id.
        // Must forward and accept R here — if we leave it unabsorbed,
        // axi_riscv_amos stays in SEND_R with mst_r_ready=0, the next L2
        // miss-fill AR can still pass, and L2 may consume the injected AMO
        // r_last as a spurious line-fill completion (orphan axi2mem READ).
        if (mst_resp_i.r_valid) begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end
        if (mst_resp_i.b_valid && slv_req_i.b_ready) state_d = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase

    // ---- Master R drain (must run after case so it can override r_ready) ----
    // Track AR→R outstanding so we never leave the DRAM R channel blocked:
    // axi2mem stays in READ with r_valid && !r_ready until r_last is taken.
    mst_r_ot_d = mst_r_ot_q;
    if (mst_req_o.ar_valid && mst_resp_i.ar_ready) begin
      mst_r_ot_d = 1'b1;
    end
    if (mst_r_ot_q) begin
      // Keep accepting R until last beat even if FSM left S_MISS_R/S_BYPASS_R.
      mst_req_o.r_ready = 1'b1;
      if (mst_resp_i.r_valid && mst_resp_i.r.last) begin
        // Do not retire OT on a spurious early last during a multi-beat fill
        // (see S_MISS_R). Bypass (len may be 0) and final fill beat are fine.
        if (!(state_q == S_MISS_R && beat_q != $bits(beat_q)'(BEATS - 1))) begin
          mst_r_ot_d = 1'b0;
        end
      end
    end
    // Safety: ATOP/AMO R can arrive after the write-bypass FSM has already
    // returned to IDLE (amos injects R after B). Forward it to the slave so
    // (1) HPDCACHE gets the atomic old-data beat and (2) amos leaves SEND_R
    // (which holds mst_r_ready=0 and would orphan the next miss-fill at
    // axi2mem). If the slave is not ready, keep the beat pending — do not
    // silently drop ATOP R.
    if (state_q == S_IDLE && mst_resp_i.r_valid && !mst_r_ot_q) begin
      slv_resp_o.r_valid = 1'b1;
      slv_resp_o.r       = mst_resp_i.r;
      mst_req_o.r_ready  = slv_req_i.r_ready;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      addr_q      <= '0;
      id_q        <= '0;
      len_q       <= '0;
      size_q      <= '0;
      cache_q     <= '0;
      atop_q      <= '0;
      lock_q      <= 1'b0;
      is_write_q  <= 1'b0;
      cacheable_q <= 1'b0;
      way_q       <= '0;
      line_q      <= '0;
      beat_q      <= '0;
      mshr_idx_q  <= '0;
      mst_r_ot_q  <= 1'b0;
    end else begin
      state_q     <= state_d;
      addr_q      <= addr_d;
      id_q        <= id_d;
      len_q       <= len_d;
      size_q      <= size_d;
      cache_q     <= cache_d;
      atop_q      <= atop_d;
      lock_q      <= lock_d;
      is_write_q  <= is_write_d;
      cacheable_q <= cacheable_d;
      way_q       <= way_d;
      line_q      <= line_d;
      beat_q      <= beat_d;
      mshr_idx_q  <= mshr_idx_d;
      mst_r_ot_q  <= mst_r_ot_d;
    end
  end

  end  // gen_l2

endmodule
