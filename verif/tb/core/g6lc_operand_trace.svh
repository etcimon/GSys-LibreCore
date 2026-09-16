// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`define G6LC_OT_SB issue_stage_i.i_scoreboard
`define G6LC_OT_RO issue_stage_i.i_issue_read_operands
`define G6LC_OT_LS ex_stage_i.lsu_i
`define G6LC_OT_LD ex_stage_i.lsu_i.i_load_unit
`define G6LC_OT_ST ex_stage_i.lsu_i.i_store_unit.store_buffer_i

if (1) begin : gen_g6lc_operand_trace
  integer enabled, fd;
  longint unsigned limit_t, next_gen;
  longint unsigned slot_gen[CVA6Cfg.NR_SB_ENTRIES];
  longint unsigned load_gen[CVA6Cfg.NrLoadBufEntries];
  fu_data_t secondary_data;
  logic [CVA6Cfg.XLEN-1:0] secondary_result;
  if (CVA6Cfg.NrALUs >= 2) begin : gen_secondary
    assign secondary_data = ex_stage_i.alu_wrapper_i.gen_alu2.fu_data_bypass;
    assign secondary_result = ex_stage_i.alu_result[1];
  end else begin : gen_no_secondary
    assign secondary_data = '0;
    assign secondary_result = '0;
  end
  initial begin
    enabled = 0;
    limit_t = 30000;
    fd = 0;
    void'($value$plusargs("g6lc_operand_trace=%d", enabled));
    void'($value$plusargs("g6lc_operand_trace_limit=%d", limit_t));
    if (enabled != 0) begin
      fd = $fopen($sformatf("operand-trace-%0d.log", hart_id_i), "w");
      if (!fd) $fatal(1, "operand trace file unavailable");
      $fdisplay(fd, "[ot-config] xlen=%0d harts=%0d issue=%0d commit=%0d sb=%0d loads=%0d tid_bits=%0d sbe_bits=%0d limit=%0d", CVA6Cfg.XLEN, CVA6Cfg.NrHarts, CVA6Cfg.NrIssuePorts, CVA6Cfg.NrCommitPorts, CVA6Cfg.NR_SB_ENTRIES, CVA6Cfg.NrLoadBufEntries, CVA6Cfg.TRANS_ID_BITS, $bits(scoreboard_entry_t), limit_t);
    end
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      next_gen = 1;
      foreach (slot_gen[i]) slot_gen[i] = 0;
      foreach (load_gen[i]) load_gen[i] = 0;
    end else if (enabled != 0 && $time <= limit_t) begin
      if (smt_switch || flush_ctrl_if || flush_unissued_instr_ctrl_id || flush_ctrl_ex || |issue_stage_i.cancelled_mask_o) begin
        $fdisplay(fd, "[ot-control] t=%0t active=%0d switch=%0d restore=%0d restore_pc=%h saved_pc=%h transport_pc=%h if_flush=%0d unissued_flush=%0d ex_flush=%0d cancel=%h", $time, smt_active_hart, smt_switch, smt_pc_restore, smt_npc_restore, i_smt_pc_bank.npc_live_i, smt_npc_live, flush_ctrl_if, flush_unissued_instr_ctrl_id, flush_ctrl_ex, issue_stage_i.cancelled_mask_o);
        for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          if (`G6LC_OT_SB.decoded_instr_valid_i[p])
            $fdisplay(fd, "[ot-pending] t=%0t p=%0d h=%0d pc=%h bits=%h ack=%0d", $time, p, `G6LC_OT_SB.decoded_instr_i[p].hart_id, `G6LC_OT_SB.decoded_instr_i[p].pc, `G6LC_OT_SB.orig_instr_i[p], `G6LC_OT_SB.decoded_instr_ack_o[p]);
      end
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (i_frontend.i_instr_queue.fire_prefix[p] || (smt_switch && fetch_valid_if_id[p]))
          $fdisplay(fd, "[ot-fetch] t=%0t p=%0d h=%0d pc=%h bits=%h flush=%0d fire=%0d", $time, p, fetch_entry_if_id[p].hart_id, fetch_entry_if_id[p].address, fetch_entry_if_id[p].instruction, flush_ctrl_if, i_frontend.i_instr_queue.fire_prefix[p]);
      end
      if (resolved_branch.valid)
        $fdisplay(fd, "[ot-branch] t=%0t gen=%0d tid=%0d h=%0d pc=%h target=%h taken=%0d mispredict=%0d cf=%0d", $time, slot_gen[resolved_branch.trans_id], resolved_branch.trans_id, resolved_branch.hart_id, resolved_branch.pc, resolved_branch.target_address, resolved_branch.is_taken, resolved_branch.is_mispredict, resolved_branch.cf_type);
      for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin
        if (commit_macro_ack[p] || we_gpr_commit_id[p])
          $fdisplay(fd, "[ot-retire] t=%0t p=%0d gen=%0d tid=%0d h=%0d pc=%h op=%0d rd=%0d value=%h ack=%0d macro_ack=%0d drop=%0d ex=%0d cause=%h we=%0d whart=%0d waddr=%0d wdata=%h", $time, p, slot_gen[commit_instr_id_commit[p].trans_id], commit_instr_id_commit[p].trans_id, commit_instr_id_commit[p].hart_id, commit_instr_id_commit[p].pc, commit_instr_id_commit[p].op, commit_instr_id_commit[p].rd, commit_instr_id_commit[p].result, commit_ack[p], commit_macro_ack[p], commit_drop_id_commit[p], commit_instr_id_commit[p].ex.valid, commit_instr_id_commit[p].ex.cause, we_gpr_commit_id[p], whart_commit_id[p], waddr_commit_id[p], wdata_commit_id[p]);
      end
      for (int p = 0; p < CVA6Cfg.NrWbPorts; p++) begin
        if (wt_valid_ex_id[p])
          $fdisplay(fd, "[ot-wb] t=%0t p=%0d gen=%0d tid=%0d value=%h ex=%0d live=%0d cancelled=%0d owner=%0d pc=%h", $time, p, slot_gen[trans_id_ex_id[p]], trans_id_ex_id[p], wbdata_ex_id[p], ex_ex_ex_id[p].valid, `G6LC_OT_SB.mem_q[trans_id_ex_id[p]].issued, `G6LC_OT_SB.mem_q[trans_id_ex_id[p]].cancelled, `G6LC_OT_SB.mem_q[trans_id_ex_id[p]].sbe.hart_id, `G6LC_OT_SB.mem_q[trans_id_ex_id[p]].sbe.pc);
      end
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (alu_valid_id_ex[p] || branch_valid_id_ex[p] || lsu_valid_id_ex[p] || ex_stage_i.alu2_valid_i[p])
          $fdisplay(fd, "[ot-ex] t=%0t p=%0d gen=%0d tid=%0d op=%0d a=%h b=%h imm=%h alu=%0d alu2=%0d branch=%0d lsu=%0d", $time, p, slot_gen[fu_data_id_ex[p].trans_id], fu_data_id_ex[p].trans_id, fu_data_id_ex[p].operation, fu_data_id_ex[p].operand_a, fu_data_id_ex[p].operand_b, fu_data_id_ex[p].imm, alu_valid_id_ex[p], ex_stage_i.alu2_valid_i[p], branch_valid_id_ex[p], lsu_valid_id_ex[p]);
      end
      if (|alu_valid_id_ex || |branch_valid_id_ex) begin
        $fdisplay(fd, "[ot-alu] t=%0t lane=0 gen=%0d tid=%0d op=%0d a=%h b=%h value=%h branch_result=%0d", $time, slot_gen[ex_stage_i.alu_data[0].trans_id], ex_stage_i.alu_data[0].trans_id, ex_stage_i.alu_data[0].operation, ex_stage_i.alu_data[0].operand_a, ex_stage_i.alu_data[0].operand_b, ex_stage_i.alu_result[0], ex_stage_i.alu_branch_res);
      end
      if (CVA6Cfg.NrALUs >= 2 && |ex_stage_i.alu2_valid_i)
        $fdisplay(fd, "[ot-alu] t=%0t lane=1 gen=%0d tid=%0d op=%0d a=%h b=%h value=%h branch_result=0", $time, slot_gen[secondary_data.trans_id], secondary_data.trans_id, secondary_data.operation, secondary_data.operand_a, secondary_data.operand_b, secondary_result);
      if (|mult_valid_id_ex)
        $fdisplay(fd, "[ot-mult] t=%0t gen=%0d tid=%0d op=%0d a=%h b=%h", $time, slot_gen[ex_stage_i.mult_data.trans_id], ex_stage_i.mult_data.trans_id, ex_stage_i.mult_data.operation, ex_stage_i.mult_data.operand_a, ex_stage_i.mult_data.operand_b);
      if (`G6LC_OT_LS.lsu_valid_i)
        $fdisplay(fd, "[ot-lsu-enqueue] t=%0t gen=%0d tid=%0d ready=%0d flush=%0d op=%0d a=%h b=%h imm=%h vaddr=%h be=%h translated=%0d", $time, slot_gen[`G6LC_OT_LS.fu_data_i.trans_id], `G6LC_OT_LS.fu_data_i.trans_id, `G6LC_OT_LS.lsu_ready_o, `G6LC_OT_LS.flush_i, `G6LC_OT_LS.fu_data_i.operation, `G6LC_OT_LS.fu_data_i.operand_a, `G6LC_OT_LS.fu_data_i.operand_b, `G6LC_OT_LS.fu_data_i.imm, `G6LC_OT_LS.lsu_req_i.vaddr, `G6LC_OT_LS.lsu_req_i.be, `G6LC_OT_LS.en_ld_st_translation_i);
      if (`G6LC_OT_LD.req_port_i.data_rvalid)
        $fdisplay(fd, "[ot-load-response] t=%0t gen=%0d rid=%0d tid=%0d raw=%h valid_slot=%0d flushed=%0d kill=%0d result_valid=%0d result=%h ex=%0d", $time, load_gen[`G6LC_OT_LD.ldbuf_rindex], `G6LC_OT_LD.ldbuf_rindex, `G6LC_OT_LD.ldbuf_rdata.trans_id, `G6LC_OT_LD.req_port_i.data_rdata, `G6LC_OT_LD.ldbuf_valid_q[`G6LC_OT_LD.ldbuf_rindex], `G6LC_OT_LD.ldbuf_flushed_q[`G6LC_OT_LD.ldbuf_rindex], `G6LC_OT_LD.req_port_o.kill_req, `G6LC_OT_LD.valid_o, `G6LC_OT_LD.result_o, `G6LC_OT_LD.ex_o.valid);
      if (`G6LC_OT_LD.req_port_o.tag_valid || `G6LC_OT_LD.req_port_o.kill_req)
        $fdisplay(fd, "[ot-load-tag] t=%0t gen=%0d rid=%0d paddr=%h tag=%h tag_valid=%0d kill=%0d", $time, load_gen[`G6LC_OT_LD.ldbuf_last_id_q], `G6LC_OT_LD.ldbuf_last_id_q, `G6LC_OT_LD.paddr_i, `G6LC_OT_LD.req_port_o.address_tag, `G6LC_OT_LD.req_port_o.tag_valid, `G6LC_OT_LD.req_port_o.kill_req);
      if (`G6LC_OT_LD.st_fwd_done)
        $fdisplay(fd, "[ot-load-forward] t=%0t gen=%0d tid=%0d vaddr=%h raw=%h be=%h value=%h", $time, slot_gen[`G6LC_OT_LD.lsu_ctrl_i.trans_id], `G6LC_OT_LD.lsu_ctrl_i.trans_id, `G6LC_OT_LD.lsu_ctrl_i.vaddr, `G6LC_OT_LD.st_fwd_data_i, `G6LC_OT_LD.st_fwd_be_i, `G6LC_OT_LD.result_o);
      if (`G6LC_OT_LD.ldbuf_w) begin
        $fdisplay(fd, "[ot-load-request] t=%0t gen=%0d tid=%0d rid=%0d vaddr=%h index=%h be=%h dtlb_hit=%0d", $time, slot_gen[`G6LC_OT_LD.lsu_ctrl_i.trans_id], `G6LC_OT_LD.lsu_ctrl_i.trans_id, `G6LC_OT_LD.ldbuf_windex, `G6LC_OT_LD.lsu_ctrl_i.vaddr, `G6LC_OT_LD.req_port_o.address_index, `G6LC_OT_LD.req_port_o.data_be, `G6LC_OT_LD.dtlb_hit_i);
        load_gen[`G6LC_OT_LD.ldbuf_windex] = slot_gen[`G6LC_OT_LD.lsu_ctrl_i.trans_id];
      end
      if (`G6LC_OT_ST.valid_i)
        $fdisplay(fd, "[ot-store-enqueue] t=%0t gen=%0d tid=%0d paddr=%h data=%h be=%h flush=%0d ready=%0d cancelled=%0d", $time, slot_gen[`G6LC_OT_ST.trans_id_i], `G6LC_OT_ST.trans_id_i, `G6LC_OT_ST.paddr_i, `G6LC_OT_ST.data_i, `G6LC_OT_ST.be_i, `G6LC_OT_ST.flush_i, `G6LC_OT_ST.ready_o, `G6LC_OT_ST.cancelled_mask_i[`G6LC_OT_ST.trans_id_i]);
      if (`G6LC_OT_ST.commit_i)
        $fdisplay(fd, "[ot-store-commit] t=%0t tid=%0d paddr=%h data=%h be=%h valid=%0d", $time, `G6LC_OT_ST.speculative_queue_q[`G6LC_OT_ST.speculative_read_pointer_q].trans_id, `G6LC_OT_ST.speculative_queue_q[`G6LC_OT_ST.speculative_read_pointer_q].address, `G6LC_OT_ST.speculative_queue_q[`G6LC_OT_ST.speculative_read_pointer_q].data, `G6LC_OT_ST.speculative_queue_q[`G6LC_OT_ST.speculative_read_pointer_q].be, `G6LC_OT_ST.speculative_queue_q[`G6LC_OT_ST.speculative_read_pointer_q].valid);
      if (`G6LC_OT_ST.req_port_o.data_req && `G6LC_OT_ST.req_port_i.data_gnt)
        $fdisplay(fd, "[ot-store-request] t=%0t tag=%h index=%h data=%h be=%h", $time, `G6LC_OT_ST.req_port_o.address_tag, `G6LC_OT_ST.req_port_o.address_index, `G6LC_OT_ST.req_port_o.data_wdata, `G6LC_OT_ST.req_port_o.data_be);
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        if (`G6LC_OT_SB.decoded_instr_valid_i[p] && `G6LC_OT_SB.decoded_instr_ack_o[p] && !`G6LC_OT_SB.flush_unissued_instr_i && !`G6LC_OT_SB.flush_i) begin
          slot_gen[`G6LC_OT_SB.issue_pointer[p]] = next_gen;
          $fdisplay(fd, "[ot-issue] t=%0t p=%0d gen=%0d tid=%0d h=%0d pc=%h bits=%h compressed=%0d op=%0d fu=%0d rs1=%0d rs2=%0d rd=%0d use_imm=%0d use_pc=%0d use_zimm=%0d rf1=%h rf2=%h a=%h b=%h imm=%h fwd1=%0d fwd2=%0d src1=%0d src2=%0d bypass=%h ex=%0d", $time, p, next_gen, `G6LC_OT_SB.issue_pointer[p], `G6LC_OT_SB.issue_instr_o[p].hart_id, `G6LC_OT_SB.issue_instr_o[p].pc, `G6LC_OT_SB.orig_instr_o[p], `G6LC_OT_SB.issue_instr_o[p].is_compressed, `G6LC_OT_SB.issue_instr_o[p].op, `G6LC_OT_SB.issue_instr_o[p].fu, `G6LC_OT_SB.issue_instr_o[p].rs1, `G6LC_OT_SB.issue_instr_o[p].rs2, `G6LC_OT_SB.issue_instr_o[p].rd, `G6LC_OT_SB.issue_instr_o[p].use_imm, `G6LC_OT_SB.issue_instr_o[p].use_pc, `G6LC_OT_SB.issue_instr_o[p].use_zimm, `G6LC_OT_RO.operand_a_regfile[p], `G6LC_OT_RO.operand_b_regfile[p], `G6LC_OT_RO.fu_data_n[p].operand_a, `G6LC_OT_RO.fu_data_n[p].operand_b, `G6LC_OT_RO.fu_data_n[p].imm, `G6LC_OT_RO.forward_rs1[p], `G6LC_OT_RO.forward_rs2[p], `G6LC_OT_RO.idx_hzd_rs1[p], `G6LC_OT_RO.idx_hzd_rs2[p], `G6LC_OT_RO.alu_bypass_n, `G6LC_OT_SB.issue_instr_o[p].ex.valid);
          next_gen++;
        end
      end
    end
  end

  final begin
    if (enabled != 0 && fd) begin
      $fdisplay(fd, "[ot-end] t=%0t next_gen=%0d", $time, next_gen);
      $fclose(fd);
    end
  end
end

`undef G6LC_OT_SB
`undef G6LC_OT_RO
`undef G6LC_OT_LS
`undef G6LC_OT_LD
`undef G6LC_OT_ST
