// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_review_fp_lifetime;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  parameter int NSB=32;
  parameter bit EXPECT_CANCEL=0,OOO=1,DIVIDER=0;
  localparam int TW=$clog2(NSB);
  localparam fu_t PRODUCER=DIVIDER?MULT:FPU;
  localparam fu_op PRODUCER_OP=DIVIDER?DIVU:FDIV;
  localparam logic[63:0] PRODUCER_RESULT=DIVIDER?64'h1000000:64'h3fd5555555555555;
  localparam logic[63:0] REPLACEMENT_RESULT=DIVIDER?64'h2000000:64'h3fe5555555555555;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.FLen=64;c.IS_XLEN64=1;
    c.NrHarts=1;c.NrIssuePorts=2;c.NrCommitPorts=2;c.NrWbPorts=4;c.NrRgprPorts=2;
    c.NR_SB_ENTRIES=NSB;c.TRANS_ID_BITS=TW;c.SuperscalarEn=1;c.SpeculativeSb=1;
    c.OoOEn=OOO;c.FpPresent=1;c.RVF=1;c.RVD=1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C) sbe_t;
  typedef struct packed {
    logic valid;logic[63:0] pc,target_address;logic is_mispredict,is_taken;
    cf_t cf_type;logic hart_id,ckpt_restore;logic[TW-1:0] trans_id;
  } bp_t;
  typedef struct packed {
    logic valid;logic[63:0] data;logic ex_valid;logic[TW-1:0] trans_id;
  } wb_t;
  typedef struct packed {
    logic[NSB-1:0] still_issued;logic[TW-1:0] issue_pointer;
    wb_t[3:0] wb;sbe_t[NSB-1:0] sbe;
  } fwd_t;
  typedef struct packed {
    logic[TW-1:0] trans_id;fu_t fu;fu_op operation;
    logic[63:0] operand_a,operand_b,imm;
  } fu_typed_t;
  logic clk=0,rst_n=0,flush_if,flush_id,flush_ex,flush_unissued,ex_event=0;
  logic sb_full,sb_empty,commit_run=0;
  logic[NSB-1:0] cancel;
  logic[1:0] dv='0,da,iv,ia,ca,drop;
  sbe_t[1:0] decoded='0,issued,committed;
  logic[1:0][TW-1:0] ip,cp;
  logic[3:0] wv;
  logic[3:0][TW-1:0] wid;
  logic[3:0][63:0] wd;
  exception_t[3:0] wx;
  bp_t branch='0;
  fwd_t fwd;
  fu_typed_t fp_data;
  logic fp_ready,fp_valid,fp_early,fp_in,fpu_ready,fpu_valid,div_ready,div_valid;
  logic[TW-1:0] fp_id,fpu_id,div_id,alu_id='0;
  logic[63:0] fp_result,fpu_result,div_result;
  logic alu_valid=0,branch_wb=0;
  exception_t fp_ex;
  int scenario,cycles=0,fp_accept_cycle=-1,fp_return_cycle=-1,reuse_cycle=-1,fp_returns=0;
  bit negative,reused=0,old_seen=0;
  always #5 clk=~clk;
  assign ia=iv & {2{!flush_unissued}};
  assign fp_in=da[0] && decoded[0].fu==PRODUCER;
  assign fp_ready=DIVIDER?div_ready:fpu_ready;
  assign fp_valid=DIVIDER?div_valid:fpu_valid;
  assign fp_id=DIVIDER?div_id:fpu_id;
  assign fp_result=DIVIDER?div_result:fpu_result;
  always_comb begin
    fp_data='0;fp_data.fu=PRODUCER;fp_data.operation=PRODUCER_OP;fp_data.trans_id=ip[0];
    if(DIVIDER)begin
      fp_data.operand_a=((scenario==3||scenario==5) && decoded[0].rd==9)?64'h8000000000000000:64'h4000000000000000;
      fp_data.operand_b=64'h4000000000;
    end else begin
      fp_data.operand_a=((scenario==3||scenario==5) && decoded[0].rd==9)?64'h4000000000000000:64'h3ff0000000000000;
      fp_data.operand_b=64'h4008000000000000;
    end
    wv='0;wid='0;wd='0;wx='0;
    wv[0]=alu_valid||branch_wb;wid[0]=branch_wb?branch.trans_id:alu_id;wd[0]=64'h55;
    wv[3]=fp_valid;wid[3]=fp_id;wd[3]=fp_result;wx[3]=fp_ex;
    ca='0;
    if(commit_run && (drop[0] || committed[0].valid))ca[0]=1;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin alu_valid<=0;alu_id<='0;end
    else begin
      alu_valid<=da[0] && decoded[0].fu==ALU && !flush_unissued;
      if(da[0])alu_id<=ip[0];
    end
  end
  always @(posedge clk) if(rst_n)begin
    cycles<=cycles+1;
    if(fp_in)begin
      fp_accept_cycle=cycles;
      $display("FP_OWNER_ACCEPT cycle=%0d tid=%0d ready=%b",cycles,ip[0],fp_ready);
    end
    if(fp_valid)begin
      fp_returns++;
      fp_return_cycle=cycles;
      old_seen=1;
      $display("FP_OWNER_RETURN cycle=%0d tid=%0d data=%h reused=%b",cycles,fp_id,fp_result,reused);
      if(EXPECT_CANCEL && scenario==1)$fatal(1,"FP_OWNER_CANCELLED_RESPONSE");
      if(fp_id!=TW'(1) || fp_result!=(((scenario==3||scenario==5)?REPLACEMENT_RESULT:PRODUCER_RESULT) ^ (negative?64'd1:64'd0)))
        $fatal(1,"FP_OWNER_RESULT");
      if(scenario==2)$fatal(1,"FP_OWNER_FULL_FLUSH_RESPONSE");
      if(scenario==5 && !reused)$fatal(1,"FP_OWNER_FLUSHED_RESPONSE");
    end
  end
  scoreboard #(.CVA6Cfg(C),.bp_resolve_t(bp_t),.exception_t(exception_t),
    .scoreboard_entry_t(sbe_t),.forwarding_t(fwd_t),.writeback_t(wb_t),.rs3_len_t(logic[63:0])) sb(
    .clk_i(clk),.rst_ni(rst_n),.sb_full_o(sb_full),.sb_empty_o(sb_empty),.spec_cancel_o(),
    .cancelled_mask_o(cancel),.sb_live_o(),.mem_violation_i(1'b0),.mem_violation_id_i('0),
    .phys_pending_i('0),.phys_replay_i('0),.phys_mod_i(1'b0),
    .flush_unissued_instr_i(flush_unissued),.flush_i(flush_id),
    .x_transaction_accepted_i(1'b0),.x_issue_writeback_i(1'b0),.x_id_i('0),
    .commit_instr_o(committed),.commit_drop_o(drop),.commit_replay_o(),.commit_ack_i(ca),
    .decoded_instr_i(decoded),.orig_instr_i('0),.decoded_instr_valid_i(dv),.decoded_instr_ack_o(da),
    .issue_instr_o(issued),.orig_instr_o(),.issue_instr_valid_o(iv),.issue_ack_i(ia),.fwd_o(fwd),
    .resolved_branch_i(branch),.trans_id_i(wid),.wbdata_i(wd),.ex_i(wx),.wt_valid_i(wv),
    .x_we_i(1'b0),.x_rd_i('0),.rvfi_issue_pointer_o(ip),.rvfi_commit_pointer_o(cp),
    .reclaim_ptr_o(),
    .g1mf_v_o(),.g1mf_rd_o(),.g1mf_line_o(),.g1mf_a3_o());
  controller #(.CVA6Cfg(C),.bp_resolve_t(bp_t)) ctrl(
    .clk_i(clk),.rst_ni(rst_n),.v_i(1'b0),.set_pc_commit_o(),.flush_if_o(flush_if),
    .flush_unissued_instr_o(flush_unissued),.flush_id_o(flush_id),.flush_ex_o(flush_ex),
    .flush_bp_o(),.flush_icache_o(),.flush_dcache_o(),.flush_dcache_ack_i(1'b0),
    .flush_tlb_o(),.flush_tlb_vvma_o(),.flush_tlb_gvma_o(),.halt_csr_i(1'b0),.halt_acc_i(1'b0),
    .halt_frontend_o(),.halt_o(),.eret_i(1'b0),.ex_valid_i(ex_event),.set_debug_pc_i(1'b0),
    .resolved_branch_i(branch),.flush_csr_i(1'b0),.fence_i_i(1'b0),.fence_i(1'b0),
    .sfence_vma_i(1'b0),.hfence_vvma_i(1'b0),.hfence_gvma_i(1'b0),.flush_commit_i(1'b0),
    .replay_i(1'b0),.mem_replay_pc_o(),.flush_acc_i(1'b0),.smt_switch_i(1'b0));
  fpu_wrap #(.CVA6Cfg(C),.exception_t(exception_t),.fu_data_t(fu_typed_t)) fpu(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush_ex),.cancelled_mask_i(cancel),.fpu_valid_i(fp_in && !DIVIDER),.fpu_ready_o(fpu_ready),
    .fu_data_i(fp_data),.fpu_fmt_i(2'b01),.fpu_rm_i(3'b000),.fpu_frm_i(3'b000),.fpu_prec_i('0),
    .fpu_trans_id_o(fpu_id),.result_o(fpu_result),.fpu_valid_o(fpu_valid),
    .fpu_exception_o(fp_ex),.fpu_early_valid_o(fp_early));
  mult #(.CVA6Cfg(C),.fu_data_t(fu_typed_t)) divider(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush_ex),.cancelled_mask_i(cancel),.fu_data_i(fp_data),.mult_valid_i(fp_in && DIVIDER),
    .result_o(div_result),.mult_valid_o(div_valid),.mult_ready_o(div_ready),.mult_trans_id_o(div_id));
  task automatic drive;@(negedge clk);endtask
  task automatic offer(input fu_t fu,input fu_op op,input int rd,input int expected_tid);
    decoded='0;decoded[0].fu=fu;decoded[0].op=op;decoded[0].rd=5'(rd);
    decoded[0].pc=64'h80000000+64'(cycles)*4;dv=1;
    #4;
    if(da!=1 || ip[0]!=TW'(expected_tid))$fatal(1,"FP_OWNER_ALLOCATION tid=%0d expected=%0d ack=%b",ip[0],expected_tid,da);
    drive();dv=0;
  endtask
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(3)drive();rst_n=1;drive();
    offer(CTRL_FLOW,NE,0,0);
    if(!fp_ready)$fatal(1,"FP_OWNER_NOT_READY");
    offer(PRODUCER,PRODUCER_OP,7,1);
    if(scenario==0 || scenario==4)begin
      if(scenario==4)begin
        offer(CTRL_FLOW,NE,0,2);
        offer(ALU,ADD,0,3);
        branch.valid=1;branch.is_mispredict=1;branch.is_taken=1;branch.cf_type=Branch;
        branch.trans_id=TW'(2);branch_wb=1;
        #4;
        if(flush_ex||cancel[1]||!cancel[3])$fatal(1,"FP_OWNER_OLDER_SETUP");
        drive();branch='0;branch_wb=0;
      end
      repeat(160)drive();
      if(fp_returns!=1)$fatal(1,"FP_OWNER_NORMAL_COMPLETION count=%0d",fp_returns);
      $display("FP_OWNER_PASS scenario=%0d accept=%0d response=%0d",scenario,fp_accept_cycle,fp_return_cycle);
    end else begin
      if(scenario==1 || scenario==3)begin
        branch.valid=1;branch.is_mispredict=1;branch.is_taken=1;branch.cf_type=Branch;
        branch.trans_id='0;branch_wb=1;
        #4;
        if(flush_ex||flush_id||!flush_unissued||!cancel[1])$fatal(1,"FP_OWNER_SELECTIVE_SETUP");
        drive();branch='0;branch_wb=0;commit_run=1;
        drive();
        for(int n=2;n<NSB;n++)offer(ALU,ADD,0,n);
        offer(ALU,ADD,0,0);
      end else if(scenario==2 || scenario==5)begin
        ex_event=1;#4;
        if(!flush_ex||!flush_id)$fatal(1,"FP_OWNER_FULL_FLUSH_SETUP");
        drive();ex_event=0;commit_run=1;
        offer(ALU,ADD,0,0);
      end else $fatal(1,"FP_OWNER_SCENARIO");
      if(scenario==3 || scenario==5)begin
        while(!fp_ready)drive();
        offer(PRODUCER,PRODUCER_OP,9,1);
      end else offer(LOAD,LD,9,1);
      reused=1;reuse_cycle=cycles;
      $display("FP_OWNER_REUSE cycle=%0d old_seen=%b",reuse_cycle,old_seen);
      repeat(160)begin
        drive();#4;
        if(cp[0]==TW'(1) && committed[0].fu==LOAD && committed[0].valid)
          $fatal(1,"FP_OWNER_STALE_COMPLETION data=%h",committed[0].result);
      end
      if(scenario==1 && fp_returns!=(EXPECT_CANCEL?0:1))$fatal(1,"FP_OWNER_MISSING_RESPONSE");
      if(scenario==2 && fp_returns!=0)$fatal(1,"FP_OWNER_FULL_FLUSH_RESPONSE");
      if((scenario==3 || scenario==5) && fp_returns!=1)$fatal(1,"FP_OWNER_REPLACEMENT_MISSING");
      if(scenario==1 && !EXPECT_CANCEL)
        $display("FP_OWNER_NO_OVERLAP accept=%0d response=%0d reuse=%0d",fp_accept_cycle,fp_return_cycle,reuse_cycle);
      else begin
        if(negative)$fatal(1,"FP_OWNER_ORACLE_NEGATIVE");
        $display("FP_OWNER_PASS scenario=%0d",scenario);
      end
    end
    $finish;
  end
endmodule

module tb_g6lc_review_load_cancel;
  import ariane_pkg::*;
  parameter bit OOO=1;
  parameter int NLOAD=4;
  parameter bit MMU=0;
  parameter bit COH=0;
  // NI=1 declares the fixture's (zero) physical page non-idempotent so the
  // commit-head gate of a device load can be exercised.
  parameter bit NI=0;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64; c.VLEN=64; c.PLEN=56; c.PPNW=44; c.IS_XLEN64=1; c.XLEN_ALIGN_BYTES=3;
    c.NR_SB_ENTRIES=8; c.TRANS_ID_BITS=3; c.NrLoadBufEntries=NLOAD;
    c.DcacheIdWidth=2; c.DCACHE_INDEX_WIDTH=12; c.DCACHE_TAG_WIDTH=44;
    c.OoOEn=OOO; c.MmuPresent=MMU; c.SpeculativeSb=1; c.SuperscalarEn=1;
    c.CohPolicy=COH ? config_pkg::COH_OOO : config_pkg::COH_WRITE_INVAL;
    c.NrHarts=COH ? 2 : 0;
    c.TvalEn=1;
    if(NI)begin
      c.NonIdemPotenceEn=1; c.NrNonIdempotentRules=1;
      c.NonIdempotentAddrBase[0]=64'h0; c.NonIdempotentLength[0]=64'h1000_0000;
    end
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {
    logic valid; logic [63:0] vaddr; logic [31:0] tinst;
    logic hs_ld_st_inst,hlvx_inst,overflow,g_overflow;
    logic [63:0] data,data_cmp,data_hi,data_cmp_hi; logic [7:0] be;
    fu_t fu; fu_op operation; logic [2:0] trans_id; logic hart;
    logic is_speculative_load,is_speculative_load_miss;
  } ctrl_t;
  typedef struct packed {
    logic valid; logic [63:0] cause,tval,tval2; logic [31:0] tinst; logic gva;
  } exception_t;
  typedef struct packed {logic valid,is_mispredict;} branch_t;
  typedef struct packed {
    logic data_we; logic [63:0] data_wdata; logic [7:0] cbo_op;
    logic [11:0] address_index; logic [43:0] address_tag; logic [1:0] data_id;
    logic data_wuser,data_req,kill_req,tag_valid; logic [7:0] data_be; logic [1:0] data_size;
  } req_t;
  typedef struct packed {logic data_gnt,data_rvalid; logic [1:0] data_rid; logic [63:0] data_rdata;} resp_t;
  logic clk=0,rst_n=0,flush=0,in_valid=0,pop,ready,wb,match_page=0,dtlb_hit=1,fwd_valid=0;
  logic nsp=1;  // committed store queue empty (speculative stores may remain)
  logic [7:0] cancel='0;
  logic [2:0] tid;
  logic [63:0] result;
  logic [55:0] translated_pa=56'h80001000,phys_addr;
  logic phys_valid,phys_hart;
  logic [2:0] phys_id;
  logic [1:0] phys_size;
  ctrl_t incoming='0,head;
  branch_t branch='0;
  req_t req;
  resp_t resp='0;
  exception_t ex,ex_in='0;
  int scenario;
  bit negative,killed=0,seen_ex=0;
  logic [1:0] old_id,new_id;
  lsu_bypass #(.CVA6Cfg(C),.lsu_ctrl_t(ctrl_t),.bp_resolve_t(branch_t)) queue (
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.lsu_req_i(incoming),
    .lsu_req_valid_i(in_valid),.pop_ld_i(pop),.pop_st_i(1'b0),
    .resolved_branch_i(branch),.lsu_ctrl_o(head),.ready_o(ready)
`ifdef G6LC_REVIEW_CANCEL_PORT
    ,.cancelled_mask_i(cancel)
`endif
  );
  load_unit #(.CVA6Cfg(C),.dcache_req_i_t(req_t),.dcache_req_o_t(resp_t),
    .exception_t(exception_t),.lsu_ctrl_t(ctrl_t)) dut (
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.cancelled_mask_i(cancel),
    .valid_i(head.valid),.lsu_ctrl_i(head),.pop_ld_o(pop),.valid_o(wb),
    .trans_id_o(tid),.result_o(result),.ex_o(ex),.mbe_i(1'b0),
    .translation_req_o(),.vaddr_o(),.tinst_o(),.hs_ld_st_inst_o(),.hlvx_inst_o(),
    .paddr_i(translated_pa),.ex_i(ex_in),.dtlb_hit_i(dtlb_hit),.dtlb_ppn_i('0),
    .page_offset_o(),.load_paddr_o(),.load_paddr_valid_o(),.load_trans_id_o(),.load_hart_o(),
    .page_offset_matches_i(match_page),.store_buffer_empty_i(1'b0),.no_st_pending_i(nsp),
    .st_fwd_valid_i(fwd_valid),.st_fwd_data_i(64'h12345666),.st_fwd_be_i(8'hff),
    .commit_tran_id_i('0),.req_port_i(resp),.req_port_o(req),
    .dcache_wbuffer_not_ni_i(1'b1),.dcache_wbuffer_empty_i(1'b0)
`ifdef G6LC_REVIEW_PHYS_PORT
    ,.phys_valid_o(phys_valid),.phys_addr_o(phys_addr),.phys_id_o(phys_id),
    .phys_hart_o(phys_hart),.phys_size_o(phys_size)
`endif
  );
`ifndef G6LC_REVIEW_PHYS_PORT
  assign phys_valid=0;
  assign phys_addr='0;
  assign phys_id='0;
  assign phys_hart=0;
  assign phys_size='0;
`endif
  task automatic tick; clk=1;#2;clk=0;#2;endtask
  task automatic offer(input int id,input fu_op op);
    incoming='0;incoming.valid=1;incoming.fu=LOAD;incoming.operation=op;
    incoming.trans_id=3'(id);incoming.vaddr=64'h80001000;incoming.be='1;in_valid=1;#2;
  endtask
  task automatic quiet; in_valid=0;incoming='0;#2;endtask
  task automatic response(input logic [1:0] id,input int owner,input bit expected,
                          input logic [63:0] value=64'h66);
    resp.data_rvalid=1;resp.data_rid=id;resp.data_rdata=64'h12345666;#2;
    if(wb!==expected || (wb && (tid!=3'(owner) || result!=(value ^ 64'(negative)))))
      $fatal(1,"LOAD_CANCEL_RESPONSE owner=%0d tid=%0d wb=%b data=%h",owner,tid,wb,result);
    tick();resp.data_rvalid=0;#2;
  endtask
  initial begin
    scenario=0;void'($value$plusargs("scenario=%d",scenario));negative=$test$plusargs("oracle_negative");
    #2;tick();rst_n=1;#2;
    case(scenario)
      0,1: begin
        match_page=1;offer(3,LD);tick();quiet();
        if(scenario==1)begin offer(4,LD);tick();quiet();cancel[4]=1;end
        else cancel[3]=1;
        #2;tick();cancel='0;
        repeat(12)tick();
        match_page=0;resp.data_gnt=1;
        if(scenario==1)begin
          while(!req.data_req)tick();
          old_id=req.data_id;tick();#2;
        end
        repeat(4)begin #2;if(OOO && req.data_req)$fatal(1,"LOAD_CANCEL_STALE_REQUEST");tick();end
        if(!ready)$fatal(1,"LOAD_CANCEL_QUEUE_NOT_DRAINED");
      end
      2:begin
        offer(3,LD);cancel[3]=1;resp.data_gnt=1;#2;
        if(OOO && req.data_req)$fatal(1,"LOAD_CANCEL_SAME_CYCLE_GRANT");
        tick();quiet();cancel='0;tick();
      end
      3:begin
        offer(3,LD);tick();quiet();cancel[3]=1;resp.data_gnt=1;#2;
        if(OOO && req.data_req)$fatal(1,"LOAD_CANCEL_WAIT_GRANT");
        tick();cancel='0;tick();
      end
      4:begin
        resp.data_gnt=1;offer(3,LD);old_id=req.data_id;tick();quiet();tick();
        cancel[3]=1;tick();cancel='0;
        offer(3,LBU);new_id=req.data_id;tick();quiet();tick();
        response(old_id,3,0);response(new_id,3,1);
      end
      5:begin
        resp.data_gnt=1;offer(1,LBU);old_id=req.data_id;tick();
        offer(3,LD);cancel[3]=1;#2;
        if(!req.tag_valid || req.kill_req || (OOO && req.data_req))$fatal(1,"LOAD_CANCEL_OLDER_TAG");
        tick();quiet();cancel='0;response(old_id,1,1);
      end
      6:begin
        match_page=1;offer(3,LD);tick();quiet();flush=1;tick();flush=0;match_page=0;
        resp.data_gnt=1;repeat(3)tick();
        if(!ready || wb || req.data_req)$fatal(1,"LOAD_CANCEL_FULL_FLUSH");
      end
      7:begin
        offer(1,LBU);incoming.is_speculative_load=1;branch='1;match_page=1;tick();
        quiet();branch='0;tick();
        match_page=0;resp.data_gnt=1;
        repeat(3)begin
          #2;if(req.data_req)old_id=req.data_id;
          tick();
        end
        response(old_id,1,1);
      end
      8:begin
        dtlb_hit=0;resp.data_gnt=1;offer(3,LBU);old_id=req.data_id;tick();quiet();
        cancel[3]=1;#2;
        if(!req.kill_req || !req.tag_valid || req.data_req || wb)$fatal(1,"LOAD_CANCEL_ABORT");
        tick();cancel='0;dtlb_hit=1;response(old_id,3,0);
      end
      9:begin
        dtlb_hit=0;offer(3,LBU);incoming.is_speculative_load=1;tick();quiet();
        cancel[3]=1;#2;
        if(!pop || req.data_req || wb)$fatal(1,"LOAD_CANCEL_WAIT_SPEC");
        tick();cancel='0;dtlb_hit=1;tick();
      end
      10:begin
        match_page=1;offer(3,LBU);tick();quiet();
        cancel[3]=1;fwd_valid=1;#2;
        if(!pop || wb || req.data_req)$fatal(1,"LOAD_CANCEL_FORWARD");
        tick();cancel='0;fwd_valid=0;match_page=0;
      end
      11:begin
        resp.data_gnt=1;offer(1,LBU);old_id=req.data_id;tick();quiet();tick();
        offer(3,LBU);cancel[3]=1;#2;
        response(old_id,1,1);quiet();cancel='0;tick();
      end
      12:begin
        dtlb_hit=0;offer(3,LBU);incoming.is_speculative_load=1;
        branch.valid=1;branch.is_mispredict=0;tick();quiet();branch='0;tick();#2;
        if(!req.data_req)$fatal(1,"LOAD_CANCEL_CORRECT_RESOLVE_RELEASE");
        dtlb_hit=1;resp.data_gnt=1;#2;new_id=req.data_id;tick();quiet();tick();
        response(new_id,3,1);
      end
      // Precise misalignment: a LW at offset 2 is granted before its exception
      // is known, so the misaligned offset legitimately enters the load buffer.
      // The contract is that the load completes ONCE, with LD_ADDR_MISALIGNED
      // and the faulting address as tval, that its D$ request is killed, and
      // that the late data return never produces a second, data-carrying
      // completion.
      // The data cache answers a killed request with a dummy rvalid in the kill
      // cycle (wt_dcache_ctrl); an unkilled request returns its data later.
      13:begin
        resp.data_gnt=1;offer(3,LW);incoming.vaddr=64'h80001002;#2;
        if(!req.data_req)$fatal(1,"LOAD_MISALIGN_SETUP grant");
        old_id=req.data_id;tick();quiet();
        ex_in.valid=1;ex_in.cause=64'd4;ex_in.tval=64'h80001002;#1;
        killed=req.kill_req;
        resp.data_rvalid=killed;resp.data_rid=old_id;resp.data_rdata=64'hBAD0BAD0;#1;
        if(wb && !ex.valid)$fatal(1,"LOAD_MISALIGN_DATA_COMPLETION tid=%0d data=%h",tid,result);
        seen_ex=wb && ex.valid && ex.cause==64'd4 && ex.tval==64'h80001002 && tid==3'd3;
        tick();ex_in='0;resp.data_rvalid=0;#2;
        if(!killed)begin
          resp.data_rvalid=1;resp.data_rid=old_id;resp.data_rdata=64'hBAD0BAD0;#2;
          if(wb && !ex.valid)$fatal(1,"LOAD_MISALIGN_DATA_COMPLETION tid=%0d data=%h",tid,result);
          tick();resp.data_rvalid=0;#2;
        end
        if(seen_ex!==!negative)$fatal(1,"LOAD_MISALIGN_EXCEPTION seen=%b killed=%b",seen_ex,killed);
      end
      // Non-idempotent load at the commit head while the store buffer is NOT
      // empty. The speculative queue only ever holds stores younger than the
      // head, so under OoO the device read must proceed once the committed
      // queue has drained (nsp=1); waiting for the whole buffer deadlocks,
      // because those younger stores commit only after this load. Committed
      // stores still pending (nsp=0, the negative arm) must keep it waiting.
      // The in-order gate is untouched: it still waits for the whole buffer.
      // 14: committed queue drained (nsp=1): OoO requests, in-order still waits.
      // 15: committed stores pending (nsp=0): nobody requests.
      // The negative arm inverts the expectation.
      14,15:begin
        if(!NI)$fatal(1,"LOAD_NI_SCENARIO requires NI=1");
        // The IDLE request is speculative and is killed once the translation
        // shows a device page, so the observable is an unkilled tag phase.
        nsp=(scenario==14);resp.data_gnt=1;offer(0,LBU);
        killed=0;
        repeat(8)begin #2;if(req.tag_valid && !req.kill_req)killed=1;tick();end
        if(killed!==((OOO && nsp) ^ negative))$fatal(1,"LOAD_NI_HEAD_GATE tag=%b ooo=%0d nsp=%b",killed,OOO,nsp);
        $display("LOAD_CANCEL_PASS scenario=%0d ooo=%0d ni=1 requested=%b",scenario,OOO,killed);$finish;
      end
      16:begin
        if(!COH || !MMU)$fatal(1,"LOAD_PHYS_SCENARIO");
        dtlb_hit=0;match_page=1;fwd_valid=1;translated_pa=56'h90001000;
        offer(1,LBU);
        repeat(3)begin
          #2;
          if(wb || pop)$fatal(1,"LOAD_UNCERTIFIED_FORWARD");
          tick();quiet();
        end
        dtlb_hit=1;fwd_valid=0;match_page=0;resp.data_gnt=1;
        for(int n=0;n<8 && !req.data_req;n++)tick();
        if(!req.data_req)$fatal(1,"LOAD_PHYS_NO_PROGRESS");
        old_id=req.data_id;tick();quiet();tick();
        response(old_id,1,1);
      end
      17:begin
        translated_pa=56'h90002000;resp.data_gnt=1;
        offer(1,LBU);incoming.hart=1;incoming.vaddr=64'h40002000;#2;
        old_id=req.data_id;tick();
        offer(2,LD);incoming.hart=0;incoming.vaddr=64'h40005000;#2;
        if(!phys_valid || phys_id!=1 || phys_hart!=1 || phys_size!=0 ||
           (phys_addr ^ 56'(negative))!=56'h90002000)$fatal(1,"LOAD_PA_OWNER");
        new_id=req.data_id;tick();quiet();translated_pa=56'ha0005000;#2;
        if(!phys_valid || phys_id!=2 || phys_hart!=0 || phys_size!=3 ||
           phys_addr!=56'ha0005000)$fatal(1,"LOAD_PA_SUCCESSOR");
        tick();
        if(phys_valid)$fatal(1,"LOAD_PA_DUPLICATE");
        response(old_id,1,1);response(new_id,2,1,64'h12345666);
      end
      18:begin
        resp.data_gnt=1;offer(1,LBU);old_id=req.data_id;tick();
        offer(2,LBU);incoming.hart=1;cancel[1]=1;#2;
        if(phys_valid)$fatal(1,"LOAD_PA_CANCEL");
        new_id=req.data_id;tick();quiet();cancel='0;translated_pa=56'h90002000;#2;
        if(!phys_valid || phys_id!=2 || phys_hart!=1 || phys_addr!=56'h90002000)
          $fatal(1,"LOAD_PA_SUCCESSOR");
        tick();response(old_id,1,0);response(new_id,2,1);
      end
      19:begin
        resp.data_gnt=1;offer(1,LBU);incoming.hart=1;old_id=req.data_id;tick();
        offer(3,LBU);cancel[3]=1;#2;
        if(!phys_valid || phys_id!=1 || phys_hart!=1 || req.data_req)
          $fatal(1,"LOAD_PA_PEER_CANCEL");
        tick();quiet();cancel='0;response(old_id,1,1);
      end
      20:begin
        resp.data_gnt=1;offer(1,LBU);old_id=req.data_id;tick();quiet();
        ex_in.valid=1;ex_in.cause=5;#2;
        if(phys_valid || !req.kill_req)$fatal(1,"LOAD_PA_FAULT");
        resp.data_rvalid=1;resp.data_rid=old_id;#2;
        if(!wb || !ex.valid || tid!=1)$fatal(1,"LOAD_PA_FAULT_COMPLETION");
        tick();resp.data_rvalid=0;ex_in='0;
      end
      21:begin
        resp.data_gnt=1;offer(1,LBU);old_id=req.data_id;tick();quiet();
        flush=1;#2;
        if(phys_valid)$fatal(1,"LOAD_PA_FLUSH");
        tick();flush=0;tick();response(old_id,1,0);
      end
      default:$fatal(1,"LOAD_CANCEL_SCENARIO");
    endcase
    resp='0;match_page=0;repeat(2)tick();
    resp.data_gnt=1;offer(3,LBU);new_id=req.data_id;
    if(!req.data_req || !pop)$fatal(1,"LOAD_CANCEL_REUSE_ADMISSION");
    tick();quiet();tick();response(new_id,3,1);
    $display("LOAD_CANCEL_PASS scenario=%0d ooo=%0d",scenario,OOO);$finish;
  end
endmodule

module tb_g6lc_review_load_cancel_props (
  input logic clk_i,rst_ni,flush,request,pop,speculative,
  input logic [3:0] cancel,
  input logic [1:0] tid,
  input logic [7:0] payload,
  input logic branch_valid,branch_mispredict,
  output logic seen_cancel=0,seen_release=0,seen_drain=0
);
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.NR_SB_ENTRIES=4;c.TRANS_ID_BITS=2;c.OoOEn=1;return c;
  endfunction
  typedef struct packed {
    logic valid;fu_t fu;logic [1:0] trans_id;logic [7:0] payload;
    logic is_speculative_load,is_speculative_load_miss;
  } ctrl_t;
  typedef struct packed {logic valid,is_mispredict;} branch_t;
  ctrl_t incoming,head,expected;
  ctrl_t [1:0] reference_q,reference_d;
  logic [1:0] count_q=0,count_d;
  logic ready,past_valid=0;
  assign incoming='{valid:request,fu:LOAD,trans_id:tid,payload:payload,
                    is_speculative_load:speculative,is_speculative_load_miss:1'b0};
  lsu_bypass #(.CVA6Cfg(configuration()),.lsu_ctrl_t(ctrl_t),.bp_resolve_t(branch_t)) dut (
    .clk_i,.rst_ni,.flush_i(flush),.cancelled_mask_i(cancel),.lsu_req_i(incoming),
    .lsu_req_valid_i(request),.pop_ld_i(pop),.pop_st_i(1'b0),
    .resolved_branch_i({branch_valid,branch_mispredict}),.lsu_ctrl_o(head),.ready_o(ready));
  always_comb begin
    expected=count_q==0?incoming:reference_q[0];
    expected.is_speculative_load_miss |= expected.valid && cancel[expected.trans_id];
    reference_d=reference_q;count_d=count_q;
    if(pop && count_q!=0)begin reference_d[0]=reference_q[1];reference_d[1]='0;count_d--;end
    if(request && !(pop && count_q==0))begin
      reference_d[count_d[0]]=incoming;
      if(speculative && branch_valid && !branch_mispredict)
        reference_d[count_d[0]].is_speculative_load=0;
      count_d++;
    end
    for(int i=0;i<2;i++)
      if(i<int'(count_d) && cancel[reference_d[i].trans_id])reference_d[i].is_speculative_load_miss=1;
    if(flush)begin reference_d='0;count_d=0;end
  end
  always_ff @(posedge clk_i)begin
    past_valid<=1;
    if(!past_valid)assume(!rst_ni);else assume(rst_ni);
    if(!rst_ni)begin reference_q<='0;count_q<=0;end
    else begin
      assume(!request || count_q<2);
      assume(!pop || count_q!=0 || request);
      assert(count_q<=2);
      assert(ready==(count_q==0));
      if(expected.valid)assert(head==expected);else assert(!head.valid);
      reference_q<=reference_d;count_q<=count_d;
      if(expected.valid && cancel[expected.trans_id] && !pop && !flush)seen_cancel<=1;
      if(seen_cancel && expected.valid && expected.is_speculative_load_miss && !cancel[expected.trans_id])seen_release<=1;
      if(seen_release && pop && expected.valid && expected.is_speculative_load_miss && !flush)seen_drain<=1;
    end
  end
endmodule

module tb_g6lc_review_iq;
  import ariane_pkg::*;
  parameter int NP=2, DEPTH=8;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.NrIssuePorts=NP; c.NrWbPorts=2; c.NR_SB_ENTRIES=16; c.TRANS_ID_BITS=4;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {fu_t fu; fu_op op; logic [3:0] trans_id; logic hart_id; logic [31:0] pc;} sbe_t;
  typedef struct packed {sbe_t s; logic [31:0] orig; logic [3:0] p1,p2,pd; bit r1,r2;} entry_t;
  entry_t reference_q[$];
  logic clk=0,rst_n=0,flush=0,mem_stall=0,full;
  logic [15:0] cancel='0,st_unresolved='0,st_live='0;
  logic [3:0] commit_ptr='0;
  logic [NP-1:0] dv='0,da,iv,ia='0,r1='0,r2='0,bypass='0;
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
    .disp_fprs1_i('0),.disp_fprs2_i('0),.disp_fprs3_i('0),
    .disp_fpr_rs1_i('0),.disp_fpr_rs2_i('0),.disp_fpr_rs3_i('0),
    .disp_rs3_ready_i('1),.fwb_valid_i('0),.fwb_prd_i('0),
    .disp_rs1_ready_i(r1),.disp_rs2_ready_i(r2),.disp_may_bypass_i(bypass),.disp_ack_o(da),.full_o(full),
    .wb_valid_i(wv),.wb_prd_i(wp),
    .issue_sbe_o(is),.issue_orig_o(ii),.issue_prd_o(ip),.issue_valid_o(iv),.issue_ack_i(ia),.mem_stall_i(mem_stall),
    .st_live_mask_i(st_live),.st_unresolved_mask_i(st_unresolved),.st_hart_mask_i(st_live),.commit_ptr_i(commit_ptr),.sb_live_i('1));
  task automatic tick;
    clk=1; #2; clk=0; #2;
  endtask
  task automatic clear_inputs;
    flush=0;mem_stall=0;cancel='0;dv='0;ds='0;di='0;p1='0;p2='0;pd='0;r1='0;r2='0;wv='0;wp='0;bypass='0;
  endtask
  // Direct gate checks (scenarios 5-9): dispatch one entry, then read the
  // presented issue valid for it against the expected gate verdict.
  task automatic offer_op(input int id,input fu_t fu,input fu_op op,input bit may_bypass);
    dv[0]=1;ds[0]='{fu:fu,op:op,trans_id:4'(id),hart_id:1'b0,pc:32'h1000+32'(id)*4};
    di[0]=32'h13000000+32'(id);p1[0]=0;p2[0]=0;pd[0]=4'(id);r1[0]=1;r2[0]=1;bypass[0]=may_bypass;
    tick();clear_inputs();#2;
  endtask
  task automatic expect_issue(input bit want,input string tag);
    if(iv[0]!==(want^negative))$fatal(1,"%s iv=%b",tag,iv[0]);
    checked++;
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
            // Contract since the ack was taken out of the IQ's selection cone:
            // candidates are presented as a pure function of queue state, so a
            // non-acked port no longer stops the scan. Exactly the acked ports
            // are removed, for any ack pattern.
            if (ia[port]) remove_entry=1;
            port++;
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
    dv[port]=1;ds[port]='{fu:fu,op:ADD,trans_id:4'(id),hart_id:1'b0,pc:32'h1000+32'(id)*4};
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
      // A load behind an older UNRESOLVED store waits unless it may bypass;
      // once the store resolves the load goes.
      5:begin
        st_live[1]=1;st_unresolved[1]=1;
        offer_op(2,LOAD,LD,0);expect_issue(0,"IQ_UNRESOLVED_GATE");
        st_unresolved[1]=0;#2;expect_issue(1,"IQ_UNRESOLVED_GATE");
      end
      // The dispatch-time prediction lets the same load pass the unresolved store.
      6:begin
        st_live[1]=1;st_unresolved[1]=1;
        offer_op(2,LOAD,LD,1);expect_issue(1,"IQ_BYPASS");
      end
      // A RESOLVED older store never blocks a load: forwarding owns that case.
      7:begin
        st_live[1]=1;st_unresolved[1]=0;
        offer_op(2,LOAD,LD,0);expect_issue(1,"IQ_RESOLVED_PASS");
      end
      // A ready younger store issues ahead of an older not-ready store: the
      // dispatch-time slot reservation replaced program-order store issue.
      8:begin
        dv[0]=1;ds[0]='{fu:STORE,op:SD,trans_id:4'd1,hart_id:1'b0,pc:32'h1004};di[0]=32'h13000001;pd[0]=4'd1;r1[0]=0;r2[0]=1;
        tick();clear_inputs();
        offer_op(3,STORE,SD,0);expect_issue(1,"IQ_STORE_OOO");
        if(is[0].trans_id!==4'd3)$fatal(1,"IQ_STORE_OOO tid=%0d",is[0].trans_id);
      end
      // CSR accesses no longer wait for the commit head; fence-class system ops
      // still do.
      9:begin
        commit_ptr=4'd0;
        offer_op(3,CSR,CSR_WRITE,0);expect_issue(1,"IQ_CSR_HEAD");
        ia='1;tick();ia='0;#2;
        offer_op(5,CSR,SFENCE_VMA,0);expect_issue(0,"IQ_CSR_HEAD");
        commit_ptr=4'd5;#2;expect_issue(1,"IQ_CSR_HEAD");
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
  // Phase4: g6lc_rename is package-free, so the per-hart namespaces can be
  // exercised here at NR_HARTS=2 WITHOUT relaxing check_cfg's
  // !(OoOEn && NrHarts>1) refusal, which still governs the full core.
  // PRF must hold 31 committed physicals per hart plus a rename pool.
  parameter int unsigned NR_HARTS=1;
  // Phase5: the split FP class is exercised here at FPRF_ENTRIES>0, again
  // without relaxing check_cfg's !(OoOEn && FpPresent) refusal. FP needs 32
  // committed physicals per hart (f0 is real, so 32 not 31) plus a pool.
  parameter int unsigned FPRF_ENTRIES=0;
  parameter int unsigned FPRF_W=1;
  localparam int unsigned HID=(NR_HARTS<=1)?1:$clog2(NR_HARTS);
  logic clk=0,rst_n=0,flush=0,mispredict=0,enable=1;
  logic [NR_PORTS-1:0] is_fpr_rd='0,is_fpr_rs1='0,is_fpr_rs2='0,is_fpr_rs3='0;
  logic [NR_PORTS-1:0][4:0] rs3='0;
  logic [NR_PORTS-1:0][FPRF_W-1:0] fprs1,fprs2,fprs3,fprd,fprd_old;
  logic [NR_PORTS-1:0] rs3_rdy;
  logic [NR_WB-1:0] fwb_v='0;
  logic [NR_WB-1:0][FPRF_W-1:0] fwb_prd='0;
  logic [NR_FREE-1:0] ffr='0,cm_is_fpr='0;
  logic [NR_FREE-1:0][FPRF_W-1:0] ffr_prd='0,cm_fprd='0;
  logic [FPRF_W-1:0] f_first,f_mid,f_spec0,f_spec1;
  logic [NR_PORTS-1:0][HID-1:0] hid_p='0;
  logic [NR_FREE-1:0][HID-1:0] cm_hart='0;
  logic [NR_HARTS-1:0] fl_hart='0;
  logic [NR_PORTS-1:0] valid='0,need_rd='0,is_branch='0;
  logic [NR_PORTS-1:0][4:0] rs1='0,rs2='0,rd='0;
  logic [NR_PORTS-1:0][PRF_W-1:0] prs1,prs2,prd,prd_old;
  logic [NR_PORTS-1:0] rs1_rdy,rs2_rdy;
  logic stall;
  logic [NR_WB-1:0] wb_v='0;
  logic [NR_WB-1:0][PRF_W-1:0] wb_prd='0;
  logic [NR_FREE-1:0] fr='0;
  logic [NR_FREE-1:0] ckpt_ret='0;
  logic [NR_FREE-1:0] cm_v='0;
  logic [NR_FREE-1:0][4:0] cm_rd='0;
  logic [NR_FREE-1:0][PRF_W-1:0] cm_prd='0;
  logic [NR_FREE-1:0][PRF_W-1:0] fr_prd='0;
  int scenario;bit negative;
  logic [PRF_W-1:0] first_alloc,mid_alloc;
  logic [$clog2(CKPT_DEPTH+1)-1:0] mis_level='1;
  logic [NR_PORTS-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_id;
  g6lc_rename #(.PRF_ENTRIES(PRF_ENTRIES),.PRF_W(PRF_W),.NR_PORTS(NR_PORTS),
                .NR_FREE(NR_FREE),.NR_WB(NR_WB),.CKPT_DEPTH(CKPT_DEPTH),
                .NR_HARTS(NR_HARTS),
                .FPRF_ENTRIES(FPRF_ENTRIES),.FPRF_W(FPRF_W)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.flush_hart_i(fl_hart),
    .mispredict_i(mispredict),
    .mispredict_level_i(mis_level),
    .hart_i(hid_p),
    .is_fpr_rd_i(is_fpr_rd), .is_fpr_rs1_i(is_fpr_rs1), .is_fpr_rs2_i(is_fpr_rs2),
    .rs3_i(rs3), .is_fpr_rs3_i(is_fpr_rs3), .fprs3_o(fprs3), .rs3_ready_o(rs3_rdy),
    .fprs1_o(fprs1), .fprs2_o(fprs2), .fprd_o(fprd), .fprd_old_o(fprd_old),
    .fwb_valid_i(fwb_v), .fwb_prd_i(fwb_prd),
    .ffree_i(ffr), .ffree_prd_i(ffr_prd),
    .commit_is_fpr_i(cm_is_fpr), .commit_fprd_i(cm_fprd),
    .valid_i(valid),.rs1_i(rs1),.rs2_i(rs2),.rd_i(rd),.need_rd_i(need_rd),
    .is_branch_i(is_branch),.prs1_o(prs1),.prs2_o(prs2),.prd_o(prd),
    .prd_old_o(prd_old),.rs1_ready_o(rs1_rdy),.rs2_ready_o(rs2_rdy),
    .ckpt_id_o(ckpt_id),.ckpt_retire_i(ckpt_ret),.stall_o(stall),
    .commit_valid_i(cm_v),.commit_hart_i(cm_hart),.commit_rd_i(cm_rd),.commit_prd_i(cm_prd),
    .wb_valid_i(wb_v),.wb_prd_i(wb_prd),.free_i(fr),.free_prd_i(fr_prd),.enable_i(enable));
  always #5 clk=~clk;
  task automatic drive; @(negedge clk); endtask
  task automatic presample; #4; endtask
  task automatic idle; valid='0;need_rd='0;is_branch='0;wb_v='0;fr='0;ckpt_ret='0;cm_v='0;mispredict=0; endtask
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
      // A full flush must restore the COMMITTED mapping. Resetting to identity
      // claims architectural register i lives in physical register i, which
      // discards every committed value.
      9:begin
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd1;
        presample();first_alloc=prd[0];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();
        // r1's producer writes back and the instruction commits.
        drive();wb_v[0]=1'b1;wb_prd[0]=first_alloc;
        drive();idle();cm_v[0]=1'b1;cm_rd[0]=5'd1;cm_prd[0]=first_alloc;
        drive();idle();
        drive();flush=1;
        drive();flush=0;idle();
        drive();valid=2'b01;rs1[0]=5'd1;
        presample();
        if(prs1[0]!==(negative?PRF_W'(1):first_alloc))
          $fatal(1,"RENAME_FLUSH_ARCH got=%0d want=%0d",prs1[0],first_alloc);
        // and the committed register must not be handed out again.
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd2;
        presample();
        if(prd[0]===first_alloc)
          $fatal(1,"RENAME_FLUSH_FREE reissued committed phys %0d",prd[0]);
      end
      // A register that was LIVE at the checkpoint, freed afterwards by an OLDER
      // instruction committing, and then reallocated to younger work must be
      // returned by recovery. A free-list snapshot cannot express that: the
      // register is absent from it, so it leaks permanently.
      10:begin
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd1;   // I0: r1 -> a0
        presample();first_alloc=prd[0];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd1;  // I1: r1 -> b0
        presample();
        if(prd_old[0]!==first_alloc)$fatal(1,"RENAME_OLD_TAG old=%0d",prd_old[0]);
        drive();idle();valid=2'b01;is_branch=2'b01;     // branch -> ckpt 0
        drive();idle();
        // I1 is OLDER than the branch and commits, freeing a0.
        drive();fr[0]=1'b1;fr_prd[0]=first_alloc;
        drive();idle();
        // Younger work reallocates a0.
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd2;
        presample();mid_alloc=prd[0];
        if(mid_alloc!==first_alloc)$fatal(1,"RENAME_NO_REALLOC got=%0d want=%0d",mid_alloc,first_alloc);
        drive();idle();
        drive();mispredict=1;mis_level=2'd0;
        drive();idle();mis_level='1;
        // Recovery discarded that younger allocation, so a0 must be free again.
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd3;
        presample();
        if(prd[0]!==(negative?PRF_W'(0):first_alloc))
          $fatal(1,"RENAME_CKPT_ALLOC_LEAK got=%0d want=%0d",prd[0],first_alloc);
      end
      // ---- Phase4 per-hart namespaces (require -GNR_HARTS=2) --------------
      // 1. Namespace isolation: both harts write their OWN x5 and must read
      //    back their own physical. A single shared map aliases them, which is
      //    precisely what the OoO+SMT elaboration guard exists to refuse.
      11:begin
        if(NR_HARTS<2)$fatal(1,"RENAME_NEEDS_NR_HARTS2");
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd5;hid_p[0]=0;
        presample();first_alloc=prd[0];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd5;hid_p[0]=1;
        presample();mid_alloc=prd[0];
        if(mid_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        if(mid_alloc==first_alloc)$fatal(1,"RENAME_HART_SAME_PHYS p=%0d",mid_alloc);
        // Hart 0 must still see its own mapping, not hart 1's.
        drive();idle();rs1[0]=5'd5;valid=2'b01;hid_p[0]=0;
        presample();
        if(prs1[0]!==(negative?mid_alloc:first_alloc))
          $fatal(1,"RENAME_HART_ALIAS hart0 got=%0d want=%0d",prs1[0],first_alloc);
        drive();idle();rs1[0]=5'd5;valid=2'b01;hid_p[0]=1;
        presample();
        if(prs1[0]!==mid_alloc)
          $fatal(1,"RENAME_HART_ALIAS hart1 got=%0d want=%0d",prs1[0],mid_alloc);
      end
      // 2. Independent recovery: hart 1 mispredicts; hart 0's rename survives.
      //    A shared checkpoint ring or a hart-agnostic ckpt_alloc would squash
      //    hart 0's allocation here.
      12:begin
        if(NR_HARTS<2)$fatal(1,"RENAME_NEEDS_NR_HARTS2");
        // hart1 takes a branch (its own checkpoint)
        drive();valid=2'b01;is_branch=2'b01;hid_p[0]=1;
        drive();idle();
        // hart0 allocates AFTER that branch
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd7;hid_p[0]=0;
        presample();first_alloc=prd[0];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();
        drive();mispredict=1;
        drive();idle();rs1[0]=5'd7;valid=2'b01;hid_p[0]=0;
        presample();
        if(prs1[0]!==(negative?PRF_W'(0):first_alloc))
          $fatal(1,"RENAME_PEER_SQUASHED got=%0d want=%0d",prs1[0],first_alloc);
      end
      // 3. Per-hart flush reclaims exactly that hart's physicals: hart 1's
      //    uncommitted rename is reset to its architectural map while hart 0's
      //    speculative rename stays live.
      13:begin
        if(NR_HARTS<2)$fatal(1,"RENAME_NEEDS_NR_HARTS2");
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd9;hid_p[0]=0;
        presample();first_alloc=prd[0];
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd9;hid_p[0]=1;
        presample();mid_alloc=prd[0];
        drive();idle();fl_hart=2'b10;
        drive();idle();fl_hart='0;
        // hart1 is back to its reset identity for x9 (not its flushed rename)
        drive();idle();rs1[0]=5'd9;valid=2'b01;hid_p[0]=1;
        presample();
        if(prs1[0]===mid_alloc)
          $fatal(1,"RENAME_HART_FLUSH_KEPT hart1 still maps %0d",mid_alloc);
        // hart0's speculative rename must be untouched by the peer's flush
        drive();idle();rs1[0]=5'd9;valid=2'b01;hid_p[0]=0;
        presample();
        if(prs1[0]!==(negative?PRF_W'(0):first_alloc))
          $fatal(1,"RENAME_HART_FLUSH_SPILL hart0 got=%0d want=%0d",prs1[0],first_alloc);
      end
      // ---- Phase5 split FP register class (require -GFPRF_ENTRIES>0) -------
      // 20. Class isolation: x5 and f5 share an architectural NUMBER but are
      //     different registers. An integer producer of x5 must not satisfy an
      //     FP consumer of f5, and the two must map to different files.
      20:begin
        if(FPRF_ENTRIES<32)$fatal(1,"RENAME_NEEDS_FPRF");
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd5;
        presample();first_alloc=prd[0];
        if(first_alloc==0)$fatal(1,"RENAME_NO_ALLOC");
        drive();idle();valid=2'b01;need_rd=2'b01;rd[0]=5'd5;is_fpr_rd=2'b01;
        presample();f_first=fprd[0];
        drive();idle();is_fpr_rd='0;
        // integer x5 must still read its own physical
        drive();idle();rs1[0]=5'd5;valid=2'b01;
        presample();
        if(prs1[0]!==first_alloc)
          $fatal(1,"RENAME_FP_CLASS int x5 got=%0d want=%0d",prs1[0],first_alloc);
        // FP f5 must read the FP physical, from the FP file
        drive();idle();rs1[0]=5'd5;valid=2'b01;is_fpr_rs1=2'b01;
        presample();
        if(fprs1[0]!==(negative?FPRF_W'(0):f_first))
          $fatal(1,"RENAME_FP_CLASS fp f5 got=%0d want=%0d",fprs1[0],f_first);
        if(rs1_rdy[0]!==1'b0)$fatal(1,"RENAME_FP_BUSY rdy=%b",rs1_rdy[0]);
      end
      // 21. f0 is an ordinary register: unlike x0 it must be renamed, tracked
      //     busy and read back. The integer path's rd!=0 filters must not have
      //     leaked into the FP path.
      21:begin
        if(FPRF_ENTRIES<32)$fatal(1,"RENAME_NEEDS_FPRF");
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd0;is_fpr_rd=2'b01;
        presample();f_first=fprd[0];
        drive();idle();rs1[0]=5'd0;valid=2'b01;is_fpr_rs1=2'b01;
        presample();
        if(fprs1[0]!==(negative?FPRF_W'(1):f_first))
          $fatal(1,"RENAME_FP_F0 got=%0d want=%0d",fprs1[0],f_first);
        // and it must be busy: an FP consumer of f0 waits for its producer
        if(rs1_rdy[0]!==1'b0)$fatal(1,"RENAME_FP_F0_BUSY rdy=%b",rs1_rdy[0]);
      end
      // 22. FP recovery: a branch checkpoints BOTH maps, so an FP rename made
      //     after the branch is undone and the pre-branch FP mapping returns.
      22:begin
        if(FPRF_ENTRIES<32)$fatal(1,"RENAME_NEEDS_FPRF");
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd7;is_fpr_rd=2'b01;
        presample();f_first=fprd[0];
        drive();idle();valid=2'b01;is_branch=2'b01;
        drive();idle();
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd7;is_fpr_rd=2'b01;
        presample();f_mid=fprd[0];
        if(f_mid==f_first)$fatal(1,"RENAME_FP_SETUP realloc matched");
        drive();idle();
        drive();mispredict=1;
        drive();idle();rs1[0]=5'd7;valid=2'b01;is_fpr_rs1=2'b01;
        presample();
        if(fprs1[0]!==(negative?f_mid:f_first))
          $fatal(1,"RENAME_FP_RECOVER got=%0d want=%0d",fprs1[0],f_first);
      end
      // 23. rs3 renames from the FP map, and an FP writeback clears busy for
      //     FP physical 0 as for any other (no rd!=0 guard on that path).
      23:begin
        if(FPRF_ENTRIES<32)$fatal(1,"RENAME_NEEDS_FPRF");
        drive();valid=2'b01;need_rd=2'b01;rd[0]=5'd9;is_fpr_rd=2'b01;
        presample();f_first=fprd[0];
        drive();idle();rs3[0]=5'd9;valid=2'b01;is_fpr_rs3=2'b01;
        presample();
        if(fprs3[0]!==(negative?FPRF_W'(0):f_first))
          $fatal(1,"RENAME_FP_RS3 got=%0d want=%0d",fprs3[0],f_first);
        if(rs3_rdy[0]!==1'b0)$fatal(1,"RENAME_FP_RS3_BUSY rdy=%b",rs3_rdy[0]);
        // writeback releases it
        drive();idle();fwb_v[0]=1;fwb_prd[0]=f_first;
        drive();idle();rs3[0]=5'd9;valid=2'b01;is_fpr_rs3=2'b01;
        presample();
        if(rs3_rdy[0]!==1'b1)$fatal(1,"RENAME_FP_RS3_WB still busy");
      end
      14,15:begin
        if(NR_HARTS!=2)$fatal(1,"RENAME_HART_SETUP");
        drive();valid=1;need_rd=1;rd[0]=1;hid_p[0]=scenario==14?0:1;
        presample();first_alloc=prd[0];mid_alloc=prd_old[0];
        drive();idle();wb_v=1;wb_prd[0]=first_alloc;
        cm_v=1;cm_hart[0]=hid_p[0];cm_rd[0]=1;cm_prd[0]=first_alloc;
        fr=1;fr_prd[0]=mid_alloc;
        drive();idle();valid=1;need_rd=1;rd[0]=2;
        hid_p[0]=scenario==14?1:0;fl_hart=scenario==14?1:2;
        presample();if(prd[0]!=mid_alloc)$fatal(1,"RENAME_HART_SETUP reuse");
        drive();idle();fl_hart=0;valid=1;rs1[0]=2;
        presample();
        if(prs1[0]!=mid_alloc||rs1_rdy[0]!==negative)
          $fatal(1,"RENAME_HART_REALLOC_FLUSH tag=%0d ready=%b",prs1[0],rs1_rdy[0]);
        drive();idle();valid=1;need_rd=1;rd[0]=3;
        presample();if(prd[0]==mid_alloc)$fatal(1,"RENAME_HART_REALLOC_FREE");
      end
      24,25:begin
        if(NR_HARTS!=2||FPRF_ENTRIES<68)$fatal(1,"RENAME_FP_HART_SETUP");
        drive();valid=3;need_rd=3;is_fpr_rd=3;rd='0;hid_p[0]=0;hid_p[1]=1;
        presample();f_first=fprd[0];f_mid=fprd[1];
        if(f_first==f_mid)$fatal(1,"RENAME_FP_HART_SETUP alias");
        drive();idle();fwb_v=3;fwb_prd[0]=f_first;fwb_prd[1]=f_mid;
        drive();idle();fwb_v=0;cm_v=3;cm_is_fpr=3;cm_rd='0;
        cm_hart[0]=0;cm_hart[1]=1;cm_fprd[0]=f_first;cm_fprd[1]=f_mid;
        ffr=3;ffr_prd[0]=0;ffr_prd[1]=32;
        drive();idle();ffr=0;cm_is_fpr=0;
        valid=3;need_rd=3;is_fpr_rd=3;rd='0;hid_p[0]=0;hid_p[1]=1;
        presample();f_spec0=fprd[0];f_spec1=fprd[1];
        drive();idle();is_fpr_rd=0;fl_hart=scenario==24?1:2;
        drive();idle();fl_hart=0;valid=3;is_fpr_rs1=3;rs1='0;
        presample();
        if(fprs1[0]!=(scenario==24?f_first:f_spec0)||
           fprs1[1]!=(scenario==25?f_mid:f_spec1)||negative)
          $fatal(1,"RENAME_FP_HART_FLUSH_MAP h0=%0d h1=%0d",fprs1[0],fprs1[1]);
        if(rs1_rdy!=(scenario==24?2'b01:2'b10))$fatal(1,"RENAME_FP_HART_FLUSH_BUSY");
        drive();idle();is_fpr_rs1=0;valid=1;need_rd=1;is_fpr_rd=1;
        hid_p[0]=scenario==24?0:1;rd[0]=9;
        presample();
        if(fprd[0]!=(scenario==24?f_spec0:f_spec1))$fatal(1,"RENAME_FP_HART_FLUSH_FREE");
      end
      default:$fatal(1,"RENAME_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS rename scenario=%0d",scenario);$finish;
  end
endmodule

// Bisect fixture: drives g6lc_lsq directly with an explicit allocation id, so a
// failure here isolates the LSQ itself rather than the dispatch id plumbing.
// Per-tid CSR address table (T2). Under OoOEn a CSR access issues whenever a
// table entry is free and its address is looked up by the COMMITTING tid, so
// two CSRs may issue out of program order and still commit their own
// addresses in order; ready is a table credit, not a whole-FLU freeze. With
// OoOEn clear the module is the historical depth-1 buffer.
module tb_g6lc_review_csrbuf;
  import ariane_pkg::*;
  parameter bit OOO=1;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.NR_SB_ENTRIES=8;c.TRANS_ID_BITS=3;c.OoOEn=OOO;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {logic [2:0] trans_id;logic [63:0] operand_a,operand_b;} fu_t2;
  logic clk=0,rst_n=0,flush=0,valid=0,commit=0,ready;
  logic [2:0] commit_tid='0;
  logic [7:0] cancel='0;
  logic [11:0] addr;
  logic [63:0] result;
  fu_t2 data='0;
  int scenario;bit negative;
  always #5 clk=~clk;
  csr_buffer #(.CVA6Cfg(C),.fu_data_t(fu_t2)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.cancelled_mask_i(cancel),.fu_data_i(data),
    .csr_ready_o(ready),.csr_valid_i(valid),.csr_result_o(result),
    .csr_commit_i(commit),.csr_commit_tid_i(commit_tid),.csr_addr_o(addr));
  task automatic drive;@(negedge clk);endtask
  // Ready is sampled before the request is presented, as issue does: the
  // in-order buffer drops ready in the very cycle it accepts a CSR.
  task automatic issue(input logic [2:0] tid,input logic [11:0] a);
    #1;if(!ready)$fatal(1,"CSRBUF_NOT_READY tid=%0d",tid);
    data.trans_id=tid;data.operand_b=64'(a);data.operand_a=64'h100+64'(tid);valid=1;
    drive();valid=0;
  endtask
  task automatic retire(input logic [2:0] tid,input logic [11:0] want,input string tag);
    commit=1;commit_tid=tid;#1;
    if(addr!==(want^(negative?12'd1:12'd0)))$fatal(1,"%s tid=%0d addr=%h want=%h",tag,tid,addr,want);
    drive();commit=0;
  endtask
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(2)drive();rst_n=1;drive();
    case(scenario)
      // Two CSRs issue younger-first; each commits its own address in program
      // order.
      0:begin
        issue(3'd5,12'h300);issue(3'd3,12'h305);
        retire(3'd3,12'h305,"CSRBUF_ADDR");retire(3'd5,12'h300,"CSRBUF_ADDR");
        #1;if(!ready)$fatal(1,"CSRBUF_ADDR ready after drain");
      end
      // Ready is the table credit: two outstanding entries deassert it, one
      // commit restores it.
      1:begin
        issue(3'd1,12'h300);issue(3'd2,12'h301);#1;
        if(ready!==negative)$fatal(1,"CSRBUF_READY full ready=%b",ready);
        retire(3'd1,12'h300,"CSRBUF_READY");#1;
        if(!ready)$fatal(1,"CSRBUF_READY after commit ready=%b",ready);
      end
      // A cancelled CSR leaves the table without a commit and frees its credit.
      2:begin
        issue(3'd1,12'h300);issue(3'd2,12'h301);
        cancel=8'h04;drive();cancel='0;#1;
        if(ready!==!negative)$fatal(1,"CSRBUF_CANCEL ready=%b",ready);
        retire(3'd1,12'h300,"CSRBUF_CANCEL");
      end
      // Full flush empties the table.
      3:begin
        issue(3'd1,12'h300);issue(3'd2,12'h301);
        flush=1;drive();flush=0;#1;
        if(ready!==!negative)$fatal(1,"CSRBUF_FLUSH ready=%b",ready);
        issue(3'd4,12'h302);retire(3'd4,12'h302,"CSRBUF_FLUSH");
      end
      // In-order identity: one uncommitted CSR holds ready low until commit.
      4:begin
        issue(3'd1,12'h300);#1;
        if(ready!==negative)$fatal(1,"CSRBUF_INORDER ready=%b",ready);
        retire(3'd1,12'h300,"CSRBUF_INORDER");#1;
        if(!ready)$fatal(1,"CSRBUF_INORDER ready after commit");
      end
      default:$fatal(1,"CSRBUF_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS csrbuf scenario=%0d",scenario);$finish;
  end
endmodule

module tb_g6lc_review_lsq;
  import ariane_pkg::*;
  // T6b hart-tag cell: HARTS=1 reproduces the single-hart geometry; HARTS=2
  // runs the same scenarios on hart 0 plus the cross-hart suite 19-24.
  parameter int unsigned HARTS=1;
  parameter bit PHYS=0;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.NrHarts=HARTS;c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;c.NrWbPorts=2;
    c.CohPolicy=PHYS ? config_pkg::COH_OOO : config_pkg::COH_WRITE_INVAL;
    if(PHYS)begin
      c.NonIdemPotenceEn=1;c.NrNonIdempotentRules=1;
      c.NonIdempotentAddrBase[0]=64'he000;c.NonIdempotentLength[0]=64'h1000;
    end
    c.DCACHE_LINE_WIDTH=128;
    c.NrCommitPorts=2;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  logic clk=0,rst_n=0;
  logic [1:0] ld_alloc='0,st_alloc='0,addr_v='0,addr_is_st='0,st_data_v='0,cmpl_v='0,cmpl_st='0;
  logic [1:0][3:0] alloc_id='0,addr_id='0,st_data_id='0,cmpl_id='0;
  logic [1:0] alloc_hart='0;
  logic [1:0][55:0] addr='0;
  logic [1:0][1:0] addr_size='0;
  logic [1:0][63:0] st_data='0;
  logic [1:0] commit_st='0;
  logic [1:0][3:0] commit_id='0;
  logic ld_query=0;
  logic [55:0] ld_addr='0;
  logic [1:0] ld_size=2'b11;
  logic [3:0] ld_id='0,commit_ptr='0;
  logic ld_hart='0;
  logic flush='0;
  logic [15:0] cancel_mask='0;
  logic pend,fwd,stall,busy,ldf,stf,viol;
  logic [2:0] ldfree,stfree;
  logic [15:0] st_mask,st_unresolved;
  logic [HARTS-1:0][15:0] st_hart_mask;
  logic [63:0] fwd_data;
  logic [3:0] viol_id;
  logic [1:0] pv='0,ph='0,mv='0,commit_ld='0;
  logic [1:0][3:0] pid='0;
  logic [1:0][55:0] pa='0,ma='0;
  logic [1:0][1:0] psz='0;
  logic [15:0] ppending,preplay;
  int scenario;bit negative;
  g6lc_lsq #(.CVA6Cfg(C),.LD_ENTRIES(4),.ST_ENTRIES(4),.NR_ALLOC(2),.NR_UPDATE(2)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.cancelled_mask_i(cancel_mask),.sb_live_i('1),
    .ld_alloc_i(ld_alloc),.st_alloc_i(st_alloc),.alloc_id_i(alloc_id),.alloc_hart_i(alloc_hart),
    .alloc_pc_i('0),
    .ld_full_o(ldf),.st_full_o(stf),.ld_free_o(ldfree),.st_free_o(stfree),
    .addr_valid_i(addr_v),.addr_id_i(addr_id),.addr_i(addr),
    .addr_is_st_i(addr_is_st),.addr_size_i(addr_size),
    .st_data_valid_i(st_data_v),.st_data_id_i(st_data_id),.st_data_i(st_data),
    .complete_valid_i(cmpl_v),.complete_id_i(cmpl_id),.complete_is_st_i(cmpl_st),
    .commit_st_i(commit_st),.commit_id_i(commit_id),.commit_ptr_i(commit_ptr),
    .ld_query_i(ld_query),.ld_query_addr_i(ld_addr),.ld_query_size_i(ld_size),
    .ld_query_id_i(ld_id),.ld_query_hart_i(ld_hart),
    .st_live_mask_o(st_mask),.st_unresolved_mask_o(st_unresolved),
    .st_hart_mask_o(st_hart_mask),.store_pending_o(pend),.stl_forward_o(fwd),
    .stl_data_o(fwd_data),.stl_stall_o(stall),.lsq_busy_o(busy),
    .mem_violation_o(viol),.mem_violation_id_o(viol_id),.mem_violation_pc_o(),
    .phys_valid_i(pv),.phys_addr_i(pa),.phys_id_i(pid),.phys_hart_i(ph),.phys_size_i(psz),
    .mod_valid_i(mv),.mod_addr_i(ma),.commit_ld_i(commit_ld),
    .phys_pending_o(ppending),.phys_replay_o(preplay));
  // Same clocking discipline as the dispatch fixture: free-running clock, drive
  // on the falling edge, sample after the rising edge settles.
  always #5 clk = ~clk;
  task automatic drive; @(negedge clk); endtask
  task automatic presample; #4; endtask
  // Alias-validation stimulus: a load whose address is already known, then a
  // store address arriving on port 0. The load's address may arrive on port 1
  // in the same cycle as the store when same_cycle is set.
  task automatic resolve_load(input logic [3:0] id,input logic [55:0] a,input logic [1:0] sz);
    addr_v=2'b01;addr_is_st=2'b00;addr_id[0]=id;addr[0]=a;addr_size[0]=sz;
    drive();addr_v='0;addr_id='0;addr='0;addr_size='0;
  endtask
  task automatic resolve_store(input logic [3:0] id,input logic [55:0] a,input logic [1:0] sz,
                               input bit same_cycle=0,input logic [3:0] ld=4'd0,
                               input logic [55:0] la=56'd0,input logic [1:0] lsz=2'b11);
    addr_v=same_cycle?2'b11:2'b01;addr_is_st=2'b01;addr_id[0]=id;addr[0]=a;addr_size[0]=sz;
    if(same_cycle)begin addr_id[1]=ld;addr[1]=la;addr_size[1]=lsz;end
  endtask
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(3) drive();
    rst_n=1;
    drive();
    case(scenario)
      // A store's entry is the reservation of its speculative-queue slot: its
      // writeback completion keeps the entry, and only its commit (matched by
      // id) releases it.
      0:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;
        drive();st_alloc='0;alloc_id='0;
        presample();
        if(!pend)$fatal(1,"LSQ_ALLOC pend=%b",pend);
        if(st_mask!==16'h0002)$fatal(1,"LSQ_LIVE_MASK got=%h want=0002",st_mask);
        drive();cmpl_v=2'b01;cmpl_st=2'b01;cmpl_id[0]=4'd1;
        drive();cmpl_v='0;cmpl_st='0;cmpl_id='0;
        presample();
        if(pend!==(negative?1'b0:1'b1))$fatal(1,"LSQ_WB_RETIRE pend=%b",pend);
        commit_st=2'b01;commit_id[0]=4'd1;
        drive();commit_st='0;commit_id='0;
        presample();
        if(pend)$fatal(1,"LSQ_COMMIT_RELEASE pend=%b",pend);
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
      // Alias validation: the load (tid 2) resolved before the OLDER store
      // (tid 1) whose bytes it overlaps, so its value may be stale. The scan
      // must report the load in the cycle the store address arrives.
      12:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;ld_alloc=2'b10;alloc_id[1]=4'd2;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;
        resolve_load(4'd2,56'h2000,2'b11);
        presample();
        if(viol)$fatal(1,"LSQ_VIOLATION_EARLY");
        resolve_store(4'd1,56'h2000,2'b11);
        presample();
        if(viol!==(negative?1'b0:1'b1)||(viol&&viol_id!==4'd2))
          $fatal(1,"LSQ_VIOLATION viol=%b id=%0d",viol,viol_id);
        addr_v='0;
      end
      // A YOUNGER store (tid 3) resolving after the load (tid 2) is program
      // order, not a violation.
      13:begin
        ld_alloc=2'b01;alloc_id[0]=4'd2;st_alloc=2'b10;alloc_id[1]=4'd3;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;
        resolve_load(4'd2,56'h2000,2'b11);
        resolve_store(4'd3,56'h2000,2'b11);
        presample();
        if(viol!==(negative?1'b1:1'b0))$fatal(1,"LSQ_VIOLATION_YOUNGER viol=%b",viol);
        addr_v='0;
      end
      // Wraparound: commit_ptr=14, store tid 15 is OLDER than load tid 0.
      14:begin
        commit_ptr=4'd14;
        st_alloc=2'b01;alloc_id[0]=4'd15;ld_alloc=2'b10;alloc_id[1]=4'd0;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;
        resolve_load(4'd0,56'h2008,2'b11);
        resolve_store(4'd15,56'h2008,2'b11);
        presample();
        if(viol!==(negative?1'b0:1'b1)||(viol&&viol_id!==4'd0))
          $fatal(1,"LSQ_VIOLATION_WRAP viol=%b id=%0d",viol,viol_id);
        addr_v='0;commit_ptr='0;
      end
      // Two resolved loads (tids 2 and 3) overlap the store (tid 1): the OLDEST
      // offending load is reported, because replaying it squashes the other.
      15:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;ld_alloc=2'b10;alloc_id[1]=4'd2;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;
        ld_alloc=2'b01;alloc_id[0]=4'd3;
        drive();ld_alloc='0;alloc_id='0;
        resolve_load(4'd3,56'h2000,2'b11);
        resolve_load(4'd2,56'h2000,2'b11);
        resolve_store(4'd1,56'h2000,2'b11);
        presample();
        if(!viol||viol_id!==(negative?4'd3:4'd2))
          $fatal(1,"LSQ_VIOLATION_OLDEST viol=%b id=%0d",viol,viol_id);
        addr_v='0;
      end
      // Byte-disjoint in the same word: SB at 0x2000 versus LH at 0x2002.
      16:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;ld_alloc=2'b10;alloc_id[1]=4'd2;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;
        resolve_load(4'd2,56'h2002,2'b01);
        resolve_store(4'd1,56'h2000,2'b00);
        presample();
        if(viol!==(negative?1'b1:1'b0))$fatal(1,"LSQ_VIOLATION_DISJOINT viol=%b",viol);
        addr_v='0;
      end
      // Same cycle: the load address (port 1) and the older store address
      // (port 0) arrive together; the load has still read before the store
      // was visible, so it is a violation.
      17:begin
        st_alloc=2'b01;alloc_id[0]=4'd1;ld_alloc=2'b10;alloc_id[1]=4'd2;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;
        resolve_store(4'd1,56'h2000,2'b11,1,4'd2,56'h2000,2'b11);
        presample();
        if(viol!==(negative?1'b0:1'b1)||(viol&&viol_id!==4'd2))
          $fatal(1,"LSQ_VIOLATION_SAMECYCLE viol=%b id=%0d",viol,viol_id);
        addr_v='0;
      end
      // The unresolved mask names only stores whose address is unknown: store 1
      // resolves, store 3 does not, and both stay live until commit.
      18:begin
        st_alloc=2'b11;alloc_id[0]=4'd1;alloc_id[1]=4'd3;
        drive();st_alloc='0;alloc_id='0;
        presample();
        if(st_unresolved!==16'h000A)$fatal(1,"LSQ_UNRESOLVED_MASK got=%h want=000a",st_unresolved);
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd1;addr[0]=56'h2000;addr_size[0]=2'b11;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        presample();
        if(st_unresolved!==(negative?16'h000A:16'h0008))
          $fatal(1,"LSQ_UNRESOLVED_MASK got=%h want=0008",st_unresolved);
        if(st_mask!==16'h000A)$fatal(1,"LSQ_UNRESOLVED_LIVE got=%h want=000a",st_mask);
      end
      // ---- T6b hart-tag scenarios (HARTS=2 only) ----
      // L-A: a peer hart's unresolved older store must not stall or forward
      // to this hart's load — peer stores become visible only at commit.
      19:begin
        if(HARTS!=2)$fatal(1,"LSQ_HART_SETUP");
        st_alloc=2'b01;alloc_id[0]=4'd1;alloc_hart[0]=1'b0;
        drive();st_alloc='0;alloc_id='0;alloc_hart='0;
        ld_query=1;ld_addr=56'h2000;ld_id=4'd2;ld_hart=1'b1;
        presample();
        if(stall!==negative||fwd)
          $fatal(1,"LSQ_HART_PEER_STALL fwd=%b stall=%b",fwd,stall);
        ld_query=0;ld_hart='0;
      end
      // L-B: the same-hart unresolved older store still stalls.
      20:begin
        if(HARTS!=2)$fatal(1,"LSQ_HART_SETUP");
        st_alloc=2'b01;alloc_id[0]=4'd1;alloc_hart[0]=1'b1;
        drive();st_alloc='0;alloc_id='0;alloc_hart='0;
        ld_query=1;ld_addr=56'h2000;ld_id=4'd2;ld_hart=1'b1;
        presample();
        if(stall!==!negative||fwd)
          $fatal(1,"LSQ_HART_OWN_STALL fwd=%b stall=%b",fwd,stall);
        ld_query=0;ld_hart='0;
      end
      // L-C: a resolved peer store does not forward to this hart; the same
      // store does forward to its own hart's load.
      21:begin
        if(HARTS!=2)$fatal(1,"LSQ_HART_SETUP");
        st_alloc=2'b01;alloc_id[0]=4'd1;alloc_hart[0]=1'b0;
        drive();st_alloc='0;alloc_id='0;alloc_hart='0;
        addr_v=2'b01;addr_is_st=2'b01;addr_id[0]=4'd1;addr[0]=56'h2000;addr_size[0]=2'b11;
        drive();addr_v='0;addr_is_st='0;addr_id='0;
        st_data_v=2'b01;st_data_id[0]=4'd1;st_data[0]=64'hDDDD;
        drive();st_data_v='0;st_data_id='0;
        ld_query=1;ld_addr=56'h2000;ld_id=4'd2;ld_hart=1'b1;
        presample();
        if((fwd||stall)!==(negative?1'b1:1'b0))
          $fatal(1,"LSQ_HART_PEER_FWD fwd=%b stall=%b",fwd,stall);
        ld_hart=1'b0;
        presample();
        if(!fwd||stall||fwd_data!==64'hDDDD)
          $fatal(1,"LSQ_HART_OWN_FWD fwd=%b stall=%b data=%h",fwd,stall,fwd_data);
        ld_query=0;ld_hart='0;
      end
      // L-D: an OLDER peer-hart store resolving after this hart's load read is
      // no memory-order violation — the queues are per-hart ordered.
      22:begin
        if(HARTS!=2)$fatal(1,"LSQ_HART_SETUP");
        st_alloc=2'b01;alloc_id[0]=4'd1;alloc_hart[0]=1'b0;
        ld_alloc=2'b10;alloc_id[1]=4'd2;alloc_hart[1]=1'b1;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;alloc_hart='0;
        resolve_load(4'd2,56'h2000,2'b11);
        resolve_store(4'd1,56'h2000,2'b11);
        presample();
        if(viol!==negative)$fatal(1,"LSQ_HART_PEER_VIOL viol=%b",viol);
        addr_v='0;
      end
      // L-E: the same-hart older store resolving late still reports the
      // violation against the load that already read.
      23:begin
        if(HARTS!=2)$fatal(1,"LSQ_HART_SETUP");
        st_alloc=2'b01;alloc_id[0]=4'd1;alloc_hart[0]=1'b1;
        ld_alloc=2'b10;alloc_id[1]=4'd2;alloc_hart[1]=1'b1;
        drive();st_alloc='0;ld_alloc='0;alloc_id='0;alloc_hart='0;
        resolve_load(4'd2,56'h2000,2'b11);
        resolve_store(4'd1,56'h2000,2'b11);
        presample();
        if(viol!==!negative||(viol&&viol_id!==4'd2))
          $fatal(1,"LSQ_HART_OWN_VIOL viol=%b id=%0d",viol,viol_id);
        addr_v='0;
      end
      // L-F: the unresolved mask is global; the per-hart masks partition it.
      24:begin
        if(HARTS!=2)$fatal(1,"LSQ_HART_SETUP");
        st_alloc=2'b01;alloc_id[0]=4'd2;alloc_hart[0]=1'b0;
        drive();st_alloc='0;alloc_id='0;alloc_hart='0;
        st_alloc=2'b01;alloc_id[0]=4'd5;alloc_hart[0]=1'b1;
        drive();st_alloc='0;alloc_id='0;alloc_hart='0;
        presample();
        if(st_unresolved!==(negative?16'hFFFF:16'h0024))
          $fatal(1,"LSQ_HART_MASK unresolved=%h want=0024",st_unresolved);
        if(st_hart_mask[0]!==16'h0004||st_hart_mask[1]!==16'h0020)
          $fatal(1,"LSQ_HART_MASK hart0=%h hart1=%h want=0004/0020",
                 st_hart_mask[0],st_hart_mask[1]);
      end
      25:begin
        st_alloc=1;ld_alloc=2;alloc_id[0]=1;alloc_id[1]=2;
        drive();st_alloc=0;ld_alloc=0;
        addr_v=3;addr_is_st=1;addr_id[0]=1;addr_id[1]=2;addr[0]=56'h4000;addr[1]=56'h5000;
        drive();addr_v=0;presample();
        if(ppending!=16'h4 || st_unresolved!=16'h2)$fatal(1,"LSQ_PA_VIRTUAL");
        drive();pv=1;pid[0]=2;pa[0]=56'h9000;psz[0]=3;
        drive();pv=0;cmpl_v=1;cmpl_id[0]=2;
        drive();cmpl_v=0;presample();
        if(ldfree!=3 || ppending!=0)$fatal(1,"LSQ_PA_LIFETIME");
        drive();pv=2;pid[1]=1;pa[1]=56'h9000;psz[1]=3;presample();
        if(!viol || viol_id!=2)$fatal(1,"LSQ_PA_TRAIN");
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=16'h4)$fatal(1,"LSQ_PHYSICAL");
      end
      26:begin
        st_alloc=1;ld_alloc=2;alloc_id[0]=1;alloc_id[1]=2;
        drive();st_alloc=0;ld_alloc=0;
        pv=3;pid[0]=2;pid[1]=1;pa[0]=56'ha000;pa[1]=56'h9000;psz='1;
        presample();
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=0)$fatal(1,"LSQ_PHYSICAL");
      end
      27:begin
        ld_alloc=1;alloc_id[0]=2;
        drive();ld_alloc=0;pv=1;pid[0]=2;pa[0]=56'h9000;psz[0]=3;
        drive();pv=0;cmpl_v=1;cmpl_id[0]=2;
        drive();cmpl_v=0;mv=1;ma[0]=56'h9008;presample();
        if(viol)$fatal(1,"LSQ_PA_SNOOP_TRAIN");
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=16'h4 || ldfree!=3)$fatal(1,"LSQ_PHYSICAL");
        drive();mv=0;commit_ld=1;commit_id[0]=2;
        drive();commit_ld=0;mv=1;presample();
        if(preplay!=0 || ldfree!=4)$fatal(1,"LSQ_PA_RETIRE");
      end
      28:begin
        st_alloc=1;ld_alloc=2;alloc_id[0]=1;alloc_id[1]=2;alloc_hart=2;
        drive();st_alloc=0;ld_alloc=0;
        pv=3;pid[0]=2;pid[1]=1;ph=1;pa[0]=56'h9000;pa[1]=56'h9000;psz='1;
        presample();if(preplay!=0)$fatal(1,"LSQ_PA_PEER_SPEC");
        drive();pv=0;mv=2;ma[1]=56'h9000;presample();
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=16'h4)$fatal(1,"LSQ_PHYSICAL");
      end
      29:begin
        ld_alloc=1;alloc_id[0]=2;
        drive();ld_alloc=0;pv=1;pid[0]=2;pa[0]=56'h9000;psz[0]=3;
        drive();pv=0;cancel_mask=16'h4;
        drive();cancel_mask=0;ld_alloc=1;alloc_hart=1;
        drive();ld_alloc=0;pv=1;ph=0;
        drive();pv=0;mv=1;ma[0]=56'h9000;presample();
        if(ppending!=16'h4 || preplay!=0)$fatal(1,"LSQ_PA_STALE_HART");
        drive();pv=1;ph=1;pa[0]=56'ha000;mv=0;
        drive();pv=0;mv=1;ma[0]=56'ha000;presample();
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=16'h4)$fatal(1,"LSQ_PHYSICAL");
      end
      30:begin
        ld_alloc=1;alloc_id[0]=2;
        drive();ld_alloc=0;pv=1;pid[0]=2;pa[0]=56'h9000;psz[0]=3;
        mv=1;ma[0]=56'h9000;presample();
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=16'h4)$fatal(1,"LSQ_PHYSICAL");
      end
      31:begin
        ld_alloc=3;alloc_id[0]=2;alloc_id[1]=4;alloc_hart=2;
        drive();ld_alloc=0;pv=1;pid[0]=2;pa[0]=56'h9000;psz[0]=3;
        drive();pid[0]=4;ph[0]=1;
        drive();pv=0;mv=1;ma[0]=56'h9000;presample();
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=16'h14)$fatal(1,"LSQ_PHYSICAL");
      end
      32:begin
        st_alloc=1;ld_alloc=2;alloc_id[0]=1;alloc_id[1]=2;
        drive();st_alloc=0;ld_alloc=0;
        pv=3;pid[0]=2;pid[1]=1;pa[0]=56'h9002;pa[1]=56'h9000;psz[0]=1;psz[1]=0;
        presample();
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=0)$fatal(1,"LSQ_PHYSICAL");
      end
      33:begin
        ld_alloc=1;alloc_id[0]=2;
        drive();ld_alloc=0;pv=1;pid[0]=2;pa[0]=56'he000;psz[0]=3;
        drive();pv=0;mv=1;ma[0]=56'he000;presample();
        if((preplay ^ (negative ? 16'h4 : 16'h0))!=0 || ppending!=0)
          $fatal(1,"LSQ_PHYSICAL");
      end
      34,35:begin
        ld_alloc=3;alloc_id[0]=2;alloc_id[1]=4;alloc_hart=(scenario==35)?2:0;
        drive();ld_alloc=0;pv=1;pid[0]=4;ph[0]=(scenario==35);pa[0]=56'h9000;psz[0]=3;
        drive();pv=0;cmpl_v=1;cmpl_id[0]=4;
        drive();cmpl_v=0;pv=1;pid[0]=2;ph[0]=0;presample();
        if((preplay ^ (negative ? 16'h10 : 16'h0))!=((scenario==34)?16'h10:16'h0) || viol)
          $fatal(1,"LSQ_PHYSICAL");
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
  // Exercises the elaboration guards: an unsound configuration must fail to
  // build, not merely warn in simulation.
  parameter int unsigned HARTS=1;
  parameter bit FPEN=1'b0;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.NrHarts=HARTS;c.NrCores=1;c.NrIssuePorts=2;c.NrCommitPorts=2;c.NrWbPorts=2;
    c.FpPresent=FPEN;c.FLen=FPEN?64:1;c.RVA=1;
    c.NR_SB_ENTRIES=16;c.TRANS_ID_BITS=4;c.PrfEntries=HARTS>1?80:40;c.RobEntries=8;c.IqEntries=8;
    // Checkpoints are owned per hart, so a two-hart geometry keeps the same
    // two outstanding branches per hart that the single-hart scenarios assume.
    c.LsqLoadEntries=4;c.LsqStoreEntries=4;c.BPCkptDepth=2*HARTS;c.OoOEn=1;
    c.MemDepPredEn=MDP;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {fu_t fu;fu_op op;logic[4:0] rs1,rs2,rd;logic[3:0] trans_id;logic[63:0] pc,result;logic[7:0] p_rs1,p_rs2,p_rd;logic[7:0] p_frs1,p_frs2,p_frs3,p_frd;logic ooo_renamed;logic hart_id;} sbe_t;
  logic clk=0,rst_n=0;
  logic[1:0] dv=0,da,iv;
  sbe_t[1:0] ds='0,issued;
  logic[1:0][31:0] orig;
  int scenario,seen,seen_st,seen_ld;
  logic [7:0] p9a='0,p9b='0;
  bit negative, dual_commit;
  logic [1:0] wb_v='0,cm_ack='0;
  logic [1:0][3:0] wb_id='0;
  logic [15:0] cancel_mask='0;
  logic [1:0][63:0] wb_data='0, op_a, op_b;
  logic [1:0] wb_exc='0, op_a_valid, op_b_valid;
  sbe_t [1:0] cm_instr='0;
  logic [3:0] cp='0,mis_id='0;
  logic mispredict=0, dispatch_flush=0, redirect_flush=0;
  logic [1:0] issue_accept=2'b11;
  // Architectural commit write, as commit_stage drives we_gpr_o/wdata_o.
  logic [1:0] cm_we='0;
  logic [1:0][63:0] cm_wdata='0;
  g6lc_ooo_dispatch #(.CVA6Cfg(C),.scoreboard_entry_t(sbe_t)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(dispatch_flush),.flush_unissued_i(redirect_flush),.cancelled_mask_i(cancel_mask),
    .sb_live_i('1),
    .phys_valid_i('0),.phys_addr_i('0),.phys_id_i('0),.phys_hart_i('0),.phys_size_i('0),
    .mod_valid_i('0),.mod_addr_i('0),.phys_pending_o(),.phys_replay_o(),
    .dispatch_sbe_i(ds),.dispatch_orig_i('0),.dispatch_valid_i(dv),.dispatch_ack_o(da),
    .issue_sbe_o(issued),.issue_orig_o(orig),.issue_valid_o(iv),.issue_ack_i(issue_accept),
    .issue_op_a_o(op_a),.issue_op_b_o(op_b),.issue_op_a_valid_o(op_a_valid),.issue_op_b_valid_o(op_b_valid),
    .wb_valid_i(wb_v),.wb_id_i(wb_id),.wb_data_i(wb_data),.wb_exc_i(wb_exc),
    .commit_we_i(cm_we),.commit_wdata_i(cm_wdata),
    .commit_ack_i(cm_ack),.commit_instr_i(cm_instr),.commit_ptr_i(cp),
    .mispredict_i(mispredict),.mispredict_id_i(mis_id),
    .freelist_empty_o(),.rob_full_o(),.iq_full_o(),.lsq_stall_o(),.rename_stall_o(),.stl_forward_o(),
    .mem_violation_o(),.mem_violation_id_o());
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
    dual_commit=$test$plusargs("dual_commit");
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
      // Ordering guard: the load must not issue while an older store's ADDRESS
      // is unresolved. The store's base register is produced by an ALU that
      // never writes back, so the store cannot issue and stays unresolved.
      // Without a dispatch-time bypass prediction the load waits; with the
      // predictor enabled and cold it bypasses (the LSQ scan then owns safety).
      3:begin
        ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=5'd5;ds[0].pc=64'h0ffc;ds[0].trans_id=0;
        ds[1].fu=STORE;ds[1].op=SD;ds[1].rs1=5'd5;ds[1].pc=64'h1000;ds[1].trans_id=1;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;ds[0]='0;ds[1]='0;
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].rs1=5'd6;ds[0].pc=64'h1004;ds[0].trans_id=2;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION2");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p])begin
            if(issued[p].trans_id==4'd1)seen_st++;
            if(issued[p].trans_id==4'd2)seen_ld++;
          end
          drive();
        end
        if(seen_st!=0)$fatal(1,"DISPATCH_STORE_PROGRESS scenario=3 issued=%0d",seen_st);
        if(seen_ld!=((MDP?1:0)^negative))$fatal(1,"DISPATCH_LOAD_ORDER load_issued=%0d",seen_ld);
      end
      // A store's LSQ entry is its speculative-queue reservation: its own
      // writeback keeps the entry, and only its commit (by trans_id) releases it.
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
        if(dut.store_pend!==(negative?1'b0:1'b1))
          $fatal(1,"DISPATCH_STORE_WB_RETIRE store_pend=%b",dut.store_pend);
        cm_instr='0;cm_instr[0].fu=STORE;cm_instr[0].op=SD;cm_instr[0].trans_id=1;cm_ack=2'b01;
        drive();cm_ack='0;
        presample();
        if(dut.store_pend)$fatal(1,"DISPATCH_STORE_COMMIT_RELEASE store_pend=%b",dut.store_pend);
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
      // Wraparound: with cp=14 the UNRESOLVED store at tid 15 (dist 1) is OLDER
      // than the load at tid 0 (dist 2) and still blocks it; a naive compare
      // would pass. The store's base register comes from an ALU at tid 14 that
      // never writes back, so the store cannot issue or resolve.
      8:begin
        cp=4'd14;
        ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=5'd5;ds[0].pc=64'h0ffc;ds[0].trans_id=14;
        ds[1].fu=STORE;ds[1].op=SD;ds[1].rs1=5'd5;ds[1].pc=64'h1000;ds[1].trans_id=15;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;ds[0]='0;ds[1]='0;
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].rs1=5'd6;ds[0].pc=64'h1004;ds[0].trans_id=0;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION2");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)begin
            if(iv[p]&&issued[p].trans_id==4'd15)seen_st++;
            if(iv[p]&&issued[p].trans_id==4'd0)seen_ld++;
          end
          drive();
        end
        if(seen_st!=0)$fatal(1,"DISPATCH_STORE_PROGRESS scenario=8 issued=%0d",seen_st);
        if(seen_ld!=((MDP?1:0)^negative))$fatal(1,"DISPATCH_WRAP_ORDER ld=%0d",seen_ld);
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
      11,12,13,14:begin
        ds[0].fu=CTRL_FLOW;ds[0].op=BRANCH;ds[0].trans_id=1;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_OWNER_SETUP branch");
        drive();dv=0;
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=7;ds[0].trans_id=2;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_OWNER_SETUP old");
        drive();dv=0;
        presample();
        if(!iv[0]||issued[0].trans_id!=2)$fatal(1,"DISPATCH_OWNER_SETUP old issue");
        p9a=issued[0].p_rd;
        drive();
        cancel_mask=16'h0004;mispredict=1;mis_id=1;
        drive();mispredict=0;
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=9;ds[0].trans_id=3;dv=1;
        if(scenario==11||scenario==14)begin
          ds[1].fu=ALU;ds[1].op=ADD;ds[1].rs1=9;ds[1].rd=10;ds[1].trans_id=4;dv=3;
        end
        presample();if(da!=dv)$fatal(1,"DISPATCH_OWNER_SETUP new");
        drive();dv=0;
        presample();
        if(!iv[0]||issued[0].trans_id!=3)$fatal(1,"DISPATCH_OWNER_SETUP new issue");
        p9b=issued[0].p_rd;
        if(p9a==0||p9a!=p9b)$fatal(1,"DISPATCH_OWNER_SETUP no reuse old=%0d new=%0d",p9a,p9b);
        drive();
        if(scenario==13)begin
          wb_v=1;wb_id[0]=3;wb_data={64'b0,64'h5678};
          presample();
          if($test$plusargs("owner_trace"))
            $display("OWNER_WB valid=%b qualified=%b id=%h prd=%h we=%b data=%h",wb_v,dut.wb_value_valid,wb_id,dut.wb_prd,dut.prf_we,wb_data);
          drive();wb_v=0;
        end else begin
          wb_v=1;wb_id[0]=scenario==14?3:2;wb_data={64'b0,64'h1111};
          wb_exc=scenario==14?2'b01:2'b00;
          presample();
          for(int p=0;p<2;p++)
            if(iv[p]&&issued[p].trans_id==4)$fatal(1,"DISPATCH_STALE_WAKE invalid completion issued waiter");
          drive();wb_v=0;wb_exc=0;
        end
        if(scenario!=11&&scenario!=14)begin
          ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rs1=9;ds[0].rd=10;ds[0].trans_id=4;dv=1;
          presample();if(!da[0])$fatal(1,"DISPATCH_OWNER_SETUP consumer");
          drive();dv=0;
        end
        if(scenario==14)begin
          presample();
          if((|iv)^negative)$fatal(1,"DISPATCH_WB_VALUE exception made data ready");
        end else begin
        if(scenario==13)begin
          wb_v=1;wb_id[0]=2;wb_data={64'b0,64'h1111};
        end else begin
          presample();
          for(int p=0;p<2;p++)
            if(iv[p]&&issued[p].trans_id==4)$fatal(1,"DISPATCH_STALE_WAKE cancelled completion cleared busy");
          drive();wb_v=1;wb_id[0]=3;wb_data={64'b0,64'h5678};
        end
        presample();seen=0;
        for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==4)begin
          seen++;
          if($test$plusargs("owner_trace"))
            $display("OWNER_READ prs=%h readaddr=%h mem=%h raw=%h data=%h",issued[p].p_rs1,dut.prf_raddr[p*2],dut.i_prf.mem_q[p9b],dut.prf_rdata[p*2],op_a[p]);
          if(!op_a_valid[p]||(op_a[p] ^ (negative?64'd1:64'd0))!=64'h5678)
            $fatal(1,"DISPATCH_WB_VALUE scenario=%0d operand=%h",scenario,op_a[p]);
        end
        if(seen!=1)$fatal(1,"DISPATCH_OWNER_SETUP no genuine wake");
        drive();wb_v=0;
        end
      end
      15,16,17:begin
        ds[0].fu=CTRL_FLOW;ds[0].op=BRANCH;ds[0].trans_id=1;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_DROP_SETUP branch");
        drive();dv=0;
        ds='0;ds[0].fu=scenario==17?CTRL_FLOW:ALU;ds[0].op=scenario==17?JALR:ADD;
        ds[0].rd=7;ds[0].trans_id=2;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_DROP_SETUP victim");
        drive();dv=0;
        presample();
        if(!iv[0]||issued[0].trans_id!=2)$fatal(1,"DISPATCH_DROP_SETUP victim issue");
        p9a=issued[0].p_rd;
        if(p9a==0||p9a==7)$fatal(1,"DISPATCH_DROP_SETUP no rename");
        drive();cancel_mask=16'h0004;mispredict=1;mis_id=1;wb_v=1;wb_id=8'h01;
        drive();mispredict=0;wb_v=0;
        cm_instr='0;cm_instr[0].fu=CTRL_FLOW;cm_instr[0].trans_id=1;cm_ack=dual_commit?0:1;
        drive();cm_ack=0;
        if(scenario==17)begin
          ds='0;ds[0].fu=CTRL_FLOW;ds[0].op=BRANCH;ds[0].trans_id=3;dv=1;
          presample();if(!da[0])$fatal(1,"DISPATCH_DROP_SETUP replacement branch");
          drive();dv=0;
          drive();
        end
        cm_instr='0;cm_instr[0].fu=scenario==17?CTRL_FLOW:ALU;
        cm_instr[0].rd=7;cm_instr[0].trans_id=2;cm_ack=1;
        if(dual_commit)begin
          cm_instr[1]=cm_instr[0];cm_instr[0]='0;
          cm_instr[0].fu=CTRL_FLOW;cm_instr[0].trans_id=1;cm_ack=3;
        end
        drive();cm_ack=0;cancel_mask=0;
        if(scenario==15)begin
          dispatch_flush=1;drive();dispatch_flush=0;
          ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rs1=7;ds[0].rd=10;ds[0].trans_id=3;dv=1;
          presample();if(!da[0])$fatal(1,"DISPATCH_DROP_SETUP arch read");
          drive();dv=0;
          presample();
          if(!iv[0]||issued[0].trans_id!=3)$fatal(1,"DISPATCH_DROP_SETUP arch issue");
          if((issued[0].p_rs1 ^ (negative?8'd1:8'd0))!=8'd7)
            $fatal(1,"DISPATCH_DROP_ARCH physical=%0d",issued[0].p_rs1);
        end else begin
          ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=9;ds[0].trans_id=scenario==17?4:3;dv=1;
          presample();if(!da[0])$fatal(1,"DISPATCH_DROP_SETUP next allocation");
          drive();dv=0;
          presample();
          if(!iv[0]||issued[0].rd!=9)$fatal(1,"DISPATCH_DROP_SETUP next issue");
          p9b=issued[0].p_rd;
          if(scenario==16)begin
            if((p9b ^ (negative?8'd1:8'd0))!=p9a)
              $fatal(1,"DISPATCH_DROP_FREE physical=%0d expected=%0d",p9b,p9a);
          end else begin
            drive();mispredict=1;mis_id=3;cancel_mask=16'h0010;wb_v=1;wb_id=8'h03;
            drive();mispredict=0;wb_v=0;
            ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=10;ds[0].trans_id=5;dv=1;
            presample();if(!da[0])$fatal(1,"DISPATCH_DROP_SETUP recovered allocation");
            drive();dv=0;
            presample();
            if(!iv[0]||issued[0].trans_id!=5)$fatal(1,"DISPATCH_DROP_SETUP recovered issue");
            if((issued[0].p_rd ^ (negative?8'd1:8'd0))!=p9b)
              $fatal(1,"DISPATCH_DROP_CKPT physical=%0d expected=%0d",issued[0].p_rd,p9b);
          end
        end
      end
      18:begin
        // Late writeback after trans_id REUSE. Unlike scenarios 13/14 the
        // cancellation mask no longer identifies the stale result: the id has
        // been handed to a live instruction, so wb_id alone cannot say whose
        // completion this is. Contract under test: a result for a cancelled
        // owner must not complete, wake or supply data for the id's NEW owner.
        ds[0].fu=CTRL_FLOW;ds[0].op=BRANCH;ds[0].trans_id=1;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_TIDREUSE_SETUP branch");
        drive();dv=0;
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=7;ds[0].trans_id=2;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_TIDREUSE_SETUP victim");
        drive();dv=0;
        presample();
        if(!iv[0]||issued[0].trans_id!=2)$fatal(1,"DISPATCH_TIDREUSE_SETUP victim issue");
        p9a=issued[0].p_rd;
        // Cancel the victim and retire the branch, then drop the victim so the
        // id is architecturally free again and its cancel bit is released.
        drive();cancel_mask=16'h0004;mispredict=1;mis_id=1;wb_v=1;wb_id=8'h01;
        drive();mispredict=0;wb_v=0;
        cm_instr='0;cm_instr[0].fu=CTRL_FLOW;cm_instr[0].trans_id=1;cm_ack=1;
        drive();cm_ack=0;
        cm_instr='0;cm_instr[0].fu=ALU;cm_instr[0].rd=7;cm_instr[0].trans_id=2;cm_ack=1;
        drive();cm_ack=0;cancel_mask=0;
        // New owner of id 2, plus a consumer that may only wake on its result.
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=9;ds[0].trans_id=2;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_TIDREUSE_SETUP new owner");
        drive();dv=0;
        presample();
        if(!iv[0]||issued[0].trans_id!=2)$fatal(1,"DISPATCH_TIDREUSE_SETUP new owner issue");
        p9b=issued[0].p_rd;
        // The new owner legitimately inherits the dropped victim's physical
        // register (scenario 16 proves that free is correct), so a stale result
        // would land on the live owner's own register. That sharpens the hazard.
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rs1=9;ds[0].rd=10;ds[0].trans_id=4;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_TIDREUSE_SETUP consumer");
        drive();dv=0;
        // The cancelled owner's result finally returns, carrying only id 2.
        drive();wb_v=1;wb_id[0]=2;wb_data={64'b0,64'hDEAD};wb_exc=0;
        presample();
        for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==4)begin
          if(!negative)
            $fatal(1,"DISPATCH_TIDREUSE stale result woke the new owner's consumer operand=%h",op_a[p]);
        end
        drive();wb_v=0;
        // The new owner must still be able to complete on its OWN result.
        drive();wb_v=1;wb_id[0]=2;wb_data={64'b0,64'h1234};
        presample();seen=0;
        for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==4)begin
          seen++;
          if(!op_a_valid[p]||op_a[p]!=64'h1234)
            $fatal(1,"DISPATCH_TIDREUSE genuine result lost operand=%h",op_a[p]);
        end
        if(seen!=1&&!negative)$fatal(1,"DISPATCH_TIDREUSE no genuine wake");
        drive();wb_v=0;
      end
      19:begin
        // Architectural result produced at COMMIT, not by the execute writeback.
        // Models CSR (commit_stage: wdata_o=csr_rdata_i) and LR (wdata_o=
        // amo_resp_i.result), both of which override commit_instr.result and never
        // appear on wb_data_i. Contract under test: a later consumer renamed against
        // that destination must observe the ARCHITECTURAL value, because with
        // OoOEn=1 issue_read_operands takes the PRF operand over the regfile read.
        // A plain CSR access no longer waits for the commit head (the per-tid
        // csr_buffer table holds its address); the value still arrives at commit.
        ds='0;ds[0].fu=CSR;ds[0].op=CSR_READ;ds[0].rd=7;ds[0].trans_id=1;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_LATERESULT_SETUP producer");
        drive();dv=0;
        presample();
        if(!iv[0]||issued[0].trans_id!=1)$fatal(1,"DISPATCH_LATERESULT_SETUP producer issue");
        cp=4'd1;
        p9a=issued[0].p_rd;
        if(p9a==0)$fatal(1,"DISPATCH_LATERESULT_SETUP no rename");
        // Execute-stage writeback carries only the placeholder.
        drive();wb_v=1;wb_id[0]=1;wb_data={64'b0,64'h0BAD};wb_exc=0;
        drive();wb_v=0;
        // Commit supplies the architectural value, as commit_stage does.
        cm_instr='0;cm_instr[0].fu=CSR;cm_instr[0].op=CSR_READ;cm_instr[0].rd=7;cm_instr[0].trans_id=1;
        cm_instr[0].result=64'h1234;cm_ack=1;
        cm_we=2'b01;cm_wdata[0]=64'h1234;
        drive();cm_ack=0;cm_we=0;
        // A consumer renamed against the committed destination.
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rs1=7;ds[0].rd=10;ds[0].trans_id=2;dv=1;
        presample();if(!da[0])$fatal(1,"DISPATCH_LATERESULT_SETUP consumer");
        drive();dv=0;
        presample();seen=0;
        for(int p=0;p<2;p++)if(iv[p]&&issued[p].trans_id==2)begin
          seen++;
          if(!op_a_valid[p])$fatal(1,"DISPATCH_LATERESULT consumer operand not valid");
          if((op_a[p]^(negative?64'd1:64'd0))!=64'h1234)
            $fatal(1,"DISPATCH_LATERESULT consumer read %h, architectural value is 1234",op_a[p]);
        end
        if(seen!=1)$fatal(1,"DISPATCH_LATERESULT_SETUP consumer did not issue");
      end
      20,22,23:begin
        issue_accept=0;
        ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=7;ds[0].trans_id=1;
        ds[1].fu=CTRL_FLOW;ds[1].op=NE;ds[1].trans_id=2;dv=3;
        presample();if(da!=3)$fatal(1,"DISPATCH_RECOVERY_SETUP");
        drive();dv=0;issue_accept=3;
        redirect_flush=1;dispatch_flush=(scenario==22);
        if(scenario==23)cancel_mask=16'h0004;
        presample();
        if((|iv)!==negative)$fatal(1,"DISPATCH_RECOVERY_ISSUE valid=%b",iv);
        if(|da)$fatal(1,"DISPATCH_RECOVERY_ALLOC");
        drive();redirect_flush=0;dispatch_flush=0;
        presample();
        if(scenario==22)begin
          if(|iv)$fatal(1,"DISPATCH_RECOVERY_FULL_FLUSH");
        end else if(scenario==23)begin
          if(iv!=1||issued[0].trans_id!=1)$fatal(1,"DISPATCH_RECOVERY_CANCEL_SCOPE");
          drive();presample();if(|iv)$fatal(1,"DISPATCH_RECOVERY_DUPLICATE");
        end else begin
          if(iv!=3||issued[0].trans_id!=1||issued[1].trans_id!=2)
            $fatal(1,"DISPATCH_RECOVERY_LOST valid=%b",iv);
          drive();presample();
          if(|iv)$fatal(1,"DISPATCH_RECOVERY_DUPLICATE");
        end
      end
      21:begin
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].rd=7;ds[0].trans_id=1;dv=1;
        presample();if(da!=1)$fatal(1,"DISPATCH_RECOVERY_SETUP producer");
        drive();dv=0;
        presample();if(iv!=1||issued[0].trans_id!=1)$fatal(1,"DISPATCH_RECOVERY_SETUP issue");
        drive();issue_accept=0;
        ds='0;ds[0].fu=CTRL_FLOW;ds[0].op=NE;ds[0].rs1=7;ds[0].trans_id=2;
        ds[1].fu=CTRL_FLOW;ds[1].op=NE;ds[1].trans_id=3;dv=3;
        presample();if(da!=3)$fatal(1,"DISPATCH_RECOVERY_SETUP branches");
        drive();dv=0;issue_accept=3;
        presample();if(iv!=1||issued[0].trans_id!=3)$fatal(1,"DISPATCH_RECOVERY_SETUP younger");
        drive();redirect_flush=1;mispredict=1;mis_id=3;
        wb_v=3;wb_id[0]=1;wb_id[1]=3;wb_data[0]=64'h1234;
        ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=8;ds[0].trans_id=4;dv=1;
        presample();
        if((|iv)!==negative)$fatal(1,"DISPATCH_RECOVERY_WAKE valid=%b",iv);
        if(|da)$fatal(1,"DISPATCH_RECOVERY_ALLOC");
        drive();redirect_flush=0;mispredict=0;wb_v=0;dv=0;
        presample();
        if(iv!=1||issued[0].trans_id!=2||!op_a_valid[0]||op_a[0]!=64'h1234)
          $fatal(1,"DISPATCH_RECOVERY_WAKE_LOST valid=%b tid=%0d data=%h",iv,issued[0].trans_id,op_a[0]);
        drive();presample();if(|iv)$fatal(1,"DISPATCH_RECOVERY_DUPLICATE");
      end
      24,25,27:begin
        if(!FPEN)$fatal(1,"DISPATCH_FP_SETUP");
        ds[0].fu=FPU;ds[0].op=FADD;ds[0].rd=scenario==25?7:0;ds[0].trans_id=1;dv=1;
        presample();if(da!=1)$fatal(1,"DISPATCH_FP_SETUP alloc");
        drive();dv=0;
        presample();if(iv!=1||issued[0].trans_id!=1)$fatal(1,"DISPATCH_FP_SETUP issue");
        p9a=issued[0].p_frd;
        drive();wb_v=1;wb_id[0]=1;wb_data={64'b0,64'h4031000000000000};
        drive();wb_v=0;
        cm_instr='0;cm_instr[0].fu=FPU;cm_instr[0].op=FADD;
        cm_instr[0].rd=scenario==25?7:0;cm_instr[0].trans_id=1;cm_ack=1;
        drive();cm_ack=0;
        if(scenario==27)begin
          ds='0;ds[0].fu=FPU;ds[0].op=FADD;ds[0].rd=7;ds[0].trans_id=2;dv=1;
          presample();if(da!=1)$fatal(1,"DISPATCH_FP_SETUP zero allocation");
          drive();dv=0;presample();
          if(iv!=1||issued[0].p_frd!=0)$fatal(1,"DISPATCH_FP_SETUP physical zero");
          p9a=issued[0].p_frd;
          drive();wb_v=1;wb_id[0]=2;wb_data={64'b0,64'h4031000000000000};
          drive();wb_v=0;cm_instr[0].rd=7;cm_instr[0].trans_id=2;cm_ack=1;
          drive();cm_ack=0;
        end
        dispatch_flush=1;
        drive();dispatch_flush=0;
        ds='0;ds[0].fu=FPU;ds[0].op=FMUL;ds[0].rd=9;
        ds[0].rs1=scenario==24?0:7;ds[0].trans_id=2;dv=1;
        presample();if(da!=1)$fatal(1,"DISPATCH_FP_SETUP consumer");
        drive();dv=0;presample();
        if(iv!=1||issued[0].p_frs1!=p9a||!op_a_valid[0]||
           (op_a[0]^(negative?64'd1:64'd0))!=64'h4031000000000000)
          $fatal(1,"DISPATCH_FP_COMMIT_FLUSH tag=%0d wanted=%0d data=%h",issued[0].p_frs1,p9a,op_a[0]);
      end
      26:begin
        if(HARTS!=2)$fatal(1,"DISPATCH_HART_SETUP");
        for(int h=0;h<2;h++)begin
          ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=5;ds[0].hart_id=1'(h);
          ds[0].trans_id=4'(h+1);dv=1;
          presample();if(da!=1)$fatal(1,"DISPATCH_HART_SETUP alloc");
          drive();dv=0;presample();
          if(iv!=1||issued[0].trans_id!=4'(h+1))$fatal(1,"DISPATCH_HART_SETUP issue");
          drive();wb_v=1;wb_id[0]=4'(h+1);wb_data[0]=64'h1005+64'(h)*64'h1000;
          drive();wb_v=0;
          cm_instr='0;cm_instr[0].fu=ALU;cm_instr[0].op=ADD;cm_instr[0].rd=5;
          cm_instr[0].hart_id=1'(h);cm_instr[0].trans_id=4'(h+1);cm_ack=1;
          cm_we=1;cm_wdata[0]=64'h1005+64'(h)*64'h1000;
          drive();cm_ack=0;cm_we=0;
        end
        dispatch_flush=1;drive();dispatch_flush=0;
        ds='0;
        for(int h=0;h<2;h++)begin
          ds[h].fu=ALU;ds[h].op=ADD;ds[h].rs1=5;ds[h].hart_id=1'(h);ds[h].trans_id=4'(h+3);
        end
        dv=3;presample();if(da!=3)$fatal(1,"DISPATCH_HART_SETUP readers");
        drive();dv=0;presample();
        if(iv!=3||op_a[0]!=(negative?64'h2005:64'h1005)||op_a[1]!=64'h2005)
          $fatal(1,"DISPATCH_HART_ARCH h0=%h h1=%h",op_a[0],op_a[1]);
        if(issued[0].p_rs1==issued[1].p_rs1)$fatal(1,"DISPATCH_HART_PHYS_ALIAS");
      end
      28,29:begin
        cp=4'd1;
        ds[0].fu=scenario==28?CSR:STORE;ds[0].op=scenario==28?CSR_READ:AMO_LRD;
        ds[0].rd=7;ds[0].trans_id=1;dv=1;
        presample();if(da!=1)$fatal(1,"DISPATCH_LATE_WAKE_SETUP producer");
        drive();dv=0;presample();if(iv!=1)$fatal(1,"DISPATCH_LATE_WAKE_SETUP issue");
        drive();ds='0;ds[0].fu=ALU;ds[0].op=ADD;ds[0].rs1=7;ds[0].rd=8;ds[0].trans_id=2;dv=1;
        wb_v=1;wb_id[0]=1;wb_data={64'b0,64'h0BAD};
        presample();if(da!=1)$fatal(1,"DISPATCH_LATE_WAKE_SETUP consumer");
        drive();dv=0;wb_v=0;presample();
        if((|iv)!==negative)$fatal(1,"DISPATCH_LATE_WAKE_EARLY");
        drive();cm_instr='0;cm_instr[0].fu=scenario==28?CSR:STORE;
        cm_instr[0].op=scenario==28?CSR_READ:AMO_LRD;
        cm_instr[0].rd=7;cm_instr[0].trans_id=1;cm_ack=1;cm_we=1;cm_wdata={64'b0,64'h1234};
        presample();
        if(iv!=1||issued[0].trans_id!=2||op_a[0]!=64'h1234)
          $fatal(1,"DISPATCH_LATE_WAKE_COMMIT valid=%b data=%h",iv,op_a[0]);
      end
      // D-A (T6b): a PEER hart's unresolved older store must not block this
      // hart's load. Same shape as scenario 3 — the store's base comes from
      // an ALU that never writes back, so the store stays unresolved — but
      // the load belongs to hart 1 while the store is hart 0.
      30:begin
        if(HARTS!=2)$fatal(1,"DISPATCH_HART_SETUP");
        ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=5'd5;ds[0].pc=64'h0ffc;ds[0].trans_id=0;ds[0].hart_id=0;
        ds[1].fu=STORE;ds[1].op=SD;ds[1].rs1=5'd5;ds[1].pc=64'h1000;ds[1].trans_id=1;ds[1].hart_id=0;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;ds[0]='0;ds[1]='0;
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].rs1=5'd6;ds[0].pc=64'h1004;ds[0].trans_id=2;ds[0].hart_id=1;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION2");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p])begin
            if(issued[p].trans_id==4'd1)seen_st++;
            if(issued[p].trans_id==4'd2)seen_ld++;
          end
          drive();
        end
        if(seen_st!=0)$fatal(1,"DISPATCH_STORE_PROGRESS scenario=30 issued=%0d",seen_st);
        if(seen_ld!=(1^negative))$fatal(1,"DISPATCH_HART_LOAD_PEER ld=%0d",seen_ld);
      end
      // D-B (T6b): the same-hart unresolved older store still blocks.
      31:begin
        if(HARTS!=2)$fatal(1,"DISPATCH_HART_SETUP");
        ds[0].fu=ALU;ds[0].op=ADD;ds[0].rd=5'd5;ds[0].pc=64'h0ffc;ds[0].trans_id=0;ds[0].hart_id=1;
        ds[1].fu=STORE;ds[1].op=SD;ds[1].rs1=5'd5;ds[1].pc=64'h1000;ds[1].trans_id=1;ds[1].hart_id=1;dv=2'b11;
        presample();if(!da[0]||!da[1])$fatal(1,"DISPATCH_ADMISSION");
        drive();dv=0;ds[0]='0;ds[1]='0;
        ds[0].fu=LOAD;ds[0].op=LD;ds[0].rs1=5'd6;ds[0].pc=64'h1004;ds[0].trans_id=2;ds[0].hart_id=1;dv=2'b01;
        presample();if(!da[0])$fatal(1,"DISPATCH_ADMISSION2");
        drive();dv=0;
        repeat(8)begin
          presample();
          for(int p=0;p<2;p++)if(iv[p])begin
            if(issued[p].trans_id==4'd1)seen_st++;
            if(issued[p].trans_id==4'd2)seen_ld++;
          end
          drive();
        end
        if(seen_st!=0)$fatal(1,"DISPATCH_STORE_PROGRESS scenario=31 issued=%0d",seen_st);
        if(seen_ld!=((MDP?1:0)^negative))$fatal(1,"DISPATCH_HART_LOAD_OWN ld=%0d",seen_ld);
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
module tb_g6lc_review_store_recovery;
  import ariane_pkg::*;
  parameter int NH=2;
  parameter bit OOO=1;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.PLEN=56;c.NrHarts=NH;c.SuperscalarEn=1;c.OoOEn=OOO;
    // cva6_cfg_empty defaults SmtDrainedHandoff=1 — the OoO 2-hart geometry
    // must opt out for the mixed-resident store-head gate to elaborate.
    c.SmtDrainedHandoff=!(NH>1 && OOO);
    c.NR_SB_ENTRIES=8;c.TRANS_ID_BITS=3;c.DCACHE_INDEX_WIDTH=12;c.DCACHE_TAG_WIDTH=44;
    c.DCacheType=config_pkg::WT;return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef logic[7:0] cbo_t;
  typedef struct packed {logic data_req,data_we,kill_req,tag_valid,data_id,data_wuser;
    logic[11:0] address_index;logic[43:0] address_tag;logic[63:0] data_wdata;
    logic[7:0] data_be;logic[1:0] data_size;cbo_t cbo_op;} req_t;
  typedef struct packed {logic data_gnt,data_rvalid;} rsp_t;
  logic clk=0,rst_n=0,flush=0,valid=0,commit=0,load_v=0;
  logic[7:0] cancelled=0;
  logic[2:0] tid=1;
  // OoO program-order keys: the querying load's tid and the age anchor
  // (oldest live instruction, which is also the tid commit is retiring).
  logic[2:0] load_tid=7,commit_tid=0;
  // T6b: store/load hart tags — inert at NH==1 or OOO==0.
  logic st_hart=0,load_hart=0;
  logic[55:0] address=56'h1010,load_address=56'h1010;
  logic[63:0] data=64'hAAAA,fwd_data;
  logic[7:0] fwd_be;
  logic ready,commit_ready,empty,no_pending,fwd;
  req_t req; rsp_t rsp='0;
  int scenario;bit negative;
  always #5 clk=~clk;
  store_buffer #(.CVA6Cfg(C),.dcache_req_i_t(req_t),.dcache_req_o_t(rsp_t),.cbo_t(cbo_t)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.cancelled_mask_i(cancelled),
    .sb_live_i('1),
    .stall_st_pending_i(1'b0),.no_st_pending_o(no_pending),.store_buffer_empty_o(empty),
    .page_offset_i(load_address[11:0]),.load_paddr_i(load_address),.load_paddr_valid_i(load_v),
    .load_trans_id_i(load_tid),.commit_trans_id_i(commit_tid),
    .oldest_live_tid_i(commit_tid),
    .load_hart_i(load_hart),.st_hart_i(st_hart),
    .dcache_wbuffer_empty_i(1'b1),.page_offset_matches_o(),.st_fwd_valid_o(fwd),
    .st_fwd_data_o(fwd_data),.st_fwd_be_o(fwd_be),.commit_i(commit),
    .commit_ready_o(commit_ready),.ready_o(ready),.valid_i(valid),.valid_without_flush_i(valid),
    .paddr_i(address),.trans_id_i(tid),.rvfi_mem_paddr_o(),.data_i(data),.be_i(8'hff),
    .data_size_i(2'b11),.cbo_op_i(CBO_NONE),.req_port_i(rsp),.req_port_o(req));
  task automatic drive;@(negedge clk);endtask
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(2)drive();rst_n=1;drive();valid=1;drive();valid=0;
    if(scenario==1)begin
      load_v=1;#4;if(!fwd)$fatal(1,"STORE_RECOVERY_SETUP forward");
      drive();load_v=0;cancelled=2;drive();cancelled=0;load_v=1;#4;
      if(empty!==!negative||fwd)$fatal(1,"STORE_RECOVERY_CANCEL");
    end else if(scenario==2)begin
      commit_tid=1;commit=1;drive();commit=0;valid=1;tid=2;address=56'h1020;data=64'hBBBB;
      drive();valid=0;flush=1;drive();flush=0;#4;
      if(!req.data_req||req.data_wdata!=(negative?64'hBBBB:64'hAAAA))$fatal(1,"STORE_RECOVERY_COMMITTED");
      rsp.data_gnt=1;drive();rsp.data_gnt=0;#4;
      if(!empty)$fatal(1,"STORE_RECOVERY_COMMITTED leaked speculative store");
    end else if(scenario==0||scenario==3)begin
      flush=1;drive();flush=0;#4;
      if(scenario==0)begin
        if(empty!==!negative)$fatal(1,"STORE_RECOVERY_FLUSH");
      end else begin
        drive();valid=1;tid=2;address=56'h1020;data=64'hBBBB;
        drive();valid=0;commit_tid=2;commit=1;drive();commit=0;#4;
        if(!req.data_req||{req.address_tag,req.address_index}!=56'h1020||
           req.data_wdata!=(negative?64'hAAAA:64'hBBBB))$fatal(1,"STORE_RECOVERY_REPLAY");
      end
    end else if(scenario==4)begin
      // Contract A: a store YOUNGER than the querying load must not be
      // observable by it, however exactly their addresses match.
      flush=1;drive();flush=0;drive();
      valid=1;tid=5;address=56'h1010;data=64'hCCCC;drive();valid=0;
      load_address=56'h1010;load_tid=2;load_v=1;#4;
      if(fwd!==negative)$fatal(1,"STORE_RECOVERY_YOUNGER_FWD");
    end else if(scenario==5)begin
      // Contract B: arrival order is issue order. The store handed to memory
      // must be the program-order-oldest one, not the one that arrived first.
      flush=1;drive();flush=0;drive();
      valid=1;tid=3;address=56'h1030;data=64'hCCCC;drive();valid=0;
      valid=1;tid=1;address=56'h1040;data=64'hDDDD;drive();valid=0;
      commit_tid=1;commit=1;drive();commit=0;#4;
      if(!req.data_req||{req.address_tag,req.address_index}!=(negative?56'h1030:56'h1040)||
         req.data_wdata!=(negative?64'hCCCC:64'hDDDD))$fatal(1,"STORE_RECOVERY_PROGRAM_ORDER");
    end else if(scenario==6)begin
      // T6b: a peer hart's speculative store must not forward to this hart's
      // load — peer stores become visible only at commit.
      if(NH!=2||!OOO)$fatal(1,"STORE_RECOVERY_HART_SETUP");
      flush=1;drive();flush=0;drive();
      valid=1;tid=1;st_hart=1;address=56'h1010;data=64'hEEEE;drive();valid=0;st_hart=0;
      load_address=56'h1010;load_tid=2;load_hart=0;load_v=1;#4;
      if(fwd!==negative)$fatal(1,"STORE_RECOVERY_HART_PEER_FWD fwd=%b",fwd);
      drive();load_v=0;
    end else if(scenario==7)begin
      // T6b: the same-hart store still forwards under the ownership rule.
      if(NH!=2||!OOO)$fatal(1,"STORE_RECOVERY_HART_SETUP");
      flush=1;drive();flush=0;drive();
      valid=1;tid=1;st_hart=1;address=56'h1010;data=64'hEEEE;drive();valid=0;st_hart=0;
      load_address=56'h1010;load_tid=2;load_hart=1;load_v=1;#4;
      if(fwd!==!negative||fwd_data!==64'hEEEE)
        $fatal(1,"STORE_RECOVERY_HART_OWN_FWD fwd=%b data=%h",fwd,fwd_data);
      drive();load_v=0;load_hart=0;
    end else if(scenario==8)begin
      // T6b-4b: under mixed-resident commit a store retires only when it is
      // the speculative-queue head. tid1 (hart0, already enqueued) is the
      // head; a commit presented with tid2 (hart1) must stall, and the
      // committed order to memory stays tid1 then tid2.
      if(NH!=2||!OOO)$fatal(1,"STORE_RECOVERY_HART_SETUP");
      valid=1;tid=2;st_hart=1;address=56'h1020;data=64'hBBBB;
      drive();valid=0;st_hart=0;drive();
      commit_tid=2;#4;
      // commit_i is the caller's pulse — it fires only when commit_ready_o
      // permits; the stall lives in that ready, so present-and-hold here.
      if(commit_ready!==negative)$fatal(1,"STB_HEAD_STALL non-head commit not stalled");
      drive();
      if(req.data_req)$fatal(1,"STB_HEAD_STALL non-head store reached memory");
      commit_tid=1;#4;
      if(commit_ready!==!negative)$fatal(1,"STB_HEAD_STALL head commit blocked");
      // Grant held asserted (always-ready sink): a post-request pulse lets
      // the queue-valid clear retire the entry a half-eval before the read
      // pointer observes the evict and strands it on the freed slot.
      rsp.data_gnt=1;
      commit=1;drive();commit=0;#4;
      if(!req.data_req||{req.address_tag,req.address_index}!=56'h1010||
         req.data_wdata!=(negative?64'hBBBB:64'hAAAA))
        $fatal(1,"STB_HEAD_STALL head order");
      commit_tid=2;#4;
      if(commit_ready!==!negative)$fatal(1,"STB_HEAD_STALL next head blocked");
      drive();
      commit=1;drive();commit=0;#4;
      if(!req.data_req||{req.address_tag,req.address_index}!=56'h1020||
         req.data_wdata!=(negative?64'hAAAA:64'hBBBB))
        $fatal(1,"STB_HEAD_STALL tail order");
      rsp.data_gnt=0;
    end else $fatal(1,"STORE_RECOVERY_SCENARIO");
    $display("RTL_REVIEW_PASS store_recovery scenario=%0d",scenario);$finish;
  end
endmodule

module tb_g6lc_review_wfi;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  parameter bit OOO=1,RVA_EN=0;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.FLen=1;
    c.NrIssuePorts=2;c.NrCommitPorts=2;c.NrWbPorts=2;c.NrHarts=1;
    c.NR_SB_ENTRIES=8;c.TRANS_ID_BITS=3;c.OoOEn=OOO;c.RVA=RVA_EN;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C) sbe_t;
  typedef struct packed {logic valid,is_mispredict,is_taken;cf_t cf_type;} bp_t;
  logic clk=0,rst_n=0,halt=0;
  sbe_t[1:0] entry='0;
  exception_t csr_ex='0;
  logic[1:0] drop='0,ack;
  logic flush_commit,commit_csr,set_pc,flush_if,flush_id,flush_ex,flush_unissued;
  int scenario;bit negative,expected;
  always #5 clk=~clk;
  commit_stage #(.CVA6Cfg(C),.exception_t(exception_t),.scoreboard_entry_t(sbe_t)) dut(
    .clk_i(clk),.rst_ni(rst_n),.halt_i(halt),.flush_dcache_i(1'b0),.exception_o(),
    .single_step_i(1'b0),.step_hart_i('0),
    .commit_instr_i(entry),.commit_drop_i(drop),.commit_replay_i('0),.commit_ack_o(ack),
    .commit_macro_ack_o(),.waddr_o(),.wdata_o(),.we_gpr_o(),.whart_o(),.we_fpr_o(),
    .amo_resp_i('0),.pc_o(),.csr_op_o(),.csr_wdata_o(),.csr_rdata_i('0),
    .csr_write_fflags_o(),.csr_exception_i(csr_ex),.commit_lsu_o(),.commit_lsu_ready_i(1'b1),
    .commit_tran_id_o(),.amo_valid_commit_o(),.no_st_pending_i(1'b1),.commit_csr_o(commit_csr),
    .fence_i_o(),.fence_o(),.flush_commit_o(flush_commit),.replay_o(),.sfence_vma_o(),
    .hfence_vvma_o(),.hfence_gvma_o(),.shared_tlb_flush_busy_i(1'b0),
    .break_from_trigger_i(1'b0),.dirty_fp_state_o());
  controller #(.CVA6Cfg(C),.bp_resolve_t(bp_t)) ctrl(
    .clk_i(clk),.rst_ni(rst_n),.v_i(1'b0),.set_pc_commit_o(set_pc),.flush_if_o(flush_if),
    .flush_unissued_instr_o(flush_unissued),.flush_id_o(flush_id),.flush_ex_o(flush_ex),
    .flush_bp_o(),.flush_icache_o(),.flush_dcache_o(),.flush_dcache_ack_i(1'b0),
    .flush_tlb_o(),.flush_tlb_vvma_o(),.flush_tlb_gvma_o(),.halt_csr_i(halt),
    .halt_acc_i(1'b0),.halt_frontend_o(),.halt_o(),.eret_i(1'b0),.ex_valid_i(1'b0),
    .set_debug_pc_i(1'b0),.resolved_branch_i('0),.flush_csr_i(1'b0),.fence_i_i(1'b0),
    .fence_i(1'b0),.sfence_vma_i(1'b0),.hfence_vvma_i(1'b0),.hfence_gvma_i(1'b0),
    .flush_commit_i(flush_commit),.replay_i(1'b0),.mem_replay_pc_o(),.flush_acc_i(1'b0),.smt_switch_i(1'b0));
  initial begin
    scenario=0;negative=$test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d",scenario));
    repeat(2)@(negedge clk);rst_n=1;@(negedge clk);
    entry[0].valid=1;entry[0].fu=CSR;entry[0].op=WFI;entry[0].pc=64'h80001000;
    case(scenario)
      0:begin end
      1:drop=1;
      2:csr_ex.valid=1;
      3:halt=1;
      4:entry[0].ex.valid=1;
      5:entry[0].valid=0;
      6:entry[0].op=CSR_READ;
      default:$fatal(1,"WFI_SCENARIO");
    endcase
    #4;expected=OOO&&scenario==0;
    if(flush_commit!=(expected^negative)||{set_pc,flush_if,flush_id,flush_ex,flush_unissued}!={5{expected}})
      $fatal(1,"WFI_RETIRE_RECOVERY flush=%b ctrl=%b",flush_commit,{set_pc,flush_if,flush_id,flush_ex,flush_unissued});
    if(scenario==0&&(ack!=1||!commit_csr))$fatal(1,"WFI_RETIRE_ACCEPT");
    $display("RTL_REVIEW_PASS wfi scenario=%0d",scenario);$finish;
  end
endmodule

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
    .clk_i(clk),.rst_ni(rst_n),.sb_full_o(sb_full),.sb_empty_o(),.spec_cancel_o(spec_cancel),
    .cancelled_mask_o(cancelled_mask),.sb_live_o(),.mem_violation_i(1'b0),.mem_violation_id_i('0),
    .phys_pending_i('0),.phys_replay_i('0),.phys_mod_i(1'b0),
    .flush_unissued_instr_i(flush_unissued),
    .flush_i(flush),.x_transaction_accepted_i(1'b0),.x_issue_writeback_i(1'b0),
    .x_id_i('0),.commit_instr_o(commit_instr),.commit_drop_o(commit_drop),
    .commit_replay_o(),.commit_ack_i(commit_ack),.decoded_instr_i(decoded),.orig_instr_i(orig),
    .decoded_instr_valid_i(decoded_valid),.decoded_instr_ack_o(decoded_ack),
    .issue_instr_o(issue_instr),.orig_instr_o(orig_o),
    .issue_instr_valid_o(issue_valid),.issue_ack_i(issue_ack),.fwd_o(fwd),
    .resolved_branch_i(resolved),.trans_id_i(wb_tid),.wbdata_i(wb_data),
    .ex_i(wb_ex),.wt_valid_i(wt_valid),.x_we_i(1'b0),.x_rd_i('0),
    .rvfi_issue_pointer_o(rvfi_issue),.rvfi_commit_pointer_o(rvfi_commit),
    .reclaim_ptr_o(),
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

module tb_g6lc_review_issue_order;
  import ariane_pkg::*;
  parameter int NP=2, HARTS=2;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.NrIssuePorts=NP; c.NrCommitPorts=2; c.NrHarts=HARTS;
    c.SuperscalarEn=1; c.XLEN=64; c.VLEN=64;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {
    logic [63:0] pc;
    fu_t fu;
    fu_op op;
    logic [4:0] rd, rs1, rs2;
    logic hart_id;
  } sbe_t;
  typedef struct packed { logic hart_id; } resolve_t;
  logic clk=0, rst_n=0, flush=0, resolve=0;
  logic [NP-1:0] valid='0, ack='0, granted;
  sbe_t [NP-1:0] entries='0;
  logic [1:0] commit_ack='0;
  sbe_t [1:0] committed='0;
  resolve_t branch='0;
  bit negative;
  int scenario;

  g6lc_issue_barrier #(.CVA6Cfg(C), .scoreboard_entry_t(sbe_t),
                      .bp_resolve_t(resolve_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .flush_unissued_instr_i(1'b0),
    .issue_valid_sb_i(valid), .issue_ack_iro_i(ack), .issue_instr_sb_i(entries),
    .decoded_instr_i(entries), .decoded_instr_valid_i(valid),
    .resolve_branch_i(resolve), .resolved_branch_i(branch),
    .commit_ack_i(commit_ack), .commit_instr_i(committed),
    .g1fh_csr_a0_i(1'b0), .g1fh_hart_i('0), .issue_valid_o(granted)
  );

  function automatic sbe_t stack_write(input logic [63:0] pc, input logic hart=0);
    return '{pc:pc, fu:ALU, op:ADD, rd:2, rs1:2, rs2:0, hart_id:hart};
  endfunction
  function automatic sbe_t control_flow(input logic [63:0] pc, input logic hart=0);
    return '{pc:pc, fu:CTRL_FLOW, op:ADD, rd:1, rs1:0, rs2:0, hart_id:hart};
  endfunction
  task automatic tick;
    clk=1; #2; clk=0; #2;
  endtask
  task automatic expect_grants(input logic [NP-1:0] expected);
    logic [NP-1:0] observed;
    #2;
    observed=granted;
    if (negative) observed[0]=!observed[0];
    if (observed !== expected)
      $fatal(1,"ISSUE_PROGRAM_ORDER scenario=%0d expected=%b observed=%b",scenario,expected,observed);
  endtask
  initial begin
    scenario=0; void'($value$plusargs("scenario=%d",scenario));
    negative=$test$plusargs("oracle_negative");
    #2; tick(); rst_n=1; #2;
    case (scenario)
      0: begin
        entries[0]=control_flow(64'h9000);
        entries[1]=stack_write(64'h1000);
        valid=NP'(3);
        expect_grants(NP'(3));
      end
      1: begin
        entries[0]=stack_write(64'h9000);
        entries[1]=control_flow(64'h1000);
        valid=NP'(3);
        expect_grants(NP'(1));
      end
      2: begin
        entries[0]=stack_write(64'h1000);
        entries[1]=control_flow(64'h9000, HARTS > 1 ? 1'b1 : 1'b0);
        valid=NP'(3);
        expect_grants(HARTS > 1 ? NP'(3) : NP'(1));
      end
      3: begin
        entries[0]=stack_write(64'h1000);
        valid=NP'(1); ack=NP'(1); tick(); ack='0;
        committed[0]=entries[0];
        entries[0]=control_flow(64'h9000);
        expect_grants('0);
        commit_ack=2'b01; tick(); commit_ack='0;
        expect_grants(NP'(1));
      end
      4: begin
        entries[0]=control_flow(64'h9000);
        entries[1]=stack_write(64'h1000);
        valid=NP'(1);
        expect_grants(NP'(1));
      end
      5: begin
        entries[0]='{pc:64'h9000, fu:CSR, op:CSR_WRITE, rd:5, rs1:1, rs2:0, hart_id:0};
        entries[1]=control_flow(64'h1000);
        valid=NP'(3);
        expect_grants(NP'(1));
      end
      default: $fatal(1,"ISSUE_ORDER_SCENARIO");
    endcase
    $display("RTL_REVIEW_PASS issue_order scenario=%0d ports=%0d harts=%0d",scenario,NP,HARTS);
    $finish;
  end
endmodule

module tb_g6lc_review_wt_tag;
  parameter int FIXUP=2;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64; c.IS_XLEN64=1; c.XLEN_ALIGN_BYTES=3; c.PLEN=56;
    c.DCACHE_INDEX_WIDTH=12; c.DCACHE_OFFSET_WIDTH=4; c.DCACHE_TAG_WIDTH=44;
    c.DCACHE_SET_ASSOC=2; c.DCACHE_LINE_WIDTH=128; c.DCACHE_NUM_WORDS=256;
    c.DCACHE_USER_WIDTH=64; c.WtDcacheWbufDepth=4; c.WtDcacheFixupDepth=FIXUP;
    c.DCACHE_MAX_TX=2; c.MEM_TID_WIDTH=1;
    c.NrCachedRegionRules=1; c.CachedRegionAddrBase[0]=64'h80000000;
    c.CachedRegionLength[0]=64'h40000000;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {
    logic [43:0] address_tag;
    logic [11:0] address_index;
    logic [63:0] data_wdata, data_wuser;
    logic [7:0] data_be;
    logic data_req, tag_valid, kill_req;
  } req_t;
  typedef struct packed {
    logic data_gnt, data_rvalid;
    logic [63:0] data_rdata, data_ruser;
    logic data_rid;
  } rsp_t;
  typedef struct packed {
    logic [52:0] wtag;
    logic [63:0] data, user;
    logic [7:0] dirty, valid, txblock;
    logic checked;
    logic [1:0] hit_oh;
  } wb_t;
  logic clk=0, rst_n=0, empty;
  req_t request='0;
  rsp_t response;
  logic miss_req, miss_ack=0, return_valid=0, return_id=0, miss_id;
  logic [55:0] miss_address;
  logic [63:0] miss_data;
  logic rd_req, rd_ack=0, tag_only;
  logic [43:0] rd_tag;
  logic [7:0] rd_index;
  logic [3:0] rd_offset;
  logic [1:0] rd_hit;
  logic [1:0] wr_req;
  logic [63:0] wr_data;
  logic [7:0] wr_be;
  wb_t [3:0] buffered;
  wb_t [FIXUP:0] fixups;
  logic previous_read=0;
  logic [43:0] previous_tag='0;
  int checks=0, requests=0, scenario=0;
  bit negative, saw_normal_tail=0;
  localparam logic [43:0] TAG_A=44'h81000, TAG_B=44'h82000;

  assign rd_hit = previous_read && rd_tag == previous_tag ? 2'b01 : 2'b00;
  wt_dcache_wbuffer #(.CVA6Cfg(C), .DCACHE_CL_IDX_WIDTH(8),
    .dcache_req_i_t(req_t), .dcache_req_o_t(rsp_t), .wbuffer_t(wb_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .cache_en_i(1'b1), .empty_o(empty), .not_ni_o(),
    .req_port_i(request), .req_port_o(response),
    .miss_ack_i(miss_ack), .miss_paddr_o(miss_address), .miss_req_o(miss_req),
    .miss_we_o(), .miss_wdata_o(miss_data), .miss_wuser_o(), .miss_vld_bits_o(),
    .miss_nc_o(), .miss_size_o(), .miss_id_o(miss_id),
    .miss_rtrn_vld_i(return_valid), .miss_rtrn_id_i(return_id),
    .rd_tag_o(rd_tag), .rd_idx_o(rd_index), .rd_off_o(rd_offset), .rd_req_o(rd_req),
    .rd_tag_only_o(tag_only), .rd_ack_i(rd_ack), .rd_data_i('0),
    .rd_vld_bits_i(2'b01), .rd_hit_oh_i(rd_hit), .wr_cl_vld_i(1'b0), .wr_cl_idx_i('0),
    .wr_req_o(wr_req), .wr_ack_i(1'b1), .wr_idx_o(), .wr_off_o(),
    .wr_data_o(wr_data), .wr_data_be_o(wr_be), .wr_user_o(),
    .inv_req_o(), .inv_ack_i(1'b1), .inv_idx_o(), .inv_way_oh_o(), .inv_vld_bits_o(),
    .pm_void_ack_o(), .pm_fixup_write_o(), .pm_fixup_inval_o(), .pm_fixup_full_o(),
    .fixup_wbuffer_o(fixups), .wbuffer_data_o(buffered), .tx_paddr_o(), .tx_vld_o()
  );

  task automatic cycle(input logic [43:0] accepting_tag=TAG_A);
    bit next_read;
    logic [43:0] observed;
    #2;
    if (previous_read) begin
      observed=rd_tag ^ (negative ? 44'd1 : 44'd0);
      if (observed !== previous_tag)
        $fatal(1,"WT_TAG_OWNER scenario=%0d checks=%0d expected=%h observed=%h pending=%b",
               scenario,checks,previous_tag,observed,rd_req);
      checks++;
    end
    if (previous_read && previous_tag == TAG_A && !rd_req) saw_normal_tail=1;
    next_read=rd_req && rd_ack;
    if (next_read) requests++;
    observed=rd_index == 0 && FIXUP>0 ? '0 :
        rd_index == 8'h12 ? (rd_offset == 4'h8 ? TAG_A : TAG_B) : accepting_tag;
    clk=1; #2; clk=0;
    previous_read=next_read;
    previous_tag=observed;
    #2;
  endtask
  task automatic offer(input logic [43:0] tag);
    request='0;
    request.address_tag=tag; request.address_index=tag == TAG_A ? 12'h128 : 12'h120;
    request.data_req=1; request.data_be='1; request.data_wdata=64'hcab51234;
    #2;
    if (!response.data_gnt) $fatal(1,"WT_TAG_SETUP no write credit");
    cycle(); request.data_req=0;
  endtask
  initial begin
    void'($value$plusargs("scenario=%d",scenario));
    negative=$test$plusargs("oracle_negative");
    cycle(); rst_n=1;
    offer(TAG_A);
    if (scenario==0) begin
      rd_ack=1;
      repeat (12) cycle();
      if (checks < 2 || !saw_normal_tail)
        $fatal(1,"WT_TAG_VACUOUS checks=%0d requests=%0d tail=%b",checks,requests,saw_normal_tail);
    end else if (scenario==1 && FIXUP>0) begin
      #2;
      if (!miss_req) $fatal(1,"WT_TAG_SETUP no memory request");
      return_id=miss_id; miss_ack=1; cycle(); miss_ack=0;
      return_valid=1; cycle(); return_valid=0;
      repeat (6) cycle();
      #2;
      if (!rd_req) $fatal(1,"WT_TAG_SETUP no fixup lookup");
      rd_ack=1;
      offer(TAG_B);
      repeat (12) cycle(TAG_B);
      if (checks < 2) $fatal(1,"WT_TAG_VACUOUS handoff not observed");
    end else $fatal(1,"WT_TAG_SCENARIO");
    $display("RTL_REVIEW_PASS wt_tag scenario=%0d depth=%0d checks=%0d",scenario,FIXUP,checks);
    $finish;
  end
endmodule

module tb_g6lc_review_smt_drain;
  parameter int NH=2, QUANTUM=1;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.NrHarts=NH;
    c.SmtPolicy=QUANTUM==128 ? config_pkg::SMT_HYBRID : config_pkg::SMT_RR;
    c.SmtFetchQuantum=QUANTUM; c.SmtStarveLimit=QUANTUM==128 ? 64 : 8;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  logic clk=0, rst_n=0, fetch=0, idle=0, quiesce, switched, trap_hold=0, flush=0;
  logic [NH-1:0] ready='1;
  logic [$clog2(NH>1?NH:2)-1:0] active;
  int scenario=0;
  bit negative;
  g6lc_thread_select #(.CVA6Cfg(C)) dut (
    .clk_i(clk), .rst_ni(rst_n), .fetch_fire_i(fetch), .issue_fire_i(1'b0), .flush_i(flush),
    .hold_i(1'b0), .drain_ready_i(idle), .quiesce_o(quiesce), .id_uniss_i(1'b0),
    .iq_valid_i(1'b0), .t0_imm_i(1'b0), .trap_hold_i(trap_hold), .hart_ready_i(ready),
    .hart_dmiss_i('0), .hart_imiss_i('0), .hart_block_i('0), .active_hart_o(active),
    .switch_o(switched), .t0_extra_o(), .switch_on_miss_o(), .switch_on_quantum_o(),
    .switch_on_starve_o()
  );
  task automatic tick;
    #2; clk=1; #2; clk=0; #2;
  endtask
  task automatic check_wait;
    if ((active != 0) || switched || !quiesce)
      $fatal(1,"SMT_DRAIN_EARLY active=%0d switch=%b quiesce=%b",active,switched,quiesce);
  endtask
  initial begin
    void'($value$plusargs("scenario=%d",scenario));
    negative=$test$plusargs("oracle_negative");
    tick(); rst_n=1; fetch=1; repeat (QUANTUM) tick(); fetch=0;
    if (NH==1) begin
      if (active != 0 || switched || quiesce) $fatal(1,"SMT_DRAIN_SINGLE");
    end else begin
      check_wait();
      repeat (4) begin tick(); check_wait(); end
      if (scenario==1) begin
        ready='d1; tick();
        if (active != 0 || switched || quiesce) $fatal(1,"SMT_DRAIN_CANCEL");
        ready='1; fetch=1; tick(); fetch=0; check_wait();
      end
      idle=1; trap_hold=1; tick(); check_wait();
      trap_hold=0; flush=1; tick(); check_wait();
      flush=0; tick();
      if (active != 1 || !switched || !quiesce) $fatal(1,"SMT_DRAIN_RELEASE");
      tick();
      if (quiesce || switched || active != 1) $fatal(1,"SMT_DRAIN_PULSE");
    end
    if ((int'(active) ^ int'(negative)) != (NH>1 ? 1 : 0))
      $fatal(1,"SMT_DRAIN_ORACLE");
    $display("RTL_REVIEW_PASS smt_drain harts=%0d scenario=%0d",NH,scenario);
    $finish;
  end
endmodule

module tb_g6lc_review_sbhead;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  // T6b-2a: per-hart oldest-issued head (sb_head_*). Parallel rotate /
  // find-first must produce exactly the ring-order head the serial scan
  // defined, including across a commit-pointer wrap.
  parameter int HARTS=2;
  parameter int SBDEPTH=16;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.NrIssuePorts=1; c.NrCommitPorts=1; c.NrWbPorts=1;
    c.NR_SB_ENTRIES=SBDEPTH; c.TRANS_ID_BITS=$clog2(SBDEPTH);
    c.XLEN=64; c.VLEN=64; c.GPLEN=64; c.FLen=64;
    c.NrHarts=HARTS; c.NrRgprPorts=2; c.SuperscalarEn=0;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  localparam int NSB=C.NR_SB_ENTRIES;
  localparam int HIDB=(C.NrHarts<=1)?1:$clog2(C.NrHarts);
  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C) scoreboard_entry_t;
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
    writeback_t [0:0] wb;
    scoreboard_entry_t [NSB-1:0] sbe;
  } forwarding_t;
  typedef logic [C.XLEN-1:0] rs3_len_t;

  logic clk=0,rst_n=0,flush=0,flush_unissued=0;
  logic commit_ack=0;
  scoreboard_entry_t [0:0] commit_instr;
  scoreboard_entry_t [0:0] decoded='{default:'0},issue_instr;
  logic [0:0][31:0] orig='0,orig_o;
  logic [0:0] decoded_valid='0,decoded_ack,issue_valid,issue_ack='0;
  logic [0:0] commit_drop;
  forwarding_t fwd;
  bp_resolve_t resolved='0;
  logic [0:0][C.TRANS_ID_BITS-1:0] wb_tid='0;
  logic [0:0][C.XLEN-1:0] wb_data='0;
  exception_t [0:0] wb_ex='{default:'0};
  logic [0:0] wt_valid='0;
  logic [0:0][C.TRANS_ID_BITS-1:0] rvfi_issue,rvfi_commit;
  logic [C.NrHarts-1:0] g1mf_v,g1mf_a3;
  logic [C.NrHarts-1:0][4:0] g1mf_rd;
  logic [C.NrHarts-1:0][C.VLEN-1:4] g1mf_line;
  logic [C.NrHarts-1:0][C.VLEN-1:0] head_pc;
  logic [C.NrHarts-1:0] head_v;
  bit negative;
  int scenario;

  scoreboard #(.CVA6Cfg(C),.bp_resolve_t(bp_resolve_t),.exception_t(exception_t),
      .scoreboard_entry_t(scoreboard_entry_t),.forwarding_t(forwarding_t),
      .writeback_t(writeback_t),.rs3_len_t(rs3_len_t)) dut (
    .clk_i(clk),.rst_ni(rst_n),.sb_full_o(),.sb_empty_o(),.spec_cancel_o(),
    .cancelled_mask_o(),.sb_live_o(),.mem_violation_i(1'b0),.mem_violation_id_i('0),
    .phys_pending_i('0),.phys_replay_i('0),.phys_mod_i(1'b0),
    .flush_unissued_instr_i(flush_unissued),
    .flush_i(flush),.x_transaction_accepted_i(1'b0),.x_issue_writeback_i(1'b0),
    .x_id_i('0),.commit_instr_o(commit_instr),.commit_drop_o(commit_drop),
    .commit_replay_o(),.commit_ack_i(commit_ack),.decoded_instr_i(decoded),
    .orig_instr_i(orig),
    .decoded_instr_valid_i(decoded_valid),.decoded_instr_ack_o(decoded_ack),
    .issue_instr_o(issue_instr),.orig_instr_o(orig_o),
    .issue_instr_valid_o(issue_valid),.issue_ack_i(issue_ack),.fwd_o(fwd),
    .resolved_branch_i(resolved),.trans_id_i(wb_tid),.wbdata_i(wb_data),
    .ex_i(wb_ex),.wt_valid_i(wt_valid),.x_we_i(1'b0),.x_rd_i('0),
    .rvfi_issue_pointer_o(rvfi_issue),.rvfi_commit_pointer_o(rvfi_commit),
    .reclaim_ptr_o(),
    .sb_head_pc_o(head_pc),.sb_head_valid_o(head_v),
    .g1mf_v_o(g1mf_v),.g1mf_rd_o(g1mf_rd),.g1mf_line_o(g1mf_line),
    .g1mf_a3_o(g1mf_a3));

  task automatic tick;clk=1; #2; clk=0; #2;endtask

  // Allocate one instruction for hart h at pc. fu=NONE self-validates.
  task automatic alloc(input int h,input logic [63:0] pc);
    decoded='{default:'0};
    decoded[0].fu=NONE;
    decoded[0].pc=C.VLEN'(pc);
    decoded[0].rd=5'd1;
    decoded[0].hart_id=HIDB'(h);
    decoded_valid=1'b1;
    issue_ack=1'b1;
    #2;
    if(!issue_valid[0]||!decoded_ack[0]) $fatal(1,"SBHEAD_ALLOC pc=%h",pc);
    tick();
    decoded_valid='0;issue_ack='0;
  endtask

  task automatic commit;
    commit_ack=1'b1; tick(); commit_ack=1'b0; #2;
  endtask

  task automatic chk_head(input int h,input logic [63:0] want,input string tag);
    logic [63:0] want_adj;
    want_adj=want ^ (negative?64'd4:64'd0);
    if(head_v[h]!==1'b1) $fatal(1,"%s hart=%0d valid=0",tag,h);
    if(head_pc[h]!==want_adj)
      $fatal(1,"%s hart=%0d pc got=%h want=%h",tag,h,head_pc[h],want_adj);
  endtask

  task automatic chk_dead(input int h,input string tag);
    if(head_v[h]!==(negative?1'b1:1'b0))
      $fatal(1,"%s hart=%0d valid=%b",tag,h,head_v[h]);
  endtask

  initial begin
    negative=$test$plusargs("oracle_negative");scenario=0;
    void'($value$plusargs("scenario=%d",scenario));
    #2;tick();rst_n=1;#2;
    if(scenario==0)begin
      // Interleaved harts: heads must track each hart's own oldest slot.
      alloc(0,64'h100); alloc(1,64'h200); alloc(0,64'h104); alloc(1,64'h204);
      chk_head(0,64'h100,"SBHEAD_ORDER"); chk_head(1,64'h200,"SBHEAD_ORDER");
      commit(); commit();
      chk_head(0,64'h104,"SBHEAD_STEP"); chk_head(1,64'h204,"SBHEAD_STEP");
      commit(); commit();
      chk_dead(0,"SBHEAD_DRAIN"); chk_dead(1,"SBHEAD_DRAIN");
    end
    else if(scenario==1)begin
      // Wrap: commit pointer at 14, allocs land at 14 (h1), 15 (h0), 0 (h1).
      for(int n=0;n<14;n++)begin alloc(0,64'h40+64'(n)*4); commit(); end
      alloc(1,64'h300); alloc(0,64'h400); alloc(1,64'h304);
      chk_head(0,64'h400,"SBHEAD_WRAP"); chk_head(1,64'h300,"SBHEAD_WRAP");
      commit();
      chk_head(1,64'h304,"SBHEAD_WRAP_STEP");
    end
    else if(scenario==2)begin
      // Hart-1-only traffic: hart 0 has no live entry, so no head.
      alloc(1,64'h500); alloc(1,64'h504);
      chk_dead(0,"SBHEAD_HOLE");
      chk_head(1,64'h500,"SBHEAD_HOLE_H1");
    end
    else $fatal(1,"SBHEAD_SCENARIO");
    $display("RTL_REVIEW_PASS sbhead scenario=%0d harts=%0d sb=%0d",scenario,HARTS,SBDEPTH);
    $finish;
  end
endmodule

// ======================================================================
// T6b-2b: per-access architectural context in the banked CSR regfile.
// Bank 0 is programmed with context set A and bank 1 with set B through each
// hart's commit CSR-write path. The LSU-side outputs must follow lsu_hart_i,
// the PMP pair lsu_chk_hart_i, the fetch-side outputs active_hart_i, and a
// WFI must park only its own hart under mixed residency while the drained
// handoff keeps the global halt_csr_o. +oracle_negative flips every
// expectation (must fatal).
// ======================================================================
module tb_g6lc_review_csrbank;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  `include "rvfi_types.svh"
  parameter int DRAINED=1;
  localparam int HARTS=2;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.IS_XLEN64=1;
    c.NrHarts=HARTS;c.SmtDrainedHandoff=DRAINED;
    c.NrIssuePorts=2;c.NrCommitPorts=2;c.NrWbPorts=2;c.NrRgprPorts=2;
    c.NR_SB_ENTRIES=8;c.TRANS_ID_BITS=3;
    c.RVS=1;c.RVU=1;c.RVA=1;c.MmuPresent=1;
    c.MODE_SV=config_pkg::ModeSv39;c.PtLevels=3;c.VpnLen=27;c.SV=39;
    c.PPNW=44;c.GPPNW=44;c.ASID_WIDTH=16;c.VMID_WIDTH=14;
    // Derived-width fields as build_config_pkg computes them (cva6_cfg_empty
    // leaves them 0, which silently drops satp_t's mode field).
    c.ModeW=4;c.ASIDW=16;c.VMIDW=14;
    c.NrPMPEntries=4;
    c.RVZCMT=1;  // scenario 3 programs per-bank jvt
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C) sbe_t;
  typedef `G6LC_IRQ_CTRL_T(C) irq_ctrl_t;
  typedef struct packed {logic[C.XLEN-7:0] base;logic[5:0] mode;} jvt_t;
  typedef `RVFI_PROBES_CSR_T(C) rvfi_csr_t;

  // Context set A (bank 0) / set B (bank 1).
  localparam logic[63:0] MSTATUS_A=64'h120800;   // MPRV=1, MPP=S, TVM=1
  localparam logic[63:0] MSTATUS_B=64'h6E1800;   // MPRV=1, MPP=M, SUM=1, MXR=1, TW=1, TSR=1
  localparam logic[63:0] JVT_A=64'h0000_1234_5678_9A40;
  localparam logic[63:0] JVT_B=64'h0000_0ABC_DEF0_1280;
  localparam logic[63:0] SATP_A=(64'd8<<60)|(64'd1<<44)|64'hABCDE;
  localparam logic[63:0] SATP_B=(64'd8<<60)|(64'd2<<44)|64'h12345;
  localparam logic[63:0] MIE_A=64'h888,MIE_B=64'h222;
  // NA4 is never supported, NAPOT needs PMPNapotEn, and a locked entry
  // blocks the pmpaddr write — use unlocked TOR forms.
  localparam logic[63:0] PMPCFG_A=64'h0F,PMPCFG_B=64'h0D;
  localparam logic[63:0] PMPADDR_A=64'h222,PMPADDR_B=64'h777;

  logic clk=0,rst_n=0;
  logic active_hart=0,lsu_hart=0,lsu_chk_hart=0;
  logic halt_csr;
  logic[1:0] hart_halt;
  sbe_t commit_i='0;
  logic[1:0] commit_ack='0;
  // T6b-4b: committing hart per port (banked ack routing). The tasks drive
  // both ports at commit_i.hart_id; scenario 4 splits them.
  logic[1:0][0:0] commit_hart='0;
  exception_t ex_i='0;
  fu_op csr_op=ADD;
  logic[11:0] csr_addr='0;
  logic[63:0] csr_wdata='0;
  logic en_ld_tr,en_ld_gtr;
  riscv::priv_lvl_t ld_st_priv;
  logic ld_st_v,sum_o,vs_sum_o,mxr_o,vmxr_o;
  logic[43:0] satp_ppn,fet_satp_ppn;
  logic[15:0] asid_o,fet_asid_o;
  logic[43:0] vsatp_ppn,hgatp_ppn;
  logic[15:0] vs_asid_o;
  logic[13:0] vmid_o;
  logic[43:0] fet_vsatp_ppn,fet_hgatp_ppn;
  logic[15:0] fet_vs_asid_o;
  logic[13:0] fet_vmid_o;
  logic fet_mxr_o,fet_vmxr_o,fet_mbe_o,mbe_commit_o;
  riscv::pmpcfg_t[3:0] pmpcfg,fet_pmpcfg;
  logic[3:0][53:0] pmpaddr,fet_pmpaddr;
  irq_ctrl_t irq_ctrl;
  irq_ctrl_t[1:0] irq_ctrl_b;
  logic[63:0] instret0,instret1;
  riscv::priv_lvl_t[1:0] priv_lvl_b;
  logic[1:0] v_b;
  logic mbe_o,v_commit_o;
  // T6b-3a probes.
  logic[1:0] tvm_b,tw_b,vtw_b,tsr_b,hu_b;
  jvt_t[1:0] jvt_b;
  logic tvm_act;
  logic[11:0] perf_addr;
  logic perf_we;
  logic[63:0] csr_rdata;
  int scenario;bit negative;
  always #5 clk=~clk;

  g6lc_smt_csr_bank #(.CVA6Cfg(C),.exception_t(exception_t),.jvt_t(jvt_t),
      .irq_ctrl_t(irq_ctrl_t),.scoreboard_entry_t(sbe_t),.rvfi_probes_csr_t(rvfi_csr_t)) dut(
    .clk_i(clk),.rst_ni(rst_n),
    .active_hart_i(active_hart),.lsu_hart_i(lsu_hart),.lsu_chk_hart_i(lsu_chk_hart),
    .switch_i(1'b0),.time_irq_i('0),.rtc_time_i('0),
    .flush_o(),.halt_csr_o(halt_csr),.hart_halt_o(hart_halt),
    .commit_instr_i(commit_i),.commit_ack_i(commit_ack),
    .commit_hart_i(commit_hart),.step_b_o(),
    .boot_addr_i('0),.hart_id_base_i('0),.ex_i(ex_i),
    .csr_op_i(csr_op),.csr_addr_i(csr_addr),.csr_wdata_i(csr_wdata),.csr_rdata_o(csr_rdata),
    .dirty_fp_state_i(1'b0),.csr_write_fflags_i(1'b0),.dirty_v_state_i(1'b0),
    .pc_i('0),.csr_exception_o(),.epc_o(),.eret_o(),.trap_vector_base_o(),
    .priv_lvl_o(),.mbe_o(mbe_o),.v_o(),
    .acc_fflags_ex_i('0),.acc_fflags_ex_valid_i(1'b0),
    .fs_o(),.vfs_o(),.fflags_o(),.frm_o(),.fprec_o(),.vs_o(),
    .irq_ctrl_o(irq_ctrl),.irq_ctrl_b_o(irq_ctrl_b),
    .priv_lvl_b_o(priv_lvl_b),.v_b_o(v_b),.v_commit_o(v_commit_o),
    .en_translation_o(),.en_g_translation_o(),
    .en_ld_st_translation_o(en_ld_tr),.en_ld_st_g_translation_o(en_ld_gtr),
    .ld_st_priv_lvl_o(ld_st_priv),.ld_st_v_o(ld_st_v),
    .csr_hs_ld_st_inst_i(1'b0),
    .sum_o(sum_o),.vs_sum_o(vs_sum_o),.mxr_o(mxr_o),.vmxr_o(vmxr_o),
    .satp_ppn_o(satp_ppn),.asid_o(asid_o),
    .vsatp_ppn_o(vsatp_ppn),.vs_asid_o(vs_asid_o),
    .hgatp_ppn_o(hgatp_ppn),.vmid_o(vmid_o),
    .fet_satp_ppn_o(fet_satp_ppn),.fet_asid_o(fet_asid_o),
    .fet_vsatp_ppn_o(fet_vsatp_ppn),.fet_vs_asid_o(fet_vs_asid_o),
    .fet_hgatp_ppn_o(fet_hgatp_ppn),.fet_vmid_o(fet_vmid_o),
    .fet_mxr_o(fet_mxr_o),.fet_vmxr_o(fet_vmxr_o),.fet_mbe_o(fet_mbe_o),
    .mbe_commit_o(mbe_commit_o),
    .mcbie_o(),.scbie_o(),.hcbie_o(),.mcbcfe_o(),.scbcfe_o(),.hcbcfe_o(),
    .mcbze_o(),.scbze_o(),.hcbze_o(),.pbmte_o(),.set_debug_pc_o(),
    .tvm_o(tvm_act),.tw_o(),.vtw_o(),.tsr_o(),.hu_o(),.debug_mode_o(),.single_step_o(),
    // T6b-3a: per-bank decode context + PMU inhibit; sampled in scenario 3.
    .tvm_b_o(tvm_b),.tw_b_o(tw_b),.vtw_b_o(vtw_b),.tsr_b_o(tsr_b),.hu_b_o(hu_b),
    .debug_mode_b_o(),.fs_b_o(),.vfs_b_o(),.vs_b_o(),.frm_b_o(),
    .mcbie_b_o(),.scbie_b_o(),.hcbie_b_o(),.mcbcfe_b_o(),.scbcfe_b_o(),.hcbcfe_b_o(),
    .mcbze_b_o(),.scbze_b_o(),.hcbze_b_o(),.jvt_b_o(jvt_b),
    .mcountinhibit_b_o(),
    .icache_en_o(),.dcache_en_o(),.acc_cons_en_o(),
    .ai_aicfg_o(),.ai_ais_o(),.ai_issue_ok_o(),.ai_q_en_o(),.ai_qid_o(),
    .dirty_ai_state_i(1'b0),.ai_setcfg_we_i(1'b0),.ai_setcfg_wdata_i('0),
    .perf_addr_o(perf_addr),.perf_data_o(),.perf_data_i('0),.perf_we_o(perf_we),
    .scountovf_i('0),.lcofi_i('0),
    .pmpcfg_o(pmpcfg),.pmpaddr_o(pmpaddr),
    .fet_pmpcfg_o(fet_pmpcfg),.fet_pmpaddr_o(fet_pmpaddr),
    .mcountinhibit_o(),.rvfi_csr_o(),.jvt_o(),.debug_from_trigger_o(),
    .vaddr_from_lsu_i('0),.orig_instr_i('0),.store_result_i('0),
    .irq_i('0),.ipi_i('0),.debug_req_i(1'b0),
    .break_from_trigger_o());

  task automatic chk1(input string n,input logic v,input logic e);
    if(v!==(negative?!e:e))$fatal(1,"%s got=%b exp=%b",n,v,e);
  endtask
  task automatic chk64(input string n,input logic[63:0] v,input logic[63:0] e);
    if(v!==(negative?(e^64'd1):e))$fatal(1,"%s got=%h exp=%h",n,v,e);
  endtask
  task automatic chkpriv(input string n,input riscv::priv_lvl_t v,input riscv::priv_lvl_t e);
    if(v!==(negative?(e==riscv::PRIV_LVL_M?riscv::PRIV_LVL_S:riscv::PRIV_LVL_M):e))
      $fatal(1,"%s got=%0d exp=%0d",n,v,e);
  endtask

  task automatic csr_write(input int hart,input logic[11:0] addr,input logic[63:0] wdata);
    @(negedge clk);
    commit_i='0;commit_i.valid=1;commit_i.hart_id=1'(hart);
    commit_hart={2{1'(hart)}};
    csr_op=CSR_WRITE;csr_addr=addr;csr_wdata=wdata;commit_ack=2'b11;
    @(negedge clk);
    csr_op=ADD;commit_ack='0;commit_i='0;
  endtask

  task automatic wfi_commit(input int hart);
    @(negedge clk);
    commit_i='0;commit_i.valid=1;commit_i.hart_id=1'(hart);
    commit_hart={2{1'(hart)}};
    csr_op=WFI;commit_ack=2'b11;
    @(negedge clk);
    csr_op=ADD;commit_ack='0;commit_i='0;
  endtask

  initial begin
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    negative=$test$plusargs("oracle_negative");
    repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
    // Program bank 0 = set A, bank 1 = set B, each through its own commit path.
    csr_write(0,12'h300,MSTATUS_A);csr_write(0,12'h180,SATP_A);
    csr_write(0,12'h304,MIE_A);csr_write(0,12'h3A0,PMPCFG_A);csr_write(0,12'h3B0,PMPADDR_A);
    csr_write(0,12'h017,JVT_A);
    csr_write(1,12'h300,MSTATUS_B);csr_write(1,12'h180,SATP_B);
    csr_write(1,12'h304,MIE_B);csr_write(1,12'h3A0,PMPCFG_B);csr_write(1,12'h3B0,PMPADDR_B);
    csr_write(1,12'h017,JVT_B);
    repeat(2)@(negedge clk);
    if(scenario==0)begin
      // active_hart=0: fetch context is always set A.
      active_hart=0;
      // lsu=0, chk=0: everything set A.
      lsu_hart=0;lsu_chk_hart=0;@(negedge clk);
      chk1 ("CSRBANK_LSU_ENTR",en_ld_tr,1'b1);
      chkpriv("CSRBANK_LSU_PRIV",ld_st_priv,riscv::PRIV_LVL_S);
      chk1 ("CSRBANK_LSU_SUM",sum_o,1'b0);chk1("CSRBANK_LSU_MXR",mxr_o,1'b0);
      chk64("CSRBANK_LSU_SATP",{20'b0,satp_ppn},SATP_A[43:0]);
      chk64("CSRBANK_LSU_ASID",{48'b0,asid_o},64'd1);
      chk64("CSRBANK_LSU_PMPCFG",{56'b0,pmpcfg[0]},PMPCFG_A&64'hFF);
      chk64("CSRBANK_LSU_PMPA",{10'b0,pmpaddr[0]},PMPADDR_A);
      // lsu=1, chk=1: LSU context set B.
      lsu_hart=1;lsu_chk_hart=1;@(negedge clk);
      chk1 ("CSRBANK_LSU_ENTR",en_ld_tr,1'b0);
      chkpriv("CSRBANK_LSU_PRIV",ld_st_priv,riscv::PRIV_LVL_M);
      chk1 ("CSRBANK_LSU_SUM",sum_o,1'b1);chk1("CSRBANK_LSU_MXR",mxr_o,1'b1);
      chk64("CSRBANK_LSU_SATP",{20'b0,satp_ppn},SATP_B[43:0]);
      chk64("CSRBANK_LSU_ASID",{48'b0,asid_o},64'd2);
      chk64("CSRBANK_LSU_PMPCFG",{56'b0,pmpcfg[0]},PMPCFG_B&64'hFF);
      chk64("CSRBANK_LSU_PMPA",{10'b0,pmpaddr[0]},PMPADDR_B);
      // lsu=0 but chk=1: lookup context A, check-stage PMP set B.
      lsu_hart=0;lsu_chk_hart=1;@(negedge clk);
      chk1 ("CSRBANK_LSU_ENTR",en_ld_tr,1'b1);
      chkpriv("CSRBANK_LSU_PRIV",ld_st_priv,riscv::PRIV_LVL_S);
      chk64("CSRBANK_LSU_SATP",{20'b0,satp_ppn},SATP_A[43:0]);
      chk64("CSRBANK_CHK_PMPCFG",{56'b0,pmpcfg[0]},PMPCFG_B&64'hFF);
      chk64("CSRBANK_CHK_PMPA",{10'b0,pmpaddr[0]},PMPADDR_B);
      // Fetch context: always set A while active_hart=0.
      chk64("CSRBANK_FET_SATP",{20'b0,fet_satp_ppn},SATP_A[43:0]);
      chk64("CSRBANK_FET_ASID",{48'b0,fet_asid_o},64'd1);
      chk64("CSRBANK_FET_PMPCFG",{56'b0,fet_pmpcfg[0]},PMPCFG_A&64'hFF);
      chk64("CSRBANK_FET_PMPA",{10'b0,fet_pmpaddr[0]},PMPADDR_A);
      // Interrupt context follows the fetch hart; the per-hart array exposes both.
      chk64("CSRBANK_IRQ_MIE",irq_ctrl.mie,MIE_A);
      chk64("CSRBANK_IRQ_B0",irq_ctrl_b[0].mie,MIE_A);
      chk64("CSRBANK_IRQ_B1",irq_ctrl_b[1].mie,MIE_B);
      active_hart=1;@(negedge clk);
      chk64("CSRBANK_IRQ_MIE",irq_ctrl.mie,MIE_B);
      chk64("CSRBANK_FET_SATP",{20'b0,fet_satp_ppn},SATP_B[43:0]);
      active_hart=0;@(negedge clk);
    end else if(scenario==1 && DRAINED)begin
      // Drained handoff: a WFI on the active hart halts the commit stage globally.
      active_hart=0;lsu_hart=0;lsu_chk_hart=0;
      wfi_commit(0);repeat(2)@(negedge clk);
      chk1("CSRBANK_WFI_HALT",halt_csr,1'b1);
      chk64("CSRBANK_WFI_VEC",{62'b0,hart_halt},64'd1);
    end else if(scenario==2 && !DRAINED)begin
      // Mixed residency: a WFI on hart 1 parks only hart 1.
      active_hart=0;lsu_hart=0;lsu_chk_hart=0;
      wfi_commit(1);repeat(2)@(negedge clk);
      chk1("CSRBANK_WFI_HALT",halt_csr,1'b0);
      chk64("CSRBANK_WFI_VEC",{62'b0,hart_halt},64'd2);
    end else if(scenario==3)begin
      // T6b-3a: commit-hart ownership of the PMU sideband and per-bank
      // decode context. active_hart=0 throughout; a commit on hart 1 must
      // drive bank 1's perf signals and bank 1's CSR read data.
      active_hart=0;lsu_hart=0;lsu_chk_hart=0;
      @(negedge clk);
      commit_i='0;commit_i.valid=1;commit_i.hart_id=1'd1;
      commit_hart={2{1'd1}};
      csr_op=CSR_WRITE;csr_addr=12'hB03;csr_wdata=64'h5;commit_ack=2'b11;
      #1;
      chk1 ("CSRBANK_PERF_HART",perf_we,1'b1);
      chk64("CSRBANK_PERF_ADDR",{52'b0,perf_addr},64'hB03);
      @(negedge clk);
      commit_ack='0;
      // Read mie as a commit on hart 1: bank 1's value, not bank 0's (mie is
      // a plain R/W register — readback equals the written bits).
      csr_op=CSR_SET;csr_addr=12'h304;csr_wdata='0;commit_ack=2'b11;#1;
      chk64("CSRBANK_RDATA_HART",csr_rdata,MIE_B);
      @(negedge clk);
      csr_op=ADD;commit_ack='0;commit_i='0;
      // The _b arrays expose each bank's own decode context.
      chk1 ("CSRBANK_TVM_B0",tvm_b[0],1'b1);chk1("CSRBANK_TVM_B1",tvm_b[1],1'b0);
      chk1 ("CSRBANK_TW_B1",tw_b[1],1'b1);chk1("CSRBANK_TW_B0",tw_b[0],1'b0);
      chk1 ("CSRBANK_TSR_B1",tsr_b[1],1'b1);chk1("CSRBANK_TSR_B0",tsr_b[0],1'b0);
      chk64("CSRBANK_JVT_B0",{6'b0,jvt_b[0].base},JVT_A>>6);
      chk64("CSRBANK_JVT_B1",{6'b0,jvt_b[1].base},JVT_B>>6);
      // Scalars still follow the active hart.
      chk1 ("CSRBANK_TVM_ACT",tvm_act,tvm_b[0]);
    end else if(scenario==4 && !DRAINED)begin
      // T6b-4b CSRBANK_ACK_PORT: banked commit acks route per port by
      // commit_hart_i — a port-1 ack for hart 1 must bump only bank 1's
      // instret while port 0 presents hart 0, and vice versa.
      commit_i='0;commit_i.valid=1;csr_addr=12'hB02;commit_ack='0;
      csr_op=CSR_READ;  // csr_rdata is gated by csr_read — ADD returns 0
      commit_i.hart_id=1'd0;#1;instret0=csr_rdata;
      commit_i.hart_id=1'd1;#1;instret1=csr_rdata;
      // Port-1-only ack for hart 1 (cross-hart commit): bank1 +1, bank0 +0.
      csr_op=ADD;
      commit_i.hart_id=1'd0;commit_hart={1'd1,1'd0};commit_ack=2'b10;
      @(negedge clk);commit_ack='0;
      csr_op=CSR_READ;
      commit_i.hart_id=1'd0;#1;chk64("CSRBANK_ACK_PORT",csr_rdata,instret0);
      commit_i.hart_id=1'd1;#1;chk64("CSRBANK_ACK_PORT",csr_rdata,instret1+64'd1);
      // Complement: a port-0-only ack for hart 0 bumps only bank 0.
      csr_op=ADD;
      commit_hart={2{1'd0}};commit_ack=2'b01;
      @(negedge clk);commit_ack='0;
      csr_op=CSR_READ;
      commit_i.hart_id=1'd1;#1;chk64("CSRBANK_ACK_PORT",csr_rdata,instret1+64'd1);
      commit_i.hart_id=1'd0;#1;chk64("CSRBANK_ACK_PORT",csr_rdata,instret0+64'd1);
      csr_op=ADD;
    end else $fatal(1,"CSRBANK_SCENARIO");
    $display("RTL_REVIEW_PASS csrbank scenario=%0d drained=%0d",scenario,DRAINED);
    $finish;
  end
endmodule

// ======================================================================
// Leaf: perf_counters — T6b-3a per-hart event banking.
// Commit-derived events land in the committing hart's bank; the HPM CSR
// access banks by csr_hart_i; mcountinhibit is per bank.
// ======================================================================
module tb_g6lc_review_perf;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  parameter int DRAINED=0;
  localparam int HARTS=2;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.IS_XLEN64=1;
    c.NrHarts=HARTS;c.SmtDrainedHandoff=DRAINED;
    c.NrIssuePorts=2;c.NrCommitPorts=2;c.NrWbPorts=2;c.NrRgprPorts=2;
    c.NR_SB_ENTRIES=8;c.TRANS_ID_BITS=3;
    c.RVS=1;c.RVU=1;c.RVA=1;c.MmuPresent=1;
    c.DCACHE_SET_ASSOC=8;c.DcacheIdWidth=4;
    c.DCACHE_INDEX_WIDTH=12;c.DCACHE_TAG_WIDTH=44;c.DCACHE_USER_WIDTH=1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  localparam int HW = (C.NrHarts <= 1) ? 1 : $clog2(C.NrHarts);
  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C) sbe_t;
  typedef struct packed {
    logic                    valid;
    logic [C.VLEN-1:0]       pc;
    logic [C.VLEN-1:0]       target_address;
    logic                    is_mispredict;
    logic                    is_taken;
    cf_t                     cf_type;
    logic [HW-1:0]           hart_id;
    logic                    ckpt_restore;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
  } bp_t;
  typedef struct packed {logic req;logic[C.VLEN-1:0] vaddr;} icache_dreq_t;
  typedef struct packed {
    logic[C.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic[C.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic[C.XLEN-1:0]               data_wdata;
    logic[C.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                           data_req;
    logic                           data_we;
    logic[(C.XLEN/8)-1:0]           data_be;
    logic[1:0]                      data_size;
    logic[C.DcacheIdWidth-1:0]      data_id;
    logic                           kill_req;
    logic                           tag_valid;
    logic[7:0]                      cbo_op;
  } dcache_req_i_t;
  localparam int NumPorts=3;

  // CSR addresses and event encodings (see riscv_pkg / ariane_pkg).
  localparam logic[11:0] A_MHPMCTR3=12'hB03,A_MHPMEV3=12'h323;
  localparam logic[63:0] EV_INT=64'd20;      // legacy group, idx 20 = integer instr
  localparam logic[63:0] EV_LOAD=64'd5;      // idx 5 = load accesses

  logic clk=0,rst_n=0;
  sbe_t[1:0] commit_sbe='0;
  logic[1:0] commit_ack='0;
  logic[11:0] addr_i='0;
  logic we_i=0;
  logic[63:0] data_i='0,data_o;
  logic[HW-1:0] csr_hart='0;
  riscv::priv_lvl_t[HARTS-1:0] priv_lvl_b='{default:riscv::PRIV_LVL_M};
  logic[HARTS-1:0][31:0] mcinhibit='0;
  int scenario;bit negative;
  always #5 clk=~clk;

  perf_counters #(.CVA6Cfg(C),.NumPorts(NumPorts),.bp_resolve_t(bp_t),
      .exception_t(exception_t),.scoreboard_entry_t(sbe_t),
      .icache_dreq_t(icache_dreq_t),.dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(logic)) dut(
    .clk_i(clk),.rst_ni(rst_n),.debug_mode_i(1'b0),
    .priv_lvl_b_i(priv_lvl_b),
    .addr_i(addr_i),.we_i(we_i),.data_i(data_i),.data_o(data_o),
    .hart_i('0),.csr_hart_i(csr_hart),
    .commit_instr_i(commit_sbe),.commit_ack_i(commit_ack),
    .l1_icache_miss_i(1'b0),.itlb_miss_i(1'b0),.dtlb_miss_i(1'b0),
    .ex_i('0),.eret_i(1'b0),
    .resolved_branch_i('0),.branch_exceptions_i('0),
    .l1_icache_access_i('0),.l1_dcache_access_i('{default:'0}),
    .l1_dcache_miss_i(1'b0),.miss_vld_bits_i('0),
    .i_tlb_flush_i(1'b0),.sb_full_i(1'b0),.if_empty_i(1'b0),
    .stall_issue_i(1'b0),
    .ooo_rename_stall_i(1'b0),.ooo_rob_full_i(1'b0),.ooo_iq_full_i(1'b0),
    .ooo_lsq_stall_i(1'b0),.ooo_stl_forward_i(1'b0),.spec_cancel_i(1'b0),
    .ooo_phys_replay_i(1'b0),.coh_inval_apply_i(1'b0),
    .ai_pmu_op_i(1'b0),.ai_pmu_mma_i(1'b0),.ai_pmu_post_i(1'b0),
    .ai_pmu_t0_i(1'b0),.ai_pmu_busy_i(1'b0),
    .l3_miss_i(1'b0),.l3_hit_i(1'b0),.pf_issue_i(1'b0),.pf_train_i(1'b0),
    .l2_miss_i(1'b0),
    .dcache_wbuf_void_ack_i(1'b0),.dcache_wbuf_fixup_write_i(1'b0),
    .dcache_wbuf_fixup_inval_i(1'b0),.dcache_wbuf_fixup_full_i(1'b0),
    .mcountinhibit_b_i(mcinhibit));

  task automatic chk64(input string n,input logic[63:0] v,input logic[63:0] e);
    if(v!==(negative?(e^64'd1):e))$fatal(1,"%s got=%h exp=%h",n,v,e);
  endtask

  // HPM CSR write to bank h (the access bank is csr_hart_i, as the bank
  // drives it from the committing hart).
  task automatic pwrite(input int h,input logic[11:0] a,input logic[63:0] d);
    @(negedge clk);csr_hart=HW'(h);addr_i=a;data_i=d;we_i=1;
    @(negedge clk);we_i=0;
  endtask
  task automatic setrd(input int h,input logic[11:0] a);
    @(negedge clk);we_i=0;csr_hart=HW'(h);addr_i=a;#1;
  endtask
  // One commit cycle: port p retires an ALU op of hart hp.
  task automatic commit2(input int h0,input int h1);
    @(negedge clk);
    commit_sbe='0;
    commit_sbe[0].valid=1;commit_sbe[0].fu=ALU;commit_sbe[0].hart_id=HW'(h0);
    commit_sbe[1].valid=1;commit_sbe[1].fu=ALU;commit_sbe[1].hart_id=HW'(h1);
    commit_ack=2'b11;
    @(negedge clk);commit_ack='0;commit_sbe='0;
  endtask

  initial begin
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    negative=$test$plusargs("oracle_negative");
    repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
    // Both banks select the integer-instructions event on mhpmcounter3.
    pwrite(0,A_MHPMEV3,EV_INT);pwrite(1,A_MHPMEV3,EV_INT);
    if(scenario==0)begin
      // Same-cycle commits on both harts: each bank counts its own retire.
      commit2(0,1);repeat(2)@(negedge clk);
      setrd(1,A_MHPMCTR3);chk64("PERF_BANK1_RETIRE",data_o,64'd1);
      setrd(0,A_MHPMCTR3);chk64("PERF_BANK0_RETIRE",data_o,64'd1);
    end else if(scenario==1)begin
      // mcountinhibit is per bank: inhibiting bank 1 never touches bank 0.
      mcinhibit[1][3]=1'b1;  // mhpmcounter3 sits at inhibit bit i+2 = 3
      commit2(0,1);repeat(2)@(negedge clk);
      setrd(1,A_MHPMCTR3);chk64("PERF_INHIBIT_B1",data_o,64'd0);
      setrd(0,A_MHPMCTR3);chk64("PERF_UNINHIBIT_B0",data_o,64'd1);
    end else if(scenario==2)begin
      // The HPM CSR access is banked by csr_hart_i.
      pwrite(1,A_MHPMCTR3,64'h42);
      setrd(1,A_MHPMCTR3);chk64("PERF_CSR_HART",data_o,64'h42);
      setrd(0,A_MHPMCTR3);chk64("PERF_CSR_PEER",data_o,64'd0);
    end else if(scenario==3 && DRAINED)begin
      // Drained geometry: every commit belongs to hart 0 — today's counts.
      // The event is one bit per bank per cycle, so two same-hart ports still
      // count +1, exactly as the pre-banked design did.
      commit2(0,0);repeat(2)@(negedge clk);
      setrd(0,A_MHPMCTR3);chk64("PERF_DRAIN_B0",data_o,64'd1);
      setrd(1,A_MHPMCTR3);chk64("PERF_DRAIN_B1",data_o,64'd0);
    end else $fatal(1,"PERF_SCENARIO");
    $display("RTL_REVIEW_PASS perf scenario=%0d drained=%0d",scenario,DRAINED);
    $finish;
  end
endmodule

// ======================================================================
// T6b-2b leaf: hart tag in the private TLB. Under mixed residency an entry
// is private to its filling hart; under the drained handoff the tag is
// ignored and entries stay shared across harts (today's behaviour).
// ======================================================================
module tb_g6lc_review_tlb;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  parameter int DRAINED=0;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.IS_XLEN64=1;
    c.NrHarts=2;c.SmtDrainedHandoff=DRAINED;
    c.PtLevels=3;c.VpnLen=27;c.SV=39;c.PPNW=44;c.GPPNW=44;
    c.ASID_WIDTH=16;c.VMID_WIDTH=14;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {
    logic n;logic[1:0] pbmt;logic[6:0] reserved;logic[C.PPNW-1:0] ppn;
    logic[1:0] rsw;logic d,a,g,u,x,w,r,v;
  } pte_t;
  typedef struct packed {
    logic valid;logic is_napot_64k;logic[C.PtLevels-2:0][0:0] is_page;
    logic[C.VpnLen-1:0] vpn;logic[C.ASID_WIDTH-1:0] asid;
    logic[C.VMID_WIDTH-1:0] vmid;logic hart;
    logic v_st_enbl;pte_t content;pte_t g_content;
  } upd_t;

  localparam logic[C.VLEN-1:0] VA=64'h0000_0000_4000_0000;
  localparam logic[C.PPNW-1:0] P0=44'h0000_0011_1111,P1=44'h0000_0022_2222;

  logic clk=0,rst_n=0;
  upd_t upd='0;
  logic lu_access=0,lu_hart=0;
  logic[C.ASID_WIDTH-1:0] lu_asid='0;
  logic[C.VMID_WIDTH-1:0] lu_vmid='0;
  logic[C.VLEN-1:0] lu_vaddr='0;
  logic lu_hit;
  pte_t lu_content,lu_gcontent;
  logic[C.PtLevels-2:0] lu_is_page;
  int scenario;bit negative;
  always #5 clk=~clk;

  cva6_tlb #(.CVA6Cfg(C),.pte_cva6_t(pte_t),.tlb_update_cva6_t(upd_t),
      .TLB_ENTRIES(4),.HYP_EXT(0)) dut(
    .clk_i(clk),.rst_ni(rst_n),
    .flush_i(1'b0),.flush_vvma_i(1'b0),.flush_gvma_i(1'b0),
    .s_st_enbl_i(1'b1),.g_st_enbl_i(1'b0),.v_i(1'b0),
    .update_i(upd),
    .lu_access_i(lu_access),.lu_asid_i(lu_asid),.lu_vmid_i(lu_vmid),
    .lu_hart_i(lu_hart),.lu_vaddr_i(lu_vaddr),
    .lu_gpaddr_o(),.lu_content_o(lu_content),.lu_g_content_o(lu_gcontent),
    .asid_to_be_flushed_i('0),.vmid_to_be_flushed_i('0),
    .vaddr_to_be_flushed_i('0),.gpaddr_to_be_flushed_i('0),
    .lu_is_page_o(lu_is_page),.lu_hit_o(lu_hit));

  task automatic fill(input int hart,input logic[C.PPNW-1:0] ppn);
    @(negedge clk);
    upd='0;upd.valid=1;upd.vpn=C.VpnLen'(VA>>12);upd.asid=16'd1;upd.hart=1'(hart);
    upd.v_st_enbl=1'b1;upd.is_page=2'b01;
    upd.content='0;upd.content.ppn=ppn;upd.content.v=1;upd.content.r=1;
    upd.content.w=1;upd.content.x=1;upd.content.a=1;upd.content.d=1;upd.content.u=1;
    lu_vaddr=VA;lu_asid=16'd1;lu_hart=1'(hart);
    @(negedge clk);upd='0;
  endtask

  // inv marks the scenario's discriminating check: only it inverts under
  // +oracle_negative, so the run fatals on the labelled expectation.
  task automatic chk_ppn(input int hart,input logic[C.PPNW-1:0] exp,input bit hit,
                         input string n,input bit inv);
    @(negedge clk);
    lu_vaddr=VA;lu_asid=16'd1;lu_hart=1'(hart);lu_access=1;
    #1;
    if(lu_hit!==(inv?!hit:hit))$fatal(1,"%s hit=%b exp=%b",n,lu_hit,hit);
    if(lu_hit && lu_content.ppn!==(inv?exp^44'd1:exp))
      $fatal(1,"%s ppn=%h exp=%h",n,lu_content.ppn,exp);
    @(negedge clk);lu_access=0;
  endtask

  initial begin
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    negative=$test$plusargs("oracle_negative");
    repeat(4)@(negedge clk);rst_n=1;repeat(2)@(negedge clk);
    if(scenario==0 && !DRAINED)begin
      fill(0,P0);
      // A hit marks the filled way as recently used so the next PLRU victim
      // is a different entry (fills alone never touch the PLRU tree).
      chk_ppn(0,P0,1,"TLB_HART0_WARM",0);
      fill(1,P1);
      chk_ppn(0,P0,1,"TLB_HART0_OWN",negative);
      chk_ppn(1,P1,1,"TLB_HART1_OWN",0);
    end else if(scenario==1 && !DRAINED)begin
      fill(0,P0);
      chk_ppn(0,P0,1,"TLB_HART0_OWN",0);
      chk_ppn(1,P0,0,"TLB_HART1_MISS",negative);
    end else if(scenario==2 && DRAINED)begin
      // Drained handoff: the tag is ignored and the shared entry serves both
      // harts — exactly today's first-match behaviour.
      fill(0,P0);
      chk_ppn(0,P0,1,"TLB_HART0_SHARED",0);
      chk_ppn(1,P0,1,"TLB_HART1_SHARED",negative);
    end else $fatal(1,"TLB_SCENARIO");
    $display("RTL_REVIEW_PASS tlb scenario=%0d drained=%0d",scenario,DRAINED);
    $finish;
  end
endmodule

// ======================================================================
// T6b-2b leaf: hart tag in the shared TLB (same isolation/sharing oracle as
// the private TLB leaf, through the shared-TLB lookup/update handshake).
// ======================================================================
module tb_g6lc_review_stlb;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  parameter int DRAINED=0;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.IS_XLEN64=1;
    c.NrHarts=2;c.SmtDrainedHandoff=DRAINED;
    c.PtLevels=3;c.VpnLen=27;c.SV=39;c.PPNW=44;c.GPPNW=44;
    c.ASID_WIDTH=16;c.VMID_WIDTH=14;
    c.UseSharedTlb=1;c.SharedTlbDepth=64;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef struct packed {
    logic n;logic[1:0] pbmt;logic[6:0] reserved;logic[C.PPNW-1:0] ppn;
    logic[1:0] rsw;logic d,a,g,u,x,w,r,v;
  } pte_t;
  typedef struct packed {
    logic valid;logic is_napot_64k;logic[C.PtLevels-2:0][0:0] is_page;
    logic[C.VpnLen-1:0] vpn;logic[C.ASID_WIDTH-1:0] asid;
    logic[C.VMID_WIDTH-1:0] vmid;logic hart;
    logic v_st_enbl;pte_t content;pte_t g_content;
  } upd_t;

  localparam logic[C.VLEN-1:0] VA=64'h0000_0000_4000_0000;
  localparam logic[C.PPNW-1:0] P0=44'h0000_0011_1111,P1=44'h0000_0022_2222;

  logic clk=0,rst_n=0;
  upd_t upd='0,dtlb_update;
  logic dtlb_access=0,dtlb_hart=0,dtlb_hit_i=0;
  logic[C.ASID_WIDTH-1:0] dtlb_asid='0;
  logic[C.VLEN-1:0] dtlb_vaddr='0;
  int scenario;bit negative;
  always #5 clk=~clk;

  cva6_shared_tlb #(.CVA6Cfg(C),.pte_cva6_t(pte_t),.tlb_update_cva6_t(upd_t),
      .SHARED_TLB_WAYS(2),.HYP_EXT(0)) dut(
    .clk_i(clk),.rst_ni(rst_n),
    .flush_i(1'b0),.flush_vvma_i(1'b0),.flush_gvma_i(1'b0),
    .s_st_enbl_i(1'b1),.g_st_enbl_i(1'b0),.v_i(1'b0),
    .s_ld_st_enbl_i(1'b1),.g_ld_st_enbl_i(1'b0),.ld_st_v_i(1'b0),
    .dtlb_asid_i(dtlb_asid),.itlb_asid_i('0),
    .lu_vmid_i('0),.itlb_vmid_i('0),
    .itlb_hart_i('0),.dtlb_hart_i(dtlb_hart),
    .itlb_access_i(1'b0),.itlb_hit_i(1'b0),.itlb_vaddr_i('0),
    .dtlb_access_i(dtlb_access),.dtlb_hit_i(dtlb_hit_i),.dtlb_vaddr_i(dtlb_vaddr),
    .shared_tlb_miss_i(1'b1),
    .asid_to_be_flushed_i('0),.vaddr_to_be_flushed_i('0),
    .vmid_to_be_flushed_i('0),.gpaddr_to_be_flushed_i('0),
    .itlb_update_o(),.dtlb_update_o(dtlb_update),
    .itlb_miss_o(),.dtlb_miss_o(),.flush_busy_o(),
    .shared_tlb_access_o(),.shared_tlb_hit_o(),.shared_tlb_vaddr_o(),
    .itlb_req_o(),.shared_tlb_update_i(upd));

  task automatic fill(input int hart,input logic[C.PPNW-1:0] ppn);
    @(negedge clk);
    upd='0;upd.valid=1;upd.vpn=C.VpnLen'(VA>>12);upd.asid=16'd1;upd.hart=1'(hart);
    upd.v_st_enbl=1'b1;upd.is_page=2'b01;
    upd.content='0;upd.content.ppn=ppn;upd.content.v=1;upd.content.r=1;
    upd.content.w=1;upd.content.x=1;upd.content.a=1;upd.content.d=1;upd.content.u=1;
    @(negedge clk);upd='0;repeat(2)@(negedge clk);
  endtask

  // The update is a single combinational cycle after the tag read — latch it
  // over a bounded window rather than sampling at one negedge. inv marks the
  // scenario's discriminating check (see the private-TLB leaf).
  task automatic chk_ppn(input int hart,input logic[C.PPNW-1:0] exp,input bit hit,
                         input string n,input bit inv);
    upd_t got;
    got='0;
    @(negedge clk);
    dtlb_vaddr=VA;dtlb_asid=16'd1;dtlb_hart=1'(hart);dtlb_access=1;
    for(int c=0;c<8;c++)begin
      @(negedge clk);
      if(c==0)dtlb_access=0;
      if(dtlb_update.valid)got=dtlb_update;
    end
    if(got.valid!==(inv?!hit:hit))
      $fatal(1,"%s update_valid=%b exp=%b",n,got.valid,hit);
    if(got.valid && got.content.ppn!==(inv?exp^44'd1:exp))
      $fatal(1,"%s ppn=%h exp=%h",n,got.content.ppn,exp);
  endtask

  initial begin
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    negative=$test$plusargs("oracle_negative");
    repeat(4)@(negedge clk);rst_n=1;repeat(2)@(negedge clk);
    if(scenario==0 && !DRAINED)begin
      fill(0,P0);fill(1,P1);
      chk_ppn(0,P0,1,"STLB_HART0_OWN",negative);
      chk_ppn(1,P1,1,"STLB_HART1_OWN",0);
    end else if(scenario==1 && !DRAINED)begin
      fill(0,P0);
      chk_ppn(0,P0,1,"STLB_HART0_OWN",0);
      chk_ppn(1,P0,0,"STLB_HART1_MISS",negative);
    end else if(scenario==2 && DRAINED)begin
      fill(0,P0);
      chk_ppn(0,P0,1,"STLB_HART0_SHARED",0);
      chk_ppn(1,P0,1,"STLB_HART1_SHARED",negative);
    end else $fatal(1,"STLB_SCENARIO");
    $display("RTL_REVIEW_PASS stlb scenario=%0d drained=%0d",scenario,DRAINED);
    $finish;
  end
endmodule

// ======================================================================
// T6b-2b leaf: check-stage context in the MMU. The data permission check
// runs one cycle after the DTLB lookup on the registered request — the
// context registered with the request (ctx_*_q) must be used, not the live
// inputs of the next hart's request. A tiny PTW memory model answers the
// page-table reads; each hart's satp root points at a different gigapage
// leaf so walks prove per-hart translation. Review-only mutations:
//   G6LC_MUT_TLB_NO_HART_TAG — TLB hart tag ignored (scenario 0 flips)
//   G6LC_MUT_MMU_LIVE_CTX  — check stage uses live context (1/3 flip)
// ======================================================================
module tb_g6lc_review_mmuctx;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64;c.VLEN=64;c.PLEN=56;c.GPLEN=64;c.IS_XLEN64=1;
    c.NrHarts=2;c.SmtDrainedHandoff=0;
    c.PtLevels=3;c.VpnLen=27;c.SV=39;c.PPNW=44;c.GPPNW=44;
    c.ASID_WIDTH=16;c.VMID_WIDTH=14;
    c.InstrTlbEntries=4;c.DataTlbEntries=4;
    c.DCACHE_INDEX_WIDTH=12;c.DCACHE_TAG_WIDTH=44;
    c.DcacheIdWidth=4;c.DCACHE_USER_WIDTH=1;c.MEM_TID_WIDTH=2;
    c.NrPMPEntries=0;
    c.SharedTlbDepth=64;  // instantiated unconditionally inside cva6_mmu
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C=configuration();
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef struct packed {
    logic fetch_valid;logic[C.PLEN-1:0] fetch_paddr;exception_t fetch_exception;
  } icache_areq_t;
  typedef struct packed {logic fetch_req;logic[C.VLEN-1:0] fetch_vaddr;} icache_arsp_t;
  typedef struct packed {
    logic[C.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic[C.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic[C.XLEN-1:0]               data_wdata;
    logic[C.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                           data_req;
    logic                           data_we;
    logic[(C.XLEN/8)-1:0]           data_be;
    logic[1:0]                      data_size;
    logic[C.DcacheIdWidth-1:0]      data_id;
    logic                           kill_req;
    logic                           tag_valid;
    logic[7:0]                      cbo_op;  // cbo_t (logic[7:0] in cva6)
  } dcache_req_i_t;
  typedef struct packed {
    logic data_gnt;logic data_rvalid;
    logic[C.DcacheIdWidth-1:0] data_rid;
    logic[C.XLEN-1:0] data_rdata;
    logic[C.DCACHE_USER_WIDTH-1:0] data_ruser;
  } dcache_req_o_t;

  localparam logic[C.VLEN-1:0] VA=64'h0000_0000_4000_0000;  // vpn2 index 1
  localparam logic[C.PPNW-1:0] SATP_A=44'h0000_0020_00,SATP_B=44'h0000_0040_00;
  localparam logic[25:0] PHIA=26'hABC,PHIB=26'h123;    // gigapage PPN[43:18]
  localparam logic[C.PLEN-1:0] EXP_A=(C.PLEN'(PHIA)<<30)|(C.PLEN'(VA)&56'h3FFFFFFF);
  localparam logic[C.PLEN-1:0] EXP_B=(C.PLEN'(PHIB)<<30)|(C.PLEN'(VA)&56'h3FFFFFFF);

  logic clk=0,rst_n=0;
  // Request stream.
  logic lsu_req=0,lsu_is_store=0,lsu_hart=0;
  logic[C.VLEN-1:0] lsu_vaddr='0;
  // Two context sets, muxed by lsu_hart exactly as the CSR bank does.
  logic[1:0] ctx_en_tr='0;
  riscv::priv_lvl_t[1:0] ctx_priv='{riscv::PRIV_LVL_M,riscv::PRIV_LVL_M};
  logic[1:0] ctx_sum='0,ctx_mxr='0;
  logic[1:0][C.PPNW-1:0] ctx_satp='0;
  logic[1:0][C.ASID_WIDTH-1:0] ctx_asid='0;
  // MMU outputs.
  logic dtlb_hit,lsu_valid;
  logic[C.PPNW-1:0] dtlb_ppn;
  logic[C.PLEN-1:0] lsu_paddr;
  exception_t lsu_exception;
  // PTW memory model: grant combinationally, return the PTE one cycle later.
  dcache_req_i_t req_o;
  dcache_req_o_t req_i;
  logic req_rvalid=0;
  logic[63:0] req_rdata='0;
  logic[63:0] pmem[longint unsigned];
  int scenario;bit negative;
  always #5 clk=~clk;

  always_comb begin
    req_i='0;
    req_i.data_gnt=req_o.data_req;
    req_i.data_rvalid=req_rvalid;
    req_i.data_rdata=req_rdata;
  end
  always_ff @(posedge clk)begin
    req_rvalid<=req_o.data_req&&req_i.data_gnt;
    if(req_o.data_req&&req_i.data_gnt)
      req_rdata<=pmem[longint'({req_o.address_tag,req_o.address_index})];
  end

  function automatic logic[63:0] leaf_pte(input logic[25:0] ppn_hi);
    // Sv39 gigapage leaf: V=R=W=X=U=A=D=1; PPN[17:0] ignored by hardware.
    logic[63:0] p;
    p='0;p[0]=1;p[1]=1;p[2]=1;p[3]=1;p[4]=1;p[6]=1;p[7]=1;
    p[53:10]={ppn_hi,18'b0};
    return p;
  endfunction

  cva6_mmu #(.CVA6Cfg(C),.icache_areq_t(icache_areq_t),.icache_arsp_t(icache_arsp_t),
      .dcache_req_i_t(dcache_req_i_t),.dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),.HYP_EXT(0)) dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(1'b0),
    .enable_translation_i(1'b1),.enable_g_translation_i(1'b0),
    .en_ld_st_translation_i(ctx_en_tr[lsu_hart]),.en_ld_st_g_translation_i(1'b0),
    .icache_areq_i('0),.icache_areq_o(),
    .misaligned_ex_i('0),
    .lsu_req_i(lsu_req),.lsu_vaddr_i(lsu_vaddr),.lsu_tinst_i('0),
    .lsu_is_store_i(lsu_is_store),.csr_hs_ld_st_inst_o(),
    .lsu_dtlb_hit_o(dtlb_hit),.lsu_dtlb_ppn_o(dtlb_ppn),
    .lsu_valid_o(lsu_valid),.lsu_paddr_o(lsu_paddr),.lsu_exception_o(lsu_exception),
    .priv_lvl_i(riscv::PRIV_LVL_M),.v_i(1'b0),
    .ld_st_priv_lvl_i(ctx_priv[lsu_hart]),.ld_st_v_i(1'b0),
    .sum_i(ctx_sum[lsu_hart]),.vs_sum_i(1'b0),
    .mxr_i(ctx_mxr[lsu_hart]),.vmxr_i(1'b0),.mbe_i(1'b0),
    .hlvx_inst_i(1'b0),.hs_ld_st_inst_i(1'b0),
    .satp_ppn_i(ctx_satp[lsu_hart]),.vsatp_ppn_i('0),.hgatp_ppn_i('0),
    .asid_i(ctx_asid[lsu_hart]),.vs_asid_i('0),
    .asid_to_be_flushed_i('0),.vmid_i('0),.vmid_to_be_flushed_i('0),
    .fetch_hart_i('0),.lsu_hart_i(lsu_hart),
    .fet_asid_i('0),.fet_vs_asid_i('0),.fet_vmid_i('0),
    .fet_satp_ppn_i('0),.fet_vsatp_ppn_i('0),.fet_hgatp_ppn_i('0),
    .fet_mxr_i(1'b0),.fet_vmxr_i(1'b0),.fet_mbe_i(1'b0),
    .fet_pmpcfg_i('0),.fet_pmpaddr_i('0),
    .vaddr_to_be_flushed_i('0),.gpaddr_to_be_flushed_i('0),
    .flush_tlb_i(1'b0),.flush_tlb_vvma_i(1'b0),.flush_tlb_gvma_i(1'b0),
    .shared_tlb_flush_busy_o(),.itlb_miss_o(),.dtlb_miss_o(),
    .req_port_i(req_i),.req_port_o(req_o),
    .pmpcfg_i('0),.pmpaddr_i('0));

  task automatic setup();
    // hart 0: S-mode, SUM=0, Sv39 root A; hart 1: U-mode, root B.
    ctx_en_tr=2'b11;ctx_priv='{riscv::PRIV_LVL_U,riscv::PRIV_LVL_S};
    ctx_sum=2'b00;ctx_mxr=2'b00;
    ctx_satp='{SATP_B,SATP_A};ctx_asid='{16'd1,16'd1};
    pmem[(longint'(SATP_A)<<12)+8]=leaf_pte(PHIA);
    pmem[(longint'(SATP_B)<<12)+8]=leaf_pte(PHIB);
  endtask

  // Issue one request and hold it until the MMU answers (hit or walk).
  task automatic request(input int hart,input logic[C.VLEN-1:0] va,
                         output logic[C.PLEN-1:0] paddr,output exception_t ex);
    lsu_req=1;lsu_hart=1'(hart);lsu_vaddr=va;lsu_is_store=0;
    @(negedge clk);
    while(!lsu_valid)@(negedge clk);
    paddr=lsu_paddr;ex=lsu_exception;
    lsu_req=0;
  endtask

  // inv marks the scenario's discriminating check: only it inverts under
  // +oracle_negative, so the run fatals on the labelled expectation.
  task automatic chk_paddr(input logic[C.PLEN-1:0] v,input logic[C.PLEN-1:0] e,
                           input string n,input bit inv);
    if(v!==(inv?e^56'd1:e))$fatal(1,"%s paddr=%h exp=%h",n,v,e);
  endtask
  task automatic chk_cause(input exception_t ex,input logic[63:0] cause,input bit vld,
                           input string n,input bit inv);
    if(ex.valid!==(inv?!vld:vld))$fatal(1,"%s ex.valid=%b exp=%b",n,ex.valid,vld);
    if(ex.valid && ex.cause!==cause)$fatal(1,"%s cause=%h exp=%h",n,ex.cause,cause);
  endtask

  initial begin
    logic[C.PLEN-1:0] pa;exception_t xe;
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    negative=$test$plusargs("oracle_negative");
    pmem.delete();
    repeat(4)@(negedge clk);rst_n=1;repeat(2)@(negedge clk);setup();
    if(scenario==0)begin
      // Walk per hart, then hits: TLB hart tag at the MMU boundary.
      @(negedge clk);request(0,VA,pa,xe);chk_paddr(pa,EXP_A,"MMUCTX_WALK_H0",negative);
      request(1,VA,pa,xe);chk_paddr(pa,EXP_B,"MMUCTX_WALK_H1",0);
      request(0,VA,pa,xe);chk_paddr(pa,EXP_A,"MMUCTX_HIT_H0",0);
      request(1,VA,pa,xe);chk_paddr(pa,EXP_B,"MMUCTX_HIT_H1",0);
    end else if(scenario==1)begin
      // Warm both harts' entries first (same checks as scenario 0).
      @(negedge clk);request(0,VA,pa,xe);chk_paddr(pa,EXP_A,"MMUCTX_WALK_H0",0);
      request(1,VA,pa,xe);chk_paddr(pa,EXP_B,"MMUCTX_WALK_H1",0);
      // Skew: cycle N hart0 S-mode SUM=0 request (U page → page fault),
      // cycle N+1 hart1 U-mode request (clean). The check of hart0's request
      // must replay hart0's registered context, not hart1's live U-mode.
      @(negedge clk);
      lsu_req=1;lsu_hart=0;lsu_vaddr=VA;lsu_is_store=0;
      @(posedge clk); #1;  // A registered; B issued during A's check window.
      lsu_hart=1;
      @(negedge clk);
      if(!lsu_valid)$fatal(1,"MMUCTX_SKEW_NO_RESP");
      chk_cause(lsu_exception,riscv::LOAD_PAGE_FAULT,1,"MMUCTX_SKEW_H0_FAULT",negative);
      chk_paddr(lsu_paddr,EXP_A,"MMUCTX_SKEW_H0_PADDR",0);
      @(negedge clk);  // B registered at the posedge; its response is live now.
      if(!lsu_valid)$fatal(1,"MMUCTX_SKEW_NO_RESP_B");
      chk_cause(lsu_exception,'0,0,"MMUCTX_SKEW_H1_CLEAN",0);
      chk_paddr(lsu_paddr,EXP_B,"MMUCTX_SKEW_H1_PADDR",0);
      lsu_req=0;
    end else if(scenario==2)begin
      // Mirror: hart0 U-mode (clean) followed by hart1 S-mode SUM=0 (fault).
      ctx_priv='{riscv::PRIV_LVL_S,riscv::PRIV_LVL_U};
      @(negedge clk);request(0,VA,pa,xe);request(1,VA,pa,xe);
      @(negedge clk);
      lsu_req=1;lsu_hart=0;lsu_vaddr=VA;lsu_is_store=0;
      @(posedge clk); #1;
      lsu_hart=1;
      @(negedge clk);
      if(!lsu_valid)$fatal(1,"MMUCTX_MIR_NO_RESP");
      chk_cause(lsu_exception,'0,0,"MMUCTX_MIR_H0_CLEAN",0);
      chk_paddr(lsu_paddr,EXP_A,"MMUCTX_MIR_H0_PADDR",0);
      @(negedge clk);
      if(!lsu_valid)$fatal(1,"MMUCTX_MIR_NO_RESP_B");
      chk_cause(lsu_exception,riscv::LOAD_PAGE_FAULT,1,"MMUCTX_MIR_H1_FAULT",negative);
      chk_paddr(lsu_paddr,EXP_B,"MMUCTX_MIR_H1_PADDR",0);
      lsu_req=0;
    end else if(scenario==3)begin
      // Translation enable is check-stage context too: hart1 issues a bare
      // M-mode request right after hart0's translated request — hart0's
      // response must still be the translated P0, not the identity map.
      @(negedge clk);request(0,VA,pa,xe);request(1,VA,pa,xe);
      ctx_en_tr=2'b01;ctx_priv='{riscv::PRIV_LVL_M,riscv::PRIV_LVL_U};
      @(negedge clk);
      lsu_req=1;lsu_hart=0;lsu_vaddr=VA;lsu_is_store=0;
      @(posedge clk); #1;
      lsu_hart=1;
      @(negedge clk);
      if(!lsu_valid)$fatal(1,"MMUCTX_EN_NO_RESP");
      chk_cause(lsu_exception,'0,0,"MMUCTX_EN_H0_CLEAN",negative);
      chk_paddr(lsu_paddr,EXP_A,"MMUCTX_EN_H0_PADDR",0);
      @(negedge clk);
      if(!lsu_valid)$fatal(1,"MMUCTX_EN_NO_RESP_B");
      chk_cause(lsu_exception,'0,0,"MMUCTX_EN_H1_CLEAN",0);
      chk_paddr(lsu_paddr,C.PLEN'(VA),"MMUCTX_EN_H1_BARE",0);
      lsu_req=0;
    end else $fatal(1,"MMUCTX_SCENARIO");
    $display("RTL_REVIEW_PASS mmuctx scenario=%0d",scenario);
    $finish;
  end
endmodule
