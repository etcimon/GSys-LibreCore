// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// tb_g6lc_l2l3_stack — standalone leaf proving the hyp8 L2->L3 stack serves
// L3 hits with correct data and stays coherent across write/ATOP/NC/back-inval.
// Both levels are g6lc_l2_top; L3 wraps g6lc_l3_top. No RTL changes.
//
// Channel types are a local copy of g6lc_l2_tb_pkg (verif/tb/l2/tb_g6lc_l2.sv)
// renamed g6lc_l2l3_tb_pkg so this bench is self-contained.

package g6lc_l2l3_tb_pkg;
  localparam int unsigned AW  = 64;
  localparam int unsigned DW  = 64;
  localparam int unsigned IDW = 4;
  localparam int unsigned UW  = 1;

  typedef logic [IDW-1:0]   id_t;
  typedef logic [AW-1:0]    addr_t;
  typedef logic [DW-1:0]    data_t;
  typedef logic [DW/8-1:0]  strb_t;
  typedef logic [UW-1:0]    user_t;

  typedef struct packed {
    id_t id; addr_t addr; logic [7:0] len; logic [2:0] size;
    logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot;
    logic [3:0] qos; logic [3:0] region; logic [5:0] atop; user_t user;
  } aw_chan_t;

  typedef struct packed {
    id_t id; addr_t addr; logic [7:0] len; logic [2:0] size;
    logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot;
    logic [3:0] qos; logic [3:0] region; user_t user;
  } ar_chan_t;

  typedef struct packed {
    data_t data; strb_t strb; logic last; user_t user;
  } w_chan_t;

  typedef struct packed {
    id_t id; logic [1:0] resp; user_t user;
  } b_chan_t;

  typedef struct packed {
    id_t id; data_t data; logic [1:0] resp; logic last; user_t user;
  } r_chan_t;

  typedef struct packed {
    aw_chan_t aw; logic aw_valid;
    w_chan_t  w;  logic w_valid;
    logic     b_ready;
    ar_chan_t ar; logic ar_valid;
    logic     r_ready;
  } req_t;

  typedef struct packed {
    logic aw_ready, ar_ready, w_ready;
    logic b_valid; b_chan_t b;
    logic r_valid; r_chan_t r;
  } resp_t;
endpackage

