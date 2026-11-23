// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-018/ST-037C model of one Storamic stick: the removable module whose
// population carries a RAM chip and a flash chip side by side. This module
// is the single source of the stick's identity and geometry so that the two
// host transports that reach it — the memory path (AXI frontend -> mem_*
// seam -> the stick's RAM chip) and the block path (VirtIO device -> st_*
// seam -> the stick's flash chip) — publish one coherent stick.
//
// Composition, matching the architecture's per-stick descriptor:
//   - the RAM chip is g6lc_storamic_sim_mem, instantiated inside
//     g6lc_storamic_attach behind the controller's mem_* binding (the
//     controller-to-stick memory interface); RamWords publishes its depth;
//   - the flash chip is g6lc_storamic_durable_store, instantiated here
//     behind the store seam; it reports durable (write-back staging that
//     commits on FLUSH), which is what lets VIRTIO_BLK_F_FLUSH be offered.
//
// The published fields mirror the discovery descriptor (descriptor words
// 2/4/8): a nonzero identity, RAM bytes and flash bytes. `present_o` is the
// model stand-in for slot presence; ST-014's real discovery pad binding
// replaces it, at which point device_usable derives from slot READY.
// Everything here is model truth, not media qualification.
// Bandwidth is adjustable per chip: the RAM chip's response stretch lives
// on g6lc_storamic_sim_mem (RspDelay, plumbed through the attach), and the
// flash chip's interface (RspCycles) and media program time (CommitCycles)
// live on the durable store. power_cut_i drops the flash chip's
// uncommitted staging for persistence-domain work.
module g6lc_storamic_model_stick #(
  parameter int unsigned RamWords = 8192,       // RAM chip depth (64-bit words)
  parameter int unsigned FlashWords = 8192,     // flash chip depth (sectors below)
  parameter int unsigned StageEntries = 8,      // flash write-back staging
  parameter int unsigned FlashRspCycles = 0,    // flash interface stretch
  parameter int unsigned FlashCommitCycles = 1, // flash program time per entry
  parameter logic [31:0] Identity = 32'h5354_4D31,  // "STM1" stick identity
  parameter logic [159:0] Serial =
      160'h304C_4544_4F4D_2D43_494D_4152_4F54_532D_434C_3647 // "G6LC-STORAMIC-MODEL0"
) (
  input logic clk_i,
  input logic rst_ni,
  input logic power_cut_i,
  // ST-025 stick save: drains flash staging (commit) — the RAM chip's
  // snapshot runs on the mem_* side. save_done_o = flash staging committed.
  input logic save_i,
  output logic save_done_o,
  // Model save interlock and diagnostic commit telemetry, not a protected
  // software ABI. Flash restore is reserved and never reports completion;
  // the RAM snapshot/restore engine is a separate model seam.
  input  logic [31:0] unlock_key_i,
  input  logic        restore_i,
  output logic        restore_done_o,
  output logic [31:0] stick_journal_gen_o,
  output logic [31:0] stick_journal_id_o,
  // ---- flash chip seam (st_*), driven by the VirtIO device ----
  input logic st_req_i,
  output logic st_gnt_o,
  input logic st_we_i,
  input logic [63:0] st_addr_i,
  input logic [63:0] st_wdata_i,
  input logic [7:0] st_be_i,
  output logic st_rvalid_o,
  output logic [63:0] st_rdata_o,
  output logic st_err_o,
  input logic st_flush_req_i,
  output logic st_flush_ack_o,
  output logic st_flush_err_o,
  // ---- published stick attributes (single source for both transports) ----
  output logic stick_present_o,
  output logic [31:0] stick_identity_o,
  output logic [63:0] stick_ram_bytes_o,
  output logic [63:0] stick_flash_bytes_o,
  output logic [63:0] stick_flash_sectors_o,   // 512-byte units for virtio capacity
  output logic stick_durable_o,
  output logic stick_store_idle_o,
  // ST-025 recovery surface (sim-observable, not a software ABI).
  output logic [31:0] stick_cut_count_o,
  output logic [31:0] stick_commit_gen_o,
  output logic [159:0] stick_serial_o
);
  localparam int unsigned RamLegal =
      RamWords > 0 && FlashWords > 0 && Identity != '0 ? 1 : 0;
  if (!RamLegal) begin : gen_param_check
    initial $fatal(1, "STORAMIC_STICK_PARAM");
  end

  g6lc_storamic_durable_store #(
    .NumWords(FlashWords), .StageEntries(StageEntries),
    .RspCycles(FlashRspCycles), .CommitCycles(FlashCommitCycles)
  ) i_flash (
    .clk_i, .rst_ni, .power_cut_i,
    .idle_o(stick_store_idle_o), .drained_o(),
    .st_req_i, .st_gnt_o, .st_we_i, .st_addr_i, .st_wdata_i, .st_be_i,
    .st_rvalid_o, .st_rdata_o, .st_err_o,
    .st_flush_req_i, .st_flush_ack_o, .st_flush_err_o,
    .save_i, .save_done_o,
    .cut_count_o(stick_cut_count_o), .commit_gen_o(stick_commit_gen_o),
    .journal_gen_o(stick_journal_gen_o), .journal_id_o(stick_journal_id_o),
    .unlock_key_i, .restore_i, .restore_done_o
  );

  // One stick, always populated in the model. The flash chip is the durable
  // store, so durability is offered honestly by this binding.
  assign stick_present_o = 1'b1;
  assign stick_identity_o = Identity;
  assign stick_ram_bytes_o = 64'(RamWords) * 64'd8;
  assign stick_flash_bytes_o = 64'(FlashWords) * 64'd8;
  assign stick_flash_sectors_o = (64'(FlashWords) * 64'd8) >> 9;
  assign stick_durable_o = 1'b1;
  assign stick_serial_o = Serial;
endmodule
