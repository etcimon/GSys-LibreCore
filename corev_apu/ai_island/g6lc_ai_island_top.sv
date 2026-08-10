// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island top (P3 spine): capability window + AI-3 addr check +
// descriptor engine. Not yet on the SoC AXI map — standalone veri first.
//
// Register map (byte address, 32-bit data):
//   0x0000..0x00FF  capability window (RO)
//   0x0100          control  [0]=enable [1]=wr_cpl_en (completion DMA; default 1 if DMA)
//   0x0104          status   [0]=busy, [1]=fetch_busy, [31:16]=last_status
//   0x0108          doorbell  [7:0]=qid, [30:8]=ticket, [31]=fetch_from_mem
//   0x010C          done sticky (write 1 clears irq/done sticky)
//   0x0110          done ticket (RO)
//   0x0114          done status (RO)
//   0x0118/0x011C   desc_ptr lo/hi (fetch source when doorbell[31]=1)
//   0x0120+q*0x20   region: +0 base_lo, +4 base_hi, +8 limit_lo,
//                            +c limit_hi, +10 perm (write commits region)
//   0x0140..0x017F  descriptor latch (16×32-bit)

module g6lc_ai_island_top
  import g6lc_ai_island_cfg_pkg::*;
  import g6lc_ai_desc_pkg::*;
