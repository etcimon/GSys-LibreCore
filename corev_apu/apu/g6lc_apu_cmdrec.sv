// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Command recorder (§6 of architecture/uncore/apu-vulkan-engine.md):
// one tc_sram arena of NumBufs x RecsPerBuf fixed 16-word records,
// each a resolved vkCmd* decode (apu_cmdrec_rec_t).  Records are
// appended while a buffer is RECORDING, sealed by END, and read back
// by the submit-time executor.  Per-buffer {count, recording, sealed}
// lives in flops; the arena is the only SRAM (retained by synthesis).
//
// Ops (ready/valid request, one completion):
//   BEGIN  (buf)      : start recording; clears count/sealed
//   APPEND (buf, rec) : store at count, count++; FULL at RecsPerBuf
//   END    (buf)      : seal the buffer (recording -> 0, sealed -> 1)
//   RESET  (buf)      : drop all state (count=0, unrecord, unseal)
//   READ   (buf, idx) : return rec; needs sealed, idx < count
//   COUNT  (buf)      : return current fill
// Statuses: OK, FULL, NOT_RECORDING, NOT_SEALED, BAD_IDX, BAD_BUF.
//
// Timing impact: one SRAM word access per op (write for APPEND in the
// accept cycle; read for READ with a capture cycle); per-buffer state
// is three flops.  The widest cone is the 512-bit record mux into
// wdata; there is no combinational request path.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; Enable=0 elaborates no datapath; req/cpl are the objtab
// ready/valid shape.

module g6lc_apu_cmdrec
  import g6lc_apu_cmdrec_pkg::*;
