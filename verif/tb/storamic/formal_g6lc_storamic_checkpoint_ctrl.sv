// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Control safety under abstract, single-owner participants. Data integrity is
// checked separately by the integrated AXI/RAM/flash simulation.
module formal_g6lc_storamic_checkpoint_ctrl #(
  parameter bit OracleNegative = 1'b0
) (
  input logic clk_i, rst_ni, command_valid_i, command_restore_i,
  input logic [31:0] command_cookie_i,
  input logic authorized_i, protection_ok_i, power_cut_i, result_ready_i,
  input logic [1:0] paused_i, producer_error_i,
  input logic axi_drained_i, flash_finish_i, flash_error_i,
  input logic metadata_finish_i, metadata_error_i, restore_finish_i, resume_safe_i,
  output logic cover_save_o, cover_restore_o, cover_error_o
);
  import g6lc_storamic_pkg::*;
  logic ready, result_valid, initialized, busy, locked, pause_req, seal;
  logic [31:0] cookie;
  checkpoint_result_e result;
  logic done_event, error_event, prepare, prepared, prepared_bank;
  logic commit_ram, abort_ram, restore_ram, restoring, restore_done;
  logic freq, fack, ferr, fpending, fseen;
  logic mreq, mack, merr, mabort, mpending, mseen;
  logic valid, bank, stored_valid, stored_bank, pub_bank;
  logic [63:0] generation, stored_generation, pub_generation;
  logic [1:0] paused;
  assign paused = pause_req ? paused_i : 2'b00;
  assign fack = fpending && (flash_finish_i || power_cut_i);
  assign ferr = power_cut_i || flash_error_i;
  assign mack = mpending && (metadata_finish_i || mabort || power_cut_i);
  assign merr = metadata_error_i || mabort || power_cut_i;
  // A successful publication acknowledges an already-visible selection.
  assign valid = (mack && !merr) || stored_valid;
  assign bank = mack && !merr ? pub_bank : stored_bank;
  assign generation = mack && !merr ? pub_generation : stored_generation;

  g6lc_storamic_checkpoint_ctrl #(
    .NumProducers(2), .IdentityWidth(8), .TimeoutCycles(16)
  ) dut (
    .clk_i, .rst_ni, .command_valid_i, .command_ready_o(ready), .command_restore_i,
    .command_cookie_i, .authorized_i, .protection_ok_i, .power_cut_i,
    .identity_valid_i(1'b1), .module_id_i(8'h53), .mapping_generation_i(32'd7),
    .boot_memory_ready_i(1'b1), .metadata_recovered_i(1'b1), .metadata_ok_i(1'b1),
    .checkpoint_valid_i(valid), .checkpoint_bank_i(bank), .checkpoint_generation_i(generation),
    .restore_resume_safe_i(resume_safe_i), .result_valid_o(result_valid),
    .result_ready_i, .result_cookie_o(cookie), .result_o(result),
    .initialized_o(initialized), .busy_o(busy), .recovery_locked_o(locked), .phase_o(),
    .event_done_o(done_event), .event_error_o(error_event),
    .producer_pause_o(pause_req), .producer_paused_i(paused), .producer_error_i,
    .axi_quiesce_o(seal), .axi_quiesced_i(seal && axi_drained_i),
    .ram_prepare_o(prepare), .ram_prepared_i(prepared), .ram_prepared_bank_i(prepared_bank),
    .ram_busy_i(prepared || restoring), .ram_error_i(1'b0),
    .ram_commit_o(commit_ram), .ram_abort_o(abort_ram), .ram_restore_o(restore_ram),
    .ram_restore_done_i(restore_done),
    .flash_flush_req_o(freq), .flash_flush_ack_i(fack), .flash_flush_error_i(ferr),
    .flash_idle_i(!fpending && !freq),
    .metadata_publish_req_o(mreq), .metadata_publish_ack_i(mack),
    .metadata_publish_error_i(merr), .metadata_abort_o(mabort),
    .metadata_idle_i(!mpending && !mreq),
    .publish_module_id_o(), .publish_mapping_generation_o(),
    .publish_generation_o(pub_generation), .publish_bank_o(pub_bank)
  );
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fpending <= 0; fseen <= 0; mpending <= 0; mseen <= 0;
      prepared <= 0; prepared_bank <= 0; restoring <= 0; restore_done <= 0;
      stored_valid <= 0; stored_bank <= 0; stored_generation <= 0;
    end else begin
      if (!freq) fseen <= 0;
      if (freq && !fseen) begin fpending <= 1; fseen <= 1; end
      if (fack) fpending <= 0;
      if (!mreq) mseen <= 0;
      if (mreq && !mseen) begin mpending <= 1; mseen <= 1; end
      if (mack) begin
        mpending <= 0;
        if (!merr) begin
          stored_valid <= 1; stored_bank <= pub_bank; stored_generation <= pub_generation;
        end
      end
      restore_done <= 0;
      if (prepare) begin prepared <= 1; prepared_bank <= !bank; end
      if (restore_ram) restoring <= 1;
      if (restoring && restore_finish_i) begin restoring <= 0; restore_done <= 1; end
      if (commit_ram) prepared <= 0;
      if (abort_ram || power_cut_i) begin
        prepared <= 0; restoring <= 0; restore_done <= 0;
      end
    end
  end

  logic owned, owner_restore, flash_done_seen, metadata_committed;
  logic past_valid, stalled_p, locked_p, initialized_p, cut_p;
  logic [31:0] owner_cookie, cookie_p;
  checkpoint_result_e result_p;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      owned <= 0; owner_restore <= 0; owner_cookie <= 0;
      flash_done_seen <= 0; metadata_committed <= 0;
      past_valid <= 0; stalled_p <= 0; locked_p <= 0; initialized_p <= 0; cut_p <= 0;
      result_p <= CP_OK; cookie_p <= 0;
      cover_save_o <= 0; cover_restore_o <= 0; cover_error_o <= 0;
    end else begin
      past_valid <= 1;
      stalled_p <= result_valid && !result_ready_i;
      locked_p <= locked; initialized_p <= initialized; cut_p <= power_cut_i;
      result_p <= result; cookie_p <= cookie;
      if (command_valid_i && ready) begin
        owned <= 1; owner_cookie <= command_cookie_i; owner_restore <= command_restore_i;
        flash_done_seen <= 0; metadata_committed <= 0;
      end
      if (result_valid && result_ready_i) owned <= 0;
      if (fack && !ferr) flash_done_seen <= 1;
      if (mack && !merr) metadata_committed <= 1;
      if (done_event && !owner_restore) cover_save_o <= 1;
      if (done_event && owner_restore) cover_restore_o <= 1;
      if (error_event && owned) cover_error_o <= 1;
    end
  end
  always_comb begin
    if (rst_ni) begin
      if (ready) assert (initialized && !busy && !result_valid);
      if (result_valid) assert (owned && cookie == owner_cookie);
      if (prepare || restore_ram || commit_ram)
        assert (seal && axi_drained_i && (&paused) && !power_cut_i);
      if (mreq && !mseen && !power_cut_i)
        assert (prepared && flash_done_seen && seal);
      if (commit_ram) assert (metadata_committed && prepared);
      if (done_event) assert (result_valid && result == CP_OK && !busy && !locked && !seal);
      if (past_valid && stalled_p)
        assert (result_valid && result == result_p && cookie == cookie_p);
      if (past_valid && locked_p && initialized_p && !locked)
        assert (done_event && owner_restore);
      if (past_valid && cut_p) assert (locked);
      if (OracleNegative) assert (!prepare);
    end
  end
endmodule
