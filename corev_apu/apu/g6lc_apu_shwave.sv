// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// ShaderCore wave engine (g6lc_apu_shwave) — §7a/§7c of
// architecture/uncore/apu-vulkan-engine.md.  Executes the committed
// SPIR-V subset of a module over ShaderLanes × ShaderVec SIMT lanes,
// one wave at a time and one instruction at a time (fetch → decode →
// operand read → execute → writeback; no overlap, no bypass).
// Register file, scratch and Workgroup slab are tc_sram; storage
// buffers live behind one 64-bit word memory port with
// robustBufferAccess semantics (out-of-range load → 0, store →
// dropped, counted in done_pl_o.robust).
//
// §7c: per-wave control state (pc, lane mask, prev_blk, pending
// targets) and a CfDepth reconvergence stack implement structured
// control flow under the pending-lane rule; a per-workgroup scheduler
// runs the waves round-robin at instruction granularity so
// OpControlBarrier is a rendezvous (finished waves count arrived).
// OpPhi reads a per-phi {parent,value} table written by shmod.
// Matrix ops are lane micro-sequences over the OpDot fold
// (MatHelperEn exists for §8 but instantiates nothing in 4b).
//
// FP32 arithmetic uses the proven IEEE units: fpnew_fma ×32
// (lane × component), fpnew_divsqrt_multi ×8 iterated per component,
// fpnew_cast_multi ×8, fpnew_noncomp ×8.  Integer ops are plain logic
// with a shared restoring divider per lane.  Every unit/memory wait
// is bounded by WaitBound and ShaderBudget caps instructions per
// wave; both end the dispatch with a fault instead of hanging.
//
// Pointer values travel as vec4 rows: comp0 = byte offset inside the
// storage space, comp1 = tag {flags[3:0], binding[7:0], set[7:0],
// builtin[7:0], storage[3:0]}, comps 2-3 = 0.  Enable=0 ties every
// output off with no datapath.
//
// Determinant/MatrixInverse run a stored-program micro-sequence read
// from DM_PROG in include/g6lc_apu_dmprog.svh — a generated file
// (tools/shader/gen_dmprog.py; `gen_dmprog.py --check` is the
// run-apu-regress.sh `dmprog` freshness suite).

module g6lc_apu_shwave
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderLanes   = 8,
  parameter int unsigned ShaderVec     = 4,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000,
  parameter int unsigned WaitBound     = 32'd4096,
  parameter int unsigned CfDepth       = 8,
  parameter int unsigned CallDepth     = 8,     // G3a-i call-stack bound
  parameter bit          MatHelperEn   = 1'b0   // §8 — unused in 4b
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  // dispatch (single-cycle strobe; only while !busy_o)
  input  logic         disp_i,
  input  apu_sh_dispatch_t disp_pl_i,
  input  apu_sh_desc_t desc_i,         // §12.3 F5 descriptor sideband
  input  logic [5:0]   push_n_i,       // valid push words (0..32)
  input  logic [1023:0] push_i,        // push-constant block
  output logic         busy_o,
  output logic         done_o,
  output apu_sh_done_t done_pl_o,
  // shmod read ports (rd_slot_o selects the slot; 1-cycle latency)
  output logic [2:0]   rd_slot_o,
  output logic [15:0]  prog_addr_o,
  input  logic [31:0]  prog_data_i,
  output logic [9:0]   type_id_o,
  input  logic [95:0]  type_data_i,
  output logic [9:0]   const_id_o,
  input  logic [511:0] const_data_i,
  output logic [9:0]   memb_id_o,
  input  logic [63:0]  memb_data_i,
  output logic [9:0]   rm_id_o,
  input  logic [31:0]  rm_data_i,
  output logic [9:0]   init_id_o,
  input  logic [63:0]  init_data_i,
  output logic [9:0]   blk_id_o,
  input  logic [31:0]  blk_data_i,
  output logic [9:0]   phi_id_o,
  input  logic [159:0] phi_data_i,
  // G3a-i: function table row per OpFunction id {nparams[31:28],
  // param-table base [27:16], OpFunction word offset [15:0]}; the
  // param table holds {4'h0, value-rows[11:8], rf row[7:0]} per param
  output logic [9:0]   func_id_o,
  input  logic [31:0]  func_data_i,
  output logic [9:0]   parm_id_o,
  input  logic [15:0]  parm_data_i,
  input  logic [127:0] entry_data_i,
  // guest memory word port (64-bit): request held until mem_ready_i,
  // exactly one mem_rvalid_i response per request (writes included,
  // after the write completes); mem_err_i returns zero data
  output logic         mem_re_o,
  output logic         mem_we_o,
  output logic [63:0]  mem_addr_o,
  output logic [63:0]  mem_wdata_o,
  output logic [7:0]   mem_wstrb_o,
  input  logic         mem_ready_i,
  input  logic         mem_rvalid_i,
  input  logic [63:0]  mem_rdata_i,
  input  logic         mem_err_i,
  // §12.3 3d-d: descriptor records carry a memory handle {gen,slot},
  // not an absolute base — on a record-cache miss the LSU resolves the
  // memory's CURRENT base through a direct-slot ObjTab read (vgtop's
  // 5th, lowest-priority requester).  A dead, generation-mismatched,
  // or unbacked memory resolves to the null record, so relocation and
  // memory free/reuse can never strand a record.
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i
);
  if (!Enable) begin : gen_off
    assign busy_o = 1'b0;   assign done_o = 1'b0;
    assign done_pl_o = '0;
    assign rd_slot_o = '0;  assign prog_addr_o = '0;
    assign type_id_o = '0;  assign const_id_o = '0;
    assign memb_id_o = '0;  assign rm_id_o = '0;
    assign init_id_o = '0;  assign blk_id_o = '0;
    assign phi_id_o = '0;
    assign func_id_o = '0;  assign parm_id_o = '0;
    assign mem_re_o = 1'b0; assign mem_we_o = 1'b0;
    assign mem_addr_o = '0; assign mem_wdata_o = '0;
    assign mem_wstrb_o = '0;
    assign ot_req_valid_o = 1'b0; assign ot_req_o = '0;
    assign ot_cpl_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | disp_i |
                    (|disp_pl_i) | (|desc_i) | (|push_n_i) |
                    (|push_i) | (|prog_data_i) | (|type_data_i) |
                    (|const_data_i) | (|memb_data_i) | (|rm_data_i) |
                    (|init_data_i) | (|blk_data_i) | (|phi_data_i) |
                    (|func_data_i) | (|parm_data_i) |
                    (|entry_data_i) | (|mem_rdata_i) | mem_ready_i |
                    mem_rvalid_i | mem_err_i |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    MatHelperEn;
  end else begin : gen_on
    localparam int unsigned LAN  = ShaderLanes;
    localparam int unsigned VEC  = ShaderVec;
    localparam int unsigned RL   = (MaxWaves > 1) ? $clog2(MaxWaves) : 1;
    localparam int unsigned RI   = $clog2(ShaderRegs);
    localparam int unsigned SCW  = (ScratchBytes > 0) ? ScratchBytes / 4 : 1;
    localparam int unsigned SWD  = MaxWaves * LAN * SCW;
    localparam int unsigned SDW  = (SWD > 1) ? $clog2(SWD) : 1;
    localparam int unsigned SLW  = (SlabBytes > 0) ? SlabBytes / 4 : 1;
    localparam int unsigned SLWA = (SLW > 1) ? $clog2(SLW) : 1;
    localparam int unsigned OPB  = 32;          // operand words/instr
    localparam int unsigned CFD  = (CfDepth > 0) ? CfDepth : 1;

    typedef logic [LAN-1:0][VEC-1:0][31:0] vt_t;

    // ---- SRAMs -------------------------------------------------------------
    logic                  rf_req, rf_we;
    logic [RL+RI-1:0]      rf_addr;
    logic [LAN*VEC*32-1:0] rf_wdata, rf_rdata;
    logic [LAN*VEC*4-1:0]  rf_be;
    logic                  sc_req, sc_we;
    logic [SDW-1:0]        sc_addr;
    logic [31:0]           sc_wdata, sc_rdata;
    logic [3:0]            sc_be;
    logic                  sb_req, sb_we;
    logic [SLWA-1:0]       sb_addr;
    logic [31:0]           sb_wdata, sb_rdata;
    logic [3:0]            sb_be;
    // active-lane mask of the selected wave (§7c): the wave scheduler
    // chooses wave_q; every per-lane loop gates on act_w.
    wire [LAN-1:0] act_w;

    // ---- states --------------------------------------------------------------
    typedef enum logic [7:0] {
      W_IDLE, W_ENT0, W_ENT1, W_IW0, W_IW1,
      W_F0, W_F1, W_LD0, W_LD1,
      W_TY0, W_TY1, W_OT0, W_OT1,
      W_RMI, W_RMC, W_CV0, W_CV1, W_RV0, W_RV1,
      W_CC0, W_CC1, W_PRE, W_TY0A,
      W_EX,
      W_FU0, W_FU1, W_DQ0, W_DQ1, W_CVT0, W_CVT1, W_NC0, W_NC1,
      W_IDIV,
      W_IR0, W_IR1, W_IR2, W_IR3,
      W_RW0, W_RW1,
      W_CHT0, W_CHT1, W_CHM0, W_CHM1, W_CHE0, W_CHE1, W_CHX,
      W_AL0, W_AL1, W_AL2, W_AL3, W_AL4, W_AL5, W_AL6, W_AL7,
      W_LS0, W_LS1, W_LS2, W_SSB, W_SSB1, W_LSA, W_CHFIN,
      W_XCNT, W_XG,
      W_WB, W_NEXT, W_EOW, W_DONE,
      // §7c
      W_SCHED,                          // round-robin wave pick
      W_WG0, W_SCLR,                    // workgroup start / slab clear
      W_SC0,                            // per-lane scratch clear
      W_CF0, W_CF1,                     // control-flow engine/jump
      W_PH0, W_PH1, W_PH2, W_PH3,       // OpPhi operand select
      W_MS0, W_MS1, W_MS2, W_MSQ,       // matrix micro-seq driver
      W_MRD0, W_MRD1,                   // matrix operand column fetch
      W_MWB,                            // matrix result column write
      W_CM0, W_CM1, W_CM2, W_CM3, W_CM4, W_CM5, W_CMW, W_CMF,
      W_MLF, W_MLA,                     // MAT result column flush (load)
      W_SMR0, W_SMR1,                   // MAT store operand column fetch
      W_XC0, W_XC1,                     // MAT composite-extract column read
      // §12.3 F5: memory-resident descriptor resolve (boff CAM ->
      // record cache -> four-beat aperture fetch) shared by the LSU
      // and OpArrayLength, plus the post-resolve bounds-check point
      W_DS0, W_DS1, W_DS2, W_DS3, W_DS4, W_DS5, W_DS6, W_DS7, W_DS8,
      // §12.3 3d-d: record memory-handle resolution — ObjTab READSLOT
      // request (W_DS9) and completion/resolve (W_DSA)
      W_DS9, W_DSA,
      W_LSC,
      // §12.3 C/5b texture path: image ops serialize lanes through a
      // record fetch (DS path), a per-mip layout walk, then a texel
      // loop over the dispatch-scoped texture cache (W_TXF* fill).
      W_TX0, W_TX1, W_TX2, W_TX3, W_TX4,
      W_TXM,                           // mip-layout walk iterator
      // G2b implicit-LOD: quad-lane derivative chain producing λ
      W_TXL0, W_TXL1, W_TXL2, W_TXL3, W_TXL4, W_TXL5, W_TXL6, W_TXL7,
      W_TXL8, W_TXL9, W_TXLA, W_TXLB, W_TXLC,
      W_TXC0, W_TXC0A, W_TXC1, W_TXC1B, W_TXC2, W_TXC3,
                                                 // sampled-coord compute
      W_TXC4, W_TXC5, W_TXC6,
      // G3a-ii texture completion: projected-sample divide (wave-wide
      // preamble), dref clamp/quantize, gather u16->fp result jobs,
      // QueryLod result jobs
      W_TXJ0, W_TXJ1, W_TXS0, W_TXS1, W_TXS2,
      W_TXG0, W_TXG1,
      W_TXQ0, W_TXQ1,
      W_TXB,                           // fetch/read/write bounds+addr
      W_TXT0, W_TXP, W_TXT1, W_TXT2,   // texel fetch: addr/probe/words
      W_TXF0, W_TXF1,                  // 64B cache line fill
      W_TXD,                           // decode texel -> channels
      W_TXA, W_TXA2, W_TXA3, W_TXA4,   // accumulate filtered weight
      W_TXR0, W_TXR1,                  // finalize lane result
      W_TXN,                           // next lane / wave done
      W_TXW0, W_TXW1,                  // image store beats
      W_TXE0, W_TXE1, W_TXE2,          // store encode + sRGB search
      W_TXQ,                           // query results
      // G3a-i: OpFunctionCall — func row fetch, param copy loop,
      // frame push
      W_FN0, W_FN1, W_FN2, W_FN3, W_FN4, W_FN5, W_FN6,
      // OpReturnValue value copy + commit; kill/demote frame drain pop
      W_FR0, W_FR1, W_FRC, W_FRP,
      // FS-out record slot 8 tail write (flags/SampleMask words)
      W_F8A, W_F8B,
      // atomic RMW (sbuf: W_LSC -> W_ATR -> W_ATC -> W_ATW; WG:
      // W_ATS0 -> W_ATS1); both resume at W_LSA
      W_ATR, W_ATC, W_ATW, W_ATS0, W_ATS1,
      W_WB2,                           // second result row (149-152)
      // Determinant/MatrixInverse micro-program (DM_PROG): operand
      // column staging, step issue, step retire, result-row flush
      W_DM0, W_DM1, W_DMS, W_DMN, W_DMF
    } st_e;
    st_e st_q, ret_q;

    // dispatch latches
    logic [2:0]   slot_q;
    logic [15:0]  gx_q, gy_q, gz_q;
    logic [31:0]  wid_q;
    // graphics wave work (G1a): WORK_VS/FS arrive as dispatches whose
    // work_id is the pseudo-ctype and whose imm words carry the record
    // batch; lane l of wave w is record index w*LAN + l
    logic [1:0]   gfx_q;              // APU_SH_GFX_*
    logic [31:0]  gcnt_q;             // imm[0]: record count
    logic [31:0]  in_base_q;          // imm[1]: input-record base (aperture byte addr)
    logic [31:0]  out_base_q;         // imm[2]: output-record base
    logic [31:0]  vbase_q;            // imm[3]: first vertex index
    logic [31:0]  inst_q;             // imm[4]: instance index
    // G2b: FS waves carry the primitive's front-facing bit in
    // imm[3].0 (vbase is a VS-only field); FrontFacing reads it
    logic         frontf_q;
    // G2b: quad-lane derivative remap state — dla/dlb select the
    // source lanes for the minuend/subtrahend of a derivative job,
    // dva_q picks which operand slot they read (0 for OpDPdx-family,
    // 1 for the texcoord operand of implicit-LOD)
    logic [2:0]   dla_q, dlb_q;
    logic [1:0]   dva_q;
    wire  [31:0]  gfx_istr = (gfx_q == APU_SH_GFX_VS)
                           ? 32'(APU_SH_ATTR_STRIDE) : 32'(APU_SH_VARY_STRIDE);
    wire  [31:0]  gfx_ostr = (gfx_q == APU_SH_GFX_VS)
                           ? 32'(APU_SH_VARY_STRIDE) : 32'(APU_SH_ATTR_STRIDE);
    // F5: desc_i is NOT latched — cmdexec holds desc_o stable from
    // dispatch until work_done (StDsDone blocks on work_done_i), so a
    // second ~5.3 kbit copy here would be dead area
    logic [31:0]  push_q [32];
    logic [5:0]   push_n_q;
    // F5 descriptor-record fetch: the LSU (W_LS0) and OpArrayLength
    // (W_AL0) enter W_DS0 with the key latched here; the subroutine
    // returns to dret_q with ls_bind/ls_bsz/ls_bok filled.
    st_e          dret_q;
    logic [7:0]   dsc_set_q, dsc_bd_q;
    logic [15:0]  dsc_idx_q;
    apu_sh_bindrow_t dsc_row_q;    // resolved binding row
    logic [63:0]  dsc_addr_q;      // current record beat address
    logic         dsc_err_q;
    // F5 descriptor cache: key {idx,binding,set}, value {kind,flags,
    // base,size}; invalidated on every dispatch
    logic [APU_DESC_CACHE-1:0]        dc_v_q;
    logic [APU_DESC_CACHE-1:0][25:0]  dc_key_q;
    // 5b: cache value = the full 32-byte record (buffers use w0/w1;
    // image records carry geometry/swizzle/sampler in w2..w6)
    logic [APU_DESC_CACHE-1:0][255:0] dc_val_q;
    logic [2:0]                       dc_vic_q;
    logic [255:0] dsc_rec_q;         // record beats assembled on fill

    // ---- §12.3 C/5b texture path -----------------------------------
    // Dispatch-scoped texel cache: TexCacheLines x 64B lines in tc_sram,
    // tags in flops; invalidated on every dispatch.  Mip offsets come
    // from a <=13-step walk (pitch = align(w_m*bpp,64)).
    localparam int TexCacheLines = 16;
    logic [255:0]  tx_rec_q;          // current lane's image record
    logic [63:0]   tx_smp_q;          // {smpw1,smpw0} for this access
    logic          tx_smpok_q;        // sampler half resolved
    logic          tx_full_q;         // DS fill also lands in tx_rec_q
    // mip walk
    logic [4:0]    tx_mcur_q;         // walk cursor
    logic [4:0]    tx_lvl_q;          // view level count
    logic [4:0]    tx_mt_q, tx_mt1_q; // walk targets (lod, lod+1)
    logic [31:0]   tx_macc_q;         // byte accumulator
    logic [31:0]   tx_pit_q;          // pitch at cursor level
    logic [15:0]   tx_wm_q, tx_hm_q;  // dims at cursor level
    logic [31:0]   tx_laysz_q;        // bytes per array layer
    logic [31:0]   tx_mof0_q, tx_mof1_q; // mip offsets for m0/m1
    logic [31:0]   tx_pit0_q, tx_pit1_q;
    logic [15:0]   tx_w0_q, tx_h0_q, tx_w1_q, tx_h1_q;
    // current-lane integer coords / lod bookkeeping
    logic signed [31:0] tx_iu_q, tx_iv_q;
    logic [15:0]  tx_ly_q;            // array layer
    logic [4:0]   tx_ld_q;            // lod (fetch/query)
    logic [8:0]   tx_fw_q;            // trilinear frac weight 0..256
    // sampled-coordinate intermediates (8.8 fixed per lane)
    logic signed [31:0] tx_su_q [2], tx_sv_q [2];  // per mip m0/m1
    // gather list: up to 8 sample points {mip, border, iu, iv}
    logic [3:0]   tx_gn_q;
    logic [3:0]   tx_gi_q;
    logic signed [31:0] tx_gu_q [8], tx_gv_q [8];
    logic [4:0]   tx_gm_q [8];
    logic [16:0]  tx_gw_q [8];        // weight 0..65536
    logic         tx_gb_q [8];        // border-colour flag
    // per-lane filter accumulator
    logic [39:0]  tx_acc_q [4];       // fixed-point (u16 path)
    logic [39:0]  tx_acc1_q [4];      // second mip level
    logic signed [8:0] tx_lode_q;     // effective lod q4.4 clamped
    logic         tx_lin_q;           // linear filtering selected
    // staging for unit jobs feeding texture operands (single lane —
    // tx_1lane_q restricts unit issue to ls_lane_q)
    logic [31:0]  txfa_q [VEC];
    logic         tx_1lane_q;         // fma/cvt issue only tx_lane
    // texel datapath
    logic [31:0]  tx_ta_q;            // texel byte address
    logic [4:0]   tx_bpp_q;           // bytes per texel
    logic [3:0]   tx_tw_q;            // words consumed in decode
    logic [63:0]  tx_td_q [2];        // raw texel beats (<=16B)
    logic [15:0]  tx_ch_q [4];        // decoded u16 linear channels
    logic [31:0]  tx_fc_q [4];        // decoded fp32 channels
    logic         tx_brd_q;           // current point is border
    logic [3:0]   tx_bcol_q;          // border colour sel (rec w5[16:14])
    logic         tx_bad_q;           // robust-failed (OOB) this op
    // store path
    logic [127:0] tx_stb_q;           // encoded store bytes
    logic [7:0]   tx_se_i_q [4];      // encode: u8 per channel
    logic [15:0]  tx_se_l_q [4];      // encode: lin16 per channel
    logic [2:0]   tx_se_c_q;          // channel cursor
    logic [7:0]   tx_se_lo_q, tx_se_hi_q; // binary search bounds
    // texture cache
    logic [TexCacheLines-1:0]        txc_v_q;
    logic [TexCacheLines-1:0][25:0]  txc_tag_q;   // addr[31:6]
    logic [3:0]                      txc_vic_q;
    logic [3:0]                      txc_hit_q;    // combinational line
    logic                            txc_hit_w;
    logic [2:0]                      txc_fi_q;     // fill beat counter
    logic [3:0]                      txc_ln_q;     // victim line
    logic [31:0]                     txc_addr_q;   // fill beat addr
    logic [7:0]                      txc_aw;       // sram port addr
    logic                            txc_re, txc_we;
    logic [63:0]                     txc_wd;
    logic [7:0]                      txc_be;
    logic [63:0]                     txc_rd;
    logic [7:0]                      tx_wbe_q;     // store byte strobe
    // misc
    logic [3:0]   tx_gi2_q;           // second half cursor
    st_e          tx_mret_q;          // mip-walk return state
    logic         tx_samp_q;          // op needs sampler maths
    logic         tx_isflt_q;         // result channels are fp32
    logic         tx_isint_q;         // raw integer result
    logic         tx_issr_q;          // sRGB format
    logic         tx_isf16_q;         // fp16 channels
    logic [4:0]   tx_nch_q;           // channel count (1/2/4)
    // G3a-ii: dref/proj/gather/qlod sub-op flags + operands
    logic         tx_dref_q;          // compare sample/gather
    logic         tx_gath_q;          // 4-texel footprint, no filter
    logic         tx_qlod_q;          // OpImageQueryLod
    logic         tx_cen_q;           // sampler compareEnable
    logic [2:0]   tx_cmp_q;           // sampler compareOp
    logic [7:0]   tx_msk_q;           // image-operands mask word
    logic         tx_rdy_q;           // dref quantize done this lane
    logic [2:0]   tx_osl_q;           // ConstOffset operand slot (0=none)
    logic [2:0]   tx_bsl_q;           // Bias operand slot (0=none)
    logic [15:0]  tx_r16_q;           // Dref quantized to u16 (UNORM)
    logic [31:0]  tx_qraw_q;          // unclamped λ (QueryLod)
    // entry record
    logic [15:0]  eoff_q, escratch_q;
    logic [7:0]   lx_q, ly_q, lz_q, ninit_q;
    // workgroup/wave iteration
    logic [15:0]  wgx_q, wgy_q, wgz_q;
    logic [RL-1:0] wave_q;
    logic [7:0]   nwaves_q;
    logic [31:0]  tot_q;              // local invocations lx*ly*lz
    // §7c per-wave control state (indexed by wave_q when running)
    logic [15:0]  pc_q    [MaxWaves];
    logic [LAN-1:0] cmask_q [MaxWaves];    // act mask
    assign act_w = cmask_q[wave_q];
    logic [9:0]   cprev_q [MaxWaves][LAN]; // prev block label per lane
    logic [9:0]   ctgt_q  [MaxWaves][LAN]; // pending-group target label
    logic [9:0]   clbl_q  [MaxWaves];      // current block label
    logic [3:0]   cfn_q   [MaxWaves];      // reconvergence stack depth
    logic [1:0]   cfk_q   [MaxWaves][CFD]; // 0 = SEL, 1 = LOOP
    logic [9:0]   cfm_q   [MaxWaves][CFD]; // merge label
    logic [9:0]   cfc_q   [MaxWaves][CFD]; // loop continue label
    logic [LAN-1:0] cfr_q [MaxWaves][CFD]; // resume mask
    logic [LAN-1:0] cfp_q [MaxWaves][CFD]; // pending mask
    logic [LAN-1:0] cfx_q [MaxWaves][CFD]; // loop cont_mask
    // per-wave bookkeeping
    logic [MaxWaves-1:0] wfin_q;      // wave finished
    logic [MaxWaves-1:0] wbar_q;      // wave waiting at OpControlBarrier
    logic [MaxWaves-1:0] wsel_q;      // armed OpSelectionMerge
    logic [9:0]   wselm_q [MaxWaves]; // armed merge label
    logic [15:0]  wsw_q;              // scheduler wave switches
    logic [15:0]  nbar_q;             // OpControlBarrier executions
    logic [15:0]  nmem_q;             // OpMemoryBarrier executions
    // ---- G3a-i: call stack, dead lanes, atomics, det/inv ----------
    // Per-wave call frame stack (parameter CallDepth).  A frame says
    // which lanes are still inside the callee (cfln) and which have
    // already returned or been killed out of it (cfdn) — a lane in
    // cfdn resumes at cfret once cfln drains.  Divergent calls run the
    // callee with the caller's lane mask; lanes parked on the merge
    // label stay in the cf entries (same rule as a divergent branch).
    localparam int unsigned CLD = (CallDepth > 0) ? CallDepth : 1;
    logic [15:0]  cfret_q [MaxWaves][CLD];   // return word offset
    logic [RI-1:0] cres_q [MaxWaves][CLD];   // result RF row base
    logic [3:0]   cresn_q [MaxWaves][CLD];   // result row count
    logic [9:0]   cclbl_q [MaxWaves][CLD];   // caller block label
    logic [LAN-1:0] cfln_q [MaxWaves][CLD];  // lanes inside callee
    logic [LAN-1:0] cfdn_q [MaxWaves][CLD];  // lanes done with callee
    logic [3:0]   ccfn_q  [MaxWaves][CLD];   // cf depth at push: the
                                           // unwind scan never descends
                                           // below the top frame's mark
    logic [4:0]   csp_q   [MaxWaves];        // call-stack depth
    // dead lanes: killed/demoted — registers keep feeding quad
    // derivatives, but stores/image-writes/atomics/record writes are
    // suppressed; a killed lane also leaves the active mask (it joins
    // the top frame's cfdn when inside a callee, else exits the wave)
    logic [LAN-1:0] dead_q  [MaxWaves];
    // FS helper-lane mask from the dispatch record (imm[5],imm[6]):
    // record r of the batch is a helper iff ghelp_q[r]
    logic [63:0]  ghelp_q;
    wire  [LAN-1:0] hlp_w;             // helper bit per current lane
    assign hlp_w = ghelp_q[RL'(wave_q)*LAN +: LAN];
    // OpFunctionCall cursor state
    logic [31:0]  frow_q;              // latched func table row
    logic [3:0]   fpk_q;               // param cursor
    logic [3:0]   fkr_q;               // param row copy cursor
    logic [15:0]  fpr_q;               // latched param table row
    logic [RI-1:0] faidx_q;            // arg rf row base
    logic [1:0]   fatag_q;             // arg tag (const/reg)
    // atomic op bookkeeping
    logic         ls_atom_q;           // in-flight LSU pass is an atomic
    logic         ls_dyn_q;            // reserved: dynamic-indexed store
    logic         ls_ps_q;             // pointer rides va1 (not va0):
                                       // ext ops that store via a ptr
    logic         ls_tsrc_q;           // store data = t1 (Modf/Frexp)
    logic         ls_wbb_q;            // store tail still commits wb
    logic [15:0]  at_op_q;             // opcode of in-flight atomic
    logic [31:0]  at_old_q;            // fetched old word
    logic [31:0]  at_new_q;            // RMW result being written back
    // call result shape (latched at W_TY1 — the frame records it so
    // OpReturnValue copies the right row count into the caller's reg)
    logic [15:0]  rsz_q;               // result type byte size
    logic [3:0]   resn_q;              // result RF row count
    // DM (Determinant/MatrixInverse) micro-program: DM_PROG steps are
    // {fop[1:0], sa{mode,sel}, ca, sb{mode,sel}, cb, dst} executed as
    // scalar fp jobs (comp 0 of every lane); matrix operand columns
    // stage in t0/t1/t2/ma, temps in dtm, inverse elements in dres.
    vt_t          dtm_q [4];           // 16 temps, comp k&3 of dtm[k>>2]
    vt_t          dres_q[4];           // inverse result columns
    logic [8:0]   dmp_q;               // program counter
    logic [2:0]   dmcol_q;             // column fetch/flush cursor
    logic         jneg_q;              // negate fma operand a this job
    logic [1:0]   jca_q, jcb_q, jcc_q; // per-slot comp for cmode==3
    logic [3:0]   jdtx_q;              // dtm/dres index for jdst 4/5
    // FS slot-8 tail write lane/word cursors + data
    logic [3:0]   f8l_q;
    logic [4:0]   f8b_q;               // byte offset within slot 8
    logic [31:0]  f8d_q;               // word being written
    logic         fslate_q;            // entry fs_late (gates the F8 tail)
    // second result row flag (struct {lo,hi} results + ext ops that
    // split their answer across two RF rows)
    logic         wb2_q;
    logic         dmph_q;              // DM phase: 0 stage, 1 flush
    // instruction state
    logic [15:0]  opc_q, wc_q;
    logic [31:0]  ops_q [OPB];
    logic [3:0]   rkind_q;
    logic [2:0]   rcomps_q;
    logic [2:0]   rcols_q;
    logic [9:0]   relem_q;
    logic [4:0]   ncomp_q;
    logic [2:0]   ot_comps_q;
    logic [3:0]   ot_kind_q;
    logic [2:0]   ot_cols_q;
    // operand values / types — G3a-ii: 6 slots (OpImageDrefGather
    // with Lod+ConstOffset carries six operand ids)
    vt_t          va_q [6];
    logic [9:0]   vty_q [6];
    logic [1:0]   otag_q [6];         // operand regmap tag (const/reg)
    logic [RI-1:0] oidx_q [6];        // operand RF row base
    logic [511:0] ocst_q [6];         // operand constant row
    logic [2:0]   nva_q;
    logic [5:0]   vk_q;
    logic [9:0]   res_id_q;
    logic [2:0]   res_slot_q;
    logic [RI-1:0] ridx_q;            // reg idx captured at W_RMC (operand)
    logic [3:0]   raux_q;             // rm_aux captured at W_RMC
    logic [RI-1:0] ir_idx_q;          // same for chain-index resolve
    logic [3:0]   ir_aux_q;
    logic [1:0]   ir_tag_q;
    vt_t          vix_q;          // resolved chain index operand
    // composite construct
    logic [2:0]   ccp_q;          // accumulated comp position
    // §7c OpPhi operand-select walk
    logic [159:0] phr_q;          // latched phi table row
    logic [2:0]   pi_q;           // pair index
    logic [LAN-1:0] phhit_q;      // lanes already resolved
    logic [LAN-1:0] phm_q;        // lanes taking the current pair
    logic [1:0]   phtag_q;
    logic [RI-1:0] phidx_q;
    logic [3:0]   phaux_q;
    // §7c matrix micro-sequence state
    vt_t          ma_q, mb_q;     // operand column staging
    logic [2:0]   mi_q, mk_q, mph_q;
    logic [2:0]   mrr_q;          // result column comps
    logic [2:0]   mrc_q;          // result cols
    logic [2:0]   mkd_q;          // inner (fold) dimension
    logic [2:0]   mac_q, macl_q;  // operand0 col comps / col count
    logic [2:0]   mbc_q, mbcl_q;  // operand1 col comps / col count
    logic [RI-1:0] mrd_q;         // current operand row address
    logic [1:0]   mrds_q;         // operand slot being fetched
    logic         mdst_q;         // fetch dest: 0 ma, 1 mb
    st_e          mret_q;         // seq return state
    // composite-construct flat stream (MAT result)
    logic [2:0]   ccr_q;          // result column cursor
    logic [2:0]   cmj_q, cmc_q;   // operand col / comp cursors
    logic [2:0]   moc_q, mocl_q;  // operand col comps / cols
    // chain walk
    logic [9:0]   cty_q;
    vt_t          poff_q;
    logic [31:0]  ctag_q;
    logic [3:0]   ck_q;
    logic [15:0]  cmstride_q;
    // writeback
    vt_t          wb_q;
    logic [3:0]   wbm_q;
    logic [RI-1:0] wreg_q;
    // micro-op sequencing (unit jobs + ext steps)
    logic [5:0]   xq_q;
    logic [4:0]   xop_q;          // ext inst number / job op
    logic [1:0]   jmode_q;        // 0 fma-vec, 1 dsq, 2 cvt, 3 nc
    logic [6:0]   ja_q, jb_q, jc_q; // {cmode[1:0], src[4:0]}
    logic [2:0]   jdst_q;         // 0 wb, 1 t0, 2 t1, 3 t2, 4 dtm, 5 dres
    vt_t          t0_q, t1_q, t2_q;
    logic [2:0]   tc_q;           // iterating comp for serial units
    logic         jdot_q;         // fma dot-product mode
    logic         jrev_q;         // dot fold reads comp ncomp-1-tc
    logic         jucc_q;         // store to comp ccc_q (swizzled ops)
    // lane/comp masks latched at issue time so the result-wait states can
    // tell a pending unit apart from an idle one (iv deasserts after issue)
    logic [LAN-1:0][3:0] fuact_q;
    logic [LAN-1:0]      dqact_q, cvact_q, ncact_q;
    // per-element accept/done/result latches: the FPnew units have
    // zero output pipe regs (PipeConfig BEFORE), so out_valid is a
    // single-cycle pulse and lanes complete at different times
    // (e.g. NaN early-out vs full iteration in divsqrt).
    logic [LAN-1:0][3:0]       fu_got_q, fu_dn_q;
    logic [LAN-1:0][3:0][31:0] fu_rc_q;
    logic [LAN-1:0]            dq_got_q, dq_dn_q;
    logic [LAN-1:0][31:0]      dq_rc_q;
    logic [LAN-1:0]            cv_got_q, cv_dn_q;
    logic [LAN-1:0][31:0]      cv_rc_q;
    logic [LAN-1:0]            nc_got_q, nc_dn_q;
    logic [LAN-1:0][31:0]      nc_rc_q;
    // LSU
    logic [3:0]   ls_lane_q;
    logic [8:0]   ls_comp_q;          // word cursor (scratch words ≤ SCW)
    logic [2:0]   lcc_q;              // comp within column (MAT)
    logic [2:0]   lrc_q;              // column cursor (MAT)
    logic         ls_mat_q;           // matrix-typed access
    logic [31:0]  ls_off_q;
    logic [3:0]   ls_sc_q;
    logic [7:0]   ls_bi_q;
    logic         ls_store_q;
    logic [63:0]  ls_bind_q;
    logic [31:0]  ls_bsz_q;
    logic         ls_bok_q;
    logic         ls_rec_q;           // graphics record access (no DS resolve)
    logic [63:0]  ls_addr_q;
    // counters / faults
    logic [31:0]  insns_q, robust_q;
    logic [15:0]  wait_q;
    logic [7:0]   done_code_q;
    logic [15:0]  fl_pc_q, fl_wave_q;
    logic [15:0]  init_i_q;
    logic [9:0]   oty_id_q, cmb_q;
    logic [15:0]  al_sz_q, al_off_q, al_st_q;
    logic [6:0]   xnum_q;
    // §7d SFU micro-sequence state: xsub_q selects a shared core
    // (1=exp2, 2=log2, 3=atan, 4=trig; 63=the per-xnum epilogue);
    // xcall_q + xret_q/xret_st_q implement call/return for the
    // Pow/Sinh/Cosh/Tanh wrappers and the implicit-LOD λ call from
    // W_TXL8.  Cleared per instruction at W_NEXT.
    logic [5:0]   xsub_q;
    logic [4:0]   xret_q;
    st_e          xret_st_q;
    logic         xcall_q;
    logic [1:0]   ccc_q;
    // int divider (per lane)
    logic [31:0]  dv_d_q [LAN], dv_q_q [LAN], dv_r_q [LAN];
    logic         dv_as_q [LAN], dv_bs_q [LAN];
    logic [5:0]   dv_i_q;
    logic         dv_sg_q, dv_sr_q, dv_md_q, dv_sm_q, dv_init_q;
    logic [9:0]   ot_elem_q, al_ty_q;

    assign busy_o = st_q != W_IDLE;
    assign done_pl_o = '{code: done_code_q, wave: fl_wave_q,
                        pc: fl_pc_q, robust: robust_q, work_id: wid_q};

    // ---- table read decodes -------------------------------------------------
    wire [3:0]  ty_kind   = type_data_i[3:0];
    wire [2:0]  ty_comps  = type_data_i[7:5];
    wire [2:0]  ty_cols   = type_data_i[10:8];
    wire [9:0]  ty_elem   = type_data_i[24:15];
    wire [15:0] ty_mbase  = type_data_i[47:32];
    wire [15:0] ty_size   = type_data_i[79:64];
    wire [15:0] ty_stride = type_data_i[95:80];
    wire [1:0]  rm_tag    = rm_data_i[31:30];
    wire [3:0]  rm_aux    = rm_data_i[29:26];
    wire [9:0]  rm_tid    = rm_data_i[25:16];
    wire [15:0] rm_idx    = rm_data_i[15:0];
    wire [15:0] iw_idx    = init_data_i[15:0];
    wire [3:0]  iw_sc     = init_data_i[19:16];
    wire [7:0]  iw_bi     = init_data_i[27:20];
    wire [3:0]  iw_fl     = init_data_i[31:28];   // APU_SH_VF_*
    wire [7:0]  iw_set    = init_data_i[39:32];
    wire [7:0]  iw_bd     = init_data_i[47:40];
    wire [15:0] iw_off    = init_data_i[63:48];
    wire [15:0] mb_off    = memb_data_i[15:0];
    wire [15:0] mb_mst    = memb_data_i[31:16];
    // member row: {14'h0, ty[9:0], flags[7:0], mstride[15:0], off[15:0]}
    wire [9:0]  mb_ty     = memb_data_i[49:40];
    wire [7:0]  mb_fl     = memb_data_i[39:32];   // APU_SH_MF_*
    wire [14:0] blk_pc    = blk_data_i[14:0];
    wire        blk_ok    = blk_data_i[15];

    function automatic logic f_nan(input logic [31:0] w);
      f_nan = (w[30:23] == 8'hFF) && (w[22:0] != 0);
    endfunction
    function automatic logic f_inf(input logic [31:0] w);
      f_inf = (w[30:23] == 8'hFF) && (w[22:0] == 0);
    endfunction
    // §7d SFU coefficient block base for the current context: a running
    // core (xsub 1..4) uses its own block; wrapper steps and the
    // xnum-keyed epilogue (xsub 0/63) use the op's xnum block.
    function automatic int unsigned f_sfu_base();
      unique case (xsub_q)
        6'd1:  f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_EXP2_BASE;
        6'd2:  f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_LOG2_BASE;
        6'd3:  f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_ATAN_BASE;
        6'd4:  f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_TRIG_BASE;
        default: unique case (xnum_q)
          7'd17: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_ACOS_BASE;
          7'd19: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_SINH_BASE;
          7'd20: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_COSH_BASE;
          7'd21: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_TANH_BASE;
          7'd22: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_ASINH_BASE;
          7'd23: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_ACOSH_BASE;
          7'd24: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_ATANH_BASE;
          7'd25: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_ATAN2_BASE;
          7'd27: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_EXP_BASE;
          7'd28: f_sfu_base = g6lc_apu_sfu_pkg::APU_SFU_LOG_BASE;
          default: f_sfu_base = 0;
        endcase
      endcase
    endfunction
    function automatic logic [2:0] f_nc(input logic [2:0] c);
      f_nc = (c == 0) ? 3'd1 : c;
    endfunction
    function automatic logic f_has_rty(input logic [15:0] o);
      unique case (o)
        12,61,65,66,68,79,80,81,82,84,86,87,88,95,98,100,103,104,106,
        109,110,111,112,124,126,127,128,
        129,130,131,132,133,134,135,136,137,138,139,142,143,144,145,
        146,147,148,164,165,166,167,168,169,170,171,172,173,174,175,
        176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,
        191,194,195,196,197,198,199,200,
        207,208,209,210,211,212,213,214,215,245,
        // G3a-i: Undef, dynamic vec ops, Carry/Borrow/MulExtended,
        // Any/All/IsNan/IsInf, FRem/FMod, bitfield family, atomics
        // (227-242 minus Store), FunctionCall, IsHelperInvocationEXT
        1,77,78,83,140,141,149,150,151,152,154,155,156,157,
        201,202,203,204,205,
        227,229,230,232,233,234,235,236,237,238,239,240,241,242,
        // G3a-ii: Dref/proj samples, gathers, QueryLod
        89,90,91,92,93,94,96,97,105,
        57,5381:
          f_has_rty = 1'b1;
        default: f_has_rty = 1'b0;
      endcase
    endfunction
    function automatic logic [2:0] f_nva(input logic [15:0] o,
                                         input logic [15:0] wc,
                                         input logic [31:0] oq [OPB]);
      unique case (o)
        62:      f_nva = 3'd2;
        80:      f_nva = (wc > 7) ? 3'd4 : 3'(wc - 3);
        169:     f_nva = 3'd3;
        82:      f_nva = 3'd2;
        12:      f_nva = (wc > 8) ? 3'd3
                       : (wc > 5 ? 3'(wc - 5) : 3'd0);
        61,65,66,68,81,84,109,110,111,112,124,126,127,168,200:
                 f_nva = 3'd1;
        250,251: f_nva = 3'd1;              // cond / selector
        99:      f_nva = 3'd3;              // ImageWrite: img,coord,texel
        95:      f_nva = (wc > 6) ? 3'd3 : 3'd2;  // Fetch: img,coord[,lod]
        88:      f_nva = 3'd3;              // SampleExplicitLod + Lod op
        // G3a-ii: operand counts grow with the image-operands mask —
        // Bias (bit 0) on the implicit forms and gathers; Lod (bit 1)
        // and ConstOffset (bit 3) ids trail the mask word in that order
        87:      f_nva = 3'(3'd2 + ((wc > 5) ? {2'b0, oq[4][3]} +
                                            {2'b0, oq[4][0]} : 4'd0));
        89:      f_nva = 3'(3'd3 + ((wc > 6) ? {2'b0, oq[5][3]} +
                                             {2'b0, oq[5][0]} : 4'd0));
        90:      f_nva = (wc > 8 && (oq[5] & 32'h8) != 0) ? 3'd5 : 3'd4;
        91:      f_nva = 3'(3'd2 + ((wc > 5) ? {2'b0, oq[4][3]} +
                                            {2'b0, oq[4][0]} : 4'd0));
        92:      f_nva = (wc > 6 && (oq[4] & 32'h8) != 0) ? 3'd4 : 3'd3;
        93:      f_nva = 3'(3'd3 + ((wc > 6) ? {2'b0, oq[5][3]} +
                                             {2'b0, oq[5][0]} : 4'd0));
        94:      f_nva = (wc > 8 && (oq[5] & 32'h8) != 0) ? 3'd5 : 3'd4;
        // gather/dref-gather: img,coord,comp|dref + trailing
        // Bias/Lod/ConstOffset ids after the mask word at oq[5]
        96,97:   f_nva = 3'(3'd3 + ((wc > 6) ? {2'b0, oq[5][3]} +
                                             {2'b0, oq[5][1]} +
                                             {2'b0, oq[5][0]} : 4'd0));
        105:     f_nva = 3'd2;              // QueryLod: img,coord
        207,208,209,210,211,212,213,214,215:
               f_nva = 3'd1;              // G2b derivative ops: 1 operand
        86:      f_nva = 3'd2;              // SampledImage: img,smp
        103:     f_nva = 3'd2;              // QuerySizeLod: img,lod
        // G3a-i
        78:      f_nva = 3'd3;              // VectorInsertDynamic
        201:     f_nva = 3'd4;              // BitFieldInsert
        202,203: f_nva = 3'd3;              // BitField(S|U)Extract
        83,154,155,156,157,204,205:
                 f_nva = 3'd1;
        227:     f_nva = 3'd1;              // AtomicLoad: ptr
        230:     f_nva = 3'd3;              // CompExchange: ptr,val,cmp
        228,229,232,233,234,235,236,237,238,239,240,241,242:
                 f_nva = 3'd2;              // atomic: ptr,value
        0,54,56,59,224,225,245,246,247,248,249,253,255,
        1,57,252,254,4416,5380,5381:
                 f_nva = 3'd0;
        default: f_nva = 3'd2;
      endcase
    endfunction
    function automatic logic [31:0] f_opid(input logic [15:0] o,
                                           input logic [2:0] k,
                                           input logic [31:0] oq [OPB]);
      if (o == 62 || o == 99)           f_opid = oq[k];
      else if (o == 250 || o == 251)    f_opid = oq[k];
      else if (o == 95 || o == 88)      // operand mask word at oq[4]
        f_opid = (k == 0) ? oq[2] : (k == 1) ? oq[3] : oq[5];
      else if (o == 90 || o == 94)      // mask at oq[5], lod/offset trail
        f_opid = (k < 3) ? oq[2 + k] : oq[k + 3];
      else if (o == 92)                 // mask at oq[4], lod[,off] trail
        f_opid = (k < 2) ? oq[2 + k] : oq[k + 3];
      else if (o == 87 || o == 91)      // mask at oq[4], Bias at oq[5]
        f_opid = (k < 2) ? oq[2 + k] : oq[k + 3];
      // mask at oq[5]; trailing Lod/ConstOffset ids at oq[6..7]
      // (96 gather: comp is oq[4]; 97 dref-gather: dref is oq[4] —
      // per the grammar it has no Component operand)
      else if (o == 89 || o == 93 || o == 96 || o == 97)
        f_opid = (k < 3) ? oq[2 + k] : oq[k + 3];
      else if (o == 105)                // QueryLod: img,coord
        f_opid = oq[2 + k];
      else if (o == 12)                 f_opid = oq[4 + k];
      else if (o == 228)                // AtomicStore: ptr,scope,sem,val
        f_opid = (k == 0) ? oq[0] : oq[3];
      else if (o >= 227 && o <= 242)    // atomic: ptr, scope, sem,
        f_opid = (k == 0) ? oq[2]       // value[, cmp]
               : (k == 1) ? oq[5] : oq[6];
      else                              f_opid = oq[2 + k];
    endfunction
    function automatic logic [9:0] f_opid10(input logic [15:0] o,
                                            input logic [5:0] k,
                                            input logic [31:0] oq [OPB]);
      f_opid10 = 10'(f_opid(o, k[2:0], oq));
    endfunction
    // builtin value: lane l, builtin bi, vector component c
    function automatic logic [31:0] f_bi(
        input logic [7:0] bi, input logic [3:0] l, input logic [2:0] c);
      logic [31:0] inv, lix, liy, liz;
      begin
        inv = 32'(wave_q) * LAN + l;
        lix = (lx_q == 0) ? 0 : inv % {24'h0, lx_q};
        liy = (lx_q == 0 || ly_q == 0) ? 0
              : (inv / {24'h0, lx_q}) % {24'h0, ly_q};
        liz = (lx_q == 0 || ly_q == 0) ? 0
              : inv / ({24'h0, lx_q} * {24'h0, ly_q});
        unique case (bi)
          APU_SH_BI_GID: unique case (c)
            0: f_bi = (32'(wgx_q) * lx_q) + lix;
            1: f_bi = (32'(wgy_q) * ly_q) + liy;
            2: f_bi = (32'(wgz_q) * lz_q) + liz;
            default: f_bi = 0; endcase
          APU_SH_BI_LID: unique case (c)
            0: f_bi = lix; 1: f_bi = liy; 2: f_bi = liz;
            default: f_bi = 0; endcase
          APU_SH_BI_WGID: unique case (c)
            0: f_bi = {16'h0, wgx_q}; 1: f_bi = {16'h0, wgy_q};
            2: f_bi = {16'h0, wgz_q}; default: f_bi = 0; endcase
          APU_SH_BI_NUMWG: unique case (c)
            0: f_bi = {16'h0, gx_q}; 1: f_bi = {16'h0, gy_q};
            2: f_bi = {16'h0, gz_q}; default: f_bi = 0; endcase
          APU_SH_BI_WGSIZE: unique case (c)
            0: f_bi = {24'h0, lx_q}; 1: f_bi = {24'h0, ly_q};
            2: f_bi = {24'h0, lz_q}; default: f_bi = 0; endcase
          APU_SH_BI_LINDEX: f_bi = (c == 0) ? inv : 0;
          // graphics builtins — VS Input VertexIndex/InstanceIndex are
          // read from record slot 8 at the LSU (G2a); the f_bi arms
          // remain as the compatibility path for callers that still
          // evaluate them without a record context
          APU_SH_BI_VERTEXINDEX:   f_bi = (c == 0) ? vbase_q + inv : 0;
          APU_SH_BI_INSTANCEINDEX: f_bi = (c == 0) ? inst_q : 0;
          // G2b: front-facing rides FS work imm[3].0 (per-primitive
          // flush in rast keeps it constant for the whole batch)
          APU_SH_BI_FRONTFACING:   f_bi = (c == 0)
                                          ? {31'h0, frontf_q} : 0;
          // G3a-i: gl_HelperInvocation — same value OpIsHelperInvocationEXT
          // returns (helper bit or demoted/killed lane)
          APU_SH_BI_HELPER:        f_bi = (c == 0)
                                          ? {31'h0, hlp_w[l] |
                                                    dead_q[wave_q][l]}
                                          : 0;
          default: f_bi = 0;
        endcase
      end
    endfunction
    // ---- §12.3 F5 descriptor resolution helpers ---------------------
    // boff CAM: {set,binding} -> {found, row}; an absent row (count 0)
    // or an out-of-range set is reported as not found
    function automatic logic [49:0] f_brow(input logic [3:0] s,
                                           input logic [7:0] bd);
      f_brow = '0;
      if (s < 4'(APU_DESC_SETS))
        for (int b = 0; b < APU_DESC_BND; b++)
          if (desc_i.boff[s[1:0]][b].count != 16'h0 &&
              desc_i.boff[s[1:0]][b].binding == bd)
            f_brow = {1'b1, desc_i.boff[s[1:0]][b]};
    endfunction
    // record cache: {set[1:0],binding,idx} -> {hit, record[255:0]};
    // invalidated at dispatch
    function automatic logic [256:0] f_dhit(input logic [1:0] s,
                                            input logic [7:0] bd,
                                            input logic [15:0] i);
      f_dhit = '0;
      for (int c = 0; c < APU_DESC_CACHE; c++)
        if (dc_v_q[c] &&
            dc_key_q[c] == {i, bd, s})
          f_dhit = {1'b1, dc_val_q[c]};
    endfunction
    // dynamic-offset table index: row.dynbase + element index,
    // saturating at the APU_DESC_DYN window
    function automatic logic [31:0] f_doff(input logic [1:0] s,
                                           input apu_sh_bindrow_t r,
                                           input logic [15:0] i);
      logic [31:0] di;
      begin
        di = 32'(r.dynbase) + 32'(i);
        f_doff = !r.dyn ? 32'h0 :
                 desc_i.dyn_off[s][di >= 32'(APU_DESC_DYN)
                                  ? 4'(APU_DESC_DYN-1) : di[3:0]];
      end
    endfunction
    // buffer descriptor kinds the LSU may execute (image/sampler
    // kinds write records but stay refused)
    function automatic logic f_buf_kind(input logic [7:0] k);
      f_buf_kind = k == 8'd6 || k == 8'd7 || k == 8'd8 || k == 8'd9;
    endfunction
    // ---- §12.3 C/5b texture helpers ----------------------------------
    // descriptor kind legality per opcode: 0 sampler, 1 combined,
    // 2 sampled, 3 storage
    function automatic logic f_tx_kind(input logic [15:0] o,
                                       input logic [7:0] k);
      unique case (o)
        16'd95:               f_tx_kind = k == 8'd1 || k == 8'd2;
        // G3a-ii: sampled/dref/proj/gather/query-lod all need a
        // combined or sampled-with-sampler record
        16'd87, 16'd88, 16'd89, 16'd90, 16'd91, 16'd92, 16'd93,
        16'd94, 16'd96, 16'd97, 16'd105:
                              f_tx_kind = k == 8'd1 || k == 8'd2;
        16'd98:               f_tx_kind = k == 8'd2 || k == 8'd3;
        16'd99:               f_tx_kind = k == 8'd3;
        16'd103, 16'd104, 16'd106:
                              f_tx_kind = k <= 8'd3;
        default:              f_tx_kind = 1'b0;
      endcase
    endfunction
    // ops that consume the sampler record (filters, bias, lod clamps,
    // address modes, compareEnable/Op — G3a-ii added the dref, proj,
    // gather and query-lod forms)
    function automatic logic f_tx_smp(input logic [15:0] o);
      f_tx_smp = (o == 16'd87 || o == 16'd88 ||
                  (o >= 16'd89 && o <= 16'd94) ||
                  o == 16'd96 || o == 16'd97 || o == 16'd105);
    endfunction
    // address-mode wrap: returns {border, coord[15:0]}; REPEAT=0,
    // MIRRORED_REPEAT=1, CLAMP_TO_EDGE=2, CLAMP_TO_BORDER=3
    function automatic logic [16:0] f_twrap(input logic signed [31:0] i,
                                            input logic [15:0] n,
                                            input logic [2:0] m);
      logic signed [31:0] mm, r;
      begin
        unique case (m)
          3'd0: begin                       // REPEAT
            r = i % $signed({16'h0, n});
            if (r < 0) r = r + $signed({16'h0, n});
            f_twrap = {1'b0, 16'(r)};
          end
          3'd1: begin                       // MIRRORED_REPEAT
            mm = i >= 0 ? i : -i - 32'sd1;
            r  = mm % $signed({17'h0, n, 1'b0});
            if (r >= $signed({16'h0, n})) r = 2 * $signed({16'h0, n})
                                              - 32'sd1 - r;
            f_twrap = {1'b0, 16'(r)};
          end
          3'd2: begin                       // CLAMP_TO_EDGE
            f_twrap = {1'b0, i < 0 ? 16'h0
                       : i >= $signed({16'h0, n})
                         ? n - 16'd1 : 16'(i)};
          end
          default: begin                    // CLAMP_TO_BORDER
            f_twrap = (i < 0 || i >= $signed({16'h0, n}))
                      ? {1'b1, 16'h0} : {1'b0, 16'(i)};
          end
        endcase
      end
    endfunction
    // VkCompareOp on two integer depths (ref vs texel): 0 NEVER,
    // 1 LESS, 2 EQUAL, 3 LESS_OR_EQUAL, 4 GREATER, 5 NOT_EQUAL,
    // 6 GREATER_OR_EQUAL, 7 ALWAYS — the comparison is ref OP texel
    function automatic logic f_dcmp(input logic [15:0] r,
                                    input logic [15:0] t,
                                    input logic [2:0] op);
      unique case (op)
        3'd0:    f_dcmp = 1'b0;
        3'd1:    f_dcmp = r <  t;
        3'd2:    f_dcmp = r == t;
        3'd3:    f_dcmp = r <= t;
        3'd4:    f_dcmp = r >  t;
        3'd5:    f_dcmp = r != t;
        3'd6:    f_dcmp = r >= t;
        default: f_dcmp = 1'b1;
      endcase
    endfunction
    // fp32 compare of the same predicate set (ref vs texel); NaN is
    // unordered — ordered predicates fail, NE succeeds (the fpnew CMP
    // NaN convention used by the 180..191 family)
    function automatic logic f_fcmp32(input logic [31:0] r,
                                      input logic [31:0] t,
                                      input logic [2:0] op);
      logic unr, eq, lt;
      begin
        unr = f_nan(r) || f_nan(t);
        eq  = ~unr & ((r == t) | ((r[30:0] == 0) & (t[30:0] == 0)));
        lt  = ~unr & ~eq &
              (r[31] != t[31] ? r[31]
                              : ((r[30:0] < t[30:0]) ^ r[31]));
        unique case (op)
          3'd0:    f_fcmp32 = 1'b0;
          3'd1:    f_fcmp32 = lt;
          3'd2:    f_fcmp32 = eq;
          3'd3:    f_fcmp32 = lt | eq;
          3'd4:    f_fcmp32 = ~unr & ~lt & ~eq;
          3'd5:    f_fcmp32 = ~eq;
          3'd6:    f_fcmp32 = ~unr & ~lt;
          default: f_fcmp32 = 1'b1;
        endcase
      end
    endfunction
    // exact fp16 -> fp32 widening (every fp16 is fp32-representable)
    function automatic logic [31:0] f_f16_f32(input logic [15:0] h);
      logic [4:0]  e;
      logic [9:0]  m;
      logic [7:0]  ae;
      logic [4:0]  sh;
      begin
        e = h[14:10]; m = h[9:0];
        if (e == 5'h1F)
          f_f16_f32 = {h[15], 8'hFF, 10'(m), 13'h0};
        else if (e == 0) begin
          if (m == 0) f_f16_f32 = {h[15], 31'h0};
          else begin
            // subnormal: normalize into fp32 (exact)
            ae = 8'd113;                    // 127 - 15 + 1 bias walk
            sh = 0;
            for (int i = 9; i >= 0; i--)
              if (m[i] && sh == 0) sh = 5'(9 - i);
            ae = ae - {3'h0, sh};
            f_f16_f32 = {h[15], ae, (10'(m << (sh + 1)) << 13) & 23'h7FFFFF};
          end
        end else
          f_f16_f32 = {h[15], 8'(e + 8'd112), m, 13'h0};
      end
    endfunction
    // fp32 -> fp16 round-nearest-even (storage write path); overflow
    // saturates to inf, nan/inf preserved
    function automatic logic [15:0] f_f32_f16(input logic [31:0] f);
      logic [7:0]   fe;
      logic [23:0]  mn;
      logic [63:0]  fmn, rem;
      logic [5:0]   sh;
      logic [63:0]  r;
      logic         up;
      logic [15:0]  rn;
      begin
        fe = f[30:23];
        mn = {1'b1, f[22:0]};
        if (fe == 8'hFF)
          f_f32_f16 = {f[31], 5'h1F,
                       f[22:0] != 0 ? 10'h200 : 10'h0};
        else if (fe == 8'h00)
          f_f32_f16 = {f[31], 15'h0};   // fp32 subnormal < fp16 min
        else if (fe >= 8'd143)          // e16 >= 31 -> inf
          f_f32_f16 = {f[31], 5'h1F, 10'h0};
        else if (fe >= 8'd113) begin    // fp16 normal: e16 = fe-112
          rn = {f[31], 5'(fe - 8'd112), f[22:13]};
          up = f[12] && (|f[11:0] || f[13]);
          f_f32_f16 = up ? rn + 16'd1 : rn;
        end else begin                 // fp16 subnormal (or underflow)
          sh  = 6'(8'd126 - fe);        // 14..125; >30 always 0
          if (sh > 6'd30) begin
            f_f32_f16 = {f[31], 15'h0};
          end else begin
            fmn = {40'h0, mn};
            r   = fmn >> sh;
            rem = fmn & ((64'h1 << sh) - 64'h1);
            up  = rem > (64'h1 << (sh - 1)) ||
                  (rem == (64'h1 << (sh - 1)) && r[0]);
            if (up) r = r + 64'd1;
            // r now holds the fp16 significand bits; a carry to bit10
            // lands on the smallest normal which is also correct
            f_f32_f16 = {f[31], 15'(r)};
          end
        end
      end
    endfunction
    // border colour (VkSamplerBorderColor sel 3b) as u16 linear or f32
    function automatic logic [15:0] f_bord16(input logic [2:0] b,
                                             input logic [2:0] c);
      f_bord16 = (b == 3'd5 || b == 3'd4) ? 16'hFFFF   // opaque white
               : (b == 3'd2 || b == 3'd3) ? (c == 3 ? 16'hFFFF : 16'h0)
               : 16'h0;                               // transparent
    endfunction
    function automatic logic [31:0] f_bord32(input logic [2:0] b,
                                             input logic [2:0] c);
      f_bord32 = (b == 3'd5 || b == 3'd4) ? 32'h3F80_0000
               : (b == 3'd2 || b == 3'd3) ? (c == 3 ? 32'h3F80_0000
                                                  : 32'h0)
               : 32'h0;
    endfunction
    // clamp fp32 to [0,1] for UNORM/sRGB store encode (NaN -> 0)
    function automatic logic [31:0] f_f01(input logic [31:0] f);
      f_f01 = (f[31] || (f[30:23] == 8'hFF && f[22:0] != 0))
              ? 32'h0
              : (f[30:23] >= 8'd127) ? 32'h3F80_0000 : f;
    endfunction
    // VkComponentSwizzle select: 0 identity, 1 zero, 2 one, 3..6 RGBA
    function automatic logic [2:0] f_swz(input logic [11:0] s,
                                         input logic [1:0] c);
      logic [2:0] w;
      begin
        w = 3'(s >> (3 * c));
        f_swz = (w == 3'd0) ? 3'(3 + c) : w;
      end
    endfunction
    // unit operand source: {cmode[1:0], src[4:0]} → 32-bit operand
    localparam logic [4:0] S_V0 = 0, S_V1 = 1, S_V2 = 2, S_V3 = 3,
                         S_T0 = 4, S_T1 = 5, S_T2 = 6,
                         S_ONE = 7, S_TWO = 8, S_THREE = 9,
                         S_NEG2 = 10, S_ZERO = 11, S_HALF = 12,
                         S_MA = 13, S_MB = 14,         // §7c mat cols
                         S_TX = 15,                    // 5b tex staging
                         S_VDA = 16, S_VDB = 17,       // G2b quad-lane
                         S_AT0 = 18, S_AT1 = 19,       // |t0|,|t1|
                         S_N127 = 20,                  // -127.0f
                         S_DT0 = 21, S_DT1 = 22,       // G3a-i det temps
                         S_DT2 = 23, S_DT3 = 24,
                         S_DR0 = 25, S_DR1 = 26,       // G3a-i inv cols
                         S_DR2 = 27, S_DR3 = 28,
                         S_XK = 29,                    // xk_q literal
                         S_NEG1 = 30,                  // -1.0f
                         S_SFC = 31;                   // §7d SFU coef[base+dx]
    // xk_q: per-extinst literal operand (pack scale factors, etc.),
    // latched at dispatch before the microsequence runs
    logic [31:0]  xk_q;
    // quad-lane remap for derivative ops (G2b): quads are lanes
    // {4k..4k+3} of a wave; sel = 0 self, 1 l|1, 2 l&~1, 3 l|2,
    // 4 l&~2, 5 quad base, 6 base+1, 7 base+2
    function automatic logic [3:0] f_dl(input logic [3:0] l,
                                        input logic [2:0] s);
      logic [3:0] q;
      begin
        q = l & 4'hC;
        unique case (s)
          3'd1:    f_dl = l | 4'd1;
          3'd2:    f_dl = l & 4'hE;
          3'd3:    f_dl = l | 4'd2;
          3'd4:    f_dl = l & 4'hD;
          3'd5:    f_dl = q;
          3'd6:    f_dl = q | 4'd1;
          default: f_dl = q | 4'd2;
        endcase
      end
    endfunction
    function automatic logic [31:0] f_src(input logic [6:0] s,
                                          input logic [3:0] l,
                                          input logic [2:0] c,
                                          input logic [1:0] ci = 0);
      logic [2:0] cc;
      begin
        unique case (s[6:5])
          2'd1: cc = 3'd0;                    // broadcast comp0
          2'd2: cc = jrev_q ? 3'(ncomp_q - 3'd1 - {2'b0, tc_q})
                            : {2'b0, tc_q};   // iterate comp (rev for dot)
          2'd3: cc = {1'b0, ci};              // G3a-i: per-slot comp
          default: cc = c;                    // per-unit comp
        endcase
        unique case (s[4:0])
          S_V0:    f_src = va_q[0][l][cc];
          S_V1:    f_src = va_q[1][l][cc];
          S_V2:    f_src = va_q[2][l][cc];
          S_V3:    f_src = va_q[3][l][cc];
          S_T0:    f_src = t0_q[l][cc];
          S_T1:    f_src = t1_q[l][cc];
          S_T2:    f_src = t2_q[l][cc];
          S_MA:    f_src = ma_q[l][cc];
          S_MB:    f_src = mb_q[l][cc];
          S_DT0:   f_src = dtm_q[0][l][cc];
          S_DT1:   f_src = dtm_q[1][l][cc];
          S_DT2:   f_src = dtm_q[2][l][cc];
          S_DT3:   f_src = dtm_q[3][l][cc];
          S_DR0:   f_src = dres_q[0][l][cc];
          S_DR1:   f_src = dres_q[1][l][cc];
          S_DR2:   f_src = dres_q[2][l][cc];
          S_DR3:   f_src = dres_q[3][l][cc];
          S_TX:    f_src = txfa_q[cc];
          // G2b: quad-lane derivative operands read the remapped lane
          // of operand slot dva_q; an inactive source lane reads 0
          S_VDA:   f_src = act_w[f_dl(l, dla_q)]
                           ? va_q[dva_q][f_dl(l, dla_q)][cc] : 32'h0;
          S_VDB:   f_src = act_w[f_dl(l, dlb_q)]
                           ? va_q[dva_q][f_dl(l, dlb_q)][cc] : 32'h0;
          S_AT0:   f_src = {1'b0, t0_q[l][cc][30:0]};
          S_AT1:   f_src = {1'b0, t1_q[l][cc][30:0]};
          S_N127:  f_src = 32'hC2FE_0000;
          S_ONE:   f_src = 32'h3F80_0000;
          S_TWO:   f_src = 32'h4000_0000;
          S_THREE: f_src = 32'h4040_0000;
          S_NEG2:  f_src = 32'hC000_0000;
          S_HALF:  f_src = 32'h3F00_0000;
          S_NEG1:  f_src = 32'hBF80_0000;
          S_XK:    f_src = xk_q;
          // §7d: SFU coefficient ROM (generated g6lc_apu_sfu_pkg); the
          // block base comes from the running core (xsub 1..4) or, in
          // wrapper/epilogue context, from the op's own xnum block.
          S_SFC:   f_src = g6lc_apu_sfu_pkg::APU_SFU_COEF
                           [f_sfu_base() + 9'(jdtx_q)];
          default: f_src = 32'h0;
        endcase
      end
    endfunction
    // unit job descriptor: jmode 0=fma-vec,1=dsq,2=cvt,3=nc;
    // ac/bc/cc2 = per-slot comp for cmode==3 operands (G3a-i)
    task automatic jset(input logic [1:0] jm, input logic [4:0] xo,
                        input logic [6:0] a, b, c,
                        input logic [2:0] dst, input logic dot,
                        input st_e ret, input logic uccc = 1'b0,
                        input logic rev = 1'b0,
                        input logic [1:0] ac = 0, bc = 0, cc2 = 0,
                        input logic neg = 1'b0, input logic [3:0] dx = 0);
      jmode_q <= jm; xop_q <= xo; ja_q <= a; jb_q <= b; jc_q <= c;
      jdst_q <= dst; jdot_q <= dot; tc_q <= '0; ret_q <= ret;
      jucc_q <= uccc; jrev_q <= rev;
      jca_q <= ac; jcb_q <= bc; jcc_q <= cc2; jneg_q <= neg;
      jdtx_q <= dx;
      fu_got_q <= '0; fu_dn_q <= '0;
      dq_got_q <= '0; dq_dn_q <= '0;
      cv_got_q <= '0; cv_dn_q <= '0;
      nc_got_q <= '0; nc_dn_q <= '0;
      st_q <= (jm == 0) ? W_FU0 : (jm == 1) ? W_DQ0
              : (jm == 2) ? W_CVT0 : W_NC0;
    endtask

    // write unit result into dst register for lane l comp c;
    // G3a-i dsts 4/5 write the DM temp/result banks at jdtx_q
    // ({reg[3:2],comp[1:0]}) — the comp arg is ignored for those
    task automatic jstore(input logic [2:0] dst, input logic [3:0] l,
                          input logic [2:0] c, input logic [31:0] v);
      unique case (dst)
        3'd0: wb_q[l][c] <= v;
        3'd1: t0_q[l][c] <= v;
        3'd2: t1_q[l][c] <= v;
        3'd3: t2_q[l][c] <= v;
        3'd4: dtm_q[jdtx_q[3:2]][l][jdtx_q[1:0]] <= v;
        default: dres_q[jdtx_q[3:2]][l][jdtx_q[1:0]] <= v;
      endcase
    endtask

    // ---------------------------------------------------------------
    // §7d SFU micro-sequences (GLSL.std.450 13..30 + implicit-LOD λ).
    // Four shared cores run over the existing FMA/DIV-SQRT/CAST/NC
    // units with t0..t2 scratch; dres banks carry context words:
    //   xsub 1  exp2:  va0=x  → t0 = 2^x      (clamp [-150,128],
    //                  denormal result via two-step 2^n scale)
    //   xsub 2  log2:  va0=x  → t0 = log2(x)  (dres1=override or the
    //                  all-ones sentinel, dres2[0]=denormal flag,
    //                  dres3=unbiased exponent int)
    //   xsub 3  atan:  va0=z  → t0 = atan(z) signed (dres3[0]=|z|>1)
    //   xsub 4  trig:  va0=x  → t0=sin, t1=cos, quadrant-folded
    //                  (dres0=k int, dres1[0]=nan|inf, va1=r²)
    //   xsub 63: epilogue keyed on xnum_q (tan div, acos/atan2 quadrant
    //            repair, pow special rules, ln2 scale …)
    // A core must preserve va1 when xcall_q (Pow keeps y live); va2/va3
    // are free scratch.  xcall_q=1 returns to the wrapper's step xret_q
    // in state xret_st_q; =0 tail-chains into the epilogue.
    // Coefficients: APU_SFU_COEF via S_SFC — generated by
    // tools/shader/gen_sfu_tables.py, mirrored op-for-op by
    // tools/shader/sfu_tables.py (Gate-1 model).
    task automatic sfu_exit();
      if (xcall_q) begin
        xsub_q  <= 6'd0; xcall_q <= 1'b0;
        xq_q    <= {1'b0, xret_q}; st_q <= xret_st_q;
      end else begin
        xsub_q <= 6'd63; xq_q <= '0; st_q <= W_EX;
      end
    endtask

    task automatic sfu_step();
      if (xsub_q == 6'd63) begin
        // ---------------- per-op epilogues (xnum-keyed) --------------
        unique case (xnum_q)
          7'd14: begin wb_q <= t1_q; st_q <= W_WB; end      // Cos
          7'd15: jset(1, 5'd0, {2'd0, S_T0}, {2'd0, S_T1}, 7'h0, 0,
                      0, W_WB);                           // Tan
          7'd17: unique case (xq_q)                       // Acos +π|x<0
            0: begin
              for (int l = 0; l < LAN; l++)
                for (int c = 0; c < VEC; c++)
                  t1_q[l][c] <= dres_q[0][l][c][31] ? 32'h4049_0FDB
                                                     : 32'h0;
              st_q <= W_XCNT;
            end
            default:
              jset(0, 5'd0, 7'h0, {2'd0, S_T0}, {2'd0, S_T1}, 0, 0,
                   W_WB);
          endcase
          7'd25: unique case (xq_q)                       // Atan2 quad
            0: begin
              for (int l = 0; l < LAN; l++)
                for (int c = 0; c < VEC; c++) begin
                  t1_q[l][c] <= va_q[1][l][c][31]
                                ? (dres_q[0][l][c][31]
                                   ? 32'hC049_0FDB : 32'h4049_0FDB)
                                : 32'h0;
                  dres_q[1][l][c] <= t0_q[l][c];
                  dres_q[2][l][c] <= {31'h0, f_nan(t0_q[l][c])};
                end
              st_q <= W_XCNT;
            end
            1: jset(0, 5'd0, 7'h0, {2'd0, S_T0}, {2'd0, S_T1}, 1, 0,
                    W_XCNT);                             // r += off
            default: begin
              // x >= 0: the model selects r unchanged (an fadd
              // would map -0 + +0 -> +0); x < 0: r +- pi.
              for (int l = 0; l < LAN; l++)
                for (int c = 0; c < VEC; c++)
                  wb_q[l][c] <= dres_q[2][l][c][0]
                                ? ((f_nan(dres_q[0][l][c]) ||
                                    f_nan(va_q[1][l][c]))
                                   ? 32'h7FC0_0000 : 32'h0)
                                : (va_q[1][l][c][31]
                                   ? t0_q[l][c] : dres_q[1][l][c]);
              st_q <= W_WB;
            end
          endcase
          7'd26: begin                                    // Pow rules
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                logic [31:0] xv, yv, r;
                xv = dres_q[0][l][c]; yv = va_q[1][l][c];
                r = t0_q[l][c];
                if (xv[30:0] == 31'h0)
                  r = (yv[30:0] == 31'h0) ? 32'h3F80_0000
                      : yv[31]            ? 32'h7F80_0000
                                          : 32'h0;
                if (xv == 32'h3F80_0000) r = 32'h3F80_0000;
                if (xv[31] && (xv[30:0] != 31'h0)) r = 32'h7FC0_0000;
                if (f_nan(xv) || f_nan(yv))      r = 32'h7FC0_0000;
                wb_q[l][c] <= r;
              end
            st_q <= W_WB;
          end
          // Log/Asinh/Acosh scale by ln2, Atanh by ½ln2 (SFC slot 0)
          7'd28, 7'd22, 7'd23, 7'd24:
            jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_SFC}, 7'h0, 0, 0,
                 W_WB, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0, 4'd0);
          default: begin wb_q <= t0_q; st_q <= W_WB; end
        endcase
      end else unique case (xsub_q)
        // -------------------- exp2 core (xsub 1) ---------------------
        6'd1: unique case (xq_q)
          0: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                  {2'd0, S_V0}, {2'd0, S_SFC}, 7'h0, 1, 0, W_XCNT,
                  1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0, 4'd7);  // min 128
          1: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                  {2'd0, S_T0}, {2'd0, S_SFC}, 7'h0, 1, 0, W_XCNT,
                  1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0, 4'd8);  // max −150
          2: jset(2, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                  {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_XCNT);  // n=floor
          3: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                  {2'd0, S_T1}, 7'h0, 7'h0, 3, 0, W_XCNT);  // nf=i2f
          4: jset(0, 5'd1, 7'h0, {2'd0, S_T0}, {2'd0, S_T2}, 1, 0,
                  W_XCNT);                                  // f=x−nf
          5: jset(0, 5'd2, {2'd0, S_SFC}, {2'd0, S_ONE}, 7'h0, 3, 0,
                  W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                  4'd0);                                    // p = c6
          6,7,8,9,10,11:
            jset(0, 5'd3, {2'd0, S_T2}, {2'd0, S_T0}, {2'd0, S_SFC},
                 3, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                 4'(xq_q - 6'd5));                          // p·f + ck
          12: begin                       // ldexp: 2^n = 2^a·2^b split
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                logic signed [31:0] ni, na, nb;
                ni = $signed(t1_q[l][c]);
                na = (ni < -32'sd126) ? -32'sd126 : ni;
                nb = ni - na;
                t0_q[l][c] <= 32'((na + 32'sd127)) << 23;
                t1_q[l][c] <= 32'((nb + 32'sd127)) << 23;
              end
            st_q <= W_XCNT;
          end
          13: jset(0, 5'd2, {2'd0, S_T2}, {2'd0, S_T0}, 7'h0, 3, 0,
                   W_XCNT);                                 // p·2^a
          14: jset(0, 5'd2, {2'd0, S_T2}, {2'd0, S_T1}, 7'h0, 1, 0,
                   W_XCNT);                                 // ·2^b → t0
          default: begin
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                t0_q[l][c] <= f_nan(va_q[0][l][c])
                              ? 32'h7FC0_0000 : t0_q[l][c];
            sfu_exit();
          end
        endcase
        // -------------------- log2 core (xsub 2) ---------------------
        6'd2: unique case (xq_q)
          0: begin                        // classify + denorm scale
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                logic [31:0] xv;
                logic        dn;
                xv = va_q[0][l][c];
                dn = (xv[30:23] == 8'h0) && (xv[22:0] != 23'h0);
                dres_q[2][l][c] <= {31'h0, dn};
                dres_q[1][l][c] <=
                    f_nan(xv)              ? 32'h7FC0_0000
                  : (xv[30:0] == 31'h0)    ? 32'hFF80_0000   // ±0 → −inf
                  : xv[31]                 ? 32'h7FC0_0000   // x<0 → NaN
                  : (xv[30:23] == 8'hFF)   ? 32'h7F80_0000   // +inf
                                           : 32'hFFFF_FFFF;  // sentinel
                t2_q[l][c] <= dn ? 32'h4B80_0000 : 32'h3F80_0000;
              end
            st_q <= W_XCNT;
          end
          1: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_T2}, 7'h0, 1, 0,
                  W_XCNT);                                  // y=x·2^24?
          2: begin                        // exponent / mantissa split
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                logic [31:0] mm;
                logic        ge;
                mm = {1'b0, 8'd127, t0_q[l][c][22:0]};
                ge = (mm > 32'h3FB5_04F3);                  // > sqrt(2)
                t0_q[l][c] <= mm - (ge ? 32'h0080_0000 : 32'h0);
                dres_q[3][l][c] <=
                  32'($signed({2'b00, t0_q[l][c][30:23]})
                      - 10'sd127
                      - (dres_q[2][l][c][0] ? 10'sd24 : 10'sd0)
                      + (ge ? 10'sd1 : 10'sd0));
              end
            st_q <= W_XCNT;
          end
          3: jset(0, 5'd1, 7'h0, {2'd0, S_T0}, {2'd0, S_ONE}, 3, 0,
                  W_XCNT);                                  // m−1 → t2
          4: jset(0, 5'd0, 7'h0, {2'd0, S_T0}, {2'd0, S_ONE}, 1, 0,
                  W_XCNT);                                  // m+1 → t0
          5: jset(1, 5'd0, {2'd0, S_T2}, {2'd0, S_T0}, 7'h0, 3, 0,
                  W_XCNT);                                  // t → t2
          6: jset(0, 5'd2, {2'd0, S_T2}, {2'd0, S_T2}, 7'h0, 1, 0,
                  W_XCNT);                                  // t² → t0
          7: jset(0, 5'd2, {2'd0, S_SFC}, {2'd0, S_ONE}, 7'h0, 2, 0,
                  W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                  4'd0);                                    // h = c9
          8,9,10,11:
            jset(0, 5'd3, {2'd0, S_T1}, {2'd0, S_T0}, {2'd0, S_SFC},
                 2, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                 4'(xq_q - 6'd7));                          // h·t² + ck
          12: jset(0, 5'd2, {2'd0, S_T1}, {2'd0, S_T2}, 7'h0, 3, 0,
                   W_XCNT);                                 // p = h·t
          13: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                   {2'd0, S_DR3}, 7'h0, 7'h0, 2, 0, W_XCNT); // ef → t1
          14: jset(0, 5'd0, 7'h0, {2'd0, S_T2}, {2'd0, S_T1}, 1, 0,
                   W_XCNT);                                 // p+ef → t0
          default: begin
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                if (dres_q[1][l][c] != 32'hFFFF_FFFF)
                  t0_q[l][c] <= dres_q[1][l][c];
            sfu_exit();
          end
        endcase
        // -------------------- atan core (xsub 3) ---------------------
        6'd3: unique case (xq_q)
          0: begin                        // a=|z|, flag=|z|>1
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                t0_q[l][c]    <= {1'b0, va_q[0][l][c][30:0]};
                dres_q[3][l][c] <=
                  {31'h0, (va_q[0][l][c][30:0] > 31'h3F80_0000)};
              end
            st_q <= W_XCNT;
          end
          1: jset(1, 5'd0, {2'd0, S_ONE}, {2'd0, S_T0}, 7'h0, 2, 0,
                  W_XCNT);                                  // 1/a → t1
          2: begin
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                if (dres_q[3][l][c][0]) t0_q[l][c] <= t1_q[l][c];
            st_q <= W_XCNT;
          end
          3: jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_T0}, 7'h0, 3, 0,
                  W_XCNT);                                  // t²
          4: jset(0, 5'd2, {2'd0, S_SFC}, {2'd0, S_ONE}, 7'h0, 2, 0,
                  W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                  4'd0);                                    // h = h11
          5,6,7,8,9:
            jset(0, 5'd3, {2'd0, S_T1}, {2'd0, S_T2}, {2'd0, S_SFC},
                 2, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                 4'(xq_q - 6'd4));                          // h·t² + ck
          10: jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_T1}, 7'h0, 1, 0,
                   W_XCNT);                                 // p = a·h
          11: jset(0, 5'd3, {2'd0, S_T0}, {2'd0, S_ONE},
                   {2'd0, S_SFC}, 3, 0, W_XCNT,
                   1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b1,
                   4'd6);                                   // π/2 − p
          default: begin                    // range select + sign
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                t0_q[l][c] <=
                  (dres_q[3][l][c][0] ? t2_q[l][c] : t0_q[l][c])
                  ^ {va_q[0][l][c][31], 31'b0};
            sfu_exit();
          end
        endcase
        // -------------------- trig core (xsub 4) ---------------------
        // sin and cos of va0 land in t0/t1; Cody–Waite k·π/2 reduction
        // (CW1..CW3) then two deg-4-in-r² polynomials and a k&3
        // quadrant select.  va1 carries kf then r²; va0 is untouched.
        6'd4: unique case (xq_q)
          0: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_SFC}, 7'h0, 1, 0,
                  W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                  4'd13);                                   // x·2/π
          1: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                  {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_XCNT);  // k
          2: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                  {2'd0, S_T1}, 7'h0, 7'h0, 3, 0, W_XCNT);  // kf
          3: begin
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                dres_q[0][l][c] <= t1_q[l][c];              // k
                va_q[1][l][c]   <= t2_q[l][c];              // kf
                dres_q[1][l][c] <= {31'h0, f_nan(va_q[0][l][c])
                                          | f_inf(va_q[0][l][c])};
              end
            st_q <= W_XCNT;
          end
          // Cody–Waite r = ((x − kf·C1) − kf·C2) − kf·C3, each a fused
          // negate-multiply-add (model fman — single rounding)
          4: jset(0, 5'd3, {2'd0, S_T2}, {2'd0, S_SFC}, {2'd0, S_V0},
                  1, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b1,
                  4'd10);                                   // x−kf·C1
          5: jset(0, 5'd3, {2'd0, S_T2}, {2'd0, S_SFC}, {2'd0, S_T0},
                  1, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b1,
                  4'd11);                                   // −kf·C2
          6: jset(0, 5'd3, {2'd0, S_T2}, {2'd0, S_SFC}, {2'd0, S_T0},
                  1, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b1,
                  4'd12);                                   // −kf·C3
          7: jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_T0}, 7'h0, 3, 0,
                  W_XCNT);                                  // r²
          8: begin
            va_q[1] <= t2_q;                                // r² stash
            st_q <= W_XCNT;
          end
          9: jset(0, 5'd2, {2'd0, S_SFC}, {2'd0, S_ONE}, 7'h0, 2, 0,
                  W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                  4'd0);                                    // S = s4
          10,11,12,13:
            jset(0, 5'd3, {2'd0, S_T1}, {2'd0, S_T2}, {2'd0, S_SFC},
                 2, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                 4'(xq_q - 6'd9));                          // S·r² + ck
          14: jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_T2}, 7'h0, 3, 0,
                   W_XCNT);                                 // r³
          15: jset(0, 5'd3, {2'd0, S_T2}, {2'd0, S_T1}, {2'd0, S_T0},
                   2, 0, W_XCNT);                           // sin_r
          16: jset(0, 5'd2, {2'd0, S_SFC}, {2'd0, S_ONE}, 7'h0, 3, 0,
                   W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                   4'd5);                                   // C = c4
          17,18,19,20:
            jset(0, 5'd3, {2'd0, S_T2}, {2'd0, S_V1}, {2'd0, S_SFC},
                 3, 0, W_XCNT, 1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                 4'(xq_q - 6'd11));                         // C·r² + ck
          21: jset(0, 5'd3, {2'd0, S_V1}, {2'd0, S_T2},
                   {2'd0, S_ONE}, 3, 0, W_XCNT);            // cos_r
          default: begin                    // k&3 quadrant select
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                logic [1:0]  qq;
                logic [31:0] so, co;
                qq = dres_q[0][l][c][1:0];
                unique case (qq)
                  2'd0:    begin so = t1_q[l][c];
                                 co = t2_q[l][c]; end
                  2'd1:    begin so = t2_q[l][c];
                                 co = t1_q[l][c] ^ 32'h8000_0000; end
                  2'd2:    begin so = t1_q[l][c] ^ 32'h8000_0000;
                                 co = t2_q[l][c] ^ 32'h8000_0000; end
                  default: begin so = t2_q[l][c] ^ 32'h8000_0000;
                                 co = t1_q[l][c]; end
                endcase
                t0_q[l][c] <= dres_q[1][l][c][0] ? 32'h7FC0_0000 : so;
                t1_q[l][c] <= dres_q[1][l][c][0] ? 32'h7FC0_0000 : co;
              end
            sfu_exit();
          end
        endcase
        default: sfu_exit();
      endcase
    endtask

    // matrix operand column fetch: stage column `col` of operand slot
    // `s` into ma_q (d=0) or mb_q (d=1); ret is the resume state.
    // For const operands mrd_q carries the flat word base instead.
    task automatic mfetch(input logic [1:0] s, input logic [2:0] col,
                          input logic d, input logic [2:0] cpc,
                          input st_e ret);
      mrds_q <= s; mdst_q <= d; mret_q <= ret;
      mrd_q <= (otag_q[s] == APU_SH_RT_CONST)
               ? RI'(col * cpc)
               : oidx_q[s] + RI'(col);
      st_q <= W_MRD0;
    endtask

    // ---- FPnew units -------------------------------------------------------
    logic [LAN-1:0][VEC-1:0][2:0][31:0] fma_ops;
    fpnew_pkg::operation_e              fma_op;
    logic                               fma_mod;
    logic [LAN-1:0][VEC-1:0]            fma_iv, fma_ir, fma_ov;
    logic [LAN-1:0][VEC-1:0][31:0]      fma_res;
    logic [LAN-1:0][1:0][31:0]          dq_ops;
    fpnew_pkg::operation_e              dq_op;
    logic [LAN-1:0]                     dq_iv, dq_ir, dq_ov;
    logic [LAN-1:0][31:0]               dq_res;
    logic [LAN-1:0][31:0]               cv_ops;
    fpnew_pkg::operation_e              cv_op;
    fpnew_pkg::roundmode_e              cv_rnd;
    logic                               cv_mod;
    logic [LAN-1:0]                     cv_iv, cv_ir, cv_ov;
    logic [LAN-1:0][31:0]               cv_res;
    logic [LAN-1:0][1:0][31:0]          nc_ops;
    fpnew_pkg::operation_e              nc_op;
    fpnew_pkg::roundmode_e              nc_rnd;
    logic                               nc_mod;
    logic [LAN-1:0]                     nc_iv, nc_ir, nc_ov;
    logic [LAN-1:0][31:0]               nc_res;

    // unit operand drive (combinational from job fields)
    always_comb begin
      fma_ops = '0; fma_op = fpnew_pkg::FMADD; fma_mod = 1'b0;
      fma_iv = '0;
      dq_ops = '0; dq_op = fpnew_pkg::DIV; dq_iv = '0;
      cv_ops = '0; cv_op = fpnew_pkg::F2I; cv_rnd = fpnew_pkg::RNE;
      cv_mod = 1'b0; cv_iv = '0;
      nc_ops = '0; nc_op = fpnew_pkg::CMP; nc_rnd = fpnew_pkg::RNE;
      nc_mod = 1'b0; nc_iv = '0;
      unique case (jmode_q)
        2'd0: begin                              // fma vector op
          unique case (xop_q)
            0: fma_op = fpnew_pkg::ADD;
            1: begin fma_op = fpnew_pkg::ADD; fma_mod = 1'b1; end
            2: fma_op = fpnew_pkg::MUL;
            default: fma_op = fpnew_pkg::FMADD;
          endcase
          if (jdot_q)
            fma_op = (tc_q == 0) ? fpnew_pkg::MUL : fpnew_pkg::FMADD;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++) begin
              if (c < ncomp_q) begin
                fma_ops[l][c][0] = f_src(ja_q, 4'(l), 3'(c), jca_q)
                                   ^ {jneg_q, 31'h0};
                fma_ops[l][c][1] = f_src(jb_q, 4'(l), 3'(c), jcb_q);
                fma_ops[l][c][2] = f_src(jc_q, 4'(l), 3'(c), jcc_q);
                fma_iv[l][c] = (st_q == W_FU0) && (act_w[l]) &&
                               !fu_got_q[l][c] &&
                               (jdot_q ? (c == 0) : 1'b1) &&
                               (!tx_1lane_q ||
                                4'(l) == {1'b0, ls_lane_q[2:0]});
              end
            end
        end
        2'd1: begin                              // divsqrt, comp tc
          dq_op = xop_q[0] ? fpnew_pkg::SQRT : fpnew_pkg::DIV;
          for (int l = 0; l < LAN; l++) begin
            dq_ops[l][0] = f_src(ja_q, 4'(l), tc_q, jca_q);
            dq_ops[l][1] = f_src(jb_q, 4'(l), tc_q, jcb_q);
            dq_iv[l] = (st_q == W_DQ0) && (act_w[l]) && !dq_got_q[l] &&
                       (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]});
          end
        end
        2'd2: begin                              // cast, comp tc
          cv_op = xop_q[0] ? fpnew_pkg::I2F : fpnew_pkg::F2I;
          cv_rnd = fpnew_pkg::roundmode_e'(xop_q[3:1]);
          cv_mod = xop_q[4];
          for (int l = 0; l < LAN; l++) begin
            cv_ops[l] = f_src(ja_q, 4'(l), tc_q, jca_q);
            cv_iv[l] = (st_q == W_CVT0) && (act_w[l]) && !cv_got_q[l] &&
                       (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]});
          end
        end
        default: begin                           // noncomp, comp tc
          nc_op = xop_q[0] ? fpnew_pkg::MINMAX : fpnew_pkg::CMP;
          nc_rnd = fpnew_pkg::roundmode_e'(xop_q[3:1]);
          nc_mod = xop_q[4];
          for (int l = 0; l < LAN; l++) begin
            nc_ops[l][0] = f_src(ja_q, 4'(l), tc_q, jca_q);
            nc_ops[l][1] = f_src(jb_q, 4'(l), tc_q, jcb_q);
            nc_iv[l] = (st_q == W_NC0) && (act_w[l]) && !nc_got_q[l] &&
                       (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]});
          end
        end
      endcase
    end

    for (genvar l = 0; l < LAN; l++) begin : g_lane
      for (genvar c = 0; c < VEC; c++) begin : g_comp
        fpnew_fma #(
          .FpFormat(fpnew_pkg::FP32), .NumPipeRegs(1),
          .PipeConfig(fpnew_pkg::BEFORE),
          .TagType(logic), .AuxType(logic)
        ) i_fma (
          .clk_i, .rst_ni,
          .operands_i(fma_ops[l][c]), .is_boxed_i(3'b111),
          .rnd_mode_i(fpnew_pkg::RNE), .op_i(fma_op),
          .op_mod_i(fma_mod), .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
          .in_valid_i(fma_iv[l][c]), .in_ready_o(fma_ir[l][c]),
          .flush_i(1'b0),
          .result_o(fma_res[l][c]), .status_o(),
          .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
          .out_valid_o(fma_ov[l][c]), .out_ready_i(1'b1),
          .busy_o(), .reg_ena_i('0), .early_out_valid_o()
        );
      end
      // E906 fdsu: correctly-rounding SRT div/sqrt (§7a requires
      // bit-exact FDiv; the PULP mvp unit is ~1ulp off on some quotients)
      fpnew_divsqrt_th_32 #(
        .NumPipeRegs(1), .PipeConfig(fpnew_pkg::BEFORE),
        .TagType(logic), .AuxType(logic)
      ) i_dsq (
        .clk_i, .rst_ni,
        .operands_i(dq_ops[l]),
        .is_boxed_i({fpnew_pkg::NUM_FP_FORMATS{2'b11}}),
        .rnd_mode_i(fpnew_pkg::RNE), .op_i(dq_op),
        .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
        .in_valid_i(dq_iv[l]), .in_ready_o(dq_ir[l]),
        .flush_i(1'b0),
        .result_o(dq_res[l]), .status_o(),
        .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
        .out_valid_o(dq_ov[l]), .out_ready_i(1'b1),
        .busy_o(), .reg_ena_i('0), .early_out_valid_o()
      );
      fpnew_cast_multi #(
        // fmt_logic_t is [0:4]: index 0 (FP32) is the MSB;
        // ifmt_logic_t is [0:3]: index 2 (INT32)
        .FpFmtConfig(5'b10000), .IntFmtConfig(4'b0010),
        .NumPipeRegs(1), .PipeConfig(fpnew_pkg::BEFORE),
        .TagType(logic), .AuxType(logic)
      ) i_cvt (
        .clk_i, .rst_ni,
        .operands_i(cv_ops[l]), .is_boxed_i(1'b1),
        .rnd_mode_i(cv_rnd), .op_i(cv_op), .op_mod_i(cv_mod),
        .src_fmt_i(fpnew_pkg::FP32), .dst_fmt_i(fpnew_pkg::FP32),
        .int_fmt_i(fpnew_pkg::INT32),
        .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
        .in_valid_i(cv_iv[l]), .in_ready_o(cv_ir[l]), .flush_i(1'b0),
        .result_o(cv_res[l]), .status_o(),
        .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
        .out_valid_o(cv_ov[l]), .out_ready_i(1'b1),
        .busy_o(), .reg_ena_i('0), .early_out_valid_o()
      );
      fpnew_noncomp #(
        .FpFormat(fpnew_pkg::FP32), .NumPipeRegs(1),
        .PipeConfig(fpnew_pkg::BEFORE),
        .TagType(logic), .AuxType(logic)
      ) i_nc (
        .clk_i, .rst_ni,
        .operands_i(nc_ops[l]), .is_boxed_i(2'b11),
        .rnd_mode_i(nc_rnd), .op_i(nc_op), .op_mod_i(nc_mod),
        .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
        .in_valid_i(nc_iv[l]), .in_ready_o(nc_ir[l]), .flush_i(1'b0),
        .result_o(nc_res[l]), .status_o(),
        .extension_bit_o(), .class_mask_o(), .is_class_o(),
        .tag_o(), .mask_o(), .aux_o(),
        .out_valid_o(nc_ov[l]), .out_ready_i(1'b1),
        .busy_o(), .reg_ena_i('0), .early_out_valid_o()
      );
    end

    // Register file split into two 512-bit halves: Verilator cannot
    // unroll tc_sram's byte-write loop at BeWidth=128 (BLKLOOPINIT
    // silently drops the write), while BeWidth=64 unrolls fine.
    logic [511:0] rf_rdata_lo, rf_rdata_hi;
    assign rf_rdata = {rf_rdata_hi, rf_rdata_lo};
    tc_sram #(.NumWords(MaxWaves * ShaderRegs),
              .DataWidth(LAN * VEC * 16), .NumPorts(1),
              .SimInit("none")) i_rf_lo (
      .clk_i, .rst_ni, .req_i(rf_req), .we_i(rf_we),
      .addr_i(rf_addr), .wdata_i(rf_wdata[511:0]),
      .be_i(rf_be[63:0]), .rdata_o(rf_rdata_lo));
    tc_sram #(.NumWords(MaxWaves * ShaderRegs),
              .DataWidth(LAN * VEC * 16), .NumPorts(1),
              .SimInit("none")) i_rf_hi (
      .clk_i, .rst_ni, .req_i(rf_req), .we_i(rf_we),
      .addr_i(rf_addr), .wdata_i(rf_wdata[1023:512]),
      .be_i(rf_be[127:64]), .rdata_o(rf_rdata_hi));
    tc_sram #(.NumWords(SWD), .DataWidth(32), .NumPorts(1),
              .SimInit("none")) i_scratch (
      .clk_i, .rst_ni, .req_i(sc_req), .we_i(sc_we),
      .addr_i(sc_addr), .wdata_i(sc_wdata), .be_i(sc_be),
      .rdata_o(sc_rdata));
    tc_sram #(.NumWords(SLW), .DataWidth(32), .NumPorts(1),
              .SimInit("none")) i_slab (
      .clk_i, .rst_ni, .req_i(sb_req), .we_i(sb_we),
      .addr_i(sb_addr), .wdata_i(sb_wdata), .be_i(sb_be),
      .rdata_o(sb_rdata));
    // §12.3 C/5b texture cache: TexCacheLines x 64B lines, tags in
    // flops (txc_tag_q); data in one 64b-wide tc_sram so a fill beat
    // lands in one write and a <=8B texel reads one word.
    tc_sram #(.NumWords(TexCacheLines * 8), .DataWidth(64),
              .NumPorts(1), .SimInit("none")) i_texcache (
      .clk_i, .rst_ni, .req_i(txc_re || txc_we), .we_i(txc_we),
      .addr_i(8'(txc_aw)), .wdata_i(txc_wd), .be_i(txc_be),
      .rdata_o(txc_rd));
    // tag probe: which resident line covers tx_ta_q[31:6]
    always_comb begin
      txc_hit_w = 1'b0; txc_hit_q = '0;
      for (int c = 0; c < TexCacheLines; c++)
        if (txc_v_q[c] && txc_tag_q[c] == tx_ta_q[31:6]) begin
          txc_hit_w = 1'b1; txc_hit_q = 4'(c);
        end
    end
    // SRAM port: texel word reads (hit in W_TXT0, second word for 16B
    // texels in W_TXT1) and line-fill writes (one 8B beat per accepted
    // memory response in W_TXF1).  Words are {line, word} addressed.
    always_comb begin
      txc_re = 1'b0; txc_we = 1'b0;
      txc_aw = '0;   txc_wd = mem_rdata_i; txc_be = 8'hFF;
      if (st_q == W_TXP && txc_hit_w) begin
        txc_re = 1'b1;
        txc_aw = {1'b0, txc_hit_q, tx_ta_q[5:3]};
      end else if (st_q == W_TXT1 && tx_bpp_q > 5'd8) begin
        txc_re = 1'b1;
        txc_aw = {1'b0, txc_hit_q, tx_ta_q[5:3] + 3'd1};
      end else if (st_q == W_TXF1 && mem_rvalid_i) begin
        txc_we = 1'b1;
        txc_aw = {1'b0, txc_ln_q, txc_fi_q};
      end
    end

    // ---- shmod read port addresses ------------------------------------------
    logic [15:0] pa_w;
    logic [9:0]  ty_w, rm_w, mb_w, fn_w, pt_w;
    logic [9:0]  cty2_q, al_ty2_q;
    // OpPhi pair decode (combinational; used by W_PH1 and the rm port)
    wire [4:0]   ph_npi = phr_q[4:0];
    wire [15:0]  phv_c  = (pi_q < ph_npi[2:0]) ? phr_q[32*pi_q + 32 +: 16]
                                               : phr_q[47:32];
    wire [15:0]  php_c  = phr_q[32*pi_q + 48 +: 16];
    always_comb begin
      pa_w = pc_q[wave_q];
      if (st_q == W_LD0) pa_w = pc_q[wave_q] + {10'h0, vk_q} + 1;
      ty_w = '0; rm_w = '0; mb_w = '0; fn_w = '0; pt_w = '0;
      unique case (st_q)
        W_TY0:  ty_w = ops_q[0][9:0];
        W_OT0:  ty_w = oty_id_q;
        W_FN0:  begin                            // callee row + result rm
          fn_w = ops_q[2][9:0];
          rm_w = ops_q[1][9:0];
        end
        W_FN2:  begin                            // param row + arg rm
          pt_w = 10'(frow_q[27:16] + 12'(fpk_q));
          rm_w = (3 + 32'(fpk_q) < OPB) ? ops_q[3 + fpk_q][9:0] : '0;
        end
        W_FR0:  rm_w = ops_q[0][9:0];            // return value id
        W_CC0:  ty_w = vty_q[vk_q[1:0]];
        W_CM0:  ty_w = vty_q[vk_q[1:0]];
        W_MS0:  ty_w = vty_q[0];
        W_MS1:  ty_w = vty_q[1];
        W_RMI:  rm_w = f_opid10(opc_q, vk_q, ops_q);
        W_IR0:  rm_w = res_id_q;
        W_RW0:  rm_w = ops_q[1][9:0];
        W_PH0:  rm_w = ops_q[1][9:0];
        W_PH1:  rm_w = phv_c[9:0];
        W_CHT0: ty_w = cty_q;
        W_CHM0: mb_w = cmb_q;
        W_CHE0: ty_w = cty2_q;
        W_AL0:  ty_w = vty_q[0];
        W_AL2:  ty_w = al_ty_q;
        W_AL4:  mb_w = cmb_q;
        W_AL6:  ty_w = al_ty2_q;
        default: ;
      endcase
    end
    logic [9:0]     cf_jmp;   // declared early: blk_id_o needs it
    logic           cf_jok;
    assign rd_slot_o   = slot_q;
    assign prog_addr_o = pa_w;
    assign type_id_o   = ty_w;
    assign const_id_o  = (st_q == W_PH2) ? phv_c[9:0] : res_id_q;
    assign memb_id_o   = mb_w;
    assign rm_id_o     = rm_w;
    assign func_id_o   = fn_w;
    assign parm_id_o   = pt_w;
    assign init_id_o   = init_i_q[9:0];
    assign blk_id_o    = (st_q == W_CF0 && cf_jok) ? cf_jmp
                                                 : ops_q[0][9:0];
    assign phi_id_o    = ops_q[1][9:0];

    // ---- integer combinational ALU ------------------------------------------
    vt_t int_alu;
    vt_t int_alu2;                   // G3a-i: second result row
    always_comb begin
      int_alu = '0;
      unique case (opc_q)
        126: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = ~va_q[0][l][c] + 1;
        127: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {~va_q[0][l][c][31], va_q[0][l][c][30:0]};
        128: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] + va_q[1][l][c];
        130: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] - va_q[1][l][c];
        132: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] * va_q[1][l][c];
        194: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] >> va_q[1][l][c][4:0];
        195: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = $signed(va_q[0][l][c]) >>>
                               va_q[1][l][c][4:0];
        196: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] << va_q[1][l][c][4:0];
        197: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] | va_q[1][l][c];
        198: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] ^ va_q[1][l][c];
        199: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c] & va_q[1][l][c];
        200: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = ~va_q[0][l][c];
        124: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = va_q[0][l][c];
        // SPIR-V numbering (grammar): 172/173 u>/s>, 174/175 u>=/s>=,
        // 176/177 u</s<, 178/179 u<=/s<=
        170: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0, va_q[0][l][c] == va_q[1][l][c]};
        171: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0, va_q[0][l][c] != va_q[1][l][c]};
        172: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0, va_q[0][l][c] > va_q[1][l][c]};
        173: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                $signed(va_q[0][l][c]) >
                                $signed(va_q[1][l][c])};
        174: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0, va_q[0][l][c] >= va_q[1][l][c]};
        175: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                $signed(va_q[0][l][c]) >=
                                $signed(va_q[1][l][c])};
        176: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0, va_q[0][l][c] < va_q[1][l][c]};
        177: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                $signed(va_q[0][l][c]) <
                                $signed(va_q[1][l][c])};
        178: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0, va_q[0][l][c] <= va_q[1][l][c]};
        179: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                $signed(va_q[0][l][c]) <=
                                $signed(va_q[1][l][c])};
        164: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                (|va_q[0][l][c]) == (|va_q[1][l][c])};
        165: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                (|va_q[0][l][c]) != (|va_q[1][l][c])};
        166: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                (|va_q[0][l][c]) | (|va_q[1][l][c])};
        167: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0,
                                (|va_q[0][l][c]) & (|va_q[1][l][c])};
        168: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] = {31'h0, ~(|va_q[0][l][c])};
        169: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] =
                 (|va_q[0][l][(ot_comps_q > 1) ? c[1:0] : 2'd0])
                 ? va_q[1][l][c] : va_q[2][l][c];
        // ---- G3a-i scalar/vector misc --------------------------------
        1,83:  for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                 int_alu[l][c] = (opc_q == 1) ? 32'h0 : va_q[0][l][c];
        // OpVectorExtractDynamic: comp index = va1[l][0] (&3 wrap)
        77:    for (int l = 0; l < LAN; l++)
                 int_alu[l][0] = va_q[0][l][va_q[1][l][0][1:0]];
        // OpVectorInsertDynamic: index = va2[l][0] (&3), value = va1
        78:    for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                 int_alu[l][c] = (c[1:0] == va_q[2][l][0][1:0])
                               ? va_q[1][l][0] : va_q[0][l][c];
        // OpIAddCarry / OpISubBorrow / Op{U,S}MulExtended: struct
        // result = flat interleaved {lo,hi} word pairs per input comp
        // (model order) — comps 0/1 → row 0 via int_alu, comps 2/3 →
        // row 1 via int_alu2 (W_WB2 writes it)
        149,150,151,152:
          for (int l = 0; l < LAN; l++) for (int c = 0; c < 4; c++) begin
            logic [63:0] p;
            logic [31:0] lo, hi;
            if (opc_q == 151) begin
              p = {32'h0, va_q[0][l][c >> 1]} *
                  {32'h0, va_q[1][l][c >> 1]};
              lo = p[31:0]; hi = p[63:32];
            end else if (opc_q == 152) begin
              p = 64'($signed(va_q[0][l][c >> 1]) *
                      $signed(va_q[1][l][c >> 1]));
              lo = p[31:0]; hi = p[63:32];
            end else begin
              p = (opc_q == 149)
                  ? 64'({1'b0, va_q[0][l][c >> 1]} +
                        {1'b0, va_q[1][l][c >> 1]})
                  : 64'({1'b0, va_q[0][l][c >> 1]} -
                        {1'b0, va_q[1][l][c >> 1]});
              lo = p[31:0];
              hi = (opc_q == 149)
                   ? 32'(p[32])
                   : 32'(va_q[0][l][c >> 1] < va_q[1][l][c >> 1]);
            end
            int_alu[l][c] = c[0] ? hi : lo;
          end
        154:   for (int l = 0; l < LAN; l++) begin   // OpAny (comp0)
                 int_alu[l][0] = {31'h0,
                   (|va_q[0][l][0]) | (ot_comps_q > 1 && |va_q[0][l][1]) |
                   (ot_comps_q > 2 && |va_q[0][l][2]) |
                   (ot_comps_q > 3 && |va_q[0][l][3])};
               end
        155:   for (int l = 0; l < LAN; l++) begin   // OpAll (comp0)
                 int_alu[l][0] = {31'h0,
                   (|va_q[0][l][0]) & (ot_comps_q < 2 || |va_q[0][l][1]) &
                   (ot_comps_q < 3 || |va_q[0][l][2]) &
                   (ot_comps_q < 4 || |va_q[0][l][3])};
               end
        156:   for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                 int_alu[l][c] = {31'h0, f_nan(va_q[0][l][c])};
        157:   for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                 int_alu[l][c] = {31'h0,
                   va_q[0][l][c][30:23] == 8'hFF &&
                   va_q[0][l][c][22:0] == 0};
        // OpBitFieldInsert(base,ins,off,cnt): off/cnt are scalars,
        // base/insert per-comp
        201:   for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               begin
                 logic [31:0] msk;
                 msk = (va_q[3][l][0] >= 32) ? 32'hFFFF_FFFF :
                       ((32'h1 << va_q[3][l][0][4:0]) - 1)
                         << va_q[2][l][0][4:0];
                 int_alu[l][c] = (va_q[0][l][c] & ~msk) |
                                 ((va_q[1][l][c] << va_q[2][l][0][4:0])
                                  & msk);
               end
        202:   for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               begin                                   // SExtract
                 logic [31:0] r;
                 r = (va_q[2][l][0] == 0) ? 32'h0 :
                     (va_q[0][l][c] >> va_q[1][l][0][4:0]) &
                     ((va_q[2][l][0] >= 32) ? 32'hFFFF_FFFF
                      : (32'h1 << va_q[2][l][0][4:0]) - 1);
                 int_alu[l][c] = (va_q[2][l][0] < 32 &&
                                  va_q[2][l][0] != 0 &&
                                  r[va_q[2][l][0][4:0] - 1])
                   ? r | ~((32'h1 << va_q[2][l][0][4:0]) - 1) : r;
               end
        203:   for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
               int_alu[l][c] =                          // UExtract
                   (va_q[2][l][0] == 0) ? 32'h0 :
                   (va_q[0][l][c] >> va_q[1][l][0][4:0]) &
                   ((va_q[2][l][0] >= 32) ? 32'hFFFF_FFFF
                    : (32'h1 << va_q[2][l][0][4:0]) - 1);
        204:   for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                 for (int b = 0; b < 32; b++)           // BitReverse
                   int_alu[l][c][b] = va_q[0][l][c][31 - b];
        205:   for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                 int_alu[l][c] = 32'($countones(va_q[0][l][c]));
        // GLSL.std.450 logic-only ops (xnum_q = extinst number)
        12: unique case (xnum_q)
          4:  for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = {1'b0, va_q[0][l][c][30:0]};       // FAbs
          5:  for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = va_q[0][l][c][31]
                                ? ~va_q[0][l][c] + 1 : va_q[0][l][c];
          6:  for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] =
                  f_nan(va_q[0][l][c]) ? va_q[0][l][c] :
                  (va_q[0][l][c][30:0] == 0) ? 32'h0 :
                  va_q[0][l][c][31] ? 32'hBF80_0000 : 32'h3F80_0000;
          7:  for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = (va_q[0][l][c] == 0) ? 0 :
                  va_q[0][l][c][31] ? 32'hFFFF_FFFF : 32'd1;     // SSign
          38: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = (va_q[0][l][c] < va_q[1][l][c])
                                ? va_q[0][l][c] : va_q[1][l][c]; // UMin
          39: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = ($signed(va_q[0][l][c]) <
                                 $signed(va_q[1][l][c]))
                                ? va_q[0][l][c] : va_q[1][l][c]; // SMin
          41: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = (va_q[0][l][c] > va_q[1][l][c])
                                ? va_q[0][l][c] : va_q[1][l][c]; // UMax
          42: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = ($signed(va_q[0][l][c]) >
                                 $signed(va_q[1][l][c]))
                                ? va_q[0][l][c] : va_q[1][l][c]; // SMax
          44: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = (va_q[0][l][c] < va_q[1][l][c])
                                ? va_q[1][l][c]
                                : (va_q[0][l][c] > va_q[2][l][c]
                                   ? va_q[2][l][c] : va_q[0][l][c]);
          45: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = ($signed(va_q[0][l][c]) <
                                 $signed(va_q[1][l][c]))
                                ? va_q[1][l][c]
                                : ($signed(va_q[0][l][c]) >
                                   $signed(va_q[2][l][c])
                                   ? va_q[2][l][c] : va_q[0][l][c]);
          48: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
                int_alu[l][c] = t0_q[l][c] ? 32'h0 : 32'h3F80_0000;
                                                       // step: 0 if x<edge
          // FindILsb / FindUMsb / FindSMsb (per comp)
          73: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
              begin
                int_alu[l][c] = 32'hFFFF_FFFF;
                for (int b = 0; b < 32; b++)
                  if (va_q[0][l][c][b] && int_alu[l][c] == 32'hFFFF_FFFF)
                    int_alu[l][c] = 32'(b);
              end
          75: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
              begin
                int_alu[l][c] = 32'hFFFF_FFFF;
                for (int b = 31; b >= 0; b--)
                  if (va_q[0][l][c][b] && int_alu[l][c] == 32'hFFFF_FFFF)
                    int_alu[l][c] = 32'(b);
              end
          74: for (int l = 0; l < LAN; l++) for (int c = 0; c < VEC; c++)
              begin
                logic [31:0] x;
                x = va_q[0][l][c];
                if (x == 0 || x == 32'hFFFF_FFFF)
                  int_alu[l][c] = 32'hFFFF_FFFF;
                else begin
                  logic [31:0] v;
                  v = x[31] ? ~x : x;
                  int_alu[l][c] = 32'hFFFF_FFFF;
                  for (int b = 31; b >= 0; b--)
                    if (v[b] && int_alu[l][c] == 32'hFFFF_FFFF)
                      int_alu[l][c] = 32'(b);
                end
              end
          default: ;
        endcase
        default: ;
      endcase
    end

    // G3a-i: second-row results for the two-word struct ops and the
    // integer extended results (OpIAddCarry carry, OpISubBorrow borrow,
    // OpUMulExtended hi, OpSMulExtended hi).
    always_comb begin
      int_alu2 = '0;
      unique case (opc_q)
        // 149-152 row 1 = interleaved {lo,hi} pairs for source comps
        // 2 and 3 (model order, see the int_alu arm)
        149,150,151,152:
          for (int l = 0; l < LAN; l++) for (int c = 0; c < 4; c++) begin
            logic [63:0] p;
            logic [31:0] lo, hi;
            if (opc_q == 151) begin
              p = {32'h0, va_q[0][l][(c >> 1) + 2]} *
                  {32'h0, va_q[1][l][(c >> 1) + 2]};
              lo = p[31:0]; hi = p[63:32];
            end else if (opc_q == 152) begin
              p = 64'($signed(va_q[0][l][(c >> 1) + 2]) *
                      $signed(va_q[1][l][(c >> 1) + 2]));
              lo = p[31:0]; hi = p[63:32];
            end else begin
              p = (opc_q == 149)
                  ? 64'({1'b0, va_q[0][l][(c >> 1) + 2]} +
                        {1'b0, va_q[1][l][(c >> 1) + 2]})
                  : 64'({1'b0, va_q[0][l][(c >> 1) + 2]} -
                        {1'b0, va_q[1][l][(c >> 1) + 2]});
              lo = p[31:0];
              hi = (opc_q == 149)
                   ? 32'(p[32])
                   : 32'(va_q[0][l][(c >> 1) + 2] <
                         va_q[1][l][(c >> 1) + 2]);
            end
            int_alu2[l][c] = c[0] ? hi : lo;
          end
        // ExtInst struct results (ModfStruct/FrexpStruct): row 1 holds
        // the ipart/exp member, staged in t2 during the microsequence;
        // member1 starts at flat word m0 = member0's comp count, so a
        // straddling member (m0 < 4, rsz > 16) enters row 1 shifted.
        12: for (int l = 0; l < LAN; l++)
              for (int c = 0; c < 4; c++)
                int_alu2[l][c] =
                  (c + 4 - 4'(f_nc(ot_comps_q)) < 4)
                    ? t2_q[l][c + 4 - 4'(f_nc(ot_comps_q))] : 32'h0;
        default: for (int l = 0; l < LAN; l++)
                   int_alu2[l] = wb_q[l];
      endcase
    end

    // G3a-i: 32-bit integer atomic combinational ALU.  a = old memory
    // word (sb_rdata on the workgroup path, mem_rdata_i slice on the
    // SSBO path), b = operand word (va_q[1][lane][0]), c = CAS
    // comparator (va_q[2][lane][0]).  Atomicity is structural: one LSU,
    // one outstanding access, and wave_q changes only in W_SCHED —
    // i.e. between instructions — so the W_AT*/W_LS1 sequence can
    // never be split by a wave switch.
    function automatic logic [31:0] f_atomic(
        input logic [15:0] op, input logic [31:0] a,
        input logic [31:0] b, input logic [31:0] c);
      unique case (op)
        16'd227: f_atomic = a;                        // Load
        16'd228: f_atomic = b;                        // Store
        16'd229: f_atomic = b;                        // Exchange
        16'd230: f_atomic = (a == c) ? b : a;         // CompareExchange
        16'd232: f_atomic = a + 32'd1;                // IIncrement
        16'd233: f_atomic = a - 32'd1;                // IDecrement
        16'd234: f_atomic = a + b;                    // IAdd
        16'd235: f_atomic = a - b;                    // ISub
        16'd236: f_atomic = ($signed(a) < $signed(b)) ? a : b;
        16'd237: f_atomic = (a < b) ? a : b;
        16'd238: f_atomic = ($signed(a) < $signed(b)) ? b : a;
        16'd239: f_atomic = (a < b) ? b : a;
        16'd240: f_atomic = a & b;
        16'd241: f_atomic = a | b;
        16'd242: f_atomic = a ^ b;
        default: f_atomic = a;
      endcase
    endfunction
    wire [31:0] atb_w = va_q[1][ls_lane_q[2:0]][0];
    wire [31:0] atc_w = va_q[2][ls_lane_q[2:0]][0];
    wire [31:0] atomic_alu = (st_q == W_ATC)
        ? f_atomic(at_op_q,
                   mem_rdata_i[32'(ls_addr_q[2]) * 32 +: 32],
                   atb_w, atc_w)
        : f_atomic(at_op_q,
                   (ls_sc_q == APU_SH_SC_WORKGROUP) ? sb_rdata
                                                    : sc_rdata,
                   atb_w, atc_w);

    // ---- G3a-i f32<->f16 and ldexp (bit-exact ports of the model) ----
    function automatic logic [31:0] f_ldexp(input logic [31:0] w,
                                            input logic [31:0] e);
      logic        s;
      logic [7:0]  ex;
      logic [22:0] m;
      logic signed [31:0] ne;
      logic [23:0] fmn;
      logic [31:0] r, rem, half;
      logic [5:0]  sh;
      logic [4:0]  clz;
      begin
        s = w[31]; ex = w[30:23]; m = w[22:0];
        if (ex == 8'hFF || (ex == 0 && m == 0))
          f_ldexp = w;                          // inf/nan/zero pass
        else begin
          if (ex == 0) begin                    // denormal: normalize
            clz = 5'd0;
            for (int i = 22; i >= 0; i--)
              if (!m[i] && clz == 5'(22 - i)) clz = clz + 1;
            m  = (m << (clz + 1)) & 23'h7FFFFF;
            ne = 32'sd1 - $signed({27'h0, clz}) + $signed(e);
          end else
            ne = $signed({24'h0, ex}) + $signed(e);
          if (ne >= 255)
            f_ldexp = {s, 8'hFF, 23'h0};
          else if (ne <= 0) begin               // underflow: denorm RNE
            fmn = {1'b1, m};
            sh  = 6'(1 - ne);
            if (sh >= 25) f_ldexp = {s, 31'h0};
            else begin
              r    = {8'h0, fmn} >> sh;
              rem  = {8'h0, fmn} & ((32'h1 << sh) - 1);
              half = 32'h1 << (sh - 1);
              if (rem > half || (rem == half && r[0])) r = r + 1;
              f_ldexp = {s, r[30:0]};           // carry folds into exp
            end
          end else
            f_ldexp = {s, ne[7:0], m};
        end
      end
    endfunction

    // ---- G3a-i DM micro-program (Determinant / MatrixInverse) --------
    // DM_PROG is generated by tools/shader/gen_dmprog.py and mirrors
    // spirv_model.py's detn()/matinv() cofactor expansion op-for-op.
    // The operand matrix is staged column-by-column into dtm_q
    // (element m[c][r] = flat id c*4+r) before the program runs.
`include "g6lc_apu_dmprog.svh"
    wire [29:0] dmi = DM_PROG[dmp_q[8:0]];
    wire [4:0]  dm_op  = dmi[29:25];
    wire [6:0]  dm_dd  = dmi[24:18];
    wire [5:0]  dm_sa  = dmi[17:12], dm_sb = dmi[11:6],
                dm_sc  = dmi[5:0];
    // source id → unit operand spec {cmode=3 (per-slot comp), sel}
    function automatic logic [6:0] dm_ssel(input logic [5:0] id);
      if (id < 6'd16)       dm_ssel = {2'd3, 5'(S_DT0) + 5'(id[3:2])};
      else if (id < 6'd28)  dm_ssel = {2'd3, 5'(S_T0) + 5'((id-6'd16)>>2)};
      else if (id < 6'd44)  dm_ssel = {2'd3, 5'(S_DR0) + 5'((id-6'd28)>>2)};
      else if (id == 6'd60) dm_ssel = {2'd3, S_ONE};
      else                  dm_ssel = {2'd3, S_ZERO};
    endfunction
    // source comp index (per-slot comp arg) — flat id bits [1:0]
    function automatic logic [1:0] dm_ci(input logic [5:0] id);
      dm_ci = (id < 6'd44) ? id[1:0] : 2'd0;
    endfunction
    // destination id → {jdst, jdtx/ccc}
    wire [2:0] dm_jdst = (dm_dd < 7'd16) ? 3'd4 :
                         (dm_dd < 7'd28) ? 3'(3'd1 + 3'((dm_dd - 7'd16) >> 2)) :
                         (dm_dd < 7'd44) ? 3'd5 : 3'd0;
    wire [3:0] dm_jdtx = (dm_dd < 7'd16) ? dm_dd[3:0] :
                         (dm_dd < 7'd44) ? 4'(dm_dd - 7'd28) : 4'h0;
    // DM op → unit job: MUL/MULN/FMA/FMAN on the fma unit, DIV on the
    // divsqrt unit; MOV lowers to ADD(a, 0.0); ADD/SUB use b±c
    wire [4:0]  dm_xo  = (dm_op == 5'd1 || dm_op == 5'd2) ? 5'd2 :
                         (dm_op == 5'd3 || dm_op == 5'd8 ||
                          dm_op == 5'd7) ? 5'd0 :         // DIV: xop[0]=0
                         (dm_op == 5'd4) ? 5'd1 : 5'd3;
    wire        dm_neg = (dm_op == 5'd2) || (dm_op == 5'd6);
    wire [6:0]  dm_sa_w = dm_ssel(dm_sa);
    wire [6:0]  dm_sb_w = (dm_op == 5'd8) ? dm_ssel(dm_sa)
                                        : dm_ssel(dm_sb);
    wire [6:0]  dm_sc_w = (dm_op == 5'd8) ? {2'd3, S_ZERO}
                                        : dm_ssel(dm_sc);

    // stored/loaded word for the current (lane,word) cursor: matrix
    // operands read/write column rows (rf or the latched const row)
    wire [2:0]  ls_wc = ls_mat_q ? lcc_q : {1'b0, ls_comp_q[1:0]};
    // matrix access shape: comps per column / column count, keyed on
    // whether the operand (store) or the result (load) is the matrix
    wire [2:0]  ls_ccn = ls_store_q ? ot_comps_q : 3'(f_nc(rcomps_q));
    wire [2:0]  ls_ccl = ls_store_q ? ot_cols_q  : rcols_q;
    // flat word index inside one lane's matrix extent (column-major)
    // = column * comps-per-column + comp-in-column; ls_comp_q free-runs
    // in the mat path and must not be used for addressing
    wire [8:0]  ls_flw = {4'h0, lrc_q} * {6'h0, ls_ccn} + {6'h0, lcc_q};
    wire [31:0] ls_wd = !ls_mat_q
                      ? (ls_tsrc_q
                         ? t1_q[ls_lane_q[2:0]][ls_comp_q[1:0]]
                         : va_q[1][ls_lane_q[2:0]][ls_comp_q[1:0]])
                      : (otag_q[1] == APU_SH_RT_CONST)
                        ? ocst_q[1][32*({23'h0, ls_flw}) +: 32]
                        : ma_q[ls_lane_q[2:0]][lcc_q];

    // ---- SRAM port drive ------------------------------------------------------
    always_comb begin
      rf_req = 1'b0; rf_we = 1'b0; rf_addr = '0; rf_wdata = '0;
      rf_be = '0;
      sc_req = 1'b0; sc_we = 1'b0; sc_addr = '0; sc_wdata = '0;
      sc_be = '0;
      sb_req = 1'b0; sb_we = 1'b0; sb_addr = '0; sb_wdata = '0;
      sb_be = '0;
      unique case (st_q)
        W_IW1: begin
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, iw_idx[RI-1:0]};
          for (int l = 0; l < LAN; l++) begin
            rf_wdata[l*128 +: 32]      = {16'h0, iw_off};
            rf_wdata[l*128 + 32 +: 32] = {iw_fl, iw_bd, iw_set,
                                          iw_bi, iw_sc};
            rf_wdata[l*128 + 64 +: 32] = '0;
            rf_wdata[l*128 + 96 +: 32] = '0;
          end
          rf_be = '1;
        end
        W_SC0: begin                       // per-lane scratch clear
          sc_req = 1'b1; sc_we = 1'b1;
          sc_addr = SDW'((32'(wave_q) * LAN + ls_lane_q) * SCW +
                         ls_comp_q);
          sc_wdata = '0; sc_be = 4'hF;
        end
        W_SCLR: begin                      // per-workgroup slab clear
          sb_req = 1'b1; sb_we = 1'b1;
          sb_addr = SLWA'(ls_off_q >> 2);
          sb_wdata = '0; sb_be = 4'hF;
        end
        W_RV0: begin
          rf_req = 1'b1;
          rf_addr = {wave_q, ridx_q};
        end
        W_IR2: begin
          rf_req = 1'b1;
          rf_addr = {wave_q, ir_idx_q};
        end
        W_PH2: begin
          rf_req = 1'b1;
          rf_addr = {wave_q, rm_idx[RI-1:0]};
        end
        W_MRD0: begin                      // matrix operand column
          if (otag_q[mrds_q] != APU_SH_RT_CONST) begin
            rf_req = 1'b1;
            rf_addr = {wave_q, mrd_q};
          end
        end
        W_XC0: begin                       // matrix extract column read
          rf_req = 1'b1;
          rf_addr = {wave_q, oidx_q[0] + RI'(ops_q[3][1:0])};
        end
        W_MWB: begin                       // matrix result column
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q + RI'(mi_q)};
          rf_wdata = wb_q;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++)
              if (act_w[l] && c < mrr_q) rf_be[l*16 + c*4 +: 4] = 4'hF;
        end
        W_CMW: begin                       // construct: full column row
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q + RI'(ccr_q)};
          rf_wdata = wb_q;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++)
              if (act_w[l] && c < rcomps_q)
                rf_be[l*16 + c*4 +: 4] = 4'hF;
        end
        W_CMF: begin                       // construct: partial last row
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q + RI'(ccr_q)};
          rf_wdata = wb_q;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++)
              if (act_w[l] && c < ccp_q) rf_be[l*16 + c*4 +: 4] = 4'hF;
        end
        W_CM5: begin                       // construct: operand col read
          if (otag_q[vk_q[1:0]] != APU_SH_RT_CONST) begin
            rf_req = 1'b1;
            rf_addr = {wave_q, oidx_q[vk_q[1:0]] + RI'(cmj_q)};
          end
        end
        W_SMR0: begin                      // store: matrix column fetch
          rf_req = 1'b1;
          rf_addr = {wave_q, oidx_q[1] + RI'(lrc_q)};
        end
        W_MLF: begin                       // load: result column flush
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q + RI'(lrc_q)};
          rf_wdata = wb_q;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++)
              if (act_w[l] && c <= lcc_q)
                rf_be[l*16 + c*4 +: 4] = 4'hF;
        end
        W_WB: begin
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q};
          rf_wdata = wb_q;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++)
              if (act_w[l] && wbm_q[c]) rf_be[l*16 + c*4 +: 4] = 4'hF;
        end
        W_WB2: begin                       // struct result: second row
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q + RI'(1)};
          rf_wdata = int_alu2;
          for (int l = 0; l < LAN; l++)
            if (act_w[l]) rf_be[l*16 +: 4] = 4'hF;
        end
        W_FN4: begin                       // call: arg row source read
          if (fatag_q != APU_SH_RT_CONST) begin
            rf_req = 1'b1;
            rf_addr = {wave_q, faidx_q + RI'(fkr_q)};
          end
        end
        W_FN5: begin                       // call: param row write
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, fpr_q[RI-1:0] + RI'(fkr_q)};
          // W_FN4's rf read lands this cycle; a const arg was fetched
          // via const_id_o (= res_id_q) through the same window
          rf_wdata = fatag_q == APU_SH_RT_CONST ? const_data_i[127:0]
                                                : rf_rdata;
          for (int l = 0; l < LAN; l++)
            if (act_w[l]) rf_be[l*16 +: 16] = '1;
        end
        W_FR1: begin                       // return-value row source read
          if (((fkr_q == 0) ? rm_tag : fatag_q) != APU_SH_RT_CONST) begin
            rf_req = 1'b1;
            rf_addr = {wave_q, RI'(fkr_q) +
                       (fkr_q == 0 ? rm_idx[RI-1:0] : faidx_q)};
          end
        end
        W_FRC: begin                       // return-value row write
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, fpr_q[RI-1:0] + RI'(fkr_q)};
          rf_wdata = fatag_q == APU_SH_RT_CONST ? const_data_i[127:0]
                                                : rf_rdata;
          for (int l = 0; l < LAN; l++)
            if (act_w[l]) rf_be[l*16 +: 16] = '1;
        end
        W_ATS0: begin                      // WG/scratch atomic read
          if (ls_sc_q == APU_SH_SC_WORKGROUP) begin
            if (ls_off_q < 32'(SlabBytes)) sb_req = 1'b1;
            sb_addr = SLWA'(ls_off_q >> 2);
          end else begin
            if ((ls_off_q >> 2) < SCW &&
                ls_off_q < {16'h0, escratch_q}) sc_req = 1'b1;
            sc_addr = SDW'((32'(wave_q) * LAN + ls_lane_q) * SCW +
                           (ls_off_q >> 2));
          end
        end
        W_ATS1: begin                      // WG/scratch atomic write
          if (ls_sc_q == APU_SH_SC_WORKGROUP) begin
            if (ls_off_q < 32'(SlabBytes)) begin
              sb_req = 1'b1;
              sb_we  = (at_op_q != 16'd227);   // AtomicLoad: no write
            end
            sb_addr = SLWA'(ls_off_q >> 2);
            sb_wdata = atomic_alu; sb_be = 4'hF;
          end else begin
            if ((ls_off_q >> 2) < SCW &&
                ls_off_q < {16'h0, escratch_q}) begin
              sc_req = 1'b1;
              sc_we  = (at_op_q != 16'd227);
            end
            sc_addr = SDW'((32'(wave_q) * LAN + ls_lane_q) * SCW +
                           (ls_off_q >> 2));
            sc_wdata = atomic_alu; sc_be = 4'hF;
          end
        end
        W_DM0: begin                       // DM: operand column stage
          if (!dmph_q && otag_q[0] != APU_SH_RT_CONST) begin
            rf_req = 1'b1;
            rf_addr = {wave_q, oidx_q[0] + RI'(dmcol_q)};
          end
        end
        W_DMF: begin                       // DM: flush result column
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q + RI'(dmcol_q)};
          rf_wdata = wb_q;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++)
              if (act_w[l] && c < rcomps_q)
                rf_be[l*16 + c*4 +: 4] = 4'hF;
        end
        W_SSB: begin
          if (ls_sc_q == APU_SH_SC_WORKGROUP) begin
            sb_req = 1'b1;
            sb_we = ls_store_q && act_w[ls_lane_q[2:0]] &&
                    !dead_q[wave_q][ls_lane_q[2:0]] &&
                    !hlp_w[ls_lane_q[2:0]] &&
                    ((ls_off_q >> 2) < SLW);
            sb_addr = SLWA'(ls_off_q >> 2);
            sb_wdata = ls_wd;
            sb_be = 4'hF;
          end else begin
            sc_req = 1'b1;
            // Function/Private stores are never suppressed — dead lanes
            // that still execute are demoted helpers, and Vulkan keeps
            // their private state (and Output records) live for quad
            // derivatives; killed lanes left act_w at the kill site.
            sc_we = ls_store_q && act_w[ls_lane_q[2:0]] &&
                    ((ls_off_q >> 2) < SCW) &&
                    (ls_off_q < {16'h0, escratch_q});
            sc_addr = SDW'((32'(wave_q) * LAN + ls_lane_q) * SCW +
                           (ls_off_q >> 2));
            sc_wdata = ls_wd;
            sc_be = 4'hF;
          end
        end
        default: ;
      endcase
    end

    wire ls_mem = (ls_sc_q == APU_SH_SC_UNIFORM) ||
                  (ls_sc_q == APU_SH_SC_SBUF) || ls_rec_q;
    // F5: W_DS1/3/5/7 issue the four descriptor-record beats
    wire dsc_mem = (st_q == W_DS1) || (st_q == W_DS3) ||
                   (st_q == W_DS5) || (st_q == W_DS7);
    // §12.3 3d-d: record memory-handle resolve — the READSLOT request
    // is built from the just-fetched record (dsc_rec_q) and held until
    // the arbitrated ObjTab accepts; the completion is consumed in
    // W_DSA only
    assign ot_req_valid_o = st_q == W_DS9;
    assign ot_req_o = '{op: APU_OBJTAB_OP_READSLOT,
                       id: {48'h0, dsc_rec_q[15:0]},
                       kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
                       default: '0};
    assign ot_cpl_ready_o = st_q == W_DSA;
    // 5b: W_TXF0 streams a texture-cache line fill; W_TXW0/W_TXW1 are
    // the image-store beats (wstrb narrows sub-8B texels)
    wire txr_mem = (st_q == W_TXF0);
    wire txw_mem = (st_q == W_TXW0);
    // G3a-i: SSBO atomic read-modify-write and the FS-out slot-8 tail beats
    wire atr_mem = (st_q == W_ATR) || (st_q == W_ATW);
    wire f8_mem  = (st_q == W_F8A) || (st_q == W_F8B);
    assign mem_re_o    = ((st_q == W_LS1) && ls_mem && !ls_store_q &&
                          ls_bok_q) || (st_q == W_ATR) ||
                         dsc_mem || txr_mem;
    // dead/helper lanes lose device-memory stores but keep Output
    // record stores (per-invocation stream; rast drops them via the
    // slot-8 discard flag for demoted, helpers are never drawn)
    assign mem_we_o    = ((st_q == W_LS1) && ls_mem && ls_store_q &&
                          ls_bok_q && act_w[ls_lane_q[2:0]] &&
                          (!(dead_q[wave_q][ls_lane_q[2:0]] ||
                             hlp_w[ls_lane_q[2:0]]) || ls_rec_q)) ||
                         (st_q == W_ATW) || f8_mem || txw_mem;
    wire [63:0] f8a_w  = ls_addr_q + {59'h0, f8b_q};
    assign mem_addr_o  = dsc_mem ? dsc_addr_q :
                         txr_mem ? txc_addr_q :
                         f8_mem  ? (f8a_w & ~64'h7) :
                         txw_mem ? ({32'h0, tx_ta_q} & ~64'h7) :
                                   (ls_addr_q & ~64'h7);
    assign mem_wdata_o = f8_mem ? (f8a_w[2] ? {f8d_q, 32'h0}
                                           : {32'h0, f8d_q}) :
                         txw_mem ? (tx_stb_q[63:0] <<
                                    {tx_ta_q[2:0], 3'b000}) :
                         (st_q == W_ATW)
                           ? (ls_addr_q[2] ? {at_new_q, 32'h0}
                                           : {32'h0, at_new_q}) :
                         ls_addr_q[2] ? {ls_wd, 32'h0}
                                      : {32'h0, ls_wd};
    assign mem_wstrb_o = f8_mem ? (f8a_w[2] ? 8'hF0 : 8'h0F) :
                         txw_mem ? tx_wbe_q :
                         ls_addr_q[2] ? 8'hF0 : 8'h0F;

    // =========================================================================
    // §7c control-flow engine — combinational next-state of the selected
    // wave's reconvergence stack, evaluated while st_q == W_CF0.  cf_jok/
    // cf_jmp take a jump (label id resolved via the block table in W_CF1),
    // cf_adv retires the instruction in order, cf_fin finishes the wave,
    // cf_flt reports APU_SH_DONE_FAULT.  Stack entries are
    // {kind: 0=SEL,1=LOOP, merge, cont, resume, pending, cont_mask}.
    // =========================================================================
    logic [LAN-1:0] cf_nact;
    logic [3:0]     cf_nn;
    logic [1:0]     cf_nk [CFD];
    logic [9:0]     cf_nm [CFD];
    logic [9:0]     cf_nc [CFD];
    logic [LAN-1:0] cf_nr [CFD];
    logic [LAN-1:0] cf_np [CFD];
    logic [LAN-1:0] cf_nx [CFD];
    logic           cf_adv, cf_fin, cf_flt, cf_ret;
    // unwind floor: inside a callee the reconvergence entries at or
    // above the pushed frame's marker belong to the caller — the scan
    // never descends below it (drain → frame pop, not wave finish)
    wire  [3:0]     cf_floor = (csp_q[wave_q] == 0) ? 4'h0
                             : ccfn_q[wave_q][csp_q[wave_q] - 5'd1];
    logic [9:0]     ctg_w [LAN];

    // pending-lane rule on stack entry e: compute the lowest pending
    // lane's target group (outputs only — the caller updates the
    // engine next-state so the comb block stays single-process).
    task automatic cf_pick(input int e, output logic [LAN-1:0] grp,
                           output logic [9:0] t0);
      logic fnd;
      begin
        grp = '0; t0 = '0; fnd = 1'b0;
        for (int l = 0; l < LAN; l++)
          if (cf_np[e][l] && !fnd) begin fnd = 1'b1; t0 = ctg_w[l]; end
        for (int l = 0; l < LAN; l++)
          if (cf_np[e][l] && ctg_w[l] == t0) grp[l] = 1'b1;
      end
    endtask

    always_comb begin : cf_eng
      int   he;
      logic [LAN-1:0] stay, park, pk_grp;
      logic           same, un, hit, fnd_t;
      logic [9:0]    tg0, pk_t0;
      cf_nact = act_w;
      cf_nn   = cfn_q[wave_q];
      for (int e = 0; e < CFD; e++) begin
        cf_nk[e] = cfk_q[wave_q][e];
        cf_nm[e] = cfm_q[wave_q][e];
        cf_nc[e] = cfc_q[wave_q][e];
        cf_nr[e] = cfr_q[wave_q][e];
        cf_np[e] = cfp_q[wave_q][e];
        cf_nx[e] = cfx_q[wave_q][e];
      end
      cf_jmp = '0; cf_jok = 1'b0; cf_adv = 1'b0;
      cf_fin = 1'b0; cf_flt = 1'b0; cf_ret = 1'b0;
      he = -1; stay = '0; park = '0; same = 1'b0; un = 1'b0;
      hit = 1'b0; fnd_t = 1'b0; tg0 = '0;
      for (int l = 0; l < LAN; l++) ctg_w[l] = ctgt_q[wave_q][l];
      if (st_q == W_CF0) begin
        unique case (opc_q)
          // ---- OpLabel: arrival checks, innermost entry first --------
          16'd248: begin
            for (int e = CFD-1; e >= 0; e--)
              if (he < 0 && e < cf_nn) begin
                if (cf_nk[e] == 2'd0 &&
                    cf_nm[e] == ops_q[0][9:0]) he = e;
                else if (cf_nk[e] == 2'd1 &&
                         (cf_nm[e] == ops_q[0][9:0] ||
                          cf_nc[e] == ops_q[0][9:0])) he = e;
              end
            if (he < 0) cf_adv = 1'b1;
            else if (cf_nk[he] == 2'd0) begin      // SEL merge
              if (cf_np[he] != '0) begin            // next pending group
                cf_pick(he, pk_grp, pk_t0);
                cf_np[he] = cf_np[he] & ~pk_grp;
                cf_nact = pk_grp; cf_jmp = pk_t0; cf_jok = 1'b1;
              end else cf_nact = '0;                // → unwind → pop/resume
            end else if (cf_nc[he] == ops_q[0][9:0]) begin
              cf_nact = cf_nact | cf_nx[he];        // continue: rejoin
              cf_nx[he] = '0;
              cf_adv = 1'b1;
            end else cf_nact = '0;                  // loop merge: park
          end
          // ---- merges / barriers retire in order ---------------------
          16'd246: begin                            // OpLoopMerge M C
            // Idempotent re-entry: the back-edge re-executes the same
            // OpLoopMerge every iteration — when its LOOP entry is
            // already live, refresh membership instead of pushing a
            // duplicate (which would overflow CfDepth in N iterations).
            for (int e = CFD-1; e >= 0; e--)
              if (!hit && e < cf_nn && cf_nk[e] == 2'd1 &&
                  cf_nm[e] == ops_q[0][9:0] &&
                  cf_nc[e] == ops_q[1][9:0]) begin
                hit = 1'b1;
                cf_nr[e] = cf_nr[e] | act_w;
              end
            if (hit) cf_adv = 1'b1;
            else if (cf_nn >= 4'(CFD)) cf_flt = 1'b1;
            else begin
              cf_nk[cf_nn] = 2'd1;
              cf_nm[cf_nn] = ops_q[0][9:0];
              cf_nc[cf_nn] = ops_q[1][9:0];
              cf_nr[cf_nn] = act_w;
              cf_np[cf_nn] = '0;
              cf_nx[cf_nn] = '0;
              cf_nn = cf_nn + 1;
              cf_adv = 1'b1;
            end
          end
          16'd247, 16'd224, 16'd225: cf_adv = 1'b1;
          // ---- OpReturn/OpReturnValue / OpFunctionEnd / OpKill /
          // OpTerminateInvocation: the active lanes leave the current
          // execution context — scrub them out of every reconvergence
          // entry.  Return lanes re-enter via the call-frame pop;
          // killed lanes re-enter dead at the frame pop (or stay dead
          // at depth 0).
          16'd253, 16'd254, 16'd56, 16'd252, 16'd4416: begin
            for (int e = 0; e < CFD; e++)
              // returns inside a callee scrub the leaving lanes out
              // of callee-side entries only: the lanes resume at the
              // frame's cfret and must keep their parked slots in the
              // caller's entries below the floor (an early-arrived
              // lane's merge-resume slot is nr[he]).  Kills scrub
              // everywhere — dead lanes resume nowhere.
              if (e >= 32'(cf_floor) || opc_q == 16'd252 ||
                  opc_q == 16'd4416) begin
                cf_nr[e] = cf_nr[e] & ~act_w;
                cf_np[e] = cf_np[e] & ~act_w;
                cf_nx[e] = cf_nx[e] & ~act_w;
              end
            cf_nact = '0;                           // → unwind below
          end
          // ---- branches ----------------------------------------------
          16'd249, 16'd250, 16'd251: begin
            for (int l = 0; l < LAN; l++) begin
              if (opc_q == 16'd249) ctg_w[l] = ops_q[0][9:0];
              else if (opc_q == 16'd250)
                ctg_w[l] = (|va_q[0][l][0]) ? ops_q[1][9:0]
                                            : ops_q[2][9:0];
              else begin                          // OpSwitch
                ctg_w[l] = ops_q[1][9:0];
                for (int k = 0; k < 14; k++)
                  if (k < (32'(wc_q) - 3) / 2 &&
                      va_q[0][l][0] == ops_q[2 + 2 * k])
                    ctg_w[l] = ops_q[3 + 2 * k][9:0];
              end
            end
            // Innermost-first parking scan: a lane branching to a loop's
            // merge waits there (still in that loop's resume); a lane
            // branching to a loop's continue parks in cont_mask — both
            // are scrubbed from the deeper entries' resume/pending.
            for (int l = 0; l < LAN; l++) begin
              hit = 1'b0;
              for (int e = CFD-1; e >= 0; e--) begin
                if (!hit && e < cf_nn && cf_nk[e] == 2'd1) begin
                  if (ctg_w[l] == cf_nm[e] ||
                      ctg_w[l] == cf_nc[e]) begin
                    hit = 1'b1;
                    if (ctg_w[l] == cf_nc[e])
                      cf_nx[e] = cf_nx[e] | (LAN'(1) << l);
                    for (int f = e + 1; f < CFD; f++) begin
                      cf_nr[f] = cf_nr[f] & ~(LAN'(1) << l);
                      cf_np[f] = cf_np[f] & ~(LAN'(1) << l);
                    end
                  end
                end
              end
              if (hit && act_w[l]) park[l] = 1'b1;
            end
            stay = act_w & ~park;
            cf_nact = stay;
            same = 1'b1;
            for (int l = 0; l < LAN; l++)
              if (stay[l]) begin
                if (!fnd_t) begin fnd_t = 1'b1; tg0 = ctg_w[l]; end
                else if (ctg_w[l] != tg0) same = 1'b0;
              end
            if (stay != '0) begin
              if (same) begin
                cf_jmp = tg0; cf_jok = 1'b1;      // uniform jump
              end else if (!wsel_q[wave_q] || cf_nn >= 4'(CFD)) begin
                cf_flt = 1'b1;   // divergent without merge (commit
                                 // rule should have refused) / overflow
              end else begin
                cf_nk[cf_nn] = 2'd0;
                cf_nm[cf_nn] = wselm_q[wave_q];
                cf_nc[cf_nn] = '0;
                cf_nr[cf_nn] = stay;
                cf_np[cf_nn] = stay;
                cf_nx[cf_nn] = '0;
                cf_nn = cf_nn + 1;
                cf_pick(cf_nn - 1, pk_grp, pk_t0); // first group runs
                cf_np[cf_nn - 1] = cf_np[cf_nn - 1] & ~pk_grp;
                cf_nact = pk_grp; cf_jmp = pk_t0; cf_jok = 1'b1;
              end
            end
          end
          16'd255: cf_flt = 1'b1;                   // OpUnreachable
          default: cf_flt = 1'b1;
        endcase
        // ---- unwind: empty act mask → first entry with work ----------
        // Inside a callee the scan bottoms out at the frame's marker:
        // a full drain of callee-side entries pops the frame (cf_ret)
        // instead of finishing the wave.
        if (!cf_adv && !cf_jok && !cf_flt && cf_nact == '0) begin
          un = 1'b1;
          for (int e = CFD-1; e >= 0; e--) begin
            if (un && e < cf_nn && e >= 32'(cf_floor)) begin
              if (cf_np[e] != '0) begin
                cf_pick(e, pk_grp, pk_t0);
                cf_np[e] = cf_np[e] & ~pk_grp;
                cf_nact = pk_grp; cf_jmp = pk_t0; cf_jok = 1'b1;
                un = 1'b0;
              end else if (cf_nx[e] != '0) begin
                cf_nact = cf_nx[e]; cf_nx[e] = '0;
                cf_jmp = cf_nc[e]; cf_jok = 1'b1; un = 1'b0;
              end else if (cf_nr[e] != '0) begin
                cf_nact = cf_nr[e]; cf_jmp = cf_nm[e];
                cf_jok = 1'b1; cf_nn = 4'(e); un = 1'b0;
              end else cf_nn = 4'(e);              // empty → pop, unwind
            end else if (un && e < 32'(cf_floor)) begin
              // below the floor: still pop bookkeeping for any stale
              // entries but never resume them inside the callee
            end
          end
          if (un) begin
            if (csp_q[wave_q] != 0) cf_ret = 1'b1;
            else                    cf_fin = 1'b1;
          end
        end
      end
    end

    // =========================================================================
    // main FSM
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        st_q <= W_IDLE; ret_q <= W_EX;
        slot_q <= '0; gx_q <= '0; gy_q <= '0; gz_q <= '0; wid_q <= '0;
        gfx_q <= APU_SH_GFX_NONE; gcnt_q <= '0;
        in_base_q <= '0; out_base_q <= '0;
        vbase_q <= '0; inst_q <= '0;
        frontf_q <= 1'b0; dla_q <= '0; dlb_q <= '0; dva_q <= '0;
        push_n_q <= '0;
        dc_v_q <= '0; dc_vic_q <= '0;
        dsc_set_q <= '0; dsc_bd_q <= '0; dsc_idx_q <= '0;
        dsc_row_q <= '0; dsc_addr_q <= '0; dsc_rec_q <= '0;
        dsc_err_q <= '0; dret_q <= W_IDLE;
        tx_rec_q <= '0; tx_smp_q <= '0; tx_smpok_q <= '0;
        tx_full_q <= '0; tx_mcur_q <= '0; tx_lvl_q <= '0;
        tx_mt_q <= '0; tx_mt1_q <= '0; tx_macc_q <= '0;
        tx_pit_q <= '0; tx_wm_q <= '0; tx_hm_q <= '0;
        tx_laysz_q <= '0; tx_mof0_q <= '0; tx_mof1_q <= '0;
        tx_pit0_q <= '0; tx_pit1_q <= '0;
        tx_w0_q <= '0; tx_h0_q <= '0; tx_w1_q <= '0; tx_h1_q <= '0;
        tx_iu_q <= '0; tx_iv_q <= '0; tx_ly_q <= '0; tx_ld_q <= '0;
        tx_fw_q <= '0;
        for (int i = 0; i < 2; i++) begin
          tx_su_q[i] <= '0; tx_sv_q[i] <= '0; tx_td_q[i] <= '0;
        end
        tx_gn_q <= '0; tx_gi_q <= '0; tx_gi2_q <= '0;
        for (int i = 0; i < 8; i++) begin
          tx_gu_q[i] <= '0; tx_gv_q[i] <= '0; tx_gm_q[i] <= '0;
          tx_gw_q[i] <= '0; tx_gb_q[i] <= '0;
        end
        for (int i = 0; i < 4; i++) begin
          tx_acc_q[i] <= '0; tx_acc1_q[i] <= '0; tx_ch_q[i] <= '0;
          tx_fc_q[i] <= '0;
          tx_se_i_q[i] <= '0; tx_se_l_q[i] <= '0;
        end
        tx_lode_q <= '0; tx_lin_q <= '0;
        for (int c = 0; c < VEC; c++) txfa_q[c] <= '0;
        tx_1lane_q <= '0;
        tx_ta_q <= '0; tx_bpp_q <= '0; tx_tw_q <= '0;
        tx_brd_q <= '0; tx_bcol_q <= '0; tx_bad_q <= '0;
        tx_stb_q <= '0; tx_se_c_q <= '0;
        tx_se_lo_q <= '0; tx_se_hi_q <= '0;
        txc_v_q <= '0; txc_tag_q <= '0; txc_vic_q <= '0;
        txc_fi_q <= '0; txc_ln_q <= '0; txc_addr_q <= '0;
        tx_wbe_q <= '0;
        tx_samp_q <= '0; tx_isflt_q <= '0; tx_isint_q <= '0;
        tx_issr_q <= '0; tx_isf16_q <= '0; tx_nch_q <= '0;
        for (int i = 0; i < 32; i++) push_q[i] <= '0;
        eoff_q <= '0; escratch_q <= '0;
        lx_q <= '0; ly_q <= '0; lz_q <= '0; ninit_q <= '0;
        wgx_q <= '0; wgy_q <= '0; wgz_q <= '0;
        wave_q <= '0; nwaves_q <= '0; tot_q <= '0;
        for (int w = 0; w < MaxWaves; w++) begin
          pc_q[w] <= '0; cmask_q[w] <= '0; clbl_q[w] <= '0;
          cfn_q[w] <= '0; wselm_q[w] <= '0;
          for (int l = 0; l < LAN; l++) begin
            cprev_q[w][l] <= '0; ctgt_q[w][l] <= '0;
          end
          for (int e = 0; e < CFD; e++) begin
            cfk_q[w][e] <= '0; cfm_q[w][e] <= '0; cfc_q[w][e] <= '0;
            cfr_q[w][e] <= '0; cfp_q[w][e] <= '0; cfx_q[w][e] <= '0;
          end
        end
        wfin_q <= '0; wbar_q <= '0; wsel_q <= '0;
        wsw_q <= '0; nbar_q <= '0; nmem_q <= '0;
        opc_q <= '0; wc_q <= '0;
        for (int i = 0; i < OPB; i++) ops_q[i] <= '0;
        rkind_q <= '0; rcomps_q <= '0; rcols_q <= '0; relem_q <= '0;
        ncomp_q <= '0; ot_comps_q <= '0; ot_kind_q <= '0;
        ot_cols_q <= '0;
        for (int i = 0; i < 4; i++) begin
          va_q[i] <= '0; vty_q[i] <= '0; otag_q[i] <= '0;
          oidx_q[i] <= '0; ocst_q[i] <= '0;
        end
        phr_q <= '0; pi_q <= '0; phhit_q <= '0; phm_q <= '0;
        phtag_q <= '0; phidx_q <= '0; phaux_q <= '0;
        ma_q <= '0; mb_q <= '0;
        mi_q <= '0; mk_q <= '0; mph_q <= '0;
        mrr_q <= '0; mrc_q <= '0; mkd_q <= '0;
        mac_q <= '0; macl_q <= '0; mbc_q <= '0; mbcl_q <= '0;
        mrd_q <= '0; mrds_q <= '0; mdst_q <= '0; mret_q <= W_EX;
        ccr_q <= '0; cmj_q <= '0; cmc_q <= '0;
        moc_q <= '0; mocl_q <= '0;
        nva_q <= '0; vk_q <= '0; res_id_q <= '0; res_slot_q <= '0;
        vix_q <= '0; ccp_q <= '0;
        cty_q <= '0; poff_q <= '0; ctag_q <= '0; ck_q <= '0;
        cmstride_q <= '0; cty2_q <= '0;
        wb_q <= '0; wbm_q <= '0; wreg_q <= '0;
        xq_q <= '0; xop_q <= '0; jmode_q <= '0;
        xsub_q <= '0; xcall_q <= '0; xret_q <= '0; xret_st_q <= W_EX;
        ja_q <= '0; jb_q <= '0; jc_q <= '0; jdst_q <= '0;
        t0_q <= '0; t1_q <= '0; t2_q <= '0; tc_q <= '0; jdot_q <= '0;
        jrev_q <= '0;
        ls_lane_q <= '0; ls_comp_q <= '0; ls_off_q <= '0;
        ls_sc_q <= '0; ls_bi_q <= '0; ls_store_q <= '0;
        ls_bind_q <= '0; ls_bsz_q <= '0; ls_bok_q <= '0;
        ls_rec_q <= 1'b0;
        ls_addr_q <= '0;
        insns_q <= '0; robust_q <= '0; wait_q <= '0;
        done_code_q <= '0; fl_pc_q <= '0; fl_wave_q <= '0;
        init_i_q <= '0; oty_id_q <= '0; cmb_q <= '0;
        al_ty_q <= '0; al_ty2_q <= '0;
        al_sz_q <= '0; al_off_q <= '0; al_st_q <= '0;
        for (int l = 0; l < LAN; l++) begin
          dv_d_q[l] <= '0; dv_q_q[l] <= '0; dv_r_q[l] <= '0;
          dv_as_q[l] <= '0; dv_bs_q[l] <= '0;
        end
        dv_i_q <= '0; dv_sg_q <= '0; dv_sr_q <= '0;
        dv_md_q <= '0; dv_sm_q <= '0; dv_init_q <= '0;
        fu_got_q <= '0; fu_dn_q <= '0;
        dq_got_q <= '0; dq_dn_q <= '0;
        cv_got_q <= '0; cv_dn_q <= '0;
        nc_got_q <= '0; nc_dn_q <= '0;
        fuact_q <= '0; dqact_q <= '0; cvact_q <= '0; ncact_q <= '0;
        ot_elem_q <= '0; al_ty_q <= '0;
        // G3a-i: call stack / dead lanes / FS tail / DM microprogram
        for (int w = 0; w < MaxWaves; w++) begin
          csp_q[w] <= '0; dead_q[w] <= '0;
          for (int d = 0; d < CLD; d++) begin
            cfret_q[w][d] <= '0; cres_q[w][d] <= '0;
            cresn_q[w][d] <= '0; cclbl_q[w][d] <= '0;
            cfln_q[w][d] <= '0; cfdn_q[w][d] <= '0;
            ccfn_q[w][d] <= '0;
          end
        end
        ghelp_q <= '0; frow_q <= '0; fpk_q <= '0; fkr_q <= '0;
        fpr_q <= '0; fatag_q <= '0; faidx_q <= '0;
        resn_q <= '0; rsz_q <= '0;
        f8l_q <= '0; f8b_q <= '0; f8d_q <= '0; fslate_q <= 1'b0;
        at_old_q <= '0; at_new_q <= '0; at_op_q <= '0;
        dmph_q <= '0; dmcol_q <= '0; dmp_q <= '0;
        for (int k = 0; k < 4; k++) begin
          dtm_q[k] <= '0; dres_q[k] <= '0;
        end
        ls_ps_q <= '0; ls_tsrc_q <= '0; ls_wbb_q <= '0;
        ls_atom_q <= '0; ls_mat_q <= '0; ls_dyn_q <= '0;
        wb2_q <= '0; xk_q <= '0;
        done_o <= 1'b0;
      end else begin
        done_o <= 1'b0;
        // bounded waits: only the unit-wait states count cycles
        if (st_q == W_FU0 || st_q == W_FU1 || st_q == W_DQ0 ||
            st_q == W_DQ1 || st_q == W_CVT0 || st_q == W_CVT1 ||
            st_q == W_NC0 || st_q == W_NC1 || st_q == W_LS1 ||
            st_q == W_LS2 || st_q == W_SSB1)
          wait_q <= (wait_q != 16'hFFFF) ? wait_q + 1 : wait_q;
        else wait_q <= '0;
        if (wait_q > 16'(WaitBound)) begin
          done_code_q <= APU_SH_DONE_FAULT;
          fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
          st_q <= W_DONE;
        end else unique case (st_q)
          // -------------------------------------------------- dispatch --
          W_IDLE: if (disp_i) begin
            slot_q <= disp_pl_i.slot;
            gx_q <= disp_pl_i.gx; gy_q <= disp_pl_i.gy;
            gz_q <= disp_pl_i.gz; wid_q <= disp_pl_i.work_id;
            // graphics wave work: the pseudo-ctype rides in work_id
            gfx_q <= (disp_pl_i.work_id == APU_SH_WORK_VS) ? APU_SH_GFX_VS
                   : (disp_pl_i.work_id == APU_SH_WORK_FS) ? APU_SH_GFX_FS
                                                         : APU_SH_GFX_NONE;
            gcnt_q     <= disp_pl_i.imm[31:0];
            in_base_q  <= disp_pl_i.imm[63:32];
            out_base_q <= disp_pl_i.imm[95:64];
            vbase_q    <= disp_pl_i.imm[127:96];
            inst_q     <= disp_pl_i.imm[159:128];
            frontf_q   <= disp_pl_i.imm[96];   // imm[3].0 (FS)
            ghelp_q    <= disp_pl_i.imm[223:160];  // imm[5:6] helper mask
            push_n_q <= push_n_i;
            // F5: desc_i stays live (cmdexec holds it through
            // work_done); the record cache is dispatch-scoped, and
            // so is the 5b texture cache
            dc_v_q  <= '0;
            dc_vic_q <= '0;
            txc_v_q <= '0;
            txc_vic_q <= '0;
            for (int i = 0; i < 32; i++)
              push_q[i] <= push_i[i*32 +: 32];
            wgx_q <= '0; wgy_q <= '0; wgz_q <= '0;
            wave_q <= '0; insns_q <= '0; robust_q <= '0;
            done_code_q <= '0; wait_q <= '0;
            wsw_q <= '0; nbar_q <= '0; nmem_q <= '0;
            st_q <= W_ENT0;
          end
          W_ENT0: st_q <= W_ENT1;       // entry read issued
          W_ENT1: begin
            eoff_q <= entry_data_i[15:0];
            lx_q <= entry_data_i[39:32]; ly_q <= entry_data_i[47:40];
            lz_q <= entry_data_i[55:48]; ninit_q <= entry_data_i[63:56];
            escratch_q <= entry_data_i[79:64];
            fslate_q <= entry_data_i[123];  // FS late-Z: slot-8 tail writes
            // graphics wave work: tot = the record count; the lanes of
            // wave w are records w*LAN .. w*LAN+LAN-1
            tot_q <= (gfx_q != APU_SH_GFX_NONE) ? gcnt_q
                     : 32'(entry_data_i[39:32]) *
                       32'(entry_data_i[47:40]) *
                       32'(entry_data_i[55:48]);
            // waves per workgroup, capped at the RF depth; local sizes
            // beyond LAN*MaxWaves invocations are a config violation.
            nwaves_q <= (gfx_q != APU_SH_GFX_NONE)
              ? (((gcnt_q + LAN - 1) / LAN > MaxWaves)
                 ? 8'(MaxWaves)
                 : 8'((gcnt_q + LAN - 1) / LAN))
              : ((32'(entry_data_i[39:32]) * 32'(entry_data_i[47:40]) *
                  32'(entry_data_i[55:48]) + LAN - 1) / LAN > MaxWaves)
                ? 8'(MaxWaves)
                : 8'((32'(entry_data_i[39:32]) * 32'(entry_data_i[47:40]) *
                      32'(entry_data_i[55:48]) + LAN - 1) / LAN);
            wfin_q <= '0; wbar_q <= '0; wave_q <= '0;
            init_i_q <= '0;
            st_q <= W_IW0;
          end
          // ------------------------------------------- wave reg init --
          // Per wave of the workgroup: walk the init rows (pointer regs),
          // clear that wave's lane scratch, then seed its control state.
          W_IW0: begin
            if (init_i_q >= 16'(ninit_q)) begin
              init_i_q <= '0; ls_lane_q <= '0; ls_comp_q <= '0;
              st_q <= W_SC0;
            end else st_q <= W_IW1;
          end
          W_IW1: begin                  // init row arrived; RF write
            init_i_q <= init_i_q + 1;
            st_q <= W_IW0;
          end
          // per-lane scratch words cleared (sc write in the port comb)
          W_SC0: begin
            // bound capped at the per-lane scratch depth: an entry
            // claiming more must never wrap into another lane's space
            if ({18'h0, ls_comp_q} + 1 <
                ((({16'h0, escratch_q} + 3) >> 2) > 32'(SCW)
                 ? 32'(SCW) : (({16'h0, escratch_q} + 3) >> 2))) begin
              ls_comp_q <= ls_comp_q + 1;
            end else if (ls_lane_q + 1 < LAN) begin
              ls_comp_q <= '0; ls_lane_q <= ls_lane_q + 1;
            end else begin
              // wave control state (§7c): full or partial lane mask,
              // empty reconvergence stack, pc at the entry label.
              for (int l = 0; l < LAN; l++) begin
                cmask_q[wave_q][l] <=
                  (32'(wave_q) * LAN + l) < tot_q;
                cprev_q[wave_q][l] <= '0;
                ctgt_q[wave_q][l]  <= '0;
              end
              // call stack + dead-lane state are per-dispatch too: a
              // faulted previous wave (DONE_FAULT leaves csp mid-push)
              // must not leak into this one
              csp_q[wave_q]   <= '0;
              dead_q[wave_q]  <= '0;
              clbl_q[wave_q]  <= '0;
              cfn_q[wave_q]   <= '0;
              wsel_q[wave_q]  <= 1'b0;
              wselm_q[wave_q] <= '0;
              pc_q[wave_q]    <= eoff_q;
              ls_lane_q <= '0; ls_comp_q <= '0;
              if (32'(wave_q) + 1 < 32'(nwaves_q)) begin
                wave_q <= wave_q + 1; st_q <= W_IW0;
              end else begin
                wave_q <= '0; ls_off_q <= '0; st_q <= W_SCLR;
              end
            end
          end
          // per-workgroup shared slab zero (sb write in the port comb)
          W_SCLR: begin
            if ({16'h0, ls_off_q} + 4 < SLW * 4) begin
              ls_off_q <= ls_off_q + 4;
            end else begin
              ls_off_q <= '0; st_q <= W_SCHED;
            end
          end
          // ---------------------------------------------------- fetch --
          W_F0: begin wait_q <= '0; st_q <= W_F1; end
          W_F1: begin
            wc_q <= prog_data_i[31:16];
            opc_q <= prog_data_i[15:0];
            if (prog_data_i[31:16] == 0 ||
                prog_data_i[31:16] > 16'(OPB) + 1 ||
                32'(pc_q[wave_q]) + prog_data_i[31:16] >
                32'(ShaderWords)) begin
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else begin
              vk_q <= '0;
              st_q <= (prog_data_i[31:16] > 1) ? W_LD0 : W_TY0A;
            end
          end
          W_LD0: st_q <= W_LD1;
          W_LD1: begin
            ops_q[vk_q[4:0]] <= prog_data_i;
            if (vk_q + 1 >= 16'(wc_q) - 1) begin
              vk_q <= '0; st_q <= W_TY0A;
            end else begin
              vk_q <= vk_q + 1; st_q <= W_LD0;
            end
          end
          // ------------------------------ result-type / operand resolve
          W_TY0A: begin
            nva_q <= f_nva(opc_q, wc_q, ops_q);
            if (f_has_rty(opc_q)) st_q <= W_TY0;
            else begin
              ncomp_q <= 4'd1;
              // nva==0 result ops (OpUndef) still need the W_RW0
              // result-row lookup — skipping it leaves wreg_q stale
              // and W_WB clobbers the previous instruction's row.
              st_q <= (f_nva(opc_q, wc_q, ops_q) != 0) ? W_RMI : W_RW0;
            end
          end
          W_TY0: st_q <= W_TY1;
          W_TY1: begin
            rkind_q <= ty_kind; rcomps_q <= ty_comps;
            rcols_q <= ty_cols;
            relem_q <= ty_elem;
            rsz_q   <= ty_size;
            ncomp_q <= 4'(f_nc(ty_comps));
            vk_q <= '0;
            st_q <= (nva_q != 0) ? W_RMI : W_RW0;
          end
          W_OT0: st_q <= W_OT1;
          W_OT1: begin
            ot_comps_q <= f_nc(ty_comps);
            ot_kind_q  <= ty_kind;
            ot_cols_q  <= ty_cols;
            ot_elem_q <= ty_elem;
            if (opc_q == 62)
              ncomp_q <= (ty_kind == APU_SH_TK_MAT)
                         ? 5'(ty_cols) * {2'b0, f_nc(ty_comps)}
                         : 5'(f_nc(ty_comps));
            st_q <= W_EX;
          end
          W_RMI: begin
            if (vk_q >= nva_q) begin
              vk_q <= '0; st_q <= W_RW0;
            end else begin
              res_id_q <= f_opid10(opc_q, vk_q, ops_q);
              res_slot_q <= vk_q[2:0];
              st_q <= W_RMC;
            end
          end
          // result-id regmap lookup: the RF index for ops_q[1]
          W_RW0: st_q <= W_RW1;
          W_RW1: begin
            wreg_q <= rm_idx[RI-1:0];
            st_q <= W_PRE;
          end
          W_RMC: begin
            vty_q[res_slot_q] <= rm_tid;
            ridx_q <= rm_idx[RI-1:0];
            raux_q <= rm_aux;
            otag_q[res_slot_q] <= rm_tag;
            oidx_q[res_slot_q] <= rm_idx[RI-1:0];
            st_q <= (rm_tag == APU_SH_RT_CONST) ? W_CV0 : W_RV0;
          end
          W_CV0: st_q <= W_CV1;
          W_CV1: begin
            ocst_q[res_slot_q] <= const_data_i;
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                va_q[res_slot_q][l][c] <=
                  const_data_i[32 * ((c < raux_q) ? c : 0) +: 32];
            vk_q <= vk_q + 1; st_q <= W_RMI;
          end
          W_RV0: st_q <= W_RV1;
          W_RV1: begin
            va_q[res_slot_q] <= rf_rdata;
            vk_q <= vk_q + 1; st_q <= W_RMI;
          end
          // composite construct: merge each resolved constituent
          W_CC0: st_q <= W_CC1;
          W_CC1: begin
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                if (c < f_nc(ty_comps))
                  wb_q[l][ccp_q + c] <= va_q[vk_q[2:0]][l][c];
            ccp_q <= ccp_q + f_nc(ty_comps);
            vk_q <= vk_q + 1;
            st_q <= (vk_q + 1 >= nva_q) ? W_WB : W_CC0;
          end
          // ------------------ pre-exec: extra operand type reads ------
          W_PRE: begin
            unique case (opc_q)
              62:  begin oty_id_q <= vty_q[1]; st_q <= W_OT0; end
              81:  begin oty_id_q <= vty_q[0]; st_q <= W_OT0; end
              142,148,169:
                   begin oty_id_q <= vty_q[0]; st_q <= W_OT0; end
              // G3a-ii: proj-sample ops need the coordinate operand's
              // vector width — the divisor is its last component
              91,92,93,94:
                   begin oty_id_q <= vty_q[1]; st_q <= W_OT0; end
              65,66: begin
                // chain: pointer's pointee type = elem of its PTR type
                oty_id_q <= vty_q[0]; st_q <= W_OT0;
              end
              68:  st_q <= W_AL0;
              80:  begin vk_q <= '0; ccp_q <= '0;
                         if (rkind_q == APU_SH_TK_MAT) begin
                           ccr_q <= '0; st_q <= W_CM0;
                         end else begin
                           wbm_q <= 4'b1111; st_q <= W_CC0;
                         end
                   end
              12:  begin
                xnum_q <= ops_q[3][6:0];
                // operand-0 shape needed: matrix ops (33/34) and the
                // vector-geometry family (66,67,69,70,71,72)
                if (ops_q[3][6:0] == 66 || ops_q[3][6:0] == 67 ||
                    ops_q[3][6:0] == 69 || ops_q[3][6:0] == 70 ||
                    ops_q[3][6:0] == 71 || ops_q[3][6:0] == 72 ||
                    ops_q[3][6:0] == 33 || ops_q[3][6:0] == 34) begin
                  oty_id_q <= vty_q[0]; st_q <= W_OT0;
                end else st_q <= W_EX;
              end
              default: st_q <= W_EX;
            endcase
          end
          // -------------------------------------------------- execute --
          W_EX: begin
            // wb mask = result comps; ExtInst micro-steps re-enter W_EX
            // via W_XCNT with ncomp_q repurposed for the step's element
            // count, so only latch it on the first entry (xq==0) —
            // and never on an xcall re-entry (the texture λ path calls
            // the SFU log2 core through W_EX with xq=0/ncomp=1, which
            // would otherwise collapse the sample result's wbm to
            // comp0 and drop comps 1-3 of the written-back vec4)
            if (xq_q == 0 && !xcall_q)
              wbm_q <= 4'((4'b1 << ncomp_q) - 1);
            // §7d: while an SFU micro-sequence core or epilogue owns
            // the wave, sfu_step() takes precedence over the opcode
            // dispatch (it is re-entered from W_XCNT between unit jobs
            // exactly like the extinst step arms).
            if (xsub_q != 6'd0) sfu_step();
            else
            unique case (opc_q)
              // combinational integer/bool/bitcast/select ops
              124,126,127,128,130,132,164,165,166,167,168,169,170,171,
              172,173,174,175,176,177,178,179,194,195,196,197,198,199,
              200: begin
                wb_q <= int_alu;
                st_q <= W_WB;
              end
              // fpnew fma ops
              // fpnew_fma ADD = ops[1]+ops[2], SUB = ops[1]-ops[2]
              // (operand A is forced to +1.0 internally)
              129: jset(0, 5'd0, {2'd0, S_ZERO}, {2'd0, S_V0},
                        {2'd0, S_V1}, 0, 0, W_WB);            // FAdd
              131: jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V0},
                        {2'd0, S_V1}, 0, 0, W_WB);            // FSub
              133: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_V1},
                        {2'd0, S_ZERO}, 0, 0, W_WB);          // FMul
              142: jset(0, 5'd2, {2'd0, S_V0}, {2'd1, S_V1},
                        {2'd0, S_ZERO}, 0, 0, W_WB);        // Vec*Scalar
              148: unique case (xq_q)                          // OpDot
                // lavapipe (Mesa 25.2.8, ffma lowered to mul+add):
                // fdot3 = (m2+m1)+m0 — products first, then a
                // right-leaning fadd tree.  Reproduce it as a MUL
                // sweep into t1 followed by a reverse-order fadd
                // fold (tc0: m_{n-1}*1.0; tc>0: m_c*1.0 + acc —
                // FMADD with b=1.0 is exactly round(m_c + acc)).
                0: begin
                  ncomp_q <= 4'(ot_comps_q);
                  jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_V1},
                       {2'd0, S_ZERO}, 2, 0, W_XCNT);    // m_c → t1
                end
                default:
                  jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                       {2'd0, S_T0}, 0, 1, W_WB, 1'b0, 1'b1);
              endcase
              136: jset(1, 5'd0, {2'd0, S_V0}, {2'd0, S_V1}, 7'h0,
                        0, 0, W_WB);                          // FDiv
              // converts: {mod,rnd,i2f}; F2I uses RTZ, I2F RNE,
              // mod=1 selects the UNSIGNED int side (fpnew_cast
              // convention: int_sign = msb & ~op_mod)
              109: jset(2, {1'b1, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, 7'h0, 7'h0, 0, 0, W_WB);  // FToU
              110: jset(2, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, 7'h0, 7'h0, 0, 0, W_WB);  // FToS
              111: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                        {2'd0, S_V0}, 7'h0, 7'h0, 0, 0, W_WB);  // SToF
              112: jset(2, {1'b1, fpnew_pkg::RNE[2:0], 1'b1},
                        {2'd0, S_V0}, 7'h0, 7'h0, 0, 0, W_WB);  // UToF
              // fp compares via noncomp CMP (180..191);
              // rnd selects predicate (RNE=LE, RTZ=LT, RDN=EQ),
              // mod inverts; FUnord* map to the same predicates
              // (EQ's NaN→mod rule gives FUNE's NaN→true for free)
              180: jset(3, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FOE
              181: jset(3, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FUE
              182: jset(3, {1'b1, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FONE
              183: jset(3, {1'b1, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FUNE
              184: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FOLT
              185: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FULT
              186: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 7'h0, 0, 0,
                        W_WB);                                // FOGT
              187: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 7'h0, 0, 0,
                        W_WB);                                // FUGT
              188: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FOLE
              189: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                        W_WB);                                // FULE
              190: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 7'h0, 0, 0,
                        W_WB);                                // FOGE
              191: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 7'h0, 0, 0,
                        W_WB);                                // FUGE
              // integer div/rem/mod (shared per-lane divider)
              134,135,137,138,139: begin
                dv_i_q <= '0; dv_init_q <= 1'b1;
                dv_sg_q <= (opc_q == 135 || opc_q == 138 ||
                            opc_q == 139);
                dv_md_q <= (opc_q != 134 && opc_q != 135);
                dv_sm_q <= (opc_q == 139);
                tc_q <= '0; ret_q <= W_WB; st_q <= W_IDIV;
              end
              // §12.3 C/5b: image/sampler ops — SampledImage (86),
              // SampleImplicitLod (87, G2b), SampleExplicitLod (88),
              // ImageFetch (95), ImageRead (98), ImageWrite (99),
              // OpImage (100), QuerySizeLod (103), QuerySize (104),
              // QueryLevels (106)
              // G3a-ii: projected forms divide the coord first
              91,92,93,94: st_q <= W_TXJ0;
              86,87,88,89,90,95,96,97,98,99,100,103,104,105,106:
                           st_q <= W_TX0;
              // G2b derivative ops: quad = lanes {4k..4k+3}.
              // Fine: dPdx(l)=v[l|1]-v[l&~1], dPdy(l)=v[l|2]-v[l&~2];
              // coarse and the non-suffixed forms broadcast the
              // lane-0-based pair (q+1-q / q+2-q).  dla/dlb pick the
              // remap, dva=0 reads the single operand slot.
              207,213: begin                    // DPdx / DPdxCoarse
                dva_q <= '0; dla_q <= 3'd6; dlb_q <= 3'd5;
                jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                     {2'd0, S_VDB}, 0, 0, W_WB);
              end
              210: begin                        // DPdxFine
                dva_q <= '0; dla_q <= 3'd1; dlb_q <= 3'd2;
                jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                     {2'd0, S_VDB}, 0, 0, W_WB);
              end
              208,214: begin                    // DPdy / DPdyCoarse
                dva_q <= '0; dla_q <= 3'd7; dlb_q <= 3'd5;
                jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                     {2'd0, S_VDB}, 0, 0, W_WB);
              end
              211: begin                        // DPdyFine
                dva_q <= '0; dla_q <= 3'd3; dlb_q <= 3'd4;
                jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                     {2'd0, S_VDB}, 0, 0, W_WB);
              end
              // Fwidth = |dPdx| + |dPdy|: dx into t0, dy into t1,
              // then the |a|+|b| add (209 nonsuffix = coarse)
              209,212,215: unique case (xq_q)
                0: begin
                  dva_q <= '0;
                  {dla_q, dlb_q} <= (opc_q == 16'd212)
                                    ? {3'd1, 3'd2} : {3'd6, 3'd5};
                  jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                       {2'd0, S_VDB}, 1, 0, W_XCNT);
                end
                1: begin
                  {dla_q, dlb_q} <= (opc_q == 16'd212)
                                    ? {3'd3, 3'd4} : {3'd7, 3'd5};
                  jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                       {2'd0, S_VDB}, 2, 0, W_XCNT);
                end
                default:
                  jset(0, 5'd0, {2'd0, S_ZERO}, {2'd0, S_AT0},
                       {2'd0, S_AT1}, 0, 0, W_WB);
              endcase
              // memory / pointer ops
              61,62: begin
                ls_store_q <= (opc_q == 62);
                ls_atom_q <= 1'b0; ls_ps_q <= 1'b0;
                ls_tsrc_q <= 1'b0; ls_wbb_q <= 1'b0;
                ls_lane_q <= '0; ls_comp_q <= '0;
                lcc_q <= '0; lrc_q <= '0;
                // matrix results/operands walk columns as RF rows
                // (§7c): flat word stream over cols*comps on the bus
                // side, per-column rows on the RF side.
                if (opc_q == 61 && rkind_q == APU_SH_TK_MAT) begin
                  ls_mat_q <= 1'b1;
                  ncomp_q <= 5'(rcols_q) * {2'b0, rcomps_q};
                end else if (opc_q == 61 &&
                             (rkind_q == APU_SH_TK_IMG ||
                              rkind_q == APU_SH_TK_SAMP ||
                              rkind_q == APU_SH_TK_SIMG)) begin
                  // §12.3 C/5b: an image/sampler "load" yields the
                  // descriptor reference — the pointer record passes
                  // through verbatim ({off, tag, elem idx}).
                  ls_mat_q <= 1'b0;
                  wb_q <= va_q[0];
                  wbm_q <= 4'b1111;
                  st_q <= W_WB;
                end else if (opc_q == 62 &&
                             ot_kind_q == APU_SH_TK_MAT)
                  ls_mat_q <= 1'b1;
                else ls_mat_q <= 1'b0;
                if (!(opc_q == 61 &&
                      (rkind_q == APU_SH_TK_IMG ||
                       rkind_q == APU_SH_TK_SAMP ||
                       rkind_q == APU_SH_TK_SIMG)))
                  st_q <= (opc_q == 62 && ot_kind_q == APU_SH_TK_MAT &&
                           otag_q[1] != APU_SH_RT_CONST)
                          ? W_SMR0 : W_LS0;
              end
              65,66: begin
                // walk starts at the pointer's pointee type
                cty_q <= ot_elem_q;
                ck_q <= '0;
                for (int l = 0; l < LAN; l++) begin
                  poff_q[l][0] <= va_q[0][l][0];
                  poff_q[l][1] <= va_q[0][l][1];
                  // F5: an already-indexed pointer keeps its
                  // descriptor element through a re-chain
                  poff_q[l][2] <= va_q[0][l][2];
                end
                ctag_q <= va_q[0][0][1];
                cmstride_q <= '0;
                if (wc_q > 4) begin
                  res_id_q <= ops_q[3][9:0]; st_q <= W_IR0;
                end else begin
                  wb_q <= va_q[0]; st_q <= W_WB;
                end
              end
              68: st_q <= W_AL0;
              // composites
              79: begin                            // VectorShuffle
                for (int l = 0; l < LAN; l++)
                  for (int c = 0; c < VEC; c++) begin
                    wb_q[l][c] <=
                      (c >= ncomp_q || ops_q[4 + c] == 32'hFFFF_FFFF)
                      ? 32'h0
                      : (ops_q[4 + c][2] ? va_q[1][l][ops_q[4+c][1:0]]
                                         : va_q[0][l][ops_q[4+c][1:0]]);
                  end
                st_q <= W_WB;
              end
              81: begin                            // CompositeExtract
                if (ot_kind_q == APU_SH_TK_MAT) begin
                  // matrix operand: [col] column extract (vector
                  // result) or [col][comp] element extract (scalar).
                  // RF-resident matrix: one extra column-row read.
                  if (otag_q[0] == APU_SH_RT_CONST) begin
                    if (wc_q > 4)
                      for (int l = 0; l < LAN; l++)
                        wb_q[l][0] <= ocst_q[0]
                            [32*(ops_q[3][1:0] * {2'b0, ot_comps_q}
                                 + ops_q[4][1:0]) +: 32];
                    else
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          wb_q[l][c] <= ocst_q[0]
                              [32*(ops_q[3][1:0] * {2'b0, ot_comps_q}
                                   + c[1:0]) +: 32];
                    st_q <= W_WB;
                  end else
                    st_q <= W_XC0;
                end else begin
                  for (int l = 0; l < LAN; l++)
                    wb_q[l][0] <= va_q[0][l][ops_q[3][1:0]];
                  st_q <= W_WB;
                end
              end
              82: begin                            // CompositeInsert
                wb_q <= va_q[1];
                for (int l = 0; l < LAN; l++)
                  wb_q[l][ops_q[4][1:0]] <= va_q[0][l][0];
                st_q <= W_WB;
              end
              // -------------------- G3a-i ---------------------------
              1:   begin wb_q <= '0;      st_q <= W_WB; end  // Undef
              83:  begin wb_q <= va_q[0]; st_q <= W_WB; end  // CopyObj
              // Any/All/IsNan/IsInf + the bitfield family — int_alu
              154,155,156,157,201,202,203,204,205:
                   begin wb_q <= int_alu; st_q <= W_WB; end
              // {lo,hi} struct results pack flat-interleaved word
              // pairs (4/row): a 2-word scalar result needs comps 0-1
              // of row 0 — wbm must cover rsz/4 flat words, and the
              // second row (comps 2/3 pairs in int_alu2) is written
              // only when the result image actually spans two rows.
              149,150,151,152: begin
                wb_q <= int_alu;
                wb2_q <= (rsz_q > 16'd16);
                wbm_q <= (rsz_q > 16'd16) ? 4'hF
                       : 4'((4'b1 << (rsz_q >> 2)) - 1);
                st_q <= W_WB;
              end
              77:  begin                       // VectorExtractDynamic
                for (int l = 0; l < LAN; l++)
                  wb_q[l][0] <= va_q[0][l][va_q[1][l][0][1:0]];
                st_q <= W_WB;
              end
              78:  begin                       // VectorInsertDynamic
                for (int l = 0; l < LAN; l++)
                  for (int c = 0; c < VEC; c++)
                    wb_q[l][c] <=
                      (c == 32'(va_q[2][l][0][1:0])) ? va_q[1][l][0]
                                                     : va_q[0][l][c];
                st_q <= W_WB;
              end
              // FRem/FMod: q = a/b (div), q' = i2f(f2i(q, RTZ|RDN)),
              // r = a - q'*b — mirrors the model's fdiv→int→fsub order
              140,141: unique case (xq_q)
                0: jset(1, 5'd0, {2'd0, S_V0}, {2'd0, S_V1}, 7'h0,
                        1, 0, W_XCNT);
                1: jset(2, {1'b0, (opc_q == 16'd140)
                             ? fpnew_pkg::RTZ[2:0]
                             : fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_XCNT);
                2: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                        {2'd0, S_T1}, 7'h0, 7'h0, 2, 0, W_XCNT);
                3: jset(0, 5'd2, {2'd0, S_V1}, {2'd0, S_T1},
                        {2'd0, S_ZERO}, 2, 0, W_XCNT);
                default:
                  jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V0},
                       {2'd0, S_T1}, 0, 0, W_WB);
              endcase
              // ---- G3a-i atomics: lane-serial RMW through the LSU ---
              // W_LS0 resolves the pointer word's storage class;
              // SSBO goes through the descriptor path + W_ATx RMW,
              // Workgroup through W_ATSx on the slab port.
              227,228,229,230,232,233,234,235,236,237,238,239,240,
              241,242: begin
                at_op_q <= opc_q;
                ls_store_q <= (opc_q == 16'd228);   // AtomicStore only
                ls_atom_q <= 1'b1;
                ls_ps_q <= 1'b0; ls_tsrc_q <= 1'b0; ls_wbb_q <= 1'b0;
                ls_mat_q <= 1'b0; ls_dyn_q <= 1'b0;
                lcc_q <= '0; lrc_q <= '0;
                ncomp_q <= 5'd1;                    // one word/lane
                ls_comp_q <= '0; ls_lane_q <= '0;
                st_q <= W_LS0;
              end
              // DemoteToHelper: dead lane — keeps executing (registers
              // feed quad derivatives), side effects suppressed
              5380: begin
                dead_q[wave_q] <= dead_q[wave_q] | act_w;
                st_q <= W_NEXT;
              end
              5381: begin                          // IsHelperInvocation
                for (int l = 0; l < LAN; l++)
                  wb_q[l][0] <= {31'h0, hlp_w[l] | dead_q[wave_q][l]};
                st_q <= W_WB;
              end
              57:  st_q <= W_FN0;                  // OpFunctionCall
              254: st_q <= W_FR0;                  // OpReturnValue
              // §7c flow — evaluated by the reconvergence engine
              246,247,248,249,250,251,253,56,255,252,4416:
                   st_q <= W_CF0;
              224: begin                           // OpControlBarrier:
                wbar_q[wave_q] <= 1'b1;            // wave parks; the
                nbar_q <= nbar_q + 1;              // scheduler releases
                pc_q[wave_q] <= pc_q[wave_q] + wc_q; // when all arrive
                insns_q <= insns_q + 1;
                if (insns_q + 1 > ShaderBudget) begin
                  done_code_q <= APU_SH_DONE_BUDGET;
                  fl_pc_q <= pc_q[wave_q];
                  fl_wave_q <= {8'h0, wave_q};
                  st_q <= W_DONE;
                end else st_q <= W_SCHED;
              end
              225: begin                           // OpMemoryBarrier:
                nmem_q <= nmem_q + 1;              // no-op, recorded
                st_q <= W_NEXT;
              end
              245: st_q <= W_PH0;                  // OpPhi
              // matrix ops — lane micro-sequences over the OpDot fold
              84,143,144,145,146,147: begin
                mi_q <= '0; mph_q <= '0; st_q <= W_MS0;
              end
              // Function/Parameter/Nop/Variable — the W_IW init walk
              // already wrote every variable's pointer register, so
              // OpVariable in the body only advances the program
              // counter; the callee's OpFunction preamble and its
              // parameter records are just pc advances.
              54,55,59,0: st_q <= W_NEXT;
              // GLSL.std.450 — xnum_q = ext inst, xq_q = step
              12: begin
                unique case (xnum_q)
                  4,5,6,7,38,39,41,42,44,45: begin
                    wb_q <= int_alu; st_q <= W_WB;
                  end
                  // floor/round family: F2I(rnd)→t0, I2F→t1, guard→wb
                  8,9,3,1,2: unique case (xq_q)
                    0: begin
                      ret_q <= W_XCNT;
                      // F2I/I2F intermediate is signed (mod=0):
                      // negative inputs must survive to the guard
                      unique case (xnum_q)
                        8: jset(2, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                                {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                        9: jset(2, {1'b0, fpnew_pkg::RUP[2:0], 1'b0},
                                {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                        3: jset(2, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                                {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                        1: jset(2, {1'b0, fpnew_pkg::RMM[2:0], 1'b0},
                                {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                        default:
                          jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                               {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                      endcase
                    end
                    1: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_XCNT);
                    default: begin
                      // |x| >= 2^31 (exp >= 158) or NaN → integral
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          wb_q[l][c] <=
                            (f_nan(va_q[0][l][c]) ||
                             va_q[0][l][c][30:23] >= 8'd158)
                            ? va_q[0][l][c] : t1_q[l][c];
                      st_q <= W_WB;
                    end
                  endcase
                  10: unique case (xq_q)           // Fract = x - floor(x)
                    0: jset(2, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                            {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                    1: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_XCNT);
                    2: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          t1_q[l][c] <=
                            (f_nan(va_q[0][l][c]) ||
                             va_q[0][l][c][30:23] >= 8'd158)
                            ? va_q[0][l][c] : t1_q[l][c];
                      st_q <= W_XCNT;
                    end
                    default:
                      jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V0},
                           {2'd0, S_T1}, 0, 0, W_WB);
                  endcase
                  31: jset(1, 5'd1, {2'd0, S_V0}, 7'h0, 7'h0, 0, 0,
                           W_WB);                               // Sqrt
                  32: unique case (xq_q)                         // IvtSqrt
                    0: jset(1, 5'd1, {2'd0, S_V0}, 7'h0, 7'h0, 1, 0,
                            W_XCNT);
                    default:
                      jset(1, 5'd0, {2'd0, S_ONE}, {2'd0, S_T0}, 7'h0,
                           0, 0, W_WB);
                  endcase
                  // fpnew_noncomp MINMAX: rnd RNE=MIN, RTZ=MAX
                  37: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                           {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                           W_WB);                                // FMin
                  40: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                           {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 0, 0,
                           W_WB);                                // FMax
                  43: unique case (xq_q)                         // FClamp
                    0: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},  // max
                            {2'd0, S_V0}, {2'd0, S_V1}, 7'h0, 1, 0,
                            W_XCNT);
                    default:
                      jset(3, {1'b0, 3'b000, 1'b1},                // min
                           {2'd0, S_T0}, {2'd0, S_V2}, 7'h0, 0, 0,
                           W_WB);
                  endcase
                  46: unique case (xq_q)                         // FMix
                    // lavapipe nir_lower_flrp strict form:
                    // x*(1-t) + y*t (mul,mul,add — ffma is lowered)
                    0: jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_ONE},
                            {2'd0, S_V2}, 1, 0, W_XCNT);         // 1-t → t0
                    1: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_T0},
                            {2'd0, S_ZERO}, 2, 0, W_XCNT);       // x(1-t) → t1
                    2: jset(0, 5'd2, {2'd0, S_V1}, {2'd0, S_V2},
                            {2'd0, S_ZERO}, 3, 0, W_XCNT);       // yt → t2
                    default:
                      jset(0, 5'd0, {2'd0, S_ZERO}, {2'd0, S_T1},
                           {2'd0, S_T2}, 0, 0, W_WB);            // t1+t2
                  endcase
                  48: unique case (xq_q)                         // Step
                    0: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                            {2'd0, S_V1}, {2'd0, S_V0}, 7'h0, 1, 0,
                            W_XCNT);                             // x<edge
                    default: begin
                      wb_q <= int_alu; st_q <= W_WB;             // 0/1.0
                    end
                  endcase
                  49: unique case (xq_q)                         // SmoothSt
                    // lavapipe nir_smoothstep (ffma lowered):
                    // t = fsat((x-e0)/(e1-e0));
                    // r = t * (t * fadd(fmul(-2,t), 3))
                    0: jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V2},
                            {2'd0, S_V0}, 1, 0, W_XCNT);         // x-e0 → t0
                    1: jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V1},
                            {2'd0, S_V0}, 2, 0, W_XCNT);         // e1-e0 → t1
                    2: jset(1, 5'd0, {2'd0, S_T0}, {2'd0, S_T1}, 7'h0,
                            1, 0, W_XCNT);                       // t → t0
                    3: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                            {2'd0, S_T0}, {2'd0, S_ZERO}, 7'h0, 2, 0,
                            W_XCNT);                             // max(t,0) → t1
                    4: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T1}, {2'd0, S_ONE}, 7'h0, 2, 0,
                            W_XCNT);                             // min(t,1) → t1
                    5: jset(0, 5'd2, {2'd0, S_NEG2}, {2'd0, S_T1},
                            {2'd0, S_ZERO}, 3, 0, W_XCNT);       // -2t → t2
                    6: jset(0, 5'd0, {2'd0, S_ZERO}, {2'd0, S_THREE},
                            {2'd0, S_T2}, 1, 0, W_XCNT);         // 3-2t → t0
                    7: jset(0, 5'd2, {2'd0, S_T1}, {2'd0, S_T0},
                            {2'd0, S_ZERO}, 3, 0, W_XCNT);       // t(3-2t) → t2
                    default:
                      jset(0, 5'd2, {2'd0, S_T1}, {2'd0, S_T2},
                           {2'd0, S_ZERO}, 0, 0, W_WB);          // t·(t(3-2t))
                  endcase
                  50: unique case (xq_q)                         // Fma
                    // lavapipe lowers ffma to fmul+fadd
                    0: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_V1},
                            {2'd0, S_ZERO}, 1, 0, W_XCNT);       // a*b → t0
                    default:
                      jset(0, 5'd0, {2'd0, S_ZERO}, {2'd0, S_T0},
                           {2'd0, S_V2}, 0, 0, W_WB);            // t0+c
                  endcase
                  66: unique case (xq_q)                         // Length
                    0: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_V0},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT);   // m_c → t1
                    end
                    1: jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                            {2'd0, S_T0}, 1, 1, W_XCNT, 1'b0, 1'b1);
                    default:
                      jset(1, 5'd1, {2'd0, S_T0}, 7'h0, 7'h0, 0, 0,
                           W_WB);
                  endcase
                  67: unique case (xq_q)                         // Distance
                    0: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V0},
                           {2'd0, S_V1}, 1, 0, W_XCNT);          // a-b → t0
                    end
                    1: jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_T0},
                            {2'd0, S_ZERO}, 2, 0, W_XCNT);   // m_c → t1
                    2: jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                            {2'd0, S_T0}, 1, 1, W_XCNT, 1'b0, 1'b1);
                    default:
                      jset(1, 5'd1, {2'd0, S_T0}, 7'h0, 7'h0, 0, 0,
                           W_WB);
                  endcase
                  68: unique case (xq_q)                         // Cross
                    // t0 = {a1b2, a2b0, a0b1}; t1 = {a2b1, a0b2, a1b0}
                    0: begin ccc_q <= 0;
                      ncomp_q <= 4'd1;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 1, 0, W_XCNT, 1'b1, 1'b0,
                           2'd1, 2'd2); end
                    1: begin ccc_q <= 1;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 1, 0, W_XCNT, 1'b1, 1'b0,
                           2'd2, 2'd0); end
                    2: begin ccc_q <= 2;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 1, 0, W_XCNT, 1'b1, 1'b0,
                           2'd0, 2'd1); end
                    3: begin ccc_q <= 0;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT, 1'b1, 1'b0,
                           2'd2, 2'd1); end
                    4: begin ccc_q <= 1;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT, 1'b1, 1'b0,
                           2'd0, 2'd2); end
                    5: begin ccc_q <= 2;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT, 1'b1, 1'b0,
                           2'd1, 2'd0); end
                    default: begin
                      ncomp_q <= 4'd3;
                      jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_T0},
                           {2'd0, S_T1}, 0, 0, W_WB);
                    end
                  endcase
                  69: unique case (xq_q)                         // Normalize
                    0: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_V0},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT);   // m_c → t1
                    end
                    1: jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                            {2'd0, S_T0}, 1, 1, W_XCNT, 1'b0, 1'b1);
                    2: jset(1, 5'd1, {2'd0, S_T0}, 7'h0, 7'h0, 1, 0,
                            W_XCNT);                             // √dot
                    3: jset(1, 5'd0, {2'd0, S_ONE}, {2'd0, S_T0},
                            7'h0, 1, 0, W_XCNT);                 // 1/√dot
                    default: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd0, S_V0}, {2'd1, S_T0},
                           {2'd0, S_ZERO}, 0, 0, W_WB);
                    end
                  endcase
                  // ---- G3a-i --------------------------------------
                  // Determinant / MatrixInverse: operand matrix staged
                  // into dtm_q (W_DM0/1), then the generated cofactor
                  // micro-program DM_PROG runs on the scalar units;
                  // inverse columns flush from dres_q via W_DMF.
                  33, 34: begin
                    dmph_q <= 1'b0; dmcol_q <= '0;
                    if (ot_cols_q == 0 || ot_cols_q > 3'd4) begin
                      done_code_q <= APU_SH_DONE_FAULT;
                      fl_pc_q <= pc_q[wave_q];
                      fl_wave_q <= {8'h0, wave_q};
                      st_q <= W_DONE;
                    end else if (ot_cols_q == 3'd1) begin
                      if (xnum_q == 7'd33) begin     // mat1: det = m00
                        for (int l = 0; l < LAN; l++)
                          wb_q[l][0] <= va_q[0][l][0];
                        st_q <= W_WB;
                      end else begin               // inv = 1/m00
                        ncomp_q <= 5'd1;
                        jset(1, 5'd0, {2'd1, S_ONE}, {2'd1, S_V0},
                             7'h0, 0, 0, W_WB);
                      end
                    end else begin
                      unique case ({xnum_q == 7'd34, ot_cols_q[1:0]})
                        3'b000:  dmp_q <= 9'(DM_DET4);
                        3'b010:  dmp_q <= 9'(DM_DET2);
                        3'b011:  dmp_q <= 9'(DM_DET3);
                        3'b110:  dmp_q <= 9'(DM_INV2);
                        3'b111:  dmp_q <= 9'(DM_INV3);
                        default: dmp_q <= 9'(DM_INV4);   // 3'b100
                      endcase
                      st_q <= W_DM0;
                    end
                  end
                  // Modf: frac → wb result, ipart → *va1 (LSU, t1)
                  35: unique case (xq_q)
                    0: jset(2, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                            {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                    1: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_XCNT);
                    2: begin                      // ip → t1
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          t1_q[l][c] <=
                            (f_nan(va_q[0][l][c]) ||
                             va_q[0][l][c][30:23] >= 8'd158)
                            ? va_q[0][l][c] : t1_q[l][c];
                      st_q <= W_XCNT;
                    end
                    3: jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V0},
                            {2'd0, S_T1}, 0, 0, W_XCNT);   // fr → wb
                    default: begin                 // store ip = t1
                      ls_store_q <= 1'b1; ls_ps_q <= 1'b1;
                      ls_tsrc_q <= 1'b1; ls_wbb_q <= 1'b1;
                      ls_atom_q <= 1'b0; ls_mat_q <= 1'b0;
                      ls_dyn_q <= 1'b0;
                      ls_lane_q <= '0; ls_comp_q <= '0;
                      st_q <= W_LS0;
                    end
                  endcase
                  // ModfStruct: flat {frac(nc), ipart(nc)} rows
                  36: unique case (xq_q)
                    0: jset(2, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                            {2'd0, S_V0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                    1: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_XCNT);
                    2: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++) begin
                          t1_q[l][c] <=
                            (f_nan(va_q[0][l][c]) ||
                             va_q[0][l][c][30:23] >= 8'd158)
                            ? va_q[0][l][c] : t1_q[l][c];
                          t2_q[l][c] <= t1_q[l][c];
                        end
                      st_q <= W_XCNT;
                    end
                    3: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          t2_q[l][c] <=
                            (f_nan(va_q[0][l][c]) ||
                             va_q[0][l][c][30:23] >= 8'd158)
                            ? va_q[0][l][c] : t1_q[l][c];
                      jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_V0},
                           {2'd0, S_T1}, 0, 0, W_XCNT);    // fr → wb
                    end
                    // member1 packs flat at word offset m0 = member0's
                    // comp count; when the struct image fits one row
                    // it merges into wb_q here, else row+1 via wb2.
                    default: begin
                      if (rsz_q <= 16'd16)
                        for (int l = 0; l < LAN; l++)
                          for (int c = 0; c < VEC; c++)
                            if (5'(f_nc(ot_comps_q)) + 5'(c) < 5'd4)
                              wb_q[l][f_nc(ot_comps_q) + c] <=
                                t2_q[l][c];
                      wb2_q <= (rsz_q > 16'd16);
                      wbm_q <= (rsz_q > 16'd16) ? 4'hF
                             : 4'((4'b1 << (rsz_q >> 2)) - 1);
                      st_q <= W_WB;
                    end
                  endcase
                  // Frexp: frac → wb, exp → *va1 (int bits, LSU t1)
                  51: unique case (xq_q)
                    0: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++) begin
                          logic [7:0] ex;
                          ex = va_q[0][l][c][30:23];
                          t0_q[l][c] <= (ex == 0 || ex == 8'hFF)
                            ? va_q[0][l][c]
                            : (va_q[0][l][c] & 32'h807F_FFFF) |
                              32'h3F00_0000;
                          t1_q[l][c] <= (ex == 0 || ex == 8'hFF)
                            ? 32'h0 : {24'h0, ex} - 32'd126;
                        end
                      st_q <= W_XCNT;
                    end
                    1: begin                      // frac → wb
                      wb_q <= t0_q;
                      ls_store_q <= 1'b1; ls_ps_q <= 1'b1;
                      ls_tsrc_q <= 1'b1; ls_wbb_q <= 1'b1;
                      ls_atom_q <= 1'b0; ls_mat_q <= 1'b0;
                      ls_dyn_q <= 1'b0;
                      ls_lane_q <= '0; ls_comp_q <= '0;
                      st_q <= W_LS0;
                    end
                    default: st_q <= W_LS0;       // unreachable
                  endcase
                  // FrexpStruct: flat {frac(nc), exp(nc)} rows
                  52: unique case (xq_q)
                    0: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++) begin
                          logic [7:0] ex;
                          ex = va_q[0][l][c][30:23];
                          wb_q[l][c]  <= (ex == 0 || ex == 8'hFF)
                            ? va_q[0][l][c]
                            : (va_q[0][l][c] & 32'h807F_FFFF) |
                              32'h3F00_0000;
                          t2_q[l][c] <= (ex == 0 || ex == 8'hFF)
                            ? 32'h0 : {24'h0, ex} - 32'd126;
                        end
                      st_q <= W_XCNT;
                    end
                    // member1 packs flat at word offset m0 = member0's
                    // comp count; when the struct image fits one row
                    // it merges into wb_q here, else row+1 via wb2.
                    default: begin
                      if (rsz_q <= 16'd16)
                        for (int l = 0; l < LAN; l++)
                          for (int c = 0; c < VEC; c++)
                            if (5'(f_nc(ot_comps_q)) + 5'(c) < 5'd4)
                              wb_q[l][f_nc(ot_comps_q) + c] <=
                                t2_q[l][c];
                      wb2_q <= (rsz_q > 16'd16);
                      wbm_q <= (rsz_q > 16'd16) ? 4'hF
                             : 4'((4'b1 << (rsz_q >> 2)) - 1);
                      st_q <= W_WB;
                    end
                  endcase
                  53: begin                        // Ldexp (comb)
                    for (int l = 0; l < LAN; l++)
                      for (int c = 0; c < VEC; c++)
                        wb_q[l][c] <= f_ldexp(va_q[0][l][c],
                                              va_q[1][l][c]);
                    st_q <= W_WB;
                  end
                  // Pack{S,U}norm{4x8,2x16} / PackHalf2x16:
                  // clamp → *scale → f2i(RNE) → field fold
                  54, 55, 56, 57: unique case (xq_q)
                    0: begin
                      ncomp_q <= (xnum_q < 7'd56) ? 5'd4 : 5'd2;
                      xk_q <= (xnum_q == 7'd54) ? 32'h42FE_0000 :
                              (xnum_q == 7'd55) ? 32'h437F_0000 :
                              (xnum_q == 7'd56) ? 32'h46FF_FE00
                                                : 32'h477F_FF00;
                      jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                           {2'd0, S_V0},
                           (xnum_q == 7'd54 || xnum_q == 7'd56)
                             ? {2'd0, S_NEG1} : {2'd0, S_ZERO},
                           7'h0, 1, 0, W_XCNT);         // max(x,lo)
                    end
                    1: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, {2'd0, S_ONE}, 7'h0,
                            1, 0, W_XCNT);              // min(t,1)
                    2: jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_XK},
                            {2'd0, S_ZERO}, 1, 0, W_XCNT); // *scale
                    3: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                            {2'd0, S_T0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                    default: begin                   // fold fields
                      for (int l = 0; l < LAN; l++) begin
                        logic [31:0] pk;
                        pk = '0;
                        for (int c = 0; c < 4; c++)
                          if (c < ncomp_q)
                            pk |= (t0_q[l][c] &
                                   ((xnum_q < 7'd56) ? 32'hFF
                                                     : 32'hFFFF))
                                  << ((xnum_q < 7'd56) ? 8*c : 16*c);
                        wb_q[l][0] <= pk;
                      end
                      st_q <= W_WB;
                    end
                  endcase
                  58: begin                        // PackHalf2x16
                    for (int l = 0; l < LAN; l++) begin
                      logic [31:0] pk;
                      pk = {16'(f_f32_f16(va_q[0][l][1])),
                            f_f32_f16(va_q[0][l][0])};
                      wb_q[l][0] <= pk;
                    end
                    st_q <= W_WB;
                  end
                  // UnpackSnorm/Unorm2x16,4x8 / UnpackHalf2x16
                  62: begin
                    for (int l = 0; l < LAN; l++) begin
                      logic [31:0] u0, u1;
                      u0 = f_f16_f32(va_q[0][l][0][15:0]);
                      u1 = f_f16_f32(va_q[0][l][0][31:16]);
                      wb_q[l][0] <= u0;
                      wb_q[l][1] <= u1;
                    end
                    st_q <= W_WB;
                  end
                  60, 61, 63, 64: unique case (xq_q)
                    0: begin                       // extract + sext
                      ncomp_q <= (xnum_q == 7'd60 ||
                                  xnum_q == 7'd61) ? 5'd2 : 5'd4;
                      xk_q <= (xnum_q == 7'd60) ? 32'h46FF_FE00 :
                              (xnum_q == 7'd61) ? 32'h477F_FF00 :
                              (xnum_q == 7'd63) ? 32'h42FE_0000
                                                : 32'h437F_0000;
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++) begin
                          logic [31:0] u;
                          u = (xnum_q == 7'd60 || xnum_q == 7'd61)
                              ? (va_q[0][l][0] >> (16 * c)) &
                                32'hFFFF
                              : (va_q[0][l][0] >> (8 * c)) & 32'hFF;
                          if (xnum_q == 7'd60 || xnum_q == 7'd63) begin
                            if (xnum_q == 7'd60 && u[15])
                              u |= 32'hFFFF_0000;
                            if (xnum_q == 7'd63 && u[7])
                              u |= 32'hFFFF_FF00;
                          end
                          t0_q[l][c] <= u;
                        end
                      st_q <= W_XCNT;
                    end
                    1: jset(2, {(xnum_q == 7'd61 || xnum_q == 7'd64),
                               fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, 7'h0, 7'h0, 1, 0, W_XCNT);
                    2: jset(1, 5'd0, {2'd0, S_T0}, {2'd0, S_XK},
                            7'h0, 1, 0, W_XCNT);      // /scale → t0
                    3: begin
                      if (xnum_q == 7'd60 || xnum_q == 7'd63)
                        jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                             {2'd0, S_T0}, {2'd0, S_NEG1}, 7'h0,
                             1, 0, W_XCNT);           // max(t,-1)
                      else begin
                        wb_q <= t0_q; st_q <= W_WB;
                      end
                    end
                    4: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, {2'd0, S_ONE}, 7'h0,
                            1, 0, W_XCNT);              // min(t,1)
                    default: begin wb_q <= t0_q; st_q <= W_WB; end
                  endcase
                  // FaceForward(N,I,Nref) = (dot(Nref,I) < 0) ? N : -N
                  70: unique case (xq_q)
                    0: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd0, S_V1}, {2'd0, S_V2},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT);  // m_c → t1
                    end
                    1: jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                            {2'd0, S_T0}, 1, 1, W_XCNT, 1'b0, 1'b1);
                    2: begin
                      ncomp_q <= 5'd1;
                      jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                           {2'd0, S_T0}, {2'd0, S_ZERO}, 7'h0,
                           0, 0, W_XCNT);          // d<0 → wb[0]
                    end
                    default: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          wb_q[l][c] <= (wb_q[l][0] != 0)
                                        ? va_q[0][l][c]
                                        : va_q[0][l][c] ^ 32'h8000_0000;
                      st_q <= W_WB;
                    end
                  endcase
                  // Reflect(I,N) = I - 2*dot(I,N)*N
                  71: unique case (xq_q)
                    0: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT);  // m_c → t1
                    end
                    1: jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                            {2'd0, S_T0}, 1, 1, W_XCNT, 1'b0, 1'b1);
                    2: begin
                      ncomp_q <= 5'd1;
                      jset(0, 5'd2, {2'd1, S_TWO}, {2'd1, S_T0},
                           {2'd1, S_ZERO}, 3, 0, W_XCNT);  // 2d → t2
                    end
                    default: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd3, {2'd0, S_V1}, {2'd1, S_T2},
                           {2'd0, S_V0}, 0, 0, W_WB, 1'b0, 1'b0,
                           2'd0, 2'd0, 2'd0, 1'b1);   // I - N*2d
                    end
                  endcase
                  // Refract(I,N,eta): k = 1 - e²(1-d²); k<0 → 0;
                  // r = e·I - (e·d + √k)·N
                  72: unique case (xq_q)
                    0: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT);  // m_c → t1
                    end
                    1: jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                            {2'd0, S_T0}, 1, 1, W_XCNT, 1'b0, 1'b1);
                    2: begin                            // d² → t1
                      ncomp_q <= 5'd1;
                      jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_T0},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT);
                    end
                    3: jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_ONE},
                            {2'd0, S_T1}, 3, 0, W_XCNT);  // 1-d² → t2
                    4: jset(0, 5'd2, {2'd1, S_V2}, {2'd1, S_V2},
                            {2'd1, S_ZERO}, 2, 0, W_XCNT);  // e² → t1
                    5: jset(0, 5'd3, {2'd0, S_T1}, {2'd0, S_T2},
                            {2'd0, S_ONE}, 3, 0, W_XCNT,
                            1'b0, 1'b0, 2'd0, 2'd0, 2'd0, 1'b1);
                                                        // k=1-e²t2 → t2
                    6: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                            {2'd0, S_T2}, {2'd0, S_ZERO}, 7'h0,
                            0, 0, W_XCNT);          // k<0 → wb[0]
                    7: jset(1, 5'd1, {2'd0, S_T2}, 7'h0, 7'h0,
                            2, 0, W_XCNT);              // √k → t1
                    8: jset(0, 5'd2, {2'd1, S_V2}, {2'd1, S_T0},
                            {2'd1, S_ZERO}, 3, 0, W_XCNT);  // e·d → t2
                    9: jset(0, 5'd0, {2'd0, S_ZERO}, {2'd0, S_T2},
                            {2'd0, S_T1}, 3, 0, W_XCNT);   // co → t2
                    10: begin                         // e·I → t1
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd1, S_V2}, {2'd0, S_V0},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT);
                    end
                    11: jset(0, 5'd2, {2'd1, S_T2}, {2'd0, S_V1},
                             {2'd0, S_ZERO}, 1, 0, W_XCNT); // co·N → t0
                    12: jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_T1},
                             {2'd0, S_T0}, 3, 0, W_XCNT);  // r → t2
                    default: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          wb_q[l][c] <= (wb_q[l][0] != 0)
                                        ? 32'h0 : t2_q[l][c];
                      st_q <= W_WB;
                    end
                  endcase
                  // FindILsb / FindSMsb / FindUMsb (int, comb)
                  73, 74, 75: begin
                    wb_q <= int_alu; st_q <= W_WB;
                  end
                  // NMin / NMax: fpnew MINMAX but NaN → canonical qNaN
                  79, 80: unique case (xq_q)
                    0: jset(3, {1'b0, (xnum_q == 7'd80)
                                 ? fpnew_pkg::RTZ[2:0]
                                 : fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_V0}, {2'd0, S_V1}, 7'h0,
                            1, 0, W_XCNT);
                    default: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          wb_q[l][c] <=
                            (f_nan(va_q[0][l][c]) ||
                             f_nan(va_q[1][l][c]))
                            ? 32'h7FC0_0000 : t0_q[l][c];
                      st_q <= W_WB;
                    end
                  endcase
                  // NClamp = NMin(NMax(x,lo),hi) with qNaN on any NaN
                  81: unique case (xq_q)
                    0: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                            {2'd0, S_V0}, {2'd0, S_V1}, 7'h0,
                            1, 0, W_XCNT);               // max → t0
                    1: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, {2'd0, S_V2}, 7'h0,
                            2, 0, W_XCNT);               // min → t1
                    default: begin
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          wb_q[l][c] <=
                            (f_nan(va_q[0][l][c]) ||
                             f_nan(va_q[1][l][c]) ||
                             f_nan(va_q[2][l][c]))
                            ? 32'h7FC0_0000 : t1_q[l][c];
                      st_q <= W_WB;
                    end
                  endcase
                  // ---- §7d SFU extinst (GLSL.std.450 13..30) --------
                  // Wrappers stage their argument in va0 then tail-
                  // chain into a shared core (xsub 1..4) or call it
                  // (xcall/xret); the xsub=63 epilogue applies the
                  // per-op fixup.  Coefs via S_SFC/dx.
                  13, 14, 15: begin                        // Sin/Cos/Tan
                    xsub_q <= 6'd4; xq_q <= '0; st_q <= W_EX;
                  end
                  18: begin                                // Atan
                    xsub_q <= 6'd3; xq_q <= '0; st_q <= W_EX;
                  end
                  29: begin                                // Exp2
                    xsub_q <= 6'd1; xq_q <= '0; st_q <= W_EX;
                  end
                  30, 28: begin                            // Log2/Log
                    xsub_q <= 6'd2; xq_q <= '0; st_q <= W_EX;
                  end
                  27: unique case (xq_q)                   // Exp
                    0: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_SFC},
                            7'h0, 1, 0, W_XCNT,
                            1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                            4'd0);                         // x·log2e
                    default: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd1; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  16: unique case (xq_q)                   // Asin
                    0: jset(0, 5'd3, {2'd0, S_V0}, {2'd0, S_V0},
                            {2'd0, S_ONE}, 1, 0, W_XCNT,
                            1'b0, 1'b0, 2'b0, 2'b0, 2'b0,
                            1'b1, 4'd0);                     // 1−x²
                    1: jset(1, 5'd1, {2'd0, S_T0}, 7'h0, 7'h0, 1, 0,
                            W_XCNT);                         // sqrt
                    2: jset(1, 5'd0, {2'd0, S_V0}, {2'd0, S_T0},
                            7'h0, 1, 0, W_XCNT);             // x/s
                    default: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd3; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  17: unique case (xq_q)                   // Acos
                    0: begin
                      dres_q[0] <= va_q[0];                  // stash x
                      st_q <= W_XCNT;
                    end
                    1: jset(0, 5'd3, {2'd0, S_V0}, {2'd0, S_V0},
                            {2'd0, S_ONE}, 1, 0, W_XCNT,
                            1'b0, 1'b0, 2'b0, 2'b0, 2'b0,
                            1'b1, 4'd0);                     // 1−x²
                    2: jset(1, 5'd1, {2'd0, S_T0}, 7'h0, 7'h0, 1, 0,
                            W_XCNT);                         // sqrt
                    3: jset(1, 5'd0, {2'd0, S_T0}, {2'd0, S_V0},
                            7'h0, 1, 0, W_XCNT);             // s/x
                    default: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd3; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  25: unique case (xq_q)                   // Atan2
                    0: jset(1, 5'd0, {2'd0, S_V0}, {2'd0, S_V1},
                            7'h0, 1, 0, W_XCNT);             // y/x
                    default: begin
                      dres_q[0] <= va_q[0];                  // stash y
                      va_q[0] <= t0_q;                       // va0 = z
                      xsub_q <= 6'd3; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  26: unique case (xq_q)                   // Pow
                    0: begin
                      dres_q[0] <= va_q[0];                  // stash x
                      xsub_q <= 6'd2; xcall_q <= 1'b1;
                      xret_q <= 5'd1; xret_st_q <= W_EX;
                      xq_q <= '0; st_q <= W_EX;
                    end
                    1: jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_V1},
                            7'h0, 1, 0, W_XCNT);             // y·log2x
                    default: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd1; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  19, 20: unique case (xq_q)               // Sinh/Cosh
                    0: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_SFC},
                           7'h0, 1, 0, W_XCNT,
                           1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                           4'd0);                            // x·log2e
                    1: begin
                      va_q[0] <= t0_q;
                      dres_q[0] <= t0_q;                 // stash x·log2e
                      xsub_q <= 6'd1; xcall_q <= 1'b1;
                      xret_q <= 5'd2; xret_st_q <= W_EX;
                      xq_q <= '0; st_q <= W_EX;
                    end
                    2: begin
                      va_q[1] <= t0_q;                       // e^x
                      for (int l = 0; l < LAN; l++)
                        for (int c = 0; c < VEC; c++)
                          va_q[0][l][c] <=
                            dres_q[0][l][c] ^ 32'h8000_0000; // −x·log2e
                      xsub_q <= 6'd1; xcall_q <= 1'b1;
                      xret_q <= 5'd3; xret_st_q <= W_EX;
                      xq_q <= '0; st_q <= W_EX;
                    end
                    // e1 − e2 (sinh) / e1 + e2 (cosh) → t2
                    3: jset(0, (xnum_q == 7'd19) ? 5'd1 : 5'd0,
                            7'h0, {2'd0, S_V1}, {2'd0, S_T0}, 3, 0,
                            W_XCNT);
                    default:
                      jset(0, 5'd2, {2'd0, S_T2}, {2'd0, S_HALF},
                           7'h0, 0, 0, W_WB);                // ·½ → wb
                  endcase
                  21: unique case (xq_q)                   // Tanh
                    0: jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_SFC},
                            7'h0, 1, 0, W_XCNT,
                            1'b0, 1'b0, 2'b0, 2'b0, 2'b0, 1'b0,
                            4'd0);                           // 2x·log2e
                    1: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd1; xcall_q <= 1'b1;
                      xret_q <= 5'd2; xret_st_q <= W_EX;
                      xq_q <= '0; st_q <= W_EX;
                    end
                    2: jset(0, 5'd1, 7'h0, {2'd0, S_T0},
                            {2'd0, S_ONE}, 2, 0, W_XCNT);    // u−1 → t1
                    3: jset(0, 5'd0, 7'h0, {2'd0, S_T0},
                            {2'd0, S_ONE}, 3, 0, W_XCNT);    // u+1 → t2
                    default:
                      jset(1, 5'd0, {2'd0, S_T1}, {2'd0, S_T2},
                           7'h0, 0, 0, W_WB);                // n/d → wb
                  endcase
                  22: unique case (xq_q)                   // Asinh
                    0: jset(0, 5'd3, {2'd0, S_V0}, {2'd0, S_V0},
                            {2'd0, S_ONE}, 1, 0, W_XCNT);    // x²+1
                    1: jset(1, 5'd1, {2'd0, S_T0}, 7'h0, 7'h0, 1, 0,
                            W_XCNT);                         // sqrt
                    2: jset(0, 5'd0, 7'h0, {2'd0, S_T0},
                            {2'd0, S_V0}, 1, 0, W_XCNT);     // s+x
                    default: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd2; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  23: unique case (xq_q)                   // Acosh
                    0: jset(0, 5'd3, {2'd0, S_V0}, {2'd0, S_V0},
                            {2'd0, S_NEG1}, 1, 0, W_XCNT);   // x²−1
                    1: jset(1, 5'd1, {2'd0, S_T0}, 7'h0, 7'h0, 1, 0,
                            W_XCNT);                         // sqrt
                    2: jset(0, 5'd0, 7'h0, {2'd0, S_T0},
                            {2'd0, S_V0}, 1, 0, W_XCNT);     // s+x
                    default: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd2; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  24: unique case (xq_q)                   // Atanh
                    0: jset(0, 5'd0, 7'h0, {2'd0, S_ONE},
                            {2'd0, S_V0}, 2, 0, W_XCNT);     // 1+x → t1
                    1: jset(0, 5'd1, 7'h0, {2'd0, S_ONE},
                            {2'd0, S_V0}, 3, 0, W_XCNT);     // 1−x → t2
                    2: jset(1, 5'd0, {2'd0, S_T1}, {2'd0, S_T2},
                            7'h0, 1, 0, W_XCNT);             // t1/t2
                    default: begin
                      va_q[0] <= t0_q;
                      xsub_q <= 6'd2; xq_q <= '0; st_q <= W_EX;
                    end
                  endcase
                  default: begin
                    done_code_q <= APU_SH_DONE_FAULT;
                    fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
                    st_q <= W_DONE;
                  end
                endcase
              end
              default: begin
                done_code_q <= APU_SH_DONE_FAULT;
                fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
                st_q <= W_DONE;
              end
            endcase
          end
          // ------------------------------------------- unit handshakes
          // in_valid is held per element until its own accept
          // (ir/rdy handshake); out_valid pulses are latched per
          // element with their result, then the wait exits once every
          // issued element has produced one.
          W_FU0: begin                          // fma issue
            begin
              logic allgot;
              allgot = 1'b1;
              for (int l = 0; l < LAN; l++)
                for (int c = 0; c < VEC; c++)
                  if ((fu_got_q[l][c] || fma_iv[l][c]) &&
                      !(fu_got_q[l][c] ||
                        (fma_iv[l][c] && fma_ir[l][c])))
                    allgot = 1'b0;
              for (int l = 0; l < LAN; l++)
                for (int c = 0; c < VEC; c++)
                  if (fma_iv[l][c] && fma_ir[l][c])
                    fu_got_q[l][c] <= 1'b1;
              if (allgot) begin
                fuact_q <= fma_iv | fu_got_q; st_q <= W_FU1;
              end
            end
          end
          W_FU1: begin                          // fma result wait
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                if (fma_ov[l][c] && fuact_q[l][c]) begin
                  fu_dn_q[l][c]  <= 1'b1;
                  fu_rc_q[l][c]  <= fma_res[l][c];
                end
            if (&((fu_dn_q | fma_ov) | ~fuact_q)) begin
              if (jdot_q) begin
                for (int l = 0; l < LAN; l++)
                  if (act_w[l] &&
                      (!tx_1lane_q ||
                       4'(l) == {1'b0, ls_lane_q[2:0]}))
                    t0_q[l][0] <= fma_ov[l][0] ? fma_res[l][0]
                                               : fu_rc_q[l][0];
                if (tc_q + 1 >= ncomp_q) begin
                  for (int l = 0; l < LAN; l++)
                    if (act_w[l] &&
                        (!tx_1lane_q ||
                         4'(l) == {1'b0, ls_lane_q[2:0]}))
                      jstore(jdst_q, 4'(l), 3'd0,
                             fma_ov[l][0] ? fma_res[l][0]
                                          : fu_rc_q[l][0]);
                  st_q <= ret_q;
                end else begin
                  tc_q <= tc_q + 1;
                  fu_got_q <= '0; fu_dn_q <= '0;
                  st_q <= W_FU0;
                end
              end else begin
                for (int l = 0; l < LAN; l++)
                  for (int c = 0; c < VEC; c++)
                    if (act_w[l] && c < ncomp_q &&
                        (!tx_1lane_q ||
                         4'(l) == {1'b0, ls_lane_q[2:0]}))
                      jstore(jdst_q, 4'(l),
                             3'(jucc_q ? {1'b0, ccc_q} : 3'(c)),
                             fma_ov[l][c] ? fma_res[l][c]
                                          : fu_rc_q[l][c]);
                st_q <= ret_q;
              end
            end
          end
          W_DQ0: begin
            // in_ready_o already encodes the unit's IDLE accept gate;
            // holding in_valid until each lane's own accept prevents
            // re-issue while waiting on a slower lane.
            begin
              logic allgot;
              allgot = 1'b1;
              for (int l = 0; l < LAN; l++)
                if (act_w[l] &&
                    (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]}) &&
                    !(dq_got_q[l] ||
                      (dq_iv[l] && dq_ir[l])))
                  allgot = 1'b0;
              for (int l = 0; l < LAN; l++)
                if (dq_iv[l] && dq_ir[l])
                  dq_got_q[l] <= 1'b1;
              if (allgot) begin
                dqact_q <= dq_iv | dq_got_q; st_q <= W_DQ1;
              end
            end
          end
          W_DQ1: begin
            for (int l = 0; l < LAN; l++)
              if (dq_ov[l] && dqact_q[l]) begin
                dq_dn_q[l] <= 1'b1;
                dq_rc_q[l] <= dq_res[l];
              end
            if (&((dq_dn_q | dq_ov) | ~dqact_q)) begin
              for (int l = 0; l < LAN; l++)
                if (act_w[l] &&
                    (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]}))
                  jstore(jdst_q, 4'(l),
                             3'(jucc_q ? {1'b0, ccc_q} : 3'(tc_q)),
                         dq_ov[l] ? dq_res[l] : dq_rc_q[l]);
              if (tc_q + 1 >= ncomp_q) st_q <= ret_q;
              else begin
                tc_q <= tc_q + 1;
                dq_got_q <= '0; dq_dn_q <= '0;
                st_q <= W_DQ0;
              end
            end
          end
          W_CVT0: begin
            begin
              logic allgot;
              allgot = 1'b1;
              for (int l = 0; l < LAN; l++)
                if (act_w[l] &&
                    (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]}) &&
                    !(cv_got_q[l] || (cv_iv[l] && cv_ir[l])))
                  allgot = 1'b0;
              for (int l = 0; l < LAN; l++)
                if (cv_iv[l] && cv_ir[l])
                  cv_got_q[l] <= 1'b1;
              if (allgot) begin
                cvact_q <= cv_iv | cv_got_q; st_q <= W_CVT1;
              end
            end
          end
          W_CVT1: begin
            for (int l = 0; l < LAN; l++)
              if (cv_ov[l] && cvact_q[l]) begin
                cv_dn_q[l] <= 1'b1;
                cv_rc_q[l] <= cv_res[l];
              end
            if (&((cv_dn_q | cv_ov) | ~cvact_q)) begin
              for (int l = 0; l < LAN; l++)
                if (act_w[l] &&
                    (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]}))
                  jstore(jdst_q, 4'(l),
                             3'(jucc_q ? {1'b0, ccc_q} : 3'(tc_q)),
                         cv_ov[l] ? cv_res[l] : cv_rc_q[l]);
              if (tc_q + 1 >= ncomp_q) st_q <= ret_q;
              else begin
                tc_q <= tc_q + 1;
                cv_got_q <= '0; cv_dn_q <= '0;
                st_q <= W_CVT0;
              end
            end
          end
          W_NC0: begin
            begin
              logic allgot;
              allgot = 1'b1;
              for (int l = 0; l < LAN; l++)
                if (act_w[l] &&
                    (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]}) &&
                    !(nc_got_q[l] || (nc_iv[l] && nc_ir[l])))
                  allgot = 1'b0;
              for (int l = 0; l < LAN; l++)
                if (nc_iv[l] && nc_ir[l])
                  nc_got_q[l] <= 1'b1;
              if (allgot) begin
                ncact_q <= nc_iv | nc_got_q; st_q <= W_NC1;
              end
            end
          end
          W_NC1: begin
            for (int l = 0; l < LAN; l++)
              if (nc_ov[l] && ncact_q[l]) begin
                nc_dn_q[l] <= 1'b1;
                nc_rc_q[l] <= nc_res[l];
              end
            if (&((nc_dn_q | nc_ov) | ~ncact_q)) begin
              for (int l = 0; l < LAN; l++)
                if (act_w[l] &&
                    (!tx_1lane_q || 4'(l) == {1'b0, ls_lane_q[2:0]}))
                  jstore(jdst_q, 4'(l),
                             3'(jucc_q ? {1'b0, ccc_q} : 3'(tc_q)),
                         xop_q[0]
                           ? (nc_ov[l] ? nc_res[l] : nc_rc_q[l])
                           : {31'h0, (nc_ov[l] ? nc_res[l][0]
                                              : nc_rc_q[l][0])});
              if (tc_q + 1 >= ncomp_q) st_q <= ret_q;
              else begin
                tc_q <= tc_q + 1;
                nc_got_q <= '0; nc_dn_q <= '0;
                st_q <= W_NC0;
              end
            end
          end
          // int divider: |a|/|b| restoring, dividend held in dv_q
          // (the {r,q} pair shifts left; q accumulates the quotient)
          W_IDIV: begin
            if (dv_init_q) begin
              for (int l = 0; l < LAN; l++) begin
                logic [31:0] a, b;
                a = va_q[0][l][tc_q]; b = va_q[1][l][tc_q];
                dv_q_q[l] <= (dv_sg_q && a[31]) ? ~a + 1 : a;
                dv_d_q[l] <= (dv_sg_q && b[31]) ? ~b + 1 : b;
                dv_r_q[l] <= '0;
                dv_as_q[l] <= a[31]; dv_bs_q[l] <= b[31];
              end
              dv_init_q <= 1'b0; dv_i_q <= '0;
            end else if (dv_i_q < 32) begin
              for (int l = 0; l < LAN; l++) begin
                logic [63:0] sh;
                logic [32:0] dif;
                sh  = {dv_r_q[l], dv_q_q[l]} << 1;
                dif = {1'b0, sh[63:32]} - {1'b0, dv_d_q[l]};
                if (!dif[32]) begin
                  dv_r_q[l] <= dif[31:0];
                  dv_q_q[l] <= sh[31:0] | 32'd1;
                end else begin
                  dv_r_q[l] <= sh[63:32];
                  dv_q_q[l] <= sh[31:0];
                end
              end
              dv_i_q <= dv_i_q + 1;
            end else begin
              // sign fix + wb write for comp tc_q
              for (int l = 0; l < LAN; l++) begin
                logic [31:0] q, r, res;
                q = (dv_d_q[l] == 0) ? 32'h0 : dv_q_q[l];
                r = (dv_d_q[l] == 0) ? 32'h0 : dv_r_q[l];
                if (dv_sm_q) begin
                  // SMod: result takes the divisor's sign
                  if (r == 0) res = 32'h0;
                  else if (dv_as_q[l] == dv_bs_q[l])
                    res = dv_bs_q[l] ? ~r + 1 : r;
                  else begin
                    res = dv_d_q[l] - r;
                    if (dv_bs_q[l]) res = ~res + 1;
                  end
                end else begin
                  if (dv_sg_q && (dv_as_q[l] != dv_bs_q[l]))
                    q = ~q + 1;
                  if (dv_sg_q && dv_as_q[l]) r = ~r + 1;
                  res = dv_md_q ? r : q;
                end
                wb_q[l][tc_q] <= res;
              end
              if (tc_q + 1 >= ncomp_q) st_q <= ret_q;
              else begin
                tc_q <= tc_q + 1; dv_init_q <= 1'b1;
                st_q <= W_IDIV;
              end
            end
          end
          W_XCNT: begin xq_q <= xq_q + 1; st_q <= W_EX; end
          W_XG: begin
            wb_q <= int_alu; st_q <= W_WB;
          end
          // chain index operand resolve (ops_q[3+ck_q])
          W_IR0: st_q <= W_IR1;
          W_IR1: begin
            ir_idx_q <= rm_idx[RI-1:0];
            ir_tag_q <= rm_tag;
            ir_aux_q <= rm_aux;
            st_q <= W_IR2;
          end
          W_IR2: st_q <= W_IR3;
          W_IR3: begin
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                vix_q[l][c] <=
                  (ir_tag_q == APU_SH_RT_CONST)
                  ? const_data_i[32 * ((c < ir_aux_q) ? c : 0) +: 32]
                  : rf_rdata[l * 128 +: 32];
            st_q <= W_CHT0;
          end
          W_CHT0: st_q <= W_CHT1;
          W_CHT1: begin
            unique case (ty_kind)
              4'd9: begin                        // struct → member read
                cmb_q <= ty_mbase + 10'(vix_q[0][0]);
                st_q <= W_CHM0;
              end
              4'd7, 4'd8: begin                  // array / runtime array
                if (ck_q == 4'd0 &&
                    (ctag_q[3:0] == APU_SH_SC_UNIFORM ||
                     ctag_q[3:0] == APU_SH_SC_UNIFORMCONST ||
                     ctag_q[3:0] == APU_SH_SC_SBUF)) begin
                  // §12.3 F5: first index into an array of descriptor
                  // records — selects the record, not a byte offset
                  for (int l = 0; l < LAN; l++)
                    poff_q[l][2] <= vix_q[l][0];
                  cty_q <= ty_elem;
                  if (ck_q + 1 >= wc_q - 4) st_q <= W_CHFIN;
                  else begin
                    ck_q <= ck_q + 1;
                    res_id_q <= ops_q[3 + ck_q + 1][9:0];
                    st_q <= W_IR0;
                  end
                end else if (ty_stride != 0) begin
                  al_st_q <= ty_stride;
                  cty2_q <= ty_elem; st_q <= W_CHX;
                end else begin
                  cty2_q <= ty_elem; st_q <= W_CHE0;
                end
              end
              4'd6: begin                        // matrix
                al_st_q <= (cmstride_q != 0) ? cmstride_q
                                             : 16'(f_nc(ty_comps)) * 4;
                cty2_q <= ty_elem; st_q <= W_CHX;
              end
              4'd5: begin                        // vector
                al_st_q <= 16'd4; cty2_q <= ty_elem; st_q <= W_CHX;
              end
              default: begin                     // scalar/end of chain
                al_st_q <= 16'd4; cty2_q <= cty_q; st_q <= W_CHX;
              end
            endcase
          end
          W_CHM0: st_q <= W_CHM1;
          W_CHM1: begin
            for (int l = 0; l < LAN; l++) begin
              poff_q[l][0] <= poff_q[l][0] + {16'h0, mb_off};
              // dropped member (PointSize/Clip/CullDistance): the
              // chained pointer carries the drop flag; the LSU ignores
              // its stores and reads it back as zero
              if (mb_fl[6])      // APU_SH_MF_DROP bit of the member fl
                poff_q[l][1][31:28] <= APU_SH_VF_DROP;
            end
            cmstride_q <= mb_mst;
            cty_q <= mb_ty;
            if (ck_q + 1 >= wc_q - 4) st_q <= W_CHFIN;
            else begin ck_q <= ck_q + 1;
              res_id_q <= ops_q[3 + ck_q + 1][9:0]; st_q <= W_IR0; end
          end
          W_CHE0: st_q <= W_CHE1;
          W_CHE1: begin                          // elem type → natural size
            al_st_q <= (ty_size != 0) ? ty_size : 16'd4;
            st_q <= W_CHX;
          end
          W_CHX: begin
            for (int l = 0; l < LAN; l++)
              poff_q[l][0] <= poff_q[l][0] +
                              vix_q[l][0] * {16'h0, al_st_q};
            cty_q <= cty2_q;
            if (ck_q + 1 >= wc_q - 4) st_q <= W_CHFIN;
            else begin ck_q <= ck_q + 1;
              res_id_q <= ops_q[3 + ck_q + 1][9:0]; st_q <= W_IR0; end
          end
          W_CHFIN: begin
            for (int l = 0; l < LAN; l++) begin
              wb_q[l][0] <= poff_q[l][0];
              wb_q[l][1] <= poff_q[l][1];
              // F5: comp2 carries the descriptor element index
              wb_q[l][2] <= poff_q[l][2]; wb_q[l][3] <= '0;
            end
            wbm_q <= 4'b1111;
            st_q <= W_WB;
          end
          // OpArrayLength: ptr → struct → member(off, mtype) → stride;
          // F5: the buffer extent comes from the memory-resident
          // record selected by the pointer's descriptor index
          W_AL0: begin
            dsc_set_q <= va_q[0][0][1][19:12];
            dsc_bd_q  <= va_q[0][0][1][27:20];
            dsc_idx_q <= va_q[0][0][2][15:0];
            dret_q    <= W_AL1;
            st_q      <= W_DS0;
          end
          W_AL1: begin al_ty_q <= ty_elem; st_q <= W_AL2; end
          W_AL2: st_q <= W_AL3;
          W_AL3: begin
            cmb_q <= ty_mbase + 10'(ops_q[3]);
            st_q <= W_AL4;
          end
          W_AL4: st_q <= W_AL5;
          W_AL5: begin
            al_off_q <= mb_off; al_ty2_q <= mb_ty; st_q <= W_AL6;
          end
          W_AL6: st_q <= W_AL7;
          W_AL7: begin
            al_st_q <= (ty_stride != 0) ? ty_stride : 16'd4;
            // unsigned divide (size-off)/stride via divider path
            for (int l = 0; l < LAN; l++) begin
              dv_q_q[l] <= (ls_bsz_q >= {16'h0, al_off_q})
                           ? ls_bsz_q - {16'h0, al_off_q} : 32'h0;
              dv_d_q[l] <= (ty_stride != 0) ? {16'h0, ty_stride}
                                            : 32'd4;
              dv_r_q[l] <= '0;
              dv_as_q[l] <= 1'b0; dv_bs_q[l] <= 1'b0;
            end
            dv_sg_q <= 1'b0; dv_md_q <= 1'b0; dv_sm_q <= 1'b0;
            // dv_q/dv_d/dv_r already seeded above — skip operand init
            dv_init_q <= 1'b0; dv_i_q <= '0; tc_q <= '0;
            ncomp_q <= 4'd1; ret_q <= W_WB; st_q <= W_IDIV;
          end
          // ------------------------------------------------------- LSU
          // W_LS0 decodes the current (lane,comp) access with fresh
          // operand values; W_LS1 issues the memory port; W_LS2
          // captures; W_SSB/W_SSB1 do the same for scratch/slab;
          // W_LSA advances the (lane,comp) cursor.
          W_LS0: begin
            logic [31:0] o32, tg;
            // ls_ps_q (ext pointer stores: Modf/Frexp) puts the pointer
            // word in operand slot 1 instead of 0
            o32 = va_q[ls_ps_q][ls_lane_q[2:0]][0] +
                  {21'h0, (ls_mat_q ? ls_flw : ls_comp_q), 2'b00};
            tg  = va_q[ls_ps_q][ls_lane_q[2:0]][1];
            ls_off_q <= o32;
            ls_sc_q  <= tg[3:0];
            ls_bi_q  <= tg[11:4];
            ls_rec_q <= 1'b0;
            if (!act_w[ls_lane_q[2:0]]) st_q <= W_LSA;
            else if (ls_atom_q && (dead_q[wave_q][ls_lane_q[2:0]] ||
                                   hlp_w[ls_lane_q[2:0]])) begin
              // dead/helper lanes do no atomic writes; result ops get 0
              if (!ls_store_q) wb_q[ls_lane_q[2:0]][0] <= '0;
              st_q <= W_LSA;
            end else if ((dead_q[wave_q][ls_lane_q[2:0]] ||
                          hlp_w[ls_lane_q[2:0]]) && ls_store_q &&
                         (tg[3:0] == APU_SH_SC_UNIFORM ||
                          tg[3:0] == APU_SH_SC_SBUF ||
                          tg[3:0] == APU_SH_SC_WORKGROUP)) begin
              // dead/helper lane: device-visible stores suppressed
              // with no robust accounting; private/function/out-record
              // stores still proceed (mirrors the model's store gate)
              st_q <= W_LSA;
            end else if (tg[31:28] == APU_SH_VF_DROP) begin
              // dropped variable/member (PointSize/Clip/CullDistance):
              // stores ignored, loads return zero
              if (!ls_store_q)
                wb_q[ls_lane_q[2:0]][ls_wc] <= '0;
              st_q <= W_LSA;
            end else if ((gfx_q != APU_SH_GFX_NONE) &&
                         (tg[31:28] == APU_SH_VF_REC) &&
                         (tg[3:0] == APU_SH_SC_INPUT ||
                          tg[3:0] == APU_SH_SC_OUTPUT)) begin
              // graphics record access: base + inv*stride + off on the
              // aperture port; W_LSC bounds-checks against the batch
              // extent count*stride and issues the access
              ls_rec_q <= 1'b1;
              ls_bok_q <= 1'b1;
              if (tg[3:0] == APU_SH_SC_INPUT) begin
                ls_bind_q <= {32'h0, in_base_q};
                ls_off_q  <= (32'(wave_q) * LAN + 32'(ls_lane_q)) *
                             gfx_istr + o32;
                ls_bsz_q  <= gcnt_q * gfx_istr;
              end else begin
                ls_bind_q <= {32'h0, out_base_q};
                ls_off_q  <= (32'(wave_q) * LAN + 32'(ls_lane_q)) *
                             gfx_ostr + o32;
                ls_bsz_q  <= gcnt_q * gfx_ostr;
              end
              st_q <= W_LSC;
            end else if (tg[3:0] == APU_SH_SC_INPUT &&
                         gfx_q == APU_SH_GFX_VS &&
                         (tg[11:4] == 8'(APU_SH_BI_VERTEXINDEX) ||
                          tg[11:4] == 8'(APU_SH_BI_INSTANCEINDEX))) begin
              // G2a: slot 8 of the VS-in record is the source of truth
              // for VertexIndex/InstanceIndex ({vi, ii, 0, 0} at +128)
              // — the work imm words stay for compatibility but are no
              // longer read for these builtins.
              ls_rec_q <= 1'b1;
              ls_bok_q <= 1'b1;
              ls_bind_q <= {32'h0, in_base_q};
              ls_off_q  <= (32'(wave_q) * LAN + 32'(ls_lane_q)) *
                           gfx_istr + 32'd128 +
                           (tg[11:4] == 8'(APU_SH_BI_INSTANCEINDEX)
                            ? 32'd4 : 32'd0);
              ls_bsz_q  <= gcnt_q * gfx_istr;
              st_q <= W_LSC;
            end else if (tg[3:0] == APU_SH_SC_INPUT) begin
              // builtin vec component comes from the pointer byte
              // offset (scalar extracts load .y/.z too), not from the
              // output component cursor
              if (!ls_store_q)
                wb_q[ls_lane_q[2:0]][ls_wc] <=
                  f_bi(tg[11:4], ls_lane_q, 3'(o32 >> 2));
              st_q <= W_LSA;
            end else if (tg[3:0] == APU_SH_SC_PUSHCONST) begin
              if ((o32 >> 2) >= {26'h0, push_n_q}) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][ls_wc] <= '0;
              end else if (!ls_store_q) begin
                wb_q[ls_lane_q[2:0]][ls_wc] <=
                  push_q[o32[31:2] > 31 ? 5'd31 : o32[6:2]];
              end
              st_q <= W_LSA;
            end else if (tg[3:0] == APU_SH_SC_UNIFORM ||
                         tg[3:0] == APU_SH_SC_SBUF) begin
              // §12.3 F5: {set,binding,idx} -> binding row -> record
              // fetch -> bounds check at W_LSC
              dsc_set_q <= tg[19:12];
              dsc_bd_q  <= tg[27:20];
              dsc_idx_q <= va_q[ls_ps_q][ls_lane_q[2:0]][2][15:0];
              dret_q    <= W_LSC;
              st_q      <= W_DS0;
            end else if (tg[3:0] == APU_SH_SC_WORKGROUP ||
                         tg[3:0] == APU_SH_SC_FUNCTION ||
                         tg[3:0] == APU_SH_SC_PRIVATE) begin
              st_q <= ls_atom_q ? W_ATS0 : W_SSB;
            end else begin
              robust_q <= robust_q + 1;
              if (!ls_store_q)
                wb_q[ls_lane_q[2:0]][ls_wc] <= '0;
              st_q <= W_LSA;
            end
          end
          // ---- §12.3 F5: descriptor record resolve ------------------
          // dsc_set/bd/idx + dret are latched by the caller (W_LS0,
          // W_AL0).  W_DS0 runs the binding CAM and the record cache;
          // a miss fetches the record's first 16 bytes in two 64-bit
          // beats.  All exits write ls_bind/ls_bsz/ls_bok and jump to
          // dret_q.
          W_DS0: begin
            logic [49:0]  br;
            logic [256:0] hit;
            br  = f_brow(4'(dsc_set_q[3:0]), dsc_bd_q);
            hit = f_dhit(dsc_set_q[1:0], dsc_bd_q, dsc_idx_q);
            if (!br[49] ||
                {16'h0, dsc_idx_q} >= {16'h0, br[40:25]}) begin
              // unbound set / no such binding / idx past the array:
              // null descriptor (zero size, invalid)
              ls_bind_q <= '0; ls_bsz_q <= '0; ls_bok_q <= 1'b0;
              dsc_rec_q <= '0;
              if (tx_full_q) tx_rec_q <= '0;
              st_q <= dret_q;
            end else begin
              dsc_row_q <= br[48:0];
              if (hit[256]) begin
                // {kind,flags,base,size} in w0/w1 + dynamic offset
                dsc_rec_q <= hit[255:0];
                if (tx_full_q) tx_rec_q <= hit[255:0];
                ls_bind_q <= hit[31:0] +
                             f_doff(dsc_set_q[1:0],
                                    apu_sh_bindrow_t'(br[48:0]),
                                    dsc_idx_q);
                ls_bsz_q  <= hit[63:32];
                ls_bok_q  <= hit[72] && f_buf_kind(hit[71:64]);
                st_q <= dret_q;
              end else begin
                dsc_err_q <= 1'b0;
                dsc_addr_q <= {32'h0, desc_i.set_base[dsc_set_q[1:0]]} +
                              ((64'(br[24:5]) + 64'(dsc_idx_q))
                               << 5);
                st_q <= W_DS1;
              end
            end
          end
          W_DS1: begin
            // mem_re_o high (desc beat); hold until accepted
            if (mem_ready_i) st_q <= W_DS2;
          end
          W_DS2: begin
            if (mem_rvalid_i) begin
              dsc_rec_q[63:0] <= mem_err_i ? 64'h0 : mem_rdata_i;
              dsc_err_q  <= mem_err_i;
              dsc_addr_q <= dsc_addr_q + 64'd8;
              st_q <= W_DS3;
            end
          end
          W_DS3: begin
            if (mem_ready_i) st_q <= W_DS4;
          end
          W_DS4: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) dsc_err_q <= 1'b1;
              dsc_rec_q[127:64] <= mem_err_i ? 64'h0 : mem_rdata_i;
              dsc_addr_q <= dsc_addr_q + 64'd8;
              st_q <= W_DS5;
            end
          end
          // 5b: image/sampler halves — record bytes 16..31
          W_DS5: begin
            if (mem_ready_i) st_q <= W_DS6;
          end
          W_DS6: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) dsc_err_q <= 1'b1;
              dsc_rec_q[191:128] <= mem_err_i ? 64'h0 : mem_rdata_i;
              dsc_addr_q <= dsc_addr_q + 64'd8;
              st_q <= W_DS7;
            end
          end
          W_DS7: begin
            if (mem_ready_i) st_q <= W_DS8;
          end
          W_DS8: begin
            if (mem_rvalid_i) begin
              logic [255:0] val;
              logic [7:0]   kind, flags;
              logic [31:0]  memh, size;
              val = {mem_err_i ? 64'h0 : mem_rdata_i,
                     dsc_rec_q[191:0]};
              memh  = val[31:0];
              size  = val[63:32];
              kind  = val[71:64];
              flags = val[79:72];
              if (!dsc_err_q && !mem_err_i && flags[0] &&
                  kind != 8'd0 && memh != 32'h0) begin
                // §12.3 3d-d: +0 names a memory {gen,slot}, not a
                // base — resolve the CURRENT base through ObjTab
                // before the record enters the cache
                dsc_rec_q <= val;
                if (tx_full_q) tx_rec_q <= val;
                st_q <= W_DS9;
              end else begin
                // no memory to resolve (sampler-only kind 0, a null
                // record) or the fetch faulted: a faulted / handleless
                // memory record is nulled by clearing flags[0] — the
                // base word itself is never trusted again
                if (dsc_err_q || mem_err_i ||
                    (flags[0] && kind != 8'd0 && memh == 32'h0))
                  val[79:72] = 8'h0;
                // fill the record cache (round-robin victim)
                dc_v_q[dc_vic_q]   <= 1'b1;
                dc_key_q[dc_vic_q] <= {dsc_idx_q, dsc_bd_q,
                                       dsc_set_q[1:0]};
                dc_val_q[dc_vic_q] <= val;
                dc_vic_q           <= dc_vic_q == 3'(APU_DESC_CACHE-1)
                                      ? 3'h0 : dc_vic_q + 3'h1;
                dsc_rec_q <= val;
                if (tx_full_q) tx_rec_q <= val;
                ls_bind_q <= val[31:0] +
                             f_doff(dsc_set_q[1:0], dsc_row_q,
                                    dsc_idx_q);
                ls_bsz_q  <= size;
                ls_bok_q  <= val[72] && f_buf_kind(kind);
                st_q <= dret_q;
              end
            end
          end
          // READSLOT for the record's memory handle (combinational
          // request above); held until the arbitrated port accepts
          W_DS9: if (ot_req_ready_i) st_q <= W_DSA;
          W_DSA: begin
            if (ot_cpl_valid_i) begin
              logic [255:0] val;
              logic [63:0]  msz, moff;
              logic         ok;
              val  = dsc_rec_q;
              msz  = ot_cpl_i.entry.size;
              moff = 64'(dsc_rec_q[255:224]);   // record +28 offset
              // live && the generation the record names && still a
              // DEVICE_MEMORY (READSLOT's kind check covers kind) &&
              // backed && the resource window fits the extent
              ok = ot_cpl_i.status == APU_OBJTAB_OK &&
                   ot_cpl_i.entry.gen == dsc_rec_q[31:16] &&
                   ot_cpl_i.entry.aux[63:32] != APU_MEM_UNBACKED &&
                   moff <= msz &&
                   64'(val[63:32]) <= msz - moff;
              if (ok)
                // resolved absolute base = mem base + resource offset
                val[31:0] = ot_cpl_i.entry.aux[63:32] +
                            dsc_rec_q[255:224];
              else
                // dead/recycled/unbacked/out-of-extent: the null
                // record (robust zero / dropped store downstream)
                val[79:72] = 8'h0;
              // cache the RESOLVED record — +0 now carries the base
              dc_v_q[dc_vic_q]   <= 1'b1;
              dc_key_q[dc_vic_q] <= {dsc_idx_q, dsc_bd_q,
                                     dsc_set_q[1:0]};
              dc_val_q[dc_vic_q] <= val;
              dc_vic_q           <= dc_vic_q == 3'(APU_DESC_CACHE-1)
                                    ? 3'h0 : dc_vic_q + 3'h1;
              dsc_rec_q <= val;
              if (tx_full_q) tx_rec_q <= val;
              ls_bind_q <= val[31:0] +
                           f_doff(dsc_set_q[1:0], dsc_row_q,
                                  dsc_idx_q);
              ls_bsz_q  <= val[63:32];
              ls_bok_q  <= val[72] && f_buf_kind(val[71:64]);
              st_q <= dret_q;
            end
          end
          // ================= §12.3 C/5b texture path ==================
          // W_TX0: OpSampledImage/OpImage are pure register merges;
          // fetch/read/write/sample/query serialize lanes through the
          // record fetch (tx_full_q routes the DS fill into tx_rec_q)
          // then the mip walk and the texel loop.
          W_TX0: begin
            unique case (opc_q)
              16'd86: begin              // OpSampledImage: merge ptrs
                // result comp0 = packed sampler key
                //   {bd[31:24], set[23:16], idx[15:0]}, comp1 tag gets
                //   bit31 = "separate sampler record"
                for (int l = 0; l < LAN; l++) begin
                  wb_q[l][0] <= {va_q[1][l][1][27:20],
                                 va_q[1][l][1][19:12],
                                 va_q[1][l][2][15:0]};
                  wb_q[l][1] <= va_q[0][l][1] | 32'h8000_0000;
                  wb_q[l][2] <= va_q[0][l][2];
                  wb_q[l][3] <= '0;
                end
                wbm_q <= 4'b1111; st_q <= W_WB;
              end
              16'd100: begin             // OpImage: strip sampler key
                for (int l = 0; l < LAN; l++) begin
                  wb_q[l][0] <= '0;
                  wb_q[l][1] <= va_q[0][l][1] & ~32'h8000_0000;
                  wb_q[l][2] <= va_q[0][l][2];
                  wb_q[l][3] <= '0;
                end
                wbm_q <= 4'b1111; st_q <= W_WB;
              end
              default: begin
                ls_lane_q <= '0; tx_full_q <= 1'b1;
                tx_1lane_q <= 1'b1;     // unit jobs for ls_lane only
                wbm_q <= 4'b1111;
                tx_dref_q <= (opc_q == 16'd89 || opc_q == 16'd90 ||
                              opc_q == 16'd93 || opc_q == 16'd94 ||
                              opc_q == 16'd97);
                tx_gath_q <= (opc_q == 16'd96 || opc_q == 16'd97);
                tx_qlod_q <= (opc_q == 16'd105);
                // image-operands mask position varies by operand count
                tx_msk_q  <=
                  8'((((opc_q == 16'd89 || opc_q == 16'd90 ||
                        opc_q == 16'd93 || opc_q == 16'd94 ||
                        opc_q == 16'd96 || opc_q == 16'd97) &&
                       wc_q > 16'd6) ? ops_q[5] :
                      ((opc_q == 16'd87 || opc_q == 16'd91 ||
                        opc_q == 16'd92) &&
                       wc_q > 16'd5) ? ops_q[4] : 32'h0) & 32'hFF);
                // ConstOffset operand slot: gathers fetch the trailing
                // ids positionally (Bias, then Lod, then ConstOffset —
                // all after the mask word); 0 marks "no offset operand"
                tx_osl_q <=
                  ((opc_q == 16'd96 || opc_q == 16'd97) &&
                   wc_q > 16'd6 && (ops_q[5] & 32'h8) != 0)
                      ? (3'd3 + {2'b0, ops_q[5][1]} +
                         {2'b0, ops_q[5][0]}) : 3'd0;
                // Bias operand slot (mask bit 0): k=2 for 87/91
                // (img,coord), k=3 for 89/93 (…,dref) and the gathers
                // (…,comp|dref); 0 marks "no Bias operand"
                tx_bsl_q <=
                  ((opc_q == 16'd87 || opc_q == 16'd91) &&
                   wc_q > 16'd5 && (ops_q[4] & 32'h1) != 0) ? 3'd2 :
                  ((opc_q == 16'd89 || opc_q == 16'd93 ||
                    opc_q == 16'd96 || opc_q == 16'd97) &&
                   wc_q > 16'd6 && (ops_q[5] & 32'h1) != 0) ? 3'd3 :
                  3'd0;
                // operand-mask legality: Lod (0x2) decoded on the
                // explicit forms, Bias (0x1) on the implicit forms and
                // gathers, ConstOffset (0x8) on the fetch/gather forms;
                // every other image operand faults (Offset/ConstOffsets/
                // Sample/MinLod are not decoded in v1)
                if ((opc_q == 16'd87 && wc_q > 16'd5 &&
                     (ops_q[4] & ~32'h1) != 0) ||
                    (opc_q == 16'd95 &&
                     wc_q > 16'd6 && (ops_q[4] & ~32'h2) != 0) ||
                    (opc_q == 16'd88 &&
                     (wc_q < 16'd7 || (ops_q[4] & ~32'h2) != 0 ||
                      (ops_q[4] & 32'h2) == 0)) ||
                    (opc_q == 16'd98 && wc_q > 16'd5 &&
                     ops_q[4] != 32'h0) ||
                    (opc_q == 16'd99 && wc_q > 16'd4 &&
                     ops_q[3] != 32'h0) ||
                    // G3a-ii: dref/proj implicit take Bias only
                    ((opc_q == 16'd89 || opc_q == 16'd93) &&
                     wc_q > 16'd6 && (ops_q[5] & ~32'h1) != 0) ||
                    (opc_q == 16'd91 && wc_q > 16'd5 &&
                     (ops_q[4] & ~32'h1) != 0) ||
                    // explicit forms require Lod, allow +ConstOffset
                    ((opc_q == 16'd90 || opc_q == 16'd94) &&
                     (wc_q < 16'd8 || (ops_q[5] & ~32'hA) != 0 ||
                      (ops_q[5] & 32'h2) == 0)) ||
                    (opc_q == 16'd92 &&
                     (wc_q < 16'd7 || (ops_q[4] & ~32'hA) != 0 ||
                      (ops_q[4] & 32'h2) == 0)) ||
                    // gathers: Bias, Lod and/or ConstOffset only
                    ((opc_q == 16'd96 || opc_q == 16'd97) &&
                     wc_q > 16'd6 && (ops_q[5] & ~32'hB) != 0) ||
                    // QueryLod takes no image operands
                    (opc_q == 16'd105 && wc_q > 16'd5 &&
                     ops_q[4] != 32'h0)) begin
                  done_code_q <= APU_SH_DONE_FAULT;
                  fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
                  st_q <= W_DONE;
                end else
                  st_q <= W_TX1;
              end
            endcase
          end
          W_TX1: begin
            logic [31:0] tg;
            tg = va_q[0][ls_lane_q[2:0]][1];
            if (!act_w[ls_lane_q[2:0]] ||
                (opc_q == 16'd99 &&
                 (dead_q[wave_q][ls_lane_q[2:0]] ||
                  hlp_w[ls_lane_q[2:0]]))) begin
              // !act: zero the lane result; dead and helper lanes
              // additionally drop image writes (side-effect suppress)
              for (int c = 0; c < VEC; c++)
                wb_q[ls_lane_q[2:0]][c] <= '0;
              if (ls_lane_q + 1 < LAN) begin
                ls_lane_q <= ls_lane_q + 1;
              end else begin
                ls_lane_q <= '0;
                tx_1lane_q <= 1'b0;
                st_q <= (opc_q == 16'd99) ? W_NEXT : W_WB;
              end
            end else begin
              dsc_set_q <= tg[19:12];
              dsc_bd_q  <= tg[27:20];
              dsc_idx_q <= va_q[0][ls_lane_q[2:0]][2][15:0];
              dret_q    <= W_TX2;
              st_q      <= W_DS0;
            end
          end
          W_TX2: begin
            // image record in tx_rec_q; kind vs op legality:
            //   invalid record   -> robust zero / dropped store
            //   kind mismatch    -> truthful device-lost
            if (!tx_rec_q[72]) begin
              robust_q <= robust_q + 1;
              tx_smpok_q <= 1'b0;
              st_q <= W_TX4;
            end else if (!f_tx_kind(opc_q, tx_rec_q[71:64])) begin
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else if (f_tx_smp(opc_q) &&
                         va_q[0][ls_lane_q[2:0]][1][31]) begin
              // OpSampledImage-merged: fetch the sampler record too
              tx_full_q <= 1'b0;      // keep the image record
              dsc_set_q <= va_q[0][ls_lane_q[2:0]][0][23:16];
              dsc_bd_q  <= va_q[0][ls_lane_q[2:0]][0][31:24];
              dsc_idx_q <= va_q[0][ls_lane_q[2:0]][0][15:0];
              dret_q    <= W_TX3;
              st_q      <= W_DS0;
            end else if (f_tx_smp(opc_q) &&
                         tx_rec_q[71:64] != 8'd1) begin
              // sampled-image without a bound sampler: cannot sample
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else begin
              tx_smp_q   <= tx_rec_q[223:160];
              tx_smpok_q <= tx_rec_q[71:64] == 8'd1;
              st_q       <= W_TX4;
            end
          end
          W_TX3: begin
            // dsc_rec_q = separate sampler record (kind must be 0)
            if (!dsc_rec_q[72] || dsc_rec_q[71:64] != 8'd0) begin
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else begin
              tx_smp_q   <= dsc_rec_q[223:160];
              tx_smpok_q <= 1'b1;
              st_q       <= W_TX4;
            end
          end
          // ---- G3a-ii: projected-sample preamble ---------------------
          // OpImageSampleProj*: the coordinate's last component divides
          // comps 0..1 (u,v) before any sampling maths — wave-wide, once
          // per instruction, before the per-lane record loop.  The
          // divisor index is the coord's vector width minus one
          // (ot_comps_q, read through W_OT0/W_OT1 from operand 1's
          // type row).
          W_TXJ0: begin
            ncomp_q <= 4'd2;
            jset(1, 5'd0, {2'd0, S_V1},
                 {2'd3, S_V1}, 7'h0, 1, 0, W_TXJ1,
                 1'b0, 1'b0, 2'b0, 2'(ot_comps_q - 3'd1));
          end
          W_TXJ1: begin                  // fold the quotient back
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < 2; c++)
                va_q[1][l][c] <= t0_q[l][c];
            st_q <= W_TX0;
          end
          // ---- G3a-ii: dref compare-operand quantize -------------------
          // The UNORM compare runs in the integer domain: ref16 =
          // RNE(clamp01(Dref) * 65535) — one pair of unit jobs per lane,
          // before the lod path.  D32_SFLOAT compares in fp directly.
          W_TXS0: begin
            txfa_q[0] <= f_f01(va_q[2][ls_lane_q[2:0]][0]);
            txfa_q[1] <= 32'h477F_FF00;   // 65535.0f
            ncomp_q   <= 4'd1;
            jset(0, 5'd2, {2'd0, S_TX}, {2'd3, S_TX},
                 {2'd0, S_ZERO}, 1, 0, W_TXS1,
                 1'b0, 1'b0, 2'b0, 2'd1);
          end
          W_TXS1:                        // ref16 = f2i(t0)
            jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                 {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_TXS2);
          W_TXS2: begin
            tx_r16_q <= t1_q[ls_lane_q[2:0]][0][15:0];
            // continue: explicit-lod forms straight into the coordinate
            // compute; implicit (and gather without a Lod operand)
            // derive λ first; a Bias operand detours through W_TXC0A
            st_q <= ((opc_q == 16'd90 || opc_q == 16'd94) ||
                     (opc_q == 16'd97 && tx_msk_q[1]))
                      ? ((tx_bsl_q != 3'd0) ? W_TXC0A : W_TXC0)
                      : W_TXL0;
          end
          // ---- format decode + mip/lod setup -------------------------
          // walk targets: tx_mt_q = primary level, tx_mt1_q = second
          // (trilinear); 5'h1F marks an unused target.  The walk seeds
          // here and iterates in W_TXM to tx_mret_q.
          W_TX4: begin
            logic [7:0] at;
            logic [4:0] lod;
            at = g6lc_apu_vn_pkg::APU_VN_IMG_ATTR[tx_rec_q[119:112]];
            tx_bad_q  <= 1'b0;
            tx_bpp_q  <= 5'(g6lc_apu_vn_pkg::APU_VN_IMG_BPP
                            [tx_rec_q[119:112]]);
            tx_nch_q  <= {1'b0, at[2:0]} + 4'd1;
            tx_isflt_q <= at[4] || at[5];
            tx_isf16_q <= at[5];
            tx_isint_q <= at[3];
            tx_issr_q  <= at[7];
            tx_lvl_q   <= tx_rec_q[123:120];
            tx_ly_q    <= (tx_rec_q[125:124] == 2'd1)
                          ? 16'(va_q[1][ls_lane_q[2:0]][2]) : 16'h0;
            tx_bcol_q  <= {1'b0, tx_smp_q[16:14]};
            tx_cen_q   <= tx_smp_q[20];           // compareEnable
            tx_cmp_q   <= tx_smp_q[19:17];        // compareOp
            // fetch/read/write fold the mip weight to 1.0 — W_TXC2
            // sets a real fraction only for OpImageSampleExplicitLod
            tx_fw_q    <= '0;
            if (!tx_rec_q[72]) begin
              // invalid record: no geometry — result is zero / the
              // store is dropped; W_TXR0 emits accordingly
              st_q <= W_TXR0;
            end else begin
              // seed the mip-layout walk
              tx_mcur_q <= '0; tx_macc_q <= '0;
              tx_wm_q   <= tx_rec_q[95:80];
              tx_hm_q   <= tx_rec_q[111:96];
              tx_mt1_q  <= 5'h1F;
              unique case (opc_q)
                16'd104, 16'd106:
                  st_q <= W_TXQ;           // no walk needed
                16'd103: begin             // QuerySizeLod
                  lod = va_q[1][ls_lane_q[2:0]][0][4:0];
                  tx_mt_q   <= (lod >= tx_rec_q[123:120])
                               ? tx_rec_q[123:120] - 5'd1 : lod;
                  tx_mret_q <= W_TXQ;
                  st_q      <= W_TXM;
                end
                // G3a-ii: dref ops quantize the compare reference once
                // per lane (W_TXS0..S2) then continue into the lod path
                16'd89, 16'd90, 16'd93, 16'd94, 16'd97:
                  st_q <= W_TXS0;
                // explicit-lod forms + gather-with-Lod take the direct
                // coordinate compute; the other implicit forms derive
                // λ from the quad-lane derivatives first
                16'd88, 16'd92, 16'd96:
                  st_q <= (opc_q == 16'd96 && !tx_msk_q[1])
                          ? W_TXL0
                          : ((tx_bsl_q != 3'd0) ? W_TXC0A : W_TXC0);
                16'd95, 16'd98, 16'd99: begin    // fetch / read / write
                  lod = (opc_q == 16'd95 && wc_q > 16'd6)
                        ? va_q[2][ls_lane_q[2:0]][0][4:0] : 5'h0;
                  if (lod >= tx_rec_q[123:120]) begin
                    // out-of-range lod: robust zero / dropped store
                    robust_q <= robust_q + 1;
                    st_q <= W_TXR0;
                  end else begin
                    tx_iu_q <= 32'(va_q[1][ls_lane_q[2:0]][0]);
                    tx_iv_q <= 32'(va_q[1][ls_lane_q[2:0]][1]);
                    tx_ld_q <= lod;
                    tx_mt_q <= lod;
                    tx_mret_q <= W_TXB;    // bounds + gather build
                    st_q      <= W_TXM;
                  end
                end
                default:                   // 87/91/105 implicit λ
                  st_q <= W_TXL0;
              endcase
            end
          end
          // mip-layout walk: pitch_m = align(w_m*bpp,64);
          // mip_bytes_m = pitch*h_m; layer_bytes = Σ all levels.
          // Captures {offset,pitch,dims} for tx_mt_q and tx_mt1_q.
          W_TXM: begin
            logic [31:0] pit;
            logic [15:0] wd, hd;
            wd  = tx_wm_q == 0 ? 16'd1 : tx_wm_q;
            hd  = tx_hm_q == 0 ? 16'd1 : tx_hm_q;
            pit = ({16'h0, wd} * {27'h0, tx_bpp_q} + 32'd63) &
                  ~32'd63;
            if (tx_mcur_q == tx_mt_q) begin
              tx_mof0_q <= tx_macc_q; tx_pit0_q <= pit;
              tx_w0_q   <= wd;        tx_h0_q   <= hd;
            end
            if (tx_mcur_q == tx_mt1_q) begin
              tx_mof1_q <= tx_macc_q; tx_pit1_q <= pit;
              tx_w1_q   <= wd;        tx_h1_q   <= hd;
            end
            tx_macc_q <= tx_macc_q + pit * {16'h0, hd};
            tx_wm_q   <= wd >> 1; tx_hm_q <= hd >> 1;
            tx_mcur_q <= tx_mcur_q + 5'd1;
            if (tx_mcur_q + 5'd1 >= tx_lvl_q) begin
              tx_laysz_q <= tx_macc_q + pit * {16'h0, hd};
              st_q <= tx_mret_q;
            end
          end
          // ---- implicit-LOD λ (op87, G2b) --------------------------
          // Per quad-lane derivatives of the texcoords, scaled by the
          // mip-0 dims: ρ² = max((du·w)²+(dv·h)² over x, same over y),
          // λ = ½·log2(ρ²).  G3a-ii: log2 is the §7d SFU log2 core
          // (deg-9 minimax in (m−1)/(m+1), 1-ulp class) — the earlier
          // linear-mantissa approximation (max error ~0.086) is gone;
          // the bias and min/max-lod clamps happen on the shared
          // W_TXC path.
          W_TXL0: begin                  // {w,h} -> f32 in t2
            txfa_q[0] <= {16'h0, tx_rec_q[95:80]};
            txfa_q[1] <= {16'h0, tx_rec_q[111:96]};
            ncomp_q <= 4'd2;
            jset(2, {1'b1, fpnew_pkg::RNE[2:0], 1'b1},
                 {2'd0, S_TX}, 7'h0, 7'h0, 3, 0, W_TXL1);
          end
          W_TXL1: begin                  // t0 = {du/dx, dv/dx}
            dva_q <= 2'd1; dla_q <= 3'd1; dlb_q <= 3'd2;
            ncomp_q <= 4'd2;
            jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                 {2'd0, S_VDB}, 1, 0, W_TXL2);
          end
          W_TXL2: begin                  // t1 = {du/dy, dv/dy}
            dla_q <= 3'd3; dlb_q <= 3'd4;
            ncomp_q <= 4'd2;
            jset(0, 5'd1, {2'd0, S_ZERO}, {2'd0, S_VDA},
                 {2'd0, S_VDB}, 2, 0, W_TXL3);
          end
          W_TXL3:                        // t0 *= {w,h}
            jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_T2},
                 {2'd0, S_ZERO}, 1, 0, W_TXL4);
          W_TXL4:                        // t1 *= {w,h}
            jset(0, 5'd2, {2'd0, S_T1}, {2'd0, S_T2},
                 {2'd0, S_ZERO}, 2, 0, W_TXL5);
          W_TXL5:                        // t2[0] = dx² (dot t0·t0)
            jset(0, 5'd3, {2'd2, S_T0}, {2'd2, S_T0},
                 {2'd0, S_T0}, 3, 1, W_TXL6);
          W_TXL6:                        // t1[0] = dy² (dot t1·t1)
            jset(0, 5'd3, {2'd2, S_T1}, {2'd2, S_T1},
                 {2'd0, S_T0}, 2, 1, W_TXL7);
          W_TXL7: begin                  // t0[0] = max(dx²,dy²) = ρ²
            ncomp_q <= 4'd1;
            jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                 {2'd0, S_T2}, {2'd0, S_T1}, 7'h0, 1, 0, W_TXL8);
          end
          // §7d/TEX-H1: λ = ½·log2(ρ²) now uses the SFU log2 core
          // (replaces the linear-mantissa approximation whose max error
          // was ~0.086 λ); ρ² in t0[.][0] moves to va0, the core returns
          // log2(ρ²) in t0[.][0] through xret_st_q and W_TXLC halves it.
          W_TXL8: begin                  // call SFU log2(ρ²)
            for (int l = 0; l < LAN; l++)
              va_q[0][l][0] <= t0_q[l][0];
            ncomp_q <= 4'd1;
            xsub_q <= 6'd2; xcall_q <= 1'b1;
            xret_q <= '0; xret_st_q <= W_TXLC;
            xq_q <= '0; st_q <= W_EX;
          end
          W_TXL9, W_TXLA, W_TXLB:        // (retired linear-mantissa λ)
            st_q <= W_TXLC;
          W_TXLC:                        // t0 = log2(ρ²) * 0.5 = λ
            jset(0, 5'd2, {2'd0, S_T0}, {2'd0, S_HALF},
                 {2'd0, S_ZERO}, 1, 0,
                 (tx_bsl_q != 3'd0) ? W_TXC0A : W_TXC0);
          // ---- sampled-coordinate compute (op88) ---------------------
          // lod*16 (fp job) -> F2I -> +bias, clamp [minLod,maxLod] and
          // mip range -> {m0,m1,fw}; dims -> fp scale; coords -> 8.8
          // fixed per mip; then the gather build wraps indices per
          // address mode.
          W_TXC0: begin
            // implicit forms (87/89/91/93/105 and gathers without a
            // Lod operand) take the computed λ from t0; explicit forms
            // read their lod operand (88/92 slot 2, 90/94/96 slot 3,
            // 97 slot 4)
            if (tx_qlod_q) tx_qraw_q <= t0_q[ls_lane_q[2:0]][0];
            txfa_q[0] <=
              (opc_q == 16'd87 || opc_q == 16'd89 || opc_q == 16'd91 ||
               opc_q == 16'd93 || opc_q == 16'd105 ||
               tx_bsl_q != 3'd0 ||   // W_TXC0A merged Bias into t0
               ((opc_q == 16'd96 || opc_q == 16'd97) && !tx_msk_q[1]))
                ? t0_q[ls_lane_q[2:0]][0]
                : va_q[(opc_q == 16'd88 || opc_q == 16'd92) ? 3'd2
                                                           : 3'd3]
                      [ls_lane_q[2:0]][0];
            t0_q[ls_lane_q[2:0]][0] <= 32'h4180_0000;  // 16.0f
            // t1 comp1 stages the fp32 array coordinate; W_TXC1's F2I
            // converts both comps (lod*16 -> int, coord.z -> layer)
            t1_q[ls_lane_q[2:0]][1] <= va_q[1][ls_lane_q[2:0]][2];
            tx_1lane_q <= 1'b1;
            ncomp_q    <= 4'd1;
            jset(0, 5'd3, {2'd1, S_TX}, {2'd1, S_T0},
                 {2'd0, S_ZERO}, 2, 0, W_TXC1);
          end
          // W_TXC0A: SPIR-V Bias image operand (mask bit 0) — λ += bias
          // in fp32 BEFORE the ·16 quantize (spec: λ_base + bias +
          // mipLodBias).  The merged value lands in t0 so the re-entered
          // W_TXC0 consumes it like an implicit λ.  The λ source: t0 for
          // the implicit forms, the shifted lod operand slot (3+bit0)
          // for a Lod+bias gather.
          W_TXC0A: begin
            txfa_q[0] <= ((opc_q == 16'd96 || opc_q == 16'd97) &&
                          tx_msk_q[1])
                           ? va_q[3'd3 + {2'b0, tx_msk_q[0]}]
                                 [ls_lane_q[2:0]][0]
                           : t0_q[ls_lane_q[2:0]][0];
            txfa_q[1] <= va_q[tx_bsl_q][ls_lane_q[2:0]][0];
            tx_1lane_q <= 1'b1;
            ncomp_q    <= 4'd1;
            // ADD adds operands b+c in this unit (a is unused on the
            // add/sub ops): stage λ/bias in txfa[0]/txfa[1] and read
            // them via the b/c slots
            jset(0, 5'd0, {2'd0, S_ZERO}, {2'd3, S_TX}, {2'd3, S_TX},
                 3'd1, 1'b0, W_TXC0, 1'b0, 1'b0, 2'd0, 2'd0, 2'd1);
          end
          W_TXC1: begin
            ncomp_q <= 4'd2;
            jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                 {2'd0, S_T1}, 7'h0, 7'h0, 3, 0, W_TXC1B);
          end
          W_TXC1B: begin
            // lod comp wants floor, not RNE: W_TXC2's own +0.5 round
            // is the mip-nearest decision, so the RNE above
            // double-rounds and tips boundary lods one mip early
            // (vkcmp tex_mip_nearest).  The array layer in comp1
            // keeps its RNE result from W_TXC1.
            ncomp_q <= 4'd1;
            jset(2, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                 {2'd0, S_T1}, 7'h0, 7'h0, 3, 0, W_TXC2);
          end
          W_TXC2: begin
            logic signed [11:0] le, bs;
            logic [7:0]         mn44, mx44;
            logic [4:0]         m0, m1;
            bs   = tx_smp_q[56] ? -12'({4'h0, tx_smp_q[55:48]})
                                : 12'({4'h0, tx_smp_q[55:48]});
            mn44 = tx_smp_q[39:32];
            mx44 = tx_smp_q[47:40];
            // λ·16 (and the bias) are signed: keep the clamp compares
            // signed or a negative λ wraps to a huge positive and
            // clamps to maxLod instead of 0
            le   = 12'($signed(t2_q[ls_lane_q[2:0]][0])) + bs;
            if (le < $signed({4'h0, mn44})) le = $signed({4'h0, mn44});
            if (le > $signed({4'h0, mx44})) le = $signed({4'h0, mx44});
            if (le < 0) le = 0;
            // array layer = RNE(coord.z), converted by the W_TXC1 F2I
            // comp1 (W_TXC5's F2I would overwrite t2 later);
            // only a 2D-array image owns an array layer — on 2D/3D/
            // cube records coord.z is the proj divisor or the depth
            // reference, not a layer index (W_TX4 already cleared it)
            if (tx_rec_q[125:124] == 2'd1)
              tx_ly_q <= 16'(t2_q[ls_lane_q[2:0]][1]);
            tx_lode_q <= le[8:0];
            if (tx_qlod_q) begin
              // OpImageQueryLod: {clamped, unclamped} — W_TXQ0 finishes
              st_q <= W_TXQ0;
            end else begin
            // magnification when lod <= 0, else minification; gathers
            // use the linear footprint math regardless of filter mode
            tx_lin_q  <= tx_gath_q ? 1'b1 :
                         (le > 12'sd0) ? tx_smp_q[3:2] != 2'd0
                                       : tx_smp_q[1:0] != 2'd0;
            if (tx_smp_q[4] && !tx_gath_q) begin   // mipmap LINEAR
              m0 = 5'(le >> 4);
              m1 = m0 + 5'd1;
              tx_fw_q <= {1'b0, le[3:0], 4'h0};
            end else if (tx_gath_q) begin        // gather: mip floor
              m0 = 5'(le >> 4);
              m1 = m0;
              tx_fw_q <= '0;
            end else begin                      // mipmap NEAREST
              m0 = 5'((le + 12'sd8) >> 4);
              m1 = m0;
              tx_fw_q <= '0;
            end
            if (m0 >= tx_lvl_q) m0 = tx_lvl_q - 5'd1;
            if (m1 >= tx_lvl_q) m1 = tx_lvl_q - 5'd1;
            tx_mt_q  <= m0;
            tx_mt1_q <= (m1 == m0) ? 5'h1F : m1;
            tx_mcur_q <= '0; tx_macc_q <= '0;
            tx_wm_q <= tx_rec_q[95:80];
            tx_hm_q <= tx_rec_q[111:96];
            tx_mret_q <= W_TXC3;
            st_q <= W_TXM;
            end
          end
          W_TXC3: begin
            // dims -> fp scale: LINEAR uses 8.8 fixed (w<<8),
            // NEAREST keeps plain pixel scale
            txfa_q[0] <= {16'h0, tx_w0_q} << (tx_lin_q ? 8 : 0);
            txfa_q[1] <= {16'h0, tx_h0_q} << (tx_lin_q ? 8 : 0);
            txfa_q[2] <= {16'h0, tx_w1_q} << (tx_lin_q ? 8 : 0);
            txfa_q[3] <= {16'h0, tx_h1_q} << (tx_lin_q ? 8 : 0);
            for (int c = 0; c < VEC; c++)
              t2_q[ls_lane_q[2:0]][c] <= tx_lin_q ? 32'hC300_0000
                                                  : 32'h0; // -128|0
            ncomp_q <= 4'd4;
            jset(2, {1'b1, fpnew_pkg::RNE[2:0], 1'b1},   // I2F (unsigned)
                 {2'd0, S_TX}, 7'h0, 7'h0, 1, 0, W_TXC4);
          end
          W_TXC4: begin
            // q = u*w - 0.5 (linear) / u*w (nearest), per mip pair
            txfa_q[0] <= va_q[1][ls_lane_q[2:0]][0];
            txfa_q[1] <= va_q[1][ls_lane_q[2:0]][1];
            txfa_q[2] <= va_q[1][ls_lane_q[2:0]][0];
            txfa_q[3] <= va_q[1][ls_lane_q[2:0]][1];
            ncomp_q <= 4'd4;
            jset(0, 5'd3, {2'd0, S_TX}, {2'd0, S_T0},
                 {2'd0, S_T2}, 2, 0, W_TXC5);
          end
          W_TXC5: begin
            jset(2, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                 {2'd0, S_T1}, 7'h0, 7'h0, 3, 0, W_TXC6);
          end
          W_TXC6: begin
            // build the gather list.  linear: t2 = {su0,sv0,su1,sv1}
            // s8.8; nearest: plain integer pixel indices.
            logic signed [31:0] su0, sv0, su1, sv1;
            logic [16:0]        wu0, wv0, wu1, wv1;
            logic [16:0]        cu0, cu1, cv0, cv1;
            logic [16:0]        du0, du1, dv0, dv1;
            logic [8:0]         npt;
            su0 = t2_q[ls_lane_q[2:0]][0];
            sv0 = t2_q[ls_lane_q[2:0]][1];
            su1 = t2_q[ls_lane_q[2:0]][2];
            sv1 = t2_q[ls_lane_q[2:0]][3];
            // ConstOffset (gathers): integer texel shift in the s8.8
            // domain, applied before the address-mode wrap
            if (tx_osl_q != 3'd0) begin
              su0 = su0 + ($signed(va_q[tx_osl_q]
                                    [ls_lane_q[2:0]][0]) <<< 8);
              sv0 = sv0 + ($signed(va_q[tx_osl_q]
                                    [ls_lane_q[2:0]][1]) <<< 8);
            end
            tx_gn_q <= '0; tx_gi_q <= '0;
            for (int c = 0; c < 4; c++) begin
              tx_acc_q[c]  <= '0; tx_acc1_q[c] <= '0;
              t2_q[ls_lane_q[2:0]][c] <= '0;    // fp acc reset
            end
            if (tx_gath_q) begin
              // gather footprint: the linear corner texels of mip m0 in
              // the SPIR-V result order (i0,j1),(i1,j1),(i1,j0),(i0,j0)
              cu0 = f_twrap(su0 >>> 8, tx_w0_q, tx_smp_q[7:5]);
              cu1 = f_twrap((su0 >>> 8) + 1, tx_w0_q, tx_smp_q[7:5]);
              cv0 = f_twrap(sv0 >>> 8, tx_h0_q, tx_smp_q[10:8]);
              cv1 = f_twrap((sv0 >>> 8) + 1, tx_h0_q, tx_smp_q[10:8]);
              tx_gn_q <= 4'd4;
              tx_gu_q[0] <= 32'(cu0[15:0]);      // (i0,j1) -> R
              tx_gv_q[0] <= 32'(cv1[15:0]);
              tx_gb_q[0] <= cu0[16] || cv1[16];
              tx_gw_q[0] <= 17'd65536; tx_gm_q[0] <= '0;
              tx_gu_q[1] <= 32'(cu1[15:0]);      // (i1,j1) -> G
              tx_gv_q[1] <= 32'(cv1[15:0]);
              tx_gb_q[1] <= cu1[16] || cv1[16];
              tx_gw_q[1] <= 17'd65536; tx_gm_q[1] <= '0;
              tx_gu_q[2] <= 32'(cu1[15:0]);      // (i1,j0) -> B
              tx_gv_q[2] <= 32'(cv0[15:0]);
              tx_gb_q[2] <= cu1[16] || cv0[16];
              tx_gw_q[2] <= 17'd65536; tx_gm_q[2] <= '0;
              tx_gu_q[3] <= 32'(cu0[15:0]);      // (i0,j0) -> A
              tx_gv_q[3] <= 32'(cv0[15:0]);
              tx_gb_q[3] <= cu0[16] || cv0[16];
              tx_gw_q[3] <= 17'd65536; tx_gm_q[3] <= '0;
            end else if (tx_lin_q) begin
              // mip0 axis wrap
              cu0 = f_twrap(su0 >>> 8, tx_w0_q, tx_smp_q[7:5]);
              cu1 = f_twrap((su0 >>> 8) + 1, tx_w0_q, tx_smp_q[7:5]);
              cv0 = f_twrap(sv0 >>> 8, tx_h0_q, tx_smp_q[10:8]);
              cv1 = f_twrap((sv0 >>> 8) + 1, tx_h0_q, tx_smp_q[10:8]);
              wu0 = 17'(9'd256 - {1'b0, su0[7:0]});
              wu1 = 17'({1'b0, su0[7:0]});
              wv0 = 17'(9'd256 - {1'b0, sv0[7:0]});
              wv1 = 17'({1'b0, sv0[7:0]});
              tx_gn_q <= 4'd4 + ((tx_mt1_q != 5'h1F) ? 4'd4 : 4'd0);
              // mip0 texels
              tx_gu_q[0] <= 32'(cu0[15:0]);
              tx_gv_q[0] <= 32'(cv0[15:0]);
              tx_gb_q[0] <= cu0[16] || cv0[16];
              tx_gw_q[0] <= wu0 * wv0; tx_gm_q[0] <= '0;
              tx_gu_q[1] <= 32'(cu1[15:0]);
              tx_gv_q[1] <= 32'(cv0[15:0]);
              tx_gb_q[1] <= cu1[16] || cv0[16];
              tx_gw_q[1] <= wu1 * wv0; tx_gm_q[1] <= '0;
              tx_gu_q[2] <= 32'(cu0[15:0]);
              tx_gv_q[2] <= 32'(cv1[15:0]);
              tx_gb_q[2] <= cu0[16] || cv1[16];
              tx_gw_q[2] <= wu0 * wv1; tx_gm_q[2] <= '0;
              tx_gu_q[3] <= 32'(cu1[15:0]);
              tx_gv_q[3] <= 32'(cv1[15:0]);
              tx_gb_q[3] <= cu1[16] || cv1[16];
              tx_gw_q[3] <= wu1 * wv1; tx_gm_q[3] <= '0;
              if (tx_mt1_q != 5'h1F) begin
                // mip1 axis wrap
                du0 = f_twrap(su1 >>> 8, tx_w1_q, tx_smp_q[7:5]);
                du1 = f_twrap((su1 >>> 8) + 1, tx_w1_q, tx_smp_q[7:5]);
                dv0 = f_twrap(sv1 >>> 8, tx_h1_q, tx_smp_q[10:8]);
                dv1 = f_twrap((sv1 >>> 8) + 1, tx_h1_q, tx_smp_q[10:8]);
                wu0 = 17'(9'd256 - {1'b0, su1[7:0]});
                wu1 = 17'({1'b0, su1[7:0]});
                wv0 = 17'(9'd256 - {1'b0, sv1[7:0]});
                wv1 = 17'({1'b0, sv1[7:0]});
                tx_gu_q[4] <= 32'(du0[15:0]);
                tx_gv_q[4] <= 32'(dv0[15:0]);
                tx_gb_q[4] <= du0[16] || dv0[16];
                tx_gw_q[4] <= wu0 * wv0; tx_gm_q[4] <= 5'd1;
                tx_gu_q[5] <= 32'(du1[15:0]);
                tx_gv_q[5] <= 32'(dv0[15:0]);
                tx_gb_q[5] <= du1[16] || dv0[16];
                tx_gw_q[5] <= wu1 * wv0; tx_gm_q[5] <= 5'd1;
                tx_gu_q[6] <= 32'(du0[15:0]);
                tx_gv_q[6] <= 32'(dv1[15:0]);
                tx_gb_q[6] <= du0[16] || dv1[16];
                tx_gw_q[6] <= wu0 * wv1; tx_gm_q[6] <= 5'd1;
                tx_gu_q[7] <= 32'(du1[15:0]);
                tx_gv_q[7] <= 32'(dv1[15:0]);
                tx_gb_q[7] <= du1[16] || dv1[16];
                tx_gw_q[7] <= wu1 * wv1; tx_gm_q[7] <= 5'd1;
              end
            end else begin
              // NEAREST: one texel per selected mip
              cu0 = f_twrap(su0, tx_w0_q, tx_smp_q[7:5]);
              cv0 = f_twrap(sv0, tx_h0_q, tx_smp_q[10:8]);
              tx_gn_q <= (tx_mt1_q != 5'h1F) ? 4'd2 : 4'd1;
              tx_gu_q[0] <= 32'(cu0[15:0]);
              tx_gv_q[0] <= 32'(cv0[15:0]);
              tx_gb_q[0] <= cu0[16] || cv0[16];
              tx_gw_q[0] <= 17'd65536; tx_gm_q[0] <= '0;
              if (tx_mt1_q != 5'h1F) begin
                du0 = f_twrap(su1, tx_w1_q, tx_smp_q[7:5]);
                dv0 = f_twrap(sv1, tx_h1_q, tx_smp_q[10:8]);
                tx_gu_q[1] <= 32'(du0[15:0]);
                tx_gv_q[1] <= 32'(dv0[15:0]);
                tx_gb_q[1] <= du0[16] || dv0[16];
                tx_gw_q[1] <= 17'd65536; tx_gm_q[1] <= 5'd1;
              end
            end
            st_q <= W_TXT0;
          end
          // ---- integer-coordinate ops: bounds + single point ---------
          W_TXB: begin
            // lod/dims ready (w0/h0/pit0/mof0); bounds-check then one
            // gather point (fetch/read) or the store path (write)
            if (tx_ly_q >= tx_rec_q[143:128] ||
                tx_iu_q < 0 || tx_iv_q < 0 ||
                tx_iu_q >= 32'({16'h0, tx_w0_q}) ||
                tx_iv_q >= 32'({16'h0, tx_h0_q})) begin
              robust_q  <= robust_q + 1;
              tx_bad_q  <= 1'b1;
              st_q <= W_TXR0;          // zeros / dropped store
            end else begin
              tx_ta_q <= tx_rec_q[31:0] +
                         {16'h0, tx_ly_q} * tx_laysz_q +
                         tx_mof0_q +
                         {16'h0, tx_iv_q[15:0]} * tx_pit0_q +
                         {16'h0, tx_iu_q[15:0]} * {27'h0, tx_bpp_q};
              if (opc_q == 16'd99) begin
                tx_gb_q[0] <= 1'b0;
                st_q <= W_TXE0;        // encode then write
              end else begin
                // fetch/read: one gather point; per-lane accumulator
                // clear (the sampled path clears in W_TXC6 instead)
                tx_gn_q <= 4'd1; tx_gi_q <= '0;
                tx_gu_q[0] <= tx_iu_q; tx_gv_q[0] <= tx_iv_q;
                tx_gm_q[0] <= '0; tx_gb_q[0] <= 1'b0;
                tx_gw_q[0] <= 17'd65536;
                for (int c = 0; c < 4; c++) begin
                  tx_acc_q[c]  <= '0;
                  tx_acc1_q[c] <= '0;
                  t2_q[ls_lane_q[2:0]][c] <= '0;  // fp acc reset
                end
                st_q <= W_TXT0;
              end
            end
          end
          // ---- texel fetch loop --------------------------------------
          // W_TXT0 computes the byte address of gather point tx_gi_q,
          // probes the texture cache, and either reads the SRAM word
          // (hit) or walks an 8-beat line fill (miss).  Border points
          // skip memory entirely.
          W_TXT0: begin
            logic [31:0] ta, mof, pit;
            logic [15:0] gwd, ghd;
            mof = tx_gm_q[tx_gi_q[2:0]] == 5'd1 ? tx_mof1_q
                                                : tx_mof0_q;
            pit = tx_gm_q[tx_gi_q[2:0]] == 5'd1 ? tx_pit1_q
                                                : tx_pit0_q;
            ta  = tx_rec_q[31:0] +
                  {16'h0, tx_ly_q} * tx_laysz_q + mof +
                  {16'h0, tx_gv_q[tx_gi_q[2:0]][15:0]} * pit +
                  {16'h0, tx_gu_q[tx_gi_q[2:0]][15:0]} *
                  {27'h0, tx_bpp_q};
            tx_ta_q  <= ta;
            tx_brd_q <= tx_gb_q[tx_gi_q[2:0]];
            if (tx_gb_q[tx_gi_q[2:0]]) begin
              st_q <= W_TXD;                 // border colour
            end else if (ta + {27'h0, tx_bpp_q} >
                         tx_rec_q[31:0] + tx_rec_q[63:32]) begin
              // past the view's bound extent: robust zero
              robust_q <= robust_q + 1;
              tx_brd_q <= 1'b1;
              st_q <= W_TXD;
            end else
              st_q <= W_TXP;                 // probe with latched ta
          end
          // W_TXP probes the cache tag against the LATCHED tx_ta_q —
          // doing it in W_TXT0 would compare the previous gather
          // point's address (false hits on stale tags/word indices)
          W_TXP: begin
            if (txc_hit_w) begin
              st_q <= W_TXT1;                // SRAM read in port comb
            end else begin
              txc_ln_q    <= txc_vic_q;
              txc_addr_q  <= {tx_ta_q[31:6], 6'b0};
              txc_fi_q    <= '0;
              st_q <= W_TXF0;
            end
          end
          W_TXT1: begin
            // first 8B word captured; a 16B texel needs word+1
            // (second SRAM read issued combinationally below)
            tx_td_q[0] <= txc_rd;
            st_q <= (tx_bpp_q > 5'd8) ? W_TXT2 : W_TXD;
          end
          W_TXT2: begin
            tx_td_q[1] <= txc_rd;
            st_q <= W_TXD;
          end
          // line fill: 8 x 8B beats into the victim line, then retry
          W_TXF0: begin
            if (mem_ready_i) st_q <= W_TXF1;
          end
          W_TXF1: begin
            if (mem_rvalid_i) begin
              // sram write of the beat is driven in the port comb
              if (mem_err_i) robust_q <= robust_q + 1;
              txc_fi_q   <= txc_fi_q + 3'd1;
              txc_addr_q <= txc_addr_q + 32'd8;
              if (txc_fi_q == 3'd7) begin
                txc_v_q[txc_ln_q]   <= 1'b1;
                txc_tag_q[txc_ln_q] <= tx_ta_q[31:6];
                txc_vic_q <= txc_vic_q == 4'(TexCacheLines - 1)
                             ? 4'h0 : txc_vic_q + 4'd1;
                st_q <= W_TXP;             // re-probe filled line
              end else st_q <= W_TXF0;
            end
          end
          // ---- texel decode -------------------------------------------
          // Border points or robust misses decode to the border/zero
          // colour; otherwise the raw bytes expand to either the u16
          // linear channels (UNORM/sRGB), fp32 channels (SFLOAT), or
          // raw ints (UINT) — missing channels are {0,0,0,max}.
          W_TXD: begin
            logic [7:0]   by [16];
            logic [7:0]   fmt;
            logic         bgr;
            logic [127:0] tdw;
            fmt = tx_rec_q[119:112];
            bgr = g6lc_apu_vn_pkg::APU_VN_IMG_ATTR[fmt][6];
            // sub-word texels: the 8B SRAM word holds two RGBA8 texels
            // (or 4/8 narrower ones) — byte-align the window on
            // tx_ta_q[2:0] exactly like the store path's tx_wbe shift
            tdw = {tx_td_q[1], tx_td_q[0]} >>
                  {25'h0, tx_ta_q[2:0], 3'b000};
            for (int i = 0; i < 16; i++)
              by[i] = tdw[8 * i +: 8];
            for (int c = 0; c < 4; c++) begin
              tx_ch_q[c] <= '0; tx_fc_q[c] <= '0;
            end
            if (tx_brd_q) begin
              for (int c = 0; c < 4; c++) begin
                tx_ch_q[c] <= f_bord16(tx_bcol_q[2:0], 3'(c));
                // int formats take the integer border (opaque white =
                // all-ones, opaque black = alpha 1); float sel on an
                // int image is UB and maps onto the same numerals
                tx_fc_q[c] <= tx_isint_q
                    ? (tx_bcol_q[2:0] >= 3'd4 ? 32'd1
                       : (tx_bcol_q[2:0] == 3'd3 && c == 3)
                         ? 32'd1 : 32'h0)
                    : f_bord32(tx_bcol_q[2:0], 3'(c));
              end
            end else unique case (fmt)
              8'd0: begin                        // R8_UNORM
                tx_ch_q[0] <= {by[0], by[0]};
                tx_ch_q[3] <= 16'hFFFF;
              end
              8'd1: begin                        // R8G8_UNORM
                tx_ch_q[0] <= {by[0], by[0]};
                tx_ch_q[1] <= {by[1], by[1]};
                tx_ch_q[3] <= 16'hFFFF;
              end
              8'd2, 8'd4: begin                  // [B]RGBA8_UNORM
                tx_ch_q[bgr ? 2 : 0] <= {by[0], by[0]};
                tx_ch_q[1]           <= {by[1], by[1]};
                tx_ch_q[bgr ? 0 : 2] <= {by[2], by[2]};
                tx_ch_q[3]           <= {by[3], by[3]};
              end
              8'd3, 8'd5: begin                  // [B]RGBA8_SRGB
                tx_ch_q[bgr ? 2 : 0] <=
                  g6lc_apu_srgb_pkg::APU_SRGB_TO_LIN[by[0]];
                tx_ch_q[1] <=
                  g6lc_apu_srgb_pkg::APU_SRGB_TO_LIN[by[1]];
                tx_ch_q[bgr ? 0 : 2] <=
                  g6lc_apu_srgb_pkg::APU_SRGB_TO_LIN[by[2]];
                tx_ch_q[3] <= {by[3], by[3]};    // alpha is linear
              end
              8'd6: begin                        // RGBA16_SFLOAT
                for (int c = 0; c < 4; c++)
                  tx_fc_q[c] <= f_f16_f32(tdw[16 * c +: 16]);
              end
              8'd7: begin                        // R32_SFLOAT
                tx_fc_q[0] <= tdw[31:0];
                tx_fc_q[3] <= 32'h3F80_0000;
              end
              8'd8: begin                        // R32G32_SFLOAT
                tx_fc_q[0] <= tdw[31:0];
                tx_fc_q[1] <= tdw[63:32];
                tx_fc_q[3] <= 32'h3F80_0000;
              end
              8'd9: begin                        // R32G32B32A32_SFLOAT
                for (int c = 0; c < 4; c++)
                  tx_fc_q[c] <= tdw[32 * c +: 32];
              end
              8'd10: begin                       // R32_UINT
                tx_fc_q[0] <= tdw[31:0];
                tx_fc_q[3] <= 32'd1;
              end
              default: begin                     // R32G32B32A32_UINT
                for (int c = 0; c < 4; c++)
                  tx_fc_q[c] <= tdw[32 * c +: 32];
              end
            endcase
            // G3a-ii dref: replace the decoded texel with the compare
            // result — PCF = per-texel compare, then the same weight
            // apply (linear/trilinear) as colour sampling
            if (tx_dref_q) begin
              logic cmp;
              if (!tx_cen_q) begin
                cmp = 1'b1;              // no compareOp -> pass
              end else if (tx_isflt_q) begin
                // SFLOAT depth (D32): fp32 compare, ref unclamped
                cmp = f_fcmp32(va_q[2][ls_lane_q[2:0]][0],
                               tx_brd_q ? f_bord32(tx_bcol_q[2:0], 3'd0)
                                        : tdw[31:0], tx_cmp_q);
              end else if (!tx_isint_q) begin
                // UNORM depth (D16): ref pre-quantized to u16 (W_TXS*)
                cmp = f_dcmp(tx_r16_q,
                             tx_brd_q ? f_bord16(tx_bcol_q[2:0], 3'd0)
                                      : tdw[15:0], tx_cmp_q);
              end else begin
                cmp = 1'b1;              // int formats: no compare
              end
              tx_fc_q[0] <= cmp ? 32'h3F80_0000 : 32'h0;
              tx_fc_q[1] <= 32'h0; tx_fc_q[2] <= 32'h0;
              tx_fc_q[3] <= 32'h0;
            end
            st_q <= W_TXA;
          end
          // ---- accumulate ----------------------------------------------
          W_TXA: begin
            if (tx_gath_q) begin
              // G3a-ii gather: point gi feeds result component gi
              // (the spec-order footprint was built in W_TXC6); the
              // component operand picks the texel channel through the
              // view swizzle
              logic [2:0] s;
              s = f_swz(tx_rec_q[155:144],
                        2'(va_q[2][ls_lane_q[2:0]][0]));
              if (tx_dref_q) begin
                wb_q[ls_lane_q[2:0]][tx_gi_q[1:0]] <= tx_fc_q[0];
                tx_gi_q <= tx_gi_q + 4'd1;
                st_q <= (tx_gi_q + 4'd1 >= tx_gn_q) ? W_TXN : W_TXT0;
              end else if (tx_isint_q) begin
                wb_q[ls_lane_q[2:0]][tx_gi_q[1:0]] <=
                  s == 3'd1 ? 32'h0 : s == 3'd2 ? 32'd1
                                              : tx_fc_q[s - 3'd3];
                tx_gi_q <= tx_gi_q + 4'd1;
                st_q <= (tx_gi_q + 4'd1 >= tx_gn_q) ? W_TXN : W_TXT0;
              end else if (tx_isflt_q) begin
                wb_q[ls_lane_q[2:0]][tx_gi_q[1:0]] <=
                  s == 3'd1 ? 32'h0 : s == 3'd2 ? 32'h3F80_0000
                                              : tx_fc_q[s - 3'd3];
                tx_gi_q <= tx_gi_q + 4'd1;
                st_q <= (tx_gi_q + 4'd1 >= tx_gn_q) ? W_TXN : W_TXT0;
              end else begin
                // UNORM/sRGB: ch16 -> fp32 normalize (W_TXG0 finishes)
                txfa_q[0] <= s == 3'd1 ? 32'h0 :
                             s == 3'd2 ? 32'd65535
                                       : {16'h0, tx_ch_q[s - 3'd3]};
                ncomp_q <= 4'd1;
                jset(2, {1'b1, fpnew_pkg::RNE[2:0], 1'b1},
                     {2'd0, S_TX}, 7'h0, 7'h0, 1, 0, W_TXG0);
              end
            end else if (tx_isint_q) begin
              // single-point raw result: swizzle into wb directly
              for (int c = 0; c < VEC; c++) begin
                logic [2:0] s;
                s = f_swz(tx_rec_q[155:144], 2'(c));
                wb_q[ls_lane_q[2:0]][c] <=
                  s == 3'd1 ? 32'h0 :
                  s == 3'd2 ? 32'd1 : tx_fc_q[s - 3'd3];
              end
              st_q <= W_TXR0;
            end else if (tx_isflt_q || tx_dref_q) begin
              // fp32 accumulate: stage texel into t1 row, then
              // i2f(W)*2^-24 -> FMADD into the t2 row accumulator;
              // dref ops ride this path with fc[0] = compare result
              for (int c = 0; c < VEC; c++)
                t1_q[ls_lane_q[2:0]][c] <= tx_fc_q[c];
              txfa_q[0] <= {6'h0,
                            26'(tx_gw_q[tx_gi_q[2:0]]) *
                            26'(tx_gm_q[tx_gi_q[2:0]] == 5'd1
                                ? {1'b0, tx_fw_q}
                                : 9'd256 - {1'b0, tx_fw_q})};
              ncomp_q <= 4'd1;
              jset(2, {1'b1, fpnew_pkg::RNE[2:0], 1'b1},
                   {2'd1, S_TX}, 7'h0, 7'h0, 1, 0, W_TXA2);
            end else begin
              // fixed-point u16 path: acc_mip[c] += (wu*wv) * ch16
              logic [32:0] pr;
              for (int c = 0; c < 4; c++) begin
                pr = 33'(tx_gw_q[tx_gi_q[2:0]]) *
                     33'({17'h0, tx_ch_q[c]});
                if (tx_gm_q[tx_gi_q[2:0]] == 5'd1)
                  tx_acc1_q[c] <= tx_acc1_q[c] + 40'(pr);
                else
                  tx_acc_q[c] <= tx_acc_q[c] + 40'(pr);
              end
              tx_gi_q <= tx_gi_q + 4'd1;
              st_q <= (tx_gi_q + 4'd1 >= tx_gn_q) ? W_TXR0 : W_TXT0;
            end
          end
          W_TXA2: begin                        // w_f = i2f(W) * 2^-24
            txfa_q[0] <= 32'h3380_0000;   // 2^-24 (gw<=2^16, mf<=2^8)
            ncomp_q <= 4'd1;
            jset(0, 5'd2, {2'd1, S_T0}, {2'd1, S_TX},
                 {2'd0, S_ZERO}, 1, 0, W_TXA3);
          end
          W_TXA3: begin                        // acc[c] += w * t[c]
            ncomp_q <= 4'd4;                   // all channels, not
            jset(0, 5'd3, {2'd1, S_T0}, {2'd0, S_T1},   // just comp0
                 {2'd0, S_T2}, 3, 0, W_TXA4);
          end
          W_TXA4: begin
            tx_gi_q <= tx_gi_q + 4'd1;
            st_q <= (tx_gi_q + 4'd1 >= tx_gn_q) ? W_TXR0 : W_TXT0;
          end
          // ---- per-lane result ---------------------------------------
          W_TXR0: begin
            logic [15:0] rrm [4];
            logic [15:0] r1c;
            logic [2:0]  s;
            if (!tx_rec_q[72] || tx_bad_q) begin
              // invalid record or out-of-bounds: robust zero for reads,
              // dropped write for stores
              if (opc_q != 16'd99)
                for (int c = 0; c < VEC; c++)
                  wb_q[ls_lane_q[2:0]][c] <= '0;
              st_q <= W_TXN;
            end else if (tx_dref_q) begin
              // G3a-ii: dref sample result is the scalar compare
              // fraction in accumulator comp0 (swizzle does not apply)
              wb_q[ls_lane_q[2:0]][0] <= t2_q[ls_lane_q[2:0]][0];
              wb_q[ls_lane_q[2:0]][1] <= 32'h0;
              wb_q[ls_lane_q[2:0]][2] <= 32'h0;
              wb_q[ls_lane_q[2:0]][3] <= 32'h0;
              st_q <= W_TXN;
            end else if (tx_isint_q) begin
              st_q <= W_TXN;           // wb written in W_TXA
            end else if (tx_isflt_q) begin
              for (int c = 0; c < VEC; c++) begin
                s = f_swz(tx_rec_q[155:144], 2'(c));
                wb_q[ls_lane_q[2:0]][c] <=
                  s == 3'd1 ? 32'h0 :
                  s == 3'd2 ? 32'h3F80_0000 :
                  t2_q[ls_lane_q[2:0]][s - 3'd3];
              end
              st_q <= W_TXN;
            end else begin
              // u16 accumulators -> rounded 16-bit per mip ->
              // trilinear blend -> swizzle -> fp32 via I2F * (1/65535)
              for (int c = 0; c < 4; c++) begin
                rrm[c] = (tx_acc_q[c] + 40'h8000 >= 40'h1_0000_0000)
                         ? 16'hFFFF
                         : 16'((tx_acc_q[c] + 40'h8000) >> 16);
                if (tx_mt1_q != 5'h1F) begin
                  r1c = (tx_acc1_q[c] + 40'h8000 >= 40'h1_0000_0000)
                        ? 16'hFFFF
                        : 16'((tx_acc1_q[c] + 40'h8000) >> 16);
                  rrm[c] = 16'((25'(rrm[c]) *
                                25'(9'd256 - {1'b0, tx_fw_q}) +
                                25'(r1c) * 25'({1'b0, tx_fw_q}) +
                                25'd128) >> 8);
                end
              end
              for (int c = 0; c < 4; c++) begin
                s = f_swz(tx_rec_q[155:144], 2'(c));
                txfa_q[c] <= s == 3'd1 ? 32'h0 :
                             s == 3'd2 ? 32'd65535 :
                             {16'h0, rrm[s - 3'd3]};
              end
              ncomp_q <= 4'd4;
              jset(2, {1'b1, fpnew_pkg::RNE[2:0], 1'b1},
                   {2'd0, S_TX}, 7'h0, 7'h0, 1, 0, W_TXR1);
            end
          end
          W_TXR1: begin
            txfa_q[0] <= 32'h3780_0080;   // 1/65535
            ncomp_q <= 4'd4;
            jset(0, 5'd2, {2'd0, S_T0}, {2'd1, S_TX},
                 {2'd0, S_ZERO}, 0, 0, W_TXN);
          end
          W_TXN: begin
            if (ls_lane_q + 4'd1 < LAN) begin
              ls_lane_q <= ls_lane_q + 4'd1;
              st_q <= W_TX1;
            end else begin
              ls_lane_q <= '0;
              tx_1lane_q <= 1'b0;
              st_q <= (opc_q == 16'd99) ? W_NEXT : W_WB;
            end
          end
          // ---- store encode (op99): value channels -> texel bytes ----
          W_TXE0: begin
            logic [7:0] fmt;
            fmt = tx_rec_q[119:112];
            txc_fi_q <= '0;
            tx_stb_q <= '0;
            tx_wbe_q <= (tx_bpp_q < 5'd8)
                        ? ((8'hFF >> (4'd8 - {1'b0, tx_bpp_q[2:0]})) <<
                           tx_ta_q[2:0])
                        : 8'hFF;
            if (tx_isint_q || (tx_isflt_q && !tx_isf16_q)) begin
              for (int c = 0; c < 4; c++)
                if (4'(c) < tx_nch_q)
                  tx_stb_q[32 * c +: 32] <=
                    va_q[2][ls_lane_q[2:0]][c];
              st_q <= W_TXW0;
            end else if (tx_isf16_q) begin
              for (int c = 0; c < 4; c++)
                if (4'(c) < tx_nch_q)
                  tx_stb_q[16 * c +: 16] <=
                    f_f32_f16(va_q[2][ls_lane_q[2:0]][c]);
              st_q <= W_TXW0;
            end else begin
              // UNORM / sRGB: clamp fp -> [0,1] -> *255 or *65535
              for (int c = 0; c < 4; c++)
                txfa_q[c] <= f_f01(va_q[2][ls_lane_q[2:0]][c]);
              for (int c = 0; c < 4; c++)
                t0_q[ls_lane_q[2:0]][c] <=
                  (tx_issr_q && c < 3) ? 32'h477F_FF00   // 65535.0f
                                       : 32'h437F_0000;  // 255.0f
              ncomp_q <= 4'd4;
              jset(0, 5'd2, {2'd0, S_TX}, {2'd0, S_T0},
                   {2'd0, S_ZERO}, 1, 0, W_TXE1);
            end
          end
          W_TXE1: begin
            tx_se_c_q  <= '0;
            tx_se_lo_q <= '0;
            tx_se_hi_q <= 8'd255;
            jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                 {2'd0, S_T0}, 7'h0, 7'h0, 2, 0, W_TXE2);
          end
          W_TXE2: begin
            // per channel: UNORM clamps the fp-int; sRGB channels
            // binary-search APU_SRGB_TO_LIN for the nearest code
            // (ties resolve upward, matching srgb_lut.py)
            logic [31:0] xv;
            logic [15:0] x16;
            logic [7:0]  mid, u8v;
            logic        last;
            xv   = t1_q[ls_lane_q[2:0]][tx_se_c_q];
            x16  = xv[31] ? 16'h0 :
                   (xv > 32'd65535) ? 16'hFFFF : xv[15:0];
            last = (tx_se_c_q + 3'd1 == 3'(tx_nch_q));
            u8v  = xv[31] ? 8'h0 : (xv > 32'd255) ? 8'hFF : xv[7:0];
            if (tx_issr_q && tx_se_c_q < 3 &&
                tx_se_lo_q < tx_se_hi_q) begin
              mid = 8'((9'(tx_se_lo_q) + 9'(tx_se_hi_q) + 9'd1) >> 1);
              if (g6lc_apu_srgb_pkg::APU_SRGB_TO_LIN[mid] <= x16)
                tx_se_lo_q <= mid;
              else
                tx_se_hi_q <= mid - 8'd1;
            end else begin
              if (tx_issr_q && tx_se_c_q < 3) begin
                if (tx_se_lo_q < 8'd255 &&
                    {1'b0, g6lc_apu_srgb_pkg::APU_SRGB_TO_LIN
                          [tx_se_lo_q + 8'd1]} - {1'b0, x16} <=
                    {1'b0, x16} - {1'b0, g6lc_apu_srgb_pkg::APU_SRGB_TO_LIN
                          [tx_se_lo_q]})
                  u8v = tx_se_lo_q + 8'd1;
                else
                  u8v = tx_se_lo_q;
              end
              tx_se_i_q[tx_se_c_q] <= u8v;
              tx_se_c_q  <= tx_se_c_q + 3'd1;
              tx_se_lo_q <= '0;
              tx_se_hi_q <= 8'd255;
              if (last) begin
                // pack bytes; BGR formats swap R<->B in memory order
                logic bgr;
                bgr = g6lc_apu_vn_pkg::APU_VN_IMG_ATTR
                      [tx_rec_q[119:112]][6];
                for (int c = 0; c < 4; c++) begin
                  logic [1:0] bi;
                  bi = bgr ? (c == 0 ? 2'd2 : c == 2 ? 2'd0 : 2'(c))
                           : 2'(c);
                  if (4'(c) < tx_nch_q)
                    tx_stb_q[8 * bi +: 8] <=
                      (3'(c) == tx_se_c_q) ? u8v : tx_se_i_q[c];
                end
                st_q <= W_TXW0;
              end
            end
          end
          // ---- store beats --------------------------------------------
          // W_TXW0 holds mem_we_o until ready; W_TXW1 waits the write
          // response (one per accepted request) and chains beat 1 for
          // 16B texels.  A store invalidates the covering cache line.
          W_TXW0: begin
            if (txc_fi_q == 3'd0)
              for (int c = 0; c < TexCacheLines; c++)
                if (txc_v_q[c] && txc_tag_q[c] == tx_ta_q[31:6])
                  txc_v_q[c] <= 1'b0;
            if (mem_ready_i) st_q <= W_TXW1;
          end
          W_TXW1: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) robust_q <= robust_q + 1;
              if (tx_bpp_q > 5'd8 && txc_fi_q == 3'd0) begin
                tx_ta_q  <= tx_ta_q + 32'd8;
                tx_stb_q <= {64'h0, tx_stb_q[127:64]};
                txc_fi_q <= 3'd1;
                st_q <= W_TXW0;
              end else st_q <= W_TXN;
            end
          end
          // ---- query results -------------------------------------------
          W_TXQ: begin
            unique case (opc_q)
              16'd106:                      // OpImageQueryLevels
                wb_q[ls_lane_q[2:0]][0] <= {27'h0, tx_lvl_q};
              16'd103: begin                // OpImageQuerySizeLod
                wb_q[ls_lane_q[2:0]][0] <= {16'h0, tx_w0_q};
                wb_q[ls_lane_q[2:0]][1] <= {16'h0, tx_h0_q};
                if (tx_rec_q[125:124] == 2'd1)
                  wb_q[ls_lane_q[2:0]][2] <=
                    {16'h0, tx_rec_q[143:128]};
              end
              default: begin                // OpImageQuerySize
                wb_q[ls_lane_q[2:0]][0] <= tx_rec_q[95:80];
                wb_q[ls_lane_q[2:0]][1] <= tx_rec_q[111:96];
                if (tx_rec_q[125:124] == 2'd1)
                  wb_q[ls_lane_q[2:0]][2] <=
                    {16'h0, tx_rec_q[143:128]};
              end
            endcase
            st_q <= W_TXN;
          end
          // ---- G3a-ii tails ------------------------------------------
          // W_TXG0/G1: gather UNORM channel normalize — t0 = i2f(ch16)
          // already landed; scale by 1/65535 then write result comp
          W_TXG0: begin
            txfa_q[0] <= 32'h3780_0080;   // 1/65535
            ncomp_q <= 4'd1;
            jset(0, 5'd2, {2'd0, S_T0}, {2'd1, S_TX},
                 {2'd0, S_ZERO}, 2, 0, W_TXG1);
          end
          W_TXG1: begin
            wb_q[ls_lane_q[2:0]][tx_gi_q[1:0]] <=
              t1_q[ls_lane_q[2:0]][0];
            tx_gi_q <= tx_gi_q + 4'd1;
            st_q <= (tx_gi_q + 4'd1 >= tx_gn_q) ? W_TXN : W_TXT0;
          end
          // W_TXQ0/Q1: OpImageQueryLod — comp0 = clamped λ (the q4.4
          // `le` of W_TXC2 additionally clamped to the mip range),
          // comp1 = the raw λ stashed in tx_qraw_q
          W_TXQ0: begin
            logic signed [11:0] lec;
            lec = $signed({3'b0, tx_lode_q});
            if (lec > 12'(tx_lvl_q - 5'd1) * 12'sd16)
              lec = 12'(tx_lvl_q - 5'd1) * 12'sd16;
            txfa_q[0] <= 32'(lec);        // int -> fp next
            ncomp_q <= 4'd1;
            jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                 {2'd0, S_TX}, 7'h0, 7'h0, 1, 0, W_TXQ1);
          end
          W_TXQ1: begin                  // λ_clamped = le * 2^-4
            txfa_q[0] <= 32'h3D80_0000;   // 0.0625f
            wb_q[ls_lane_q[2:0]][1] <= tx_qraw_q;
            wb_q[ls_lane_q[2:0]][2] <= 32'h0;
            wb_q[ls_lane_q[2:0]][3] <= 32'h0;
            ncomp_q <= 4'd1;
            jset(0, 5'd2, {2'd0, S_T0}, {2'd1, S_TX},
                 {2'd0, S_ZERO}, 0, 0, W_TXN);   // -> wb[0]
          end
          // post-resolve bounds check for the resource access
          W_LSC: begin
            if (!ls_bok_q || {32'h0, ls_off_q} + 4 > {32'h0, ls_bsz_q})
            begin
              robust_q <= robust_q + 1;
              if (!ls_store_q)
                wb_q[ls_lane_q[2:0]][ls_wc] <= '0;
              st_q <= W_LSA;
            end else begin
              ls_addr_q <= ls_bind_q + {32'h0, ls_off_q};
              st_q <= ls_atom_q ? W_ATR : W_LS1;
            end
          end
          // mem_re_o/mem_we_o hold until mem_ready_i; a masked-out
          // store lane issues nothing and skips the wait
          W_LS1: begin
            if (mem_re_o || mem_we_o) begin
              if (mem_ready_i) st_q <= W_LS2;
            end else st_q <= W_LSA;
          end
          // waits the one response (write B included); err returns
          // zero and counts as an out-of-range robust access
          W_LS2: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) robust_q <= robust_q + 1;
              // atomics latch the old word in W_ATC — the write
              // response carries no data, don't overwrite it
              if (!ls_store_q && !ls_atom_q)
                wb_q[ls_lane_q[2:0]][ls_wc] <=
                  mem_err_i ? 32'h0 :
                  ls_addr_q[2] ? mem_rdata_i[63:32]
                               : mem_rdata_i[31:0];
              st_q <= W_LSA;
            end
          end
          W_SSB: st_q <= W_SSB1;              // sb/sc issued
          W_SSB1: begin
            if (ls_sc_q == APU_SH_SC_WORKGROUP) begin
              if ((ls_off_q >> 2) >= SLW) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][ls_wc] <= '0;
              end else if (!ls_store_q) begin
                wb_q[ls_lane_q[2:0]][ls_wc] <= sb_rdata;
              end
            end else begin
              if ((ls_off_q >> 2) >= SCW ||
                  ls_off_q >= {16'h0, escratch_q}) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][ls_wc] <= '0;
              end else if (!ls_store_q) begin
                wb_q[ls_lane_q[2:0]][ls_wc] <= sc_rdata;
              end
            end
            st_q <= W_LSA;
          end
          W_LSA: begin
            if (!ls_mat_q) begin
              if (ls_comp_q + 1 < ncomp_q) begin
                ls_comp_q <= ls_comp_q + 1; st_q <= W_LS0;
              end else if (ls_lane_q + 1 < LAN) begin
                ls_comp_q <= '0; ls_lane_q <= ls_lane_q + 1;
                st_q <= W_LS0;
              end else begin
                ls_comp_q <= '0; ls_lane_q <= '0;
                st_q <= (ls_store_q && !ls_wbb_q) ? W_NEXT : W_WB;
              end
            end else begin
              // matrix access — (column, lane, comp) order: the RF row
              // for a column is complete when the last lane's last comp
              // of that column retires, and is flushed (load) or the
              // next column staged (store) at that boundary.
              ls_comp_q <= ls_comp_q + 1;
              if (lcc_q + 1 < ls_ccn) begin
                lcc_q <= lcc_q + 1; st_q <= W_LS0;
              end else if (ls_lane_q + 1 < LAN) begin
                lcc_q <= '0; ls_lane_q <= ls_lane_q + 1;
                st_q <= W_LS0;
              end else if (!ls_store_q) begin
                st_q <= W_MLF;          // flush column lrc_q row
              end else if (lrc_q + 1 >= ls_ccl) begin
                lcc_q <= '0; ls_lane_q <= '0; ls_comp_q <= '0;
                st_q <= W_NEXT;
              end else begin
                lcc_q <= '0; ls_lane_q <= '0; lrc_q <= lrc_q + 1;
                st_q <= (otag_q[1] == APU_SH_RT_CONST)
                        ? W_LS0 : W_SMR0;
              end
            end
          end
          // load matrix: flush the assembled column row into the RF
          W_MLF: begin
            lcc_q <= '0; ls_lane_q <= '0;
            if (lrc_q + 1 < ls_ccl) begin
              lrc_q <= lrc_q + 1; st_q <= W_LS0;
            end else begin
              lrc_q <= '0; ls_comp_q <= '0; st_q <= W_NEXT;
            end
          end
          // store matrix: stage operand column lrc_q into ma_q
          W_SMR0: st_q <= W_SMR1;       // rf read issued in port comb
          W_SMR1: begin
            ma_q <= rf_rdata;
            st_q <= W_LS0;
          end
          // ---------------- G3a-i: OpFunctionCall ---------------------
          // The func row packs {nparams[31:28], param-table base
          // [27:16], first-block word offset [15:0]}; param row p at
          // parm base+p holds {4'h0, value-rows[11:8], rf row[7:0]}.
          // Arg rows are copied into the param's registers; pointer
          // params copy verbatim (the pointer word is just data).
          W_FN0: begin                          // func row read issued
            fpk_q <= '0; st_q <= W_FN1;
          end
          W_FN1: begin
            frow_q <= func_data_i;
            wreg_q <= rm_idx[RI-1:0];           // call result RF row
            // result RF row count for the frame (mat=cols, struct=
            // ceil(size/16), else 1)
            resn_q <= (rkind_q == APU_SH_TK_MAT) ? 4'(rcols_q)
                    : (rkind_q == APU_SH_TK_STRUCT)
                      ? 4'((32'(rsz_q) + 15) >> 4) : 4'd1;
            if (func_data_i == '0 ||                 // undefined callee
                csp_q[wave_q] >= 5'(CLD)) begin      // stack overflow
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else st_q <= W_FN2;
          end
          // param loop: parm row + the argument's regmap row are read
          // together (W_FN2 drives parm_id_o and rm_id_o)
          W_FN2: begin
            res_id_q <= ops_q[3 + fpk_q][9:0];   // const-fetch id
            fkr_q <= '0;
            st_q <= (fpk_q >= frow_q[31:28]) ? W_FN6 : W_FN3;
          end
          W_FN3: begin                    // parm row + arg rm arrived
            fpr_q   <= parm_data_i;
            fatag_q <= rm_tag;
            faidx_q <= rm_idx[RI-1:0];
            st_q <= W_FN4;
          end
          W_FN4: st_q <= W_FN5;           // arg row read issued (port)
          W_FN5: begin                    // param row written (port)
            fkr_q <= fkr_q + 1;
            if ({1'b0, fkr_q} + 1 < {1'b0, fpr_q[11:8]})
              st_q <= W_FN4;
            else begin
              fpk_q <= fpk_q + 1; st_q <= W_FN2;
            end
          end
          // push the frame: return pc, result reg, caller label, the
          // lanes entering (cfln) and the done-with-callee mask (cfdn)
          W_FN6: begin
            cfret_q[wave_q][csp_q[wave_q][4:0]] <=
              pc_q[wave_q] + {6'h0, wc_q};
            cres_q[wave_q][csp_q[wave_q][4:0]]  <= wreg_q;
            cresn_q[wave_q][csp_q[wave_q][4:0]] <= resn_q;
            cclbl_q[wave_q][csp_q[wave_q][4:0]] <= clbl_q[wave_q];
            cfln_q[wave_q][csp_q[wave_q][4:0]]  <= act_w;
            cfdn_q[wave_q][csp_q[wave_q][4:0]]  <= '0;
            ccfn_q[wave_q][csp_q[wave_q][4:0]]  <= cfn_q[wave_q];
            csp_q[wave_q]  <= csp_q[wave_q] + 1;
            pc_q[wave_q]   <= frow_q[15:0];
            insns_q <= insns_q + 1;
            if (insns_q + 1 > ShaderBudget) begin
              done_code_q <= APU_SH_DONE_BUDGET;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else st_q <= W_SCHED;
          end
          // ---------------- G3a-i: OpReturnValue ---------------------
          // value-id rm row read (W_FR0), then per-row copy into the
          // frame's result register; W_FRC retires into the cf engine
          // which scrubs the returning lanes like a plain OpReturn
          W_FR0: begin
            res_id_q <= ops_q[0][9:0];
            fkr_q    <= '0;
            fpr_q    <= 16'(cres_q[wave_q][csp_q[wave_q] - 5'd1]);
            st_q <= W_FR1;
          end
          W_FR1: begin                    // value rm row arrived
            if (fkr_q == 0) begin
              fatag_q <= rm_tag;
              faidx_q <= rm_idx[RI-1:0];
            end
            st_q <= W_FRC;                // source read issued (port)
          end
          W_FRC: begin                    // result row written (port)
            fkr_q <= fkr_q + 1;
            if ({1'b0, fkr_q} + 1 <
                {1'b0, cresn_q[wave_q][csp_q[wave_q] - 5'd1]})
              st_q <= W_FR1;
            else st_q <= W_CF0;           // return bookkeeping path
          end
          // ----------------- G3a-i: SSBO atomic RMW -------------------
          // One lane's RMW at a time; the FSM cannot switch waves
          // outside W_SCHED so the read->write window is indivisible.
          W_ATR: begin                    // read issued (port)
            if (mem_ready_i) st_q <= W_ATC;
          end
          W_ATC: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q) wb_q[ls_lane_q[2:0]][0] <= '0;
                st_q <= W_LSA;
              end else begin
                at_old_q <= ls_addr_q[2] ? mem_rdata_i[63:32]
                                         : mem_rdata_i[31:0];
                at_new_q <= atomic_alu;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][0] <=
                    ls_addr_q[2] ? mem_rdata_i[63:32]
                                 : mem_rdata_i[31:0];
                // AtomicLoad is read-only — skip the RMW write
                st_q <= (at_op_q == 16'd227) ? W_LSA : W_ATW;
              end
            end
          end
          W_ATW: begin                    // RMW write issued (port)
            if (mem_ready_i) st_q <= W_LS2;      // write response wait
          end
          // workgroup/scratch atomic: slab read in W_ATS0, RMW write
          // + old-word capture in W_ATS1 (no response handshake)
          W_ATS0: st_q <= W_ATS1;
          W_ATS1: begin
            if ((ls_sc_q == APU_SH_SC_WORKGROUP &&
                 ls_off_q >= 32'(SlabBytes)) ||
                (ls_sc_q != APU_SH_SC_WORKGROUP &&
                 ((ls_off_q >> 2) >= SCW ||
                  ls_off_q >= {16'h0, escratch_q}))) begin
              robust_q <= robust_q + 1;
              if (!ls_store_q) wb_q[ls_lane_q[2:0]][0] <= '0;
            end else if (!ls_store_q)
              wb_q[ls_lane_q[2:0]][0] <=
                (ls_sc_q == APU_SH_SC_WORKGROUP) ? sb_rdata : sc_rdata;
            st_q <= W_LSA;
          end
          // ----------------- G3a-i: FS-out slot 8 tail ----------------
          // Every started lane writes flags/SampleMask/zero words of
          // the builtin-output slot (word0 FragDepth is written by the
          // shader's own record store).  f8d/f8b carry the pending
          // word; W_F8A/W_F8B alternate single-word writes.
          W_F8A, W_F8B: begin
            if (mem_ready_i) begin
              // write order word2 → word3 → word1: the flags word is
              // staged (below) at least one cycle after wave finish so
              // a kill that retires the wave's last lane in the same
              // edge still lands in dead_q before it is sampled.
              if (f8b_q == 5'd8) begin
                f8b_q <= 5'd12; f8d_q <= '0;
              end else if (f8b_q == 5'd12) begin
                f8b_q <= 5'd4;
                f8d_q <= {31'h0, dead_q[wave_q][f8l_q]};
              end else if (32'(wave_q) * LAN + {28'h0, f8l_q} + 1 >=
                           tot_q || f8l_q + 1 >= LAN) begin
                // word1 done and no more lanes → the wave retires
                wfin_q[wave_q] <= 1'b1;
                st_q <= W_SCHED;
              end else begin
                // word1 done — advance to the next lane's slot-8
                f8l_q <= f8l_q + 1;
                ls_addr_q <= out_base_q +
                  (32'(wave_q) * LAN + 32'(f8l_q) + 1) * gfx_ostr +
                  32'(APU_SH_FSOUT_BI * 16);
                f8b_q <= 5'd8;
                f8d_q <= 32'hFFFF_FFFF;
              end
              if (!(f8b_q == 5'd4 &&
                    (32'(wave_q) * LAN + {28'h0, f8l_q} + 1 >= tot_q ||
                     f8l_q + 1 >= LAN)))
                st_q <= (st_q == W_F8A) ? W_F8B : W_F8A;
            end
          end
          // ---------------- G3a-i: Determinant/MatrixInverse ---------
          // Operand matrix columns stage into dtm_q (flat element id
          // c*4+r — column-major matches the RF row-per-column layout
          // and the const flat layout), then DM_PROG runs as scalar
          // per-lane fp jobs through the shared units.
          W_DM0: begin
            if (dmph_q) begin                // flush: dres col → wb
              wb_q <= dres_q[dmcol_q];
              st_q <= W_DMF;
            end else st_q <= W_DM1;          // operand col read issued
          end
          W_DM1: begin                       // stage column dmcol
            for (int l = 0; l < LAN; l++)
              for (int r = 0; r < 4; r++)
                if (r < ot_comps_q)
                  dtm_q[dmcol_q[1:0]][l][r[1:0]] <=
                    (otag_q[0] == APU_SH_RT_CONST)
                      ? ocst_q[0][32 * ({26'h0, dmcol_q} *
                                        {2'b0, ot_comps_q} + r) +: 32]
                      : rf_rdata[l*128 + r*32 +: 32];
            if (dmcol_q + 1 < ot_cols_q) begin
              dmcol_q <= dmcol_q + 1; st_q <= W_DM0;
            end else begin
              dmcol_q <= '0; st_q <= W_DMS;
            end
          end
          // micro-program step issue; HALT retires (det → wb via the
          // program's MOV; inverse → flush phase)
          W_DMS: begin
            if (dm_op == 5'd0) begin         // HALT
              dmph_q <= 1'b1;
              if (xnum_q == 33) st_q <= W_WB;
              else begin dmcol_q <= '0; st_q <= W_DM0; end
            end else begin
              ncomp_q <= 5'd1;               // scalar jobs, comp 0
              // temps/elems carry their bank comp in the dest id —
              // jstore's comp arg would be the scalar-loop tc_q (0),
              // so route it through the jucc/ccc override.
              ccc_q <= dm_dd[1:0];
              jset((dm_op == 5'd7) ? 2'd1 : 2'd0,
                   dm_xo,
                   dm_sa_w, dm_sb_w, dm_sc_w,
                   dm_jdst, 1'b0, W_DMN, 1'b1, 1'b0,
                   dm_ci(dm_sa),
                   dm_ci((dm_op == 5'd8) ? dm_sa : dm_sb),
                   dm_ci(dm_sc),
                   dm_neg, dm_jdtx);
            end
          end
          W_DMN: begin
            dmp_q <= dmp_q + 1; st_q <= W_DMS;
          end
          W_DMF: begin                       // result column written
            if (dmcol_q + 1 < rcols_q) begin
              dmcol_q <= dmcol_q + 1; st_q <= W_DM0;
            end else st_q <= W_NEXT;
          end
          W_WB2: st_q <= W_NEXT;            // second row written (port)
          W_WB: begin
            st_q <= wb2_q ? W_WB2 : W_NEXT;
          end
          // ---------------------------------------------------- φ ----
          // OpPhi: pick the pair whose parent == cprev (§7c).  The phi
          // table row is {count, {parent,value}*} packed by shmod.
          W_PH0: begin
            phr_q <= phi_data_i;                 // row for ops_q[1]
            pi_q <= '0; phhit_q <= '0;
            wb_q <= '0;
            wbm_q <= 4'((4'b1 << ncomp_q) - 1);
            st_q <= W_PH1;                       // result rm read issued
          end
          W_PH1: begin
            if (pi_q == 0) wreg_q <= rm_idx[RI-1:0];
            if (pi_q >= ph_npi[2:0]) begin
              // no parent matched → the first pair's value is the
              // model's fallback (t2 stashed at pair 0)
              for (int l = 0; l < LAN; l++)
                for (int c = 0; c < VEC; c++)
                  if (act_w[l] && !phhit_q[l] && c < ncomp_q)
                    wb_q[l][c] <= t2_q[l][c];
              st_q <= W_WB;
            end else st_q <= W_PH2;              // pair rm read issued
          end
          W_PH2: begin                           // pair rm row arrived
            phtag_q <= rm_tag;
            phidx_q <= rm_idx[RI-1:0];
            phaux_q <= rm_aux;
            phm_q <= '0;
            for (int l = 0; l < LAN; l++)
              if (act_w[l] && !phhit_q[l] &&
                  cprev_q[wave_q][l] == php_c[9:0])
                phm_q[l] <= 1'b1;
            st_q <= W_PH3;                       // rf/const read issued
          end
          W_PH3: begin
            for (int l = 0; l < LAN; l++) begin
              for (int c = 0; c < VEC; c++) begin
                if (phm_q[l] && c < ncomp_q)
                  wb_q[l][c] <=
                    (phtag_q == APU_SH_RT_CONST)
                    ? const_data_i[32 *
                                   ((c < phaux_q) ? c : 0) +: 32]
                    : rf_rdata[l*128 + c*32 +: 32];
                // pair 0's value is the no-match fallback
                if (pi_q == 0 && act_w[l])
                  t2_q[l][c] <=
                    (phtag_q == APU_SH_RT_CONST)
                    ? const_data_i[32 *
                                   ((c < phaux_q) ? c : 0) +: 32]
                    : rf_rdata[l*128 + c*32 +: 32];
              end
              if (phm_q[l]) phhit_q[l] <= 1'b1;
            end
            pi_q <= pi_q + 1;
            st_q <= W_PH1;
          end
          // ---------------------------------------------------- CF ----
          // control-flow retire: commit the engine's next-state; the
          // block table read for a taken jump is issued combinationally
          // (blk_id_o = cf_jmp) and lands here next cycle.
          W_CF0: begin
            cmask_q[wave_q] <= cf_nact;
            cfn_q[wave_q]   <= cf_nn;
            for (int e = 0; e < CFD; e++) begin
              cfk_q[wave_q][e] <= cf_nk[e];
              cfm_q[wave_q][e] <= cf_nm[e];
              cfc_q[wave_q][e] <= cf_nc[e];
              cfr_q[wave_q][e] <= cf_nr[e];
              cfp_q[wave_q][e] <= cf_np[e];
              cfx_q[wave_q][e] <= cf_nx[e];
            end
            if (opc_q == 16'd247) begin          // arm the merge
              wsel_q[wave_q]  <= 1'b1;
              wselm_q[wave_q] <= ops_q[0][9:0];
            end
            if (opc_q == 16'd248)                // block label arrives
              clbl_q[wave_q] <= ops_q[0][9:0];
            if (opc_q == 16'd252 || opc_q == 16'd4416)
              // Kill / TerminateInvocation: the leaving lanes are dead —
              // registers still feed quad derivatives, all side
              // effects suppressed (stores, atomics, image writes,
              // FS-out colour/depth — via the slot-8 discard flag)
              dead_q[wave_q] <= dead_q[wave_q] | act_w;
            if (opc_q == 16'd249 || opc_q == 16'd250 ||
                opc_q == 16'd251) begin
              wsel_q[wave_q] <= 1'b0;
              for (int l = 0; l < LAN; l++)
                if (act_w[l]) begin
                  cprev_q[wave_q][l] <= clbl_q[wave_q];
                  ctgt_q[wave_q][l]  <= ctg_w[l];
                end
            end
            if (cf_flt) begin
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q[wave_q];
              fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else if (cf_ret) begin
              // callee drained — pop the top frame and resume the
              // lanes that took the call at the return pc; their
              // previous-block label is the block that held the call
              insns_q <= insns_q + 1;
              csp_q[wave_q]  <= csp_q[wave_q] - 5'd1;
              cmask_q[wave_q] <=
                cfln_q[wave_q][csp_q[wave_q] - 5'd1] &
                ~dead_q[wave_q];
              pc_q[wave_q]   <= cfret_q[wave_q][csp_q[wave_q] - 5'd1];
              clbl_q[wave_q] <= cclbl_q[wave_q][csp_q[wave_q] - 5'd1];
              for (int l = 0; l < LAN; l++)
                if (cfln_q[wave_q][csp_q[wave_q] - 5'd1][l] &&
                    !dead_q[wave_q][l])
                  cprev_q[wave_q][l] <=
                    cclbl_q[wave_q][csp_q[wave_q] - 5'd1];
              if ((cfln_q[wave_q][csp_q[wave_q] - 5'd1] &
                   ~dead_q[wave_q]) == '0) begin
                // every lane that entered the callee died inside it —
                // the pop above is committed (mask = 0) and W_CF0 is
                // re-entered so cf_eng continues the unwind below the
                // new floor, exactly like an OpReturn with an empty
                // mask: parked caller entries resume first, a deeper
                // drain pops the next frame, and cf_fin — the only
                // place the F8 tail / wfin may start — fires solely at
                // depth 0 with nothing parked.
                st_q <= W_CF0;
              end else if (insns_q + 1 > ShaderBudget) begin
                done_code_q <= APU_SH_DONE_BUDGET;
                fl_pc_q <= pc_q[wave_q];
                fl_wave_q <= {8'h0, wave_q};
                st_q <= W_DONE;
              end else st_q <= W_SCHED;
            end else if (cf_fin) begin
              insns_q <= insns_q + 1;
              if (gfx_q == APU_SH_GFX_FS && fslate_q &&
                  32'(wave_q) * LAN < tot_q) begin
                // FS wave end: write the per-lane builtin-output slot
                // (flags word1 / SampleMask word2 / word3=0; word0 is
                // the shader's own FragDepth record store)
                f8l_q <= '0;
                ls_addr_q <= out_base_q +
                  32'(wave_q) * LAN * gfx_ostr +
                  32'(APU_SH_FSOUT_BI * 16);
                f8b_q <= 5'd8;
                f8d_q <= 32'hFFFF_FFFF;
                st_q <= W_F8A;
              end else begin
                wfin_q[wave_q] <= 1'b1;
                st_q <= W_SCHED;
              end
            end else if (cf_jok) begin
              insns_q <= insns_q + 1;
              st_q <= W_CF1;
            end else begin                       // cf_adv: retire
              insns_q <= insns_q + 1;
              pc_q[wave_q] <= pc_q[wave_q] + wc_q;
              if (insns_q + 1 > ShaderBudget) begin
                done_code_q <= APU_SH_DONE_BUDGET;
                fl_pc_q <= pc_q[wave_q];
                fl_wave_q <= {8'h0, wave_q};
                st_q <= W_DONE;
              end else st_q <= W_SCHED;
            end
          end
          W_CF1: begin                           // jump target resolved
            if (!blk_ok) begin
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q[wave_q];
              fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else begin
              pc_q[wave_q] <= {1'b0, blk_pc};
              st_q <= W_SCHED;
            end
          end
          // ------------------------------------------- matrix ops ----
          // operand shape reads: W_MS0 issues the operand-0 type read,
          // W_MS1 latches it and issues operand-1's; W_MS2 dispatches
          // the per-column micro-sequence; W_MSQ is the step/join state.
          W_MS0: st_q <= W_MS1;
          W_MS1: begin
            // operand0 shape: cols / comps-per-column
            mac_q  <= (ty_kind == APU_SH_TK_MAT ||
                       ty_kind == APU_SH_TK_VEC) ? f_nc(ty_comps)
                                                : 3'd1;
            macl_q <= (ty_kind == APU_SH_TK_MAT) ? ty_cols : 3'd1;
            st_q <= W_MS2;
          end
          W_MS2: begin
            // operand1 shape (row in hand only when nva>1).  ty_* only
            // carries operand1's type on the FIRST visit (issued by
            // W_MS1); on W_MWB re-entries ty_w is '0 so ty_* decodes
            // row 0 — gate every ty-derived latch on mi_q==0.
            if (mi_q == 3'd0) begin
              mbc_q  <= (nva_q > 1 && (ty_kind == APU_SH_TK_MAT ||
                         ty_kind == APU_SH_TK_VEC)) ? f_nc(ty_comps)
                                                   : 3'd1;
              mbcl_q <= (nva_q > 1 && ty_kind == APU_SH_TK_MAT)
                        ? ty_cols : 3'd1;
            end
            unique case (opc_q)
              84: begin                          // Transpose
                mrr_q <= macl_q;                 // result col comps
                mrc_q <= mac_q;                  // result columns
                mk_q  <= '0;
                mfetch(0, 3'd0, 1'b0, mac_q, W_MSQ);
                mph_q <= 1;
              end
              143: begin                         // MatrixTimesScalar
                mrr_q <= mac_q; mrc_q <= macl_q;
                mfetch(0, mi_q, 1'b0, mac_q, W_MSQ);
                mph_q <= 1;
              end
              144: begin                         // VectorTimesMatrix
                mkd_q <= (nva_q > 1 &&
                          ty_kind == APU_SH_TK_MAT) ? f_nc(ty_comps)
                                                  : 3'd1;
                mrc_q <= (nva_q > 1 &&
                          ty_kind == APU_SH_TK_MAT) ? ty_cols : 3'd1;
                mfetch(1, mi_q, 1'b1, 3'(f_nc(ty_comps)), W_MSQ);
                mph_q <= 1;
              end
              145: begin                         // MatrixTimesVector
                mrr_q <= mac_q; mkd_q <= macl_q;
                mk_q  <= macl_q - 3'd1;
                mfetch(0, macl_q - 3'd1, 1'b0, mac_q, W_MSQ);
                mph_q <= 1;
              end
              146: begin                         // MatrixTimesMatrix
                mrr_q <= mac_q;
                if (mi_q == 3'd0) begin
                  mrc_q <= (ty_kind == APU_SH_TK_MAT) ? ty_cols : 3'd1;
                  mkd_q <= macl_q;
                end
                // B column length == K == A's column count (macl_q),
                // which is what a const operand's flat base strides by
                mfetch(1, mi_q, 1'b1, macl_q, W_MSQ);
                mph_q <= 5;
              end
              default: begin                     // 147 OuterProduct
                mrr_q <= mac_q;
                if (mi_q == 3'd0)
                  mrc_q <= (nva_q > 1 &&
                            (ty_kind == APU_SH_TK_MAT ||
                             ty_kind == APU_SH_TK_VEC))
                           ? f_nc(ty_comps) : 3'd1;
                ncomp_q <= 5'(mac_q);
                jset(0, 5'd2, {2'd0, S_V0}, {2'd3, S_V1},
                     {2'd0, S_ZERO}, 0, 0, W_MWB, 1'b0, 1'b0,
                     2'd0, mi_q[1:0]);
              end
            endcase
          end
          W_MSQ: begin
            unique case (opc_q)
              84: begin                          // wb[k] = col_k[mi]
                for (int l = 0; l < LAN; l++)
                  if (act_w[l]) wb_q[l][mk_q] <= ma_q[l][mi_q];
                if (mk_q + 1 < macl_q) begin
                  mk_q <= mk_q + 1;
                  mfetch(0, mk_q + 3'd1, 1'b0, mac_q, W_MSQ);
                end else st_q <= W_MWB;
              end
              143: begin                         // wb = col * scalar
                ncomp_q <= 5'(mrr_q);
                jset(0, 5'd2, {2'd0, S_MA}, {2'd1, S_V1},
                     {2'd0, S_ZERO}, 0, 0, W_MWB);
              end
              144: unique case (mph_q)           // dot(v, col_mi)
                1: begin
                  ncomp_q <= 5'(mkd_q); mph_q <= 2;
                  jset(0, 5'd2, {2'd0, S_V0}, {2'd0, S_MB},
                       {2'd0, S_ZERO}, 2, 0, W_MSQ);
                end
                2: begin
                  ncomp_q <= 5'(mkd_q); mph_q <= 3;
                  jset(0, 5'd3, {2'd2, S_T1}, {2'd0, S_ONE},
                       {2'd0, S_T0}, 1, 1, W_MSQ, 1'b0, 1'b1);
                end
                default: begin
                  for (int l = 0; l < LAN; l++)
                    if (act_w[l]) wb_q[l][mi_q] <= t0_q[l][0];
                  if (mi_q + 1 < mrc_q) begin
                    mi_q <= mi_q + 1; mph_q <= 1;
                    mfetch(1, mi_q + 3'd1, 1'b1, mbc_q, W_MSQ);
                  end else st_q <= W_WB;
                end
              endcase
              145,146: unique case (mph_q)
                5: begin                         // B col staged
                  mk_q <= mkd_q - 3'd1;
                  mfetch(0, mkd_q - 3'd1, 1'b0, mac_q, W_MSQ);
                  mph_q <= 1;
                end
                1: begin                         // product col_k * s_k
                  ncomp_q <= 5'(mrr_q);
                  mph_q <= (mk_q == mkd_q - 3'd1) ? 3'd2 : 3'd3;
                  jset(0, 5'd2, {2'd0, S_MA},
                       {2'd3, (opc_q == 146) ? S_MB : S_V1},
                       {2'd0, S_ZERO},
                       (mk_q == mkd_q - 3'd1) ? 3'd1 : 3'd2,
                       0, W_MSQ, 1'b0, 1'b0, 2'd0, mk_q[1:0]);
                end
                2, 4: begin                      // acc updated / seeded
                  if (mk_q == 0) begin
                    for (int l = 0; l < LAN; l++)
                      for (int c = 0; c < VEC; c++)
                        if (act_w[l]) wb_q[l][c] <= t0_q[l][c];
                    st_q <= (opc_q == 146) ? W_MWB : W_WB;
                  end else begin
                    mk_q <= mk_q - 3'd1;
                    mfetch(0, mk_q - 3'd1, 1'b0, mac_q, W_MSQ);
                    mph_q <= 1;
                  end
                end
                default: begin                   // acc += product
                  mph_q <= 4;
                  jset(0, 5'd0, {2'd0, S_ZERO}, {2'd0, S_T1},
                       {2'd0, S_T0}, 1, 0, W_MSQ);
                end
              endcase
              default: st_q <= W_NEXT;
            endcase
          end
          // matrix operand column fetch: W_MRD0 issues the RF read for
          // register operands; W_MRD1 stages the column into ma/mb
          // (constants slice the latched const row — mrd_q is then the
          // flat word base).
          W_MRD0: st_q <= W_MRD1;
          W_MRD1: begin
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++) begin
                if (!mdst_q)
                  ma_q[l][c] <=
                    (otag_q[mrds_q] == APU_SH_RT_CONST)
                    ? ocst_q[mrds_q][32 * ({26'h0, mrd_q} +
                                           c) +: 32]
                    : rf_rdata[l*128 + c*32 +: 32];
                else
                  mb_q[l][c] <=
                    (otag_q[mrds_q] == APU_SH_RT_CONST)
                    ? ocst_q[mrds_q][32 * ({26'h0, mrd_q} +
                                           c) +: 32]
                    : rf_rdata[l*128 + c*32 +: 32];
              end
            st_q <= mret_q;
          end
          // matrix composite-extract: W_XC0 read the operand's column
          // row; latch the element ([col][comp]) or the whole column
          W_XC0: st_q <= W_XC1;
          W_XC1: begin
            if (wc_q > 4)
              for (int l = 0; l < LAN; l++)
                wb_q[l][0] <=
                  rf_rdata[l*128 + ops_q[4][1:0]*32 +: 32];
            else
              wb_q <= rf_rdata;
            st_q <= W_WB;
          end
          // matrix result column writeback (rf write in the port comb)
          W_MWB: begin
            if (mi_q + 1 < mrc_q) begin
              mi_q <= mi_q + 1; st_q <= W_MS2;
            end else st_q <= W_NEXT;
          end
          // ---- composite construct of a MAT result: flat cols-major
          // stream of the constituents into per-column RF rows --------
          W_CM0: begin
            if (vk_q >= {3'b0, nva_q}) begin
              st_q <= (ccp_q != 0) ? W_CMF : W_NEXT;
            end else st_q <= W_CM1;              // operand ty read out
          end
          W_CM1: begin
            moc_q  <= f_nc(ty_comps);            // operand col comps
            mocl_q <= (ty_kind == APU_SH_TK_MAT) ? ty_cols : 3'd1;
            cmj_q <= '0; cmc_q <= '0;
            st_q <= W_CM5;
          end
          W_CM5: st_q <= W_CM2;                  // col rf read issued
          W_CM2: begin                           // stage operand column
            for (int l = 0; l < LAN; l++)
              for (int c = 0; c < VEC; c++)
                ma_q[l][c] <=
                  (otag_q[vk_q[1:0]] == APU_SH_RT_CONST)
                  ? ocst_q[vk_q[1:0]]
                        [32 * (cmj_q * moc_q + c) +: 32]
                  : rf_rdata[l*128 + c*32 +: 32];
            st_q <= W_CM3;
          end
          W_CM3: begin                           // emit one flat word
            for (int l = 0; l < LAN; l++)
              wb_q[l][ccp_q[1:0]] <= ma_q[l][cmc_q];
            if (ccp_q + 1 >= 3'(f_nc(rcomps_q))) st_q <= W_CMW;
            else begin ccp_q <= ccp_q + 1; st_q <= W_CM4; end
          end
          W_CMW: begin                           // full column flushed
            ccr_q <= ccr_q + 1; ccp_q <= '0; st_q <= W_CM4;
          end
          W_CM4: begin                           // advance source word
            if (cmc_q + 1 < moc_q) begin
              cmc_q <= cmc_q + 1; st_q <= W_CM3;
            end else begin
              cmc_q <= '0;
              if (cmj_q + 1 < mocl_q) begin
                cmj_q <= cmj_q + 1; st_q <= W_CM5;
              end else begin
                vk_q <= vk_q + 1; st_q <= W_CM0;
              end
            end
          end
          W_CMF: st_q <= W_NEXT;                 // partial col flushed
          // ------------------------------------------- scheduler -----
          // §7c round-robin at instruction granularity: the next
          // runnable wave after wave_q wins; a wave parked at
          // OpControlBarrier is skipped until every live wave of the
          // workgroup has arrived (finished waves count as arrived).
          W_SCHED: begin
            int pick, first, w;
            logic any_live;
            pick = -1; first = -1; any_live = 1'b0;
            for (int i = 1; i <= MaxWaves; i++) begin
              w = (32'(wave_q) + i) % MaxWaves;
              if (pick < 0 && w < 32'(nwaves_q) &&
                  !wfin_q[w] && !wbar_q[w])
                pick = w;
            end
            for (w = 0; w < MaxWaves; w++)
              if (w < 32'(nwaves_q) && !wfin_q[w]) begin
                any_live = 1'b1;
                if (first < 0) first = w;
              end
            if (pick >= 0) begin
              if (pick != 32'(wave_q)) wsw_q <= wsw_q + 1;
              wave_q <= RL'(pick); st_q <= W_F0;
            end else if (!any_live) begin
              st_q <= W_EOW;
            end else begin
              // every live wave is parked at the barrier → release
              // them together; the lowest lane continues first.
              wbar_q <= '0;
              if (first != 32'(wave_q)) wsw_q <= wsw_q + 1;
              wave_q <= RL'(first); st_q <= W_F0;
            end
          end
          W_WG0: begin                           // workgroup start
            wfin_q <= '0; wbar_q <= '0;
            wave_q <= '0; init_i_q <= '0;
            st_q <= W_IW0;
          end
          W_NEXT: begin
            pc_q[wave_q] <= pc_q[wave_q] + wc_q;
            insns_q <= insns_q + 1;
            xq_q <= '0;      // ExtInst step counter is per instruction
            xsub_q <= '0; xcall_q <= '0;   // §7d SFU seq is per instr
            if (insns_q + 1 > ShaderBudget) begin
              done_code_q <= APU_SH_DONE_BUDGET;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else st_q <= W_SCHED;
          end
          W_EOW: begin
            // all waves of the workgroup finished → next workgroup
            if (wgx_q + 1 < gx_q) begin
              wgx_q <= wgx_q + 1; st_q <= W_WG0;
            end else if (wgy_q + 1 < gy_q) begin
              wgx_q <= '0; wgy_q <= wgy_q + 1; st_q <= W_WG0;
            end else if (wgz_q + 1 < gz_q) begin
              wgx_q <= '0; wgy_q <= '0; wgz_q <= wgz_q + 1;
              st_q <= W_WG0;
            end else begin
              done_code_q <= APU_SH_DONE_OK;
              fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end
          end
          W_DONE: begin
            done_o <= 1'b1;
            tx_1lane_q <= 1'b0;
            st_q <= W_IDLE;
          end
          default: begin
            done_code_q <= APU_SH_DONE_FAULT;
            fl_pc_q <= pc_q[wave_q]; fl_wave_q <= {8'h0, wave_q};
            st_q <= W_DONE;
          end
        endcase
      end
    end
  end
endmodule

// Thin fixture for the yosys Enable=0/1 screens (generic flow).
module g6lc_apu_shwave_fixture
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderLanes   = 8,
  parameter int unsigned ShaderVec     = 4,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000,
  parameter int unsigned WaitBound     = 32'd4096,
  parameter int unsigned CallDepth     = 8
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  input  logic         disp_i,
  input  apu_sh_dispatch_t disp_pl_i,
  input  apu_sh_desc_t desc_i,
  input  logic [5:0]   push_n_i,
  input  logic [1023:0] push_i,
  output logic         busy_o,
  output logic         done_o,
  output apu_sh_done_t done_pl_o,
  output logic [2:0]   rd_slot_o,
  output logic [15:0]  prog_addr_o,
  input  logic [31:0]  prog_data_i,
  output logic [9:0]   type_id_o,
  input  logic [95:0]  type_data_i,
  output logic [9:0]   const_id_o,
  input  logic [511:0] const_data_i,
  output logic [9:0]   memb_id_o,
  input  logic [63:0]  memb_data_i,
  output logic [9:0]   rm_id_o,
  input  logic [31:0]  rm_data_i,
  output logic [9:0]   init_id_o,
  input  logic [63:0]  init_data_i,
  output logic [9:0]   blk_id_o,
  input  logic [31:0]  blk_data_i,
  output logic [9:0]   phi_id_o,
  input  logic [159:0] phi_data_i,
  output logic [9:0]   func_id_o,
  input  logic [31:0]  func_data_i,
  output logic [9:0]   parm_id_o,
  input  logic [15:0]  parm_data_i,
  input  logic [127:0] entry_data_i,
  output logic         mem_re_o,
  output logic         mem_we_o,
  output logic [63:0]  mem_addr_o,
  output logic [63:0]  mem_wdata_o,
  output logic [7:0]   mem_wstrb_o,
  input  logic         mem_ready_i,
  input  logic         mem_rvalid_i,
  input  logic [63:0]  mem_rdata_i,
  input  logic         mem_err_i,
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i
);
  g6lc_apu_shwave #(.Enable(Enable), .ShaderLanes(ShaderLanes),
      .ShaderVec(ShaderVec), .ShaderRegs(ShaderRegs),
      .MaxWaves(MaxWaves), .ShaderIds(ShaderIds),
      .ShaderSlots(ShaderSlots), .ShaderWords(ShaderWords),
      .ShaderInit(ShaderInit), .ShaderMembers(ShaderMembers),
      .ScratchBytes(ScratchBytes), .SlabBytes(SlabBytes),
      .ShaderBudget(ShaderBudget), .WaitBound(WaitBound),
      .CallDepth(CallDepth)
    ) i_dut (.*);
endmodule