module tb_g6lc_l2l3_stack;
  import g6lc_l2l3_tb_pkg::*;
  import g6lc_l2_pkg::*;
  import axi_pkg::*;

  // ---------------- geometry / knobs ----------------
  parameter int unsigned L2_BYTE_SIZE    = 4096;
  parameter int unsigned L2_SET_ASSOC    = 4;
  parameter int unsigned L2_LINE_WIDTH   = 512;
  parameter int unsigned L2_MSHR_DEPTH   = 2;
  parameter int unsigned L2_DATA_BANKS   = 2;
  parameter bit          L2_RR_EN        = 1'b1;
  parameter bit          L2_FAIR_WRITES  = 1'b1;
  parameter bit          L2_TAG_SRAM     = 1'b1;
  parameter bit          L2_WRITE_UPDATE = 1'b1;
  parameter bit          L2_POSTED_WRITES= 1'b1;

  parameter int unsigned L3_BYTE_SIZE    = 32768;
  parameter int unsigned L3_SET_ASSOC    = 8;
  parameter int unsigned L3_LINE_WIDTH   = 512;
  parameter int unsigned L3_MSHR_DEPTH   = 4;
  parameter int unsigned L3_DATA_BANKS   = 2;
  parameter bit          L3_RR_EN        = 1'b1;
  parameter bit          L3_FAIR_WRITES  = 1'b1;
  parameter bit          L3_TAG_SRAM     = 1'b1;
  parameter bit          L3_WRITE_UPDATE = 1'b1;
  parameter bit          L3_POSTED_WRITES= 1'b1;

  parameter int unsigned MEM_LATENCY     = 8;
  parameter int unsigned WATCHDOG        = 20000;

  localparam int unsigned LINE_BYTES = L2_LINE_WIDTH / 8;   // 64
  localparam int unsigned BEATS      = L2_LINE_WIDTH / DW;  // 8
  localparam logic [3:0] CACHEABLE = 4'b1111;  // cacheable (l2_is_cacheable)
  localparam logic [3:0] NONCACHE  = 4'b0010;  // MODIFIABLE only -> bypass

  // ---------------- clocks / resets ----------------
  logic clk = 0;
  logic rst_ni = 0;
  always #5 clk = ~clk;

  // ---------------- observability counters ----------------
  longint unsigned c_l2_hit=0, c_l2_miss=0, c_l3_hit=0, c_l3_miss=0,
                   c_l3_selfinv=0, c_l3_wupd=0, c_l2_selfinv=0, c_l2_wupd=0,
                   cycles=0, ops_done=0;
  longint unsigned dbg_l3binv=0, dbg_l3minv=0, dbg_l2minv=0;
  always_ff @(posedge clk) if (rst_ni) begin
    cycles <= cycles + 1;
    if (l2_hit_o)        c_l2_hit   <= c_l2_hit+1;
    if (l2_miss_o)       c_l2_miss  <= c_l2_miss+1;
    if (l2_selfinv_hit_o)c_l2_selfinv<= c_l2_selfinv+1;
    if (l2_wupdate_o)    c_l2_wupd   <= c_l2_wupd+1;
    if (l3_hit_o)        c_l3_hit   <= c_l3_hit+1;
    if (l3_miss_o)       c_l3_miss  <= c_l3_miss+1;
    if (l3_selfinv_hit_o)c_l3_selfinv<= c_l3_selfinv+1;
    if (l3_wupdate_o)    c_l3_wupd   <= c_l3_wupd+1;
    if (i_l3.i_l3_as_l2.l2_back_inval_valid_i) dbg_l3binv <= dbg_l3binv+1;
    if (i_l3.i_l3_as_l2.gen_l2.tag_match_inval) dbg_l3minv <= dbg_l3minv+1;
    if (i_l2.gen_l2.tag_match_inval)             dbg_l2minv <= dbg_l2minv+1;
  end

  // ---------------- DUT chain: L1 driver -> L2 -> L3 -> mem ----------------
  req_t  l1_req;
  resp_t l1_resp;
  req_t  l2_mst_req;
  resp_t l2_mst_resp;
  req_t  l3_mst_req;
  resp_t l3_mst_resp;

  logic l2_hit_o, l2_miss_o, l2_bypass_o, l2_mshr_full_o, l2_bank_conflict_o;
  logic l2_selfinv_hit_o, l2_wupdate_o, l2_write_idle_o;
  logic l2_evict_valid_o, l2_evict_ready_i = 1'b1;
  logic l3_evict_valid_o, l3_evict_ready_i = 1'b1;
  logic l2_back_inval_ready_o, l3_back_inval_ready_o;
  logic [AW-1:0] l2_evict_addr_o, l3_evict_addr_o;
  logic l3_hit_o, l3_miss_o, l3_bypass_o;
  logic l3_selfinv_hit_o, l3_wupdate_o, l3_write_idle_o;

  logic [1:0] back_inval_vld = '0;
  logic [AW-1:0] back_inval_addr [0:1];

  g6lc_l2_top #(
    .Enable(1'b1), .BYTE_SIZE(L2_BYTE_SIZE), .SET_ASSOC(L2_SET_ASSOC),
    .LINE_WIDTH(L2_LINE_WIDTH), .MSHR_DEPTH(L2_MSHR_DEPTH),
    .DATA_BANKS(L2_DATA_BANKS), .RR_EN(bit'(L2_RR_EN)),
    .FAIR_WRITES(bit'(L2_FAIR_WRITES)), .TAG_SRAM(bit'(L2_TAG_SRAM)),
    .WRITE_UPDATE(bit'(L2_WRITE_UPDATE)), .POSTED_WRITES(bit'(L2_POSTED_WRITES)),
    .WTRK_DEPTH(4), .RDTRK_DEPTH(4), .SLV_WRID_OK(1'b0), .PF_EN(1'b0),
    .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IDW),
    .AXI_USER_WIDTH(UW), .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) i_l2 (
    .clk_i(clk), .rst_ni(rst_ni),
    .slv_req_i(l1_req), .slv_resp_o(l1_resp),
    .mst_req_o(l2_mst_req), .mst_resp_i(l2_mst_resp),
    .l2_hit_o(l2_hit_o), .l2_miss_o(l2_miss_o), .l2_bypass_o(l2_bypass_o),
    .l2_mshr_full_o(l2_mshr_full_o), .l2_bank_conflict_o(l2_bank_conflict_o),
    .l2_selfinv_hit_o(l2_selfinv_hit_o), .l2_wupdate_o(l2_wupdate_o),
    .l2_wtrk_full_o(), .l2_wtrk_line_hold_o(),
    .l2_hold_r1_o(), .l2_hold_r1_wu_o(), .l2_hold_r2_o(), .l2_posted_o(),
    .l2_rdtrk_o(), .l2_posted_hold_o(),
    .l2_pf_issue_o(), .l2_pf_useful_o(), .l2_pf_drop_o(),
    .l2_evict_valid_o(l2_evict_valid_o), .l2_evict_addr_o(l2_evict_addr_o),
    .l2_evict_ready_i(l2_evict_ready_i),
    .l2_back_inval_valid_i(back_inval_vld[0]),
    .l2_back_inval_addr_i(back_inval_addr[0]),
    .l2_back_inval_ready_o(l2_back_inval_ready_o),
    .l2_write_idle_o(l2_write_idle_o),
    .l2_quiesce_i(1'b0), .l2_block_slv_i(1'b0), .l2_idle_o(),
    .l2_inval_all_i(1'b0), .l2_inval_all_done_o()
  );

  g6lc_l3_top #(
    .Enable(1'b1), .BYTE_SIZE(L3_BYTE_SIZE), .SET_ASSOC(L3_SET_ASSOC),
    .LINE_WIDTH(L3_LINE_WIDTH), .MSHR_DEPTH(L3_MSHR_DEPTH),
    .DATA_BANKS(L3_DATA_BANKS), .RR_EN(bit'(L3_RR_EN)),
    .FAIR_WRITES(bit'(L3_FAIR_WRITES)), .TAG_SRAM(bit'(L3_TAG_SRAM)),
    .WRITE_UPDATE(bit'(L3_WRITE_UPDATE)), .POSTED_WRITES(bit'(L3_POSTED_WRITES)),
    .WTRK_DEPTH(4), .RDTRK_DEPTH(4), .PF_EN(1'b0),
    .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IDW),
    .AXI_USER_WIDTH(UW), .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) i_l3 (
    .clk_i(clk), .rst_ni(rst_ni),
    .slv_req_i(l2_mst_req), .slv_resp_o(l2_mst_resp),
    .mst_req_o(l3_mst_req), .mst_resp_i(l3_mst_resp),
    .l3_hit_o(l3_hit_o), .l3_miss_o(l3_miss_o), .l3_bypass_o(l3_bypass_o),
    .l3_selfinv_hit_o(l3_selfinv_hit_o), .l3_wupdate_o(l3_wupdate_o),
    .l3_wtrk_full_o(), .l3_wtrk_line_hold_o(),
    .l3_hold_r1_o(), .l3_hold_r1_wu_o(), .l3_hold_r2_o(), .l3_posted_o(),
    .l3_rdtrk_o(), .l3_posted_hold_o(),
    .l3_pf_issue_o(), .l3_pf_useful_o(), .l3_pf_drop_o(),
    .l3_evict_valid_o(l3_evict_valid_o), .l3_evict_addr_o(l3_evict_addr_o),
    .l3_evict_ready_i(l3_evict_ready_i),
    .l3_back_inval_valid_i(back_inval_vld[1]),
    .l3_back_inval_addr_i(back_inval_addr[1]),
    .l3_back_inval_ready_o(l3_back_inval_ready_o),
    .l3_write_idle_o(l3_write_idle_o),
    .l3_quiesce_i(1'b0), .l3_block_slv_i(1'b0), .l3_idle_o(),
    .l3_inval_all_i(1'b0), .l3_inval_all_done_o()
  );

  // ---------------- golden + backing models ----------------
  // Sparse word-addressed store; unwritten words return a deterministic
  // address hash so untouched reads are still checkable.
  data_t golden_mem[addr_t];
  data_t backing_mem[addr_t];

  function automatic data_t hash_data(input addr_t a);
    return data_t'(a * 64'h9E37_79B9_7F4A_7C15 ^ 64'h517C_C1B7_2722_0A95);
  endfunction

  function automatic data_t golden(input addr_t a);
    addr_t w = a >> 3;
    if (golden_mem.exists(w) != 0) return golden_mem[w];
    return hash_data(a);
  endfunction

  task automatic golden_write(input addr_t a, input data_t d, input strb_t strb);
    addr_t w = a >> 3;
    data_t cur = golden(a);
    for (int i = 0; i < DW/8; i++)
      if (strb[i]) cur[i*8 +: 8] = d[i*8 +: 8];
    golden_mem[w] = cur;
  endtask

  function automatic data_t memory_read(input addr_t a);
    if (backing_mem.exists(a >> 3) != 0) return backing_mem[a >> 3];
    return hash_data(a);
  endfunction

  // Write-through path: apply strb to the backing word. The golden-side
  // assert from the L2 leaf is intentionally dropped here: with posted
  // writes a later op's golden update can precede an earlier write's
  // arrival, so word-level equality is not a safe invariant. Read-side
  // data compares remain the coherence oracle.
  task automatic memory_write(input addr_t a, input data_t d, input strb_t mask);
    data_t value = memory_read(a);
    for (int b = 0; b < DW/8; b++)
      if (mask[b]) value[8*b +: 8] = d[8*b +: 8];
    backing_mem[a >> 3] = value;
  endtask

  task automatic memory_install(input addr_t a, input data_t d, input strb_t mask);
    data_t value = memory_read(a);
    for (int b = 0; b < DW/8; b++)
      if (mask[b]) value[8*b +: 8] = d[8*b +: 8];
    backing_mem[a >> 3] = value;
    golden_mem[a >> 3] = value;
  endtask

  function automatic data_t amo_compute(input data_t old_v, input data_t op,
                                        input logic [5:0] atop);
    data_t result = old_v;
    if (atop == ATOP_ATOMICSWAP) result = op;
    else begin
      logic [1:0] kind = atop[5:4];
      if (kind == ATOP_ATOMICLOAD || kind == ATOP_ATOMICSTORE) begin
        unique case (atop[2:0])
          ATOP_ADD: result = old_v + op;
          ATOP_CLR: result = old_v & ~op;
          ATOP_EOR: result = old_v ^ op;
          ATOP_SET: result = old_v | op;
          default:  result = old_v;
        endcase
      end
    end
    return result;
  endfunction

  // ---------------- behavioral AXI memory (below L3) ----------------
  // One outstanding read burst + one write burst; AR/AW arbitrated by
  // acceptance order; first beat after MEM_LATENCY; INCR; strb honoured;
  // R/B carry the request id with RESP_OKAY. ATOP: only AtomicSwap
  // single-beat is supported; old data returns on R (atop[5]) and B.
  typedef struct packed { addr_t addr; logic [7:0] len; id_t id; } job_t;
  job_t rd_job;
  logic rd_active = 1'b0;
  int unsigned rd_wait = 0, rd_beat = 0;
  job_t wr_job;
  logic wr_hdr = 1'b0;
  logic wr_active = 1'b0;
  int unsigned wr_wait = 0, wr_beat = 0;
  logic [5:0] wr_atop = '0;
  logic wr_lock = 1'b0;
  logic [1:0] wr_bresp = RESP_OKAY;
  logic rd_lock = 1'b0;
  data_t amo_old_q = '0;
  logic atop_r_pending = 1'b0;
  int unsigned beat_ctr = 0;

  resp_t mem_resp;
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_resp       <= '0;
      rd_active      <= 1'b0;
      wr_hdr         <= 1'b0;
      wr_active      <= 1'b0;
      rd_wait        <= 0;
      wr_wait        <= 0;
      rd_beat        <= 0;
      wr_beat        <= 0;
      beat_ctr       <= 0;
      wr_atop        <= '0;
      wr_lock        <= 1'b0;
      wr_bresp       <= RESP_OKAY;
      rd_lock        <= 1'b0;
      amo_old_q      <= '0;
      atop_r_pending <= 1'b0;
    end else begin
      beat_ctr <= beat_ctr + 1;
      // ---- AR accept
      mem_resp.ar_ready <= !rd_active && !mem_resp.r_valid && !atop_r_pending;
      if (l3_mst_req.ar_valid && mem_resp.ar_ready) begin
        if (rd_active || mem_resp.r_valid || atop_r_pending)
          $fatal(1, "STACK_MEM_AR_OVERLAP");
        rd_job    <= '{addr: l3_mst_req.ar.addr, len: l3_mst_req.ar.len,
                       id: l3_mst_req.ar.id};
        rd_lock   <= l3_mst_req.ar.lock;
        rd_active <= 1'b1;
        rd_wait   <= MEM_LATENCY;
        rd_beat   <= 0;
      end
      // ---- R stream
      if (rd_active) begin
        if (rd_wait != 0) begin
          rd_wait <= rd_wait - 1;
          mem_resp.r_valid <= 1'b0;
        end else if (!mem_resp.r_valid || l3_mst_req.r_ready) begin
          mem_resp.r_valid <= 1'b1;
          mem_resp.r.id    <= rd_job.id;
          mem_resp.r.resp  <= RESP_OKAY;
          mem_resp.r.data  <= memory_read(rd_job.addr + addr_t'(rd_beat) * (DW/8));
          mem_resp.r.last  <= (rd_beat == rd_job.len);
          if (rd_beat == rd_job.len) begin
            rd_active <= 1'b0;
            rd_beat   <= 0;
            rd_lock   <= 1'b0;
          end else begin
            rd_beat <= rd_beat + 1;
          end
        end
      end else if (atop_r_pending) begin
        if (!mem_resp.r_valid) begin
          mem_resp.r_valid <= 1'b1;
          mem_resp.r <= '{id: wr_job.id, data: amo_old_q, resp: RESP_OKAY,
                          last: 1'b1, user: '0};
        end else if (l3_mst_req.r_ready) begin
          mem_resp.r_valid <= 1'b0;
          mem_resp.r.last  <= 1'b0;
          atop_r_pending   <= 1'b0;
        end
      end else if (mem_resp.r_valid && l3_mst_req.r_ready) begin
        mem_resp.r_valid <= 1'b0;
        mem_resp.r.last  <= 1'b0;
      end
      // ---- AW accept
      mem_resp.aw_ready <= !wr_hdr && !wr_active;
      if (l3_mst_req.aw_valid && mem_resp.aw_ready) begin
        if (wr_hdr || wr_active) $fatal(1, "STACK_MEM_AW_OVERLAP");
        mem_resp.aw_ready <= 1'b0;
        wr_job    <= '{addr: l3_mst_req.aw.addr, len: l3_mst_req.aw.len,
                       id: l3_mst_req.aw.id};
        wr_atop    <= l3_mst_req.aw.atop;
        wr_lock    <= l3_mst_req.aw.lock;
        wr_hdr     <= 1'b1;
      end
      // ---- W accept
      mem_resp.w_ready <= wr_hdr;
      if (l3_mst_req.w_valid && mem_resp.w_ready) begin
        if (!wr_hdr || l3_mst_req.w.last !== (wr_beat == wr_job.len))
          $fatal(1, "STACK_MEM_W_BAD last=%0d beat=%0d len=%0d",
                 l3_mst_req.w.last, wr_beat, wr_job.len);
        if (wr_atop != 0) begin
          if (wr_atop != ATOP_ATOMICSWAP)
            $fatal(1, "STACK_MEM_ATOP_UNSUPPORTED atop=%h", wr_atop);
          if (l3_mst_req.w.last) begin
            data_t old_v, new_v;
            old_v = memory_read(wr_job.addr);
            amo_old_q <= old_v;
            new_v = amo_compute(old_v, l3_mst_req.w.data, wr_atop);
            memory_install(wr_job.addr, new_v, l3_mst_req.w.strb);
            atop_r_pending <= wr_atop[5];
            wr_bresp <= RESP_OKAY;
          end
        end else begin
          memory_write(wr_job.addr + addr_t'(wr_beat) * (DW/8),
                       l3_mst_req.w.data, l3_mst_req.w.strb);
          wr_bresp <= RESP_OKAY;
        end
        if (l3_mst_req.w.last || wr_beat == wr_job.len) begin
          wr_hdr    <= 1'b0;
          mem_resp.w_ready <= 1'b0;
          wr_active <= 1'b1;
          wr_wait   <= MEM_LATENCY;
          wr_beat   <= 0;
        end else begin
          wr_beat <= wr_beat + 1;
        end
      end
      // ---- B emit
      if (wr_active) begin
        if (wr_wait != 0) begin
          wr_wait <= wr_wait - 1;
          mem_resp.b_valid <= 1'b0;
        end else if (!mem_resp.b_valid) begin
          mem_resp.b_valid <= 1'b1;
          mem_resp.b.id    <= wr_job.id;
          mem_resp.b.resp  <= wr_bresp;
        end else if (l3_mst_req.b_ready) begin
          mem_resp.b_valid <= 1'b0;
          wr_active        <= 1'b0;
          wr_atop          <= '0;
          wr_lock          <= 1'b0;
        end
      end else begin
        mem_resp.b_valid <= 1'b0;
      end
    end
  end
  assign l3_mst_resp = mem_resp;

  // ---------------- slave driver (proven negedge idiom) ----------------
  // Drive at negedge, sample ready #1 later — avoids the posedge race that
  // makes ready pulses invisible (the wedge tb_g6lc_l2 first hit).
  logic [63:0] lfsr = 64'h9E37_79B9_7F4A_7C15;
  int unsigned id_ctr = 0;
  int unsigned total_reads = 0, total_writes = 0;
  bit oracle_negative = 0, mut_skip_l3_inval = 0;
  int unsigned ops_target = 4000;
  int unsigned seed_arg = 1;
  int unsigned inval_hold = 1;

  function automatic logic [63:0] lfsr_next();
    lfsr ^= lfsr << 13; lfsr ^= lfsr >> 7; lfsr ^= lfsr << 17;
    return lfsr;
  endfunction
  function automatic id_t next_id();
    id_ctr = id_ctr + 1;
    return id_t'(id_ctr % 14);   // 0..13; 14=WR_ID, 15=FILL_ID reserved
  endfunction
  // Random non-zero byte-enable for writes (partial-strb coverage).
  function automatic strb_t rand_strb();
    strb_t m = strb_t'(lfsr_next() & 64'hFF);
    return (m == '0) ? strb_t'(8'h01) : m;
  endfunction

  // op ring for post-mortem on data mismatch (POD only — no strings)
  typedef struct { addr_t a; data_t d; id_t id; int unsigned code; } oprec_t;
  oprec_t op_log [0:511];
  int unsigned op_idx = 0, op_cnt = 0;
  task automatic op_mark(input int unsigned code, input addr_t a, input data_t d, input id_t id);
    op_log[op_idx % 512] = '{a: a, d: d, id: id, code: code};
    op_idx++; op_cnt++;
  endtask
  function automatic string op_name(input int unsigned c);
    case (c)
      1: return "rd";    2: return "wr";    3: return "atop";
      4: return "poke";  5: return "inval"; 6: return "ncrd";
      7: return "ncwr";  8: return "rdline";
      default: return "dir";
    endcase
  endfunction
  task automatic dump_ops(input addr_t bad);
    int unsigned n = (op_cnt < 512) ? op_cnt : 512;
    $display("[STACK] op-history last=%0d", n);
    $display("[STACK] badword a=%h golden=%h backing=%h", bad, golden(bad), memory_read(bad));
    for (int i = 0; i < n; i++) begin
      automatic int unsigned k = (op_idx - n + i) % 512;
      $display("[STACK]   op[%0d] %s id=%h a=%h d=%h", i, op_name(op_log[k].code), op_log[k].id, op_log[k].a, op_log[k].d);
    end
    $display("[STACK] l2_hit=%0d l2_miss=%0d l3_hit=%0d l3_miss=%0d cycles=%0d",
      c_l2_hit, c_l2_miss, c_l3_hit, c_l3_miss, cycles);
  endtask

  // Hierarchy probe for the mismatch path: dump the L3 inner tag port state
  // (portable across TAG_SRAM flavours) plus the inner FSM state, so a
  // stale-hit cause can be classified. index_i/tag_i/lookup_i are the tag
  // module's live compare inputs — they show what the last lookup saw.
  task automatic dump_l3_probe(input int set);
    $display("[STACK] probe l3set=%0d l3idx=%0d l3tag=%h l3lkp=%b l3hit=%b l3way=%0d l3wval=%b l3rowv=%b l3state=%0d",
      set,
      i_l3.i_l3_as_l2.gen_l2.i_tag.index_i,
      i_l3.i_l3_as_l2.gen_l2.i_tag.tag_i,
      i_l3.i_l3_as_l2.gen_l2.i_tag.lookup_i,
      i_l3.i_l3_as_l2.gen_l2.i_tag.hit_o,
      i_l3.i_l3_as_l2.gen_l2.i_tag.way_o,
      i_l3.i_l3_as_l2.gen_l2.i_tag.way_valid_o,
      i_l3.i_l3_as_l2.gen_l2.i_tag.row_valid_o,
      i_l3.i_l3_as_l2.gen_l2.state_q);
    $display("[STACK] probe dbg l3binv=%0d l3minv=%0d l2minv=%0d",
      dbg_l3binv, dbg_l3minv, dbg_l2minv);
  endtask

  task automatic axi_read(input addr_t a, input logic [3:0] cache,
                          input int unsigned beats = 2,
                          input logic [1:0] expected_resp = RESP_OKAY,
                          input string tag = "", input int unsigned opc = 0);
    int unsigned beats_got = 0;
    int unsigned guard = 0;
    id_t req_id = next_id();
    longint unsigned m_l2h = c_l2_hit, m_l2m = c_l2_miss,
                     m_l3h = c_l3_hit, m_l3m = c_l3_miss;
    op_mark(opc, a, '0, req_id);
    if (beats == 0 || beats > BEATS || a[2:0] != 0) $fatal(1, "STACK_BAD_READ a=%h", a);
    @(negedge clk);
    l1_req.ar = '0;
    l1_req.ar.addr = a;
    l1_req.ar.len = 8'(beats - 1);
    l1_req.ar.id = req_id;
    l1_req.ar.size = 3;
    l1_req.ar.burst = BURST_INCR;
    l1_req.ar.cache = cache;
    l1_req.ar_valid = 1'b1;
    l1_req.r_ready = 1'b0;
    total_reads++;
    while (1) begin
      #1;
      if (l1_resp.ar_ready) break;
      @(negedge clk);
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG ar_ready a=%h tag=%s", a, tag);
    end
    @(negedge clk);
    l1_req.ar_valid = 1'b0;
    guard = 0;
    while (1) begin
      l1_req.r_ready = 1'b1;
      @(posedge clk);
      guard++;
      if (l1_resp.r_valid && l1_req.r_ready) begin
        if (l1_resp.r.id !== req_id || l1_resp.r.resp !== expected_resp ||
            l1_resp.r.last !== (beats_got == beats - 1))
          $fatal(1, "STACK_RESP a=%h beat=%0d id=%h/%h resp=%h/%h last=%b/%b tag=%s",
                 a, beats_got, l1_resp.r.id, req_id, l1_resp.r.resp, expected_resp,
                 l1_resp.r.last, (beats_got == beats - 1), tag);
        begin
          automatic addr_t ea = a + addr_t'(beats_got) * (DW/8);
          automatic data_t eg = golden(ea);
          if (oracle_negative && tag == "p1_reread" && beats_got == 0)
            eg = eg ^ 64'h1;   // flip one expected bit -> must mismatch
          if (l1_resp.r.data !== eg) begin
            dump_ops(ea);
            $display("[STACK] read-hit-miss dl2h=%0d dl2m=%0d dl3h=%0d dl3m=%0d",
              c_l2_hit-m_l2h, c_l2_miss-m_l2m, c_l3_hit-m_l3h, c_l3_miss-m_l3m);
            // Hierarchy probe: is the stale line still tagged-valid in L3?
            // L3 geometry: NUM_SETS=64 -> index=addr[11:6]; SET_ASSOC=8.
            dump_l3_probe(int'(ea[11:6]));
            $fatal(1, "STACK_DATA_MISMATCH addr=%h got=%h exp=%h phase=%s",
                   ea, l1_resp.r.data, eg, tag);
          end
        end
        beats_got++;
        if (l1_resp.r.last) break;
      end
      if (guard >= WATCHDOG) $fatal(1, "STACK_HANG r a=%h tag=%s", a, tag);
      @(negedge clk);
    end
    @(negedge clk);
    l1_req.r_ready = 1'b0;
    if (beats_got != beats) $fatal(1, "STACK_INCOMPLETE_READ a=%h", a);
    ops_done = ops_done + 1;
  endtask

  task automatic axi_write(input addr_t a, input data_t d, input logic [3:0] cache,
                           input strb_t mask = '1, input string tag = "", input int unsigned opc = 0);
    int unsigned guard = 0;
    id_t req_id = next_id();
    op_mark(opc, a, d, req_id);
    @(negedge clk);
    l1_req.aw = '0;
    l1_req.aw.addr = a;
    l1_req.aw.id = req_id;
    l1_req.aw.len = 0;
    l1_req.aw.size = 3;
    l1_req.aw.burst = BURST_INCR;
    l1_req.aw.cache = cache;
    l1_req.aw_valid = 1'b1;
    l1_req.b_ready = 1'b0;
    total_writes++;
    while (1) begin
      #1;
      if (l1_resp.aw_ready) break;
      @(negedge clk);
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG aw_ready a=%h tag=%s", a, tag);
    end
    @(negedge clk);
    l1_req.aw_valid = 1'b0;
    l1_req.w = '0;
    l1_req.w.data = d;
    l1_req.w.strb = mask;
    golden_write(a, d, mask);
    l1_req.w.last = 1'b1;
    l1_req.w_valid = 1'b1;
    guard = 0;
    while (1) begin
      #1;
      if (l1_resp.w_ready) break;
      @(negedge clk);
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG w_ready a=%h tag=%s", a, tag);
    end
    @(negedge clk);
    l1_req.w_valid = 1'b0;
    guard = 0;
    while (1) begin
      l1_req.b_ready = 1'b1;
      @(posedge clk);
      if (l1_resp.b_valid && l1_req.b_ready) begin
        if (l1_resp.b.id !== req_id || l1_resp.b.resp !== RESP_OKAY)
          $fatal(1, "STACK_RESP_WR a=%h id=%h/%h resp=%h tag=%s",
                 a, l1_resp.b.id, req_id, l1_resp.b.resp, tag);
        break;
      end
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG b a=%h tag=%s", a, tag);
      @(negedge clk);
    end
    @(negedge clk);
    l1_req.b_ready = 1'b0;
    ops_done = ops_done + 1;
  endtask

  // One-beat ATOP through the stack. Cache attr = CACHEABLE, matching the
  // proven tb_g6lc_l2 AMO path (the L1 AMO issue path is cacheable so the
  // stack sees a normal cached atomic). Only ATOP_ATOMICSWAP is driven.
  task automatic axi_atop(input addr_t a, input data_t operand,
                          input string tag = "", input int unsigned opc = 0);
    int unsigned guard = 0;
    bit got_b = 0, got_r = 0;
    id_t req_id = next_id();
    data_t exp_old = golden(a);
    op_mark(opc, a, operand, req_id);
    @(negedge clk);
    l1_req.aw = '0;
    l1_req.aw.addr = a;
    l1_req.aw.id = req_id;
    l1_req.aw.len = 0;
    l1_req.aw.size = 3;
    l1_req.aw.burst = BURST_INCR;
    l1_req.aw.cache = CACHEABLE;
    l1_req.aw.atop = ATOP_ATOMICSWAP;
    l1_req.aw_valid = 1'b1;
    l1_req.b_ready = 1'b0;
    l1_req.r_ready = 1'b0;
    total_writes++;
    while (1) begin
      #1;
      if (l1_resp.aw_ready) break;
      @(negedge clk);
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG atop_aw a=%h tag=%s", a, tag);
    end
    @(negedge clk);
    l1_req.aw_valid = 1'b0;
    l1_req.w = '{data: operand, strb: '1, last: 1'b1, user: '0};
    l1_req.w_valid = 1'b1;
    guard = 0;
    while (1) begin
      #1;
      if (l1_resp.w_ready) break;
      @(negedge clk);
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG atop_w a=%h tag=%s", a, tag);
    end
    @(negedge clk);
    l1_req.w_valid = 1'b0;
    guard = 0;
    while (!got_b || !got_r) begin
      l1_req.b_ready = 1'b1;
      l1_req.r_ready = 1'b1;
      @(posedge clk);
      if (l1_resp.b_valid && l1_req.b_ready) begin
        if (l1_resp.b.id !== req_id || l1_resp.b.resp !== RESP_OKAY)
          $fatal(1, "STACK_RESP_ATOP_B a=%h id=%h/%h resp=%h tag=%s",
                 a, l1_resp.b.id, req_id, l1_resp.b.resp, tag);
        got_b = 1;
      end
      if (l1_resp.r_valid && l1_req.r_ready) begin
        if (l1_resp.r.id !== req_id || l1_resp.r.last !== 1'b1 ||
            l1_resp.r.data !== exp_old)
          $fatal(1, "STACK_ATOP_OLD a=%h got=%h exp=%h tag=%s",
                 a, l1_resp.r.data, exp_old, tag);
        got_r = 1;
      end
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG atop_resp a=%h tag=%s", a, tag);
      @(negedge clk);
    end
    l1_req.b_ready = 1'b0;
    l1_req.r_ready = 1'b0;
    ops_done = ops_done + 1;
  endtask

  task automatic pulse_inval(input int lvl, input addr_t line_addr);
    int unsigned guard = 0;
    int unsigned held = 0;
    if (lvl == 0) begin
      back_inval_vld[0] = 1'b1;
      back_inval_addr[0] = line_addr;
    end else begin
      back_inval_vld[1] = 1'b1;
      back_inval_addr[1] = line_addr;
    end
    @(negedge clk);
    while (back_inval_vld[lvl]) begin
      if (back_inval_vld[lvl] && (lvl == 0 ? l2_back_inval_ready_o
                                          : l3_back_inval_ready_o)) begin
        held = held + 1;
        if (held >= inval_hold) back_inval_vld[lvl] = 1'b0;
      end
      @(negedge clk);
      if (++guard >= WATCHDOG) $fatal(1, "STACK_HANG backinval l%0d a=%h", lvl, line_addr);
    end
    // Deferred tag-match clear lands ~2 cycles after the offer; let it commit.
    repeat (4) @(negedge clk);
  endtask

  // ---------------- back-inval + poke helpers ----------------
  task automatic do_backinval(input addr_t line_addr, input bit skip_l3);
    longint unsigned si_l2, si_l3;
    op_mark(5, line_addr, '0, '0);
    // Coherent ordering, top-down: quiesce in-flight writebacks, invalidate
    // L2 first so it stops sourcing stale L2->L3 writes (and so any dirty
    // victim it emits lands before L3 is dropped), settle again, then
    // invalidate L3. The master is idle inside this task, so no new L1
    // traffic can restart the fill/write machinery mid-sequence.
    repeat (128) @(negedge clk);
    si_l2 = c_l2_selfinv;
    pulse_inval(0, line_addr);
    repeat (128) @(negedge clk);
    si_l3 = c_l3_selfinv;
    if (!skip_l3) pulse_inval(1, line_addr);
    $display("[STACK] inval a=%h l2_si=%0d l3_si=%0d",
             line_addr, c_l2_selfinv - si_l2, c_l3_selfinv - si_l3);
  endtask

  // Non-coherent DMA poke: updates backing + golden directly (architectural
  // truth), bypassing both caches.
  task automatic mem_poke(input addr_t a, input data_t d);
    addr_t w = a >> 3;
    op_mark(4, a, d, '0);
    backing_mem[w] = d;
    golden_mem[w]  = d;
  endtask

  // ---------------- phases ----------------
  longint unsigned ph_l2h, ph_l2m, ph_l3h, ph_l3m, ph_l2si, ph_l2wu, ph_l3si, ph_l3wu;
  task automatic phase_begin();
    ph_l2h=c_l2_hit; ph_l2m=c_l2_miss; ph_l3h=c_l3_hit; ph_l3m=c_l3_miss;
    ph_l2si=c_l2_selfinv; ph_l2wu=c_l2_wupd; ph_l3si=c_l3_selfinv; ph_l3wu=c_l3_wupd;
  endtask
  task automatic phase_end(input string name);
    $display("[STACK] phase %s l2_hit=%0d l2_miss=%0d l2_selfinv=%0d l2_wupd=%0d l3_hit=%0d l3_miss=%0d l3_selfinv=%0d l3_wupd=%0d",
      name, c_l2_hit-ph_l2h, c_l2_miss-ph_l2m, c_l2_selfinv-ph_l2si, c_l2_wupd-ph_l2wu,
      c_l3_hit-ph_l3h, c_l3_miss-ph_l3m, c_l3_selfinv-ph_l3si, c_l3_wupd-ph_l3wu);
  endtask

  addr_t p1_addr [0:15];
  localparam addr_t P1_BASE = 64'h1000_0000;
  localparam addr_t P7_BASE = 64'h2000_0000;

  task automatic phase_p1();
    longint unsigned l3h_pre;
    phase_begin();
    // 8 lines at stride 4096: collide in every L2 set (16 sets * 64B) and
    // every L3 set (64 sets * 64B). L2 keeps 4, L3 keeps all 8.
    for (int i = 0; i < 8; i++) p1_addr[i] = P1_BASE + addr_t'(i) * 4096;
    for (int i = 0; i < 8; i++) axi_read(p1_addr[i], CACHEABLE, 2, RESP_OKAY, "p1_fill");
    l3h_pre = c_l3_hit;
    for (int i = 0; i < 8; i++) axi_read(p1_addr[i], CACHEABLE, 2, RESP_OKAY, "p1_reread");
    if (c_l3_hit - l3h_pre < 4) $fatal(1, "STACK_NO_L3_HIT delta=%0d", c_l3_hit - l3h_pre);
    phase_end("l3_hit_service");
  endtask

  task automatic phase_p2();
    phase_begin();
    // 4 fresh same-L2-set lines evict the L2 copies of p1 lines; the L3
    // copies of lines 4..7 survive (L3 RR evicts the oldest ways 0..3).
    for (int i = 8; i < 12; i++) p1_addr[i] = P1_BASE + addr_t'(i) * 4096;
    for (int i = 8; i < 12; i++) axi_read(p1_addr[i], CACHEABLE, 2, RESP_OKAY, "p2_evict");
    // p1_addr[4]: expected L3-resident, L2-evicted.
    axi_write(p1_addr[4], 64'hDEAD_BEEF_1234_5678, CACHEABLE, '1, "write_l3_only");
    axi_read (p1_addr[4], CACHEABLE, 2, RESP_OKAY, "write_l3_only");
    phase_end("write_l3_only");
  endtask

  task automatic phase_p3();
    phase_begin();
    p1_addr[12] = P1_BASE + addr_t'(12) * 4096;
    axi_read (p1_addr[12], CACHEABLE, 2, RESP_OKAY, "write_both");
    axi_read (p1_addr[12], CACHEABLE, 2, RESP_OKAY, "write_both");
    axi_write(p1_addr[12], 64'hCAFE_1234_FEDC_BA98, CACHEABLE, '1, "write_both");
    axi_read (p1_addr[12], CACHEABLE, 2, RESP_OKAY, "write_both");
    phase_end("write_both");
  endtask

  task automatic phase_p4();
    phase_begin();
    p1_addr[13] = P1_BASE + addr_t'(13) * 4096;
    axi_read (p1_addr[13], CACHEABLE, 2, RESP_OKAY, "atop_both");
    axi_read (p1_addr[13], CACHEABLE, 2, RESP_OKAY, "atop_both");
    axi_atop  (p1_addr[13], 64'h1122_3344_5566_7788, "atop_both");
    axi_read (p1_addr[13], CACHEABLE, 2, RESP_OKAY, "atop_both");
    phase_end("atop_both");
  endtask

  task automatic phase_p5();
    phase_begin();
    p1_addr[14] = P1_BASE + addr_t'(14) * 4096;
    axi_read (p1_addr[14], CACHEABLE, 2, RESP_OKAY, "nc_write_alias");
    // NC write to the cacheable-resident line, then a cached read must
    // observe the new data (the stack must invalidate/snoop, not serve stale).
    axi_write(p1_addr[14], 64'h0BAD_F00D_1234_5678, NONCACHE, '1, "nc_write_alias");
    axi_read (p1_addr[14], CACHEABLE, 2, RESP_OKAY, "nc_write_alias");
    phase_end("nc_write_alias");
  endtask

  task automatic phase_p6();
    phase_begin();
    p1_addr[15] = P1_BASE + addr_t'(15) * 4096;
    axi_read (p1_addr[15], CACHEABLE, 2, RESP_OKAY, "dma_backinval");
    axi_read (p1_addr[15], CACHEABLE, 2, RESP_OKAY, "dma_backinval");
    // DMA writes memory directly; both cache levels must be invalidated.
    for (int b = 0; b < 8; b++)
      mem_poke(p1_addr[15] + addr_t'(b) * 8, 64'h5A00_0000_0000_0000 | 64'(b));
    do_backinval(p1_addr[15] & ~addr_t'(LINE_BYTES - 1), mut_skip_l3_inval);
    axi_read (p1_addr[15], CACHEABLE, 2, RESP_OKAY, "dma_backinval");
    phase_end("dma_backinval");
  endtask

  task automatic phase_p7();
    phase_begin();
    for (int i = 0; i < ops_target; i++) begin
      // 384 consecutive lines: 24 per L2 set (>4 ways -> L2 thrashes) but
      // only 6 per L3 set (<8 ways -> L3 mostly retains).
      automatic addr_t a = P7_BASE + addr_t'(lfsr_next() % 384) * LINE_BYTES;
      automatic int sel = int'(lfsr_next() % 100);
      if (sel < 45) begin
        // cached read: mostly 2 beats, ~1-in-10 a full 64B line
        if ((lfsr_next() % 10) == 0) axi_read(a & ~addr_t'(LINE_BYTES-1), CACHEABLE, BEATS, RESP_OKAY, "p7_rdline", 8);
        else                        axi_read(a, CACHEABLE, 2, RESP_OKAY, "p7_rd", 1);
      end else if (sel < 75) begin
        axi_write(a, lfsr_next(), CACHEABLE, rand_strb(), "p7_wr", 2);
      end else if (sel < 83) begin
        axi_write(a, lfsr_next(), NONCACHE, rand_strb(), "p7_ncwr", 7);
      end else if (sel < 90) begin
        axi_read(a, NONCACHE, 1, RESP_OKAY, "p7_ncrd", 6);
      end else if (sel < 95) begin
        axi_atop(a, lfsr_next(), "p7_atop", 3);
      end else begin
        automatic addr_t la = a & ~addr_t'(LINE_BYTES - 1);
        mem_poke(la, lfsr_next());
        do_backinval(la, 0);
      end
    end
    phase_end("random");
  endtask

  // ---------------- stimulus ----------------
  initial begin
    l1_req = '0;
    back_inval_addr[0] = '0;
    back_inval_addr[1] = '0;
    void'($value$plusargs("seed=%d", seed_arg));
    lfsr = 64'(seed_arg) * 64'h9E37_79B9_7F4A_7C15 + 64'h243F_6A88_85A3_08D3;
    void'($value$plusargs("ops=%d", ops_target));
    void'($value$plusargs("oracle_negative=%d", oracle_negative));
    void'($value$plusargs("mut_skip_l3_inval=%d", mut_skip_l3_inval));
    void'($value$plusargs("inval_hold=%d", inval_hold));
    $display("[STACK] config l2=%0dB/%0dway l3=%0dB/%0dway lat=%0d wu2=%0d pw2=%0d ts2=%0d wu3=%0d pw3=%0d ts3=%0d",
      L2_BYTE_SIZE, L2_SET_ASSOC, L3_BYTE_SIZE, L3_SET_ASSOC, MEM_LATENCY,
      L2_WRITE_UPDATE, L2_POSTED_WRITES, L2_TAG_SRAM,
      L3_WRITE_UPDATE, L3_POSTED_WRITES, L3_TAG_SRAM);
    repeat (8) @(negedge clk);
    rst_ni = 1'b1;
    repeat (4) @(negedge clk);

    phase_p1();
    phase_p2();
    phase_p3();
    phase_p4();
    phase_p5();
    phase_p6();
    phase_p7();

    @(negedge clk); rst_ni = 1'b0;
    repeat (4) @(negedge clk);

    $display("[STACK] totals ops=%0d l2_hit=%0d l2_miss=%0d l3_hit=%0d l3_miss=%0d l3_selfinv=%0d l3_wupd=%0d cycles=%0d",
      ops_done, c_l2_hit, c_l2_miss, c_l3_hit, c_l3_miss,
      c_l3_selfinv, c_l3_wupd, cycles);
    if (c_l3_hit < 100) $fatal(1, "STACK_NO_L3_HIT total=%0d", c_l3_hit);
    $display("[STACK] RESULT pass");
    $finish;
  end

endmodule