#(
    parameter ai_island_cfg_t IslandCfg = AiIslandLatencyDefault,
    parameter int unsigned    AddrWidth = 64,
    // When 1: instantiate AXI desc-fetch (SoC). Standalone spine keeps 0.
    parameter bit             EnableDmaFetch = 1'b0,
    parameter int unsigned    AxiDataWidth = 64,
    parameter int unsigned    AxiIdWidth   = 4,
    parameter type            axi_req_t    = logic,
    parameter type            axi_resp_t   = logic
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
    // Sideband: non-zero sb_desc_ptr_i ⇒ DMA-fetch then submit; zero ⇒ latched desc.
    input  logic        sb_enq_valid_i,
    input  logic [7:0]  sb_qid_i,
    input  logic [31:0] sb_ticket_i,
    input  logic [63:0] sb_desc_ptr_i,
    // Completion feedback for ai.poll (in-order tickets)
    output logic [31:0] sb_last_ticket_o,
    output logic [15:0] sb_last_status_o,
    output logic        sb_has_completion_o,
    // AXI master for desc fetch (tie req idle / resp ready when EnableDmaFetch=0)
    output axi_req_t    axi_dma_req_o,
    input  axi_resp_t   axi_dma_resp_i
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
  logic              wr_cpl_en_q;  // CTL[1]: completion-word DMA (runtime)
  logic [31:0]       desc_words_q[16];
  logic [QidWidth-1:0] db_qid_q;
  logic [31:0]       db_ticket_q;
  logic              submit_pulse_q;
  logic              done_sticky_q;
  logic              irq_sticky_q;
  logic [31:0]       done_ticket_hold_q;
  logic [15:0]       done_status_hold_q;
  logic [63:0]       desc_ptr_q;

  logic [63:0] base_q [NumQueues];
  logic [63:0] limit_q[NumQueues];
  logic [1:0]  perm_q [NumQueues];

  // ------------------------------------------------------------------ check / engine
  logic        submit_ready, done_valid, busy_engine;
  logic [31:0] done_ticket;
  logic [15:0] done_status, last_status;
  logic        done_irq;
  logic        fetch_busy;
  logic        busy;
  assign busy = busy_engine || fetch_busy;

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

  // Stretch core sideband pulse: zero ptr ⇒ submit latched desc; non-zero
  // ptr ⇒ DMA-fetch then submit. Clear sticky on engine accept.
  logic        sb_enq_sticky_q;
  logic [7:0]  sb_qid_hold_q;
  logic [31:0] sb_ticket_hold_q;
  logic        sb_fetch_pending_q;  // sideband wait for DMA
  logic        fetch_src_sb_q;      // 1=sideband kick, 0=doorbell[31]
  logic [63:0] fetch_addr_q;

  // Sideband same-cycle submit only when not DMA-fetching a ptr
  logic sb_imm_submit;
  assign sb_imm_submit = sb_enq_valid_i &&
      (!EnableDmaFetch || (sb_desc_ptr_i == '0));

  // Mux MMIO doorbell vs core sideband kick (sideband preferred)
  logic                  submit_valid_mux;
  logic [QidWidth-1:0]   submit_qid_mux;
  logic [31:0]           submit_ticket_mux;
  always_comb begin
    if (sb_enq_sticky_q || sb_imm_submit) begin
      submit_valid_mux  = 1'b1;
      submit_qid_mux    = QidWidth'(sb_imm_submit ? sb_qid_i : sb_qid_hold_q);
      submit_ticket_mux = sb_imm_submit ? sb_ticket_i : sb_ticket_hold_q;
    end else begin
      submit_valid_mux  = submit_pulse_q;
      submit_qid_mux    = db_qid_q;
      submit_ticket_mux = db_ticket_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sb_enq_sticky_q    <= 1'b0;
      sb_qid_hold_q      <= '0;
      sb_ticket_hold_q   <= '0;
      sb_fetch_pending_q <= 1'b0;
    end else begin
      if (submit_ready && (sb_enq_sticky_q || sb_imm_submit)) begin
        sb_enq_sticky_q <= 1'b0;
      end else if (sb_imm_submit && !submit_ready) begin
        sb_enq_sticky_q  <= 1'b1;
        sb_qid_hold_q    <= sb_qid_i;
        sb_ticket_hold_q <= sb_ticket_i;
      end else if (EnableDmaFetch && sb_enq_valid_i && (sb_desc_ptr_i != '0)) begin
        // Hold identity for post-fetch submit
        sb_qid_hold_q      <= sb_qid_i;
        sb_ticket_hold_q   <= sb_ticket_i;
        sb_fetch_pending_q <= 1'b1;
      end
      // After sideband DMA success, sticky submit is armed in the write FF block
      if (EnableDmaFetch && fetch_done && fetch_src_sb_q && !fetch_err) begin
        sb_enq_sticky_q    <= 1'b1;
        sb_fetch_pending_q <= 1'b0;
      end else if (EnableDmaFetch && fetch_done && fetch_src_sb_q && fetch_err) begin
        sb_fetch_pending_q <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------ DMA: fetch + completion store + GEMM (muxed AXI)
  logic        fetch_start_q;
  logic        fetch_ready, fetch_done, fetch_err;
  desc_bits_t  fetch_desc;
  logic        fetch_err_complete_q;  // one-cycle pulse after bus error

  logic        wr_start, wr_ready, wr_done, wr_err;
  logic [AddrWidth-1:0] wr_addr;
  logic [63:0] wr_data;
  axi_req_t    fetch_axi_req, store_axi_req, gemm_axi_req;

  // I1-lite GEMM handshake / params (engine → unit)
  logic        gemm_start, gemm_ready, gemm_done, gemm_err;
  logic [31:0] gemm_m, gemm_n, gemm_k;
  logic [15:0] gemm_lda, gemm_ldb;
  logic [AddrWidth-1:0] gemm_ptr_a, gemm_ptr_b, gemm_ptr_c;

  if (EnableDmaFetch) begin : gen_dma_fetch
    g6lc_ai_desc_fetch #(
        .AddrWidth (AddrWidth),
        .DataWidth (AxiDataWidth),
        .IdWidth   (AxiIdWidth),
        .axi_req_t (axi_req_t),
        .axi_resp_t(axi_resp_t)
    ) i_fetch (
        .clk_i,
        .rst_ni,
        .start_i (fetch_start_q),
        .addr_i  (AddrWidth'(fetch_addr_q)),
        .ready_o (fetch_ready),
        .done_o  (fetch_done),
        .err_o   (fetch_err),
        .desc_o  (fetch_desc),
        .axi_req_o  (fetch_axi_req),
        .axi_resp_i (axi_dma_resp_i)
    );
    g6lc_ai_mem_store #(
        .AddrWidth (AddrWidth),
        .DataWidth (AxiDataWidth),
        .IdWidth   (AxiIdWidth),
        .axi_req_t (axi_req_t),
        .axi_resp_t(axi_resp_t)
    ) i_store (
        .clk_i,
        .rst_ni,
        .start_i (wr_start),
        .addr_i  (wr_addr),
        .data_i  (AxiDataWidth'(wr_data)),
        .ready_o (wr_ready),
        .done_o  (wr_done),
        .err_o   (wr_err),
        .axi_req_o  (store_axi_req),
        .axi_resp_i (axi_dma_resp_i)
    );
    // Geometry from IslandCfg (single source with capability window).
    // I1-lite assumes square AccTileM=N=K; PeLanes = MacsPerCycle.
    // pragma translate_off
    initial begin
      assert (IslandCfg.AccTileM == IslandCfg.AccTileN
              && IslandCfg.AccTileN == IslandCfg.AccTileK)
      else $error("g6lc_ai_island: AccTileM/N/K must be equal (I1-lite square tile)");
      assert (IslandCfg.MacsPerCycle >= 1 && IslandCfg.AccTileM >= 1)
      else $error("g6lc_ai_island: MacsPerCycle and AccTileM must be >= 1");
      assert (IslandCfg.MacsPerCycle <= IslandCfg.AccTileK)
      else $error("g6lc_ai_island: MacsPerCycle must be <= AccTileK");
    end
    // pragma translate_on
    g6lc_ai_gemm_seq #(
        .AddrWidth (AddrWidth),
        .DataWidth (AxiDataWidth),
        .IdWidth   (AxiIdWidth),
        .MaxDim    (IslandCfg.AccTileM),
        .PeLanes   (IslandCfg.MacsPerCycle),
        .axi_req_t (axi_req_t),
        .axi_resp_t(axi_resp_t)
    ) i_gemm (
        .clk_i,
        .rst_ni,
        .testmode_i(testmode_i),
        .start_i  (gemm_start),
        .m_i      (gemm_m),
        .n_i      (gemm_n),
        .k_i      (gemm_k),
        .lda_i    (gemm_lda),
        .ldb_i    (gemm_ldb),
        .ptr_a_i  (gemm_ptr_a),
        .ptr_b_i  (gemm_ptr_b),
        .ptr_c_i  (gemm_ptr_c),
        .ready_o  (gemm_ready),
        .done_o   (gemm_done),
        .err_o    (gemm_err),
        .axi_req_o  (gemm_axi_req),
        .axi_resp_i (axi_dma_resp_i)
    );
    // Priority: completion store > GEMM > desc fetch. When all idle, drive a
    // clean zero req (no b_ready) so the DMA master cannot siphon B beats from
    // the xbar — that was observed to break subsequent PLIC claim.
    logic store_active, gemm_active;
    assign store_active = (!wr_ready || wr_start);
    assign gemm_active  = (!gemm_ready || gemm_start);
    assign axi_dma_req_o = store_active ? store_axi_req
                         : gemm_active  ? gemm_axi_req
                         : (!fetch_ready ? fetch_axi_req : '0);
    assign fetch_busy = !fetch_ready || sb_fetch_pending_q || !wr_ready || !gemm_ready;
  end else begin : gen_no_dma_fetch
    assign fetch_ready = 1'b1;
    assign fetch_done  = 1'b0;
    assign fetch_err   = 1'b0;
    assign fetch_desc  = '0;
    assign fetch_busy  = 1'b0;
    assign fetch_axi_req = '0;
    assign store_axi_req = '0;
    assign gemm_axi_req  = '0;
    assign axi_dma_req_o = '0;
    assign wr_ready = 1'b1;
    // One-cycle delayed ack so engine sees wr_issued_q && wr_done_i
    // (same-cycle wr_done=wr_start leaves ST_WR_DONE wedged).
    logic wr_done_q, gemm_done_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        wr_done_q   <= 1'b0;
        gemm_done_q <= 1'b0;
      end else begin
        wr_done_q   <= wr_start;
        gemm_done_q <= gemm_start;
      end
    end
    assign wr_done    = wr_done_q;
    assign wr_err     = 1'b0;
    assign gemm_ready = 1'b1;
    assign gemm_done  = gemm_done_q;
    assign gemm_err   = 1'b0;  // accept-only path when no DMA master
    // verilator lint_off UNUSEDSIGNAL
    logic _ax;
    assign _ax = |axi_dma_resp_i | sb_fetch_pending_q | |sb_desc_ptr_i
                 | |wr_addr | |wr_data
                 | |gemm_m | |gemm_n | |gemm_k | |gemm_lda | |gemm_ldb
                 | |gemm_ptr_a | |gemm_ptr_b | |gemm_ptr_c;
    // verilator lint_on UNUSEDSIGNAL
  end

  g6lc_ai_desc_engine #(
      .NumQueues       (NumQueues),
      .AddrWidth       (AddrWidth),
      .WriteCompletion (EnableDmaFetch),
      .ExecuteGemm     (EnableDmaFetch)
  ) i_engine (
      .clk_i, .rst_ni,
      .testmode_i      (testmode_i),
      .enable_i        (enable_q),
      .wr_cpl_en_i     (wr_cpl_en_q),
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
      .busy_o          (busy_engine),
      .last_status_o   (last_status),
      .wr_start_o      (wr_start),
      .wr_addr_o       (wr_addr),
      .wr_data_o       (wr_data),
      .wr_ready_i      (wr_ready),
      .wr_done_i       (wr_done),
      .wr_err_i        (wr_err),
      .gemm_start_o    (gemm_start),
      .gemm_m_o        (gemm_m),
      .gemm_n_o        (gemm_n),
      .gemm_k_o        (gemm_k),
      .gemm_lda_o      (gemm_lda),
      .gemm_ldb_o      (gemm_ldb),
      .gemm_ptr_a_o    (gemm_ptr_a),
      .gemm_ptr_b_o    (gemm_ptr_b),
      .gemm_ptr_c_o    (gemm_ptr_c),
      .gemm_ready_i    (gemm_ready),
      .gemm_done_i     (gemm_done),
      .gemm_err_i      (gemm_err)
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
      wr_cpl_en_q         <= EnableDmaFetch;  // on when DMA path present
      db_qid_q            <= '0;
      db_ticket_q         <= '0;
      submit_pulse_q      <= 1'b0;
      done_sticky_q       <= 1'b0;
      irq_sticky_q        <= 1'b0;
      done_ticket_hold_q  <= '0;
      done_status_hold_q  <= '0;
      desc_ptr_q          <= '0;
      fetch_start_q       <= 1'b0;
      fetch_err_complete_q <= 1'b0;
      fetch_src_sb_q      <= 1'b0;
      fetch_addr_q        <= '0;
      for (int unsigned i = 0; i < 16; i++) desc_words_q[i] <= '0;
      for (int unsigned q = 0; q < NumQueues; q++) begin
        base_q[q]  <= '0;
        limit_q[q] <= '0;
        perm_q[q]  <= '0;
      end
    end else begin
      submit_pulse_q       <= 1'b0;
      fetch_start_q        <= 1'b0;
      fetch_err_complete_q <= 1'b0;

      // Engine completion
      if (done_valid) begin
        done_sticky_q      <= 1'b1;
        done_ticket_hold_q <= done_ticket;
        done_status_hold_q <= done_status;
        if (done_irq) irq_sticky_q <= 1'b1;
      end

      // Sideband kick with non-zero ptr ⇒ start DMA (identity held in sticky FF)
      if (EnableDmaFetch && sb_enq_valid_i && (sb_desc_ptr_i != '0) && fetch_ready) begin
        fetch_addr_q   <= sb_desc_ptr_i;
        fetch_src_sb_q <= 1'b1;
        fetch_start_q  <= 1'b1;
      end

      // DMA fetch completion: load latch + submit, or bus-error complete
      if (EnableDmaFetch && fetch_done) begin
        if (fetch_err) begin
          done_sticky_q        <= 1'b1;
          done_ticket_hold_q   <= fetch_src_sb_q ? sb_ticket_hold_q : db_ticket_q;
          done_status_hold_q   <= ST_ERR;
          fetch_err_complete_q <= 1'b1;
        end else begin
          for (int unsigned i = 0; i < 16; i++)
            desc_words_q[i] <= fetch_desc[i*32 +: 32];
          // Doorbell path: pulse submit. Sideband path: sticky FF arms submit.
          if (!fetch_src_sb_q) submit_pulse_q <= 1'b1;
        end
      end

      if (req_i && we_i) begin
        if (addr_i[15:0] == 16'h0100) begin
          enable_q    <= wdata_i[0];
          wr_cpl_en_q <= wdata_i[1];
        end else if (addr_i[15:0] == 16'h0108) begin
          db_qid_q    <= QidWidth'(wdata_i[7:0]);
          db_ticket_q <= {9'h0, wdata_i[30:8]};
          // [31]=fetch_from_mem (DMA); else immediate submit of latched desc
          if (EnableDmaFetch && wdata_i[31] && (desc_ptr_q != '0) && fetch_ready) begin
            fetch_addr_q   <= desc_ptr_q;
            fetch_src_sb_q <= 1'b0;
            fetch_start_q  <= 1'b1;
          end else if (!(EnableDmaFetch && wdata_i[31] && (desc_ptr_q != '0))) begin
            submit_pulse_q <= 1'b1;
          end
        end else if (addr_i[15:0] == 16'h010C) begin
          if (wdata_i[0]) begin
            done_sticky_q <= 1'b0;
            irq_sticky_q  <= 1'b0;
          end
        end else if (addr_i[15:0] == 16'h0118) begin
          desc_ptr_q[31:0] <= wdata_i;
        end else if (addr_i[15:0] == 16'h011C) begin
          desc_ptr_q[63:32] <= wdata_i;
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
        16'h0100: rdata_n = {30'h0, wr_cpl_en_q, enable_q};
        16'h0104: rdata_n = {last_status, 14'h0, fetch_busy, busy};
        16'h0108: rdata_n = {db_ticket_q[23:0], 8'(db_qid_q)};
        16'h010C: rdata_n = {31'h0, done_sticky_q};
        16'h0110: rdata_n = done_ticket_hold_q;
        16'h0114: rdata_n = {16'h0, done_status_hold_q};
        16'h0118: rdata_n = desc_ptr_q[31:0];
        16'h011C: rdata_n = desc_ptr_q[63:32];
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
  logic _sr, _fec;
  assign _sr  = submit_ready;
  assign _fec = fetch_err_complete_q;
  // verilator lint_on UNUSEDSIGNAL

endmodule
