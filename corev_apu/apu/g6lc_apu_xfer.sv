// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// §12.3 phase C / increment 5a of architecture/uncore/apu-vulkan-engine.md:
// the Xfer engine — hardware execution of vkCmdCopyBuffer, vkCmdFillBuffer
// and vkCmdUpdateBuffer as bulk DMA over the shared AXI master.
//
// cmdexec resolves the operand buffers into an apu_xfer_desc_t sideband
// (aperture-relative {base, size} per operand) and hands the work record
// here; the U64 operands (copy regions, dstOffset/size, update data) ride
// the cmdrec payload arena and are replayed through PAYREAD (a third
// cmdrec requester — vgtop arbitration is pump > cmdexec > xfer).
//
// Datapath: every operand goes through the existing checked pair
// g6lc_apu_dma_read / g6lc_apu_dma_write.  The pair speaks the same
// right-justified fragment format ({data, contiguous-low keep,
// chunk-relative offset, last}), so COPY is a fragment FIFO from reader
// to writer — the write engine's own stepping performs the src/dst
// realignment (Vulkan imposes no alignment on copy offsets).  FILL and
// UPDATE bypass the reader and feed the FIFO directly (UPDATE reads its
// data words back through PAYREAD).  All region/offset bounds and the
// Vulkan no-overlap rule are validated in pass A before any write
// request is issued in pass B, so a refused record writes zero bytes.
// Requests are chunked to Dma{Read,Write}MaxBytes.
//
// The read engine emits checked bursts (page-split at 4 KiB, up to
// DmaReadBurstBeats beats); the write engine performs one narrow AXI
// write round trip per fragment step.  One read and one write are
// outstanding at a time — the next performance step is deeper
// outstanding (multi-request pipelining) in both engines.
//
// A DMA completion with status != APU_DMA_OK, or an engine bus_fault,
// completes the record APU_SH_DONE_FAULT (cmdexec marks the submit
// DEVICE_LOST) and poisons the engine until reset: later records fail
// fast instead of hanging on a halted DMA leg.  The engines themselves
// latch protocol faults in their Halted state until rst_ni.
//
// Config seam: apu_cfg_legal forbids Dma{Read,Write}En under VenusEn, so
// the pair sees a derived view — the Venus window/burst geometry with the
// internal DMA legs on and the guest-facing VIRGL surface cleared.  This
// is an internal engine only; the outer ApuCfg keeps the F1 split.
//
// flush_i (engine reset, from vgsys): cancels both legs, drains in-flight
// bursts to completion or halt, drops the work item without a done pulse,
// and returns to idle — an issued AXI transaction always retires before
// eng_rst_n falls.
//
// §12.3 C/5b-r2: all image-class address generation runs through ONE
// shared iterative 32x32->64 multiplier (MulRadixBits bits per cycle,
// default 8 -> 4 cycles per product).  Each image op compiles into a
// short micro-program — a list of {op, dst, a, b} steps walked one
// product/sum per XCalc cycle — so no parallel multiplier sits in any
// image state.  Image addressing is 32-bit aperture-relative: any
// product or sum that exceeds 32 bits, and any bufferOffset upper
// word != 0, is a validation fault (DEVICE_LOST) — the DMA mapping is
// a second line of defence, never the correctness check.  The CLEAR
// sRGB encode walks the 256-entry LUT one binary-search step per
// cycle (8 cycles per component), not an unrolled compare chain.
//
// Timing impact: the widest state element is the fragment FIFO
// (FifoDepth x 105 bits, flops — a deeper geometry should move to
// tc_sram); control is a micro-FSM with one PAYREAD / AXI beat per
// micro-step.  The shared multiplier's per-cycle cone is one
// MulRadixBits x 32 partial-product plus a 64-bit accumulate.
//
// Review checklist: async active-low reset; always_ff/always_comb split;
// no latches; Enable=0 constant-inactive netlist; no new clocks.

