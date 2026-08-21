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
// A fetch block is a stream of halfwords. The frontend right-shifts the I$ line
// so halfword 0 is the one addressed by address_i, therefore this block carries
// FETCH_WIDTH/16 - address_i[FETCH_ALIGN_BITS-1:1] meaningful halfwords. An
// instruction starts at a halfword boundary and is 1 halfword (RVC) or 2
// halfwords (RVI) long, so the only state needed is the lower half of an RVI
// that did not fit in the block.
//
// A/B draft note: this replaces the (FETCH_WIDTH x offset x compressed-pattern)
// decision tree with one cursor walking that halfword stream, which makes the
// block width-generic (32/64/128/256) instead of hand-written for 32 and 64.

module instr_realign
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Fetch flush request - CONTROLLER (inert on leftover, like kill)
    input logic flush_i,
    // In-flight kill (misp/bp/replay) — must not consume leftover
    input logic kill_i,
    // Active hart — leftover is per-hart (I4)
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // 32-bit block is valid - CACHE
    input logic valid_i,
    // Instruction is unaligned - FRONTEND
    output logic serving_unaligned_o,
    // Leftover valid but not completing this window (I3 keep)
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

  // halfwords per fetch block, bits needed to index one, and the cursor width
  // (the cursor also has to represent "one past the last halfword")
  localparam int unsigned NrHalfWords = CVA6Cfg.FETCH_WIDTH / 16;
  localparam int unsigned HwIdxW = CVA6Cfg.FETCH_ALIGN_BITS - 1;
  localparam int unsigned CurW = HwIdxW + 1;

  logic [NrHalfWords-1:0][15:0] hw;
  logic [NrHalfWords-1:0] hw_compressed;
  logic [CurW-1:0] hw_first;  // halfwords skipped by the fetch alignment
  logic [CurW-1:0] hw_avail;  // halfwords carried by this block

  // lower half of an instruction that spans into the next fetch block
  localparam int unsigned NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  logic [NH-1:0] carry_valid_bank_q;
  logic [NH-1:0][15:0] carry_instr_bank_q;
  logic [NH-1:0][CVA6Cfg.VLEN-1:0] carry_addr_bank_q;
  logic [15:0] carry_instr_d, carry_instr_q;
  logic [CVA6Cfg.VLEN-1:0] carry_addr_d, carry_addr_q;
  logic carry_valid_d, carry_valid_q;
  // A split instruction can only be completed by the block that immediately
  // follows the one that produced it. Its lower half is by construction the last
  // halfword of its block, so that block starts at carry_addr_q + 2. Any other
  // address (a redirect, a replay, or the same block presented twice) leaves the
  // carry stale and it must be dropped instead of consuming a halfword.
  logic carry_ok;

  assign carry_valid_q = carry_valid_bank_q[hart_i];
  assign carry_instr_q = carry_instr_bank_q[hart_i];
  assign carry_addr_q  = carry_addr_bank_q[hart_i];

  assign carry_ok = g6lc_fetch_pkg::leftover_complete(
      carry_valid_q,
      g6lc_fetch_pkg::leftover_next(64'(address_i), 64'(carry_addr_q)),
      g6lc_fetch_pkg::rvi_prefix(carry_instr_q),
      1'b1);
  assign serving_unaligned_o = carry_ok;
  assign leftover_pending_o = g6lc_fetch_pkg::leftover_pending(carry_valid_q, carry_ok);

  for (genvar j = 0; j < NrHalfWords; j++) begin : gen_halfword
    assign hw[j] = data_i[16*j+:16];
    // without RVC no halfword can terminate an instruction
    assign hw_compressed[j] = (g6lc_fetch_pkg::ilen_of(CVA6Cfg, hw[j]) == 2);
  end

  assign hw_first = CVA6Cfg.RVC ? CurW'(g6lc_fetch_pkg::hw_off(CVA6Cfg, 64'(address_i))) : '0;
  assign hw_avail = CurW'(NrHalfWords) - hw_first;

  always_comb begin : realign
    logic [CurW-1:0] cur, nxt;  // cursor into the halfword stream, relative to address_i
    logic [15:0] lo, hi;
    logic [CVA6Cfg.VLEN-1:0] slot_addr;
    logic tail;  // cursor sits on the last halfword of the block

    carry_valid_d = 1'b0;
    carry_instr_d = carry_instr_q;
    carry_addr_d  = carry_addr_q;

    valid_o       = '0;
    instr_o       = '0;
    addr_o        = '0;
    cur           = '0;
    nxt           = '0;
    tail          = 1'b0;
    lo            = '0;
    hi            = '0;
    slot_addr     = '0;

    // a carried half always completes into an RVI with halfword 0 of this block
    if (carry_ok) begin
      valid_o[0] = valid_i;
      instr_o[0] = {hw[0], carry_instr_q};
      addr_o[0]  = carry_addr_q;
      cur        = CurW'(1);
    end

    for (int unsigned k = 0; k < CVA6Cfg.INSTR_PER_FETCH; k++) begin
      if ((k != 0 || !carry_ok) && (cur < hw_avail)) begin
        nxt = cur + CurW'(1);
        tail = nxt >= hw_avail;
        lo = hw[cur[HwIdxW-1:0]];
        hi = tail ? 16'b0 : hw[nxt[HwIdxW-1:0]];
        slot_addr = address_i + {{(CVA6Cfg.VLEN - CurW - 1) {1'b0}}, cur, 1'b0};

        unique case ({
          hw_compressed[cur[HwIdxW-1:0]], tail
        })
          // compressed, whether or not it is the last halfword
          2'b10, 2'b11: begin
            valid_o[k] = valid_i;
            instr_o[k] = {hi, lo};
            addr_o[k]  = slot_addr;
            cur        = nxt;
          end
          // RVI fully contained in this block
          2'b00: begin
            valid_o[k] = valid_i;
            instr_o[k] = {hi, lo};
            addr_o[k]  = slot_addr;
            cur        = cur + CurW'(2);
          end
          // RVI split at the block boundary: carry its lower half
          2'b01: begin
            carry_valid_d = 1'b1;
            carry_instr_d = lo;
            carry_addr_d  = slot_addr;
            cur           = hw_avail;
          end
          default: ;
        endcase
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      carry_valid_bank_q <= '0;
      carry_instr_bank_q <= '0;
      carry_addr_bank_q  <= '0;
    end else begin
      if (g6lc_fetch_pkg::leftover_update(flush_i, valid_i, kill_i)) begin
        carry_instr_bank_q[hart_i] <= carry_instr_d;
        carry_addr_bank_q[hart_i]  <= carry_addr_d;
        carry_valid_bank_q[hart_i] <= carry_valid_d;
      end
    end
  end
endmodule
