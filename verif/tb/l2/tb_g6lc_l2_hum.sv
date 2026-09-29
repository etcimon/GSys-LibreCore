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
  parameter bit FAIR_WRITES=1'b0;
  parameter bit TAG_SRAM=1'b0;
  // WRITE_UPDATE=1: an eligible write-through to a resident line merges into
  // it instead of purging. Scenarios 42-48 are the directed WU contract;
  // earlier scenarios must behave identically in either mode.
  parameter bit WRITE_UPDATE=1'b0;
  // T9b: posted writes + bypass-read tracking. Scenarios 49+ are the posted
  // contract; earlier records must keep the M1a metric hash when off.
  parameter bit POSTED_WRITES=1'b0;
  parameter int unsigned WTRK_DEPTH=4, RDTRK_DEPTH=4;
  // T9h/M5: L2 stream/stride prefetcher. Off keeps every earlier scenario
  // cycle-identical (asserted below by hash-stable observability taps).
  parameter bit PREFETCH=1'b0;
  parameter int unsigned PF_STREAMS=4, PF_DISTANCE=2, PF_MSHR_RESERVE=1;
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
  logic l2_wupd;
  logic l2_wtrk_full_p, l2_line_hold_p, l2_hold_r2_p,
        l2_posted_p, l2_rdtrk_p;
  logic l2_idle_w, l2_phold_w;
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
      .FAIR_WRITES (FAIR_WRITES),
      .TAG_SRAM    (TAG_SRAM),
      .WRITE_UPDATE(WRITE_UPDATE),
      .POSTED_WRITES(POSTED_WRITES),
      .WTRK_DEPTH  (WTRK_DEPTH),
      .RDTRK_DEPTH (RDTRK_DEPTH),
      .PF_EN       (PREFETCH),
      .PF_STREAMS  (PF_STREAMS),
      .PF_DISTANCE (PF_DISTANCE),
      .PF_MSHR_RESERVE(PF_MSHR_RESERVE),
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
      .l2_selfinv_hit_o   (),
      .l2_wupdate_o       (l2_wupd),
      .l2_wtrk_full_o     (l2_wtrk_full_p),
      .l2_wtrk_line_hold_o(l2_line_hold_p),
      .l2_hold_r1_o       (),
      .l2_hold_r1_wu_o    (),
      .l2_hold_r2_o       (l2_hold_r2_p),
      .l2_posted_o        (l2_posted_p),
      .l2_rdtrk_o         (l2_rdtrk_p),
      .l2_posted_hold_o   (l2_phold_w),
      .l2_pf_issue_o      (l2_pf_issue_p),
      .l2_pf_useful_o     (l2_pf_useful_p),
      .l2_pf_drop_o       (l2_pf_drop_p),
      .l2_evict_valid_o   (evict_v),
      .l2_evict_addr_o    (evict_addr),
      .l2_evict_ready_i   (evict_ready),
      .l2_back_inval_valid_i (inval_valid),
      .l2_back_inval_addr_i  (inval_addr),
      .l2_back_inval_ready_o (back_inval_ready),
      .l2_write_idle_o       (l2_idle_w)
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
      .MSHR_DEPTH(2),.DATA_BANKS(2),.TAG_SRAM(TAG_SRAM),
      .WRITE_UPDATE(WRITE_UPDATE),
      .POSTED_WRITES(POSTED_WRITES),
      .WTRK_DEPTH(WTRK_DEPTH),.RDTRK_DEPTH(RDTRK_DEPTH),
      .AXI_ADDR_WIDTH(AW),.AXI_DATA_WIDTH(DW),
      .AXI_ID_WIDTH(IDW),.AXI_USER_WIDTH(UW),.axi_req_t(req_t),.axi_resp_t(resp_t)
    ) i_l3 (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(cut_req),.slv_resp_o(cut_resp),
      .mst_req_o(mst_req),.mst_resp_i(mst_resp),
      .l3_hit_o(),.l3_miss_o(),.l3_bypass_o(),.l3_selfinv_hit_o(),
      .l3_wupdate_o(),
      .l3_wtrk_full_o(),.l3_wtrk_line_hold_o(),.l3_posted_o(),
      .l3_rdtrk_o(),.l3_posted_hold_o(),
      .l3_pf_issue_o(),.l3_pf_useful_o(),.l3_pf_drop_o(),
      .l3_evict_valid_o(l3_evict_valid),
      .l3_evict_addr_o(l3_evict_addr),
      // The directed stimulus owns the port when it is driving.
      .l3_evict_ready_i(back_inval_ready && !back_inval_valid),
      .l3_write_idle_o(),
      .l3_back_inval_valid_i(1'b0), .l3_back_inval_addr_i('0),
      .l3_back_inval_ready_o()
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

  // Write patch layer: the write-through contract. Every W beat the memory
  // model accepts is recorded byte-granularly, and the R stream serves the
  // patched value — exactly the bytes a WRITE_UPDATE merge must also have
  // recorded. A dropped merge shows up as stale read-back on a resident hit;
  // a dropped write-through shows up after an invalidate+refetch.
  data_t patch_val[addr_t];
  strb_t patch_msk[addr_t];
  function automatic void patch_apply(input addr_t a, input data_t d,
                                      input strb_t m);
    addr_t w = a >> 3;
    if (!patch_val.exists(w)) begin
      patch_val[w] = '0;
      patch_msk[w] = '0;
    end
    for (int b = 0; b < DW/8; b++)
      if (m[b]) patch_val[w][8*b +: 8] = d[8*b +: 8];
    patch_msk[w] |= m;
  endfunction
  function automatic data_t patched_word(input addr_t a);
    addr_t w = a >> 3;
    data_t v = reference_word(a);
    if (patch_val.exists(w))
      for (int b = 0; b < DW/8; b++)
        if (patch_msk[w][b]) v[8*b +: 8] = patch_val[w][8*b +: 8];
    return v;
  endfunction

  // Beat i of a burst starting at `a`: the DUT indexes within the line and
  // wraps at the line boundary, so the reference must wrap identically.
  function automatic data_t reference_beat(input addr_t a, input int unsigned i);
    addr_t base  = a & ~addr_t'(LINE_BYTES - 1);
    int unsigned first = int'((a >> 3) % BEATS);
    reference_beat = patched_word(base + addr_t'(((first + i) % BEATS) * 8));
  endfunction

  // ---- memory model: serves any AR after MEM_LATENCY cycles ---------------
  localparam int RD_DEPTH=16;
  typedef struct packed {
    addr_t addr;
    id_t id;
    logic [7:0] len;
    int unsigned beat;
    int unsigned delay_cycles;
    data_t salt;
    // Reorder-mode completion mark: a non-head job may finish before the
    // head; slots free contiguously from rd_head.
    logic done;
  } read_job_t;
  read_job_t jobs[RD_DEPTH];
  int unsigned rd_head=0,rd_tail=0,rd_count=0;
  int unsigned mem_ar_count=0,mem_outstanding=0,mem_peak=0;
  logic memory_hold=1'b0;
  logic memory_ar_hold=1'b0;
  // XORed into every beat of fills whose AR is accepted while it is nonzero:
  // lets a scenario prove a refetch returned NEW data rather than the
  // pre-invalidation copy. Latched into the job at AR acceptance.
  data_t data_salt='0;
  int unsigned install_conflicts=0;
  logic atomic_r_hold=1'b0,memory_b_hold=1'b0;
  logic r_is_atop=1'b0;
  int unsigned mem_atomic_r=0;
  // +mem_reorder_ids: B and R completions may reorder across different ids
  // (AXI preserves order per id only). Write bytes then apply when the
  // job's B issues — a same-line different-id write that sneaks past the
  // L2's R2 hold can therefore land its bytes under the older write's.
  bit mem_reorder=1'b0;
  // Write job queue (AW-issue order). Posted writes let several memory-side
  // writes be outstanding at once; W beats land on the oldest job still
  // collecting (AXI W follows AW order), Bs issue per the ordering rules.
  localparam int WD_DEPTH=8;
  typedef struct {
    aw_chan_t header;
    int unsigned beat;
    bit w_done, b_done, r_pend, r_issued;
    int unsigned wnum;
    addr_t waddr[16]; data_t wdata[16]; strb_t wstrb[16];
  } wjob_t;
  wjob_t wjobs[WD_DEPTH];
  int unsigned wq_head=0, wq_tail=0, wq_count=0;
  int unsigned atop_slot=0;
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
      r_is_atop=0;mem_atomic_r=0;
      wq_head=0;wq_tail=0;wq_count=0;atop_slot=0;
      for(int i=0;i<RD_DEPTH;i++)jobs[i]='0;
      for(int i=0;i<WD_DEPTH;i++)begin
        wjobs[i].beat=0;wjobs[i].w_done=0;wjobs[i].b_done=0;
        wjobs[i].r_pend=0;wjobs[i].r_issued=0;wjobs[i].wnum=0;
      end
    end else begin
      automatic bit take_ar = mst_req.ar_valid && mst_resp.ar_ready;
      automatic bit take_aw=mst_req.aw_valid && mst_resp.aw_ready;
      automatic bit take_w=mst_req.w_valid && mst_resp.w_ready;
      automatic int pick=-1, apick=-1, rpick=-1, wpick=-1;
      automatic bit id_unique;
      if(mst_resp.r_valid && mst_req.r_ready && mst_resp.r.last)begin
        if(r_is_atop)begin
          wjobs[atop_slot].r_pend=1'b0;wjobs[atop_slot].r_issued=1'b0;
          mem_atomic_r++;
        end
        else mem_outstanding--;
      end
      if(mst_resp.b_valid && mst_req.b_ready)
        mst_resp.b_valid<=1'b0;
      // Issue the next B: oldest ready job normally; under mem_reorder the
      // newest ready job whose id is unique among ready jobs (per-id order
      // stays intact — only different ids may pass each other).
      if(!memory_b_hold && !mst_resp.b_valid)begin
        if(!mem_reorder)begin
          for(int k=0;k<wq_count;k++)begin
            automatic int i=(wq_head+k)%WD_DEPTH;
            if(wjobs[i].w_done && !wjobs[i].b_done && pick<0)pick=i;
          end
        end else begin
          for(int k=wq_count-1;k>=0;k--)begin
            automatic int i=(wq_head+k)%WD_DEPTH;
            id_unique=1'b1;
            if(wjobs[i].w_done && !wjobs[i].b_done)begin
              for(int m=0;m<k;m++)begin
                automatic int j2=(wq_head+m)%WD_DEPTH;
                if(wjobs[j2].w_done && !wjobs[j2].b_done &&
                   wjobs[j2].header.id==wjobs[i].header.id)id_unique=1'b0;
              end
              if(id_unique && pick<0)pick=i;
            end
          end
        end
        if(pick>=0)begin
          if(mem_reorder)
            for(int k=0;k<wjobs[pick].wnum;k++)
              patch_apply(wjobs[pick].waddr[k],wjobs[pick].wdata[k],
                          wjobs[pick].wstrb[k]);
          mst_resp.b_valid<=1'b1;
          mst_resp.b<='{id:wjobs[pick].header.id,resp:axi_pkg::RESP_OKAY,user:'0};
          wjobs[pick].b_done=1'b1;
        end
      end
      for(int i=0;i<RD_DEPTH;i++)
        if(jobs[i].delay_cycles!=0)jobs[i].delay_cycles--;
      if(!mst_resp.r_valid || mst_req.r_ready) begin
        mst_resp.r_valid <= 1'b0;
        r_is_atop=1'b0;
        for(int k=0;k<wq_count;k++)begin
          automatic int i=(wq_head+k)%WD_DEPTH;
          if(wjobs[i].r_pend && !wjobs[i].r_issued && apick<0)apick=i;
        end
        if(apick>=0 && !atomic_r_hold)begin
          mst_resp.r_valid<=1'b1;
          mst_resp.r<='{id:wjobs[apick].header.id,
                        data:patched_word(wjobs[apick].header.addr),
                        resp:axi_pkg::RESP_OKAY,last:1'b1,user:'0};
          r_is_atop=1'b1;wjobs[apick].r_issued=1'b1;atop_slot=apick;
        end else begin
          if(rd_count!=0 && !memory_hold)begin
            if(!mem_reorder)begin
              if(jobs[rd_head].delay_cycles==0)rpick=rd_head;
            end else begin
              for(int k=rd_count-1;k>=0;k--)begin
                automatic int i=(rd_head+k)%RD_DEPTH;
                id_unique=1'b1;
                if(jobs[i].delay_cycles==0)begin
                  for(int m=0;m<k;m++)begin
                    automatic int j2=(rd_head+m)%RD_DEPTH;
                    if(jobs[j2].delay_cycles==0 &&
                       jobs[j2].id==jobs[i].id)id_unique=1'b0;
                  end
                  if(id_unique && rpick<0)rpick=i;
                end
              end
            end
          end
          // An ATOP-R job sharing the read's id keeps that id's read beats
          // behind it (same-id channel order).
          if(rpick>=0)begin
            for(int k=0;k<wq_count;k++)begin
              automatic int i=(wq_head+k)%WD_DEPTH;
              if(wjobs[i].r_pend && wjobs[i].header.id==jobs[rpick].id)rpick=-1;
            end
          end
          if(rpick>=0)begin
            mst_resp.r_valid <= 1'b1;
            mst_resp.r.id <= jobs[rpick].id;
            mst_resp.r.resp <= axi_pkg::RESP_OKAY;
            mst_resp.r.data <= patched_word(jobs[rpick].addr + addr_t'(jobs[rpick].beat*8)) ^
                               jobs[rpick].salt;
            mst_resp.r.last <= (jobs[rpick].beat==int'(jobs[rpick].len));
            if(jobs[rpick].beat==int'(jobs[rpick].len))begin
              if(mem_reorder)jobs[rpick].done=1'b1;
              else begin rd_head=(rd_head+1)%RD_DEPTH;rd_count--;end
            end else jobs[rpick].beat++;
          end
        end
      end
      // Reorder-mode read jobs free their slot once every job ahead of them
      // has completed — the ring stays FIFO for accounting.
      if(mem_reorder)
        while(rd_count!=0 && jobs[rd_head].done)begin
          jobs[rd_head]='0;
          rd_head=(rd_head+1)%RD_DEPTH;rd_count--;
        end
      // Completed write jobs retire in order.
      while(wq_count!=0 && wjobs[wq_head].w_done && wjobs[wq_head].b_done &&
            !wjobs[wq_head].r_pend)begin
        wjobs[wq_head].b_done=1'b0;wjobs[wq_head].w_done=1'b0;
        wq_head=(wq_head+1)%WD_DEPTH;wq_count--;
      end
      if(take_ar)begin
        if(rd_count>=RD_DEPTH)$fatal(1,"HUM_MEMORY_OVERFLOW");
        jobs[rd_tail]='{addr:mst_req.ar.addr,id:mst_req.ar.id,len:mst_req.ar.len,
                        beat:0,delay_cycles:MEM_LATENCY,salt:data_salt,done:1'b0};
        rd_tail=(rd_tail+1)%RD_DEPTH;rd_count++;
        mem_ar_count++;mem_outstanding++;
        if(mem_outstanding>mem_peak)mem_peak=mem_outstanding;
      end
      if(take_aw)begin
        // Multi-beat INCR writes (len>0) are legal traffic: WU eligibility
        // requires size==full-word when len>0, which the DUT forwards.
        if(wq_count>=WD_DEPTH)$fatal(1,"HUM_WRITE_OVERFLOW");
        wjobs[wq_tail]='{header:mst_req.aw,beat:0,w_done:1'b0,b_done:1'b0,
                        r_pend:1'b0,r_issued:1'b0,wnum:0,
                        waddr:'{default:'0},wdata:'{default:'0},wstrb:'{default:'0}};
        wq_tail=(wq_tail+1)%WD_DEPTH;wq_count++;
      end
      if(take_w)begin
        for(int k=0;k<wq_count;k++)begin
          automatic int i=(wq_head+k)%WD_DEPTH;
          if(!wjobs[i].w_done && wpick<0)wpick=i;
        end
        if(wpick<0)$fatal(1,"HUM_WRITE_DATA");
        if(mst_req.w.last !== (wjobs[wpick].beat == int'(wjobs[wpick].header.len)))
          $fatal(1,"HUM_WRITE_LAST beat=%0d len=%0d",wjobs[wpick].beat,
                 wjobs[wpick].header.len);
        if(!mem_reorder)begin
          patch_apply(wjobs[wpick].header.addr + addr_t'(wjobs[wpick].beat)*(DW/8),
                      mst_req.w.data, mst_req.w.strb);
        end else if(wjobs[wpick].wnum<16)begin
          wjobs[wpick].waddr[wjobs[wpick].wnum]=
              wjobs[wpick].header.addr + addr_t'(wjobs[wpick].beat)*(DW/8);
          wjobs[wpick].wdata[wjobs[wpick].wnum]=mst_req.w.data;
          wjobs[wpick].wstrb[wjobs[wpick].wnum]=mst_req.w.strb;
          wjobs[wpick].wnum++;
        end
        if(mst_req.w.last)begin
          wjobs[wpick].w_done=1'b1;
          wjobs[wpick].r_pend=wjobs[wpick].header.atop[5];
          wjobs[wpick].r_issued=1'b0;
        end else wjobs[wpick].beat++;
      end
      mst_resp.aw_ready<=wq_count<WD_DEPTH;
      begin
        automatic bit w_open=1'b0;
        for(int k=0;k<wq_count;k++)
          if(!wjobs[(wq_head+k)%WD_DEPTH].w_done)w_open=1'b1;
        mst_resp.w_ready<=w_open;
      end
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

  // TAG_SRAM engagement + contract probes. All events are observed on the
  // i_tag ports and the parent FSM — visible on both tag paths (identical
  // functional contract); the SRAM-only assertions are parameter-gated at
  // the scenario sites.
  int unsigned fwd_launch_cycles = 0, comb_fwd_cycles = 0, steal_cycles = 0;
  int unsigned invw_corner_cycles = 0;
  int unsigned intr_retag_seen = 0;
  // Mirrors g6lc_l2_top's state_e encoding (hierarchical enum-literal reads
  // are not portable across simulators).
  localparam logic [3:0] L2_S_TAG = 4'd1, L2_S_SERVE = 4'd4;
  logic [3:0] state_prev = '0;
  bit retag_stalled = 1'b0;
  bit check_evict_addr = 1'b0;
  addr_t way_line [SET_ASSOC];
  always_ff @(posedge clk) if (rst_n) begin
    // (a) launch-cycle forward: install to the set whose row is being read.
    if (dut.gen_l2.i_tag.write_i && dut.gen_l2.i_tag.write_valid_i &&
        dut.gen_l2.i_tag.launch_i && !dut.gen_l2.i_tag.inval_match_i &&
        dut.gen_l2.i_tag.write_index_i == dut.gen_l2.i_tag.launch_index_i)
      fwd_launch_cycles <= fwd_launch_cycles + 1;
    // (b) use-cycle coincidence: an install lands on the set under compare.
    // The SRAM path (like the flop array) must not let that in-flight write
    // reach the current compare — the decision uses pre-write state and the
    // next relaunched row sees the install.
    if (dut.gen_l2.i_tag.write_i && dut.gen_l2.i_tag.write_valid_i &&
        dut.gen_l2.i_tag.lookup_i && dut.gen_l2.i_tag.row_valid_o &&
        dut.gen_l2.i_tag.write_index_i == dut.gen_l2.i_tag.index_i)
      comb_fwd_cycles <= comb_fwd_cycles + 1;
    // (c) inval-match port steal: a held lookup must lose exactly the
    // stolen cycle, no more.
    if (dut.gen_l2.state_q == L2_S_TAG &&
        !dut.gen_l2.i_tag.row_valid_o)
      steal_cycles <= steal_cycles + 1;
    // (d) S_SERVE interrupt return must re-enter S_TAG with a valid row.
    state_prev <= dut.gen_l2.state_q;
    if (dut.gen_l2.state_q == L2_S_TAG &&
        state_prev == L2_S_SERVE) begin
      intr_retag_seen <= intr_retag_seen + 1;
      if (!dut.gen_l2.i_tag.row_valid_o) retag_stalled <= 1'b1;
    end
    // (e) victim probe after a forwarded install: way-level shadow of which
    // line each way holds; on an eviction the announced address must be the
    // line the victim way currently holds.
    if (dut.gen_l2.tag_write)
      way_line[dut.gen_l2.tag_wway] <=
          {dut.gen_l2.fill_addr_q[dut.gen_l2.inst_idx][AW-1:6], 6'b0};
    if (check_evict_addr && evict_v && evict_ready &&
        evict_addr != way_line[dut.gen_l2.tag_probe_way])
      $fatal(1, "HUM_TAG_PROBE_STALE evict=%h way=%0d resident=%h",
             evict_addr, dut.gen_l2.tag_probe_way,
             way_line[dut.gen_l2.tag_probe_way]);
    // (g) install coinciding with a same-set inval-match read: the deferred
    // compare must decide on the valid bits as of the read cycle.
    if (dut.gen_l2.tag_write && dut.gen_l2.tag_wvalid &&
        dut.gen_l2.tag_match_inval &&
        dut.gen_l2.tag_windex == dut.gen_l2.tag_match_index)
      invw_corner_cycles <= invw_corner_cycles + 1;
  end

  // WRITE_UPDATE observability: one pulse per merged write (the port output),
  // plus the install-stall engagement for the merge-vs-evict window.
  int unsigned wupd_count = 0, wupd_mark = 0;
  int unsigned wu_stall_cycles = 0;
  always_ff @(posedge clk) if (rst_n) begin
    if (l2_wupd) wupd_count <= wupd_count + 1;
    if (WRITE_UPDATE && dut.gen_l2.wu_install_stall)
      wu_stall_cycles <= wu_stall_cycles + 1;
  end

  // T9b posted-write observability: engagement counters on the DUT pulses.
  int unsigned pw_wtrk_full = 0, pw_line_hold = 0, pw_r2_hold = 0,
               pw_posted = 0, pw_rdtrk = 0, pw_hold = 0;
  always_ff @(posedge clk) if (rst_n) begin
    if (l2_wtrk_full_p) pw_wtrk_full <= pw_wtrk_full + 1;
    if (l2_line_hold_p) pw_line_hold <= pw_line_hold + 1;
    if (l2_hold_r2_p)   pw_r2_hold   <= pw_r2_hold + 1;
    if (l2_posted_p)    pw_posted    <= pw_posted + 1;
    if (l2_rdtrk_p)     pw_rdtrk     <= pw_rdtrk + 1;
    if (l2_phold_w)     pw_hold      <= pw_hold + 1;
  end
  // Read-tracker occupancy (push-edge): an entry whose memory R is held
  // downstream is already live — pops alone cannot prove engagement.
  int unsigned pw_rdtrk_push = 0;
  always_ff @(posedge clk) if (rst_n && POSTED_WRITES &&
      dut.gen_l2.rdtrk_push)
    pw_rdtrk_push <= pw_rdtrk_push + 1;

  // T9h/M5 prefetcher observability: engagement counters on the DUT pulses.
  int unsigned pf_issue = 0, pf_useful = 0, pf_drop = 0;
  logic l2_pf_issue_p, l2_pf_useful_p, l2_pf_drop_p;
  always_ff @(posedge clk) if (rst_n) begin
    if (l2_pf_issue_p)  pf_issue  <= pf_issue + 1;
    if (l2_pf_useful_p) pf_useful <= pf_useful + 1;
    if (l2_pf_drop_p)   pf_drop   <= pf_drop + 1;
  end

  // R5 engagement: a hit response captive in S_TAG whose id carries a live
  // read-tracker entry (probe[0] = id_q). Only fires under POSTED_WRITES;
  // the probes are tied off otherwise.
  int unsigned pw_r5_hold = 0;
  localparam logic [3:0] L2T_S_TAG = 4'd1;
  always_ff @(posedge clk) if (rst_n && POSTED_WRITES &&
      dut.gen_l2.state_q == L2T_S_TAG && dut.gen_l2.tag_hit &&
      dut.gen_l2.rdtrk_probe_match[0])
    pw_r5_hold <= pw_r5_hold + 1;

  // Slave-R burst atomicity: once a burst's first beat is on the channel no
  // other burst may cut in before last (the R arbiter owns it to the end).
  bit   r_burst_open = 1'b0;
  id_t  r_burst_id;
  always @(posedge clk) if (rst_n && slv_resp.r_valid && slv_req.r_ready) begin
    if (r_burst_open && slv_resp.r.id != r_burst_id)
      $fatal(1, "HUM_R_INTERLEAVE id=%0d in_burst=%0d",
             slv_resp.r.id, r_burst_id);
    r_burst_id = slv_resp.r.id;
    r_burst_open = !slv_resp.r.last;
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
    data_t       salt;
  } stim_t;

  stim_t pending[$];
  int unsigned issued = 0, completed = 0, expected_total = 0;
  int unsigned beats_seen[16];
  stim_t expected[16][64];
  int unsigned exp_head[16], exp_tail[16];
  int unsigned requested=0;
  int unsigned order[$];
  bit          negative;
  // When set, a data mismatch on `stale_id` means the post-invalidation
  // requester was served the killed entry's pre-invalidation fill — a stale
  // merge — not an ordinary data error.
  bit          stale_mode = 1'b0;
  id_t         stale_id = '0;
  int unsigned start_cyc = 0, end_cyc = 0, cyc = 0;
  int          scenario;

  // Per-id expected-B queues: posted writes let several Bs be outstanding
  // across ids, and +mem_reorder_ids lets them return out of order — each
  // id's count is consumed independently (per-id B order is an AXI rule).
  int unsigned bexp[16];
  int unsigned write_completed=0;
  always @(posedge clk)if(rst_n && slv_resp.b_valid && slv_req.b_ready)begin
    if(bexp[slv_resp.b.id]==0 || slv_resp.b.resp!==axi_pkg::RESP_OKAY)
      $fatal(1,"HUM_B_RESPONSE id=%0d",slv_resp.b.id);
    bexp[slv_resp.b.id]--;write_completed++;
  end
  assert property(@(posedge clk)disable iff(!rst_n)
    slv_resp.b_valid && !slv_req.b_ready |=> slv_resp.b_valid && $stable(slv_resp.b))
    else $fatal(1,"HUM_B_STABILITY");

  always_ff @(posedge clk) if (rst_n) cyc <= cyc + 1;

  task automatic push(input id_t id, input addr_t a, input int unsigned len,
                      input logic [3:0] cache = 4'b1111, input bit lock = 0);
    stim_t s;
    s.id = id; s.addr = a; s.len = len; s.cache = cache; s.lock = lock;
    s.salt = data_salt;
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
      want=reference_beat(expected[rid][exp_head[rid]].addr,beats_seen[rid]) ^
           expected[rid][exp_head[rid]].salt;
      if(negative)want^=64'd1;
      if(slv_resp.r.data!==want)begin
        if(stale_mode && rid==stale_id)
          $fatal(1,"HUM_STALE_MERGE id=%0d got=%h want=%h",rid,slv_resp.r.data,want);
        else
          $fatal(1,"HUM_DATA id=%0d beat=%0d got=%h want=%h",rid,beats_seen[rid],slv_resp.r.data,want);
      end
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

  // Generalized write: len+1 beats of `data0` stepped per beat, `strb` on
  // every beat, full AXI attribute control for the WU ineligibility cases.
  task automatic send_write_b(input id_t id,input addr_t a,input logic[5:0] atop,
                              input logic [3:0] cache,input bit lock,
                              input int unsigned len,input data_t data0,
                              input strb_t strb);
    stim_t er;
    @(negedge clk);
    bexp[id]++;
    slv_req.aw='{id:id,addr:a,len:8'(len),size:3'd3,burst:axi_pkg::BURST_INCR,
                 atop:atop,cache:cache,lock:lock,default:'0};
    slv_req.aw_valid=1;
    do @(posedge clk);while(!slv_resp.aw_ready);
    if(atop[5])begin
      if(exp_tail[id]>=64)$fatal(1,"HUM_EXPECTED_CAPACITY");
      er.id=id;er.addr=a;er.len=0;er.cache=4'hf;er.lock=0;
      expected[id][exp_tail[id]]=er;exp_tail[id]++;requested++;
    end
    @(negedge clk);
    slv_req.aw_valid=0;
    for(int unsigned bt=0;bt<=len;bt++)begin
      slv_req.w='{data:data0 ^ (64'(bt)*64'h0101_0101_0101_0101),strb:strb,
                  last:(bt==len),user:'0};
      slv_req.w_valid=1;
      do @(posedge clk);while(!slv_resp.w_ready);
      @(negedge clk);
      slv_req.w_valid=0;
    end
  endtask

  task automatic send_write(input id_t id,input addr_t a,input logic[5:0] atop);
    send_write_b(id,a,atop,4'hf,1'b0,0,64'h1234,'1);
  endtask

  initial begin
    scenario = 0;
    for(int i=0;i<16;i++)begin exp_head[i]=0;exp_tail[i]=0;beats_seen[i]=0;bexp[i]=0;end
    negative = $test$plusargs("oracle_negative");
    mem_reorder = $test$plusargs("mem_reorder_ids");
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
      32: begin
        push(4'd1,64'h40000,0);
        while(!dut.gen_l2.inst_vld) @(negedge clk);
        back_inval_addr=64'h40000;
        back_inval_valid=1'b1;
        @(negedge clk);
        back_inval_valid=1'b0;
        wait_done();
        push(4'd2,64'h40000,0);
        wait_done();
        if(l2_ar_count!=2) $fatal(1,"HUM_INSTALL_INVAL_STALE ar=%0d",l2_ar_count);
      end
      33: begin
        automatic int read_mark;
        push(4'd1,64'h50000,0);
        wait_done();
        slv_req.b_ready=1'b1;
        for(int n=0;n<32;n++) push(id_t'(1+(n%2)),64'h50000,0);
        @(negedge clk);
        read_mark=issued;
        bexp[4'd8]++;
        slv_req.aw='{id:4'd8,addr:64'h51000,len:0,size:3,
                     burst:axi_pkg::BURST_INCR,cache:4'hf,default:'0};
        slv_req.aw_valid=1'b1;
        do begin
          @(posedge clk);
          if(issued-read_mark>1 && !slv_resp.aw_ready)
            $fatal(1,"HUM_WRITE_STARVE grants=%0d",issued-read_mark);
        end while(!slv_resp.aw_ready);
        @(negedge clk);
        slv_req.aw_valid=1'b0;
        slv_req.w='{data:64'h1234,strb:'1,last:1'b1,user:'0};
        slv_req.w_valid=1'b1;
        do @(posedge clk); while(!slv_resp.w_ready);
        @(negedge clk);
        slv_req.w_valid=1'b0;
        wait_done();
        while(write_completed!=1) @(negedge clk);
      end
      // Stale merge: a read arriving AFTER a back-invalidation must not merge
      // into the killed fill entry — it must refetch the line. The first
      // fill is held mid-flight (memory_hold gates the DRAM R channel) so
      // the entry is still F_FILLING when the invalidation kills it — the
      // only window where a post-inval requester can observe the killed
      // entry resident (an F_READY entry is the serve head and occupies the
      // FSM before any later request can be accepted). The second read must
      // then launch a new master AR and receive the NEW (salted) fill data,
      // while the pre-kill requester still drains the OLD fill.
      34: begin
        memory_hold = 1'b1;
        l2_ar_mark = l2_ar_count;
        push(4'd1, 64'h34000, 0);
        while (l2_ar_count == l2_ar_mark) @(negedge clk);  // fill AR out, R held
        repeat(4) @(negedge clk);            // entry sits F_FILLING
        back_inval_addr = 64'h34000;
        back_inval_valid = 1'b1;
        @(negedge clk);
        back_inval_valid = 1'b0;
        data_salt = 64'h00ff_00ff_00ff_00ff;
        stale_mode = 1'b1;
        stale_id = 4'd2;
        l2_ar_mark = l2_ar_count;
        push(4'd2, 64'h34000, 0);
        begin
          int unsigned guard = 0;
          addr_t ar_addr = '0;
          while (l2_ar_count == l2_ar_mark) begin
            @(negedge clk);
            guard++;
            if (guard > 400)
              $fatal(1, "HUM_STALE_MERGE no refetch ar=%0d", l2_ar_count);
            if (mst_req.ar_valid && mst_resp.ar_ready) ar_addr = mst_req.ar.addr;
          end
          if (ar_addr != 64'h34000)
            $fatal(1, "HUM_STALE_MERGE wrong addr=%h", ar_addr);
        end
        memory_hold = 1'b0;                  // killed fill drains + discards
        wait_done();
        if (merges != 0) $fatal(1, "HUM_STALE_MERGE merges=%0d", merges);
      end
      // ---- TAG_SRAM launched-read protocol (35-40) -------------------------
      // Functional contract is identical on both tag paths; the generate-
      // guarded counters prove the SRAM-only mechanisms actually engaged.
      // Set-0 addresses stride 0x400 (index field [9:6]).
      // (a) Install into the launched set on the launch cycle: sweep the
      // offset between a set-0 miss's install edge and a following set-0
      // request so some iteration lands the install on the row read.
      35: begin
        for (int w = 0; w < int'(SET_ASSOC); w++)
          push(id_t'(1 + w), 64'h60000 + addr_t'(w) * 64'h400, 0);
        wait_done();
        for (int unsigned off = 0; off < 28; off++) begin
          push(4'd1, 64'h60000 + addr_t'(4 + off) * 64'h400, 0);
          repeat (off) @(negedge clk);
          push(4'd2, 64'h60000 + addr_t'(4 + 28 + off) * 64'h400, 0);
          wait_done(8000);
        end
        if (TAG_SRAM && fwd_launch_cycles == 0)
          $fatal(1, "HUM_TAG_FWD_LAUNCH_DEAD");
      end
      // (b) Install landing while a same-set lookup sits in S_TAG: the
      // combinational forward must make it visible. The held request is
      // stalled on the evict offer while an earlier fill installs.
      36: begin
        for (int w = 0; w < int'(SET_ASSOC) - 1; w++)
          push(id_t'(1 + w), 64'h70000 + addr_t'(w) * 64'h400, 0);
        wait_done();
        check_evict_addr = 1'b1;
        for (int unsigned k = 0; k < 12; k++) begin
          // Miss A: commits to the last invalid way; its fill installs later.
          // Miss B: every way valid or pending -> valid victim -> evict offer
          // -> held while evict_ready is low; A's install lands mid-hold.
          push(4'd1, 64'h70000 + addr_t'(3 + 2 * k) * 64'h400, 0);
          @(negedge clk);
          evict_ready = 1'b0;
          push(4'd2, 64'h70000 + addr_t'(4 + 2 * k) * 64'h400, 0);
          while (!(dut.gen_l2.state_q == L2_S_TAG)) @(negedge clk);
          // Hold across A's install edge — that is the use-cycle forward
          // condition (bounded so a missed coincidence cannot hang).
          for (int unsigned g = 0; g < 60 && !dut.gen_l2.tag_write; g++)
            @(negedge clk);
          repeat (2) @(negedge clk);
          evict_ready = 1'b1;
          wait_done(8000);
        end
        check_evict_addr = 1'b0;
        if (TAG_SRAM && comb_fwd_cycles == 0)
          $fatal(1, "HUM_TAG_FWD_COMB_DEAD");
      end
      // (c) A back-invalidation while a lookup holds in S_TAG steals the read
      // port for exactly one cycle; the request must then decide correctly.
      37: begin
        automatic int unsigned mark;
        push(4'd9, 64'h70040, 0);                // resident line in set 1
        for (int w = 0; w < int'(SET_ASSOC); w++)
          push(id_t'(1 + w), 64'h80000 + addr_t'(w) * 64'h400, 0);
        wait_done();
        evict_ready = 1'b0;
        push(4'd1, 64'h80000 + 64'h1000, 0);     // set-0 miss, valid victim -> held
        while (!(dut.gen_l2.state_q == L2_S_TAG && evict_v)) @(negedge clk);
        repeat (3) @(negedge clk);
        mark = steal_cycles;
        back_inval_addr = 64'h70040; back_inval_valid = 1'b1;
        @(negedge clk);
        back_inval_valid = 1'b0;
        repeat (4) @(negedge clk);
        evict_ready = 1'b1;
        wait_done();
        if (TAG_SRAM && steal_cycles != mark + 1)
          $fatal(1, "HUM_TAG_STEAL got=%0d want=1", steal_cycles - mark);
        l2_ar_mark = l2_ar_count;
        push(4'd2, 64'h70040, 0); wait_done();   // invalidated -> refetch
        if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_TAG_INVAL_LOST ar=%0d", l2_ar_count);
      end
      // (d) S_TAG re-entry after the S_SERVE deadlock-break interrupt: the
      // row must already be valid on the first re-entry cycle.
      38: begin
        memory_hold = 1'b1;
        for (int e = 0; e < int'(MSHR_DEPTH); e++)
          push(id_t'(1 + e), 64'h90000 + addr_t'(e) * 64'h40, 0);  // 4 sets fill the MSHR
        while (l2_ar_count != MSHR_DEPTH) @(negedge clk);
        repeat (4) @(negedge clk);               // let all four allocate
        push(4'd5, 64'hA0000, 0);                // 5th miss: stalls in S_TAG
        while (!(dut.gen_l2.state_q == L2_S_TAG)) @(negedge clk);
        repeat (4) @(negedge clk);               // held: no MSHR, no serve_pend
        memory_hold = 1'b0;                      // fills drain -> interrupt path
        wait_done(12000);
        if (intr_retag_seen == 0) $fatal(1, "HUM_TAG_RETAG_NEVER_ENGAGED");
        if (TAG_SRAM && retag_stalled)
          $fatal(1, "HUM_TAG_RETAG_STALL");
      end
      // (e) Victim probe after a forwarded install: every eviction's
      // announced address must be the victim way's resident line, even when
      // the row was read the same cycle the current occupant was installed.
      39: begin
        check_evict_addr = 1'b1;
        for (int w = 0; w < int'(SET_ASSOC); w++)
          push(id_t'(1 + w), 64'hA0000 + addr_t'(w) * 64'h400, 0);
        wait_done();
        for (int unsigned k = 0; k < 24; k++) begin
          push(id_t'(1 + (k % 2)), 64'hA0000 + addr_t'(4 + k) * 64'h400, 0);
          repeat (k % 6) @(negedge clk);
        end
        wait_done(16000);
        check_evict_addr = 1'b0;
        if (TAG_SRAM && fwd_launch_cycles + comb_fwd_cycles == 0)
          $fatal(1, "HUM_TAG_PROBE_NEVER_FWD");
      end
      // (f) Two chained same-set match-invalidation reads: both deferred
      // clears must land and the untouched line must keep hitting.
      40: begin
        push(4'd1, 64'hB0000, 0);
        push(4'd1, 64'hB0400, 0);
        push(4'd1, 64'hB0800, 0);
        wait_done();
        back_inval_addr = 64'hB0000; back_inval_valid = 1'b1;
        @(negedge clk);
        back_inval_addr = 64'hB0400;             // second steal, chained
        @(negedge clk);
        back_inval_valid = 1'b0;
        l2_ar_mark = l2_ar_count;
        push(4'd2, 64'hB0000, 0); wait_done();
        push(4'd2, 64'hB0400, 0); wait_done();
        if (l2_ar_count != l2_ar_mark + 2)
          $fatal(1, "HUM_TAG_INVAL_LOST2 ar=%0d", l2_ar_count);
        push(4'd3, 64'hB0800, 0); wait_done();   // untouched: hit, no AR
        if (l2_ar_count != l2_ar_mark + 2)
          $fatal(1, "HUM_TAG_INVAL_OVER ar=%0d", l2_ar_count);
      end
      // (g) Deferred inval-match must compare the set's VALID state as of the
      // match-read cycle, not at the deferred compare. Corner: a fill installs
      // tag T2 into a way whose stale row entry still holds the match tag T —
      // a live-valid compare at the deferred cycle would drop the fresh line
      // (the flop array samples valid before the write and keeps it).
      // Setup: fill one set, write to the way-0 line (self-inval clears the
      // valid bit; the SRAM row keeps the stale tag), then hold a second
      // write's W channel so wr_self_inval spans the install edge of a new
      // miss into that freed way. A surviving line means no refetch on the
      // re-read; a spuriously cleared one costs one DRAM AR.
      41: begin
        slv_req.b_ready = 1'b1;                // both writes need their B drain
        for (int w = 0; w < int'(SET_ASSOC); w++)
          push(id_t'(1 + w), 64'hC0000 + addr_t'(w) * 64'h400, 0);
        wait_done();
        send_write(4'd9, 64'hC0000, 6'h00);    // clears way 0, stale tag stays
        repeat (4) @(negedge clk);
        memory_hold = 1'b1;
        l2_ar_mark = l2_ar_count;
        push(4'd5, 64'hC0000 + addr_t'(SET_ASSOC) * 64'h400, 0);  // miss -> way 0
        begin
          int unsigned g = 0;
          while (l2_ar_count == l2_ar_mark && g < 2000) begin
            @(negedge clk); g++;
          end
          if (l2_ar_count == l2_ar_mark) begin
            $display("S41DBG state=%0d ar_v=%0b ar_r=%0b act=%b fstate=%b serve_pend=%0b wip=%0b alloc=%0b",
                     dut.gen_l2.state_q, slv_req.ar_valid, slv_resp.ar_ready,
                     dut.gen_l2.fill_act_q, dut.gen_l2.fill_state_q[0],
                     dut.gen_l2.serve_pend, dut.gen_l2.wr_inval_pend_q,
                     dut.gen_l2.mshr_alloc);
            $fatal(1, "HUM_S41_NO_FILL_AR");
          end
        end
        // Second write to the cleared line: hold W so the self-inval window
        // (S_BYPASS_AW..S_BYPASS_W) definitely covers the fill's install edge.
        @(negedge clk);
        bexp[4'd9]++;
        slv_req.aw='{id:4'd9,addr:64'hC0000,len:0,size:3,
                     burst:axi_pkg::BURST_INCR,atop:6'h00,cache:4'hf,default:'0};
        slv_req.aw_valid=1;
        begin
          int unsigned g = 0;
          do begin @(posedge clk); g++; end while(!slv_resp.aw_ready && g < 2000);
          if (!slv_resp.aw_ready) $fatal(1, "HUM_S41_AW_STUCK state=%0d", dut.gen_l2.state_q);
        end
        @(negedge clk); slv_req.aw_valid=0;
        repeat (6) @(negedge clk);               // stalled in S_BYPASS_W
        memory_hold = 1'b0;                      // fill drains, install lands mid-window
        repeat (40) @(negedge clk);              // install + deferred compare settle
        slv_req.w='{data:64'h1234,strb:'1,last:1'b1,user:'0};
        slv_req.w_valid=1;
        begin
          int unsigned g = 0;
          do begin @(posedge clk); g++; end while(!slv_resp.w_ready && g < 2000);
          if (!slv_resp.w_ready) $fatal(1, "HUM_S41_W_STUCK state=%0d", dut.gen_l2.state_q);
        end
        @(negedge clk); slv_req.w_valid=0;
        memory_hold = 1'b0;
        wait_done();
        // Under WRITE_UPDATE the second write merges into the still-resident
        // line — no inval-match stream runs, so the deferred-compare corner
        // does not engage; the WU coverage is the install stall on the
        // merge's way while the fill drains.
        if (TAG_SRAM && !WRITE_UPDATE && invw_corner_cycles == 0)
          $fatal(1, "HUM_TAG_INVW_DEAD");
        if (WRITE_UPDATE && wu_stall_cycles == 0)
          $fatal(1, "HUM_WU_STALL_DEAD");
        l2_ar_mark = l2_ar_count;
        push(4'd6, 64'hC0000 + addr_t'(SET_ASSOC) * 64'h400, 0);
        wait_done();                             // re-read: must hit, no refetch
        if (l2_ar_count != l2_ar_mark)
          $fatal(1, "HUM_TAG_STALE_CLEAR ar=%0d", l2_ar_count);
      end
      // ---- WRITE_UPDATE directed contract (42-48) -------------------------
      // (a) Resident line, single-beat partial-strobe write: merges in place
      // under WU (hit, no DRAM AR); the same bytes must be in memory — an
      // invalidate+refetch returns them too.
      42: begin
        push(4'd1, 64'h50000, 0);
        wait_done();
        slv_req.b_ready = 1'b1;
        l2_ar_mark = l2_ar_count;
        wupd_mark = wupd_count;
        send_write_b(4'd9, 64'h50008, 6'h00, 4'hf, 1'b0, 0,
                     64'hdead_beef_cafe_f00d, 8'h0f);
        while (write_completed != 1) @(negedge clk);
        push(4'd2, 64'h50008, 0);            // resident read-back
        wait_done();
        if (WRITE_UPDATE) begin
          if (l2_ar_count != l2_ar_mark)
            $fatal(1, "HUM_WU_REFETCH ar=%0d", l2_ar_count);
          if (wupd_count != wupd_mark + 1)
            $fatal(1, "HUM_WU_NO_MERGE wupd=%0d", wupd_count);
        end else if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_WU_REFETCH ar=%0d", l2_ar_count);
        // Memory-side check: drop the merged line, refetch — memory must
        // carry the same patched bytes the hit returned.
        back_inval_addr = 64'h50000; back_inval_valid = 1'b1;
        @(negedge clk);
        back_inval_valid = 1'b0;
        push(4'd3, 64'h50008, 0);
        wait_done();
        if (l2_ar_count != l2_ar_mark + (WRITE_UPDATE ? 2'(1) : 2'(2)))
          $fatal(1, "HUM_WU_MEM_BYTES ar=%0d", l2_ar_count);
      end
      // (b) Multi-beat full-width write inside one line: both beats merge.
      43: begin
        push(4'd1, 64'h51000, 0);
        wait_done();
        slv_req.b_ready = 1'b1;
        l2_ar_mark = l2_ar_count;
        wupd_mark = wupd_count;
        send_write_b(4'd9, 64'h51008, 6'h00, 4'hf, 1'b0, 1,
                     64'h1111_2222_3333_4444, '1);
        while (write_completed != 1) @(negedge clk);
        push(4'd2, 64'h51008, 0);
        push(4'd3, 64'h51010, 0);
        wait_done();
        if (WRITE_UPDATE) begin
          if (l2_ar_count != l2_ar_mark)
            $fatal(1, "HUM_WU_REFETCH ar=%0d", l2_ar_count);
          if (wupd_count != wupd_mark + 1)
            $fatal(1, "HUM_WU_NO_MERGE wupd=%0d", wupd_count);
        end else if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_WU_REFETCH ar=%0d", l2_ar_count);
      end
      // (c) Write to a non-resident line: never allocates; the later read
      // fetches memory's post-write bytes. Mode-independent contract.
      44: begin
        slv_req.b_ready = 1'b1;
        l2_ar_mark = l2_ar_count;
        wupd_mark = wupd_count;
        send_write_b(4'd9, 64'h52008, 6'h00, 4'hf, 1'b0, 0,
                     64'h5eed_5eed_5eed_5eed, '1);
        while (write_completed != 1) @(negedge clk);
        push(4'd2, 64'h52008, 0);
        wait_done();
        if (wupd_count != wupd_mark)
          $fatal(1, "HUM_WU_PHANTOM_MERGE wupd=%0d", wupd_count);
        if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_WU_NONRESIDENT ar=%0d", l2_ar_count);
      end
      // (d) ATOP write to a resident line: memory-side result carries an R
      // beat; the line must be invalidated, not merged.
      45: begin
        push(4'd1, 64'h53000, 0);
        wait_done();
        slv_req.b_ready = 1'b1;
        l2_ar_mark = l2_ar_count;
        wupd_mark = wupd_count;
        send_write_b(4'd9, 64'h53008, axi_pkg::ATOP_ATOMICSWAP, 4'hf, 1'b0,
                     0, 64'h0bad_0bad_0bad_0bad, '1);
        while (write_completed != 1) @(negedge clk);
        push(4'd2, 64'h53008, 0);
        wait_done();
        if (wupd_count != wupd_mark)
          $fatal(1, "HUM_WU_ATOP_MERGE wupd=%0d", wupd_count);
        if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_WU_ATOP_KEPT ar=%0d", l2_ar_count);
      end
      // (e) Locked write to a resident line: same ineligible path.
      46: begin
        push(4'd1, 64'h54000, 0);
        wait_done();
        slv_req.b_ready = 1'b1;
        l2_ar_mark = l2_ar_count;
        wupd_mark = wupd_count;
        send_write_b(4'd9, 64'h54008, 6'h00, 4'hf, 1'b1, 0,
                     64'hc001_c001_c001_c001, '1);
        while (write_completed != 1) @(negedge clk);
        push(4'd2, 64'h54008, 0);
        wait_done();
        if (wupd_count != wupd_mark)
          $fatal(1, "HUM_WU_LOCK_MERGE wupd=%0d", wupd_count);
        if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_WU_LOCK_KEPT ar=%0d", l2_ar_count);
      end
      // (f) Non-cacheable write to a resident line: bypasses the tags but
      // must still drop the stale cached copy.
      47: begin
        push(4'd1, 64'h55000, 0);
        wait_done();
        slv_req.b_ready = 1'b1;
        l2_ar_mark = l2_ar_count;
        wupd_mark = wupd_count;
        send_write_b(4'd9, 64'h55008, 6'h00, 4'h0, 1'b0, 0,
                     64'h0f0f_0f0f_0f0f_0f0f, '1);
        while (write_completed != 1) @(negedge clk);
        push(4'd2, 64'h55008, 0);
        wait_done();
        if (wupd_count != wupd_mark)
          $fatal(1, "HUM_WU_NC_MERGE wupd=%0d", wupd_count);
        if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_WU_NC_KEPT ar=%0d", l2_ar_count);
      end
      // (g) Write while a same-line fill is in flight: kill_match fires
      // whether or not the tag clear is suppressed — the killed fill drains
      // and discards, and a read issued after B refetches the new bytes.
      48: begin
        memory_hold = 1'b1;
        l2_ar_mark = l2_ar_count;
        push(4'd1, 64'h56000, 0);
        while (l2_ar_count == l2_ar_mark) @(negedge clk);  // fill AR out, R held
        repeat (4) @(negedge clk);                          // entry F_FILLING
        slv_req.b_ready = 1'b1;
        send_write_b(4'd9, 64'h56008, 6'h00, 4'hf, 1'b0, 0,
                     64'hf111_f111_f111_f111, '1);
        while (write_completed != 1) @(negedge clk);
        memory_hold = 1'b0;
        wait_done();
        wupd_mark = wupd_count;
        l2_ar_mark = l2_ar_count;
        push(4'd2, 64'h56008, 0);
        wait_done();
        if (wupd_count != wupd_mark)
          $fatal(1, "HUM_WU_FILL_MERGE wupd=%0d", wupd_count);
        if (l2_ar_count != l2_ar_mark + 1)
          $fatal(1, "HUM_WU_FILL_KILL ar=%0d", l2_ar_count);
      end
      // ---- POSTED_WRITES directed contract (49-59) -------------------------
      // (a) Read miss to a tracked-write line holds until the write's B
      // (R1); the fill then carries the write's bytes — the miss path of
      // read-after-write.
      49: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        send_write(4'd1, 64'h24000, 6'h00);          // posted; B held
        l2_ar_mark = l2_ar_count;
        push(4'd2, 64'h24000, 0);                    // same-line read miss
        begin automatic int g = 0;
          while (pw_line_hold == 0 && l2_ar_count == l2_ar_mark && g < 200) begin
            @(posedge clk); g++;
          end
          if (l2_ar_count != l2_ar_mark)
            $fatal(1, "HUM_R1_FILL_LAUNCHED ar=%0d", l2_ar_count);
          if (pw_line_hold == 0) $fatal(1, "HUM_R1_NO_HOLD");
          // The hold pulse alone does not prove the commit gate held — it
          // also fires on a miss that leaked through a dropped R1. Confirm
          // no miss AR leaves while the write's B is still held.
          for (g = 0; g < 40 && l2_ar_count == l2_ar_mark; g++)
            @(posedge clk);
          if (l2_ar_count != l2_ar_mark)
            $fatal(1, "HUM_R1_FILL_LAUNCHED ar=%0d", l2_ar_count);
        end
        if (l2_idle_w) $fatal(1, "HUM_IDLE_EARLY");
        memory_b_hold = 1'b0;
        wait_done();                                 // fill = post-write bytes
        if (!l2_idle_w) $fatal(1, "HUM_IDLE_LATE");
        if (pw_posted != 1) $fatal(1, "HUM_POSTED_COUNT %0d", pw_posted);
      end
      // (a2) Resident-line read hit during a tracked write serves the
      // merged bytes immediately — R1 holds only misses (WU merge path).
      50: begin
        if (!POSTED_WRITES || !WRITE_UPDATE)
          $fatal(1, "HUM_POSTED_WU_REQUIRED");
        slv_req.b_ready = 1'b1;
        push(4'd1, 64'h24100, 0);
        wait_done();                                 // line resident
        memory_b_hold = 1'b1;
        send_write(4'd2, 64'h24108, 6'h00);          // merge + posted
        push(4'd3, 64'h24108, 0);                    // hit — no hold
        wait_done();                                 // merged bytes verified
        memory_b_hold = 1'b0;
        while (write_completed != 1) @(negedge clk);
      end
      // (b) Different-slave-id posted write to a tracked line (T9e/M1d):
      // both posts forward on the reserved WR_ID, so R2 compares equal
      // downstream ids and the second AW is admitted with no hold — the
      // +mem_reorder_ids knob has nothing to reorder on a single id.
      51: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        send_write_b(4'd1, 64'h24200, 6'h00, 4'hf, 1'b0, 0,
                     64'h1111_1111_1111_1111, '1);
        bexp[4'd2]++;
        @(negedge clk);
        slv_req.aw = '{id: 4'd2, addr: 64'h24200, len: 0, size: 3'd3,
                       burst: axi_pkg::BURST_INCR, atop: 6'h00, cache: 4'hf,
                       lock: 1'b0, default: '0};
        slv_req.aw_valid = 1'b1;
        do @(posedge clk); while (!slv_resp.aw_ready);
        @(negedge clk);
        slv_req.aw_valid = 1'b0;
        slv_req.w = '{data: 64'h2222_2222_2222_2222, strb: '1, last: 1'b1,
                      user: '0};
        slv_req.w_valid = 1'b1;
        do @(posedge clk); while (!slv_resp.w_ready);
        @(negedge clk);
        slv_req.w_valid = 1'b0;
        memory_b_hold = 1'b0;
        while (write_completed != 2) @(negedge clk);
        if (pw_r2_hold != 0) $fatal(1, "HUM_R2_HELD cycles=%0d", pw_r2_hold);
        if (patched_word(64'h24200) != 64'h2222_2222_2222_2222)
          $fatal(1, "HUM_R2_MEMORY_ORDER %h", patched_word(64'h24200));
      end
      // (c) Same-id consecutive writes to one line: admitted without the
      // R2 hold (same id), per-id B order preserved.
      52: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        send_write_b(4'd3, 64'h24300, 6'h00, 4'hf, 1'b0, 0,
                     64'h3333_3333_3333_3333, '1);
        bexp[4'd3]++;
        @(negedge clk);
        slv_req.aw = '{id: 4'd3, addr: 64'h24300, len: 0, size: 3'd3,
                       burst: axi_pkg::BURST_INCR, atop: 6'h00, cache: 4'hf,
                       lock: 1'b0, default: '0};
        slv_req.aw_valid = 1'b1;
        begin automatic int g = 0;
          do begin @(posedge clk); g++; end while (!slv_resp.aw_ready && g < 200);
          if (g >= 200) $fatal(1, "HUM_SAMEID_HELD");
        end
        @(negedge clk);
        slv_req.aw_valid = 1'b0;
        slv_req.w = '{data: 64'h4444_4444_4444_4444, strb: '1, last: 1'b1,
                      user: '0};
        slv_req.w_valid = 1'b1;
        do @(posedge clk); while (!slv_resp.w_ready);
        @(negedge clk);
        slv_req.w_valid = 1'b0;
        memory_b_hold = 1'b0;
        while (write_completed != 2) @(negedge clk);
        if (patched_word(64'h24300) != 64'h4444_4444_4444_4444)
          $fatal(1, "HUM_SAMEID_ORDER %h", patched_word(64'h24300));
      end
      // (d) Full write tracker: the next AW backpressures (wtrk_full
      // pulse), nothing is lost.
      53: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        for (int k = 0; k < WTRK_DEPTH; k++)
          send_write_b(id_t'(k + 1), 64'h24400 + addr_t'(k) * 64'h100, 6'h00,
                       4'hf, 1'b0, 0, 64'h5555 + data_t'(k), '1);
        bexp[4'd9]++;
        @(negedge clk);
        slv_req.aw = '{id: 4'd9, addr: 64'h24800, len: 0, size: 3'd3,
                       burst: axi_pkg::BURST_INCR, atop: 6'h00, cache: 4'hf,
                       lock: 1'b0, default: '0};
        slv_req.aw_valid = 1'b1;
        repeat (10) @(posedge clk);
        if (slv_resp.aw_ready) $fatal(1, "HUM_WTRK_FULL_ACCEPTED");
        if (pw_wtrk_full == 0) $fatal(1, "HUM_WTRK_FULL_NO_PULSE");
        memory_b_hold = 1'b0;
        do @(posedge clk); while (!slv_resp.aw_ready);
        @(negedge clk);
        slv_req.aw_valid = 1'b0;
        slv_req.w = '{data: 64'h9999, strb: '1, last: 1'b1, user: '0};
        slv_req.w_valid = 1'b1;
        do @(posedge clk); while (!slv_resp.w_ready);
        @(negedge clk);
        slv_req.w_valid = 1'b0;
        while (write_completed != WTRK_DEPTH + 1) @(negedge clk);
      end
      // (e) Posted Bs from four requesters route back to their own ids —
      // +mem_reorder_ids lets them arrive in any cross-id order; the per-id
      // B accounting catches a misroute.
      54: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        for (int k = 0; k < 4; k++)
          send_write_b(id_t'(10 + k), 64'h24A00 + addr_t'(k) * 64'h100, 6'h00,
                       4'hf, 1'b0, 0, 64'haa00 + data_t'(k), '1);
        memory_b_hold = 1'b0;
        while (write_completed != 4) @(negedge clk);
        if (pw_posted != 4) $fatal(1, "HUM_POSTED_COUNT %0d", pw_posted);
      end
      // (f) Tracked NC reads interleaved with a hit response and a fill
      // serve — every slave R burst stays atomic (HUM_R_INTERLEAVE fires
      // on any cut-in).
      55: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        push(4'd1, 64'h24B00, 0);
        wait_done();                                 // line resident
        push(4'd2, 64'h24B40, 2, 4'b0000);           // NC read, 3 beats
        push(4'd1, 64'h24B00, 0);                    // hit response
        push(4'd3, 64'h24BC0, 1, 4'b0000);           // NC read, 2 beats
        push(4'd4, 64'h24C00, 0);                    // miss -> fill serve
        wait_done();
        if (pw_rdtrk < 2) $fatal(1, "HUM_RDTRK_NO_TRACK %0d", pw_rdtrk);
      end
      // (g) Same-id ordering (R5): a hit response whose id has a live
      // tracked read holds until that read's burst completes — the
      // collector's per-id queue detects any out-of-order R.
      56: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        push(4'd5, 64'h24D00, 0);
        wait_done();                                 // line resident
        memory_hold = 1'b1;
        push(4'd5, 64'h24D40, 3, 4'b0000);           // tracked NC read id5
        begin automatic int g = 0;
          while (pw_rdtrk_push == 0 && g < 200) begin @(posedge clk); g++; end
          if (pw_rdtrk_push == 0) $fatal(1, "HUM_RDTRK_NO_ENTRY");
        end
        push(4'd5, 64'h24D00, 0);                    // same-id hit — R5 hold
        begin automatic int g = 0;
          while (pw_r5_hold == 0 && g < 200) begin @(posedge clk); g++; end
          if (pw_r5_hold == 0) $fatal(1, "HUM_R5_NO_HOLD");
        end
        memory_hold = 1'b0;
        wait_done();
      end
      // (h) ATOP and lock writes take the blocking path (tracker entry
      // blocking=1, no posted pulse) and still receive their B/R.
      57: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        send_write_b(4'd7, 64'h24E00, axi_pkg::ATOP_ATOMICSWAP, 4'hf, 1'b0,
                     0, 64'h7777, '1);
        send_write_b(4'd7, 64'h24E40, 6'h00, 4'hf, 1'b1, 0, 64'h8888, '1);
        begin automatic int g = 0;
          while ((write_completed != 2 || mem_atomic_r != 1) && g < 2000) begin
            @(posedge clk); g++;
          end
          if (g >= 2000) $fatal(1, "HUM_BLOCKING_TIMEOUT");
        end
        if (pw_posted != 0) $fatal(1, "HUM_BLOCKING_POSTED %0d", pw_posted);
      end
      // (i) Posted write racing an in-flight same-line fill: kill_match
      // semantics unchanged — write posts and reaches memory, the killed
      // fill drains, later reads return post-write data.
      58: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_hold = 1'b1;
        l2_ar_mark = l2_ar_count;
        push(4'd1, 64'h24F00, 0);
        while (l2_ar_count == l2_ar_mark) @(negedge clk);  // fill AR out
        repeat (4) @(negedge clk);
        send_write(4'd2, 64'h24F08, 6'h00);          // posts while fill held
        while (write_completed != 1) @(negedge clk);
        memory_hold = 1'b0;
        wait_done();
        l2_ar_mark = l2_ar_count;
        push(4'd3, 64'h24F08, 0);                    // refetch post-write data
        wait_done();
        if (pw_posted != 1) $fatal(1, "HUM_POSTED_COUNT %0d", pw_posted);
      end
      // (j) l2_write_idle_o: deasserts while a posted write is tracked,
      // reasserts only after the tracker drains — the CMO engine's
      // clean/flush ordering input.
      59: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        if (!l2_idle_w) $fatal(1, "HUM_IDLE_BASELINE");
        memory_b_hold = 1'b1;
        send_write(4'd3, 64'h25000, 6'h00);
        repeat (3) @(posedge clk);
        if (l2_idle_w) $fatal(1, "HUM_IDLE_WHILE_TRACKED");
        memory_b_hold = 1'b0;
        while (write_completed != 1) @(negedge clk);
        repeat (3) @(posedge clk);
        if (!l2_idle_w) $fatal(1, "HUM_IDLE_AFTER_DRAIN");
      end
      // T9e/M1d ordering oracle: three posted writes to one line from
      // three different slave ids all forward on WR_ID — no l2_hold_r2
      // cycle, and under +mem_reorder_ids the single downstream id keeps
      // B (and byte-apply) order strict FIFO, so memory must end with the
      // third write. The pw_wrid mutation (posted writes forwarded on
      // their original ids while the tracker still records WR_ID) leaves
      // every memory B unroutable — the bounded drain below fires
      // HUM_WID_DRAIN instead of hanging.
      60: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        send_write_b(4'd1, 64'h25600, 6'h00, 4'hf, 1'b0, 0,
                     64'haaaa_0000_0000_0001, '1);
        send_write_b(4'd2, 64'h25600, 6'h00, 4'hf, 1'b0, 0,
                     64'haaaa_0000_0000_0002, '1);
        send_write_b(4'd3, 64'h25600, 6'h00, 4'hf, 1'b0, 0,
                     64'haaaa_0000_0000_0003, '1);
        memory_b_hold = 1'b0;
        begin automatic int g = 0;
          while (write_completed != 3 && g < 2000) begin
            @(posedge clk); g++;
          end
          if (g >= 2000) $fatal(1, "HUM_WID_DRAIN completed=%0d",
                              write_completed);
        end
        if (pw_r2_hold != 0) $fatal(1, "HUM_WID_R2_CYCLES %0d", pw_r2_hold);
        if (patched_word(64'h25600) != 64'haaaa_0000_0000_0003)
          $fatal(1, "HUM_WID_MEMORY_ORDER %h", patched_word(64'h25600));
      end
      // T9e/M1d mixed-id hold: a posted write tracked on WR_ID then a
      // blocking store-atomic (atop[5]=0, no R) to the same line — the
      // atomic keeps its original id downstream, so the pair has
      // different downstream ids and the R2 hold still applies. Under
      // +mem_reorder_ids the pw_r2 mutation (admit different downstream
      // ids) lets the atomic's bytes land under the posted write's —
      // HUM_ATOP_MEMORY_ORDER catches it.
      61: begin
        if (!POSTED_WRITES) $fatal(1, "HUM_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        send_write_b(4'd1, 64'h25700, 6'h00, 4'hf, 1'b0, 0,
                     64'hbbbb_0000_0000_0001, '1);
        bexp[4'd5]++;
        @(negedge clk);
        slv_req.aw = '{id: 4'd5, addr: 64'h25700, len: 0, size: 3'd3,
                       burst: axi_pkg::BURST_INCR, atop: 6'h10, cache: 4'hf,
                       lock: 1'b0, default: '0};
        slv_req.aw_valid = 1'b1;
        begin automatic bit aw_acc = 1'b0;
          repeat (10) begin
            @(posedge clk);
            if (slv_resp.aw_ready) aw_acc = 1'b1;
          end
          if (aw_acc) $fatal(1, "HUM_ATOP_AW_ACCEPTED");
        end
        if (pw_r2_hold == 0) $fatal(1, "HUM_ATOP_NO_HOLD");
        memory_b_hold = 1'b0;
        do @(posedge clk); while (!slv_resp.aw_ready);
        @(negedge clk);
        slv_req.aw_valid = 1'b0;
        slv_req.w = '{data: 64'hbbbb_0000_0000_0002, strb: '1, last: 1'b1,
                      user: '0};
        slv_req.w_valid = 1'b1;
        do @(posedge clk); while (!slv_resp.w_ready);
        @(negedge clk);
        slv_req.w_valid = 1'b0;
        begin automatic int g = 0;
          while (write_completed != 2 && g < 2000) begin
            @(posedge clk); g++;
          end
          if (g >= 2000) $fatal(1, "HUM_ATOP_DRAIN completed=%0d",
                              write_completed);
        end
        if (patched_word(64'h25700) != 64'hbbbb_0000_0000_0002)
          $fatal(1, "HUM_ATOP_MEMORY_ORDER %h", patched_word(64'h25700));
      end
      // ---------------- T9h/M5 prefetch directed contract (62-64) ---------
      // (a) Useful hit after a stream: three next-line demand misses arm
      // the stream; both PF fills issue, and a demand read of each
      // PF-installed line is a hit (or an in-flight merge — still useful)
      // that queues no new fill AR.
      62: begin
        if (!PREFETCH) $fatal(1, "HUM_PREFETCH_REQUIRED");
        push(4'd1, 64'h26000, 0); wait_done();
        push(4'd1, 64'h26040, 0); wait_done();
        push(4'd1, 64'h26080, 0); wait_done();
        begin automatic int g = 0;
          while (pf_issue != 2 && g < 400) begin @(posedge clk); g++; end
          if (pf_issue != 2) $fatal(1, "HUM_PF_NO_ISSUE issue=%0d", pf_issue);
        end
        wait_done();
        repeat (80) @(posedge clk);            // let both fills install
        l2_ar_mark = mem_ar_count;
        push(4'd2, 64'h260C0, 0); wait_done();
        push(4'd2, 64'h26100, 0); wait_done();
        if (pf_useful != 2) $fatal(1, "HUM_PF_NO_USEFUL useful=%0d", pf_useful);
        if (mem_ar_count != l2_ar_mark)
          $fatal(1, "HUM_PF_USEFUL_REFETCH ar=%0d", mem_ar_count - l2_ar_mark);
      end
      // (b) A same-line write kills an in-flight PF fill: install_discard
      // applies, the line never installs, a later read refetches post-write
      // data (the killed fill may not serve the stale fetch).
      63: begin
        if (!PREFETCH || !POSTED_WRITES) $fatal(1, "HUM_PREFETCH_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        push(4'd1, 64'h27000, 0); wait_done();
        push(4'd1, 64'h27040, 0); wait_done();
        memory_hold = 1'b1;
        push(4'd1, 64'h27080, 0);            // arms; cand 270C0 issues & holds
        begin automatic int g = 0;
          while (pf_issue == 0 && g < 400) begin @(posedge clk); g++; end
          if (pf_issue == 0) $fatal(1, "HUM_PF_NO_ISSUE");
        end
        send_write(4'd2, 64'h270C8, 6'h00);  // kills the in-flight pf fill
        while (write_completed != 1) @(negedge clk);
        memory_hold = 1'b0;
        wait_done();
        repeat (80) @(posedge clk);          // killed fill drains + retires
        l2_ar_mark = mem_ar_count;
        push(4'd3, 64'h270C0, 0); wait_done(); // refetch — not a stale hit
        repeat (80) @(posedge clk);            // retrained follow-on PF drains
        // +1 refetch AR on the killed line; +1 fill AR from the follow-on
        // candidate (27140) the refetch's demand-miss train re-armed.
        if (mem_ar_count != l2_ar_mark + 2)
          $fatal(1, "HUM_PF_KILL_INSTALL ar=%0d", mem_ar_count - l2_ar_mark);
      end
      // (c) R1: a posted write whose B is held keeps its wtrk entry live;
      // a PF candidate for the tracked line drops (a read fill now could
      // return pre-write memory), while the other candidate still issues.
      64: begin
        if (!PREFETCH || !POSTED_WRITES) $fatal(1, "HUM_PREFETCH_POSTED_REQUIRED");
        slv_req.b_ready = 1'b1;
        memory_b_hold = 1'b1;
        send_write(4'd4, 64'h280C0, 6'h00);
        push(4'd1, 64'h28000, 0); wait_done();
        push(4'd1, 64'h28040, 0); wait_done();
        push(4'd1, 64'h28080, 0); wait_done(); // armed: cands 280C0/28100
        l2_ar_mark = mem_ar_count;
        begin automatic int g = 0;
          while (pf_drop == 0 && pf_issue == 0 && g < 400) begin
            @(posedge clk); g++;
          end
          if (pf_drop == 0) $fatal(1, "HUM_PF_R1_ISSUE");
        end
        // The tracked candidate must never reach DRAM; the untracked one may.
        wait_done();
        repeat (80) @(posedge clk);
        if (mem_ar_count > l2_ar_mark + 1)
          $fatal(1, "HUM_PF_R1_FILL ar=%0d", mem_ar_count - l2_ar_mark);
        memory_b_hold = 1'b0;
        while (write_completed != 1) @(negedge clk);
        push(4'd5, 64'h280C0, 0); wait_done(); // post-write data
      end
      default: $fatal(1, "HUM_SCENARIO");
    endcase

    // Write-only scenarios complete no slave R beats; close the window on
    // the scenario's own cycle counter instead of the last read beat.
    if (end_cyc <= start_cyc) end_cyc = cyc;
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