module g6lc_apu_xfer
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_srgb_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  // outer (Venus) view; the DMA pair gets apu_xfer_cfg(ApuCfg)
  parameter apu_cfg_t    ApuCfg = ApuVenus,
  // fragments between the read leg and the write leg; flops
  parameter int unsigned FifoDepth = 32,
  // §12.3 C/5b-r2: shared iterative-multiplier radix — one
  // MulRadixBits-bit digit of the multiplicand per cycle
  // (8 -> a 32x32 product completes in 4 cycles)
  parameter int unsigned MulRadixBits = 8
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  // work port (routed from cmdexec by vgtop; xf_i valid with work_i)
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_xfer_desc_t    xf_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  // cmdrec payload-arena reads (PAYREAD requester)
  output logic              cr_req_valid_o,
  input  logic              cr_req_ready_i,
  output apu_cmdrec_req_t   cr_req_o,
  input  logic              cr_cpl_valid_i,
  output logic              cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t   cr_cpl_i,
  // aperture base (mapping base = ap_base_i + operand offset)
  input  logic [63:0]       ap_base_i,
  // engine reset: cancel + drain DMA, drop work, return idle
  input  logic              flush_i,
  // non-idle FSM (vgsys reset sequencer waits for this too)
  output logic              busy_o,
  // AXI master: union of the read leg (AR/R) and write leg (AW/W/B)
  output apu_dma_axi_req_t  axi_req_o,
  input  apu_dma_axi_resp_t axi_rsp_i
);
  // ---- derived internal DMA configuration -----------------------------
  // VenusEn configs may not enable the host-facing DMA legs; the xfer
  // pair is internal, so it runs on the Venus geometry with the legs
  // on and the guest-facing VIRGL surface cleared.  Declared at module
  // scope — constant functions under a generate cannot drive localparams.
  function automatic apu_cfg_t apu_xfer_cfg(input apu_cfg_t c);
    apu_cfg_t d;
    d = c;
    d.VenusEn          = 1'b0;
    d.FeatureVirgl     = 1'b0;
    d.NumCapsets       = unsigned'(0);
    d.DmaReadEn        = 1'b1;
    d.DmaWriteEn       = 1'b1;
    d.DmaReadMaxBytes  = unsigned'(1048576);
    d.DmaWriteMaxBytes = unsigned'(1048576);
    return d;
  endfunction
  localparam apu_cfg_t    XCfg = apu_xfer_cfg(ApuCfg);
  localparam int unsigned ChunkMax =
      XCfg.DmaReadMaxBytes < XCfg.DmaWriteMaxBytes
      ? XCfg.DmaReadMaxBytes : XCfg.DmaWriteMaxBytes;
  localparam logic [63:0] WHOLE = 64'hFFFF_FFFF_FFFF_FFFF;

  if (!Enable) begin : gen_off
    assign work_ready_o   = 1'b0;
    assign done_o         = 1'b0;
    assign done_pl_o      = '0;
    assign cr_req_valid_o = 1'b0;
    assign cr_req_o       = '0;
    assign cr_cpl_ready_o = 1'b0;
    assign busy_o         = 1'b0;
    assign axi_req_o      = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | work_valid_i |
                    (|work_i) | (|xf_i) | cr_req_ready_i |
                    cr_cpl_valid_i | (|cr_cpl_i) | (|ap_base_i) |
                    flush_i | (|axi_rsp_i);
  end else begin : gen_on

    `ifndef SYNTHESIS
    initial begin
      assert (apu_cfg_legal(XCfg))
        else $fatal(1, "APU xfer: derived DMA configuration illegal");
      assert (FifoDepth >= 2)
        else $fatal(1, "APU xfer: FifoDepth < 2");
      assert (MulRadixBits >= 1 && MulRadixBits <= 32 &&
              32 % MulRadixBits == 0)
        else $fatal(1, "APU xfer: MulRadixBits must divide 32");
    end
    `endif

    typedef enum logic [4:0] {
      XIdle,
      XPay,                          // u64 arena fetch (2 x PAYREAD)
      XHdrA, XHdrB, XHdrChk,         // FILL/UPDATE {dstOffset, size}
      XVaS, XVaD, XVaChk,            // pass A: region bounds
      XOvA, XOvChk,                  // pass A: overlap inner loop
      XExS, XExD, XExChk,            // pass B: region re-read
      XReq,                          // issue one chunk's DMA requests
      XRun,                          // stream fragments
      // §12.3 C/5b: image-class records
      XImgRd,                        // stream region words into rg_q
      XImgChk,                       // pass A: region bounds
      XImgChkN,                      // pass A: need <= operand size
      XCalc,                         // shared-multiplier micro-step
      XImgGo,                        // pass B: mip-loop for the region
      XImgMip,                       // mip_off[m] / pitch_m walk
      XImgMip2,                      // mip walk level advance
      XSeedR,                        // resume after the seed program
      XImgNxt,                       // advance row/layer/region
      XClrPat,                       // build the packed clear pattern
      XSrEnc,                        // sRGB binary search (1 step/cyc)
      XClrMip,                       // clear: mip walk per range
      XDone, XAbort
    } xf_state_e;
    xf_state_e state_q;

    apu_xfer_desc_t xf_q;
    logic [31:0]    fill_q;            // FILL pattern (rec.imm[0])
    // PAYREAD u64 service: the caller presets pay_adr_q + pay_ret_q and
    // enters XPay; on return pw_q holds the pair
    logic           pay_fly_q, pay_half_q;
    logic [15:0]    pay_adr_q;
    xf_state_e      pay_ret_q;
    logic [63:0]    pw_q;
    // FILL/UPDATE operands
    logic [63:0]    hoff_q, hsz_q;
    // COPY state
    logic [15:0]    vi_q, vj_q, ei_q;
    logic [63:0]    so_q, do_q, sz_q;  // region under validation/execution
    logic [63:0]    os_q;              // probe region srcOffset
    // chunk/byte bookkeeping
    logic [63:0]    coff_q;            // region byte cursor
    logic [31:0]    csz_q;             // bytes in the in-flight chunk req
    logic [31:0]    csent_q;           // bytes pushed for this chunk
    logic [63:0]    rem_q;             // record bytes left to produce
    logic           rd_iss_q, wr_iss_q;  // request accepted
    logic           rd_done_q, wr_done_q; // completion consumed
    logic           xf_fault_q;
    logic           poison_q;          // a DMA leg faulted: fail fast
    // UPDATE producer
    logic           up_ph_q;           // fetching data word 1
    logic [31:0]    up_lo_q;
    logic           up_v_q;
    apu_dma_read_data_t up_frag_q;
    // ---- §12.3 C/5b: image-class record state -----------------------
    // region/range words staged whole: 14w (B2I/I2B), 17w (I2I),
    // 5w (CLEAR range, after the 4 colour words)
    logic [31:0]    rg_q [18];
    logic [4:0]     rw_i_q, rg_n_q;
    xf_state_e      rg_ret_q;
    logic [15:0]    ri_q;              // region index
    // mip walk: mip_off[m] accumulates pitch_i*h_i; captures at m
    logic [31:0]    im_acc_q, im_off_q, im_pitch_q;
    logic [15:0]    im_wm_q, im_hm_q;
    logic [4:0]     im_m_q, im_tgt_q;
    logic           im_dst_q;          // I2I: dst-image walk
    logic [31:0]    dm_off_q, dm_pitch_q;
    logic [15:0]    dm_wm_q, dm_hm_q;
    // row walk within a region
    logic [31:0]    r_lay_q, r_row_q;
    logic [31:0]    r_rows_q, r_lays_q;
    logic [3:0]     c_mip_q;           // CLEAR: mip cursor in the range
    logic [127:0]   clr_pat_q;         // packed texel repeated to 16 B
    logic [3:0]     clr_ci_q;          // pattern comp cursor
    logic [31:0]    clr_col_q [4];     // raw colour words
    logic           pass_b_q;          // 0 = validating sweep
    logic           seed_q;            // XImgNxt: seed row 0 vs advance
    // row addressing: so_q/do_q hold the current row base and step by
    // rstep per row, ladj = lstep-(rows-1)*rstep at a layer edge —
    // keeps the row loop multiply-free.  §5b-r2: image addressing is
    // 32-bit aperture-relative; the COPY path keeps u64 region words.
    logic [31:0]    s_rstep_q, s_ladj_q;
    logic [31:0]    d_rstep_q, d_ladj_q;
    logic [31:0]    r_sz_q;            // bytes per row (w*bpp)
    // ---- §12.3 C/5b-r2: shared address-gen micro-engine --------------
    // Every image-state product runs on one iterative 32x32->64
    // multiplier: a micro-program ({op,dst,a,b} steps) is walked one
    // step per XCalc cycle; MUL/MAC steps take MulSteps radix cycles.
    // A product or sum exceeding 32 bits sets covf_q — the return
    // state turns it into the record's validation FAULT.
    localparam int unsigned MulSteps = 32 / MulRadixBits;
    logic [3:0]     cprog_q;           // program id
    logic [5:0]     cpc_q;             // micro-op cursor
    xf_state_e      cret_q;            // program return state
    logic           covf_q;            // any product/sum exceeded u32
    logic [31:0]    acc_q, t0_q, t1_q; // program temporaries
    logic           mrun_q;            // radix multiply in flight
    logic [31:0]    ma_q, mb_q;        // latched operands
    logic [63:0]    mp_q;              // product accumulator
    logic [5:0]     mk_q;              // radix step
    logic [2:0]     mop_q;             // latched micro-op
    logic [3:0]     mdst_q;            // latched destination
    // sequential sRGB encode: one LUT binary-search step per cycle
    logic           sr_rdy_q;          // result latched for XClrPat
    logic [15:0]    sr_lin_q;          // linear-16 input
    logic [8:0]     sr_lo_q, sr_hi_q;
    logic [15:0]    sr_lut_q;          // LUT[lo] mirror
    logic [2:0]     sr_k_q;
    logic [7:0]     sr_res_q;
    // fragment FIFO (producer -> write leg)
    apu_dma_read_data_t ff_q [FifoDepth];
    localparam int unsigned FBits = $clog2(FifoDepth);
    logic [FBits-1:0] fwr_q, frd_q;
    logic [FBits:0]   fn_q;
    logic             fifo_space;
    assign fifo_space = fn_q != (FBits+1)'(FifoDepth);

    logic is_copy, is_fill, is_upd, is_b2i, is_i2b, is_i2i, is_clr;
    logic is_img, is_rd;
    assign is_copy = xf_q.op == APU_XFER_OP_COPY;
    assign is_fill = xf_q.op == APU_XFER_OP_FILL;
    assign is_upd  = xf_q.op == APU_XFER_OP_UPDATE;
    assign is_b2i  = xf_q.op == APU_XFER_OP_B2I;
    assign is_i2b  = xf_q.op == APU_XFER_OP_I2B;
    assign is_i2i  = xf_q.op == APU_XFER_OP_I2I;
    assign is_clr  = xf_q.op == APU_XFER_OP_CLEARI;
    assign is_img  = is_b2i || is_i2b || is_i2i || is_clr;
    // every op except CLEAR streams read-leg fragments; B2I reads the
    // buffer operand, I2B/I2I the source image
    assign is_rd   = is_copy || is_b2i || is_i2b || is_i2i;

    // ---- §12.3 C/5b: device image-layout helpers ----------------------
    // off(layer, mip) = layer*layer_bytes + Σ_{i<m} pitch_i*h_i,
    // pitch_m = align(max(w>>m,1)*bpp, 64) — vnfront computes the same
    // totals at vkCreateImage; per-mip bases accumulate in XImgMip.
    function automatic logic [15:0] f_mdim(input logic [15:0] d,
                                           input logic [4:0]  m);
      logic [15:0] s;
      s = d >> m;
      return s == 16'h0 ? 16'd1 : s;
    endfunction
    function automatic logic [31:0] f_mpitch(input logic [15:0] w,
                                             input logic [7:0]  fmt,
                                             input logic [4:0]  m);
      return ((32'(f_mdim(w, m)) * 32'(APU_VN_IMG_BPP[fmt[3:0]])) +
              32'd63) & ~32'd63;
    endfunction
    // ---- CLEAR colour conversions ------------------------------------
    // fp32 -> UNORM8, clamped, round-to-nearest.  v = f*255 =
    // mant*255 * 2^(e-150); the single multiply is off the row loop.
    function automatic logic [7:0] f_f32_u8(input logic [31:0] f);
      logic [39:0] p;
      logic [8:0]  sh;
      p  = 40'({1'b1, f[22:0]}) * 40'd255;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 8'h00;
      if (f[30:23] >= 8'd127) return 8'hff;    // f >= 1.0 / inf / nan
      return 8'((p + (40'h1 << (sh - 9'd1))) >> sh);
    endfunction
    // fp32 -> linear 16 (round(f * 65535)) feeding the sRGB search
    function automatic logic [15:0] f_f32_l16(input logic [31:0] f);
      logic [47:0] p;
      logic [8:0]  sh;
      p  = 48'({1'b1, f[22:0]}) * 48'd65535;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 16'h0000;
      if (f[30:23] >= 8'd127) return 16'hffff;
      return 16'((p + (48'h1 << (sh - 9'd1))) >> sh);
    endfunction
    // linear16 -> sRGB byte is sequential in XSrEnc: one LUT
    // binary-search step per cycle (APU_SRGB_TO_LIN[mid]), same
    // "nearest entry, ties upward" rule as srgb_lut.py::lin16_to_srgb8.
    //
    // ---- shared iterative multiplier / micro-programs -----------------
    // micro-op word {op[2:0], dst[3:0], a[5:0], b[5:0]}:
    //   SET  dst = a            ADD  dst += a        SUB dst -= a
    //   MUL  dst = a*b          MAC  dst += a*b      MULNF = MUL, no
    //   overflow flag (buffer-side layer-skip term — legitimately
    //   ignored at layerCount == 1, so its product may exceed u32)
    // Every other product/sum saturates covf_q when it exceeds 32 bits.
    localparam logic [2:0] COP_END = 3'd0, COP_SET = 3'd1,
                           COP_ADD = 3'd2, COP_SUB = 3'd3,
                           COP_MUL = 3'd4, COP_MAC = 3'd5,
                           COP_MULNF = 3'd6;
    localparam logic [3:0] CD_ACC = 4'd0, CD_T0 = 4'd1, CD_T1 = 4'd2,
                           CD_SO = 4'd3, CD_DO = 4'd4, CD_SRST = 4'd5,
                           CD_SLAD = 4'd6, CD_DRST = 4'd7,
                           CD_DLAD = 4'd8, CD_RSZ = 4'd9,
                           CD_RROWS = 4'd10, CD_RLAYS = 4'd11,
                           CD_IMACC = 4'd12;
    // operand selects: 0/1 constants, 2..19 -> rg_q[0..17], then the
    // derived sources below; 38..40 read the temporaries back
    localparam logic [5:0] CO_ZERO = 6'd0, CO_ONE = 6'd1,
                           CO_RL = 6'd20, CO_IH = 6'd21,
                           CO_BPP = 6'd22, CO_LB0 = 6'd23,
                           CO_LB1 = 6'd24, CO_IMOFF = 6'd25,
                           CO_IMPT = 6'd26, CO_DMOFF = 6'd27,
                           CO_DMPT = 6'd28, CO_IMW = 6'd29,
                           CO_IMH = 6'd30, CO_IHH = 6'd31,
                           CO_RG12M1 = 6'd32, CO_RG15M1 = 6'd33,
                           CO_IMHM1 = 6'd34, CO_RG7M1 = 6'd35,
                           CO_PT = 6'd36, CO_HM2 = 6'd37,
                           CO_ACC = 6'd38, CO_T0 = 6'd39,
                           CO_T1 = 6'd40;
    // program ids: the operand-bound check, the four seed layouts and
    // the mip-offset accumulation
    localparam logic [3:0] CP_NEED = 4'd0, CP_B2I = 4'd1,
                           CP_I2B = 4'd2, CP_I2I = 4'd3,
                           CP_CLR = 4'd4, CP_MIP = 4'd5;
    // derived micro-engine sources (image operand geometry)
    logic [15:0] cwl_iw, cwl_ih, cwl_hm;
    logic [31:0] crl, cih, cbpp;
    assign cwl_iw = im_dst_q ? xf_q.img1.w : xf_q.img0.w;
    assign cwl_ih = im_dst_q ? xf_q.img1.h : xf_q.img0.h;
    assign cwl_hm = f_mdim(cwl_ih, im_m_q);
    assign crl = rg_q[2] != 32'h0 ? rg_q[2] : rg_q[11];
    assign cih = rg_q[3] != 32'h0 ? rg_q[3] : rg_q[12];
    assign cbpp = 32'(APU_VN_IMG_BPP[xf_q.img0.fmt[3:0]]);

    function automatic logic [31:0] f_cop(input logic [5:0] s);
      if (s >= 6'd2 && s <= 6'd19) return rg_q[5'(s - 6'd2)];
      case (s)
        CO_ZERO:   return 32'h0;
        CO_ONE:    return 32'd1;
        CO_RL:     return crl;
        CO_IH:     return cih;
        CO_BPP:    return cbpp;
        CO_LB0:    return xf_q.img0.layer_bytes;
        CO_LB1:    return xf_q.img1.layer_bytes;
        CO_IMOFF:  return im_off_q;
        CO_IMPT:   return im_pitch_q;
        CO_DMOFF:  return dm_off_q;
        CO_DMPT:   return dm_pitch_q;
        CO_IMW:    return 32'(im_wm_q);
        CO_IMH:    return 32'(im_hm_q);
        CO_IHH:    return cih - rg_q[12] + 32'd1;
        CO_RG12M1: return rg_q[12] - 32'd1;
        CO_RG15M1: return rg_q[15] - 32'd1;
        CO_IMHM1:  return 32'(im_hm_q) - 32'd1;
        CO_RG7M1:  return rg_q[7] - 32'd1;
        CO_PT:     return f_mpitch(cwl_iw,
                                   im_dst_q ? xf_q.img1.fmt
                                            : xf_q.img0.fmt, im_m_q);
        CO_HM2:    return 32'(cwl_hm);
        CO_ACC:    return acc_q;
        CO_T0:     return t0_q;
        CO_T1:     return t1_q;
        default:   return 32'h0;
      endcase
    endfunction
    function automatic logic [31:0] f_cdst(input logic [3:0] d);
      case (d)
        CD_ACC:   return acc_q;
        CD_T0:    return t0_q;
        CD_T1:    return t1_q;
        CD_SO:    return so_q[31:0];
        CD_DO:    return do_q[31:0];
        CD_SRST:  return s_rstep_q;
        CD_SLAD:  return s_ladj_q;
        CD_DRST:  return d_rstep_q;
        CD_DLAD:  return d_ladj_q;
        CD_RSZ:   return r_sz_q;
        CD_RROWS: return r_rows_q;
        CD_RLAYS: return r_lays_q;
        CD_IMACC: return im_acc_q;
        default:  return 32'h0;
      endcase
    endfunction
    task automatic f_cwb(input logic [3:0]  d,
                         input logic [31:0] v);
      unique case (d)
        CD_ACC:   acc_q <= v;
        CD_T0:    t0_q <= v;
        CD_T1:    t1_q <= v;
        CD_SO:    so_q <= {32'h0, v};
        CD_DO:    do_q <= {32'h0, v};
        CD_SRST:  s_rstep_q <= v;
        CD_SLAD:  s_ladj_q <= v;
        CD_DRST:  d_rstep_q <= v;
        CD_DLAD:  d_ladj_q <= v;
        CD_RSZ:   r_sz_q <= v;
        CD_RROWS: r_rows_q <= v;
        CD_RLAYS: r_lays_q <= v;
        CD_IMACC: im_acc_q <= v;
        default: ;
      endcase
    endtask
    // micro-program ROM — one {op,dst,a,b} word per step.  B2I/I2B
    // bounds: need = bo + w*bpp + (h-1)*rl*bpp + (L-1)*ih*rl*bpp.
    // Buffer-side seeds: base = bo (rg1==0 is checked upstream),
    // rstep = rl*bpp, ladj = (ih-h+1)*rl*bpp (MULNF — dead term at
    // layerCount==1).  Image-side seeds: layer*lb + mip_off +
    // y*pitch + x*bpp, rstep = pitch, ladj = lb-(rows-1)*pitch.
    function automatic logic [18:0] f_uop(input logic [3:0] p,
                                          input logic [5:0] c);
      logic [18:0] r;
      r = {COP_END, 4'h0, 6'h0, 6'h0};
      case (p)
        CP_NEED: case (c)
          6'd0: r = {COP_MUL, CD_T0, CO_RG7M1,  CO_IH};
          6'd1: r = {COP_MUL, CD_T0, CO_T0,     CO_RL};
          6'd2: r = {COP_MUL, CD_T0, CO_T0,     CO_BPP};
          6'd3: r = {COP_SET, CD_ACC, 6'd2,     CO_ZERO};
          6'd4: r = {COP_ADD, CD_ACC, CO_T0,    CO_ZERO};
          6'd5: r = {COP_MUL, CD_T0, CO_RG12M1, CO_RL};
          6'd6: r = {COP_MUL, CD_T0, CO_T0,     CO_BPP};
          6'd7: r = {COP_ADD, CD_ACC, CO_T0,    CO_ZERO};
          6'd8: r = {COP_MAC, CD_ACC, 6'd13,    CO_BPP};
          default: ;
        endcase
        CP_B2I: case (c)
          6'd0:  r = {COP_MUL,   CD_RSZ,   6'd13,    CO_BPP};
          6'd1:  r = {COP_SET,   CD_RROWS, 6'd14,    CO_ZERO};
          6'd2:  r = {COP_SET,   CD_RLAYS, 6'd9,     CO_ZERO};
          6'd3:  r = {COP_SET,   CD_SO,    6'd2,     CO_ZERO};
          6'd4:  r = {COP_MUL,   CD_SRST,  CO_RL,    CO_BPP};
          6'd5:  r = {COP_MULNF, CD_T0,    CO_IHH,   CO_RL};
          6'd6:  r = {COP_MULNF, CD_SLAD,  CO_T0,    CO_BPP};
          6'd7:  r = {COP_MUL,   CD_DO,    6'd8,     CO_LB0};
          6'd8:  r = {COP_MAC,   CD_DO,    6'd11,    CO_IMPT};
          6'd9:  r = {COP_MAC,   CD_DO,    6'd10,    CO_BPP};
          6'd10: r = {COP_ADD,   CD_DO,    CO_IMOFF, CO_ZERO};
          6'd11: r = {COP_SET,   CD_DRST,  CO_IMPT,  CO_ZERO};
          6'd12: r = {COP_MUL,   CD_T0,    CO_RG12M1, CO_IMPT};
          6'd13: r = {COP_SET,   CD_DLAD,  CO_LB0,   CO_ZERO};
          6'd14: r = {COP_SUB,   CD_DLAD,  CO_T0,    CO_ZERO};
          default: ;
        endcase
        CP_I2B: case (c)
          6'd0:  r = {COP_MUL,   CD_RSZ,   6'd13,    CO_BPP};
          6'd1:  r = {COP_SET,   CD_RROWS, 6'd14,    CO_ZERO};
          6'd2:  r = {COP_SET,   CD_RLAYS, 6'd9,     CO_ZERO};
          6'd3:  r = {COP_SET,   CD_DO,    6'd2,     CO_ZERO};
          6'd4:  r = {COP_MUL,   CD_DRST,  CO_RL,    CO_BPP};
          6'd5:  r = {COP_MULNF, CD_T0,    CO_IHH,   CO_RL};
          6'd6:  r = {COP_MULNF, CD_DLAD,  CO_T0,    CO_BPP};
          6'd7:  r = {COP_MUL,   CD_SO,    6'd8,     CO_LB0};
          6'd8:  r = {COP_MAC,   CD_SO,    6'd11,    CO_IMPT};
          6'd9:  r = {COP_MAC,   CD_SO,    6'd10,    CO_BPP};
          6'd10: r = {COP_ADD,   CD_SO,    CO_IMOFF, CO_ZERO};
          6'd11: r = {COP_SET,   CD_SRST,  CO_IMPT,  CO_ZERO};
          6'd12: r = {COP_MUL,   CD_T0,    CO_RG12M1, CO_IMPT};
          6'd13: r = {COP_SET,   CD_SLAD,  CO_LB0,   CO_ZERO};
          6'd14: r = {COP_SUB,   CD_SLAD,  CO_T0,    CO_ZERO};
          default: ;
        endcase
        CP_I2I: case (c)
          6'd0:  r = {COP_MUL,   CD_RSZ,   6'd16,    CO_BPP};
          6'd1:  r = {COP_SET,   CD_RROWS, 6'd17,    CO_ZERO};
          6'd2:  r = {COP_SET,   CD_RLAYS, 6'd5,     CO_ZERO};
          6'd3:  r = {COP_MUL,   CD_SO,    6'd4,     CO_LB0};
          6'd4:  r = {COP_MAC,   CD_SO,    6'd7,     CO_IMPT};
          6'd5:  r = {COP_MAC,   CD_SO,    6'd6,     CO_BPP};
          6'd6:  r = {COP_ADD,   CD_SO,    CO_IMOFF, CO_ZERO};
          6'd7:  r = {COP_SET,   CD_SRST,  CO_IMPT,  CO_ZERO};
          6'd8:  r = {COP_MUL,   CD_T0,    CO_RG15M1, CO_IMPT};
          6'd9:  r = {COP_SET,   CD_SLAD,  CO_LB0,   CO_ZERO};
          6'd10: r = {COP_SUB,   CD_SLAD,  CO_T0,    CO_ZERO};
          6'd11: r = {COP_MUL,   CD_DO,    6'd11,    CO_LB1};
          6'd12: r = {COP_MAC,   CD_DO,    6'd14,    CO_DMPT};
          6'd13: r = {COP_MAC,   CD_DO,    6'd13,    CO_BPP};
          6'd14: r = {COP_ADD,   CD_DO,    CO_DMOFF, CO_ZERO};
          6'd15: r = {COP_SET,   CD_DRST,  CO_DMPT,  CO_ZERO};
          6'd16: r = {COP_MUL,   CD_T0,    CO_RG15M1, CO_DMPT};
          6'd17: r = {COP_SET,   CD_DLAD,  CO_LB1,   CO_ZERO};
          6'd18: r = {COP_SUB,   CD_DLAD,  CO_T0,    CO_ZERO};
          default: ;
        endcase
        CP_CLR: case (c)
          6'd0:  r = {COP_MUL, CD_RSZ,   CO_IMW,   CO_BPP};
          6'd1:  r = {COP_SET, CD_RROWS, CO_IMH,   CO_ZERO};
          6'd2:  r = {COP_SET, CD_RLAYS, 6'd6,     CO_ZERO};
          6'd3:  r = {COP_SET, CD_SO,    CO_ZERO,  CO_ZERO};
          6'd4:  r = {COP_SET, CD_SRST,  CO_ZERO,  CO_ZERO};
          6'd5:  r = {COP_SET, CD_SLAD,  CO_ZERO,  CO_ZERO};
          6'd6:  r = {COP_MUL, CD_DO,    6'd5,     CO_LB0};
          6'd7:  r = {COP_ADD, CD_DO,    CO_IMOFF, CO_ZERO};
          6'd8:  r = {COP_SET, CD_DRST,  CO_IMPT,  CO_ZERO};
          6'd9:  r = {COP_MUL, CD_T0,    CO_IMHM1, CO_IMPT};
          6'd10: r = {COP_SET, CD_DLAD,  CO_LB0,   CO_ZERO};
          6'd11: r = {COP_SUB, CD_DLAD,  CO_T0,    CO_ZERO};
          default: ;
        endcase
        CP_MIP: case (c)
          6'd0: r = {COP_MAC, CD_IMACC, CO_PT, CO_HM2};
          default: ;
        endcase
        default: ;
      endcase
      return r;
    endfunction
    // fp32 -> fp16, round-to-nearest-even, denormal + carry-into-
    // exponent handling; |f| >= 65520 saturates to inf, |f| < 2^-25
    // and exact 2^-25 flush to zero (RNE boundary).
    function automatic logic [15:0] f_f32_f16(input logic [31:0] f);
      logic        s;
      logic [7:0]  e;
      logic [10:0] mr;
      logic [9:0]  sh;
      logic [23:0] m, msh, half;
      s = f[31]; e = f[30:23];
      if (e == 8'hff)
        return {s, 5'h1f, |f[22:0] ? 10'h1 : 10'h0};
      if (e >= 8'd143) return {s, 5'h1f, 10'h0};
      if (e < 8'd102)  return {s, 15'h0};
      m = {1'b1, f[22:0]};
      if (e >= 8'd113) begin
        // normal fp16: exponent field e-112 in [1,30], RNE 23->10
        mr = {1'b0, f[22:13]} +
             (f[12] && (|f[11:0] || f[13]) ? 11'd1 : 11'd0);
        return {s, 15'({5'(e - 8'd112), 10'h0} + {4'h0, mr})};
      end
      // denormal: D = RNE(m / 2^(126-e)); a carry into bit 10 folds
      // into exponent bit 0, giving min-normal naturally
      sh   = 10'(8'd126 - e);                    // e in [102,112]
      half = 24'h1 << (sh - 10'd1);
      msh  = m >> sh;
      if ((m & half) != 24'h0 &&
          ((m & (half - 24'h1)) != 24'h0 || msh[0]))
        msh = msh + 24'd1;
      return {s, 15'(msh[10:0])};
    endfunction
    // replicate the packed texel (low bpp*8 bits) across 16 bytes
    function automatic logic [127:0] f_rep16(input logic [127:0] t,
                                             input logic [3:0]  bsh);
      case (bsh)                    // bsh = log2(bytes-per-texel)
        4'd0:    return {16{t[7:0]}};
        4'd1:    return {8{t[15:0]}};
        4'd2:    return {4{t[31:0]}};
        4'd3:    return {2{t[63:0]}};
        default: return t;
      endcase
    endfunction
    // ceil-log2 of a small power-of-two byte count
    function automatic logic [3:0] f_l2(input logic [7:0] v);
      case (v)
        8'd1:    return 4'd0;
        8'd2:    return 4'd1;
        8'd4:    return 4'd2;
        8'd8:    return 4'd3;
        default: return 4'd4;
      endcase
    endfunction

    // ---- DMA pair ------------------------------------------------------
    // the read map covers the buffer operand (COPY/B2I) or the source
    // image (I2B/I2I); the write map the buffer (COPY/I2B/FILL/UPDATE)
    // or the destination image (B2I/CLEAR: img0, I2I: img1)
    logic [31:0] rd_op_base, rd_op_size, wr_op_base, wr_op_size;
    assign rd_op_base = is_b2i || is_copy ? xf_q.src_base
                                          : xf_q.img0.base;
    assign rd_op_size = is_b2i || is_copy ? xf_q.src_size
                                          : xf_q.img0.size;
    assign wr_op_base = is_i2i ? xf_q.img1.base
                        : is_b2i || is_clr ? xf_q.img0.base
                                           : xf_q.dst_base;
    assign wr_op_size = is_i2i ? xf_q.img1.size
                        : is_b2i || is_clr ? xf_q.img0.size
                                           : xf_q.dst_size;
    apu_dma_mapping_t rd_map, wr_map;
    assign rd_map = '{valid: 1'b1, permissions: 2'b01,
                     resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     base:  ap_base_i + 64'(rd_op_base),
                     bytes: 64'(rd_op_size)};
    assign wr_map = '{valid: 1'b1, permissions: 2'b10,
                     resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     base:  ap_base_i + 64'(wr_op_base),
                     bytes: 64'(wr_op_size)};

    logic               kill;
    assign kill = flush_i || xf_fault_q;

    logic               rd_req_v, rd_req_rdy;
    apu_dma_read_req_t  rd_req;
    logic               rd_dv, rd_dr;
    apu_dma_read_data_t rd_data;
    logic               rd_cpl_v, rd_idle, rd_fault;
    apu_dma_read_cpl_t  rd_cpl;
    logic               wr_req_v, wr_req_rdy;
    apu_dma_write_req_t wr_req;
    logic               wr_dv, wr_dr;
    apu_dma_read_data_t wr_data;
    logic               wr_cpl_v, wr_idle, wr_fault;
    apu_dma_write_cpl_t wr_cpl;
    apu_dma_axi_req_t   rd_axi, wr_axi;

    assign rd_req = '{resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     offset: so_q + coff_q, bytes: csz_q,
                     tag: {48'h0, ei_q}};
    assign wr_req = '{resource_id: 32'h1, context_id: 32'h0, epoch: 32'h0,
                     offset: (is_copy || is_img) ? (do_q + coff_q)
                                                 : (hoff_q + coff_q),
                     bytes: csz_q, tag: {48'h0, ei_q}};

    g6lc_apu_dma_read #(.ApuCfg(XCfg)) i_rd (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .enable_i(1'b1), .cancel_i(kill),
      .req_valid_i(rd_req_v), .req_ready_o(rd_req_rdy), .req_i(rd_req),
      .mapping_i(rd_map),
      .data_valid_o(rd_dv), .data_ready_i(rd_dr), .data_o(rd_data),
      .cpl_valid_o(rd_cpl_v), .cpl_ready_i(1'b1), .cpl_o(rd_cpl),
      .idle_o(rd_idle), .bus_fault_o(rd_fault),
      .axi_req_o(rd_axi), .axi_rsp_i(axi_rsp_i));

    g6lc_apu_dma_write #(.ApuCfg(XCfg)) i_wr (
      .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
      .enable_i(1'b1), .cancel_i(kill),
      .req_valid_i(wr_req_v), .req_ready_o(wr_req_rdy), .req_i(wr_req),
      .mapping_i(wr_map),
      .data_valid_i(wr_dv), .data_ready_o(wr_dr), .data_i(wr_data),
      .cpl_valid_o(wr_cpl_v), .cpl_ready_i(1'b1), .cpl_o(wr_cpl),
      .idle_o(wr_idle), .bus_fault_o(wr_fault),
      .axi_req_o(wr_axi), .axi_rsp_i(axi_rsp_i));

    // read leg drives AR/R only; write leg drives AW/W/B only — unioned
    // onto the single AXI master the join carries downstream
    always_comb begin
      axi_req_o          = '0;
      axi_req_o.ar_valid = rd_axi.ar_valid;
      axi_req_o.ar       = rd_axi.ar;
      axi_req_o.r_ready  = rd_axi.r_ready;
      axi_req_o.aw_valid = wr_axi.aw_valid;
      axi_req_o.aw       = wr_axi.aw;
      axi_req_o.w_valid  = wr_axi.w_valid;
      axi_req_o.w        = wr_axi.w;
      axi_req_o.b_ready  = wr_axi.b_ready;
    end

    // ---- producers -> fragment FIFO -> write leg -----------------------
    // COPY + image copies: reader fragments pass through (offset/last
    // are already chunk-relative and the formats match).  FILL: pattern
    // words.  CLEAR: the packed clear texel repeated over the row.
    // UPDATE: pairs of PAYREAD words assembled into fragments.
    // `crem` = bytes left to feed for the in-flight chunk request.
    logic [31:0]        crem;
    logic               discard, fill_go, upd_go, clr_go;
    logic               fifo_push, fifo_pop;
    apu_dma_read_data_t push_frag;
    logic [3:0]         upd_n;
    assign crem    = csz_q - csent_q;
    assign upd_n   = crem >= 32'd8 ? 4'd8 : 4'(crem[2:0]);
    assign discard = xf_fault_q || flush_i;

    assign fill_go = state_q == XRun && is_fill && crem != 32'h0 &&
                     fifo_space && !discard;
    assign clr_go  = state_q == XRun && is_clr && crem != 32'h0 &&
                     fifo_space && !discard;
    assign upd_go  = state_q == XRun && is_upd && crem != 32'h0 &&
                     !up_ph_q && !up_v_q && !pay_fly_q &&
                     fifo_space && !discard;

    assign fifo_push = state_q == XRun && !discard &&
        ((is_rd && rd_dv && fifo_space) ||
         fill_go || clr_go ||
         (is_upd && up_v_q && fifo_space));

    // CLEAR fragment: the packed-texel pattern at the fragment's byte
    // offset — rows start 64 B-aligned so the pattern phase within a
    // 16 B pair is fixed at csent_q[3]
    function automatic logic [63:0] f_clr_frag(input logic [31:0] off);
      return off[3] ? clr_pat_q[127:64] : clr_pat_q[63:0];
    endfunction

    always_comb begin
      push_frag = '0;
      if (is_rd) begin
        push_frag = rd_data;
      end else if (is_fill) begin
        // dstOffset and size are 4-byte aligned -> fragments are 8 or 4 B
        push_frag.data   = crem >= 32'd8 ? {2{fill_q}} : {32'h0, fill_q};
        push_frag.keep   = crem >= 32'd8 ? 8'hff : 8'h0f;
        push_frag.offset = csent_q;
        push_frag.last   = csent_q + (crem >= 32'd8 ? 32'd8 : 32'd4) ==
                           csz_q;
      end else if (is_clr) begin
        // a fragment never crosses a 16 B pattern pair; the tail keep
        // mask carries a whole texel count since bpp | 8
        push_frag.data   = f_clr_frag(csent_q);
        push_frag.keep   = crem >= 32'd8 ? 8'hff : 8'hff >> (8 - crem[2:0]);
        push_frag.offset = csent_q;
        push_frag.last   = csent_q + (crem >= 32'd8 ? 32'd8
                                                  : {29'h0, crem[2:0]}) ==
                           csz_q;
      end else begin
        push_frag = up_frag_q;
      end
    end

    // read leg drains into the FIFO; under fault/flush it still consumes
    // beats (into /dev/null) so an in-flight burst always retires
    assign rd_dr = (state_q == XRun || state_q == XAbort) &&
                   (fifo_space || discard);
    assign wr_dv    = fn_q != '0;
    assign wr_data  = ff_q[frd_q];
    assign fifo_pop = wr_dv && wr_dr;

    // ---- PAYREAD port --------------------------------------------------
    // XPay (region/operand fetches) and XRun (UPDATE data words) share
    // the requester; at most one is active at a time.
    assign cr_cpl_ready_o = 1'b1;
    assign cr_req_o = '{op: APU_CMDREC_OP_PAYREAD, cbuf: xf_q.cbuf,
                       idx: pay_adr_q, default: '0};

    assign busy_o    = state_q != XIdle;
    assign done_o    = state_q == XDone;
    assign done_pl_o = '{code: xf_fault_q ? 8'(APU_SH_DONE_FAULT)
                                         : 8'(APU_SH_DONE_OK),
                         wave: '0, pc: '0, robust: '0, work_id: '0};

    // an engine is settled when its completion was seen, it never issued,
    // or it halted on a bus/protocol fault
    logic rd_settled, wr_settled;
    assign rd_settled = rd_done_q || !rd_iss_q || rd_fault;
    assign wr_settled = wr_done_q || !wr_iss_q || wr_fault;

    always_comb begin
      cr_req_valid_o = 1'b0;
      rd_req_v       = 1'b0;
      wr_req_v       = 1'b0;
      if ((state_q == XPay || state_q == XImgRd) && !pay_fly_q)
        cr_req_valid_o = 1'b1;
      if (state_q == XRun && is_upd &&
          (upd_go || (up_ph_q && !pay_fly_q))) cr_req_valid_o = 1'b1;
      if (state_q == XReq && !discard) begin
        rd_req_v = is_rd && !rd_iss_q;
        wr_req_v = !wr_iss_q;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q    <= XIdle;
        xf_q       <= '0;
        fill_q     <= '0;
        pay_fly_q  <= 1'b0;
        pay_half_q <= 1'b0;
        pay_adr_q  <= '0;
        pay_ret_q  <= XIdle;
        pw_q       <= '0;
        hoff_q     <= '0;
        hsz_q      <= '0;
        vi_q       <= '0;
        vj_q       <= '0;
        ei_q       <= '0;
        so_q       <= '0;
        do_q       <= '0;
        sz_q       <= '0;
        os_q       <= '0;
        coff_q     <= '0;
        csz_q      <= '0;
        csent_q    <= '0;
        rem_q      <= '0;
        rd_iss_q   <= 1'b0;
        wr_iss_q   <= 1'b0;
        rd_done_q  <= 1'b0;
        wr_done_q  <= 1'b0;
        xf_fault_q <= 1'b0;
        poison_q   <= 1'b0;
        up_ph_q    <= 1'b0;
        up_lo_q    <= '0;
        up_v_q     <= 1'b0;
        up_frag_q  <= '0;
        fwr_q      <= '0;
        frd_q      <= '0;
        fn_q       <= '0;
        rw_i_q     <= '0;
        rg_n_q     <= '0;
        rg_ret_q   <= XIdle;
        ri_q       <= '0;
        im_acc_q   <= '0;
        im_off_q   <= '0;
        im_pitch_q <= '0;
        im_wm_q    <= '0;
        im_hm_q    <= '0;
        im_m_q     <= '0;
        im_tgt_q   <= '0;
        im_dst_q   <= 1'b0;
        dm_off_q   <= '0;
        dm_pitch_q <= '0;
        dm_wm_q    <= '0;
        dm_hm_q    <= '0;
        r_lay_q    <= '0;
        r_row_q    <= '0;
        r_rows_q   <= '0;
        r_lays_q   <= '0;
        r_sz_q     <= '0;
        c_mip_q    <= '0;
        clr_pat_q  <= '0;
        clr_ci_q   <= '0;
        pass_b_q   <= 1'b0;
        seed_q     <= 1'b0;
        s_rstep_q  <= '0;
        s_ladj_q   <= '0;
        d_rstep_q  <= '0;
        d_ladj_q   <= '0;
        cprog_q    <= '0;
        cpc_q      <= '0;
        cret_q     <= XIdle;
        covf_q     <= 1'b0;
        acc_q      <= '0;
        t0_q       <= '0;
        t1_q       <= '0;
        mrun_q     <= 1'b0;
        ma_q       <= '0;
        mb_q       <= '0;
        mp_q       <= '0;
        mk_q       <= '0;
        mop_q      <= '0;
        mdst_q     <= '0;
        sr_rdy_q   <= 1'b0;
        sr_lin_q   <= '0;
        sr_lo_q    <= '0;
        sr_hi_q    <= '0;
        sr_lut_q   <= '0;
        sr_k_q     <= '0;
        sr_res_q   <= '0;
      end else begin
        // ---- fragment FIFO -------------------------------------------
        if (fifo_push) begin
          ff_q[fwr_q] <= push_frag;
          fwr_q <= fwr_q == FBits'(FifoDepth - 1) ? '0 : fwr_q + 1'b1;
        end
        if (fifo_pop)
          frd_q <= frd_q == FBits'(FifoDepth - 1) ? '0 : frd_q + 1'b1;
        if (fifo_push && !fifo_pop)      fn_q <= fn_q + 1'b1;
        else if (fifo_pop && !fifo_push) fn_q <= fn_q - 1'b1;

        // ---- DMA completions / fault tracking ------------------------
        if (rd_cpl_v) begin
          rd_done_q <= 1'b1;
          if (rd_cpl.status != APU_DMA_OK) begin
            xf_fault_q <= 1'b1;
            poison_q   <= 1'b1;
          end
        end
        if (wr_cpl_v) begin
          wr_done_q <= 1'b1;
          if (wr_cpl.status != APU_DMA_OK) begin
            xf_fault_q <= 1'b1;
            poison_q   <= 1'b1;
          end
        end
        if (rd_fault || wr_fault) begin
          xf_fault_q <= 1'b1;
          poison_q   <= 1'b1;
        end

        unique case (state_q)
          XIdle: begin
            xf_fault_q <= 1'b0;
            if (work_valid_i && work_ready_o) begin
              xf_q   <= xf_i;
              fill_q <= work_i.rec.imm[0];
              coff_q <= '0;
              pay_half_q <= 1'b0;
              pay_fly_q  <= 1'b0;
              pass_b_q   <= 1'b0;
              seed_q     <= 1'b0;
              clr_ci_q   <= '0;
              c_mip_q    <= '0;
              if (poison_q) begin
                // a DMA leg is halted: fail fast rather than hang
                xf_fault_q <= 1'b1;
                state_q    <= XDone;
              end else if (xf_i.op == APU_XFER_OP_COPY) begin
                if (xf_i.regions == 16'h0) begin
                  state_q <= XDone;        // degenerate record: OK
                end else begin
                  vi_q      <= '0;
                  pay_adr_q <= xf_i.pay_base;
                  pay_ret_q <= XVaS;
                  state_q   <= XPay;
                end
              end else if (xf_i.op == APU_XFER_OP_B2I ||
                           xf_i.op == APU_XFER_OP_I2B ||
                           xf_i.op == APU_XFER_OP_I2I) begin
                // §12.3 C/5b: pass A validates every region's bounds
                // before pass B writes anything
                if (xf_i.regions == 16'h0) begin
                  state_q <= XDone;
                end else if (xf_i.op == APU_XFER_OP_I2I &&
                    APU_VN_IMG_BPP[xf_i.img0.fmt[3:0]] !=
                    APU_VN_IMG_BPP[xf_i.img1.fmt[3:0]]) begin
                  // CopyImage requires equal bytes-per-texel
                  xf_fault_q <= 1'b1;
                  state_q    <= XDone;
                end else begin
                  pass_b_q  <= 1'b0;
                  ri_q      <= '0;
                  rw_i_q    <= '0;
                  rg_n_q    <= xf_i.op == APU_XFER_OP_I2I ? 5'd17
                                                          : 5'd14;
                  pay_adr_q <= xf_i.pay_base;
                  rg_ret_q  <= XImgChk;
                  state_q   <= XImgRd;
                end
              end else if (xf_i.op == APU_XFER_OP_CLEARI) begin
                if (xf_i.regions == 16'h0) begin
                  state_q <= XDone;
                end else begin
                  // 4 colour words at the pay base, then 5w ranges
                  rw_i_q    <= '0;
                  rg_n_q    <= 5'd4;
                  pay_adr_q <= xf_i.pay_base;
                  rg_ret_q  <= XClrPat;
                  state_q   <= XImgRd;
                end
              end else begin
                // FILL / UPDATE header {dstOffset, size} at the base
                pay_adr_q <= xf_i.pay_base;
                pay_ret_q <= XHdrA;
                state_q   <= XPay;
              end
            end
          end

          // shared u64 arena fetch: two PAYREADs into pw_q
          XPay: begin
            if (!pay_fly_q) begin
              if (cr_req_ready_i) begin
                pay_fly_q <= 1'b1;
                pay_adr_q <= pay_adr_q + 16'd1;
              end
            end else if (cr_cpl_valid_i) begin
              pay_fly_q <= 1'b0;
              if (cr_cpl_i.status != APU_CMDREC_OK) begin
                xf_fault_q <= 1'b1;
                state_q    <= XDone;
              end else if (!pay_half_q) begin
                pw_q[31:0] <= cr_cpl_i.pdata;
                pay_half_q <= 1'b1;
              end else begin
                pw_q[63:32] <= cr_cpl_i.pdata;
                pay_half_q  <= 1'b0;
                state_q     <= pay_ret_q;
              end
            end
            // a flush waits for an in-flight read to answer, then aborts
            if (flush_i && !(pay_fly_q && !cr_cpl_valid_i)) begin
              pay_fly_q <= 1'b0;
              state_q   <= XAbort;
            end
          end

          // ---- FILL / UPDATE header {dstOffset, size} -----------------
          XHdrA: begin
            hoff_q    <= pw_q;
            pay_ret_q <= XHdrB;
            state_q   <= XPay;
          end
          XHdrB: begin
            hsz_q   <= pw_q;
            state_q <= XHdrChk;
          end
          XHdrChk: begin
            automatic logic [63:0] eff;
            eff = hsz_q;
            if (is_fill && hsz_q == WHOLE)
              eff = hoff_q >= 64'(xf_q.dst_size) ? 64'h0
                    : 64'(xf_q.dst_size) - hoff_q;
            if (hoff_q[1:0] != 2'b00 ||              // dstOffset % 4
                (is_upd && (hsz_q[1:0] != 2'b00 ||   // dataSize % 4
                            hsz_q == 64'h0 || hsz_q > 64'd65536)) ||
                (is_fill && hsz_q != WHOLE && hsz_q[1:0] != 2'b00) ||
                (is_fill && hsz_q == WHOLE && eff[1:0] != 2'b00) ||
                hoff_q > 64'(xf_q.dst_size) ||
                eff > 64'(xf_q.dst_size) - hoff_q) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (eff == 64'h0) begin
              state_q <= XDone;                      // legal no-op
            end else begin
              rem_q     <= eff;
              // UPDATE data words follow the 4-word header
              if (is_upd) pay_adr_q <= xf_q.pay_base + 16'd4;
              rd_iss_q  <= 1'b0;
              rd_done_q <= 1'b1;                     // no read leg
              wr_iss_q  <= 1'b0;
              wr_done_q <= 1'b0;
              csent_q   <= '0;
              coff_q    <= '0;
              fn_q      <= '0; fwr_q <= '0; frd_q <= '0;
              up_ph_q   <= 1'b0;
              up_v_q    <= 1'b0;
              csz_q     <= eff > 64'(ChunkMax) ? 32'(ChunkMax)
                                               : 32'(eff);
              state_q   <= XReq;
            end
          end

          // ---- COPY pass A: bounds + overlap ---------------------------
          // region i: {srcOff, dstOff, size} at pay_base + 6*i
          XVaS: begin
            so_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(vi_q) * 16'd6 + 16'd2;
            pay_ret_q <= XVaD;
            state_q   <= XPay;
          end
          XVaD: begin
            do_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(vi_q) * 16'd6 + 16'd4;
            pay_ret_q <= XVaChk;
            state_q   <= XPay;
          end
          XVaChk: begin
            sz_q <= pw_q;
            if (so_q > 64'(xf_q.src_size) ||
                pw_q > 64'(xf_q.src_size) - so_q ||
                do_q > 64'(xf_q.dst_size) ||
                pw_q > 64'(xf_q.dst_size) - do_q) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (pw_q == 64'h0) begin
              // zero-size region: nothing to overlap or move
              if (vi_q + 16'd1 >= xf_q.regions) begin
                ei_q      <= '0;
                pay_adr_q <= xf_q.pay_base;
                pay_ret_q <= XExS;
                state_q   <= XPay;
              end else begin
                vi_q      <= vi_q + 16'd1;
                pay_adr_q <= xf_q.pay_base +
                             16'(vi_q + 16'd1) * 16'd6;
                pay_ret_q <= XVaS;
                state_q   <= XPay;
              end
            end else begin
              vj_q      <= '0;
              pay_adr_q <= xf_q.pay_base;       // srcOffset[0]
              pay_ret_q <= XOvA;
              state_q   <= XPay;
            end
          end
          // inner overlap loop: src region j x dst region i
          XOvA: begin
            os_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(vj_q) * 16'd6 + 16'd4;
            pay_ret_q <= XOvChk;
            state_q   <= XPay;
          end
          XOvChk: begin
            // pw_q = size_j; reject src_j x dst_i intersection
            if (pw_q != 64'h0 &&
                64'(xf_q.src_base) + os_q <
                    64'(xf_q.dst_base) + do_q + sz_q &&
                64'(xf_q.dst_base) + do_q <
                    64'(xf_q.src_base) + os_q + pw_q) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (vj_q + 16'd1 >= xf_q.regions) begin
              // region i is clean
              if (vi_q + 16'd1 >= xf_q.regions) begin
                ei_q      <= '0;
                pay_adr_q <= xf_q.pay_base;
                pay_ret_q <= XExS;
                state_q   <= XPay;
              end else begin
                vi_q      <= vi_q + 16'd1;
                pay_adr_q <= xf_q.pay_base +
                             16'(vi_q + 16'd1) * 16'd6;
                pay_ret_q <= XVaS;
                state_q   <= XPay;
              end
            end else begin
              vj_q      <= vj_q + 16'd1;
              pay_adr_q <= xf_q.pay_base +
                           16'(vj_q + 16'd1) * 16'd6;
              pay_ret_q <= XOvA;
              state_q   <= XPay;
            end
          end

          // ---- COPY pass B: re-read region ei, then execute ------------
          XExS: begin
            so_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(ei_q) * 16'd6 + 16'd2;
            pay_ret_q <= XExD;
            state_q   <= XPay;
          end
          XExD: begin
            do_q      <= pw_q;
            pay_adr_q <= xf_q.pay_base + 16'(ei_q) * 16'd6 + 16'd4;
            pay_ret_q <= XExChk;
            state_q   <= XPay;
          end
          XExChk: begin
            sz_q <= pw_q;
            if (pw_q == 64'h0) begin
              if (ei_q + 16'd1 >= xf_q.regions) begin
                state_q <= XDone;
              end else begin
                ei_q      <= ei_q + 16'd1;
                pay_adr_q <= xf_q.pay_base +
                             16'(ei_q + 16'd1) * 16'd6;
                pay_ret_q <= XExS;
                state_q   <= XPay;
              end
            end else begin
              coff_q    <= '0;
              csz_q     <= pw_q > 64'(ChunkMax) ? 32'(ChunkMax)
                                                : 32'(pw_q);
              csent_q   <= '0;
              rd_iss_q  <= 1'b0;
              wr_iss_q  <= 1'b0;
              rd_done_q <= 1'b0;
              wr_done_q <= 1'b0;
              fn_q      <= '0; fwr_q <= '0; frd_q <= '0;
              state_q   <= XReq;
            end
          end

          // ---- issue one chunk's DMA requests --------------------------
          XReq: begin
            if (rd_req_v && rd_req_rdy) rd_iss_q <= 1'b1;
            if (wr_req_v && wr_req_rdy) wr_iss_q <= 1'b1;
            if ((!is_rd || rd_iss_q || (rd_req_v && rd_req_rdy)) &&
                (wr_iss_q || wr_req_rdy))
              state_q <= XRun;
          end

          XRun: begin
            // UPDATE word fetch handshakes
            if (upd_go && cr_req_ready_i) begin
              pay_fly_q <= 1'b1;
              pay_adr_q <= pay_adr_q + 16'd1;
            end
            if (up_ph_q && !pay_fly_q && cr_req_ready_i &&
                is_upd) begin
              pay_fly_q <= 1'b1;
              pay_adr_q <= pay_adr_q + 16'd1;
            end
            if (pay_fly_q && cr_cpl_valid_i) begin
              pay_fly_q <= 1'b0;
              if (cr_cpl_i.status != APU_CMDREC_OK) begin
                xf_fault_q <= 1'b1;
              end else if (!up_ph_q) begin
                up_lo_q <= cr_cpl_i.pdata;
                if (upd_n == 4'd8) begin
                  up_ph_q <= 1'b1;              // fetch the second word
                end else begin
                  up_v_q           <= 1'b1;
                  up_frag_q.data   <= {32'h0, cr_cpl_i.pdata};
                  up_frag_q.keep   <= 8'h0f;
                  up_frag_q.offset <= csent_q;
                  up_frag_q.last   <= csent_q + 32'd4 == csz_q;
                end
              end else begin
                up_v_q           <= 1'b1;
                up_frag_q.data   <= {cr_cpl_i.pdata, up_lo_q};
                up_frag_q.keep   <= 8'hff;
                up_frag_q.offset <= csent_q;
                up_frag_q.last   <= csent_q + 32'd8 == csz_q;
                up_ph_q          <= 1'b0;
              end
            end
            if (up_v_q && fifo_space && !discard) begin
              up_v_q  <= 1'b0;
              rem_q   <= rem_q - 64'(upd_n);
              csent_q <= csent_q + 32'(upd_n);
            end
            if (fill_go) begin
              rem_q   <= rem_q - 64'(crem >= 32'd8 ? 8 : 4);
              csent_q <= csent_q + (crem >= 32'd8 ? 32'd8 : 32'd4);
            end
            if (clr_go) begin
              csent_q <= csent_q +
                         (crem >= 32'd8 ? 32'd8 : {29'h0, crem[2:0]});
            end

            // chunk done when both legs completed and the FIFO drained;
            // on fault the halted leg never drains — stranded fragments
            // and a pending update word are discarded instead of blocking
            if (rd_settled && wr_settled && !fifo_push &&
                (fn_q == '0 || xf_fault_q) && (!up_v_q || xf_fault_q)) begin
              if (xf_fault_q) begin
                state_q <= XDone;
              end else if (is_copy && coff_q + 64'(csz_q) < sz_q) begin
                // next chunk of the same region
                coff_q    <= coff_q + 64'(csz_q);
                csz_q     <= sz_q - coff_q - 64'(csz_q) > 64'(ChunkMax)
                             ? 32'(ChunkMax)
                             : 32'(sz_q - coff_q - 64'(csz_q));
                csent_q   <= '0;
                rd_iss_q  <= 1'b0;
                wr_iss_q  <= 1'b0;
                rd_done_q <= 1'b0;
                wr_done_q <= 1'b0;
                state_q   <= XReq;
              end else if (is_copy) begin
                // region done: next region or record done
                if (ei_q + 16'd1 >= xf_q.regions) begin
                  state_q <= XDone;
                end else begin
                  ei_q      <= ei_q + 16'd1;
                  pay_adr_q <= xf_q.pay_base +
                               16'(ei_q + 16'd1) * 16'd6;
                  pay_fly_q <= 1'b0;
                  pay_ret_q <= XExS;
                  state_q   <= XPay;
                end
              end else if (is_img &&
                           coff_q + 64'(csz_q) < 64'(r_sz_q)) begin
                // next chunk of a >ChunkMax image row
                coff_q    <= coff_q + 64'(csz_q);
                csz_q     <= 64'(r_sz_q) - coff_q - 64'(csz_q) >
                             64'(ChunkMax) ? 32'(ChunkMax)
                             : 32'(64'(r_sz_q) - coff_q - 64'(csz_q));
                csent_q   <= '0;
                rd_iss_q  <= 1'b0;
                wr_iss_q  <= 1'b0;
                rd_done_q <= 1'b0;
                wr_done_q <= 1'b0;
                state_q   <= XReq;
              end else if (is_img) begin
                state_q <= XImgNxt;           // row done
              end else if (rem_q != 64'h0) begin
                // next chunk of the same fill/update
                coff_q    <= coff_q + 64'(csz_q);
                csz_q     <= rem_q > 64'(ChunkMax) ? 32'(ChunkMax)
                                                   : 32'(rem_q);
                csent_q   <= '0;
                wr_iss_q  <= 1'b0;
                wr_done_q <= 1'b0;
                state_q   <= XReq;
              end else begin
                state_q <= XDone;
              end
            end
            if (flush_i) state_q <= XAbort;
          end

          // ---- §12.3 C/5b: image-class records -----------------------
          // stream rg_n words at pay_adr_q into rg_q, then rg_ret_q;
          // pay_adr advances past the region so sequential sweeps keep
          // walking the record
          XImgRd: begin
            if (!pay_fly_q && cr_req_ready_i) pay_fly_q <= 1'b1;
            if (pay_fly_q && cr_cpl_valid_i) begin
              pay_fly_q <= 1'b0;
              if (cr_cpl_i.status != APU_CMDREC_OK) begin
                xf_fault_q <= 1'b1;
                state_q    <= XDone;
              end else begin
                rg_q[rw_i_q] <= cr_cpl_i.pdata;
                pay_adr_q    <= pay_adr_q + 16'd1;
                if (rw_i_q + 5'd1 >= rg_n_q) state_q <= rg_ret_q;
                else                         rw_i_q <= rw_i_q + 5'd1;
              end
            end
            if (flush_i && !(pay_fly_q && !cr_cpl_valid_i)) begin
              pay_fly_q <= 1'b0;
              state_q   <= XAbort;
            end
          end

          // pass A: every region's bounds before a single write
          XImgChk: begin
            automatic logic        v_ok;
            automatic logic [15:0] wm, hm;
            automatic logic [31:0] rl, ih;
            v_ok = 1'b0;
            rl = 32'h0; ih = 32'h0;
            wm = 16'h0;  hm = 16'h0;
            if (is_clr) begin
              // {aspect, baseMip, levelCount, baseLayer, layerCount}
              v_ok = rg_q[0] == 32'd1 &&
                     rg_q[2] >= 32'd1 &&
                     rg_q[1] + rg_q[2] <= 32'(xf_q.img0.mips) &&
                     rg_q[4] >= 32'd1 &&
                     rg_q[3] + rg_q[4] <= 32'(xf_q.img0.layers);
            end else if (is_i2i) begin
              // {srcSub, srcOff, dstSub, dstOff, extent}
              wm = f_mdim(xf_q.img0.w, 5'(rg_q[1][4:0]));
              hm = f_mdim(xf_q.img0.h, 5'(rg_q[1][4:0]));
              v_ok = rg_q[0] == 32'd1 && rg_q[7] == 32'd1 &&
                     rg_q[1] < 32'(xf_q.img0.mips) &&
                     rg_q[8] < 32'(xf_q.img1.mips) &&
                     rg_q[3] >= 32'd1 && rg_q[3] == rg_q[10] &&
                     rg_q[2] + rg_q[3] <= 32'(xf_q.img0.layers) &&
                     rg_q[9] + rg_q[10] <= 32'(xf_q.img1.layers) &&
                     rg_q[6] == 32'h0 && rg_q[13] == 32'h0 &&
                     rg_q[14] >= 32'd1 && rg_q[15] >= 32'd1 &&
                     rg_q[16] == 32'd1 &&
                     rg_q[4] + rg_q[14] <= 32'(wm) &&
                     rg_q[5] + rg_q[15] <= 32'(hm) &&
                     rg_q[11] + rg_q[14] <=
                       32'(f_mdim(xf_q.img1.w, 5'(rg_q[8][4:0]))) &&
                     rg_q[12] + rg_q[15] <=
                       32'(f_mdim(xf_q.img1.h, 5'(rg_q[8][4:0])));
            end else begin
              // B2I/I2B: {bufOff u64, rowLen, imgH, aspect, mip,
              // baseLayer, layerCount, off.xyz, ext.whd}; the buffer
              // operand is the source (B2I) or destination (I2B).  The
              // bufferOffset upper word must be zero — image-class
              // addressing is 32-bit aperture-relative — and the byte
              // need is evaluated by the shared multiplier (CP_NEED),
              // where any product or sum exceeding u32 faults.
              wm = f_mdim(xf_q.img0.w, 5'(rg_q[5][4:0]));
              hm = f_mdim(xf_q.img0.h, 5'(rg_q[5][4:0]));
              rl = crl;
              ih = cih;
              v_ok = rg_q[4] == 32'd1 &&
                     rg_q[5] < 32'(xf_q.img0.mips) &&
                     rg_q[7] >= 32'd1 &&
                     rg_q[6] + rg_q[7] <= 32'(xf_q.img0.layers) &&
                     rg_q[10] == 32'h0 && rg_q[13] == 32'd1 &&
                     rg_q[11] >= 32'd1 && rg_q[12] >= 32'd1 &&
                     rg_q[1] == 32'h0 &&               // bo[63:32] == 0
                     rg_q[8] + rg_q[11] <= 32'(wm) &&
                     rg_q[9] + rg_q[12] <= 32'(hm) &&
                     rl >= rg_q[11] && ih >= rg_q[12];
            end
            if (!v_ok) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (is_b2i || is_i2b) begin
              cprog_q <= CP_NEED;
              cpc_q   <= '0;
              covf_q  <= 1'b0;
              mrun_q  <= 1'b0;
              cret_q  <= XImgChkN;
              state_q <= XCalc;
            end else begin
              state_q <= XImgChkN;
            end
          end

          // region accepted once the operand bound clears (or the op
          // carries no byte need): advance to the next region, or
          // start pass B once every region checked clean
          XImgChkN: begin
            if ((is_b2i || is_i2b) &&
                acc_q > (is_b2i ? xf_q.src_size : xf_q.dst_size)) begin
              xf_fault_q <= 1'b1;
              state_q    <= XDone;
            end else if (ri_q + 16'd1 >= xf_q.regions) begin
              // all regions clean: pass B re-reads region 0
              pass_b_q  <= 1'b1;
              ri_q      <= '0;
              rw_i_q    <= '0;
              c_mip_q   <= '0;
              pay_adr_q <= is_clr ? xf_q.pay_base + 16'd4
                                  : xf_q.pay_base;
              rg_ret_q  <= is_clr ? XClrMip : XImgGo;
              state_q   <= XImgRd;
            end else begin
              ri_q   <= ri_q + 16'd1;
              rw_i_q <= '0;
              state_q <= XImgRd;
            end
          end

          // shared-multiplier micro-step: SET/ADD/SUB retire in one
          // cycle, multiply-class steps take MulSteps radix cycles.
          // A >32-bit product or sum latches covf_q; the program's END
          // step turns it into the record's validation fault.
          XCalc: begin
            automatic logic [18:0] u;
            automatic logic [31:0] av, bv, dv;
            automatic logic [32:0] s33;
            automatic logic [63:0] mn;
            u  = f_uop(cprog_q, cpc_q);
            av = f_cop(u[11:6]);
            bv = f_cop(u[5:0]);
            dv = f_cdst(u[15:12]);
            if (mrun_q) begin
              mn = mp_q + ((64'(ma_q[MulRadixBits-1:0]) * mb_q)
                           << (mk_q * MulRadixBits));
              mp_q <= mn;
              ma_q <= ma_q >> MulRadixBits;
              if (mk_q == 6'(MulSteps - 1)) begin
                mrun_q <= 1'b0;
                cpc_q  <= cpc_q + 6'd1;
                if (mop_q == COP_MUL) begin
                  if (mn[63:32] != 32'h0) covf_q <= 1'b1;
                  f_cwb(mdst_q, mn[31:0]);
                end else if (mop_q == COP_MULNF) begin
                  f_cwb(mdst_q, mn[31:0]);
                end else begin
                  s33 = 33'(f_cdst(mdst_q)) + 33'(mn[31:0]);
                  if (mn[63:32] != 32'h0 || s33[32])
                    covf_q <= 1'b1;
                  f_cwb(mdst_q, s33[31:0]);
                end
              end else begin
                mk_q <= mk_q + 6'd1;
              end
            end else if (u[18:16] == COP_END) begin
              if (covf_q) begin
                xf_fault_q <= 1'b1;
                state_q    <= XDone;
              end else begin
                state_q <= cret_q;
              end
            end else if (u[18:16] == COP_SET) begin
              f_cwb(u[15:12], av);
              cpc_q <= cpc_q + 6'd1;
            end else if (u[18:16] == COP_ADD) begin
              s33 = 33'(dv) + 33'(av);
              if (s33[32]) covf_q <= 1'b1;
              f_cwb(u[15:12], s33[31:0]);
              cpc_q <= cpc_q + 6'd1;
            end else if (u[18:16] == COP_SUB) begin
              if (av > dv) covf_q <= 1'b1;          // underflow
              f_cwb(u[15:12], dv - av);
              cpc_q <= cpc_q + 6'd1;
            end else begin
              ma_q   <= av;
              mb_q   <= bv;
              mp_q   <= '0;
              mk_q   <= '0;
              mop_q  <= u[18:16];
              mdst_q <= u[15:12];
              mrun_q <= 1'b1;
            end
          end

          // pass B region entry: start the mip-offset walk
          XImgGo: begin
            im_m_q   <= '0;
            im_acc_q <= '0;
            im_dst_q <= 1'b0;
            seed_q   <= 1'b1;
            im_tgt_q <= is_i2i ? 5'(rg_q[1][4:0]) : 5'(rg_q[5][4:0]);
            state_q  <= XImgMip;
          end

          // CLEAR range entry: re-walk for baseMip + c_mip
          XClrMip: begin
            im_m_q   <= '0;
            im_acc_q <= '0;
            im_dst_q <= 1'b0;
            seed_q   <= 1'b1;
            im_tgt_q <= 5'(rg_q[1][4:0]) + {1'b0, c_mip_q};
            state_q  <= XImgMip;
          end

          // mip_off[m] accumulation — captures {off, pitch, w, h} at
          // the target level; each level's pitch*h term accumulates
          // through the shared multiplier (CP_MIP).  I2I walks the
          // destination image second.
          XImgMip: begin
            automatic logic [15:0] iw, ih2, wm2;
            automatic logic [31:0] pt;
            automatic logic [4:0]  nm;
            iw   = cwl_iw;
            ih2  = cwl_ih;
            wm2  = f_mdim(iw, im_m_q);
            pt   = f_mpitch(iw, im_dst_q ? xf_q.img1.fmt
                                         : xf_q.img0.fmt, im_m_q);
            nm   = im_dst_q ? xf_q.img1.mips : xf_q.img0.mips;
            if (im_m_q == im_tgt_q) begin
              if (im_dst_q) begin
                dm_off_q   <= im_acc_q;
                dm_pitch_q <= pt;
                dm_wm_q    <= wm2;
                dm_hm_q    <= cwl_hm;
              end else begin
                im_off_q   <= im_acc_q;
                im_pitch_q <= pt;
                im_wm_q    <= wm2;
                im_hm_q    <= cwl_hm;
              end
            end
            if (im_m_q + 5'd1 >= nm) begin
              // walk done; the layer strides ride the descriptor
              // (img{i}.layer_bytes, resolved at record assembly)
              if (is_i2i && !im_dst_q) begin
                im_dst_q <= 1'b1;
                im_m_q   <= '0;
                im_acc_q <= '0;
                im_tgt_q <= 5'(rg_q[8][4:0]);
              end else begin
                state_q <= XImgNxt;          // seed_q -> row 0
              end
            end else begin
              cprog_q <= CP_MIP;
              cpc_q   <= '0;
              covf_q  <= 1'b0;
              mrun_q  <= 1'b0;
              cret_q  <= XImgMip2;
              state_q <= XCalc;
            end
          end

          XImgMip2: begin
            im_m_q  <= im_m_q + 5'd1;
            state_q <= XImgMip;
          end

          // seed-row bookkeeping runs the op's seed program on the
          // shared multiplier; XSeedR resumes into the row loop
          XSeedR: begin
            csz_q   <= r_sz_q > 32'(ChunkMax) ? 32'(ChunkMax)
                                              : r_sz_q;
            state_q <= XReq;
          end

          // seed row 0 after the mip walk, or advance row/layer/region
          XImgNxt: begin
            automatic logic [64:0] s_n, d_n;
            s_n = 65'h0;
            d_n = 65'h0;
            if (seed_q) begin
              seed_q    <= 1'b0;
              r_row_q   <= '0;
              r_lay_q   <= '0;
              coff_q    <= '0;
              csent_q   <= '0;
              rd_iss_q  <= 1'b0; rd_done_q <= 1'b0;
              wr_iss_q  <= 1'b0; wr_done_q <= 1'b0;
              fn_q      <= '0; fwr_q <= '0; frd_q <= '0;
              cprog_q   <= is_clr ? CP_CLR :
                           is_i2i ? CP_I2I :
                           is_b2i ? CP_B2I : CP_I2B;
              cpc_q     <= '0;
              covf_q    <= 1'b0;
              mrun_q    <= 1'b0;
              cret_q    <= XSeedR;
              state_q   <= XCalc;
            end else if (!(r_row_q + 32'd1 >= r_rows_q &&
                           r_lay_q + 32'd1 >= r_lays_q)) begin
              // next row (or next layer's row 0) of this region; a
              // row/layer advance that carries out of u32 faults —
              // sound seeds make that unreachable, but the check is
              // the contract, not the DMA map
              if (r_row_q + 32'd1 < r_rows_q) begin
                s_n = {1'b0, so_q} + 65'(s_rstep_q);
                d_n = {1'b0, do_q} + 65'(d_rstep_q);
                r_row_q <= r_row_q + 32'd1;
              end else begin
                s_n = {1'b0, so_q} + 65'(s_ladj_q);
                d_n = {1'b0, do_q} + 65'(d_ladj_q);
                r_row_q <= '0;
                r_lay_q <= r_lay_q + 32'd1;
              end
              if (s_n[64:32] != 33'h0 || d_n[64:32] != 33'h0) begin
                xf_fault_q <= 1'b1;
                state_q    <= XDone;
              end else begin
                so_q      <= s_n[63:0];
                do_q      <= d_n[63:0];
                coff_q    <= '0;
                csent_q   <= '0;
                rd_iss_q  <= 1'b0; rd_done_q <= 1'b0;
                wr_iss_q  <= 1'b0; wr_done_q <= 1'b0;
                csz_q     <= r_sz_q > 32'(ChunkMax) ? 32'(ChunkMax)
                                                    : r_sz_q;
                state_q   <= XReq;
              end
            end else begin
              // region/range exhausted
              if (is_clr) begin
                if (32'(c_mip_q) + 32'd1 < rg_q[2]) begin
                  c_mip_q <= c_mip_q + 4'd1;
                  state_q <= XClrMip;
                end else if (ri_q + 16'd1 >= xf_q.regions) begin
                  state_q <= XDone;
                end else begin
                  ri_q     <= ri_q + 16'd1;
                  c_mip_q  <= '0;
                  rw_i_q   <= '0;
                  rg_ret_q <= XClrMip;
                  state_q  <= XImgRd;
                end
              end else if (ri_q + 16'd1 >= xf_q.regions) begin
                state_q <= XDone;
              end else begin
                ri_q     <= ri_q + 16'd1;
                rw_i_q   <= '0;
                rg_ret_q <= XImgGo;
                state_q  <= XImgRd;
              end
            end
          end

          // build the repeated-texel pattern for CLEAR, one colour
          // component per cycle; then pass A over the ranges
          XClrPat: begin
            automatic logic [7:0]   attr, bpp;
            automatic logic [3:0]   ncomp;
            automatic logic [31:0]  cw;
            automatic logic [5:0]   cbits;
            automatic logic [3:0]   cj;
            automatic logic         is_alpha, go;
            automatic logic [127:0] cv, tex;
            attr  = APU_VN_IMG_ATTR[xf_q.img0.fmt[3:0]];
            bpp   = APU_VN_IMG_BPP[xf_q.img0.fmt[3:0]];
            ncomp = 4'(attr[2:0]) + 4'd1;
            cbits = 6'({bpp, 3'b0} >>
                    (attr[2:0] == 3'd3 ? 6'd2 :
                     attr[2:0] == 3'd1 ? 6'd1 : 6'd0));
            if (clr_ci_q == 4'd0) begin
              clr_col_q[0] <= rg_q[0];
              clr_col_q[1] <= rg_q[1];
              clr_col_q[2] <= rg_q[2];
              clr_col_q[3] <= rg_q[3];
              clr_pat_q    <= '0;
              sr_rdy_q     <= 1'b0;
            end
            cw = clr_ci_q == 4'd0 ? rg_q[0]
                                  : clr_col_q[clr_ci_q[1:0]];
            // §12.3 C/5b-r2: conversion selects on the format's
            // attribute bits, not the texel byte width — a UINT or
            // FLOAT format stores the VkClearColorValue union words
            // raw; half formats convert fp32->fp16; sRGB encodes the
            // linear colour through the sequential LUT search (RGB
            // components only — alpha stays linear UNORM); every
            // other format clamps round-to-nearest UNORM8.
            is_alpha = ncomp == 4'd4 && clr_ci_q == 4'd3;
            go = 1'b1;
            if (attr[7] && !is_alpha && !attr[3] && !attr[4] &&
                !sr_rdy_q) begin
              // launch the 8-step binary search for this component
              sr_lin_q <= f_f32_l16(cw);
              sr_lo_q  <= '0;
              sr_hi_q  <= 9'd255;
              sr_lut_q <= 16'(APU_SRGB_TO_LIN[0]);
              sr_k_q   <= '0;
              state_q  <= XSrEnc;
              go = 1'b0;
            end
            if (go) begin
              if (attr[3] || attr[4])
                cv = 128'(cw);
              else if (attr[5])
                cv = 128'(32'(f_f32_f16(cw)));
              else if (attr[7] && !is_alpha)
                cv = 128'(32'(sr_res_q));
              else
                cv = 128'(32'(f_f32_u8(cw)));
              // BGRA storage swaps colour components 0/2
              cj  = attr[6] && clr_ci_q < 4'd3 ? 4'd2 - clr_ci_q
                                               : clr_ci_q;
              tex = (clr_ci_q == 4'd0 ? 128'h0 : clr_pat_q) |
                    (cv << ({2'h0, cj, 3'b0} << cbits[5:4]));
              sr_rdy_q <= 1'b0;
              if (clr_ci_q + 4'd1 >= ncomp) begin
                clr_pat_q <= f_rep16(tex, f_l2(bpp));
                ri_q      <= '0;
                rw_i_q    <= '0;
                c_mip_q   <= '0;
                pass_b_q  <= 1'b0;
                rg_n_q    <= 5'd5;
                pay_adr_q <= xf_q.pay_base + 16'd4;
                rg_ret_q  <= XImgChk;
                state_q   <= XImgRd;
              end else begin
                clr_pat_q <= tex;
                clr_ci_q  <= clr_ci_q + 4'd1;
              end
            end
          end

          // sRGB encode: one LUT binary-search step per cycle — the
          // same "nearest entry, ties upward" rule as
          // srgb_lut.py::lin16_to_srgb8; at k==7 the final table
          // entry breaks the tie against LUT[lo+1]
          XSrEnc: begin
            automatic logic [8:0]  mid, flo;
            automatic logic [15:0] lv, flut, lup;
            mid  = (sr_lo_q + sr_hi_q + 9'd1) >> 1;
            lv   = 16'(APU_SRGB_TO_LIN[mid[7:0]]);
            flo  = lv <= sr_lin_q ? mid : sr_lo_q;
            flut = lv <= sr_lin_q ? lv : sr_lut_q;
            lup  = 16'(APU_SRGB_TO_LIN[flo[7:0] + 8'd1]);
            if (sr_k_q == 3'd7) begin
              if (flo == 9'd255 ||
                  17'(lup) - 17'(sr_lin_q) >
                  17'(sr_lin_q) - 17'(flut))
                sr_res_q <= 8'(flo);
              else
                sr_res_q <= 8'(flo + 9'd1);
              sr_rdy_q <= 1'b1;
              state_q  <= XClrPat;
            end else begin
              sr_k_q <= sr_k_q + 3'd1;
              if (lv <= sr_lin_q) begin
                sr_lo_q  <= mid;
                sr_lut_q <= lv;
              end else begin
                sr_hi_q <= mid - 9'd1;
              end
            end
          end

          // done pulse; cmdexec sees work_done_i for one cycle
          XDone: state_q <= XIdle;

          // engine reset: cancel both legs, drain to idle or halt
          XAbort: begin
            fn_q      <= '0; fwr_q <= '0; frd_q <= '0;
            up_ph_q   <= 1'b0; up_v_q <= 1'b0;
            pay_fly_q <= 1'b0;
            if ((rd_idle || rd_fault) && (wr_idle || wr_fault) &&
                !rd_cpl_v && !wr_cpl_v)
              state_q <= XIdle;
          end

          default: state_q <= XIdle;
        endcase

        // a flush outside XRun/XPay/XAbort still aborts cleanly
        if (flush_i && state_q != XRun && state_q != XPay &&
            state_q != XAbort && state_q != XIdle)
          state_q <= XAbort;
      end
    end

    assign work_ready_o = state_q == XIdle && !flush_i;

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cr_req_valid_o && !cr_req_ready_i |=>
        cr_req_valid_o && $stable(cr_req_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      rd_req_v && !rd_req_rdy |=> rd_req_v && $stable(rd_req));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_req_v && !wr_req_rdy |=> wr_req_v && $stable(wr_req));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fifo_push |-> fn_q < (FBits+1)'(FifoDepth));
    `endif
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_xfer_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter apu_cfg_t    ApuCfg = ApuVenus,
  parameter int unsigned FifoDepth = 32
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_xfer_desc_t    xf_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  output logic              cr_req_valid_o,
  input  logic              cr_req_ready_i,
  output apu_cmdrec_req_t   cr_req_o,
  input  logic              cr_cpl_valid_i,
  output logic              cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t   cr_cpl_i,
  input  logic [63:0]       ap_base_i,
  input  logic              flush_i,
  output logic              busy_o,
  output apu_dma_axi_req_t  axi_req_o,
  input  apu_dma_axi_resp_t axi_rsp_i
);
  g6lc_apu_xfer #(.Enable(Enable), .ApuCfg(ApuCfg),
                  .FifoDepth(FifoDepth)) i_dut (.*);
endmodule
