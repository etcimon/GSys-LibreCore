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
    // I4br: mtvec fetch/tail in progress — suppress SMT switch (0 when SI)
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
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i,
    // G1fh: dest-FIFO / presented CSR-to-a0 (active fetch hart)
    output logic g1fh_csr_a0_o,
    // G1lq: IQ-visible aligned-00 RVI LOAD
    // (g1ct_valid) for ID g1lo_cap. Flop
    // only — not G1lm IQ rewrite.
    // G1ma: one latch per hart.
    output logic [CVA6Cfg.NrHarts-1:0] g1lq_v_o,
    output logic [CVA6Cfg.NrHarts-1:0][4:0] g1lq_rd_o,
    output logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1lq_line_o,
    output logic [CVA6Cfg.NrHarts-1:0] g1lq_a3_o
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
  // I4z (smt2): keep fetching mtvec until that 8B block is *registered*.
  // I4w nat skipped jal@0x3d8 and retired csrr@3e0/sd@3e4 — the first trap
  // fetch was killed (flush/stale bp_valid) after NPC had already stepped.
  logic                                       trap_fetch_q;
  logic                                       trap_tail_q;
  logic [                   CVA6Cfg.VLEN-1:0] trap_pc_q;
  logic                                       trap_fetch_hit;
  logic                                       trap_hold;

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
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][            31:0] instr_ra, instr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr_ra, addr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0]                   instruction_valid_ra, instruction_valid;
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
  logic                               leftover_pending;
  // G1bv: stash leftover-complete taken-Branch target I$ return.
  // Present it after the leftover line drops. Not G1bb freeze.
  // Not G1bu reject. Not G1bq/G1bt kill_s2. Not G1ab NPC.
  // Not G1bk/G1bn/G1bi. SMT+SS.
  logic                            g1bv_wait_q;
  logic                            g1bv_stash_v_q;
  logic                            g1bv_use_stash;
  logic                            g1bv_arm;
  logic [CVA6Cfg.VLEN-1:0]         g1bv_tgt_q;
  logic [CVA6Cfg.VLEN-1:0]         g1bv_arm_line_q;
  logic [CVA6Cfg.VLEN-1:0]         g1bv_stash_addr_q;
  logic [CVA6Cfg.FETCH_WIDTH-1:0]  g1bv_stash_data_q;
  assign g1bv_use_stash = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      g1bv_stash_v_q &&
      !(icache_valid_q &&
        (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         g1bv_stash_addr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) &&
      !(icache_valid_q &&
        (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         g1bv_arm_line_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]));
  // G1cc: do not sequential-step NPC while leftover-Branch
  // target is outstanding and not yet presented. TRACE
  // 0x4c8→0x4d0→0x4e0 skipped the 0x4d0 fill. Not G1ab
  // (Jump unconsumed). Not G1bu reject. Not G1bq kill_s2.
  // SMT+SS. Uses existing g1bv wait/tgt.
  // G1cd hold on g1bv_arm same-cycle — HOLD-FAIL no
  // cookie-exit (starved OpenSBI fetch). Do not re-land.
  logic g1cc_hold_tgt;
  assign g1cc_hold_tgt = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      g1bv_wait_q &&
      !g1bv_use_stash &&
      !(icache_valid_q &&
        (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         g1bv_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]));
  // G1cs: after a line-aligned EX mispredict, do not
  // sequential-step NPC until that target line is
  // presented. TRACE t=920 0x4d0 reseed then +8 to
  // 0x4d8 before the fill returns (c.li never writes).
  // Registered wait only — not G1cd same-cycle arm.
  // Not G1ce/G1ck leftover NPC stall. Not G1cc
  // leftover-Branch g1bv_wait. SMT+SS.
  logic                            g1cs_wait_q;
  logic [CVA6Cfg.VLEN-1:0]         g1cs_tgt_q;
  logic                            g1cs_arm;
  logic                            g1cs_hold_tgt;
  assign g1cs_arm = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      is_mispredict && !ex_valid_i &&
      (resolved_branch_i.target_address[CVA6Cfg.FETCH_ALIGN_BITS-1:0] == '0);
  assign g1cs_hold_tgt = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      g1cs_wait_q &&
      !(icache_valid_q &&
        (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         g1cs_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]));
  // G1db leftover-complete slot0 Jump !+8 this beat —
  // HOLD-FAIL no cookie-exit (past 6 min). Do not
  // re-land (G1ce leftover +8 stall class; OpenSBI
  // leftover JAL starves fetch).
  // G1ct: first presented beat of the line-aligned
  // mispredict target is dest-only to IQ. Later-slot
  // Branch (beq@0x4d4) otherwise shares that one-cycle
  // packet and c.li never writes. Not G1cl leftover
  // later slots. Not G1cm leftover Jump. SMT+SS.
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1ct_valid;
  logic                               g1ct_tgt_beat;
  logic                               g1cz_leftover_jump_beat;
  assign g1ct_tgt_beat = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      g1cs_wait_q && icache_valid_q &&
      (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
       g1cs_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]);
  // G1cz: leftover-complete slot0 Jump is slot0-only to
  // IQ. Later-slot li/bne at 0x3fa otherwise enter IQ
  // on the complete beat and jal never issues (G1cy
  // never saw fetch[0] as leftover jal). Jump-only —
  // not G1cl leftover-Branch hide (P1 fallthrough is
  // live). Not G1cm later-slot Jump hide. Not G1ct
  // mispredict dest-only. SMT+SS. One-cycle window.
  assign g1cz_leftover_jump_beat = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 && serving_unaligned &&
      instruction_valid[0] && (cf_type[0] == ariane_pkg::Jump);
  // G1eq: aligned I|I whose slot1 is CSR (7a8 addi+csrr)
  // is not hidden by G1ct dest-only / G1cz leftover-Jump
  // slot0-only. Those zero valid[1+] so csrr never
  // enters IQ (no csrrcmt; 7bc sees a0=1). Not G1eo
  // idx_is. Not G1ct 0x4d0 C|Branch. SMT+SS.
  logic g1eq_ii_csr;
  assign g1eq_ii_csr = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      instruction_valid[0] && instruction_valid[1] &&
      (addr[0][2:1] == 2'b00) &&
      (instr[0][1:0] == 2'b11) &&
      (instr[1][1:0] == 2'b11) &&
      (instr[1][6:0] == 7'b1110011) &&
      (instr[1][11:7] != 5'd0);
  // G1fr: G1fq only fills when valid[1]=0. An already-
  // valid later-slot c.jalr/jalr (7ba) is still smashed
  // by G1ct dest-only. Keep those slots (G1eq analog).
  // Do not exempt G1cz leftover-Jump slot0-only (that
  // hid later li/bne so jal issues). SMT+SS.
  // E5: encodings in g6lc_rvc_enc (bit-identical).
  // EXTRACT g1gi–g1gm: leftover jal x0 hide while jalr
  // in flight / npc 01 / 01-hold, leftover-PC replay
  // block. Scan loop stays here. Flops + predicates in
  // g6lc_lj_hide. Mux stays here. G1gn HOLD-FAIL.
  // SMT+SS.
  logic g1gi_see_jalr;
  logic g1gi_lj;
  logic g1gi_hide;
  always_comb begin
    g1gi_see_jalr = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (instruction_valid[i] && g6lc_rvc_enc::is_jalr(instr[i]))
          g1gi_see_jalr = 1'b1;
      end
    end
  end
  assign g1gi_lj = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      serving_unaligned && instruction_valid[0] &&
      g6lc_iq_hide::leftover_jal_x0(addr[0][2:1], instr[0]);
  // Leftover jal x0 after taken same-group skip (P2 / 766).
  // Arm on aligned 8B: earlier Branch + leftover jal x0 start.
  // Keep the arm across kill_s2; block leftover-PC replay of that
  // jal x0. Hide present/is_jump only — do not clear leftover (NT
  // may still complete). Skip-range latch HOLD-FAIL 51b1c001 / 3dc.
  // c.jalr skip-arm HOLD-FAIL. G1gn HOLD-FAIL. Not G1gi jalr-in-flight.
  // SMT+SS.
  logic [63:0]                g6lc_lj_line;
  logic                       g6lc_lj_arm;
  logic [CVA6Cfg.VLEN-1:0]    g6lc_lj_arm_pc;
  logic [CVA6Cfg.VLEN-1:0]    g6lc_lj_br_pc;
  logic                       g6lc_lj_nt;
  logic                       g6lc_lj_range;
  logic                       g6lc_lj_skip;
  logic                       g6lc_lj_rpl;
  logic                       g6lc_lj_pend;
  logic                       g6lc_lj_clr;
  logic                       g6lc_lj_hold;
  logic                       g6lc_lj_pres;
  logic                       g6lc_lj_pc_v;
  logic [CVA6Cfg.VLEN-1:0]    g6lc_lj_pc;
  assign g6lc_lj_line = 64'(g1bv_use_stash ? g1bv_stash_data_q
                                           : g1et_data);
  assign g6lc_lj_arm_pc = {
      (g1bv_use_stash ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:3]
                      : icache_vaddr_q[CVA6Cfg.VLEN-1:3]),
      3'b110};
  assign g6lc_lj_br_pc = {
      (g1bv_use_stash ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:3]
                      : icache_vaddr_q[CVA6Cfg.VLEN-1:3]),
      3'b000};
  assign g6lc_lj_arm = g6lc_leftover::skip_arm(
      CVA6Cfg, g1bv_use_stash || icache_valid_q,
      (g1bv_use_stash ? g1bv_stash_addr_q[2:1]
                      : icache_vaddr_q[2:1]) == 2'b00,
      g6lc_lj_line[15:0],
      g6lc_lj_line[63:48]);
  assign g6lc_lj_nt = resolved_branch_i.valid &&
      (resolved_branch_i.cf_type == ariane_pkg::Branch) &&
      !resolved_branch_i.is_taken;
  logic g6lc_lj_taken;
  assign g6lc_lj_taken = resolved_branch_i.valid &&
      (resolved_branch_i.cf_type == ariane_pkg::Branch) &&
      resolved_branch_i.is_taken;
  assign g6lc_lj_pres = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      instruction_valid[0] && g6lc_iq_hide::is_jal_x0(instr[0]);
  assign g6lc_lj_range = g6lc_lj_pres &&
      g6lc_leftover::skip_range(
          resolved_branch_i.valid && resolved_branch_i.is_taken &&
              (resolved_branch_i.cf_type == ariane_pkg::Branch),
          64'(resolved_branch_i.pc),
          64'(resolved_branch_i.target_address),
          64'(addr[0]));
  g6lc_lj_hide #(
      .CVA6Cfg(CVA6Cfg)
  ) i_g6lc_lj_hide (
      .clk_i,
      .rst_ni,
      .flush_i         (flush_i),
      .see_jalr_i      (g1gi_see_jalr),
      .jump_r_i        (resolved_branch_i.valid &&
                        (resolved_branch_i.cf_type == ariane_pkg::JumpR)),
      .leftover_lj_gi_i(g1gi_lj),
      .npc01_i         (npc_q[2:1] == 2'b01),
      .arm_i           (g6lc_lj_arm),
      .arm_pc_i        (g6lc_lj_arm_pc),
      .arm_br_pc_i     (g6lc_lj_br_pc),
      .leftover_lj_i   (g6lc_lj_pres),
      .leftover_pc_i   (addr[0]),
      .br_nt_i         (g6lc_lj_nt),
      .br_taken_i      (g6lc_lj_taken),
      .br_pc_i         (resolved_branch_i.pc),
      .npc_i           (npc_q),
      .replay_addr_i   (replay_addr),
      .hide_o          (g6lc_lj_skip),
      .gi_hide_o       (g1gi_hide),
      .replay_block_o  (g6lc_lj_rpl),
      .pend_o          (g6lc_lj_pend),
      .clear_leftover_o(g6lc_lj_clr),
      .lj_pc_v_o       (g6lc_lj_pc_v),
      .lj_pc_o         (g6lc_lj_pc)
  );
  assign g6lc_lj_hold = g6lc_lj_skip || g6lc_lj_range;
  // G1gn leftover-PC bp_valid npc skip —
  // HOLD-FAIL no cookie ~6 min (kill_s2
  // still fired, starved OpenSBI fetch).
  // Do not re-land (G1bq/G1bt kill_s2
  // class). Not G1ce/+8.
  always_comb begin
    g1ct_valid = instruction_valid;
    // G1ft: leftover-Jump slot0-only still hides later
    // li/bne (G1cz) but keeps a later-slot JumpR
    // (7ba c.jalr). G1fs needs valid_i[1]=1.
    // Not G1cy later-slot fallthrough. SMT+SS.
    if ((g1cz_leftover_jump_beat || g1ct_tgt_beat) &&
        !g1eq_ii_csr && !g1fq_cjalr) begin
      for (int unsigned i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!(instruction_valid[i] && g6lc_rvc_enc::is_jalr(instr[i])))
          g1ct_valid[i] = 1'b0;
      end
    end
    // later_br_01 npc-01 dest-only / later-slot Branch mute —
    // MINI-FAIL FDT printed 23 @1184 (G1iz/G1jh class). Do not
    // re-land. G1by any-npc later-slot Branch HOLD-FAIL.
    if (g1gi_hide || g6lc_lj_hold)
      g1ct_valid[0] = 1'b0;
    // Skip-hide leftover jal x0: do not push later slots of that
    // leftover-complete beat. IQ address overflow would replay
    // leftover-PC (G1az addr[0]) and starve the taken-target
    // fetch (p2_ok auipc/tohost). Not G1cm (later Jump only).
    if (g6lc_lj_skip)
      g1ct_valid = '0;
    if (g6lc_lj_pend) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (instruction_valid[i] && g6lc_iq_hide::is_jal_x0(instr[i]))
          g1ct_valid[i] = 1'b0;
      end
    end
  end
  // G1ce one-cycle +8 stall on leftover-complete —
  // HOLD-FAIL no cookie-exit. Do not re-land (starved
  // OpenSBI fetch, G1cd class).
  // G1cf leftover-next I$ vaddr override — MINI-FAIL
  // P1 0x10 @406 (first load_be32). Do not re-land.
  // G1cj leftover-complete NoCF sequential-next I$
  // stash — HOLD-FAIL wfi-exit t=217088 plat_hc=80.
  // Do not re-land (replayed sequential after leftover).
  // G1ck leftover-NoCF sequential-next +8 hold —
  // HOLD-FAIL no cookie-exit (past 10 min). Do not
  // re-land (G1ce class; leftover-complete NPC stall
  // family closed).
  // G1cn one-cycle I$ req suppress after leftover-NoCF
  // sequential next — MINI-FAIL P1 0x10 @386. Do not
  // re-land (header-walk leftover-complete, G1cf class).
  // G1du: leftover-RVI captured this beat (last
  // halfword [1:0]==11 at pc[2:1]==11) must survive
  // replay kill_s2. 7c0 c.mv+ld+jal first half
  // otherwise loses leftover; 7c8 never completes
  // jal (no @38e0, ra stays 752). G1cq is leftover-
  // complete NoCF !replay-kill I$. Not G1as drop.
  // Not G1db NPC. SMT+SS.
  // G1dx: C|I|U capture sets valid[3]=0 (instr[3]
  // is {0,data[63:48]}). G1du required valid[3] and
  // never armed. Keep on last-halfword RVI-start
  // even when that slot is not presented. G1dw
  // leftover-pending +8 hold — HOLD-FAIL. Not G1ce.
  logic g1du_keep_leftover;
  assign g1du_keep_leftover = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 && replay && !serving_unaligned &&
      icache_valid_q &&
      (addr[CVA6Cfg.INSTR_PER_FETCH-1][2:1] == 2'b11) &&
      (instr[CVA6Cfg.INSTR_PER_FETCH-1][1:0] == 2'b11);
  // G1ic: leftover-PC I$ ([2:1]==11) must not
  // present while npc is mid-line 01. 7ba
  // Branch is leftover 766 data (G1hh/G1hi).
  // G1el holds only while an unconsumed 01
  // package exists. Not G1gz rewrite. Not
  // G1es leftover I|I. SMT+SS.
  // G1in leftover-PC I$ mute while npc
  // aligned 00 — MINI-FAIL lottery hang
  // @400000. Do not re-land (starves
  // leftover-complete next-line fetch).
  logic g1ic_leftover_mid;
  assign g1ic_leftover_mid = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      (npc_q[2:1] == 2'b01) &&
      icache_valid_q && !g1bv_use_stash &&
      (icache_vaddr_q[2:1] == 2'b11);
  // G1fu: present a registered same-line I$ from mid-line
  // npc (7ba) so realign starts at +2, not line base.
  logic g1fu_mid;
  assign g1fu_mid = g6lc_present::fu_mid(
      CVA6Cfg, icache_valid_q, npc_q[2:1] == 2'b01,
      npc_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
          icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]);
  // G1gx: g1fu_mid reuses same-line I$ (often a
  // line-aligned request, shamt=0) with
  // address=npc ([2:1]==01). Realign 2'b01
  // assumes halfword 0 is already at address_i.
  // Shift so slot0 is the 16-bit at that PC,
  // not {c.jalr, c.beqz} at 7ba. Not G1gv.
  // SMT+SS.
  logic [CVA6Cfg.FETCH_WIDTH-1:0] g1gx_data;
  assign g1gx_data = g6lc_present::gx_shift(
      CVA6Cfg, g1fu_mid, icache_vaddr_q[2:1] == 2'b00)
      ? (icache_data_q >> 16) : icache_data_q;
  // Re-align instructions
  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (icache_dreq_o.kill_s2),
      .hart_i             (smt_hart_i),
      .keep_unaligned_i   (trap_hold | g1du_keep_leftover),
      .clear_unaligned_i  ((CVA6Cfg.NrHarts > 1 & ex_valid_i) |
                           g1gi_hide | g6lc_lj_clr),
      .valid_i            (g1bv_use_stash ? 1'b1 :
                           (icache_valid_q && !g1ic_leftover_mid)),
      .serving_unaligned_o(serving_unaligned),
      .leftover_pending_o (leftover_pending),
      .address_i          (g1bv_use_stash ? g1bv_stash_addr_q :
                           (g1fu_mid ? npc_q : icache_vaddr_q)),
      .data_i             (g1bv_use_stash ? g1bv_stash_data_q : g1gx_data),
      .valid_o            (instruction_valid_ra),
      .addr_o             (addr_ra),
      .instr_o            (instr_ra)
  );
  // G1et: if realign left aligned I|I slot1 invalid
  // (leftover_next ate slot0 and shifted csrr off),
  // fill slot1 from the registered I$ high word when
  // slot0 is line-aligned RVI and that word is CSR.
  // Leftover-complete slot0 PC is [2:1]==11 so this
  // does not steal leftover_next (G1es hang). Not
  // G1ed smash. Not G1eo idx_is. SMT+SS.
  logic [CVA6Cfg.FETCH_WIDTH-1:0] g1et_data;
  logic                           g1et_ii_csr;
  assign g1et_data = g1bv_use_stash ? g1bv_stash_data_q : icache_data_q;
  assign g1et_ii_csr = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      (g1bv_use_stash || icache_valid_q) &&
      !serving_unaligned &&
      instruction_valid_ra[0] && !instruction_valid_ra[1] &&
      (addr_ra[0][2:1] == 2'b00) &&
      (instr_ra[0][1:0] == 2'b11) &&
      (g1et_data[33:32] == 2'b11) &&
      (g1et_data[38:32] == 7'b1110011) &&
      (g1et_data[43:39] != 5'd0);
  // G1fq: realign left slot1 invalid on an aligned
  // compressed package (7b8 c.beqz) whose I$ next
  // halfword is c.jalr (7ba). G1fo/G1fp never saw
  // JumpR. Fill from registered I$ like G1et.
  // !serving_unaligned so leftover_next is not
  // stolen (G1es). Not G1eo idx_is. SMT+SS.
  logic g1fq_cjalr;
  // G1hb: G1fq only filled when valid[1]=0.
  // Force slot1 from I$ +2 exact c.jalr even
  // when slot1 is already valid (wrong bits
  // at 7ba). Not G1fz any slot1. Not G1gz
  // slot0. Not G1es leftover_next. SMT+SS.
  assign g1fq_cjalr = g6lc_present::fq_cjalr(
      CVA6Cfg, g1bv_use_stash || icache_valid_q, serving_unaligned,
      instruction_valid_ra[0], addr_ra[0][2:1] == 2'b00,
      instr_ra[0][1:0] != 2'b11, g1et_data[31:0]);
  // G1hc: G1fq/G1hb need !serving_unaligned
  // and aligned slot0. Leftover-complete
  // slot0 is [2:1]==11 so they miss 7ba.
  // Fill slot1 from I$ +2 exact c.jalr
  // only while npc is mid-line 01. Aligned
  // leftover-next (auipc+addi) keeps
  // realign slot1. Not G1es I|I. Not G1gz.
  // SMT+SS.
  logic g1hc_cjalr;
  logic [CVA6Cfg.VLEN-1:3] g1hc_line;
  assign g1hc_line = g1bv_use_stash
      ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:3]
      : icache_vaddr_q[CVA6Cfg.VLEN-1:3];
  assign g1hc_cjalr = g6lc_present::hc_cjalr(
      CVA6Cfg, g1bv_use_stash || icache_valid_q, serving_unaligned,
      instruction_valid_ra[0], addr_ra[0][2:1] == 2'b11,
      (g1bv_use_stash ? g1bv_stash_addr_q[2:1]
                      : icache_vaddr_q[2:1]) == 2'b00,
      npc_q[2:1] == 2'b01,
      g1et_data[31:0]);
  // G1gz mid-line slot0 from I$ +2 halfword —
  // MINI-FAIL lottery printed 2 @411, FDT
  // printed 90 @1082. Do not re-land (yanks
  // live mid-line slot0). Isolated P4 stays.
  // G1ha: same I$ +2 only when that halfword
  // is exact c.jalr. Not G1gz all mid-line.
  // Not G1gv [6:2] mash. SMT+SS.
  logic [1:0]  g1ha_v01;
  logic [15:0] g1ha_hw;
  logic        g1ha_cjalr;
  logic        g1ha_mid;
  assign g1ha_v01 = g1bv_use_stash ? g1bv_stash_addr_q[2:1]
                                   : icache_vaddr_q[2:1];
  assign g1ha_hw  = g6lc_present::plus2_hw(g1ha_v01, g1et_data[31:0]);
  assign g1ha_cjalr = g6lc_rvc_enc::is_cjalr16(g1ha_hw);
  assign g1ha_mid = g6lc_present::ha_mid(
      CVA6Cfg, g1bv_use_stash || icache_valid_q,
      (g1ha_v01 == 2'b00) || (g1ha_v01 == 2'b01), g1ha_cjalr,
      g1fu_mid && !g1bv_use_stash,
      instruction_valid_ra[0] && (addr_ra[0][2:1] == 2'b01) &&
          (addr_ra[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
           (g1bv_use_stash
                ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]
                : icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])));
  // G1ie: frontend latch of aligned compressed
  // Branch (line + C2 rs1'). Used by the
  // present rewrite below. G1ir also arms
  // from the G1iq stash. SMT+SS.
  logic        g1ie_v_q;
  logic [4:0]  g1ie_rs1_q;
  logic [CVA6Cfg.VLEN-1:3] g1ie_line_q;
  // G1kk: aligned-00 RVI LOAD rd
  // recovers sibling 8-byte 01 Branch
  // as c.jalr of that rd (7b0 ld a5
  // → 7ba). 16-byte line. Not G1ie
  // C2 rs1' (a0). Not G1je any-op.
  // G1mc: one latch per hart — a peer
  // 00 LOAD must not occupy hart0.
  // SMT+SS.
  logic [CVA6Cfg.NrHarts-1:0] g1kk_v_q;
  logic [CVA6Cfg.NrHarts-1:0][4:0] g1kk_rd_q;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1kk_line_q;
  // G1kl: sibling 8-byte half of the
  // captured aligned-00 LOAD (addr[3]).
  logic [CVA6Cfg.NrHarts-1:0] g1kk_a3_q;
  // G1le: last I$ aligned-00 RVI LOAD
  // side-stash (npc-independent).
  // Present at that LOAD's sibling 01.
  // G1kk stays npc-line (G1ld). Not
  // G1lb into G1kk. Not G1ki sticky.
  // G1mb: one latch per hart — a peer
  // I$ 00 LOAD must not occupy hart0.
  // SMT+SS.
  logic [CVA6Cfg.NrHarts-1:0] g1le_v_q;
  logic [CVA6Cfg.NrHarts-1:0][4:0] g1le_rd_q;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1le_line_q;
  logic [CVA6Cfg.NrHarts-1:0] g1le_a3_q;
  logic        g1le_load;
  logic        g1le_hit;
  logic        g1lh_load;
  logic        g1li_load;
  logic        g1le_cap;
  logic [4:0]  g1le_cap_rd;
  logic [CVA6Cfg.VLEN-1:4] g1le_cap_line;
  logic        g1le_cap_a3;
  // G1lq: IQ-visible aligned-00 RVI LOAD
  // from g1ct_valid (IQ input after G1ct
  // smash). Survives flush_i on SMT+SS
  // (G1il analog). Sideband into ID
  // g1lo_cap. G1lr: keep until sibling
  // 01 (G1lf analog). Same-line
  // recapture allowed; npc-line
  // recapture may replace a held
  // different-line LOAD (G1lg analog).
  // G1ls: present-path instruction_
  // valid 00 LOAD into g1lq_cap (G1lh
  // analog; g1ct overwrite after).
  // G1lt: live I$ 00 LOAD overwrite
  // after present (G1le analog). G1lu:
  // registered I$ 00 LOAD overwrite
  // when live dreq missed (G1li analog).
  // Not G1lb into G1kk. Not G1lm IQ
  // rewrite. Not G1ki sticky. G1ma:
  // one latch per hart — a peer IQ
  // 00 LOAD must not occupy hart0.
  // SMT+SS.
  logic [CVA6Cfg.NrHarts-1:0] g1lq_v_q;
  logic [CVA6Cfg.NrHarts-1:0][4:0] g1lq_rd_q;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1lq_line_q;
  logic [CVA6Cfg.NrHarts-1:0] g1lq_a3_q;
  logic        g1lq_cap;
  logic [4:0]  g1lq_cap_rd;
  logic [CVA6Cfg.VLEN-1:4] g1lq_cap_line;
  logic        g1lq_cap_a3;
  logic        g1ls_load;
  logic        g1lq_ct_load;
  logic        g1lq_hit;
  // G1jb: do not replace the aligned-Branch
  // recover latch/stash with a different
  // 8-byte line until that line's mid-line
  // 01 slot is presented. Not G1ja 00 I$
  // under predict. Not G1iz 01 hold.
  // SMT+SS.
  logic        g1jb_01_seen_q;
  // G1ji: sibling 8-byte line of the live
  // I$ (G1iw other-half). G1ie arms from
  // that half's compressed Branch. Not
  // G1iv stash. Not G1jh 01 steal.
  logic [CVA6Cfg.VLEN-1:3] g1ji_sib_line;
  // G1jc: first leftover-RVI I$ steal
  // while npc is mid-line 01 still
  // issues the npc 8-byte line. Later
  // leftover fetches proceed. Not G1iz
  // (every cycle). Not G1ja (any 00
  // predict). SMT+SS.
  logic        g1jc_did_q;
  logic        g1jc_steal;
  // G1jg: first sequential-next 8-byte
  // fetch while npc is mid-line 01 still
  // issues the npc 8-byte line. Not G1iz
  // every cycle. Not G1jc leftover-11.
  // Not G1jd sequential at 00. SMT+SS.
  logic        g1jg_did_q;
  logic        g1jg_steal;
  always_comb begin
    instruction_valid = instruction_valid_ra;
    addr              = addr_ra;
    instr             = instr_ra;
    if (g1et_ii_csr) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = {addr_ra[0][CVA6Cfg.VLEN-1:3], 3'b100};
      instr[1]             = g1et_data[63:32];
    end else if (g1fq_cjalr || g1hc_cjalr) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = g1hc_cjalr
          ? {g1hc_line, 3'b010}
          : (addr_ra[0] + CVA6Cfg.VLEN'(2));
      instr[1]             = {16'b0, g1et_data[31:16]};
    end
    if (g1ha_mid) begin
      instruction_valid[0] = 1'b1;
      addr[0]              = (g1fu_mid && !g1bv_use_stash)
          ? npc_q : addr_ra[0];
      instr[0]             = {16'b0, g1ha_hw};
    end
    // G1io: aligned npc + same-line I$ →
    // slot0 is I$[15:0] (the 16-bit at
    // that PC). Not G1in leftover-PC
    // mute. Not G1gz mid-line. Not G1es
    // leftover_next. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        (g1bv_use_stash || icache_valid_q) &&
        !serving_unaligned &&
        instruction_valid[0] &&
        (addr[0][2:1] == 2'b00) &&
        (npc_q[2:1] == 2'b00) &&
        ((g1bv_use_stash ? g1bv_stash_addr_q[2:1]
                         : icache_vaddr_q[2:1]) == 2'b00) &&
        (npc_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         (g1bv_use_stash
              ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]
              : icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])))
      instr[0][15:0] = g1et_data[15:0];
    // G1ip: leftover slot0 stays. When npc
    // is aligned 00, slot1 is I$[15:0]
    // (the 16-bit at npc), not G1hc +2
    // c.jalr. Not G1io slot0. Not G1es
    // leftover_next. Not G1in mute. Not
    // G1gz. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        (g1bv_use_stash || icache_valid_q) &&
        serving_unaligned &&
        instruction_valid[0] &&
        (addr[0][2:1] == 2'b11) &&
        (npc_q[2:1] == 2'b00) &&
        ((g1bv_use_stash ? g1bv_stash_addr_q[2:1]
                         : icache_vaddr_q[2:1]) == 2'b00) &&
        (npc_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         (g1bv_use_stash
              ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]
              : icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) &&
        (g1et_data[1:0] == 2'b01) &&
        ((g1et_data[15:13] == 3'b110) ||
         (g1et_data[15:13] == 3'b111))) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = npc_q;
      instr[1]             = {16'b0, g1et_data[15:0]};
    end
    // G1iq: stash of aligned I$[15:0]
    // compressed Branch (G1hj analog).
    // Present at aligned npc even if live
    // I$ is leftover 766. Do not steal
    // leftover slot0 (G1es). Not G1in
    // mute. Not G1gz. SMT+SS.
    if (g6lc_sib_cjalr::iq_br_npc00(
            CVA6Cfg, g1iq_v_q, npc_q[2:1] == 2'b00,
            npc_q[CVA6Cfg.VLEN-1:3] == g1iq_pc_q[CVA6Cfg.VLEN-1:3])) begin
      if (g6lc_sib_cjalr::leftover_slot0(
              serving_unaligned, instruction_valid[0],
              addr[0][2:1] == 2'b11)) begin
        instruction_valid[1] = 1'b1;
        addr[1]              = g1iq_pc_q;
        instr[1]             = {16'b0, g1iq_hw_q};
      end else if (!g6lc_sib_cjalr::leftover_slot0(
                       serving_unaligned, instruction_valid[0],
                       addr[0][2:1] == 2'b11)) begin
        instruction_valid[0] = 1'b1;
        addr[0]              = g1iq_pc_q;
        instr[0][15:0]       = g1iq_hw_q;
      end
    end
    // G1hh: any valid slot at [2:1]==01
    // is I$ +2 when that halfword is
    // exact c.jalr. G1ha is slot0-only;
    // G1fq/G1hc only fill slot1 under
    // leftover/aligned-slot0. Not G1gz
    // all mid-line slot0. SMT+SS.
    // G1hi: drop G1hh same-line. Leftover
    // 766 I$ is live when 7ba presents
    // so same-line never matches. Not
    // G1gz all mid-line slot0. SMT+SS.
    // npc 01 only: leftover-complete later
    // RVI at 01 (p2_ok addi @8a) must stay.
    if (g6lc_present::hh_cjalr(
            CVA6Cfg, g1bv_use_stash || icache_valid_q, g1ha_cjalr,
            npc_q[2:1] == 2'b01)) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (instruction_valid[s] &&
            (addr[s][2:1] == 2'b01))
          instr[s] = {16'b0, g1ha_hw};
      end
    end
    // G1hj: live I$ at 7ba is leftover 766,
    // not the 7b8 line. Fill mid-line 01
    // from the last aligned I$ +2 exact
    // c.jalr. Not G1hi live I$. Not G1gz.
    // SMT+SS.
    // G1jk: only at the stashed +2 PC.
    // G1jj any-01 present yanked a live
    // lottery jalr. Not G1jj capture.
    // Not G1gz. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        g1hj_v_q && !g1ha_cjalr) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (instruction_valid[s] &&
            (addr[s][2:1] == 2'b01) &&
            (addr[s] == g1hj_pc_q))
          instr[s] = {16'b0, g1hj_hw_q};
      end
    end
    // G1hk: G1hj only rewrites an existing
    // mid-line 01 slot. npc is 7ba @20467
    // with no such slot. Present slot0 at
    // npc from the stash. Do not steal
    // leftover-complete slot0. Not G1ha
    // live I$. Not G1gz. SMT+SS.
    // G1jk: npc must be the stashed +2
    // PC. Not G1jj. SMT+SS.
    if (g6lc_sib_cjalr::stash_npc01(
            CVA6Cfg, g1hj_v_q, g1ha_cjalr,
            npc_q[2:1] == 2'b01, npc_q == g1hj_pc_q,
            g6lc_sib_cjalr::leftover_blocks_01(
                serving_unaligned, instruction_valid[0],
                addr[0][2:1] == 2'b11,
                addr[0][CVA6Cfg.VLEN-1:3] ==
                    npc_q[CVA6Cfg.VLEN-1:3]))) begin
      instruction_valid[0] = 1'b1;
      addr[0]              = npc_q;
      instr[0]             = {16'b0, g1hj_hw_q};
      for (int unsigned s = 1; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        instruction_valid[s] = 1'b0;
      end
    end
    // G1jy: IDLE aligned-00 sibling pair
    // is latched aside (not G1hj — G1hm
    // leftover inject caused G1jw 71d8).
    // Present slot0 at npc 01 only when
    // npc is that latched +2. Not G1jw.
    // Not G1jj. SMT+SS.
    if (g6lc_sib_cjalr::stash_npc01(
            CVA6Cfg, g1jy_v_q && !g1hj_v_q, g1ha_cjalr,
            npc_q[2:1] == 2'b01, npc_q == g1jy_pc_q,
            g6lc_sib_cjalr::leftover_blocks_01(
                serving_unaligned, instruction_valid[0],
                addr[0][2:1] == 2'b11,
                addr[0][CVA6Cfg.VLEN-1:3] ==
                    npc_q[CVA6Cfg.VLEN-1:3]))) begin
      instruction_valid[0] = 1'b1;
      addr[0]              = npc_q;
      instr[0]             = {16'b0, g1jy_hw_q};
      for (int unsigned s = 1; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        instruction_valid[s] = 1'b0;
      end
    end
    // G1ka: present live user[33] sibling
    // c.jalr at npc 01 when npc is last
    // I$ return's sibling +2 (G1jy flop
    // missed the IDLE window). Not G1hj.
    // Not G1jw. Not G1hm. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        CVA6Cfg.FETCH_USER_WIDTH >= 34 &&
        g1ka_hit && !g1hj_v_q && !g1jy_v_q && !g1ha_cjalr &&
        !(serving_unaligned && instruction_valid[0] &&
          (addr[0][2:1] == 2'b11))) begin
      instruction_valid[0] = 1'b1;
      addr[0]              = npc_q;
      instr[0]             = {16'b0, icache_dreq_i.user[32:17]};
      for (int unsigned s = 1; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        instruction_valid[s] = 1'b0;
      end
    end
    // G1kl: G1kk only rewrites an existing
    // mid-line 01 Branch. npc 7ba has no
    // such slot (leftover occupies
    // present). Present slot0 at npc from
    // the LOAD-rd c.jalr. Sibling 8-byte
    // 01 of the captured 16-byte line.
    // G1kz: also from same-cycle I$ LOAD
    // cap (g1ky_cap / g1kn/g1kw).
    // G1la: do not skip leftover 11 when
    // sibling 01 matches (flop or
    // g1ky_cap). Slot0 is c.jalr at npc;
    // leftover is not presented this
    // beat. G1le: last I$ LOAD side-stash
    // if G1kk/g1ky miss. G1lk: G1kl from
    // g1lj_cap delayed cookie t=206848
    // (G1lb class; 7ba unchanged) —
    // reverted. G1ll: G1kl from same-
    // cycle g1le I$/registered cap with
    // npc-line (G1kz analog; not G1lk).
    // G1lw: G1kl slot0 from g1lq_hit
    // (npc-line; G1ll analog). Not G1lk
    // no-npc-line. Not G1hm off-npc
    // inject. Not G1jw G1hj. Not G1je
    // any-op. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        (g1kk_v_q[smt_hart_i] || g1ky_cap || g1le_hit || g1ll_cap ||
         g1lq_hit) &&
        !g1hj_v_q && !g1jy_v_q &&
        !g1ka_hit && !g1ha_cjalr &&
        (npc_q[2:1] == 2'b01) &&
        (g1ky_cap ||
         (g1kk_v_q[smt_hart_i] &&
          (npc_q[CVA6Cfg.VLEN-1:4] == g1kk_line_q[smt_hart_i]) &&
          (npc_q[3] != g1kk_a3_q[smt_hart_i])) ||
         g1ll_cap ||
         g1le_hit ||
         g1lq_hit)) begin
      instruction_valid[0] = 1'b1;
      addr[0]              = npc_q;
      instr[0]             = {16'b0,
          g6lc_sib_cjalr::make_cjalr16(
              g1ky_cap ? g1ky_rd :
              (g1kk_v_q[smt_hart_i] &&
               (npc_q[CVA6Cfg.VLEN-1:4] == g1kk_line_q[smt_hart_i]) &&
               (npc_q[3] != g1kk_a3_q[smt_hart_i])) ? g1kk_rd_q[smt_hart_i] :
              (g1ll_cap ? g1ll_rd :
               (g1le_hit ? g1le_rd_q[smt_hart_i] :
                g1lq_rd_q[smt_hart_i])))};
      for (int unsigned s = 1; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        instruction_valid[s] = 1'b0;
      end
    end
    // G1hl: G1hk skips leftover-complete
    // slot0. On that beat present the
    // stash as slot1 at npc (G1hc analog).
    // Slot0 stays leftover. Not G1es.
    // Not G1gz. SMT+SS.
    // G1jk: npc must be the stashed +2
    // PC. Not G1jj. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        g1hj_v_q && !g1ha_cjalr &&
        serving_unaligned &&
        instruction_valid[0] &&
        (addr[0][2:1] == 2'b11) &&
        (npc_q[2:1] == 2'b01) &&
        (npc_q == g1hj_pc_q)) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = npc_q;
      instr[1]             = {16'b0, g1hj_hw_q};
    end
    // G1ka leftover slot1 analog: npc 01
    // last-return +2 with leftover 11
    // slot0. Not G1hm (no leftover
    // inject off-npc). SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        CVA6Cfg.FETCH_USER_WIDTH >= 34 &&
        g1ka_hit && !g1hj_v_q && !g1ha_cjalr &&
        serving_unaligned &&
        instruction_valid[0] &&
        (addr[0][2:1] == 2'b11)) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = npc_q;
      instr[1]             = {16'b0, icache_dreq_i.user[32:17]};
    end
    // G1kc: G1jy slot0 present skips
    // leftover 11. G1ka leftover slot1
    // needs live user[33]; G1hl needs
    // G1hj. Present the IDLE latch as
    // slot1 at npc == latched +2 while
    // leftover occupies slot0. Not
    // G1hm leftover inject off-npc.
    // Not G1jw G1hj. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        g1jy_v_q && !g1hj_v_q && !g1ha_cjalr &&
        serving_unaligned &&
        instruction_valid[0] &&
        (addr[0][2:1] == 2'b11) &&
        (npc_q[2:1] == 2'b01) &&
        (npc_q == g1jy_pc_q)) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = npc_q;
      instr[1]             = {16'b0, g1jy_hw_q};
    end
    // G1km: G1kl slot0 present skips
    // leftover 11. Present the LOAD-rd
    // c.jalr as slot1 at npc sibling 01
    // while leftover occupies slot0.
    // G1ky: also from same-cycle I$
    // LOAD cap (g1kn/g1kw). Flop is next
    // cycle; present-path g1kk_cap is
    // not used here (comb loop through
    // instruction_valid). G1lj: same-
    // cycle g1le I$/registered cap
    // (g1le_load/g1li_load). G1lv:
    // leftover slot1 from g1lq flop at
    // npc sibling 01 (g1le_hit analog).
    // Not G1lk G1kl. Not present-path
    // (comb loop). Not G1hm leftover
    // inject off-npc. Not G1jw G1hj.
    // SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        (g1kk_v_q[smt_hart_i] || g1ky_cap || g1le_hit || g1lj_cap ||
         g1lq_hit) &&
        !g1hj_v_q && !g1jy_v_q &&
        !g1ka_hit && !g1ha_cjalr &&
        serving_unaligned &&
        instruction_valid[0] &&
        (addr[0][2:1] == 2'b11) &&
        (npc_q[2:1] == 2'b01) &&
        (g1ky_cap ||
         (g1kk_v_q[smt_hart_i] &&
          (npc_q[CVA6Cfg.VLEN-1:4] == g1kk_line_q[smt_hart_i]) &&
          (npc_q[3] != g1kk_a3_q[smt_hart_i])) ||
         g1lj_cap ||
         g1le_hit ||
         g1lq_hit)) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = npc_q;
      instr[1]             = {16'b0,
          g6lc_sib_cjalr::make_cjalr16(
              g1ky_cap ? g1ky_rd :
              (g1kk_v_q[smt_hart_i] &&
               (npc_q[CVA6Cfg.VLEN-1:4] == g1kk_line_q[smt_hart_i]) &&
               (npc_q[3] != g1kk_a3_q[smt_hart_i])) ? g1kk_rd_q[smt_hart_i] :
              (g1lj_cap ? g1lj_rd :
               (g1le_hit ? g1le_rd_q[smt_hart_i] :
                g1lq_rd_q[smt_hart_i])))};
    end
    // G1hm: leftover-complete slot1 from
    // stashed +2 c.jalr without npc 01.
    // Only when leftover slot0 is Jump
    // (766 / 7ba). Leftover auipc keeps
    // realign addi (p2_ok). Not G1es.
    // Not G1gz. SMT+SS.
    if (g6lc_present::hm_cjalr(
            CVA6Cfg, g1hj_v_q, g1ha_cjalr, serving_unaligned,
            instruction_valid[0], addr[0][2:1] == 2'b11,
            (instr[0][6:0] == riscv::OpcodeJal) ||
                g6lc_rvc_enc::is_jalr(instr[0]))) begin
      instruction_valid[1] = 1'b1;
      addr[1]              = g1hj_pc_q;
      instr[1]             = {16'b0, g1hj_hw_q};
    end
    // G1hz: slot0-only aligned compressed
    // Branch keeps +2 exact c.jalr in
    // instruction[31:16] so ID G1hy can
    // latch it. Prefer realign high half,
    // else I$ [31:16]. Not G1fq slot1.
    // Not G1gz slot0 rewrite. SMT+SS.
    // G1kb: G1hz also when slot0 is any
    // compressed (7b8 is not Branch at
    // ID — G1ik). Not G1fx npc +2. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        instruction_valid[0] && !instruction_valid[1] &&
        (addr[0][2:1] == 2'b00) &&
        (instr[0][1:0] == 2'b01)) begin
      if ((instr_ra[0][31:28] == 4'b1001) &&
          (instr_ra[0][22:18] == 5'd0) &&
          (instr_ra[0][27:23] != 5'd0) &&
          (instr_ra[0][17:16] == 2'b10))
        instr[0][31:16] = instr_ra[0][31:16];
      else if ((g1bv_use_stash || icache_valid_q) &&
          (g1et_data[17:16] == 2'b10) &&
          (g1et_data[31:28] == 4'b1001) &&
          (g1et_data[22:18] == 5'd0) &&
          (g1et_data[27:23] != 5'd0))
        instr[0][31:16] = g1et_data[31:16];
    end
    // G1ib: slot0-only must not hide a live +2
    // exact c.jalr. G1hz only keeps the high
    // half on slot0 (ID latch). G1fr needs
    // slot1 already valid. G1fq/G1hc need I$
    // +2 on a specific leftover/aligned beat.
    // Aligned 00: un-hide as slot1. Mid-line
    // 01: unshifted [31:16] is this PC.
    // Not G1gz all mid-line slot0. Not G1he.
    // SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64 &&
        instruction_valid[0] && !instruction_valid[1]) begin
      if ((addr[0][2:1] == 2'b00) &&
          (instr[0][1:0] != 2'b11) &&
          (instr[0][31:28] == 4'b1001) &&
          (instr[0][22:18] == 5'd0) &&
          (instr[0][27:23] != 5'd0) &&
          (instr[0][17:16] == 2'b10)) begin
        instruction_valid[1] = 1'b1;
        addr[1]              = addr[0] + CVA6Cfg.VLEN'(2);
        instr[1]             = {16'b0, instr[0][31:16]};
      end else if ((addr[0][2:1] == 2'b00) &&
          (instr[0][1:0] != 2'b11) &&
          (g1bv_use_stash || icache_valid_q) &&
          (g1et_data[17:16] == 2'b10) &&
          (g1et_data[31:28] == 4'b1001) &&
          (g1et_data[22:18] == 5'd0) &&
          (g1et_data[27:23] != 5'd0)) begin
        instruction_valid[1] = 1'b1;
        addr[1]              = addr[0] + CVA6Cfg.VLEN'(2);
        instr[1]             = {16'b0, g1et_data[31:16]};
      end else if ((addr[0][2:1] == 2'b01) &&
          (g1bv_use_stash || icache_valid_q) &&
          (g1et_data[17:16] == 2'b10) &&
          (g1et_data[31:28] == 4'b1001) &&
          (g1et_data[22:18] == 5'd0) &&
          (g1et_data[27:23] != 5'd0)) begin
        instr[0] = {16'b0, g1et_data[31:16]};
      end
    end
    // G1ie: ID G1id missed because 7b8 may
    // never enter ID as aligned compressed
    // Branch. Latch that shape at present;
    // a same-line mid-line 01 Branch is
    // that line's +2 c.jalr (constructed
    // from the aligned Branch's C2 rs1').
    // Not G1he all mid-line. Not G1gz.
    // SMT+SS.
    // G1if same-line 01 any-slot c.jalr —
    // HOLD-FAIL no cookie @600000. Do not
    // re-land (yanks live mid-line 01).
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (g6lc_sib_cjalr::mid_br_slot(
                instruction_valid[s], addr[s][2:1] == 2'b01,
                instr[s])) begin
          if (g1kk_v_q[smt_hart_i] &&
              (addr[s][CVA6Cfg.VLEN-1:4] ==
               g1kk_line_q[smt_hart_i]))
            instr[s] = {16'b0,
                g6lc_sib_cjalr::make_cjalr16(g1kk_rd_q[smt_hart_i])};
          else if (g1ie_v_q &&
              (addr[s][CVA6Cfg.VLEN-1:3] == g1ie_line_q))
            instr[s] = {16'b0,
                g6lc_sib_cjalr::make_cjalr16(g1ie_rs1_q)};
          // G1iw: same-cycle sibling-half
          // [15:0] Branch (user[16:0]).
          // Not G1iv stash. Not G1if.
          else if (CVA6Cfg.FETCH_USER_WIDTH >= 17 &&
                   icache_dreq_i.user[16] &&
                   (addr[s][CVA6Cfg.VLEN-1:4] ==
                    icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4]) &&
                   (addr[s][3] != icache_dreq_i.vaddr[3]))
            instr[s] = {16'b0,
                g6lc_sib_cjalr::make_cjalr16(
                    {2'b01, icache_dreq_i.user[9:7]})};
          else begin
            for (int unsigned a = 0; a < CVA6Cfg.INSTR_PER_FETCH; a++) begin
              if (instruction_valid[a] &&
                  (addr[a][2:1] == 2'b00) &&
                  (addr[a][CVA6Cfg.VLEN-1:3] ==
                   addr[s][CVA6Cfg.VLEN-1:3]) &&
                  (instr[a][1:0] == 2'b01) &&
                  ((instr[a][15:13] == 3'b110) ||
                   (instr[a][15:13] == 3'b111)))
                instr[s] = {16'b0,
                    g6lc_sib_cjalr::make_cjalr16(
                        {2'b01, instr[a][9:7]})};
            end
          end
        end
      end
    end
  end
  // G1hj stash: aligned I$ [31:16] exact
  // c.jalr only (750 line-start c.jalr is
  // [15:0], not +2). Clear on flush /
  // mid-line 01 consume. SMT+SS.
  // G1hm: also keep the +2 PC.
  logic        g1hj_v_q;
  logic [15:0] g1hj_hw_q;
  logic [CVA6Cfg.VLEN-1:0] g1hj_pc_q;
  logic        g1jy_v_q;
  logic [15:0] g1jy_hw_q;
  logic [CVA6Cfg.VLEN-1:0] g1jy_pc_q;
  logic        g1jy_cap;
  logic        g1jy_cons;
  logic        g1jz_ret_v_q;
  logic [CVA6Cfg.VLEN-1:0] g1jz_ret_q;
  logic        g1ka_hit;
  logic        g1hj_cap;
  logic        g1hj_cons;
  logic [CVA6Cfg.VLEN-1:0] g1hj_cap_pc;
  // G1hn: capture [31:16] exact c.jalr
  // even when vaddr is not line-aligned
  // (7b8 I$ is often a mid-line request).
  // Still +2 of the registered word, not
  // line-start [15:0] (750). Not G1gz.
  // SMT+SS.
  // G1ho: also [15:0] exact c.jalr when
  // vaddr [2:1]==01 (shifted mid-line).
  // Not 750 line-start (vaddr==00).
  // Prefer [31:16] if both. SMT+SS.
  logic g1hn_hi;
  logic g1ho_lo;
  assign g1hn_hi = g6lc_rvc_enc::is_cjalr16(g1et_data[31:16]);
  assign g1ho_lo =
      (g1ha_v01 == 2'b01) &&
      g6lc_rvc_enc::is_cjalr16(g1et_data[15:0]);
  // G1hp: unshifted I$ never shows c.jalr.
  // Capture either half of the present
  // word (g1gx_data / stash). Skip
  // unshifted aligned [15:0] (750).
  // Not G1gz. SMT+SS.
  logic [CVA6Cfg.FETCH_WIDTH-1:0] g1hp_src;
  logic                            g1hp_hi;
  logic                            g1hp_lo;
  assign g1hp_src = g1bv_use_stash ? g1bv_stash_data_q : g1gx_data;
  assign g1hp_hi = g6lc_rvc_enc::is_cjalr16(g1hp_src[31:16]);
  assign g1hp_lo =
      (g1fu_mid || (g1ha_v01 != 2'b00)) &&
      g6lc_rvc_enc::is_cjalr16(g1hp_src[15:0]);
  // G1hq: registered q never holds the 7b8
  // window (leftover-PC predict kills the
  // fill). Capture exact c.jalr from the
  // incoming I$ +2 halfword (unshifted
  // FETCH_WIDTH return). Not line-start
  // [15:0] (750). Not G1gz. SMT+SS.
  logic g1hq_hi;
  assign g1hq_hi = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_WIDTH >= 64 &&
      icache_dreq_i.valid &&
      g6lc_rvc_enc::is_cjalr16(icache_dreq_i.data[31:16]);
  // G1hr: I$ mutes valid on kill_s2
  // (g6lc_icache READ hit). Data and
  // vaddr stay on the bus. Capture +2
  // exact c.jalr on that cycle. Not
  // G1bb freeze. Not 750. Not G1gz.
  // SMT+SS.
  logic g1hr_hi;
  assign g1hr_hi = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_WIDTH >= 64 &&
      icache_dreq_o.kill_s2 &&
      g6lc_rvc_enc::is_cjalr16(icache_dreq_i.data[31:16]);
  // G1jj sibling-half [31:16] exact
  // c.jalr into G1hj — MINI-FAIL lottery
  // tohost 2 @200615. Do not re-land
  // (any sibling +2; yanks live mid-line
  // jalr). G1jl: pair only ([15:0]
  // Branch + [31:16] c.jalr on
  // user[33:17]). G1jk PC-matches
  // present. Not G1iv. SMT+SS.
  logic g1jl_hi;
  logic g1jl_only;
  // G1jw sibling-pair capture without
  // I$ valid/kill_s2 — HOLD-FAIL no
  // cookie @600000 [1000]=800071d8
  // mcause=4. Do not re-land (IDLE
  // user[33] yanked a later jalr into
  // 71d8). G1jk PC-match not enough.
  // Not G1jj. SMT+SS.
  // G1jx: IDLE user[33] pair only when
  // npc is already the sibling +2 PC
  // (7ba while vaddr still 7b0). Not
  // G1jw any-IDLE. Not G1jj. SMT+SS.
  // g1jx_sib_pc was 1-bit (truncated
  // LSB=0) so npc== never matched.
  // G1kj: full PC into G1jy, not G1hj
  // (G1hm leftover inject — G1jw).
  // Drop the npc term from G1jl_hi.
  logic [CVA6Cfg.VLEN-1:0] g1jx_sib_pc;
  assign g1jx_sib_pc =
      {icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4],
       ~icache_dreq_i.vaddr[3], 3'b010};
  assign g1jl_hi = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_WIDTH >= 64 &&
      CVA6Cfg.FETCH_USER_WIDTH >= 34 &&
      icache_dreq_i.user[33] &&
      g6lc_rvc_enc::is_cjalr16(icache_dreq_i.user[32:17]) &&
      (icache_dreq_i.valid || icache_dreq_o.kill_s2);
  assign g1hj_cap = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_WIDTH >= 64 &&
      (((g1bv_use_stash || icache_valid_q) &&
        (g1hn_hi || g1ho_lo || g1hp_hi || g1hp_lo)) ||
       g1hq_hi || g1hr_hi || g1jl_hi);
  assign g1jl_only = g1jl_hi &&
      !((g1bv_use_stash || icache_valid_q) &&
        (g1hn_hi || g1ho_lo || g1hp_hi || g1hp_lo)) &&
      !g1hq_hi && !g1hr_hi;
  assign g1hj_cap_pc = g1jl_only
      ? {icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4],
         ~icache_dreq_i.vaddr[3], 3'b010}
      : {
          ((g1hq_hi || g1hr_hi) ? icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:3] :
           (g1bv_use_stash ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:3]
                           : icache_vaddr_q[CVA6Cfg.VLEN-1:3])),
          3'b010
        };
  always_comb begin
    g1hj_cons = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        // Consume only the stashed +2 PC (7a2 01 must not drop 7ba).
        if (instruction_valid[s] &&
            instr_queue_consumed[s] &&
            (addr[s] == g1hj_pc_q))
          g1hj_cons = 1'b1;
      end
    end
  end
  // G1ju: G1hj +2 c.jalr stash survives
  // leftover Jump flush_i until that
  // +2 PC is presented (capture then
  // leftover jal flush dropped it
  // before 7ba). Not G1il G1ie latch.
  // Not G1jb replace-until-01. Not G1jr
  // flush kill_s1. SMT+SS.
  // G1jv: same-cycle G1hj capture beats
  // flush_i clear (G1ju first-if dropped
  // capture when leftover Jump was not
  // serving). Not G1jr. SMT+SS.
  // G1hj is_mispredict spare is G1kk
  // G1kq/G1kr analog (leftover Jump +
  // npc 00). Soaked hygiene (cookie
  // t=83968; hangj 766 unchanged —
  // leftover Jump / npc 00 mispredict
  // was not dropping the stash). Not
  // G1iy all-01. ex_valid still
  // clears. SMT+SS.
  // stash_keep16: last-replace must not
  // drop a held sibling-01 of the npc
  // 16-byte line (7b0 captured 7ba,
  // then 7c0). Soaked hygiene (cookie
  // t=83968; hangj 766 unchanged — 7ba
  // was never captured). Not G1jb
  // any-01. idle_sib16 HOLD-FAIL G1jw.
  // stash_keep_pc: keep until npc is the
  // stashed +2 PC (71e4 last-replace).
  // Soaked hygiene (cookie t=83968;
  // hangj 766 unchanged — 7ba never
  // captured). SMT+SS.
  // SMT+SS.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1hj_v_q  <= 1'b0;
      g1hj_hw_q <= 16'b0;
      g1hj_pc_q <= '0;
    end else if ((is_mispredict &&
                  ~(g1hv_spare_flush | g1jq_spare_flush |
                    g1jt_spare_misp)) ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      g1hj_v_q <= 1'b0;
    end else if (g1hj_cap &&
                 !g6lc_sib_cjalr::stash_keep_pc(
                     CVA6Cfg, g1hj_v_q, npc_q != g1hj_pc_q)) begin
      g1hj_v_q  <= 1'b1;
      g1hj_hw_q <= g1hn_hi ? g1et_data[31:16] :
                   g1ho_lo ? g1et_data[15:0] :
                   g1hp_hi ? g1hp_src[31:16] :
                   g1hp_lo ? g1hp_src[15:0] :
                   (g1hq_hi || g1hr_hi) ? icache_dreq_i.data[31:16] :
                   g1jl_hi ? icache_dreq_i.user[32:17] :
                   icache_dreq_i.data[31:16];
      g1hj_pc_q <= g1hj_cap_pc;
    end else if (flush_i && ~(g1hv_spare_flush | g1jq_spare_flush)) begin
      g1hj_v_q <= 1'b0;
    end else if (g1hj_v_q && g1hj_cons) begin
      g1hj_v_q <= 1'b0;
    end
  end
  // G1jy: latch IDLE aligned-00 sibling
  // Branch+c.jalr pair aside. Do not
  // fill G1hj (G1hm leftover inject —
  // G1jw HOLD-FAIL 71d8). Present only
  // at npc 01 == latched +2. Not G1jw.
  // Not G1jj. SMT+SS.
  // G1jz: +2 PC is last I$ return vaddr
  // (7b0 READ), not the current request
  // (already 7c0 in IDLE). Drop current
  // vaddr 00. Not G1jw G1hj. SMT+SS.
  // G1kd: 7b0 may never valid/kill_s2
  // (flush_i kill_s1 at npc 00 must
  // stay — G1jr/G1js). Capture without
  // last-return; +2 PC is current I$
  // sibling +2. user[33] pair means
  // that sibling is the Branch+c.jalr.
  // Not G1jw G1hj. Not G1jx
  // npc-already-+2. SMT+SS.
  // G1ke: same-line IDLE pair (current
  // I$ [15:0] compressed Branch +
  // [31:16] exact c.jalr at vaddr 00).
  // Sibling user[33] never the 7b8
  // pair at OpenSBI 7ba. +2 PC is this
  // 8-byte line +2 (7b8→7ba). Not
  // G1jw G1hj. Not G1jj sibling stash.
  // Not G1hn valid/registered G1hj.
  // SMT+SS.
  logic g1ke_pair;
  assign g1ke_pair = g6lc_sib_cjalr::idle_br_cjalr(
      CVA6Cfg, icache_dreq_i.valid, icache_dreq_o.kill_s2,
      icache_dreq_i.vaddr[2:1] == 2'b00, icache_dreq_i.data[31:0]);
  // G1kn: aligned-00 RVI LOAD from I$
  // data (valid or IDLE) into G1kk.
  // Present instruction_valid missed
  // 7b0 (g1kk_v_q empty at npc 7ba —
  // G1kl/G1km). Not G1ke pair. Not
  // G1jw G1hj. Not G1ki sticky. SMT+SS.
  logic g1kn_load;
  assign g1kn_load = g6lc_sib_cjalr::fe_load00_npc(
      CVA6Cfg,
      g6lc_sib_cjalr::icache_seen(icache_dreq_i.valid,
                                 icache_dreq_o.kill_s2),
      icache_dreq_i.vaddr[2:1] == 2'b00, icache_dreq_i.data[31:0],
      npc_q[CVA6Cfg.VLEN-1:4] ==
          icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4]);
  // G1le: last I$ aligned-00 RVI LOAD
  // without npc-line (not into G1kk —
  // G1lb cookie t=206848). SMT+SS.
  assign g1le_load = g6lc_sib_cjalr::fe_load00(
      CVA6Cfg,
      g6lc_sib_cjalr::icache_seen(icache_dreq_i.valid,
                                 icache_dreq_o.kill_s2),
      icache_dreq_i.vaddr[2:1] == 2'b00, icache_dreq_i.data[31:0]);
  assign g1le_hit = g6lc_sib_cjalr::sib01_hit(
      CVA6Cfg, g1le_v_q[smt_hart_i], npc_q[2:1] == 2'b01,
      npc_q[CVA6Cfg.VLEN-1:4] == g1le_line_q[smt_hart_i],
      npc_q[3] != g1le_a3_q[smt_hart_i]);
  // G1lv: leftover slot1 g1lq present
  // at npc sibling 01 (g1le_hit analog).
  // Same-cycle I$/registered leftover
  // slot1 is G1lj. Not G1lk G1kl from
  // no-npc-line. Not present-path
  // (comb loop). Not G1lm. SMT+SS.
  assign g1lq_hit = g6lc_sib_cjalr::sib01_hit(
      CVA6Cfg, g1lq_v_q[smt_hart_i], npc_q[2:1] == 2'b01,
      npc_q[CVA6Cfg.VLEN-1:4] == g1lq_line_q[smt_hart_i],
      npc_q[3] != g1lq_a3_q[smt_hart_i]);
  // G1lh: present-path aligned-00 RVI
  // LOAD into g1le (G1kv analog; no
  // npc-line — g1le is the off-npc
  // side-stash). Flop only (not leftover
  // present — comb loop). I$ overwrite
  // after present (G1kk analog). Not
  // G1ki sticky. Not G1lb into G1kk.
  // SMT+SS.
  always_comb begin
    g1lh_load      = 1'b0;
    g1le_cap       = 1'b0;
    g1le_cap_rd    = 5'd0;
    g1le_cap_line  = '0;
    g1le_cap_a3    = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (g6lc_sib_cjalr::present_load00(
                instruction_valid[s], addr[s][2:1] == 2'b00,
                instr[s])) begin
          g1lh_load     = 1'b1;
          g1le_cap_rd   = instr[s][11:7];
          g1le_cap_line = addr[s][CVA6Cfg.VLEN-1:4];
          g1le_cap_a3   = addr[s][3];
        end
      end
      if (g1le_load) begin
        g1le_cap_rd   = icache_dreq_i.data[11:7];
        g1le_cap_line = icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4];
        g1le_cap_a3   = icache_dreq_i.vaddr[3];
      end
      // G1li: registered I$ LOAD
      // overwrites when live dreq
      // missed (G1kw analog; no npc-
      // line). Not G1ki sticky. SMT+SS.
      if (g1li_load) begin
        g1le_cap_rd   = g1et_data[11:7];
        g1le_cap_line = g1kf_vaddr[CVA6Cfg.VLEN-1:4];
        g1le_cap_a3   = g1kf_vaddr[3];
      end
      g1le_cap = g1lh_load || g1le_load || g1li_load;
    end
  end
  // G1kp: G1kk capture beats flush_i
  // (G1jv analog). G1ko leftover Jump
  // spare did not fire — leftover not
  // serving between 7b0 and npc 7ba.
  // is_mispredict still first. Not
  // G1jr/G1js. SMT+SS.
  logic        g1kk_cap;
  logic [4:0]  g1kk_cap_rd;
  logic [CVA6Cfg.VLEN-1:4] g1kk_cap_line;
  logic        g1kk_cap_a3;
  always_comb begin
    g1kk_cap      = 1'b0;
    g1kk_cap_rd   = 5'd0;
    g1kk_cap_line = '0;
    g1kk_cap_a3   = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        // G1kv: present-path LOAD only
        // when npc is on the same 16-byte
        // line (G1ku analog). G1ku I$
        // npc-line did not fire —
        // present still captured any
        // aligned-00 LOAD. Not G1ki.
        // SMT+SS.
        if (g6lc_sib_cjalr::present_load00(
                instruction_valid[s], addr[s][2:1] == 2'b00,
                instr[s]) &&
            (addr[s][CVA6Cfg.VLEN-1:4] ==
             npc_q[CVA6Cfg.VLEN-1:4])) begin
          g1kk_cap      = 1'b1;
          g1kk_cap_rd   = instr[s][11:7];
          g1kk_cap_line = addr[s][CVA6Cfg.VLEN-1:4];
          g1kk_cap_a3   = addr[s][3];
        end
      end
      if (g1kn_load) begin
        g1kk_cap      = 1'b1;
        g1kk_cap_rd   = icache_dreq_i.data[11:7];
        g1kk_cap_line = icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4];
        g1kk_cap_a3   = icache_dreq_i.vaddr[3];
      end
      // G1kw: registered I$ LOAD (below)
      // overwrites when live dreq missed.
      if (g1kw_load) begin
        g1kk_cap      = 1'b1;
        g1kk_cap_rd   = g1et_data[11:7];
        g1kk_cap_line = g1kf_vaddr[CVA6Cfg.VLEN-1:4];
        g1kk_cap_a3   = g1kf_vaddr[3];
      end
    end
  end
  // G1kf: same-line pair from the last
  // registered I$ word (g1et_data /
  // icache_vaddr_q), not live dreq
  // (already 7c0 in IDLE — G1ke). Do
  // not require icache_valid_q: data_q
  // holds after valid drops until the
  // next fill. Not G1jw G1hj. Not G1hn
  // valid-beat G1hj. SMT+SS.
  logic [CVA6Cfg.VLEN-1:0] g1kf_vaddr;
  logic                    g1kf_pair;
  assign g1kf_vaddr = g1bv_use_stash ? g1bv_stash_addr_q
                                     : icache_vaddr_q;
  // G1kw: aligned-00 RVI LOAD from
  // registered I$ (g1et_data /
  // g1kf_vaddr) into G1kk. Live dreq
  // at npc 7ba is 7c0 (G1ku). Present
  // is leftover (G1kv). Registered may
  // still be 7b0 on the same 16-byte
  // line (the cycle live 7c0 is valid,
  // data_q still holds 7b0; after valid
  // drops, data_q holds until the next
  // fill — G1kf analog). Do not require
  // valid_q / IDLE. Not G1ki sticky.
  // SMT+SS.
  logic g1kw_load;
  assign g1kw_load = g6lc_sib_cjalr::fe_load00_npc(
      CVA6Cfg, 1'b1, g1kf_vaddr[2:1] == 2'b00, g1et_data[31:0],
      npc_q[CVA6Cfg.VLEN-1:4] == g1kf_vaddr[CVA6Cfg.VLEN-1:4]);
  // G1li: aligned-00 RVI LOAD from
  // registered I$ into g1le (G1kw
  // analog; no npc-line — g1le is the
  // off-npc side-stash). Live dreq at
  // npc 7ba is 7c0. Present is leftover
  // (G1lh). Registered may still be
  // 7b0 (G1kf analog). Do not require
  // valid_q / IDLE. Not G1ki sticky.
  // Not G1lb into G1kk. SMT+SS.
  assign g1li_load = g6lc_sib_cjalr::fe_load00(
      CVA6Cfg, 1'b1, g1kf_vaddr[2:1] == 2'b00, g1et_data[31:0]);
  // G1ky: leftover slot1 G1kk present
  // from same-cycle I$ LOAD cap at npc
  // sibling 01 (g1kn live / g1kw
  // registered). Not present-path
  // g1kk_cap (comb loop). Not G1hm.
  // Not G1ki sticky. SMT+SS.
  logic        g1ky_cap;
  logic [4:0]  g1ky_rd;
  assign g1ky_cap =
      g6lc_sib_cjalr::sib01_cap(
          CVA6Cfg, npc_q[2:1] == 2'b01, g1kn_load,
          npc_q[3] != icache_dreq_i.vaddr[3]) ||
      g6lc_sib_cjalr::sib01_cap(
          CVA6Cfg, npc_q[2:1] == 2'b01, g1kw_load,
          npc_q[3] != g1kf_vaddr[3]);
  assign g1ky_rd = (g1kw_load &&
                    (npc_q[3] != g1kf_vaddr[3]))
      ? g1et_data[11:7]
      : icache_dreq_i.data[11:7];
  // G1lj: leftover slot1 g1le present
  // from same-cycle I$/registered LOAD
  // cap at npc sibling 01 (g1le_load /
  // g1li_load). Not present-path g1lh
  // (comb loop). Not G1hm. Not G1ki
  // sticky. Not G1lb into G1kk. SMT+SS.
  logic        g1lj_cap;
  logic [4:0]  g1lj_rd;
  assign g1lj_cap =
      g6lc_sib_cjalr::sib01_cap(
          CVA6Cfg, npc_q[2:1] == 2'b01, g1le_load,
          npc_q[3] != icache_dreq_i.vaddr[3]) ||
      g6lc_sib_cjalr::sib01_cap(
          CVA6Cfg, npc_q[2:1] == 2'b01, g1li_load,
          npc_q[3] != g1kf_vaddr[3]);
  assign g1lj_rd = (g1li_load &&
                    (npc_q[3] != g1kf_vaddr[3]))
      ? g1et_data[11:7]
      : icache_dreq_i.data[11:7];
  // G1ll: G1kl slot0 from same-cycle
  // g1le I$/registered LOAD cap with
  // npc-line (G1kz analog). G1lk no-
  // npc-line g1lj_cap delayed cookie
  // t=206848. Not leftover slot1
  // (G1lj kept). Not present-path
  // g1lh. Not G1ki sticky. Not G1lb
  // into G1kk. SMT+SS.
  logic        g1ll_cap;
  logic [4:0]  g1ll_rd;
  assign g1ll_cap = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_WIDTH >= 64 &&
      (npc_q[2:1] == 2'b01) &&
      ((g1le_load &&
        (npc_q[CVA6Cfg.VLEN-1:4] ==
         icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4]) &&
        (npc_q[3] != icache_dreq_i.vaddr[3])) ||
       (g1li_load &&
        (npc_q[CVA6Cfg.VLEN-1:4] ==
         g1kf_vaddr[CVA6Cfg.VLEN-1:4]) &&
        (npc_q[3] != g1kf_vaddr[3])));
  assign g1ll_rd = (g1li_load &&
                    (npc_q[CVA6Cfg.VLEN-1:4] ==
                     g1kf_vaddr[CVA6Cfg.VLEN-1:4]) &&
                    (npc_q[3] != g1kf_vaddr[3]))
      ? g1et_data[11:7]
      : icache_dreq_i.data[11:7];
  assign g1kf_pair = g6lc_sib_cjalr::idle_br_cjalr(
      CVA6Cfg, icache_dreq_i.valid, icache_dreq_o.kill_s2,
      g1kf_vaddr[2:1] == 2'b00, g1et_data[31:0]);
  // G1kg: same-line pair on kill_s2
  // (incoming data still on the bus,
  // valid muted). G1ke/G1kf IDLE-only;
  // 7b8 fill may die as kill_s2. Into
  // G1jy, not G1hj (G1hr [31:16]
  // c.jalr on kill_s2; G1jw leftover
  // inject). Not G1jp all npc-00
  // kill_s2 spare. SMT+SS.
  logic g1kg_pair;
  assign g1kg_pair = g6lc_sib_cjalr::kill_br_cjalr(
      CVA6Cfg, icache_dreq_o.kill_s2,
      icache_dreq_i.vaddr[2:1] == 2'b00, icache_dreq_i.data[31:0]);
  // G1kh: kill_s2 sibling user[33] pair
  // into G1jy (not G1hj/G1jl). G1kg is
  // same-line data; sibling of 7b0 is
  // the 7b8 Branch+c.jalr. Not G1jp
  // kill_s2 spare. Not G1jw G1hj.
  // SMT+SS.
  logic g1kh_sib;
  assign g1kh_sib = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_USER_WIDTH >= 34 &&
      icache_dreq_o.kill_s2 &&
      icache_dreq_i.user[33] &&
      g6lc_rvc_enc::is_cjalr16(icache_dreq_i.user[32:17]);
  // G1kj: npc already the sibling +2
  // of the live user[33] pair (full
  // g1jx_sib_pc). Into G1jy, not G1hj.
  // Not G1ki sticky. Not G1jw. SMT+SS.
  logic g1kj_npc;
  assign g1kj_npc = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_USER_WIDTH >= 34 &&
      icache_dreq_i.user[33] &&
      g6lc_rvc_enc::is_cjalr16(icache_dreq_i.user[32:17]) &&
      (npc_q[2:1] == 2'b01) &&
      (npc_q == g1jx_sib_pc);
  assign g1jy_cap = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_WIDTH >= 64 &&
      (g1ke_pair || g1kf_pair || g1kg_pair ||
       g1kh_sib || g1kj_npc ||
       (!icache_dreq_i.valid &&
        !icache_dreq_o.kill_s2 &&
        CVA6Cfg.FETCH_USER_WIDTH >= 34 &&
        icache_dreq_i.user[33] &&
        g6lc_rvc_enc::is_cjalr16(icache_dreq_i.user[32:17])));
  assign g1jy_cons = g1jy_v_q &&
      (npc_q[2:1] == 2'b01) &&
      (npc_q == g1jy_pc_q);
  // G1ka: live user[33] pair at npc 01
  // matching last I$ return sibling +2.
  assign g1ka_hit = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_USER_WIDTH >= 34 &&
      g1jz_ret_v_q &&
      icache_dreq_i.user[33] &&
      (icache_dreq_i.user[32:29] == 4'b1001) &&
      (icache_dreq_i.user[23:19] == 5'd0) &&
      (icache_dreq_i.user[28:24] != 5'd0) &&
      (icache_dreq_i.user[18:17] == 2'b10) &&
      (npc_q[2:1] == 2'b01) &&
      (npc_q == {g1jz_ret_q[CVA6Cfg.VLEN-1:4],
                 ~g1jz_ret_q[3], 3'b010});
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1jy_v_q    <= 1'b0;
      g1jy_hw_q   <= 16'b0;
      g1jy_pc_q   <= '0;
      g1jz_ret_v_q <= 1'b0;
      g1jz_ret_q   <= '0;
    end else if ((is_mispredict &&
                  ~(g1hv_spare_flush | g1jq_spare_flush |
                    g1jt_spare_misp)) ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      g1jy_v_q     <= 1'b0;
      g1jz_ret_v_q <= 1'b0;
    end else begin
      if (icache_dreq_i.valid || icache_dreq_o.kill_s2) begin
        g1jz_ret_v_q <= 1'b1;
        g1jz_ret_q   <= icache_dreq_i.vaddr;
      end
      if (g1jy_cap &&
          !g6lc_sib_cjalr::stash_keep_pc(
              CVA6Cfg, g1jy_v_q, npc_q != g1jy_pc_q)) begin
        g1jy_v_q  <= 1'b1;
        if (g1ke_pair || g1kg_pair) begin
          g1jy_hw_q <= icache_dreq_i.data[31:16];
          g1jy_pc_q <= {icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:3],
                        3'b010};
        end else if (g1kf_pair) begin
          g1jy_hw_q <= g1et_data[31:16];
          g1jy_pc_q <= {g1kf_vaddr[CVA6Cfg.VLEN-1:3],
                        3'b010};
        end else begin
          g1jy_hw_q <= icache_dreq_i.user[32:17];
          g1jy_pc_q <= {icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4],
                        ~icache_dreq_i.vaddr[3], 3'b010};
        end
      end else if (flush_i && ~(g1hv_spare_flush | g1jq_spare_flush)) begin
        g1jy_v_q <= 1'b0;
      end else if (g1jy_cons) begin
        g1jy_v_q <= 1'b0;
      end
    end
  end
  // G1iq: stash aligned I$[15:0]
  // compressed Branch. Capture registered
  // or incoming I$ when vaddr is line-
  // aligned. Clear on flush / aligned-00
  // consume. SMT+SS.
  // G1is any-vaddr [15:0] Branch —
  // HOLD-FAIL no cookie @250000. Do
  // not re-land (yanks wrong-line
  // aligned Branch).
  // G1it: also capture when vaddr is
  // mid-line 01 (same 8-byte line;
  // G1ho analog). Not leftover 11.
  // G1iu: also when npc is mid-line 01
  // on the same I$ line (any vaddr
  // offset). Not G1is any-vaddr.
  logic        g1iq_v_q;
  logic [15:0] g1iq_hw_q;
  logic [CVA6Cfg.VLEN-1:0] g1iq_pc_q;
  logic        g1iq_cap;
  logic        g1iq_cons;
  logic        g1iq_br_reg;
  logic        g1iq_br_in;
  assign g1iq_br_reg = g6lc_fe_keep::is_cbranch16(g1et_data[15:0]);
  assign g1iq_br_in =
      g6lc_fe_keep::is_cbranch16(icache_dreq_i.data[15:0]);
  logic g1iu_npc01;
  logic g1iu_reg_same;
  logic g1iu_in_same;
  assign g1iu_npc01 = (npc_q[2:1] == 2'b01);
  assign g1iu_reg_same = g1iu_npc01 &&
      (npc_q[CVA6Cfg.VLEN-1:3] ==
       (g1bv_use_stash
            ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:3]
            : icache_vaddr_q[CVA6Cfg.VLEN-1:3]));
  assign g1iu_in_same = g1iu_npc01 &&
      (npc_q[CVA6Cfg.VLEN-1:3] ==
       icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:3]);
  // G1iv sibling-line [15:0] Branch —
  // MINI-FAIL FDT tohost 91 @948. Do
  // not re-land.
  assign g1ji_sib_line =
      {icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4],
       ~icache_dreq_i.vaddr[3]};
  assign g1iq_cap = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.FETCH_WIDTH >= 64 &&
      ((((g1bv_use_stash || icache_valid_q) &&
         (((g1ha_v01 == 2'b00) || (g1ha_v01 == 2'b01)) ||
          g1iu_reg_same) &&
         g1iq_br_reg) ||
        (icache_dreq_i.valid &&
         (((icache_dreq_i.vaddr[2:1] == 2'b00) ||
           (icache_dreq_i.vaddr[2:1] == 2'b01)) ||
          g1iu_in_same) &&
         g1iq_br_in) ||
        (icache_dreq_o.kill_s2 &&
         (((icache_dreq_i.vaddr[2:1] == 2'b00) ||
           (icache_dreq_i.vaddr[2:1] == 2'b01)) ||
          g1iu_in_same) &&
         g1iq_br_in)));
  logic [CVA6Cfg.VLEN-1:3] g1iq_cap_line;
  assign g1iq_cap_line =
      ((icache_dreq_i.valid || icache_dreq_o.kill_s2) &&
       (((icache_dreq_i.vaddr[2:1] == 2'b00) ||
         (icache_dreq_i.vaddr[2:1] == 2'b01)) ||
        g1iu_in_same) &&
       g1iq_br_in)
          ? icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:3]
          : (g1bv_use_stash
                 ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:3]
                 : icache_vaddr_q[CVA6Cfg.VLEN-1:3]);
  always_comb begin
    g1iq_cons = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (instruction_valid[s] &&
            instr_queue_consumed[s] &&
            (addr[s][2:1] == 2'b00) &&
            (addr[s][CVA6Cfg.VLEN-1:3] == g1iq_pc_q[CVA6Cfg.VLEN-1:3]))
          g1iq_cons = 1'b1;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1iq_v_q  <= 1'b0;
      g1iq_hw_q <= 16'b0;
      g1iq_pc_q <= '0;
    end else if (flush_i || is_mispredict ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      g1iq_v_q <= 1'b0;
    end else if (g1iq_cap &&
                 !(g1iq_v_q && !g1jb_01_seen_q &&
                   (g1iq_cap_line !=
                    g1iq_pc_q[CVA6Cfg.VLEN-1:3]))) begin
      g1iq_v_q  <= 1'b1;
      g1iq_hw_q <= ((icache_dreq_i.valid || icache_dreq_o.kill_s2) &&
                    (((icache_dreq_i.vaddr[2:1] == 2'b00) ||
                      (icache_dreq_i.vaddr[2:1] == 2'b01)) ||
                     g1iu_in_same) &&
                    g1iq_br_in)
                       ? icache_dreq_i.data[15:0]
                       : g1et_data[15:0];
      g1iq_pc_q <= {g1iq_cap_line, 3'b000};
    end else if (g1iq_v_q && g1iq_cons) begin
      g1iq_v_q <= 1'b0;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1ie_v_q    <= 1'b0;
      g1ie_rs1_q  <= 5'd0;
      g1ie_line_q <= '0;
    end else if (flush_i || is_mispredict ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      g1ie_v_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      // G1ir: arm from G1iq stash (aligned
      // I$[15:0] compressed Branch + C2
      // rs1') so recover does not need a
      // visible aligned present. Live
      // present overwrites. Not G1if
      // any-slot. SMT+SS.
      if (g1iq_v_q &&
          (g1iq_hw_q[1:0] == 2'b01) &&
          ((g1iq_hw_q[15:13] == 3'b110) ||
           (g1iq_hw_q[15:13] == 3'b111))) begin
        g1ie_v_q    <= 1'b1;
        g1ie_rs1_q  <= {2'b01, g1iq_hw_q[9:7]};
        g1ie_line_q <= g1iq_pc_q[CVA6Cfg.VLEN-1:3];
      end
      // G1ji: arm from G1iw sibling-half
      // compressed Branch (user[16:0]).
      // Same-cycle G1iw misses leftover
      // I$ at npc 01; the latch keeps the
      // sibling until 01 (G1jb). Not
      // G1iv data stash. Not G1jh 01
      // steal. Not G1is any-vaddr.
      // SMT+SS.
      if (CVA6Cfg.FETCH_USER_WIDTH >= 17 &&
          (icache_dreq_i.valid || icache_dreq_o.kill_s2) &&
          icache_dreq_i.user[16] &&
          (icache_dreq_i.user[1:0] == 2'b01) &&
          ((icache_dreq_i.user[15:13] == 3'b110) ||
           (icache_dreq_i.user[15:13] == 3'b111)) &&
          !(g1ie_v_q && !g1jb_01_seen_q &&
            (g1ji_sib_line != g1ie_line_q))) begin
        g1ie_v_q    <= 1'b1;
        g1ie_rs1_q  <= {2'b01, icache_dreq_i.user[9:7]};
        g1ie_line_q <= g1ji_sib_line;
      end
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (instruction_valid[s] &&
            (addr[s][2:1] == 2'b00) &&
            (instr[s][1:0] == 2'b01) &&
            ((instr[s][15:13] == 3'b110) ||
             (instr[s][15:13] == 3'b111)) &&
            !(g1ie_v_q && !g1jb_01_seen_q &&
              (addr[s][CVA6Cfg.VLEN-1:3] != g1ie_line_q))) begin
          g1ie_v_q    <= 1'b1;
          g1ie_rs1_q  <= {2'b01, instr[s][9:7]};
          g1ie_line_q <= addr[s][CVA6Cfg.VLEN-1:3];
        end
      end
    end
  end
  // G1ko: G1kk survives leftover Jump
  // flush_i (G1ju analog). G1kn I$
  // capture fired (+3 cy) but leftover
  // jal flush still dropped the latch
  // before npc 7ba. is_mispredict
  // still clears. Not G1jr/G1js npc-00
  // flush_i !kill_s1. SMT+SS.
  // G1kq: G1kk survives leftover Jump
  // is_mispredict (G1hw analog; g1hv/
  // g1jq). ex_valid still clears. Not
  // G1iy all-01. Not G1jt all npc-00.
  // SMT+SS.
  // G1kr: G1kk survives is_mispredict
  // while npc is aligned 00 (G1jt
  // analog; 7b8 c.beqz between 7b0
  // and npc 7ba). ex_valid still
  // clears. Not G1iy all-01. SMT+SS.
  // load_flush_keep: flush_i while npc
  // is on the captured 16B line (G1ko
  // missed leftover jal flush after
  // leftover stopped serving). Soaked
  // hygiene (cookie t=83968; hangj 766
  // unchanged — G1kk empty at npc 7ba
  // or npc left the 16B line).
  // load_flush_next16: flush while npc
  // is the next 16B line (7c0). Not
  // G1kt keep-until-01. Not G1jr.
  // SMT+SS.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1kk_v_q    <= '0;
      g1kk_rd_q   <= '0;
      g1kk_line_q <= '0;
      g1kk_a3_q   <= '0;
    end else if ((is_mispredict &&
                  ~(g1hv_spare_flush | g1jq_spare_flush |
                    g1jt_spare_misp)) ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      // G1mc: drop only the active hart.
      g1kk_v_q[smt_hart_i] <= 1'b0;
    end else if (g1kk_cap &&
                 !(g1kk_v_q[smt_hart_i] &&
                   (g1kk_cap_line !=
                    g1kk_line_q[smt_hart_i]) &&
                   (g1kk_cap_line !=
                    npc_q[CVA6Cfg.VLEN-1:4]))) begin
      // G1kt: keep until sibling 01
      // (G1jb analog). G1ks fired (−16
      // cy) but a later 16-byte LOAD
      // replaced 7b0 before npc 7ba.
      // Same-line recapture allowed.
      // G1kx: npc-line LOAD recapture
      // may replace a held different-
      // line LOAD (first LOAD blocked
      // 7b0).
      // G1lc: g1kn no longer bypasses
      // keep-until-01 (G1lb cookie
      // t=206848). Empty latch still
      // arms from off-npc I$ (G1lb
      // G1ku undo). G1mc: capture the
      // active hart only. Not G1ki
      // sticky. SMT+SS.
      g1kk_v_q[smt_hart_i]    <= 1'b1;
      g1kk_rd_q[smt_hart_i]   <= g1kk_cap_rd;
      g1kk_line_q[smt_hart_i] <= g1kk_cap_line;
      g1kk_a3_q[smt_hart_i]   <= g1kk_cap_a3;
    end else if (flush_i &&
                 ~(g1hv_spare_flush | g1jq_spare_flush |
                   g6lc_sib_cjalr::load_flush_keep(
                       CVA6Cfg, g1kk_v_q[smt_hart_i],
                       npc_q[CVA6Cfg.VLEN-1:4] ==
                           g1kk_line_q[smt_hart_i]) ||
                   g6lc_sib_cjalr::load_flush_next16(
                       CVA6Cfg, g1kk_v_q[smt_hart_i],
                       npc_q[CVA6Cfg.VLEN-1:4] ==
                           (g1kk_line_q[smt_hart_i] + 1'b1)))) begin
      g1kk_v_q[smt_hart_i] <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        // G1ks: consume only at sibling
        // 01, not mid-LOAD 01 of the
        // same 16-byte line (7b2 drops
        // the latch before npc 7ba).
        // G1mc: consume the active hart.
        // Not G1if any-slot. SMT+SS.
        if (g1kk_v_q[smt_hart_i] &&
            instruction_valid[s] &&
            instr_queue_consumed[s] &&
            (addr[s][2:1] == 2'b01) &&
            (addr[s][CVA6Cfg.VLEN-1:4] ==
             g1kk_line_q[smt_hart_i]) &&
            (addr[s][3] != g1kk_a3_q[smt_hart_i]))
          g1kk_v_q[smt_hart_i] <= 1'b0;
      end
    end
  end
  // G1le: last I$ LOAD side-stash.
  // G1lf: keep until sibling 01 (G1kt
  // analog). Same-line recapture
  // allowed; later different-line I$
  // LOAD does not replace. Consume
  // only at sibling 01. Same spare as
  // G1kk. G1lg: npc-line LOAD
  // recapture may replace a held
  // different-line g1le (G1kx analog;
  // first I$ LOAD blocked 7b0). G1lh:
  // present-path aligned-00 RVI LOAD
  // into g1le (G1kv analog; no npc-
  // line). G1li: registered I$ LOAD
  // into g1le (G1kw analog; no npc-
  // line). Capture mux g1le_cap.
  // Not G1ki sticky. Not G1lb into
  // G1kk. SMT+SS.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1le_v_q    <= '0;
      g1le_rd_q   <= '0;
      g1le_line_q <= '0;
      g1le_a3_q   <= '0;
    end else if ((is_mispredict &&
                  ~(g1hv_spare_flush | g1jq_spare_flush |
                    g1jt_spare_misp)) ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      // G1mb: drop only the active hart.
      g1le_v_q[smt_hart_i] <= 1'b0;
    end else if (g1le_cap &&
                 !(g1le_v_q[smt_hart_i] &&
                   (g1le_cap_line !=
                    g1le_line_q[smt_hart_i]) &&
                   (g1le_cap_line !=
                    npc_q[CVA6Cfg.VLEN-1:4]))) begin
      g1le_v_q[smt_hart_i]    <= 1'b1;
      g1le_rd_q[smt_hart_i]   <= g1le_cap_rd;
      g1le_line_q[smt_hart_i] <= g1le_cap_line;
      g1le_a3_q[smt_hart_i]   <= g1le_cap_a3;
    end else if (flush_i &&
                 ~(g1hv_spare_flush | g1jq_spare_flush)) begin
      g1le_v_q[smt_hart_i] <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (g1le_v_q[smt_hart_i] &&
            instruction_valid[s] &&
            instr_queue_consumed[s] &&
            (addr[s][2:1] == 2'b01) &&
            (addr[s][CVA6Cfg.VLEN-1:4] ==
             g1le_line_q[smt_hart_i]) &&
            (addr[s][3] != g1le_a3_q[smt_hart_i]))
          g1le_v_q[smt_hart_i] <= 1'b0;
      end
    end
  end
  // G1lq: last IQ-visible aligned-00 RVI
  // LOAD (g1ct_valid). 7b0 may be valid
  // at IQ input but not pushed (G1ii
  // analog). G1lr: keep until sibling
  // 01 (G1lf analog). Not G1lm rewrite.
  // Not G1ki sticky. SMT+SS.
  always_comb begin
    g1lq_cap      = 1'b0;
    g1lq_cap_rd   = 5'd0;
    g1lq_cap_line = '0;
    g1lq_cap_a3   = 1'b0;
    g1ls_load     = 1'b0;
    g1lq_ct_load  = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.FETCH_WIDTH >= 64) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        // G1ls: present-path aligned-00
        // RVI LOAD (G1lh analog). 7b0
        // may be instruction_valid but
        // G1ct-muted. Not leftover
        // present. SMT+SS.
        if (g6lc_sib_cjalr::present_load00(
                instruction_valid[s], addr[s][2:1] == 2'b00,
                instr[s])) begin
          g1ls_load     = 1'b1;
          g1lq_cap_rd   = instr[s][11:7];
          g1lq_cap_line = addr[s][CVA6Cfg.VLEN-1:4];
          g1lq_cap_a3   = addr[s][3];
        end
      end
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (g6lc_sib_cjalr::present_load00(
                g1ct_valid[s], addr[s][2:1] == 2'b00, instr[s])) begin
          g1lq_ct_load  = 1'b1;
          g1lq_cap_rd   = instr[s][11:7];
          g1lq_cap_line = addr[s][CVA6Cfg.VLEN-1:4];
          g1lq_cap_a3   = addr[s][3];
        end
      end
      // G1lt: live I$ aligned-00 RVI LOAD
      // into g1lq_cap (G1le analog;
      // overwrite after present). Keep-
      // until-01 still filters (not G1lb
      // into G1kk). Not G1lm. SMT+SS.
      if (g1le_load) begin
        g1lq_cap_rd   = icache_dreq_i.data[11:7];
        g1lq_cap_line = icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4];
        g1lq_cap_a3   = icache_dreq_i.vaddr[3];
      end
      // G1lu: registered I$ aligned-00
      // RVI LOAD into g1lq_cap (G1li
      // analog; overwrite when live
      // dreq missed). Keep-until-01
      // still filters (not G1lb into
      // G1kk). Not G1lm. SMT+SS.
      if (g1li_load) begin
        g1lq_cap_rd   = g1et_data[11:7];
        g1lq_cap_line = g1kf_vaddr[CVA6Cfg.VLEN-1:4];
        g1lq_cap_a3   = g1kf_vaddr[3];
      end
      g1lq_cap = g1ls_load || g1lq_ct_load ||
                 g1le_load || g1li_load;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1lq_v_q    <= '0;
      g1lq_rd_q   <= '0;
      g1lq_line_q <= '0;
      g1lq_a3_q   <= '0;
    end else if (flush_i) begin
      if (!(CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1))
        g1lq_v_q <= '0;
    end else if (g1lq_cap &&
                 !(g1lq_v_q[smt_hart_i] &&
                   (g1lq_cap_line !=
                    g1lq_line_q[smt_hart_i]) &&
                   (g1lq_cap_line !=
                    npc_q[CVA6Cfg.VLEN-1:4]))) begin
      // G1lr: keep until sibling 01
      // (G1lf analog). G1ma: capture
      // the active hart only. Same-line
      // recapture allowed; npc-line
      // recapture may replace a held
      // different-line LOAD (G1lg
      // analog). Not G1ki sticky. Not
      // G1lm. Not G1lk. SMT+SS.
      g1lq_v_q[smt_hart_i]    <= 1'b1;
      g1lq_rd_q[smt_hart_i]   <= g1lq_cap_rd;
      g1lq_line_q[smt_hart_i] <= g1lq_cap_line;
      g1lq_a3_q[smt_hart_i]   <= g1lq_cap_a3;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
                 CVA6Cfg.FETCH_WIDTH >= 64) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        // G1ks analog: consume only at
        // sibling 01, not mid-LOAD 01
        // of the same 16-byte line.
        // G1ma: consume the active hart.
        if (g1lq_v_q[smt_hart_i] &&
            instruction_valid[s] &&
            instr_queue_consumed[s] &&
            (addr[s][2:1] == 2'b01) &&
            (addr[s][CVA6Cfg.VLEN-1:4] ==
             g1lq_line_q[smt_hart_i]) &&
            (addr[s][3] != g1lq_a3_q[smt_hart_i]))
          g1lq_v_q[smt_hart_i] <= 1'b0;
      end
    end
  end
  assign g1lq_v_o    = g1lq_v_q;
  assign g1lq_rd_o   = g1lq_rd_q;
  assign g1lq_line_o = g1lq_line_q;
  assign g1lq_a3_o   = g1lq_a3_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1jb_01_seen_q <= 1'b0;
    end else if (flush_i || is_mispredict ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      g1jb_01_seen_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (g1iq_cap &&
          !(g1iq_v_q && !g1jb_01_seen_q &&
            (g1iq_cap_line !=
             g1iq_pc_q[CVA6Cfg.VLEN-1:3])) &&
          (!g1iq_v_q ||
           (g1iq_cap_line !=
            g1iq_pc_q[CVA6Cfg.VLEN-1:3])))
        g1jb_01_seen_q <= 1'b0;
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (instruction_valid[s] &&
            (addr[s][2:1] == 2'b01) &&
            ((g1iq_v_q &&
              (addr[s][CVA6Cfg.VLEN-1:3] ==
               g1iq_pc_q[CVA6Cfg.VLEN-1:3])) ||
             (g1ie_v_q &&
              (addr[s][CVA6Cfg.VLEN-1:3] ==
               g1ie_line_q))))
          g1jb_01_seen_q <= 1'b1;
      end
    end
  end
  // G1ff: registered I$ word is aligned I|I CSR-to-a0
  // (same data as G1et; not realign instr_i). G1fe did
  // not fire. Hide later dest-FIFO a0-Branch while this
  // line is registered. Not G1et fill. SMT+SS.
  logic g1ff_ii_csr;
  logic [CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] g1ff_line;
  assign g1ff_line = g1bv_use_stash
      ? g1bv_stash_addr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]
      : icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS];
  assign g1ff_ii_csr = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 && CVA6Cfg.FETCH_WIDTH >= 64 &&
      (g1bv_use_stash || icache_valid_q) &&
      ((g1bv_use_stash ? g1bv_stash_addr_q[2:1] :
        icache_vaddr_q[2:1]) == 2'b00) &&
      (g1et_data[1:0] == 2'b11) &&
      (g1et_data[33:32] == 2'b11) &&
      (g1et_data[38:32] == 7'b1110011) &&
      (g1et_data[43:39] == 5'd10);
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

  // G1bj: aligned slot0 CF class follows the 16-bit at that PC.
  // Leftover mash {c.li_hi, branch_lo} scans as rvi_branch so IQ
  // taken[0] hides later slots and redirects off c.li. Not G1ba
  // (ID expand). Not G1bf (format). Not G1bi (IQ rotate). SMT+SS.
  logic g1bj_slot0_nocf;
  assign g1bj_slot0_nocf = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      instruction_valid[0] && (addr[0][2:1] == 2'b00) &&
      (((instr[0][1:0] != 2'b11) &&
        !rvc_branch[0] && !rvc_jump[0] && !rvc_jr[0] && !rvc_jalr[0]) ||
       ((instr[0][6:0] == riscv::OpcodeBranch) &&
        (instr[0][17:16] == 2'b01) &&
        (instr[0][31:29] == riscv::OpcodeC1Li)));

  // G1br later-slot !is_branch while prefix unconsumed —
  // HOLD-FAIL: combo loop is_branch → IQ consume → g1br.
  // Do not re-land (consumed in the is_branch cone).
  // G1bs later-slot !is_branch while dest *valid* —
  // HOLD-FAIL no cookie-exit (too wide: any dest then
  // Branch). Do not re-land.
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i])
        & ~(i == 0 && g1bj_slot0_nocf);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i])
        & ~(i == 0 && (g1gi_hide || g6lc_lj_hold))
        & ~(g6lc_lj_pend && g6lc_iq_hide::is_jal_x0(instr[i]));
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
    // G1co leftover-complete next-line RVI Branch as
    // cf=Branch — HOLD-FAIL no cookie-exit (past 10 min).
    // Do not re-land (unresolved_cf on leftover NT beq).
    // G1cw: leftover-complete slot0 JAL is cf=Jump even
    // if mash left NoCF. G1do: any leftover-complete
    // slot (jal@7c6 may not be fetch[0]; G1dn did not
    // fire — jal never entered a dest FIFO). Not G1co
    // leftover NT beq. Not G1cu NPC. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        serving_unaligned) begin
      for (int unsigned gi = 0; gi < CVA6Cfg.INSTR_PER_FETCH; gi++) begin
        if (instruction_valid[gi] && (addr[gi][2:1] == 2'b11) &&
            (instr[gi][6:0] == riscv::OpcodeJal) &&
            (instr[gi][1:0] == 2'b11)) begin
          cf_type[gi]      = ariane_pkg::Jump;
          taken_rvi_cf[gi] = 1'b1;
          predict_address  = addr[gi] + rvi_imm[gi];
        end
      end
    end
  end
  // or reduce struct
  always_comb begin
    logic any_imm_jump;
    bp_valid = 1'b0;
    any_imm_jump = 1'b0;
    // BP cannot be valid if we have a return instruction and the RAS is not giving a valid address
    // Check that we encountered a control flow and that for a return the RAS
    // contains a valid prediction.
    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
      // G1ci: leftover-complete later-slot Jump is not
      // bp_valid while leftover slot0 is unconsumed.
      // c.j@0x4ce on the leftover-complete 0x4c8 line
      // otherwise kill_s2 / drops the 0x4d0 I$ return
      // (c.li never writes t3). G1bz zeroed every leftover
      // later-slot CF — MINI-FAIL P3 0x39 (later-slot Jump
      // is live in load_be32 once slot0 is in the IQ).
      // After consumed[0], later Jump may predict. Not
      // G1by (aligned dest). Not G1cb (keep_line). Not
      // G1br (is_branch/consumed combo). SMT+SS.
      if (!(CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
            serving_unaligned && instruction_valid[0] &&
            !instr_queue_consumed[0] && (i != 0) &&
            (cf_type[i] == ariane_pkg::Jump))) begin
        bp_valid |= ((cf_type[i] != NoCF & cf_type[i] != Return) |
                     ((cf_type[i] == Return) & ras_predict.valid & |ras_predict.ra));
        any_imm_jump |= (cf_type[i] == ariane_pkg::Jump);
      end
    end
    // I4p: never redirect fetch to PC=0 (empty DRAM → illegal). SMT2 I4o
    // saw hart0 mepc=0; BTB/RAS target 0 is never a useful OpenSBI fetch.
    // I4ah: also drop a predicted JALR/RAS/BTB target that is not executable.
    // I4v only filters *resolve* (bmiss / NPC / BTB train). A stale BTB hit
    // on fdt_next_tag `jr a5` still fetched .rodata/FDT @0x8001f801, and
    // after I4ag that target is not a mispredict — so the FDT stream was
    // never flushed and s0 landed as 0x8001f801 at lw@12c0a.
    // I4au: do *not* apply the execute-region filter to immediate Jump
    // (`jal` / `c.j`). I4ah's comment was JALR/RAS/BTB only; dropping a
    // PC-relative jal leaves cf=Jump in the IQ so EX is_mispredict=0
    // (matching tgt) while IF never redirected — I4x then kills
    // fallthrough and npc sits on `jal offset_ptr` @129f0. Page-0
    // (I4p) still drops every CF, including Jump.
    if (CVA6Cfg.NrHarts > 1 && predict_address == '0)
      bp_valid = 1'b0;
    else if (CVA6Cfg.NrHarts > 1 && !any_imm_jump &&
             !config_pkg::is_inside_execute_regions(CVA6Cfg, 64'(predict_address)))
      bp_valid = 1'b0;
    // G1bx: leftover-complete taken Branch whose target is the
    // next 8B line does not raise bp_valid. Sequential already
    // fetches that line; bp_valid would kill_s2 it. kill_s2
    // formula unchanged (G1bq/G1bt/G1bw HOLD-FAIL). cf_type
    // stays Branch for IQ. Not G1ab NPC. Not G1br is_branch.
    // SMT+SS. One-cycle window (serving_unaligned).
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        serving_unaligned && instruction_valid[0] &&
        (cf_type[0] == ariane_pkg::Branch) &&
        (predict_address[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1'b1)))
      bp_valid = 1'b0;
    // G1by later-slot !bp_valid while dest valid — HOLD-FAIL
    // wfi-exit t=217088 plat_hc=80. Do not re-land (too wide).
    // G1bz leftover-complete later-slot !bp_valid — MINI-FAIL
    // P3 0x39 @437 (s0!=a0). Do not re-land (too wide:
    // leftover later-slot Jump is live in P3).
    // G1ci (in-loop): leftover later-slot Jump only, and
    // only while leftover slot0 is unconsumed. Hygiene.
    // G1go leftover-PC !bp_valid after mid-line
    // 01 / jalr seen — HOLD-FAIL no cookie
    // ~2 min (preload only). Do not re-land
    // (leftover-PC predict is load-bearing;
    // G1gn npc-skip / G1bq kill_s2 class).
  end
  // Classic EX mispredict only. Matching taken Jump must NOT reseed NPC or
  // feed TAGE mispredict_i: reseed re-fetches calls → double RAS push
  // (RASDepth=2) → return to PC=0x4; OR-ing into is_mispredict → IAF
  // mepc=0x1400000000. Hang-6 residual fallthrough is handled elsewhere
  // (icache clear on bp_valid, CF issue stall). Post-bp IQ sequential drop
  // was tried (Jump-only) but regressed bare smt_dual_concurrent — do not rearm
  // without a concurrent soak.
  // EXTRACT E2: suppress only JALR mispredicts to unusable targets.
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict
                         & ~(CVA6Cfg.NrHarts > 1
                             & (resolved_branch_i.cf_type == ariane_pkg::JumpR)
                             & ~g6lc_jalr_usable::usable(
                                    CVA6Cfg, CVA6Cfg.VLEN,
                                    64'(resolved_branch_i.target_address)));

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
  // G1cq: leftover-complete NoCF must not replay-kill I$
  // s1/s2. IQ overflow on leftover later slots (li s11)
  // would otherwise cancel the in-flight 0x4d0 fill.
  // Not G1bq leftover !kill_s2 (bp_valid). Not G1cn
  // req suppress. Replay still reseeds NPC. SMT+SS.
  // G1hs: leftover-complete Jump the same.
  // 7b8 fill dies in kill_s1 before READ
  // (G1hr never saw the bits). Not G1bq
  // !kill_s2. Not G1db leftover +8. Not
  // G1gn leftover-PC predict. SMT+SS.
  // G1ht: replay must not kill_s1 while
  // npc is mid-line 01 (7ba fetch
  // outstanding). G1hs leftover Jump is
  // not the replay source. Not G1bq
  // !kill_s2. Not G1gn leftover-PC.
  // SMT+SS.
  // G1jo: replay must not kill_s1 while
  // npc is aligned 00 (7b8 request is
  // in s1 at npc 7b8; G1ht is 01-only.
  // G1jn kill_s2 returning-data did not
  // fire — in-flight s2 is the previous
  // 8-byte line). Not G1iy flush/
  // mispredict. Not G1hu. SMT+SS.
  // G1hv: leftover-complete Jump must not
  // flush_i-kill s1 while npc is mid-line
  // 01. Not G1hu kill_s2. Not G1ht
  // replay. Not G1gn leftover-PC.
  // SMT+SS.
  logic g1hv_spare_flush;
  assign g1hv_spare_flush = g6lc_fe_kill::leftover_jump_s1(
      CVA6Cfg, serving_unaligned, instruction_valid[0],
      cf_type[0] == ariane_pkg::Jump, npc_q[2:1] == 2'b01, ex_valid_i);
  // G1hw: leftover-complete Jump must not
  // is_mispredict-kill s1 while npc is
  // mid-line 01. G1hv spared flush_i
  // only; EX mispredict still killed.
  // Not G1hu kill_s2. Not G1gn.
  // SMT+SS.
  // G1iy flush/mispredict !kill_s1 at
  // npc 01 — MINI-FAIL lottery tohost
  // 2 @430. Do not re-land (needs
  // mispredict kill of mid-line 01).
  // G1jq: leftover Jump must not
  // flush/mispredict-kill s1 while npc
  // is aligned 00 (G1hv is 01-only;
  // G1jo saved replay s1; G1jp all-00
  // kill_s2 MINI-FAIL). Not G1iy. Not
  // G1hu. SMT+SS.
  logic g1jq_spare_flush;
  assign g1jq_spare_flush = g6lc_fe_kill::leftover_jump_s1(
      CVA6Cfg, serving_unaligned, instruction_valid[0],
      cf_type[0] == ariane_pkg::Jump, npc_q[2:1] == 2'b00, ex_valid_i);
  // G1jr flush_i !kill_s1 at all npc
  // 00 — HOLD-FAIL no cookie @600000
  // [1000]=8000f1d0 mcause=4. Do not
  // re-land (aligned-00 fetch needs
  // flush_i kill_s1). Not G1iy. Not
  // G1jp. SMT+SS.
  // G1js same-line flush_i !kill_s1 at
  // npc 00 — HOLD-FAIL same pin
  // [1000]=8000f1d0 mcause=4 @600000.
  // Do not re-land (same-line flush
  // s1 at 00 is the G1jr hole). SMT+SS.
  // G1jt: is_mispredict must not kill_s1
  // while npc is aligned 00 (7b8 in s1;
  // G1jo saved replay; G1jr/G1js flush
  // at 00 HOLD-FAIL so flush_i stays).
  // Not G1iy both at 01. Not G1jp.
  // SMT+SS.
  logic g1jt_spare_misp;
  assign g1jt_spare_misp = g6lc_fe_kill::aligned_misp_s1(
      CVA6Cfg, npc_q[2:1] == 2'b00);
  assign icache_dreq_o.kill_s1 =
      (is_mispredict & ~(g1hv_spare_flush | g1jq_spare_flush |
                         g1jt_spare_misp)) |
      (flush_i & ~(g1hv_spare_flush | g1jq_spare_flush)) |
      (replay & ~g6lc_fe_kill::replay_spare(
          CVA6Cfg, serving_unaligned, instruction_valid[0],
          cf_type[0] == ariane_pkg::NoCF,
          cf_type[0] == ariane_pkg::Jump,
          npc_q[2:1] == 2'b01, npc_q[2:1] == 2'b00));
  // if we have a valid branch-prediction we need to only kill the last cache request
  // also if we killed the first stage we also need to kill the second stage (inclusive flush)
  // I4z: do not let a stale bp_valid kill the in-flight mtvec line.
  assign trap_hold = CVA6Cfg.NrHarts > 1 & (trap_fetch_q | trap_tail_q);
  assign smt_trap_hold_o = trap_hold;
  // I4ad: also protect trap_tail (completing half of straddling RVI).
  // I4z only masked trap_fetch; stale bp then killed the ff10 fill.
  // G1bq leftover-complete !kill_s2 — HOLD-FAIL no cookie-exit.
  // G1bt leftover taken Branch to next 8B !kill_s2 — HOLD-FAIL
  // no cookie-exit. G1bw s2==target !kill_s2 — HOLD-FAIL no
  // cookie-exit. Do not re-land any of them.
  // G1cu leftover-complete slot0 Jump arms G1cc —
  // MINI-FAIL P8 0x18 @200727 (sticky +8 starve).
  // Do not re-land (G1aa / leftover NPC stall class).
  assign g1bv_arm = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      serving_unaligned && instruction_valid[0] &&
      (cf_type[0] == ariane_pkg::Branch) && |predict_address;
  // G1hu leftover Jump bp_valid !kill_s2
  // different-line I$ — MINI-FAIL FDT
  // printed 24 (P8 0x18) @2479. Do not
  // re-land (G1bq/G1bt kill_s2 class).
  // G1ix: bp_valid must not kill_s2 while
  // npc is mid-line 01 (7b8 fill dies
  // in s2 even when G1ht spared s1).
  // Not G1hu leftover Jump. Not G1in
  // mute. SMT+SS.
  // G1jn: also spare when the returning
  // I$ is the npc-00 aligned compressed
  // Branch line (7b8 fill dies in s2 at
  // npc 00; G1ix is 01-only). Not G1ja
  // fetch steal. Not G1hu. SMT+SS.
  // G1jp bp_valid !kill_s2 at all npc
  // 00 — MINI-FAIL lottery tohost 2
  // @420, FDT 50 @545. Do not re-land
  // (aligned-00 fetch needs bp_valid
  // kill_s2). Not G1ix npc-01.
  // sib_lo_s2 16B-line second 8B vs
  // first-8B in-flight — MINI-FAIL
  // lottery 2 @420 / FDT 50 @545
  // (G1jp class). leftover_hi8_s2
  // leftover occupying off-line vs
  // first-8B in-flight at npc high
  // half — MINI-FAIL FDT 24 @201516
  // (G1hu). leftover_lo8_s2: leftover
  // occupying off-line, npc 00 first
  // 8B, in-flight is that same 8B
  // (7b0 fill). Hygiene: leftover
  // occupying false at n7b0.
  // load00_lo8_s2: same-8B in-flight
  // is 00 first-8B RVI LOAD rd!=0.
  // No leftover occupying. Not
  // leftover_hi8_s2. Not G1jp. Not
  // G1hu. SMT+SS (not Phase 4b
  // SS&&RVC; stream I=2 / server
  // T=1 stay folded).
  logic g1jn_spare;
  logic g6lc_lo_lo8_s2;
  logic g6lc_ld_lo8_s2;
  assign g1jn_spare = g6lc_fe_kill::cbranch_s2(
      CVA6Cfg, npc_q[2:1] == 2'b00,
      icache_dreq_i.vaddr[2:1] == 2'b00,
      icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:3] ==
          npc_q[CVA6Cfg.VLEN-1:3],
      icache_dreq_i.data[15:0]);
  assign g6lc_lo_lo8_s2 = g6lc_fe_kill::leftover_lo8_s2(
      CVA6Cfg,
      g6lc_sib_cjalr::leftover_slot0(
          serving_unaligned, instruction_valid[0],
          addr[0][2:1] == 2'b11),
      npc_q[2:1] == 2'b00, ~npc_q[3],
      addr[0][CVA6Cfg.VLEN-1:4] !=
          npc_q[CVA6Cfg.VLEN-1:4],
      icache_dreq_i.vaddr[2:1] == 2'b00,
      icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:3] ==
          npc_q[CVA6Cfg.VLEN-1:3]);
  assign g6lc_ld_lo8_s2 = g6lc_fe_kill::load00_lo8_s2(
      CVA6Cfg, icache_dreq_i.valid,
      npc_q[2:1] == 2'b00, ~npc_q[3],
      icache_dreq_i.vaddr[2:1] == 2'b00,
      icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:3] ==
          npc_q[CVA6Cfg.VLEN-1:3],
      icache_dreq_i.data[31:0]);
  assign icache_dreq_o.kill_s2 = icache_dreq_o.kill_s1
                                 | (bp_valid & ~trap_hold &
                                    ~g6lc_fe_kill::bp_s2_spare(
                                        CVA6Cfg, npc_q[2:1] == 2'b01,
                                        g1jn_spare || g6lc_lo_lo8_s2 ||
                                        g6lc_ld_lo8_s2));

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
                                & g6lc_jalr_usable::usable(
                                      CVA6Cfg, CVA6Cfg.VLEN,
                                      64'(resolved_branch_i.target_address));
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // G1fu: after slot0-only consume of an aligned
  // compressed Branch, next fetch is pc+2.
  logic g1fu_plus2;
  assign g1fu_plus2 = g6lc_present::plus2_cons(
      CVA6Cfg, instruction_valid[0], serving_unaligned,
      addr[0][2:1] == 2'b00, instr[0][1:0] != 2'b11, is_branch[0],
      instr_queue_consumed[0], instr_queue_consumed[1]);
  // G1fv: G1fu consume is too late (7b8 cmt t=20474
  // after npc 7c0 t=20465). Step +2 when an aligned
  // compressed Branch is *presented* slot0-only.
  // Not G1ce/+8 hold. SMT+SS.
  logic g1fv_plus2;
  assign g1fv_plus2 = g6lc_present::plus2_pres(
      CVA6Cfg, instruction_valid[0], instruction_valid[1],
      serving_unaligned, addr[0][2:1] == 2'b00,
      instr[0][1:0] != 2'b11, is_branch[0]);
  // G1fw: G1fv uses instruction_valid[1]. IQ sees
  // g1ct_valid[1] (G1ct/G1cz smash). Step +2 when
  // the IQ view is slot0-only. Not G1ce/+8. SMT+SS.
  logic g1fw_plus2;
  assign g1fw_plus2 = g6lc_present::plus2_iq(
      CVA6Cfg, g1ct_valid[0], g1ct_valid[1], serving_unaligned,
      addr[0][2:1] == 2'b00, instr[0][1:0] != 2'b11, is_branch[0]);
  // G1fx IQ slot0-only +2 without is_branch —
  // MINI-FAIL FDT printed 42 @584. Do not re-land
  // (steps npc +2 on every aligned compressed
  // slot0-only IQ view).
  // G1fy: same IQ slot0-only +2 gated on
  // rvc_branch encoding, not is_branch (G1bj
  // may clear it) and not all compressed.
  // Not G1ce/+8. SMT+SS.
  logic g1fy_plus2;
  assign g1fy_plus2 = g6lc_present::plus2_iq(
      CVA6Cfg, g1ct_valid[0], g1ct_valid[1], serving_unaligned,
      addr[0][2:1] == 2'b00, instr[0][1:0] != 2'b11, rvc_branch[0]);
  // G1fz IQ slot0 Branch +2 even if slot1
  // valid — MINI-FAIL FDT printed 23 @200633.
  // Do not re-land (skips later-slot
  // fallthrough after a compressed Branch).
  // G1ga: same +2 only when slot1 is JumpR
  // (7ba c.jalr). Not G1fz all slot1-valid.
  // Not G1fx. SMT+SS.
  logic g1ga_plus2;
  assign g1ga_plus2 = g6lc_present::plus2_jalr(
      CVA6Cfg, g1ct_valid[0], g1ct_valid[1], !serving_unaligned,
      addr[0][2:1] == 2'b00, instr[0][1:0] != 2'b11,
      is_branch[0] || rvc_branch[0], instr[1]);
  // G1gb: G1ga uses g1ct_valid. IQ smash may
  // hide slot1 JumpR. Same Branch|JumpR +2 on
  // the frontend instruction_valid view.
  // Not G1fz any slot1. SMT+SS.
  logic g1gb_plus2;
  assign g1gb_plus2 = g6lc_present::plus2_jalr(
      CVA6Cfg, instruction_valid[0], instruction_valid[1],
      !serving_unaligned, addr[0][2:1] == 2'b00,
      instr[0][1:0] != 2'b11, is_branch[0] || rvc_branch[0], instr[1]);
  // G1gc: G1gb requires !serving_unaligned.
  // 7b8 may be on the leftover path. Same
  // frontend Branch|JumpR +2 even when
  // serving leftover. Not G1fz. SMT+SS.
  logic g1gc_plus2;
  assign g1gc_plus2 = g6lc_present::plus2_jalr(
      CVA6Cfg, instruction_valid[0], instruction_valid[1], 1'b1,
      addr[0][2:1] == 2'b00, instr[0][1:0] != 2'b11,
      is_branch[0] || rvc_branch[0], instr[1]);
  // G1gd: all +2 gates require !bp_valid.
  // Not-taken 7b8 may still raise bp_valid
  // with predict=7c0. Same frontend
  // Branch|JumpR +2 even when bp_valid.
  // Not G1fz. SMT+SS.
  logic g1gd_plus2;
  assign g1gd_plus2 = g1gc_plus2;
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
    g1jc_steal = 1'b0;
    g1jg_steal = 1'b0;
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
    // I4ad: do not let a stale taken-CF steal the completing half either.
    // G1gn leftover-PC predict npc skip —
    // HOLD-FAIL no cookie ~6 min. Do not
    // re-land (left kill_s2 live).
    if (bp_valid && !trap_hold) begin
      fetch_address = predict_address;
      npc_d = predict_address;
    end
    // G1iz I$ vaddr stays npc 8-byte line
    // at mid-line 01 — MINI-FAIL FDT
    // tohost 23 @1192. Do not re-land
    // (starves leftover-PC I$ at 01).
    // 1. Default assignment
    // I4y: do not step NPC while IF is flushed.
    // I4z: do not step while the mtvec line is still outstanding.
    // G1cc: do not step while leftover-Branch target is
    // outstanding (g1bv_wait) and not yet presented.
    // G1cd arm-beat hold — HOLD-FAIL no cookie-exit.
    // G1ce leftover-complete +8 stall — HOLD-FAIL no cookie-exit.
    // G1ck leftover-NoCF sequential-next +8 hold —
    // HOLD-FAIL no cookie-exit. Do not re-land.
    // G1cs: also hold +8 while a line-aligned
    // mispredict target has not been presented.
    // G1db leftover-complete slot0 Jump !+8 —
    // HOLD-FAIL no cookie-exit. Do not re-land.
    // G1dw leftover-pending +8 hold at complete
    // line — HOLD-FAIL (illegal @780, hang @2d38,
    // no cookie). Do not re-land.
    if (if_ready && !flush_i && !(CVA6Cfg.NrHarts > 1 && trap_fetch_q) &&
        !g1cc_hold_tgt && !g1cs_hold_tgt) begin
      npc_d = {
        fetch_address[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1, {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
      };
    end
    // G1fu: slot0-only consume of an aligned compressed
    // Branch (7b8 c.beqz) must fetch pc+2 (7ba), not
    // the next 8B line (7c0). Not G1ce/+8 hold.
    // Not G1ep mid-line 01. Replay/mispredict still win.
    // SMT+SS.
    if (((g1fu_plus2 || g1fv_plus2 || g1fw_plus2 || g1fy_plus2 ||
          g1ga_plus2 || g1gb_plus2 || g1gc_plus2) && !bp_valid) ||
        g1gd_plus2) begin
      npc_d = addr[0] + CVA6Cfg.VLEN'(2);
    end
    // 2. Replay instruction fetch
    // G1gl: leftover-PC replay must not steal
    // npc after G1gd +2 (mid-line 01).
    // G1gm: same while a jalr has been seen
    // (no cnt). Off-line leftover-PC replay
    // (replay 8B line ≠ npc line) — 766 at
    // npc 7ba. Skip-range latch HOLD-FAIL.
    // G1gn bp_valid HOLD-FAIL. Not G1ce/+8.
    if (replay && !g6lc_lj_rpl) begin
      npc_d = replay_addr;
    end
    // 3. Control flow change request (mispredict)
    // Classic (FtqDepth==0): next fetch is the resolved target.
    // FTQ: reseed queue with the resolved target (see ftq_push_vaddr), but NPC
    // steps to the *following* fetch block so when CF-hold lifts we do not push
    // the target twice (same pattern as set_pc_commit reseed below).
    if (is_mispredict) begin
      // EXTRACT E2: do not reseed NPC to an unusable JALR target.
      if (!(CVA6Cfg.NrHarts > 1 &&
            !g6lc_jalr_usable::usable(
                 CVA6Cfg, CVA6Cfg.VLEN,
                 64'(resolved_branch_i.target_address)))) begin
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
    // G1ge: leftover jal x0 unconsumed must not
    // keep npc off a committed JumpR target.
    if (g1ge_wait_q && serving_unaligned &&
        instruction_valid[0] && !instr_queue_consumed[0] &&
        (cf_type[0] == ariane_pkg::Jump)) begin
      npc_d = g1ge_tgt_q;
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
    // Must *not* outrank exception/eret/CSR-flush: I4w nat skipped mtvec
    // jal@0x3d8 and fetched the next 8B block (csrr@3e0 / sd@3e4) because a
    // same-cycle or next-cycle restore overwrote trap_vector_base.
    if (CVA6Cfg.NrHarts > 1 && smt_restore_i &&
        !ex_valid_i && !eret_i && !set_pc_commit_i &&
        !(CVA6Cfg.DebugEn && set_debug_pc_i) && !trap_hold) begin
      npc_d         = smt_npc_restore_i;
      fetch_address = smt_npc_restore_i;
    end
    // I4z: hold fetch on mtvec until that block is registered (beats restore
    // and if_ready step). SI (NrHarts==1) never arms trap_fetch_q.
    if (CVA6Cfg.NrHarts > 1 && trap_fetch_q) begin
      npc_d         = trap_pc_q;
      fetch_address = trap_pc_q;
    end
    // G1ja different-line predict must not
    // skip aligned-00 npc I$ — MINI-FAIL
    // lottery tohost 4 @362 (first-pass
    // bnez took ret0). Do not re-land
    // (extra 00-line I$ under predict
    // breaks lottery jalr/bnez).
    // G1jc: first leftover-RVI ([2:1]==11)
    // I$ on a different 16-byte line while
    // npc is mid-line 01 still requests the
    // npc 8-byte line. npc_d is already
    // final. Not G1iz every-cycle hold.
    // Not G1in mute leftover present.
    // SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        !trap_hold &&
        (npc_q[2:1] == 2'b01) &&
        (fetch_address[2:1] == 2'b11) &&
        (fetch_address[CVA6Cfg.VLEN-1:4] !=
         npc_q[CVA6Cfg.VLEN-1:4]) &&
        !g1jc_did_q) begin
      g1jc_steal    = 1'b1;
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
    end
    // G1jd sequential-next 8-byte fetch
    // must not skip aligned-00 npc I$ —
    // MINI-FAIL FDT tohost 57 @2652
    // (P3 0x39 c.mv s0,a0 dropped). Do
    // not re-land (extra 00-line I$
    // under next-line predict).
    // G1jg: first sequential-next 8-byte
    // fetch while npc is mid-line 01 still
    // requests the npc 8-byte line. npc_d
    // is already final. Not G1iz every
    // cycle. Not G1jc leftover-11. Not
    // G1jd at 00. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        !trap_hold &&
        (npc_q[2:1] == 2'b01) &&
        (fetch_address[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
         (npc_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1)) &&
        !g1jg_did_q) begin
      g1jg_steal    = 1'b1;
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
    end
    // G1jh first different 8-byte-line I$
    // at npc 01 — MINI-FAIL FDT tohost
    // 23 @1205 (P7 getprop-shaped jal,
    // same class as G1iz). Do not re-land
    // (one-shot still starves leftover-PC
    // I$ at 01; leftover/jump-target
    // fetch is load-bearing).
    // sib8_fetch sibling 8B while npc on
    // first half of 16B line — MINI-FAIL
    // FDT hang @400000 (G1jd class). Do
    // not re-land.
    // plus2_stay: aligned C-Branch at npc
    // 00 keeps I$ on that 8B line (7b8).
    // TRACE n7b8@20431 n7c0@20438 n7ba
    // @20440 — bp_valid sequential 7c0
    // before +2. Not G1ja any-00. Not
    // G1iz. SMT+SS.
    if (!trap_hold &&
        g6lc_present::plus2_stay(
            CVA6Cfg, npc_q[2:1] == 2'b00,
            instruction_valid[0],
            instr[0][1:0] != 2'b11,
            is_branch[0] || rvc_branch[0])) begin
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
    end
    // line_hi8_stay: npc 00 of the 16B-line
    // second 8B (7b8) keeps I$ there, not
    // sequential 7c0. plus2_stay did not
    // fire (no C-Branch in slot0 yet).
    // hi8_npc_fetch any-diff-8B — MINI-FAIL
    // lottery 4 @362 (G1ja) FDT 57 @445
    // (G1jd). Do not re-land. SMT+SS.
    if (!trap_hold &&
        g6lc_present::line_hi8_stay(
            CVA6Cfg, npc_q[2:1] == 2'b00, npc_q[3],
            fetch_address[CVA6Cfg.VLEN-1:3] ==
                (npc_q[CVA6Cfg.VLEN-1:3] + 1))) begin
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
    end
    // hi8_lo11 leftover-PC-shaped fetch
    // [2:1]==11 vs npc 00 of 16B-line
    // second 8B — MINI-FAIL FDT 57 @445
    // (G1jd). lottery PASS. Do not re-land
    // (7b8 vs leftover-PC fetch is
    // load-bearing).
    // lo11_npc00 leftover-PC-shaped
    // fetch ([2:1]==11) vs npc 00 first
    // 8B — MINI-FAIL sib P0 fail 1 @407
    // / FDT 0x10 @423. Do not re-land
    // (jalr-target [2:1]==11 stolen).
    // lo_pc_npc00 leftover serving +
    // fetch is leftover 8B vs npc 00
    // first 8B — HOLD-FAIL plat_hc=80
    // mepc 0xb0/2 @250000. Do not
    // re-land (starves leftover-PC I$
    // at npc 00 first 8B).
    // ljx0_off_npc00: leftover jal x0
    // serving off the npc 16B line —
    // hygiene (not serving at n7b0).
    // ljx0_pc: latched leftover jal x0
    // PC after serving ends. Fetch of
    // that leftover 8B vs npc 00 first
    // 8B still requests npc. Not lo_pc.
    // Not lo11. Not G1gn. Not is_mispredict.
    // SMT+SS.
    if (!trap_hold && !is_mispredict &&
        g6lc_present::ljx0_off_npc00(
            CVA6Cfg, npc_q[2:1] == 2'b00, ~npc_q[3],
            g1gi_lj || g6lc_lj_pc_v,
            (g1gi_lj ? addr[0][CVA6Cfg.VLEN-1:4] :
                       g6lc_lj_pc[CVA6Cfg.VLEN-1:4]) !=
                npc_q[CVA6Cfg.VLEN-1:4],
            fetch_address[CVA6Cfg.VLEN-1:3] ==
                (g1gi_lj ? addr[0][CVA6Cfg.VLEN-1:3] :
                           g6lc_lj_pc[CVA6Cfg.VLEN-1:3]))) begin
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
    end
    // ljx0_bp_npc00: leftover jal x0
    // presented ([2:1]==11, not only
    // serving) and bp_valid stole fetch
    // to the Jump target. npc 00 first
    // 8B still requests npc. Not fetch
    // == leftover PC (ljx0_off no-op).
    // Not JumpR (lo11). Not G1gn npc
    // skip. Not is_mispredict. SMT+SS.
    if (!trap_hold && !is_mispredict &&
        g6lc_present::ljx0_bp_npc00(
            CVA6Cfg, npc_q[2:1] == 2'b00, ~npc_q[3],
            instruction_valid[0] &&
                g6lc_iq_hide::leftover_jal_x0(
                    addr[0][2:1], instr[0]),
            bp_valid,
            fetch_address[CVA6Cfg.VLEN-1:3] !=
                npc_q[CVA6Cfg.VLEN-1:3])) begin
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
    end
    // lo_ld_stay aligned RVI LOAD at npc
    // 00 first 8B — HOLD-FAIL 51b1c001
    // @250000. Do not re-land (yanked
    // success-cave addi / G1jw analog).
    // lo_ld_lo11: that LOAD plus fetch
    // leftover-PC-shaped [2:1]==11 off
    // the npc 16B line. Not lo11. Not
    // lo_ld. Not is_mispredict. SMT+SS.
    if (!trap_hold && !is_mispredict &&
        g6lc_present::lo_ld_lo11(
            CVA6Cfg, npc_q[2:1] == 2'b00, ~npc_q[3],
            instruction_valid[0],
            instr[0][1:0] == 2'b11,
            instr[0][6:0] == 7'b0000011,
            fetch_address[2:1] == 2'b11,
            fetch_address[CVA6Cfg.VLEN-1:4] !=
                npc_q[CVA6Cfg.VLEN-1:4])) begin
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
    end
    // leftover_nx8_npc00: leftover occupying
    // slot0, fetch is leftover's next 8B
    // (768), npc 00 first 8B off leftover
    // 16B (7b0). Request npc. Not lo_pc
    // leftover-PC 8B. Not lo11 hw11. Not
    // leftover_slot0 hide. Not is_mispredict.
    // SMT+SS.
    if (!trap_hold && !is_mispredict &&
        g6lc_present::leftover_nx8_npc00(
            CVA6Cfg,
            g6lc_sib_cjalr::leftover_slot0(
                serving_unaligned, instruction_valid[0],
                addr[0][2:1] == 2'b11),
            npc_q[2:1] == 2'b00, ~npc_q[3],
            addr[0][CVA6Cfg.VLEN-1:4] !=
                npc_q[CVA6Cfg.VLEN-1:4],
            fetch_address[CVA6Cfg.VLEN-1:3] ==
                (addr[0][CVA6Cfg.VLEN-1:3] + 1))) begin
      fetch_address = {npc_q[CVA6Cfg.VLEN-1:3], 3'b000};
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
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1jc_did_q <= 1'b0;
    end else if (flush_i || is_mispredict ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i) ||
                 (npc_q[2:1] != 2'b01)) begin
      g1jc_did_q <= 1'b0;
    end else if (g1jc_steal) begin
      g1jc_did_q <= 1'b1;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1jg_did_q <= 1'b0;
    end else if (flush_i || is_mispredict ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i) ||
                 (npc_q[2:1] != 2'b01)) begin
      g1jg_did_q <= 1'b0;
    end else if (g1jg_steal) begin
      g1jg_did_q <= 1'b1;
    end
  end

  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data;
  // re-align the cache line
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};

  assign trap_fetch_hit = trap_fetch_q && icache_valid_q &&
      (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]
       == trap_pc_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]);
  // I4bs: I$ registered is not queued. I4bq released on hit&&!flush, then
  // if_ready stepped to 3e0 before IQ consumed jal@3d8 (I4br: no switch).
  // I4bt: consumed mtvec Jump (patched jal@3d8→0x2d00) must not release
  // to sequential 3e0 — sd@3e4 can issue before EX resolves the Jump.
  logic                            trap_fetch_queued;
  logic                            trap_queued_jump;
  logic [CVA6Cfg.VLEN-1:0]         trap_jump_tgt;
  // G1y: predicted Jump in the registered line not yet in the IQ.
  // G1aq: older NoCF still unconsumed before a Branch on this line.
  // G1au: leftover-RVI complete slot0 not yet in the IQ.
  logic                            jump_unconsumed;
  logic                            prefix_unconsumed;
  logic                            leftover_unconsumed;
  logic                            g1bp_nocf_dest;
  always_comb begin
    jump_unconsumed     = 1'b0;
    prefix_unconsumed   = 1'b0;
    leftover_unconsumed = 1'b0;
    g1bp_nocf_dest      = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 && icache_valid_q) begin
      logic seen_noncf;
      seen_noncf = 1'b0;
      leftover_unconsumed = serving_unaligned && instruction_valid[0] &&
                            !instr_queue_consumed[0];
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        // G1cb: leftover-complete later-slot Jump (c.j@0x4ce)
        // is not G1y keep. After G1ca, that Jump was the only
        // keep on the leftover line and g1bl/keep blocked
        // 0x4d0. Slot0 leftover Jump still keeps. Not G1bz
        // (bp_valid stays). Not G1y aligned jal. SMT+SS.
        if (instruction_valid[i] && !instr_queue_consumed[i] &&
            cf_type[i] == ariane_pkg::Jump &&
            !(serving_unaligned && instruction_valid[0] && (i != 0)))
          jump_unconsumed = 1'b1;
        if (instruction_valid[i] && !instr_queue_consumed[i] &&
            cf_type[i] == ariane_pkg::NoCF)
          seen_noncf = 1'b1;
        if (instruction_valid[i] &&
            cf_type[i] == ariane_pkg::Branch) begin
          if (seen_noncf) prefix_unconsumed = 1'b1;
        end
        // G1bp: unconsumed NoCF dest on this 8B line (g1bl).
        if (instruction_valid[i] && !instr_queue_consumed[i] &&
            cf_type[i] == ariane_pkg::NoCF &&
            (instr[i][11:7] != 5'd0) &&
            (addr[i][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
             icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]))
          g1bp_nocf_dest = 1'b1;
      end
      // G1ca: prefix is dest *before* Branch only (in-loop
      // seen_noncf). The any-slot OR (seen_branch && dest)
      // treated leftover-complete Branch then li s11 as a
      // prefix and g1bl-rejected 0x4d0. c.li@0x4d0 is older
      // than beq@0x4d4 — in-loop already covers it. Not G1bz
      // later-slot CF. Not G1bu barrier. SMT+SS.
    end
  end
  // G1bl: do not accept a different 8B I$ return while an
  // older same-line NoCF dest is still unconsumed. keep_line
  // already keeps valid; the else-path still overwrote 0x4d0
  // with 0x4e0. G1bb froze all data for all keep_line —
  // HOLD-FAIL. Same-line replay still accepted. Not G1ab/G1bk.
  // SMT+SS. G1ca: dest-before-Branch only (not leftover
  // Branch then later dest).
  // G1cp: aligned line holds on unconsumed NoCF dest
  // without a later Branch. Second pass 0x4d0→0x4d8 is
  // sequential +8; beq@0x4d4 is static NT so prefix=0
  // and G1bl never kept c.li. Leftover-complete still
  // requires prefix (G1ca). Not G1bp any-slot leftover.
  // Not G1by. SMT+SS.
  // G1cv: leftover-complete unconsumed slot0 Jump
  // (jal@0x3f6) must not be overwritten by sequential
  // 0x400. Not leftover NoCF (that rejected 0x4d0).
  // Not G1cu/G1aa NPC hold. Not G1bb freeze. SMT+SS.
  // G1ge: after a JumpR commits, accept its
  // target I$ even if leftover jal x0 is
  // unconsumed (g1cv). 7ba cmt @20475 never
  // presented 71e4. Not G1cv general accept.
  // SMT+SS.
  logic                            g1ge_wait_q;
  logic [CVA6Cfg.VLEN-1:0]         g1ge_tgt_q;
  logic                            g1ge_arm;
  logic                            g1ge_lift;
  assign g1ge_arm = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      resolved_branch_i.valid &&
      (resolved_branch_i.cf_type == ariane_pkg::JumpR) &&
      g6lc_jalr_usable::usable(
          CVA6Cfg, CVA6Cfg.VLEN,
          64'(resolved_branch_i.target_address));
  assign g1ge_lift = g1ge_wait_q && icache_dreq_i.valid &&
      (icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
       g1ge_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]);
  logic g1cv_leftover_jump;
  assign g1cv_leftover_jump = g6lc_fe_keep::leftover_jump(
      CVA6Cfg, serving_unaligned, instruction_valid[0],
      instr_queue_consumed[0], cf_type[0] == ariane_pkg::Jump, g1ge_lift);
  // G1ez: leftover-complete unconsumed slot0 NoCF dest
  // holds a different-line I$ without G1ca prefix.
  // serving_unaligned + g1bp requires prefix_unconsumed
  // (G1ca), so leftover auipc/addi releases 7b0 before
  // csrr pushes. Not G1cv Jump. Not G1bp prefix. Not
  // leftover Branch (G1ca/G1bt). SMT+SS.
  logic g1ez_hold;
  assign g1ez_hold = g6lc_fe_keep::leftover_nocf(
      CVA6Cfg, icache_valid_q, serving_unaligned, instruction_valid[0],
      instr_queue_consumed[0], cf_type[0] == ariane_pkg::NoCF,
      instr[0][11:7] != 5'd0, icache_dreq_i.valid,
      g6lc_fe_keep::diff_line(CVA6Cfg.VLEN, CVA6Cfg.FETCH_ALIGN_BITS,
          64'(icache_dreq_i.vaddr), 64'(icache_vaddr_q)));
  // G1ek: unconsumed aligned I|I (7a8 addi+csrr) must
  // not be replaced by 7b0/7b8. 7bc otherwise issues
  // with a0=1 before csrr enters IQ. Not G1cv leftover
  // Jump. Not G1ce/+8 NPC. SMT+SS.
  logic g1ek_ii_hold;
  assign g1ek_ii_hold = g6lc_fe_keep::ii_hold(
      CVA6Cfg, icache_valid_q, instruction_valid[0], instruction_valid[1],
      addr[0][2:1] == 2'b00, instr[0][1:0] == 2'b11, instr[1][1:0] == 2'b11,
      instr_queue_consumed[0], instr_queue_consumed[1], icache_dreq_i.valid,
      g6lc_fe_keep::diff_line(CVA6Cfg.VLEN, CVA6Cfg.FETCH_ALIGN_BITS,
          64'(icache_dreq_i.vaddr), 64'(icache_vaddr_q)));
  // G1el: 7a2 is [2:1]==01 (c.li+auipc). G1ek I|I hold
  // never arms. Hold different-line I$ while this
  // mid-line package is unconsumed so 7b8 cannot
  // issue before c.li/auipc/csrr. Not G1ek. Not
  // G1ce/+8 NPC. SMT+SS.
  logic g1el_mid_hold;
  assign g1el_mid_hold = g6lc_fe_keep::mid_hold(
      CVA6Cfg, icache_valid_q, instruction_valid[0], addr[0][2:1] == 2'b01,
      instr_queue_consumed[0], instruction_valid[1], instr_queue_consumed[1],
      icache_dreq_i.valid,
      g6lc_fe_keep::diff_line(CVA6Cfg.VLEN, CVA6Cfg.FETCH_ALIGN_BITS,
          64'(icache_dreq_i.vaddr), 64'(icache_vaddr_q)));
  // G1ep: after mid-line [2:1]==01 is consumed (7a2
  // c.li+auipc), do not accept a later 8B that is not
  // the sequential next line (7a8 I|I). G1el only
  // holds while unconsumed; TRACE npc@7a8 then 7b0
  // with no csrrcmt. Not G1eo idx_is. Not G1ce/+8
  // NPC. Not G1ck leftover +8. SMT+SS.
  logic [CVA6Cfg.VLEN-1:0] g1ep_next;
  logic                    g1ep_hold;
  assign g1ep_next = {addr[0][CVA6Cfg.VLEN-1:3] + 1'b1, 3'b0};
  assign g1ep_hold = g6lc_fe_keep::seq_next_hold(
      CVA6Cfg, icache_valid_q, instruction_valid[0], addr[0][2:1] == 2'b01,
      instr_queue_consumed[0], instruction_valid[1], instr_queue_consumed[1],
      icache_dreq_i.valid,
      g6lc_fe_keep::diff_line(CVA6Cfg.VLEN, CVA6Cfg.FETCH_ALIGN_BITS,
          64'(icache_dreq_i.vaddr), 64'(g1ep_next)));
  // G1ex: unissued dest-FIFO / presented CSR-to-a0
  // holds a different-line I$ (7b0/7b8). G1ek only
  // holds while I|I unconsumed; after consume CSR is
  // in IQ and 7bc can still issue first. Not G1ew IQ
  // head. Not G1ce/+8 NPC. SMT+SS.
  logic g1ex_csr_a0;
  logic g1ex_hold;
  assign g1ex_hold = g6lc_fe_keep::csr_a0_hold(
      CVA6Cfg, icache_valid_q, g1ex_csr_a0, icache_dreq_i.valid,
      g6lc_fe_keep::diff_line(CVA6Cfg.VLEN, CVA6Cfg.FETCH_ALIGN_BITS,
          64'(icache_dreq_i.vaddr), 64'(icache_vaddr_q)));
  // G1fa: do not accept an I$ line ahead of npc
  // (7b0/7b8 while npc is still 7a8). TRACE holds
  // 7a8 for 7 cy; a later-line return skips
  // addi+csrr. Not G1ce/+8 NPC stall. Not G1ep
  // consumed-01. Not leftover keep. SMT+SS.
  logic g1fa_hold;
  assign g1fa_hold = g6lc_fe_keep::ahead_npc(
      CVA6Cfg, icache_valid_q, icache_dreq_i.valid, g1ge_lift,
      icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >
      npc_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]);
  // G1ic: leftover-PC I$ must not replace the
  // registered line while npc is mid-line 01.
  // Not G1el unconsumed-01 package. Not 71e4
  // (incoming [2:1]!=11). SMT+SS.
  // G1in leftover-PC hold while npc aligned
  // 00 — MINI-FAIL (with mute). Do not
  // re-land.
  logic g1ic_hold;
  assign g1ic_hold = g6lc_fe_keep::leftover_pc_01(
      CVA6Cfg, npc_q[2:1] == 2'b01, icache_dreq_i.valid,
      icache_dreq_i.vaddr[2:1] == 2'b11);
  // G1jm: registered aligned compressed
  // Branch I$ is not replaced until that
  // line's mid-line 01 is presented so
  // [31:16] c.jalr stays for 7ba. Not
  // G1iz vaddr force. Not G1bb all
  // keep_line. Not G1jh steal. SMT+SS.
  logic g1jm_01_now;
  logic g1jm_keep;
  always_comb begin
    g1jm_01_now = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (instruction_valid[s] &&
            (addr[s][2:1] == 2'b01) &&
            (addr[s][CVA6Cfg.VLEN-1:3] ==
             icache_vaddr_q[CVA6Cfg.VLEN-1:3]))
          g1jm_01_now = 1'b1;
      end
    end
  end
  assign g1jm_keep = g6lc_fe_keep::br_until_01(
      CVA6Cfg, icache_valid_q, g1bv_use_stash, icache_vaddr_q[2:1] == 2'b00,
      icache_data_q[15:0], g1jm_01_now);
  // ld_until_01 keep registered 00 LOAD
  // until sibling 01 — MINI-FAIL FDT
  // 106 @409 (G1lm). Do not re-land.
  // load00_vs_off16: 00 first-8B LOAD is
  // not replaced by off-16B I$ while npc
  // is on that first 8B (n7b0 vs leftover
  // 768). Not until 01. Not G1in. SMT+SS.
  logic g6lc_ld_vs_lo;
  logic g6lc_ld_npc_lo;
  assign g6lc_ld_npc_lo = g6lc_fe_keep::load00_vs_off16(
      CVA6Cfg, icache_valid_q,
      icache_vaddr_q[2:1] == 2'b00, ~icache_vaddr_q[3],
      npc_q[2:1] == 2'b00, ~npc_q[3],
      npc_q[CVA6Cfg.VLEN-1:4] == icache_vaddr_q[CVA6Cfg.VLEN-1:4],
      icache_data_q[31:0], 1'b1);
  assign g6lc_ld_vs_lo = g6lc_fe_keep::load00_vs_off16(
      CVA6Cfg, icache_valid_q,
      icache_vaddr_q[2:1] == 2'b00, ~icache_vaddr_q[3],
      npc_q[2:1] == 2'b00, ~npc_q[3],
      npc_q[CVA6Cfg.VLEN-1:4] == icache_vaddr_q[CVA6Cfg.VLEN-1:4],
      icache_data_q[31:0],
      icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:4] !=
          npc_q[CVA6Cfg.VLEN-1:4]);
  // load00_vs_lj: 00 first-8B LOAD vs
  // leftover-PC I$ [2:1]==11, no npc
  // (7b0 may register before n7b0).
  // Not ld_until_01. Not G1in. SMT+SS.
  logic g6lc_ld_vs_lj;
  assign g6lc_ld_vs_lj = g6lc_fe_keep::load00_vs_lj(
      CVA6Cfg, icache_valid_q,
      icache_vaddr_q[2:1] == 2'b00, ~icache_vaddr_q[3],
      icache_data_q[31:0],
      icache_dreq_i.vaddr[2:1] == 2'b11);
  logic g1bl_hold_line;
  assign g1bl_hold_line = g6lc_fe_keep::hold_diff(
      CVA6Cfg, icache_valid_q, icache_dreq_i.valid,
      g6lc_fe_keep::diff_line(CVA6Cfg.VLEN, CVA6Cfg.FETCH_ALIGN_BITS,
          64'(icache_dreq_i.vaddr), 64'(icache_vaddr_q)),
      (g1bp_nocf_dest && (serving_unaligned ? prefix_unconsumed : 1'b1)) ||
      g1cv_leftover_jump || g1ek_ii_hold || g1el_mid_hold ||
      g1ep_hold || g1ex_hold || g1ez_hold || g1fa_hold ||
      g1ic_hold || g1jm_keep || g6lc_ld_vs_lo ||
      g6lc_ld_vs_lj);
  // G1cr: keep registered I$ across mispredict when the
  // resolved target is this same 8B line (aligned).
  logic g1cr_keep_tgt;
  assign g1cr_keep_tgt = g6lc_fe_keep::keep_misp_tgt(
      CVA6Cfg, icache_valid_q, ex_valid_i, resolved_branch_i.valid,
      resolved_branch_i.is_mispredict,
      resolved_branch_i.target_address[CVA6Cfg.FETCH_ALIGN_BITS-1:0] == '0,
      g6lc_fe_keep::same_line(CVA6Cfg.VLEN, CVA6Cfg.FETCH_ALIGN_BITS,
          64'(icache_vaddr_q), 64'(resolved_branch_i.target_address)));
  // G1bu leftover-Branch I$ target barrier — HOLD-FAIL no
  // cookie-exit. Do not re-land (starved OpenSBI fetch).
  // G1bv: capture leftover-Branch target return into a side
  // stash (does not reject other lines). Present after the
  // leftover line drops. SMT+SS.
  // g1bv_arm assigned with G1bw kill_s2 (needs cf_type/predict).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1bv_wait_q       <= 1'b0;
      g1bv_stash_v_q    <= 1'b0;
      g1bv_tgt_q        <= '0;
      g1bv_arm_line_q   <= '0;
      g1bv_stash_addr_q <= '0;
      g1bv_stash_data_q <= '0;
    end else if (flush_i || is_mispredict ||
                 (CVA6Cfg.NrHarts > 1 && ex_valid_i)) begin
      g1bv_wait_q    <= 1'b0;
      g1bv_stash_v_q <= 1'b0;
    end else begin
      if (g1bv_arm) begin
        g1bv_wait_q     <= 1'b1;
        g1bv_tgt_q      <= predict_address;
        g1bv_arm_line_q <= icache_vaddr_q;
      end
      if (g1bv_wait_q && icache_dreq_i.valid &&
          (icache_dreq_i.vaddr[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
           g1bv_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) begin
        g1bv_stash_v_q    <= 1'b1;
        g1bv_stash_data_q <= icache_data;
        g1bv_stash_addr_q <= icache_dreq_i.vaddr;
      end
      // G1cj leftover-complete sequential-next stash —
      // HOLD-FAIL wfi-exit t=217088 plat_hc=80. Do not
      // re-land.
      if (g1bv_stash_v_q && instruction_valid[0] &&
          instr_queue_consumed[0] &&
          (addr[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
           g1bv_stash_addr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) begin
        g1bv_wait_q    <= 1'b0;
        g1bv_stash_v_q <= 1'b0;
      end
      if (g1bv_wait_q && icache_valid_q && !g1bv_use_stash &&
          (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
           g1bv_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) begin
        g1bv_wait_q    <= 1'b0;
        g1bv_stash_v_q <= 1'b0;
      end
    end
  end
  // G1cs wait: arm on line-aligned mispredict; clear
  // when that line is registered or on exception /
  // set_pc / eret / debug. Do not clear on flush_if
  // or is_mispredict (that is the arm). Not G1cd.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1cs_wait_q <= 1'b0;
      g1cs_tgt_q  <= '0;
    end else if (CVA6Cfg.NrHarts > 1 &&
                 (ex_valid_i || set_pc_commit_i || eret_i ||
                  set_debug_pc_i)) begin
      g1cs_wait_q <= 1'b0;
    end else if (g1cs_arm) begin
      g1cs_wait_q <= 1'b1;
      g1cs_tgt_q  <= resolved_branch_i.target_address;
    end else if (g1cs_wait_q && icache_valid_q &&
                 (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
                  g1cs_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) begin
      g1cs_wait_q <= 1'b0;
    end
  end
  // G1ge: arm on usable JumpR resolve; clear when
  // that line is registered or on exception /
  // set_pc / eret / debug. SMT+SS.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1ge_wait_q <= 1'b0;
      g1ge_tgt_q  <= '0;
    end else if (CVA6Cfg.NrHarts > 1 &&
                 (ex_valid_i || set_pc_commit_i || eret_i ||
                  set_debug_pc_i)) begin
      g1ge_wait_q <= 1'b0;
    end else if (g1ge_arm) begin
      g1ge_wait_q <= 1'b1;
      g1ge_tgt_q  <= resolved_branch_i.target_address;
    end else if (g1ge_wait_q && icache_valid_q &&
                 (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] ==
                  g1ge_tgt_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) begin
      g1ge_wait_q <= 1'b0;
    end
  end
  // G1gi jalr-seen + G1gk 01-hold flops live in g6lc_lj_hide.
  // G1cn I$ req suppress flop — MINI-FAIL P1 0x10 @386.
  // Do not re-land.
  always_comb begin
    trap_fetch_queued = 1'b0;
    trap_queued_jump  = 1'b0;
    trap_jump_tgt     = '0;
    if (trap_fetch_hit && !flush_i) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (instruction_valid[i] && instr_queue_consumed[i] &&
            (addr[i][CVA6Cfg.VLEN-1:1] == trap_pc_q[CVA6Cfg.VLEN-1:1])) begin
          trap_fetch_queued = 1'b1;
          if (cf_type[i] == ariane_pkg::Jump) begin
            trap_queued_jump = 1'b1;
            trap_jump_tgt = addr[i] +
                (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trap_fetch_q <= 1'b0;
      trap_tail_q  <= 1'b0;
      trap_pc_q    <= '0;
    end else if (CVA6Cfg.NrHarts > 1 && ex_valid_i) begin
      trap_fetch_q <= 1'b1;
      trap_tail_q  <= 1'b0;
      trap_pc_q    <= trap_vector_base_i;
    end else if (trap_fetch_queued) begin
      // I4aa: first mtvec line is in. Allow NPC to step for a straddling
      // RVI (expected_trap csrr@ff0e) but keep restore off until a *later*
      // fetch block is registered (one beat was not enough on an I$ miss).
      // I4bq: same-cycle SMT switch flush_if drops icache_valid_q *and*
      // would have released the hold (hit used the pre-flush registered
      // 3d8 line). IQ never saw jal@3d8 → PEEL fallthrough sd@3e4.
      // Stay on mtvec until a non-flush beat presents the block.
      // I4bs: also require IQ consume of the mtvec insn (not just I$ hit).
      // I4bt: Jump at mtvec → hold fetch at the jal target (dump cave),
      // not tail/3e0. Non-Jump (csrr@ff08) still takes the I4aa tail.
      if (trap_queued_jump && |trap_jump_tgt) begin
        trap_fetch_q <= 1'b1;
        trap_tail_q  <= 1'b0;
        trap_pc_q    <= trap_jump_tgt;
      end else begin
        trap_fetch_q <= 1'b0;
        trap_tail_q  <= 1'b1;
      end
    end else if (trap_tail_q && icache_valid_q &&
                 (icache_vaddr_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS]
                  != trap_pc_q[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS])) begin
      trap_tail_q <= 1'b0;
    end
  end

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
      // G1y: do not drop the line while the predicted Jump itself is
      // still unconsumed (mini P6 jal + li t2 in one FETCH_WIDTH block).
      // G1bb hold registered I$ data — HOLD-FAIL plat_hc=80 mepc
      // 0x12640/2. Do not re-land (keep_line already keep-valid;
      // freezing data starved OpenSBI fetch).
      // G1bl: reject only a *different-line* return while aligned
      // slot0 NoCF is unconsumed (not all keep_line, not same-line).
      // G1cr: mispredict to the registered line (line-aligned
      // target) must not drop that I$. Leftover beq@0x4c6
      // resolves taken to 0x4d0 after G1cp already held
      // 0x4d0; flush_if/is_mispredict then killed c.li.
      // TRACE t=920 0x4d0 t1=ra, t3 stayed 0xed. IQ still
      // flushes (flush_if). Not G1bb freeze. Not G1bd
      // replay. Not leftover kill_s2. SMT+SS.
      // G1jm: bp_valid must not drop a
      // registered aligned compressed-
      // Branch line before its +2 is
      // presented. Not G1ix npc-01 only.
      // ld_until_01 — MINI-FAIL FDT 106
      // @409 (G1lm). Do not re-land.
      // load00_vs_off16: leftover jal
      // bp_valid must not drop the
      // registered 00 first-8B LOAD
      // while npc is on that first 8B.
      if (((flush_i || is_mispredict) && !g1cr_keep_tgt) ||
          (bp_valid && !trap_hold &&
           !g6lc_cf_unissued::keep_line(CVA6Cfg, jump_unconsumed,
                                        prefix_unconsumed,
                                        leftover_unconsumed) &&
           !g1jm_keep && !g6lc_ld_npc_lo)) begin
        icache_valid_q    <= 1'b0;
        icache_ex_valid_q <= ariane_pkg::FE_NONE;
      end else begin
      // Prefer real I$ return; else inject loop-buffer data into the same pipeline
      icache_valid_q <= icache_dreq_i.valid | lbuf_inject | g1bl_hold_line;
      if (icache_dreq_i.valid && !g1bl_hold_line) begin
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
      .leftover_pending_i (leftover_pending),
      .g1ff_ii_csr_i      (g1ff_ii_csr),
      .g1ff_line_i        (g1ff_line),
      .valid_i            (g1ct_valid),            // G1ct dest-only first beat
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i),   // to back-end
      .g1ex_csr_a0_o      (g1ex_csr_a0)
  );
  assign g1fh_csr_a0_o = g1ex_csr_a0;

endmodule
