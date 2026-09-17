// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_review_iq;
  import ariane_pkg::*;
  parameter int NP=2, DEPTH=8;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.NrIssuePorts=NP; c.NrWbPorts=2; c.NR_SB_ENTRIES=16; c.TRANS_ID_BITS=4;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {fu_t fu; logic [3:0] trans_id; logic [31:0] pc;} sbe_t;
  typedef struct packed {sbe_t s; logic [31:0] orig; logic [3:0] p1,p2,pd; bit r1,r2;} entry_t;
  entry_t reference_q[$];
  logic clk=0,rst_n=0,flush=0,mem_stall=0,full;
  logic [15:0] cancel='0;
  logic [NP-1:0] dv='0,da,iv,ia='0,r1='0,r2='0;
  sbe_t [NP-1:0] ds,is;
  logic [NP-1:0][31:0] di,ii;
  logic [NP-1:0][3:0] p1,p2,pd,ip;
  logic [1:0] wv='0;
  logic [1:0][3:0] wp='0;
  bit negative;
  int scenario,checked=0;
  logic [31:0] random_q=32'h61ab293d;
  g6lc_iq #(.CVA6Cfg(C),.DEPTH(DEPTH),.PRF_W(4),.scoreboard_entry_t(sbe_t)) dut (
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.cancelled_mask_i(cancel),
    .disp_valid_i(dv),.disp_sbe_i(ds),.disp_orig_i(di),.disp_prs1_i(p1),.disp_prs2_i(p2),.disp_prd_i(pd),
    .disp_rs1_ready_i(r1),.disp_rs2_ready_i(r2),.disp_ack_o(da),.full_o(full),.wb_valid_i(wv),.wb_prd_i(wp),
    .issue_sbe_o(is),.issue_orig_o(ii),.issue_prd_o(ip),.issue_valid_o(iv),.issue_ack_i(ia),.mem_stall_i(mem_stall));
  task automatic tick;
    clk=1; #2; clk=0; #2;
  endtask
  task automatic clear_inputs;
    flush=0;mem_stall=0;cancel='0;dv='0;ds='0;di='0;p1='0;p2='0;pd='0;r1='0;r2='0;wv='0;wp='0;
  endtask
  task automatic reset;
    rst_n=0;ia='0;clear_inputs();reference_q.delete();#2;tick();rst_n=1;#2;
  endtask
  task automatic step;
    entry_t keep[$];
    entry_t e;
    logic [NP-1:0] expected_valid,expected_ack;
    int port;
    keep.delete();
    #2;
    if (full !== (reference_q.size()+NP>DEPTH)) $fatal(1,"IQ_CREDIT count=%0d",reference_q.size());
    expected_valid='0;expected_ack='0;port=0;
    if (!flush) begin
      for (int n=0;n<reference_q.size();n++) begin
        bit remove_entry;
        e=reference_q[n];remove_entry=0;
        if (!cancel[e.s.trans_id]) begin
          for (int w=0;w<2;w++) if (wv[w] && wp[w]!=0) begin
            if (e.p1==wp[w]) e.r1=1;
            if (e.p2==wp[w]) e.r2=1;
          end
          if (port<NP && e.r1 && e.r2 && !(mem_stall && (e.s.fu==LOAD || e.s.fu==STORE))) begin
            expected_valid[port]=1;
            if (!iv[port] || is[port]!==e.s || (ii[port] ^ (negative?32'd1:32'd0))!==e.orig || ip[port]!==e.pd)
              $fatal(1,"IQ_ISSUE port=%0d expected_tid=%0d observed_tid=%0d",port,e.s.trans_id,is[port].trans_id);
            if (ia[port]) begin remove_entry=1;port++;end
            else port=NP;
          end
          if (!remove_entry) keep.push_back(e);
        end
      end
      if (iv!==expected_valid) $fatal(1,"IQ_VALID got=%b expected=%b",iv,expected_valid);
      for (int p=0;p<NP;p++) if (dv[p] && keep.size()<DEPTH) begin
        expected_ack[p]=1;
        e='{s:ds[p],orig:di[p],p1:p1[p],p2:p2[p],pd:pd[p],r1:r1[p],r2:r2[p]};
        for (int w=0;w<2;w++) if (wv[w] && wp[w]!=0) begin
          if (e.p1==wp[w]) e.r1=1;
          if (e.p2==wp[w]) e.r2=1;
        end
        keep.push_back(e);
      end
    end
    if (da!==expected_ack) $fatal(1,"IQ_DISPATCH got=%b expected=%b rtl_count=%0d ref_count=%0d",da,expected_ack,dut.count_q,reference_q.size());
    reference_q=keep;checked++;tick();
  endtask
  task automatic offer(input int port, input int id, input fu_t fu,
                       input int src, input int dst, input bit ready);
    dv[port]=1;ds[port]='{fu:fu,trans_id:4'(id),pc:32'h1000+32'(id)*4};
    di[port]=32'h13000000+32'(id);p1[port]=4'(src);p2[port]=0;pd[port]=4'(dst);r1[port]=ready;r2[port]=1;
  endtask
  initial begin
    negative=$test$plusargs("oracle_negative");scenario=0;void'($value$plusargs("scenario=%d",scenario));
    reset();
    case(scenario)
      0:begin offer(0,1,ALU,0,3,1);step();clear_inputs();ia='1;step();end
      1:begin
        offer(0,1,LOAD,0,3,1);step();clear_inputs();offer(0,2,ALU,3,4,0);step();
        clear_inputs();ia='1;repeat(6)step();wv=1;wp[0]=3;step();
      end
      2:begin offer(0,2,ALU,5,6,0);wv=1;wp[0]=5;step();clear_inputs();ia='1;step();end
      3:begin
        for(int n=0;n<DEPTH;n+=NP)begin clear_inputs();for(int p=0;p<NP;p++)if(n+p<DEPTH)offer(p,n+p,ALU,1,2,0);step();end
        clear_inputs();step();flush=1;step();
      end
      4:begin
        repeat(160)begin
          clear_inputs();random_q^=random_q<<13;random_q^=random_q>>17;random_q^=random_q<<5;
          ia=NP'(random_q);wv=2'(random_q>>8);wp[0]=4'(random_q>>12);wp[1]=4'(random_q>>16);
          cancel=16'(random_q>>16);mem_stall=random_q[5];flush=(random_q[7:3]==0);
          if(reference_q.size()+NP<=DEPTH)for(int p=0;p<NP;p++)if(random_q[p+2])offer(p,p+int'(random_q[7:4]),random_q[p]?ALU:LOAD,int'(random_q[11:8]),p+1,random_q[p+6]);
          step();
        end
        clear_inputs();flush=1;step();
      end
      default:$fatal(1,"IQ_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS iq scenario=%0d checked=%0d",scenario,checked);$finish;
  end
