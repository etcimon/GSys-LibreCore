// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-018 slice: commit-boundary DURABLE-SEMANTICS model of a flash chip for
// the native virtio-blk store seam (st_*). Host writes land in a write-back
// staging buffer; a flush request drains the buffer into the tc_sram backing
// array, and st_flush_ack_o asserts only when the buffer is empty. This
// models the durability ordering contract: writes are not committed until
// they cross the staging boundary.
//
// It is still a model, not physical persistence: there is no power-loss
// domain or erase cycle. Replay retains one modeled journal entry. Reads see
// staged data (read-own-writes). When staging is full an incoming write
// stalls while the oldest entry commits to the array (a spill is itself a
// commit, so ordering and durability are preserved). Out-of-range accesses
// are granted, complete with an error, and change nothing.
// Bandwidth knobs, independent of the RAM channel: RspCycles stretches the
// st_* interface completion (one response-owned access at a time), while
// CommitCycles stretches the media program time per staged entry during a
// drain. Both default to the original rates.
//
// power_cut_i models loss at the chip boundary for the persistence track:
// staged-but-uncommitted data is dropped, the commit/flush engine resets,
// and a pending granted access completes with an error. Committed contents
// in the backing array survive — that is exactly the durability contract.
module g6lc_storamic_durable_store #(
  parameter int unsigned NumWords = 8192,       // 64 KiB = 128 sectors
  parameter int unsigned StageEntries = 8,
  parameter int unsigned RspCycles = 0,         // interface response stretch
  parameter int unsigned CommitCycles = 1       // media program time per entry
) (
  input logic clk_i,
  input logic rst_ni,
  input logic power_cut_i,
  output logic idle_o, drained_o,
  input logic st_req_i,
  output logic st_gnt_o,
  input logic st_we_i,
  input logic [63:0] st_addr_i,                 // byte offset, 8-aligned
  input logic [63:0] st_wdata_i,
  input logic [7:0] st_be_i,
  output logic st_rvalid_o,
  output logic [63:0] st_rdata_o,
  output logic st_err_o,
  // Flush seam: the requester holds st_flush_req_i until the one-cycle ack.
  input logic st_flush_req_i,
  output logic st_flush_ack_o,
  output logic st_flush_err_o,
  // ST-025 save seam: a stick-owned drain of all staging (same as a flush,
  // but no requester handshake — save_done_o pulses when drained).
  input logic save_i,
  output logic save_done_o,
  // ST-025 recovery surface (sim-observable, not a software ABI):
  // cut_count_o counts power cuts; commit_gen_o counts completed flushes
  // (each acknowledged flush is one recovery epoch). A host comparing
  // generations across a cut can detect that staging was lost.
  output logic [31:0] cut_count_o,
  output logic [31:0] commit_gen_o,
  // Debug telemetry only: last committed word index and pre-flush generation.
  // These registers are not a persistent version map or a recovery record.
  output logic [31:0] journal_gen_o,
  output logic [31:0] journal_id_o,
  // Model save interlock, not authorization or the protected stick-wide ABI.
  input  logic [31:0] unlock_key_i,
  // Reserved flash restore seam; no snapshot rollback is implemented here.
  input  logic        restore_i,
  output logic        restore_done_o
);
  localparam int unsigned AW = NumWords > 1 ? $clog2(NumWords) : 1;
  localparam int unsigned EW = StageEntries > 1 ? $clog2(StageEntries) : 1;

  // pragma translate_off
  initial begin
    if (NumWords == 0 || StageEntries == 0 ||
        CommitCycles == 0 || CommitCycles > 65536)
      $fatal(1, "STORAMIC_DSTORE_PARAM");
  end
  // pragma translate_on

  logic in_range;
  assign in_range = st_addr_i[2:0] == 3'b000 && (st_addr_i >> 3) < 64'(NumWords);

  // Staging buffer: a circular write-back FIFO, head = oldest.
  logic [StageEntries-1:0] stage_v_q;
  logic [AW-1:0] stage_addr_q [StageEntries];
  logic [63:0] stage_data_q [StageEntries];
  logic [7:0] stage_be_q [StageEntries];
  logic [EW-1:0] head_q, tail_q;
  logic [EW:0] count_q;

  logic merge_hit, stage_rd_hit;
  logic [EW-1:0] merge_idx;
  logic [63:0] stage_rd_data;
  logic [7:0] stage_rd_be;
  always_comb begin
    merge_hit = 1'b0;
    merge_idx = '0;
    stage_rd_hit = 1'b0;
    stage_rd_data = '0;
    stage_rd_be = '0;
    for (int i = 0; i < StageEntries; i++)
      if (stage_v_q[i] && stage_addr_q[i] == st_addr_i[AW+2:3]) begin
        merge_hit = 1'b1;
        merge_idx = EW'(i);
        stage_rd_hit = 1'b1;
        stage_rd_data = stage_data_q[i];
        stage_rd_be = stage_be_q[i];
      end
  end

  // Commit engine: drains staging into the SRAM one entry per cycle while a
  // spill or a flush drain is active; it owns the single SRAM port.
  typedef enum logic [0:0] {CIdle, CDrain} commit_t;
  commit_t commit_q;
  logic flush_q, flush_seen_q;
  logic [15:0] commit_cnt_q;
  logic jrnl_q, replay_q, save_q;
  logic unlocked;

  logic sram_write, sram_read;
  logic [63:0] sram_rdata;
  // The SRAM update and metadata retirement share one powered commit edge.
  assign sram_write = !power_cut_i && commit_q == CDrain && commit_cnt_q == '0;
  tc_sram #(
    .NumWords(NumWords), .DataWidth(64), .ByteWidth(8), .NumPorts(1), .Latency(1)
  ) i_sram (
    .clk_i, .rst_ni,
    .req_i(sram_write || sram_read), .we_i(sram_write),
    .addr_i(sram_write ? stage_addr_q[head_q] : st_addr_i[AW+2:3]),
    .wdata_i(stage_data_q[head_q]), .be_i(stage_be_q[head_q]),
    .rdata_o(sram_rdata)
  );

  // Save, flush and replay close admission, including error-only requests.
  // Ordinary in-range accesses also wait for the commit engine; writes
  // additionally need a merge target or staging room.
  logic write_room, rsp_idle;
  assign write_room = merge_hit || count_q < (EW+1)'(StageEntries);
  // Staging may be dirty while idle: a maintenance owner must still flush it.
  assign idle_o = !power_cut_i && rsp_idle && commit_q == CIdle &&
                  !flush_q && !save_q && !replay_q && !st_req_i &&
                  !st_flush_req_i && !(save_i && unlocked);
  // Model ownership, not physical persistence: idle alone permits dirty staging.
  assign drained_o = rst_ni && idle_o && count_q == '0;
  // A powered-off chip grants nothing, including out-of-range accesses.
  assign st_gnt_o = st_req_i && !power_cut_i && rsp_idle &&
                    commit_q == CIdle && !flush_q && !save_q && !replay_q &&
                    !st_flush_req_i && !(save_i && unlocked) &&
                    (!in_range || !st_we_i || write_room);
  assign sram_read = st_gnt_o && in_range && !st_we_i;

  // Read/write response: RspCycles+1 cycles after grant (matching tc_sram
  // latency at the default). An out-of-range request also completes with
  // the error flag. One access is in flight at a time, so the countdown
  // cannot overlap a grant. Snapshot staged bytes at grant and capture the
  // one-cycle SRAM read before a delayed response can outlive that read.
  logic rsp_pending_q, rd_capture_q;
  logic [63:0] rd_data_q, rd_stage_q, rd_merged;
  logic [7:0] rd_be_q;
  logic err_q;
  localparam int unsigned RW = RspCycles > 0 ? $clog2(RspCycles + 1) : 1;
  logic [RW-1:0] rsp_cnt_q;
  assign rsp_idle = !rsp_pending_q && !st_rvalid_o;
  assign rd_merged = (rd_stage_q & expand_be(rd_be_q)) |
                     (sram_rdata & ~expand_be(rd_be_q));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_rvalid_o <= 1'b0; rd_capture_q <= 1'b0;
      rd_data_q <= '0; rd_stage_q <= '0; rd_be_q <= '0; err_q <= 1'b0;
      rsp_pending_q <= 1'b0; rsp_cnt_q <= '0;
    end else begin
      st_rvalid_o <= 1'b0;
      rd_capture_q <= 1'b0;
      if (rd_capture_q) rd_data_q <= rd_merged;
      if (st_gnt_o) begin
        err_q <= !in_range;
        rd_data_q <= '0;
        rd_capture_q <= in_range && !st_we_i;
        rd_stage_q <= stage_rd_data;
        rd_be_q <= stage_rd_hit ? stage_rd_be : '0;
        if (RspCycles == 0) st_rvalid_o <= 1'b1;
        else begin
          rsp_pending_q <= 1'b1;
          rsp_cnt_q <= RW'(RspCycles);
        end
      end
      if (rsp_pending_q) begin
        // A cut terminates the outstanding response once, even if held.
        if (power_cut_i || rsp_cnt_q == 1) begin
          st_rvalid_o <= 1'b1;
          rsp_pending_q <= 1'b0;
          rsp_cnt_q <= '0;
          if (power_cut_i) err_q <= 1'b1;
        end else rsp_cnt_q <= rsp_cnt_q - 1'b1;
      end
    end
  end
  assign st_err_o = err_q;
  // The default response uses the SRAM output in its first valid cycle;
  // stretched responses use the captured value, never live request signals.
  assign st_rdata_o = err_q ? '0 : (rd_capture_q ? rd_merged : rd_data_q);

  // A spill is triggered when staging is full and a write wants a slot;
  // a flush drains the whole buffer. CommitCycles is the media program
  // time per entry.
  logic need_spill;
  // jrnl_q: the entry currently committing is journal-backed; a power cut
  // keeps it and replays it into the array on recovery (ST-025 slice D).
  // replay_q: resume that drain once power returns.
  logic [31:0] cut_count_q, commit_gen_q;
  logic [31:0] journal_gen_q, journal_id_q;
  // This magic only prevents accidental model saves; it is not access control.
  localparam logic [31:0] AbiKey = 32'h5354524D;
  assign unlocked = unlock_key_i == AbiKey;
  assign journal_gen_o = journal_gen_q;
  assign journal_id_o = journal_id_q;
  assign restore_done_o = 1'b0;
  logic power_seen_q;
  assign cut_count_o = cut_count_q;
  assign commit_gen_o = commit_gen_q;
  assign save_done_o = !power_cut_i && save_q && count_q == '0 &&
                       commit_q == CIdle && rsp_idle;
  assign need_spill = count_q == (EW+1)'(StageEntries) && !merge_hit &&
                      st_req_i && st_we_i && in_range && rsp_idle;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stage_v_q <= '0; head_q <= '0; tail_q <= '0; count_q <= '0;
      commit_q <= CIdle; flush_q <= 1'b0; flush_seen_q <= 1'b0;
      st_flush_ack_o <= 1'b0;
      st_flush_err_o <= 1'b0;
      commit_cnt_q <= '0; jrnl_q <= 1'b0; replay_q <= 1'b0; save_q <= 1'b0;
      journal_gen_q <= '0; journal_id_q <= '0;
      cut_count_q <= '0; commit_gen_q <= '0; power_seen_q <= 1'b0;
    end else if (power_cut_i) begin
      // Committed array contents survive; uncommitted staging drops. An
      // entry already in commit is journal-backed: it survives the cut and
      // replays on recovery (all-or-nothing at the commit boundary).
      flush_q <= 1'b0;
      // Retire a held request once with error. Keeping its ownership marker
      // through the cut prevents a fresh success for lost staging on recovery.
      flush_seen_q <= st_flush_req_i;
      st_flush_ack_o <= st_flush_req_i && !flush_seen_q;
      st_flush_err_o <= st_flush_req_i && !flush_seen_q;
      save_q <= 1'b0; commit_cnt_q <= '0;
      if (!power_seen_q) cut_count_q <= cut_count_q + 1'b1;
      power_seen_q <= 1'b1;
      // Process the falling-power event once. A held cut must not discard
      // the retained head, nor may a second cut before replay retirement.
      if (!power_seen_q) begin
        if (stage_v_q[head_q] && (jrnl_q || replay_q)) begin
          for (int i = 0; i < StageEntries; i++)
            stage_v_q[i] <= (i == int'(head_q));
          count_q <= (EW+1)'(1);
          tail_q <= head_q == EW'(StageEntries - 1) ? '0 : head_q + 1'b1;
          replay_q <= 1'b1; jrnl_q <= 1'b0; commit_q <= CIdle;
        end else begin
          stage_v_q <= '0; head_q <= '0; tail_q <= '0; count_q <= '0;
          replay_q <= 1'b0; jrnl_q <= 1'b0; commit_q <= CIdle;
        end
      end
    end else begin
      st_flush_ack_o <= 1'b0;
      st_flush_err_o <= 1'b0;
      power_seen_q <= power_cut_i;
      // A save latches its own drain; already-empty completes next cycle.
      if (save_i && unlocked) save_q <= 1'b1;
      if (save_q && count_q == '0 && commit_q == CIdle && rsp_idle) save_q <= 1'b0;
      // Latch a flush until staging has drained; an already-empty buffer
      // acknowledges while the request is held.
      if (!st_flush_req_i) flush_seen_q <= 1'b0;
      if (st_flush_req_i && !flush_seen_q && count_q != '0) flush_q <= 1'b1;
      if (st_flush_req_i && !flush_seen_q && count_q == '0 && !flush_q &&
          rsp_idle) begin
        st_flush_ack_o <= 1'b1;
        flush_seen_q <= 1'b1;
        commit_gen_q <= commit_gen_q + 1'b1;
      end
      if (commit_q == CIdle && rsp_idle && (flush_q || need_spill || replay_q ||
                                (save_q && count_q != '0))) begin
        commit_q <= CDrain;
        commit_cnt_q <= 16'(CommitCycles - 1);
        jrnl_q <= 1'b1;
      end
      if (commit_q == CDrain) begin
        if (commit_cnt_q != '0) commit_cnt_q <= commit_cnt_q - 1'b1;
        else begin
          commit_cnt_q <= 16'(CommitCycles - 1);
          stage_v_q[head_q] <= 1'b0;
          head_q <= head_q == EW'(StageEntries - 1) ? '0 : head_q + 1'b1;
          count_q <= count_q - 1'b1;
          // Diagnostic identity advances on the same edge as the SRAM write.
          journal_id_q <= 32'(stage_addr_q[head_q]);
          journal_gen_q <= commit_gen_q;
          jrnl_q <= 1'b1;   // next head enters commit if the drain continues
          // A spill or replay commits one entry; a flush drain runs to
          // empty. A flush latched mid-spill takes over the drain.
          if ((flush_q || replay_q) && count_q == 1) begin
            commit_q <= CIdle;
            flush_q <= 1'b0; replay_q <= 1'b0; jrnl_q <= 1'b0;
            if (st_flush_req_i && !flush_seen_q) begin
              st_flush_ack_o <= 1'b1;
              flush_seen_q <= 1'b1;
              commit_gen_q <= commit_gen_q + 1'b1;
            end
          end else if (!flush_q && count_q == 1) begin
            commit_q <= CIdle;
            jrnl_q <= 1'b0;
          end else if (!flush_q) begin
            commit_q <= CIdle;
            jrnl_q <= 1'b0;
          end
        end
      end
      // Stage an accepted write (merge into an existing entry wins over
      // allocating a new one at the tail).
      if (st_gnt_o && in_range && st_we_i) begin
        if (merge_hit) begin
          stage_data_q[merge_idx] <=
              (stage_data_q[merge_idx] & ~expand_be(st_be_i)) |
              (st_wdata_i & expand_be(st_be_i));
          stage_be_q[merge_idx] <= stage_be_q[merge_idx] | st_be_i;
        end else begin
          stage_v_q[tail_q] <= 1'b1;
          stage_addr_q[tail_q] <= st_addr_i[AW+2:3];
          stage_data_q[tail_q] <= st_wdata_i;
          stage_be_q[tail_q] <= st_be_i;
          tail_q <= tail_q == EW'(StageEntries - 1) ? '0 : tail_q + 1'b1;
          count_q <= count_q + 1'b1;
        end
      end
    end
  end

  function automatic logic [63:0] expand_be(input logic [7:0] be);
    logic [63:0] m;
    for (int i = 0; i < 8; i++) m[i*8+:8] = {8{be[i]}};
    return m;
  endfunction
endmodule
