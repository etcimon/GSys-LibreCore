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
// Description: Ariane Instruction Fetch Frontend
//
// This module interfaces with the instruction cache, handles control
// change request from the back-end and does branch prediction.
// U2: optional FTQ + FDIP + loop buffer (FtqDepth==0 ⇒ pre-U2 netlist path).

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
    // COMMIT PC - COMMIT
    input logic [CVA6Cfg.VLEN-1:0] pc_commit_i,
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
    // U6.1 SMT: active hart + PC restore on coarse-grain switch - SMT
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] smt_hart_i,
    input logic smt_restore_i,
    input logic [CVA6Cfg.VLEN-1:0] smt_npc_restore_i,
    // Live NPC for PC bank snapshot - SMT
    output logic [CVA6Cfg.VLEN-1:0] npc_q_o,
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

  // Instruction Cache Registers, from I$
  logic                            [    CVA6Cfg.FETCH_WIDTH-1:0] icache_data_q;
  logic                                                          icache_valid_q;
  ariane_pkg::frontend_exception_t                               icache_ex_valid_q;
  logic                            [           CVA6Cfg.VLEN-1:0] icache_vaddr_q;
  logic                            [          CVA6Cfg.GPLEN-1:0] icache_gpaddr_q;
  logic                            [                       31:0] icache_tinst_q;
  logic                                                          icache_gva_q;
  logic                                                          instr_queue_ready;
  logic                            [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_queue_consumed;
  // upper-most branch-prediction from last cycle
  btb_prediction_t                                               btb_q;
  bht_prediction_t                                               bht_q;
  // instruction fetch is ready
  logic                                                          if_ready;
  logic [CVA6Cfg.VLEN-1:0] npc_d, npc_q;  // next PC
  logic [CVA6Cfg.VLEN-1:0] fetch_address;  // address presented to I$ / FTQ this cycle
  assign npc_q_o = npc_q;
  // smt_hart_i selects RAS/GHR banks when NrHarts>1

  // indicates whether we come out of reset (then we need to load boot_addr_i)
  logic                                       npc_rst_load_q;

  logic                                       replay;
  logic [                   CVA6Cfg.VLEN-1:0] replay_addr;

  // shift amount
  logic [$clog2(CVA6Cfg.INSTR_PER_FETCH)-1:0] shamt;
  // address will always be 16 bit aligned, make this explicit here
  if (CVA6Cfg.RVC) begin : gen_shamt
    assign shamt = icache_dreq_i.vaddr[$clog2(CVA6Cfg.INSTR_PER_FETCH):1];
  end else begin
    assign shamt = 1'b0;
  end

  // -----------------------
  // Ctrl Flow Speculation
  // -----------------------
  // RVI ctrl flow prediction
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvi_imm;
  // RVC branching
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvc_imm;
  // re-aligned instruction and address (coming from cache - combinationally)
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][            31:0] instr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0]                   instruction_valid;
  // BHT, BTB and RAS prediction
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction;
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction_shifted;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction_shifted;
  ras_t                                                            ras_predict;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_btb;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_bht;

  // branch-predict update
  logic                                                            is_mispredict;
  logic ras_push, ras_pop;
  logic [           CVA6Cfg.VLEN-1:0] ras_update;

  // Instruction FIFO
  logic [           CVA6Cfg.VLEN-1:0] predict_address;
  cf_t  [CVA6Cfg.INSTR_PER_FETCH-1:0] cf_type;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvi_cf;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvc_cf;

  logic                               serving_unaligned;
  // Re-align instructions
  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (icache_dreq_o.kill_s2),
      .valid_i            (icache_valid_q),
      .serving_unaligned_o(serving_unaligned),
      .address_i          (icache_vaddr_q),
      .data_i             (icache_data_q),
      .valid_o            (instruction_valid),
      .addr_o             (addr),
      .instr_o            (instr)
  );
  // --------------------
  // Branch Prediction
  // --------------------
  // select the right branch prediction result
  // in case we are serving an unaligned instruction in instr[0] we need to take
  // the prediction we saved from the previous fetch
  if (CVA6Cfg.RVC) begin : gen_btb_prediction_shifted
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];

    // for all other predictions we can use the generated address to index
    // into the branch prediction data structures
    for (genvar i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_prediction_address
      assign bht_prediction_shifted[i] = bht_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
      assign btb_prediction_shifted[i] = btb_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
    end
  end else begin
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][1]];
  end
  ;

  // for the return address stack it doesn't matter as we have the
  // address of the call/return already
  logic bp_valid;

  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_branch;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_call;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_return;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jalr;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i] & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end

  // taken/not taken
  always_comb begin
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;

    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) cf_type[i] = ariane_pkg::NoCF;

    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

    // lower most prediction gets precedence
    for (int i = CVA6Cfg.INSTR_PER_FETCH - 1; i >= 0; i--) begin
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000: ;  // regular instruction e.g.: no branch
        // unconditional jump to register, we need the BTB to resolve this
        4'b0001: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          if (CVA6Cfg.BTBEntries != 0 && btb_prediction_shifted[i].valid) begin
            predict_address = btb_prediction_shifted[i].target_address;
            cf_type[i] = ariane_pkg::JumpR;
          end
        end
        // its an unconditional jump to an immediate
        4'b0010: begin
          ras_pop = 1'b0;
          ras_push = 1'b0;
          taken_rvi_cf[i] = rvi_jump[i];
          taken_rvc_cf[i] = rvc_jump[i];
          cf_type[i] = ariane_pkg::Jump;
        end
        // return
        4'b0100: begin
          // make sure to only alter the RAS if we actually consumed the instruction
          ras_pop = ras_predict.valid & instr_queue_consumed[i];
          ras_push = 1'b0;
          // Hang-7 residual: if RAS is empty/invalid, do NOT advertise Return
          // with a garbage target. Leave NoCF so branch_unit always treats the
          // JALR as mispredicted (cf==NoCF) and redirects to rs1 (ra). Marking
          // Return with an invalid RAS top previously allowed wrong-path fetch
          // into fdt_path_offset alias (jal memchr with a0=-4).
          // I4m: RAS valid with ra==0 is still garbage (empty slot / cancelled
          // ld ra). Treat like invalid so EX redirects to architectural ra.
          if (ras_predict.valid && |ras_predict.ra) begin
            predict_address = ras_predict.ra;
            cf_type[i] = ariane_pkg::Return;
          end else begin
            // Sequential NPC only for bookkeeping; NoCF forces EX mispredict→ra.
            predict_address = addr[i] + (rvc_return[i] ? {{CVA6Cfg.VLEN - 2{1'b0}}, 2'h2}
                                                       : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'h4});
            cf_type[i] = ariane_pkg::NoCF;
          end
        end
        // branch prediction
        4'b1000: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          // if we have a valid dynamic prediction use it
          if (bht_prediction_shifted[i].valid) begin
            taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
            taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
            // otherwise default to static prediction
          end else begin
            // set if immediate is negative - static prediction
            taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
            taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
          end
          if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
            cf_type[i] = ariane_pkg::Branch;
          end
        end
        default: ;
        // default: $error("Decoded more than one control flow");
      endcase
      // if this instruction, in addition, is a call, save the resulting address
      // but only if we actually consumed the address
      if (is_call[i]) begin
        ras_push   = instr_queue_consumed[i];
        ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
      end
      // calculate the jump target address
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
      end
    end
  end
  // or reduce struct
  always_comb begin
    bp_valid = 1'b0;
    // BP cannot be valid if we have a return instruction and the RAS is not giving a valid address
    // Check that we encountered a control flow and that for a return the RAS
    // contains a valid prediction.
    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++)
    bp_valid |= ((cf_type[i] != NoCF & cf_type[i] != Return) |
                 ((cf_type[i] == Return) & ras_predict.valid & |ras_predict.ra));
    // I4p: never redirect fetch to PC=0 (empty DRAM → illegal). SMT2 I4o
    // saw hart0 mepc=0; BTB/RAS target 0 is never a useful OpenSBI fetch.
    if (CVA6Cfg.NrHarts > 1 && predict_address == '0) bp_valid = 1'b0;
  end
  // Classic EX mispredict only. Matching taken Jump must NOT reseed NPC or
  // feed TAGE mispredict_i: reseed re-fetches calls → double RAS push
  // (RASDepth=2) → return to PC=0x4; OR-ing into is_mispredict → IAF
  // mepc=0x1400000000. Hang-6 residual fallthrough is handled elsewhere
  // (icache clear on bp_valid, CF issue stall). Post-bp IQ sequential drop
  // was tried (Jump-only) but regressed bare smt_dual_concurrent — do not rearm
  // without a concurrent soak.
  // I4t: even if EX still raises is_mispredict on JALR-to-0, do not kill
  // FTQ/I$ or reseed NPC. Scoreboard/controller consume the branch_unit
  // clear; this is the frontend half of the same SMT hygiene.
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict
                         & ~(CVA6Cfg.NrHarts > 1 & ~(|resolved_branch_i.target_address));

  // Cache interface
  // Gate ICache requests and NPC updates during fence.i
  // U2: when FTQ is enabled, NPC advances against FTQ space (decoupled from I$
  // ready); demand fetch drains the FTQ; FDIP may steal idle I$ cycles.
  logic ftq_full, ftq_empty, ftq_head_valid;
  logic [CVA6Cfg.VLEN-1:0] ftq_head_vaddr, ftq_peek_vaddr;
  logic ftq_peek_valid, ftq_pop, ftq_push;
  logic lbuf_hit, lbuf_active, lbuf_consume;
  logic [CVA6Cfg.FETCH_WIDTH-1:0] lbuf_data;
  logic pf_req;
  logic [CVA6Cfg.VLEN-1:0] pf_vaddr;
  logic demand_req, demand_fire;

  if (CVA6Cfg.FtqDepth == 0) begin : gen_no_ftq
    assign icache_dreq_o.req = instr_queue_ready & ~halt_frontend_i;
    assign if_ready = icache_dreq_i.ready & instr_queue_ready & ~halt_frontend_i;
    assign ftq_full = 1'b0;
    assign ftq_empty = 1'b1;
    assign ftq_head_valid = 1'b0;
    assign ftq_head_vaddr = '0;
    assign ftq_peek_valid = 1'b0;
    assign ftq_peek_vaddr = '0;
    assign ftq_pop = 1'b0;
    assign ftq_push = 1'b0;
    assign lbuf_hit = 1'b0;
    assign lbuf_active = 1'b0;
    assign lbuf_data = '0;
    assign lbuf_consume = 1'b0;
    assign pf_req = 1'b0;
    assign pf_vaddr = '0;
    assign demand_req = 1'b0;
    assign demand_fire = 1'b0;
  end else begin : gen_ftq
    // After a predicted taken CF, hold off sequential FTQ fills until the
    // redirected fetch has been registered and re-decoded. Otherwise NPC runs
    // ahead into post-target addresses (often empty DRAM → 0x0000 → ILLEGAL)
    // before kill_s2 can cancel them. Classic (FtqDepth==0) relies on kill_s2
    // racing the single in-flight sequential request; FTQ depth breaks that race.
    logic ftq_cf_hold_q;
    // Hold sequential FTQ fill after predicted CF, mispredict reseed,
    // AMO/CSR set_pc reseed, *or* trap/eret/debug redirect until the redirect
    // fetch is presented — otherwise if_ready re-pushes the same PC and the
    // stream is duplicated/shifted (mini_amocas_w: lui@0x3c twice; CRT memcpy
    // ret → wrong PC after RAS miss; I-ADD-01 mret → fetch mepc-2 → tohost 1337).
    logic ftq_trap_reseed;
    logic [CVA6Cfg.VLEN-1:0] ftq_trap_vaddr;
    // mret/sret/dret, exception entry, or debug halt: force FTQ to the architectural
    // redirect PC. Without this, same-cycle flush+if_ready re-seeds with stale
    // fetch_address (= pre-mret npc_q, often mepc-2 for RVC-aligned mepc).
    assign ftq_trap_reseed = eret_i | ex_valid_i |
                             (CVA6Cfg.DebugEn && set_debug_pc_i);
    assign ftq_trap_vaddr = eret_i ? epc_i
                          : ex_valid_i ? trap_vector_base_i
                          : (CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0]
                             + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0]);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ftq_cf_hold_q <= 1'b0;
      end else if (bp_valid || is_mispredict || (set_pc_commit_i & flush_i) ||
                   ftq_trap_reseed) begin
        ftq_cf_hold_q <= 1'b1;
      end else if (icache_valid_q) begin
        // Registered fetch presented; resume sequential fill
        ftq_cf_hold_q <= 1'b0;
      end else if (flush_i && !(set_pc_commit_i) && !ftq_trap_reseed) begin
        ftq_cf_hold_q <= 1'b0;
      end
    end

    // NPC may run ahead while I$ is busy (only FTQ-full / CF-hold stalls it).
    // On predicted taken CF / mispredict / trap reseed the FTQ is flushed+reseeded,
    // so treat that cycle as having free space even if the pre-flush queue was full.
    assign if_ready = (!ftq_full | bp_valid | is_mispredict | ftq_trap_reseed) &
                      instr_queue_ready & ~halt_frontend_i &
                      (~ftq_cf_hold_q | bp_valid | is_mispredict | ftq_trap_reseed);
    // Demand I$ only when loop buffer cannot supply the FTQ head.
    // Critical: FTQ reseed is *registered*. Same-cycle head is still pre-flush;
    // suppress demand so s1 never accepts a stale head (mini_jumps).
    assign demand_req = ftq_head_valid & instr_queue_ready & ~halt_frontend_i & ~lbuf_hit
                        & ~bp_valid & ~is_mispredict & ~flush_i;
    assign demand_fire = demand_req & icache_dreq_i.ready;

    // Force-reseed FTQ on:
    //  - AMO/CSR set_pc+flush_if → commit+4 (NPC may have run ahead during AMO)
    //  - mispredict → resolved target (fetch_address is still pre-redirect npc_q;
    //    pushing it re-seeds the *wrong* stream — CRT memcpy c.jr ra with RAS miss
    //    then committed fallthrough into memset mid-body → ret@0 / tohost 1337)
    //  - eret / exception / debug → architectural epc or trap vector (I-ADD-01:
    //    mret to RVC-aligned mepc=…e2 must not re-seed sequential …e0)
    // Keep sequential if_ready push otherwise (needed for boot).
    logic                    ftq_setpc_reseed;
    logic [CVA6Cfg.VLEN-1:0] ftq_push_vaddr;
    assign ftq_setpc_reseed = set_pc_commit_i & flush_i;
    assign ftq_push_vaddr = ftq_setpc_reseed
        ? (pc_commit_i + (halt_i ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100}))
        : (is_mispredict ? resolved_branch_i.target_address
           : (ftq_trap_reseed ? ftq_trap_vaddr
              : (bp_valid ? predict_address : fetch_address)));
    // Force push on set_pc, mispredict, or trap redirect even if if_ready is low.
    assign ftq_push = if_ready | ftq_setpc_reseed | is_mispredict | ftq_trap_reseed;

    // Pop FTQ only when I$ accepts a demand request that is not being killed.
    // If we pop while kill_s2 is high (bp_valid still set from the taken CF),
    // the redirect target is dropped and the I$ miss return is discarded
    // (MISS/KILL_MISS with no cache write) — a later fetch can then present
    // stale/wrong data (seen as illegal at jal targets e.g. memcpy).
    // Loop-buffer inject still consumes a fetch block.
    assign ftq_pop = (demand_fire & ~icache_dreq_o.kill_s2) | lbuf_consume;

    // Flush FTQ on predicted taken CF as well as mispredict/pipeline flush.
    // Without this, sequential addresses already queued after a taken jump/branch
    // are drained by demand fetch (often empty DRAM → 0x0000 → ILLEGAL_INSTR).
    // Same-cycle push (via if_ready) re-seeds the redirect PC into an empty FTQ.
    g6lc_ftq #(
        .CVA6Cfg(CVA6Cfg),
        .DEPTH  (CVA6Cfg.FtqDepth)
    ) i_ftq (
        .clk_i,
        .rst_ni,
        .flush_i       (flush_i | is_mispredict | bp_valid),
        .push_i        (ftq_push),
        .push_vaddr_i  (ftq_push_vaddr),
        .push_taken_i  (bp_valid),
        .push_target_i (predict_address),
        .pop_i         (ftq_pop),
        .head_vaddr_o  (ftq_head_vaddr),
        .head_taken_o  (),
        .head_target_o (),
        .head_valid_o  (ftq_head_valid),
        .peek_offset_i ((CVA6Cfg.FdipDistance > 0) ? $clog2(CVA6Cfg.FtqDepth+1)'(CVA6Cfg.FdipDistance) : '0),
        .peek_vaddr_o  (ftq_peek_vaddr),
        .peek_valid_o  (ftq_peek_valid),
        .full_o        (ftq_full),
        .empty_o       (ftq_empty),
        .count_o       ()
    );

    if (CVA6Cfg.FdipEn) begin : gen_fdip
      g6lc_fdip #(
          .CVA6Cfg (CVA6Cfg),
          .DISTANCE(CVA6Cfg.FdipDistance)
      ) i_fdip (
          .clk_i,
          .rst_ni,
          .flush_i         (flush_i | is_mispredict | bp_valid),
          .enable_i        (1'b1),
          .peek_valid_i    (ftq_peek_valid),
          .peek_vaddr_i    (ftq_peek_vaddr),
          .demand_active_i (demand_req),
          .icache_ready_i  (icache_dreq_i.ready),
          .pf_req_o        (pf_req),
          .pf_vaddr_o      (pf_vaddr),
          .pf_drop_pma_o   ()
      );
    end else begin : gen_no_fdip
      assign pf_req   = 1'b0;
      assign pf_vaddr = '0;
    end

    if (CVA6Cfg.LoopBufEn) begin : gen_lbuf
      g6lc_loop_buffer #(
          .CVA6Cfg    (CVA6Cfg),
          .NR_ENTRIES (CVA6Cfg.LoopBufEntries),
          .DATA_W     (CVA6Cfg.FETCH_WIDTH)
      ) i_lbuf (
          .clk_i,
          .rst_ni,
          .flush_i        (flush_i | is_mispredict | flush_bp_i),
          .enable_i       (1'b1),
          .cf_valid_i     (bp_valid),
          .cf_taken_i     (bp_valid),
          // Arm on the in-flight fetch PC that produced the taken prediction
          .cf_pc_i        (icache_vaddr_q),
          .cf_target_i    (predict_address),
          // Demand fills only (never speculative FDIP) — sequential EQ inside
          .fill_valid_i   (icache_dreq_i.valid & ~icache_dreq_o.spec),
          .fill_vaddr_i   (icache_dreq_i.vaddr),
          .fill_data_i    (icache_dreq_i.data[CVA6Cfg.FETCH_WIDTH-1:0]),
          .lookup_vaddr_i (ftq_head_vaddr),
          .lookup_ready_i (instr_queue_ready & ~halt_frontend_i),
          .hit_o          (lbuf_hit),
          .data_o         (lbuf_data),
          .active_o       (lbuf_active),
          .consume_o      (lbuf_consume)
      );
    end else begin : gen_no_lbuf
      assign lbuf_hit     = 1'b0;
      assign lbuf_active  = 1'b0;
      assign lbuf_data    = '0;
      assign lbuf_consume = 1'b0;
    end

    // Demand wins; FDIP only when demand idle; loop-buffer hits skip I$ entirely
    assign icache_dreq_o.req = demand_req | pf_req;
  end

  // We need to flush the cache pipeline if:
  // 1. We mispredicted
  // 2. Want to flush the whole processor front-end
  // 3. Need to replay an instruction because the fetch-fifo was full
  assign icache_dreq_o.kill_s1 = is_mispredict | flush_i | replay;
  // if we have a valid branch-prediction we need to only kill the last cache request
  // also if we killed the first stage we also need to kill the second stage (inclusive flush)
  assign icache_dreq_o.kill_s2 = icache_dreq_o.kill_s1 | bp_valid;

  // Update Control Flow Predictions
  bht_update_t bht_update;
  btb_update_t btb_update;

  // assert on branch, deassert when resolved
  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolved_branch_i.valid || |is_branch || |is_return || |is_jalr) && !flush_i;
  // Prefetches are always speculative; demand keeps existing policy
  assign icache_dreq_o.spec = (CVA6Cfg.FtqDepth != 0 && pf_req && !demand_req) ? 1'b1 : speculative_d;

  assign bht_update.valid = resolved_branch_i.valid
                                & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign bht_update.pc = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;
  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid = resolved_branch_i.valid
                                & resolved_branch_i.is_mispredict
                                & (resolved_branch_i.cf_type == ariane_pkg::JumpR)
                                & (|resolved_branch_i.target_address);
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // -------------------
  // Next PC
  // -------------------
  // next PC (NPC) can come from (in order of precedence):
  // 0. Default assignment/replay instruction
  // 1. Branch Predict taken
  // 2. Control flow change request (misprediction)
  // 3. Return from environment call
  // 4. Exception/Interrupt
  // 5. Pipeline Flush because of CSR side effects
  // Mis-predict handling is a little bit different
  // select PC a.k.a PC Gen
  always_comb begin : npc_select
    // check whether we come out of reset
    // this is a workaround. some tools have issues
    // having boot_addr_i in the asynchronous
    // reset assignment to npc_q, even though
    // boot_addr_i will be assigned a constant
    // on the top-level.
    if (npc_rst_load_q) begin
      npc_d         = boot_addr_i;
      fetch_address = boot_addr_i;
    end else begin
      fetch_address = npc_q;
      // keep stable by default
      npc_d         = npc_q;
    end
    // 0. Branch Prediction
    if (bp_valid) begin
      fetch_address = predict_address;
      npc_d = predict_address;
    end
    // 1. Default assignment
    if (if_ready) begin
      npc_d = {
        fetch_address[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1, {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
      };
    end
    // 2. Replay instruction fetch
    if (replay) begin
      npc_d = replay_addr;
    end
    // 3. Control flow change request (mispredict)
    // Classic (FtqDepth==0): next fetch is the resolved target.
    // FTQ: reseed queue with the resolved target (see ftq_push_vaddr), but NPC
    // steps to the *following* fetch block so when CF-hold lifts we do not push
    // the target twice (same pattern as set_pc_commit reseed below).
    if (is_mispredict) begin
      // I4q (smt2): EX may resolve JALR/Return to 0 (rs1/ra stale or x0).
      // Fetching 0 is empty DRAM → illegal (I4o hart0 mepc=0). Keep npc_q;
      // commit still retires the CF. SI unchanged.
      if (!(CVA6Cfg.NrHarts > 1 && resolved_branch_i.target_address == '0)) begin
        if (CVA6Cfg.FtqDepth != 0) begin
          logic [CVA6Cfg.VLEN-1:0] mp_target;
          mp_target = resolved_branch_i.target_address;
          npc_d = {
            mp_target[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1,
            {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
          };
        end else begin
          npc_d = resolved_branch_i.target_address;
        end
      end
    end
    // 4. Return from environment call
    // Classic: next fetch is epc. FTQ: force-reseed FTQ with epc (ftq_trap_vaddr),
    // NPC steps to the following fetch block so CF-hold lift does not double-push.
    if (eret_i) begin
      if (CVA6Cfg.FtqDepth != 0) begin
        npc_d = {
          epc_i[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1,
          {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
        };
      end else begin
        npc_d = epc_i;
      end
    end
    // 5. Exception/Interrupt
    if (ex_valid_i) begin
      if (CVA6Cfg.FtqDepth != 0) begin
        npc_d = {
          trap_vector_base_i[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1,
          {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
        };
      end else begin
        npc_d = trap_vector_base_i;
      end
    end
    // 6. Pipeline Flush because of CSR side effects
    // On a pipeline flush start fetching from the next address
    // of the instruction in the commit stage
    // we either came here from a flush request of a CSR instruction or AMO,
    // so as CSR or AMO instructions do not exist in a compressed form
    // we can unconditionally do PC + 4 here
    // or if the commit stage is halted, just take the current pc of the
    // instruction in the commit stage
    // TODO(zarubaf) This adder can at least be merged with the one in the csr_regfile stage
    if (set_pc_commit_i) begin
      // Classic (FtqDepth==0): next fetch is commit+4.
      // FTQ: reseed queue with commit+4, but NPC steps to the *following*
      // fetch block so when CF-hold lifts we do not push commit+4 twice
      // (duplicate/shifted post-AMO stream).
      if (CVA6Cfg.FtqDepth != 0 && !halt_i) begin
        logic [CVA6Cfg.VLEN-1:0] reseed_pc;
        reseed_pc = pc_commit_i + {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100};
        npc_d = {
          reseed_pc[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1,
          {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
        };
      end else begin
        npc_d = pc_commit_i + (halt_i ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
      end
    end
    // 7. Debug
    // enter debug on a hard-coded base-address
    if (CVA6Cfg.DebugEn && set_debug_pc_i) begin
      if (CVA6Cfg.FtqDepth != 0) begin
        logic [CVA6Cfg.VLEN-1:0] dbg_pc;
        dbg_pc = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0]
                 + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];
        npc_d = {
          dbg_pc[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1,
          {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
        };
      end else begin
        npc_d = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0]
                + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];
      end
    end
    // 8. U6.1 SMT coarse-grain switch: restore banked NPC for newly active hart.
    // Highest precedence after reset so switch is not lost to speculative bp.
    if (CVA6Cfg.NrHarts > 1 && smt_restore_i) begin
      npc_d         = smt_npc_restore_i;
      fetch_address = smt_npc_restore_i;
    end

    // I$ address: direct path, or FTQ head / FDIP prefetch when U2 is on
    if (CVA6Cfg.FtqDepth == 0) begin
      icache_dreq_o.vaddr = fetch_address;
    end else if (demand_req) begin
      icache_dreq_o.vaddr = ftq_head_vaddr;
    end else if (pf_req) begin
      icache_dreq_o.vaddr = pf_vaddr;
    end else begin
      icache_dreq_o.vaddr = fetch_address;
    end
  end

  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data;
  // re-align the cache line
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};

  // U2 loop-buffer inject: present as a 1-cycle I$ response without a request.
  // lbuf_consume already folds ready/halt; keep Ftq/Loop gates for generate elision.
  logic lbuf_inject;
  assign lbuf_inject = (CVA6Cfg.FtqDepth != 0) && (CVA6Cfg.LoopBufEn != 0) && lbuf_consume;

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
    end else begin
      npc_rst_load_q <= 1'b0;
      npc_q          <= npc_d;
      speculative_q  <= speculative_d;
      // Hang-7 / hang-6 residual: drop registered I$ presentation on
      // mispredict, flush, *or predicted taken CF* (bp_valid). kill_s2 cancels
      // in-flight sequential over-fetch, but a line already registered in
      // icache_valid_q still presents next cycle and re-enters instr_queue.
      // Seen as: (1) ret RAS-miss → fallthrough jal@alias; (2) jal fdt_next_tag
      // @0x80012b0a with EX Jump predict correct yet sequential bne@0x80012b10.
      if (flush_i || is_mispredict || bp_valid) begin
        icache_valid_q    <= 1'b0;
        icache_ex_valid_q <= ariane_pkg::FE_NONE;
      end else begin
      // Prefer real I$ return; else inject loop-buffer data into the same pipeline
      icache_valid_q <= icache_dreq_i.valid | lbuf_inject;
      if (icache_dreq_i.valid) begin
        icache_data_q  <= icache_data;
        icache_vaddr_q <= icache_dreq_i.vaddr;
        if (CVA6Cfg.RVH) begin
          icache_gpaddr_q <= icache_dreq_i.ex.tval2[CVA6Cfg.GPLEN-1:0];
          icache_tinst_q  <= icache_dreq_i.ex.tinst;
          icache_gva_q    <= icache_dreq_i.ex.gva;
        end else begin
          icache_gpaddr_q <= 'b0;
          icache_tinst_q  <= 'b0;
          icache_gva_q    <= 1'b0;
        end

        // Map the only three exceptions which can occur in the frontend to a two bit enum
        if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_GUEST_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT;
        end else if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_PAGE_FAULT;
        end else if (icache_dreq_i.ex.cause == riscv::INSTR_ACCESS_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_ACCESS_FAULT;
        end else begin
          icache_ex_valid_q <= ariane_pkg::FE_NONE;
        end
        // save the uppermost prediction
        btb_q <= btb_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
        bht_q <= bht_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
      end else if (lbuf_inject) begin
        // Sequential loop-buffer inject: zero exceptions, same BP shadow
        icache_data_q     <= lbuf_data;
        icache_vaddr_q    <= ftq_head_vaddr;
        icache_gpaddr_q   <= '0;
        icache_tinst_q    <= '0;
        icache_gva_q      <= 1'b0;
        icache_ex_valid_q <= ariane_pkg::FE_NONE;
        btb_q             <= btb_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
        bht_q             <= bht_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
      end
      end // ~flush_i && ~is_mispredict && ~bp_valid
    end
  end

  // FSE S2: RAS stack snapshot / restore for BP checkpoint (TAGE_LITE fabric)
  // FSE S5: train_hart = resolving branch hart for snap/restore isolation
  logic ras_restore;
  ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_stack_snap;
  ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_restore_stack;
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] resolve_hart;
  assign resolve_hart = resolved_branch_i.hart_id;

  if (CVA6Cfg.RASDepth == 0) begin
    assign ras_predict = '0;
    assign ras_stack_snap = '0;
  end else begin : ras_gen
    ras #(
        .CVA6Cfg(CVA6Cfg),
        .ras_t  (ras_t),
        .DEPTH  (CVA6Cfg.RASDepth)
    ) i_ras (
        .clk_i,
        .rst_ni,
        .flush_bp_i(flush_bp_i),
        .hart_i    (smt_hart_i),
        .train_hart_i(resolve_hart),
        .push_i(ras_push),
        .pop_i(ras_pop),
        .data_i(ras_update),
        .data_o(ras_predict),
        .stack_snapshot_o(ras_stack_snap),
        .restore_i(ras_restore),
        .restore_stack_i(ras_restore_stack)
    );
  end

  //For FPGA, BTB is implemented in read synchronous BRAM
  //while for ASIC, BTB is implemented in D flip-flop
  //and can be read at the same cycle.
  //Same for BHT
  assign vpc_btb = (CVA6Cfg.FpgaEn) ? icache_dreq_i.vaddr : icache_vaddr_q;
  assign vpc_bht = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q;

  // Classic BTB when not using ITTAGE fabric path
  if (CVA6Cfg.BTBEntries == 0 ||
      (CVA6Cfg.BPType == config_pkg::TAGE_LITE && CVA6Cfg.BPIndirectEn)) begin
    if (!(CVA6Cfg.BPType == config_pkg::TAGE_LITE && CVA6Cfg.BPIndirectEn)) begin
      assign btb_prediction = '0;
    end
    // else: btb_prediction driven by cva6_bp_top below
  end else begin : btb_gen
    btb #(
        .CVA6Cfg   (CVA6Cfg),
        .btb_update_t(btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES(CVA6Cfg.BTBEntries)
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

  if (CVA6Cfg.BHTEntries == 0) begin
    assign bht_prediction = '0;
  end else if (CVA6Cfg.BPType == config_pkg::BHT) begin : bht_gen
    bht #(
        .CVA6Cfg   (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES(CVA6Cfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::PH_BHT) begin : bht2lvl_gen
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
  end else if (CVA6Cfg.BPType == config_pkg::GSHARE) begin : gshare_gen
    // U1: standalone gshare (PC ⊕ GHR), same port contract as bht.
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
  end else if (CVA6Cfg.BPType == config_pkg::TAGE_LITE) begin : tage_lite_gen
    // U1 fabric: TAGE + optional loop / SC / ITTAGE / checkpoint (GHR+RAS).
    // btb_prediction is only driven here when BPIndirectEn (ITTAGE); otherwise
    // the classic btb_gen above owns it.
    btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] btb_fabric;
    g6lc_bp_top #(
        .CVA6Cfg          (CVA6Cfg),
        .bht_update_t     (bht_update_t),
        .btb_update_t     (btb_update_t),
        .btb_prediction_t (btb_prediction_t),
        .ras_t            (ras_t)
    ) i_bp_top (
        .clk_i,
        .rst_ni,
        .flush_bp_i,
        .debug_mode_i,
        .hart_i          (smt_hart_i),
        .resolve_hart_i  (resolve_hart),
        .vpc_bht_i       (vpc_bht),
        .vpc_btb_i       (vpc_btb),
        .bht_update_i    (bht_update),
        .btb_update_i    (btb_update),
        .mispredict_i    (is_mispredict),
        .ras_stack_i     (ras_stack_snap),
        .ras_restore_o   (ras_restore),
        .ras_restore_stack_o(ras_restore_stack),
        .bht_prediction_o(bht_prediction),
        .btb_prediction_o(btb_fabric)
    );
    if (CVA6Cfg.BPIndirectEn) begin : gen_ittage_btb
      assign btb_prediction = btb_fabric;
    end
  end

  // RAS restore only from TAGE fabric checkpoint; other BP types leave RAS as-is
  // (flush_bp still clears on exceptions).
  if (CVA6Cfg.BPType != config_pkg::TAGE_LITE) begin : gen_no_ras_restore
    assign ras_restore = 1'b0;
    assign ras_restore_stack = '0;
  end

  // we need to inspect up to CVA6Cfg.INSTR_PER_FETCH instructions for branches
  // and jumps
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_instr_scan
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

  instr_queue #(
      .CVA6Cfg(CVA6Cfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .instr_i            (instr),                 // from re-aligner
      .addr_i             (addr),                  // from re-aligner
      .exception_i        (icache_ex_valid_q),     // from I$
      .exception_addr_i   (icache_vaddr_q),
      .exception_gpaddr_i (icache_gpaddr_q),
      .exception_tinst_i  (icache_tinst_q),
      .exception_gva_i    (icache_gva_q),
      .predict_address_i  (predict_address),
      .cf_type_i          (cf_type),
      .valid_i            (instruction_valid),     // from re-aligner
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i)    // to back-end
  );

endmodule
