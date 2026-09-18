// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_l2_hum — hit-under-miss contract for g6lc_l2_top.
//
// The base bench (tb_g6lc_l2) drives strictly one outstanding slave AR at a
// time, so it cannot observe same-line merging at all. This bench issues
// concurrent reads and checks the contract that matters:
//   * a further cacheable read to the line currently being filled is accepted
//     and parked as an MSHR waiter (observed directly, not inferred),
//   * every requester gets its OWN beats back (its addr/len/size, not the
//     primary's) with its own AXI id,
//   * one DRAM fill serves all of them,
//   * requests that must NOT merge (other line / non-cacheable / locked) are
//     refused while the fill is outstanding and served correctly afterwards.
//
// Data returned is checked against an independent reference function, never
// against the DUT's own state.

`timescale 1ns/1ps

module tb_g6lc_l2_hum;
  import g6lc_l2_pkg::*;
  import g6lc_l2_tb_pkg::*;

  parameter bit CHAIN_L3=1'b0;
  parameter bit RR_EN=1'b0;
  parameter int unsigned BYTE_SIZE   = 4096;
  parameter int unsigned SET_ASSOC   = 4;
  parameter int unsigned LINE_WIDTH  = 512;
  parameter int unsigned MSHR_DEPTH  = 4;
  parameter int unsigned DATA_BANKS  = 2;
  parameter int unsigned MEM_LATENCY = 8;
  parameter int unsigned MAX_WAITERS = 4;   // mirrors the DUT instantiation

  localparam int unsigned LINE_BYTES = LINE_WIDTH / 8;
  localparam int unsigned BEATS      = LINE_WIDTH / DW;
  localparam int unsigned OFF_BITS   = l2_offset_bits(LINE_WIDTH);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  req_t  slv_req;
  resp_t slv_resp;
  req_t  mst_req;
  resp_t mst_resp;
  req_t cache_req;
  resp_t cache_resp;

  logic l2_hit, l2_miss, l2_bypass, l2_mshr_full, l2_bank_conf, evict_v;
  addr_t evict_addr;
  logic evict_ready = 1'b1;
  logic back_inval_ready;
  logic back_inval_valid = 1'b0;
  addr_t back_inval_addr = '0;
  // Inclusive source selection: a directed stimulus and the outer cache's own
  // victim share the L2's single back-invalidation port, so the fixture has to
  // arbitrate exactly as the cluster does. Leaving the outer victim
  // unconnected (as this fixture first did) never exercises inclusion at all.
  logic inval_valid;
  addr_t inval_addr;
  logic l3_evict_valid;
  addr_t l3_evict_addr;
  int unsigned l3_evict_count = 0;
  assign inval_valid = back_inval_valid || (CHAIN_L3 && l3_evict_valid);
  assign inval_addr  = back_inval_valid ? back_inval_addr : l3_evict_addr;

  g6lc_l2_top #(
      .Enable      (1'b1),
      .BYTE_SIZE   (BYTE_SIZE),
      .SET_ASSOC   (SET_ASSOC),
      .LINE_WIDTH  (LINE_WIDTH),
      .MSHR_DEPTH  (MSHR_DEPTH),
      .DATA_BANKS  (DATA_BANKS),
      .RR_EN       (RR_EN),
      .AXI_ADDR_WIDTH (AW),
      .AXI_DATA_WIDTH (DW),
      .AXI_ID_WIDTH   (IDW),
      .AXI_USER_WIDTH (UW),
      .axi_req_t   (req_t),
      .axi_resp_t  (resp_t)
  ) dut (
      .clk_i (clk),
      .rst_ni(rst_n),
      .slv_req_i  (slv_req),
      .slv_resp_o (slv_resp),
      .mst_req_o  (cache_req),
      .mst_resp_i (cache_resp),
      .l2_hit_o           (l2_hit),
      .l2_miss_o          (l2_miss),
      .l2_bypass_o        (l2_bypass),
      .l2_mshr_full_o     (l2_mshr_full),
      .l2_bank_conflict_o (l2_bank_conf),
      .l2_evict_valid_o   (evict_v),
      .l2_evict_addr_o    (evict_addr),
      .l2_evict_ready_i   (evict_ready),
      .l2_back_inval_valid_i (inval_valid),
      .l2_back_inval_addr_i  (inval_addr),
      .l2_back_inval_ready_o (back_inval_ready)
  );

  if(CHAIN_L3)begin : gen_l3_chain
    req_t cut_req;
    resp_t cut_resp;
    axi_cut #(
      .Bypass(1'b0),.aw_chan_t(aw_chan_t),.w_chan_t(w_chan_t),.b_chan_t(b_chan_t),
      .ar_chan_t(ar_chan_t),.r_chan_t(r_chan_t),.req_t(req_t),.resp_t(resp_t)
    ) i_cut (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(cache_req),.slv_resp_o(cache_resp),
      .mst_req_o(cut_req),.mst_resp_i(cut_resp)
    );
    g6lc_l3_top #(
      .Enable(1'b1),.BYTE_SIZE(2048),.SET_ASSOC(2),.LINE_WIDTH(LINE_WIDTH),
      .MSHR_DEPTH(2),.DATA_BANKS(2),.AXI_ADDR_WIDTH(AW),.AXI_DATA_WIDTH(DW),
      .AXI_ID_WIDTH(IDW),.AXI_USER_WIDTH(UW),.axi_req_t(req_t),.axi_resp_t(resp_t)
    ) i_l3 (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(cut_req),.slv_resp_o(cut_resp),
      .mst_req_o(mst_req),.mst_resp_i(mst_resp),
      .l3_hit_o(),.l3_miss_o(),.l3_bypass_o(),
      .l3_evict_valid_o(l3_evict_valid),
      .l3_evict_addr_o(l3_evict_addr),
      // The directed stimulus owns the port when it is driving.
      .l3_evict_ready_i(back_inval_ready && !back_inval_valid)
    );
    always_ff @(posedge clk) if(rst_n && l3_evict_valid && back_inval_ready &&
                                !back_inval_valid)
      l3_evict_count <= l3_evict_count + 1;
  end else begin : gen_l2_only
    assign mst_req=cache_req;
    assign cache_resp=mst_resp;
    assign l3_evict_valid=1'b0;
    assign l3_evict_addr='0;
  end
  assert property(@(posedge clk)disable iff(!rst_n)
    cache_req.ar_valid && !cache_resp.ar_ready |=> cache_req.ar_valid && $stable(cache_req.ar))
    else $fatal(1,"HUM_CACHE_AR_STABILITY");

  // Replacement-metadata port scheduling. The pointer read belongs to the
  // request being accepted and cannot be repeated, so an install sharing the
  // single port must not displace it. Counted structurally at the RAM
  // interface: rr_collide is engagement, rr_read_lost is the contract.
  int unsigned rr_collide=0, rr_read_lost=0;
  if(RR_EN)begin : gen_rr_mon
    always_ff @(posedge clk) if(rst_n) begin
      if(dut.gen_l2.gen_rr.read_req && dut.gen_l2.rr_adv) rr_collide <= rr_collide + 1;
      if(dut.gen_l2.gen_rr.read_req &&
         !(dut.gen_l2.gen_rr.i_metadata.req_i && !dut.gen_l2.gen_rr.i_metadata.we_i &&
           dut.gen_l2.gen_rr.i_metadata.addr_i ==
           dut.gen_l2.idx_of(slv_req.ar.addr)))
        rr_read_lost <= rr_read_lost + 1;
    end
  end

  // Requests leaving the L2 under test. Counting at this boundary keeps the
  // refetch checks valid when an outer cache absorbs them.
  int unsigned l2_ar_count=0, l2_ar_mark=0;
  always_ff @(posedge clk) if(rst_n && cache_req.ar_valid && cache_resp.ar_ready)
    l2_ar_count <= l2_ar_count + 1;

  // ---- independent reference memory --------------------------------------
  function automatic data_t reference_word(input addr_t a);
    reference_word = {a[31:0], ~a[31:0]} ^ 64'h5a5a_a5a5_1234_9876;
  endfunction

  // Beat i of a burst starting at `a`: the DUT indexes within the line and
  // wraps at the line boundary, so the reference must wrap identically.
  function automatic data_t reference_beat(input addr_t a, input int unsigned i);
    addr_t base  = a & ~addr_t'(LINE_BYTES - 1);
    int unsigned first = int'((a >> 3) % BEATS);
    reference_beat = reference_word(base + addr_t'(((first + i) % BEATS) * 8));
  endfunction

  // ---- memory model: serves any AR after MEM_LATENCY cycles ---------------
  localparam int RD_DEPTH=16;
  typedef struct packed {
    addr_t addr;
    id_t id;
    logic [7:0] len;
    int unsigned beat;
    int unsigned delay_cycles;
  } read_job_t;
  read_job_t jobs[RD_DEPTH];
  int unsigned rd_head=0,rd_tail=0,rd_count=0;
  int unsigned mem_ar_count=0,mem_outstanding=0,mem_peak=0;
  logic memory_hold=1'b0;
  logic memory_ar_hold=1'b0;
  int unsigned install_conflicts=0;
  logic atomic_r_hold=1'b0,memory_b_hold=1'b0;
  logic wr_active=1'b0,wr_data_done=1'b0,wr_b_pending=1'b0,wr_r_pending=1'b0,wr_r_issued=1'b0;
  logic r_is_atop=1'b0;
  aw_chan_t wr_header;
  int unsigned mem_atomic_r=0;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      mst_resp.ar_ready <= 1'b0;
      mst_resp.aw_ready <= 1'b0;
      mst_resp.w_ready <= 1'b0;
      mst_resp.b_valid <= 1'b0;
      mst_resp.r_valid <= 1'b0;
      mst_resp.r <= '0;
      rd_head=0;rd_tail=0;rd_count=0;
      mem_ar_count=0;mem_outstanding=0;mem_peak=0;
      wr_active=0;wr_data_done=0;wr_b_pending=0;wr_r_pending=0;wr_r_issued=0;
      r_is_atop=0;wr_header='0;mem_atomic_r=0;
      for(int i=0;i<RD_DEPTH;i++)jobs[i]='0;
    end else begin
      automatic bit take_ar = mst_req.ar_valid && mst_resp.ar_ready;
      automatic bit take_aw=mst_req.aw_valid && mst_resp.aw_ready;
      automatic bit take_w=mst_req.w_valid && mst_resp.w_ready;
      if(mst_resp.r_valid && mst_req.r_ready && mst_resp.r.last)begin
        if(r_is_atop)begin wr_r_pending=1'b0;wr_r_issued=1'b0;mem_atomic_r++;end
        else mem_outstanding--;
      end
      if(mst_resp.b_valid && mst_req.b_ready)begin
        mst_resp.b_valid<=1'b0;wr_b_pending=1'b0;
      end
      if(wr_b_pending && !memory_b_hold && !mst_resp.b_valid)begin
        mst_resp.b_valid<=1'b1;
        mst_resp.b<='{id:wr_header.id,resp:axi_pkg::RESP_OKAY,user:'0};
      end
      for(int i=0;i<RD_DEPTH;i++)
        if(jobs[i].delay_cycles!=0)jobs[i].delay_cycles--;
      if(!mst_resp.r_valid || mst_req.r_ready) begin
        mst_resp.r_valid <= 1'b0;
        r_is_atop=1'b0;
        if(wr_r_pending && !wr_r_issued && !atomic_r_hold)begin
          mst_resp.r_valid<=1'b1;
          mst_resp.r<='{id:wr_header.id,data:reference_word(wr_header.addr),
                        resp:axi_pkg::RESP_OKAY,last:1'b1,user:'0};
          r_is_atop=1'b1;wr_r_issued=1'b1;
        end else
        if(rd_count!=0 && jobs[rd_head].delay_cycles==0 && !memory_hold && !(wr_r_pending && jobs[rd_head].id==wr_header.id))begin
          mst_resp.r_valid <= 1'b1;
          mst_resp.r.id <= jobs[rd_head].id;
          mst_resp.r.resp <= axi_pkg::RESP_OKAY;
          mst_resp.r.data <= reference_word(jobs[rd_head].addr + addr_t'(jobs[rd_head].beat*8));
          mst_resp.r.last <= (jobs[rd_head].beat==int'(jobs[rd_head].len));
          if(jobs[rd_head].beat==int'(jobs[rd_head].len))begin
            rd_head=(rd_head+1)%RD_DEPTH;rd_count--;
          end else jobs[rd_head].beat++;
        end
      end
      if(take_ar)begin
        if(rd_count>=RD_DEPTH)$fatal(1,"HUM_MEMORY_OVERFLOW");
        jobs[rd_tail]='{addr:mst_req.ar.addr,id:mst_req.ar.id,len:mst_req.ar.len,
                        beat:0,delay_cycles:MEM_LATENCY};
        rd_tail=(rd_tail+1)%RD_DEPTH;rd_count++;
        mem_ar_count++;mem_outstanding++;
        if(mem_outstanding>mem_peak)mem_peak=mem_outstanding;
      end
      if(take_aw)begin
        if(wr_active || mst_req.aw.len!=0)$fatal(1,"HUM_WRITE_SHAPE");
        wr_active=1'b1;wr_data_done=1'b0;wr_header=mst_req.aw;
      end
      if(take_w)begin
        if(!wr_active || wr_data_done || !mst_req.w.last)$fatal(1,"HUM_WRITE_DATA");
        wr_data_done=1'b1;wr_b_pending=1'b1;
        wr_r_pending=wr_header.atop[5];wr_r_issued=1'b0;
      end
      if(wr_data_done && !wr_b_pending && !wr_r_pending)begin
        wr_active=1'b0;wr_data_done=1'b0;
      end
      mst_resp.aw_ready<=!wr_active;
      mst_resp.w_ready<=wr_active && !wr_data_done;
      mst_resp.ar_ready <= (rd_count < RD_DEPTH) && !memory_ar_hold;
    end
  end

  // ---- observed DUT events (for engagement, never for data checking) ------
  int unsigned merges = 0;
  int unsigned fills  = 0;
  always_ff @(posedge clk) if (rst_n) begin
    if (dut.gen_l2.mshr_alloc && dut.gen_l2.mshr_merged) merges <= merges + 1;
    if (dut.gen_l2.tag_write && !dut.gen_l2.bank_conflict) fills <= fills + 1;
  end

  always @(posedge clk) if(rst_n)begin
    if(dut.gen_l2.bank_conflict)install_conflicts++;
    if(dut.gen_l2.collect_cnt_q>dut.gen_l2.issued_cnt_q ||
       dut.gen_l2.issued_cnt_q>dut.gen_l2.fifo_cnt_q ||
       dut.gen_l2.fifo_cnt_q>MSHR_DEPTH)$fatal(1,"HUM_FILL_COUNT_BOUNDS");
    if(dut.gen_l2.tag_write && dut.gen_l2.bank_conflict)$fatal(1,"HUM_TAG_WITHOUT_DATA");
  end

  assert property(@(posedge clk)disable iff(!rst_n)
    mst_req.ar_valid && !mst_resp.ar_ready |=> mst_req.ar_valid && $stable(mst_req.ar))
    else $fatal(1,"HUM_AR_STABILITY");
  assert property(@(posedge clk)disable iff(!rst_n)
    slv_req.ar_valid && !slv_resp.ar_ready |=> slv_req.ar_valid && $stable(slv_req.ar))
    else $fatal(1,"HUM_INPUT_AR_STABILITY");
  assert property(@(posedge clk)disable iff(!rst_n)
    slv_resp.r_valid && !slv_req.r_ready |=> slv_resp.r_valid && $stable(slv_resp.r))
    else $fatal(1,"HUM_R_STABILITY");

  // ---- concurrent slave-side request driver ------------------------------
  typedef struct {
    id_t         id;
    addr_t       addr;
    int unsigned len;
    logic [3:0]  cache;
    bit          lock;
  } stim_t;

  stim_t pending[$];
  int unsigned issued = 0, completed = 0, expected_total = 0;
  int unsigned beats_seen[16];
  stim_t expected[16][64];
  int unsigned exp_head[16], exp_tail[16];
  int unsigned requested=0;
  int unsigned order[$];
  bit          negative;
  int unsigned start_cyc = 0, end_cyc = 0, cyc = 0;
  int          scenario;

  bit b_expected=0;
  id_t expected_bid;
  int unsigned write_completed=0;
  always @(posedge clk)if(rst_n && slv_resp.b_valid && slv_req.b_ready)begin
    if(!b_expected || slv_resp.b.id!==expected_bid || slv_resp.b.resp!==axi_pkg::RESP_OKAY)
      $fatal(1,"HUM_B_RESPONSE");
    b_expected=0;write_completed++;
  end
  assert property(@(posedge clk)disable iff(!rst_n)
    slv_resp.b_valid && !slv_req.b_ready |=> slv_resp.b_valid && $stable(slv_resp.b))
    else $fatal(1,"HUM_B_STABILITY");

  always_ff @(posedge clk) if (rst_n) cyc <= cyc + 1;

  task automatic push(input id_t id, input addr_t a, input int unsigned len,
                      input logic [3:0] cache = 4'b1111, input bit lock = 0);
    stim_t s;
    s.id = id; s.addr = a; s.len = len; s.cache = cache; s.lock = lock;
    pending.push_back(s);
    requested++;
    expected_total += len + 1;
  endtask

  // AR driver: keeps the head of the queue presented until accepted.
  stim_t s;
  initial begin
    slv_req = '0;
    slv_req.r_ready = 1'b1;
    @(posedge rst_n);
    forever begin
      @(negedge clk);
      if (pending.size() != 0) begin
        s = pending[0];
        slv_req.ar_valid = 1'b1;
        slv_req.ar.id    = s.id;
        slv_req.ar.addr  = s.addr;
        slv_req.ar.len   = 8'(s.len);
        slv_req.ar.size  = 3'd3;
        slv_req.ar.burst = 2'b01;
        slv_req.ar.cache = s.cache;
        slv_req.ar.lock  = s.lock;
        do @(posedge clk); while(!slv_resp.ar_ready);
        if(exp_tail[s.id]>=64)$fatal(1,"HUM_EXPECTED_CAPACITY");
        expected[s.id][exp_tail[s.id]]=s;
        exp_tail[s.id]++;
        void'(pending.pop_front());
        issued++;
        @(negedge clk);
        slv_req.ar_valid = 1'b0;
      end
    end
  end

  // R collector: every beat checked against the independent reference.
  always_ff @(posedge clk) if (rst_n) begin
    if (slv_resp.r_valid && slv_req.r_ready) begin
      automatic id_t rid = slv_resp.r.id;
      automatic data_t want;
      if(exp_head[rid]>=exp_tail[rid])$fatal(1,"HUM_UNEXPECTED_ID id=%0d",rid);
      want=reference_beat(expected[rid][exp_head[rid]].addr,beats_seen[rid]);
      if(negative)want^=64'd1;
      if(slv_resp.r.data!==want)
        $fatal(1,"HUM_DATA id=%0d beat=%0d got=%h want=%h",rid,beats_seen[rid],slv_resp.r.data,want);
      if(slv_resp.r.resp!==axi_pkg::RESP_OKAY)$fatal(1,"HUM_RESP");
      if(slv_resp.r.last!==(beats_seen[rid]==expected[rid][exp_head[rid]].len))
        $fatal(1,"HUM_LAST id=%0d beat=%0d",rid,beats_seen[rid]);
      if(slv_resp.r.last)begin
        order.push_back(int'(rid));completed++;
        exp_head[rid]++;beats_seen[rid]=0;
      end else beats_seen[rid]++;
      end_cyc=cyc;
    end
  end

  task automatic wait_done(input int unsigned limit = 4000);
    int unsigned guard = 0;
    while (completed != expected_count() && guard < limit) begin
      @(posedge clk); guard++;
    end
    if (guard >= limit) $fatal(1, "HUM_TIMEOUT completed=%0d", completed);
  endtask

  function automatic int unsigned expected_count();
    return requested;
  endfunction

  task automatic send_write(input id_t id,input addr_t a,input logic[5:0] atop);
    stim_t er;
    @(negedge clk);
    b_expected=1;expected_bid=id;
    slv_req.aw='{id:id,addr:a,len:0,size:3,burst:axi_pkg::BURST_INCR,atop:atop,cache:4'hf,default:'0};
    slv_req.aw_valid=1;
    do @(posedge clk);while(!slv_resp.aw_ready);
    if(atop[5])begin
      if(exp_tail[id]>=64)$fatal(1,"HUM_EXPECTED_CAPACITY");
      er.id=id;er.addr=a;er.len=0;er.cache=4'hf;er.lock=0;
      expected[id][exp_tail[id]]=er;exp_tail[id]++;requested++;
    end
    @(negedge clk);
    slv_req.aw_valid=0;
    slv_req.w='{data:64'h1234,strb:'1,last:1'b1,user:'0};
    slv_req.w_valid=1;
    do @(posedge clk);while(!slv_resp.w_ready);
    @(negedge clk);slv_req.w_valid=0;
  endtask

  initial begin
    scenario = 0;
    for(int i=0;i<16;i++)begin exp_head[i]=0;exp_tail[i]=0;beats_seen[i]=0;end
    negative = $test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d", scenario));
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    start_cyc = cyc;

    case (scenario)
      // Same-line readers merge onto one fill and each get their own beats.
      0: begin
        push(4'd1, 64'h2000, 0);
        push(4'd2, 64'h2008, 0);
        push(4'd3, 64'h2010, 0);
        wait_done();
        if (fills != 1) $fatal(1, "HUM_FILLS fills=%0d", fills);
        if (mem_ar_count != 1) $fatal(1, "HUM_DRAM_AR count=%0d", mem_ar_count);
        if (merges != 2) $fatal(1, "HUM_NOT_ENGAGED merges=%0d", merges);
      end
      // Waiters with a different shape than the primary.
      1: begin
        push(4'd1, 64'h3000, 0);
        push(4'd2, 64'h3010, 1);
        push(4'd3, 64'h3038, 0);
        wait_done();
        if (mem_ar_count != 1) $fatal(1, "HUM_DRAM_AR count=%0d", mem_ar_count);
        if (merges != 2) $fatal(1, "HUM_NOT_ENGAGED merges=%0d", merges);
      end
      // One more same-line reader than there are waiter slots.
      2: begin
        push(4'd1, 64'h4000, 0);
        for (int i = 0; i < int'(MAX_WAITERS) + 1; i++)
          push(id_t'(2 + i), 64'h4000 + addr_t'(8 * (i + 1)), 0);
        wait_done();
        if (mem_ar_count != 1) $fatal(1, "HUM_DRAM_AR count=%0d", mem_ar_count);
        if (merges != MAX_WAITERS) $fatal(1, "HUM_WAITER_CAP merges=%0d", merges);
      end
      // Requests that must never merge into the in-flight line.
      3: begin
        push(4'd1, 64'h5000, 0);                 // primary, cacheable
        push(4'd2, 64'h6000, 0);                 // different line
        push(4'd3, 64'h5008, 0, 4'b0000);        // same line, non-cacheable
        push(4'd4, 64'h5010, 0, 4'b1111, 1'b1);  // same line, locked
        wait_done();
        if (merges != 0) $fatal(1, "HUM_ILLEGAL_MERGE merges=%0d", merges);
      end
      // Primary first, then waiters in attach order.
      4: begin
        push(4'd1, 64'h7000, 0);
        push(4'd2, 64'h7008, 0);
        push(4'd3, 64'h7010, 0);
        push(4'd4, 64'h7018, 0);
        wait_done();
        if (merges != 3) $fatal(1, "HUM_NOT_ENGAGED merges=%0d", merges);
        if (order.size() != 4) $fatal(1, "HUM_ORDER_COUNT");
        for (int i = 0; i < 4; i++)
          if (order[i] != i + 1) $fatal(1, "HUM_ORDER pos=%0d id=%0d", i, order[i]);
      end
      // Measurement: 8 readers of one shared line.
      5: begin
        for (int i = 0; i < 8; i++) push(id_t'(1 + i), 64'h8000 + addr_t'(8 * i), 0);
        wait_done();
      end
      // Measurement control: 8 readers of 8 distinct lines (no merge possible).
      6: begin
        for (int i = 0; i < 8; i++) push(id_t'(1 + i), 64'h9000 + addr_t'(LINE_BYTES * i), 0);
        wait_done();
        if (merges != 0) $fatal(1, "HUM_ILLEGAL_MERGE merges=%0d", merges);
      end
      // Inclusive eviction handshake: a miss that displaces a VALID victim
      // must hold l2_evict_valid_o (and must not launch the DRAM fill) until
      // l2_evict_ready_i accepts the notification. Without the hold the
      // victim commit races a busy back-inval engine and the invalidation is
      // silently dropped — an L1 keeps a line L2/L3 already replaced.
      7: begin
        // Fill set 0: four 1 KiB-strided lines share index 0 (16 sets, 64 B
        // lines), occupying ways 0..3 with tags 0..3.
        push(4'd1, 64'h0000, 0);
        push(4'd2, 64'h0400, 0);
        push(4'd3, 64'h0800, 0);
        push(4'd4, 64'h0C00, 0);
        wait_done();
        evict_ready = 1'b0;
        push(4'd5, 64'h1000, 0);     // index 0, tag 4 -> victim way 0 (0x0000)
        begin
          int unsigned guard = 0;
          while (!evict_v) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 200) $fatal(1, "HUM_EVICT_NEVER_OFFERED");
          end
        end
        // Offer observed: it must remain asserted, with a stable address and
        // no fill launch, for the whole backpressure window.
        repeat (8) begin
          @(posedge clk);
          if (!evict_v)             $fatal(1, "HUM_EVICT_DROPPED");
          if (evict_addr !== 64'h0) $fatal(1, "HUM_EVICT_ADDR got=%h", evict_addr);
          if (mst_req.ar_valid)     $fatal(1, "HUM_EVICT_FILL_LAUNCHED");
        end
        @(negedge clk) evict_ready = 1'b1;
        @(posedge clk);              // accept edge: transfer + victim commit
        wait_done();
        if (mem_ar_count != 5) $fatal(1, "HUM_EVICT_AR count=%0d", mem_ar_count);
      end
      8: begin
        memory_hold=1'b1;
        for(int i=0;i<8;i++)push(id_t'(i+1),64'ha000+addr_t'(LINE_BYTES*i),0);
        repeat(100)@(negedge clk);
        if(mem_peak<2)$fatal(1,"HUM_MLP_NOT_ENGAGED peak=%0d",mem_peak);
        memory_hold=1'b0;
        wait_done();
        if(mem_ar_count!=8 || completed!=8 || mem_outstanding!=0)
          $fatal(1,"HUM_MLP_DRAIN ar=%0d responses=%0d pending=%0d",mem_ar_count,completed,mem_outstanding);
      end
      9: begin
        slv_req.r_ready=1'b0;
        memory_hold=1'b1;
        push(4'd1,64'hb000,0);push(4'd2,64'hb040,0);
        repeat(40)@(negedge clk);
        if(mem_ar_count!=2)$fatal(1,"HUM_COLLECT_SETUP");
        memory_hold=1'b0;
        while(!(mem_outstanding==1 && mst_resp.r_valid && mst_resp.r.last && slv_resp.r_valid))
          @(negedge clk);
        slv_req.r_ready=1'b1;
        @(posedge clk);@(negedge clk);
        if(dut.gen_l2.collect_cnt_q!=1)$fatal(1,"HUM_COLLECT_RETIRE_COUNT");
        wait_done();
      end
      10: begin
        slv_req.r_ready=1'b0;
        push(4'd1,64'hc000,0);
        while(mem_ar_count!=1)@(negedge clk);
        memory_ar_hold=1'b1;
        repeat(2)@(negedge clk);
        push(4'd2,64'hc040,0);
        while(!(mst_req.ar_valid && slv_resp.r_valid))@(negedge clk);
        memory_ar_hold=1'b0;
        while(!mst_resp.ar_ready)@(negedge clk);
        slv_req.r_ready=1'b1;
        @(posedge clk);@(negedge clk);
        if(dut.gen_l2.issued_cnt_q!=1)$fatal(1,"HUM_ISSUE_RETIRE_COUNT");
        wait_done();
      end
      11: begin
        push(4'd1,64'hd000,0);wait_done();
        push(4'd2,64'hd040,0);
        do begin @(posedge clk);#1;end
        while(!(mem_ar_count==2 && mst_resp.r_valid && mst_resp.r.last));
        push(4'd3,64'hd000,0);
        wait_done();
        if(install_conflicts==0)$fatal(1,"HUM_INSTALL_COLLISION_MISSING");
      end
      12: begin
        push(4'd7,64'hf000,0);wait_done();
        memory_hold=1'b1;
        push(4'd1,64'he000,1);push(4'd1,64'hf000,0);
        repeat(40)@(negedge clk);
        memory_hold=1'b0;wait_done();
        if(mem_ar_count!=2)$fatal(1,"HUM_SAME_ID_HIT_AR");
      end
      13: begin
        memory_hold=1'b1;
        push(4'd1,64'he000,0);push(4'd1,64'he040,0);push(4'd1,64'he008,0);
        repeat(40)@(negedge clk);
        memory_hold=1'b0;wait_done();
        if(mem_ar_count!=2)$fatal(1,"HUM_NONADJACENT_AR");
      end
      14: begin
        memory_hold=1'b1;
        push(4'hf,64'he000,0);push(4'hf,64'he080,0,4'b0000);
        repeat(40)@(negedge clk);
        memory_hold=1'b0;wait_done();
        if(mem_ar_count!=2)$fatal(1,"HUM_BYPASS_AR");
      end
      15: begin
        memory_ar_hold=1'b1;
        repeat(3)@(negedge clk);
        push(4'd1,64'he000,0);
        while(!mst_req.ar_valid)@(negedge clk);
        push(4'd2,64'he080,0,4'b0000);
        repeat(12)@(negedge clk);
        memory_ar_hold=1'b0;wait_done();
        if(mem_ar_count!=2)$fatal(1,"HUM_HELD_AR_DRAIN");
      end
      16: begin
        push(4'd7,64'hf000,0);wait_done();
        memory_hold=1'b1;
        push(4'd1,64'he000,0);push(4'd2,64'hf000,0);
        repeat(40)@(negedge clk);
        if(completed!=2 || order[1]!=2)$fatal(1,"HUM_DIFFERENT_ID_BLOCKED");
        memory_hold=1'b0;wait_done();
      end
      17: begin
        memory_hold=1'b1;
        push(4'd1,64'he000,0);push(4'd1,64'he008,1);push(4'd1,64'he018,0);
        repeat(40)@(negedge clk);
        memory_hold=1'b0;wait_done();
        if(mem_ar_count!=1 || merges!=2)$fatal(1,"HUM_SAME_ID_MERGE");
      end
      18: begin
        memory_hold=1'b1;
        for(int i=0;i<8;i++)push(4'hf,64'he000+addr_t'(LINE_BYTES*i),0);
        repeat(100)@(negedge clk);
        if(mem_peak<2)$fatal(1,"HUM_SAME_ID_MLP");
        memory_hold=1'b0;wait_done();
        if(mem_ar_count!=8 || completed!=8 || mem_outstanding!=0)$fatal(1,"HUM_SAME_ID_DRAIN");
      end
      19: begin
        push(4'd7,64'hf000,0);wait_done();
        memory_hold=1'b1;slv_req.r_ready=1'b0;
        push(4'd7,64'he000,0);push(4'd1,64'he008,0);
        push(4'd1,64'he040,0);push(4'd1,64'hf000,0);
        repeat(40)@(negedge clk);
        memory_hold=1'b0;
        repeat(40)@(negedge clk);
        slv_req.r_ready=1'b1;wait_done();
      end
      20,21:begin
        atomic_r_hold=1'b1;memory_hold=1'b1;
        slv_req.b_ready=1'b1;slv_req.r_ready=1'b0;
        send_write(scenario==20 ? 4'hf : 4'd3,64'h12000,6'h20);
        while(write_completed!=1)@(negedge clk);
        push(4'd4,64'h13000,0,scenario==20 ? 4'hf : 4'h0);
        repeat(40)@(negedge clk);
        atomic_r_hold=1'b0;
        repeat(6)@(negedge clk);
        if(!CHAIN_L3 && mem_atomic_r!=0)$fatal(1,"HUM_ATOP_R_BACKPRESSURE");
        slv_req.r_ready=1'b1;memory_hold=1'b0;
        wait_done();
        if(mem_atomic_r!=1 || write_completed!=1)$fatal(1,"HUM_ATOP_ACCOUNTING");
      end
      22,24:begin
        memory_b_hold=1'b1;slv_req.b_ready=1'b0;
        send_write(scenario==22 ? 4'hf : 4'd3,64'h12000,6'h20);
        wait_done();
        if(write_completed!=0 || mem_atomic_r!=1)$fatal(1,"HUM_R_BEFORE_B");
        push(4'd4,64'h13000,0);
        repeat(40)@(negedge clk);
        memory_b_hold=1'b0;
        repeat(6)@(negedge clk);
        slv_req.b_ready=1'b1;
        while(write_completed!=1)@(negedge clk);
        wait_done();
      end
      23,25:begin
        slv_req.b_ready=1'b1;
        send_write(scenario==23 ? 4'hf : 4'd3,64'h12000,6'h20);
        push(4'd4,64'h13000,0);
        while(write_completed!=1)@(negedge clk);
        wait_done();
        if(mem_atomic_r!=1)$fatal(1,"HUM_SIMULTANEOUS_BR");
      end
      26,27:begin
        slv_req.b_ready=1'b1;
        send_write(4'hf,64'h12000,scenario==26 ? 6'h10 : 6'h00);
        while(write_completed!=1)@(negedge clk);
        push(4'd4,64'h13000,0);
        wait_done();
        if(mem_atomic_r!=0)$fatal(1,"HUM_UNEXPECTED_ATOP_R");
      end
      // An invalidation landing on an in-flight fill still serves the attached
      // requester, but must leave nothing installed: the next read re-fetches.
      28: begin
        memory_hold=1'b1;
        push(4'd1,64'h14000,0);
        while(l2_ar_count!=1)@(negedge clk);
        back_inval_addr=64'h14000;back_inval_valid=1'b1;
        @(negedge clk);
        back_inval_valid=1'b0;
        memory_hold=1'b0;wait_done();
        push(4'd2,64'h14000,0);wait_done();
        if(l2_ar_count!=2)$fatal(1,"HUM_KILL_NO_REFETCH ar=%0d",l2_ar_count);
      end
      // A write-through self-invalidation may not be dropped because an
      // external back-invalidation held the shared tag match port.
      29: begin
        push(4'd1,64'h15000,0);wait_done();
        if(l2_ar_count!=1)$fatal(1,"HUM_INVAL_SETUP");
        slv_req.b_ready=1'b1;
        back_inval_addr=64'h16000;back_inval_valid=1'b1;
        send_write(4'd2,64'h15000,6'h00);
        while(write_completed!=1)@(negedge clk);
        back_inval_valid=1'b0;
        repeat(6)@(negedge clk);
        push(4'd3,64'h15000,0);wait_done();
        if(l2_ar_count!=2)$fatal(1,"HUM_SELF_INVAL_LOST ar=%0d",l2_ar_count);
      end
      // Replacement-metadata scheduling: sustained concurrent misses make
      // installs coincide with request acceptance. Every accepted request's own
      // set must still be the set that is read.
      30: begin
        // A continuous request stream: acceptance keeps happening while earlier
        // fills install, which is the only way the shared port collides.
        // Phase sweep: offer a second request a variable number of cycles after
        // the first fill is issued, so acceptance lands on the install cycle for
        // some offset. A saturated MSHR parks the front end in the lookup state,
        // so a continuous stream alone never reaches the collision.
        for(int unsigned off=0;off<24;off++)begin
          push(4'd1,64'h20000+addr_t'(LINE_BYTES*(2*off)),0);
          while(mem_ar_count!=int'(off)*2+1)@(negedge clk);
          repeat(off)@(negedge clk);
          push(4'd2,64'h20000+addr_t'(LINE_BYTES*(2*off+1)),0);
          wait_done(8000);
        end
        $display("HUM_RR collide=%0d lost=%0d reads=%0d",rr_collide,rr_read_lost,l2_ar_count);
        if(RR_EN && rr_collide==0 && !$test$plusargs("rr_diagnose"))
          $fatal(1,"HUM_RR_NO_COLLISION");
        if(rr_read_lost!=0)$fatal(1,"HUM_RR_READ_LOST lost=%0d",rr_read_lost);
      end
      // Inclusion mechanism: the outer cache's victim must invalidate the inner
      // copy. With two outer ways, a third line in the same outer set evicts the
      // first, and the inner cache must then refetch it instead of hitting.
      // Chain-only: without the outer cache there is no victim to propagate.
      31: begin
        push(4'd1,64'h30000,0);wait_done();
        push(4'd1,64'h30400,0);wait_done();
        push(4'd1,64'h30800,0);wait_done();
        repeat(20)@(negedge clk);
        if(l3_evict_count==0)$fatal(1,"HUM_NO_OUTER_EVICT");
        l2_ar_mark=l2_ar_count;
        push(4'd2,64'h30000,0);wait_done();
        if(l2_ar_count==l2_ar_mark)
          $fatal(1,"HUM_INCLUSION_STALE_HIT ar=%0d",l2_ar_count);
      end
      default: $fatal(1, "HUM_SCENARIO");
    endcase

    $display("HUM_METRICS scenario=%0d cycles=%0d dram_ar=%0d fills=%0d merges=%0d responses=%0d",
             scenario, end_cyc - start_cyc, mem_ar_count, fills, merges, completed);
    $display("RTL_REVIEW_PASS hum scenario=%0d", scenario);
    $finish;
  end

  initial begin
    #500us;
    $fatal(1, "HUM_WATCHDOG");
  end

endmodule
