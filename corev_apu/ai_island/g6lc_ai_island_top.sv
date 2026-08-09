// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island top (P3 spine): capability window + AI-3 addr check +
// descriptor engine. Not yet on the SoC AXI map — standalone veri first.
//
// Register map (byte address, 32-bit data):
//   0x0000..0x00FF  capability window (RO)
//   0x0100          control  [0]=enable
//   0x0104          status   [0]=busy, [31:16]=last_status
//   0x0108          doorbell  write kicks submit; [7:0]=qid, [31:8]=ticket
//   0x010C          done sticky (write 1 clears irq/done sticky)
//   0x0110          done ticket (RO)
//   0x0114          done status (RO)
//   0x0120+q*0x20   region: +0 base_lo, +4 base_hi, +8 limit_lo,
//                            +c limit_hi, +10 perm (write commits region)
//   0x0140..0x017F  descriptor latch (16×32-bit)

module g6lc_ai_island_top
  import g6lc_ai_island_cfg_pkg::*;
  import g6lc_ai_desc_pkg::*;
#(
    parameter ai_island_cfg_t IslandCfg = AiIslandLatencyDefault,
    parameter int unsigned    AddrWidth = 64
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,
    input  logic        req_i,
    input  logic        we_i,
    input  logic [15:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        rvalid_o,
    output logic        irq_o,
    // Core-sideband submit (ai.enq): uses latched descriptor + this ticket/qid.
    // Bring-up protocol: SW programs region+desc via MMIO, then loads a
    // *different* island reg (not the just-written addr — STLF can hide the
    // miss) so AXI BRESP has retired, then ai.enq. fence alone is not enough
    // — sideband is a core wire and races the peripheral write.
    input  logic        sb_enq_valid_i,
    input  logic [7:0]  sb_qid_i,
    input  logic [31:0] sb_ticket_i,
    // Completion feedback for ai.poll (in-order tickets)
    output logic [31:0] sb_last_ticket_o,
    output logic [15:0] sb_last_status_o,
    output logic        sb_has_completion_o
);

  localparam int unsigned NumQueues = (IslandCfg.Queues == 0) ? 1 : IslandCfg.Queues;
  localparam int unsigned QidWidth  = (NumQueues > 1) ? $clog2(NumQueues) : 1;

  // ------------------------------------------------------------------ cap
  logic [31:0] cap_rdata;
  logic        cap_rvalid;
  logic        cap_sel;
  assign cap_sel = req_i && (addr_i[15:8] == 8'h00);

  g6lc_ai_cap_window #(.IslandCfg(IslandCfg)) i_cap (
      .clk_i, .rst_ni,
      .req_i   (cap_sel),
      .we_i    (we_i),
      .addr_i  (addr_i),
      .wdata_i (wdata_i),
      .rdata_o (cap_rdata),
      .rvalid_o(cap_rvalid)
  );

  // ------------------------------------------------------------------ regs
  logic              enable_q;
  logic [31:0]       desc_words_q[16];
  logic [QidWidth-1:0] db_qid_q;
  logic [31:0]       db_ticket_q;
  logic              submit_pulse_q;
  logic              done_sticky_q;
  logic              irq_sticky_q;
  logic [31:0]       done_ticket_hold_q;
  logic [15:0]       done_status_hold_q;

  logic [63:0] base_q [NumQueues];
  logic [63:0] limit_q[NumQueues];
  logic [1:0]  perm_q [NumQueues];

  // ------------------------------------------------------------------ check / engine
  logic        submit_ready, done_valid, busy;
  logic [31:0] done_ticket;
  logic [15:0] done_status, last_status;
  logic        done_irq;

  logic                  prog_we;
  logic [QidWidth-1:0]   prog_qid;
  logic [AddrWidth-1:0]  prog_base, prog_limit;
  logic [1:0]            prog_perm;

  logic                  check_req, check_need_r, check_need_w, check_ok;
  logic [QidWidth-1:0]   check_qid;
  logic [AddrWidth-1:0]  check_addr, check_len;

  desc_bits_t desc_bits;
  always_comb begin
    for (int unsigned i = 0; i < 16; i++) desc_bits[i*32 +: 32] = desc_words_q[i];
  end

  g6lc_ai_addr_check #(.NumQueues(NumQueues), .AddrWidth(AddrWidth)) i_addr_check (
      .clk_i, .rst_ni,
      .prog_we_i     (prog_we),
      .prog_qid_i    (prog_qid),
      .prog_base_i   (prog_base),
      .prog_limit_i  (prog_limit),
      .prog_perm_i   (prog_perm),
      .check_req_i   (check_req),
      .check_qid_i   (check_qid),
      .check_addr_i  (check_addr),
      .check_len_i   (check_len),
      .check_need_r_i(check_need_r),
      .check_need_w_i(check_need_w),
      .check_ok_o    (check_ok)
  );

  // Stretch core sideband pulse so a 1-cycle enq is not missed if the
  // engine is mid-cycle. Clear on accept (ready) so we do not re-submit
  // the same ticket when the engine returns to IDLE.
  logic        sb_enq_sticky_q;
  logic [7:0]  sb_qid_hold_q;
  logic [31:0] sb_ticket_hold_q;

  // Mux MMIO doorbell vs core sideband kick (sideband preferred)
  logic                  submit_valid_mux;
  logic [QidWidth-1:0]   submit_qid_mux;
  logic [31:0]           submit_ticket_mux;
  always_comb begin
    if (sb_enq_sticky_q || sb_enq_valid_i) begin
      submit_valid_mux  = 1'b1;
      submit_qid_mux    = QidWidth'(sb_enq_valid_i ? sb_qid_i : sb_qid_hold_q);
      submit_ticket_mux = sb_enq_valid_i ? sb_ticket_i : sb_ticket_hold_q;
    end else begin
      submit_valid_mux  = submit_pulse_q;
      submit_qid_mux    = db_qid_q;
      submit_ticket_mux = db_ticket_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sb_enq_sticky_q  <= 1'b0;
      sb_qid_hold_q    <= '0;
      sb_ticket_hold_q <= '0;
    end else begin
      // Accept this cycle ⇒ drop sticky (covers valid&&ready same cycle too).
      if (submit_ready && (sb_enq_sticky_q || sb_enq_valid_i)) begin
        sb_enq_sticky_q <= 1'b0;
      end else if (sb_enq_valid_i) begin
        // Engine busy: hold until ready.
        sb_enq_sticky_q  <= 1'b1;
        sb_qid_hold_q    <= sb_qid_i;
        sb_ticket_hold_q <= sb_ticket_i;
      end
    end
  end

  g6lc_ai_desc_engine #(.NumQueues(NumQueues), .AddrWidth(AddrWidth)) i_engine (
      .clk_i, .rst_ni,
      .testmode_i      (testmode_i),
      .enable_i        (enable_q),
      .submit_valid_i  (submit_valid_mux),
      .submit_ready_o  (submit_ready),
      .submit_qid_i    (submit_qid_mux),
      .submit_ticket_i (submit_ticket_mux),
      .submit_desc_i   (desc_bits),
      .done_valid_o    (done_valid),
      .done_ticket_o   (done_ticket),
      .done_status_o   (done_status),
      .done_irq_o      (done_irq),
      .prog_we_o       (),
      .prog_qid_o      (),
      .prog_base_o     (),
      .prog_limit_o    (),
      .prog_perm_o     (),
      .prog_ext_we_i   (prog_we),
      .prog_ext_qid_i  (prog_qid),
      .prog_ext_base_i (prog_base),
      .prog_ext_limit_i(prog_limit),
      .prog_ext_perm_i (prog_perm),
      .check_req_o     (check_req),
      .check_qid_o     (check_qid),
      .check_addr_o    (check_addr),
      .check_len_o     (check_len),
      .check_need_r_o  (check_need_r),
      .check_need_w_o  (check_need_w),
      .check_ok_i      (check_ok),
      .busy_o          (busy),
      .last_status_o   (last_status)
  );

  // ------------------------------------------------------------------ writes + prog pulse
  always_comb begin
    int unsigned q;
    logic [15:0] off;
    q   = 0;
    off = '0;
    prog_we    = 1'b0;
    prog_qid   = '0;
    prog_base  = '0;
    prog_limit = '0;
    prog_perm  = '0;
    if (req_i && we_i && addr_i[15:0] >= 16'h0120 && addr_i[15:0] < 16'h0140) begin
      q   = (unsigned'(addr_i[15:0]) - 32'h0120) >> 5;
      off = (addr_i[15:0] - 16'h0120) & 16'h1f;
      if (q < NumQueues && off[4:2] == 3'd4) begin
        // Commit region on perm write; base/limit already stored
        prog_we    = 1'b1;
        prog_qid   = QidWidth'(q);
        prog_base  = AddrWidth'(base_q[q]);
        prog_limit = AddrWidth'(limit_q[q]);
        prog_perm  = wdata_i[1:0];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      enable_q            <= 1'b0;
      db_qid_q            <= '0;
      db_ticket_q         <= '0;
      submit_pulse_q      <= 1'b0;
      done_sticky_q       <= 1'b0;
      irq_sticky_q        <= 1'b0;
      done_ticket_hold_q  <= '0;
      done_status_hold_q  <= '0;
      for (int unsigned i = 0; i < 16; i++) desc_words_q[i] <= '0;
      for (int unsigned q = 0; q < NumQueues; q++) begin
        base_q[q]  <= '0;
        limit_q[q] <= '0;
        perm_q[q]  <= '0;
      end
    end else begin
      submit_pulse_q <= 1'b0;

      if (done_valid) begin
        done_sticky_q      <= 1'b1;
        done_ticket_hold_q <= done_ticket;
        done_status_hold_q <= done_status;
        if (done_irq) irq_sticky_q <= 1'b1;
      end

      if (req_i && we_i) begin
        if (addr_i[15:0] == 16'h0100) begin
          enable_q <= wdata_i[0];
        end else if (addr_i[15:0] == 16'h0108) begin
          db_qid_q       <= QidWidth'(wdata_i[7:0]);
          db_ticket_q    <= {8'h0, wdata_i[31:8]};
          submit_pulse_q <= 1'b1;
        end else if (addr_i[15:0] == 16'h010C) begin
          if (wdata_i[0]) begin
            done_sticky_q <= 1'b0;
            irq_sticky_q  <= 1'b0;
          end
        end else if (addr_i[15:0] >= 16'h0140 && addr_i[15:0] < 16'h0180) begin
          desc_words_q[addr_i[5:2]] <= wdata_i;
        end else if (addr_i[15:0] >= 16'h0120 && addr_i[15:0] < 16'h0140) begin
          automatic int unsigned q;
          automatic logic [15:0] off;
          q   = (unsigned'(addr_i[15:0]) - 32'h0120) >> 5;
          off = (addr_i[15:0] - 16'h0120) & 16'h1f;
          if (q < NumQueues) begin
            unique case (off[4:2])
              3'd0: base_q[q][31:0]   <= wdata_i;
              3'd1: base_q[q][63:32]  <= wdata_i;
              3'd2: limit_q[q][31:0]  <= wdata_i;
              3'd3: limit_q[q][63:32] <= wdata_i;
              3'd4: perm_q[q]         <= wdata_i[1:0];
              default: ;
            endcase
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------ reads
  // One-cycle registered response for non-cap; cap window already registered.
  logic [31:0] rdata_n, rdata_q;
  logic        rvalid_n, rvalid_q;
  logic        cap_pending_q;

  always_comb begin
    int unsigned q;
    logic [15:0] off;
    q   = 0;
    off = '0;
    rdata_n  = '0;
    rvalid_n = 1'b0;
    if (req_i && !cap_sel) begin
      rvalid_n = 1'b1;
      unique case (addr_i[15:0])
        16'h0100: rdata_n = {31'h0, enable_q};
        16'h0104: rdata_n = {last_status, 15'h0, busy};
        16'h0108: rdata_n = {db_ticket_q[23:0], 8'(db_qid_q)};
        16'h010C: rdata_n = {31'h0, done_sticky_q};
        16'h0110: rdata_n = done_ticket_hold_q;
        16'h0114: rdata_n = {16'h0, done_status_hold_q};
        default: begin
          if (addr_i[15:0] >= 16'h0140 && addr_i[15:0] < 16'h0180)
            rdata_n = desc_words_q[addr_i[5:2]];
          else if (addr_i[15:0] >= 16'h0120 && addr_i[15:0] < 16'h0140) begin
            q   = (unsigned'(addr_i[15:0]) - 32'h0120) >> 5;
            off = (addr_i[15:0] - 16'h0120) & 16'h1f;
            if (q < NumQueues) begin
              unique case (off[4:2])
                3'd0: rdata_n = base_q[q][31:0];
                3'd1: rdata_n = base_q[q][63:32];
                3'd2: rdata_n = limit_q[q][31:0];
                3'd3: rdata_n = limit_q[q][63:32];
                3'd4: rdata_n = {30'h0, perm_q[q]};
                default: rdata_n = '0;
              endcase
            end
          end
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_q       <= '0;
      rvalid_q      <= 1'b0;
      cap_pending_q <= 1'b0;
    end else begin
      cap_pending_q <= cap_sel;
      if (cap_pending_q) begin
        rdata_q  <= cap_rdata;
        rvalid_q <= cap_rvalid;
      end else begin
        rdata_q  <= rdata_n;
        rvalid_q <= rvalid_n;
      end
    end
  end

  assign rdata_o  = rdata_q;
  assign rvalid_o = rvalid_q;
  assign irq_o    = irq_sticky_q;

  assign sb_last_ticket_o     = done_ticket_hold_q;
  assign sb_last_status_o     = done_status_hold_q;
  assign sb_has_completion_o  = done_sticky_q;

  // Silence unused
  // verilator lint_off UNUSEDSIGNAL
  logic _sr;
  assign _sr = submit_ready;
  // verilator lint_on UNUSEDSIGNAL

endmodule
