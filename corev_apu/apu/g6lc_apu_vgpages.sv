// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Aperture page allocator (§7b/5a-ii): first-fit over a page bitmap for
// the blob SHM aperture window.  Factored out of g6lc_apu_vgctl so the
// same page pool backs both virtio-gpu blob resources (vgctl) and
// vkAllocateMemory device memory (vnfront); instantiated once in
// g6lc_apu_vgtop behind a grant arbiter.
//
//   ALLOC(bytes)      -> {OK, base}    first-fit run of ceil(bytes/
//                                      PageBytes) pages, marked busy
//                   -> {FULL, 0}      no run fits
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
// The allocation bitmap is flops (Pages bits).  Requests and
// completions use the ObjTab ready/valid pattern: a request is taken
// only in StIdle, every request produces exactly one completion held
// until cpl_ready_i.  The first-fit scan walks one page bit per cycle,
// so ALLOC is O(Pages) worst case - allocation latency is dominated by
// the per-command sequencing of its requesters anyway (stability over
// throughput for 5a-ii).
//
// Timing impact: the widest cones are the variable shift that builds
// the mark mask and the Pages-wide free-bit probe; both are
// single-cycle and isolated in their own states.  No SRAM.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; Enable=0 elaborates no datapath; one completion per
// request.
module g6lc_apu_vgpages
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit          Enable    = 1'b0,
  parameter int unsigned Pages     = 256,
  parameter int unsigned PageBytes = 4096,
  // pages below GuestPages form the guest-mappable window the kernel's
  // shm drm_mm places MAP_BLOB extents in; pages [GuestPages, Pages)
  // are the device-private arena reachable only through ALLOC_PRIV
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
    localparam int unsigned PageBits  = $clog2(Pages);
    localparam int unsigned WinBytes  = Pages * PageBytes;
    localparam int unsigned GuestBytes = GuestPages * PageBytes;
    localparam int unsigned PrivPages  = Pages - GuestPages;
    // pages covering `bytes` bytes
    function automatic logic [31:0] pages_of(input logic [31:0] bytes);
      return (bytes + PageBytes - 1) / PageBytes;
    endfunction

    typedef enum logic [1:0] { StIdle, StScan, StCpl } state_e;

    state_e            state_q;
    apu_vgpages_cpl_t  cpl_q;
    logic [Pages-1:0]  free_q;
    logic [PageBits-1:0] scan_q;   // probe index
    logic [31:0]         npg_q;    // pages needed by in-flight op
    logic                priv_q;   // in-flight scan is the private arena
    logic [PageBits:0]   run_q;    // current free-run length
    logic [PageBits-1:0] run_s_q;  // current free-run start

    assign req_ready_o = state_q == StIdle;
    assign cpl_valid_o = state_q == StCpl;
    assign cpl_o       = cpl_q;

    // mark mask for a run of n pages starting at page s
    function automatic logic [Pages-1:0] run_mask(
        input logic [31:0] n, input logic [31:0] s);
      logic [Pages-1:0] m;
      m = '0;
      for (int i = 0; i < Pages; i++)
        if (i >= s && i < s + n)
          m[i] = 1'b1;
      return m;
    endfunction

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle; cpl_q <= '0;
        free_q <= '0; scan_q <= '0; npg_q <= '0;
        priv_q <= '0;
        run_q <= '0; run_s_q <= '0;
      end else begin
        unique case (state_q)
        // ---------------- request accept / dispatch ----------------
        StIdle: if (req_valid_i) begin
          unique case (req_i.op)
            APU_VGPAGES_OP_ALLOC, APU_VGPAGES_OP_ALLOC_PRIV: begin
              if (req_i.bytes == 32'h0) begin
                cpl_q   <= '{status: APU_VGPAGES_OK, base: '0};
                state_q <= StCpl;
              end else if (pages_of(req_i.bytes) >
                           (req_i.op == APU_VGPAGES_OP_ALLOC_PRIV
                            ? 32'(PrivPages) : 32'(GuestPages))) begin
                cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
                state_q <= StCpl;
              end else begin
                npg_q   <= pages_of(req_i.bytes);
                priv_q  <= req_i.op == APU_VGPAGES_OP_ALLOC_PRIV;
                scan_q  <= req_i.op == APU_VGPAGES_OP_ALLOC_PRIV
                           ? PageBits'(GuestPages) : '0;
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
                cpl_q <= '{status: APU_VGPAGES_BOUNDS, base: '0};
              end else if ((free_q &
                            run_mask((req_i.base + req_i.bytes - 32'h1) /
                                       PageBytes - req_i.base / PageBytes +
                                       32'd1,
                                     req_i.base / PageBytes)) != '0) begin
                cpl_q <= '{status: APU_VGPAGES_BUSY, base: '0};
              end else begin
                free_q <= free_q |
                          run_mask((req_i.base + req_i.bytes - 32'h1) /
                                     PageBytes - req_i.base / PageBytes +
                                     32'd1,
                                   req_i.base / PageBytes);
                cpl_q <= '{status: APU_VGPAGES_OK, base: req_i.base};
              end
              state_q <= StCpl;
            end
            default: begin // APU_VGPAGES_OP_FREE
              if (req_i.bytes != 32'h0 &&
                  64'(req_i.base) + 64'(req_i.bytes) > 64'(WinBytes)) begin
                cpl_q   <= '{status: APU_VGPAGES_BOUNDS, base: '0};
              end else begin
                if (req_i.bytes != 32'h0)
                  // unmark coverage, matching ALLOC_AT: the last covered
                  // page may be partially used by an unaligned extent
                  free_q <= free_q &
                            ~run_mask((req_i.base + req_i.bytes - 32'h1) /
                                        PageBytes - req_i.base / PageBytes +
                                        32'd1,
                                      req_i.base / PageBytes);
                cpl_q   <= '{status: APU_VGPAGES_OK, base: '0};
              end
              state_q <= StCpl;
            end
          endcase
        end

        // ---------------- first-fit scan (1 page/cycle) --------------
        StScan: begin
          if (!free_q[scan_q]) begin
            if (run_q == '0)
              run_s_q <= scan_q;
            run_q <= run_q + 1'b1;
            if (64'(run_q) + 1 == 64'(npg_q)) begin
              free_q <= free_q |
                        run_mask(npg_q, run_q == '0 ? 32'(scan_q)
                                                    : 32'(run_s_q));
              cpl_q  <= '{status: APU_VGPAGES_OK,
                          base: (run_q == '0 ? 32'(scan_q)
                                              : 32'(run_s_q)) *
                                PageBytes};
              state_q <= StCpl;
            end else if (scan_q == PageBits'(priv_q ? Pages - 1
                                                    : GuestPages - 1)) begin
              cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
              state_q <= StCpl;
            end else begin
              scan_q <= scan_q + 1'b1;
            end
          end else begin
            run_q <= '0;
            if (scan_q == PageBits'(priv_q ? Pages - 1
                                           : GuestPages - 1)) begin
              cpl_q   <= '{status: APU_VGPAGES_FULL, base: '0};
              state_q <= StCpl;
            end else begin
              scan_q <= scan_q + 1'b1;
            end
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
