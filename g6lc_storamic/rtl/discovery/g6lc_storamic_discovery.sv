// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-009A per-slot discovery and lifecycle machine. Async inputs reach state
// only through g6lc_storamic_sync + the debounce counter. power_en_o is high
// only from POWER_WAIT through QUIESCE and drops the same cycle the debounced
// presence falls. Descriptor reads are one outstanding word at a time; field
// flags accumulate word by word and the first documented failure is reported
// at VALIDATE. No descriptor array: only fields, the running sum and the word
// index are registered.
module g6lc_storamic_discovery #(
  parameter int unsigned DebounceCycles = 4,
  parameter int unsigned PowerTimeout = 64,
  parameter int unsigned DescTimeout = 64,
  parameter int unsigned InitTimeout = 256,
  parameter int unsigned DescMaxWords = 32,
  parameter logic [63:0] MaxRamBytes = 64'hFFFF_FFFF_FFFF_FFFF,
  parameter logic [63:0] MaxFlashBytes = 64'hFFFF_FFFF_FFFF_FFFF,
  parameter logic [3:0] SupportedProfile = 4'h0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic presence_i,
  input logic [3:0] profile_strap_i,
  input logic power_good_i,
  output logic power_en_o,
  output logic desc_req_o,
  output logic [7:0] desc_addr_o,
  input logic desc_valid_i,
  input logic [31:0] desc_data_i,
  input logic desc_error_i,
  output logic init_req_o,
  input logic init_done_i,
  input logic init_error_i,
  input logic quiesce_req_i,
  input logic drain_i,
  input logic fault_clear_i,
  output g6lc_storamic_discovery_pkg::state_t state_o,
  output g6lc_storamic_discovery_pkg::fault_t fault_o,
  output g6lc_storamic_region_pkg::slot_desc_t slot_desc_o,
  output logic ram_ready_o,
  output logic flash_ready_o,
  output logic persist_ready_o,
  output logic persist_cap_o,
  output logic [63:0] flash_bytes_o,
  output logic [31:0] erase_bytes_o,
  output logic fault_event_o,
  output logic ready_event_o
);
  import g6lc_storamic_discovery_pkg::*;

  // pragma translate_off
  initial begin
    if (DebounceCycles < 1) $fatal(1, "STORAMIC_DISC_PARAM_DEBOUNCE");
    if (PowerTimeout < 1) $fatal(1, "STORAMIC_DISC_PARAM_POWER_TIMEOUT");
    if (DescTimeout < 1) $fatal(1, "STORAMIC_DISC_PARAM_DESC_TIMEOUT");
    if (InitTimeout < 1) $fatal(1, "STORAMIC_DISC_PARAM_INIT_TIMEOUT");
    if (DescMaxWords < DescMinWords || DescMaxWords > 256)
      $fatal(1, "STORAMIC_DISC_PARAM_DESC_MAX_WORDS");
  end
  // pragma translate_on

  logic [4:0] async_in, sync_out;
  logic power_good_sync;
  assign async_in = {presence_i, profile_strap_i};
  g6lc_storamic_sync #(.Width(5)) i_pres_strap (
    .clk_i, .rst_ni, .testmode_i, .in_i(async_in), .out_o(sync_out)
  );
  g6lc_storamic_sync #(.Width(1)) i_power_good (
    .clk_i, .rst_ni, .testmode_i, .in_i(power_good_i), .out_o(power_good_sync)
  );
  logic pres_sync;
  logic [3:0] strap_sync;
  assign {pres_sync, strap_sync} = sync_out;

  // Debounce: presence changes only after DebounceCycles consecutive stable
  // samples. pres_eff is the value that will be registered this edge, so a
  // powered-state transition leaves at the same edge the debounced presence
  // falls and power_en_o (decoded from state) drops in that cycle.
  logic pres_db;
  logic [31:0] deb_cnt;
  logic pres_commit;
  logic pres_eff;
  assign pres_commit = (pres_sync != pres_db) && (deb_cnt >= DebounceCycles - 1);
  assign pres_eff = pres_commit ? pres_sync : pres_db;

  state_t state_q;
  fault_t fault_q;
  logic [3:0] strap_q;
  logic [31:0] timer_q;
  logic [7:0] idx_q;
  logic [15:0] len_q;
  logic [31:0] sum_q;
  logic magic_bad_q, ver_bad_q, len_bad_q, sum_bad_q;
  logic ident_bad_q, flags_bad_q, resv_bad_q;
  logic [31:0] ident_q, flags_q;
  logic [63:0] ram_q, res_q, flash_q;
  logic [31:0] erase_q;
  g6lc_storamic_region_pkg::slot_desc_t slot_desc_q;

  // A powered state loses presence -> FaultRemoved; Present/PowerCheck and
  // Quiesced return to Absent.
  function automatic bit powered(input state_t s);
    return s == PowerWait || s == Identify || s == Validate ||
           s == Initialize || s == Ready || s == Quiesce;
  endfunction

  bit capacity_bad, geometry_bad;
  always_comb begin
    capacity_bad = (ram_q > MaxRamBytes) || (res_q > ram_q) ||
                   (flash_q > MaxFlashBytes) ||
                   (flags_q[0] && ram_q == 0) || (!flags_q[0] && ram_q != 0) ||
                   (flags_q[1] && flash_q == 0) || (!flags_q[1] && flash_q != 0);
    geometry_bad = (erase_q != 0 && (erase_q & (erase_q - 1)) != 0) ||
                   (flags_q[1] && erase_q == 0) || (!flags_q[1] && erase_q != 0);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pres_db <= 1'b0;
      deb_cnt <= '0;
      state_q <= Absent;
      fault_q <= FaultNone;
      strap_q <= '0;
      timer_q <= '0;
      idx_q <= '0;
      len_q <= '0;
      sum_q <= '0;
      magic_bad_q <= 1'b0;
      ver_bad_q <= 1'b0;
      len_bad_q <= 1'b0;
      sum_bad_q <= 1'b0;
      ident_bad_q <= 1'b0;
      flags_bad_q <= 1'b0;
      resv_bad_q <= 1'b0;
      ident_q <= '0;
      flags_q <= '0;
      ram_q <= '0;
      res_q <= '0;
      flash_q <= '0;
      erase_q <= '0;
      slot_desc_q <= '0;
      fault_event_o <= 1'b0;
      ready_event_o <= 1'b0;
    end else begin
      fault_event_o <= 1'b0;
      ready_event_o <= 1'b0;
      // Debounce counter.
      if (pres_sync != pres_db) begin
        if (deb_cnt >= DebounceCycles - 1) begin
          pres_db <= pres_sync;
          deb_cnt <= '0;
        end else deb_cnt <= deb_cnt + 1;
      end else deb_cnt <= '0;
      // Per-phase timeout counter.
      timer_q <= timer_q + 1;

      case (state_q)
        Absent: begin
          fault_q <= FaultNone;
          if (pres_eff) begin
            state_q <= Present;
            timer_q <= '0;
          end
        end
        Present: begin
          if (!pres_eff) state_q <= Absent;
          else state_q <= PowerCheck;
        end
        PowerCheck: begin
          strap_q <= strap_sync;
          if (!pres_eff) state_q <= Absent;
          else if (strap_sync == SupportedProfile) begin
            state_q <= PowerWait;
            timer_q <= '0;
          end else begin
            state_q <= Fault;
            fault_q <= FaultProfile;
            fault_event_o <= 1'b1;
          end
        end
        PowerWait: begin
          if (!pres_eff) begin
            state_q <= Fault;
            fault_q <= FaultRemoved;
            fault_event_o <= 1'b1;
          end else if (power_good_sync) begin
            state_q <= Identify;
            timer_q <= '0;
            idx_q <= '0;
            sum_q <= '0;
            magic_bad_q <= 1'b0;
            ver_bad_q <= 1'b0;
            len_bad_q <= 1'b0;
            sum_bad_q <= 1'b0;
            ident_bad_q <= 1'b0;
            flags_bad_q <= 1'b0;
            resv_bad_q <= 1'b0;
          end else if (timer_q >= PowerTimeout - 1) begin
            state_q <= Fault;
            fault_q <= FaultPowerTimeout;
            fault_event_o <= 1'b1;
          end
        end
        Identify: begin
          if (!pres_eff) begin
            state_q <= Fault;
            fault_q <= FaultRemoved;
            fault_event_o <= 1'b1;
          end else if (desc_error_i) begin
            state_q <= Fault;
            fault_q <= FaultDescRead;
            fault_event_o <= 1'b1;
          end else if (desc_valid_i) begin
            timer_q <= '0;
            sum_q <= sum_q + desc_data_i;
            case (idx_q)
              8'd0: begin
                magic_bad_q <= desc_data_i != DescMagic;
                if (desc_data_i != DescMagic) state_q <= Validate;
                else idx_q <= idx_q + 1;
              end
              8'd1: begin
                ver_bad_q <= desc_data_i[31:16] != DescVersion;
                len_bad_q <= desc_data_i[15:0] < DescMinWords ||
                             desc_data_i[15:0] > 16'(DescMaxWords);
                len_q <= desc_data_i[15:0];
                if (desc_data_i[31:16] != DescVersion ||
                    desc_data_i[15:0] < DescMinWords ||
                    desc_data_i[15:0] > 16'(DescMaxWords))
                  state_q <= Validate;
                else idx_q <= idx_q + 1;
              end
              8'd2: begin
                ident_q <= desc_data_i;
                ident_bad_q <= desc_data_i == 0;
                idx_q <= idx_q + 1;
              end
              8'd3: begin
                flags_q <= desc_data_i;
                flags_bad_q <= (desc_data_i & ~DescFlagsKnown) != 0 ||
                               !(desc_data_i[0] || desc_data_i[1]) ||
                               desc_data_i[11:8] != strap_q;
                idx_q <= idx_q + 1;
              end
              8'd4: begin ram_q[31:0] <= desc_data_i; idx_q <= idx_q + 1; end
              8'd5: begin ram_q[63:32] <= desc_data_i; idx_q <= idx_q + 1; end
              8'd6: begin res_q[31:0] <= desc_data_i; idx_q <= idx_q + 1; end
              8'd7: begin res_q[63:32] <= desc_data_i; idx_q <= idx_q + 1; end
              8'd8: begin flash_q[31:0] <= desc_data_i; idx_q <= idx_q + 1; end
              8'd9: begin flash_q[63:32] <= desc_data_i; idx_q <= idx_q + 1; end
              8'd10: begin erase_q <= desc_data_i; idx_q <= idx_q + 1; end
              default: begin
                if (idx_q < len_q - 1 && desc_data_i != 0) resv_bad_q <= 1'b1;
                idx_q <= idx_q + 1;
              end
            endcase
            // Last word: checksum must make the whole-descriptor sum zero.
            if (idx_q == len_q - 1 && len_q != 0) begin
              sum_bad_q <= (sum_q + desc_data_i) != 0;
              state_q <= Validate;
            end
          end else if (timer_q >= DescTimeout - 1) begin
            state_q <= Fault;
            fault_q <= FaultDescTimeout;
            fault_event_o <= 1'b1;
          end
        end
        Validate: begin
          if (!pres_eff) begin
            state_q <= Fault;
            fault_q <= FaultRemoved;
            fault_event_o <= 1'b1;
          end else if (magic_bad_q) begin
            state_q <= Fault; fault_q <= FaultMagic; fault_event_o <= 1'b1;
          end else if (ver_bad_q) begin
            state_q <= Fault; fault_q <= FaultVersion; fault_event_o <= 1'b1;
          end else if (len_bad_q) begin
            state_q <= Fault; fault_q <= FaultLength; fault_event_o <= 1'b1;
          end else if (sum_bad_q) begin
            state_q <= Fault; fault_q <= FaultChecksum; fault_event_o <= 1'b1;
          end else if (ident_bad_q) begin
            state_q <= Fault; fault_q <= FaultIdentity; fault_event_o <= 1'b1;
          end else if (flags_bad_q) begin
            state_q <= Fault; fault_q <= FaultFlags; fault_event_o <= 1'b1;
          end else if (capacity_bad) begin
            state_q <= Fault; fault_q <= FaultCapacity; fault_event_o <= 1'b1;
          end else if (geometry_bad) begin
            state_q <= Fault; fault_q <= FaultGeometry; fault_event_o <= 1'b1;
          end else if (resv_bad_q) begin
            state_q <= Fault; fault_q <= FaultReserved; fault_event_o <= 1'b1;
          end else begin
            state_q <= Initialize;
            timer_q <= '0;
          end
        end
        Initialize: begin
          if (!pres_eff) begin
            state_q <= Fault;
            fault_q <= FaultRemoved;
            fault_event_o <= 1'b1;
          end else if (init_error_i) begin
            state_q <= Fault;
            fault_q <= FaultInit;
            fault_event_o <= 1'b1;
          end else if (init_done_i) begin
            state_q <= Ready;
            timer_q <= '0;
            ready_event_o <= 1'b1;
            slot_desc_q <= '{present: 1'b1, identity: ident_q,
                            ram_bytes: ram_q, reserved_bytes: res_q};
          end else if (timer_q >= InitTimeout - 1) begin
            state_q <= Fault;
            fault_q <= FaultInit;
            fault_event_o <= 1'b1;
          end
        end
        Ready: begin
          if (!pres_eff) begin
            state_q <= Fault;
            fault_q <= FaultRemoved;
            fault_event_o <= 1'b1;
            slot_desc_q <= '0;
          end else if (quiesce_req_i) begin
            state_q <= Quiesce;
            timer_q <= '0;
          end
        end
        Quiesce: begin
          if (!pres_eff) begin
            state_q <= Fault;
            fault_q <= FaultRemoved;
            fault_event_o <= 1'b1;
            slot_desc_q <= '0;
          end else if (drain_i) begin
            state_q <= Quiesced;
            slot_desc_q <= '0;
          end
        end
        Quiesced: begin
          if (!pres_eff) state_q <= Absent;
        end
        Fault: begin
          if (!pres_eff && fault_clear_i) begin
            state_q <= Absent;
            fault_q <= FaultNone;
          end
        end
        default: state_q <= Fault;
      endcase
    end
  end

  assign power_en_o = powered(state_q);
  assign desc_req_o = state_q == Identify;
  assign desc_addr_o = idx_q;
  assign init_req_o = state_q == Initialize;
  assign state_o = state_q;
  assign fault_o = fault_q;
  assign slot_desc_o = state_q == Ready ? slot_desc_q :
                       '{present: 1'b0, identity: '0, ram_bytes: '0,
                         reserved_bytes: '0};
  assign ram_ready_o = state_q == Ready && flags_q[0];
  assign flash_ready_o = state_q == Ready && flags_q[1];
  assign persist_ready_o = 1'b0;
  assign persist_cap_o = state_q == Ready && flags_q[2];
  assign flash_bytes_o = state_q == Ready ? flash_q : '0;
  assign erase_bytes_o = state_q == Ready ? erase_q : '0;
endmodule
