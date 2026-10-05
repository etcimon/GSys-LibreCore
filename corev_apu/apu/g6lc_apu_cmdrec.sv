// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Command recorder (§6 + §7b of architecture/uncore/apu-vulkan-engine.md):
// one tc_sram arena of NumBufs x RecsPerBuf fixed 16-word records,
// each a resolved vkCmd* decode (apu_cmdrec_rec_t), plus a second
// tc_sram of NumBufs x PayWordsPerBuf payload words.  Records are
// appended while a buffer is RECORDING, sealed by END, and read back
// by the submit-time executor.  Per-buffer {count, recording, sealed,
// pay_top} lives in flops; the two arenas are the only SRAMs (retained
// by synthesis).
//
// Ops (ready/valid request, one completion):
//   BEGIN   (buf)        : start recording; clears count/sealed/pay_top
//   APPEND  (buf, rec, pay_n) : store at count (imm[7] <- pay_top when
//                          pay_n != 0), then stream pay_n words on the
//                          pay port; FULL at RecsPerBuf, PAY_FULL when
//                          pay_top + pay_n > PayWordsPerBuf (the record
//                          is not appended)
//   END     (buf)        : seal the buffer (recording -> 0, sealed -> 1)
//   RESET   (buf)        : drop all state (count=0, unrecord, unseal,
//                          pay_top=0)
//   READ    (buf, idx)   : return rec; needs sealed, idx < count
//   PAYREAD (buf, idx)   : return arena word idx in pdata; needs sealed,
//                          idx < PayWordsPerBuf
//   COUNT   (buf)        : return current fill
// Statuses: OK, FULL, NOT_RECORDING, NOT_SEALED, BAD_IDX, BAD_BUF,
// PAY_FULL.
//
// Payload stream: while an APPEND is being serviced (StPay), the
// producer holds pay_valid_i with the next word on pay_data_i;
// pay_ready_o marks acceptance (one word per cycle).
//
// Timing impact: one record-SRAM access per record op and one
// payload-SRAM word per streamed word; per-buffer state is four flops.
// The widest cone is the 512-bit record mux into wdata.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; Enable=0 elaborates no datapath; req/cpl are the objtab
// ready/valid shape.

module g6lc_apu_cmdrec
  import g6lc_apu_cmdrec_pkg::*;
