// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Coordinated, same-clock model binding. Native activation, privileged control,
// physical power/flash qualification and coherence providers remain external.
module g6lc_storamic_checkpoint_model #(
  parameter int unsigned NumProducers = 2,
  parameter int unsigned ModelBytes = 64,
  parameter int unsigned RawFlashBytes = 1024,
  parameter int unsigned RamRspCycles = 0,
  parameter int unsigned FlashRspCycles = 0,
  parameter int unsigned StageEntries = 4,
  parameter int unsigned CommitCycles = 4,
  parameter int unsigned TimeoutCycles = 4096
) (
  input logic clk_i, rst_ni,
  input logic present_i, identity_valid_i, protection_ok_i, power_cut_i,
  input logic [159:0] module_id_i,
  input logic [31:0] mapping_generation_i, reset_generation_i,
  input logic command_valid_i, command_restore_i, authorized_i,
  input logic [31:0] command_cookie_i,
  output logic command_ready_o, result_valid_o,
  input logic result_ready_i,
  output logic [31:0] result_cookie_o,
  output g6lc_storamic_pkg::checkpoint_result_e result_o,
  input logic restore_resume_safe_i,
  output logic producer_pause_o, axi_quiesce_o, media_hold_o,
  input logic [NumProducers-1:0] producer_paused_i, producer_error_i,
  input logic axi_quiesced_i,
  output logic initialized_o, busy_o, recovery_locked_o,
  output logic checkpoint_valid_o, metadata_ok_o, degraded_o,
  output logic [63:0] checkpoint_generation_o, block_sectors_o, reserved_bytes_o,
  output logic [3:0] phase_o,
  output logic [5:0] media_phase_o,
  output logic [2:0] guard_phase_o,
  output logic done_event_o, error_event_o, refuse_event_o, stale_event_o,
  // Existing canonical tagged, relative-byte-address RAM seam.
  output logic mem_ready_o,
  input logic mem_req_i, mem_we_i,
  output logic mem_gnt_o,
  input logic [63:0] mem_addr_i, mem_wdata_i,
  input logic [7:0] mem_be_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic mem_rvalid_o, mem_error_o,
  output logic [63:0] mem_rdata_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  input logic st_req_i, st_we_i,
  output logic st_gnt_o,
  input logic [63:0] st_addr_i, st_wdata_i,
  input logic [7:0] st_be_i,
  output logic st_rvalid_o, st_error_o,
  output logic [63:0] st_rdata_o,
  input logic st_flush_req_i,
  output logic st_flush_ack_o, st_flush_error_o
);
  import g6lc_storamic_pkg::*;
  import g6lc_storamic_checkpoint_pkg::*;
  localparam checkpoint_layout_t Layout = checkpoint_layout(
      64'(RawFlashBytes), 64'(ModelBytes), 64'd0, 1'b0);
  // pragma translate_off
  initial begin
    if (!Layout.legal || ModelBytes < 16 || ModelBytes % 8 != 0 ||
        NumProducers < 1 || NumProducers > 8 ||
        64'(TimeoutCycles) < 64'(ModelBytes / 8) * 32 + 64)
      $fatal(1, "STORAMIC_CHECKPOINT_MODEL_CONFIG");
  end
  // pragma translate_on
  assign block_sectors_o = Layout.user_bytes >> 9;
  assign reserved_bytes_o = Layout.reserved_bytes;

  logic boot_cut_q, boot_ready_q;
  logic ram_busy, prepared, prepared_bank, commit_ram, abort_ram, prepare_ram;
  logic restore_ram, restore_done, restore_error;
  logic cp_bank, meta_recovered, meta_idle, meta_owned, maintenance, exclusive;
  logic publish_req, publish_ack, publish_error, abort_meta;
  logic [159:0] publish_id;
  logic [31:0] publish_map;
  logic [63:0] publish_generation;
  logic publish_bank;
  logic cf_req, cf_ack, cf_error, flash_idle, flash_drained;
  logic guard_idle;
  assign exclusive = axi_quiesced_i && (&producer_paused_i) &&
                     guard_idle && !st_flush_req_i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin boot_cut_q <= 1; boot_ready_q <= 0; end
    else begin
      boot_cut_q <= 0;
      if (!boot_cut_q && !ram_busy) boot_ready_q <= 1;
    end
  end
  g6lc_storamic_checkpoint_ctrl #(
    .NumProducers(NumProducers), .TimeoutCycles(TimeoutCycles)
  ) i_ctrl (
    .clk_i, .rst_ni, .command_valid_i, .command_ready_o, .command_restore_i,
    .command_cookie_i, .authorized_i, .protection_ok_i(protection_ok_i && !degraded_o),
    .power_cut_i, .identity_valid_i(identity_valid_i && present_i),
    .module_id_i, .mapping_generation_i,
    .boot_memory_ready_i(boot_ready_q && !ram_busy && (&producer_paused_i)),
    .metadata_recovered_i(meta_recovered), .metadata_ok_i(metadata_ok_o),
    .checkpoint_valid_i(checkpoint_valid_o), .checkpoint_bank_i(cp_bank),
    .checkpoint_generation_i(checkpoint_generation_o), .restore_resume_safe_i,
    .result_valid_o, .result_ready_i, .result_cookie_o, .result_o,
    .initialized_o, .busy_o, .recovery_locked_o, .phase_o,
    .event_done_o(done_event_o), .event_error_o(error_event_o),
    .producer_pause_o, .producer_paused_i, .producer_error_i,
    .axi_quiesce_o, .axi_quiesced_i,
    .ram_prepare_o(prepare_ram), .ram_prepared_i(prepared), .ram_prepared_bank_i(prepared_bank),
    .ram_busy_i(ram_busy), .ram_error_i(restore_error), .ram_commit_o(commit_ram),
    .ram_abort_o(abort_ram), .ram_restore_o(restore_ram), .ram_restore_done_i(restore_done),
    .flash_flush_req_o(cf_req), .flash_flush_ack_i(cf_ack), .flash_flush_error_i(cf_error),
    .flash_idle_i(flash_idle && guard_idle && !st_flush_req_i),
    .metadata_publish_req_o(publish_req), .metadata_publish_ack_i(publish_ack),
    .metadata_publish_error_i(publish_error), .metadata_abort_o(abort_meta),
    .metadata_idle_i(meta_idle), .publish_module_id_o(publish_id),
    .publish_mapping_generation_o(publish_map), .publish_generation_o(publish_generation),
    .publish_bank_o(publish_bank)
  );

  logic rr, rg, rw, rrv, re, ram_owner_q;
  logic [63:0] ra, rd, rdata;
  logic [7:0] rb;
  txn_id_t rt, returned_tag;
  logic mr, mg, mw;
  logic [63:0] ma, md;
  logic [7:0] mb;
  txn_id_t mt;
  assign rr = maintenance ? mr : mem_req_i;
  assign rw = maintenance ? mw : mem_we_i;
  assign ra = maintenance ? ma : mem_addr_i;
  assign rd = maintenance ? md : mem_wdata_i;
  assign rb = maintenance ? mb : mem_be_i;
  assign rt = maintenance ? mt : mem_tag_i;
  assign mg = maintenance && rg;
  assign mem_gnt_o = !maintenance && rg;
  assign mem_rvalid_o = rrv && !ram_owner_q;
  assign mem_error_o = re;
  assign mem_rdata_o = rdata;
  assign mem_tag_o = returned_tag;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ram_owner_q <= 0;
    else if (rr && rg) ram_owner_q <= maintenance;
  end
  g6lc_storamic_sim_mem #(
    .NumWords(ModelBytes / 8), .ModelBytes(64'(ModelBytes)), .RspDelay(RamRspCycles),
    .ExternalCheckpointCommit(1'b1), .ExternalFlashCheckpoint(1'b1)
  ) i_ram (
    .clk_i, .rst_ni, .mem_ready_o, .mem_req_i(rr), .mem_gnt_o(rg), .mem_we_i(rw),
    .mem_addr_i(ra), .mem_wdata_i(rd), .mem_be_i(rb), .mem_tag_i(rt),
    .mem_rvalid_o(rrv), .mem_rdata_o(rdata), .mem_error_o(re), .mem_tag_o(returned_tag),
    .power_cut_i(power_cut_i || boot_cut_q), .save_i(prepare_ram), .restore_i(1'b0),
    .checkpoint_valid_i(checkpoint_valid_o), .checkpoint_bank_i(cp_bank),
    .checkpoint_commit_i(commit_ram), .checkpoint_abort_i(abort_ram), .maintenance_i(maintenance),
    .checkpoint_prepared_o(prepared), .checkpoint_prepared_bank_o(prepared_bank),
    .save_busy_o(ram_busy), .restore_done_o()
  );

  logic nr, ng, nw, nrv, ne, nv_owner_q;
  logic [63:0] na, nd, ndata;
  logic [7:0] nb;
  logic dr, dg, dw, mf_req, mf_ack, mf_error;
  logic [63:0] da, dd;
  logic [7:0] db;
  logic ur, ug, uw;
  logic [63:0] ua, ud;
  logic [7:0] ub;
  assign nr = meta_owned ? dr : ur;
  assign nw = meta_owned ? dw : uw;
  assign na = meta_owned ? da : ua;
  assign nd = meta_owned ? dd : ud;
  assign nb = meta_owned ? db : ub;
  assign dg = meta_owned && ng;
  assign ug = !meta_owned && ng;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) nv_owner_q <= 0;
    else if (nr && ng) nv_owner_q <= meta_owned;
  end
  g6lc_storamic_store_guard i_guard (
    .clk_i, .rst_ni, .enable_i(metadata_ok_o && present_i && identity_valid_i),
    .capacity_bytes_i(Layout.user_bytes), .idle_o(guard_idle),
    .refuse_event_o, .phase_o(guard_phase_o), .st_req_i, .st_gnt_o, .st_we_i,
    .st_addr_i, .st_wdata_i, .st_be_i, .st_rvalid_o, .st_rdata_o, .st_error_o,
    .down_req_o(ur), .down_gnt_i(ug), .down_we_o(uw), .down_addr_o(ua),
    .down_wdata_o(ud), .down_be_o(ub), .down_rvalid_i(nrv && !nv_owner_q),
    .down_rdata_i(ndata), .down_error_i(ne)
  );

  typedef enum logic [1:0] {FUser, FControl, FMedia} flush_owner_e;
  flush_owner_e flush_owner_q, selected_flush;
  logic flush_active_q, nf_req, nf_ack, nf_error;
  always_comb begin
    selected_flush = flush_active_q ? flush_owner_q :
                     meta_owned ? FMedia : cf_req ? FControl : FUser;
    case (selected_flush)
      FUser: nf_req = st_flush_req_i;
      FControl: nf_req = cf_req;
      FMedia: nf_req = mf_req;
      default: nf_req = 0;
    endcase
  end
  // Flush has no grant: capture its requester before the completion can arrive.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin flush_active_q <= 0; flush_owner_q <= FUser; end
    else if (nf_ack) flush_active_q <= 0;
    else if (!flush_active_q && nf_req) begin
      flush_active_q <= 1; flush_owner_q <= selected_flush;
    end
  end
  assign st_flush_ack_o = nf_ack && flush_active_q && flush_owner_q == FUser;
  assign st_flush_error_o = nf_error;
  assign cf_ack = nf_ack && flush_active_q && flush_owner_q == FControl;
  assign cf_error = nf_error;
  assign mf_ack = nf_ack && flush_active_q && flush_owner_q == FMedia;
  assign mf_error = nf_error;
  // Keep policy ownership through accepted word responses, dirty staging,
  // metadata activity and every flush owner. This does not request a flush.
  assign media_hold_o = meta_owned || maintenance || !guard_idle ||
                        !flash_drained || flush_active_q || nf_req;
  g6lc_storamic_durable_store #(
    .NumWords(RawFlashBytes / 8), .StageEntries(StageEntries),
    .RspCycles(FlashRspCycles), .CommitCycles(CommitCycles)
  ) i_flash (
    .clk_i, .rst_ni, .power_cut_i, .idle_o(flash_idle), .drained_o(flash_drained),
    .st_req_i(nr), .st_gnt_o(ng), .st_we_i(nw), .st_addr_i(na),
    .st_wdata_i(nd), .st_be_i(nb), .st_rvalid_o(nrv), .st_rdata_o(ndata), .st_err_o(ne),
    .st_flush_req_i(nf_req), .st_flush_ack_o(nf_ack), .st_flush_err_o(nf_error),
    .save_i(1'b0), .save_done_o(), .cut_count_o(), .commit_gen_o(),
    .journal_gen_o(), .journal_id_o(), .unlock_key_i(32'd0),
    .restore_i(1'b0), .restore_done_o()
  );
  g6lc_storamic_checkpoint_media #(
    .ImageBytes(64'(ModelBytes)), .RawFlashBytes(64'(RawFlashBytes))
  ) i_media (
    .clk_i, .rst_ni, .available_i(present_i && identity_valid_i),
    .protection_ok_i, .power_cut_i, .exclusive_i(exclusive),
    .module_id_i, .mapping_generation_i, .reset_generation_i,
    .publish_req_i(publish_req), .publish_ack_o(publish_ack), .publish_error_o(publish_error),
    .publish_module_id_i(publish_id), .publish_mapping_generation_i(publish_map),
    .publish_generation_i(publish_generation), .publish_bank_i(publish_bank),
    .abort_i(abort_meta), .restore_i(restore_ram),
    .restore_done_o(restore_done), .restore_error_o(restore_error), .restore_busy_o(),
    .recovered_o(meta_recovered), .metadata_ok_o, .checkpoint_valid_o,
    .checkpoint_bank_o(cp_bank), .checkpoint_generation_o,
    .idle_o(meta_idle), .maintenance_o(maintenance), .media_owned_o(meta_owned),
    .degraded_o, .tag_exhausted_o(), .stale_event_o, .error_event_o(), .phase_o(media_phase_o),
    .layout_legal_o(), .user_capacity_bytes_o(), .reserved_bytes_o(),
    .mem_req_o(mr), .mem_gnt_i(mg), .mem_we_o(mw), .mem_addr_o(ma),
    .mem_wdata_o(md), .mem_be_o(mb), .mem_tag_o(mt),
    .mem_rvalid_i(rrv && ram_owner_q), .mem_rdata_i(rdata), .mem_error_i(re),
    .mem_tag_i(returned_tag),
    .st_req_o(dr), .st_gnt_i(dg), .st_we_o(dw), .st_addr_o(da),
    .st_wdata_o(dd), .st_be_o(db), .st_rvalid_i(nrv && nv_owner_q),
    .st_rdata_i(ndata), .st_error_i(ne), .st_flush_req_o(mf_req),
    .st_flush_ack_i(mf_ack), .st_flush_error_i(mf_error), .store_idle_i(flash_idle)
  );
endmodule
