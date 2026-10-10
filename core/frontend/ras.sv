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
// U6.1 follow-on: per-hart RAS banks when NrHarts>1 — Etienne Cimon 2026
// T21: pointer-based stack with a top-of-stack checkpoint — Etienne Cimon 2026

// return address stack (optionally banked for SMT)
//
// T21: the stack is a circular array addressed by a top-of-stack pointer with
// a valid count, instead of a shift register. Push/pop/predict semantics are
// unchanged (push on a full stack overwrites the oldest entry; the stack is
// empty after as many pops as it holds entries). The change makes the branch
// prediction checkpoint cheap: a checkpoint is {tos, cnt, ra[tos]} -- the
// pointer, the depth and the one entry a wrong-path pop-then-push can have
// overwritten -- rather than a copy of the whole stack (RASDepth x VLEN bits
// per checkpoint entry, 136 kbit on g6lc64_ooo_server at depth 16 x 64 x 2).
// On restore the resolving control flow's own stack effect is re-applied
// (restore_pop_i for a return, restore_push_i for a call) because the
// checkpoint is the state before the fetch window that carried it.

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: per-hart RAS banking when NrHarts>1;
// pointer-based stack with top-of-stack checkpoint (T21).
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
module ras #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type ras_t = logic,
    parameter int unsigned DEPTH = 2,
    // T21 checkpoint field widths (derived; exposed so the fabric can size its ports)
    parameter int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int unsigned CNT_W = $clog2(DEPTH + 1)
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
    // T21: bank a restore targets (the resolving hart on a mispredict, the
    // fetch hart on a switch/replay clear)
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] restore_hart_i,
    // Push address in RAS - FRONTEND
    input logic push_i,
    // Pop address from RAS - FRONTEND
    input logic pop_i,
    // Data to be pushed - FRONTEND
    input logic [CVA6Cfg.VLEN-1:0] data_i,
    // Popped data - FRONTEND
    output ras_t data_o,
    // T21: top-of-stack checkpoint of the FETCH hart's bank (the context a
    // prediction made this cycle is using)
    output logic [PTR_W-1:0]         snap_tos_o,
    output logic [CNT_W-1:0]         snap_cnt_o,
    output logic [CVA6Cfg.VLEN-1:0]  snap_top_o,
    // T21: restore the resolving hart's bank from a checkpoint (overrides the
    // speculative push/pop of the same cycle on that bank), then re-apply the
    // resolving control flow's own effect: pop for a return, push for a call.
    input  logic                     restore_i,
    input  logic [PTR_W-1:0]         restore_tos_i,
    input  logic [CNT_W-1:0]         restore_cnt_i,
    input  logic [CVA6Cfg.VLEN-1:0]  restore_top_i,
    input  logic                     restore_pop_i,
    input  logic                     restore_push_i,
    input  logic [CVA6Cfg.VLEN-1:0]  restore_push_ra_i
);

  localparam int unsigned NH    = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  function automatic logic [PTR_W-1:0] inc(logic [PTR_W-1:0] p);
    return (p == PTR_W'(DEPTH - 1)) ? '0 : p + PTR_W'(1);
  endfunction
  function automatic logic [PTR_W-1:0] dec(logic [PTR_W-1:0] p);
    return (p == '0) ? PTR_W'(DEPTH - 1) : p - PTR_W'(1);
  endfunction

  logic [NH-1:0][DEPTH-1:0][CVA6Cfg.VLEN-1:0] ra_d, ra_q;
  logic [NH-1:0][PTR_W-1:0] tos_d, tos_q;
  logic [NH-1:0][CNT_W-1:0] cnt_d, cnt_q;

  logic [HID_W-1:0] fsel, rsel;
  assign fsel = (NH <= 1) ? '0 : hart_i[HID_W-1:0];
  assign rsel = (NH <= 1) ? '0 : restore_hart_i[HID_W-1:0];

  // An empty stack predicts ra = 0, exactly as the shift stack did (popped
  // cells were zeroed). The branch unit relies on it: an unpredicted return
  // still travels as cf = Return with this address, and is caught at resolve
  // only because the address cannot equal the real target -- a stale cell
  // that happened to hold the right link would retire the fall-through path.
  assign data_o.valid = (cnt_q[fsel] != '0);
  assign data_o.ra    = (cnt_q[fsel] != '0) ? ra_q[fsel][tos_q[fsel]] : '0;

  assign snap_tos_o = tos_q[fsel];
  assign snap_cnt_o = cnt_q[fsel];
  assign snap_top_o = ra_q[fsel][tos_q[fsel]];

  // restore scratch: checkpoint pointer/count after the own-effect replay
  logic [PTR_W-1:0] t;
  logic [CNT_W-1:0] c;

  always_comb begin
    t     = restore_tos_i;
    c     = restore_cnt_i;
    ra_d  = ra_q;
    tos_d = tos_q;
    cnt_d = cnt_q;

    // Speculative push/pop on the active fetch hart's bank. push+pop in one
    // window (ret then call) replaces the top entry, as the shift stack did.
    if (push_i && pop_i) begin
      if (cnt_q[fsel] != '0) begin
        ra_d[fsel][tos_q[fsel]] = data_i;
      end else begin
        tos_d[fsel] = inc(tos_q[fsel]);
        ra_d[fsel][inc(tos_q[fsel])] = data_i;
        cnt_d[fsel] = CNT_W'(1);
      end
    end else if (push_i) begin
      tos_d[fsel] = inc(tos_q[fsel]);
      ra_d[fsel][inc(tos_q[fsel])] = data_i;
      cnt_d[fsel] = (cnt_q[fsel] == CNT_W'(DEPTH)) ? CNT_W'(DEPTH) : cnt_q[fsel] + CNT_W'(1);
    end else if (pop_i && cnt_q[fsel] != '0) begin
      tos_d[fsel] = dec(tos_q[fsel]);
      cnt_d[fsel] = cnt_q[fsel] - CNT_W'(1);
    end

    // Mispredict restore of the resolving bank (priority over the speculative
    // update of the same bank), then the resolving CF's own stack effect.
    if (restore_i) begin
      ra_d[rsel] = ra_q[rsel];
      ra_d[rsel][t] = restore_top_i;
      if (restore_pop_i && c != '0) begin
        t = dec(t);
        c = c - CNT_W'(1);
      end
      if (restore_push_i) begin
        t = inc(t);
        ra_d[rsel][t] = restore_push_ra_i;
        c = (c == CNT_W'(DEPTH)) ? CNT_W'(DEPTH) : c + CNT_W'(1);
      end
      tos_d[rsel] = t;
      cnt_d[rsel] = c;
    end

    // Flush only the active bank (exception/fence), keep peer RAS
    if (flush_bp_i) begin
      cnt_d[fsel] = '0;
      tos_d[fsel] = '0;
    end
  end

  //pragma translate_off
  // An invalid prediction never carries an address (see data_o above).
  always_ff @(posedge clk_i) begin
    if (rst_ni) ras_empty_zero: assert (data_o.valid || data_o.ra == '0);
  end
  //pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      ra_q  <= '0;
      tos_q <= '0;
      cnt_q <= '0;
    end else begin
      ra_q  <= ra_d;
      tos_q <= tos_d;
      cnt_q <= cnt_d;
    end
  end
endmodule
