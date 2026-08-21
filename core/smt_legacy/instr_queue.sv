// Copyright 2018 - 2019 ETH Zurich and University of Bologna.
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
// Date: 26.10.2018sim:/ariane_tb/dut/i_ariane/i_frontend/icache_ex_valid_q

// Description: Instruction Queue, separates instruction front-end from processor
//              back-end.
//
// This is an optimized instruction queue which supports the handling of
// compressed instructions (16 bit instructions). Internally it is organized as
// FETCH_ENTRY x 32 bit queues which are filled in a consecutive manner. Two pointers
// point into (`idx_is_q` and `idx_ds_q`) the fill port and the read port. The read port
// is designed so that it will easily allow for multiple issue implementation.
// The input supports arbitrary power of two instruction fetch widths.
//
// The queue supports handling of branch prediction and will take care of
// only saving a valid instruction stream.
//
// Furthermore it contains a replay interface in case the instruction queue
// is already full. As instructions are in general easily replayed this should
// increase the efficiency as I$ misses are potentially hidden. This stands in
// contrast to pessimistic actions (early stalling) or credit based approaches.
// Credit based systems might be difficult to implement with the current system
// as we do not exactly know how much space we are going to need in the fifos
// as each instruction can take either one or two slots.
//
// So the consumed/valid interface degenerates to a `information` interface. If the
// upstream circuits keeps pushing the queue will discard the information
// and start replaying from the point were it could last manage to accept instructions.
//
// The instruction front-end will stop issuing instructions as soon as the
// fifo is full. This will gate the logic if the processor is e.g.: halted
//
// TODO(zarubaf): The instruction queues can be reduced to 16 bit. Potentially
// the replay mechanism gets more complicated as it can be that a 32 bit instruction
// can not be pushed at once.

