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
// Date: 26.10.2018
//
// Description: Instruction Queue, separates instruction front-end from processor
//              back-end.
//
// INSTR_PER_FETCH parallel 32-bit FIFOs are filled round-robin: idx_is_q is the
// binary fill pointer, idx_ds_q the one-hot drain pointer, so a fetch packet of
// arbitrary length lands without a shifter on the queue itself. Instructions past
// the first predicted-taken control flow of a packet are dropped; a packet that
// does not fit is not partially accepted but replayed (replay_o/replay_addr_o).
//
// A/B draft note: the rotations are expressed once as rotate_left/rotate_right
// instead of open-coded double-width shifts, the RVC and non-RVC input/output
// paths are one path parameterised by INSTR_PER_FETCH, and the (dead) PC
// reconstruction chain is gone - fetch_entry_o.address comes from the realigner
// PC stored with each word.

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
    // Fetch hart — stamped into the packet (L3); not the decode-time active hart
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // Instruction - instr_realign
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0][31:0] instr_i,
    // Instruction address - instr_realign
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr_i,
    // Instruction is valid - instr_realign
    input logic [CVA6Cfg.INSTR_PER_FETCH-1:0] valid_i,
    // Handshake's ready with CACHE - CACHE
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
    // Handshake's data with ID_STAGE - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid with ID_STAGE - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready with ID_STAGE - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i
);

  localparam int unsigned NrFifo = CVA6Cfg.INSTR_PER_FETCH;
  localparam int unsigned NrIssue = CVA6Cfg.NrIssuePorts;
  localparam int unsigned IdxW = CVA6Cfg.LOG2_INSTR_PER_FETCH;
  localparam int unsigned HidW = $clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2);
  localparam g6lc_fetch_pkg::fetch_en_t En = g6lc_fetch_pkg::en(CVA6Cfg);

  typedef logic [IdxW-1:0] fifo_idx_t;
  // NrFifo is a power of two, so a truncating mask is a modulo
  localparam fifo_idx_t IdxMask = fifo_idx_t'(NrFifo - 1);

  typedef struct packed {
    logic [31:0]                     instr;      // instruction word
    logic [CVA6Cfg.VLEN-1:0]         pc;         // instr PC from realign (not reconstructed)
    ariane_pkg::cf_t                 cf;         // branch was taken
    ariane_pkg::frontend_exception_t ex;         // exception happened
    logic [CVA6Cfg.VLEN-1:0]         ex_vaddr;   // lower VLEN bits of tval for exception
    logic [CVA6Cfg.GPLEN-1:0]        ex_gpaddr;  // lower GPLEN bits of tval2 for exception
    logic [31:0]                     ex_tinst;   // tinst of exception
    logic                            ex_gva;
    logic [HidW-1:0]                 hart;       // fetch hart (L3 packet_hart)
  } instr_data_t;

  // instruction queues
  instr_data_t [NrFifo-1:0] instr_data_in, instr_data_out;
  logic [NrFifo-1:0] instr_queue_full, instr_queue_empty;
  logic [NrFifo-1:0] push_instr, push_instr_fifo, pop_instr;
  // input stream
  logic [NrFifo-1:0] taken, branch_mask, valid, fifo_pos;
  logic instr_overflow;
  fifo_idx_t idx_is_d, idx_is_q, shamt, replay_sel;
  // output stream: one-hot select rotated by issue port
  logic [NrFifo-1:0] idx_ds_d, idx_ds_q;
  logic [NrIssue:0][NrFifo-1:0] idx_ds;
  // address (branch target) queue
  logic [CVA6Cfg.VLEN-1:0] address_out;
  logic push_address, pop_address, full_address, address_overflow;
  // downstream handshake
  logic [NrIssue-1:0] fetch_entry_is_cf, fetch_entry_blocks_ss, fetch_entry_fire, fire_prefix;
  // instruction / predicted CF of the slot each port drains, kept separate from
  // fetch_entry_o so the handshake does not depend on the branch target FIFO
  logic [NrIssue-1:0][31:0] sel_instr;
  ariane_pkg::cf_t [NrIssue-1:0] sel_cf;

  // rotate a per-slot mask between input-stream order and FIFO order
  function automatic logic [NrFifo-1:0] rotate_left(logic [NrFifo-1:0] v, fifo_idx_t amt);
    logic [2*NrFifo-1:0] ext;
    ext = {v, v} << amt;
    return ext[2*NrFifo-1:NrFifo];
  endfunction

  function automatic logic [NrFifo-1:0] rotate_right(logic [NrFifo-1:0] v, fifo_idx_t amt);
    logic [2*NrFifo-1:0] ext;
    ext = {v, v} >> amt;
    return ext[NrFifo-1:0];
  endfunction

  // control-flow class straight from the 32-bit word, no full decode: a CF
  // instruction must be the youngest of an issue group
  function automatic logic is_ctrl_instr(logic [31:0] w);
    unique case (w[1:0])
      2'b11:
      return (w[6:0] == 7'b1100011) ||  // BRANCH
      (w[6:0] == 7'b1101111) ||  // JAL
      (w[6:0] == 7'b1100111);  // JALR
      2'b01:
      return (w[15:13] == 3'b101) ||  // c.j / c.jal
      (w[15:13] == 3'b110) ||  // c.beqz
      (w[15:13] == 3'b111);  // c.bnez
      2'b10: return (w[15:13] == 3'b100) && (w[6:2] == 5'b00000);  // c.jr / c.jalr
      default: return 1'b0;
    endcase
  endfunction

  // ----------------------
  // Input interface
  // ----------------------
  assign ready_o = ~(|instr_queue_full) & ~full_address;

  for (genvar i = 0; i < NrFifo; i++) begin : gen_taken
    assign taken[i] = cf_type_i[i] != ariane_pkg::NoCF;
  end

  // L3: through first predicted CF (packet_upto_cf). n-wide = NrFifo.
  always_comb begin : gen_branch_mask
    logic [7:0] taken8, mask8;
    taken8 = '0;
    taken8[NrFifo-1:0] = taken;
    mask8 = g6lc_fetch_pkg::packet_upto_cf(taken8, NrFifo);
    branch_mask = mask8[NrFifo-1:0];
  end

  assign valid = valid_i & branch_mask;
  // input slot i is served by FIFO (i + idx_is_q)
  assign fifo_pos = rotate_left(valid, idx_is_q);
  assign instr_overflow = |(instr_queue_full & fifo_pos);
  // I7: if any needed slot cannot enqueue, push none (then replay).
  assign push_instr = fifo_pos
      & {NrFifo{g6lc_fetch_pkg::packet_accept(instr_overflow)}};
  assign push_instr_fifo = push_instr
      & {NrFifo{g6lc_fetch_pkg::packet_accept(address_overflow)}};
  assign consumed_o = rotate_right(push_instr_fifo, idx_is_q);

  always_comb begin : gen_shamt
    shamt = '0;
    for (int unsigned i = 0; i < NrFifo; i++) shamt = shamt + fifo_idx_t'(push_instr_fifo[i]);
  end

  assign idx_is_d = idx_is_q + shamt;

  always_comb begin : gen_fifo_input
    for (int unsigned f = 0; f < NrFifo; f++) begin
      fifo_idx_t s;
      s = (fifo_idx_t'(f) - idx_is_q) & IdxMask;
      instr_data_in[f].instr = instr_i[s];
      instr_data_in[f].pc = addr_i[s];
      instr_data_in[f].cf = cf_type_i[s];
      // an exception holds for the whole fetch packet
      instr_data_in[f].ex = exception_i;
      instr_data_in[f].ex_vaddr = exception_addr_i;
      instr_data_in[f].ex_gpaddr = CVA6Cfg.RVH ? exception_gpaddr_i : '0;
      instr_data_in[f].ex_tinst = CVA6Cfg.RVH ? exception_tinst_i : '0;
      instr_data_in[f].ex_gva = CVA6Cfg.RVH && exception_gva_i;
      instr_data_in[f].hart = HidW'(g6lc_fetch_pkg::packet_hart(En, 8'(hart_i)));
    end
  end

  // ----------------------
  // Replay Logic
  // ----------------------
  // Replay the fetch if an instruction FIFO we needed was full, or if the branch
  // target FIFO was full (then nothing of the packet is accepted at all).
  assign address_overflow = full_address & push_address;
  assign replay_o = instr_overflow | address_overflow;
  // restart at the first instruction we could not push
  assign replay_sel = shamt & IdxMask;
  assign replay_addr_o = address_overflow ? addr_i[0] : addr_i[replay_sel];

  // ----------------------
  // Downstream interface
  // ----------------------
  // slot of issue port p, i.e. the drain pointer rotated by p
  for (genvar p = 0; p <= NrIssue; p++) begin : gen_rotate_ds
    assign idx_ds[p] = rotate_left(idx_ds_q, fifo_idx_t'(p % NrFifo));
  end

  // port 0 presents whenever its FIFO slot holds data; a later port additionally
  // requires that no earlier port of the group carries a control-flow instruction
  assign fetch_entry_valid_o[0] = ~|(instr_queue_empty & idx_ds[0]);
  for (genvar p = 1; p < NrIssue; p++) begin : gen_fetch_entry_valid
    logic blocked;
    always_comb begin
      blocked = 1'b0;
      for (int unsigned e = 0; e < p; e++) if (fetch_entry_blocks_ss[e]) blocked = 1'b1;
    end
    assign fetch_entry_valid_o[p] = ~|(instr_queue_empty & idx_ds[p])
                                    & ~blocked & fetch_entry_valid_o[0];
  end

  always_comb begin : gen_fetch_entry
    for (int unsigned p = 0; p < NrIssue; p++) begin
      fetch_entry_o[p] = '0;
      fetch_entry_o[p].branch_predict.predict_address = address_out;
      fetch_entry_o[p].branch_predict.cf = ariane_pkg::NoCF;
    end

    // map each issue port to its rotating FIFO slot
    for (int unsigned f = 0; f < NrFifo; f++) begin
      for (int unsigned p = 0; p < NrIssue; p++) begin
        if (idx_ds[p][f]) begin
          fetch_entry_o[p].instruction = instr_data_out[f].instr;
          // PC from the FIFO (realigner), not a combinational size chain
          fetch_entry_o[p].address = instr_data_out[f].pc;
          fetch_entry_o[p].ex.valid = instr_data_out[f].ex != ariane_pkg::FE_NONE;
          unique case (instr_data_out[f].ex)
            ariane_pkg::FE_INSTR_ACCESS_FAULT:
            fetch_entry_o[p].ex.cause = riscv::INSTR_ACCESS_FAULT;
            ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT:
            fetch_entry_o[p].ex.cause = (CVA6Cfg.RVH && p == 0) ? riscv::INSTR_GUEST_PAGE_FAULT :
                riscv::INSTR_PAGE_FAULT;
            default: fetch_entry_o[p].ex.cause = riscv::INSTR_PAGE_FAULT;
          endcase
          if (CVA6Cfg.TvalEn) begin
            fetch_entry_o[p].ex.tval = {
              {(CVA6Cfg.XLEN - CVA6Cfg.VLEN) {1'b0}}, instr_data_out[f].ex_vaddr
            };
          end
          if (CVA6Cfg.RVH && p == 0) begin
            fetch_entry_o[p].ex.tval2 = instr_data_out[f].ex_gpaddr;
            fetch_entry_o[p].ex.tinst = instr_data_out[f].ex_tinst;
            fetch_entry_o[p].ex.gva   = instr_data_out[f].ex_gva;
          end
          fetch_entry_o[p].branch_predict.cf = instr_data_out[f].cf;
          fetch_entry_o[p].hart_id = instr_data_out[f].hart;
        end
      end
    end
  end

  always_comb begin : gen_selected
    for (int unsigned p = 0; p < NrIssue; p++) begin
      sel_instr[p] = '0;
      sel_cf[p] = ariane_pkg::NoCF;
      for (int unsigned f = 0; f < NrFifo; f++) begin
        if (idx_ds[p][f]) begin
          sel_instr[p] = instr_data_out[f].instr;
          sel_cf[p]    = instr_data_out[f].cf;
        end
      end
    end
  end

  // a slot is popped when its issue port fires as part of the prefix
  always_comb begin : gen_pop
    pop_instr = '0;
    for (int unsigned f = 0; f < NrFifo; f++) begin
      for (int unsigned p = 0; p < NrIssue; p++) begin
        if (idx_ds[p][f]) pop_instr[f] = fire_prefix[p];
      end
    end
  end

  for (genvar p = 0; p < NrIssue; p++) begin : gen_fire
    // taken CF from the predictor: pops the branch target FIFO
    assign fetch_entry_is_cf[p] = sel_cf[p] != ariane_pkg::NoCF;
    // any CF-class instruction, including a not-taken branch
    assign fetch_entry_blocks_ss[p] = fetch_entry_is_cf[p] | is_ctrl_instr(sel_instr[p]);
    assign fetch_entry_fire[p] = fetch_entry_valid_o[p] & fetch_entry_ready_i[p];
  end

  // Issue ports drain as a prefix from port 0: a ready[1] without ready[0] must
  // not pop the second slot, otherwise the drain pointer never rotates past it.
  assign fire_prefix[0] = fetch_entry_fire[0];
  for (genvar p = 1; p < NrIssue; p++) begin : gen_fire_prefix
    assign fire_prefix[p] = fetch_entry_fire[p] & fire_prefix[p-1];
  end

  assign pop_address = |(fetch_entry_is_cf & fire_prefix);

  always_comb begin : gen_rotate_head
    idx_ds_d = idx_ds_q;
    for (int unsigned p = 0; p < NrIssue; p++) begin
      if (fire_prefix[p]) idx_ds_d = idx_ds[p+1];
      else break;
    end
  end

  // ----------------------
  // FIFOs
  // ----------------------
  for (genvar i = 0; i < NrFifo; i++) begin : gen_instr_fifo
    // do not save an instruction if we could not save its branch target
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

  always_comb begin : gen_push_address
    push_address = 1'b0;
    for (int unsigned f = 0; f < NrFifo; f++) begin
      push_address |= push_instr[f] & (instr_data_in[f].cf != ariane_pkg::NoCF);
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

  // ----------------------
  // Pointers
  // ----------------------
  if (NrFifo > 1) begin : gen_rotating_pointers
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        idx_ds_q <= {{NrFifo - 1{1'b0}}, 1'b1};  // one-hot
        idx_is_q <= '0;  // binary
      end else if (flush_i) begin
        idx_ds_q <= {{NrFifo - 1{1'b0}}, 1'b1};
        idx_is_q <= '0;
      end else begin
        idx_ds_q <= idx_ds_d;
        idx_is_q <= idx_is_d;
      end
    end
  end else begin : gen_static_pointers
    assign idx_ds_q = 1'b1;
    assign idx_is_q = '0;
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
