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
// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
// Description: Instruction Re-aligner
//
// This module takes cache blocks and extracts the instructions.
// As we are supporting the compressed instruction set extension, in a 32 bit instruction word
// are up to 2 compressed instructions.
// Furthermore those instructions can be arbitrarily interleaved which makes it possible to fetch
// only the lower part of a 32 bit instruction.
// Furthermore we need to handle the case if we want to start fetching from an unaligned
// instruction e.g. a branch.

module instr_realign
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Fetch flush request - CONTROLLER
    input logic flush_i,
    // I4ab: SMT hart of this fetch (banks unaligned leftover)
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // I4ad: keep leftover across kill_s2 while trap_hold (mtvec line + tail).
    // I4ac gated the flush *input* with ~trap_hold and held pre-trap leftover
    // into bootrom (plat_hc=80). Exception entry pulses clear_unaligned_i.
    input logic keep_unaligned_i,
    input logic clear_unaligned_i,
    // 32-bit block is valid - CACHE
    input logic valid_i,
    // Instruction is unaligned - FRONTEND
    output logic serving_unaligned_o,
    // G1eg: leftover-RVI pending on a non-next-line fetch
    output logic leftover_pending_o,
    // 32-bit block address - CACHE
    input logic [CVA6Cfg.VLEN-1:0] address_i,
    // 32-bit block - CACHE
    input logic [CVA6Cfg.FETCH_WIDTH-1:0] data_i,
    // instruction is valid - FRONTEND
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0] valid_o,
    // Instruction address - FRONTEND
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr_o,
    // Instruction - instr_scan&instr_queue
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0][31:0] instr_o
);
  // as a maximum we support a fetch width of 64-bit, hence there can be 4 compressed instructions
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_is_compressed;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
    // LSB != 2'b11
    assign instr_is_compressed[i] = ~&data_i[i*16+:2];
  end

  // save the unaligned part of the instruction to this ff
  logic [15:0] unaligned_instr_d, unaligned_instr_q;
  // the last instruction was unaligned
  logic unaligned_d, unaligned_q;
  // register to save the unaligned address
  logic [CVA6Cfg.VLEN-1:0] unaligned_address_d, unaligned_address_q;
  // I4ab: per-hart leftover. A shared flop was cleared on SMT switch
  // flush_if, so hart0's completing half of csrr mtval (@ff0e) was lost
  // and the resume decoded as illegal (I4z nat).
  localparam int unsigned NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  logic [NH-1:0]              unaligned_bank_q;
  logic [NH-1:0][15:0]        unaligned_instr_bank_q;
  logic [NH-1:0][CVA6Cfg.VLEN-1:0] unaligned_address_bank_q;
  assign unaligned_q         = unaligned_bank_q[hart_i];
  assign unaligned_instr_q   = unaligned_instr_bank_q[hart_i];
  assign unaligned_address_q = unaligned_address_bank_q[hart_i];
  // I4ad: a leftover is only completable if it is the start of an RVI
  // ([1:0]==11). Flag=1 with data=0 assembled {0x3430, 0} = 0x34300000
  // (compressed 0 / illegal) at expected_trap@ff0e.
  logic leftover_rvi;
  assign leftover_rvi = g6lc_leftover::leftover_rvi(
      unaligned_q, unaligned_instr_q);
  // G1as leftover-next-line-only HOLD-FAIL plat_hc=80 — do not re-land
  // (that drop leftover on a later-non-adjacent fetch).
  // G1av: complete only from the immediately next 8B line; keep leftover
  // on any other fetch so trap-tail can still complete. Not G1aa.
  logic [CVA6Cfg.VLEN-1:3] leftover_next_block;
  logic                    leftover_next_line;
  assign leftover_next_block = unaligned_address_q[CVA6Cfg.VLEN-1:3] + 1'b1;
  assign leftover_next_line  = g6lc_leftover::on_next(
      leftover_rvi, address_i[CVA6Cfg.VLEN-1:3] == leftover_next_block);
  // G1aw: advertise leftover-complete only on the next-line assemble
  // beat. G1av keeps leftover across 0x4d0, so leftover_rvi stays 1
  // while slot0 is c.li — saved BHT / G1au leftover_unconsumed then
  // treat that slot as leftover. Not G1as drop. Not G1aa.
  assign serving_unaligned_o = g6lc_leftover::serving(
      CVA6Cfg, leftover_next_line, unaligned_q);
  // G1eg: leftover is pending (not assembling this beat).
  assign leftover_pending_o = g6lc_leftover::pending(
      leftover_rvi, leftover_next_line);

  // Instruction re-alignment
  if (CVA6Cfg.FETCH_WIDTH == 32) begin : realign_bp_32
    always_comb begin : re_align
      unaligned_d = unaligned_q;
      unaligned_address_d = {address_i[CVA6Cfg.VLEN-1:2], 2'b10};
      unaligned_instr_d = data_i[31:16];

      valid_o[0] = valid_i;
      instr_o[0] = unaligned_q ? g6lc_leftover::assemble(data_i[15:0],
                                                          unaligned_instr_q)
                                : data_i[31:0];
      addr_o[0] = unaligned_q ? unaligned_address_q : address_i;

      if (CVA6Cfg.INSTR_PER_FETCH != 1) begin
        valid_o[CVA6Cfg.INSTR_PER_FETCH-1] = 1'b0;
        instr_o[CVA6Cfg.INSTR_PER_FETCH-1] = '0;
        addr_o[CVA6Cfg.INSTR_PER_FETCH-1]  = {address_i[CVA6Cfg.VLEN-1:2], 2'b10};
      end
      // this instruction is compressed or the last instruction was unaligned
      if (instr_is_compressed[0] || unaligned_q) begin
        // check if this is instruction is still unaligned e.g.: it is not compressed
        // if its compressed re-set unaligned flag
        // for 32 bit we can simply check the next instruction and whether it is compressed or not
        // if it is compressed the next fetch will contain an aligned instruction
        // is instruction 1 also compressed
        // yes? -> no problem, no -> we've got an unaligned instruction
        if (instr_is_compressed[CVA6Cfg.INSTR_PER_FETCH-1] && CVA6Cfg.RVC) begin
          unaligned_d = 1'b0;
          valid_o[CVA6Cfg.INSTR_PER_FETCH-1] = valid_i;
          instr_o[CVA6Cfg.INSTR_PER_FETCH-1] = {16'b0, data_i[31:16]};
        end else begin
          // save the upper bits for next cycle
          unaligned_d = 1'b1;
          unaligned_instr_d = data_i[31:16];
          unaligned_address_d = {address_i[CVA6Cfg.VLEN-1:2], 2'b10};
        end
      end  // else -> normal fetch

      // we started to fetch on a unaligned boundary with a whole instruction -> wait until we've
      // received the next instruction
      if (valid_i && address_i[1]) begin
        // the instruction is not compressed so we can't do anything in this cycle
        if (!instr_is_compressed[0]) begin
          valid_o = '0;
          unaligned_d = 1'b1;
          unaligned_address_d = {address_i[CVA6Cfg.VLEN-1:2], 2'b10};
          unaligned_instr_d = data_i[15:0];
          // the instruction isn't compressed but only the lower is ready
        end else begin
          valid_o = {{CVA6Cfg.INSTR_PER_FETCH - 1{1'b0}}, 1'b1};
        end
      end
    end
  end else if (CVA6Cfg.FETCH_WIDTH == 64) begin : realign_bp_64
    always_comb begin : re_align
      unaligned_d         = 1'b0;
      unaligned_address_d = unaligned_address_q;
      unaligned_instr_d   = unaligned_instr_q;

      valid_o             = '0;
      instr_o[0]          = '0;
      addr_o[0]           = '0;
      instr_o[1]          = '0;
      addr_o[1]           = '0;
      instr_o[2]          = '0;
      addr_o[2]           = '0;
      instr_o[3]          = {16'b0, data_i[63:48]};
      addr_o[3]           = {address_i[CVA6Cfg.VLEN-1:3], 3'b110};

      case (address_i[2:1])
        2'b00: begin
          valid_o[0]  = valid_i;
          valid_o[1]  = valid_i;

          // I4ae: keep leftover on same-block replay.
          // G1av: also keep leftover on a later-non-adjacent fetch
          // (G1as cleared it → plat_hc=80). Complete only next-line.
          unaligned_d = leftover_rvi;

          // last instruction was unaligned
          // TODO how are jumps + unaligned managed?
          // I4ae: complete only from a *later* 8B block. Replaying the
          // mtvec line (ff08) with leftover=0x2773 assembled
          // {mcause_lo, 0x2773}=0x27732773 at ff0e (illegal csr 0x277).
          // G1av: later is not enough — only the immediately next 8B line.
          // Leftover stays pending on any other fetch (not G1as drop).
          if (leftover_next_line) begin
            // for 64 bit there exist the following options:
            //     64  48  32  16  0
            //     | 3 | 2 | 1 | 0 | <- instruction slot
            // |   I   |   I   |   U   | -> again unaligned
            // | * | C |   I   |   U   | -> aligned
            // | * |   I   | C |   U   | -> aligned
            // |   I   | C | C |   U   | -> again unaligned
            // | * | C | C | C |   U   | -> aligned
            // Legend: C = compressed, I = 32 bit instruction, U = unaligned upper half

            instr_o[0] = g6lc_leftover::assemble(data_i[15:0],
                                                unaligned_instr_q);
            addr_o[0]  = unaligned_address_q;

            instr_o[1] = data_i[47:16];
            addr_o[1]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b010};
            // G1ia: compressed +2 is the 16-bit
            // at that PC, not {+4,+2} mash.
            // Not G1gz slot0. SMT+SS.
            if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
                instr_is_compressed[1])
              instr_o[1] = {16'b0, data_i[31:16]};

            if (instr_is_compressed[1]) begin
              instr_o[2] = data_i[63:32];
              addr_o[2]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b100};
              valid_o[2] = valid_i;

              if (instr_is_compressed[2]) begin
                if (instr_is_compressed[3]) begin
                  unaligned_d = 1'b0;
                  valid_o[3]  = valid_i;
                end else begin
                  unaligned_instr_d   = instr_o[3];
                  unaligned_address_d = addr_o[3];
                end
              end else begin
                unaligned_d = 1'b0;
                valid_o[2]  = valid_i;
              end
            end else begin
              instr_o[2] = instr_o[3];
              addr_o[2]  = addr_o[3];
              if (instr_is_compressed[3]) begin
                unaligned_d = 1'b0;
                valid_o[2]  = valid_i;
              end else begin
                unaligned_instr_d   = instr_o[3];
                unaligned_address_d = addr_o[3];
              end
            end
          end else begin
            instr_o[0] = data_i[31:0];
            addr_o[0]  = address_i;

            if (instr_is_compressed[0]) begin
              instr_o[1] = data_i[47:16];
              addr_o[1]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b010};
              // G1ia: compressed +2 is the 16-bit
              // at that PC, not {+4,+2} mash.
              // Not G1gz slot0. SMT+SS.
              if (CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 &&
                  instr_is_compressed[1])
                instr_o[1] = {16'b0, data_i[31:16]};

              //     64  48  32  16  0
              //     | 3 | 2 | 1 | 0 | <- instruction slot
              // |   I   |   I   | C | -> again unaligned
              // | * | C |   I   | C | -> aligned
              // | * |   I   | C | C | -> aligned
              // |   I   | C | C | C | -> again unaligned
              // | * | C | C | C | C | -> aligned
              if (instr_is_compressed[1]) begin
                instr_o[2] = data_i[63:32];
                addr_o[2]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b100};
                valid_o[2] = valid_i;

                if (instr_is_compressed[2]) begin
                  if (instr_is_compressed[3]) begin
                    valid_o[3] = valid_i;
                  end else begin
                    unaligned_d         = 1'b1;
                    unaligned_instr_d   = instr_o[3];
                    unaligned_address_d = addr_o[3];
                  end
                end
              end else begin
                instr_o[2] = instr_o[3];
                addr_o[2]  = addr_o[3];

                if (instr_is_compressed[3]) begin
                  valid_o[2] = valid_i;
                end else begin
                  unaligned_d         = 1'b1;
                  unaligned_instr_d   = instr_o[3];
                  unaligned_address_d = addr_o[3];
                end
              end
            end else begin
              //     64     32       0
              //     | 3 | 2 | 1 | 0 | <- instruction slot
              // |   I   | C |   I   |
              // | * | C | C |   I   |
              // | * |   I   |   I   |
              instr_o[1] = data_i[63:32];
              addr_o[1]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b100};

              instr_o[2] = instr_o[3];
              addr_o[2]  = addr_o[3];

              if (instr_is_compressed[2]) begin
                if (instr_is_compressed[3]) begin
                  valid_o[2] = valid_i;
                end else begin
                  // I4aa: I + C + RVI-start (OpenSBI __sbi_expected_trap:
                  // csrr mcause; c.sd; csrr mtval). Do not present
                  // {RVI_lo, C} as one 32-bit at +4 — that made ff0e illegal.
                  instr_o[1]          = {16'b0, data_i[47:32]};
                  addr_o[1]           = {address_i[CVA6Cfg.VLEN-1:3], 3'b100};
                  valid_o[2]          = 1'b0;
                  unaligned_d         = 1'b1;
                  unaligned_instr_d   = data_i[63:48];
                  unaligned_address_d = {address_i[CVA6Cfg.VLEN-1:3], 3'b110};
                end
              end
            end
          end
        end
        // Frontend already right-shifts I$ data so halfword 0 is at address_i.
        // With address_i[2:1]==2'b01 only 3 halfwords remain (data_i[47:0]).
        // Hang-6: old code treated data as unshifted and used data_i[63:32] as a
        // live instruction — wrong after the frontend shift (dual-issue FETCH_WIDTH=64).
        2'b01: begin
          // G1av: keep leftover unless this beat is the next-line complete.
          unaligned_d = leftover_rvi;
          if (leftover_next_line) begin
            // Complete spanning RVI; up to two more halfwords follow.
            instr_o[0] = g6lc_leftover::assemble(data_i[15:0],
                                                unaligned_instr_q);
            addr_o[0]  = unaligned_address_q;
            valid_o[0] = valid_i;

            instr_o[1] = data_i[47:16];
            addr_o[1]  = address_i + CVA6Cfg.VLEN'(2);
            valid_o[1] = valid_i;
            if (instr_is_compressed[1]) begin
              if (instr_is_compressed[2]) begin
                instr_o[2] = {16'b0, data_i[47:32]};
                addr_o[2]  = address_i + CVA6Cfg.VLEN'(4);
                valid_o[2] = valid_i;
              end else begin
                unaligned_d         = 1'b1;
                unaligned_instr_d   = data_i[47:32];
                unaligned_address_d = address_i + CVA6Cfg.VLEN'(4);
              end
            end
            // else instr_o[1] is a full RVI from halfwords 1+2 — done
          end else begin
            instr_o[0] = data_i[31:0];
            addr_o[0]  = address_i;
            valid_o[0] = valid_i;

            if (instr_is_compressed[0]) begin
              instr_o[1] = data_i[47:16];
              addr_o[1]  = address_i + CVA6Cfg.VLEN'(2);
              valid_o[1] = valid_i;
              if (instr_is_compressed[1]) begin
                if (instr_is_compressed[2]) begin
                  instr_o[2] = {16'b0, data_i[47:32]};
                  addr_o[2]  = address_i + CVA6Cfg.VLEN'(4);
                  valid_o[2] = valid_i;
                end else begin
                  unaligned_d         = 1'b1;
                  unaligned_instr_d   = data_i[47:32];
                  unaligned_address_d = address_i + CVA6Cfg.VLEN'(4);
                end
              end
              // else instr_o[1] is RVI from halfwords 1+2
            end else begin
              // First is RVI (halfwords 0+1); one halfword remains
              if (instr_is_compressed[2]) begin
                instr_o[1] = {16'b0, data_i[47:32]};
                addr_o[1]  = address_i + CVA6Cfg.VLEN'(4);
                valid_o[1] = valid_i;
              end else begin
                unaligned_d         = 1'b1;
                unaligned_instr_d   = data_i[47:32];
                unaligned_address_d = address_i + CVA6Cfg.VLEN'(4);
              end
            end
          end
        end
        2'b10: begin
          // 64  48  32  16  0
          // | 3 | 2 | 1 | 0 | <- instruction slot
          // | * |   I   | C | <- unaligned
          // |   *   | C | C | <- aligned
          // |   *   |   I   | <- aligned
          //      1000 110 100 <- unaligned address

          instr_o[0] = data_i[31:0];
          addr_o[0]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b100};
          valid_o[0] = valid_i;

          instr_o[1] = data_i[47:16];
          addr_o[1]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b110};

          if (instr_is_compressed[0]) begin
            if (instr_is_compressed[1]) begin
              valid_o[1] = valid_i;
            end else begin
              unaligned_d         = 1'b1;
              unaligned_instr_d   = instr_o[1];
              unaligned_address_d = addr_o[1];
            end
          end
        end
        // we started to fetch on a unaligned boundary with a whole instruction -> wait until we've
        // received the next instruction
        2'b11: begin
          //     64  48  32  16  0
          // | 3 | 2 | 1 | 0 | <- instruction slot
          // |   *   |   I   | <- unaligned
          // |     *     | C | <- aligned
          //          1000 110 <- unaligned address

          instr_o[0] = data_i[31:0];
          addr_o[0]  = {address_i[CVA6Cfg.VLEN-1:3], 3'b110};

          if (instr_is_compressed[0]) begin
            valid_o[0] = valid_i;
          end else begin
            unaligned_d         = 1'b1;
            unaligned_instr_d   = instr_o[0];
            unaligned_address_d = addr_o[0];
          end
        end
      endcase
      // G1bf: leftover pending on a later aligned fetch must present
      // slot0 as the 16-bit at address_i (c.li@0x4d0). Do not complete
      // leftover here (G1av keep; not G1as drop). SMT+SS. Not G1bb.
      // G1bo widen to any aligned compressed slot0 — MINI-FAIL P1
      // 0x10 @384. Do not re-land.
      // G1ed: only when slot0 is compressed. OpenSBI 7a8 I|I
      // (addi+csrr) and 7b0 I|C|C (ld+c.mv) must stay 32-bit;
      // leftover from 750 ld-half is still pending (not next-line).
      if (g6lc_present::bf_ed(
              CVA6Cfg, leftover_rvi, leftover_next_line, valid_i,
              address_i[2:1] == 2'b00, instr_is_compressed[0])) begin
        valid_o[0] = 1'b1;
        addr_o[0]  = address_i;
        instr_o[0] = {16'b0, data_i[15:0]};
      end
      // G1gx: mid-line [2:1]==01 slot0 is the 16-bit
      // at that PC, not leftover-complete 32-bit
      // {data[15:0], leftover} at leftover PC.
      // G1gw needs fetch_entry at 7ba to be c.jalr.
      // Keep leftover (G1av; not G1as drop). Not
      // G1es I|I starve (aligned leftover_next
      // still completes). Not G1gv mash. SMT+SS.
      if (g6lc_present::gx_mid01(
              CVA6Cfg, leftover_next_line, valid_i,
              address_i[2:1] == 2'b01, instr_is_compressed[0])) begin
        valid_o[0] = 1'b1;
        addr_o[0]  = address_i;
        instr_o[0] = {16'b0, data_i[15:0]};
        unaligned_d = leftover_rvi;
        valid_o[1]  = 1'b0;
        valid_o[2]  = 1'b0;
        valid_o[3]  = 1'b0;
      end
      // G1es aligned I|I overrides leftover_next —
      // MINI-FAIL lottery+FDT hang @400000. Do not
      // re-land (starved leftover-complete onto
      // I|I-looking next lines). Isolated P4 stays.
      // G1eu: leftover jal x0 (rd==0) does not
      // leftover-complete onto an aligned I|I line
      // (7a8 addi+csrr). Present I|I; keep leftover
      // pending. P8 jal ra still completes. Not G1es
      // (any leftover). Not G1dr G1dc rd. SMT+SS.
      if (g6lc_present::eu_jalx0_ii(
              CVA6Cfg, leftover_next_line, valid_i,
              address_i[2:1] == 2'b00,
              instr_is_compressed[0], instr_is_compressed[2],
              unaligned_instr_q[31:0])) begin
        valid_o[0]  = valid_i;
        valid_o[1]  = valid_i;
        valid_o[2]  = 1'b0;
        valid_o[3]  = 1'b0;
        addr_o[0]   = address_i;
        instr_o[0]  = data_i[31:0];
        addr_o[1]   = {address_i[CVA6Cfg.VLEN-1:3], 3'b100};
        instr_o[1]  = data_i[63:32];
        unaligned_d = leftover_rvi;
      end
      // leftover_off_npc00: leftover-complete
      // of a different 16B line must not occupy
      // slot0 when the completing fetch is 00
      // first 8B of a 16B line (7b0 ld). Present
      // aligned I$ slot0; keep leftover pending.
      // Same-16B leftover_next still completes
      // (766 from 768). Hygiene at n7b0 (I$ of
      // leftover_next is not a 00-first-8B LOAD
      // off leftover's 16B). Not G1es any I|I.
      // Not G1eu jal x0 + I|I. Not skip_next. SMT+SS.
      if (g6lc_present::leftover_off_npc00(
              CVA6Cfg, leftover_next_line, valid_i,
              address_i[2:1] == 2'b00, ~address_i[3],
              unaligned_address_q[CVA6Cfg.VLEN-1:4] !=
                  address_i[CVA6Cfg.VLEN-1:4],
              data_i[31:0])) begin
        valid_o[0]  = valid_i;
        addr_o[0]   = address_i;
        instr_o[0]  = data_i[31:0];
        valid_o[1]  = 1'b0;
        valid_o[2]  = 1'b0;
        valid_o[3]  = 1'b0;
        unaligned_d = leftover_rvi;
      end
      // G1cl leftover-complete later slots after leftover-RVI
      // Branch — MINI-FAIL P1 0x11 @442. Do not re-land
      // (too wide: P1 leftover-Branch fallthrough is live).
      // G1cm: only the later-slot Jump (c.j / jal) is not
      // presented. Later ALU (li s11) stays. Not G1bz
      // bp_valid. Not G1ci consumed. SMT+SS.
      if (g6lc_leftover::cm_arm(
              CVA6Cfg, leftover_next_line,
              instr_o[0][6:0] == riscv::OpcodeBranch)) begin
        for (int unsigned i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
          if (g6lc_leftover::later_jump(instr_o[i]))
            valid_o[i] = 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      unaligned_bank_q         <= '0;
      unaligned_address_bank_q <= '0;
      unaligned_instr_bank_q   <= '0;
    end else begin
      if (valid_i) begin
        unaligned_address_bank_q[hart_i] <= unaligned_address_d;
        unaligned_instr_bank_q[hart_i]   <= unaligned_instr_d;
      end

      // I4ad: exception entry (clear) outranks keep. Other flushes still
      // drop leftover (boot / mispredict). trap_hold keep covers the
      // establish cycle *and* the gap before the completing fetch.
      // G1du/G1dx: replay keep of leftover-RVI capture (frontend
      // keep_unaligned). Not G1as drop.
      // G1dy capture-outranks-kill_s2 — MINI-FAIL printed 23
      // @1134. Do not re-land.
      if (clear_unaligned_i) begin
        unaligned_bank_q[hart_i] <= 1'b0;
      end else if (flush_i && !keep_unaligned_i) begin
        unaligned_bank_q[hart_i] <= 1'b0;
      end else if (valid_i) begin
        unaligned_bank_q[hart_i] <= unaligned_d;
      end
    end
  end
endmodule
