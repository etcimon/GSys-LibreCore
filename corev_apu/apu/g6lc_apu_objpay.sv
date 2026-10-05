// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Object-payload store (§7b): a word-addressed payload arena behind a
// first-fit chunk allocator.  Object kinds that carry generated decode
// payloads (descriptor-set layouts, pipeline layouts, descriptor sets,
// pipelines) rent an extent here; the {base,words} pair is parked in the
// object's ObjTab aux and read back by the front-end / executor.
//
//   ALLOC(words) -> {OK, base}        first-fit run of ceil(words/
//                                    ChunkWords) chunks, marked busy
//                 -> {FULL, 0}        no run fits
//   FREE(base,words) -> OK           clears the same chunk run
//                 -> BOUNDS          unaligned base or run past the end
//   WRITE(addr,word) -> OK/BOUNDS    one word
//   READ(addr) -> {OK,rdata}/BOUNDS  one word, one-cycle read
//
// The allocation bitmap is flops (NumChunks bits, NumChunks =
// PayWords/ChunkWords); the payload arena itself is one tc_sram.
// Requests and completions use the ObjTab ready/valid pattern: a
// request is taken only in StIdle, every request produces exactly one
// completion held until cpl_ready_i.  The first-fit scan walks one
// chunk bit per cycle, so ALLOC is O(NumChunks) worst case - allocator
// latency is dominated by the front-end's per-command sequencing anyway
// (stability over throughput for 5a-i).
//
// Timing impact: the widest cones are the variable shift that builds the
// mark mask and the NumChunks-wide free-bit probe; both are single-cycle
// and isolated in their own states.  ALLOC scan cost NumChunks cycles
// worst case (256 at the default geometry).
//
// Review checklist: async active-low reset; no latches; single always_ff
// plus combinational SRAM-request steering; Enable=0 elaborates no
// datapath; one completion per request.

module g6lc_apu_objpay
  import g6lc_apu_objpay_pkg::*;
