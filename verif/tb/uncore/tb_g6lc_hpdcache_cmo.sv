// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//
// Leaf testbench for the T9a CMO response hold in cva6_hpdcache_if_adapter
// (store port, IsLoadPort=0). A line CBO is sent to HPDCACHE as a CMO_*
// request (need_rsp=1) AND — under L2CmoEn — issued on the cmo_* sideband;
// its hpdcache response (tid='0) is swallowed and the core's data_rvalid is
// released only when BOTH the response and cmo_done_i have arrived.
//
// Oracles:
//   - request maps cbo_op -> HPDCACHE_REQ_CMO_*_NLINE, need_rsp=1, tid='0
//     (HPDCACHE_CMO_MAP);
//   - exactly one cmo_valid_o issue, held until cmo_ready_i, never re-armed
//     by a data_req that stays high after the grant (HPDCACHE_CMO_REISSUE);
//   - no data_rvalid before both rsp and cmo_done_i (HPDCACHE_CMO_EARLY_RVALID),
//     works in both arrival orders;
//   - exactly one data_rvalid once released (HPDCACHE_CMO_RVALID);
//   - a flush_i while a CMO is held must not be mistaken for completion
//     (flush_ack waits for the CMO release — HPDCACHE_CMO_FLUSH_MIXUP);
//   - a cbo.zero drain beat is a plain STORE but with need_rsp=1 (the store
//     buffer waits one data_rvalid per beat and HPDCACHE only responds to
//     stores when need_rsp is set — HPDCACHE_CMO_CBZ_NEEDRSP), never reaches
//     the sideband (HPDCACHE_CMO_CBZ_SIDEBAND), and its tid='0 response
//     forwards as data_rvalid (HPDCACHE_CMO_CBZ_RVALID).
//
// PASS token: HPDCACHE_CMO_PASS

