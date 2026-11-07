// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Single-clock maintenance owner. Every enabled writer must provide a real
// job-drain acknowledgement. Metadata publication is a separate, durable
// participant: this controller never substitutes reset flops for its record.
module g6lc_storamic_checkpoint_ctrl #(
  parameter int unsigned NumProducers = 1,
  parameter int unsigned IdentityWidth = 160,
  parameter int unsigned TimeoutCycles = 1024
) (
  input logic clk_i,
  input logic rst_ni,
  input logic command_valid_i,
  output logic command_ready_o,
  input logic command_restore_i,
  input logic [31:0] command_cookie_i,
  input logic authorized_i,
  input logic protection_ok_i,
  input logic power_cut_i,
  input logic identity_valid_i,
  input logic [IdentityWidth-1:0] module_id_i,
  input logic [31:0] mapping_generation_i,
  // Boot firmware runs outside the protected window. Blank-media boot may
  // open initialized RAM; an existing checkpoint requires explicit restore.
  input logic boot_memory_ready_i,
  input logic metadata_recovered_i,
  input logic metadata_ok_i,
  input logic checkpoint_valid_i,
  input logic checkpoint_bank_i,
  input logic [63:0] checkpoint_generation_i,
  input logic restore_resume_safe_i,
  output logic result_valid_o,
  input logic result_ready_i,
  output logic [31:0] result_cookie_o,
  output g6lc_storamic_pkg::checkpoint_result_e result_o,
  output logic initialized_o,
  output logic busy_o,
  output logic recovery_locked_o,
  output logic [3:0] phase_o,
  output logic event_done_o,
  output logic event_error_o,
  output logic producer_pause_o,
  input logic [NumProducers-1:0] producer_paused_i,
  input logic [NumProducers-1:0] producer_error_i,
  output logic axi_quiesce_o,
  input logic axi_quiesced_i,
  output logic ram_prepare_o,
  input logic ram_prepared_i,
  input logic ram_prepared_bank_i,
  input logic ram_busy_i,
  input logic ram_error_i,
  output logic ram_commit_o,
  output logic ram_abort_o,
  output logic ram_restore_o,
  input logic ram_restore_done_i,
  output logic flash_flush_req_o,
  input logic flash_flush_ack_i,
  input logic flash_flush_error_i,
  input logic flash_idle_i,
  output logic metadata_publish_req_o,
  input logic metadata_publish_ack_i,
  input logic metadata_publish_error_i,
  output logic metadata_abort_o,
  input logic metadata_idle_i,
  output logic [IdentityWidth-1:0] publish_module_id_o,
  output logic [31:0] publish_mapping_generation_o,
  output logic [63:0] publish_generation_o,
  output logic publish_bank_o
);
  import g6lc_storamic_pkg::*;
  localparam int unsigned TW = TimeoutCycles > 1 ? $clog2(TimeoutCycles) : 1;
  typedef enum logic [3:0] {
    CIdle, CPause, CSeal, CPrepare, CWaitPrepare, CPublish,
    CRelease, CWaitRelease, CRestore, CWaitRestore, CSync, CAbort
  } state_e;
  typedef struct packed {
    state_e state;
    logic initialized, locked, sealed;
    logic restoring, restore_started, metadata_issued;
    logic flash_pending, flash_done, metadata_pending;
    logic [TW-1:0] timer;
    logic [IdentityWidth-1:0] module_id;
    logic [IdentityWidth-1:0] service_module_id;
    logic [31:0] service_mapping_generation;
    logic [31:0] mapping_generation, cookie;
    logic [63:0] generation;
    logic old_valid, old_bank, target_bank;
    logic result_valid, event_done, event_error;
    checkpoint_result_e result;
  } control_t;
  control_t q, d;
  logic active, context_matches, image_matches, service_matches, abort_now, lock_on_error;
  checkpoint_result_e abort_result;

  // pragma translate_off
  initial begin
    if (NumProducers == 0 || IdentityWidth == 0 || TimeoutCycles == 0)
      $fatal(1, "STORAMIC_CHECKPOINT_PARAM");
  end
  // pragma translate_on

  assign active = q.state != CIdle && q.state != CAbort;
  assign initialized_o = q.initialized;
  assign command_ready_o = q.initialized && q.state == CIdle && !q.result_valid;
  assign result_valid_o = q.result_valid;
  assign result_cookie_o = q.cookie;
  assign result_o = q.result;
  assign busy_o = q.state != CIdle;
  assign recovery_locked_o = q.locked;
  assign phase_o = q.state;
  assign event_done_o = q.event_done;
  assign event_error_o = q.event_error;
  assign producer_pause_o = busy_o || q.locked;
  assign axi_quiesce_o = q.sealed || q.locked;
  assign ram_prepare_o = q.state == CPrepare && !abort_now && !power_cut_i;
  assign ram_restore_o = q.state == CRestore && !abort_now && !power_cut_i;
  assign ram_commit_o = q.state == CRelease && !abort_now && !power_cut_i;
  assign ram_abort_o = q.state == CAbort;
  assign flash_flush_req_o = q.flash_pending;
  assign metadata_publish_req_o = q.metadata_pending;
  assign metadata_abort_o = q.state == CAbort && q.metadata_pending;
  assign publish_module_id_o = q.module_id;
  assign publish_mapping_generation_o = q.mapping_generation;
  assign publish_generation_o = q.generation + 64'd1;
  assign publish_bank_o = q.target_bank;
  assign context_matches = identity_valid_i && module_id_i == q.module_id &&
      mapping_generation_i == q.mapping_generation &&
      metadata_recovered_i && metadata_ok_i;
  assign image_matches = checkpoint_valid_i == q.old_valid &&
      checkpoint_bank_i == q.old_bank && checkpoint_generation_i == q.generation;
  assign service_matches = identity_valid_i && module_id_i == q.service_module_id &&
      mapping_generation_i == q.service_mapping_generation;

  always_comb begin
    abort_now = 1'b0;
    abort_result = CP_OK;
    lock_on_error = q.restore_started || q.metadata_issued;
    if (active) begin
      if (power_cut_i) begin
        abort_now = 1'b1; abort_result = CP_POWER_CUT; lock_on_error = 1'b1;
      end else if (!context_matches ||
                   ((q.restoring || !q.metadata_issued) && !image_matches)) begin
        abort_now = 1'b1; abort_result = CP_CONTEXT_CHANGED; lock_on_error = 1'b1;
      end else if ((|producer_error_i) && q.state != CSync) begin
        abort_now = 1'b1; abort_result = CP_PRODUCER_ERROR;
      end else if ((q.state == CPrepare || q.state == CWaitPrepare ||
                    q.state == CPublish || q.state == CRelease ||
                    q.state == CWaitRelease || q.state == CRestore ||
                    q.state == CWaitRestore) &&
                   (!axi_quiesced_i || !(&producer_paused_i))) begin
        abort_now = 1'b1; abort_result = CP_PROTOCOL_ERROR; lock_on_error = 1'b1;
      end else if ((q.state == CPublish || q.state == CRelease) &&
                   (!ram_prepared_i || ram_prepared_bank_i != q.target_bank)) begin
        abort_now = 1'b1; abort_result = CP_PROTOCOL_ERROR; lock_on_error = 1'b1;
      end else if (ram_error_i ||
                   (q.flash_pending && flash_flush_ack_i && flash_flush_error_i) ||
                   (q.metadata_pending && metadata_publish_ack_i &&
                    metadata_publish_error_i)) begin
        abort_now = 1'b1; abort_result = CP_MEDIA_ERROR;
      end else if (!q.restoring && !protection_ok_i) begin
        abort_now = 1'b1; abort_result = CP_NOT_READY;
      end else if (q.timer == TW'(TimeoutCycles - 1)) begin
        abort_now = 1'b1; abort_result = CP_TIMEOUT; lock_on_error = 1'b1;
      end
    end
  end

  always_comb begin
    d = q;
    d.event_done = 1'b0;
    d.event_error = 1'b0;
    if (q.result_valid && result_ready_i) d.result_valid = 1'b0;
    if (active && !abort_now) d.timer = q.timer + 1'b1;
    // An abort never withdraws an offered flush/publication. The participant
    // must retire it (possibly with error); a silent participant stays locked.
    if (q.flash_pending && flash_flush_ack_i) begin
      d.flash_pending = 1'b0;
      d.flash_done = !flash_flush_error_i;
    end
    if (q.metadata_pending && metadata_publish_ack_i)
      d.metadata_pending = 1'b0;
    if (!q.initialized && metadata_recovered_i && metadata_ok_i &&
        boot_memory_ready_i && identity_valid_i && !power_cut_i) begin
      d.initialized = 1'b1;
      d.locked = checkpoint_valid_i;
      d.service_module_id = module_id_i;
      d.service_mapping_generation = mapping_generation_i;
    end
    if (!abort_now) begin
      case (q.state)
        CIdle: if (command_valid_i && command_ready_o) begin
          d.cookie = command_cookie_i;
          d.result = CP_OK;
          d.restoring = command_restore_i;
          d.restore_started = 1'b0;
          d.metadata_issued = 1'b0;
          d.flash_done = 1'b0;
          d.timer = '0;
          d.module_id = module_id_i;
          d.mapping_generation = mapping_generation_i;
          d.generation = checkpoint_generation_i;
          d.old_valid = checkpoint_valid_i;
          d.old_bank = checkpoint_bank_i;
          if (!authorized_i) d.result = CP_DENIED;
          else if (power_cut_i) d.result = CP_POWER_CUT;
          else if (!identity_valid_i || !metadata_recovered_i || !metadata_ok_i)
            d.result = CP_NOT_READY;
          else if ((q.locked || !service_matches) &&
                   (!command_restore_i || !(&producer_paused_i) ||
                    (|producer_error_i))) d.result = CP_RECOVERY_REQUIRED;
          else if (command_restore_i && !checkpoint_valid_i) d.result = CP_NO_CHECKPOINT;
          else if (!command_restore_i && !protection_ok_i) d.result = CP_NOT_READY;
          else if (!command_restore_i && &checkpoint_generation_i)
            d.result = CP_GENERATION_EXHAUSTED;
          else if (|producer_error_i) d.result = CP_PRODUCER_ERROR;
          if (d.result == CP_OK) d.state = CPause;
          else begin
            d.result_valid = 1'b1;
            d.event_error = 1'b1;
          end
        end
        CPause: if (&producer_paused_i) begin
          d.sealed = 1'b1;
          d.state = CSeal;
        end
        CSeal: if (axi_quiesced_i && !ram_busy_i && !ram_prepared_i &&
                   flash_idle_i && metadata_idle_i &&
                   !flash_flush_ack_i && !metadata_publish_ack_i && !ram_restore_done_i)
          d.state = q.restoring ? CRestore : CPrepare;
        CPrepare: begin
          d.flash_pending = 1'b1;
          d.state = CWaitPrepare;
        end
        CWaitPrepare: if (ram_prepared_i && q.flash_done) begin
          if (ram_prepared_bank_i == q.old_bank) begin
            d.state = CAbort; d.locked = 1'b1;
            d.result = CP_PROTOCOL_ERROR; d.result_valid = 1'b1; d.event_error = 1'b1;
          end else if (flash_idle_i && metadata_idle_i) begin
            d.target_bank = ram_prepared_bank_i;
            d.metadata_issued = 1'b1;
            d.metadata_pending = 1'b1;
            d.state = CPublish;
          end
        end
        CPublish: if (q.metadata_pending && metadata_publish_ack_i) begin
          if (!checkpoint_valid_i || checkpoint_bank_i != q.target_bank ||
              checkpoint_generation_i != publish_generation_o) begin
            d.state = CAbort; d.locked = 1'b1;
            d.result = CP_PROTOCOL_ERROR; d.result_valid = 1'b1; d.event_error = 1'b1;
          end else d.state = CRelease;
        end
        CRelease: d.state = CWaitRelease;
        CWaitRelease: if (!ram_prepared_i && !ram_busy_i &&
                         flash_idle_i && metadata_idle_i) begin
          d.state = CIdle; d.sealed = 1'b0;
          d.result = CP_OK; d.result_valid = 1'b1; d.event_done = 1'b1;
        end
        CRestore: begin
          d.restore_started = 1'b1;
          d.state = CWaitRestore;
        end
        CWaitRestore: if (ram_restore_done_i && !ram_busy_i) d.state = CSync;
        CSync: if (restore_resume_safe_i && (&producer_paused_i) &&
                   !(|producer_error_i) && axi_quiesced_i &&
                   flash_idle_i && metadata_idle_i) begin
          d.state = CIdle; d.sealed = 1'b0; d.locked = 1'b0;
          d.service_module_id = q.module_id;
          d.service_mapping_generation = q.mapping_generation;
          d.result = CP_OK; d.result_valid = 1'b1; d.event_done = 1'b1;
        end
        CAbort: if (!power_cut_i && !ram_busy_i && !ram_prepared_i &&
                   !q.flash_pending && !q.metadata_pending &&
                   flash_idle_i && metadata_idle_i) begin
          d.state = CIdle; d.sealed = 1'b0;
        end
        default: begin
          d.state = CAbort; d.locked = 1'b1;
          d.result = CP_PROTOCOL_ERROR; d.result_valid = 1'b1; d.event_error = 1'b1;
        end
      endcase
    end else begin
      d.state = CAbort;
      d.locked = q.locked || lock_on_error;
      d.result = abort_result;
      d.result_valid = 1'b1;
      d.event_error = 1'b1;
    end
    // A changed/unknown idle context must not expose old live RAM just because
    // no maintenance command was active. Recovery, not a new save, rebinds it.
    if (q.initialized && q.state == CIdle &&
        (!service_matches || !metadata_recovered_i || !metadata_ok_i)) begin
      d.locked = 1'b1;
      if (!q.locked) d.event_error = 1'b1;
    end
    if (power_cut_i) d.locked = 1'b1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q <= '0;
      q.state <= CIdle;
      q.locked <= 1'b1;
    end else q <= d;
  end
endmodule
