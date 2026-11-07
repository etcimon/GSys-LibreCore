// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-011B simulation binding for the Storamic model profile: backs the
// g6lc_storamic_axi_memory `mem_*` command seam with the same pulp `sram`
// module the gen_sim_axi backend uses, so the storage sits behind tc_sram.
// This is a simulation binding only — not a qualified memory controller, and
// no persistence or physical-media claim.
//
// The seam is one command outstanding: mem_gnt_o accepts a command while
// idle, and the read data or write completion arrives one cycle after grant
// with the tag echoed. mem_addr_i is the base-relative byte offset within
// the model window produced by the frontend (addr - ModelBase). An address
// beyond ModelBytes, or one not aligned to the data width, completes with
// mem_error_o and never touches the array (defensive; the frontend's own
// window check normally prevents it).
// RspDelay is the RAM channel's bandwidth knob: a command completes
// RspDelay+1 cycles after grant, so sustained bandwidth is one beat per
// RspDelay+2 cycles including the response-owned cycle. 0 is the original
// one-cycle model.
module g6lc_storamic_sim_mem #(
  parameter int unsigned DataWidth = 64,
  parameter int unsigned NumWords = 8192,
  parameter logic [63:0] ModelBytes = 64'h0,
  parameter int unsigned RspDelay = 0,
  parameter bit ExternalCheckpointCommit = 1'b0,
  parameter bit ExternalFlashCheckpoint = 1'b0
) (
  input logic clk_i,
  input logic rst_ni,
  output logic mem_ready_o,
  input logic mem_req_i,
  output logic mem_gnt_o,
  input logic mem_we_i,
  input logic [63:0] mem_addr_i,
  input logic [DataWidth-1:0] mem_wdata_i,
  input logic [DataWidth/8-1:0] mem_be_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic mem_rvalid_o,
  output logic [DataWidth-1:0] mem_rdata_o,
  output logic mem_error_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  // ST-025 stick save/restore: RAM is volatile — power_cut_i loses its
  // contents (a powered scan clears the live array after a cut). save_i
  // writes an inactive modeled checkpoint, then publishes it atomically in
  // legacy mode. save_i/restore_i are control pulses, not held requests.
  // restore_i scans the last completed image back. All scans hold admission
  // off; these SRAM-backed images are not physical nonvolatile storage.
  input logic power_cut_i,
  input logic save_i,
  input logic restore_i,
  // External mode freezes a prepared image until the metadata owner commits
  // or aborts it. Selected bank/validity come from that owner's recovery.
  // The owner must keep AXI sealed across restore/abort until recovery is safe.
  input logic checkpoint_valid_i,
  input logic checkpoint_bank_i,
  input logic checkpoint_commit_i,
  input logic checkpoint_abort_i,
  // Trusted internal owner only, never a host-controlled sideband. Prepared
  // images permit reads; after abort, already-offered owner work may drain
  // while AXI remains sealed and recovery remains locked.
  input logic maintenance_i,
  output logic checkpoint_prepared_o,
  output logic checkpoint_prepared_bank_o,
  output logic save_busy_o,
  output logic restore_done_o
);

  localparam int unsigned ByteW = $clog2(DataWidth / 8);
  localparam int unsigned IW = NumWords > 1 ? $clog2(NumWords) : 1;
  localparam int unsigned RW = RspDelay > 0 ? $clog2(RspDelay + 1) : 1;
  localparam int unsigned CW = $clog2(2 * NumWords);

  // pragma translate_off
  initial begin
    if (NumWords == 0 || DataWidth < 8 || DataWidth % 8 != 0 ||
        $countones(DataWidth / 8) != 1 ||
        (ExternalFlashCheckpoint && !ExternalCheckpointCommit))
      $fatal(1, "STORAMIC_RAM_PARAM");
  end
  // pragma translate_on

  logic rsp_q;                        // completion due this cycle
  logic [RW-1:0] rsp_cnt_q;
  logic err_q;
  g6lc_storamic_pkg::txn_id_t tag_q;
  logic cmd_ok;
  logic maintenance;
  assign maintenance = ExternalCheckpointCommit && maintenance_i;
  logic sram_req, sram_we;
  logic [IW-1:0] sram_addr;
  logic [DataWidth-1:0] sram_wdata, sram_rdata;
  logic [DataWidth/8-1:0] sram_be;
  logic accepted;

  // A save writes only the inactive bank. A cut aborts its publication,
  // retaining the previous complete checkpoint and its bank selector.
  typedef enum logic [1:0] {ScanIdle, ScanSave, ScanRestore, ScanClear} scan_t;
  scan_t scan_q;
  logic [IW-1:0] scan_idx_q, scan_rd_q;
  logic saved_q, lost_q, scan_has_q;
  logic save_pending_q, restore_pending_q;
  logic checkpoint_bank_q, restore_done_q;
  logic checkpoint_prepared_q, scan_bank_q;
  logic published_valid, published_bank, abort_checkpoint;
  logic scan_saving, scan_restoring;
  logic checkpoint_req, checkpoint_we, checkpoint_bank;
  logic [CW-1:0] checkpoint_addr;
  logic [DataWidth-1:0] checkpoint_rdata;
  assign scan_saving = scan_q == ScanSave;
  assign scan_restoring = scan_q == ScanRestore;

  assign published_valid = ExternalCheckpointCommit ? checkpoint_valid_i : saved_q;
  assign published_bank = ExternalCheckpointCommit ? checkpoint_bank_i : checkpoint_bank_q;
  assign abort_checkpoint = ExternalCheckpointCommit && checkpoint_abort_i;
  assign checkpoint_prepared_o = checkpoint_prepared_q && !power_cut_i;
  assign checkpoint_prepared_bank_o = scan_bank_q;
  assign save_busy_o = scan_q != ScanIdle || save_pending_q || restore_pending_q ||
                       checkpoint_prepared_q;
  assign restore_done_o = !power_cut_i && !abort_checkpoint && restore_done_q;

  assign mem_ready_o = 1'b1;
  assign cmd_ok = ({1'b0, mem_addr_i} < {1'b0, ModelBytes}) &&
                  (mem_addr_i >> ByteW) < 64'(NumWords) &&
                  ((mem_addr_i & ((64'd1 << ByteW) - 64'd1)) == 0);
  // One command outstanding: grant whenever the seam offers a command, no
  // response is pending or counting down, no scan is running, and the chip
  // is powered (power_cut_i low).
  assign mem_gnt_o = mem_req_i && !rsp_q && !(|rsp_cnt_q) &&
                     scan_q == ScanIdle && !power_cut_i &&
                     !save_i && !restore_i && !save_pending_q && !restore_pending_q &&
                     (!checkpoint_prepared_q || (maintenance && !mem_we_i)) &&
                     (!abort_checkpoint || maintenance);
  assign sram_req = !power_cut_i &&
      (((!abort_checkpoint || scan_q == ScanClear) &&
        (scan_q == ScanSave || scan_q == ScanClear ||
         (scan_q == ScanRestore && scan_has_q))) ||
       (mem_req_i && mem_gnt_o && cmd_ok));
  assign sram_we = scan_q == ScanIdle ? mem_we_i :
                   scan_q == ScanRestore || scan_q == ScanClear;
  assign sram_addr = scan_q == ScanIdle ? mem_addr_i[ByteW+IW-1:ByteW] :
                     scan_q == ScanRestore ? scan_rd_q : scan_idx_q;
  assign sram_wdata = scan_q == ScanRestore ? checkpoint_rdata :
                      scan_q == ScanClear ? '0 : mem_wdata_i;
  assign sram_be = scan_q == ScanIdle ? mem_be_i : '1;
  assign accepted = mem_req_i && mem_gnt_o;

  assign checkpoint_bank = scan_bank_q;
  assign checkpoint_addr = (checkpoint_bank ? CW'(NumWords) : '0) +
                           CW'(scan_saving ? scan_rd_q : scan_idx_q);
  assign checkpoint_we = scan_saving;
  assign checkpoint_req = !power_cut_i && !abort_checkpoint &&
                          (scan_restoring || (scan_saving && scan_has_q));
  if (!ExternalFlashCheckpoint) begin : gen_local_checkpoint
    tc_sram #(
      .NumWords(2 * NumWords), .DataWidth(DataWidth), .ByteWidth(8),
      .NumPorts(1), .Latency(1)
    ) i_checkpoint (
      .clk_i, .rst_ni, .req_i(checkpoint_req), .we_i(checkpoint_we),
      .addr_i(checkpoint_addr), .wdata_i(sram_rdata), .be_i({DataWidth/8{1'b1}}),
      .rdata_o(checkpoint_rdata)
    );
  end else begin : gen_flash_checkpoint
    assign checkpoint_rdata = '0;
  end

  assign mem_rvalid_o = rsp_q;
  assign mem_rdata_o = lost_q ? '0 : sram_rdata;
  assign mem_error_o = err_q;
  assign mem_tag_o = tag_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_q <= 1'b0;
      rsp_cnt_q <= '0;
      err_q <= 1'b0;
      tag_q <= '0;
      scan_q <= ScanIdle;
      scan_idx_q <= '0;
      scan_rd_q <= '0;
      saved_q <= 1'b0;
      lost_q <= 1'b0;
      scan_has_q <= 1'b0;
      save_pending_q <= 1'b0;
      restore_pending_q <= 1'b0;
      checkpoint_bank_q <= 1'b0;
      checkpoint_prepared_q <= 1'b0;
      scan_bank_q <= 1'b0;
      restore_done_q <= 1'b0;
    end else begin
      restore_done_q <= 1'b0;
      if (RspDelay == 0) rsp_q <= accepted;
      else begin
        rsp_q <= rsp_cnt_q == 1;
        if (accepted) rsp_cnt_q <= RW'(RspDelay);
        else if (rsp_cnt_q != '0) rsp_cnt_q <= rsp_cnt_q - 1'b1;
      end
      if (accepted) begin
        err_q <= !cmd_ok;
        tag_q <= mem_tag_i;
      end
      if (power_cut_i) begin
        // Volatile live contents must be cleared before reopening admission.
        // The last published checkpoint survives interrupted save or restore.
        lost_q <= 1'b1;
        scan_q <= ScanClear;
        scan_idx_q <= '0;
        scan_has_q <= 1'b0;
        save_pending_q <= 1'b0;
        restore_pending_q <= 1'b0;
        checkpoint_prepared_q <= 1'b0;
        // An accepted delayed command still owns one completion on a cut.
        if (rsp_cnt_q != '0) begin
          rsp_q <= 1'b1;
          rsp_cnt_q <= '0;
          err_q <= 1'b1;
        end
      end else begin
        if (scan_q == ScanIdle || scan_q == ScanClear) begin
          // Latch a control pulse while the command response drains. Save
          // wins a simultaneous request; do not start a scan on a live reply.
          if (!save_pending_q && !restore_pending_q && !checkpoint_prepared_q &&
              !abort_checkpoint) begin
            if (save_i) begin
              save_pending_q <= 1'b1;
              scan_bank_q <= !published_bank;
            end else if (restore_i && published_valid && !ExternalFlashCheckpoint) begin
              restore_pending_q <= 1'b1;
              scan_bank_q <= published_bank;
            end
          end
          if (scan_q == ScanIdle && (save_pending_q || restore_pending_q) &&
              !rsp_q && rsp_cnt_q == '0) begin
            save_pending_q <= 1'b0;
            restore_pending_q <= 1'b0;
            if (ExternalFlashCheckpoint && save_pending_q) begin
              // Real backups live in the media owner, not a retained shadow.
              checkpoint_prepared_q <= 1'b1;
              scan_q <= ScanIdle;
            end else scan_q <= save_pending_q ? ScanSave : ScanRestore;
            scan_idx_q <= '0;
            scan_rd_q <= '0;
            scan_has_q <= 1'b0;
          end
          if (scan_q == ScanClear) begin
            if (scan_idx_q == IW'(NumWords - 1)) begin
              scan_q <= ScanIdle;
              lost_q <= 1'b0;
            end else scan_idx_q <= scan_idx_q + 1'b1;
          end
        end else begin
          // Both SRAMs have one read cycle. Commit the previous address,
          // and publish completion only after the final write edge.
          if (scan_has_q && scan_rd_q == IW'(NumWords - 1)) begin
            scan_q <= ScanIdle;
            if (scan_q == ScanSave) begin
              if (ExternalCheckpointCommit) checkpoint_prepared_q <= 1'b1;
              else begin
                saved_q <= 1'b1;
                checkpoint_bank_q <= scan_bank_q;
              end
            end else begin
              restore_done_q <= 1'b1;
              lost_q <= 1'b0;
            end
          end else begin
            scan_has_q <= 1'b1;
            scan_rd_q <= scan_idx_q;
            if (scan_idx_q != IW'(NumWords - 1))
              scan_idx_q <= scan_idx_q + 1'b1;
          end
        end
        if (ExternalCheckpointCommit && checkpoint_commit_i && checkpoint_prepared_q)
          checkpoint_prepared_q <= 1'b0;
        if (abort_checkpoint) begin
          restore_done_q <= 1'b0;
          checkpoint_prepared_q <= 1'b0;
          save_pending_q <= 1'b0;
          restore_pending_q <= 1'b0;
          // A clear scan is loss recovery, not a checkpoint operation.
          if (scan_q != ScanClear) begin
            scan_q <= ScanIdle;
            scan_has_q <= 1'b0;
          end
        end
      end
    end
  end

  sram #(
      .DATA_WIDTH ( DataWidth ),
      .USER_WIDTH ( 1         ),
      .USER_EN    ( 0         ),
`ifdef VERILATOR
      .SIM_INIT   ( "none"    ),
`else
      .SIM_INIT   ( "zeros"   ),
`endif
      .NUM_WORDS  ( NumWords  )
  ) i_sram (
      .clk_i   ( clk_i   ),
      .rst_ni  ( rst_ni  ),
      .req_i   ( sram_req ),
      .we_i    ( sram_we  ),
      .addr_i  ( sram_addr ),
      .wuser_i ( 1'b0    ),
      .wdata_i ( sram_wdata ),
      .be_i    ( sram_be ),
      .ruser_o (         ),
      .rdata_o ( sram_rdata )
  );
endmodule
