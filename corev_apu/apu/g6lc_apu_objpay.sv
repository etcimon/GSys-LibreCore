// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Object-payload store (§5a G3b-i "ObjPay-V"): a word-addressed
// payload arena behind a next-fit chunk allocator.  Object kinds that
// carry generated decode payloads (descriptor-set layouts, pipeline
// layouts, descriptor sets, pipelines) rent an extent here; the
// {base>>6, words} pair is parked in the object's ObjTab
// aux[63:32] and read back by the front-end / executor.
//
//   ALLOC(words) -> {OK, base}       next-fit run of ceil(words/
//                                   ChunkWords) chunks, marked busy;
//                                   base is a word address
//                -> {FULL, 0}        no run fits
//                -> {BOUNDS,0}       words > 65535 (parked field is
//                                    16 bits)
//   FREE(base,words) -> OK          clears the same chunk run
//                -> BOUNDS           unaligned base or run past the end
//   WRITE(addr,word) -> OK/BOUNDS   one word; BOUNDS when addr is
//                                   outside PayMem OR inside an
//                                   unallocated chunk
//   READ(addr) -> {OK,rdata}/BOUNDS one word; same extent check
//   READN(addr,n) -> {OK,rdata}*n   1<=n<=16, one 16-word-aligned
//                                   line; one completion per word,
//                                   req_ready low until the last beat
//
// §5a storage decisions:
//   - the allocation bitmap is a tc_sram of NumChunks/64 64-bit words
//     (on-chip metadata — it is metadata, not payload, so it does not
//     live in objmem); zeroed by an init sweep after reset since a
//     real SRAM has no reset
//   - the payload arena is the objmem PAY region (private DRAM)
//     reached through g6lc_apu_objmem's write-back pay cache; this
//     module issues one 64-B OMP_LINE op per cache line
//   - a one-line write-merge buffer (wbuf) coalesces the front-end's
//     sequential word writes so a filled cache line costs at most one
//     line read (partial merge) + one line write instead of two
//     objmem round-trips per word
//   - ALLOC scans one 64-bit bitmap word per cycle with a next-fit
//     cursor; a run may span words via a carried run length
//
// Requests and completions keep the ObjTab ready/valid pattern: a
// request is taken only in StIdle, every request produces exactly one
// completion held until cpl_ready_i.
//
// Timing impact: the widest cone is the 64-way shifted-AND that
// detects an in-word run of nch free chunks (~4k gates, single
// cycle); the bitmap RMW and the scan are one word per cycle by
// design.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; bitmap via tc_sram; Enable=0 elaborates no datapath;
// one completion per request.

module g6lc_apu_objpay
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_objtab_pkg::apu_omp_req_t;
  import g6lc_apu_objtab_pkg::apu_omp_rsp_t;
