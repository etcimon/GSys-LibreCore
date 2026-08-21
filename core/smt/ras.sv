//Copyright (C) 2018 to present,
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 08.02.2018
// Migrated: Luis Vitorio Cargnini, IEEE
// Date: 09.06.2018
// U6.1 follow-on: per-hart RAS banks when NrHarts>1 ΓÇö Etienne Cimon 2026

// return address stack (optionally banked for SMT)

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: per-hart RAS banking when NrHarts>1.
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
module ras #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type ras_t = logic,
    parameter int unsigned DEPTH = 2
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Branch prediction flush request - zero
    // When multi-hart: flushes only the active hart's bank (not peers).
    input logic flush_bp_i,
    // U6.1: active fetch hart for push/pop/predict (ignored when NrHarts==1)
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // FSE S5: resolve hart for snapshot + restore (may differ after SMT switch)
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] train_hart_i,
    // Push address in RAS - FRONTEND
    input logic push_i,
    // Pop address from RAS - FRONTEND
    input logic pop_i,
    // Data to be pushed - FRONTEND
    input logic [CVA6Cfg.VLEN-1:0] data_i,
    // Popped data - FRONTEND
    output ras_t data_o,
    // FSE S2/S5: full stack snapshot for BP checkpoint (train/resolve hart bank)
    output ras_t [DEPTH-1:0] stack_snapshot_o,
    // FSE S2: restore entire stack on mispredict (overrides push/pop same cycle)
    input  logic restore_i,
    input  ras_t [DEPTH-1:0] restore_stack_i
);

  localparam int unsigned NH    = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  if (NH <= 1) begin : gen_single
    ras_t [DEPTH-1:0] stack_d, stack_q;

    assign data_o = stack_q[0];
    assign stack_snapshot_o = stack_q;

    always_comb begin
      stack_d = stack_q;

      if (push_i) begin
        stack_d[0].ra = data_i;
        stack_d[0].valid = 1'b1;
        stack_d[DEPTH-1:1] = stack_q[DEPTH-2:0];
      end

      if (pop_i) begin
        stack_d[DEPTH-2:0] = stack_q[DEPTH-1:1];
        stack_d[DEPTH-1].valid = 1'b0;
        stack_d[DEPTH-1].ra = 'b0;
      end
      if (pop_i && push_i) begin
        stack_d = stack_q;
        stack_d[0].ra = data_i;
        stack_d[0].valid = 1'b1;
      end

      // Mispredict restore (takes priority over speculative push/pop)
      if (restore_i) begin
        stack_d = restore_stack_i;
      end

      if (flush_bp_i) begin
        stack_d = '0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        stack_q <= '0;
      end else begin
        stack_q <= stack_d;
      end
    end
  end else begin : gen_banked
    // One RAS stack per hart ΓÇö isolation under SMT switch without BP flush.
    ras_t [NH-1:0][DEPTH-1:0] stack_d, stack_q;

    assign data_o = stack_q[hart_i][0];
    // Snapshot the resolve/train bank for ckpt push (S5 dual-hart isolation)
    assign stack_snapshot_o = stack_q[train_hart_i];

    always_comb begin
      stack_d = stack_q;
      // Speculative push/pop only on the active fetch hart's bank
      if (push_i) begin
        stack_d[hart_i][0].ra = data_i;
        stack_d[hart_i][0].valid = 1'b1;
        stack_d[hart_i][DEPTH-1:1] = stack_q[hart_i][DEPTH-2:0];
      end
      if (pop_i) begin
        stack_d[hart_i][DEPTH-2:0] = stack_q[hart_i][DEPTH-1:1];
        stack_d[hart_i][DEPTH-1].valid = 1'b0;
        stack_d[hart_i][DEPTH-1].ra = 'b0;
      end
      if (pop_i && push_i) begin
        stack_d[hart_i] = stack_q[hart_i];
        stack_d[hart_i][0].ra = data_i;
        stack_d[hart_i][0].valid = 1'b1;
      end
      // FSE S5: restore the resolving branch's bank (not necessarily fetch)
      if (restore_i) begin
        stack_d[train_hart_i] = restore_stack_i;
      end
      // Flush only the active bank (exception/fence), keep peer RAS
      if (flush_bp_i) begin
        stack_d[hart_i] = '0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        stack_q <= '0;
      end else begin
        stack_q <= stack_d;
      end
    end
  end
endmodule