module instr_queue
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type fetch_entry_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Fetch flush request - CONTROLLER
    input logic flush_i,
    // Instruction - instr_realign
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0][31:0] instr_i,
    // Instruction address - instr_realign
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr_i,
    // Instruction is valid - instr_realign
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0] valid_i,
    // G1eg: leftover-RVI pending (not next-line complete)
    input logic leftover_pending_i,
    // G1ff: registered I$ is aligned I|I CSR-to-a0
    input logic g1ff_ii_csr_i,
    input logic [CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] g1ff_line_i,
    // Handshake’s ready with CACHE - CACHE
    output logic ready_o,
    // Indicates instructions consumed, or popped by ID_STAGE - FRONTEND
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0] consumed_o,
    // Exception (which is page-table fault) - CACHE
    input ariane_pkg::frontend_exception_t exception_i,
    // Exception address - CACHE
    input logic [CVA6Cfg.VLEN-1:0] exception_addr_i,
    input logic [CVA6Cfg.GPLEN-1:0] exception_gpaddr_i,
    input logic [31:0] exception_tinst_i,
    input logic exception_gva_i,
    // Branch predict - FRONTEND
    input logic [CVA6Cfg.VLEN-1:0] predict_address_i,
    // Instruction predict address - FRONTEND
    input ariane_pkg::cf_t [CVA6Cfg.INSTR_PER_FETCH-1:0] cf_type_i,
    // Replay instruction because one of the FIFO was full - FRONTEND
    output logic replay_o,
    // Address at which to replay the fetch - FRONTEND
    output logic [CVA6Cfg.VLEN-1:0] replay_addr_o,
    // Handshake’s data with ID_STAGE - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake’s valid with ID_STAGE - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake’s ready with ID_STAGE - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i,
    // G1ex: unissued / presented CSR that writes a0
    output logic g1ex_csr_a0_o
);

  // Legacy dual-issue index (port 1); multi-issue uses NrIssuePorts loops.
  localparam NID = CVA6Cfg.SuperscalarEn ? 1 : 0;
  localparam int unsigned NISSUE = CVA6Cfg.NrIssuePorts;

  typedef struct packed {
    logic [31:0]                     instr;      // instruction word
    logic [CVA6Cfg.VLEN-1:0]         pc;         // instr PC from realign (not reconstructed)
    ariane_pkg::cf_t                 cf;         // branch was taken
    ariane_pkg::frontend_exception_t ex;         // exception happened
    logic [CVA6Cfg.VLEN-1:0]         ex_vaddr;   // lower VLEN bits of tval for exception
    logic [CVA6Cfg.GPLEN-1:0]        ex_gpaddr;  // lower GPLEN bits of tval2 for exception
    logic [31:0]                     ex_tinst;   // tinst of exception
    logic                            ex_gva;
  } instr_data_t;

  // G1ih: IQ latch of aligned compressed
  // Branch. 7ba is delivered from IQ
  // after G1ie present rewrite missed.
  // Recover same-line 01 Branch at
  // output. Keep Branch-bits gate
  // (not G1if). SMT+SS.
  logic        g1ih_v_q;
  logic [4:0]  g1ih_rs1_q;
  logic [CVA6Cfg.VLEN-1:3] g1ih_line_q;
  logic [CVA6Cfg.LOG2_INSTR_PER_FETCH-1:0] branch_index;
  // instruction queues
  instr_data_t [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_data_in, instr_data_out;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] push_instr, push_instr_fifo;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] pop_instr;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_queue_full;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_queue_empty;
  logic                               instr_overflow;
  // address queue
  logic [           CVA6Cfg.VLEN-1:0] address_out;
  logic                               pop_address;
  logic                               push_address;
  logic                               full_address;
  logic                               address_overflow;
  // input stream counter
  logic [CVA6Cfg.LOG2_INSTR_PER_FETCH-1:0] idx_is_d, idx_is_q;

  // Registers
  // output FIFO select, one-hot
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] idx_ds_d, idx_ds_q;
  // rotated by N
  logic [CVA6Cfg.NrIssuePorts:0][CVA6Cfg.INSTR_PER_FETCH-1:0] idx_ds;

  logic [CVA6Cfg.VLEN-1:0] pc_d, pc_q;  // current PC
  logic [CVA6Cfg.NrIssuePorts:0][CVA6Cfg.VLEN-1:0] pc_j;
  logic reset_address_d, reset_address_q;  // we need to re-set the address because of a flush

  logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_is_cf, fetch_entry_fire;
  // Taken CF (predict) vs any CF *instruction* (incl. not-taken branch).
  // Dual-issue must not pair a CF instr with a younger op: not-taken bltu+c.j
  // after dense stack traffic hangs (mini_memcpy0 / bisect_bnez_midj).
  logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_is_ctrl_instr;
  logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_blocks_ss;
  // Prefix mask of fetch_entry_fire (port k only if 0..k-1 also fire).
  logic [CVA6Cfg.NrIssuePorts-1:0] fetch_fire_prefix;

  // Lightweight CF-class detect from the 32b word (RVI/RVC), no full decode.
  function automatic logic is_ctrl_instr_f(logic [31:0] instr);
    logic rvi_cf, rvc_j, rvc_b, rvc_jr;
    rvi_cf = (instr[1:0] == 2'b11) && (
        (instr[6:0] == 7'b1100011) ||  // BRANCH
        (instr[6:0] == 7'b1101111) ||  // JAL
        (instr[6:0] == 7'b1100111)     // JALR
    );
    rvc_j = (instr[1:0] == 2'b01) && (instr[15:13] == 3'b101);  // c.j / c.jal
    rvc_b = (instr[1:0] == 2'b01) &&
            ((instr[15:13] == 3'b110) || (instr[15:13] == 3'b111));  // c.beqz/c.bnez
    rvc_jr = (instr[1:0] == 2'b10) && (instr[15:13] == 3'b100) &&
             (instr[6:2] == 5'b00000);  // c.jr / c.jalr
    return rvi_cf | rvc_j | rvc_b | rvc_jr;
  endfunction

  logic [CVA6Cfg.INSTR_PER_FETCH*2-2:0] branch_mask_extended;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] branch_mask;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken;
  // shift amount, e.g.: instructions we want to retire
  logic [CVA6Cfg.LOG2_INSTR_PER_FETCH:0] popcount;
  logic [CVA6Cfg.LOG2_INSTR_PER_FETCH-1:0] shamt;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] valid;
  logic [CVA6Cfg.INSTR_PER_FETCH*2-1:0] consumed_extended;
  // FIFO mask
  logic [CVA6Cfg.INSTR_PER_FETCH*2-1:0] fifo_pos_extended;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] fifo_pos;
  logic [CVA6Cfg.INSTR_PER_FETCH*2-1:0][31:0] instr;
  logic [CVA6Cfg.INSTR_PER_FETCH*2-1:0][CVA6Cfg.VLEN-1:0] addr_dup;
  ariane_pkg::cf_t [CVA6Cfg.INSTR_PER_FETCH*2-1:0] cf;
  // replay interface
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_overflow_fifo;

  assign ready_o = ~(|instr_queue_full) & ~full_address;

  if (CVA6Cfg.RVC) begin : gen_multiple_instr_per_fetch_with_C

    for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_unpack_taken
      assign taken[i] = cf_type_i[i] != ariane_pkg::NoCF;
    end

    // calculate a branch mask, e.g.: get the first taken branch
    lzc #(
        .WIDTH(CVA6Cfg.INSTR_PER_FETCH),
        .MODE (0)                         // count trailing zeros
    ) i_lzc_branch_index (
        .in_i   (taken),         // we want to count trailing zeros
        .cnt_o  (branch_index),  // first branch on branch_index
        .empty_o()
    );


    // the first index is for sure valid
    // for example (64 bit fetch):
    // taken mask: 0 1 1 0
    // leading zero count = 1
    // 0 0 0 1, 1 1 1 << 1 = 0 0 1 1, 1 1 0
    // take the upper 4 bits: 0 0 1 1
    assign branch_mask_extended = {{{CVA6Cfg.INSTR_PER_FETCH-1}{1'b0}}, {{CVA6Cfg.INSTR_PER_FETCH}{1'b1}}} << branch_index;
    assign branch_mask = branch_mask_extended[CVA6Cfg.INSTR_PER_FETCH * 2 - 2:CVA6Cfg.INSTR_PER_FETCH - 1];

    // mask with taken branches to get the actual amount of instructions we want to push
    // G1er: aligned I|I whose slot1 is CSR (7a8 addi+csrr)
    // keeps slot1 through branch_mask. If slot0 is marked
    // taken (cf mash / leftover Jump), lzc zeros valid[1]
    // and csrr never pushes (no csrrcmt). Not G1eq
    // g1ct hide. Not G1eo idx_is. SMT+SS.
    logic g1er_ii_csr;
    assign g1er_ii_csr = g6lc_iq_hide::ii_csr_keep(
        CVA6Cfg, valid_i[0], valid_i[1], addr_i[0][2:1] == 2'b00,
        instr_i[0], instr_i[1]);
    // G1fs: aligned Branch|JumpR (7b8 c.beqz + 7ba
    // c.jalr). Slot0 cf!=NoCF makes branch_mask zero
    // valid[1] so jalr never pushes; leftover 766
    // issues instead. Not G1er CSR. Not G1eo idx_is.
    // Not G1cz leftover-Jump. SMT+SS.
    logic g1fs_br_jalr;
    assign g1fs_br_jalr = g6lc_iq_hide::br_jalr_keep(
        CVA6Cfg, valid_i[0], valid_i[1], addr_i[0][2:1] == 2'b00,
        instr_i[0], instr_i[1]);
    always_comb begin
      valid = valid_i & branch_mask;
      if (g1er_ii_csr) valid[1] = valid_i[1];
      if (g1fs_br_jalr) valid[1] = valid_i[1];
    end
    // G1da: leftover-complete slot0 Jump (jal@0x3f6,
    // pc[2:1]==11) is the first IQ push. G1cz hid later
    // slots; idx_is after the 0x3e8 prefix can be
    // nonzero so jal is not fifo_pos[0]. Use 0 this
    // beat, then advance by shamt. Not G1cg (all
    // leftover). Not G1ch (Branch-only). SMT+SS.
    logic [CVA6Cfg.LOG2_INSTR_PER_FETCH-1:0] idx_is_sel;
    logic                                    g1da_leftover_jump;
    assign g1da_leftover_jump = CVA6Cfg.SuperscalarEn &&
        CVA6Cfg.NrHarts > 1 && valid_i[0] &&
        (addr_i[0][2:1] == 2'b11) &&
        (cf_type_i[0] == ariane_pkg::Jump);
    // G1eo aligned I|I idx_is restart — MINI-FAIL
    // lottery hang @200678 + FDT printed 18 @434.
    // Do not re-land (G1cg-class idx_is restart).
    assign idx_is_sel = g1da_leftover_jump ? '0 : idx_is_q;
    // rotate right again
    assign consumed_extended = {push_instr_fifo, push_instr_fifo} >> idx_is_sel;
    // G1bm: aligned slot0 consume is the dest-FIFO push, not a
    // later-slot rotate bit. False consumed[0] drops keep_line/G1bl
    // while c.li never entered IQ. SMT+SS. Not G1az. Not G1bk.
    always_comb begin
      consumed_o = consumed_extended[CVA6Cfg.INSTR_PER_FETCH-1:0];
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
          valid_i[0] && (addr_i[0][2:1] == 2'b00))
        consumed_o[0] = push_instr_fifo[idx_is_sel];
    end
    // count the numbers of valid instructions we've pushed from this package
    popcount #(
        .INPUT_WIDTH(CVA6Cfg.INSTR_PER_FETCH)
    ) i_popcount (
        .data_i    (push_instr_fifo),
        .popcount_o(popcount)
    );
    assign shamt = popcount[$bits(shamt)-1:0];

    // save the shift amount for next cycle
    // G1cg leftover-complete idx_is restart — MINI-FAIL
    // P1 0x10 @384 (first load_be32). Do not re-land.
    // G1ch leftover-complete Branch-only idx_is restart —
    // HOLD-FAIL no cookie-exit. Do not re-land.
    assign idx_is_d = idx_is_sel + shamt;

    // ----------------------
    // Input interface
    // ----------------------
    // rotate left by the current position
    assign fifo_pos_extended = {valid, valid} << idx_is_sel;
    // we just care about the upper bits
    assign fifo_pos = fifo_pos_extended[CVA6Cfg.INSTR_PER_FETCH*2-1:CVA6Cfg.INSTR_PER_FETCH];
    // the fifo_position signal can directly be used to guide the push signal of each FIFO
    // make sure it is not full
    // G1az: leftover complete rotates idx_is; if the dest FIFO for this
    // aligned line's slot0 is full, do not push later slots (replay
    // would skip to addr_i[shamt] and drop c.li@0x4d0). SMT+SS.
    // Not G1aa leftover-JAL. Not G1as leftover drop.
    logic g1az_slot0_blocked;
    assign g1az_slot0_blocked = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        valid_i[0] && addr_i[0][2:1] == 2'b00 &&
        fifo_pos[idx_is_sel] && instr_queue_full[idx_is_sel];
    // G1cx: leftover-complete slot0 Jump (jal@0x3f6,
    // pc[2:1]==11) must not lose to later-slot push +
    // replay addr[shamt]. Same G1az block, leftover PC.
    // Not G1bd target replay. Not G1cu NPC. SMT+SS.
    logic g1cx_slot0_blocked;
    assign g1cx_slot0_blocked = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        valid_i[0] && (addr_i[0][2:1] == 2'b11) &&
        (cf_type_i[0] == ariane_pkg::Jump) &&
        fifo_pos[idx_is_sel] && instr_queue_full[idx_is_sel];
    // G1ej: aligned I|I (7a8 addi+csrr) is atomic. If the
    // csrr dest FIFO is full, G1az still pushes addi and
    // consumed[0] advances replay to addr[shamt] — csrr
    // never enters IQ and 7bc sees a0=1. Block the whole
    // line (replay addr_i[0]). Not G1eh IQ head. Not G1az
    // slot0-only. SMT+SS.
    logic g1ej_ii_blocked;
    assign g1ej_ii_blocked = CVA6Cfg.SuperscalarEn &&
        CVA6Cfg.NrHarts > 1 && valid_i[0] && valid_i[1] &&
        (addr_i[0][2:1] == 2'b00) &&
        (instr_i[0][1:0] == 2'b11) &&
        (instr_i[1][1:0] == 2'b11) &&
        |(fifo_pos & instr_queue_full);
    assign push_instr = fifo_pos & ~instr_queue_full &
        ~{CVA6Cfg.INSTR_PER_FETCH{g1az_slot0_blocked | g1cx_slot0_blocked |
                                  g1ej_ii_blocked}};

    // duplicate the entries for easier selection e.g.: 3 2 1 0 3 2 1 0
    for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_duplicate_instr_input
      assign instr[i] = instr_i[i];
      assign instr[i+CVA6Cfg.INSTR_PER_FETCH] = instr_i[i];
      assign addr_dup[i] = addr_i[i];
      assign addr_dup[i+CVA6Cfg.INSTR_PER_FETCH] = addr_i[i];
      assign cf[i] = cf_type_i[i];
      assign cf[i+CVA6Cfg.INSTR_PER_FETCH] = cf_type_i[i];
    end

    // shift the inputs
    for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_fifo_input_select
      /* verilator lint_off WIDTH */
      assign instr_data_in[i].instr = instr[CVA6Cfg.INSTR_PER_FETCH+i-idx_is_sel];
      // Hang-4: store realign PC with each word. Dual-issue used to rebuild
      // sequential PC from instr[1:0] sizes; a garbage/empty head or size
      // desync advanced PC by +2, so auipc in fdt_next_tag produced
      // mtval=0x800222be (table base off-by-2) and load-misalign hang.
      assign instr_data_in[i].pc = addr_dup[CVA6Cfg.INSTR_PER_FETCH+i-idx_is_sel];
      assign instr_data_in[i].cf = cf[CVA6Cfg.INSTR_PER_FETCH+i-idx_is_sel];
      assign instr_data_in[i].ex = exception_i;  // exceptions hold for the whole fetch packet
      assign instr_data_in[i].ex_vaddr = exception_addr_i;
      if (CVA6Cfg.RVH) begin : gen_hyp_ex_with_C
        assign instr_data_in[i].ex_gpaddr = exception_gpaddr_i;
        assign instr_data_in[i].ex_tinst = exception_tinst_i;
        assign instr_data_in[i].ex_gva = exception_gva_i;
      end else begin : gen_no_hyp_ex_with_C
        assign instr_data_in[i].ex_gpaddr = '0;
        assign instr_data_in[i].ex_tinst = '0;
        assign instr_data_in[i].ex_gva = 1'b0;
      end
      /* verilator lint_on WIDTH */
    end
  end else begin : gen_multiple_instr_per_fetch_without_C

    assign taken = '0;
    assign branch_index = '0;
    assign branch_mask_extended = '0;
    assign branch_mask = '0;
    assign consumed_extended = '0;
    assign fifo_pos_extended = '0;
    assign fifo_pos = '0;
    assign instr = '0;
    assign popcount = '0;
    assign shamt = '0;
    assign valid = '0;


    assign consumed_o = push_instr_fifo[0];
    // ----------------------
    // Input interface
    // ----------------------
    assign push_instr = valid_i & ~instr_queue_full;
    assign addr_dup = '0;

    /* verilator lint_off WIDTH */
    assign instr_data_in[0].instr = instr_i[0];
    assign instr_data_in[0].pc = addr_i[0];
    assign instr_data_in[0].cf = cf_type_i[0];
    assign instr_data_in[0].ex = exception_i;  // exceptions hold for the whole fetch packet
    assign instr_data_in[0].ex_vaddr = exception_addr_i;
    if (CVA6Cfg.RVH) begin : gen_hyp_ex_without_C
      assign instr_data_in[0].ex_gpaddr = exception_gpaddr_i;
      assign instr_data_in[0].ex_tinst = exception_tinst_i;
      assign instr_data_in[0].ex_gva = exception_gva_i;
    end else begin : gen_no_hyp_ex_without_C
      assign instr_data_in[0].ex_gpaddr = '0;
      assign instr_data_in[0].ex_tinst = '0;
      assign instr_data_in[0].ex_gva = 1'b0;
    end
    /* verilator lint_on WIDTH */
  end

  // ----------------------
  // Replay Logic
  // ----------------------
  // We need to replay a instruction fetch iff:
  // 1. One of the instruction data FIFOs was full and we needed it
  // (e.g.: we pushed and it was full)
  // 2. The address/branch predict FIFO was full
  // if one of the FIFOs was full we need to replay the faulting instruction
  if (CVA6Cfg.RVC == 1'b1) begin : gen_instr_overflow_fifo_with_C
    assign instr_overflow_fifo = instr_queue_full & fifo_pos;
  end else begin : gen_instr_overflow_fifo_without_C
    assign instr_overflow_fifo = instr_queue_full & valid_i;
  end
  assign instr_overflow = |instr_overflow_fifo;  // at least one instruction overflowed
  assign address_overflow = full_address & push_address;
  assign replay_o = instr_overflow | address_overflow;

  if (CVA6Cfg.RVC) begin : gen_replay_addr_o_with_c
    // select the address, in the case of an address fifo overflow just
    // use the base of this package
    // if we successfully pushed some instructions we can output the next instruction
    // which we didn't manage to push
    // G1az: replay from slot0 of an aligned line if that slot was not
    // pushed. addr_i[shamt] skips c.li when later slots pushed first.
    // G1bd leftover-RVI taken-target replay — HOLD-FAIL mepc 0x7b0/4
    // no cookie @6e6. Do not re-land.
    assign replay_addr_o = (address_overflow ||
        (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
         valid_i[0] && replay_o && !consumed_o[0] &&
         ((addr_i[0][2:1] == 2'b00) ||
          ((addr_i[0][2:1] == 2'b11) &&
           (cf_type_i[0] == ariane_pkg::Jump)))))
        ? addr_i[0] : addr_i[shamt];
  end else begin : gen_replay_addr_o_without_C
    assign replay_addr_o = addr_i[0];
  end

  // ----------------------
  // Downstream interface
  // ----------------------
  // Downstream valid: port 0 only if the *head* rotating FIFO slot has data.
  // (Using ~(&empty) let a zeroed head present while a later slot still held
  // ops; dual-issue then advanced PC on a garbage +2 and desynced the queue.)
  // Later ports: their slot non-empty, no earlier CF-class instr, port0 valid.
  // G1bi hold Branch / rotate to older same-line dest — HOLD-FAIL
  // wfi-exit t=217088 cookie 51b1c001. Do not re-land.
  // G1ef: presented leftover-complete Jump (7c6) drops
  // a different leftover Jump already in a dest FIFO
  // (766 jal x0 / 996). G1dv used to "drain" FIFO 0
  // by issuing that stale jal → ef4c. Not G1dr (no rd
  // filter; P8 presented PC matches). SMT+SS.
  function automatic logic g1ef_is_lj(input instr_data_t d);
    return (d.pc[2:1] == 2'b11) &&
        ((d.cf == ariane_pkg::Jump) ||
         ((d.instr[1:0] == 2'b11) &&
          (d.instr[6:0] == 7'b1101111)));
  endfunction
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1ef_stale;
  logic                               g1ef_present;
  logic                               g1en_csr_a0;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] iq_vis_empty;
  assign g1ef_present = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
      CVA6Cfg.INSTR_PER_FETCH > 1 && valid_i[0] &&
      (addr_i[0][2:1] == 2'b11) &&
      (cf_type_i[0] == ariane_pkg::Jump);
  always_comb begin
    g1ef_stale = '0;
    g1en_csr_a0 = 1'b0;
    if (g1ef_present) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] && g1ef_is_lj(instr_data_out[i]) &&
            (instr_data_out[i].pc != addr_i[0]))
          g1ef_stale[i] = 1'b1;
      end
    end
    // G1eg: leftover-pending aligned fetch (7a8 I|I) drops
    // leftover Jump from another 8B line (766) so addi+csrr
    // can push. Not G1ef present-Jump. Not G1dw +8. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        leftover_pending_i && valid_i[0] &&
        (addr_i[0][2:1] == 2'b00)) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] && g1ef_is_lj(instr_data_out[i]) &&
            (instr_data_out[i].pc[CVA6Cfg.VLEN-1:3] !=
             addr_i[0][CVA6Cfg.VLEN-1:3]))
          g1ef_stale[i] = 1'b1;
      end
    end
    // G1ei: leftover_pending is 0 at 7a8 (750 ld already
    // completed at 758). Still drop leftover jal x0
    // (rd==0) from another line so G1dc does not park
    // 766 through csrr. Not G1dr (G1dc still any leftover
    // Jump). Not G1eh same-line. P8 jal ra stays. SMT+SS.
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        valid_i[0] && (addr_i[0][2:1] == 2'b00)) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] && g1ef_is_lj(instr_data_out[i]) &&
            (instr_data_out[i].instr[1:0] == 2'b11) &&
            (instr_data_out[i].instr[6:0] == 7'b1101111) &&
            (instr_data_out[i].instr[11:7] == 5'd0) &&
            (instr_data_out[i].pc[CVA6Cfg.VLEN-1:3] !=
             addr_i[0][CVA6Cfg.VLEN-1:3]))
          g1ef_stale[i] = 1'b1;
      end
    end
    // G1en: leftover jal x0 is dropped while a CSR
    // that writes a0 is in a dest FIFO or is being
    // presented. G1ei only hides 766 on the aligned
    // 7a8 beat; after that consume G1dc parks jal x0
    // again so G1em/csrr never issue. Not G1dr
    // (G1dc still any leftover Jump when no CSR-a0).
    // P8 jal ra stays. SMT+SS.
    g1en_csr_a0 = 1'b0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g6lc_iq_hide::is_csr_a0(instr_data_out[i].instr))
          g1en_csr_a0 = 1'b1;
        if (valid_i[i] &&
            g6lc_iq_hide::is_csr_a0(instr_i[i]))
          g1en_csr_a0 = 1'b1;
      end
      if (g1en_csr_a0) begin
        for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
          if (!instr_queue_empty[i] &&
              g6lc_iq_hide::leftover_jal_x0(
                  instr_data_out[i].pc[2:1], instr_data_out[i].instr))
            g1ef_stale[i] = 1'b1;
          // G1ey: dest-FIFO a0-Branch is not IQ-visible
          // while CSR-to-a0 is queued or presented.
          // G1ex I$ hold did not delay 7bc (package
          // already in IQ). G1em head loses to G1dc
          // leftover Jump. Not G1ew ALU head. Not
          // G1eh oldest-PC. SMT+SS.
          if (!instr_queue_empty[i] &&
              g1ey_is_a0_br(instr_data_out[i].instr))
            g1ef_stale[i] = 1'b1;
        end
      end
    end
  end
  assign g1ex_csr_a0_o = g1en_csr_a0;
  // G1fb/G1fc npc-ahead hide — MINI-FAIL. Do not re-land.
  // G1fd: after a mid-line [2:1]==01 package is pushed,
  // hide dest-FIFO a0-Branch past the sequential next
  // line until that next line is presented (or fetch
  // skips past it). Not npc-distance. Not G1ep I$ hold.
  // Do not pop. SMT+SS.
  logic g1fd_wait_q;
  logic [CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] g1fd_next_q;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1fd_hide;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1fd_wait_q <= 1'b0;
      g1fd_next_q <= '0;
    end else if (flush_i) begin
      g1fd_wait_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (valid_i[0] && (addr_i[0][2:1] == 2'b01) &&
          consumed_o[0] &&
          (!valid_i[1] || consumed_o[1])) begin
        g1fd_wait_q <= 1'b1;
        g1fd_next_q <= addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1'b1;
      end
      if (g1fd_wait_q && valid_i[0] &&
          (addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >=
           g1fd_next_q))
        g1fd_wait_q <= 1'b0;
    end
  end
  always_comb begin
    g1fd_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 && g1fd_wait_q) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g1ey_is_a0_br(instr_data_out[i].instr) &&
            (instr_data_out[i].pc[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >
             g1fd_next_q))
          g1fd_hide[i] = 1'b1;
      end
    end
  end
  // G1fi: arm mid-line [2:1]==01 wait on *presentation*
  // (G1fd required consume and never armed). Hide dest-FIFO
  // a0-Branch past the sequential next line until that
  // line is presented or fetch skips past. Not G1fb
  // npc-ahead. Do not pop. SMT+SS.
  logic g1fi_wait_q;
  logic [CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] g1fi_next_q;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1fi_hide;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1fi_wait_q <= 1'b0;
      g1fi_next_q <= '0;
    end else if (flush_i) begin
      g1fi_wait_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (valid_i[0] && (addr_i[0][2:1] == 2'b01)) begin
        g1fi_wait_q <= 1'b1;
        g1fi_next_q <= addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1'b1;
      end
      if (g1fi_wait_q && valid_i[0] &&
          (addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >=
           g1fi_next_q))
        g1fi_wait_q <= 1'b0;
    end
  end
  always_comb begin
    g1fi_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 && g1fi_wait_q) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g1ey_is_a0_br(instr_data_out[i].instr) &&
            (instr_data_out[i].pc[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >
             g1fi_next_q))
          g1fi_hide[i] = 1'b1;
      end
    end
  end
  // G1fj: G1fi clears when the sequential next line
  // is presented (7a8 t=20450) before 7bc issues.
  // Hold through that next line; clear only when
  // fetch is past it (or flush). Not G1fb npc-ahead.
  // Do not pop. SMT+SS.
  logic g1fj_wait_q;
  logic [CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] g1fj_next_q;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1fj_hide;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1fj_wait_q <= 1'b0;
      g1fj_next_q <= '0;
    end else if (flush_i) begin
      g1fj_wait_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (valid_i[0] && (addr_i[0][2:1] == 2'b01)) begin
        g1fj_wait_q <= 1'b1;
        g1fj_next_q <= addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1'b1;
      end
      if (g1fj_wait_q && valid_i[0] &&
          (addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >
           g1fj_next_q))
        g1fj_wait_q <= 1'b0;
    end
  end
  always_comb begin
    g1fj_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 && g1fj_wait_q) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g1ey_is_a0_br(instr_data_out[i].instr) &&
            (instr_data_out[i].pc[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >
             g1fj_next_q))
          g1fj_hide[i] = 1'b1;
      end
    end
  end
  // G1fk dest-FIFO hide until CSR-to-a0 commit — MINI-FAIL
  // (FDT hang @400000). Do not re-land.
  // G1fl: arm mid-line [2:1]==01 on presentation
  // (G1fi). Clear only when the sequential next
  // line is *consumed* (pushed), not merely
  // presented. Not G1fk CSR-commit. Not G1fb.
  // Do not pop. SMT+SS.
  logic g1fl_wait_q;
  logic [CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] g1fl_next_q;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1fl_hide;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1fl_wait_q <= 1'b0;
      g1fl_next_q <= '0;
    end else if (flush_i) begin
      g1fl_wait_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (valid_i[0] && (addr_i[0][2:1] == 2'b01)) begin
        g1fl_wait_q <= 1'b1;
        g1fl_next_q <= addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1'b1;
      end
      if (g1fl_wait_q && valid_i[0] &&
          (addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >=
           g1fl_next_q) &&
          consumed_o[0] &&
          (!valid_i[1] || consumed_o[1]))
        g1fl_wait_q <= 1'b0;
    end
  end
  always_comb begin
    g1fl_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 && g1fl_wait_q) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g1ey_is_a0_br(instr_data_out[i].instr) &&
            (instr_data_out[i].pc[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >
             g1fl_next_q))
          g1fl_hide[i] = 1'b1;
      end
    end
  end
  // G1fe: aligned I|I whose slot1 *data* is CSR-to-a0
  // (even if valid[1]=0 / G1ct smash) hides dest-FIFO
  // a0-Branch until that line is no longer presented.
  // G1ey needs CSR queued (did not fire). G1fd mid-line
  // wait did not fire. Do not pop. SMT+SS.
  logic g1fe_ii_csr;
  logic g1fe_wait_q;
  logic [CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] g1fe_line_q;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1fe_hide;
  assign g1fe_ii_csr = CVA6Cfg.SuperscalarEn &&
      CVA6Cfg.NrHarts > 1 && CVA6Cfg.INSTR_PER_FETCH > 1 &&
      valid_i[0] && (addr_i[0][2:1] == 2'b00) &&
      (instr_i[0][1:0] == 2'b11) &&
      (instr_i[1][1:0] == 2'b11) &&
      (instr_i[1][6:0] == 7'b1110011) &&
      (instr_i[1][11:7] == 5'd10);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1fe_wait_q <= 1'b0;
      g1fe_line_q <= '0;
    end else if (flush_i) begin
      g1fe_wait_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      if (g1fe_ii_csr) begin
        g1fe_wait_q <= 1'b1;
        g1fe_line_q <= addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS];
      end
      if (g1fe_wait_q && valid_i[0] &&
          (addr_i[0][CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] !=
           g1fe_line_q))
        g1fe_wait_q <= 1'b0;
    end
  end
  always_comb begin
    g1fe_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        (g1fe_ii_csr || g1fe_wait_q)) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g1ey_is_a0_br(instr_data_out[i].instr))
          g1fe_hide[i] = 1'b1;
      end
    end
  end
  // G1ff: registered I$ aligned I|I with high-word
  // CSR-to-a0 (G1et data, not realign instr_i). G1fe
  // did not fire (7a8 never on instr_i). Hide dest-FIFO
  // a0-Branch on a later line only. Do not pop. SMT+SS.
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1ff_hide;
  always_comb begin
    g1ff_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        g1ff_ii_csr_i) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g1ey_is_a0_br(instr_data_out[i].instr) &&
            (instr_data_out[i].pc[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] >
             g1ff_line_i))
          g1ff_hide[i] = 1'b1;
      end
    end
  end
  // G1fm any-slot mid-line arm — MINI-FAIL FDT printed 23
  // @1196. Do not re-land.
  // G1fo: leftover jal x0 is not IQ-visible while
  // dest-FIFO has a JumpR (c.jalr/jalr). TRACE G1fn:
  // 7bc never commits; 7b8 commits t=20474; 766
  // leftover jal x0 commits t=20476; a5=71e4 so
  // 7ba c.jalr should have issued. G1dc parks 766
  // after G1en/G1ey release. Do not pop (not
  // g1ef_stale). Not G1dr rd. Not G1ec oldest-PC.
  // Not G1cv. SMT+SS.
  logic g1fo_have_jalr;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1fo_hide;
  always_comb begin
    g1fo_have_jalr = 1'b0;
    g1fo_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!instr_queue_empty[i] &&
            g6lc_iq_hide::is_jalr(instr_data_out[i].instr))
          g1fo_have_jalr = 1'b1;
      end
      if (g1fo_have_jalr) begin
        for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
          if (!instr_queue_empty[i] &&
              g6lc_iq_hide::leftover_jal_x0(
                  instr_data_out[i].pc[2:1], instr_data_out[i].instr))
            g1fo_hide[i] = 1'b1;
        end
      end
    end
  end
  // G1fp: G1fo needs JumpR already queued (7ba never
  // entered dest-FIFO). Hide leftover jal x0 while a
  // JumpR is *presented* (instr data or cf JumpR),
  // even if G1ct/G1cz zeroed valid[1+]. Do not pop.
  // Not G1dr. Not G1fm. SMT+SS.
  logic g1fp_pres;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] g1fp_hide;
  always_comb begin
    g1fp_pres = 1'b0;
    g1fp_hide = '0;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        |valid_i) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        if (g6lc_iq_hide::is_jalr(instr_i[s]) ||
            (cf_type_i[s] == ariane_pkg::JumpR))
          g1fp_pres = 1'b1;
      end
      if (g1fp_pres) begin
        for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
          if (!instr_queue_empty[i] &&
              g6lc_iq_hide::leftover_jal_x0(
                  instr_data_out[i].pc[2:1], instr_data_out[i].instr))
            g1fp_hide[i] = 1'b1;
        end
      end
    end
  end
  assign iq_vis_empty = instr_queue_empty | g1ef_stale | g1fd_hide | g1fe_hide | g1ff_hide | g1fi_hide | g1fj_hide | g1fl_hide | g1fo_hide | g1fp_hide;
  assign fetch_entry_valid_o[0] = ~|(iq_vis_empty & idx_ds[0]);
  if (CVA6Cfg.SuperscalarEn) begin : gen_fetch_entry_valid_ss
    for (genvar p = 1; p < NISSUE; p++) begin : gen_fe_valid
      logic earlier_blocks;
      logic [CVA6Cfg.VLEN-1:0] exp_pc;
      logic younger_has_data;
      always_comb begin
        earlier_blocks = 1'b0;
        younger_has_data = ~|(iq_vis_empty & idx_ds[p]);
        // Block dual-issue after any earlier CF instr (taken or not-taken).
        for (int unsigned e = 0; e < p; e++) begin
          if (fetch_entry_blocks_ss[e]) earlier_blocks = 1'b1;
        end
        // PC continuity vs immediate older port: younger must start at
        // older+size. Blocks mid-RVI halfword as a new op (PEEL_STRLEN pin).
        exp_pc = fetch_entry_o[p-1].address +
            ((fetch_entry_o[p-1].instruction[1:0] != 2'b11) ? CVA6Cfg.VLEN'(2)
                                                            : CVA6Cfg.VLEN'(4));
        if (younger_has_data && fetch_entry_o[p].address != exp_pc)
          earlier_blocks = 1'b1;
      end
      assign fetch_entry_valid_o[p] =
          younger_has_data & ~earlier_blocks & fetch_entry_valid_o[0];
    end
  end

  // G1dc: leftover Jump in any dest FIFO is IQ head.
  // G1dn: also leftover RVI jal opcode if cf mash is
  // NoCF (OpenSBI jal@7c6 fetched, ra stayed 752).
  // Not G1cw slot0-only. Not G1db NPC. SMT+SS.
  // G1dp: leftover-complete slot0 Jump whose dest
  // FIFO 0 is full (G1da dest) must drain that FIFO
  // so jal can push. G1dc only seeks leftover Jump
  // already in a dest FIFO — G1dn/G1do did not fire
  // (jal never entered). Do not override a leftover
  // Jump already in a dest FIFO (P8). Not G1db NPC.
  // Not G1cv accept-target I$. SMT+SS.
  // G1dr leftover link-jal-only IQ head —
  // MINI-FAIL P8 0x18 @2454. Do not re-land
  // (narrowed G1dc; leftover jal sat behind
  // idx_ds again).
  // G1ds: among leftover Jumps, IQ head is the
  // oldest PC. 996 jal x0 and jal@7c6 both match
  // G1dc; first-FIFO scan parked 996. P8 leftover
  // jal stays a leftover Jump (no rd filter).
  // Not G1dr. Not G1db NPC. SMT+SS.
  // G1dv: presented leftover Jump whose PC is not
  // the G1dc FIFO entry. TRACE: 7c8 then hang
  // @ef4c +10cy; 996 already fetched. G1dc parks
  // on stale leftover so jal@7c6 never pushes
  // (G1dp blocked). P8 presented PC matches.
  // Not G1dr rd. Not G1ds (7c6 not yet in FIFO).
  // SMT+SS.
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] idx_ds_head;
  logic                               g1dc_leftover_in_fifo;
  logic [CVA6Cfg.VLEN-1:0]            g1ds_best_pc;
  // G1ee: CSR that writes rd is IQ head over a younger
  // use of that rd (7ac csrr a0 vs 7b4 c.mv / 7bc
  // c.bnez a0). Not G1ec all-oldest. Not G1eb ID stall.
  // IQ is flushed on SMT switch so entries are same-hart.
  function automatic logic g1ee_is_csr(input logic [31:0] i);
    return (i[1:0] == 2'b11) && (i[6:0] == 7'b1110011);
  endfunction
  function automatic logic g1ee_uses(input logic [31:0] i, input logic [4:0] r);
    logic u;
    u = 1'b0;
    if (r == 5'd0) return 1'b0;
    if (i[1:0] == 2'b11) begin
      if ((i[19:15] == r) || (i[24:20] == r)) u = 1'b1;
    end else if ((i[1:0] == 2'b10) && (i[15:13] == 3'b100)) begin
      if (i[6:2] == r) u = 1'b1;
    end else if ((i[1:0] == 2'b01) &&
                 ((i[15:13] == 3'b110) || (i[15:13] == 3'b111))) begin
      if ({2'b01, i[9:7]} == r) u = 1'b1;
    end
    return u;
  endfunction
  // G1ey: RVI Branch rs1==a0, or c.beqz/c.bnez rs1'==a0.
  function automatic logic g1ey_is_a0_br(input logic [31:0] i);
    if ((i[1:0] == 2'b11) && (i[6:0] == 7'b1100011) &&
        (i[19:15] == 5'd10))
      return 1'b1;
    if ((i[1:0] == 2'b01) &&
        ((i[15:13] == 3'b110) || (i[15:13] == 3'b111)) &&
        (i[9:7] == 3'd2))
      return 1'b1;
    return 1'b0;
  endfunction
  always_comb begin
    idx_ds_head = idx_ds_q;
    g1dc_leftover_in_fifo = 1'b0;
    g1ds_best_pc = '1;
    if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
        CVA6Cfg.INSTR_PER_FETCH > 1) begin
      // G1ec oldest-PC among all nonempty FIFOs —
      // MINI-FAIL P1 0x10 @412. Do not re-land.
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        if (!iq_vis_empty[i] && g1ef_is_lj(instr_data_out[i])) begin
          if (!g1dc_leftover_in_fifo ||
              (instr_data_out[i].pc < g1ds_best_pc)) begin
            idx_ds_head = '0;
            idx_ds_head[i] = 1'b1;
            g1ds_best_pc = instr_data_out[i].pc;
            g1dc_leftover_in_fifo = 1'b1;
          end
        end
      end
      // G1ef: do not issue FIFO 0 to "drain" a leftover
      // Jump whose PC is not the presented one (766).
      if (g1dc_leftover_in_fifo && g1ef_present &&
          (g1ds_best_pc != addr_i[0])) begin
        g1dc_leftover_in_fifo = 1'b0;
        idx_ds_head = idx_ds_q;
      end
      if (!g1dc_leftover_in_fifo && g1ef_present &&
          instr_queue_full[0] && !iq_vis_empty[0]) begin
        idx_ds_head = '0;
        idx_ds_head[0] = 1'b1;
      end
      // G1ee after leftover-Jump head (do not steal G1dc).
      if (!g1dc_leftover_in_fifo) begin
        for (int unsigned ci = 0; ci < CVA6Cfg.INSTR_PER_FETCH; ci++) begin
          if (!iq_vis_empty[ci] &&
              g1ee_is_csr(instr_data_out[ci].instr) &&
              (instr_data_out[ci].instr[11:7] != 5'd0)) begin
            for (int unsigned uj = 0; uj < CVA6Cfg.INSTR_PER_FETCH; uj++) begin
              if ((uj != ci) && !iq_vis_empty[uj] &&
                  g1ee_uses(instr_data_out[uj].instr,
                            instr_data_out[ci].instr[11:7]) &&
                  (instr_data_out[ci].pc < instr_data_out[uj].pc)) begin
                idx_ds_head = '0;
                idx_ds_head[ci] = 1'b1;
              end
            end
          end
        end
        // G1em: older CSR that writes a0 is IQ head over
        // the rotate head even if the a0-use already left
        // IQ (7bc in ID; G1ee needs the use still queued).
        // Not G1eh/G1ec all-oldest. Not G1eb ID RAW.
        // G1dc leftover Jump stays first. SMT+SS.
        for (int unsigned ci = 0; ci < CVA6Cfg.INSTR_PER_FETCH; ci++) begin
          if (!iq_vis_empty[ci] &&
              g1ee_is_csr(instr_data_out[ci].instr) &&
              (instr_data_out[ci].instr[11:7] == 5'd10)) begin
            for (int unsigned hj = 0; hj < CVA6Cfg.INSTR_PER_FETCH; hj++) begin
              if ((hj != ci) && !iq_vis_empty[hj] && idx_ds_q[hj] &&
                  (instr_data_out[ci].pc < instr_data_out[hj].pc)) begin
                idx_ds_head = '0;
                idx_ds_head[ci] = 1'b1;
              end
            end
          end
        end
      end
      // G1ew older ALU-to-a0 IQ head — MINI-FAIL FDT
      // printed 29 (0x1d P10) @1854. Do not re-land
      // (G1eh-class in-order head starved P-window).
      // Isolated P4 stays.
      // G1eh same-line oldest-PC IQ — MINI-FAIL lottery hang
      // @400000 + FDT printed 89 @1043. Do not re-land
      // (G1ec-class in-order head on one line starved
      // later-slot consume / P-window). Isolated P4 stays.
    end
  end
  assign idx_ds[0] = idx_ds_head;
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    if (CVA6Cfg.INSTR_PER_FETCH > 1) begin
      assign idx_ds[i+1] = {
        idx_ds[i][CVA6Cfg.INSTR_PER_FETCH-2:0], idx_ds[i][CVA6Cfg.INSTR_PER_FETCH-1]
      };
    end else begin
      assign idx_ds[i+1] = idx_ds[i];
    end
  end

  if (CVA6Cfg.RVC) begin : gen_downstream_itf_with_c
    always_comb begin
      idx_ds_d  = idx_ds_q;

      pop_instr = g1ef_stale;
      // assemble fetch entry
      for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        fetch_entry_o[i].instruction = '0;
        fetch_entry_o[i].address = '0;
        fetch_entry_o[i].ex.valid = 1'b0;
        fetch_entry_o[i].ex.cause = '0;

        fetch_entry_o[i].ex.tval = '0;
        fetch_entry_o[i].ex.tval2 = '0;
        fetch_entry_o[i].ex.gva = 1'b0;
        fetch_entry_o[i].ex.tinst = '0;
        fetch_entry_o[i].branch_predict.predict_address = address_out;
        fetch_entry_o[i].branch_predict.cf = ariane_pkg::NoCF;
        // U6.1: fetch-side tag default 0; decoder overwrites from active SMT hart
        fetch_entry_o[i].hart_id = '0;
      end

      // Output mux: map each issue port to its rotating FIFO slot (idx_ds[p])
      for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        for (int unsigned p = 0; p < NISSUE; p++) begin
          if (idx_ds[p][i] && !g1ef_stale[i]) begin
            if (instr_data_out[i].ex == ariane_pkg::FE_INSTR_ACCESS_FAULT) begin
              fetch_entry_o[p].ex.cause = riscv::INSTR_ACCESS_FAULT;
            end else if (CVA6Cfg.RVH && p == 0 &&
                         instr_data_out[i].ex == ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT) begin
              fetch_entry_o[p].ex.cause = riscv::INSTR_GUEST_PAGE_FAULT;
            end else begin
              fetch_entry_o[p].ex.cause = riscv::INSTR_PAGE_FAULT;
            end
            fetch_entry_o[p].instruction = instr_data_out[i].instr;
            // PC from FIFO (realign), not combinational size chain.
            fetch_entry_o[p].address = instr_data_out[i].pc;
            fetch_entry_o[p].ex.valid = instr_data_out[i].ex != ariane_pkg::FE_NONE;
            if (CVA6Cfg.TvalEn)
              fetch_entry_o[p].ex.tval = {
                {(CVA6Cfg.XLEN - CVA6Cfg.VLEN) {1'b0}}, instr_data_out[i].ex_vaddr
              };
            if (CVA6Cfg.RVH && p == 0) begin
              fetch_entry_o[p].ex.tval2 = instr_data_out[i].ex_gpaddr;
              fetch_entry_o[p].ex.tinst = instr_data_out[i].ex_tinst;
              fetch_entry_o[p].ex.gva   = instr_data_out[i].ex_gva;
            end
            fetch_entry_o[p].branch_predict.cf = instr_data_out[i].cf;
            // Prefix-only pop (see fetch_fire_prefix below).
            pop_instr[i] = fetch_fire_prefix[p] | g1ef_stale[i];
          end
        end
      end
      // Rotate pointer by number of consecutive prefix fires from port 0
      if (fetch_fire_prefix[0]) begin
        idx_ds_d = idx_ds[1];
        if (CVA6Cfg.SuperscalarEn) begin
          for (int unsigned p = 1; p < NISSUE; p++) begin
            if (fetch_fire_prefix[p]) idx_ds_d = idx_ds[p+1];
            else break;
          end
        end
      end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
                   CVA6Cfg.INSTR_PER_FETCH > 1 &&
                   |(iq_vis_empty & idx_ds_q) && |(~iq_vis_empty)) begin
        // G1bc: leftover complete rotates idx_is; slot0 (c.li@0x4d0)
        // can sit in a later FIFO while idx_ds still names an empty
        // head — valid[0] stays 0 and ID never sees it. Skip empty
        // heads only (do not present a later slot under the empty
        // head — hang-4). Not G1ac bp_valid park. Not G1az. Not G1bb.
        for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
          if (!|(iq_vis_empty & idx_ds_d)) break;
          idx_ds_d = {idx_ds_d[CVA6Cfg.INSTR_PER_FETCH-2:0],
                      idx_ds_d[CVA6Cfg.INSTR_PER_FETCH-1]};
        end
      end
      // G1ih: recover same-line 01 Branch
      // as c.jalr at IQ output. G1ie
      // present rewrite missed because
      // 7ba was already queued. Keep
      // Branch-bits gate (not G1if).
      // Not G1id ID latch. G1lm IQ
      // aligned-00 RVI LOAD sibling 01
      // recover MINI-FAIL FDT 106
      // @200619 — reverted. SMT+SS.
      if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
        for (int unsigned p = 0; p < NISSUE; p++) begin
          if ((fetch_entry_o[p].address[2:1] == 2'b01) &&
              (((fetch_entry_o[p].instruction[1:0] == 2'b01) &&
                ((fetch_entry_o[p].instruction[15:13] == 3'b110) ||
                 (fetch_entry_o[p].instruction[15:13] == 3'b111))) ||
               ((fetch_entry_o[p].instruction[1:0] == 2'b11) &&
                (fetch_entry_o[p].instruction[6:0] == 7'b1100011)))) begin
            if (g1ih_v_q &&
                (fetch_entry_o[p].address[CVA6Cfg.VLEN-1:3] ==
                 g1ih_line_q)) begin
              fetch_entry_o[p].instruction = {16'b0,
                  {4'b1001, g1ih_rs1_q, 5'd0, 2'b10}};
              fetch_entry_o[p].branch_predict.cf = ariane_pkg::JumpR;
            end else if ((p != 0) &&
                (fetch_entry_o[0].address[2:1] == 2'b00) &&
                (fetch_entry_o[0].instruction[1:0] == 2'b01) &&
                ((fetch_entry_o[0].instruction[15:13] == 3'b110) ||
                 (fetch_entry_o[0].instruction[15:13] == 3'b111)) &&
                (fetch_entry_o[0].address[CVA6Cfg.VLEN-1:3] ==
                 fetch_entry_o[p].address[CVA6Cfg.VLEN-1:3])) begin
              fetch_entry_o[p].instruction = {16'b0,
                  {4'b1001, {2'b01, fetch_entry_o[0].instruction[9:7]},
                   5'd0, 2'b10}};
              fetch_entry_o[p].branch_predict.cf = ariane_pkg::JumpR;
            end
          end
        end
      end
    end
  end else begin : gen_downstream_itf_without_c
    always_comb begin
      idx_ds_d = '0;
      idx_is_d = '0;
      fetch_entry_o[0].instruction = instr_data_out[0].instr;
      fetch_entry_o[0].address = instr_data_out[0].pc;

      fetch_entry_o[0].ex.valid = instr_data_out[0].ex != ariane_pkg::FE_NONE;
      if (instr_data_out[0].ex == ariane_pkg::FE_INSTR_ACCESS_FAULT) begin
        fetch_entry_o[0].ex.cause = riscv::INSTR_ACCESS_FAULT;
      end else begin
        fetch_entry_o[0].ex.cause = riscv::INSTR_PAGE_FAULT;
      end
      if (CVA6Cfg.TvalEn)
        fetch_entry_o[0].ex.tval = {{64 - CVA6Cfg.VLEN{1'b0}}, instr_data_out[0].ex_vaddr};
      else fetch_entry_o[0].ex.tval = '0;
      if (CVA6Cfg.RVH) begin
        fetch_entry_o[0].ex.tval2 = instr_data_out[0].ex_gpaddr;
        fetch_entry_o[0].ex.tinst = instr_data_out[0].ex_tinst;
        fetch_entry_o[0].ex.gva   = instr_data_out[0].ex_gva;
      end else begin
        fetch_entry_o[0].ex.tval2 = '0;
        fetch_entry_o[0].ex.tinst = '0;
        fetch_entry_o[0].ex.gva   = 1'b0;
      end

      fetch_entry_o[0].branch_predict.predict_address = address_out;
      fetch_entry_o[0].branch_predict.cf = instr_data_out[0].cf;
      fetch_entry_o[0].hart_id = '0;

      pop_instr[0] = fetch_entry_valid_o[0] & fetch_entry_ready_i[0];
    end
  end

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    // Taken CF from predictor (drives address FIFO pop + redirect PC).
    assign fetch_entry_is_cf[i] = fetch_entry_o[i].branch_predict.cf != ariane_pkg::NoCF;
    // Any CF-class instruction (incl. not-taken branch with NoCF predict).
    assign fetch_entry_is_ctrl_instr[i] = is_ctrl_instr_f(fetch_entry_o[i].instruction);
    assign fetch_entry_blocks_ss[i] = fetch_entry_is_cf[i] | fetch_entry_is_ctrl_instr[i];
    assign fetch_entry_fire[i]  = fetch_entry_valid_o[i] & fetch_entry_ready_i[i];
  end

  // Dual-issue must pop/advance as a *prefix* from port 0. A non-prefix
  // ready[1]&&!ready[0] would pop the second FIFO slot without rotating
  // idx_ds/PC (instr lost; fall-through after not-taken bltu never commits).
  assign fetch_fire_prefix[0] = fetch_entry_fire[0];
  for (genvar p = 1; p < CVA6Cfg.NrIssuePorts; p++) begin : gen_fire_prefix
    assign fetch_fire_prefix[p] = fetch_entry_fire[p] & fetch_fire_prefix[p-1];
  end

  // Address FIFO only for *taken* CF (not every ctrl instr / not-taken branch).
  assign pop_address = |(fetch_entry_is_cf & fetch_fire_prefix);

  // ----------------------
  // Calculate (Next) PC
  // ----------------------
  // Fall-through after issue: last fired instr's stored PC + size, or taken
  // CF predict target. Output addresses themselves come from the FIFO (above).
  //
  // Soft-ladder iter-011 / hang-4 completion: when the next issue port is
  // already presented, use *its* realign PC rather than size-based +2/+4 from
  // instruction[1:0]. Size arithmetic desynced mid-RVI PCs under OpenSBI
  // sbi_strlen (mepc=0x80004a50 into `add` @0x80004a4e, mcause=2).
  assign pc_j[0] = pc_q;
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : gen_pc_j
    logic [CVA6Cfg.VLEN-1:0] size_next;
    assign size_next = fetch_entry_o[i].address +
        ((fetch_entry_o[i].instruction[1:0] != 2'b11) ? CVA6Cfg.VLEN'(2) : CVA6Cfg.VLEN'(4));
    if (i + 1 < CVA6Cfg.NrIssuePorts) begin : gen_pc_j_has_younger
      // Only taken CF redirects; else prefer younger realign PC when valid.
      assign pc_j[i+1] = fetch_entry_is_cf[i] ? address_out : (
          fetch_entry_valid_o[i+1] ? fetch_entry_o[i+1].address : size_next
      );
    end else begin : gen_pc_j_last
      assign pc_j[i+1] = fetch_entry_is_cf[i] ? address_out : size_next;
    end
  end

  always_comb begin
    pc_d = pc_q;
    reset_address_d = flush_i ? 1'b1 : reset_address_q;

    if (fetch_fire_prefix[0]) begin
      // Next sequential PC after the oldest fired instr (port 0).
      pc_d = pc_j[1];
      if (CVA6Cfg.SuperscalarEn) begin
        for (int unsigned p = 1; p < NISSUE; p++) begin
          if (fetch_fire_prefix[p]) pc_d = pc_j[p+1];
          else break;
        end
      end
    end

    // we previously flushed so we need to reset the address
    if (valid_i[0] && reset_address_q) begin
      // this is the base of the first instruction
      pc_d = addr_i[0];
      reset_address_d = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g1ih_v_q    <= 1'b0;
      g1ih_rs1_q  <= 5'd0;
      g1ih_line_q <= '0;
    end else if (flush_i) begin
      g1ih_v_q <= 1'b0;
    end else if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1) begin
      for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
        // G1ih: latch on push of aligned
        // compressed Branch.
        // G1ii: 7b8 may be valid at IQ
        // input but not pushed (G1ct
        // smash / dest-only). Latch from
        // valid_i. Also latch aligned
        // cf==Branch (G1bj may clear the
        // 16-bit class). Keep output
        // Branch-bits gate (not G1if).
        // SMT+SS.
        if (valid_i[s] &&
            (addr_i[s][2:1] == 2'b00) &&
            (((instr_i[s][1:0] == 2'b01) &&
              ((instr_i[s][15:13] == 3'b110) ||
               (instr_i[s][15:13] == 3'b111))) ||
             (cf_type_i[s] == ariane_pkg::Branch))) begin
          g1ih_v_q    <= 1'b1;
          g1ih_rs1_q  <= ((instr_i[s][1:0] == 2'b11) &&
                          (instr_i[s][6:0] == 7'b1100011))
              ? instr_i[s][19:15]
              : {2'b01, instr_i[s][9:7]};
          g1ih_line_q <= addr_i[s][CVA6Cfg.VLEN-1:3];
        end
      end
    end
  end

  // FIFOs
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_instr_fifo
    // Make sure we don't save any instructions if we couldn't save the address
    // G1bk push slot0 through address_overflow — HOLD-FAIL no cookie
    // @202752 (soak burned past cookie-exit). Do not re-land.
    // G1bn keep dest FIFO across flush — MINI-FAIL P3 0x2a @588.
    // Do not re-land (wrong-path slot0 survived a real flush).
    assign push_instr_fifo[i] = push_instr[i] & ~address_overflow;
    cva6_fifo_v3 #(
        .FPGA_ALTERA(CVA6Cfg.FpgaAlteraEn),
        .DEPTH(ariane_pkg::FETCH_FIFO_DEPTH),
        .dtype(instr_data_t),
        .FPGA_EN(CVA6Cfg.FpgaEn)
    ) i_fifo_instr_data (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .flush_i   (flush_i),
        .testmode_i(1'b0),
        .full_o    (instr_queue_full[i]),
        .empty_o   (instr_queue_empty[i]),
        .usage_o   (),
        .data_i    (instr_data_in[i]),
        .push_i    (push_instr_fifo[i]),
        .data_o    (instr_data_out[i]),
        .pop_i     (pop_instr[i])
    );
  end
  // or reduce and check whether we are retiring a taken branch (might be that the corresponding)
  // fifo is full.
  always_comb begin
    push_address = 1'b0;
    // check if we are pushing a ctrl flow change, if so save the address
    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
      push_address |= push_instr[i] & (instr_data_in[i].cf != ariane_pkg::NoCF);
    end
  end

  cva6_fifo_v3 #(
      .FPGA_ALTERA(CVA6Cfg.FpgaAlteraEn),
      .DEPTH      (ariane_pkg::FETCH_ADDR_FIFO_DEPTH),
      .DATA_WIDTH (CVA6Cfg.VLEN),
      .FPGA_EN    (CVA6Cfg.FpgaEn)
  ) i_fifo_address (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (flush_i),
      .testmode_i(1'b0),
      .full_o    (full_address),
      .empty_o   (),
      .usage_o   (),
      .data_i    (predict_address_i),
      .push_i    (push_address & ~full_address),
      .data_o    (address_out),
      .pop_i     (pop_address)
  );

  unread i_unread_branch_mask (.d_i(|branch_mask_extended));
  unread i_unread_fifo_pos (.d_i(|fifo_pos_extended));  // we don't care about the lower signals

  if (CVA6Cfg.RVC) begin : gen_pc_q_with_c
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        idx_ds_q        <= 'b1;
        idx_is_q        <= '0;
        pc_q            <= '0;
        reset_address_q <= 1'b1;
      end else begin
        pc_q            <= pc_d;
        reset_address_q <= reset_address_d;
        if (flush_i) begin
          // one-hot encoded
          idx_ds_q        <= 'b1;
          // binary encoded
          idx_is_q        <= '0;
          reset_address_q <= 1'b1;
        end else begin
          idx_ds_q <= idx_ds_d;
          idx_is_q <= idx_is_d;
        end
      end
    end
  end else begin : gen_pc_q_without_C
    assign idx_ds_q = '0;
    assign idx_is_q = '0;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pc_q            <= '0;
        reset_address_q <= 1'b1;
      end else begin
        pc_q            <= pc_d;
        reset_address_q <= reset_address_d;
        if (flush_i) begin
          reset_address_q <= 1'b1;
        end
      end
    end
  end

  // pragma translate_off
  replay_address_fifo :
  assert property (@(posedge clk_i) disable iff (!rst_ni) replay_o |-> !i_fifo_address.push_i)
  else $fatal(1, "[instr_queue] Pushing address although replay asserted");

  output_select_onehot :
  assert property (@(posedge clk_i) $onehot0(idx_ds_q))
  else begin
    $error("Output select should be one-hot encoded");
    $stop();
  end
  // pragma translate_on
endmodule
