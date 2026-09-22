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
// Date: 05.05.2017
// Description: Buffer to hold CSR address, this acts like a functional unit
//              to the scoreboard.


module csr_buffer
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Flush CSR - CONTROLLER
    input logic flush_i,
    // OoO: drop table entries whose scoreboard slot was cancelled - ISSUE_STAGE
    input logic [CVA6Cfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // CSR FU is ready - ISSUE_STAGE
    output logic csr_ready_o,
    // CSR instruction is valid - ISSUE_STAGE
    input logic csr_valid_i,
    // CSR buffer result - ISSUE_STAGE
    output logic [CVA6Cfg.XLEN-1:0] csr_result_o,
    // commit the pending CSR OP - TO_BE_COMPLETED
    input logic csr_commit_i,
    // trans_id of the committing CSR (OoO only) - COMMIT_STAGE
    input logic [CVA6Cfg.TRANS_ID_BITS-1:0] csr_commit_tid_i,
    // CSR address to write - COMMIT_STAGE
    output logic [11:0] csr_addr_o
);
  // In-order keeps the single-entry buffer bit-identically. OoO can issue a
  // second CSR while an older one awaits commit, so the table is two entries
  // and the commit selects its address by trans_id.
  localparam int unsigned DEPTH = CVA6Cfg.OoOEn ? 2 : 1;

  typedef struct packed {
    logic [11:0] csr_address;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] tid;
    logic        valid;
  } csr_ent_t;

  csr_ent_t tab_d[DEPTH], tab_q[DEPTH];

  // control logic, scoreboard signals
  assign csr_result_o = fu_data_i.operand_a;

  if (!CVA6Cfg.OoOEn) begin : gen_inorder
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
    // same-cycle commit is releasing.
    logic commit_release;
    always_comb begin
      automatic int unsigned free_count;
      free_count = 0;
      commit_release = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (!tab_q[i].valid) free_count++;
        if (csr_commit_i && tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i))
          commit_release = 1'b1;
      end
      csr_ready_o = (free_count + int'(commit_release)) >= 1;
    end

    // The commit stage reads the address of the CSR it is retiring, identified
    // by trans_id — issue order and commit order no longer coincide.
    always_comb begin
      csr_addr_o = '0;
      for (int unsigned i = 0; i < DEPTH; i++)
        if (tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i))
          csr_addr_o = tab_q[i].csr_address;
    end

    //pragma translate_off
    always_ff @(posedge clk_i) begin
      if (rst_ni && csr_commit_i) begin
        automatic logic matched;
        matched = 1'b0;
        for (int unsigned i = 0; i < DEPTH; i++)
          if (tab_q[i].valid && (tab_q[i].tid == csr_commit_tid_i)) matched = 1'b1;
        if (!matched) $error("csr commit without table entry");
      end
    end
    //pragma translate_on

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
    end
  end

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      for (int unsigned i = 0; i < DEPTH; i++) tab_q[i] <= csr_ent_t'('0);
    end else begin
      tab_q <= tab_d;
    end
  end

endmodule