#(
  parameter bit          Enable      = 1'b0,
  parameter int unsigned PayMemBytes = 16 * 1024 * 1024
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             testmode_i,
  input  logic             req_valid_i,
  output logic             req_ready_o,
  input  apu_objpay_req_t  req_i,
  output logic             cpl_valid_o,
  input  logic             cpl_ready_i,
  output apu_objpay_cpl_t  cpl_o,
  // objmem payload port
  output logic             omp_req_valid_o,
  input  logic             omp_req_ready_i,
  output apu_omp_req_t     omp_req_o,
  input  logic             omp_rsp_valid_i,
  input  apu_omp_rsp_t     omp_rsp_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o     = 1'b0;
    assign cpl_valid_o     = 1'b0;
    assign cpl_o           = '0;
    assign omp_req_valid_o = 1'b0;
    assign omp_req_o       = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i |
                    cpl_ready_i | omp_req_ready_i |
                    omp_rsp_valid_i | (|req_i) | (|omp_rsp_i);
  end else begin : gen_on
    localparam int unsigned PayWords   = PayMemBytes / 4;
    localparam int unsigned ChunkWords = APU_OBJPAY_CHUNK_WORDS; // 64
    localparam int unsigned NumChunks  = PayWords / ChunkWords;
    localparam int unsigned BmpWords   = (NumChunks + 63) / 64;
    localparam int unsigned BmpBits    = BmpWords > 1
                                         ? $clog2(BmpWords) : 1;
    // chunks past NumChunks in the tail word stay marked so a scan
    // can never hand out an out-of-arena extent
    localparam logic [63:0] TailFill   = NumChunks % 64 == 0
                                         ? 64'h0
                                         : ~64'h0 << (NumChunks % 64);

    // num chunks covering `words` words
    function automatic logic [31:0] chunks_of(input logic [31:0] words);
      return (words + ChunkWords - 1) / ChunkWords;
    endfunction

    typedef enum logic [4:0] {
      StInit, StIdle,
      StOmReq, StOmWait,
      StBmpRd, StBmpCap,
      StMarkRd, StMarkWr,
      StChkRd, StChkCap,
      StWStart, StWMrg, StWFlush, StWFlushM, StWFlushW,
      StWCap,
      StNCap, StNBeat,
      StCpl
    } state_e;

    state_e            state_q, om_ret_q;
    apu_objpay_req_t   req_q;
    apu_objpay_cpl_t   cpl_q;
    // bitmap scan state
    logic [BmpBits-1:0] cursor_q;    // next-fit cursor (word index)
    logic [BmpBits-1:0] scan_q;      // current probe word
    logic [BmpBits:0]   wrap_q;      // words scanned this ALLOC
    logic [63:0]        bits_q;      // captured bitmap word
    logic [31:0]        nch_q;       // chunks needed
    logic [31:0]        run_q;       // carried free-run length
    logic [31:0]        run_s_q;     // carried run start (chunk idx)
    logic [31:0]        mark_a_q;    // mark range [a,b) in chunks
    logic [31:0]        mark_b_q;
    logic               mark_set_q;  // 1 = allocate, 0 = free
    logic [BmpBits-1:0] mark_w_q;    // current mark word
    logic [31:0]        used_q;      // allocated chunks (observability)
    // one-line write-merge buffer
    logic               wb_v_q;
    logic [31:0]        wb_line_q;
    logic [511:0]       wb_data_q;
    logic [15:0]        wb_bm_q;
    // READN burst state: words remaining, beat index, in-line offset
    logic [4:0]         nb_n_q;
    logic [4:0]         nb_i_q;
    logic [3:0]         nb_off_q;

    // ---- bitmap SRAM ------------------------------------------------------
    logic                bmp_req, bmp_we;
    logic [BmpBits-1:0]  bmp_addr;
    logic [63:0]         bmp_wdata, bmp_rdata;

    tc_sram #(.NumWords(BmpWords), .DataWidth(64), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_bmp (
      .clk_i, .rst_ni, .req_i(bmp_req), .we_i(bmp_we),
      .addr_i(bmp_addr), .wdata_i(bmp_wdata), .be_i('1),
      .rdata_o(bmp_rdata)
    );

    always_comb begin
      bmp_req   = 1'b0; bmp_we = 1'b0;
      bmp_addr  = '0;   bmp_wdata = '0;
      unique case (state_q)
        StInit:   begin bmp_req = 1'b1; bmp_we = 1'b1;
                        bmp_addr = scan_q[BmpBits-1:0];
                        // §5a G3b-iii: chunk 0 stays marked — 0 is the
                        // "none" sentinel for extent parkings (command-
                        // buffer descriptor aux[63:32], pool chain
                        // head, descriptor-pool free list), so no real
                        // allocation may begin at word 0
                        bmp_wdata = (scan_q == '0)
                                    ? 64'h1
                                    : (scan_q == BmpBits'(BmpWords - 1))
                                      ? TailFill : 64'h0; end
        StBmpRd:  begin bmp_req = 1'b1;
                        bmp_addr = scan_q; end
        StChkRd:  begin bmp_req = 1'b1;
                        bmp_addr = BmpBits'(req_q.addr[31:12]); end
        StMarkRd: begin bmp_req = 1'b1;
                        bmp_addr = mark_w_q; end
        // the word read in StMarkRd returns THIS cycle (bmp_rdata) —
        // write the merged value back to the same word
        StMarkWr: begin bmp_req = 1'b1; bmp_we = 1'b1;
                        bmp_addr = mark_w_q;
                        bmp_wdata = mark_set_q
                            ? bmp_rdata | mark_word_mask(mark_a_q,
                                                         mark_b_q,
                                                         mark_w_q)
                            : bmp_rdata & ~mark_word_mask(mark_a_q,
                                                        mark_b_q,
                                                        mark_w_q); end
        default: ;
      endcase
    end

    // mask of chunk bits [a,b) inside bitmap word w
    function automatic logic [63:0] mark_word_mask(
        input logic [31:0] a, input logic [31:0] b,
        input logic [BmpBits-1:0] w);
      logic [63:0] m;
      logic [31:0] lo, hi;
      m = '0;
      lo = a > (32'(w) << 6) ? a - (32'(w) << 6) : 32'h0;
      hi = b > (32'(w) << 6)
           ? ((b - (32'(w) << 6)) > 64 ? 64 : b - (32'(w) << 6))
           : 0;
      for (int i = 0; i < 64; i++)
        if (32'(i) >= lo && 32'(i) < hi) m[i] = 1'b1;
      return m;
    endfunction

    // count of leading (LSB-side) free bits in a bitmap word
    function automatic logic [6:0] lsb_free(input logic [63:0] b);
      logic [6:0] n;
      n = 7'd64;
      for (int i = 0; i < 64; i++)
        if (b[i] && n == 7'd64) n = 7'(i);
      return n;
    endfunction

    // index of the highest set bit (MSB side)
    function automatic logic [5:0] top_set(input logic [63:0] b);
      logic [5:0] n;
      n = 6'd0;
      for (int i = 0; i < 64; i++)
        if (b[i]) n = 6'(i);
      return n;
    endfunction

    // first chunk index (0..63, word-relative) of a free run of
    // length >= n wholly inside `free` (free = ~bitmap word);
    // returns 64 when absent
    function automatic logic [6:0] run_in_word(
        input logic [63:0] free, input logic [31:0] n);
      logic [63:0] m;
      logic [6:0]  idx;
      m = free;
      // m[i] set => bits i..i+n-1 all free (n <= 64 callers only)
      for (int i = 1; i < 64; i++)
        if (32'(i) < n) m = m & (free >> i);
      idx = 7'd64;
      for (int i = 0; i < 64; i++)
        if (m[i] && idx == 7'd64) idx = 7'(i);
      return idx;
    endfunction

    // ---- objmem request plumbing ------------------------------------------
    logic         om_we_q;
    logic [25:0]  om_line_q;
    logic [511:0] om_wdata_q;
    logic [511:0] om_rdata_q;

    assign omp_req_valid_o = state_q == StOmReq;
    assign req_ready_o     = state_q == StIdle;
    assign cpl_valid_o     = state_q == StCpl || state_q == StNBeat;
    assign cpl_o           = cpl_q;

    // READN beat word: in-line index of beat nb_i_q
    function automatic logic [31:0] nbeat_word(
        input logic [511:0] line, input logic [3:0] off,
        input logic [4:0] i);
      return line[(4'(off) + 4'(i)) * 32 +: 32];
    endfunction

    // in-line word mask of the accepted READN burst [off, off+words)
    // — the legality check guarantees off+words <= 16; keep the
    // arithmetic 32-bit so words==16 doesn't wrap a 4-bit shift
    logic [15:0] nb_mask;
    always_comb begin
      nb_mask = 16'( (32'hFFFF << req_q.addr[3:0]) &
                     ~(32'hFFFF << (32'(req_q.addr[3:0]) +
                                    req_q.words)) );
    end

    assign omp_req_o = '{dir: 1'b1,
                        line_addr: om_line_q,
                        we: om_we_q,
                        wdata: om_wdata_q};

    task automatic omp_call(input logic we, input logic [31:0] line,
                            input logic [511:0] data,
                            input state_e ret);
      om_we_q    <= we;
      om_line_q  <= 26'(line);
      om_wdata_q <= data;
      om_ret_q   <= ret;
      state_q    <= StOmReq;
    endtask

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StInit; om_ret_q <= StIdle;
        req_q <= '0; cpl_q <= '0;
        cursor_q <= '0; scan_q <= '0; wrap_q <= '0;
        bits_q <= '0; nch_q <= '0; run_q <= '0; run_s_q <= '0;
        mark_a_q <= '0; mark_b_q <= '0; mark_set_q <= 1'b0;
        used_q <= '0;
        mark_w_q <= '0;
        wb_v_q <= 1'b0; wb_line_q <= '0; wb_data_q <= '0;
        wb_bm_q <= '0;
        nb_n_q <= '0; nb_i_q <= '0; nb_off_q <= '0;
        om_we_q <= 1'b0; om_line_q <= '0; om_wdata_q <= '0;
        om_rdata_q <= '0;
      end else begin
        unique case (state_q)
        // ---------------- bitmap init sweep ------------------------------
        StInit: begin
          if (scan_q == BmpWords - 1) begin
            scan_q  <= '0;
            state_q <= StIdle;
          end else begin
            scan_q <= scan_q + 1'b1;
          end
        end

        // ---------------- objmem round-trip ------------------------------
        StOmReq:  if (omp_req_ready_i) state_q <= StOmWait;
        StOmWait: if (omp_rsp_valid_i) begin
          om_rdata_q <= omp_rsp_i.rdata;
          state_q    <= om_ret_q;
        end

        // ---------------- request accept ---------------------------------
        StIdle: if (req_valid_i) begin
          req_q <= req_i;
          unique case (req_i.op)
            APU_OBJPAY_OP_ALLOC: begin
              if (req_i.words == 32'h0) begin
                cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end else if (req_i.words > APU_OBJPAY_MAX_WORDS) begin
                cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end else if (chunks_of(req_i.words) > NumChunks) begin
                cpl_q   <= '{status: APU_OBJPAY_FULL, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end else begin
                nch_q   <= chunks_of(req_i.words);
                scan_q  <= cursor_q;
                wrap_q  <= '0;
                run_q   <= '0;
                run_s_q <= '0;
                state_q <= StBmpRd;
              end
            end
            APU_OBJPAY_OP_FREE: begin
              if (req_i.words != 32'h0 &&
                  (req_i.addr % ChunkWords != 32'h0 ||
                   64'(req_i.addr) +
                     64'(chunks_of(req_i.words)) * ChunkWords >
                     64'(PayWords) ||
                   req_i.words > APU_OBJPAY_MAX_WORDS)) begin
                cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end else if (req_i.words == 32'h0) begin
                cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end else begin
                mark_a_q   <= req_i.addr / ChunkWords;
                mark_b_q   <= req_i.addr / ChunkWords +
                              chunks_of(req_i.words);
                mark_set_q <= 1'b0;
                mark_w_q   <= BmpBits'(req_i.addr /
                                       (ChunkWords * 64));
                // flush the merge buffer first so no stale data
                // survives the free
                state_q <= wb_v_q ? StWFlush : StMarkRd;
              end
            end
            APU_OBJPAY_OP_WRITE, APU_OBJPAY_OP_READ,
            APU_OBJPAY_OP_READN: begin
              if (req_i.addr >= PayWords) begin
                cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                             rdata: '0};
                state_q <= StCpl;
              end else begin
                state_q <= StChkRd;
              end
            end
            default: begin
              cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                           rdata: '0};
              state_q <= StCpl;
            end
          endcase
        end

        // ---------------- next-fit scan (1 word/cycle) -------------------
        StBmpRd:  state_q <= StBmpCap;
        StBmpCap: begin
          bits_q <= bmp_rdata;
          // free-run accounting across the captured word
          if (run_q + 32'(lsb_free(bmp_rdata)) >= nch_q) begin
            // the carried run plus this word's free prefix fits
            mark_a_q <= run_q != 32'h0 ? run_s_q
                                       : 32'(scan_q) << 6;
            mark_b_q <= (run_q != 32'h0 ? run_s_q
                                        : 32'(scan_q) << 6) + nch_q;
            mark_set_q <= 1'b1;
            mark_w_q   <= BmpBits'((run_q != 32'h0
                                    ? run_s_q
                                    : 32'(scan_q) << 6) >> 6);
            state_q    <= StMarkRd;
          end else if (nch_q <= 32'd64 &&
                       run_in_word(~bmp_rdata, nch_q) != 7'd64) begin
            // a run entirely inside this word
            mark_a_q <= (32'(scan_q) << 6) +
                        32'(run_in_word(~bmp_rdata, nch_q));
            mark_b_q <= (32'(scan_q) << 6) +
                        32'(run_in_word(~bmp_rdata, nch_q)) + nch_q;
            mark_set_q <= 1'b1;
            mark_w_q   <= scan_q;
            state_q    <= StMarkRd;
          end else if (wrap_q == BmpWords - 1) begin
            cpl_q   <= '{status: APU_OBJPAY_FULL, base: '0,
                         rdata: '0};
            state_q <= StCpl;
          end else begin
            // carry: whole word free extends the run, otherwise a
            // fresh run starts after the last allocated bit; a run
            // may NOT span the bitmap wrap (extents are contiguous)
            if (bmp_rdata == 64'h0) begin
              run_q   <= run_q + 32'd64;
              if (run_q == 32'h0)
                run_s_q <= 32'(scan_q) << 6;
            end else begin
              run_q   <= 32'(63 - top_set(bmp_rdata));
              run_s_q <= (32'(scan_q) << 6) +
                         32'(top_set(bmp_rdata)) + 32'h1;
            end
            wrap_q <= wrap_q + 1'b1;
            if (scan_q == BmpWords - 1) begin
              scan_q  <= '0;
              run_q   <= '0;
              run_s_q <= '0;
            end else begin
              scan_q <= scan_q + 1'b1;
            end
            state_q <= StBmpRd;
          end
        end

        // ---------------- bitmap RMW ------------------------------------
        StMarkRd: state_q <= StMarkWr;
        StMarkWr: begin
          if (mark_w_q == BmpBits'((mark_b_q - 1) >> 6)) begin
            // last word in range: the combinational write above has
            // already been accepted this cycle
            if (mark_set_q)
              cursor_q <= BmpBits'((mark_b_q >> 6) % BmpWords);
            used_q   <= mark_set_q ? used_q + (mark_b_q - mark_a_q)
                                   : used_q - (mark_b_q - mark_a_q);
            cpl_q    <= '{status: APU_OBJPAY_OK,
                          base: mark_set_q
                                ? mark_a_q * ChunkWords : '0,
                          rdata: '0};
            state_q  <= StCpl;
          end else begin
            mark_w_q <= mark_w_q + 1'b1;
            state_q  <= StMarkRd;
          end
        end

        // ---------------- WRITE/READ extent check ------------------------
        StChkRd:  state_q <= StChkCap;
        StChkCap: begin
          if (!bmp_rdata[req_q.addr[11:6]]) begin
            // chunk not allocated: past-every-extent is BOUNDS
            cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                         rdata: '0};
            state_q <= StCpl;
          end else if (req_q.op == APU_OBJPAY_OP_WRITE) begin
            if (wb_v_q && wb_line_q == (req_q.addr >> 4)) begin
              // merge hit: no objmem traffic at all
              wb_data_q[req_q.addr[3:0] * 32 +: 32] <= req_q.wdata;
              wb_bm_q[req_q.addr[3:0]] <= 1'b1;
              cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                           rdata: '0};
              state_q <= StCpl;
            end else if (wb_v_q) begin
              state_q <= StWFlush;
            end else begin
              state_q <= StWStart;
            end
          end else if (req_q.op == APU_OBJPAY_OP_READN) begin
            // READN: burst of `words` words inside one 16-word line.
            // Illegal bursts answer one BOUNDS completion.
            if (req_q.words == 32'h0 || req_q.words > 32'd16 ||
                32'(req_q.addr[3:0]) + req_q.words > 32'd16) begin
              cpl_q   <= '{status: APU_OBJPAY_BOUNDS, base: '0,
                           rdata: '0};
              state_q <= StCpl;
            end else begin
              nb_n_q   <= 5'(req_q.words);
              nb_i_q   <= '0;
              nb_off_q <= req_q.addr[3:0];
              // every requested word already merged in the one-line
              // write buffer -> no objmem trip at all
              if (wb_v_q && wb_line_q == (req_q.addr >> 4) &&
                  (wb_bm_q & nb_mask) == nb_mask) begin
                cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                             rdata: nbeat_word(wb_data_q,
                                               req_q.addr[3:0], 0)};
                state_q <= StNBeat;
              end else begin
                omp_call(1'b0, req_q.addr >> 4, '0, StNCap);
              end
            end
          end else begin
            // READ: serve straight out of the merge buffer when it
            // holds the word, else go to objmem
            if (wb_v_q && wb_line_q == (req_q.addr >> 4) &&
                wb_bm_q[req_q.addr[3:0]]) begin
              cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                           rdata: wb_data_q[req_q.addr[3:0] * 32
                                            +: 32]};
              state_q <= StCpl;
            end else begin
              omp_call(1'b0, req_q.addr >> 4, '0, StWCap);
            end
          end
        end

        // ---------------- merge-buffer management ------------------------
        StWStart: begin
          wb_v_q    <= 1'b1;
          wb_line_q <= req_q.addr >> 4;
          wb_data_q <= '0;
          wb_bm_q   <= '0;
          state_q   <= StWMrg;
        end
        StWMrg: begin
          wb_data_q[req_q.addr[3:0] * 32 +: 32] <= req_q.wdata;
          wb_bm_q[req_q.addr[3:0]] <= 1'b1;
          cpl_q   <= '{status: APU_OBJPAY_OK, base: '0, rdata: '0};
          state_q <= StCpl;
        end
        StWFlush: begin
          // drain the merge buffer: full lines write directly,
          // partial lines read-merge
          if (wb_bm_q == 16'hFFFF) begin
            wb_v_q <= 1'b0;
            omp_call(1'b1, wb_line_q, wb_data_q, StWFlushW);
          end else begin
            omp_call(1'b0, wb_line_q, '0, StWFlushM);
          end
        end
        StWFlushM: begin
          // overlay buffered words on the fetched line and write back
          logic [511:0] mrg;
          mrg = om_rdata_q;
          for (int i = 0; i < 16; i++)
            if (wb_bm_q[i]) mrg[i * 32 +: 32] = wb_data_q[i * 32 +: 32];
          wb_v_q <= 1'b0;
          omp_call(1'b1, wb_line_q, mrg, StWFlushW);
        end
        StWFlushW: begin
          // resume whatever forced the flush
          if (req_q.op == APU_OBJPAY_OP_FREE) state_q <= StMarkRd;
          else                              state_q <= StWStart;
        end
        StWCap: begin
          cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                       rdata: om_rdata_q[req_q.addr[3:0] * 32
                                         +: 32]};
          state_q <= StCpl;
        end

        // ---------------- READN burst ------------------------------------
        StNCap: begin
          // line fetched; beat 0 goes out next cycle
          cpl_q   <= '{status: APU_OBJPAY_OK, base: '0,
                       rdata: (wb_v_q &&
                               wb_line_q == (req_q.addr >> 4) &&
                               wb_bm_q[nb_off_q])
                              ? nbeat_word(wb_data_q, nb_off_q, 0)
                              : nbeat_word(om_rdata_q, nb_off_q, 0)};
          state_q <= StNBeat;
        end
        StNBeat: if (cpl_ready_i) begin
          if (nb_i_q == nb_n_q - 5'd1) begin
            state_q <= StIdle;
          end else begin
            logic [3:0] wi;
            wi = nb_off_q + 4'(nb_i_q + 5'd1);
            nb_i_q <= nb_i_q + 5'd1;
            cpl_q  <= '{status: APU_OBJPAY_OK, base: '0,
                        rdata: (wb_v_q &&
                                wb_line_q == (req_q.addr >> 4) &&
                                wb_bm_q[wi])
                               ? wb_data_q[wi * 32 +: 32]
                               : om_rdata_q[wi * 32 +: 32]};
          end
        end

        // ---------------- completion -------------------------------------
        StCpl: if (cpl_ready_i) state_q <= StIdle;
        default: state_q <= StIdle;
        endcase
// pragma translate_off
        if ($test$plusargs("optrace") && state_q == StCpl)
          $display("[op t=%0t] op=%0d addr=%08x words=%08x -> st=%0d base=%08x rdata=%08x",
                   $time, req_q.op, req_q.addr, req_q.words,
                   cpl_q.status, cpl_q.base, cpl_q.rdata);
// pragma translate_on
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
  import g6lc_apu_objtab_pkg::apu_omp_req_t;
  import g6lc_apu_objtab_pkg::apu_omp_rsp_t;
#(parameter bit          Enable      = 1'b0,
  parameter int unsigned PayMemBytes = 64 * 1024) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             testmode_i,
  input  logic             req_valid_i,
  output logic             req_ready_o,
  input  apu_objpay_req_t  req_i,
  output logic             cpl_valid_o,
  input  logic             cpl_ready_i,
  output apu_objpay_cpl_t  cpl_o,
  output logic             omp_req_valid_o,
  input  logic             omp_req_ready_i,
  output apu_omp_req_t     omp_req_o,
  input  logic             omp_rsp_valid_i,
  input  apu_omp_rsp_t     omp_rsp_i
);
  g6lc_apu_objpay #(.Enable(Enable),
                    .PayMemBytes(PayMemBytes)) i_dut (.*);
endmodule