#(
  parameter bit          Enable     = 1'b0,
  parameter int unsigned PayWords   = 16384,
  parameter int unsigned ChunkWords = 64
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             testmode_i,
  input  logic             req_valid_i,
  output logic             req_ready_o,
  input  apu_objpay_req_t  req_i,
  output logic             cpl_valid_o,
  input  logic             cpl_ready_i,
  output apu_objpay_cpl_t  cpl_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o       = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i |
                    cpl_ready_i | (|req_i);
  end else begin : gen_on
    localparam int unsigned NumChunks = PayWords / ChunkWords;
    localparam int unsigned ChunkBits = $clog2(NumChunks);
    localparam int unsigned PayBits   = $clog2(PayWords);
    // num chunks covering `words` words
    function automatic logic [31:0] chunks_of(input logic [31:0] words);
      return (words + ChunkWords - 1) / ChunkWords;
    endfunction

    typedef enum logic [2:0] { StIdle, StScan, StRdW, StCpl } state_e;

    state_e            state_q;
    apu_objpay_req_t   req_q;
    apu_objpay_cpl_t   cpl_q;
    logic [NumChunks-1:0] free_q;
    logic [ChunkBits-1:0] scan_q;    // probe index
    logic [31:0]          nch_q;     // chunks needed by in-flight op
    logic [ChunkBits:0]   run_q;     // current free-run length
    logic [ChunkBits-1:0] run_s_q;   // current free-run start

    // ---- payload SRAM ---------------------------------------------------
    logic                pay_req, pay_we;
    logic [PayBits-1:0]  pay_addr;
    logic [31:0]         pay_rdata;

    tc_sram #(.NumWords(PayWords), .DataWidth(32), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_pay (
      .clk_i, .rst_ni, .req_i(pay_req), .we_i(pay_we),
      // req_i (not req_q): the request is written/read in its accept cycle
      .addr_i(pay_addr), .wdata_i(req_i.wdata), .be_i('1),
      .rdata_o(pay_rdata)
    );

    always_comb begin
      pay_req  = 1'b0; pay_we = 1'b0; pay_addr = '0;
      unique case (state_q)
        StIdle: if (req_valid_i && req_i.op inside {APU_OBJPAY_OP_WRITE,
                                                    APU_OBJPAY_OP_READ} &&
                    req_i.addr < PayWords) begin
          pay_req  = 1'b1;
          pay_we   = req_i.op == APU_OBJPAY_OP_WRITE;
          pay_addr = req_i.addr[PayBits-1:0];
        end
        default: ;
      endcase
    end

    assign req_ready_o = state_q == StIdle;
    assign cpl_valid_o = state_q == StCpl;
    assign cpl_o       = cpl_q;

    // mark mask for a run of n chunks starting at chunk s
    function automatic logic [NumChunks-1:0] run_mask(
        input logic [31:0] n, input logic [31:0] s);
      logic [NumChunks-1:0] m;
      m = '0;
      for (int i = 0; i < NumChunks; i++)
        if (i >= s && i < s + n)
          m[i] = 1'b1;
      return m;
    endfunction

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle; req_q <= '0; cpl_q <= '0;
        free_q <= '0; scan_q <= '0; nch_q <= '0;
        run_q <= '0; run_s_q <= '0;
      end else begin
        unique case (state_q)
        // ---------------- request accept / dispatch ----------------
        StIdle: if (req_valid_i) begin
          req_q <= req_i;
          unique case (req_i.op)
            APU_OBJPAY_OP_ALLOC: begin
              if (req_i.words == 32'h0) begin
                cpl_q   <= '{status: APU_OBJPAY_OK, base: '0, rdata: '0};
                state_q <= StCpl;
              end else if (chunks_of(req_i.words) > NumChunks) begin
                cpl_q   <= '{status: APU_OBJPAY_FULL, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end else begin
                nch_q   <= chunks_of(req_i.words);
                scan_q  <= '0;
                run_q   <= '0;
                run_s_q <= '0;
                state_q <= StScan;
              end
            end
            APU_OBJPAY_OP_FREE: begin
              if (req_i.words != 32'h0 &&
                  (req_i.addr % ChunkWords != 32'h0 ||
                   64'(req_i.addr) +
                     64'(chunks_of(req_i.words)) * ChunkWords >
                     64'(PayWords))) begin
                cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                             rdata: '0};
              end else begin
                if (req_i.words != 32'h0)
                  free_q <= free_q & ~run_mask(chunks_of(req_i.words),
                                               req_i.addr / ChunkWords);
                cpl_q   <= '{status: APU_OBJPAY_OK, base: '0, rdata: '0};
              end
              state_q <= StCpl;
            end
            APU_OBJPAY_OP_WRITE: begin
              cpl_q   <= '{status: req_i.addr < PayWords
                                   ? APU_OBJPAY_OK : APU_OBJPAY_BOUNDS,
                           base: '0, rdata: '0};
              state_q <= StCpl;
            end
            default: begin // APU_OBJPAY_OP_READ
              if (req_i.addr < PayWords) begin
                state_q <= StRdW;
              end else begin
                cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end
            end
          endcase
        end

        // ---------------- first-fit scan (1 chunk/cycle) -------------
        StScan: begin
          if (!free_q[scan_q]) begin
            if (run_q == '0)
              run_s_q <= scan_q;
            run_q <= run_q + 1'b1;
            if (64'(run_q) + 1 == 64'(nch_q)) begin
              // run [found_start, found_start+nch) is free: mark it
              free_q <= free_q |
                        run_mask(nch_q, run_q == '0 ? 32'(scan_q)
                                                    : 32'(run_s_q));
              cpl_q  <= '{status: APU_OBJPAY_OK,
                          base: (run_q == '0 ? 32'(scan_q) : 32'(run_s_q))
                                 * ChunkWords,
                          rdata: '0};
              state_q <= StCpl;
            end else if (scan_q == NumChunks - 1) begin
              cpl_q   <= '{status: APU_OBJPAY_FULL, base: '0, rdata: '0};
              state_q <= StCpl;
            end else begin
              scan_q <= scan_q + 1'b1;
            end
          end else begin
            run_q <= '0;
            if (scan_q == NumChunks - 1) begin
              cpl_q   <= '{status: APU_OBJPAY_FULL, base: '0, rdata: '0};
              state_q <= StCpl;
            end else begin
              scan_q <= scan_q + 1'b1;
            end
          end
        end

        // ---------------- SRAM read return ---------------------------
        StRdW: begin
          cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                       rdata: pay_rdata};
          state_q <= StCpl;
        end

        // ---------------- completion ---------------------------------
        StCpl: if (cpl_ready_i)
          state_q <= StIdle;

        default: state_q <= StIdle;
        endcase
      end
    end

`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o);
`endif
  end
endmodule

// enable-0 / small-geometry fixture for the synthesis screens
module g6lc_apu_objpay_fixture
  import g6lc_apu_objpay_pkg::*;
#(parameter bit          Enable     = 1'b0,
  parameter int unsigned PayWords   = 16384,
  parameter int unsigned ChunkWords = 64) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_objpay_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_objpay_cpl_t cpl_o
);
  g6lc_apu_objpay #(.Enable(Enable), .PayWords(PayWords),
                    .ChunkWords(ChunkWords)) i_dut (.*);
endmodule