module tb_g6lc_hpdcache_cmo;
  import ariane_pkg::*;

  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.IS_XLEN64=1;c.XLEN_ALIGN_BYTES=3;
    c.DCACHE_LINE_WIDTH=128;c.DCACHE_USER_LINE_WIDTH=2;c.DCACHE_USER_WIDTH=1;
    c.DCACHE_INDEX_WIDTH=8;c.DCACHE_OFFSET_WIDTH=4;c.DCACHE_TAG_WIDTH=44;
    c.DCACHE_SET_ASSOC=2;c.DCACHE_SET_ASSOC_WIDTH=1;c.DCACHE_NUM_WORDS=16;
    c.DCACHE_MAX_TX=4;c.MEM_TID_WIDTH=2;
    c.DcacheIdWidth=1;
    c.AxiDataWidth=64;c.AxiAddrWidth=64;c.AxiIdWidth=4;c.AxiUserWidth=1;
    c.NrCores=1;c.NrLoadBufEntries=4;
    c.WtDcacheWbufDepth=8;
    c.RVZiCbom=1;c.RVZiCboz=1;
    c.L2CmoEn=1;
    c.DCacheType=config_pkg::HPDCACHE_WT;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t CVA6Cfg=cfg();

  function automatic hpdcache_pkg::hpdcache_user_cfg_t hpdc_cfg();
    hpdcache_pkg::hpdcache_user_cfg_t u;
    u.nRequesters=4;
    u.paWidth=CVA6Cfg.PLEN;
    u.wordWidth=CVA6Cfg.XLEN;
    u.sets=CVA6Cfg.DCACHE_NUM_WORDS;
    u.ways=CVA6Cfg.DCACHE_SET_ASSOC;
    u.clWords=CVA6Cfg.DCACHE_LINE_WIDTH/u.wordWidth;
    u.reqWords=1;
    u.reqTransIdWidth=CVA6Cfg.DcacheIdWidth;
    u.reqSrcIdWidth=3;
    u.victimSel=hpdcache_pkg::HPDCACHE_VICTIM_RANDOM;
    u.dataWaysPerRamWord=1;
    u.dataSetsPerRam=CVA6Cfg.DCACHE_NUM_WORDS;
    u.dataRamByteEnable=1'b1;
    u.accessWords=1;
    u.mshrSets=1;
    u.mshrWays=CVA6Cfg.NrLoadBufEntries;
    u.mshrWaysPerRamWord=CVA6Cfg.NrLoadBufEntries;
    u.mshrSetsPerRam=1;
    u.mshrRamByteEnable=1'b1;
    u.mshrUseRegbank=1'b1;
    u.cbufEntries=CVA6Cfg.WtDcacheWbufDepth;
    u.refillCoreRspFeedthrough=1'b1;
    u.refillFifoDepth=2*(CVA6Cfg.DCACHE_LINE_WIDTH/CVA6Cfg.AxiDataWidth);
    u.wbufDirEntries=CVA6Cfg.WtDcacheWbufDepth;
    u.wbufDataEntries=CVA6Cfg.WtDcacheWbufDepth;
    u.wbufWords=1;
    u.wbufTimecntWidth=3;
    u.rtabEntries=4;
    u.flushEntries=CVA6Cfg.WtDcacheWbufDepth;
    u.flushFifoDepth=CVA6Cfg.WtDcacheWbufDepth;
    u.memAddrWidth=CVA6Cfg.AxiAddrWidth;
    u.memIdWidth=CVA6Cfg.MEM_TID_WIDTH;
    u.memDataWidth=CVA6Cfg.AxiDataWidth;
    u.wtEn=1'b1;
    u.wbEn=1'b0;
    u.lowLatency=1'b1;
    u.eccEn=1'b0;
    u.eccScrubberEn=1'b0;
    return u;
  endfunction
  localparam hpdcache_pkg::hpdcache_cfg_t HPDcacheCfg =
      hpdcache_pkg::hpdcacheBuildConfig(hpdc_cfg());

  `include "hpdcache_typedef.svh"
  `HPDCACHE_TYPEDEF_REQ_ATTR_T(hpdcache_req_offset_t, hpdcache_data_word_t,
                               hpdcache_data_be_t, hpdcache_req_data_t,
                               hpdcache_req_be_t, hpdcache_req_sid_t,
                               hpdcache_req_tid_t, hpdcache_tag_t, HPDcacheCfg);
  `HPDCACHE_TYPEDEF_REQ_T(hpdcache_req_t, hpdcache_req_offset_t,
                          hpdcache_req_data_t, hpdcache_req_be_t,
                          hpdcache_req_sid_t, hpdcache_req_tid_t,
                          hpdcache_tag_t);
  `HPDCACHE_TYPEDEF_RSP_T(hpdcache_rsp_t, hpdcache_req_data_t,
                          hpdcache_req_sid_t, hpdcache_req_tid_t);

  typedef struct packed {
    logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [CVA6Cfg.XLEN-1:0]               data_wdata;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                                  data_req;
    logic                                  data_we;
    logic [(CVA6Cfg.XLEN/8)-1:0]           data_be;
    logic [1:0]                            data_size;
    logic [CVA6Cfg.DcacheIdWidth-1:0]      data_id;
    logic                                  kill_req;
    logic                                  tag_valid;
    logic [7:0]                            cbo_op;
  } dcache_req_i_t;
  typedef struct packed {
    logic                                 data_gnt;
    logic                                 data_rvalid;
    logic [CVA6Cfg.DcacheIdWidth-1:0]     data_rid;
    logic [CVA6Cfg.XLEN-1:0]              data_rdata;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] data_ruser;
  } dcache_req_o_t;

  logic clk=0,rst_n=0;
  hpdcache_req_sid_t sid='0;
  dcache_req_i_t core_req='0;
  dcache_req_o_t core_rsp;
  amo_req_t amo_req='0;
  amo_resp_t amo_rsp;
  logic flush_i=0, flush_ack;
  logic hp_req_v, hp_req_rdy=1'b1, hp_req_abort;
  hpdcache_req_t hp_req;
  hpdcache_tag_t hp_tag;
  hpdcache_pkg::hpdcache_pma_t hp_pma;
  logic hp_rsp_v=0;
  hpdcache_rsp_t hp_rsp='0;
  logic cmo_valid, cmo_ready=0, cmo_done=0;
  logic [1:0] cmo_op;
  logic [CVA6Cfg.PLEN-1:0] cmo_addr;

  cva6_hpdcache_if_adapter #(
      .CVA6Cfg(CVA6Cfg),
      .HPDcacheCfg(HPDcacheCfg),
      .hpdcache_tag_t(hpdcache_tag_t),
      .hpdcache_req_offset_t(hpdcache_req_offset_t),
      .hpdcache_req_sid_t(hpdcache_req_sid_t),
      .hpdcache_req_t(hpdcache_req_t),
      .hpdcache_rsp_t(hpdcache_rsp_t),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .InvalidateOnFlush(1'b0),
      .IsLoadPort(1'b0)
  ) dut (
      .clk_i(clk),.rst_ni(rst_n),
      .hpdcache_req_sid_i(sid),
      .cva6_req_i(core_req),.cva6_req_o(core_rsp),
      .cva6_amo_req_i(amo_req),.cva6_amo_resp_o(amo_rsp),
      .cva6_dcache_flush_i(flush_i),.cva6_dcache_flush_ack_o(flush_ack),
      .hpdcache_req_valid_o(hp_req_v),.hpdcache_req_ready_i(hp_req_rdy),
      .hpdcache_req_o(hp_req),.hpdcache_req_abort_o(hp_req_abort),
      .hpdcache_req_tag_o(hp_tag),.hpdcache_req_pma_o(hp_pma),
      .hpdcache_rsp_valid_i(hp_rsp_v),.hpdcache_rsp_i(hp_rsp),
      .cmo_valid_o(cmo_valid),.cmo_op_o(cmo_op),.cmo_addr_o(cmo_addr),
      .cmo_ready_i(cmo_ready),.cmo_done_i(cmo_done)
  );

  int cycle=0;
  int rvalid_count=0, cmo_issue_count=0, hp_cmo_count=0;
  int rsp_while_pend=0;
  bit negative;
  int neg_kind=0;
  // Set once the sideband request for the in-flight CMO was granted; any
  // data_rvalid before cmo_done_i has also arrived is the defect.
  bit cmo_out=0, cmo_done_seen=0;

  task automatic tick;
    begin
      #2 clk=1;
      #2 clk=0;
      #2 cycle++;
    end
  endtask

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rvalid_count<=0; cmo_issue_count<=0; hp_cmo_count<=0;
      cmo_out<=0; cmo_done_seen<=0; rsp_while_pend<=0;
    end else begin
      if (core_rsp.data_rvalid) rvalid_count<=rvalid_count+1;
      if (cmo_valid && cmo_ready) begin
        cmo_issue_count<=cmo_issue_count+1;
        cmo_out<=1;
        cmo_done_seen<=0;
      end
      if (cmo_done) cmo_done_seen<=1;
      if (hp_rsp_v && hp_rsp.tid=='0 && cmo_out && !cmo_done_seen)
        rsp_while_pend<=rsp_while_pend+1;
      // A swallowed CMO rsp must never leak an early rvalid.  The release
      // is combinational on cmo_done_i, so rvalid is legal in the same
      // cycle that asserts done — !cmo_done covers that case.
      if (core_rsp.data_rvalid && cmo_out && !cmo_done_seen && !cmo_done)
        $fatal(1,"HPDCACHE_CMO_EARLY_RVALID cycle=%0d",cycle);
      // rvalids are exactly-once per issued CMO — the released pulse is the
      // only legal one for a CMO on this port.
      if (cmo_valid && cmo_ready && cmo_out)
        $fatal(1,"HPDCACHE_CMO_REISSUE cycle=%0d",cycle);
    end
  end

  // Request driver: raise the store-port request; the bench may keep
  // data_req high after the grant (held-request check).
  task automatic cbo_req(input logic [55:0] paddr, input logic [7:0] cbo,
                         input bit hold);
    int n;
    begin
      core_req<='0;
      core_req.data_req<=1'b1;
      core_req.data_we<=1'b1;
      core_req.data_wdata<='0;
      core_req.data_be<=8'h1;
      core_req.data_size<=2'd0;
      core_req.address_index<=paddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
      core_req.address_tag<=paddr[55:CVA6Cfg.DCACHE_INDEX_WIDTH];
      core_req.tag_valid<=1'b1;
      core_req.cbo_op<=cbo;
      n=0;
      do begin tick(); n++; end while(!core_rsp.data_gnt && n<2000);
      if(!hold)core_req.data_req<=1'b0;
    end
  endtask

  task automatic cmo_handshake(input logic [1:0] want_op,
                               input logic [55:0] want_addr,
                               input bit rsp_first);
    int n;
    begin
      cmo_out=0;cmo_done_seen=0;
      n=0;
      while(!cmo_valid && n<2000) begin tick(); n++; end
      if(!cmo_valid)$fatal(1,"HPDCACHE_CMO_NO_ISSUE op=%0d",want_op);
      if(cmo_op!=want_op)$fatal(1,"HPDCACHE_CMO_MAP op=%0d want=%0d",cmo_op,want_op);
      if(cmo_addr!=want_addr)
        $fatal(1,"HPDCACHE_CMO_ADDR %h want=%h",cmo_addr,want_addr);
      // sideband accept
      cmo_ready=1;
      tick();
      cmo_ready=0;
      if(cmo_valid)$fatal(1,"HPDCACHE_CMO_REISSUE");
      if(rsp_first) begin
        // rsp before done: must be swallowed, no rvalid
        hp_rsp<='0;
        hp_rsp.tid<='0;
        hp_rsp_v<=1;
        tick();
        hp_rsp_v<=0;
        repeat(4)tick();
        if(core_rsp.data_rvalid)$fatal(1,"HPDCACHE_CMO_EARLY_RVALID");
        repeat(3)tick();
        if(rvalid_count!=cmo_issue_count-1)
          $fatal(1,"HPDCACHE_CMO_RSP_LEAK rvalids=%0d issued=%0d",
                 rvalid_count,cmo_issue_count);
        cmo_done=1;
        tick();
        cmo_done=0;
      end else begin
        // done before rsp: rvalid must wait for the hpdcache rsp too
        cmo_done=1;
        tick();
        cmo_done=0;
        repeat(4)tick();
        if(rvalid_count!=cmo_issue_count-1)$fatal(1,"HPDCACHE_CMO_DONE_LEAK");
        hp_rsp<='0;
        hp_rsp.tid<='0;
        hp_rsp_v<=1;
        tick();
        hp_rsp_v<=0;
      end
      // exactly one rvalid once both are in
      repeat(6)tick();
      if(rvalid_count!=cmo_issue_count)
        $fatal(1,"HPDCACHE_CMO_RVALID rvalids=%0d issued=%0d",
               rvalid_count,cmo_issue_count);
    end
  endtask

  initial begin
    negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("neg_kind=%d",neg_kind));
    repeat(4)tick();rst_n=1;repeat(4)tick();

    // ---- sc0: cbo.inval, rsp-first ordering --------------------------------
    cbo_req(56'h2000,8'(ariane_pkg::CBO_INVAL),1'b1);
    cmo_handshake(2'd0,56'h2000,1'b1);
    core_req.data_req<=0;
    tick();

    // ---- sc1: cbo.clean held request, done-first ordering ------------------
    cbo_req(56'h2040,8'(ariane_pkg::CBO_CLEAN),1'b1);
    cmo_handshake(2'd1,56'h2040,1'b0);
    core_req.data_req<=0;
    tick();

    // ---- sc2: cbo.flush ----------------------------------------------------
    cbo_req(56'h2080,8'(ariane_pkg::CBO_FLUSH),1'b0);
    cmo_handshake(2'd2,56'h2080,1'b1);

    // ---- sc3: flush while a CMO is held is not a completion ----------------
    cbo_req(56'h20c0,8'(ariane_pkg::CBO_INVAL),1'b0);
    begin
      int n=0;
      cmo_out=0;cmo_done_seen=0;
      while(!cmo_valid && n<2000) begin tick(); n++; end
      if(!cmo_valid)$fatal(1,"HPDCACHE_CMO_NO_ISSUE");
      cmo_ready=1;tick();cmo_ready=0;
      // hold the rsp out, take a flush edge, then swallow the rsp late
      flush_i=1;
      tick();
      hp_rsp<='0;hp_rsp.tid<='0;hp_rsp_v<=1;
      tick();
      hp_rsp_v<=0;flush_i=0;
      repeat(4)tick();
      if(core_rsp.data_rvalid)$fatal(1,"HPDCACHE_CMO_FLUSH_MIXUP");
      cmo_done=1;tick();cmo_done=0;
      repeat(6)tick();
      if(rvalid_count!=cmo_issue_count)
        $fatal(1,"HPDCACHE_CMO_FLUSH_MIXUP rvalids=%0d",rvalid_count);
    end

    // ---- sc4: cbo.zero drain beat — STORE + need_rsp, off the sideband ----
    cbo_req(56'h2100,8'(ariane_pkg::CBO_ZERO),1'b1);
    begin
      int n=0, rv0=rvalid_count;
      // the request has been granted already (cbo_req waits for data_gnt);
      // inspect the forwarded request fields on the hpdcache port
      while(!hp_req_v && n<2000) begin tick(); n++; end
      if(hp_req.op!=hpdcache_pkg::HPDCACHE_REQ_STORE)
        $fatal(1,"HPDCACHE_CMO_CBZ_MAP op=%0d",hp_req.op);
      if(!hp_req.need_rsp)$fatal(1,"HPDCACHE_CMO_CBZ_NEEDRSP");
      // a cbo.zero beat is a local write — it must never touch the sideband
      repeat(8) begin
        tick();
        if(cmo_valid)$fatal(1,"HPDCACHE_CMO_CBZ_SIDEBAND cycle=%0d",cycle);
      end
      // inject the tid='0 store response; it must reach the LSU as rvalid
      hp_rsp<='0;hp_rsp.tid<='0;hp_rsp_v<=1;
      tick();
      hp_rsp_v<=0;
      repeat(6)tick();
      if(rvalid_count!=rv0+1)$fatal(1,"HPDCACHE_CMO_CBZ_RVALID");
      core_req.data_req<=0;
      tick();
    end

    if(negative)$fatal(1,"HPDCACHE_CMO_NEG_UNEXPECTEDLY_COMPLETE neg=%0d",neg_kind);
    $display("HPDCACHE_CMO_PASS rvalids=%0d issued=%0d pend_rsp=%0d",
             rvalid_count,cmo_issue_count,rsp_while_pend);
    $finish;
  end

  always_ff @(posedge clk)
    if(cycle>50000)$fatal(1,"HPDCACHE_CMO_TIMEOUT cycle=%0d",cycle);

endmodule