endmodule

module tb_g6lc_review_mshr;
  parameter int D=4,NW=2;
  localparam int IW=$clog2(D);
  logic clk=0,rst_n=0,flush=0,av=0,ready,merged,complete=0,pop=0,wvalid,empty,full,mfull,lhit;
  logic [31:0] line=0;
  logic [7:0] id=0,cid,wid;
  logic [IW-1:0] ai,ci=0,li;
  logic [IW:0] count;
  bit negative;int scenario;
  g6lc_l2_mshr #(.DEPTH(D),.ADDR_WIDTH(32),.ID_WIDTH(8),.MAX_WAITERS(NW)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.alloc_i(av),.alloc_line_addr_i(line),.alloc_id_i(id),.alloc_is_write_i(1'b0),
    .alloc_ready_o(ready),.alloc_merged_o(merged),.alloc_idx_o(ai),.lookup_line_addr_i(line),.lookup_hit_o(lhit),.lookup_idx_o(li),
    .complete_i(complete),.complete_idx_i(ci),.complete_id_o(cid),.waiter_valid_o(wvalid),.waiter_id_o(wid),.waiter_pop_i(pop),
    .empty_o(empty),.full_o(full),.merge_full_o(mfull),.count_o(count));
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  task automatic allocate(input int address,input int tag,input bit expect_ready,input bit expect_merge);
    line=32'(address);id=8'(tag);av=1;#2;
    if((ready ^ (negative?1'b1:1'b0))!==expect_ready || (expect_ready && merged!==expect_merge))$fatal(1,"MSHR_ADMISSION");
    tick();av=0;
  endtask
  task automatic waiter(input int expected);
    #2;if(!wvalid || wid!==8'(expected))$fatal(1,"MSHR_WAITER got=%0d expected=%0d",wid,expected);
  endtask
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");void'($value$plusargs("scenario=%d",scenario));
    #2;tick();rst_n=1;#2;allocate(256,1,1,0);ci=ai;
    case(scenario)
      0:begin complete=1;tick();complete=0;if(count!=0)$fatal(1,"MSHR_BASIC");end
      1:begin
        for(int n=0;n<NW;n++)allocate(256,n+2,1,1);
        if(count!=1 || !mfull)$fatal(1,"MSHR_SETUP");allocate(256,99,0,0);
        for(int n=0;n<NW;n++)begin waiter(n+2);pop=1;tick();pop=0;end
        complete=1;tick();complete=0;if(count!=0)$fatal(1,"MSHR_COUNT");
      end
      2:begin
        for(int n=0;n<NW;n++)allocate(256,n+2,1,1);
        waiter(2);pop=1;allocate(256,99,1,1);pop=0;
        for(int n=1;n<NW;n++)begin waiter(n+2);pop=1;tick();pop=0;end
        waiter(99);pop=1;complete=1;tick();pop=0;complete=0;if(count!=0)$fatal(1,"MSHR_COUNT");
      end
      3:begin
        complete=1;allocate(256,2,1,1);complete=0;
        if(count!=1 || empty)$fatal(1,"MSHR_RETENTION");waiter(2);
        pop=1;complete=1;tick();pop=0;complete=0;if(count!=0)$fatal(1,"MSHR_COUNT");
      end
      4:begin
        complete=1;allocate(512,3,1,0);complete=0;
        if(count!=1)$fatal(1,"MSHR_CONCURRENT_COUNT");ci=ai;#2;if(cid!=3)$fatal(1,"MSHR_ID");
        complete=1;tick();complete=0;if(count!=0)$fatal(1,"MSHR_COUNT");
      end
      default:$fatal(1,"MSHR_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS mshr scenario=%0d",scenario);$finish;
  end
