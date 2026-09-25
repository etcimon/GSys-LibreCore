// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_wt_amo_apply;
  import ariane_pkg::*;
  import wt_cache_pkg::*;
  // Real g6lc64_ooo_int2 envelope: COH_OOO WT, RVA=1, Zacas=1. The
  // gen_inval_apply register stage only exists under COH_OOO.
  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  `include "wt-types.svh"
  typedef logic [63:0] addr_t;
  typedef logic [CVA6Cfg.PLEN-1:0] paddr_t;
  localparam type icache_req_t = struct packed {
    logic [CVA6Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] way;
    logic [CVA6Cfg.PLEN-1:0] paddr;
    logic nc;
    logic [CVA6Cfg.MEM_TID_WIDTH-1:0] tid;
  };
  localparam type icache_rtrn_t = struct packed {
    wt_cache_pkg::icache_in_t rtype;
    logic [CVA6Cfg.ICACHE_LINE_WIDTH-1:0] data;
    logic [CVA6Cfg.ICACHE_USER_LINE_WIDTH-1:0] user;
    struct packed {
      logic vld;
      logic all;
      logic [CVA6Cfg.ICACHE_INDEX_WIDTH-1:0] idx;
      logic [CVA6Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] way;
    } inv;
    logic [CVA6Cfg.MEM_TID_WIDTH-1:0] tid;
  };
  localparam addr_t P=64'h8000_4000;
  localparam addr_t Q=64'h8000_8000;
  logic clk=0,rst_n=0;
  dcache_req_t dreq='0;
  logic dreq_vld=0,dreq_ack;
  dcache_rtrn_t drtrn;
  logic drtrn_vld;
  icache_req_t ireq='0;
  icache_rtrn_t irtrn;
  ariane_axi::req_t areq;
  ariane_axi::resp_t arsp;
  logic [63:0] inval_addr=Q;
  logic inval_valid,inval_ready,inval_apply_valid;
  logic [63:0] inval_apply_addr;
  bit negative;
  int scenario,cycle=0;
  int inv_count=0,apply_count=0,ack_seen=0;
  int inv_idx[8],inv_cycle[8];
  bit inv_all[8];
  longint unsigned apply_addr[8];
  int apply_cycle[8];
  bit pend_seen=0,ready_while_pend=0;

  wt_axi_adapter #(.CVA6Cfg(CVA6Cfg),
      .axi_req_t(ariane_axi::req_t),.axi_rsp_t(ariane_axi::resp_t),
      .dcache_req_t(dcache_req_t),.dcache_rtrn_t(dcache_rtrn_t),
      .dcache_inval_t(dcache_inval_t),.icache_req_t(icache_req_t),
      .icache_rtrn_t(icache_rtrn_t)) dut (
      .clk_i(clk),.rst_ni(rst_n),
      .icache_data_req_i(1'b0),.icache_data_ack_o(),.icache_data_i(ireq),
      .icache_rtrn_vld_o(),.icache_rtrn_o(irtrn),
      .dcache_data_req_i(dreq_vld),.dcache_data_ack_o(dreq_ack),
      .dcache_data_i(dreq),
      .dcache_rtrn_vld_o(drtrn_vld),.dcache_rtrn_o(drtrn),
      .axi_req_o(areq),.axi_resp_i(arsp),.mbe_i(1'b0),
      .inval_addr_i(inval_addr),.inval_valid_i(inval_valid),
      .inval_ready_o(inval_ready),.inval_apply_valid_o(inval_apply_valid),
      .inval_apply_addr_o(inval_apply_addr));

  // External invalidation asserted in the same cycle as the AMO grant
  // (invalidate pulse) for scenario 3, exercising the retained
  // self-invalidation path. invalidate does not depend on inval_valid_i, so
  // this tap cannot close a combinational loop.
  assign inval_valid=(scenario==3) && dut.invalidate;

  function automatic ariane_axi::data_t mem_word(input ariane_axi::addr_t a);
    return {a[31:0],~a[31:0]} ^ 64'h5a5a_a5a5_1234_9876;
  endfunction

  // DRAM model: AW+W accepted always; ATOP load (atop[5]) earns an R beat with
  // the AW id carrying old data, then a B; locked AR (AMO_LR) earns one EXOKAY
  // R beat. Small in-order queues; no interleaving needed for this bench.
  typedef struct packed {ariane_axi::id_t id; ariane_axi::data_t data;
    axi_pkg::resp_t resp;} rjob_t;
  typedef struct packed {ariane_axi::id_t id; axi_pkg::resp_t resp;} bjob_t;
  rjob_t rq[8];
  bjob_t bq[8];
  int rq_h=0,rq_n=0,bq_h=0,bq_n=0;
  always_comb begin
    arsp='0;
    arsp.aw_ready=1;arsp.w_ready=1;arsp.ar_ready=1;
    arsp.r_valid=rq_n>0;
    arsp.r='{id:rq[rq_h].id,data:rq[rq_h].data,resp:rq[rq_h].resp,last:1,user:0};
    arsp.b_valid=bq_n>0;
    arsp.b='{id:bq[bq_h].id,resp:bq[bq_h].resp,user:0};
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
      rq_h<=0;rq_n<=0;bq_h<=0;bq_n<=0;
    end else begin
      int rtail;
      rtail=rq_h+rq_n;
      if(areq.aw_valid && arsp.aw_ready)begin
        if(!areq.aw.id[0])$fatal(1,"WT_AMO_AW_ID id=%h",areq.aw.id);
        bq[(bq_h+bq_n)%8]<='{id:areq.aw.id,resp:axi_pkg::RESP_OKAY};
        bq_n<=bq_n+1;
        if(areq.aw.atop[axi_pkg::ATOP_R_RESP])begin
          rq[rtail%8]<='{id:areq.aw.id,data:mem_word(areq.aw.addr),
            resp:axi_pkg::RESP_OKAY};
          rtail=rtail+1;rq_n<=rq_n+1;
        end
      end
      if(areq.ar_valid && arsp.ar_ready)begin
        rq[rtail%8]<='{id:areq.ar.id,data:mem_word(areq.ar.addr),
          resp:areq.ar.lock ? axi_pkg::RESP_EXOKAY : axi_pkg::RESP_OKAY};
        rtail=rtail+1;rq_n<=rq_n+1;
      end
      if(arsp.r_valid && areq.r_ready)begin rq_h<=(rq_h+1)%8;rq_n<=rq_n-1;end
      if(arsp.b_valid && areq.b_ready)begin bq_h<=(bq_h+1)%8;bq_n<=bq_n-1;end
    end
  end

  always @(posedge clk) begin
    if(rst_n)begin
      cycle++;
      if(dut.self_inval_pend_q)begin
        pend_seen=1;
        if(inval_ready)ready_while_pend=1;
      end
      if(drtrn_vld && drtrn.rtype==DCACHE_INV_REQ && inv_count<8)begin
        inv_idx[inv_count]=int'(drtrn.inv.idx);
        inv_all[inv_count]=drtrn.inv.all;
        inv_cycle[inv_count]=cycle;
        inv_count++;
      end
      if(inval_apply_valid && apply_count<8)begin
        apply_addr[apply_count]=inval_apply_addr;
        apply_cycle[apply_count]=cycle;
        apply_count++;
      end
      if(drtrn_vld && drtrn.rtype==DCACHE_ATOMIC_ACK)ack_seen=1;
    end
  end

  task automatic tick;#2;clk=1;#2;clk=0;#2;endtask
  task automatic send_amo(input ariane_pkg::amo_t op);
    dreq='0;
    dreq.rtype=DCACHE_ATOMIC_REQ;dreq.amo_op=op;dreq.paddr=paddr_t'(P);
    dreq.size=3'b011;dreq.data=64'hdead_beef_c0ff_ee11;dreq.tid='0;
    dreq_vld=1;
    for(int n=0;n<200;n++)begin
      #1;
      if(dreq_ack)begin tick();dreq_vld=0;return;end
      tick();
    end
    $fatal(1,"WT_AMO_REQ_TIMEOUT");
  endtask

  initial begin
    negative=$test$plusargs("oracle_negative");
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    repeat(3)tick();rst_n=1;repeat(20)tick();
    case(scenario)
      0:send_amo(AMO_SWAP);
      1:send_amo(AMO_CAS1);
      2:send_amo(AMO_LR);
      3:send_amo(AMO_CAS1);
      default:$fatal(1,"WT_AMO_SCENARIO");
    endcase
    for(int n=0;n<64;n++)tick();
    // (a) the invalidation returns must exist: P for the AMO self-invalidate,
    // Q then P for the externally-displaced case. inv.all must be set.
    if(scenario==3)begin
      if(inv_count!=2)$fatal(1,"WT_AMO_INV_MISSING count=%0d",inv_count);
      if(!inv_all[0] || !inv_all[1])$fatal(1,"WT_AMO_INV_MISSING all");
      if(inv_idx[0]!=int'(Q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0]) ||
         inv_idx[1]!=int'(P[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0]))
        $fatal(1,"WT_AMO_ORDER inv0=%h inv1=%h",inv_idx[0],inv_idx[1]);
    end else begin
      if(inv_count!=1)$fatal(1,"WT_AMO_INV_MISSING count=%0d",inv_count);
      if(!inv_all[0])$fatal(1,"WT_AMO_INV_MISSING all");
      if(inv_idx[0]!=int'(P[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0]))
        $fatal(1,"WT_AMO_INV_MISSING idx=%h",inv_idx[0]);
    end
    // (b) the apply event tracks the return: in this RTL both are registered
    // from the same d emission, so apply lands the same cycle the return is
    // presented (a one-cycle skew is tolerated).
    if(scenario==3)begin
      if(apply_count!=2)$fatal(1,"WT_AMO_APPLY count=%0d",apply_count);
      if(apply_addr[0]!=Q || apply_addr[1]!=P)
        $fatal(1,"WT_AMO_ORDER a0=%h a1=%h",apply_addr[0],apply_addr[1]);
      if(!pend_seen || ready_while_pend)$fatal(1,"WT_AMO_ORDER pend=%0d rdy=%0d",
        pend_seen,ready_while_pend);
      if(apply_addr[1]!=(P^64'(negative)))
        $fatal(1,"WT_AMO_APPLY addr=%h",apply_addr[1]);
    end else begin
      if(apply_count!=1)$fatal(1,"WT_AMO_APPLY count=%0d",apply_count);
      if(apply_addr[0]!=(P^64'(negative)))
        $fatal(1,"WT_AMO_APPLY addr=%h",apply_addr[0]);
      if(apply_cycle[0]<inv_cycle[0] || apply_cycle[0]>inv_cycle[0]+1)
        $fatal(1,"WT_AMO_APPLY delta=%0d",apply_cycle[0]-inv_cycle[0]);
    end
    // (c) the atomic must eventually be acknowledged.
    if(!ack_seen)$fatal(1,"WT_AMO_ACK_MISSING");
    $display("WT_AMO_PASS scenario=%0d",scenario);
    $finish;
  end
endmodule
