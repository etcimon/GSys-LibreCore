// Copyright 2018 - 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich (bht.sv base)
// Modified by: Etienne Cimon
// Description: Gshare direction predictor (U1). Same port contract as bht so
//              frontend.sv selection/priority logic is untouched. Index is
//              PC XOR global history; 2-bit saturating counters per entry.

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: gshare direction predictor derived from the ETH bht.sv base.
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_bp_gshare
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 1024
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_bp_i,
    input  logic debug_mode_i,
    // U6.1: active fetch hart for banked GHR read (ignored when NrHarts==1)
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // FSE S5: resolve/train hart for GHR update (may differ after SMT switch)
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] train_hart_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_i,
    input  bht_update_t bht_update_i,
    output bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] bht_prediction_o
);
  // Fall back to BHTHist when BPGhistLen is left at 0 so a GSHARE config can
  // reuse the existing history-length knob without a second mandatory field.
  localparam int unsigned GHIST_LEN =
      (CVA6Cfg.BPGhistLen != 0) ? CVA6Cfg.BPGhistLen : CVA6Cfg.BHTHist;
  localparam int unsigned OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned NR_ROWS = NR_ENTRIES / CVA6Cfg.INSTR_PER_FETCH;
  localparam int unsigned ROW_ADDR_BITS = $clog2(CVA6Cfg.INSTR_PER_FETCH);
  localparam int unsigned ROW_INDEX_BITS = CVA6Cfg.RVC == 1'b1 ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 1;
  localparam int unsigned INDEX_BITS = $clog2(NR_ROWS);

  typedef struct packed {
    logic       valid;
    logic [1:0] saturation_counter;
  } gshare_entry_t;

  gshare_entry_t [NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0] table_d, table_q;

  // Global history (banked per hart when NrHarts>1). Shared counter table is OK;
  // isolation for SMT is the GHR view used for the XOR index.
  localparam int unsigned NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  logic [NH-1:0][GHIST_LEN-1:0] ghist_d, ghist_q;
  logic [GHIST_LEN-1:0] ghist_live, ghist_train;
  assign ghist_live  = ghist_q[hart_i];
  assign ghist_train = ghist_q[train_hart_i];

  logic [INDEX_BITS-1:0] index, update_index;
  logic [ROW_INDEX_BITS-1:0] update_row_index;
  logic [INDEX_BITS-1:0] pc_index, update_pc_index;

  // PC bits used for the XOR (skip alignment bits).
  assign pc_index = vpc_i[OFFSET+:INDEX_BITS];
  assign update_pc_index = bht_update_i.pc[OFFSET+:INDEX_BITS];

  // Fold GHR into INDEX_BITS with a balanced XOR tree when GHIST_LEN > INDEX_BITS.
  function automatic logic [INDEX_BITS-1:0] fold_ghist(logic [GHIST_LEN-1:0] h);
    logic [INDEX_BITS-1:0] f;
    f = '0;
    for (int unsigned k = 0; k < GHIST_LEN; k++) begin
      f[k%INDEX_BITS] = f[k%INDEX_BITS] ^ h[k];
    end
    return f;
  endfunction

  assign index = pc_index ^ fold_ghist(ghist_live);
  // Train uses resolve-hart GHR so dual-hart drain after switch is correct
  assign update_index = update_pc_index ^ fold_ghist(ghist_train);

  if (CVA6Cfg.RVC) begin : gen_update_row_index
    assign update_row_index = bht_update_i.pc[ROW_ADDR_BITS+OFFSET-1:OFFSET];
  end else begin : gen_update_row_index_fixed
    assign update_row_index = '0;
  end

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_gshare_output
    assign bht_prediction_o[i].valid = table_q[index][i].valid;
    assign bht_prediction_o[i].taken = table_q[index][i].saturation_counter[1] == 1'b1;
  end

  always_comb begin : update_gshare
    table_d = table_q;
    ghist_d = ghist_q;

    if ((bht_update_i.valid && CVA6Cfg.DebugEn && !debug_mode_i) ||
        (bht_update_i.valid && !CVA6Cfg.DebugEn)) begin
      automatic logic [1:0] sat;
      sat = table_q[update_index][update_row_index].saturation_counter;
      table_d[update_index][update_row_index].valid = 1'b1;
      if (sat == 2'b11) begin
        if (!bht_update_i.taken) table_d[update_index][update_row_index].saturation_counter = sat - 2'b01;
      end else if (sat == 2'b00) begin
        if (bht_update_i.taken) table_d[update_index][update_row_index].saturation_counter = sat + 2'b01;
      end else begin
        if (bht_update_i.taken) table_d[update_index][update_row_index].saturation_counter = sat + 2'b01;
        else table_d[update_index][update_row_index].saturation_counter = sat - 2'b01;
      end
      // FSE S5: shift taken into the resolve/train hart GHR (newest at LSB).
      ghist_d[train_hart_i] = {ghist_train[GHIST_LEN-2:0], bht_update_i.taken};
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ghist_q <= '0;
      for (int unsigned r = 0; r < NR_ROWS; r++) begin
        for (int unsigned c = 0; c < CVA6Cfg.INSTR_PER_FETCH; c++) begin
          table_q[r][c] <= '0;
        end
      end
    end else if (flush_bp_i) begin
      // Clear only the active fetch hart's GHR; soft-invalidate shared table
      ghist_q[hart_i] <= '0;
      for (int unsigned r = 0; r < NR_ROWS; r++) begin
        for (int unsigned c = 0; c < CVA6Cfg.INSTR_PER_FETCH; c++) begin
          table_q[r][c].valid <= 1'b0;
          table_q[r][c].saturation_counter <= 2'b10;
        end
      end
    end else begin
      table_q <= table_d;
      ghist_q <= ghist_d;
    end
  end

endmodule
