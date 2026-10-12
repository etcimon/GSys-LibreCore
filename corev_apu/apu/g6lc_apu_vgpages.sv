// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Aperture page allocator (§7b/5a-ii + §12.3 3d-c): first-fit over a
// page bitmap for the blob SHM aperture window.  Factored out of
// g6lc_apu_vgctl so the same page pool backs both virtio-gpu blob
// resources (vgctl) and vkAllocateMemory device memory (vnfront);
// instantiated once in g6lc_apu_vgtop behind a grant arbiter.
//
//   ALLOC(bytes)      -> {OK, base}    first-fit run of ceil(bytes/
//                                      PageBytes) pages, marked busy
//                   -> {FULL, 0}      no run fits
//   ALLOC_HI(bytes,   -> {OK, base}    §12.3 3d-d: same, but top-down
//     excl_lo,excl_hi)                  inside the guest window — the
//                                       highest-address fit — treating
//                                       the exclusion pages as busy
//                   -> {FULL, 0}      no fit outside the exclusion
//   ALLOC_AT(base,bytes) -> {OK,base} caller-chosen extent (kernel
//                                     drm_mm): marks every page the
//                                     byte range covers (4 KiB-class
//                                     alignment allowed)
//                        -> {BUSY,0}   any covered page already busy
//                        -> BOUNDS     run past the window end
//   FREE(base,bytes) -> OK            unmarks every covered page —
//                                     same coverage rule as ALLOC_AT
//                   -> BOUNDS         run past the end (bytes==0 is OK)
//
// `base` is a window-relative byte offset (the aperture itself lives at
// APU_VG_SHM_BASE in the SHM BAR window); callers add the window base.
// Requests and completions use the ObjTab ready/valid pattern: a
// request is taken only in StIdle, every request produces exactly one
// completion held until cpl_ready_i.
//
// §12.3 3d-c storage: the busy bitmap is a tc_sram of Pages/64 x
// 64-bit words (bit p of word w = page 64w+p allocated) plus two flop
// summary bits per word — `full` (no free page) and `empty` (all 64
// free).  First-fit scans one summary word per cycle, skipping full
// words and consuming empty words 64 pages at a time; a mixed word is
// read from SRAM (latency 1) and resolved with CTZ/CLZ plus a
// shift-accumulate first-run mask, with a carry run that preserves
// exact page-granular first-fit across word boundaries (a run may
// enter, complete inside, or leave a word at any offset, so no
// alignment is ever required of an extent).  ALLOC / ALLOC_AT / FREE
// mark one SRAM word per cycle; whole-word extents need no read-
// modify-write, and summary-known or just-scanned edge words reuse
// their content without an extra read.  Worst-case ALLOC latency is
// O(Pages/64) scan cycles plus O(extent/64) mark cycles — 128 + n
// words at the shipped 8192-page (32 MiB) geometry and 1024 + n at
// 256 MiB — versus the flat bitmap's Pages-cycle scan and Pages flops.
//
// The busy-page count `used_q` is kept incrementally at every word
// write and is the TB observability tap (the flat `free_q` vector it
// replaced was only ever consumed through $countones / === '0).
//
// Timing impact: the widest cone is the 64-bit first-run accumulate
// (63 shift-AND terms), one cycle inside StScanW; summary lookups are
// two single-bit selects.  SRAM read latency is absorbed by the
// StScan/StScanW split — a mixed word costs 2 cycles, an empty or
// full word 1.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; Enable=0 elaborates no datapath; bitmap storage behind
// the tc_sram PDK seam; one completion per request.
module g6lc_apu_vgpages
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable    = 1'b0,
  parameter int unsigned Pages     = 256,
  parameter int unsigned PageBytes = 4096,
  // pages below GuestPages form the guest-mappable window the kernel's
  // shm drm_mm places MAP_BLOB extents in; pages [GuestPages, Pages)
  // are the device-private arena reachable only through ALLOC_PRIV.
  // The split must land on a 64-page word boundary (or GuestPages ==
  // Pages for no private arena) and the private arena must cover at
  // least 1 MiB — elaboration assertions enforce both.
  parameter int unsigned GuestPages = Pages
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  input  logic              req_valid_i,
  output logic              req_ready_o,
  input  apu_vgpages_req_t  req_i,
  output logic              cpl_valid_o,
  input  logic              cpl_ready_i,
  output apu_vgpages_cpl_t  cpl_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o       = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i |
                    cpl_ready_i | (|req_i);
  end else begin : gen_on
    localparam int unsigned PageBits   = $clog2(Pages);
    localparam int unsigned Words      = Pages / 64;
    localparam int unsigned WBits      = Words > 1 ? $clog2(Words) : 1;
    localparam int unsigned WinBytes   = Pages * PageBytes;
    localparam int unsigned GuestBytes = GuestPages * PageBytes;
    localparam int unsigned PrivPages  = Pages - GuestPages;
    // word-aligned guest/private split (elaboration-asserted below)
    localparam int unsigned GuestWords = GuestPages / 64;
    // pages covering `bytes` bytes
    function automatic logic [31:0] pages_of(input logic [31:0] bytes);
      return (bytes + PageBytes - 1) / PageBytes;
    endfunction

    // ---- 64-bit busy-word helpers (bit=1 means allocated) ----------
    // index of the lowest busy bit; 64 when the word is all-free
    function automatic logic [6:0] ctz64(input logic [63:0] v);
      for (int i = 0; i < 64; i++)
        if (v[i]) return 7'(i);
      return 7'd64;
    endfunction
    // free bits above the highest busy bit; 64 when all-free
    function automatic logic [6:0] clz64(input logic [63:0] v);
      for (int i = 63; i >= 0; i--)
        if (v[i]) return 7'(63 - i);
      return 7'd64;
    endfunction
    // first word-local window of n free pages: index i with
    // [i, i+n) all clear in `w` (busy=1 view); 64 when none fits.
    // g[i] = AND of free bits f[i .. i+n-1] via shift-accumulate.
    function automatic logic [6:0] first_run(
        input logic [63:0] w, input logic [31:0] n);
      logic [63:0] f, g;
      f = ~w;
      g = f;
      for (int k = 1; k < 64; k++)
        if (k < n) g &= f >> k;
      for (int i = 0; i < 64; i++)
        if (32'(i) + n <= 64 && g[i]) return 7'(i);
      return 7'd64;
    endfunction
    // §12.3 3d-d: highest word-local window for ALLOC_HI — same
    // accumulate as first_run but returning the largest index.
    function automatic logic [6:0] last_run(
        input logic [63:0] w, input logic [31:0] n);
      logic [63:0] f, g;
      f = ~w;
      g = f;
      for (int k = 1; k < 64; k++)
        if (k < n) g &= f >> k;
      for (int i = 63; i >= 0; i--)
        if (32'(i) + n <= 64 && g[i]) return 7'(i);
      return 7'd64;
    endfunction
    // bits of word m covered by the page extent [f0, f1]
    function automatic logic [63:0] ext_mask(
        input logic [WBits-1:0] m,
        input logic [31:0]      f0,
        input logic [31:0]      f1);
      logic [31:0] lo, hi;
      // a word entirely outside the extent contributes nothing —
      // required because the ALLOC_HI exclusion mask applies this to
      // every scanned word, not just words the extent intersects
      if (32'(m) * 64 > f1 || 32'(m) * 64 + 63 < f0) return '0;
      lo = (32'(m) * 64 >= f0) ? 32'h0 : f0 - 32'(m) * 64;
      hi = (32'(m) * 64 + 63 <= f1) ? 32'd63 : f1 - 32'(m) * 64;
      if (lo == 0 && hi == 63) return '1;
      return ((64'h1 << (hi - lo + 1)) - 64'h1) << lo;
    endfunction

    typedef enum logic [3:0] {
      StIdle,   // request accept / dispatch
      StScan,   // ALLOC first-fit: summary consult or read issue
      StScanW,  // process the mixed word read in StScan
      StChk,    // ALLOC_AT conflict check: summary consult or read
      StChkW,   // test the read word against the extent mask
      StMark,   // mark/unmark: write direct or issue a word read
      StMarkW,  // complete a read-modify-write
      StCpl,
      // §12.3 3d-d: ALLOC_HI top-down scan — same two-state shape as
      // StScan/StScanW but descending and exclusion-masked
      StScanH, StScanHW
    } state_e;

    state_e            state_q;
    apu_vgpages_cpl_t  cpl_q;
    // flop summary per SRAM word: full = no free page, empty = all free
    logic [Words-1:0]  full_q, empty_q;
    logic [WBits-1:0]  widx_q;   // scan / check / mark word index
    logic [WBits-1:0]  wend_q;   // last word of the active range
    logic [31:0]       npg_q;    // pages needed by the in-flight ALLOC
    logic              clr_q;    // mark pass clears (FREE) vs sets
    logic [31:0]       run_q;    // open free-run length reaching widx*64
    logic [31:0]       run_s_q;  // open free-run start page
    logic [31:0]       f0_q, f1_q;  // page extent being marked/checked
    logic [31:0]       res_q;    // ALLOC result (byte offset)
    // §12.3 3d-d: ALLOC_HI exclusion in page space ([ep0_q, ep1_q]);
    // ep0_q > ep1_q marks "no exclusion"
    logic [31:0]       ep0_q, ep1_q;
    // last word read from / written to the map (edge-word RMW cache)
    logic [63:0]       word_q;
    logic [WBits-1:0]  word_i_q;
    logic              word_v_q;
    logic [31:0]       used_q;   // busy-page count (TB observability)

    // ---- map SRAM --------------------------------------------------
    logic              map_req, map_we;
    logic [WBits-1:0]  map_addr;
    logic [63:0]       map_wdata, map_rdata;

    // SimInit none: every read is gated by the empty/full summaries or
    // the just-touched cache, so a word is only ever read after a
    // whole-word write — reset state is the summaries, not the array.
    tc_sram #(.NumWords(Words), .DataWidth(64), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_map (
      .clk_i, .rst_ni,
      .req_i(map_req), .we_i(map_we), .addr_i(map_addr),
      .wdata_i(map_wdata), .be_i('1), .rdata_o(map_rdata)
    );

    assign req_ready_o = state_q == StIdle;
    assign cpl_valid_o = state_q == StCpl;
    assign cpl_o       = cpl_q;

    // §12.3 3d-d: exclusion mask over word widx_q for ALLOC_HI —
    // exclusion pages scan as busy, which is exactly "skip every
    // candidate overlapping [excl_lo, excl_hi)" at page granularity.
    wire [63:0] xh_mask = ep0_q <= ep1_q ? ext_mask(widx_q, ep0_q, ep1_q)
                                        : 64'h0;

    // mask the mark pass applies to word widx_q
    wire [63:0] mk_mask = ext_mask(widx_q, f0_q, f1_q);
    // word content known without a read: just-touched cache, or a
    // summary that fixes every bit
    wire        mk_known = (word_v_q && word_i_q == widx_q) ||
                           empty_q[widx_q] || full_q[widx_q];
    wire [63:0] mk_wold = (word_v_q && word_i_q == widx_q) ? word_q
                        : empty_q[widx_q]                  ? '0
                                                           : '1;
    wire        mk_full = &mk_mask;      // whole word covered: no RMW
    wire [63:0] mk_wdat = clr_q ? mk_wold & ~mk_mask
                                : mk_wold | mk_mask;

    always_comb begin
      map_req   = 1'b0;
      map_we    = 1'b0;
      map_addr  = widx_q;
      map_wdata = mk_wdat;
      unique case (state_q)
        StScan:  map_req = !(empty_q[widx_q] || full_q[widx_q]);
        StScanH: map_req = !(empty_q[widx_q] || full_q[widx_q]);
        StChk:   map_req = !(empty_q[widx_q] || full_q[widx_q]);
        // write direct when the new content is already known, else
        // issue the read half of the read-modify-write
        StMark:  begin
          map_req = 1'b1;
          map_we  = mk_full || mk_known;
        end
        StMarkW: begin
          map_req   = 1'b1;
          map_we    = 1'b1;
          map_wdata = clr_q ? map_rdata & ~mk_mask
                            : map_rdata | mk_mask;
        end
        default: ;
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle; cpl_q <= '0;
        full_q <= '0; empty_q <= '1;
        widx_q <= '0; wend_q <= '0; npg_q <= '0;
        clr_q <= '0;
        run_q <= '0; run_s_q <= '0;
        f0_q <= '0; f1_q <= '0; res_q <= '0;
        ep0_q <= '1; ep1_q <= '0;
        word_q <= '0; word_i_q <= '0; word_v_q <= '0;
        used_q <= '0;
      end else begin
        // default: no cache update; set per access below
        unique case (state_q)
        // ---------------- request accept / dispatch ----------------
        StIdle: if (req_valid_i) begin
          unique case (req_i.op)
            APU_VGPAGES_OP_ALLOC, APU_VGPAGES_OP_ALLOC_PRIV,
            APU_VGPAGES_OP_ALLOC_HI: begin
              if (req_i.bytes == 32'h0) begin
                cpl_q   <= '{status: APU_VGPAGES_OK, base: '0};
                state_q <= StCpl;
              end else if (pages_of(req_i.bytes) >
                           (req_i.op == APU_VGPAGES_OP_ALLOC_PRIV
                            ? 32'(PrivPages) : 32'(GuestPages))) begin
                cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
                state_q <= StCpl;
              end else if (req_i.op == APU_VGPAGES_OP_ALLOC_HI) begin
                // §12.3 3d-d: top-down scan of the guest window; the
                // exclusion folds into the scan as busy pages
                npg_q   <= pages_of(req_i.bytes);
                clr_q   <= 1'b0;
                widx_q  <= WBits'(GuestWords - 1);
                wend_q  <= '0;
                run_q   <= '0;
                run_s_q <= '0;
                ep0_q   <= req_i.base < req_i.excl_hi
                           ? req_i.base / PageBytes : 32'hFFFF_FFFF;
                ep1_q   <= req_i.base < req_i.excl_hi
                           ? (req_i.excl_hi - 32'h1) / PageBytes : '0;
                state_q <= StScanH;
              end else begin
                npg_q   <= pages_of(req_i.bytes);
                clr_q   <= 1'b0;
                widx_q  <= req_i.op == APU_VGPAGES_OP_ALLOC_PRIV
                           ? WBits'(GuestWords) : '0;
                wend_q  <= req_i.op == APU_VGPAGES_OP_ALLOC_PRIV
                           ? WBits'(Words - 1) : WBits'(GuestWords - 1);
                run_q   <= '0;
                run_s_q <= '0;
                state_q <= StScan;
              end
            end
            APU_VGPAGES_OP_ALLOC_AT: begin
              // caller-chosen extent: mark every page the byte range
              // [base, base+bytes) covers; BUSY on a real overlap.  The
              // guest kernel allocates at its own (4 KiB-class) grid, so
              // alignment is checked against the aperture, not PageBytes.
              // Guest placements may not reach the device-private arena:
              // the kernel's drm_mm only spans the advertised SHM_LEN,
              // but enforce it here so a stray guest extent can never
              // share a page with internal allocations.
              if (req_i.bytes == 32'h0 ||
                  64'(req_i.base) + 64'(req_i.bytes) > 64'(GuestBytes)) begin
                cpl_q   <= '{status: APU_VGPAGES_BOUNDS, base: '0};
                state_q <= StCpl;
              end else begin
                f0_q   <= req_i.base / PageBytes;
                f1_q   <= (req_i.base + req_i.bytes - 32'h1) / PageBytes;
                widx_q <= WBits'((req_i.base / PageBytes) >> 6);
                wend_q <= WBits'(((req_i.base + req_i.bytes - 32'h1) /
                                  PageBytes) >> 6);
                res_q  <= req_i.base;
                clr_q  <= 1'b0;
                state_q <= StChk;
              end
            end
            default: begin // APU_VGPAGES_OP_FREE
              if (req_i.bytes != 32'h0 &&
                  64'(req_i.base) + 64'(req_i.bytes) > 64'(WinBytes)) begin
                cpl_q   <= '{status: APU_VGPAGES_BOUNDS, base: '0};
                state_q <= StCpl;
              end else begin
                if (req_i.bytes != 32'h0) begin
                  f0_q   <= req_i.base / PageBytes;
                  f1_q   <= (req_i.base + req_i.bytes - 32'h1) / PageBytes;
                  widx_q <= WBits'((req_i.base / PageBytes) >> 6);
                  wend_q <= WBits'(((req_i.base + req_i.bytes - 32'h1) /
                                    PageBytes) >> 6);
                  clr_q  <= 1'b1;
                  state_q <= StMark;
                end else begin
                  cpl_q   <= '{status: APU_VGPAGES_OK, base: '0};
                  state_q <= StCpl;
                end
              end
            end
          endcase
        end

        // ---------------- first-fit scan (1 word/cycle) --------------
        // empty/full words are resolved from the flop summaries alone;
        // a mixed word is read and processed in StScanW.
        StScan: begin
          if (empty_q[widx_q]) begin
            if (64'(run_q) + 64 >= 64'(npg_q)) begin
              // run completes inside this all-free word
              res_q   <= 32'(run_q != 0 ? run_s_q
                                        : 32'(widx_q) * 64) *
                         PageBytes;
              f0_q    <= run_q != 0 ? run_s_q : 32'(widx_q) * 64;
              f1_q    <= (run_q != 0 ? run_s_q : 32'(widx_q) * 64) +
                         npg_q - 1;
              widx_q  <= WBits'((run_q != 0 ? run_s_q
                                            : 32'(widx_q) * 64) >> 6);
              wend_q  <= WBits'(((run_q != 0 ? run_s_q
                                             : 32'(widx_q) * 64) +
                                 npg_q - 1) >> 6);
              state_q <= StMark;
            end else begin
              if (run_q == 0)
                run_s_q <= 32'(widx_q) * 64;
              run_q <= run_q + 64;
              if (widx_q == wend_q) begin
                cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
                state_q <= StCpl;
              end else begin
                widx_q <= widx_q + 1'b1;
              end
            end
          end else if (full_q[widx_q]) begin
            run_q <= '0;
            if (widx_q == wend_q) begin
              cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
              state_q <= StCpl;
            end else begin
              widx_q <= widx_q + 1'b1;
            end
          end else begin
            word_i_q <= widx_q;
            state_q  <= StScanW;
          end
        end

        StScanW: begin
          // map_rdata = busy bits of word widx_q (word_i_q)
          word_q  <= map_rdata;
          word_v_q <= 1'b1;
          begin
            automatic logic [63:0] w  = map_rdata;
            automatic logic [6:0]  ld = ctz64(w);
            automatic logic [6:0]  fr = first_run(w, npg_q);
            if (w == '0) begin
              // defence in depth: summary said mixed; treat as empty
              if (64'(run_q) + 64 >= 64'(npg_q)) begin
                res_q   <= 32'(run_q != 0 ? run_s_q
                                          : 32'(widx_q) * 64) *
                           PageBytes;
                f0_q    <= run_q != 0 ? run_s_q : 32'(widx_q) * 64;
                f1_q    <= (run_q != 0 ? run_s_q : 32'(widx_q) * 64) +
                           npg_q - 1;
                widx_q  <= WBits'((run_q != 0 ? run_s_q
                                              : 32'(widx_q) * 64) >> 6);
                wend_q  <= WBits'(((run_q != 0 ? run_s_q
                                               : 32'(widx_q) * 64) +
                                   npg_q - 1) >> 6);
                state_q <= StMark;
              end else begin
                if (run_q == 0)
                  run_s_q <= 32'(widx_q) * 64;
                run_q <= run_q + 64;
                if (widx_q == wend_q) begin
                  cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
                  state_q <= StCpl;
                end else begin
                  widx_q <= widx_q + 1'b1;
                end
              end
            end else if (run_q != 0 && 64'(run_q) + ld >= 64'(npg_q)) begin
              // carried run completes at/before the first busy bit
              res_q   <= run_s_q * PageBytes;
              f0_q    <= run_s_q;
              f1_q    <= run_s_q + npg_q - 1;
              widx_q  <= WBits'(run_s_q >> 6);
              wend_q  <= WBits'((run_s_q + npg_q - 1) >> 6);
              state_q <= StMark;
            end else if (fr != 7'd64) begin
              // first in-word window; any fit in bits [0,lead) would
              // already have been taken by the carried run
              res_q   <= (32'(widx_q) * 64 + fr) * PageBytes;
              f0_q    <= 32'(widx_q) * 64 + fr;
              f1_q    <= 32'(widx_q) * 64 + fr + npg_q - 1;
              widx_q  <= WBits'((32'(widx_q) * 64 + fr) >> 6);
              wend_q  <= WBits'((32'(widx_q) * 64 + fr + npg_q - 1) >> 6);
              state_q <= StMark;
            end else begin
              // no fit: carry the trailing free run into the next word
              automatic logic [6:0] tr = clz64(w);
              run_q   <= 32'(tr);
              run_s_q <= 32'(widx_q) * 64 + 64 - tr;
              if (widx_q == wend_q) begin
                cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
                state_q <= StCpl;
              end else begin
                widx_q <= widx_q + 1'b1;
                state_q <= StScan;
              end
            end
          end
        end

        // ---------------- §12.3 3d-d: ALLOC_HI top-down scan ---------
        // Descends the guest window one word per cycle; run_q counts
        // the free pages contiguous from page (widx+1)*64 upward —
        // the part of the current free segment already scanned.
        // Exclusion pages fold into the busy view via xh_mask, so a
        // run can never straddle [excl_lo, excl_hi).  A fit lands at
        // the top of the highest reachable run — the highest-address
        // placement — then shares the StMark machinery.
        StScanH: begin
          automatic logic [63:0] w = empty_q[widx_q] ? xh_mask :
              full_q[widx_q] ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0;
          automatic logic [6:0]  cl = clz64(w);
          automatic logic [6:0]  lr = last_run(w, npg_q);
          if (!empty_q[widx_q] && !full_q[widx_q]) begin
            // mixed word: read and resolve in StScanHW
            word_i_q <= widx_q;
            state_q  <= StScanHW;
          end else if (32'(cl) + run_q >= npg_q) begin
            // free region [64w+64-clz, 64w+64+run): extent at its top
            f0_q    <= 32'(widx_q) * 64 + 63 + run_q - (npg_q - 1);
            f1_q    <= 32'(widx_q) * 64 + 63 + run_q;
            res_q   <= (32'(widx_q) * 64 + 63 + run_q - (npg_q - 1)) *
                       PageBytes;
            widx_q  <= WBits'((32'(widx_q) * 64 + 63 + run_q -
                               (npg_q - 1)) >> 6);
            wend_q  <= WBits'((32'(widx_q) * 64 + 63 + run_q) >> 6);
            state_q <= StMark;
          end else if (lr != 7'd64) begin
            // highest in-word window below the top busy/excluded bit
            f0_q    <= 32'(widx_q) * 64 + 32'(lr);
            f1_q    <= 32'(widx_q) * 64 + 32'(lr) + npg_q - 1;
            res_q   <= (32'(widx_q) * 64 + 32'(lr)) * PageBytes;
            widx_q  <= WBits'((32'(widx_q) * 64 + 32'(lr)) >> 6);
            wend_q  <= WBits'((32'(widx_q) * 64 + 32'(lr) + npg_q - 1)
                              >> 6);
            state_q <= StMark;
          end else begin
            // carry the free bottom of this word into the next one
            run_q <= cl == 7'd64 ? run_q + 32'd64 : 32'(ctz64(w));
            if (widx_q == '0) begin
              cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
              state_q <= StCpl;
            end else begin
              widx_q <= widx_q - 1'b1;
            end
          end
        end

        StScanHW: begin
          // map_rdata = busy bits of word widx_q (word_i_q); xh_mask
          // merges the exclusion in for the fit logic only — the
          // cached word stays the real bitmap so a later mark RMW
          // cannot write exclusion bits into the map
          automatic logic [63:0] w = map_rdata | xh_mask;
          automatic logic [6:0]  cl = clz64(w);
          automatic logic [6:0]  lr = last_run(w, npg_q);
          word_q   <= map_rdata;
          word_v_q <= 1'b1;
          if (32'(cl) + run_q >= npg_q) begin
            f0_q    <= 32'(widx_q) * 64 + 63 + run_q - (npg_q - 1);
            f1_q    <= 32'(widx_q) * 64 + 63 + run_q;
            res_q   <= (32'(widx_q) * 64 + 63 + run_q - (npg_q - 1)) *
                       PageBytes;
            widx_q  <= WBits'((32'(widx_q) * 64 + 63 + run_q -
                               (npg_q - 1)) >> 6);
            wend_q  <= WBits'((32'(widx_q) * 64 + 63 + run_q) >> 6);
            state_q <= StMark;
          end else if (lr != 7'd64) begin
            f0_q    <= 32'(widx_q) * 64 + 32'(lr);
            f1_q    <= 32'(widx_q) * 64 + 32'(lr) + npg_q - 1;
            res_q   <= (32'(widx_q) * 64 + 32'(lr)) * PageBytes;
            widx_q  <= WBits'((32'(widx_q) * 64 + 32'(lr)) >> 6);
            wend_q  <= WBits'((32'(widx_q) * 64 + 32'(lr) + npg_q - 1)
                              >> 6);
            state_q <= StMark;
          end else begin
            run_q <= cl == 7'd64 ? run_q + 32'd64 : 32'(ctz64(w));
            if (widx_q == '0) begin
              cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
              state_q <= StCpl;
            end else begin
              widx_q <= widx_q - 1'b1;
              state_q <= StScanH;
            end
          end
        end

        // ---------------- ALLOC_AT conflict check -------------------
        StChk: begin
          if (empty_q[widx_q]) begin
            // all free: no covered page can be busy
            if (widx_q == wend_q) begin
              widx_q  <= WBits'(f0_q >> 6);
              state_q <= StMark;
            end else begin
              widx_q <= widx_q + 1'b1;
            end
          end else if (full_q[widx_q]) begin
            cpl_q   <= '{status: APU_VGPAGES_BUSY, base: '0};
            state_q <= StCpl;
          end else begin
            word_i_q <= widx_q;
            state_q  <= StChkW;
          end
        end

        StChkW: begin
          word_q   <= map_rdata;
          word_v_q <= 1'b1;
          if ((map_rdata & ext_mask(widx_q, f0_q, f1_q)) != '0) begin
            cpl_q   <= '{status: APU_VGPAGES_BUSY, base: '0};
            state_q <= StCpl;
          end else if (widx_q == wend_q) begin
            widx_q  <= WBits'(f0_q >> 6);
            state_q <= StMark;
          end else begin
            widx_q  <= widx_q + 1'b1;
            state_q <= StChk;
          end
        end

        // ---------------- mark / unmark (1 word/cycle) ---------------
        // A covered word is written whole when the mask is '1 or its
        // content is already known (cache / summaries); a partial
        // mixed word goes through read-modify-write in StMarkW.
        StMark: begin
          if (mk_full || mk_known) begin
            // direct write, no read needed
            word_q   <= mk_wdat;
            word_i_q <= widx_q;
            word_v_q <= 1'b1;
            full_q[widx_q]  <= &mk_wdat;
            empty_q[widx_q] <= ~(|mk_wdat);
            used_q <= used_q + 32'($countones(mk_wdat)) -
                      32'($countones(mk_wold));
            if (widx_q == wend_q) begin
              cpl_q   <= '{status: APU_VGPAGES_OK,
                           base: clr_q ? '0 : res_q};
              state_q <= StCpl;
            end else begin
              widx_q <= widx_q + 1'b1;
            end
          end else begin
            word_i_q <= widx_q;
            state_q  <= StMarkW;
          end
        end

        StMarkW: begin
          automatic logic [63:0] wn = clr_q ? map_rdata & ~mk_mask
                                            : map_rdata | mk_mask;
          word_q   <= wn;
          word_i_q <= widx_q;
          word_v_q <= 1'b1;
          full_q[widx_q]  <= &wn;
          empty_q[widx_q] <= ~(|wn);
          used_q <= used_q + 32'($countones(wn)) -
                    32'($countones(map_rdata));
          if (widx_q == wend_q) begin
            cpl_q   <= '{status: APU_VGPAGES_OK,
                         base: clr_q ? '0 : res_q};
            state_q <= StCpl;
          end else begin
            widx_q  <= widx_q + 1'b1;
            state_q <= StMark;
          end
        end

        // ---------------- completion ---------------------------------
        StCpl: if (cpl_ready_i)
          state_q <= StIdle;

        default: state_q <= StIdle;
        endcase
      end
    end

