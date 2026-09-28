// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//
// Leaf testbench for the T9a WT CMO sideband in wt_dcache. A Zicbom store-port
// command (cbo_op in {INVAL, CLEAN, FLUSH}) must never reach the write buffer
// as a data write: it is granted, the buffer drains, the command issues once
// on cmo_*, and exactly one data_rvalid retires the store-buffer entry when
// cmo_done_i arrives. cbo.zero stays an ordinary store (the store unit
// expands it upstream) and gets its single rvalid from the tracker.
//
// Oracles:
//   - a CBO produces NO DCACHE_STORE_REQ on the mem port for its address
//     (mutation: forwarding it as a store is caught as a size-0 write →
//      WT_CMO_BYTE_WRITE);
//   - cmo_valid_o must wait for wbuffer_empty_o (drain ordering) —
//     WT_CMO_DRAIN_ORDER;
//   - exactly one data_rvalid per CBO after cmo_done_i — WT_CMO_RVALID;
//   - cmo_addr_o/cmo_op_o carry the line address / op — WT_CMO_PAYLOAD;
//   - cbo.zero drains as a store and still pulses rvalid once —
//     WT_CMO_ZERO_*;
//   - a normal store still reaches memory — WT_CMO_STORE_LOST.
//
// PASS token: WT_CMO_PASS

