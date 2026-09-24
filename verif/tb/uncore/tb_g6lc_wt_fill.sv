// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_wt_fill;
  import ariane_pkg::*;
  import wt_cache_pkg::*;
  parameter bit COH=1;
  parameter int NCORES=1;
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.IS_XLEN64=1;c.XLEN_ALIGN_BYTES=3;
    c.DCACHE_LINE_WIDTH=128;c.DCACHE_USER_LINE_WIDTH=2;c.DCACHE_USER_WIDTH=1;
    c.DCACHE_INDEX_WIDTH=8;c.DCACHE_OFFSET_WIDTH=4;c.DCACHE_TAG_WIDTH=48;
    c.DCACHE_SET_ASSOC=2;c.DCACHE_SET_ASSOC_WIDTH=1;c.DCACHE_NUM_WORDS=16;
    c.DCACHE_MAX_TX=4;c.MEM_TID_WIDTH=2;
    c.AxiDataWidth=64;c.AxiAddrWidth=64;c.AxiIdWidth=4;c.AxiUserWidth=1;
    c.NrCores=NCORES;
    c.CohPolicy=COH ? config_pkg::COH_OOO : config_pkg::COH_WRITE_INVAL;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t CVA6Cfg=cfg();
  `include "wt-types.svh"
  logic clk=0,rst_n=0,flush=0,enabled,mem_req,mem_ack=0,rvalid=0;
  logic [1:0] miss_req='0,miss_ack,returned,ways,valid_bits;
  logic [1:0][55:0] addresses='0;
  logic [3:0] index,offset;
  logic [127:0] returned_data;
  logic [15:0] data_be;
  logic line_valid;
  dcache_req_t request;
  dcache_rtrn_t response='0;
  bit negative,track_flush=0;
  logic [15:0] flush_seen='0;
  int scenario;
  wt_dcache_missunit #(.CVA6Cfg(CVA6Cfg),.DCACHE_CL_IDX_WIDTH(4),
      .dcache_req_t(dcache_req_t),.dcache_rtrn_t(dcache_rtrn_t),.NumPorts(2)) dut (
      .clk_i(clk),.rst_ni(rst_n),.enable_i(1'b1),.flush_i(flush),.flush_ack_o(),.miss_o(),
      .wbuffer_empty_i(1'b1),.cache_en_o(enabled),.amo_req_i('0),.amo_resp_o(),.mbe_i(1'b0),
      .miss_req_i(miss_req),.miss_ack_o(miss_ack),.miss_nc_i('0),.miss_we_i('0),
      .miss_wdata_i('0),.miss_wuser_i('0),.miss_paddr_i(addresses),.miss_vld_bits_i('0),
      .miss_size_i({3'd7,3'd7}),.miss_id_i({2'd0,2'd2}),.miss_replay_o(),
      .miss_rtrn_vld_o(returned),.miss_rtrn_id_o(),.tx_paddr_i('0),.tx_vld_i('0),
      .wr_cl_vld_o(line_valid),.wr_cl_nc_o(),.wr_cl_we_o(ways),.wr_cl_tag_o(),
      .wr_cl_idx_o(index),.wr_cl_off_o(offset),.wr_cl_data_o(returned_data),.wr_cl_user_o(),
      .wr_cl_data_be_o(data_be),.wr_vld_bits_o(valid_bits),
      .mem_rtrn_vld_i(rvalid),.mem_rtrn_i(response),.mem_data_req_o(mem_req),
      .mem_data_ack_i(mem_ack),.mem_data_o(request)
  );
  task automatic tick;
    #2;
    if(track_flush && line_valid && ways!=0 && valid_bits==0)flush_seen[index]=1;
    clk=1;#2;clk=0;#2;
  endtask
  task automatic invalidate(input logic [7:0] addr);
    rvalid=1;response='0;response.rtype=DCACHE_INV_REQ;response.inv.all=1;response.inv.idx=addr;
  endtask
  task automatic start_fill(input bit collision=0);
    addresses[0]=56'h4008;miss_req=1;mem_ack=1;
    if(collision)invalidate(8'h00);
    #1;
    if(!mem_req || !miss_ack[0] || request.paddr!=56'h4000 || request.tid!=2)
      $fatal(1,"WT_FILL_ADMIT");
    tick();miss_req=0;mem_ack=0;rvalid=0;
  endtask
  task automatic complete_fill(input bit install);
    response='0;response.rtype=DCACHE_LOAD_ACK;response.tid=2;
    response.data=128'h10203040506070808877665544332211;rvalid=1;#1;
    if(!returned[0] || !line_valid || offset!=8 || returned_data!=response.data)
      $fatal(1,"WT_FILL_RESPONSE");
    if(((|valid_bits) ^ negative)!=install || (install && (ways==0 || data_be!='1)) ||
       (!install && (ways!=0 || data_be!=0)))$fatal(1,"WT_FILL_INSTALL");
    tick();rvalid=0;repeat(2)tick();
  endtask
  initial begin
    negative=$test$plusargs("oracle_negative");
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    tick();rst_n=1;repeat(20)tick();
    if(!enabled)$fatal(1,"WT_FILL_ENABLE");
    if(scenario==4 || scenario==5)begin
      track_flush=1;flush=1;tick();flush=0;
      if(scenario==5)begin
        for(int n=0;n<20 && index!=4'hf;n++)tick();
        if(index!=4'hf)$fatal(1,"WT_FLUSH_LAST_SETUP");
      end
      invalidate(scenario==4 ? 8'hf0 : 8'h00);#1;
      if(index!=(scenario==4 ? 4'hf : 4'h0) || valid_bits!=0)$fatal(1,"WT_INVAL_FLUSH_COLLISION");
      tick();rvalid=0;repeat(20)tick();track_flush=0;
      if(flush_seen!='1)$fatal(1,"WT_FLUSH_COVER seen=%h",flush_seen);
      start_fill();complete_fill(1);
    end else begin
      start_fill(scenario==3);
      if(scenario==1 || scenario==2)begin
        invalidate(scenario==1 ? 8'h00 : 8'h10);#1;
        // Same-cycle application: the missunit's write port must already
        // reflect the invalidation combinatorially before the edge.
        if (!((line_valid && valid_bits==0 && ways=='1 &&
               index==(scenario==1 ? 4'h0 : 4'h1)) ^ negative))
          $fatal(1,"WT_INVAL_APPLY_SAME_CYCLE");
        tick();rvalid=0;
      end
      repeat(3)tick();
      complete_fill(!((COH || NCORES>1) && (scenario==1 || scenario==3)));
      start_fill();complete_fill(1);
    end
    $display("WT_FILL_PASS scenario=%0d coh=%0d",scenario,COH);$finish;
  end
endmodule