#(
  parameter bit          Enable     = 1'b0,
  parameter int unsigned NumBufs    = 16,
  parameter int unsigned RecsPerBuf = 64
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_cmdrec_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_cmdrec_cpl_t cpl_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o       = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i |
                    cpl_ready_i | (|req_i);
  end else begin : gen_on
    localparam int unsigned BufBits = $clog2(NumBufs);
    localparam int unsigned RecBits = $clog2(RecsPerBuf);
    localparam int unsigned Words   = NumBufs * RecsPerBuf;
    localparam int unsigned AdrBits = $clog2(Words);
    localparam int unsigned RecW    = $bits(apu_cmdrec_rec_t);

    typedef enum logic [1:0] { StIdle, StRdCap, StCpl } state_e;
    state_e           state_q;
    apu_cmdrec_req_t  req_q;
    apu_cmdrec_cpl_t  cpl_q;

    logic [7:0] cnt_q  [NumBufs];
    logic       recd_q [NumBufs];
    logic       seal_q [NumBufs];

    logic buf_ok, rec_ok, seal_ok;
    assign buf_ok  = req_i.cbuf < 8'(NumBufs);
    assign rec_ok  = recd_q[req_i.cbuf[BufBits-1:0]];
    assign seal_ok = seal_q[req_i.cbuf[BufBits-1:0]];
    logic [7:0] cnt_cur;
    assign cnt_cur = cnt_q[req_i.cbuf[BufBits-1:0]];

    // ---- arena SRAM -------------------------------------------------
    logic                  ara_req, ara_we;
    logic [AdrBits-1:0]    ara_addr;
    logic [RecW-1:0]       ara_wdata, ara_rdata;
    logic [RecBits-1:0]    ara_idx;
    assign ara_idx  = req_i.op == APU_CMDREC_OP_APPEND
                      ? RecBits'(cnt_cur) : RecBits'(req_i.idx);
    assign ara_addr = AdrBits'(req_i.cbuf[BufBits-1:0] * RecsPerBuf) +
                      AdrBits'(ara_idx);
    tc_sram #(.NumWords(Words), .DataWidth(RecW), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_arena (
      .clk_i, .rst_ni, .req_i(ara_req), .we_i(ara_we),
      .addr_i(ara_addr), .wdata_i(ara_wdata), .be_i('1),
      .rdata_o(ara_rdata)
    );

    assign req_ready_o = state_q == StIdle;
    assign cpl_valid_o = state_q == StCpl;
    assign cpl_o       = cpl_q;

    always_comb begin
      ara_req   = 1'b0;
      ara_we    = 1'b0;
      ara_wdata = '0;
      if (state_q == StIdle && req_valid_i && buf_ok) begin
        if (req_i.op == APU_CMDREC_OP_APPEND && rec_ok &&
            cnt_cur < 8'(RecsPerBuf)) begin
          ara_req   = 1'b1;
          ara_we    = 1'b1;
          ara_wdata = RecW'(req_i.rec);
        end else if (req_i.op == APU_CMDREC_OP_READ && seal_ok &&
                     req_i.idx < cnt_cur) begin
          ara_req = 1'b1;
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        req_q   <= '0;
        cpl_q   <= '0;
        for (int i = 0; i < NumBufs; i++) begin
          cnt_q[i]  <= '0;
          recd_q[i] <= 1'b0;
          seal_q[i] <= 1'b0;
        end
      end else begin
        case (state_q)
          StIdle: if (req_valid_i) begin
            req_q <= req_i;
            if (!buf_ok) begin
              cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                           rec: '0};
              state_q <= StCpl;
            end else begin
              case (req_i.op)
                APU_CMDREC_OP_BEGIN: begin
                  cnt_q[req_i.cbuf[BufBits-1:0]]  <= '0;
                  recd_q[req_i.cbuf[BufBits-1:0]] <= 1'b1;
                  seal_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                  cpl_q   <= '{status: APU_CMDREC_OK, count: '0,
                               rec: '0};
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_APPEND: begin
                  if (!rec_ok) begin
                    cpl_q   <= '{status: APU_CMDREC_NOT_RECORDING,
                                 count: cnt_cur, rec: '0};
                  end else if (cnt_cur >= 8'(RecsPerBuf)) begin
                    cpl_q   <= '{status: APU_CMDREC_FULL,
                                 count: cnt_cur, rec: '0};
                  end else begin
                    cnt_q[req_i.cbuf[BufBits-1:0]] <= cnt_cur + 8'h1;
                    cpl_q   <= '{status: APU_CMDREC_OK,
                                 count: cnt_cur + 8'h1, rec: '0};
                  end
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_END: begin
                  if (!rec_ok) begin
                    cpl_q <= '{status: APU_CMDREC_NOT_RECORDING,
                               count: cnt_cur, rec: '0};
                  end else begin
                    recd_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                    seal_q[req_i.cbuf[BufBits-1:0]] <= 1'b1;
                    cpl_q <= '{status: APU_CMDREC_OK,
                               count: cnt_cur, rec: '0};
                  end
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_RESET: begin
                  cnt_q[req_i.cbuf[BufBits-1:0]]  <= '0;
                  recd_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                  seal_q[req_i.cbuf[BufBits-1:0]] <= 1'b0;
                  cpl_q   <= '{status: APU_CMDREC_OK, count: '0,
                               rec: '0};
                  state_q <= StCpl;
                end
                APU_CMDREC_OP_READ: begin
                  if (!seal_ok) begin
                    cpl_q   <= '{status: APU_CMDREC_NOT_SEALED,
                                 count: cnt_cur, rec: '0};
                    state_q <= StCpl;
                  end else if (req_i.idx >= cnt_cur) begin
                    cpl_q   <= '{status: APU_CMDREC_BAD_IDX,
                                 count: cnt_cur, rec: '0};
                    state_q <= StCpl;
                  end else begin
                    state_q <= StRdCap;   // read issued combinationally
                  end
                end
                APU_CMDREC_OP_COUNT: begin
                  cpl_q   <= '{status: APU_CMDREC_OK,
                               count: cnt_cur, rec: '0};
                  state_q <= StCpl;
                end
                default: begin
                  cpl_q   <= '{status: APU_CMDREC_BAD_BUF, count: '0,
                               rec: '0};
                  state_q <= StCpl;
                end
              endcase
            end
          end

          StRdCap: begin
            cpl_q   <= '{status: APU_CMDREC_OK,
                         count: cnt_q[req_q.cbuf[BufBits-1:0]],
                         rec: apu_cmdrec_rec_t'(ara_rdata)};
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
  parameter int unsigned RecsPerBuf = 64) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_cmdrec_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_cmdrec_cpl_t cpl_o
);
  g6lc_apu_cmdrec #(.Enable(Enable), .NumBufs(NumBufs),
                    .RecsPerBuf(RecsPerBuf)) i_dut (.*);
endmodule
