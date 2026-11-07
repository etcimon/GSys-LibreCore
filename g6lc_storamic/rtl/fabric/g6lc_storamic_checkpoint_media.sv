// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// SRAM-backed media model's record/backup owner, not a physical flash driver.
// The caller seals/drains all writers and arbitrates the existing command
// seams exclusively. Records are rediscovered from committed media on reset.
module g6lc_storamic_checkpoint_media #(
  parameter logic [63:0] RawFlashBytes = 1024,
  parameter logic [63:0] ImageBytes = 64,
  parameter logic [63:0] RamBaseOffset = 0,
  parameter logic [63:0] ExtraReservedBytes = 0,
  parameter bit AllowNoBlock = 1'b0,
  parameter logic [63:0] BlankWord = 0,
  parameter logic [7:0] Source = 8'hFE,
  parameter int unsigned SeqWidth = 32,
  parameter int unsigned EpochWidth = 8
) (
  input logic clk_i, rst_ni,
  input logic available_i, protection_ok_i, power_cut_i,
  // Real all-writer/ingress acknowledgement, including during reset recovery.
  input logic exclusive_i,
  input logic [159:0] module_id_i,
  input logic [31:0] mapping_generation_i, reset_generation_i,
  input logic publish_req_i,
  output logic publish_ack_o, publish_error_o,
  input logic [159:0] publish_module_id_i,
  input logic [31:0] publish_mapping_generation_i,
  input logic [63:0] publish_generation_i,
  input logic publish_bank_i,
  input logic abort_i,
  // Pulse only when idle/recovered with a valid selected checkpoint.
  input logic restore_i,
  output logic restore_done_o, restore_error_o, restore_busy_o,
  output logic idle_o, recovered_o, metadata_ok_o,
  output logic checkpoint_valid_o, checkpoint_bank_o,
  output logic [63:0] checkpoint_generation_o,
  output logic layout_legal_o,
  output logic [63:0] user_capacity_bytes_o, reserved_bytes_o,
  output logic maintenance_o, media_owned_o, degraded_o, tag_exhausted_o, stale_event_o,
  output logic error_event_o,
  output logic [5:0] phase_o,
  input logic store_idle_i,
  output logic mem_req_o,
  input logic mem_gnt_i,
  output logic mem_we_o,
  output logic [63:0] mem_addr_o, mem_wdata_o,
  output logic [7:0] mem_be_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  input logic mem_rvalid_i,
  input logic [63:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic st_req_o,
  input logic st_gnt_i,
  output logic st_we_o,
  output logic [63:0] st_addr_o, st_wdata_o,
  output logic [7:0] st_be_o,
  input logic st_rvalid_i,
  input logic [63:0] st_rdata_i,
  input logic st_error_i,
  output logic st_flush_req_o,
  input logic st_flush_ack_i, st_flush_error_i
);
  import g6lc_storamic_checkpoint_pkg::*;
  localparam checkpoint_layout_t Layout =
      checkpoint_layout(RawFlashBytes, ImageBytes, ExtraReservedBytes, AllowNoBlock);
  localparam logic [63:0] ImageWords = ImageBytes >> 3;
  localparam int unsigned IW = ImageWords > 1 ? $clog2(ImageWords) : 1;
  typedef enum logic [5:0] {
    ERecoveryStart, EHeaderRead, EHeaderWait, ENextHeaderWord, ECheckHeader,
    EDataRead, EDataWait, EDataNext, EVerifyData, ENextSlot, ERecoveryFinish,
    EIdle, EInvalidate, EInvalidateWait, EInvalidateFlush, EInvalidateFlushWait,
    ECopyRamRead, ECopyRamWait, ECopyNvmWrite, ECopyNvmWait, ECopyFlush, ECopyFlushWait,
    EBuildCrc, EBuildCrcNext, EBuildMarker, EWriteBody, EWriteBodyWait,
    EBodyFlush, EBodyFlushWait, ECommit, ECommitWait, ECommitFlush, ECommitFlushWait,
    EWriteRam, EWriteRamWait, ECrc, EAbort, EPubDone, EWaitPubDrop,
    ERestoreDone, ERestoreDefer, ERecoveryFlush, ERecoveryFlushWait
  } state_e;
  typedef enum logic [1:0] {MRecover, MPublish, MRestore} mode_e;
  typedef enum logic [1:0] {PRecovery, PVerifyRestore, PCopyRestore} purpose_e;
  typedef struct packed {
    state_e state, crc_return;
    mode_e mode;
    purpose_e purpose;
    checkpoint_record_t record, best;
    logic best_valid, recovered, ok, degraded, saw_nonblank, foreign_seen;
    logic error, needs_rescan, slot, image_bank, slot_blank;
    logic [63:0] foreign_generation, shift, data;
    logic [31:0] crc;
    logic [4:0] crc_step;
    logic [2:0] word_index;
    logic [IW-1:0] index;
    logic [159:0] context_module;
    logic [31:0] context_map, context_reset;
    logic pub_ack, pub_error, restore_done, restore_error, error_event;
  } control_t;
  control_t q, d;
  logic io_command, io_ready, io_ram, io_flush, io_write;
  logic [63:0] io_addr, io_write_data, io_data;
  logic io_response, io_error, context_matches, running;
  logic [63:0] record_base, image_base;
  assign record_base = q.image_bank ? Layout.record1 : Layout.record0;
  assign image_base = q.image_bank ? Layout.image1 : Layout.image0;
  assign context_matches = available_i && q.context_module == module_id_i &&
      q.context_map == mapping_generation_i && q.context_reset == reset_generation_i;
  assign idle_o = q.state == EIdle && io_ready;
  assign recovered_o = q.recovered && context_matches;
  assign metadata_ok_o = q.ok && recovered_o;
  assign checkpoint_valid_o = q.best_valid && metadata_ok_o;
  assign checkpoint_bank_o = q.best_valid && q.best.generation[0];
  assign checkpoint_generation_o = q.best_valid ? q.best.generation : 64'd0;
  assign layout_legal_o = Layout.legal;
  assign user_capacity_bytes_o = Layout.user_bytes;
  assign reserved_bytes_o = Layout.reserved_bytes;
  assign maintenance_o = q.mode != MRecover && q.state != EIdle;
  assign media_owned_o = (q.state != EIdle && q.state != ERecoveryStart) || !io_ready;
  assign restore_busy_o = q.mode == MRestore && q.state != EIdle;
  assign degraded_o = q.degraded;
  assign publish_ack_o = q.pub_ack;
  assign publish_error_o = q.pub_error;
  assign restore_done_o = q.restore_done;
  assign restore_error_o = q.restore_error;
  assign error_event_o = q.error_event;
  assign phase_o = q.state;
  assign running = q.state != EIdle && q.state != ERecoveryStart &&
      q.state != EAbort && q.state != EPubDone && q.state != EWaitPubDrop &&
      q.state != ERestoreDone && q.state != ERestoreDefer;
  g6lc_storamic_checkpoint_io #(
    .Source(Source), .SeqWidth(SeqWidth), .EpochWidth(EpochWidth)
  ) i_io (
    .clk_i, .rst_ni, .reset_generation_i, .command_i(io_command), .ready_o(io_ready),
    .ram_i(io_ram), .flush_i(io_flush), .write_i(io_write), .addr_i(io_addr),
    .data_i(io_write_data), .response_o(io_response), .response_ready_i(1'b1),
    .data_o(io_data), .error_o(io_error), .exhausted_o(tag_exhausted_o), .stale_event_o,
    .mem_req_o, .mem_gnt_i, .mem_we_o, .mem_addr_o, .mem_wdata_o, .mem_be_o, .mem_tag_o,
    .mem_rvalid_i, .mem_rdata_i, .mem_error_i, .mem_tag_i,
    .st_req_o, .st_gnt_i, .st_we_o, .st_addr_o, .st_wdata_o, .st_be_o,
    .st_rvalid_i, .st_rdata_i, .st_error_i, .st_flush_req_o, .st_flush_ack_i, .st_flush_error_i
  );

  // pragma translate_off
  initial begin
    if (!Layout.legal || (BlankWord != '0 && BlankWord != '1) || RamBaseOffset[2:0] != 0 ||
        ({1'b0, RamBaseOffset} + {1'b0, ImageBytes}) > 65'h1_0000_0000_0000_0000)
      $fatal(1, "STORAMIC_CHECKPOINT_MEDIA_PARAM");
  end
  // pragma translate_on
  always_comb begin
    d = q;
    d.pub_ack = 0; d.pub_error = 0;
    d.restore_done = 0; d.restore_error = 0; d.error_event = 0;
    io_command = 0; io_ram = 0; io_flush = 0; io_write = 0;
    io_addr = 0; io_write_data = 0;
    case (q.state)
      ERecoveryStart: if (io_ready && available_i && exclusive_i && !power_cut_i && store_idle_i) begin
        d.mode = MRecover;
        d.context_module = module_id_i;
        d.context_map = mapping_generation_i; d.context_reset = reset_generation_i;
        d.recovered = 0; d.ok = 0; d.best_valid = 0; d.best = '0;
        d.record = '0; d.slot = 0; d.image_bank = 0; d.word_index = 0;
        d.crc = '1; d.slot_blank = 1;
        d.saw_nonblank = 0; d.foreign_seen = 0; d.foreign_generation = 0;
        d.error = 0; d.needs_rescan = 0;
        d.state = Layout.legal ? ERecoveryFlush : ERecoveryFinish;
      end
      ERecoveryFlush: if (io_ready) begin
        io_command = 1; io_flush = 1; d.state = ERecoveryFlushWait;
      end
      ERecoveryFlushWait: if (io_response && !io_error) d.state = EHeaderRead;
      EHeaderRead: if (io_ready) begin
        io_command = 1; io_addr = record_base + (64'(q.word_index) << 3);
        d.state = EHeaderWait;
      end
      EHeaderWait: if (io_response && !io_error) begin
        d.record = decode_word(q.record, q.word_index, io_data);
        d.saw_nonblank = q.saw_nonblank || io_data != BlankWord;
        d.slot_blank = q.slot_blank && io_data == BlankWord;
        if (q.word_index == 7) d.state = ECheckHeader;
        else begin
          d.shift = q.word_index == 6 ? {32'd0, io_data[63:32]} : io_data;
          d.crc_step = 0; d.crc_return = ENextHeaderWord; d.state = ECrc;
        end
      end
      ENextHeaderWord: begin d.word_index = q.word_index + 1'b1; d.state = EHeaderRead; end
      ECheckHeader: begin
        d.state = ENextSlot;
        if (record_header_valid(q.record, q.slot, ~q.crc)) begin
          if (!record_matches(q.record, q.context_module, q.context_map, ImageBytes)) begin
            d.foreign_seen = 1;
            if (!q.foreign_seen || q.record.generation > q.foreign_generation)
              d.foreign_generation = q.record.generation;
          end else begin
            d.index = 0; d.crc = '1; d.purpose = PRecovery; d.state = EDataRead;
          end
        end else if (!q.slot_blank && q.record.marker != 0) begin
          d.degraded = 1; d.error_event = 1;
        end
      end
      EDataRead: if (io_ready) begin
        io_command = 1; io_addr = image_base + (64'(q.index) << 3); d.state = EDataWait;
      end
      EDataWait: if (io_response && !io_error) begin
        d.data = io_data; d.shift = io_data; d.crc_step = 0;
        d.crc_return = q.purpose == PCopyRestore ? EWriteRam : EDataNext;
        d.state = ECrc;
      end
      EDataNext: if (64'(q.index) == ImageWords - 1) d.state = EVerifyData;
                else begin d.index = q.index + 1'b1; d.state = EDataRead; end
      EVerifyData: begin
        if (~q.crc != q.record.image_crc) begin
          d.degraded = 1; d.error_event = 1;
          if (q.mode == MRecover) d.state = ENextSlot;
          else begin d.error = 1; d.needs_rescan = 1; d.state = ERestoreDone; end
        end else if (q.purpose == PRecovery) begin
          if (!q.best_valid || q.record.generation > q.best.generation) begin
            d.best = q.record; d.best_valid = 1;
          end
          d.state = ENextSlot;
        end else begin
          d.purpose = PCopyRestore; d.index = 0; d.crc = '1; d.state = EDataRead;
        end
      end
      ENextSlot: if (!q.slot) begin
        d.slot = 1; d.image_bank = 1; d.word_index = 0; d.record = '0;
        d.crc = '1; d.slot_blank = 1; d.state = EHeaderRead;
      end else d.state = ERecoveryFinish;
      ERecoveryFinish: begin
        d.recovered = 1;
        d.ok = Layout.legal && (q.best_valid || !q.saw_nonblank) &&
            (!q.foreign_seen || (q.best_valid && q.best.generation > q.foreign_generation));
        d.state = EIdle;
      end
      EIdle: begin
        if (!context_matches || power_cut_i) begin
          d.recovered = 0; d.mode = MRecover; d.state = ERecoveryStart;
        end else if (publish_req_i) begin
          d.mode = MPublish; d.error = 0; d.needs_rescan = 0;
          d.context_reset = reset_generation_i;
          d.record = '0;
          d.record.magic = RecordMagic; d.record.module_id = publish_module_id_i;
          d.record.mapping_generation = publish_mapping_generation_i;
          d.record.generation = publish_generation_i; d.record.image_bytes = ImageBytes;
          d.image_bank = publish_bank_i;
          if (!metadata_ok_o || !exclusive_i || !protection_ok_i || q.degraded || tag_exhausted_o ||
              abort_i || restore_i || publish_module_id_i != module_id_i ||
              publish_mapping_generation_i != mapping_generation_i ||
              publish_bank_i != publish_generation_i[0] ||
              (q.best_valid && (&q.best.generation)) ||
              publish_generation_i != (q.best_valid ? q.best.generation + 64'd1 : 64'd1))
            d.error = 1;
          d.state = d.error ? EPubDone : EInvalidate;
        end else if (restore_i) begin
          d.mode = MRestore; d.error = 0; d.needs_rescan = 0;
          d.record = q.best; d.image_bank = q.best.generation[0];
          d.index = 0; d.crc = '1; d.purpose = PVerifyRestore;
          if (!checkpoint_valid_o || !exclusive_i || tag_exhausted_o || abort_i) d.error = 1;
          d.state = d.error ? ERestoreDone : EDataRead;
        end
      end
      // Publication/copy states are kept separate from their accepted I/O.
      EInvalidate: if (io_ready) begin
        io_command = 1; io_write = 1; io_addr = record_base + 64'd56;
        d.state = EInvalidateWait;
      end
      EInvalidateWait: if (io_response && !io_error) d.state = EInvalidateFlush;
      EInvalidateFlush, ECopyFlush, EBodyFlush, ECommitFlush: if (io_ready) begin
        io_command = 1; io_flush = 1;
        case (q.state)
          EInvalidateFlush: d.state = EInvalidateFlushWait;
          ECopyFlush: d.state = ECopyFlushWait;
          EBodyFlush: d.state = EBodyFlushWait;
          default: d.state = ECommitFlushWait;
        endcase
      end
      EInvalidateFlushWait: if (io_response && !io_error) begin
        d.index = 0; d.crc = '1; d.state = ECopyRamRead;
      end
      ECopyRamRead: if (io_ready) begin
        io_command = 1; io_ram = 1;
        io_addr = RamBaseOffset + (64'(q.index) << 3); d.state = ECopyRamWait;
      end
      ECopyRamWait: if (io_response && !io_error) begin
        d.data = io_data; d.shift = io_data; d.crc_step = 0;
        d.crc_return = ECopyNvmWrite; d.state = ECrc;
      end
      ECopyNvmWrite: if (io_ready) begin
        io_command = 1; io_write = 1;
        io_addr = image_base + (64'(q.index) << 3); io_write_data = q.data;
        d.state = ECopyNvmWait;
      end
      ECopyNvmWait: if (io_response && !io_error) begin
        if (64'(q.index) == ImageWords - 1) begin
          d.record.image_crc = ~q.crc; d.state = ECopyFlush;
        end else begin d.index = q.index + 1'b1; d.state = ECopyRamRead; end
      end
      ECopyFlushWait: if (io_response && !io_error) begin
        d.crc = '1; d.word_index = 0; d.state = EBuildCrc;
      end
      EBuildCrc: begin
        d.shift = record_crc_word(q.record, q.word_index); d.crc_step = 0;
        d.crc_return = EBuildCrcNext; d.state = ECrc;
      end
      EBuildCrcNext: if (q.word_index == 6) begin
        d.record.record_crc = ~q.crc; d.state = EBuildMarker;
      end else begin d.word_index = q.word_index + 1'b1; d.state = EBuildCrc; end
      EBuildMarker: begin
        d.record.marker = commit_marker(q.record); d.word_index = 0; d.state = EWriteBody;
      end
      EWriteBody: if (io_ready) begin
        io_command = 1; io_write = 1; io_addr = record_base + (64'(q.word_index) << 3);
        io_write_data = record_word(q.record, q.word_index); d.state = EWriteBodyWait;
      end
      EWriteBodyWait: if (io_response && !io_error) begin
        if (q.word_index == 6) d.state = EBodyFlush;
        else begin d.word_index = q.word_index + 1'b1; d.state = EWriteBody; end
      end
      EBodyFlushWait: if (io_response && !io_error) d.state = ECommit;
      ECommit: if (io_ready) begin
        io_command = 1; io_write = 1; io_addr = record_base + 64'd56;
        io_write_data = q.record.marker; d.state = ECommitWait;
      end
      ECommitWait: if (io_response && !io_error) d.state = ECommitFlush;
      ECommitFlushWait: if (io_response && !io_error) d.state = EPubDone;
      EWriteRam: if (io_ready) begin
        io_command = 1; io_ram = 1; io_write = 1;
        io_addr = RamBaseOffset + (64'(q.index) << 3); io_write_data = q.data;
        d.state = EWriteRamWait;
      end
      EWriteRamWait: if (io_response && !io_error) begin
        if (64'(q.index) == ImageWords - 1) begin
          if (~q.crc != q.record.image_crc) begin
            d.error = 1; d.needs_rescan = 1; d.degraded = 1; d.error_event = 1;
          end
          d.state = ERestoreDone;
        end else begin d.index = q.index + 1'b1; d.state = EDataRead; end
      end
      ECrc: begin
        d.crc = crc2(q.crc, q.shift[1:0]); d.shift = q.shift >> 2;
        if (q.crc_step == 31) d.state = q.crc_return;
        else d.crc_step = q.crc_step + 1'b1;
      end
      EAbort: if (io_ready && available_i && !power_cut_i) begin
        if (q.mode == MPublish) d.state = EPubDone;
        else if (q.mode == MRestore) d.state = ERestoreDone;
        else begin d.recovered = 0; d.state = ERecoveryStart; end
      end
      EPubDone: begin
        d.pub_ack = 1;
        d.pub_error = q.error || power_cut_i || abort_i || !publish_req_i ||
                      !context_matches || !exclusive_i || !protection_ok_i;
        if (d.pub_error) begin
          d.error_event = 1;
          if (power_cut_i || abort_i || !context_matches || !exclusive_i || !protection_ok_i)
            d.needs_rescan = 1;
        end else begin
          d.best = q.record; d.best_valid = 1; d.recovered = 1; d.ok = 1;
        end
        d.state = EWaitPubDrop;
      end
      EWaitPubDrop: if (!publish_req_i) begin
        if (q.needs_rescan) begin
          d.recovered = 0; d.mode = MRecover; d.state = ERecoveryStart;
        end else d.state = EIdle;
      end
      ERestoreDone: begin
        d.restore_done = 1;
        d.restore_error = q.error || power_cut_i || abort_i || !context_matches || !exclusive_i;
        if (d.restore_error) begin d.error_event = 1; d.state = ERestoreDefer; end
        else d.state = EIdle;
      end
      ERestoreDefer: begin
        d.recovered = 0; d.mode = MRecover; d.state = ERecoveryStart;
      end
      default: begin d.error = 1; d.needs_rescan = 1; d.state = EAbort; end
    endcase
    if (io_response && io_error && q.state != EAbort) begin
      if (!q.error && !power_cut_i && !abort_i && !tag_exhausted_o) d.degraded = 1;
      d.error_event = 1;
      if (q.state == ERecoveryFlushWait) begin
        d.recovered = 1; d.ok = 0; d.state = EIdle;
      end else if (q.mode == MRecover) begin d.saw_nonblank = 1; d.state = ENextSlot; end
      else begin d.error = 1; d.needs_rescan = 1; d.state = EAbort; end
    end
    // Once offered, the word sequencer still owns its terminal response.
    // Abort prevents new commands, then drains it before reporting an error.
    if (running && (power_cut_i || !context_matches || !exclusive_i ||
        (q.mode != MRecover && abort_i) ||
        (q.mode == MPublish && (!protection_ok_i || !publish_req_i)))) begin
      io_command = 0; d.error = 1; d.needs_rescan = 1; d.state = EAbort;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q <= '0;
      q.state <= ERecoveryStart;
    end else q <= d;
  end
endmodule