module tb_g6lc_wt_cmo;
  import ariane_pkg::*;
  import wt_cache_pkg::*;

  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.IS_XLEN64=1;c.XLEN_ALIGN_BYTES=3;
    c.DCACHE_LINE_WIDTH=128;c.DCACHE_USER_LINE_WIDTH=2;c.DCACHE_USER_WIDTH=1;
    c.DCACHE_INDEX_WIDTH=8;c.DCACHE_OFFSET_WIDTH=4;c.DCACHE_TAG_WIDTH=44;
    c.DCACHE_SET_ASSOC=2;c.DCACHE_SET_ASSOC_WIDTH=1;c.DCACHE_NUM_WORDS=16;
    c.DCACHE_MAX_TX=4;c.MEM_TID_WIDTH=2;
    c.DcacheIdWidth=1;
    c.AxiDataWidth=64;c.AxiAddrWidth=64;c.AxiIdWidth=4;c.AxiUserWidth=1;
    c.NrCores=1;
    c.RVZiCbom=1;c.RVZiCboz=1;
    c.WtDcacheWbufDepth=8;c.WtDcacheFixupDepth=1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t CVA6Cfg=cfg();
  `include "wt-types.svh"

  localparam int NumPorts=4;

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
  logic wbuf_empty, wbuf_nni;
  logic cmo_valid, cmo_ready=0, cmo_done=0;
  logic [1:0] cmo_op;
  logic [CVA6Cfg.PLEN-1:0] cmo_addr;
  amo_req_t amo_req='0;
  amo_resp_t amo_rsp;
  dcache_req_i_t [NumPorts-1:0] req_i='0;
  dcache_req_o_t [NumPorts-1:0] req_o;
  logic mem_rtrn_vld=0;
  dcache_rtrn_t mem_rtrn='0;
  logic mem_req;
  logic mem_ack=0;
  dcache_req_t mem_d;

  wt_dcache #(
      .CVA6Cfg(CVA6Cfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .dcache_req_t(dcache_req_t),
      .dcache_rtrn_t(dcache_rtrn_t),
      .NumPorts(NumPorts),
      .RdAmoTxId(1)
  ) dut (
      .clk_i(clk),.rst_ni(rst_n),
      .enable_i(1'b1),.flush_i(1'b0),.flush_ack_o(),.miss_o(),
      .wbuffer_empty_o(wbuf_empty),.wbuffer_not_ni_o(wbuf_nni),
      .cmo_valid_o(cmo_valid),.cmo_op_o(cmo_op),.cmo_addr_o(cmo_addr),
      .cmo_ready_i(cmo_ready),.cmo_done_i(cmo_done),
      .amo_req_i(amo_req),.amo_resp_o(amo_rsp),.mbe_i(1'b0),
      .req_ports_i(req_i),.req_ports_o(req_o),
      .miss_vld_bits_o(),
      .pm_void_ack_o(),.pm_fixup_write_o(),.pm_fixup_inval_o(),.pm_fixup_full_o(),
      .mem_rtrn_vld_i(mem_rtrn_vld),.mem_rtrn_i(mem_rtrn),
      .mem_data_req_o(mem_req),.mem_data_ack_i(mem_ack),.mem_data_o(mem_d)
  );

  int cycle=0;
  int rvalid_count=0;
  int mem_store_count=0;
  int cmo_issue_count=0;
  logic [55:0] cmo_addr_seen='0;
  logic [1:0]  cmo_op_seen='0;
  bit negative;

  task automatic tick;
    begin
      #2 clk=1;
      #2 clk=0;
      #2 cycle++;
    end
  endtask

  // Mem port model: a request is acked once, and the ACK'd response returns
  // one cycle later. The return MUST trail the handshake: the missunit's
  // stores_inflight count only registers the send at the ack edge, so a
  // same-cycle STORE_ACK would be dropped and the wbuffer entry never pops.
  logic       served_q = 1'b0;
  logic       pend_rtrn_q = 1'b0;
  logic [2:0] pend_rtype_q;
  logic [CVA6Cfg.MEM_TID_WIDTH-1:0] pend_tid_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mem_ack<=1'b0; mem_rtrn_vld<=1'b0; served_q<=1'b0; pend_rtrn_q<=1'b0;
    end else begin
      mem_ack<=1'b0; mem_rtrn_vld<=1'b0;
      if (mem_req && !mem_ack && !served_q) begin
        mem_ack<=1'b1;
        served_q<=1'b1;
        pend_rtrn_q<=1'b1;
        pend_rtype_q<=mem_d.rtype;
        pend_tid_q<=mem_d.tid;
      end
      if (!mem_req) served_q<=1'b0;
      if (pend_rtrn_q) begin
        pend_rtrn_q<=1'b0;
        mem_rtrn<='0;
        if (pend_rtype_q==DCACHE_STORE_REQ) begin
          mem_store_count<=mem_store_count+1;
          mem_rtrn.rtype<=DCACHE_STORE_ACK;
        end else begin
          mem_rtrn.rtype<=DCACHE_LOAD_ACK;
        end
        mem_rtrn.tid<=pend_tid_q;
        mem_rtrn_vld<=1'b1;
      end
    end
  end

  // Oracles on the DUT outputs.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rvalid_count<=0; cmo_issue_count<=0;
    end else begin
      if (req_o[NumPorts-1].data_rvalid) rvalid_count<=rvalid_count+1;
      if (cmo_valid && cmo_ready) begin
        cmo_issue_count<=cmo_issue_count+1;
        cmo_addr_seen<=cmo_addr;
        cmo_op_seen<=cmo_op;
      end
      // A CMO must never issue while the write buffer is non-empty.
      if (cmo_valid && !wbuf_empty)
        $fatal(1,"WT_CMO_DRAIN_ORDER cycle=%0d",cycle);
      // A CBO forwarded as a store shows up here as a one-byte zero write —
      // the pre-fix defect signature. No stimulus in this bench produces a
      // legit size-0 zero-data store, so this fires only under the mutation.
      if (mem_req && mem_ack && mem_d.rtype==DCACHE_STORE_REQ &&
          mem_d.size==3'd0 && mem_d.data==64'h0)
        $fatal(1,"WT_CMO_BYTE_WRITE paddr=%h cycle=%0d",mem_d.paddr,cycle);
    end
  end

  // Store-port driver: one request, granted, then the response watcher below
  // counts rvalids. The request is staged through drv_* and copied into req_i
  // by a clocked process: under Verilator --timing (5.020), writes to an
  // unpacked-array input port from a timing task never propagate into the
  // DUT, while a posedge write does.
  logic        drv_v = 1'b0;
  logic [55:0] drv_paddr;
  logic [63:0] drv_data;
  logic [7:0]  drv_be;
  logic [1:0]  drv_size;
  logic [7:0]  drv_cbo;

  always_ff @(posedge clk) begin
    if (drv_v) begin
      req_i[NumPorts-1]              <= '0;
      req_i[NumPorts-1].data_req     <= 1'b1;
      req_i[NumPorts-1].data_we      <= 1'b1;
      req_i[NumPorts-1].data_wdata   <= drv_data;
      req_i[NumPorts-1].data_be      <= drv_be;
      req_i[NumPorts-1].data_size    <= drv_size;
      // The physical tag rides in address_tag from the first cycle; the
      // wbuffer asserts tag_valid is never raised on this port.
      req_i[NumPorts-1].address_index <= drv_paddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
      req_i[NumPorts-1].address_tag  <=
          CVA6Cfg.DCACHE_TAG_WIDTH'(drv_paddr >> CVA6Cfg.DCACHE_INDEX_WIDTH);
      req_i[NumPorts-1].tag_valid    <= 1'b0;
      req_i[NumPorts-1].cbo_op       <= drv_cbo;
    end else begin
      req_i[NumPorts-1].data_req <= 1'b0;
      req_i[NumPorts-1].data_we  <= 1'b0;
    end
  end

  task automatic store_req(input logic [55:0] paddr, input logic [63:0] data,
                           input logic [7:0] be, input logic [1:0] size,
                           input logic [7:0] cbo);
    int n;
    begin
      drv_paddr = paddr;
      drv_data  = data;
      drv_be    = be;
      drv_size  = size;
      drv_cbo   = cbo;
      drv_v     = 1'b1;
      for (n = 0; n < 20000 && !req_o[NumPorts-1].data_gnt; n++) tick();
      if (!req_o[NumPorts-1].data_gnt)
        $fatal(1, "WT_CMO_NO_GNT paddr=%h cbo=%h", paddr, cbo);
      drv_v = 1'b0;
      tick();
    end
  endtask

  // Handshake the CMO sideband: accept, hold off done for `hold` cycles,
  // pulse it once.
  task automatic run_cmo(input logic [1:0] want_op, input logic [55:0] want_addr,
                         input int hold, input int prev_rvalid);
    int n;
    begin
      n=0;
      while(!cmo_valid && n<5000) begin tick(); n++; end
      if(!cmo_valid)$fatal(1,"WT_CMO_NO_ISSUE op=%0d",want_op);
      if(cmo_op!=want_op)$fatal(1,"WT_CMO_PAYLOAD op=%0d want=%0d",cmo_op,want_op);
      if(cmo_addr!=want_addr)$fatal(1,"WT_CMO_PAYLOAD addr=%h want=%h",cmo_addr,want_addr);
      cmo_ready=1;
      tick();
      cmo_ready=0;
      repeat(hold)tick();
      cmo_done=1;
      tick();
      cmo_done=0;
      // rvalid lands the cycle after done; bound the observation window.
      repeat(4)tick();
      if(rvalid_count!=prev_rvalid+1)
        $fatal(1,"WT_CMO_RVALID count=%0d want=%0d",rvalid_count,prev_rvalid+1);
      // No second rvalid for the same CBO.
      repeat(6)tick();
      if(rvalid_count!=prev_rvalid+1)
        $fatal(1,"WT_CMO_RVALID count=%0d want=%0d",rvalid_count,prev_rvalid+1);
    end
  endtask

  initial begin
    negative=$test$plusargs("oracle_negative");
    repeat(4)tick();rst_n=1;repeat(4)tick();
    if(!wbuf_empty)begin
      // drain any reset stragglers
      repeat(20)tick();
    end

    // ---- sc0: cbo.inval never reaches the wbuffer; one rvalid -------------
    store_req(56'h4000,64'h0,8'h1,2'd0,ariane_pkg::CBO_INVAL);
    run_cmo(2'd0,56'h4000,3,rvalid_count);

    // ---- sc1: cbo.clean / cbo.flush ---------------------------------------
    store_req(56'h4040,64'h0,8'h1,2'd0,ariane_pkg::CBO_CLEAN);
    run_cmo(2'd1,56'h4040,2,rvalid_count);
    store_req(56'h4080,64'h0,8'h1,2'd0,ariane_pkg::CBO_FLUSH);
    run_cmo(2'd2,56'h4080,2,rvalid_count);

    // ---- sc2: drain ordering — a pending store blocks issue ---------------
    // Stall the mem port so the store stays in the buffer.
    mem_ack<=1'b0;
    store_req(56'h4100,64'hdead_beef,8'hff,2'd3,8'(ariane_pkg::CBO_NONE));
    // The store may still be draining; issue the CBO behind it.
    store_req(56'h4180,64'h0,8'h1,2'd0,ariane_pkg::CBO_INVAL);
    // While the wbuffer is non-empty no cmo_valid may rise (checked in the
    // always block above); just wait for the drain then run the handshake.
    run_cmo(2'd0,56'h4180,2,rvalid_count);
    if(mem_store_count<1)$fatal(1,"WT_CMO_STORE_LOST");

    // ---- sc3: cbo.zero is an ordinary store + one rvalid ------------------
    begin
      int rv=rvalid_count, st=mem_store_count;
      store_req(56'h4200,64'h0,8'hff,2'd3,ariane_pkg::CBO_ZERO);
      repeat(30)tick();
      if(rvalid_count!=rv+1)$fatal(1,"WT_CMO_ZERO_RVALID %0d",rvalid_count);
      if(mem_store_count<st+1)$fatal(1,"WT_CMO_ZERO_NOSTORE");
      // 4 CMOs so far (sc0 inval, sc1 clean+flush, sc2 inval) — cbo.zero
      // must NOT add another.
      if(cmo_issue_count!=4)$fatal(1,"WT_CMO_ZERO_ISSUED");
    end

    // ---- sc4: back-to-back CBOs serialize through the tracker -------------
    store_req(56'h4300,64'h0,8'h1,2'd0,ariane_pkg::CBO_INVAL);
    run_cmo(2'd0,56'h4300,1,rvalid_count);
    store_req(56'h4340,64'h0,8'h1,2'd0,ariane_pkg::CBO_INVAL);
    run_cmo(2'd0,56'h4340,1,rvalid_count);
    if(cmo_issue_count!=6)$fatal(1,"WT_CMO_ISSUE_COUNT %0d",cmo_issue_count);

    $display("WT_CMO_PASS rvalids=%0d cmo_issued=%0d mem_stores=%0d",
             rvalid_count,cmo_issue_count,mem_store_count);
    $finish;
  end

  // Watchdog — a hung CBO (pre-fix behaviour) expires here.
  always_ff @(posedge clk)
    if(cycle>50000)$fatal(1,"WT_CMO_TIMEOUT cycle=%0d",cycle);

endmodule