#(
  parameter bit          Enable         = 1'b0,
  parameter int unsigned NumBufs        = 16,
  parameter int unsigned RecsPerBuf     = 64,
  parameter int unsigned PayWordsPerBuf = 256
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_cmdrec_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_cmdrec_cpl_t cpl_o,
  // §7b payload stream for APPEND
  input  logic            pay_valid_i,
  input  logic [31:0]     pay_data_i,
  output logic            pay_ready_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o       = '0;
    assign pay_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i |
                    cpl_ready_i | (|req_i) | pay_valid_i |
                    (|pay_data_i);
  end else begin : gen_on
    localparam int unsigned BufBits = $clog2(NumBufs);
    localparam int unsigned RecBits = $clog2(RecsPerBuf);
    localparam int unsigned Words   = NumBufs * RecsPerBuf;
    localparam int unsigned AdrBits = $clog2(Words);
    localparam int unsigned RecW    = $bits(apu_cmdrec_rec_t);
    localparam int unsigned PayBits = $clog2(PayWordsPerBuf);
    localparam int unsigned PWords  = NumBufs * PayWordsPerBuf;
    localparam int unsigned PAdr    = $clog2(PWords);

    typedef enum logic [2:0] { StIdle, StRdCap, StPayRd, StPay,
                             StCpl } state_e;
    state_e           state_q;
    apu_cmdrec_req_t  req_q;
    apu_cmdrec_cpl_t  cpl_q;

    logic [7:0] cnt_q  [NumBufs];
    logic       recd_q [NumBufs];
    logic       seal_q [NumBufs];
    logic [PayBits:0] ptop_q [NumBufs];   // bump ptr, 0..PayWordsPerBuf
    logic [PayBits:0] pptr_q;             // in-flight stream cursor
    logic [15:0]      prem_q;             // words left in the stream
    logic             pay_drop_q;         // PAY_FULL: drain, don't store

    logic buf_ok, rec_ok, seal_ok;
    assign buf_ok  = req_i.cbuf < 8'(NumBufs);
    assign rec_ok  = recd_q[req_i.cbuf[BufBits-1:0]];
    assign seal_ok = seal_q[req_i.cbuf[BufBits-1:0]];
    logic [7:0] cnt_cur;
    assign cnt_cur = cnt_q[req_i.cbuf[BufBits-1:0]];
    logic [PayBits:0] ptop_cur;
    assign ptop_cur = ptop_q[req_i.cbuf[BufBits-1:0]];
    // payload arena would overflow for this APPEND
    logic pay_ovf;
    assign pay_ovf = (32'(ptop_cur) + 32'(req_i.pay_n)) >
                     32'(PayWordsPerBuf);

    // ---- record arena -----------------------------------------------
    logic                  ara_req, ara_we;
    logic [AdrBits-1:0]    ara_addr;
    apu_cmdrec_rec_t       ara_wdata;
    logic [RecW-1:0]       ara_rdata;
    logic [RecBits-1:0]    ara_idx;
    assign ara_idx  = req_i.op == APU_CMDREC_OP_APPEND
                      ? RecBits'(cnt_cur) : RecBits'(req_i.idx);
    assign ara_addr = AdrBits'(req_i.cbuf[BufBits-1:0] * RecsPerBuf) +
                      AdrBits'(ara_idx);
    tc_sram #(.NumWords(Words), .DataWidth(RecW), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_arena (
      .clk_i, .rst_ni, .req_i(ara_req), .we_i(ara_we),
      .addr_i(ara_addr), .wdata_i(RecW'(ara_wdata)), .be_i('1),
      .rdata_o(ara_rdata)
    );

    // ---- payload arena ----------------------------------------------
    logic              pay_req, pay_we;
    logic [PAdr-1:0]   pay_addr;
    logic [31:0]       pay_rdata;
    tc_sram #(.NumWords(PWords), .DataWidth(32), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_pay (
      .clk_i, .rst_ni, .req_i(pay_req), .we_i(pay_we),
      .addr_i(pay_addr), .wdata_i(pay_data_i), .be_i('1),
      .rdata_o(pay_rdata)
    );

    assign req_ready_o = state_q == StIdle;
    assign cpl_valid_o = state_q == StCpl;
    assign cpl_o       = cpl_q;
    assign pay_ready_o = state_q == StPay;

    always_comb begin
      ara_req   = 1'b0;
      ara_we    = 1'b0;
      ara_wdata = req_i.rec;
      pay_req   = 1'b0;
      pay_we    = 1'b0;
      pay_addr  = '0;
      if (state_q == StIdle && req_valid_i && buf_ok) begin
        if (req_i.op == APU_CMDREC_OP_APPEND && rec_ok &&
            cnt_cur < 8'(RecsPerBuf) && !pay_ovf) begin
          ara_req = 1'b1;
          ara_we  = 1'b1;
          if (req_i.pay_n != 16'h0)
            ara_wdata.imm[7] = 32'(ptop_cur); // §7b: imm[7] = pay_base
        end else if (req_i.op == APU_CMDREC_OP_READ && seal_ok &&
                     req_i.idx < cnt_cur) begin
          ara_req = 1'b1;
        end else if (req_i.op == APU_CMDREC_OP_PAYREAD && seal_ok &&
                     req_i.idx < 16'(PayWordsPerBuf)) begin
          pay_req  = 1'b1;
          pay_addr = PAdr'(req_i.cbuf[BufBits-1:0] * PayWordsPerBuf) +
                     PAdr'(req_i.idx);
        end
      end else if (state_q == StPay) begin
        pay_req  = pay_valid_i && !pay_drop_q;
        pay_we   = pay_valid_i && !pay_drop_q;
        pay_addr = PAdr'(req_q.cbuf[BufBits-1:0] * PayWordsPerBuf) +
                   PAdr'(pptr_q);
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        req_q   <= '0;
        cpl_q   <= '0;
        pptr_q  <= '0; prem_q <= '0; pay_drop_q <= 1'b0;
        for (int i = 0; i < NumBufs; i++) begin
          cnt_q[i]  <= '0;
          recd_q[i] <= 1'b0;
          seal_q[i] <= 1'b0;
          ptop_q[i] <= '0;
        end
      end else begin
        case (state_q)
          StIdle: if (req_valid_i) begin
            req_q <= req_i;
            if (req_i.op == APU_CMDREC_OP_APPEND &&
                req_i.pay_n != 16'h0) begin
              // §7b: the front streams pay_n words unconditionally
              // after the request accept, so a rejected APPEND must
              // still drain them -- decide the status now, consume the
              // stream in StPay (dropped unless the append succeeds),
              // then complete.
              prem_q  <= req_i.pay_n;
              pptr_q  <= ptop_cur;
              state_q <= StPay;
              if (!buf_ok) begin
                pay_drop_q <= 1'b1;
                cpl_q <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                           pdata: '0, rec: '0};
              end else if (!rec_ok) begin
                pay_drop_q <= 1'b1;
                cpl_q <= '{status: APU_CMDREC_NOT_RECORDING,
                           count: cnt_cur, pdata: '0, rec: '0};
              end else if (cnt_cur >= 8'(RecsPerBuf)) begin
                pay_drop_q <= 1'b1;
                cpl_q <= '{status: APU_CMDREC_FULL, count: cnt_cur,
                           pdata: '0, rec: '0};
              end else if (pay_ovf) begin
                pay_drop_q <= 1'b1;
                cpl_q <= '{status: APU_CMDREC_PAY_FULL, count: cnt_cur,
                           pdata: '0, rec: '0};
              end else begin
                // record written combinationally this cycle
                pay_drop_q <= 1'b0;
                cnt_q[req_i.cbuf[BufBits-1:0]]  <= cnt_cur + 8'h1;
                ptop_q[req_i.cbuf[BufBits-1:0]] <=
                    ptop_cur + (PayBits+1)'(req_i.pay_n);
                cpl_q <= '{status: APU_CMDREC_OK,
                           count: cnt_cur + 8'h1, pdata: '0, rec: '0};
              end
            end else if (!buf_ok) begin
              cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                           pdata: '0, rec: '0};
              state_q <= StCpl;
            end else begin
              case (req_i.op)
                APU_CMDREC_OP_BEGIN: begin
                  cnt_q[req_i.cbuf[BufBits-1:0]]  <= '0;
                  recd_q[req_i.cbuf[BufBits-1:0]] <= 1'b1;
                  seal_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                  ptop_q[req_i.cbuf[BufBits-1:0]] <= '0;
                  cpl_q   <= '{status: APU_CMDREC_OK, count: '0,
                               pdata: '0, rec: '0};
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_APPEND: begin
                  // pay_n == 0 here: payload-carrying appends took the
                  // drain/store path above
                  if (!rec_ok) begin
                    cpl_q   <= '{status: APU_CMDREC_NOT_RECORDING,
                                 count: cnt_cur, pdata: '0, rec: '0};
                  end else if (cnt_cur >= 8'(RecsPerBuf)) begin
                    cpl_q   <= '{status: APU_CMDREC_FULL,
                                 count: cnt_cur, pdata: '0, rec: '0};
                  end else if (pay_ovf) begin
                    cpl_q   <= '{status: APU_CMDREC_PAY_FULL,
                                 count: cnt_cur, pdata: '0, rec: '0};
                  end else begin
                    cnt_q[req_i.cbuf[BufBits-1:0]] <= cnt_cur + 8'h1;
                    cpl_q   <= '{status: APU_CMDREC_OK,
                                 count: cnt_cur + 8'h1, pdata: '0,
                                 rec: '0};
                  end
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_END: begin
                  if (!rec_ok) begin
                    cpl_q <= '{status: APU_CMDREC_NOT_RECORDING,
                               count: cnt_cur, pdata: '0, rec: '0};
                  end else begin
                    recd_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                    seal_q[req_i.cbuf[BufBits-1:0]] <= 1'b1;
                    cpl_q <= '{status: APU_CMDREC_OK,
                               count: cnt_cur, pdata: '0, rec: '0};
                  end
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_RESET: begin
                  cnt_q[req_i.cbuf[BufBits-1:0]]  <= '0;
                  recd_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                  seal_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                  ptop_q[req_i.cbuf[BufBits-1:0]] <= '0;
                  cpl_q   <= '{status: APU_CMDREC_OK, count: '0,
                               pdata: '0, rec: '0};
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_READ: begin
                  if (!seal_ok) begin
                    cpl_q   <= '{status: APU_CMDREC_NOT_SEALED,
                                 count: cnt_cur, pdata: '0, rec: '0};
                    state_q <= StCpl;
                  end else if (req_i.idx >= cnt_cur) begin
                    cpl_q   <= '{status: APU_CMDREC_BAD_IDX,
                                 count: cnt_cur, pdata: '0, rec: '0};
                    state_q <= StCpl;
                  end else begin
                    state_q <= StRdCap;   // read issued combinationally
                  end
                end
                APU_CMDREC_OP_PAYREAD: begin
                  if (!seal_ok) begin
                    cpl_q   <= '{status: APU_CMDREC_NOT_SEALED,
                                 count: cnt_cur, pdata: '0, rec: '0};
                    state_q <= StCpl;
                  end else if (req_i.idx >= 16'(PayWordsPerBuf)) begin
                    cpl_q   <= '{status: APU_CMDREC_BAD_IDX,
                                 count: cnt_cur, pdata: '0, rec: '0};
                    state_q <= StCpl;
                  end else begin
                    state_q <= StPayRd;   // read issued combinationally
                  end
                end
                APU_CMDREC_OP_COUNT: begin
                  cpl_q   <= '{status: APU_CMDREC_OK,
                               count: cnt_cur, pdata: '0, rec: '0};
                  state_q <= StCpl;
                end
                default: begin
                  cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                               pdata: '0, rec: '0};
                  state_q <= StCpl;
                end
              endcase
            end
          end

          StRdCap: begin
            cpl_q   <= '{status: APU_CMDREC_OK,
                         count: cnt_q[req_q.cbuf[BufBits-1:0]],
                         pdata: '0,
                         rec: apu_cmdrec_rec_t'(ara_rdata)};
            state_q <= StCpl;
          end

          StPayRd: begin
            cpl_q   <= '{status: APU_CMDREC_OK,
                         count: cnt_q[req_q.cbuf[BufBits-1:0]],
                         pdata: pay_rdata, rec: '0};
            state_q <= StCpl;
          end

          // one payload word per handshake
          StPay: if (pay_valid_i) begin
            pptr_q <= pptr_q + 1'b1;
            prem_q <= prem_q - 16'd1;
            if (prem_q == 16'd1)
              state_q <= StCpl;
          end

          StCpl: if (cpl_ready_i) state_q <= StIdle;

          default: state_q <= StIdle;
        endcase
      end
    end
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_cmdrec_fixture
  import g6lc_apu_cmdrec_pkg::*;
#(parameter bit Enable = 1'b0,
  parameter int unsigned NumBufs = 16,
  parameter int unsigned RecsPerBuf = 64,
  parameter int unsigned PayWordsPerBuf = 256) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_cmdrec_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_cmdrec_cpl_t cpl_o,
  input  logic            pay_valid_i,
  input  logic [31:0]     pay_data_i,
  output logic            pay_ready_o
);
  g6lc_apu_cmdrec #(.Enable(Enable), .NumBufs(NumBufs),
                    .RecsPerBuf(RecsPerBuf),
                    .PayWordsPerBuf(PayWordsPerBuf)) i_dut (.*);
endmodule
