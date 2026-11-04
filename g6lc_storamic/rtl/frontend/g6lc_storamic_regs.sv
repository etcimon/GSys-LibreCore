// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-010A control/status register block on the standalone AXI-Lite ctrl seam.
// Off/refuse profiles map only ID/VERSION/CONFIG/STATUS/CAPS; all else SLVERR.
// Model/mapped profiles map everything except REGION[] (ST-010B): a MAP_CTRL
// commit request returns SLVERR, and MAP_CTRL reads committed+MapOk only in
// ProfileMapped (the boot map is an elaboration-time parameter). Counters are
// 32-bit wrapping; internal accept/retire totals are 33-bit for the drain
// snapshot. irq_o is the registered level of IRQ_PENDING & IRQ_ENABLE; events
// win over a same-cycle W1C. AW and W may arrive in either order; responses
// are held stable until ready.
module g6lc_storamic_regs #(
  parameter g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg =
      g6lc_storamic_cfg_pkg::StoramicOff,
  parameter int unsigned Slots = 1,
  parameter int unsigned Regions = 1,
  parameter int unsigned DataWidth = 64,
  // ST-010B: in the mapped profile with BootMapEn=0 the staged REGION[]
  // window is writable and MAP_CTRL runs a sequential commit validator.
  parameter bit BootMapEn = 1'b1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  input logic service_ready_i,
  input logic model_ready_i,
  input logic sequence_exhausted_i,
  input logic [2:0] faults_i,
  input logic stray_i,
  input logic [1:0] txn_accept_i,
  input logic [1:0] txn_refuse_i,
  input logic [1:0] txn_retire_i,
  input logic [1:0] txn_error_i,
  input logic inflight_i,
  input logic [Slots-1:0][3:0] slot_state_i,
  input logic [Slots-1:0][3:0] slot_fault_i,
  input logic [Slots-1:0] slot_dup_i,
  input g6lc_storamic_region_pkg::slot_map_t slot_map_i,
  input logic [Slots-1:0] slot_fault_event_i,
  input logic [Slots-1:0] slot_ready_event_i,
  output logic [Slots-1:0] slot_quiesce_o,
  output logic [Slots-1:0] slot_fault_clear_o,
  output logic irq_o,
  // ST-010B committed runtime map (ProfileMapped && !BootMapEn only).
  output logic map_valid_o,
  output g6lc_storamic_region_pkg::slot_map_t slot_map_o,
  output g6lc_storamic_region_pkg::region_map_t region_map_o
);
  localparam bit Full = Cfg.Profile == g6lc_storamic_cfg_pkg::ProfileModel ||
                        Cfg.Profile == g6lc_storamic_cfg_pkg::ProfileMapped;
  localparam bit Mapped = Cfg.Profile == g6lc_storamic_cfg_pkg::ProfileMapped;
  localparam int unsigned MaxSticks = Cfg.MaxSticks;
  localparam int unsigned Log2Bytes =
      DataWidth > 8 ? $clog2(DataWidth / 8) : 0;

  logic [5:0] faults_q;
  logic [3:0] irq_enable_q, irq_pending_q;
  logic [31:0] drain_token_q, drain_done_q;
  logic drain_pending_q;
  logic [32:0] accept_total, retire_total;
  logic [32:0] snapshot_q;
  logic [31:0] refuse_total, complete_total, error_total;

  // AXI-Lite channel state.
  logic aw_v, w_v, r_v, b_v;
  logic [11:0] aw_a;
  logic [31:0] w_d;
  logic [3:0] w_s;
  logic [1:0] b_resp, r_resp;
  logic [31:0] r_data;

  wire aw_fire = ctrl_req_i.aw_valid && ctrl_resp_o.aw_ready;
  wire w_fire = ctrl_req_i.w_valid && ctrl_resp_o.w_ready;
  wire ar_fire = ctrl_req_i.ar_valid && ctrl_resp_o.ar_ready;
  wire b_fire = b_v && ctrl_req_i.b_ready;
  wire r_fire = r_v && ctrl_req_i.r_ready;

  logic [11:0] wr_addr;
  logic [31:0] wr_data;
  logic [3:0] wr_strb;
  logic wr_go; // both sides latched or arriving this cycle
  always_comb begin
    wr_addr = aw_v ? aw_a : ctrl_req_i.aw.addr[11:0];
    wr_data = w_v ? w_d : ctrl_req_i.w.data;
    wr_strb = w_v ? w_s : ctrl_req_i.w.strb;
    wr_go = (aw_v || ctrl_req_i.aw_valid) && (w_v || ctrl_req_i.w_valid) &&
            !b_v;
  end

  // Decode helpers. W1C clear mask comes only from strobed bytes.
  logic [31:0] s_mask;
  assign s_mask = {{8{wr_strb[3]}}, {8{wr_strb[2]}}, {8{wr_strb[1]}},
                   {8{wr_strb[0]}}};
  logic [5:0] fault_set;
  logic [3:0] pend_set;
  logic drain_done_ev;
  logic [5:0] fault_new;
  logic commit_err_ev;
  assign fault_set = {commit_err_ev, |slot_fault_event_i, stray_i,
                      faults_i};
  assign fault_new = fault_set & ~faults_q;
  // ST-010B staged + committed runtime map. ~2x16 entries of ~230 bits of
  // flops each: acceptable for the model profile; a production build would
  // move staging to tc_sram (recorded limitation).
  localparam bit RuntimeMap = Full && Mapped && !BootMapEn;
  g6lc_storamic_region_pkg::region_map_t staged_q, committed_map_q;
  g6lc_storamic_region_pkg::slot_map_t snap_q, committed_slots_q;
  logic committed_q, commit_evt_q, commit_err_q;
  logic [2:0] vstate; // 0 idle, 1 pre, 2 slots, 3 regions, 4 pairs, 5 commit
  logic busy_q;
  assign busy_q = (vstate != 3'd0);
  g6lc_storamic_region_pkg::map_status_t status_q;
  logic [4:0] vi, vj;
  logic vsub;
  logic [4:0] nreg_q;
  logic map_committed;
  assign map_committed = Mapped ? (BootMapEn ? 1'b1 : committed_q) : 1'b0;
  assign map_valid_o = committed_q;
  assign slot_map_o = committed_slots_q;
  assign region_map_o = committed_map_q;
  // Leading valid staged entries: the effective n_regions.
  function automatic logic [4:0] n_regions_of(
      g6lc_storamic_region_pkg::region_map_t m);
    n_regions_of = '0;
    for (int i = 0; i < g6lc_storamic_region_pkg::MaxRegions; i++)
      if (i < int'(Regions) && m[i].valid) n_regions_of = 5'(i + 1);
      else if (i < int'(Regions)) return n_regions_of;
  endfunction
  logic [4:0] nreg_c;
  assign nreg_c = n_regions_of(staged_q);
  // Region index helpers for the 0x400 window.
  int unsigned w_region, r_region;
  logic commit_done_ev;
  assign commit_done_ev = commit_evt_q;
  assign commit_err_ev = commit_evt_q & commit_err_q;
  assign pend_set = {|drain_done_ev, commit_done_ev, |slot_ready_event_i,
                     |fault_new};
  assign drain_done_ev = drain_pending_q && !inflight_i &&
                         retire_total >= snapshot_q;

  // Read decode of the incoming AR address (registered at accept).
  logic [31:0] rd_data;
  logic rd_err;
  int unsigned slot_idx;
  always_comb begin
    rd_data = '0;
    rd_err = 0;
    slot_idx = int'((ctrl_req_i.ar.addr[11:0] - 12'h100) >> 5);
    r_region = int'((ctrl_req_i.ar.addr[11:0] - 12'h400) >> 5);
    if (!Full) begin
      case (ctrl_req_i.ar.addr[11:0])
        12'h000: rd_data = 32'h5354_524D;
        12'h004: rd_data = 32'(g6lc_storamic_cfg_pkg::ContractVersion);
        12'h008: rd_data = {8'h0, 8'(Log2Bytes), 3'h0, 5'(Regions),
                            4'(MaxSticks), 2'h0, 2'(Cfg.Profile)};
        12'h00C: rd_data = {27'h0, drain_pending_q, sequence_exhausted_i,
                            1'b0, model_ready_i, service_ready_i};
        12'h010: rd_data = g6lc_storamic_cfg_pkg::ImplementedMediaCaps;
        default: rd_err = 1;
      endcase
    end else if (ctrl_req_i.ar.addr[11:0] < 12'h100) begin
      case (ctrl_req_i.ar.addr[11:0])
        12'h000: rd_data = 32'h5354_524D;
        12'h004: rd_data = 32'(g6lc_storamic_cfg_pkg::ContractVersion);
        12'h008: rd_data = {8'h0, 8'(Log2Bytes), 3'h0, 5'(Regions),
                            4'(MaxSticks), 2'h0, 2'(Cfg.Profile)};
        12'h00C: rd_data = {27'h0, drain_pending_q, sequence_exhausted_i,
                            map_committed, model_ready_i, service_ready_i};
        12'h010: rd_data = g6lc_storamic_cfg_pkg::ImplementedMediaCaps;
        12'h014: rd_data = {26'h0, faults_q};
        12'h018: rd_data = {28'h0, irq_enable_q};
        12'h01C: rd_data = {28'h0, irq_pending_q};
        12'h020: rd_data = {19'h0, 5'(status_q), 5'h0, map_committed,
                            busy_q, 1'b0};
        12'h024: rd_data = drain_token_q;
        12'h028: rd_data = drain_done_q;
        12'h02C: rd_data = accept_total[31:0];
        12'h030: rd_data = refuse_total;
        12'h034: rd_data = complete_total;
        12'h038: rd_data = error_total;
        default: rd_err = 1;
      endcase
    end else if (ctrl_req_i.ar.addr[11:0] < 12'h400 &&
                 slot_idx < MaxSticks &&
                 ctrl_req_i.ar.addr[1:0] == 0) begin
      case (ctrl_req_i.ar.addr[4:0])
        5'h00: rd_data = {15'h0, slot_dup_i[slot_idx], 4'h0,
                          slot_fault_i[slot_idx], 4'h0,
                          slot_state_i[slot_idx]};
        5'h04: rd_data = slot_map_i[slot_idx].identity;
        5'h08: rd_data = slot_map_i[slot_idx].ram_bytes[31:0];
        5'h0C: rd_data = slot_map_i[slot_idx].ram_bytes[63:32];
        5'h10: rd_data = slot_map_i[slot_idx].reserved_bytes[31:0];
        5'h14: rd_data = slot_map_i[slot_idx].reserved_bytes[63:32];
        default: rd_err = 1; // CTRL is write-only
      endcase
    end else if (RuntimeMap && ctrl_req_i.ar.addr[11:0] >= 12'h400 &&
                 r_region < Regions && ctrl_req_i.ar.addr[1:0] == 0) begin
      case (ctrl_req_i.ar.addr[4:0])
        5'h00: rd_data = staged_q[r_region].base[31:0];
        5'h04: rd_data = staged_q[r_region].base[63:32];
        5'h08: rd_data = staged_q[r_region].bytes[31:0];
        5'h0C: rd_data = staged_q[r_region].bytes[63:32];
        5'h10: rd_data = staged_q[r_region].offset[31:0];
        5'h14: rd_data = staged_q[r_region].offset[63:32];
        5'h18: rd_data = {24'h0, staged_q[r_region].slot};
        5'h1C: rd_data = {29'h0, staged_q[r_region].write,
                          staged_q[r_region].read, staged_q[r_region].valid};
        default: rd_err = 1;
      endcase
    end else rd_err = 1;
  end

  // Write decode: executed combinationally into next-state below.
  logic wr_err;
  int unsigned w_slot;
  always_comb begin
    wr_err = 0;
    w_slot = int'((wr_addr - 12'h100) >> 5);
    w_region = int'((wr_addr - 12'h400) >> 5);
    if (wr_addr[1:0] != 0) wr_err = 1;
    else if (!Full) wr_err = 1; // no writable registers in off/refuse
    else if (wr_addr < 12'h100) begin
      case (wr_addr)
        12'h018, 12'h024: ; // IRQ_ENABLE / DRAIN_TOKEN writable
        12'h014, 12'h01C: ; // W1C writable
        12'h020: begin // MAP_CTRL commit request
          if (!(RuntimeMap && wr_strb[0] && wr_data[0] &&
                !committed_q && !busy_q)) wr_err = 1;
        end
        default: wr_err = 1;
      endcase
    end else if (wr_addr < 12'h400 && w_slot < MaxSticks &&
                 wr_addr[4:0] == 5'h18) ; // SLOT CTRL
    else if (RuntimeMap && wr_addr >= 12'h400 &&
             w_region < int'(Regions) && !committed_q && !busy_q) begin
      case (wr_addr[4:0])
        5'h00, 5'h04, 5'h08, 5'h0C, 5'h10, 5'h14, 5'h18: ;
        5'h1C: if (wr_data[31:8] != '0) wr_err = 1; // ATTR reserved bits
        default: wr_err = 1;
      endcase
    end else wr_err = 1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      faults_q <= '0;
      irq_enable_q <= '0;
      irq_pending_q <= '0;
      drain_token_q <= '0;
      drain_done_q <= '0;
      drain_pending_q <= 1'b0;
      accept_total <= '0;
      retire_total <= '0;
      snapshot_q <= '0;
      refuse_total <= '0;
      complete_total <= '0;
      error_total <= '0;
      aw_v <= 1'b0; w_v <= 1'b0; r_v <= 1'b0; b_v <= 1'b0;
      aw_a <= '0; w_d <= '0; w_s <= '0;
      b_resp <= '0; r_resp <= '0; r_data <= '0;
      slot_quiesce_o <= '0;
      slot_fault_clear_o <= '0;
      irq_o <= 1'b0;
      staged_q <= '0; committed_map_q <= '0;
      snap_q <= '0; committed_slots_q <= '0;
      committed_q <= 0; commit_evt_q <= 0; commit_err_q <= 0;
      status_q <= g6lc_storamic_region_pkg::MapOk;
      vstate <= '0; vi <= '0; vj <= '0; vsub <= '0; nreg_q <= '0;
    end else begin
      // Counters (wrapping) and 33-bit totals.
      accept_total <= accept_total + 33'(txn_accept_i);
      retire_total <= retire_total + 33'(txn_retire_i);
      refuse_total <= refuse_total + 32'(txn_refuse_i);
      complete_total <= complete_total + 32'(txn_retire_i);
      error_total <= error_total + 32'(txn_error_i);
      // Sticky faults; W1C clear only through strobed bytes; events win.
      faults_q <= (faults_q & ~(6'(wr_go && !wr_err &&
                    wr_addr == 12'h014 ? wr_data[5:0] & s_mask[5:0] : 6'h0)))
                  | fault_set;
      // Events always set pending; W1C clears; event wins same cycle.
      irq_pending_q <= (irq_pending_q & ~(4'(wr_go && !wr_err &&
                         wr_addr == 12'h01C ? wr_data[3:0] & s_mask[3:0]
                                            : 4'h0))) | pend_set;
      if (wr_go && !wr_err && wr_addr == 12'h018)
        irq_enable_q <= 4'((irq_enable_q & ~s_mask[3:0]) |
                           (wr_data[3:0] & s_mask[3:0]));
      if (drain_done_ev) begin
        drain_done_q <= drain_token_q;
        drain_pending_q <= 1'b0;
      end
      // A same-cycle token write replaces the drain (it wins over completion).
      if (wr_go && !wr_err && wr_addr == 12'h024) begin
        drain_token_q <= (drain_token_q & ~s_mask) | (wr_data & s_mask);
        drain_pending_q <= 1'b1;
        snapshot_q <= accept_total + 33'(txn_accept_i);
      end
      slot_quiesce_o <= '0;
      slot_fault_clear_o <= '0;
      if (wr_go && !wr_err && wr_addr >= 12'h100 && wr_addr < 12'h400 &&
          wr_addr[4:0] == 5'h18 && w_slot < MaxSticks) begin
        if (s_mask[0] && wr_data[0]) slot_quiesce_o[w_slot] <= 1'b1;
        if (s_mask[0] && wr_data[1]) slot_fault_clear_o[w_slot] <= 1'b1;
      end
      commit_evt_q <= 1'b0;
      commit_err_q <= 1'b0;
      // MAP_CTRL commit request: snapshot the discovery view and start the
      // sequential validator (write legality was checked by wr_err).
      if (wr_go && !wr_err && wr_addr == 12'h020) begin
        snap_q <= slot_map_i;
        nreg_q <= nreg_c;
        vstate <= 3'd1; vi <= '0; vj <= '0; vsub <= '0;
      end
      // Staged REGION field writes (byte-strobe merged).
      if (wr_go && !wr_err && RuntimeMap && wr_addr >= 12'h400 &&
          w_region < int'(Regions)) begin
        case (wr_addr[4:0])
          5'h00: staged_q[w_region].base[31:0] <=
            (staged_q[w_region].base[31:0] & ~s_mask) | (wr_data & s_mask);
          5'h04: staged_q[w_region].base[63:32] <=
            (staged_q[w_region].base[63:32] & ~s_mask) | (wr_data & s_mask);
          5'h08: staged_q[w_region].bytes[31:0] <=
            (staged_q[w_region].bytes[31:0] & ~s_mask) | (wr_data & s_mask);
          5'h0C: staged_q[w_region].bytes[63:32] <=
            (staged_q[w_region].bytes[63:32] & ~s_mask) | (wr_data & s_mask);
          5'h10: staged_q[w_region].offset[31:0] <=
            (staged_q[w_region].offset[31:0] & ~s_mask) | (wr_data & s_mask);
          5'h14: staged_q[w_region].offset[63:32] <=
            (staged_q[w_region].offset[63:32] & ~s_mask) | (wr_data & s_mask);
          5'h18: staged_q[w_region].slot <=
            (staged_q[w_region].slot & ~s_mask[7:0]) | (wr_data[7:0] &
             s_mask[7:0]);
          5'h1C: if (s_mask[0]) begin
            staged_q[w_region].valid <= wr_data[0];
            staged_q[w_region].read <= wr_data[1];
            staged_q[w_region].write <= wr_data[2];
          end
          default: ;
        endcase
      end
      // Sequential map validator: one slot, region or pair check per cycle,
      // in map_check's exact priority order. SlotCount/WordBytes are
      // statically legal here (MaxSticks is cfg_legal-bounded, Bytes a power
      // of two) so the pre-step only enforces MapRegionCount.
      case (vstate)
        3'd0: ; // idle
        3'd1: begin // pre: n_regions
          if (nreg_q == 0) begin
            status_q <= g6lc_storamic_region_pkg::MapRegionCount;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else begin
            vstate <= 3'd2; vi <= '0; vsub <= '0; vj <= '0;
          end
        end
        3'd2: begin // slot field + duplicate checks (slot vi, dup index vj)
          if (!snap_q[vi].present) begin
            if (5'(vi + 1) == 5'(MaxSticks)) begin
              vstate <= 3'd3; vi <= '0;
            end else vi <= vi + 1;
            vsub <= '0; vj <= '0;
          end else if (!vsub) begin
            if (snap_q[vi].reserved_bytes > snap_q[vi].ram_bytes) begin
              status_q <= g6lc_storamic_region_pkg::MapReservation;
              commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
            end else if (snap_q[vi].identity == '0) begin
              status_q <= g6lc_storamic_region_pkg::MapIdentityZero;
              commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
            end else if (vi == 0) begin
              if (5'(MaxSticks) == 5'd1) begin
                vstate <= 3'd3; vi <= '0;
              end else vi <= vi + 1;
            end else begin
              vsub <= 1'b1; vj <= '0;
            end
          end else begin
            if (snap_q[vj].present &&
                snap_q[vj].identity == snap_q[vi].identity) begin
              status_q <= g6lc_storamic_region_pkg::MapIdentityDuplicate;
              commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
            end else if (5'(vj + 1) == vi) begin
              if (5'(vi + 1) == 5'(MaxSticks)) begin
                vstate <= 3'd3; vi <= '0;
              end else vi <= vi + 1;
              vsub <= '0; vj <= '0;
            end else vj <= vj + 1;
          end
        end
        3'd3: begin // single-region checks for staged_q[vi], in doc order
          if (!staged_q[vi].valid) begin
            status_q <= g6lc_storamic_region_pkg::MapRegionInvalid;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (staged_q[vi].bytes == '0) begin
            status_q <= g6lc_storamic_region_pkg::MapRegionEmpty;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (((staged_q[vi].base | staged_q[vi].bytes |
                         staged_q[vi].offset) &
                        64'((DataWidth / 8) - 1)) != 0) begin
            status_q <= g6lc_storamic_region_pkg::MapRegionAlign;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if ({1'b0, staged_q[vi].base} + {1'b0, staged_q[vi].bytes}
                       > 65'h1_0000_0000_0000_0000) begin
            status_q <= g6lc_storamic_region_pkg::MapRegionOverflow;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (vi != 0 && {1'b0, staged_q[vi].base} <
                       {1'b0, staged_q[vi-1].base} +
                       {1'b0, staged_q[vi-1].bytes}) begin
            status_q <= g6lc_storamic_region_pkg::MapRegionOrder;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (int'(staged_q[vi].slot) >= int'(MaxSticks)) begin
            status_q <= g6lc_storamic_region_pkg::MapSlotIndex;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (!snap_q[staged_q[vi].slot].present) begin
            status_q <= g6lc_storamic_region_pkg::MapSlotAbsent;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (!staged_q[vi].read && !staged_q[vi].write) begin
            status_q <= g6lc_storamic_region_pkg::MapPermission;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if ({1'b0, staged_q[vi].offset} +
                       {1'b0, staged_q[vi].bytes} >
                       {1'b0, snap_q[staged_q[vi].slot].ram_bytes} -
                       {1'b0, snap_q[staged_q[vi].slot].reserved_bytes}) begin
            status_q <= g6lc_storamic_region_pkg::MapBackingExtent;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (5'(vi + 1) == nreg_q) begin
            vstate <= (nreg_q == 5'd1) ? 3'd5 : 3'd4; vi <= '0; vj <= 5'd1;
          end else vi <= vi + 1;
        end
        3'd4: begin // region pair alias checks (vi, vj)
          if (staged_q[vi].slot == staged_q[vj].slot &&
              staged_q[vi].offset < staged_q[vj].offset +
                                    staged_q[vj].bytes &&
              staged_q[vj].offset < staged_q[vi].offset +
                                    staged_q[vi].bytes) begin
            status_q <= g6lc_storamic_region_pkg::MapBackingAlias;
            commit_evt_q <= 1; commit_err_q <= 1; vstate <= '0;
          end else if (5'(vj + 1) == nreg_q) begin
            if (5'(vi + 2) == nreg_q) vstate <= 3'd5; // last pair checked
            else begin
              vi <= vi + 1; vj <= vi + 5'd2;
            end
          end else vj <= vj + 1;
        end
        3'd5: begin // commit MapOk with snapshot identities
          status_q <= g6lc_storamic_region_pkg::MapOk;
          commit_evt_q <= 1; commit_err_q <= 0;
          committed_q <= 1; committed_slots_q <= snap_q;
          for (int k = 0; k < g6lc_storamic_region_pkg::MaxRegions; k++) begin
            committed_map_q[k] <= (k < int'(nreg_q)) ? staged_q[k] : '0;
            if (k < int'(nreg_q))
              committed_map_q[k].slot_identity <=
                  snap_q[staged_q[k].slot].identity;
          end
          vstate <= '0;
        end
        default: vstate <= '0;
      endcase
      irq_o <= |(irq_pending_q & irq_enable_q);

      // Write channel: latch each side until both present, then respond.
      if (b_fire) b_v <= 1'b0;
      if (wr_go) begin
        b_v <= 1'b1;
        b_resp <= wr_err ? 2'b10 : 2'b00;
        aw_v <= 1'b0;
        w_v <= 1'b0;
      end else begin
        if (ctrl_req_i.aw_valid && !aw_v) begin
          aw_v <= 1'b1;
          aw_a <= ctrl_req_i.aw.addr[11:0];
        end
        if (ctrl_req_i.w_valid && !w_v) begin
          w_v <= 1'b1;
          w_d <= ctrl_req_i.w.data;
          w_s <= ctrl_req_i.w.strb;
        end
      end
      // Read channel: decode at accept, hold until ready.
      if (r_fire) r_v <= 1'b0;
      else if (ar_fire) begin
        r_v <= 1'b1;
        r_resp <= (ctrl_req_i.ar.addr[1:0] != 0 || rd_err) ? 2'b10 : 2'b00;
        r_data <= rd_err ? '0 : rd_data;
      end
    end
  end

  assign ctrl_resp_o.aw_ready = !aw_v && !b_v;
  assign ctrl_resp_o.w_ready = !w_v && !b_v;
  assign ctrl_resp_o.b.resp = b_resp;
  assign ctrl_resp_o.b_valid = b_v;
  assign ctrl_resp_o.ar_ready = !r_v;
  assign ctrl_resp_o.r.data = r_data;
  assign ctrl_resp_o.r.resp = r_resp;
  assign ctrl_resp_o.r_valid = r_v;
endmodule