endmodule

module tb_g6lc_review_dispatch;
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.NrHarts=1;c.NrCores=1;c.NrIssuePorts=2;c.NrCommitPorts=2;c.NrWbPorts=2;
    c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;c.PrfEntries=40;c.RobEntries=8;c.IqEntries=8;
    c.LsqLoadEntries=4;c.LsqStoreEntries=4;c.BPCkptDepth=2;c.OoOEn=1;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {fu_t fu;fu_op op;logic[4:0] rs1,rs2,rd;logic[3:0] trans_id;logic[63:0] pc,result;logic[7:0] p_rs1,p_rs2,p_rd;logic ooo_renamed;} sbe_t;
  logic clk=0,rst_n=0;
  logic[1:0] dv=0,da,iv;
  sbe_t[1:0] ds='0,issued;
  logic[1:0][31:0] orig;
  int scenario,seen;
  g6lc_ooo_dispatch #(.CVA6Cfg(C),.scoreboard_entry_t(sbe_t)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(1'b0),.flush_unissued_i(1'b0),.cancelled_mask_i('0),
    .dispatch_sbe_i(ds),.dispatch_orig_i('0),.dispatch_valid_i(dv),.dispatch_ack_o(da),
    .issue_sbe_o(issued),.issue_orig_o(orig),.issue_valid_o(iv),.issue_ack_i(2'b11),
    .issue_op_a_o(),.issue_op_b_o(),.issue_op_a_valid_o(),.issue_op_b_valid_o(),
    .wb_valid_i('0),.wb_id_i('0),.wb_data_i('0),.wb_exc_i('0),.commit_ack_i('0),.commit_instr_i('0),.mispredict_i(1'b0),
    .freelist_empty_o(),.rob_full_o(),.iq_full_o(),.lsq_stall_o(),.rename_stall_o(),.stl_forward_o());
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  initial begin
    scenario=0;seen=0;void'($value$plusargs("scenario=%d",scenario));#2;tick();rst_n=1;
    ds[0].fu=scenario==0?ALU:STORE;ds[0].op=scenario==0?ADD:SD;ds[0].pc=64'h1000;ds[0].trans_id=1;dv=1;
    #2;if(!da[0])$fatal(1,"DISPATCH_ADMISSION");tick();dv=0;
    repeat(8)begin #2;if(iv[0])begin if(issued[0].trans_id!=1)$fatal(1,"DISPATCH_ID");seen++;end tick();end
    if(seen!=1)$fatal(1,"DISPATCH_STORE_PROGRESS scenario=%0d issued=%0d",scenario,seen);
    $display("RTL_REVIEW_PASS dispatch scenario=%0d",scenario);$finish;
  end
endmodule

module tb_g6lc_review_decay;
  import ariane_pkg::*;
  parameter int SLOTS=2,RVC=1;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.VLEN=32;c.RVC=RVC;c.INSTR_PER_FETCH=SLOTS;c.DebugEn=1;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {logic valid;logic [31:0] pc;logic taken;} update_t;
  logic clk=0,rst_n=0,flush=0,debug_mode=0,hv,ht;
  update_t update='0;
  bht_prediction_t [SLOTS-1:0] prediction;
  bit negative;int updates=0,pulses=0;
  g6lc_bp_tage #(.CVA6Cfg(C),.bht_update_t(update_t),.NR_ENTRIES(16),.NR_TABLES(2),.TABLE_ENTRIES(8),.TAG_BITS(4),.GHIST_LEN(8)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_bp_i(flush),.debug_mode_i(debug_mode),.vpc_i(32'h1000),.ghist_i('0),.folded_i('0),
    .bht_update_i(update),.bht_prediction_o(prediction),.hist_update_valid_o(hv),.hist_update_taken_o(ht));
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  initial begin
    negative=$test$plusargs("oracle_negative");#2;tick();rst_n=1;
    for(int n=0;n<20000;n++)begin
      bit accepted,expected;
      update='{valid:(n%7!=0),pc:32'h1000,taken:n[0]};debug_mode=(n%23==0);flush=(n==5000 || n==14000);#2;
      accepted=update.valid && !debug_mode;
      if(hv!==accepted)$fatal(1,"TAGE_UPDATE_GATE");
      if(accepted)updates++;
      expected=accepted && updates%4096==0;
      tick();
      if((dut.decay_q ^ (negative && expected))!==expected)$fatal(1,"TAGE_DECAY updates=%0d expected=%0b observed=%0b",updates,expected,dut.decay_q);
      if(expected)pulses++;
    end
    if(pulses<3)$fatal(1,"TAGE_DECAY_COVER");
    $display("RTL_REVIEW_PASS decay updates=%0d pulses=%0d",updates,pulses);$finish;
  end
endmodule
