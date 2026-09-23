// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Modified by: Etienne Cimon
// Date: 08.02.2018
// Description: Instruction Fetch Frontend
//
// This module interfaces with the instruction cache, handles control flow change
// requests from the back-end and does branch prediction. With FtqDepth != 0 the
// address generation is decoupled from the I$ by a fetch target queue, which can
// then be run ahead of demand fetch (FDIP) or bypassed by a loop buffer.
//
// A/B draft note: every non-sequential fetch address is arbitrated once
// (arch_redirect_select) and consumed by the NPC register, the FTQ reseed and the
// I$ kill logic, instead of being re-derived as a chain of overriding ifs in each
// of those three places.

module frontend
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Next PC when reset - SUBSYSTEM
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Flush branch prediction - zero
    input logic flush_bp_i,
    // Flush requested by FENCE, mis-predict and exception - CONTROLLER
    input logic flush_i,
    // Halt requested by WFI and Accelerate port - CONTROLLER
    input logic halt_i,
    // Halt frontend - CONTROLLER (in the case of fence_i to avoid fetching an old instruction)
    input logic halt_frontend_i,
    // Set COMMIT PC as next PC requested by FENCE, CSR side-effect and Accelerate port - CONTROLLER
    input logic set_pc_commit_i,
    // Hart of the committing instruction — PC_COMMIT only if it matches smt_hart_i
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] commit_hart_i,
    // COMMIT PC - COMMIT
    input logic [CVA6Cfg.VLEN-1:0] pc_commit_i,
    // Memory-order replay: refetch the committing PC instead of pc+4 - CONTROLLER
    input logic mem_replay_pc_i,
    // Exception event - COMMIT
    input logic ex_valid_i,
    // Mispredict event and next PC - EXECUTE
    input bp_resolve_t resolved_branch_i,
    // Return from exception event - CSR
    input logic eret_i,
    // Next PC when returning from exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] epc_i,
    // Next PC when jumping into exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] trap_vector_base_i,
    // Debug event - CSR
    input logic set_debug_pc_i,
    // Debug mode state - CSR
    input logic debug_mode_i,
    // Active hart + PC restore on coarse-grain switch - SMT
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] smt_hart_i,
    input logic smt_restore_i,
    input logic [CVA6Cfg.VLEN-1:0] smt_npc_restore_i,
    // Live NPC for PC bank snapshot - SMT
    output logic [CVA6Cfg.VLEN-1:0] npc_q_o,
    // A trap redirect is fetched but not yet registered: suppress hart switch - SMT
    output logic smt_trap_hold_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    output icache_dreq_t icache_dreq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    input icache_drsp_t icache_dreq_i,
    // Handshake's data between fetch and decode - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid between fetch and decode - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready between fetch and decode - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i
);

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(CVA6Cfg);
  localparam int unsigned NrInstr = Geo.slots;
  localparam int unsigned IdxW = Geo.log2_slots;
  localparam bit FtqEn = Geo.ftq;
  localparam bit SmtEn = Geo.smt;

  localparam type bht_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;     // update at PC
    logic                    taken;
  };

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;              // update at PC
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type ras_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] ra;
  };

  // next fetch block — pkg geometry (same as win_base + W_BYTES)
  function automatic logic [CVA6Cfg.VLEN-1:0] next_block(logic [CVA6Cfg.VLEN-1:0] addr);
    logic [63:0] nb;
    nb = g6lc_fetch_pkg::next_block(CVA6Cfg, 64'(addr));
    return nb[CVA6Cfg.VLEN-1:0];
  endfunction

  // the three exceptions the frontend can see, as a two bit enum
  function automatic ariane_pkg::frontend_exception_t fe_exception(logic [CVA6Cfg.XLEN-1:0] cause);
    unique case (cause)
      riscv::INSTR_GUEST_PAGE_FAULT:
      return CVA6Cfg.MmuPresent ? ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT : ariane_pkg::FE_NONE;
      riscv::INSTR_PAGE_FAULT:
      return CVA6Cfg.MmuPresent ? ariane_pkg::FE_INSTR_PAGE_FAULT : ariane_pkg::FE_NONE;
      riscv::INSTR_ACCESS_FAULT: return ariane_pkg::FE_INSTR_ACCESS_FAULT;
      default: return ariane_pkg::FE_NONE;
    endcase
  endfunction

  // Instruction Cache Registers, from I$
  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data_q;
  logic icache_valid_q;
  ariane_pkg::frontend_exception_t icache_ex_valid_q;
  logic [CVA6Cfg.VLEN-1:0] icache_vaddr_q;
  logic [CVA6Cfg.GPLEN-1:0] icache_gpaddr_q;
  logic [31:0] icache_tinst_q;
  logic icache_gva_q;
  // Unregistered counterparts of the three above. I22 repointed the realigner
  // from icache_{valid,vaddr,data}_q to this same-cycle path, and the realigner
  // is instantiated far above the logic that drives them, so they are declared
  // here beside the registers they replaced rather than at their drivers.
  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data;
  logic icache_take;
  // FTQ / loop-buffer substitutes used by that same feed when the I$ is silent.
  logic [CVA6Cfg.VLEN-1:0] ftq_head_vaddr;
  logic [CVA6Cfg.FETCH_WIDTH-1:0] lbuf_data;
  logic instr_queue_ready;
  logic [NrInstr-1:0] instr_queue_consumed;
  // upper-most branch-prediction from last cycle
  btb_prediction_t btb_q;
  bht_prediction_t bht_q;
  // instruction fetch is ready
  logic if_ready;
  logic [CVA6Cfg.VLEN-1:0] npc_d, npc_q;  // next PC
  logic [CVA6Cfg.VLEN-1:0] seq_base;  // address the sequential step starts from
  logic [CVA6Cfg.VLEN-1:0] fetch_address;  // address presented to I$ / FTQ this cycle
  // indicates whether we come out of reset (then we need to load boot_addr_i)
  logic npc_rst_load_q;

  logic replay, replay_q;
  logic [CVA6Cfg.VLEN-1:0] replay_addr, replay_addr_q;
  logic arch_valid, arch_step, arch_reseed;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      replay_q <= 1'b0;
      replay_addr_q <= '0;
    end else begin
      replay_q <= replay && !arch_valid;
      if (replay && !arch_valid) replay_addr_q <= replay_addr;
    end
  end

  // halfword offset of the fetch address inside the block
  logic [IdxW-1:0] shamt;

  // -----------------------
  // Ctrl Flow Speculation
  // -----------------------
  // RVI ctrl flow prediction
  logic [NrInstr-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump;
  logic [NrInstr-1:0][CVA6Cfg.VLEN-1:0] rvi_imm;
  // RVC branching
  logic [NrInstr-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic [NrInstr-1:0][CVA6Cfg.VLEN-1:0] rvc_imm;
  // re-aligned instruction and address (coming from cache - combinationally)
  logic [NrInstr-1:0][31:0] instr;
  logic [NrInstr-1:0][CVA6Cfg.VLEN-1:0] addr;
  logic [NrInstr-1:0] instruction_valid_raw, instruction_valid;
  // BHT, BTB and RAS prediction
  bht_prediction_t [NrInstr-1:0] bht_prediction;
  btb_prediction_t [NrInstr-1:0] btb_prediction;
  bht_prediction_t [NrInstr-1:0] bht_prediction_shifted;
  btb_prediction_t [NrInstr-1:0] btb_prediction_shifted;
  ras_t ras_predict;
  logic [CVA6Cfg.VLEN-1:0] vpc_btb;
  logic [CVA6Cfg.VLEN-1:0] vpc_bht;

  // branch-predict update
  logic is_mispredict, resolution_for_active;
  logic ras_push, ras_pop;
  logic [CVA6Cfg.VLEN-1:0] ras_update;

  // Instruction FIFO
  logic [CVA6Cfg.VLEN-1:0] predict_address;
  cf_t [NrInstr-1:0] cf_type;
  logic [NrInstr-1:0] taken_rvi_cf;
  logic [NrInstr-1:0] taken_rvc_cf;

  logic bp_valid;
  logic [NrInstr-1:0] is_branch, is_call, is_jump, is_return, is_jalr;
  logic serving_unaligned, leftover_pending, leftover_valid;
  logic leftover_slot0_push, leftover_kill;
  logic [CVA6Cfg.VLEN-1:0] leftover_pc;
  // I$ request fields are kept as local wires: the request struct is then only
  // driven, never read back inside this module
  logic kill_s1, kill_s2, spec_req;
  logic inflight_q;
  logic [CVA6Cfg.VLEN-1:0] inflight_addr_q;
  logic [63:0] snap_nb;
  // address will always be 16 bit aligned, make this explicit here
  // shamt is in HALFWORDS, not bytes (bit 0 is dropped). Without RVC every
  // fetch is window-aligned, so there is nothing to shift and the mux folds.
  assign shamt = CVA6Cfg.RVC ? icache_dreq_i.vaddr[IdxW:1] : '0;

  // Re-align: leftover_kill is misp/flush/replay except leftover-complete
  // slot0 push (I7 overflow of rest). bp_fire (kill_s2 only) must still
  // retire a leftover-complete jal, else the next leftover (strncmp jal_lo
  // after strlen jal@17fc6) is never stored and RAS misses 17fda
  // (s4-v-nien node_is_enabled -48). Not G1bq (do not spare I$ kill_s2).
  // A split conditional branch in slot0 that is predicted-taken must not
  // consume the carry, because the mispredict-fallthrough path will replay
  // the same block and needs the low half to rebuild the RVI (b1-fdt-lenp
  // 2-byte aligned split-RVI at 0x8001263e and 0x8001378e). Jumps are still
  // retired so unconditional taken-jals update the carry for the target.
  // I22: present the I$ response to the realigner on the same cycle it is
  // returned, not one cycle later via icache_*_q. The registered copy can
  // latch a bogus pc=0 / data=0 from an initial or X-state return and push
  // a stream of illegal instructions into the instruction queue.
  logic [CVA6Cfg.VLEN-1:0] realigner_vaddr;
  logic [CVA6Cfg.FETCH_WIDTH-1:0] realigner_data;
  assign realigner_vaddr = icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr;
  assign realigner_data  = icache_dreq_i.valid ? icache_data     : lbuf_data;

  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .kill_i             (leftover_kill),
      .hart_i             (smt_hart_i),
      // I23: hold the realigner at 0 during reset so an X-state I$.valid or
      // stale carry is not pushed into the instruction queue as a bogus pc=0.
      .valid_i            (icache_take & rst_ni),
      .serving_unaligned_o(serving_unaligned),
      .leftover_pending_o (leftover_pending),
      .leftover_valid_o   (leftover_valid),
      .leftover_pc_o      (leftover_pc),
      .address_i          (realigner_vaddr),
      .data_i             (realigner_data),
      .valid_o            (instruction_valid_raw),
      .addr_o             (addr),
      .instr_o            (instr)
  );

  // L2 live[]: drop slots with pc < present_exp. Same-window sequential
  // HIT of 12970 while jal targets 12974 must not issue the +16/ret prefix.
  // Keep direct jal/call (not ret/branch): RAS return to 12994 stole the
  // jal@12990 window and live[] ate the jal (beqz retired a0=FDT).
  // Not I$ extra-shift (SIGSEGV). Not exact vaddr==tgt / bp_ret_ge (MINI-FAIL).
  // accept=1: do not AND kill_s2 (eats taken jumps).
  logic [63:0] present_exp_q, present_exp;
  // `G6LC_NO_PREFIX_FILTER` makes this filter permissive. It is kept as a
  // documented switch because the answer it gave is worth being able to reproduce.
  //
  // MEASURED 2026-08-31: defining it changes the DI battery NOT AT ALL -- 4/16,
  // same tests, same failure modes. Two conclusions follow, and the second
  // corrects an earlier attribution of mine:
  //   1. this filter is not load-bearing for the current suite; and
  //   2. it is therefore NOT the mechanism that drops instructions after a
  //      predicted `ret` (O7f). Those three vanished instructions have another
  //      cause, and blaming the filter was wrong even though the O7a fix to it
  //      was independently worth +2 tests on the architectural-redirect path.
  // The filter is left ACTIVE: "not load-bearing for 16 minis" is weak grounds for
  // deleting a mechanism whose comment cites specific OpenSBI walk scenarios that
  // this suite does not contain. Its comparison is still unsound in principle for
  // returns, which is what O7b should resolve properly.
  always_comb begin
    for (int unsigned i = 0; i < NrInstr; i++) begin
      instruction_valid[i] = g6lc_fetch_pkg::slot_live(
          instruction_valid_raw[i],
          1'b1,
          g6lc_fetch_pkg::slot_keep_link(
              g6lc_fetch_pkg::slot_ge_expected(
`ifdef G6LC_NO_PREFIX_FILTER
                  1'b1,
`else
                  (i == 0) && serving_unaligned,
`endif
                  64'(addr[i]),
                  present_exp),
              rvi_jump[i] | rvc_jump[i] | rvi_call[i] | rvc_call[i]));
    end
  end

  // --------------------
  // Branch Prediction
  // --------------------
  // Index the prediction structures with the generated address. In case we serve
  // an unaligned instruction in instr[0] its prediction was saved last fetch.
  for (genvar i = 0; i < NrInstr; i++) begin : gen_prediction_shifted
    logic [IdxW-1:0] sel;
    assign sel = addr[i][IdxW:1] & IdxW'(NrInstr - 1);
    if (i == 0) begin : gen_head
      assign bht_prediction_shifted[0] = serving_unaligned ? bht_q : bht_prediction[sel];
      assign btb_prediction_shifted[0] = serving_unaligned ? btb_q : btb_prediction[sel];
    end else begin : gen_tail
      assign bht_prediction_shifted[i] = bht_prediction[sel];
      assign btb_prediction_shifted[i] = btb_prediction[sel];
    end
  end

  for (genvar i = 0; i < NrInstr; i++) begin : gen_cf_class
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i]
                        & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end

  // taken/not taken
  always_comb begin : cf_select
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;
    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

    for (int i = 0; i < NrInstr; i++) cf_type[i] = ariane_pkg::NoCF;

    // lower most prediction gets precedence
    for (int i = NrInstr - 1; i >= 0; i--) begin
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000: ;  // regular instruction e.g.: no branch
        // unconditional jump to register, we need the BTB to resolve this
        4'b0001: begin
          if (CVA6Cfg.BTBEntries != 0 && btb_prediction_shifted[i].valid) begin
            predict_address = btb_prediction_shifted[i].target_address;
            cf_type[i] = ariane_pkg::JumpR;
          end
        end
        // its an unconditional jump to an immediate
        4'b0010: begin
          taken_rvi_cf[i] = rvi_jump[i];
          taken_rvc_cf[i] = rvc_jump[i];
          cf_type[i] = ariane_pkg::Jump;
        end
        // return: only alter the RAS if we actually consumed the instruction
        4'b0100: begin
          ras_pop = ras_predict.valid & instr_queue_consumed[i];
          predict_address = ras_predict.ra;
          cf_type[i] = ariane_pkg::Return;
        end
        // branch prediction: dynamic if we have it, else static on the sign of
        // the immediate
        4'b1000: begin
          if (bht_prediction_shifted[i].valid) begin
            taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
            taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
          end else begin
            taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
            taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
          end
          if (taken_rvi_cf[i] || taken_rvc_cf[i]) cf_type[i] = ariane_pkg::Branch;
        end
        default: ;  // more than one control flow decoded
      endcase

      // if this instruction is also a call, save the return address, but only if
      // we actually consumed it
      if (is_call[i]) begin
        ras_push   = instr_queue_consumed[i];
        ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
      end
      // calculate the jump target address
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
      end
    end
    // Leftover-complete RVI jal is slot0 at carry_pc. Later slots in the
    // completing window stay valid for realign but must not win cf_select:
    // jal@17fd6 predicted 17fda (link) not strncmp 49d6 (s4-v-nockpt
    // tgt=17fda); RAS missed; node_is_enabled -48@17f16. G1do on B.
    // Not G1aa / NoCF ckpt_restore (pin unchanged).
    if (serving_unaligned && instruction_valid[0] && rvi_jump[0]) begin
      cf_type[0] = ariane_pkg::Jump;
      taken_rvi_cf[0] = 1'b1;
      predict_address = addr[0] + rvi_imm[0];
      ras_push = rvi_call[0] && instr_queue_consumed[0];
      if (rvi_call[0]) ras_update = addr[0] + 4;
    end
  end

  // A prediction is only valid if we saw a control flow, and for a return only if
  // the RAS holds a valid address.
  always_comb begin : bp_valid_reduce
    bp_valid = 1'b0;
    for (int i = 0; i < NrInstr; i++) begin
      bp_valid |= ((cf_type[i] != NoCF) & (cf_type[i] != Return))
                  | ((cf_type[i] == Return) & ras_predict.valid);
    end
  end

  // I19: act on a prediction only if the target is fetchable. Resolve is unfiltered.
  // L4: also require IQ consumed the CF (ras_push already does). Else bp_fire
  // drops icache_valid_q while leftover-complete jal is still unissued.
  logic [7:0] cf_v8, cf_t8, cf_c8;
  always_comb begin
    cf_v8 = '0;
    cf_t8 = '0;
    cf_c8 = '0;
    cf_v8[NrInstr-1:0] = instruction_valid;
    cf_c8[NrInstr-1:0] = instr_queue_consumed;
    for (int i = 0; i < NrInstr; i++) cf_t8[i] = (cf_type[i] != NoCF);
  end
  logic bp_fire;
  assign bp_fire = bp_valid
      && g6lc_fetch_pkg::predict_fetchable(CVA6Cfg, 64'(predict_address))
      && g6lc_fetch_pkg::cf_consumed(cf_v8, cf_t8, cf_c8);

  assign resolution_for_active = g6lc_fetch_pkg::redirect_for_hart(
      SmtEn, resolved_branch_i.valid, 8'(resolved_branch_i.hart_id), 8'(smt_hart_i));
  // A branch that resolves in the cycle an older architectural redirect fires
  // (trap, eret, or a commit-side refetch such as the memory-order replay) is
  // younger than that redirect and squashed by it. Its resolution must not arm
  // the mispredict target filter (bp_pend/bp_tgt) or kill the redirect's
  // fetch: with out-of-order issue the two do coincide (the replayed load's
  // stale value fed the branch), and the armed filter then rejected the
  // replay window and resumed at the squashed branch's target, skipping the
  // instructions in between. In order the two never meet, so this is inert.
  logic misp_outranked;
  assign misp_outranked = ex_valid_i | eret_i |
      g6lc_fetch_pkg::commit_for_hart(SmtEn, set_pc_commit_i, 8'(commit_hart_i), 8'(smt_hart_i));
  assign is_mispredict = resolution_for_active && resolved_branch_i.is_mispredict && !misp_outranked;

  // Classic EX mispredict only. A matching taken Jump must not reseed the NPC:
  // re-fetching a call pushes the RAS twice.

  // ------------------------------------------------------------------
  // Redirect arbitration
  // ------------------------------------------------------------------
  // Every architectural (non branch-predicted) redirect is selected once here.
  //  - arch_pc     : the address the machine must fetch next
  //  - arch_step   : with an FTQ the queue is reseeded with arch_pc, so the NPC
  //                  register steps to the *following* block, otherwise the same
  //                  address would be pushed twice when the CF hold lifts
  //  - arch_reseed : force an FTQ push/flush even if if_ready is low
  logic [CVA6Cfg.VLEN-1:0] arch_pc;
  logic [CVA6Cfg.VLEN-1:0] commit_next_pc, debug_halt_pc;

  // CSR or AMO instructions do not exist in a compressed form, so commit + 4;
  // if commit is halted just take the PC of the instruction sitting there
  // +4 is unconditional because no CSR/AMO has a compressed form, so this can
  // never land mid-instruction the way a blind +4 would elsewhere in fetch.
  assign commit_next_pc = pc_commit_i + ((halt_i || mem_replay_pc_i) ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
  assign debug_halt_pc = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0]
                         + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];

  // a trap redirect additionally may not be interrupted by a hart switch
  logic arch_trap;
  logic [3:0] arch_src;

  // I8 encoder (post-pre-ladder): trap/eret/commit/debug outrank SMT restore.
  assign arch_src = g6lc_fetch_pkg::arch_src_sel(
      SmtEn, smt_restore_i, CVA6Cfg.DebugEn && set_debug_pc_i,
      g6lc_fetch_pkg::commit_for_hart(SmtEn, set_pc_commit_i,
          8'(commit_hart_i), 8'(smt_hart_i)),
      ex_valid_i, eret_i, is_mispredict);

  always_comb begin : arch_redirect_select
    arch_valid  = 1'b1;
    arch_step   = FtqEn;
    arch_reseed = 1'b1;
    arch_trap   = 1'b0;
    arch_pc     = '0;

    unique case (arch_src)
      g6lc_fetch_pkg::SRC_EX: begin
        arch_pc   = trap_vector_base_i;
        arch_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_ERET: begin
        arch_pc   = epc_i;
        arch_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_COMMIT: begin
        arch_pc     = commit_next_pc;
        arch_step   = FtqEn & ~halt_i;
        arch_reseed = flush_i;
      end
      g6lc_fetch_pkg::SRC_DEBUG: begin
        arch_pc   = debug_halt_pc;
        arch_trap = 1'b1;
      end
      g6lc_fetch_pkg::SRC_RESTORE: begin
        arch_pc   = smt_npc_restore_i;
        arch_step = 1'b0;
      end
      g6lc_fetch_pkg::SRC_MISP: begin
        arch_pc = resolved_branch_i.target_address;
      end
      default: begin
        arch_valid  = 1'b0;
        arch_step   = 1'b0;
        arch_reseed = 1'b0;
      end
    endcase
  end

  // ------------------------------------------------------------------
  // Redirect completion
  // ------------------------------------------------------------------
  // A redirect is not done when its address is issued, only when its fetch block
  // has been *registered*. If the fetch in flight for it is killed (a flush, or a
  // taken prediction still coming out of the pre-redirect block) the target must be
  // presented again, otherwise the NPC has already moved on and the first
  // instructions at the target are never supplied.
  //
  // This is recovery only, never a stall: the NPC steps as soon as the I$ accepts
  // a request, because an address presented while its request is already accepted
  // is fetched twice, and the second copy is pushed into the queue a second time.
  // With an FTQ the queue holds the target instead (arch_step / cf_hold_q), so this
  // only drives the direct path.
  logic redirect_pend_q, redirect_inflight_q, redirect_lost_q;
  logic redirect_trap_q, redirect_tail_q;
  logic [CVA6Cfg.VLEN-1:0] redirect_pc_q;
  logic redirect_hit, redirect_hold, redirect_accept;
  logic [7:0][63:0] redirect_slot_pc;

  always_comb begin
    redirect_slot_pc = '0;
    for (int p = 0; p < CVA6Cfg.INSTR_PER_FETCH; p++)
      redirect_slot_pc[p] = 64'(addr[p]);
  end

  // L2 keep: registered / in-flight window vs redirect target. No opcode.
  assign redirect_hit = g6lc_fetch_pkg::accepted_target(
      CVA6Cfg.INSTR_PER_FETCH, icache_take, flush_i, 8'(instr_queue_consumed),
      redirect_slot_pc, 64'(redirect_pc_q));
  assign redirect_hold = g6lc_fetch_pkg::redirect_rehold(
      FtqEn, redirect_pend_q, redirect_lost_q, redirect_hit);
  assign redirect_accept = g6lc_fetch_pkg::window_accept(
      if_ready, kill_s2,
      g6lc_fetch_pkg::same_win(CVA6Cfg, 64'(fetch_address), 64'(redirect_pc_q)));

  // L2: predicted redirect does not set redirect_pend (arch only). kill_s2
  // can lose the sequential inflight (OpenSBI 12ad0 leftover_drop of jal).
  // Pend only filters that return; sequential HIT with pend=0 is unchanged.
  // Mispredict retargets pend to the resolve target (17fda) so the
  // previous predicted window (17f16) is not taken after flush cleared
  // pend. TTL lifts if the target I$ never returns (not redirect_pend
  // take: that gated every I$ until hit; 2jr mepc=0xaa).
  // stale_ret_ok extra same_win on take SIGSEGV rc=-11 s4-v-stale-minis.
  logic bp_pend_q;
  logic [CVA6Cfg.VLEN-1:0] bp_tgt_q;
  logic [2:0] bp_misp_ttl_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bp_pend_q     <= 1'b0;
      bp_tgt_q      <= '0;
      bp_misp_ttl_q <= '0;
    end else if (is_mispredict) begin
      bp_pend_q     <= 1'b1;
      bp_tgt_q      <= resolved_branch_i.target_address;
      bp_misp_ttl_q <= 3'd7;
    end else if (flush_i) begin
      bp_pend_q     <= 1'b0;
      bp_misp_ttl_q <= '0;
    end else if (bp_fire) begin
      bp_pend_q     <= 1'b1;
      bp_tgt_q      <= predict_address;
      bp_misp_ttl_q <= '0;
    end else if (bp_pend_q && icache_dreq_i.valid &&
        g6lc_fetch_pkg::same_win(CVA6Cfg, 64'(icache_dreq_i.vaddr), 64'(bp_tgt_q))) begin
      bp_pend_q     <= 1'b0;
      bp_misp_ttl_q <= '0;
    end else if (bp_misp_ttl_q != 3'd0) begin
      // I23 bound on the mispredict hold: if the resolve target's window never
      // comes back, the TTL releases pend instead of filtering every return.
      if (bp_misp_ttl_q == 3'd1) bp_pend_q <= 1'b0;
      bp_misp_ttl_q <= bp_misp_ttl_q - 3'd1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      redirect_pend_q     <= 1'b0;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      redirect_trap_q     <= 1'b0;
      redirect_tail_q     <= 1'b0;
      redirect_pc_q       <= '0;
    end else if (arch_valid) begin
      redirect_pend_q     <= 1'b1;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      redirect_trap_q     <= arch_trap;
      redirect_tail_q     <= 1'b0;
      redirect_pc_q       <= arch_pc;
    end else if (redirect_pend_q && redirect_hit) begin
      redirect_pend_q     <= 1'b0;
      redirect_inflight_q <= 1'b0;
      redirect_lost_q     <= 1'b0;
      // the target block may end with an instruction split into the next block;
      // whether it does is only known once the realigner has taken it
      redirect_tail_q     <= 1'b1;
    end else if (redirect_tail_q) begin
      // hold only while that split instruction is still waiting for its second
      // half, so a stalled pipeline cannot block a switch indefinitely
      // The condition is self-clearing: once the next window is registered the
      // carry either completed or was dropped, so there is nothing left to wait on.
      redirect_tail_q <= serving_unaligned & ~icache_valid_q;
      redirect_trap_q <= redirect_trap_q & serving_unaligned & ~icache_valid_q;
    end else if (redirect_pend_q) begin
      // a kill leaves nothing in flight for the target, so present it again
      if (kill_s2) begin
        redirect_inflight_q <= 1'b0;
        redirect_lost_q     <= 1'b1;
      end else if (redirect_accept) begin
        redirect_inflight_q <= 1'b1;
        redirect_lost_q     <= 1'b0;
      end
    end
  end

  // Narrower than a flush: only a trap redirect blocks the switch, so
  // switch-on-miss still works over ordinary redirects.
  assign smt_trap_hold_o = SmtEn & redirect_trap_q & (redirect_pend_q | redirect_tail_q);

  // -------------------
  // Next PC
  // -------------------
  // The sequential step is taken from the predicted target when a prediction
  // fires this cycle, else from the current NPC (boot address out of reset).
  // With an FTQ the replay is a reseed like bp_fire: the refused window is
  // presented, pushed and stepped from in the same cycle.
  assign seq_base = npc_rst_load_q ? boot_addr_i : bp_fire ? predict_address :
      (FtqEn && replay_q) ? replay_addr_q : npc_q;
  // I8: I$ address follows the same encoder as npc_d. Restore-first here
  // outranked trap/commit (I4y) and could present a banked data VA.
  assign fetch_address = arch_valid ? arch_pc :
      redirect_hold ? redirect_pc_q : seq_base;

  always_comb begin : npc_select
    if (arch_valid) npc_d = arch_step ? next_block(arch_pc) : arch_pc;
    // re-present the redirect target until its block has been registered
    else if (redirect_hold) npc_d = redirect_pc_q;
    else if (replay_q && !FtqEn) npc_d = replay_addr_q;
    else if (if_ready) npc_d = next_block(seq_base);
    else if (bp_fire) npc_d = predict_address;
    else npc_d = seq_base;
  end

  // ------------------------------------------------------------------
  // Cache interface
  // ------------------------------------------------------------------
  // Without an FTQ the NPC is presented to the I$ directly and advances against
  // I$ ready. With an FTQ the NPC advances against queue space, demand fetch
  // drains the queue head, and FDIP may steal idle I$ cycles.
  logic ftq_full, ftq_head_valid, ftq_pop, ftq_push;
  logic [CVA6Cfg.VLEN-1:0] ftq_peek_vaddr, ftq_push_vaddr;
  logic ftq_peek_valid;
  logic lbuf_hit, lbuf_consume, lbuf_inject;
  logic pf_req;
  logic [CVA6Cfg.VLEN-1:0] pf_vaddr;
  logic demand_req, demand_fire;

  if (!FtqEn) begin : gen_no_ftq
    assign icache_dreq_o.req = instr_queue_ready & ~halt_frontend_i;
    assign if_ready = icache_dreq_i.ready & instr_queue_ready & ~halt_frontend_i;
    assign ftq_full = 1'b0;
    assign ftq_head_valid = 1'b0;
    assign ftq_head_vaddr = '0;
    assign ftq_peek_valid = 1'b0;
    assign ftq_peek_vaddr = '0;
    assign ftq_push_vaddr = '0;
    assign ftq_pop = 1'b0;
    assign ftq_push = 1'b0;
    assign lbuf_hit = 1'b0;
    assign lbuf_data = '0;
    assign lbuf_consume = 1'b0;
    assign pf_req = 1'b0;
    assign pf_vaddr = '0;
    assign demand_req = 1'b0;
    assign demand_fire = 1'b0;
  end else begin : gen_ftq
    // After a redirect the queue must not be refilled sequentially until the
    // redirected fetch has been registered: otherwise if_ready keeps pushing the
    // pre-redirect NPC and the stream is duplicated. A depth-1 in-flight request
    // (FtqDepth == 0) relies on kill_s2 racing that instead.
    logic cf_hold_q;

    // The hold is armed only when the redirect target was actually pushed: a
    // prediction firing while the instruction queue is not ready leaves the
    // target in npc_q instead (npc_select), and holding then would wait for a
    // response no request will ever produce — the FTQ was just flushed, so
    // nothing is demanded and the frontend falls silent. Seen on a 16-entry
    // scoreboard, whose backpressure fills the queue at a predicted back-edge.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) cf_hold_q <= 1'b0;
      else if ((bp_fire || arch_reseed) && ftq_push) cf_hold_q <= 1'b1;
      else if (icache_valid_q) cf_hold_q <= 1'b0;  // redirect fetch presented
      else if (flush_i && !arch_reseed) cf_hold_q <= 1'b0;
    end

    // An instruction-queue replay leaves stale sequential entries ahead of the
    // refused window in the FTQ, which would be served first and deliver
    // windows out of accepted-stream order, breaking the queue's per-slot FIFO
    // alignment. A replay is therefore a reseed like bp_fire: the FTQ and FDIP
    // are flushed, the stale head is not demanded, and seq_base rewinds npc to
    // replay_addr_q so the refused window is pushed and stepped from in the
    // same cycle. kill_s1 already carries replay_q, so the in-flight responses
    // to the dropped pre-flush entries are killed by token.
    // A reseed flushes and refills the queue, so treat that cycle as having free
    // space even if the pre-flush queue was full or held.
    assign if_ready = (~ftq_full | bp_fire | arch_reseed | replay_q) & instr_queue_ready
                      & ~halt_frontend_i & (~cf_hold_q | bp_fire | arch_reseed | replay_q);
    // Demand the I$ only when the loop buffer cannot supply the queue head. The
    // reseed is registered, so the same-cycle head is still the pre-flush one.
    assign demand_req = ftq_head_valid & instr_queue_ready & ~halt_frontend_i & ~lbuf_hit
                        & ~bp_fire & ~arch_reseed & ~flush_i & ~replay_q;
    assign demand_fire = demand_req & icache_dreq_i.ready;
    // Pop only when the I$ accepts a demand request that is not being killed: a
    // pop under kill_s2 drops the redirect target and discards the miss return.
    // A loop-buffer inject also consumes a fetch block.
    assign ftq_pop = (demand_fire & ~kill_s2) | lbuf_consume;

    assign ftq_push_vaddr = arch_reseed ? arch_pc : (bp_fire ? predict_address : fetch_address);
    assign ftq_push = if_ready | arch_reseed;

    g6lc_ftq #(
        .CVA6Cfg(CVA6Cfg),
        .DEPTH  (CVA6Cfg.FtqDepth)
    ) i_ftq (
        .clk_i,
        .rst_ni,
        // sequential addresses queued behind a taken CF must not be drained
        .flush_i      (flush_i | is_mispredict | bp_fire | replay_q),
        .push_i       (ftq_push),
        .push_vaddr_i (ftq_push_vaddr),
        .push_taken_i (bp_fire),
        .push_target_i(predict_address),
        .pop_i        (ftq_pop),
        .head_vaddr_o (ftq_head_vaddr),
        .head_taken_o (),
        .head_target_o(),
        .head_valid_o (ftq_head_valid),
        .peek_offset_i(
        (CVA6Cfg.FdipDistance > 0) ? $clog2(CVA6Cfg.FtqDepth + 1)'(CVA6Cfg.FdipDistance) : '0),
        .peek_vaddr_o (ftq_peek_vaddr),
        .peek_valid_o (ftq_peek_valid),
        .full_o       (ftq_full),
        .empty_o      (),
        .count_o      ()
    );

    if (CVA6Cfg.FdipEn) begin : gen_fdip
      g6lc_fdip #(
          .CVA6Cfg (CVA6Cfg),
          .DISTANCE(CVA6Cfg.FdipDistance)
      ) i_fdip (
          .clk_i,
          .rst_ni,
          .flush_i        (flush_i | is_mispredict | bp_fire | replay_q),
          .enable_i       (1'b1),
          .peek_valid_i   (ftq_peek_valid),
          .peek_vaddr_i   (ftq_peek_vaddr),
          .demand_active_i(demand_req),
          .icache_ready_i (icache_dreq_i.ready),
          .pf_req_o       (pf_req),
          .pf_vaddr_o     (pf_vaddr),
          .pf_drop_pma_o  ()
      );
    end else begin : gen_no_fdip
      assign pf_req   = 1'b0;
      assign pf_vaddr = '0;
    end

    if (CVA6Cfg.LoopBufEn) begin : gen_lbuf
      g6lc_loop_buffer #(
          .CVA6Cfg   (CVA6Cfg),
          .NR_ENTRIES(CVA6Cfg.LoopBufEntries),
          .DATA_W    (CVA6Cfg.FETCH_WIDTH)
      ) i_lbuf (
          .clk_i,
          .rst_ni,
          .flush_i       (flush_i | is_mispredict | flush_bp_i),
          .enable_i      (1'b1),
          .cf_valid_i    (bp_fire),
          .cf_taken_i    (bp_fire),
          // arm on the in-flight fetch PC that produced the taken prediction
          .cf_pc_i       (icache_vaddr_q),
          .cf_target_i   (predict_address),
          // demand fills only (never speculative FDIP)
          .fill_valid_i  (icache_dreq_i.valid & ~spec_req),
          .fill_vaddr_i  (icache_dreq_i.vaddr),
          .fill_data_i   (icache_dreq_i.data[CVA6Cfg.FETCH_WIDTH-1:0]),
          .lookup_vaddr_i(ftq_head_vaddr),
          .lookup_ready_i(instr_queue_ready & ~halt_frontend_i),
          .hit_o         (lbuf_hit),
          .data_o        (lbuf_data),
          .active_o      (),
          .consume_o     (lbuf_consume)
      );
    end else begin : gen_no_lbuf
      assign lbuf_hit     = 1'b0;
      assign lbuf_data    = '0;
      assign lbuf_consume = 1'b0;
    end

    // demand wins; FDIP only when demand is idle; loop-buffer hits skip the I$
    assign icache_dreq_o.req = demand_req | pf_req;
  end

  // Three mutually exclusive suppliers, priority-encoded rather than OR'd:
  // demand (FTQ head) > FDIP prefetch > the direct redirect/NPC path.
  assign icache_dreq_o.vaddr = (FtqEn && demand_req) ? ftq_head_vaddr :
      (FtqEn && pf_req) ? pf_vaddr : fetch_address;

  // Redirect drops in-flight I$ (A keep/kill capability, no opcode spares).
  assign kill_s1 = g6lc_fetch_pkg::kill_s1(is_mispredict, flush_i, replay_q);
  assign kill_s2 = g6lc_fetch_pkg::kill_s2(kill_s1, bp_fire);
  assign icache_dreq_o.kill_s1 = kill_s1;
  assign icache_dreq_o.kill_s2 = kill_s2;
  // Leftover-complete slot0 pushed on I7 overflow: consume carry
  // (leftover_update) while I$ kill_s1 still replays the rest.
  assign leftover_slot0_push = serving_unaligned & instr_queue_consumed[0] & replay;
  // Hold the carry when a leftover-complete conditional branch is predicted
  // taken: the carry must survive until the branch resolves in case the
  // prediction is wrong and the completing block has to be replayed.
  logic leftover_branch_bp_fire;
  assign leftover_branch_bp_fire = bp_fire & serving_unaligned
      & (cf_type[0] == ariane_pkg::Branch);
  assign leftover_kill = is_mispredict | flush_i | (replay & ~leftover_slot0_push)
      | leftover_branch_bp_fire;

  // Response ownership by request token. Every accepted I$ request carries a
  // 2-bit token; the frontend wants exactly one outstanding token and takes a
  // response only when its token matches. A kill (kill_s1 or kill_s2) with
  // nothing new accepted forgets the outstanding token, and a request accepted
  // in a kill cycle is itself unwanted, so a response the I$ still returns for
  // a killed or redirected request is dropped by identity, not by address.
  // A prefetch response is dropped the same way by ownership: it only warms
  // the I$, and the demand for the same window later hits the warmed I$.
  logic [1:0] req_token_q, want_token_q;
  logic       want_valid_q, want_pf_q, icache_accept, kill_drop;
  assign icache_accept = icache_dreq_o.req & icache_dreq_i.ready;
  assign icache_dreq_o.token = req_token_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_token_q  <= '0;
      want_token_q <= '0;
      want_valid_q <= 1'b0;
      want_pf_q    <= 1'b0;
    end else begin
      if (icache_accept) req_token_q <= req_token_q + 1'b1;
      if (kill_s2) begin
        want_valid_q <= 1'b0;
        if (icache_accept) begin
          want_token_q <= req_token_q;
          want_pf_q    <= FtqEn && pf_req && !demand_req;
        end
      end else if (icache_accept) begin
        want_valid_q <= 1'b1;
        want_token_q <= req_token_q;
        want_pf_q    <= FtqEn && pf_req && !demand_req;
      end else if (icache_dreq_i.valid && icache_dreq_i.token == want_token_q) begin
        want_valid_q <= 1'b0;
      end
    end
  end
  assign kill_drop = icache_dreq_i.valid
      && !(want_valid_q && icache_dreq_i.token == want_token_q && !want_pf_q);

  // I10: bank the accepted I$ address when switch kills it, not next_block.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      inflight_q      <= 1'b0;
      inflight_addr_q <= '0;
    end else if (kill_s2) begin
      inflight_q <= 1'b0;
    end else if (FtqEn ? demand_fire : if_ready) begin
      inflight_q      <= 1'b1;
      inflight_addr_q <= FtqEn ? ftq_head_vaddr : fetch_address;
    end else if (icache_dreq_i.valid) begin
      inflight_q <= 1'b0;
    end
  end
  assign snap_nb = g6lc_fetch_pkg::snap_pc(SmtEn && smt_restore_i, inflight_q,
      64'(inflight_addr_q), 64'(npc_q));
  assign npc_q_o = snap_nb[CVA6Cfg.VLEN-1:0];

  // assert on branch, deassert when resolved; prefetches are always speculative
  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolution_for_active
                          || |is_branch || |is_return || |is_jalr) && !flush_i;
  // FDIP is speculative by construction; a demand fetch is speculative only
  // while an unresolved CF is outstanding. Do not reuse this as a leftover
  // gate: spec_req is high on ordinary sequential fetch (NEGATIVE I3 keep).
  assign spec_req = (FtqEn && pf_req && !demand_req) ? 1'b1 : speculative_d;
  assign icache_dreq_o.spec = spec_req;

  // Update Control Flow Predictions
  bht_update_t bht_update;
  btb_update_t btb_update;

  assign bht_update.valid = resolved_branch_i.valid
                                & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign bht_update.pc = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;
  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid = resolved_branch_i.valid
                                & resolved_branch_i.is_mispredict
                                & (resolved_branch_i.cf_type == ariane_pkg::JumpR);
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // ------------------------------------------------------------------
  // I$ response pipeline register
  // ------------------------------------------------------------------
  // re-align the cache line
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};
  // loop-buffer inject: present as a 1-cycle I$ response without a request
  assign lbuf_inject = FtqEn && CVA6Cfg.LoopBufEn && lbuf_consume;

  // Do not register the next I$ return while IQ is replaying an
  // overflowed leftover-complete packet (s4-v-iq8-twice: 12960 taken
  // while 12958 replay'd), except leftover_complete of a still-pending
  // carry (leftover_retake). leftover_take_ok MINI-FAIL s4-v-lotake-minis
  // (gated all take; 2jr hang). pipe_keep MINI-FAIL s4-v-pipekeep-minis
  // (held leftover_drop; osbi illegal 129b8). serving_unaligned &&
  // take==next_block SIGSEGV s4-v-lotake1. Not leftover_drop npc mux.
  assign present_exp = g6lc_fetch_pkg::present_expected(
      bp_pend_q, 64'(bp_tgt_q), 64'(realigner_vaddr));
  assign icache_take = (icache_dreq_i.valid | lbuf_inject)
      && !kill_drop
      && g6lc_fetch_pkg::bp_ret_ok(bp_pend_q,
          g6lc_fetch_pkg::same_win(CVA6Cfg,
              64'(icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr),
              64'(bp_tgt_q)))
      && g6lc_fetch_pkg::leftover_retake(
          replay_q, leftover_valid,
          g6lc_fetch_pkg::leftover_next(
              64'(icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr),
              64'(leftover_pc)));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      npc_rst_load_q    <= 1'b1;
      npc_q             <= '0;
      speculative_q     <= '0;
      icache_data_q     <= '0;
      icache_valid_q    <= 1'b0;
      icache_vaddr_q    <= 'b0;
      icache_gpaddr_q   <= 'b0;
      icache_tinst_q    <= 'b0;
      icache_gva_q      <= 1'b0;
      icache_ex_valid_q <= ariane_pkg::FE_NONE;
      btb_q             <= '0;
      bht_q             <= '0;
      present_exp_q     <= '0;
    end else begin
      npc_rst_load_q <= 1'b0;
      npc_q          <= npc_d;
      speculative_q  <= speculative_d;
      // A line already registered here would still be presented next cycle and
      // re-enter the instruction queue, so drop it on any redirect. kill_s2 only
      // cancels the in-flight request.
      if (flush_i || is_mispredict || bp_fire) begin
        icache_valid_q    <= 1'b0;
        icache_ex_valid_q <= ariane_pkg::FE_NONE;
        // I3/I7: re-base the prefix filter on the redirect target.
        //
        // `present_exp_q` is a MONOTONIC-PROGRESS filter: `slot_ge_expected`
        // drops any slot whose pc is below it, which is what stops a
        // same-window sequential HIT from re-issuing the prefix ahead of a
        // jump target. That is only sound while addresses increase. A redirect
        // may go BACKWARDS -- `mret` to `mepc+4`, a taken backward branch, a
        // trap entry to a low `mtvec` -- and until now this branch left the
        // register holding the PRE-redirect address. When that stale value is
        // above the target, every slot in the target's own (partial) window is
        // dropped and fetch effectively resumes at the next window boundary.
        //
        // Measured before this fix, in mini_csr_expected_trap: the handler set
        // mepc=0x80000024 and execution resumed at 0x80000028; the second probe
        // set mepc=0x80000042 and resumed at 0x80000048 -- each time the next
        // 8-byte boundary, losing `csrw mtvec,t1` and `lui t3,0xe`, which is why
        // the cookie compare saw 0xec02 instead of 0xe601. Aligned redirects
        // (jr s0 -> 0x80000000, trap entry -> handler at 0x80000060) were
        // unaffected, which is what made this look like a trap bug rather than a
        // fetch one.
        //
        // Cleared, NOT seeded with `npc_d`. Seeding with npc_d was tried first and
        // traded one bug for another: it fixed the two trap minis but hung
        // mini_fdt_lenp_sw (PASS -> timeout), because npc_d at the instant of a
        // flush is not always the address the redirect eventually requests, and a
        // seed ABOVE the real target drops that target's window -- the very
        // failure this is meant to remove, with a different stale value.
        //
        // Clearing cannot over-filter, and it costs nothing real: prefix-drop
        // exists for the SAME-WINDOW SEQUENTIAL HIT case, where a jump target
        // sits inside a window already being streamed and the slots ahead of it
        // must not issue. After a redirect there is no such prefix -- the window
        // is freshly requested AT the target and `icache_data` is shifted by
        // `shamt` so slot 0 IS the target. The filter is re-armed one cycle later
        // by the normal `icache_take` update, so exactly one window is unfiltered
        // and that window has nothing to filter.
        present_exp_q     <= '0;
      end else begin
        // prefer the real I$ return, else inject the loop buffer into the same pipe
        icache_valid_q <= icache_take;
        if (icache_take) begin
          icache_data_q     <= icache_dreq_i.valid ? icache_data : lbuf_data;
          icache_vaddr_q    <= icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr;
          icache_ex_valid_q <= icache_dreq_i.valid ? fe_exception(icache_dreq_i.ex.cause)
              : ariane_pkg::FE_NONE;
          icache_gpaddr_q <= (CVA6Cfg.RVH && icache_dreq_i.valid) ?
              icache_dreq_i.ex.tval2[CVA6Cfg.GPLEN-1:0] : '0;
          icache_tinst_q <= (CVA6Cfg.RVH && icache_dreq_i.valid) ? icache_dreq_i.ex.tinst : '0;
          icache_gva_q <= (CVA6Cfg.RVH && icache_dreq_i.valid) ? icache_dreq_i.ex.gva : 1'b0;
          // save the uppermost prediction
          btb_q <= btb_prediction[NrInstr-1];
          bht_q <= bht_prediction[NrInstr-1];
          present_exp_q <= g6lc_fetch_pkg::present_expected(
              bp_pend_q, 64'(bp_tgt_q),
              64'(icache_dreq_i.valid ? icache_dreq_i.vaddr : ftq_head_vaddr));
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Prediction structures
  // ------------------------------------------------------------------
  // RAS snapshot / restore for the BP checkpoint; train_hart is the hart of the
  // resolving branch so snap/restore stay per-hart
  logic ras_restore;
  ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_stack_snap;
  ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_restore_stack;
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] resolve_hart;
  assign resolve_hart = resolved_branch_i.hart_id;

  // Prediction-time checkpoint bookkeeping (TAGE fabric): push one entry per
  // consumed real-CF slot — decode type, not predicted cf_type, so the push
  // set equals the resolve set; pop one per resolved CF.
  logic [NrInstr-1:0] bp_push_cf;
  logic             bp_cf_resolve;
  for (genvar i = 0; i < NrInstr; i++) begin : gen_bp_push_cf
    assign bp_push_cf[i] = (is_branch[i] | is_jump[i] | is_jalr[i] | is_return[i])
                           & instr_queue_consumed[i];
  end
  assign bp_cf_resolve = resolved_branch_i.valid
                         && (resolved_branch_i.cf_type != ariane_pkg::NoCF);

  if (CVA6Cfg.RASDepth == 0) begin : gen_no_ras
    assign ras_predict = '0;
    assign ras_stack_snap = '0;
  end else begin : gen_ras
    ras #(
        .CVA6Cfg(CVA6Cfg),
        .ras_t  (ras_t),
        .DEPTH  (CVA6Cfg.RASDepth)
    ) i_ras (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .hart_i          (smt_hart_i),
        .train_hart_i    (resolve_hart),
        .push_i          (ras_push),
        .pop_i           (ras_pop),
        .data_i          (ras_update),
        .data_o          (ras_predict),
        .stack_snapshot_o(ras_stack_snap),
        .restore_i       (ras_restore),
        .restore_stack_i (ras_restore_stack)
    );
  end

  // FPGA BTB/BHT retain their BRAM lookup phase; ASIC predictors follow the
  // response being realigned, including loop-buffer injection.
  assign vpc_btb = CVA6Cfg.FpgaEn ? icache_dreq_i.vaddr : realigner_vaddr;
  assign vpc_bht = !CVA6Cfg.FpgaEn ? realigner_vaddr :
      (CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q;

  // classic BTB, unless the ITTAGE fabric owns the indirect prediction
  if (CVA6Cfg.BTBEntries == 0
      || (CVA6Cfg.BPType == config_pkg::TAGE_LITE && CVA6Cfg.BPIndirectEn)) begin : gen_no_btb
    if (!(CVA6Cfg.BPType == config_pkg::TAGE_LITE && CVA6Cfg.BPIndirectEn)) begin : gen_btb_tie
      assign btb_prediction = '0;
    end
  end else begin : gen_btb
    btb #(
        .CVA6Cfg         (CVA6Cfg),
        .btb_update_t    (btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES      (CVA6Cfg.BTBEntries)
    ) i_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_btb),
        .btb_update_i    (btb_update),
        .btb_prediction_o(btb_prediction)
    );
  end

  if (CVA6Cfg.BHTEntries == 0) begin : gen_no_bht
    assign bht_prediction = '0;
  end else if (CVA6Cfg.BPType == config_pkg::BHT) begin : gen_bht
    bht #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (CVA6Cfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::PH_BHT) begin : gen_bht2lvl
    bht2lvl #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        .vpc_i           (icache_vaddr_q),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::GSHARE) begin : gen_gshare
    // standalone gshare (PC xor GHR), same port contract as bht
    g6lc_bp_gshare #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (CVA6Cfg.BHTEntries)
    ) i_gshare (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .hart_i          (smt_hart_i),
        .train_hart_i    (resolve_hart),
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::TAGE_LITE) begin : gen_tage_lite
    // TAGE + optional loop / SC / ITTAGE / checkpoint (GHR+RAS). btb_prediction
    // is driven here only with BPIndirectEn, else the classic BTB owns it.
    btb_prediction_t [NrInstr-1:0] btb_fabric;
    g6lc_bp_top #(
        .CVA6Cfg         (CVA6Cfg),
        .bht_update_t    (bht_update_t),
        .btb_update_t    (btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .ras_t           (ras_t)
    ) i_bp_top (
        .clk_i,
        .rst_ni,
        .flush_bp_i,
        .debug_mode_i,
        .hart_i             (smt_hart_i),
        .resolve_hart_i     (resolve_hart),
        .push_cf_i          (bp_push_cf),
        .cf_resolve_i       (bp_cf_resolve),
        .vpc_bht_i          (vpc_bht),
        .vpc_btb_i          (vpc_btb),
        .bht_update_i       (bht_update),
        .btb_update_i       (btb_update),
        .mispredict_i       (resolved_branch_i.valid && resolved_branch_i.is_mispredict),
        .ras_stack_i        (ras_stack_snap),
        .ras_restore_o      (ras_restore),
        .ras_restore_stack_o(ras_restore_stack),
        .bht_prediction_o   (bht_prediction),
        .btb_prediction_o   (btb_fabric)
    );
    if (CVA6Cfg.BPIndirectEn) begin : gen_ittage_btb
      assign btb_prediction = btb_fabric;
    end
  end

  // only the TAGE fabric checkpoints the RAS; flush_bp still clears it
  if (CVA6Cfg.BPType != config_pkg::TAGE_LITE) begin : gen_no_ras_restore
    assign ras_restore = 1'b0;
    assign ras_restore_stack = '0;
  end

  // we need to inspect up to INSTR_PER_FETCH instructions for branches and jumps
  for (genvar i = 0; i < NrInstr; i++) begin : gen_instr_scan
    instr_scan #(
        .CVA6Cfg(CVA6Cfg)
    ) i_instr_scan (
        .instr_i     (instr[i]),
        .rvi_return_o(rvi_return[i]),
        .rvi_call_o  (rvi_call[i]),
        .rvi_branch_o(rvi_branch[i]),
        .rvi_jalr_o  (rvi_jalr[i]),
        .rvi_jump_o  (rvi_jump[i]),
        .rvi_imm_o   (rvi_imm[i]),
        .rvc_branch_o(rvc_branch[i]),
        .rvc_jump_o  (rvc_jump[i]),
        .rvc_jr_o    (rvc_jr[i]),
        .rvc_return_o(rvc_return[i]),
        .rvc_jalr_o  (rvc_jalr[i]),
        .rvc_call_o  (rvc_call[i]),
        .rvc_imm_o   (rvc_imm[i])
    );
  end

  // O7m note: an experiment to flush the instruction queue on predicted taken
  // control flow (bp_fire) was tried and reverted. It removed the return target
  // along with the fall-through and the core refetched the caller path. The
  // right fix is to keep the return target and remove only the fall-through, or
  // to order the group without inverting program order. See AGENTS-todo.md O7m.

  instr_queue #(
      .CVA6Cfg(CVA6Cfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .hart_i             (smt_hart_i),
      .instr_i            (instr),                 // from re-aligner
      .addr_i             (addr),                  // from re-aligner
      .exception_i        (icache_dreq_i.valid && icache_dreq_i.ex.valid ? fe_exception(icache_dreq_i.ex.cause) : ariane_pkg::FE_NONE),     // from I$
      .exception_addr_i   (realigner_vaddr),
      .exception_gpaddr_i (CVA6Cfg.RVH && icache_dreq_i.valid ? icache_dreq_i.ex.tval2[CVA6Cfg.GPLEN-1:0] : '0),
      .exception_tinst_i  (CVA6Cfg.RVH && icache_dreq_i.valid ? icache_dreq_i.ex.tinst : '0),
      .exception_gva_i    (CVA6Cfg.RVH && icache_dreq_i.valid && icache_dreq_i.ex.gva),
      .predict_address_i  (predict_address),
      .cf_type_i          (cf_type),
      .valid_i            (instruction_valid),     // from re-aligner
      .leftover_complete_i(serving_unaligned),
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i)    // to back-end
  );

//pragma translate_off
  // -------------------------------------------------------------------------
  // WINDOW LIFECYCLE PROBE (`+fetch_win_trace`).
  //
  // Added because the last three attributions for "instructions did not retire"
  // were each wrong, and each would have been caught immediately by looking at
  // the whole window lifecycle instead of one suspected signal. The rule this
  // encodes: when the question is WHERE something is dropped, instrument every
  // stage that can drop it and read, rather than testing one hypothesis per
  // rebuild.
  //
  // One line per cycle in which anything happens to a window: an I$ response, a
  // take, a kill, or a redirect. Fields are the full set of reasons a window or
  // its slots can disappear between the I$ and the queue:
  //   rsp/vaddr  the response and the address it is attributed to
  //   take       registered into icache_*_q, i.e. accepted by the frontend
  //   k1/k2      kill_s1 / kill_s2 -- request killed in flight
  //   bpf        bp_fire -- prediction redirect, ALSO clears icache_valid_q
  //   fl/mp/rp   flush_i / is_mispredict / replay
  //   una        serving_unaligned (realigner carrying a split instruction)
  //   vmask      per-slot instruction_valid actually presented to the queue
  //   iqr        instr_queue_ready -- backpressure, the other way slots vanish
  // -------------------------------------------------------------------------
  logic fwt_en;
  initial fwt_en = $test$plusargs("fetch_win_trace");

  // -------------------------------------------------------------------------
  // KILL-PERSISTENCE CHECK (`+fetch_kill_check`).
  //
  // Contract under test: a fetch whose request was killed must never have its
  // response accepted. Under token ownership a response is wanted only while
  // `want_valid_q` holds and its token matches `want_token_q`, and
  // `icache_take` is gated by `kill_drop` — exactly "valid and not the wanted
  // token" — so a take of an unwanted response cannot occur. This probe
  // reports it if a future change lets it: the regression detector for this
  // contract. Still report-only rather than fatal: promoting it to a gate
  // is a separate decision that needs a full-suite silence result first, and a
  // fatal probe that fires in an unrelated configuration would be worse than no
  // probe at all.
  // -------------------------------------------------------------------------
  logic kcheck_en;
  initial kcheck_en = $test$plusargs("fetch_kill_check");

  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i) begin
    if (rst_ni && kcheck_en && icache_dreq_i.valid && icache_take
        && !(want_valid_q && icache_dreq_i.token == want_token_q && !want_pf_q)) begin
      $display("[killchk] t=%0t UNWANTED TAKE rsp_vaddr=%h rsp_tok=%0d want=%b want_tok=%0d npc=%h",
               $time, icache_dreq_i.vaddr, icache_dreq_i.token,
               want_valid_q, want_token_q, npc_d);
    end
  end

  // verilog_lint: waive always-ff-non-reset
  always_ff @(posedge clk_i) begin
    if (rst_ni && fwt_en && $time() < 200000) begin
      if (icache_dreq_i.valid || icache_take || kill_s1 || kill_s2 || bp_fire
          || flush_i || is_mispredict || replay) begin
        // Single string literal, NOT a {"..",".."} concatenation: with the
        // concatenated form the block compiled (fwt_en appears in the generated
        // model) but the format string never reached the binary and the probe
        // printed nothing -- a silent no-op probe, which is the worst kind.
        $display("[win] t=%0t rsp=%b vaddr=%h take=%b k1=%b k2=%b bpf=%b fl=%b mp=%b rp=%b una=%b vmask=%b iqr=%b npc=%h",
                 $time, icache_dreq_i.valid, icache_dreq_i.vaddr, icache_take,
                 kill_s1, kill_s2, bp_fire, flush_i, is_mispredict, replay,
                 serving_unaligned, instruction_valid, instr_queue_ready, npc_d);
      end
    end
  end
//pragma translate_on

endmodule
