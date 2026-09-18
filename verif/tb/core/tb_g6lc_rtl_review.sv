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
    .issue_sbe_o(is),.issue_orig_o(ii),.issue_prd_o(ip),.issue_valid_o(iv),.issue_ack_i(ia),.mem_stall_i(mem_stall),
    .st_live_mask_i('0),.commit_ptr_i('0));
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
    .merge_block_i('0),.alloc_meta_i('0),
    .alloc_ready_o(ready),.alloc_merged_o(merged),.alloc_idx_o(ai),.lookup_line_addr_i(line),.lookup_hit_o(lhit),.lookup_idx_o(li),.id_match_o(),
    .complete_i(complete),.complete_idx_i(ci),.complete_id_o(cid),.waiter_valid_o(wvalid),.waiter_id_o(wid),.waiter_meta_o(),.waiter_pop_i(pop),
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

// Rename recovery contracts. g6lc_rename is package-free, so it is driven
// directly and every check reads only its ports: prs1_o reveals the map,
// rs1_ready_o reveals the busy table, and which register an allocation picks
// reveals the free list. No hierarchical probes.
module tb_g6lc_review_rename;
  parameter int unsigned PRF_ENTRIES=40,PRF_W=6,NR_PORTS=2,NR_FREE=2,NR_WB=2,CKPT_DEPTH=2;
  logic clk=0,rst_n=0,flush=0,mispredict=0,enable=1;
  logic [NR_PORTS-1:0] valid='0,need_rd='0,is_branch='0;
  logic [NR_PORTS-1:0][4:0] rs1='0,rs2='0,rd='0;
  logic [NR_PORTS-1:0][PRF_W-1:0] prs1,prs2,prd,prd_old;
  logic [NR_PORTS-1:0] rs1_rdy,rs2_rdy;
  logic stall;
  logic [NR_WB-1:0] wb_v='0;
  logic [NR_WB-1:0][PRF_W-1:0] wb_prd='0;
  logic [NR_FREE-1:0] fr='0;
  logic [NR_FREE-1:0] ckpt_ret='0;
  logic [NR_FREE-1:0][PRF_W-1:0] fr_prd='0;
  int scenario;bit negative;
  logic [PRF_W-1:0] first_alloc,mid_alloc;
  logic [$clog2(CKPT_DEPTH+1)-1:0] mis_level='1;
  logic [NR_PORTS-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_id;
  g6lc_rename #(.PRF_ENTRIES(PRF_ENTRIES),.PRF_W(PRF_W),.NR_PORTS(NR_PORTS),
                .NR_FREE(NR_FREE),.NR_WB(NR_WB),.CKPT_DEPTH(CKPT_DEPTH)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.mispredict_i(mispredict),
    .mispredict_level_i(mis_level),
    .valid_i(valid),.rs1_i(rs1),.rs2_i(rs2),.rd_i(rd),.need_rd_i(need_rd),
    .is_branch_i(is_branch),.prs1_o(prs1),.prs2_o(prs2),.prd_o(prd),
    .prd_old_o(prd_old),.rs1_ready_o(rs1_rdy),.rs2_ready_o(rs2_rdy),
    .ckpt_id_o(ckpt_id),.ckpt_retire_i(ckpt_ret),.stall_o(stall),
    .wb_valid_i(wb_v),.wb_prd_i(wb_prd),.free_i(fr),.free_prd_i(fr_prd),.enable_i(enable));
  always #5 clk=~clk;
  task automatic drive; @(negedge clk); endtask
  task automatic presample; #4; endtask
  task automatic idle; valid='0;need_rd='0;is_branch='0;wb_v='0;fr='0;ckpt_ret='0;mispredict=0; endtask
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(2) drive();
    rst_n=1;
    drive();flush=1;
    drive();flush=0;idle();
    case(scenario)
      // Basic: an allocation must change the mapping and mark it busy.
      0:begin
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd1;
        presample();first_alloc=prd[0];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();rs1[0]=5'd1;valid=2'b01;
        presample();
        if(prs1[0]!==(negative?PRF_W'(0):first_alloc))
          $fatal(1,"RENAME_MAP got=%0d want=%0d",prs1[0],first_alloc);
        if(rs1_rdy[0]!==1'b0)$fatal(1,"RENAME_BUSY rdy=%b",rs1_rdy[0]);
      end
      // Recovery must retain renames OLDER than the mispredicting branch. The
      // checkpoint saves pre-group state, so a port-0 rename in the same group
      // as a port-1 branch is discarded on mispredict.
      1:begin
        drive();valid=2'b11;need_rd=2'b01;rd[0]=5'd1;is_branch=2'b10;
        presample();first_alloc=prd[0];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();
        drive();mispredict=1;
        drive();idle();rs1[0]=5'd1;valid=2'b01;
        presample();
        if(prs1[0]!==(negative?PRF_W'(0):first_alloc))
          $fatal(1,"RENAME_OLDER_LOST got=%0d want=%0d",prs1[0],first_alloc);
      end
      // Recovery must not resurrect a busy bit whose writeback already happened:
      // the producer will never write back again, so the consumer waits forever.
      2:begin
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd1;
        presample();first_alloc=prd[0];
        drive();idle();valid=2'b01;is_branch=2'b01;
        drive();idle();
        drive();wb_v[0]=1'b1;wb_prd[0]=first_alloc;
        drive();idle();
        drive();mispredict=1;
        drive();idle();rs1[0]=5'd1;valid=2'b01;
        presample();
        if(rs1_rdy[0]!==(negative?1'b0:1'b1))
          $fatal(1,"RENAME_BUSY_RESURRECT rdy=%b prs1=%0d",rs1_rdy[0],prs1[0]);
      end
      // An OLDER branch resolving must unwind to ITS checkpoint: work between the
      // two branches is younger than the resolver and must be discarded, and the
      // intervening checkpoint must not be left behind.
      3:begin
        drive();valid=2'b01;is_branch=2'b01;              // branch A -> ckpt 0
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd1;
        presample();mid_alloc=prd[0];                     // allocated after A
        if(mid_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();valid=2'b01;is_branch=2'b01;       // branch B -> ckpt 1
        drive();idle();
        drive();mispredict=1;mis_level=negative?'1:'0;    // branch A resolves
        drive();idle();mis_level='1;rs1[0]=5'd1;valid=2'b01;
        presample();
        // r1 must be back to its architectural mapping, not the post-A rename.
        if(prs1[0]===mid_alloc)
          $fatal(1,"RENAME_STALE_LEVEL prs1=%0d still the squashed rename",prs1[0]);
        // and the squashed register must have returned to the free list.
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd2;
        presample();
        if(prd[0]!==mid_alloc)
          $fatal(1,"RENAME_LEVEL_LEAK got=%0d want=%0d",prd[0],mid_alloc);
      end
      // Two-branch group: each branch must consume its OWN checkpoint level.
      // Unwinding to the OLDER level must also consume the younger one's slot:
      // the next branch's ckpt_id reveals the surviving ckpt_ptr.
      4:begin
        drive();valid=2'b11;is_branch=2'b11;
        presample();
        if(stall)$fatal(1,"RENAME_CKPT_STALL");
        if(ckpt_id[0]!==2'd0||ckpt_id[1]!==2'd1)
          $fatal(1,"RENAME_CKPT_TAG id0=%0d id1=%0d",ckpt_id[0],ckpt_id[1]);
        drive();idle();
        // Older branch resolves: unwind to level 0, consuming ckpt 1 as well.
        drive();mispredict=1;mis_level=negative?2'd1:2'd0;
        drive();idle();mis_level='1;
        drive();valid=2'b01;is_branch=2'b01;
        presample();
        if(ckpt_id[0]!==2'd0)
          $fatal(1,"RENAME_CKPT2_UNWIND id=%0d want=0",ckpt_id[0]);
      end
      // Checkpoint capacity: CKPT_DEPTH=2, so a third branch group must stall
      // rather than dispatch a branch that could never be unwound.
      5:begin
        drive();valid=2'b01;is_branch=2'b01;
        drive();idle();valid=2'b01;is_branch=2'b01;
        drive();idle();valid=2'b01;is_branch=2'b01;
        presample();
        if(stall!==(negative?1'b0:1'b1))
          $fatal(1,"RENAME_CKPT_FULL stall=%b",stall);
      end
      // Exclusivity probe: free_i landing on a still-busy register while a
      // mispredict restores an older checkpoint must not leave the reg both
      // free and busy. (Formal frame-3 cex hypothesis check.)
      6:begin
        drive();valid=2'b11;need_rd=2'b10;rd[1]=5'd1;is_branch=2'b01;
        presample();first_alloc=prd[1];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();
        drive();mispredict=1;fr[0]=1'b1;fr_prd[0]=first_alloc;
        drive();idle();mispredict=0;fr='0;
        drive();idle();
        if((dut.free_q[first_alloc]&&dut.busy_q[first_alloc])!==(negative?1'b1:1'b0))
          $fatal(1,"RENAME_EXCLUSIVE free=%b busy=%b",dut.free_q[first_alloc],dut.busy_q[first_alloc]);
      end
      // A committed branch's checkpoint must return to the pool: without that
      // the pool only drains on mispredict and dispatch stalls forever after
      // CKPT_DEPTH correctly predicted branches.
      7:begin
        drive();valid=2'b01;is_branch=2'b01;              // branch A -> slot 0
        drive();idle();valid=2'b01;is_branch=2'b01;       // branch B -> slot 1
        drive();idle();ckpt_ret[0]=1'b1;                  // A commits
        drive();idle();valid=2'b01;is_branch=2'b01;       // branch C
        presample();
        if(stall!==(negative?1'b1:1'b0))
          $fatal(1,"RENAME_CKPT_NO_RELEASE stall=%b",stall);
        if(ckpt_id[0]!==2'd0)
          $fatal(1,"RENAME_CKPT_REUSE id=%0d want=0",ckpt_id[0]);
      end
      // Retirement must not disturb recovery: renames older than the resolving
      // branch survive, and the freed slot is not resurrected.
      8:begin
        drive();valid=2'b01;is_branch=2'b01;              // branch A -> slot 0
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd1;
        presample();mid_alloc=prd[0];                     // allocated after A
        if(mid_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();valid=2'b01;is_branch=2'b01;       // branch B -> slot 1
        drive();idle();ckpt_ret[0]=1'b1;                  // A commits
        drive();idle();
        drive();mispredict=1;mis_level=2'd1;              // B resolves
        drive();idle();mis_level='1;
        drive();valid=2'b01;is_branch=2'b01;
        presample();
        // Head has advanced past A, so the next branch takes B's slot again.
        if(ckpt_id[0]!==(negative?2'd0:2'd1))
          $fatal(1,"RENAME_RETIRE_WINDOW id=%0d",ckpt_id[0]);
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd2;
        presample();
        // The post-A rename is older than B and must not have been squashed.
        if(prd[0]===mid_alloc)
          $fatal(1,"RENAME_RETIRE_SQUASH got=%0d",prd[0]);
      end
      default:$fatal(1,"RENAME_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS rename scenario=%0d",scenario);$finish;
  end
endmodule

// Bisect fixture: drives g6lc_lsq directly with an explicit allocation id, so a
// failure here isolates the LSQ itself rather than the dispatch id plumbing.
module tb_g6lc_review_lsq;
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;c.NrWbPorts=2;
    c.NrCommitPorts=2;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  logic clk=0,rst_n=0;
  logic [1:0] ld_alloc='0,st_alloc='0,addr_v='0,addr_is_st='0,st_data_v='0,cmpl_v='0,cmpl_st='0;
  logic [1:0][3:0] alloc_id='0,addr_id='0,st_data_id='0,cmpl_id='0;
  logic [1:0][55:0] addr='0;
  logic [1:0][1:0] addr_size='0;
  logic [1:0][63:0] st_data='0;
  logic [1:0] commit_st='0;
  logic [1:0][3:0] commit_id='0;
  logic ld_query=0;
  logic [55:0] ld_addr='0;
  logic [1:0] ld_size=2'b11;
  logic [3:0] ld_id='0,commit_ptr='0;
  logic flush='0;
  logic [15:0] cancel_mask='0;
  logic pend,fwd,stall,busy,ldf,stf;
  logic [2:0] ldfree,stfree;
  logic [15:0] st_mask;
  logic [63:0] fwd_data;
  int scenario;bit negative;
  g6lc_lsq #(.CVA6Cfg(C),.LD_ENTRIES(4),.ST_ENTRIES(4),.NR_ALLOC(2),.NR_UPDATE(2)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.cancelled_mask_i(cancel_mask),
    .ld_alloc_i(ld_alloc),.st_alloc_i(st_alloc),.alloc_id_i(alloc_id),
    .ld_full_o(ldf),.st_full_o(stf),.ld_free_o(ldfree),.st_free_o(stfree),
    .addr_valid_i(addr_v),.addr_id_i(addr_id),.addr_i(addr),
    .addr_is_st_i(addr_is_st),.addr_size_i(addr_size),
    .st_data_valid_i(st_data_v),.st_data_id_i(st_data_id),.st_data_i(st_data),
    .complete_valid_i(cmpl_v),.complete_id_i(cmpl_id),.complete_is_st_i(cmpl_st),
    .commit_st_i(commit_st),.commit_id_i(commit_id),.commit_ptr_i(commit_ptr),
    .ld_query_i(ld_query),.ld_query_addr_i(ld_addr),.ld_query_size_i(ld_size),
    .ld_query_id_i(ld_id),
    .st_live_mask_o(st_mask),.store_pending_o(pend),.stl_forward_o(fwd),
    .stl_data_o(fwd_data),.stl_stall_o(stall),.lsq_busy_o(busy));
  // Same clocking discipline as the dispatch fixture: free-running clock, drive
  // on the falling edge, sample after the rising edge settles.
  always #5 clk = ~clk;
  task automatic drive; @(negedge clk); endtask
  task automatic presample; #4; endtask
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(3) drive();
    rst_n=1;
    drive();
    case(scenario)
      // A store's completion, matched by its own id, must retire its entry.
      0:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        presample();
        if(!pend)$fatal(1,"LSQ_ALLOC pend=%b",pend);
        if(st_mask!==16'h0002)$fatal(1,"LSQ_LIVE_MASK got=%h want=0002",st_mask);
        drive();cmpl_v=2'b01;cmpl_st=2'b01;cmpl_id[0]=4'd1;
        drive();cmpl_v='0;cmpl_st='0;cmpl_id='0;
        presample();
        if(pend!==(negative?1'b1:1'b0))$fatal(1,"LSQ_WB_RETIRE pend=%b",pend);
        if(st_mask!=='0)$fatal(1,"LSQ_MASK_CLEAR got=%h",st_mask);
      end
      // Address then data, both matched by id, must enable forwarding.
      1:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd1;addr[0]=56'h2000;addr_size[0]=2'b11;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b01;st_data_id[0]=4'd1;st_data[0]=64'hdeadbeef;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2000;ld_id=4'd2;
        presample();
        if(!fwd||stall)$fatal(1,"LSQ_STL_FORWARD fwd=%b stall=%b",fwd,stall);
        if(fwd_data!==(negative?64'd0:64'hdeadbeef))$fatal(1,"LSQ_STL_DATA got=%h",fwd_data);
        ld_query=0;
      end
      // Retiring a completed store must not release a different store's entry.
      // Store 1 completes by id, then store 1 commits; store 2 is still pending
      // and unresolved, so an older store must remain visible to load ordering.
      2:begin
        st_alloc=2'b11;alloc_id[0]=4'd1;alloc_id[1]=4'd2;
        drive();st_alloc='0;alloc_id='0;
        presample();
        if(!pend)$fatal(1,"LSQ_ALLOC pend=%b",pend);
        drive();cmpl_v=2'b01;cmpl_st=2'b01;cmpl_id[0]=4'd1;
        drive();cmpl_v='0;cmpl_st='0;cmpl_id='0;
        commit_st=2'b01;commit_id[0]=4'd1;
        drive();commit_st='0;commit_id='0;
        presample();
        if(pend!==(negative?1'b0:1'b1))
          $fatal(1,"LSQ_COMMIT_DOUBLE_FREE pend=%b",pend);
      end
      // Age-aware forward: the OLDER matching store (tid 1) supplies the load
      // (tid 2); the YOUNGER matching store (tid 3) must be ignored even though
      // it sits at the higher slot index the old scan preferred.
      3:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        st_alloc=2'b01;alloc_id[0]=4'd3;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b11;addr_is_st=2'b11;
        addr_id[0]=4'd1;addr[0]=56'h2000;addr_size[0]=2'b11;
        addr_id[1]=4'd3;addr[1]=56'h2000;addr_size[1]=2'b11;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b11;st_data_id[0]=4'd1;st_data[0]=64'hAAAA;
        st_data_id[1]=4'd3;st_data[1]=64'hBBBB;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2000;ld_id=4'd2;
        presample();
        if(stall||!fwd)$fatal(1,"LSQ_AGE_FWD fwd=%b stall=%b",fwd,stall);
        if(fwd_data!==(negative?64'hBBBB:64'hAAAA))$fatal(1,"LSQ_STL_AGE got=%h",fwd_data);
        ld_query=0;
      end
      // An unresolved OLDER store stalls the load even when a resolved YOUNGER
      // store matches; the younger store must neither forward nor suppress it.
      4:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        st_alloc=2'b01;alloc_id[0]=4'd3;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd3;addr[0]=56'h2000;addr_size[0]=2'b11;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b01;st_data_id[0]=4'd3;st_data[0]=64'hBBBB;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2000;ld_id=4'd2;
        presample();
        if(stall!==(negative?1'b0:1'b1)||fwd)
          $fatal(1,"LSQ_AGE_STALL fwd=%b stall=%b",fwd,stall);
        ld_query=0;
      end
      // Wraparound: with commit_ptr=14 a store at tid 15 (dist 1) is OLDER than
      // a load at tid 0 (dist 2); a naive "s < l" compare would get it wrong.
      5:begin
        commit_ptr=4'd14;
        st_alloc=2'b01;alloc_id[0]=4'd15;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd15;addr[0]=56'h2000;addr_size[0]=2'b11;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b01;st_data_id[0]=4'd15;st_data[0]=64'hCCCC;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2000;ld_id=4'd0;
        presample();
        if(stall||!fwd)$fatal(1,"LSQ_WRAP_FWD fwd=%b stall=%b",fwd,stall);
        if(fwd_data!==(negative?64'd0:64'hCCCC))$fatal(1,"LSQ_WRAP_DATA got=%h",fwd_data);
        ld_query=0;commit_ptr=0;
      end
      // Byte-exact overlap: SB at 0x2000 (lane 0) vs LH at 0x2002 (lanes 2-3)
      // share the word but no bytes -- neither stall nor forward. The old
      // group match would have forwarded the byte store as a full word.
      6:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd1;addr[0]=56'h2000;addr_size[0]=2'b00;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b01;st_data_id[0]=4'd1;st_data[0]=64'hAA;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2002;ld_size=2'b01;ld_id=4'd2;
        presample();
        if((fwd||stall)!==(negative?1'b1:1'b0))
          $fatal(1,"LSQ_BYTE_DISJOINT fwd=%b stall=%b",fwd,stall);
        ld_query=0;ld_size=2'b11;
      end
      // Containment: SD at 0x2000 covers LB at 0x2003 (lane 3) -- forward flag
      // marks a fully-covered load (the store_buffer's st_fwd_covers rule).
      7:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd1;addr[0]=56'h2000;addr_size[0]=2'b11;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b01;st_data_id[0]=4'd1;st_data[0]=64'hDD;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2003;ld_size=2'b00;ld_id=4'd2;
        presample();
        if(fwd!==(negative?1'b0:1'b1)||stall)
          $fatal(1,"LSQ_BYTE_COVER fwd=%b stall=%b",fwd,stall);
        ld_query=0;ld_size=2'b11;
      end
      // Partial overlap without store data stalls: SW at 0x2002 (lanes 2-5)
      // shares lanes with LW at 0x2000 (lanes 0-3) but covers only half.
      8:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd1;addr[0]=56'h2002;addr_size[0]=2'b10;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        ld_query=1;ld_addr=56'h2000;ld_size=2'b10;ld_id=4'd2;
        presample();
        if(stall!==(negative?1'b0:1'b1)||fwd)
          $fatal(1,"LSQ_PARTIAL_NODATA fwd=%b stall=%b",fwd,stall);
        ld_query=0;ld_size=2'b11;
      end
      // Partial overlap WITH data is no full forward and no stall -- the
      // store_buffer byte-merge supplies the covered lanes downstream.
      9:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd1;addr[0]=56'h2002;addr_size[0]=2'b10;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b01;st_data_id[0]=4'd1;st_data[0]=64'h77;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2000;ld_size=2'b10;ld_id=4'd2;
        presample();
        if(fwd!==(negative?1'b1:1'b0)||stall)
          $fatal(1,"LSQ_PARTIAL_MERGE fwd=%b stall=%b",fwd,stall);
        ld_query=0;ld_size=2'b11;
      end
      // Cancel drops the entry by tid: the store never lands in the LSU buffer
      // and must stop shadowing younger loads.
      10:begin
        st_alloc=2'b01;alloc_id[0]=4'd5;
        drive();st_alloc='0;alloc_id='0;
        presample();
        if(!pend)$fatal(1,"LSQ_CANCEL_PRE pend=%b",pend);
        cancel_mask=16'h0020;
        drive();cancel_mask='0;
        presample();
        if(pend!==(negative?1'b1:1'b0))
          $fatal(1,"LSQ_CANCEL_DROP pend=%b",pend);
        if(st_mask!=='0)$fatal(1,"LSQ_CANCEL_MASK got=%h",st_mask);
      end
      // Full flush clears both queues: fence/trap handoff leaves no live
      // entries behind.
      11:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        ld_alloc=2'b01;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;
        presample();
        if(!pend||!busy)$fatal(1,"LSQ_FLUSH_PRE pend=%b busy=%b",pend,busy);
        flush=1;
        drive();flush=0;
        presample();
        if(pend!==(negative?1'b1:1'b0)||busy)
          $fatal(1,"LSQ_FLUSH pend=%b busy=%b",pend,busy);
      end
      default:$fatal(1,"LSQ_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS lsq scenario=%0d",scenario);$finish;
  end
endmodule

module tb_g6lc_review_dispatch;
  import ariane_pkg::*;
  // MemDepPredEn has never been elaborated: with it enabled the predictor's
  // stall is a combinational function of the IQ's own issue outputs while also
  // gating IQ selection.
  parameter bit MDP=1'b0;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.NrHarts=1;c.NrCores=1;c.NrIssuePorts=2;c.NrCommitPorts=2;c.NrWbPorts=2;
    c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;c.PrfEntries=40;c.RobEntries=8;c.IqEntries=8;
    c.LsqLoadEntries=4;c.LsqStoreEntries=4;c.BPCkptDepth=2;c.OoOEn=1;
    c.MemDepPredEn=MDP;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {fu_t fu;fu_op op;logic[4:0] rs1,rs2,rd;logic[3:0] trans_id;logic[63:0] pc,result;logic[7:0] p_rs1,p_rs2,p_rd;logic ooo_renamed;} sbe_t;
  logic clk=0,rst_n=0;
  logic[1:0] dv=0,da,iv;
  sbe_t[1:0] ds='0,issued;
  logic[1:0][31:0] orig;
  int scenario,seen,seen_st,seen_ld;
  logic [7:0] p9a='0,p9b='0;
  bit negative;
  logic [1:0] wb_v='0,cm_ack='0;
  logic [1:0][3:0] wb_id='0;
  sbe_t [1:0] cm_instr='0;
  logic [3:0] cp='0,mis_id='0;
  logic mispredict=0;
  g6lc_ooo_dispatch #(.CVA6Cfg(C),.scoreboard_entry_t(sbe_t)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(1'b0),.flush_unissued_i(1'b0),.cancelled_mask_i('0),
    .dispatch_sbe_i(ds),.dispatch_orig_i('0),.dispatch_valid_i(dv),.dispatch_ack_o(da),
    .issue_sbe_o(issued),.issue_orig_o(orig),.issue_valid_o(iv),.issue_ack_i(2'b11),
    .issue_op_a_o(),.issue_op_b_o(),.issue_op_a_valid_o(),.issue_op_b_valid_o(),
    .wb_valid_i(wb_v),.wb_id_i(wb_id),.wb_data_i('0),.wb_exc_i('0),
    .commit_ack_i(cm_ack),.commit_instr_i(cm_instr),.commit_ptr_i(cp),
    .mispredict_i(mispredict),.mispredict_id_i(mis_id),
    .freelist_empty_o(),.rob_full_o(),.iq_full_o(),.lsq_stall_o(),.rename_stall_o(),.stl_forward_o());
  // Free-running clock. The clock must NOT be driven from the stimulus process:
  // the previous hand-rolled `tick` (clk=1;#2;clk=0;#2) made results depend on
  // the simulator's optimisation level, which destroyed the fixture's value as
  // evidence. Stimulus is applied on the falling edge and sampled after the
  // rising edge has settled, so no check races a clock edge.
  always #5 clk = ~clk;
  // drive():     apply stimulus at the falling edge, start of a cycle.
  // presample(): observe combinational handshakes just before the rising edge,
  //              i.e. in the same cycle they are asserted. Sampling after the
  //              edge would miss issue_valid_o, which the edge itself consumes.
  task automatic drive; @(negedge clk); endtask
  task automatic presample; #4; endtask

  initial if($test$plusargs("vcd")) begin
    $dumpfile("dispatch.vcd");
    $dumpvars(0,tb_g6lc_review_dispatch);
  end
  initial begin
    scenario=0;seen=0;seen_st=0;seen_ld=0;
    negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(3) drive();
    rst_n=1;
    drive();
    case(scenario)
      0,1:begin
        ds[0].fu=scenario==0?ALU:STORE;ds[0].op=scenario==0?ADD:SD;ds[0].pc=64'h1000;ds[0].trans_id=1;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        repeat(8)begin
          presample();
          if(iv[0])begin
            if(issued[0].trans_id!=(negative?4'd2:4'd1))$fatal(1,"DISPATCH_ID");
            seen++;
          end
          drive();
        end
        if(seen!=1)$fatal(1,"DISPATCH_STORE_PROGRESS scenario=%0d issued=%0d",scenario,seen);
      end
      // Two stores: neither may block the other out of issue.
      2:begin
        ds[0].fu=STORE;ds[0].op=SD;ds[0].pc=64'h1000;ds[0].trans_id=1;
        ds[1].fu=STORE;ds[1].op=SD;ds[1].pc=64'h1004;ds[1].trans_id=2;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p])begin
            if(issued[p].trans_id==4'd1)seen_st++;
            if(issued[p].trans_id==4'd2)seen_ld++;
          end
          drive();
        end
        if(seen_st!=1||seen_ld!=(negative?2:1))$fatal(1,"DISPATCH_STORE_PAIR a=%0d b=%0d",seen_st,seen_ld);
      end
      // Ordering guard: the load must not issue while an older store address is
      // unresolved. No writeback is supplied, so the store never resolves.
      3:begin
        ds[0].fu=STORE;ds[0].op=SD;ds[0].pc=64'h1000;ds[0].trans_id=1;
        ds[1].fu=LOAD;ds[1].op=LD;ds[1].pc=64'h1004;ds[1].trans_id=2;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p])begin
            if(issued[p].trans_id==4'd1)seen_st++;
            if(issued[p].trans_id==4'd2)seen_ld++;
          end
          drive();
        end
        if(seen_st!=1)$fatal(1,"DISPATCH_STORE_PROGRESS scenario=3 issued=%0d",seen_st);
        if(seen_ld!=(negative?1:0))$fatal(1,"DISPATCH_LOAD_ORDER load_issued=%0d",seen_ld);
      end
      // Writeback of a store's own trans_id must retire its LSQ entry.
      6:begin
        ds[0].fu=STORE;ds[0].op=SD;ds[0].pc=64'h1000;ds[0].trans_id=1;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        repeat(3) drive();
        presample();
        if(!dut.store_pend)$fatal(1,"DISPATCH_STORE_ABSENT");
        drive();wb_v=2'b01;wb_id[0]=4'd1;
        presample();
        drive();wb_v='0;wb_id='0;
        presample();
        if(dut.store_pend!==(negative?1'b1:1'b0))
          $fatal(1,"DISPATCH_STORE_WB_RETIRE store_pend=%b",dut.store_pend);
      end
      // Age-aware gate: a load dispatched BEFORE a store is older than it, so
      // the pending store must not block the load's issue. Both dispatch in
      // the SAME group (load port 0 = older, store port 1 = younger) so the
      // store is already live in the LSQ at the load's first issue cycle --
      // dispatching the load alone first let it issue before the store
      // existed, which tests nothing.
      7:begin
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].pc=64'h1000;ds[0].trans_id=1;
        ds[1].fu=STORE;ds[1].op=SD;ds[1].pc=64'h1004;ds[1].trans_id=2;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==4'd1)seen_ld++;
          drive();
        end
        if(seen_ld!=(negative?0:1))$fatal(1,"DISPATCH_LOAD_UNBLOCKED ld=%0d",seen_ld);
      end
      // Wraparound: with cp=14 the store at tid 15 (dist 1) is OLDER than the
      // load at tid 0 (dist 2) and still blocks it; a naive compare would pass.
      8:begin
        cp=4'd14;
        ds[0].fu=STORE;ds[0].op=SD;ds[0].pc=64'h1000;ds[0].trans_id=15;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].pc=64'h1004;ds[0].trans_id=0;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION2");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==4'd0)seen_ld++;
          drive();
        end
        if(seen_ld!=(negative?1:0))$fatal(1,"DISPATCH_WRAP_ORDER ld=%0d",seen_ld);
      end
      // Branch-tag plumbing: the OLDER branch's resolve must unwind rename to
      // ITS checkpoint, not the youngest. Observable through top-level ports:
      // the physical register allocated between the two branches must return
      // to the free list, so the next allocation reissues it -- read back from
      // the issued sbe's p_rd.
      9:begin
        ds[0].fu=CTRL_FLOW;ds[0].op=BRANCH;ds[0].pc=64'h1000;ds[0].trans_id=1;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=5'd7;ds[0].trans_id=2;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION2");
        drive();dv=0;
        repeat(6)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==4'd2)p9a=issued[p].p_rd;
          drive();
        end
        if(p9a=='0)$fatal(1,"DISPATCH_TAG_ISSUE a=%0d",p9a);
        ds='0;ds[0].fu=CTRL_FLOW;ds[0].op=BRANCH;ds[0].pc=64'h1008;ds[0].trans_id=3;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION3");
        drive();dv=0;
        drive();mispredict=1;mis_id=negative?4'd3:4'd1;
        drive();mispredict=0;mis_id='0;
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=5'd9;ds[0].trans_id=4;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION4");
        drive();dv=0;
        repeat(6)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==4'd4)p9b=issued[p].p_rd;
          drive();
        end
        if(p9b!=p9a)$fatal(1,"DISPATCH_TAG_REUSE a=%0d b=%0d",p9a,p9b);
      end
      // Group credits: with one free load entry a two-load group cannot be
      // admitted. "Any entry free" would admit it and the LSQ would discard the
      // surplus allocation, leaving that load live with no queue entry.
      10:begin
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].pc=64'h1000;ds[0].trans_id=1;
        ds[1].fu=LOAD;ds[1].op=LD;ds[1].pc=64'h1008;ds[1].trans_id=2;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;
        ds='0;ds[0].fu=LOAD;ds[0].op=LD;ds[0].pc=64'h1010;ds[0].trans_id=3;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION2");
        drive();dv=0;
        ds='0;
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].pc=64'h1018;ds[0].trans_id=4;
        ds[1].fu=LOAD;ds[1].op=LD;ds[1].pc=64'h1020;ds[1].trans_id=5;dv=2'b11;
        presample();
        if((da[0]||da[1])!==(negative?1'b1:1'b0))
          $fatal(1,"DISPATCH_LSQ_CREDIT ack=%b free=%0d",da,dut.ld_free);
      end
      default:$fatal(1,"DISPATCH_SCENARIO");
    endcase
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
    .clk_i(clk),.rst_ni(rst_n),.flush_bp_i(flush),.debug_mode_i(debug_mode),.vpc_i(32'h1000),.ghist_i('0),.folded_i('0),.folded_update_i('0),
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

// Predictor context ownership. Pre-fix the TAGE shared one fetch-window base
// index and one tagged provider across all slots (an unaligned window's slot
// PCs were never hashed), broadcast a tagged hit to every slot, and trained
// tagged tables on the live fetch-hart fold rather than the resolving
// branch's bank. Geometry: RVC, IPF=2, base row=pc[4:2] col=pc[1],
// tagged idx=pc[3:1] tag=pc[7:4].
module tb_g6lc_review_tage;
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.VLEN=32;c.RVC=1;c.INSTR_PER_FETCH=2;c.DebugEn=1;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {logic valid;logic [31:0] pc;logic taken;} update_t;
  logic clk=0,rst_n=0,flush=0,debug_mode=0,hv,ht;
  logic [31:0] vpc='0;
  update_t update='0;
  logic [1:0][7:0] folded='0, folded_upd='0;
  bht_prediction_t [1:0] prediction;
  // Second DUT: ITTAGE shares the same row/column and update-fold ownership
  // contract; scenario 3 exercises it with the btb_* payload shapes.
  typedef struct packed {logic valid;logic [31:0] pc;logic [31:0] target_address;} btb_update_t;
  typedef struct packed {logic valid;logic [31:0] target_address;} btb_pred_t;
  btb_update_t btb_upd='0;
  btb_pred_t [1:0] btb_pred;
  bit negative;int scenario;
  g6lc_bp_tage #(.CVA6Cfg(C),.bht_update_t(update_t),.NR_ENTRIES(16),.NR_TABLES(2),.TABLE_ENTRIES(8),.TAG_BITS(4),.GHIST_LEN(8)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_bp_i(flush),.debug_mode_i(debug_mode),.vpc_i(vpc),.ghist_i('0),
    .folded_i(folded),.folded_update_i(folded_upd),
    .bht_update_i(update),.bht_prediction_o(prediction),.hist_update_valid_o(hv),.hist_update_taken_o(ht));
  g6lc_bp_ittage #(.CVA6Cfg(C),.btb_update_t(btb_update_t),.btb_prediction_t(btb_pred_t),.NR_ENTRIES(16),.TAG_BITS(4),.FOLD_W(8)) dut_ind(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.debug_mode_i(debug_mode),.vpc_i(vpc),
    .folded_i(folded[0]),.folded_update_i(folded_upd[0]),
    .btb_update_i(btb_upd),.btb_prediction_o(btb_pred));
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  task automatic upd(input logic [31:0] pc,input bit tk);
    update='{valid:1'b1,pc:pc,taken:tk};tick();update='0;tick();
  endtask
  task automatic upd_ind(input logic [31:0] pc,input logic [31:0] tgt);
    btb_upd='{valid:1'b1,pc:pc,target_address:tgt};tick();btb_upd='0;tick();
  endtask
  initial begin
    negative=$test$plusargs("oracle_negative");
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    #2;tick();rst_n=1;
    case(scenario)
      // Per-slot tagged provider: train pc 0x1010 taken -> tagged table1
      // idx0 tag1. Window vpc=0x1010: slot0 (pc 0x1010) hits taken, slot1
      // (pc 0x1012, idx1) must NOT inherit the window's provider.
      0:begin
        upd(32'h1010,1'b1);upd(32'h1010,1'b1);
        vpc=32'h1010;#2;
        if(negative) begin
          if(!(prediction[1].valid && prediction[1].taken))$fatal(1,"TAGE_SLOT_BROADCAST");
        end else begin
          if(!(prediction[0].valid && prediction[0].taken))$fatal(1,"TAGE_SLOT0_PROVIDER");
          if(prediction[1].valid && prediction[1].taken)$fatal(1,"TAGE_SLOT1_PROVIDER");
        end
      end
      // Update-fold ownership: train pc 0x1020 with folded_update=7 while the
      // live fold is 0. The entry must land at pc^folded_update; a later
      // predict only hits when folded_i supplies the update-time fold.
      1:begin
        folded_upd[1]=8'h07;
        upd(32'h1020,1'b1);
        folded[1]=8'h07;vpc=32'h1020;#2;
        if(negative) begin
          // Old behaviour: update hashed the live fold (0), so folded_i=0
          // still hits. Fixed RTL trained at pc^7, so this lookup misses.
          folded[1]=8'h00;#2;
          if(!prediction[0].taken)$fatal(1,"TAGE_UPDATE_FOLD");
        end else begin
          if(!prediction[0].taken)$fatal(1,"TAGE_UPDATE_FOLD");
          folded[1]=8'h00;#2;
          if(prediction[0].taken)$fatal(1,"TAGE_UPDATE_FOLD_MISS");
        end
      end
      // Unaligned base window (RVC): train pc 0x1002 taken twice -> new
      // addressing lands row0 col1; old overlapped addressing put it in
      // row1 col1. Folded lookups forced to miss so the base decides.
      2:begin
        upd(32'h1002,1'b1);upd(32'h1002,1'b1);
        folded[0]=8'h07;folded[1]=8'h07;
        vpc=32'h1002;#2;
        if(negative) begin
          if(!prediction[1].taken)$fatal(1,"TAGE_BASE_ALIAS");
        end else begin
          if(!prediction[0].taken)$fatal(1,"TAGE_BASE_ALIAS");
          if(prediction[1].taken)$fatal(1,"TAGE_BASE_ALIAS1");
        end
      end
      // ITTAGE unaligned ownership: train pc 0x1012 -> target 0x4000. New
      // addressing: uindex=pc[4:2]=4, urow=pc[1]=1. Old overlapped addressing
      // wrote index1 row1, so a vpc=0x1012 window hit slot1 (wrong PC), not
      // slot0.
      3:begin
        upd_ind(32'h1012,32'h4000);
        vpc=32'h1012;#2;
        if(negative) begin
          if(!btb_pred[1].valid)$fatal(1,"ITTAGE_SLOT_ALIAS");
        end else begin
          if(!(btb_pred[0].valid && btb_pred[0].target_address==32'h4000))$fatal(1,"ITTAGE_SLOT0");
          if(btb_pred[1].valid)$fatal(1,"ITTAGE_SLOT1_ALIAS");
        end
      end
      default:$fatal(1,"TAGE_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS tage scenario=%0d",scenario);$finish;
  end
endmodule

// Banked-GHR fold ownership: the train fold must derive from the resolve
// hart's history bank, not the live fetch bank (NrHarts=2).
module tb_g6lc_review_ghist;
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.VLEN=32;c.RVC=1;c.INSTR_PER_FETCH=2;c.NrHarts=2;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  logic clk=0,rst_n=0,flush=0,hart=0,train_hart=0,uv=0,ut=0,rv=0;
  logic [7:0] rgh='0,ghist,train_ghist;
  logic [1:0][7:0] folded,folded_tr;
  bit negative;
  g6lc_bp_ghist #(.CVA6Cfg(C),.GHIST_LEN(8),.NR_FOLDS(2),.FOLD_W(8)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.hart_i(hart),.train_hart_i(train_hart),
    .update_valid_i(uv),.update_taken_i(ut),.restore_valid_i(rv),.restore_ghist_i(rgh),
    .fold_src_i(train_ghist),
    .ghist_o(ghist),.train_ghist_o(train_ghist),.folded_o(folded),.folded_src_o(folded_tr));
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  initial begin
    negative=$test$plusargs("oracle_negative");
    #2;tick();rst_n=1;
    // bank0: shift in one taken (ghist=1); bank1: two takens (ghist=3)
    hart=0;train_hart=0;ut=1;uv=1;tick();uv=0;
    train_hart=1;uv=1;tick();tick();uv=0;tick();
    #2;
    // fold0 is the raw bank (GHIST_LEN==FOLD_W); fold1 rotates by one bit.
    if(ghist!==8'h01 || train_ghist!==8'h03)$fatal(1,"GHIST_BANK g=%0h t=%0h",ghist,train_ghist);
    if(folded[0]!==8'h01 || folded[1]!==8'h02)$fatal(1,"GHIST_FOLD_FETCH");
    if(negative) begin
      if(folded_tr[0]!==8'h01)$fatal(1,"GHIST_FOLD_TRAIN");
    end else begin
      if(folded_tr[0]!==8'h03 || folded_tr[1]!==8'h06)$fatal(1,"GHIST_FOLD_TRAIN %0h %0h",folded_tr[0],folded_tr[1]);
    end
    $display("RTL_REVIEW_PASS ghistfold");$finish;
  end
endmodule

// Prediction-time checkpoint FIFO: per-slot push vector, split push/pop
// harts, restore consumes the head and drops younger wrong-path entries,
// overflow raises desync until the bank drains. Observability is via the
// comb outputs (empty/full/desync/restore_*) and distinct per-push ghist
// values read back through restore_ghist_o (the head entry).
module tb_g6lc_review_ckpt;
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.VLEN=32;c.RVC=1;c.INSTR_PER_FETCH=2;c.NrHarts=1;c.RASDepth=0;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  localparam int DEPTH=4;
  logic clk=0,rst_n=0,flush=0,pop=0,restore=0;
  logic [0:0] phart='0, chart='0;
  logic [1:0] push='0;
  logic [7:0] pghist='0, rghist;
  logic rv,empty,full,desync;
  bit negative;int scenario;
  g6lc_bp_ckpt #(.CVA6Cfg(C),.GHIST_LEN(8),.DEPTH(DEPTH),.RAS_DEPTH(0),.RAS_VLEN(32),.NR_PUSH(2)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.push_hart_i(phart),.pop_hart_i(chart),
    .push_i(push),.push_ghist_i(pghist),.push_ras_valid_i('0),.push_ras_ra_i('0),
    .pop_i(pop),.restore_i(restore),
    .restore_ghist_o(rghist),.restore_ras_valid_o(),.restore_ras_ra_o(),
    .restore_valid_o(rv),.empty_o(empty),.full_o(full),.desync_o(desync));
  task automatic tick;clk=1;#2;clk=0;#2;endtask
  task automatic push1(input logic [7:0] g);
    push=2'b01;pghist=g;tick();push='0;
  endtask
  initial begin
    negative=$test$plusargs("oracle_negative");
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    #2;tick();rst_n=1;tick();
    case(scenario)
      // Conservation + ordering: push 0x11, then a two-slot push of 0x22
      // (count=3). Head must read 0x11; after one pop it reads 0x22.
      0:begin
        push1(8'h11);
        push=2'b11;pghist=8'h22;tick();push='0;
        #2;
        if(rghist!==8'h11)$fatal(1,"CKPT_HEAD0 %0h",rghist);
        pop=1;tick();pop=0;#2;
        if(rghist!==8'h22)$fatal(1,"CKPT_HEAD1 %0h",rghist);
        if(empty)$fatal(1,"CKPT_EMPTY");
        if(negative) begin
          // With multi-entry storage, one more pop leaves one entry, not
          // empty: asserting empty reproduces the pre-fix single-entry shape.
          pop=1;tick();pop=0;#2;
          if(!empty)$fatal(1,"CKPT_MULTI");
        end
      end
      // Full FIFO, same-cycle push+pop: the pop frees the slot the push
      // takes, so the head advances exactly once and count stays DEPTH.
      // Pre-fix RTL advanced head twice (drop-oldest + pop), losing 0x20.
      1:begin
        push1(8'h10);push1(8'h20);push1(8'h30);push1(8'h40);
        if(!full)$fatal(1,"CKPT_FULL");
        push=2'b01;pghist=8'h50;pop=1;tick();push='0;pop=0;#2;
        if(!full)$fatal(1,"CKPT_COUNT");
        if(negative) begin
          if(rghist!==8'h30)$fatal(1,"CKPT_DOUBLE_ADV");
        end else begin
          if(rghist!==8'h20)$fatal(1,"CKPT_DOUBLE_ADV %0h",rghist);
        end
      end
      // Restore consumes the head (0x11) and drops the younger 0x22/0x33:
      // the bank ends empty and a later pop is a no-op.
      2:begin
        push1(8'h11);push1(8'h22);push1(8'h33);
        #2;
        if(rghist!==8'h11)$fatal(1,"CKPT_RHEAD %0h",rghist);
        restore=1;#2;
        if(!rv)$fatal(1,"CKPT_RV");
        tick();restore=0;#2;
        if(!empty)$fatal(1,"CKPT_DRAIN");
        pop=1;tick();pop=0;#2;
        if(!empty)$fatal(1,"CKPT_POP_EMPTY");
        if(negative)$fatal(1,"CKPT_NEG_UNREACH");
      end
      // Overflow: fifth push on a full bank is dropped -> desync -> restore
      // is not qualified (rv stays low). Draining the bank clears desync.
      3:begin
        push1(8'h10);push1(8'h20);push1(8'h30);push1(8'h40);
        push1(8'h50);#2;
        if(!desync)$fatal(1,"CKPT_DESYNC");
        restore=1;#2;
        if(negative) begin
          if(!rv)$fatal(1,"CKPT_DESYNC_RV");
        end else begin
          if(rv)$fatal(1,"CKPT_DESYNC_RV");
        end
        tick();restore=0;#2;
        if(!empty || desync)$fatal(1,"CKPT_DESYNC_CLEAR e=%0b d=%0b",empty,desync);
      end
      // Multi-slot push ordering across windows: 0xAA then 0xBB -> head
      // must be 0xAA; restore drains both.
      4:begin
        push1(8'hAA);push1(8'hBB);#2;
        if(rghist!==8'hAA)$fatal(1,"CKPT_ORDER %0h",rghist);
        restore=1;tick();restore=0;#2;
        if(!empty)$fatal(1,"CKPT_ORDER_DRAIN");
        if(negative)$fatal(1,"CKPT_NEG_UNREACH");
      end
      5:begin
        push1(8'h10);push1(8'h20);push1(8'h30);push1(8'h40);
        push1(8'h50);
        pop=1;repeat(4)tick();pop=0;#2;
        if(!empty)$fatal(1,"CKPT_STORED_DRAIN");
        push1(8'h60);#2;
        restore=1;#2;
        if(rv!==(negative?1'b1:1'b0))$fatal(1,"CKPT_DROPPED_OWNER");
        tick();restore=0;#2;
        if(!empty||desync)$fatal(1,"CKPT_RESYNC_RESTORE");
        push1(8'h70);restore=1;#2;
        if(!rv||rghist!==8'h70)$fatal(1,"CKPT_RESYNC_HEAD");
      end
      6:begin
        push1(8'h10);push1(8'h20);push1(8'h30);push1(8'h40);
        push1(8'h50);
        pop=1;repeat(4)tick();pop=0;#2;
        if(!empty||!desync)$fatal(1,"CKPT_EMPTY_POISON");
        restore=1;tick();restore=0;#2;
        if(!empty||desync)$fatal(1,"CKPT_EMPTY_RESYNC");
        push1(8'h80);restore=1;#2;
        if(rv!==(negative?1'b0:1'b1)||rghist!==8'h80)$fatal(1,"CKPT_EMPTY_RESTORE_HEAD");
      end
      default:$fatal(1,"CKPT_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS ckpt scenario=%0d",scenario);$finish;
  end
endmodule

// Directed retirement-width contract for scoreboard. The pre-fix num_commit
// counted only port 0 whenever NrCommitPorts != 2, so a four-port ack retired
// four entries while the commit pointer advanced by one — retired slots were
// re-presented and the surviving tail was never reached in order. These
// scenarios observe the port ordering (commit_instr_o[k].trans_id ==
// commit_pointer_q[k]) and TID conservation across a full drain and a
// wraparound, with no hierarchical probes.
module tb_g6lc_review_commit;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  parameter int NPC=4;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.NrIssuePorts=2; c.NrCommitPorts=NPC; c.NrWbPorts=2;
    c.NR_SB_ENTRIES=8; c.TRANS_ID_BITS=3;
    c.XLEN=64; c.VLEN=64; c.GPLEN=64; c.FLen=64;
    c.NrHarts=1; c.NrRgprPorts=2; c.SuperscalarEn=1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  localparam int NSB=C.NR_SB_ENTRIES;
  localparam int NP=C.NrIssuePorts;
  localparam int NW=C.NrWbPorts;
  localparam int HIDB=(C.NrHarts<=1)?1:$clog2(C.NrHarts);
  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C) scoreboard_entry_t;
  // Layout-identical copies of the cva6.sv localparam types that
  // g6lc_core_types.svh does not carry yet (bp_resolve_t, writeback_t,
  // forwarding_t). Same hand-copy hazard the header warns about: if cva6.sv
  // changes these, change them here.
  typedef struct packed {
    logic valid; logic [C.VLEN-1:0] pc; logic [C.VLEN-1:0] target_address;
    logic is_mispredict; logic is_taken; cf_t cf_type;
    logic [HIDB-1:0] hart_id; logic ckpt_restore;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
  } bp_resolve_t;
  typedef struct packed {
    logic valid; logic [C.XLEN-1:0] data; logic ex_valid;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
  } writeback_t;
  typedef struct packed {
    logic [NSB-1:0] still_issued;
    logic [C.TRANS_ID_BITS-1:0] issue_pointer;
    writeback_t [NW-1:0] wb;
    scoreboard_entry_t [NSB-1:0] sbe;
  } forwarding_t;
  typedef logic [C.XLEN-1:0] rs3_len_t;

  logic clk=0,rst_n=0,flush=0,flush_unissued=0;
  logic sb_full,spec_cancel;
  logic [NSB-1:0] cancelled_mask;
  logic [NPC-1:0] commit_ack='0,commit_drop;
  scoreboard_entry_t [NPC-1:0] commit_instr;
  scoreboard_entry_t [NP-1:0] decoded='{default:'0},issue_instr;
  logic [NP-1:0][31:0] orig='0,orig_o;
  logic [NP-1:0] decoded_valid='0,decoded_ack,issue_valid,issue_ack='0;
  forwarding_t fwd;
  bp_resolve_t resolved='0;
  logic [NW-1:0][C.TRANS_ID_BITS-1:0] wb_tid='0;
  logic [NW-1:0][C.XLEN-1:0] wb_data='0;
  exception_t [NW-1:0] wb_ex='{default:'0};
  logic [NW-1:0] wt_valid='0;
  logic [NP-1:0][C.TRANS_ID_BITS-1:0] rvfi_issue;
  logic [NPC-1:0][C.TRANS_ID_BITS-1:0] rvfi_commit;
  logic [C.NrHarts-1:0] g1mf_v,g1mf_a3;
  logic [C.NrHarts-1:0][4:0] g1mf_rd;
  logic [C.NrHarts-1:0][C.VLEN-1:4] g1mf_line;
  bit negative;
  int scenario;
  // commit_instr_o / issue_instr_o are unpacked arrays of a wide packed
  // struct; reading them directly from the timed process trips a Verilator
  // 5.008 codegen bug (__Vilp used before declaration in the top-level
  // __Vsampled loop). Snapshot the commit head on the clock edge into a
  // packed vector instead, and read the issue-side trans_id through the
  // (packed) rvfi_issue_pointer_o, which carries the same value.
  logic [NPC-1:0][$bits(scoreboard_entry_t)-1:0] commit_snap;
  // Negedge capture: the snapshot holds the post-edge commit head during the
  // low half-cycle in which the checks below sample it.
  always_ff @(negedge clk) begin
    for (int g = 0; g < NPC; g++) commit_snap[g] <= commit_instr[g];
  end
  task automatic chk_head(input int k,input int want_tid,
                          input logic [63:0] want_pc,input string tag);
    scoreboard_entry_t e;
    e=scoreboard_entry_t'(commit_snap[k]);
    if(e.trans_id!==C.TRANS_ID_BITS'(want_tid))
      $fatal(1,"%s port=%0d tid got=%0d want=%0d",tag,k,e.trans_id,want_tid);
    if(e.pc!==want_pc)
      $fatal(1,"%s port=%0d pc got=%h want=%h",tag,k,e.pc,want_pc);
  endtask

  scoreboard #(.CVA6Cfg(C),.bp_resolve_t(bp_resolve_t),.exception_t(exception_t),
      .scoreboard_entry_t(scoreboard_entry_t),.forwarding_t(forwarding_t),
      .writeback_t(writeback_t),.rs3_len_t(rs3_len_t)) dut (
    .clk_i(clk),.rst_ni(rst_n),.sb_full_o(sb_full),.spec_cancel_o(spec_cancel),
    .cancelled_mask_o(cancelled_mask),.flush_unissued_instr_i(flush_unissued),
    .flush_i(flush),.x_transaction_accepted_i(1'b0),.x_issue_writeback_i(1'b0),
    .x_id_i('0),.commit_instr_o(commit_instr),.commit_drop_o(commit_drop),
    .commit_ack_i(commit_ack),.decoded_instr_i(decoded),.orig_instr_i(orig),
    .decoded_instr_valid_i(decoded_valid),.decoded_instr_ack_o(decoded_ack),
    .issue_instr_o(issue_instr),.orig_instr_o(orig_o),
    .issue_instr_valid_o(issue_valid),.issue_ack_i(issue_ack),.fwd_o(fwd),
    .resolved_branch_i(resolved),.trans_id_i(wb_tid),.wbdata_i(wb_data),
    .ex_i(wb_ex),.wt_valid_i(wt_valid),.x_we_i(1'b0),.x_rd_i('0),
    .rvfi_issue_pointer_o(rvfi_issue),.rvfi_commit_pointer_o(rvfi_commit),
    .g1mf_v_o(g1mf_v),.g1mf_rd_o(g1mf_rd),.g1mf_line_o(g1mf_line),
    .g1mf_a3_o(g1mf_a3));

  task automatic tick;clk=1; #2; clk=0; #2;endtask

  // Offer one decoded instruction on issue port p (fu=NONE self-validates).
  task automatic offer(input int p,input int marker);
    decoded[p]='0;
    decoded[p].fu=NONE;
    decoded[p].pc=64'h1000+64'(marker)*4;
    decoded[p].rd=5'(marker+1);
    decoded_valid[p]=1'b1;
    orig[p]=32'(marker);
  endtask

  initial begin
    negative=$test$plusargs("oracle_negative");scenario=0;
    void'($value$plusargs("scenario=%d",scenario));
    #2;tick();rst_n=1;#2;
    if(scenario==0)begin
      // Six allocs over three cycles on two issue ports -> trans_ids 0..5.
      for(int n=0;n<3;n++)begin
        issue_ack='1;
        for(int p=0;p<NP;p++)offer(p,n*NP+p);
        #2;
        for(int p=0;p<NP;p++)begin
          if(!issue_valid[p]||!decoded_ack[p])
            $fatal(1,"COMMIT4_ALLOC port=%0d iv=%b da=%b",p,issue_valid[p],decoded_ack[p]);
          if(rvfi_issue[p]!==C.TRANS_ID_BITS'(n*NP+p))
            $fatal(1,"COMMIT4_ISSUE_TID port=%0d got=%0d want=%0d",p,rvfi_issue[p],n*NP+p);
        end
        tick();
      end
      decoded_valid='0;issue_ack='0;#2;
      // Commit head must present the four oldest entries in order — check the
      // stored payload (pc marker) as well as the presented trans_id, since
      // trans_id is overwritten with the pointer at present time and cannot
      // detect a desynchronised FIFO by itself.
      for(int k=0;k<NPC;k++) chk_head(k,k,64'h1000+64'(k)*4,"COMMIT4_ORDER");
      // One four-wide commit: pointer must advance by FOUR, not one.
      commit_ack='1;tick();commit_ack='0;#2;
      chk_head(0,negative?5:4,64'h1000+64'(negative?5:4)*4,"COMMIT4_TID");
      chk_head(1,5,64'h1014,"COMMIT4_TAIL");
      if(fwd.still_issued!==NSB'(8'h30))
        $fatal(1,"COMMIT4_STILL got=%b want=00110000",fwd.still_issued);
      if(rvfi_commit[0]!==C.TRANS_ID_BITS'(4))
        $fatal(1,"COMMIT4_PTR got=%0d want=4",rvfi_commit[0]);
      // Drain the remaining two on ports 0-1; queue must be empty.
      commit_ack=4'b0011;tick();commit_ack='0;#2;
      if(fwd.still_issued!=='0)$fatal(1,"COMMIT4_DRAIN still=%b",fwd.still_issued);
      if(rvfi_commit[0]!==rvfi_issue[0])
        $fatal(1,"COMMIT4_EMPTY commit=%0d issue=%0d",rvfi_commit[0],rvfi_issue[0]);
    end
    else if(scenario==1)begin
      // Wraparound: six allocs, commit four, alloc four more (tids 6,7,0,1),
      // commit four again -> commit pointer wraps to 0; the wrapped entries
      // stay live and in order, then drain.
      for(int n=0;n<3;n++)begin
        issue_ack='1;for(int p=0;p<NP;p++)offer(p,n*NP+p);#2;tick();
      end
      decoded_valid='0;issue_ack='0;#2;
      commit_ack='1;tick();commit_ack='0;#2;
      for(int n=0;n<2;n++)begin
        issue_ack='1;
        for(int p=0;p<NP;p++)offer(p,6+n*NP+p);
        #2;
        for(int p=0;p<NP;p++)
          if(rvfi_issue[p]!==C.TRANS_ID_BITS'((6+n*NP+p)%NSB))
            $fatal(1,"COMMIT4_WRAP_ISSUE port=%0d got=%0d want=%0d",
                   p,rvfi_issue[p],(6+n*NP+p)%NSB);
        tick();
      end
      decoded_valid='0;issue_ack='0;#2;
      // Head presents entries 4..7 (pointers) whose payloads are markers
      // 4,5,6,7 — allocated as tids 4,5,6,7 before the first commit.
      for(int k=0;k<NPC;k++) chk_head(k,4+k,64'h1000+64'(4+k)*4,"COMMIT4_WRAP_HEAD");
      commit_ack='1;tick();commit_ack='0;#2;
      // Committed entries 4..7; pointer wrapped to 0. The wrapped allocs at
      // tids 0,1 (markers 8,9) must still be live and in order at the head.
      if(fwd.still_issued!==NSB'(8'h03))
        $fatal(1,"COMMIT4_WRAP_STILL got=%b want=00000011",fwd.still_issued);
      chk_head(0,0,64'h1020,"COMMIT4_WRAP_LIVE0");
      chk_head(1,1,64'h1024,"COMMIT4_WRAP_LIVE1");
      commit_ack=4'b0011;tick();commit_ack='0;#2;
      if(fwd.still_issued!=='0)$fatal(1,"COMMIT4_WRAP_DRAIN still=%b",fwd.still_issued);
      if(rvfi_commit[0]!==rvfi_issue[0])
        $fatal(1,"COMMIT4_WRAP_EMPTY commit=%0d issue=%0d",rvfi_commit[0],rvfi_issue[0]);
    end
    else $fatal(1,"COMMIT4_SCENARIO");
    $display("RTL_REVIEW_PASS commit scenario=%0d npc=%0d",scenario,NPC);$finish;
  end
endmodule
