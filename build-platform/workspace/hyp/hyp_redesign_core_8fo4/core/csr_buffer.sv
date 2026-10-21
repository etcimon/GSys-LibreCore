// hyp8 provenance: ADAPTED (sv-timing emit base, registered lookup + credit)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
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
// Date: 05.05.2017
// Description: Buffer to hold CSR address, this acts like a functional unit
//              to the scoreboard.
//
// hyp8 (group 6): on the OoO path the per-tid commit lookup and the issue
// credit are registered (+1 each):
//   - csr_addr_o is the commit-cycle-matched address captured the cycle
//     after csr_commit_i/csr_commit_tid_i are presented, which is also the
//     cycle the commit bundle's side effects apply under the new
//     scoreboard handshake (tier2_tier3.md csr_buffer).
//   - csr_ready_o is the table credit computed from REGISTERED free
//     counts -- a freed/allocated slot moves the credit one cycle later,
//     never a cycle early. A CSR is only ever readable through a matching
//     table record (the lookup carries a hit flag the commit stage's
//     invariant can check).
// The in-order (OoOEn==0) single-entry path keeps its emit timing
// bit-identically.


module csr_buffer
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Flush CSR - CONTROLLER
    input logic flush_i,
    // OoO: drop table entries whose scoreboard slot was cancelled - ISSUE_STAGE
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // CSR FU is ready - ISSUE_STAGE
    output logic csr_ready_o,
    // CSR instruction is valid - ISSUE_STAGE
    input logic csr_valid_i,
    // CSR buffer result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] csr_result_o,
    // commit the pending CSR OP - TO_BE_COMPLETED
    input logic csr_commit_i,
    // trans_id of the committing CSR (OoO only) - COMMIT_STAGE
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] csr_commit_tid_i,
    // CSR address to write - COMMIT_STAGE
    output logic [11:0] csr_addr_o
);

  // In-order keeps the single-entry buffer bit-identically. OoO can issue a
  // second CSR while an older one awaits commit, so the table is two entries
  // and the commit selects its address by trans_id.
  localparam int unsigned DEPTH = G6LCCfg.OoOEn ? 2 : 1;

  typedef struct packed {
    logic [11:0] csr_address;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] tid;
    logic        valid;
  } csr_ent_t;

  csr_ent_t tab_d[DEPTH], tab_q[DEPTH];

  // control logic, scoreboard signals
  assign csr_result_o = fu_data_i.operand_a;

  if (!G6LCCfg.OoOEn) begin : gen_inorder
    assign csr_addr_o = tab_q[0].csr_address;

    // write logic
    always_comb begin : write
      tab_d = tab_q;
      // by default we are ready
      csr_ready_o = 1'b1;
      // if we have a valid uncommitted csr req or are just getting one WITHOUT a commit in, we are not ready
      // Depth one on purpose: a second CSR must not be accepted before the first
      // retires, or the two side effects could be applied out of program order.
      if ((tab_q[0].valid || csr_valid_i) && ~csr_commit_i) csr_ready_o = 1'b0;
      // if we got a valid from the scoreboard
      // store the CSR address
      if (csr_valid_i) begin
        tab_d[0].csr_address = fu_data_i.operand_b[11:0];
        tab_d[0].valid       = 1'b1;
      end
      // if we get a commit and no new valid instruction -> clear the valid bit
      if (csr_commit_i && ~csr_valid_i) begin
        tab_d[0].valid = 1'b0;
      end
      // clear the buffer if we flushed
      if (flush_i) tab_d[0].valid = 1'b0;
    end
  end else begin : gen_ooo
    // Ready is a table credit: at least one free entry, counting a slot the
    // same-cycle commit is releasing and *excluding* the slot the CSR
    // presented this cycle is taking. Issue acks a CSR one cycle before its
    // csr_valid_i reaches this table, so the op acked last cycle is still
    // allocating while the next issue decision reads this credit; without the
    // csr_valid_i term two back-to-back CSRs could both be acked against one
    // free entry and the second allocation was silently dropped (its commit
    // then found no address and raised ILLEGAL_INSTR).
    // hyp8: the credit is REGISTERED -- issue reads the credit a cycle
    // later under the I1/I2 split, so a registered count is the safe form:
    // a slot freed by cancel/commit moves the credit +1 late, never early.
    logic commit_release, commit_release_q;
    logic csr_valid_q;
    logic [1:0] free_count_q;
    int unsigned fc_c;
    always_ff @(posedge clk_i or negedge rst_ni) begin : credit_regs
      if (!rst_ni) begin
        free_count_q      <= 2'(DEPTH);
        commit_release_q  <= 1'b0;
        csr_valid_q       <= 1'b0;
      end else if (flush_i) begin
        free_count_q      <= 2'(DEPTH);
        commit_release_q  <= 1'b0;
        csr_valid_q       <= 1'b0;
      end else begin
        free_count_q     <= 2'(fc_c);
        commit_release_q <= commit_release;
        csr_valid_q      <= csr_valid_i;
      end
    end
    always_comb begin
      fc_c = 0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (!tab_q[i].valid) fc_c++;
    end
    always_comb begin
      commit_release = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (csr_commit_i && tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i))
          commit_release = 1'b1;
      end
      csr_ready_o = (free_count_q + 2'(commit_release_q)) >= (1 + 2'(csr_valid_q));
    end

    // The commit stage reads the address of the CSR it is retiring, identified
    // by trans_id -- issue order and commit order no longer coincide.
    // hyp8: the lookup is REGISTERED. The match runs against the live table
    // during the commit-presentation cycle and lands in csr_addr_q for the
    // side-effect cycle; a lookup with no matching record presents addr 0
    // and a 0 hit flag (the translate_off check below flags it).
    logic [11:0] csr_addr_q;
    logic        csr_addr_hit_q;
    logic [11:0] csr_addr_d;
    logic        csr_hit_d;
    always_comb begin
      csr_addr_d = '0;
      csr_hit_d  = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (csr_commit_i && tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i)) begin
          csr_addr_d = tab_q[i].csr_address;
          csr_hit_d  = 1'b1;
        end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        csr_addr_q    <= '0;
        csr_addr_hit_q <= 1'b0;
      end else begin
        csr_addr_q    <= csr_addr_d;
        csr_addr_hit_q <= csr_hit_d;
      end
    end
    assign csr_addr_o = csr_addr_q;

    //pragma translate_off
    always_ff @(posedge clk_i) begin
      if (rst_ni && csr_commit_i) begin
        if (!csr_hit_d) $error("csr commit without table entry");
      end
    end
    //pragma translate_on

    logic alloc_dropped;
    always_comb begin : write_ooo
      automatic logic allocated;
      tab_d = tab_q;
      allocated = 1'b0;
      // Wrong-path squash frees the credit without a commit.
      for (int unsigned i = 0; i < DEPTH; i++)
        if (tab_d[i].valid && cancelled_mask_i[tab_d[i].tid])
          tab_d[i].valid = 1'b0;
      // Commit releases the entry whose trans_id is retiring.
      for (int unsigned i = 0; i < DEPTH; i++)
        if (csr_commit_i && tab_d[i].valid && (tab_d[i].tid == csr_commit_tid_i))
          tab_d[i].valid = 1'b0;
      // Allocate the lowest free entry.
      for (int unsigned i = 0; i < DEPTH; i++)
        if (csr_valid_i && !allocated && !tab_d[i].valid) begin
          tab_d[i].valid       = 1'b1;
          tab_d[i].tid         = fu_data_i.trans_id;
          tab_d[i].csr_address = fu_data_i.operand_b[11:0];
          allocated            = 1'b1;
        end
      if (flush_i) begin
        for (int unsigned i = 0; i < DEPTH; i++) tab_d[i].valid = 1'b0;
      end
      // A presented CSR that finds no entry would commit with address 0; the
      // credit above must make this unreachable.
      alloc_dropped = csr_valid_i && !allocated && !flush_i;
    end

    //pragma translate_off
    always_ff @(posedge clk_i) begin
      if (rst_ni && alloc_dropped) $error("csr_buffer: CSR presented with no free table entry");
    end
    //pragma translate_on

    logic _unused_hit;
    assign _unused_hit = csr_addr_hit_q;
  end

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      for (int unsigned i = 0; i < DEPTH; i++) tab_q[i] <= csr_ent_t'('0);
    end else begin
      tab_q <= tab_d;
    end
  end

  // HypCfg currently only documents the seam (the OoO staging is structural).
  logic _unused_hyp;
  assign _unused_hyp = &{1'b0, HypCfg.WbReserve};

endmodule