`ifndef SYNTHESIS
    // §12.3 3d-c geometry rules
    initial begin
      assert (Pages % 64 == 0)
        else $fatal(1, "g6lc_apu_vgpages: Pages %0d not a multiple of 64",
                    Pages);
      assert (GuestPages == Pages || GuestPages % 64 == 0)
        else $fatal(1, "g6lc_apu_vgpages: guest/private split %0d pages \
not word-aligned", GuestPages);
      assert (GuestPages == Pages ||
              PrivPages * PageBytes >= 32'h0010_0000)
        else $fatal(1, "g6lc_apu_vgpages: private arena %0d B < 1 MiB",
                    PrivPages * PageBytes);
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o);
`endif
  end
endmodule

// enable-0 / small-geometry fixture for the synthesis screens
module g6lc_apu_vgpages_fixture
  import g6lc_apu_vgpages_pkg::*;
#(parameter bit          Enable    = 1'b0,
  parameter int unsigned Pages     = 256,
  parameter int unsigned PageBytes = 4096,
  parameter int unsigned GuestPages = Pages) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             testmode_i,
  input  logic             req_valid_i,
  output logic             req_ready_o,
  input  apu_vgpages_req_t req_i,
  output logic             cpl_valid_o,
  input  logic             cpl_ready_i,
  output apu_vgpages_cpl_t cpl_o
);
  g6lc_apu_vgpages #(.Enable(Enable), .Pages(Pages),
                     .PageBytes(PageBytes),
                     .GuestPages(GuestPages)) i_dut (.*);
endmodule
