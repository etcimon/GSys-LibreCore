// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Raster engine (G2a): CLEAR fills one attachment per work item —
// color attachment 0 by default, or the depth attachment `da` when
// da_valid is set (D32_SFLOAT raw f32 words, D16_UNORM packed u16);
// DRAW runs the vertex→raster→fragment chain.  Attribute gather
// reads the vertex buffers into VS input records
// (APU_SH_ATTR_STRIDE, 9 slots — slot 8 carries
// {VertexIndex, InstanceIndex, 0, 0}) honoring per-binding
// inputRate (instance-rate attributes are indexed by the absolute
// instance index), issues an APU_SH_WORK_VS batch per ≤
// APU_RAST_VS_BATCH vertices on the ShaderCore work port, then
// scan-converts each primitive against the VS output records: a
// clip-space Sutherland–Hodgman clipper cuts each primitive against
// the six frustum planes (w≤0 vertices are regenerated, not
// dropped), NDC+viewport transform to 16.8 fixed point,
// signed-area cull/front-face handling, a scissor-clamped bounding
// box, and a top-left-rule point sample at each pixel center.
// Triangle list/strip/fan topologies; indexed
// draws fetch UINT16/UINT32 indices (OOB → index 0 + robust) and
// gl_VertexIndex = index + vertexOffset.  With a depth attachment,
// early-Z tests (and optionally writes) the interpolated z before
// the fragment enters the FS batch — unless the FS module flags
// fs_late (writes FragDepth or contains kill/demote), in which
// case the depth test+write moves to the ROP and sources z from
// FS-out record slot 8 (APU_SH_FSOUT_BI: word0 FragDepth when the
// module declares builtin 22, else the interpolated z; word1 bit0
// is the shader discard flag, which suppresses colour AND depth
// writes).  Fragments accumulate into FS
// input records (FragCoord at slot 0, the fs_in_mask locations
// perspective-corrected) and flush in APU_SH_WORK_FS batches of ≤
// APU_RAST_FS_BATCH; the ROP then processes every valid color
// attachment (FS-out location l → ca[l]): per-attachment blending
// in f32 on the fpnew units (dst read-back, VkBlendFactor/Op on
// color and alpha, blendConstants from the draw record), encode to
// R8G8B8A8/B8G8R8A8_UNORM or _SRGB (12-bit linear → 8-bit sRGB via
// APU_SRGB_ENC, alpha stays linear), and byte strobes per
// colorWriteMask.
//
// The scratch rings (vs_in/vs_out/fs_in/fs_out, in the pkg's fixed
// order, each 64 B aligned) are carved once from the device-private
// arena through one lazy vgpages ALLOC_PRIV of
// APU_RAST_SCRATCH_BYTES at the first work record and never freed.
//
// Datapath: exactly one each of fpnew_fma (FP32), the E906
// correctly-rounding fpnew_divsqrt_th_32, and fpnew_cast_multi.
// The per-fragment chain (S_F_LE0) and the per-location varying
// chain (S_F_V0) issue one job per cycle on the shared units —
// operands latch in fp_*_q while the unit computes the previous
// job and its result is captured the following cycle.  Other float
// work still uses the t_fpgo()/S_FPW request-return path: fp_iss_q
// is held until the targeted unit's in_ready, out_valid is a single-
// cycle pulse, and the return state captures fp_res_q at its ENTRY.
// (S_FPS stays in the enum but is no longer visited.)
// Integer edge/area math is
// plain 64-bit logic.  The big tables are flops in v1: the
// 3-vertex × 8-location × vec4 varying cache (3 KiBit), the
// 64-entry fs_xy fragment table, and the 24-byte gather window —
// first pixel, not throughput.
//
// Timing/area note: the FSM is a slow micro-sequencer (one memory
// word in flight); the only wide combinational cone is the three
// 64-bit edge multiplies in the scan state.  All float operands are
// still registered before the unit and all results registered after
// it — interleaving adds no new combinational path.  FMA and
// converter jobs are flop → unit → flop in a single cycle with no
// unit input register; the divider keeps its register (its accepted
// operands live in that register, so the chains may reuse fp_a_q/
// fp_b_q once dq_ir shows acceptance).  The flop tables above
// dominate the area (~5 KiBit).
//
// RP4 write-behind queue: the eleven record-write states (clear
// beats, vs_in attribute + slot-8 writes, depth/stencil, fs_in slot0
// + varying writes, ROP pixel writes) no longer park in S_MPW for
// their own response.  Each pushes {addr,data,strb} into a two-entry
// flop FIFO (wq_*) and advances; the port mux serves the FIFO head
// first — still exactly one outstanding request — and pops it on the
// response.  S_MPW keeps serving the unconverted reads and is gated
// on an empty queue, so the accepted-request order (and therefore
// every (addr,data,strb,we) the port sees) is identical to the
// pre-RP4 sequence, only issued back-to-back instead of one state
// round-trip apart.  Wave launch (S_VS_ISS/S_FLUSH) and done
// (S_FIN_OK/S_FIN_BAD) hold while any entry is valid, so the shader
// core never starts on unresponded writes and done is never reported
// with a write pending.
//
// Timing impact: the queue is flops only (~2 x 136 bits + 3 state
// bits); the port mux adds one 2:1 select in front of mp_req_o and
// mp_req_valid_o.  There is no new combinational path from the port
// response into the datapath beyond wq_pop -> wq_ok -> the issuing
// state's hold enable; push addresses/data are the same flop-sourced
// expressions the old mp_*_q registers captured.
//
// Review checklist: always_ff/always_comb split, async active-low
// reset, no latches, Enable=0 constant-zero netlist, queue entries
// flops only (no SRAM), FIFO order preserved, one outstanding
// request, drain before wave launch / done.
//
// Known limits: stencil is the D24S8 high byte (front ops only).
// Point list is one pixel at the vertex.
// Line list/strip are 1 px Bresenham, flat colour from the first
// vertex, no line clip or width. Strips and fans must fit one
// vertex batch, subpass color reference l → attachment l
// (identity), no MSAA, single viewport.
// depthClampEnable clamps window z to the viewport and skips
// near/far clipping.
// Constant depth bias is applied (r = 1 for D32, 2^-16 for D16),
// then slopeFactor times the triangle's max edge |dz|/span, then
// depthBiasClamp. Lines and points have slope 0.
// area/edge values are shifted into int32 for the float λ path (the
// exact inside test stays 64-bit), scissor offsets are unsigned.
module g6lc_apu_rast
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_srgb_pkg::*;
#(
  parameter bit Enable = 1'b0,
  // draw-path counters (W1.5; also the source for primitives-generated
  // and pipeline-statistics queries).  0 = no cells.
  parameter bit PerfCountersEn = 1'b0,
  // FP0: per-stage busy-cycle classes (bench-read; 0 = no cells)
  parameter bit PerfClassEn = 1'b0,
  // TP5 vertex reuse: post-transform cache entries; 0 = reuse off
  parameter int unsigned VtxCacheEntries = 0
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  // cmdexec work-port record + draw sideband (rd_i/desc_i/push_*
  // valid with work_valid_i; rd_i is the resolved draw record)
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_rast_draw_t    rd_i,
  input  apu_sh_desc_t      desc_i,
  input  logic [5:0]        push_n_i,
  input  logic [1023:0]     push_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  // ShaderCore work port (VS/FS wave batches; desc/push are the
  // latched draw-accept copies replayed with every wave)
  output logic              sh_work_valid_o,
  input  logic              sh_work_ready_i,
  output logic [31:0]       sh_ctype_o,
  output logic [7:0][31:0]  sh_imm_o,
  output logic [2:0]        sh_slot_o,
  output apu_sh_desc_t      sh_desc_o,
  output logic [5:0]        sh_push_n_o,
  output logic [1023:0]     sh_push_o,
  input  logic              sh_done_i,
  input  apu_sh_done_t      sh_done_pl_i,
  // shared aperture memory port (dom=1, single outstanding)
  output logic              mp_req_valid_o,
  input  logic              mp_req_ready_i,
  output apu_mp_req_t       mp_req_o,
  input  logic              mp_rsp_valid_i,
  input  apu_mp_rsp_t       mp_rsp_i,
  // vgpages requester (lazy one-time ALLOC_PRIV of the scratch rings)
  output logic              pg_req_valid_o,
  input  logic              pg_req_ready_i,
  output apu_vgpages_req_t  pg_req_o,
  input  logic              pg_cpl_valid_i,
  output logic              pg_cpl_ready_o,
  input  apu_vgpages_cpl_t  pg_cpl_i,
  output logic              busy_o,
  // {pixel writes, triangles assembled (before culling), busy cycles}
  // since reset
  output logic [3*32-1:0]   stat_o,
  // §3a query-statistics bus {fs_invocations, occlusion_samples,
  //   ia_primitives, ia_vertices} — the four draw-stage counters the
  //   bounded statistics mask 0x87 reads (VS-invocations reuse the
  //   ia_vertices value per the model).  All four are free-running and
  //   monotonic; cmdexec differences them across a Begin/End window.
  output logic [4*32-1:0]   qry_stat_o,
  // R3 record store: the record/clip carve's aperture (dom=1) base —
  // vsi_q, the lowest of the six OFF_* buffers (OFF_VSI=0) — and its
  // valid strobe (scr_ok_q, set once S_ALLOC_W latches the ALLOC_PRIV
  // base).  vgsys forwards these to apmem.rec_base_i/rec_en_i so the
  // apmem tc_sram fast-path can recognise record accesses.  The window
  // is [scratch_base_o, +APU_REC_CARVE_BYTES); it covers all six
  // buffers (max extent ~39 KiB < 64 KiB).
  output logic [31:0]       scratch_base_o,
  output logic              scratch_valid_o
);
  if (!Enable) begin : gen_off
    assign stat_o = '0;
    assign qry_stat_o = '0;
    assign work_ready_o = 1'b0;
    assign done_o = 1'b0; assign done_pl_o = '0;
    assign sh_work_valid_o = 1'b0; assign sh_ctype_o = '0;
    assign sh_imm_o = '0; assign sh_slot_o = '0;
    assign sh_desc_o = '0; assign sh_push_n_o = '0; assign sh_push_o = '0;
    assign mp_req_valid_o = 1'b0; assign mp_req_o = '0;
    assign pg_req_valid_o = 1'b0; assign pg_req_o = '0;
    assign pg_cpl_ready_o = 1'b0;
    assign busy_o = 1'b0;
    assign scratch_base_o = '0; assign scratch_valid_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | work_valid_i |
                    (|work_i) | (|rd_i) | (|desc_i) | (|push_n_i) |
                    (|push_i) | sh_work_ready_i | sh_done_i |
                    (|sh_done_pl_i) | mp_req_ready_i | mp_rsp_valid_i |
                    (|mp_rsp_i) | pg_req_ready_i | pg_cpl_valid_i |
                    (|pg_cpl_i);
  end else begin : gen_on

    localparam int unsigned VSB  = APU_RAST_VS_BATCH;   // 63
    localparam int unsigned FSB  = APU_RAST_FS_BATCH;   // 64
    localparam int unsigned ASTR = APU_SH_ATTR_STRIDE;  // 144
    localparam int unsigned VSTR = APU_SH_VARY_STRIDE;  // 144
    // scratch carve order (pkg): vs_in, vs_out, fs_in, fs_out,
    // clip_out, clip_tmp — each base 64 B aligned.  The two 9-record
    // clip rings are the S-H ping-pong buffers; clip_out always
    // holds the final polygon (the fan-triangulated records the
    // setup path then reads through the selectable record base).
    localparam int unsigned OFF_VSI = 0;
    localparam int unsigned OFF_VSO = VSB * ASTR;                          // 8064
    localparam int unsigned OFF_FSI = (OFF_VSO + VSB * VSTR + 63) & ~63;   // 17152
    localparam int unsigned OFF_FSO = OFF_FSI + FSB * VSTR;                // 26368
    localparam int unsigned OFF_CLP = (OFF_FSO + FSB * ASTR + 63) & ~63;
    localparam int unsigned OFF_CTP = OFF_CLP + ((9 * VSTR + 63) & ~63);
    // TP5 vertex reuse (scatter-v1).  The six rings above end at
    // CTP_END = 39296, leaving ~25.6 KiB of carve slack to 64 KiB —
    // OFF_VTXC parks the compacted VS-output ring (vso_c, VSB*VSTR)
    // there so it is served by the existing isrec_w window.  The
    // post-transform cache entries do NOT fit the carve; they live in
    // apmem's parallel isvtx_w window appended at scratch_base+64 KiB
    // (VTX_WIN_B bytes), which is why the ALLOC_PRIV request below grows
    // by exactly that amount.  Cache entry stride = one tag word (8 B)
    // + the VSTR post-transform record = VSTR+8 = 152 B, mirroring
    // g6lc_apu_pkg::APU_VTX_ENTRY_WORDS/BYTES on the apmem side.
    localparam int unsigned CTP_END  = OFF_CTP + ((9 * VSTR + 63) & ~63);
    localparam int unsigned OFF_VTXC = CTP_END;                    // 39296
    localparam int unsigned VTXC_STR = VSTR + 8;                  // 152 B/entry
    localparam int unsigned VTX_WIN_B = VtxCacheEntries * VTXC_STR;
    // FP6 frag-pipeline overlap: bank-1 frag-in (FSI) records park in the
    // carve slack right after the vso_c ring (OFF_VTXC + VSB*VSTR ends at
    // 48368).  FSI bank-1 = FSB*VSTR = 9216 B -> OFF_FSI1+FSB*VSTR = 57600,
    // still < 64 KiB, so NO record-SRAM growth is needed (unlike a full
    // FSI+FSO pair).  FSO stays single: its writer (shader) and reader
    // (ROP) are ordered by the deferred drain before each wave launch.
    localparam int unsigned OFF_FSI1 = (OFF_VTXC + VSB * VSTR + 63) & ~63; // 48384

    typedef enum logic [7:0] {
      S_IDLE,
      S_ALLOC, S_ALLOC_W,
      S_OP,
      S_CLR_X, S_CLR_N,
      S_DR_HW, S_DR_HH, S_DR_DZ,
      S_DR_BATCH,
      S_GA_ISET, S_GA_IBX,
      S_GA_ATTR, S_GA_RD, S_GA_CVT,
      S_GA_U8I, S_GA_U8M, S_GA_U8S,
      S_GA_W0, S_GA_W1, S_GA_S8A, S_GA_S8B,
      S_VS_ISS, S_VS_WAIT,
      S_PR_I0, S_PR_I0B, S_PR_I1, S_PR_I2, S_PR_W,
      S_T0R, S_T1R, S_T2R,
      S_T0X, S_T0Y, S_T0Z, S_T1X, S_T1Y, S_T1Z, S_T2X, S_T2Y, S_T2Z,
      S_T0SA, S_T0SF, S_T0SM, S_T0SC, S_T0YA, S_T0YF, S_T0YM, S_T0YC,
      S_T0ZF,
      S_T1SA, S_T1SF, S_T1SM, S_T1SC, S_T1YA, S_T1YF, S_T1YM, S_T1YC,
      S_T1ZF,
      S_T2SA, S_T2SF, S_T2SM, S_T2SC, S_T2YA, S_T2YF, S_T2YM, S_T2YC,
      S_T2ZF,
      S_PR_AREA, S_PR_SHF, S_PR_BBX,
      S_PR_RCI, S_PR_RCD, S_PR_VF, S_PR_VF2,
      S_SCAN,
      S_F_LE0, S_F_LE1, S_F_LE2,
      S_F_L0, S_F_L1, S_F_L2,
      S_F_P0, S_F_P1, S_F_P2,
      S_F_S0, S_F_S1, S_F_RD,
      S_F_Z1, S_F_Z2, S_F_Z3,
      S_F_PXI, S_F_PXM, S_F_PYI, S_F_PYM,
      S_DZ_RD, S_DZ_DI, S_DZ_DM, S_DZ_C2, S_DZ_WR,
      S_F_W0, S_F_W1,
      S_F_LSET,
      S_F_V0, S_F_V1, S_F_V2, S_F_VS, S_F_VN,
      S_F_VW0, S_F_VW1,
      // G2b clip-space clipper: outcode eval (gw = 4096*w per
      // vertex), then Sutherland–Hodgman over the violated planes
      // ping-ponging {in,out} vertex rings; emit states write
      // VS-out-format records (slot 0 + fs_in_mask locations)
      S_OC_G1, S_OC_G2, S_OC_G3, S_OC,
      S_CP_RP0, S_CP_RP1, S_CP_RP2, S_CP_DD, S_CP_DG,
      S_CP_EDGE, S_CP_ENX,
      S_CP_IT0, S_CP_IT1, S_CP_IT2,
      S_CP_ILP,
      S_CP_IR0, S_CP_IR1, S_CP_IR2, S_CP_IR3,
      S_CP_IS, S_CP_IF, S_CP_IW2, S_CP_IW3, S_CP_IW4,
      S_CP_CB0, S_CP_CB1, S_CP_CBL, S_CP_CBR, S_CP_CBQ, S_CP_CBW,
      S_CP_PDN,
      S_F_PY2, S_F_LNEXT,
      S_FLUSH, S_FS_WAIT, S_DGATE,
      S_ROP_R0, S_ROP_R1, S_ROP_R2,
      S_ROP_F8, S_ROP_LRD, S_ROP_LDI, S_ROP_LDM,
      S_ROP_LC, S_ROP_LWR,
      S_ROP_DI, S_ROP_DM, S_ROP_DS,
      S_BL_SAT, S_BL_MM,
      S_BL_F1, S_BL_F1B, S_BL_F2B,
      S_BL_M2, S_BL_OP, S_BL_ST,
      S_ROP_WR, S_ROP_NX,
      S_BATNEXT,
      S_FIN_OK, S_FIN_BAD,
      S_MPW,
      S_FPS, S_FPW,
      // 1 px line list/strip.  Appended so the clip-state numbers
      // the unit TB pins (S_OC_G1 .. S_CP_PDN) do not move.
      S_LN_VF, S_LN_VF2, S_LN_VF3, S_LN_INIT, S_LN_PIX, S_LN_STEP,
      S_DB0, S_DBCR, S_DB1, S_DB1B, S_DB2,
      S_DS0, S_DS1, S_DS2, S_DS3, S_DS4, S_DS5, S_DS6,
      S_ROP_LOP,
      // Line clip.  Appended so earlier state numbers stay put.
      S_LC_D0, S_LC_DG, S_LC_DD, S_LC_T0, S_LC_T1, S_LC_TL,
      S_LC_C0, S_LC_C1, S_LC_C2, S_LC_N,
      // TP5 vertex-cache reuse (VtxCacheEntries>0, indexed, instance==1,
      // !xfb, !vs_sidefx).  Appended so all earlier state numbers hold.
      S_VT_TAG,      // classify the probed cache tag (hit vs miss)
      S_VT_HIT,      // hit: arm the 18-word cache->vso[j_q] copy burst
      S_VT_CP,       // copy burst: read cache word -> queue vso write
      S_VT_MISS,     // miss: record out_slot, enter packed-miss gather
      S_VT_SC,       // post-VS scatter: vso_c[m] -> vso[out_slot[m]]
      S_VT_F0,       // fill miss setup: cache tag write + first rec read
      S_VT_FL        // post-VS cache fill: vso_c[m] -> cache entry record
    } st_e;
    st_e st_q;

    // ---- latched record + sideband -------------------------------------
    apu_rast_draw_t dr_q;
    apu_sh_desc_t   desc_q;
    logic [5:0]     push_n_q;
    logic [1023:0]  push_q;
    logic [31:0]    wid_q;
    logic [31:0]    robust_q;
    logic [7:0]     code_q;

    // ---- scratch ring bases (carved once) ------------------------------
    logic           scr_ok_q;
    logic [31:0]    vsi_q, vso_q, fsi_q, fso_q, clp_q, ctp_q;
    logic [31:0]    fsi1_q;                 // FP6 frag-in bank-1 base

    // ---- memory-port sequencer ------------------------------------------
    // S_MPW issues one request (held until ready), then waits for the
    // single response; mp_acked_q marks the accepted request.  The
    // windowed gather (mp_ret_q == S_GA_RD) chains word reads; the
    // varying prefetch chains two words via S_PR_VF/S_PR_VF2.
    logic           mp_acked_q, mp_we_q;
    logic [63:0]    mp_addr_q, mp_data_q;
    logic [7:0]     mp_strb_q;
    logic [63:0]    mp_res_q;
    st_e            mp_ret_q;

    // RP4 write-behind queue: a two-entry FIFO in front of the memory
    // port.  The eleven record-write states push {addr,data,strb}
    // here and advance immediately instead of parking in S_MPW; the
    // port serves the head entry first (the one-outstanding-request
    // contract is unchanged) and pops it when its response returns.
    // S_MPW still serves the unconverted reads and is gated on an
    // empty queue, so a read can never be accepted before every
    // earlier queued write has responded.
    logic [1:0]         wq_v_q;
    logic               wq_acked_q;
    logic [63:0]        wq_addr_q [2];
    logic [63:0]        wq_data_q [2];
    logic [7:0]         wq_strb_q [2];
    logic               wq_pop, wq_ok;

    // ---- fpnew sequencer --------------------------------------------------
    // fp_kind_q 0=fma 1=dsq 2=cvt; fp_o_q: fma 0=FMADD 1=ADD 2=MUL,
    // cvt 0=I2F 1=F2I; fp_mod_q: fma-ADD subtract / cvt unsigned.
    logic [1:0]     fp_kind_q, fp_o_q;
    logic           fp_mod_q;
    logic [31:0]    fp_a_q, fp_b_q, fp_c_q, fp_res_q;
    st_e            fp_ret_q;
    logic           fp_iss_q;
    // FP6-opt(i): second FMA lane for the S_F_V0 varying chain.  The 16
    // per-location jobs form 4 independent per-component accumulator
    // chains; two component jobs of the same op issue per cycle on
    // i_fma / i_fma2.  fp2_* mirror the fp_* operand flops for lane B.
    logic [1:0]     fp2_o_q;
    logic           fp2_mod_q;
    logic [31:0]    fp2_a_q, fp2_b_q, fp2_c_q;
    logic           fp2_iss_q;
    // RP2: per-cycle issue step counters for the two interpolation
    // chains (S_F_LE0 fragment chain, S_F_V0 varying chain).  ik_q is
    // 0 on entry to either and returns to 0 on exit; rsd_q marks a
    // divider result still pending when the chain reached its end.
    logic [4:0]     ik_q;
    logic           rsd_q;
    // FP6: rdiv_q marks a deferred 1/wsum divider capture — set when
    // S_F_LE0 leaves its chain with the divider still in flight on a
    // frag that takes the direct S_F_PY2->S_F_W0 path (no early-Z, so
    // no second divider or fp issue can interleave).  dq_res is then
    // grabbed in the always_ff tail and rs_q is first consumed at
    // S_F_W1, which holds until rdiv_q clears.
    logic           rdiv_q;

    // fpnew wiring
    logic [2:0][31:0] fma_ops;
    fpnew_pkg::operation_e fma_op;
    logic                 fma_mod, fma_iv, fma_ir, fma_ov;
    logic [31:0]          fma_res;
    // FP6-opt(i): lane-B FMA wires (S_F_V0 component pairs only).
    logic [2:0][31:0] fma2_ops;
    fpnew_pkg::operation_e fma2_op;
    logic                 fma2_mod, fma2_iv, fma2_ir, fma2_ov;
    logic [31:0]          fma2_res;
    logic [1:0][31:0]     dq_ops;
    fpnew_pkg::operation_e dq_op;
    logic                 dq_iv, dq_ir, dq_ov;
    logic [31:0]          dq_res;
    logic [31:0]          cv_ops;
    fpnew_pkg::operation_e cv_op;
    fpnew_pkg::roundmode_e cv_rnd;
    logic                 cv_mod, cv_iv, cv_ir, cv_ov;
    logic [31:0]          cv_res;

    // RP1: fma and cvt drop the unit input register — the operands
    // already sit in the fp_a_q/fp_b_q/fp_c_q flops for the whole
    // job, so that register was a second, redundant stage; the
    // operand-flop → unit → fp_res_q path is the same logic depth as
    // operand-flop → unit-reg → unit → fp_res_q was.  i_dsq keeps its
    // register (the divider's own latency is unchanged).
    fpnew_fma #(
      .FpFormat(fpnew_pkg::FP32), .NumPipeRegs(0),
      .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic), .AuxType(logic)
    ) i_fma (
      .clk_i, .rst_ni,
      .operands_i(fma_ops), .is_boxed_i(3'b111),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(fma_op),
      .op_mod_i(fma_mod), .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(fma_iv), .in_ready_o(fma_ir),
      .flush_i(1'b0),
      .result_o(fma_res), .status_o(),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(fma_ov), .out_ready_i(1'b1),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );
    // FP6-opt(i): dedicated second FMA lane, used only by the S_F_V0
    // component-pair issue.  Same parameters as i_fma so both lanes
    // produce bit-identical results for the same operands/op.
    fpnew_fma #(
      .FpFormat(fpnew_pkg::FP32), .NumPipeRegs(0),
      .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic), .AuxType(logic)
    ) i_fma2 (
      .clk_i, .rst_ni,
      .operands_i(fma2_ops), .is_boxed_i(3'b111),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(fma2_op),
      .op_mod_i(fma2_mod), .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(fma2_iv), .in_ready_o(fma2_ir),
      .flush_i(1'b0),
      .result_o(fma2_res), .status_o(),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(fma2_ov), .out_ready_i(1'b1),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );
    fpnew_divsqrt_th_32 #(
      .NumPipeRegs(1), .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic), .AuxType(logic)
    ) i_dsq (
      .clk_i, .rst_ni,
      .operands_i(dq_ops),
      .is_boxed_i({fpnew_pkg::NUM_FP_FORMATS{2'b11}}),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(dq_op),
      .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(dq_iv), .in_ready_o(dq_ir),
      .flush_i(1'b0),
      .result_o(dq_res), .status_o(),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(dq_ov), .out_ready_i(1'b1),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );
    fpnew_cast_multi #(
      // fmt_logic_t is [0:4]: index 0 (FP32) is the MSB;
      // ifmt_logic_t is [0:3]: index 2 (INT32)
      .FpFmtConfig(5'b10000), .IntFmtConfig(4'b0010),
      .NumPipeRegs(0), .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic), .AuxType(logic)
    ) i_cvt (
      .clk_i, .rst_ni,
      .operands_i(cv_ops), .is_boxed_i(1'b1),
      .rnd_mode_i(cv_rnd), .op_i(cv_op), .op_mod_i(cv_mod),
      .src_fmt_i(fpnew_pkg::FP32), .dst_fmt_i(fpnew_pkg::FP32),
      .int_fmt_i(fpnew_pkg::INT32),
      .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(cv_iv), .in_ready_o(cv_ir), .flush_i(1'b0),
      .result_o(cv_res), .status_o(),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(cv_ov), .out_ready_i(1'b1),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );

    assign fma_ops = {fp_c_q, fp_b_q, fp_a_q};
    assign fma_op  = (fp_o_q == 2'd0) ? fpnew_pkg::FMADD :
                     (fp_o_q == 2'd1) ? fpnew_pkg::ADD : fpnew_pkg::MUL;
    assign fma_mod = fp_mod_q;
    assign fma_iv  = fp_iss_q && fp_kind_q == 2'd0;
    // FP6-opt(i): lane B is FMA-only and dedicated to S_F_V0 pairs.
    assign fma2_ops = {fp2_c_q, fp2_b_q, fp2_a_q};
    assign fma2_op  = (fp2_o_q == 2'd0) ? fpnew_pkg::FMADD :
                      (fp2_o_q == 2'd1) ? fpnew_pkg::ADD : fpnew_pkg::MUL;
    assign fma2_mod = fp2_mod_q;
    assign fma2_iv  = fp2_iss_q;
    assign dq_ops  = {fp_b_q, fp_a_q};
    assign dq_op   = fpnew_pkg::DIV;
    assign dq_iv   = fp_iss_q && fp_kind_q == 2'd1;
    assign cv_ops  = fp_a_q;
    assign cv_op   = (fp_o_q == 2'd0) ? fpnew_pkg::I2F : fpnew_pkg::F2I;
    assign cv_rnd  = fpnew_pkg::RNE;
    assign cv_mod  = fp_mod_q;
    assign cv_iv   = fp_iss_q && fp_kind_q == 2'd2;

    // ---- helpers --------------------------------------------------------
    // fp32 -> UNORM8, clamped, round-to-nearest (same rule as
    // g6lc_apu_xfer::f_f32_u8 — v = f*255)
    function automatic logic [7:0] f_f32_u8(input logic [31:0] f);
      logic [39:0] p;
      logic [8:0]  sh;
      p  = 40'({1'b1, f[22:0]}) * 40'd255;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 8'h00;
      if (f[30:23] == 8'h00)  return 8'h00;   // subnormal/zero
      if (f[30:23] >= 8'd127) return 8'hff;   // f >= 1.0 / inf / nan
      return 8'((p + (40'h1 << (sh - 9'd1))) >> sh);
    endfunction

    // fp32 -> UNORM16, clamped, round-to-nearest (f*65535 — same
    // structure as f_f32_u8; used by the D16 depth clear/write)
    function automatic logic [15:0] f_f32_u16(input logic [31:0] f);
      logic [39:0] p;
      logic [8:0]  sh;
      p  = 40'({1'b1, f[22:0]}) * 40'd65535;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 16'h0000;
      if (f[30:23] == 8'h00)  return 16'h0000;
      if (f[30:23] >= 8'd127) return 16'hFFFF;
      return 16'((p + (40'h1 << (sh - 9'd1))) >> sh);
    endfunction

    // fp32 -> UNORM24 (f*16777215).  D24S8 stores this in [23:0].
    function automatic logic [23:0] f_f32_u24(input logic [31:0] f);
      logic [47:0] p;
      logic [8:0]  sh;
      p  = 48'({1'b1, f[22:0]}) * 48'd16777215;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 24'h000000;
      if (f[30:23] == 8'h00)  return 24'h000000;
      if (f[30:23] >= 8'd127) return 24'hFFFFFF;
      return 24'((p + (48'h1 << (sh - 9'd1))) >> sh);
    endfunction

    // p + 0.5 as fp32, exact: (2p+1) has at most 17 significant bits
    function automatic logic [31:0] f_pxc(input logic [15:0] p);
      logic [16:0] m, n;
      logic [4:0]  hi;
      m  = {p, 1'b1};
      hi = '0;
      for (int i = 0; i <= 16; i++) if (m[i]) hi = 5'(i);
      n  = m << (5'd16 - hi);          // leading one at bit 16
      return {1'b0, 8'd126 + 8'(hi), n[15:0], 7'h0};
    endfunction

    function automatic logic f_scmp(input logic [2:0] op,
                                    input logic [7:0] s,
                                    input logic [7:0] rf,
                                    input logic [7:0] mask);
      logic [7:0] a, b;
      a = s & mask;
      b = rf & mask;
      unique case (op)
        3'd0:     f_scmp = 1'b0;
        3'd1:     f_scmp = a < b;
        3'd2:     f_scmp = a == b;
        3'd3:     f_scmp = a <= b;
        3'd4:     f_scmp = a > b;
        3'd5:     f_scmp = a != b;
        3'd6:     f_scmp = a >= b;
        default:  f_scmp = 1'b1;
      endcase
    endfunction

    function automatic logic [7:0] f_sop(input logic [2:0] op,
                                         input logic [7:0] oldb,
                                         input logic [7:0] rf,
                                         input logic [7:0] mask);
      logic [7:0] n;
      unique case (op)
        3'd0:     n = oldb;
        3'd1:     n = 8'h00;
        3'd2:     n = rf;
        3'd3:     n = (oldb == 8'hFF) ? 8'hFF : oldb + 8'd1;
        3'd4:     n = (oldb == 8'h00) ? 8'h00 : oldb - 8'd1;
        3'd5:     n = ~oldb;
        3'd6:     n = oldb + 8'd1;
        default:  n = oldb - 8'd1;
      endcase
      f_sop = (oldb & ~mask) | (n & mask);
    endfunction

    // fp32 -> 12-bit linear index for the sRGB encode LUT
    // (clamp*4095 RNE; APU_SRGB_ENC is contracted to u12)
    function automatic logic [11:0] f_f32_u12(input logic [31:0] f);
      logic [39:0] p;
      logic [8:0]  sh;
      p  = 40'({1'b1, f[22:0]}) * 40'd4095;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 12'h000;
      if (f[30:23] == 8'h00)  return 12'h000;
      if (f[30:23] >= 8'd127) return 12'hFFF;
      return 12'((p + (40'h1 << (sh - 9'd1))) >> sh);
    endfunction

    // f32 a < b on magnitudes (NaN → false; -0 == +0)
    function automatic logic f_f32_lt(input logic [31:0] a,
                                      input logic [31:0] b);
      if ({a[30:0], b[30:0]} == 62'h0) return 1'b0;
      if (a[31] != b[31])              return a[31];
      return a[31] ? (a > b) : (a < b);
    endfunction

    // depth compare (VkCompareOp 0..7) on f32 values
    function automatic logic f_dcmp(input logic [2:0] op,
                                    input logic [31:0] a,
                                    input logic [31:0] b);
      unique case (op)
        3'd0:     f_dcmp = 1'b0;                       // NEVER
        3'd1:     f_dcmp = f_f32_lt(a, b);             // LESS
        3'd2:     f_dcmp = (a == b);                   // EQUAL
        3'd3:     f_dcmp = f_f32_lt(a, b) || (a == b); // LEQUAL
        3'd4:     f_dcmp = f_f32_lt(b, a);             // GREATER
        3'd5:     f_dcmp = (a != b);                   // NOTEQUAL
        3'd6:     f_dcmp = f_f32_lt(b, a) || (a == b); // GEQUAL
        default:  f_dcmp = 1'b1;                       // ALWAYS
      endcase
    endfunction

    // attachment row pitch — the Xfer device-linear rule
    // (align(w*bpp,64)); bpp is 4 for the color/D32 formats and 2
    // for D16_UNORM.
    function automatic logic [31:0] f_pitch2(input logic [15:0] w,
                                             input logic [2:0]  bpp);
      return ((32'(w) * 32'(bpp)) + 32'd63) & ~32'd63;
    endfunction

    // color-attachment format legality
    function automatic logic f_cfmt_ok(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_R8G8B8A8_UNORM) ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_UNORM) ||
             f == 8'(APU_IMG_FMT_R8G8B8A8_SRGB)  ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_SRGB)  ||
             // T3: integer RGBA8 (f_enc8 keeps the low byte, no blend)
             f == 8'(APU_IMG_FMT_R8G8B8A8_UINT);
    endfunction
    function automatic logic f_dfmt_ok(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_D32_SFLOAT) ||
             f == 8'(APU_IMG_FMT_D16_UNORM) ||
             f == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT);
    endfunction
    // sRGB formats share the BGRA/RGBA byte orders
    function automatic logic f_is_srgb(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_R8G8B8A8_SRGB) ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_SRGB);
    endfunction
    function automatic logic f_is_bgr(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_B8G8R8A8_UNORM) ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_SRGB);
    endfunction

    // attribute byte count per accepted format (0 = unsupported)
    // IEEE binary16 -> binary32.  Subnormals flush to signed zero.
    function automatic logic [31:0] f_f16_f32(input logic [15:0] h);
      logic [4:0] e;
      e = h[14:10];
      if (e == 5'h00)
        f_f16_f32 = {h[15], 31'h0};
      else if (e == 5'h1F)
        f_f16_f32 = {h[15], 8'hFF, h[9:0], 13'h0};
      else
        f_f16_f32 = {h[15], 8'(e) + 8'd112, h[9:0], 13'h0};
    endfunction

    function automatic logic [31:0] f_sxt8(input logic [7:0] b);
      f_sxt8 = {{24{b[7]}}, b};
    endfunction
    function automatic logic [31:0] f_sxt16(input logic [15:0] h);
      f_sxt16 = {{16{h[15]}}, h};
    endfunction
    // Integer attributes are copied as raw bits.  A missing alpha is
    // the integer 1, not the float 1.
    function automatic logic f_is_int(input logic [7:0] f);
      f_is_int = f == APU_RAST_VF_R32_UINT || f == APU_RAST_VF_R32_SINT ||
                 f == APU_RAST_VF_RG32_UINT || f == APU_RAST_VF_RG32_SINT ||
                 f == APU_RAST_VF_RGB32_UINT || f == APU_RAST_VF_RGB32_SINT ||
                 f == APU_RAST_VF_RGBA32_UINT || f == APU_RAST_VF_RGBA32_SINT;
    endfunction
    // 8- and 16-bit vertex integers are raw words.  Missing components
    // are (0, 0, 0, 1), with the 1 an integer.
    function automatic logic f_is_i8(input logic [7:0] f);
      f_is_i8 = f == APU_RAST_VF_R8_UINT || f == APU_RAST_VF_R8_SINT ||
                f == APU_RAST_VF_RG8_UINT || f == APU_RAST_VF_RG8_SINT ||
                f == APU_RAST_VF_RGB8_UINT || f == APU_RAST_VF_RGB8_SINT ||
                f == APU_RAST_VF_RGBA8_UINT || f == APU_RAST_VF_RGBA8_SINT;
    endfunction
    function automatic logic f_is_i16(input logic [7:0] f);
      f_is_i16 = f == APU_RAST_VF_R16_UINT || f == APU_RAST_VF_R16_SINT ||
                 f == APU_RAST_VF_RG16_UINT || f == APU_RAST_VF_RG16_SINT ||
                 f == APU_RAST_VF_RGB16_UINT || f == APU_RAST_VF_RGB16_SINT ||
                 f == APU_RAST_VF_RGBA16_UINT || f == APU_RAST_VF_RGBA16_SINT;
    endfunction
    function automatic logic f_is_sint(input logic [7:0] f);
      f_is_sint = f == APU_RAST_VF_R8_SINT || f == APU_RAST_VF_RG8_SINT ||
                  f == APU_RAST_VF_RGB8_SINT || f == APU_RAST_VF_RGBA8_SINT ||
                  f == APU_RAST_VF_R16_SINT || f == APU_RAST_VF_RG16_SINT ||
                  f == APU_RAST_VF_RGB16_SINT || f == APU_RAST_VF_RGBA16_SINT;
    endfunction
    function automatic logic [2:0] f_nc(input logic [7:0] f);
      if (f == APU_RAST_VF_R8_UINT || f == APU_RAST_VF_R8_SINT ||
          f == APU_RAST_VF_R16_UINT || f == APU_RAST_VF_R16_SINT)
        f_nc = 3'd1;
      else if (f == APU_RAST_VF_RG8_UINT || f == APU_RAST_VF_RG8_SINT ||
               f == APU_RAST_VF_RG16_UINT || f == APU_RAST_VF_RG16_SINT)
        f_nc = 3'd2;
      else if (f == APU_RAST_VF_RGB8_UINT || f == APU_RAST_VF_RGB8_SINT ||
               f == APU_RAST_VF_RGB16_UINT || f == APU_RAST_VF_RGB16_SINT)
        f_nc = 3'd3;
      else
        f_nc = 3'd4;
    endfunction
    function automatic logic [31:0] f_icomp(
        input logic [191:0] w, input logic [2:0] off,
        input logic [1:0] comp, input logic wide, input logic sgn,
        input logic [2:0] nc);
      logic [15:0] h;
      logic [7:0]  b;
      if ({1'b0, comp} >= nc)
        f_icomp = (comp == 2'd3) ? 32'h1 : 32'h0;
      else if (wide) begin
        h = w[8*off + 16*comp +: 16];
        f_icomp = sgn ? {{16{h[15]}}, h} : {16'h0, h};
      end else begin
        b = w[8*off + 8*comp +: 8];
        f_icomp = sgn ? {{24{b[7]}}, b} : {24'h0, b};
      end
    endfunction

    function automatic logic [4:0] f_asz(input logic [7:0] f);
      unique case (f)
        APU_RAST_VF_R32_SFLOAT:    f_asz = 5'd4;
        APU_RAST_VF_RG32_SFLOAT:   f_asz = 5'd8;
        APU_RAST_VF_RGB32_SFLOAT:  f_asz = 5'd12;
        APU_RAST_VF_RGBA32_SFLOAT: f_asz = 5'd16;
        APU_RAST_VF_R8_UNORM:      f_asz = 5'd1;
        APU_RAST_VF_RG8_UNORM:     f_asz = 5'd2;
        APU_RAST_VF_RGB8_UNORM:    f_asz = 5'd3;
        APU_RAST_VF_RGBA8_UNORM:   f_asz = 5'd4;
        APU_RAST_VF_R8_SNORM:      f_asz = 5'd1;
        APU_RAST_VF_RG8_SNORM:     f_asz = 5'd2;
        APU_RAST_VF_RGB8_SNORM:    f_asz = 5'd3;
        APU_RAST_VF_RGBA8_SNORM:   f_asz = 5'd4;
        APU_RAST_VF_R8_UINT, APU_RAST_VF_R8_SINT: f_asz = 5'd1;
        APU_RAST_VF_RG8_UINT, APU_RAST_VF_RG8_SINT: f_asz = 5'd2;
        APU_RAST_VF_RGB8_UINT, APU_RAST_VF_RGB8_SINT: f_asz = 5'd3;
        APU_RAST_VF_RGBA8_UINT, APU_RAST_VF_RGBA8_SINT: f_asz = 5'd4;
        APU_RAST_VF_R16_UNORM:     f_asz = 5'd2;
        APU_RAST_VF_RG16_UNORM:    f_asz = 5'd4;
        APU_RAST_VF_RGB16_UNORM:   f_asz = 5'd6;
        APU_RAST_VF_RGBA16_UNORM:  f_asz = 5'd8;
        APU_RAST_VF_R16_SNORM:     f_asz = 5'd2;
        APU_RAST_VF_RG16_SNORM:    f_asz = 5'd4;
        APU_RAST_VF_RGB16_SNORM:   f_asz = 5'd6;
        APU_RAST_VF_RGBA16_SNORM:  f_asz = 5'd8;
        APU_RAST_VF_R16_UINT, APU_RAST_VF_R16_SINT: f_asz = 5'd2;
        APU_RAST_VF_RG16_UINT, APU_RAST_VF_RG16_SINT: f_asz = 5'd4;
        APU_RAST_VF_RGB16_UINT, APU_RAST_VF_RGB16_SINT: f_asz = 5'd6;
        APU_RAST_VF_RGBA16_UINT, APU_RAST_VF_RGBA16_SINT: f_asz = 5'd8;
        APU_RAST_VF_R16_SFLOAT:    f_asz = 5'd2;
        APU_RAST_VF_RG16_SFLOAT:   f_asz = 5'd4;
        APU_RAST_VF_RGB16_SFLOAT:  f_asz = 5'd6;
        APU_RAST_VF_RGBA16_SFLOAT: f_asz = 5'd8;
        APU_RAST_VF_R32_UINT, APU_RAST_VF_R32_SINT: f_asz = 5'd4;
        APU_RAST_VF_RG32_UINT, APU_RAST_VF_RG32_SINT: f_asz = 5'd8;
        APU_RAST_VF_RGB32_UINT, APU_RAST_VF_RGB32_SINT: f_asz = 5'd12;
        APU_RAST_VF_RGBA32_UINT, APU_RAST_VF_RGBA32_SINT: f_asz = 5'd16;
        default:                   f_asz = 5'd0;
      endcase
    endfunction

    // blend-factor operand base for factor code f on component c
    // (the ONE_MINUS_* variants share the code's base and are flagged
    // by f_fminus; SRC_ALPHA_SATURATE uses the precomputed 1-dst.a)
    function automatic logic f_fminus(input logic [4:0] f);
      return f == APU_RAST_BF_OM_SRC_COLOR  ||
             f == APU_RAST_BF_OM_DST_COLOR  ||
             f == APU_RAST_BF_OM_SRC_ALPHA  ||
             f == APU_RAST_BF_OM_DST_ALPHA  ||
             f == APU_RAST_BF_OM_CONST_COLOR ||
             f == APU_RAST_BF_OM_CONST_ALPHA;
    endfunction
    // f32 strictly positive and finite (w > 0 keeps the prim)
    function automatic logic f_wpos(input logic [31:0] w);
      return !w[31] && (w[30:0] != 31'h0) && (w[30:23] != 8'hFF);
    endfunction

    // highest set bit of |v| (for the λ shift); 63 = no bit found
    function automatic logic [5:0] f_msb(input logic [63:0] v);
      logic [63:0] a;
      a = v[63] ? ~v + 64'd1 : v;
      f_msb = 6'd63;
      for (int i = 62; i >= 0; i--)
        if (a[i] && f_msb == 6'd63) f_msb = 6'(i);
    endfunction

    // ---- state -----------------------------------------------------------
    // CLEAR
    logic [31:0]  clr_pix_q;
    logic [15:0]  cy_q, cx_q;
    // DRAW setup
    logic [31:0]  vphw_q, vphh_q, vpdz_q;   // vp.w/2, vp.h/2, maxz-minz
    logic [31:0]  inst_q, bat_q;
    logic [5:0]   nv_q, j_q;
    logic [2:0]   a_q;
    logic [1:0]   i_q;                      // window word cursor
    logic [1:0]   t_q;                      // triangle vertex cursor
    logic signed [31:0] ib_i;               // current vertex index
    logic [191:0] win_q;                    // gather window (3 words)
    logic [1:0]   wn_q;                     // words still to read
    logic [31:0]  caddr_q, gbase_q, gsize_q;// gather addr / bounds
    logic [4:0]   csz_q;
    st_e          gret_q;
    logic [3:0][31:0] conv_q;               // converted attr / frag tmp
    logic [2:0]   c_q;                      // component cursor
    logic [2:0]   u8n_q;                    // UNORM8/SNORM8 components present
    logic         snorm_q, u16_q;
    // primitive transform results
    logic [3:0][31:0] pos_q [3];            // raw Position x,y,z,w
    logic [31:0]  vrw_q [3];                // 1/w
    logic [31:0]  vnd_q [3][3];             // ndc x,y,z
    logic [31:0]  vz_q  [3];                // viewport z
    logic signed [31:0] vxi_q [3], vyi_q [3]; // 16.8 screen coords
    // max |pixel delta| of the three edges, at least 1.  Depth-bias
    // slope is max |dz| over this span.
    function automatic logic [15:0] f_uad(input logic signed [31:0] a,
                                          input logic signed [31:0] b);
      logic signed [15:0] d;
      d = 16'(a >>> 8) - 16'(b >>> 8);
      f_uad = d[15] ? 16'(-d) : 16'(d);
    endfunction
    function automatic logic [15:0] f_mx2(input logic [15:0] a,
                                          input logic [15:0] b);
      f_mx2 = (a > b) ? a : b;
    endfunction
    // TP5: direct-mapped cache entry for a resolved vertex index.
    // ib_i is signed; $unsigned keeps the map total and deterministic.
    // The stored tag (full resolved index + generation + valid) catches
    // every collision, so any bounded map is functionally correct — the
    // modulo only spreads entries across the window.  Guarded against
    // VtxCacheEntries==0 so the (dead) address wires never divide by 0.
    function automatic logic [15:0] f_vt_ent(input logic signed [31:0] i);
      f_vt_ent = (VtxCacheEntries == 0) ? 16'd0
                  : 16'($unsigned(i) % VtxCacheEntries);
    endfunction
    // Next active varying location strictly above cur in the per-draw
    // fs_in_mask (varm_q), or 8 when none remains.  The mask is constant
    // for a draw, so the S_F_LSET inactive-location scan collapses to one
    // priority jump instead of one cycle per masked-off slot.
    function automatic logic [3:0] f_nvar(input logic [7:0] m,
                                         input logic [3:0] cur);
      f_nvar = 4'd8;
      for (int l = 0; l < 8; l++)
        if (l > int'(cur) && m[l] && f_nvar == 4'd8) f_nvar = 4'(l);
    endfunction
    wire [15:0] span_w = f_mx2(16'd1, f_mx2(
        f_mx2(f_uad(vxi_q[1], vxi_q[0]), f_uad(vyi_q[1], vyi_q[0])),
        f_mx2(f_mx2(f_uad(vxi_q[2], vxi_q[0]), f_uad(vyi_q[2], vyi_q[0])),
              f_mx2(f_uad(vxi_q[2], vxi_q[1]), f_uad(vyi_q[2], vyi_q[1])))));
    // edges: E_k anchored at vertex (k+1)%3, direction to (k+2)%3
    logic signed [31:0] ex_q [3], ey_q [3], edx_q [3], edy_q [3];
    logic [2:0]   tl_q;
    logic signed [63:0] area_q;
    logic [5:0]   shf_q;
    logic [31:0]  rcpa_q;
    logic [15:0]  bx0_q, bx1_q, by0_q, by1_q;
    logic [15:0]  sx_q, sy_q;               // scan cursor
    logic [5:0]   p_q;                      // primitive cursor
    logic [5:0]   base_q;                   // first vertex of this strip/fan
    logic [62:0]  brk_q;                    // indexed restart sentinel per slot
    // ---- TP5 vertex-cache reuse (scatter-v1) ----------------------------
    // All of this is dead logic when VtxCacheEntries==0 (reuse_en is a
    // parameter-folded 0), so the disabled path stays bit-identical and
    // synthesis strips the cone.  mi_q is the packed miss-record index
    // into the dense vsi/vso_c rings; j_q stays the dense assembly
    // position (0..nv_q-1) that primitive setup consumes.  out_sl_q[m]
    // records the assembly position of the m-th miss so the post-VS
    // scatter can place vso_c[m] back at vso[out_sl_q[m]]; m_idx_q[m]
    // latches the resolved index for the post-VS cache tag/fill so the
    // fill loop needs no second index-buffer read.
    logic [5:0]   mi_q;                     // packed miss record index
    logic [4:0]   vt_w;                     // word cursor 0..18
    logic [5:0]   vt_m;                     // scatter/fill miss cursor
    logic [5:0]   vt_j;                     // hit-copy target assembly pos
    logic [5:0]   vt_os;                    // current miss's out_slot
    logic [15:0]  vt_e;                     // cache entry index
    logic [31:0]  vt_ib;                    // resolved index (tag/fill)
    // 31-bit draw generation: the tag is {gen[30:0], idx[31:0], valid} =
    // exactly 64 b, so gen gets every spare bit.  2^31 draws before wrap
    // is unreachable in practice; a wider gen would force truncating the
    // 32-bit resolved index and admit false hits.
    logic [30:0]  vt_gen;                   // per-draw generation serial
    logic [5:0]   out_sl_q [VSB];           // assembly pos per miss
    logic [31:0]  m_idx_q  [VSB];           // resolved vertex index per miss
    // reuse_en: indexed draw, single instance, pure VS, cache present.
    // instance_count==1 keeps the key the resolved index alone (Q2);
    // vs_sidefx blocks reuse when the VS may side-effect globally.
    // There is no XFB path in this APU, so no transform-feedback term.
    wire reuse_en = (VtxCacheEntries != 0) &&
                    (dr_q.ib_type != 2'd0) &&
                    (dr_q.instance_count == 32'd1) &&
                    !dr_q.vs_sidefx;
    // Vertex-cache window base (apmem isvtx_w) sits at
    // scratch_base+64 KiB = vsi_q+APU_RAST_SCRATCH_BYTES (OFF_VSI==0).
    // vso_c is the compacted VS-output ring parked at OFF_VTXC in the
    // carve slack, still served by the isrec_w window.  Kept 64-bit so
    // the +64 KiB window offset can never wrap a 32-bit base.
    wire [63:0]  vtx_base_w = {32'h0, vsi_q} + 64'(APU_RAST_SCRATCH_BYTES);
    wire [63:0]  vso_c_w    = {32'h0, vsi_q} + 64'(OFF_VTXC);
    // Resolved vertex index for the vertex currently being probed in
    // S_GA_IBX (mirrors the ib_i assignment there; ib_i itself only
    // updates next cycle, so the probe address needs this comb view).
    // Meaningful only while st_q==S_GA_IBX.
    wire signed [31:0] vt_cur_ib =
        dr_q.vertex_offset +
        (dr_q.ib_type == 2'd1
         ? {16'h0, win_q[8*caddr_q[2:0] +: 16]}
         : win_q[8*caddr_q[2:0] +: 32]);
    // Cache byte addresses (8 B aligned).  Entry stride VTXC_STR=152 B:
    // word0 = tag, words1..18 = the VSTR post-transform record.  The
    // entry*152 product is kept in a 48-bit self-determined width (entry
    // <=430 -> <=65360) so nothing truncates before the 64-bit add.
    wire [63:0]  vt_tag_addr_w  = vtx_base_w +
                    64'(f_vt_ent(vt_cur_ib) * VTXC_STR);
    wire [63:0]  vt_rec_addr_w  = vt_tag_addr_w + 64'd8;   // record word0
    // Same addresses but indexed by the latched entry vt_e — used by the
    // hit-copy burst and the post-VS cache fill, which run after vt_e has
    // been overwritten by later probes.
    wire [63:0]  vt_e_tag_w    = vtx_base_w + 64'(vt_e * VTXC_STR);
    wire [63:0]  vt_e_rec_w    = vt_e_tag_w + 64'd8;
    // Scatter/fill record + word byte addresses (all exact 64-bit).
    //   vt_src_rec = vso_c[vt_m] record base;  vt_woff* = vt_w*8 / +1*8
    //   vt_vso_os / vt_vso_j = dense vso record bases for scatter/hit.
    wire [63:0]  vt_src_rec  = vso_c_w + {26'h0, vt_m} * VSTR;
    wire [63:0]  vt_src_rec_n = vso_c_w + {26'h0, vt_m + 6'd1} * VSTR;
    wire [63:0]  vt_vso_os   = {32'h0, vso_q} + {26'h0, vt_os} * VSTR;
    wire [63:0]  vt_vso_j    = {32'h0, vso_q} + {26'h0, vt_j} * VSTR;
    wire [63:0]  vt_woff     = {56'h0, vt_w, 3'h0};
    wire [63:0]  vt_woff_n   = {56'h0, vt_w + 5'd1, 3'h0};
    wire [63:0]  vt_cch_w    = vt_e_rec_w + vt_woff;         // cache rec wrd
    wire [63:0]  vt_fill_tag = vtx_base_w +
                    64'(f_vt_ent(m_idx_q[vt_m]) * VTXC_STR);
    // Packed miss-record index for the dense vsi ring: when reuse is on,
    // only misses reach S_GA_ATTR..S_GA_S8B and they index vsi by mi_q;
    // when off, every vertex indexes by j_q (bit-identical).
    wire [5:0]   rec_idx_w = reuse_en ? mi_q : j_q;
    logic         ln_q;                     // fragment return is the line walk
    logic         poly_ln_q;                // triangle drawn as three edges
    logic         poly_pt_q;                // triangle drawn as one point per vertex
    logic [1:0]   le_q;
    logic         db_late_q;                 // bias updates FragDepth, else fz
    logic         db_done_q;
    st_e          db_ret_q;
    logic [31:0]  db_bias_q, db_cr_q, db_dz_q;
    // FP6-overlap late-Z slope snapshot: the deferred frag drain runs the
    // S_DB0->S_DS* depth-bias chain AFTER frag production may have advanced
    // to the next primitive and overwritten the live vz_q/span_w.  The
    // pending batch's per-primitive slope is captured into the wr_bank_q
    // slot at frag-complete (f_q==0, when vz_q/span_w still belong to the
    // producing primitive — a prim-boundary S_FLUSH already sees the NEXT
    // prim's values); db_late_q selects it for the drain path while early-Z
    // keeps the live registers.  Two banks match the frag-flop ping-pong.
    logic [31:0]  ds_vz_q [2][3];
    logic [15:0]  ds_span_q [2];
    logic [7:0]   stn_q;
    logic [23:0]  std_q;
    logic         st_hold_q;
    logic signed [15:0] lx_q, ly_q, lxe_q, lye_q;
    logic signed [15:0] ldx_q, ldy_q, lxs_q, lys_q;
    logic signed [16:0] lerr_q;
    logic [5:0]   f_q;                      // queued frags (0..FSB-1)
    logic [6:0]   nf_q;                     // in-flight frag count
    // FP6 frag-pipeline overlap: frag records are double-buffered so the
    // rasterizer produces batch N+1 while the shader/ROP drains batch N.
    // wr_bank_q selects the bank frag production writes (FSI + flops);
    // pend_bank_q/dnf_q describe the launched-but-undrained batch the
    // deferred drain (S_FS_WAIT/S_ROP) consumes.  They alternate each
    // flush, so production and drain never share a bank.
    logic         wr_bank_q, pend_bank_q;
    logic         pend_v_q;                 // a launched wave awaits drain
    logic [6:0]   dnf_q;                    // pend batch frag count
    st_e          dret_q;                   // drain return (S_FLUSH/S_FIN_OK)
    // per-fragment temporaries
    logic signed [63:0] e_q [3];
    logic [31:0]  lam_q [3], pv_q [3], rs_q, fz_q;
    logic [3:0]   lc_q;                     // location cursor (0..8)
    // fragment tables (flops, v1 — see header note); banked for overlap
    logic [31:0]  fsxy_q  [2][FSB];         // {py[15:0], px[15:0]}
    logic         fs_help_q [2][FSB];       // G2b helper-lane flags
    logic [31:0]  fsz_q   [2][FSB];         // interpolated z (late-Z source)
    logic [31:0]  lz_q;                     // late-Z candidate (slot8 word0 or fsz)
    logic         lzdone_q;                 // current fragment's late step ran
    logic [31:0]  var_q [3][8][4];          // [vert][loc][comp] cache
    logic [7:0]   varm_q;                   // locs fetched this prim
    // next ACTIVE varying location above the cursor (or 8 = fragment
    // done); consumed by S_F_VW1 to skip the LSET dispatch on hits
    wire  [3:0]   nva_w = f_nvar(varm_q, lc_q);
    // FP6-opt(i): S_F_V0 pair-step decode.  ik_q counts pair-steps
    // 0..8 (8=done); step p issues the two jobs {2p,2p+1}: op = p[2:1],
    // comps {fp_ca,fp_cb} = {p[0]?2:0, +1}.  The comp-pair alternates
    // {0,1}/{2,3} each step so the result capture and the next issue
    // never touch the same conv_q slot in one cycle.  Meaningful only
    // inside S_F_V0 (ik_q is shared with S_F_LE0).
    wire  [1:0]   fp_ca = {ik_q[0], 1'b0};   // lane-A comp: 0 or 2
    wire  [1:0]   fp_cb = fp_ca + 2'd1;      // lane-B comp: 1 or 3
    wire  [1:0]   fp_pa = {~ik_q[0], 1'b0};  // prev-step lane-A comp
    wire  [1:0]   fp_pb = fp_pa + 2'd1;      // prev-step lane-B comp
    wire  [1:0]   fp_op = ik_q[2:1];         // op 0..3
    // G2b quad scan: (sx_q,sy_q) is the even-aligned 2x2 block base,
    // (px_q,py_q) the pixel of the lane under construction; lane_q
    // is the 0..3 lane cursor inside the block and help_q its flag
    logic [1:0]   lane_q;
    logic         help_q;
    logic [15:0]  px_q, py_q;
    logic         front_q;                  // accepted prim's front bit
    // A1.3 (2026-10-16): front bit of the fragments currently in the
    // open FS batch — set when the first fragment of a fresh batch is
    // recorded (S_F_LSET f_q==0).  Adjacent same-facing primitives
    // merge into one batch; a facing change with the batch open
    // flushes before the new primitive scans.  imm[3] carries this
    // per-batch bit to the wave.
    logic         bat_front_q;
    logic         vsw_q;                    // geom slots 1/2 swapped this prim
    // ---- G2b clip-space clipper state -----------------------------------
    // Clip planes (bit order): 0 near z>=0, 1 far z<=w, 2 w>=1e-5,
    // 3 |x|<=4096w, 4 |y|<=4096w — outcodes + the violating-plane mask
    localparam logic [31:0] CLIP_EPS = 32'h3727C5AC;  // 1e-5f
    localparam logic [31:0] CLIP_GB  = 32'h45800000;  // 4096.0f
    logic [4:0]   oc_q [3];                 // per-vertex outcodes
    logic [31:0]  gw_q [3];                 // 4096*w per vertex
    logic [4:0]   cpm_q;                    // planes still to clip
    logic [2:0]   cpl_q;                    // current plane
    logic [3:0]   cn_q, co_q;               // in-poly / out-poly counts
    logic [3:0]   ce_q, ceb_q;              // edge cursor + its b vertex
    logic [31:0]  cib_q, cob_q;             // in/out ring byte bases
    logic         cmap_q;                   // in-rec index = f_pi (vso)
    logic         cslot_q;                  // emit cursor: 1 = slot 0
    logic         cemitb_q;                 // emit copy of b after interp
    logic [31:0]  cpos_q [9][4];            // in-poly positions
    logic [31:0]  cdis_q [9];               // in-poly plane distances
    logic [8:0]   cin_q;                    // in-poly inside mask
    logic [31:0]  cva_q [4], cvb_q [4];     // a/b varying staging
    logic [31:0]  ctt_q;                    // edge-crossing t
    logic         clip_q;                   // fan-triangulate clip_out
    logic         lc_out_q;                 // line clip: vertex 0 is outside
    logic [3:0]   cfan_q;                   // fan cursor (tri = 0,ci,ci+1)
    logic [3:0]   cpn_q;                    // final polygon vertex count
    // early-Z / ROP
    logic [31:0]  dz_q;                     // decoded depth texel
    logic [5:0]   r_q;
    logic [1:0]   at_q;                     // attachment cursor (0..3)
    logic [3:0][31:0] src_q;                // fs_out color (f32)
    logic [3:0][31:0] dst_q;                // decoded dst texel (f32)
    logic [3:0][31:0] res_q;                // blend result / src pass
    logic [31:0]  sf_q, df_q;               // blend factors
    logic [31:0]  bm1_q, bm2_q;             // s*sf, d*df products
    logic [31:0]  omd3_q;                   // 1 - dst.a (SATURATE)
    // RP3 dst-decode pipeline: the four channel I2F (cvt) jobs and the
    // four scale-MUL (fma) jobs issue back-to-back one per cycle, the
    // same in-order-capture discipline as S_F_LE0 — job k's result is
    // read from cv_res/fma_res one step after it was issued.  dcv_q[c]
    // holds channel c's decoded-but-unscaled I2F result until its MUL.
    logic [3:0]   dd_q;                     // decode job cursor (0..9)
    logic [3:0][31:0] dcv_q;                // per-channel I2F results
    // flush return state + sticky shader-done latch
    st_e          flr_q;
    logic         shd_q;
    apu_sh_done_t shdp_q;
    // FP6: a second done latch for FS-wave completions.  The overlap
    // lets an FS frag-batch wave stay in flight while the NEXT vertex
    // batch's VS wave runs — both share sh_done_i, so a single shd_q
    // would let a VS done satisfy S_FS_WAIT (or an FS done satisfy
    // S_VS_WAIT).  Dones are routed by work_id pseudo-ctype: FS ->
    // fshd_q (S_FS_WAIT), everything else -> shd_q (S_VS_WAIT).
    logic         fshd_q;
    apu_sh_done_t fsdp_q;

    // blend factor base value: picks src/dst colour, alpha or the
    // blend constant per the factor id (declared after the ROP regs
    // so slang sees the operands before use)
    function automatic logic [31:0] f_fbase(input logic [4:0] f,
                                            input logic [1:0] c);
      unique case (f)
        APU_RAST_BF_ZERO:          f_fbase = 32'h00000000;
        APU_RAST_BF_ONE:           f_fbase = 32'h3F800000;
        APU_RAST_BF_SRC_COLOR,
        APU_RAST_BF_OM_SRC_COLOR:  f_fbase = src_q[c];
        APU_RAST_BF_DST_COLOR,
        APU_RAST_BF_OM_DST_COLOR:  f_fbase = dst_q[c];
        APU_RAST_BF_SRC_ALPHA,
        APU_RAST_BF_OM_SRC_ALPHA:  f_fbase = src_q[3];
        APU_RAST_BF_DST_ALPHA,
        APU_RAST_BF_OM_DST_ALPHA:  f_fbase = dst_q[3];
        APU_RAST_BF_CONST_COLOR,
        APU_RAST_BF_OM_CONST_COLOR: f_fbase = dr_q.blend_const[c];
        APU_RAST_BF_CONST_ALPHA,
        APU_RAST_BF_OM_CONST_ALPHA: f_fbase = dr_q.blend_const[3];
        default: // SRC_ALPHA_SATURATE: min(As, 1-Ad) on RGB, 1 on alpha
          f_fbase = (c == 2'd3) ? 32'h3F800000
                    : (src_q[3][31] ? src_q[3]
                       : (f_f32_lt(omd3_q, src_q[3]) ? omd3_q
                          : src_q[3]));
      endcase
    endfunction

    // primitive vertex slot (batch-local): list steps 3; strip steps 1
    // and swaps slots 1/2 on odd primitives to keep the winding; fan
    // steps 1 anchored at vertex 0.  Clip mode fan-triangulates the
    // clipped polygon: tri (0, cfan, cfan+1) of the clip_out ring.
    wire line_w  = dr_q.topology == 8'd1 || dr_q.topology == 8'd2;
    wire point_w = dr_q.topology == 8'd0;
    // POINT_LIST / LINE_LIST / TRIANGLE_LIST: no vertex carries across
    // primitives, so a draw may span several vertex batches
    wire topo_list_w = dr_q.topology == 8'd0 || dr_q.topology == 8'd1 ||
                       dr_q.topology == 8'd3;
    // batch size: a primitive multiple (VSB = 63 is a multiple of 1 and
    // 3; a line list uses the even 62)
    wire [5:0] batch_v_w = (dr_q.topology == 8'd1) ? 6'(VSB & ~1) : 6'(VSB);
    // Late-Z slope bias is per-primitive: the S_ROP_LC bias uses the
    // last-scanned primitive's vz_q/span_w, so a merged same-facing batch
    // would give every fragment that primitive's slope.  When the slope
    // term is live under fs_late, flush the FS batch at each primitive
    // boundary so every batch is single-primitive and the registers are
    // correct at ROP time.  Constant-only bias is draw-uniform (safe to
    // merge); early-Z recomputes per fragment during the scan (correct).
    wire slope_bias_late = dr_q.depth_bias_en && dr_q.fs_late &&
                           (dr_q.depth_test || dr_q.depth_write) &&
                           (dr_q.depth_bias_slope[30:0] != 31'h0);
    // FP6-overlap late-Z slope: the deferred frag drain runs the
    // S_ROP_LC -> S_DB0..S_DS* bias chain possibly AFTER frag production
    // advanced to the next primitive and overwrote the live vz_q/span_w
    // (the case43 "slope leak").  Rather than force those draws synchronous
    // (the old frag_sync), each batch's per-primitive slope is captured
    // into the wr_bank_q ds_vz_q/ds_span_q slot at frag-complete (f_q==0) —
    // the moment vz_q/span_w still belong to the producing primitive, even
    // though a prim-boundary S_FLUSH already sees the NEXT prim's values.
    // db_late_q selects the pending bank's snapshot for the late-Z drain
    // path; early-Z keeps the live regs.  All draws now overlap (early-Z
    // bias is per-fragment during the scan; const-only bias is
    // draw-uniform; the slope chain is skipped for point/line/poly and
    // slope==0).
    wire [31:0] svz0_w = db_late_q ? ds_vz_q[pend_bank_q][0] : vz_q[0];
    wire [31:0] svz1_w = db_late_q ? ds_vz_q[pend_bank_q][1] : vz_q[1];
    wire [31:0] svz2_w = db_late_q ? ds_vz_q[pend_bank_q][2] : vz_q[2];
    wire [15:0] sspan_w = db_late_q ? ds_span_q[pend_bank_q] : span_w;
    wire [2:0] st_cmp_w = front_q ? dr_q.stencil_cmp : dr_q.stencil_cmp_b;
    wire [2:0] st_fail_w = front_q ? dr_q.stencil_fail : dr_q.stencil_fail_b;
    wire [2:0] st_pass_w = front_q ? dr_q.stencil_pass : dr_q.stencil_pass_b;
    wire [2:0] st_dfail_w = front_q ? dr_q.stencil_dfail : dr_q.stencil_dfail_b;
    wire [7:0] st_ref_w = front_q ? dr_q.stencil_ref : dr_q.stencil_ref_b;
    wire [7:0] st_cmask_w = front_q ? dr_q.stencil_cmp_mask
                                    : dr_q.stencil_cmp_mask_b;
    wire [7:0] st_wmask_w = front_q ? dr_q.stencil_wr_mask
                                    : dr_q.stencil_wr_mask_b;
    wire [1:0] l0_w = (poly_ln_q || poly_pt_q) ? le_q : 2'd0;
    wire [1:0] l1_w = (point_w || poly_pt_q) ? l0_w :
                      poly_ln_q ? ((le_q == 2'd2) ? 2'd0 : le_q + 2'd1) : 2'd1;
    function automatic logic [5:0] f_pi(input logic [1:0] t);
      if (clip_q)
        f_pi = (t == 2'd0) ? 6'd0 : {2'b0, cfan_q} + 6'(t) - 6'd1;
      else if (line_w)
        f_pi = p_q + 6'(t);
      else if (dr_q.topology == 8'd5)
        f_pi = (t == 2'd0) ? base_q : p_q + 6'(t);
      else if (dr_q.topology == 8'd4 && (p_q[0] ^ base_q[0]))
        f_pi = p_q + 6'(t == 2'd0 ? 0 : t == 2'd1 ? 2 : 1);
      else
        f_pi = p_q + 6'(t);
    endfunction

    // ---- G2b clip helpers -------------------------------------------------
    // 5-bit outcode for clip-space vertex p with guard product gw=4096*w:
    //   0 near z<0 | 1 far z>w | 2 w<1e-5 | 3 |x|>gw | 4 |y|>gw
    function automatic logic [4:0] f_oc(input logic [3:0][31:0] p,
                                        input logic [31:0] gw);
      f_oc[0] = !dr_q.depth_clamp && f_f32_lt(p[2], 32'h0);
      f_oc[1] = !dr_q.depth_clamp && f_f32_lt(p[3], p[2]);
      f_oc[2] = f_f32_lt(p[3], CLIP_EPS);
      f_oc[3] = f_f32_lt(gw, {1'b0, p[0][30:0]});
      f_oc[4] = f_f32_lt(gw, {1'b0, p[1][30:0]});
    endfunction

    // byte address of in-polygon vertex i's record: the first clip
    // plane reads the VS-out ring through the topology map; later
    // planes read the contiguous clip rings
    function automatic logic [63:0] f_crec(input logic [3:0] i);
      f_crec = {32'h0, cib_q} +
               64'(cmap_q ? f_pi(i[1:0]) : {2'b0, i}) * 64'(VSTR);
    endfunction

    // next violated plane after cpl_q (7 = none — mask bits above)
    function automatic logic [2:0] f_npl(input logic [4:0] m,
                                         input logic [2:0] c);
      f_npl = 3'd7;
      for (int p = 4; p >= 0; p--)
        if (p > int'(c) && m[p]) f_npl = 3'(p);
    endfunction
    // Lowest set plane.  7 means the mask is empty.
    function automatic logic [2:0] f_lpl(input logic [4:0] m);
      f_lpl = 3'd7;
      for (int p = 4; p >= 0; p--)
        if (m[p]) f_lpl = 3'(p);
    endfunction

    // prim done: advance the topo cursor, or the clip fan cursor while
    // fan tris of the clipped polygon remain (fan ends the whole prim)
    task automatic t_pd;
      if (clip_q) begin
        if (cfan_q >= cpn_q - 4'd2) begin
          clip_q <= 1'b0;
          if (dr_q.topology != 8'd3) p_q <= p_q + 6'd1;
          else                       p_q <= p_q + 6'd3;
        end else
          cfan_q <= cfan_q + 4'd1;
      end else begin
        // line list pairs step 2; triangle list steps 3; strips step 1
        if (dr_q.topology == 8'd1)      p_q <= p_q + 6'd2;
        else if (dr_q.topology == 8'd3) p_q <= p_q + 6'd3;
        else                            p_q <= p_q + 6'd1;
      end
    endtask

    // issue the float job latched in fp_*_q: raise the issue strobe
    // and enter the wait state in the same cycle (S_FPS is bypassed)
    task automatic t_fpgo;
      fp_iss_q <= 1'b1;
      st_q     <= S_FPW;
    endtask

    // RP4: enqueue one memory write behind the queue head.  Call only
    // while wq_ok holds (entry 1 free, or the head pops this cycle).
    // Slot pick: a pop with entry 1 valid promotes it to head, so the
    // new write takes entry 1; a pop with only the head valid empties
    // the queue and the write takes entry 0; no pop with a busy head
    // takes entry 1; an empty queue takes entry 0.  These assignments
    // follow the pop/ack block in the FSM always_ff, so on a pop+push
    // cycle the push wins the tail slot while the pop's head shift
    // still lands.
    task automatic t_wq(input logic [63:0] a, input logic [63:0] d,
                         input logic [7:0] s);
      if (wq_pop && wq_v_q[1]) begin
        wq_addr_q[1] <= a; wq_data_q[1] <= d; wq_strb_q[1] <= s;
        wq_v_q <= 2'b11;
      end else if (!wq_pop && wq_v_q[0]) begin
        wq_addr_q[1] <= a; wq_data_q[1] <= d; wq_strb_q[1] <= s;
        wq_v_q <= 2'b11;
      end else begin
        wq_addr_q[0] <= a; wq_data_q[0] <= d; wq_strb_q[0] <= s;
        wq_v_q <= 2'b01;
      end
    endtask

    // ---- combinational views -------------------------------------------
    // clear target: the depth attachment wins a depth-clear record,
    // else color attachment 0 (one CLEAR work per attachment)
    wire        clr_is_d = dr_q.da_valid;
    wire [31:0] clr_base = clr_is_d ? dr_q.da.base : dr_q.ca[0].base;
    wire [15:0] clr_w    = clr_is_d ? dr_q.da.w    : dr_q.ca[0].w;
    wire [15:0] clr_h    = clr_is_d ? dr_q.da.h    : dr_q.ca[0].h;
    wire [2:0]  clr_bpp  = (clr_is_d &&
                          dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM))
                         ? 3'd2 : 3'd4;
    wire [31:0] clr_pitch = f_pitch2(clr_w, clr_bpp);
    wire [31:0] clr_rowb = 32'(clr_w) * 32'(clr_bpp);
    // clear-target format legality (DRAW legality is per-attachment
    // in S_OP)
    wire        fmt_ok   = clr_is_d
                           ? f_dfmt_ok(dr_q.da.fmt)
                           : f_cfmt_ok(dr_q.ca[0].fmt);
    // pitch of the color attachment under the ROP cursor, and of the
    // depth attachment (early-Z)
    wire [31:0] cpitch_w = f_pitch2(dr_q.ca[at_q].w, 3'd4);
    wire [31:0] dpitch_w = f_pitch2(
        dr_q.da.w, dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                   ? 3'd2 : 3'd4);
    // current scan pixel center, 16.8 fixed
    wire signed [31:0] cpx = {16'(sx_q), 8'd0} + 32'd128;
    wire signed [31:0] cpy = {16'(sy_q), 8'd0} + 32'd128;
    // edge functions at the pixel center (edge opposite vertex k,
    // anchored at (k+1)%3 toward (k+2)%3):  E = d × (P - anchor),
    // interior-positive for the post-swap positive-area winding, so
    // E_k / area is exactly the barycentric weight of vertex k
    logic signed [63:0] ec [3];
    always_comb begin
      for (int k = 0; k < 3; k++)
        ec[k] = 64'(edx_q[k]) * (64'(cpy) - 64'(ey_q[k])) -
                64'(edy_q[k]) * (64'(cpx) - 64'(ex_q[k]));
    end
    wire in_tri = ((ec[0] > 64'sd0) || (ec[0] == 64'sd0 && tl_q[0])) &&
                  ((ec[1] > 64'sd0) || (ec[1] == 64'sd0 && tl_q[1])) &&
                  ((ec[2] > 64'sd0) || (ec[2] == 64'sd0 && tl_q[2]));
    // edge-function value at block lane l of the current 2x2 block
    // (the lane offsets shift the 16.8 sample point by one pixel)
    function automatic logic signed [63:0] f_le(
        input int k, input logic [1:0] l);
      f_le = ec[k] + (l[0] ? -(64'(edy_q[k]) <<< 8) : 64'sd0)
                   + (l[1] ?  (64'(edx_q[k]) <<< 8) : 64'sd0);
    endfunction
    // coverage test (same edge+top-left rule as in_tri) for lane l;
    // lanes outside the scissor-clamped bbox are never covered (the
    // even-aligned block may reach one pixel past the box)
    function automatic logic f_lcov(input logic [1:0] l);
      logic signed [63:0] e [3];
      logic [15:0] lx, ly;
      for (int k = 0; k < 3; k++) e[k] = f_le(k, l);
      lx = sx_q + {15'h0, l[0]};
      ly = sy_q + {15'h0, l[1]};
      f_lcov = ((e[0] > 64'sd0) || (e[0] == 64'sd0 && tl_q[0])) &&
               ((e[1] > 64'sd0) || (e[1] == 64'sd0 && tl_q[1])) &&
               ((e[2] > 64'sd0) || (e[2] == 64'sd0 && tl_q[2])) &&
               lx >= bx0_q && lx <= bx1_q &&
               ly >= by0_q && ly <= by1_q;
    endfunction
    // block coverage: 1 when any of the four 2x2 pixels is covered;
    // uncovered lanes of a hit block emit helper invocations
    wire blk_hit = f_lcov(2'd0) || f_lcov(2'd1) ||
                   f_lcov(2'd2) || f_lcov(2'd3);
    // signed area of the current vertex set (standard shoelace in
    // framebuffer coordinates)
    wire signed [63:0] area_w =
        (64'(vxi_q[1]) - 64'(vxi_q[0])) * (64'(vyi_q[2]) - 64'(vyi_q[0])) -
        (64'(vxi_q[2]) - 64'(vxi_q[0])) * (64'(vyi_q[1]) - 64'(vyi_q[0]));
    // Vulkan face orientation: the spec's signed area is the NEGATED
    // shoelace (a = -1/2 * sum x_i*y_{i+1} - x_{i+1}*y_i), so CCW
    // front-facing means area < 0 here and CW means area > 0.
    wire front_w = (area_q < 64'sd0) == dr_q.front_ccw;
    // vertex bbox (16.8 -> covered pixel centers)
    wire signed [31:0] xmin_w =
        vxi_q[0] < vxi_q[1]
        ? (vxi_q[0] < vxi_q[2] ? vxi_q[0] : vxi_q[2])
        : (vxi_q[1] < vxi_q[2] ? vxi_q[1] : vxi_q[2]);
    wire signed [31:0] xmax_w =
        vxi_q[0] > vxi_q[1]
        ? (vxi_q[0] > vxi_q[2] ? vxi_q[0] : vxi_q[2])
        : (vxi_q[1] > vxi_q[2] ? vxi_q[1] : vxi_q[2]);
    wire signed [31:0] ymin_w =
        vyi_q[0] < vyi_q[1]
        ? (vyi_q[0] < vyi_q[2] ? vyi_q[0] : vyi_q[2])
        : (vyi_q[1] < vyi_q[2] ? vyi_q[1] : vyi_q[2]);
    wire signed [31:0] ymax_w =
        vyi_q[0] > vyi_q[1]
        ? (vyi_q[0] > vyi_q[2] ? vyi_q[0] : vyi_q[2])
        : (vyi_q[1] > vyi_q[2] ? vyi_q[1] : vyi_q[2]);
    wire signed [31:0] vlo_x = xmin_w >>> 8;
    wire signed [31:0] vhi_x = (xmax_w - 32'sd128) >>> 8;
    wire signed [31:0] vlo_y = ymin_w >>> 8;
    wire signed [31:0] vhi_y = (ymax_w - 32'sd128) >>> 8;
    // scissor ∩ attachment clamp
    wire signed [31:0] slo_x = 32'({16'h0, dr_q.sc_x});
    wire signed [31:0] slo_y = 32'({16'h0, dr_q.sc_y});
    wire signed [31:0] shi_x = slo_x + 32'({16'h0, dr_q.sc_w}) - 32'sd1;
    wire signed [31:0] shi_y = slo_y + 32'({16'h0, dr_q.sc_h}) - 32'sd1;
    wire signed [31:0] whi_x = 32'({16'h0, dr_q.ca[0].w}) - 32'sd1;
    wire signed [31:0] whi_y = 32'({16'h0, dr_q.ca[0].h}) - 32'sd1;
    wire signed [31:0] mxlo_x = vlo_x > slo_x ? vlo_x : slo_x;
    wire signed [31:0] mxhi_x = vhi_x < shi_x ? vhi_x : shi_x;
    wire signed [31:0] mxlo_y = vlo_y > slo_y ? vlo_y : slo_y;
    wire signed [31:0] mxhi_y = vhi_y < shi_y ? vhi_y : shi_y;
    wire signed [31:0] blo_x = mxlo_x < 0 ? 0 : mxlo_x;
    wire signed [31:0] blo_y = mxlo_y < 0 ? 0 : mxlo_y;
    wire signed [31:0] bhi_x = mxhi_x > whi_x ? whi_x : mxhi_x;
    wire signed [31:0] bhi_y = mxhi_y > whi_y ? whi_y : mxhi_y;
    wire              bbox_empty = bhi_x < blo_x || bhi_y < blo_y;
    // current attribute fields
    wire [7:0]  a_fmt = dr_q.attr[a_q].fmt;
    wire [3:0]  a_bnd = dr_q.attr[a_q].binding;
    wire [31:0] a_off = 32'({18'h0, dr_q.attr[a_q].offset});
    wire        attr_ok = dr_q.attr[a_q].valid && f_asz(a_fmt) != 5'd0;
    // gather-range bounds check (signed: a negative vertex index must
    // not wrap below the buffer base)
    wire        g_oob = $signed(caddr_q) < $signed(gbase_q) ||
                        caddr_q + {27'h0, csz_q} > gbase_q + gsize_q;
    // fragment pixel coordinates (fsxy widened to 16+16); the deferred
    // drain reads the pending batch's bank (pend_bank_q), not the bank
    // frag production is currently writing (wr_bank_q).
    wire [15:0] fr_px = fsxy_q[pend_bank_q][r_q][15:0];
    wire [15:0] fr_py = fsxy_q[pend_bank_q][r_q][31:16];
    // frag-in record base for the bank frag production is writing —
    // used by the four t_wq FSI record writes and by the wave launch.
    wire [31:0] fsi_wr_w = wr_bank_q ? fsi1_q : fsi_q;
    // ROP encode: comp c -> byte (sRGB LUT on rgb comps of sRGB
    // formats; linear elsewhere)
    function automatic logic [7:0] f_enc8(input logic [7:0] fmt,
                                          input logic [1:0] c,
                                          input logic [31:0] f);
      // T3 R8G8B8A8_UINT: the value is an integer (shader uvec4 output
      // or VkClearColorValue.uint32) — the attachment keeps its low 8
      // bits; no fp conversion, and no blend (integer formats carry no
      // COLOR_ATTACHMENT_BLEND, so blendEnable is invalid usage)
      if (fmt == 8'(APU_IMG_FMT_R8G8B8A8_UINT))
        return f[7:0];
      if (f_is_srgb(fmt) && c != 2'd3)
        return APU_SRGB_ENC[f_f32_u12(f)];
      return f_f32_u8(f);
    endfunction
    // packed dst-byte position for comp c under the attachment's
    // channel order
    function automatic logic [1:0] f_cbyte(input logic [7:0] fmt,
                                           input logic [1:0] c);
      if (f_is_bgr(fmt))
        return (c == 2'd0) ? 2'd2 : (c == 2'd1) ? 2'd1
               : (c == 2'd2) ? 2'd0 : 2'd3;
      return c;
    endfunction
    // RP3 dst decode: the per-channel I2F operand and scale factor,
    // identical to the values the serial S_ROP_DI/S_ROP_DM states used.
    function automatic logic [31:0] f_dec_i2f(input logic [1:0] ch);
      f_dec_i2f = (f_is_srgb(dr_q.ca[at_q].fmt) && ch != 2'd3)
        ? {16'h0, APU_SRGB_TO_LIN[
            mp_res_q[32*fr_px[0] +
                     8*f_cbyte(dr_q.ca[at_q].fmt, ch) +: 8]]}
        : {24'h0, mp_res_q[32*fr_px[0] +
                          8*f_cbyte(dr_q.ca[at_q].fmt, ch) +: 8]};
    endfunction
    function automatic logic [31:0] f_dec_scale(input logic [1:0] ch);
      f_dec_scale = (f_is_srgb(dr_q.ca[at_q].fmt) && ch != 2'd3)
                  ? 32'h38008001                    // *1/65535
                  : 32'h3B808081;                   // *1/255
    endfunction
    wire [7:0] rop_b0 = f_enc8(dr_q.ca[at_q].fmt, 2'd0, res_q[0]);
    wire [7:0] rop_b1 = f_enc8(dr_q.ca[at_q].fmt, 2'd1, res_q[1]);
    wire [7:0] rop_b2 = f_enc8(dr_q.ca[at_q].fmt, 2'd2, res_q[2]);
    wire [7:0] rop_b3 = f_enc8(dr_q.ca[at_q].fmt, 2'd3, res_q[3]);
    wire [31:0] rop_pix = f_is_bgr(dr_q.ca[at_q].fmt)
        ? {rop_b3, rop_b0, rop_b1, rop_b2}
        : {rop_b3, rop_b2, rop_b1, rop_b0};
    // VkLogicOp on the encoded attachment bytes.  Blend is not used.
    function automatic logic [7:0] f_lop(input logic [3:0] op,
                                         input logic [7:0] s,
                                         input logic [7:0] d);
      case (op)
        4'd0:  f_lop = 8'h00;
        4'd1:  f_lop = s & d;
        4'd2:  f_lop = s & ~d;
        4'd3:  f_lop = s;
        4'd4:  f_lop = ~s & d;
        4'd5:  f_lop = d;
        4'd6:  f_lop = s ^ d;
        4'd7:  f_lop = s | d;
        4'd8:  f_lop = ~(s | d);
        4'd9:  f_lop = ~(s ^ d);
        4'd10: f_lop = ~d;
        4'd11: f_lop = s | ~d;
        4'd12: f_lop = ~s;
        4'd13: f_lop = ~s | d;
        4'd14: f_lop = ~(s & d);
        default: f_lop = 8'hFF;
      endcase
    endfunction
    function automatic logic [31:0] f_lop_pix(
        input logic [7:0] fmt, input logic [3:0] op,
        input logic [31:0] s0, input logic [31:0] s1,
        input logic [31:0] s2, input logic [31:0] s3,
        input logic [31:0] dstw);
      logic [31:0] src [4];
      logic [7:0]  sb, db;
      logic [1:0]  lane;
      src[0] = s0; src[1] = s1; src[2] = s2; src[3] = s3;
      f_lop_pix = dstw;
      for (int c = 0; c < 4; c++) begin
        lane = f_cbyte(fmt, 2'(c));
        sb = f_enc8(fmt, 2'(c), src[c]);
        db = dstw[8*lane +: 8];
        f_lop_pix[8*lane +: 8] = f_lop(op, sb, db);
      end
    endfunction
    logic [31:0] lop_pix_q;
    // byte strobes for the pixel under the ROP cursor
    wire [7:0] rop_strb = {4'h0, dr_q.blend[at_q].mask}
                          << {fr_px[0], 2'b00};
    // Window depth.  Clamp enable uses the viewport range and the
    // near/far planes are not clip planes.  Otherwise the value is
    // held to [0,1], which is what the unclamped fixed path writes.
    function automatic logic [31:0] f_zcl(input logic [31:0] z);
      logic [31:0] lo, hi;
      lo = dr_q.depth_clamp ? dr_q.vp.minz : 32'h0;
      hi = dr_q.depth_clamp ? dr_q.vp.maxz : 32'h3F800000;
      if (f_f32_lt(z, lo)) f_zcl = lo;
      else if (f_f32_lt(hi, z)) f_zcl = hi;
      else f_zcl = z;
    endfunction
    wire [31:0] zc_w = f_zcl(fz_q);
    wire [31:0] lzc_w = f_zcl(lz_q);
    // blend-state field selects for the comp under the blend cursor
    wire [4:0] bsf_w = (c_q[1:0] == 2'd3) ? dr_q.blend[at_q].src_a
                                        : dr_q.blend[at_q].src_c;
    wire [4:0] bdf_w = (c_q[1:0] == 2'd3) ? dr_q.blend[at_q].dst_a
                                        : dr_q.blend[at_q].dst_c;
    wire [2:0] bop_w = (c_q[1:0] == 2'd3) ? dr_q.blend[at_q].op_a
                                        : dr_q.blend[at_q].op_c;

    assign busy_o = st_q != S_IDLE;
    // R3: publish the record/clip carve base + valid for apmem's
    // tc_sram fast-path (vsi_q is the lowest OFF_* buffer).
    assign scratch_base_o   = vsi_q;
    assign scratch_valid_o  = scr_ok_q;
    if (PerfCountersEn) begin : gen_stat
      logic [31:0] n_busy_q, n_prim_q, n_pix_q;
      logic [31:0] q_vtx_q, q_fs_q, q_occ_q;
      logic        in_wr_q, in_vsi_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          n_busy_q <= '0; n_prim_q <= '0; n_pix_q <= '0;
          q_vtx_q <= '0; q_fs_q <= '0; q_occ_q <= '0;
          in_wr_q <= 1'b0; in_vsi_q <= 1'b0;
        end else begin
          in_wr_q  <= (st_q == S_ROP_WR);
          in_vsi_q <= (st_q == S_VS_ISS);
          if (st_q != S_IDLE) n_busy_q <= n_busy_q + 32'd1;
          // one count per primitive at assembly: S_PR_W is a
          // single-cycle state every point/line/triangle passes once
          // after its vertices are fetched, before outcode, clip and
          // cull — the primitives-generated point.  Clip-fan triangles
          // re-enter it with clip_q set and belong to the primitive
          // that produced the fan, so they are not counted again.
          if (st_q == S_PR_W && !clip_q)
            n_prim_q <= n_prim_q + 32'd1;
          if (st_q == S_ROP_WR && !in_wr_q)
            n_pix_q <= n_pix_q + 32'd1;
          // §3a query counters (model vn_transfer_executor.py:297):
          // IA-vertices and VS-invocations both equal the fetched
          // vertex-record count — nv_q per accepted VS batch, counted
          // once on S_VS_ISS entry (the state is held until the wave
          // is granted, so edge-detect, not level).  FS-invocations
          // count every recorded fragment lane (helpers included, as
          // fs.total does); occlusion counts only non-helper lanes —
          // the covered samples.  Fragment record is the single
          // S_F_LSET pass at lc_q==8.
          // TP5: under reuse the wave shades only the packed misses, so
          // VS-invocations (and the assembled input records they share
          // this counter with) equal mi_q, not the submitted nv_q.
          if (st_q == S_VS_ISS && !in_vsi_q)
            q_vtx_q <= q_vtx_q + {26'h0, reuse_en ? mi_q : nv_q};
          if (st_q == S_F_LSET && lc_q == 4'd8) begin
            q_fs_q  <= q_fs_q + 32'd1;
            if (!help_q) q_occ_q <= q_occ_q + 32'd1;
          end
        end
      end
      assign stat_o = {n_pix_q, n_prim_q, n_busy_q};
      // {fs_inv, occ, ia_prim, ia_vtx}; VS-invocations reuse ia_vtx
      assign qry_stat_o = {q_fs_q, q_occ_q, n_prim_q, q_vtx_q};
    end else begin : gen_nostat
      assign stat_o = '0;
      assign qry_stat_o = '0;
    end
    // ---- FP0 cycle classes (performance-area-scalability.md §9.3) -------
    // PerfClassEn: one busy-cycle counter per frame stage, read
    // hierarchically by the benches (no port; 0 = no cells).  The shared
    // sequencer states (S_MPW, S_FPS, S_FPW) are charged to the class of
    // the state that entered them and are also counted on their own
    // axis: memory-wait cycles, accepted memory requests, float-unit
    // wait cycles, accepted float-unit jobs.  The classes partition
    // busy time: their sum equals stat_o's busy count.
    if (PerfClassEn) begin : gen_cls
      localparam int unsigned NCLS = 11;
      typedef enum logic [3:0] {
        CL_CTL, CL_CLEAR, CL_GATHER, CL_VSWAIT, CL_SETUP, CL_CLIP,
        CL_SCAN, CL_INTERP, CL_DEPTH, CL_FSWAIT, CL_MERGE
      } cls_e;
      function automatic cls_e f_cls(input st_e s);
        if (s inside {S_CLR_X, S_CLR_N}) return CL_CLEAR;
        if (s inside {S_GA_ISET, S_GA_IBX, S_GA_ATTR, S_GA_RD, S_GA_CVT,
                      S_GA_U8I, S_GA_U8M, S_GA_U8S, S_GA_W0, S_GA_W1,
                      S_GA_S8A, S_GA_S8B}) return CL_GATHER;
        if (s inside {S_VS_ISS, S_VS_WAIT}) return CL_VSWAIT;
        if (s inside {S_PR_I0, S_PR_I0B, S_PR_I1, S_PR_I2, S_PR_W,
                      S_T0R, S_T1R, S_T2R,
                      S_T0X, S_T0Y, S_T0Z, S_T1X, S_T1Y, S_T1Z,
                      S_T2X, S_T2Y, S_T2Z,
                      S_T0SA, S_T0SF, S_T0SM, S_T0SC, S_T0YA, S_T0YF,
                      S_T0YM, S_T0YC, S_T0ZF,
                      S_T1SA, S_T1SF, S_T1SM, S_T1SC, S_T1YA, S_T1YF,
                      S_T1YM, S_T1YC, S_T1ZF,
                      S_T2SA, S_T2SF, S_T2SM, S_T2SC, S_T2YA, S_T2YF,
                      S_T2YM, S_T2YC, S_T2ZF,
                      S_PR_AREA, S_PR_SHF, S_PR_BBX, S_PR_RCI, S_PR_RCD,
                      S_PR_VF, S_PR_VF2,
                      S_LN_VF, S_LN_VF2, S_LN_VF3, S_LN_INIT})
          return CL_SETUP;
        if (s inside {S_OC_G1, S_OC_G2, S_OC_G3, S_OC,
                      S_CP_RP0, S_CP_RP1, S_CP_RP2, S_CP_DD, S_CP_DG,
                      S_CP_EDGE, S_CP_ENX, S_CP_IT0, S_CP_IT1, S_CP_IT2,
                      S_CP_ILP, S_CP_IR0, S_CP_IR1, S_CP_IR2, S_CP_IR3,
                      S_CP_IS, S_CP_IF, S_CP_IW2, S_CP_IW3, S_CP_IW4,
                      S_CP_CB0, S_CP_CB1, S_CP_CBL, S_CP_CBR, S_CP_CBQ,
                      S_CP_CBW, S_CP_PDN,
                      S_LC_D0, S_LC_DG, S_LC_DD, S_LC_T0, S_LC_T1,
                      S_LC_TL, S_LC_C0, S_LC_C1, S_LC_C2, S_LC_N})
          return CL_CLIP;
        if (s inside {S_SCAN, S_LN_PIX, S_LN_STEP}) return CL_SCAN;
        if (s inside {S_F_LE0, S_F_LE1, S_F_LE2, S_F_L0, S_F_L1, S_F_L2,
                      S_F_P0, S_F_P1, S_F_P2, S_F_S0, S_F_S1, S_F_RD,
                      S_F_Z1, S_F_Z2, S_F_Z3,
                      S_F_PXI, S_F_PXM, S_F_PYI, S_F_PYM, S_F_PY2,
                      S_F_W0, S_F_W1, S_F_LSET,
                      S_F_V0, S_F_V1, S_F_V2, S_F_VS, S_F_VN,
                      S_F_VW0, S_F_VW1, S_F_LNEXT}) return CL_INTERP;
        if (s inside {S_DZ_RD, S_DZ_DI, S_DZ_DM, S_DZ_C2, S_DZ_WR,
                      S_DB0, S_DBCR, S_DB1, S_DB1B, S_DB2,
                      S_DS0, S_DS1, S_DS2, S_DS3, S_DS4, S_DS5, S_DS6,
                      S_ROP_F8, S_ROP_LRD, S_ROP_LDI, S_ROP_LDM,
                      S_ROP_LC, S_ROP_LWR}) return CL_DEPTH;
        if (s inside {S_FLUSH, S_FS_WAIT, S_DGATE}) return CL_FSWAIT;
        if (s inside {S_ROP_R0, S_ROP_R1, S_ROP_R2,
                      S_ROP_DI, S_ROP_DM, S_ROP_DS,
                      S_BL_SAT, S_BL_MM, S_BL_F1, S_BL_F1B,
                      S_BL_F2B, S_BL_M2, S_BL_OP, S_BL_ST,
                      S_ROP_WR, S_ROP_NX, S_ROP_LOP}) return CL_MERGE;
        return CL_CTL;
      endfunction
      cls_e                  cls_q, cls_w;
      logic [NCLS-1:0][31:0] cyc_q;
      logic [31:0]           mpw_q, mpn_q, fpw_q, fpn_q;
      logic [31:0]           dvw_q, wqw_q;   // FP6 diag: div-tail / wq-stall
      assign cls_w = (st_q inside {S_MPW, S_FPS, S_FPW}) ? cls_q
                                                         : f_cls(st_q);
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          cls_q <= CL_CTL; cyc_q <= '0;
          mpw_q <= '0; mpn_q <= '0; fpw_q <= '0; fpn_q <= '0;
          dvw_q <= '0; wqw_q <= '0;
        end else begin
          cls_q <= cls_w;
          if (st_q != S_IDLE) cyc_q[cls_w] <= cyc_q[cls_w] + 32'd1;
          if (st_q == S_MPW) mpw_q <= mpw_q + 32'd1;
          if (mp_req_valid_o && mp_req_ready_i) mpn_q <= mpn_q + 32'd1;
          if (st_q inside {S_FPS, S_FPW}) fpw_q <= fpw_q + 32'd1;
          // FP6-opt(i): count fp OPS not issue-cycles — the shared
          // i_fma/i_dsq/i_cvt path is mutually exclusive via fp_kind_q
          // (<=1 op/cycle) but lane-B i_fma2 issues in parallel, so a
          // V0 pair-step is 2 ops.  Sum the per-lane accept pulses.
          fpn_q <= fpn_q + {31'd0, (fma_iv  && fma_ir)}
                        + {31'd0,  fma2_iv}
                        + {31'd0, (dq_iv   && dq_ir)}
                        + {31'd0, (cv_iv   && cv_ir)};
          // FP6 diagnostics: S_F_LE0 ik_q>=14 is the post-DIV window
          // (divider result wait); S_F_VW0/VW1 !wq_ok is frag-write
          // queue back-pressure.  Both inside CL_INTERP already.
          if (st_q == S_F_LE0 && ik_q >= 5'd14) dvw_q <= dvw_q + 32'd1;
          if (st_q inside {S_F_VW0, S_F_VW1} && !wq_ok)
            wqw_q <= wqw_q + 32'd1;
        end
      end
    end
    assign work_ready_o = st_q == S_IDLE;
    // RP4: the port serves the write-behind queue head whenever one
    // is valid — queue writes always take priority over the S_MPW
    // request, which only reaches the port once the queue is empty.
    // Queue entries are writes only, so we is constant 1 on that arm.
    assign mp_req_valid_o = wq_v_q[0] ? !wq_acked_q
                                    : (st_q == S_MPW && !mp_acked_q);
    assign mp_req_o = wq_v_q[0]
                     ? '{dom: 1'b1, we: 1'b1, addr: wq_addr_q[0],
                        wdata: wq_data_q[0], wstrb: wq_strb_q[0]}
                     : '{dom: 1'b1, we: mp_we_q, addr: mp_addr_q,
                        wdata: mp_data_q, wstrb: mp_strb_q};
    // head pops on its write response (accepted => acked); a push is
    // legal while entry 1 is free or the head pops this same cycle
    assign wq_pop = wq_v_q[0] && wq_acked_q && mp_rsp_valid_i;
    assign wq_ok  = !wq_v_q[1] || wq_pop;
    assign pg_req_valid_o = st_q == S_ALLOC;
    // TP5: reserve the 64 KiB record carve PLUS the isvtx_w vertex-cache
    // window appended at scratch_base+64 KiB, so vgpages cannot hand the
    // vertex window to another ALLOC_PRIV client.  VtxCacheEntries=0 ->
    // VTX_WIN_B=0 -> identical 64 KiB request (bit-identical).
    assign pg_req_o = '{op: APU_VGPAGES_OP_ALLOC_PRIV, base: '0,
                       excl_hi: '0,
                       bytes: 32'(APU_RAST_SCRATCH_BYTES + VTX_WIN_B)};
    assign pg_cpl_ready_o = st_q == S_ALLOC_W;
    // shv_q: registered work-valid — the ctype/imm/slot payload is
    // written in the same state entry, so valid is delayed one cycle;
    // a peer that is ready on entry never latches a stale record.
    logic           shv_q;
    assign sh_work_valid_o = shv_q;
    assign sh_desc_o = desc_q;
    assign sh_push_n_o = push_n_q;
    assign sh_push_o = push_q;

    // ---- the FSM ---------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        st_q <= S_IDLE;
        dr_q <= '0; desc_q <= '0; push_n_q <= '0; push_q <= '0;
        wid_q <= '0; robust_q <= '0; code_q <= '0;
        scr_ok_q <= 1'b0;
        vsi_q <= '0; vso_q <= '0; fsi_q <= '0; fso_q <= '0;
        mp_acked_q <= 1'b0; mp_we_q <= 1'b0; mp_addr_q <= '0;
        mp_data_q <= '0; mp_strb_q <= '0; mp_res_q <= '0;
        mp_ret_q <= S_IDLE;
        wq_v_q <= 2'b00; wq_acked_q <= 1'b0;
        wq_addr_q[0] <= '0; wq_addr_q[1] <= '0;
        wq_data_q[0] <= '0; wq_data_q[1] <= '0;
        wq_strb_q[0] <= '0; wq_strb_q[1] <= '0;
        fp_kind_q <= '0; fp_o_q <= '0; fp_mod_q <= 1'b0;
        fp_a_q <= '0; fp_b_q <= '0; fp_c_q <= '0; fp_res_q <= '0;
        fp2_o_q <= '0; fp2_mod_q <= 1'b0;
        fp2_a_q <= '0; fp2_b_q <= '0; fp2_c_q <= '0; fp2_iss_q <= 1'b0;
        fp_ret_q <= S_IDLE; fp_iss_q <= 1'b0;
        ik_q <= '0; rsd_q <= 1'b0; rdiv_q <= 1'b0;
        clr_pix_q <= '0; cy_q <= '0; cx_q <= '0;
        vphw_q <= '0; vphh_q <= '0; vpdz_q <= '0;
        inst_q <= '0; bat_q <= '0; nv_q <= '0; j_q <= '0; a_q <= '0;
        i_q <= '0; t_q <= '0; ib_i <= '0; win_q <= '0; wn_q <= '0;
        caddr_q <= '0; gbase_q <= '0; gsize_q <= '0; csz_q <= '0;
        gret_q <= S_IDLE;
        conv_q <= '0; c_q <= '0;
        for (int v = 0; v < 3; v++) begin
          pos_q[v] <= '0; vrw_q[v] <= '0; vz_q[v] <= '0;
          vxi_q[v] <= '0; vyi_q[v] <= '0;
          vnd_q[v][0] <= '0; vnd_q[v][1] <= '0; vnd_q[v][2] <= '0;
          ex_q[v] <= '0; ey_q[v] <= '0; edx_q[v] <= '0; edy_q[v] <= '0;
          e_q[v] <= '0; lam_q[v] <= '0; pv_q[v] <= '0;
        end
        tl_q <= '0; area_q <= '0; shf_q <= '0; rcpa_q <= '0;
        vsw_q <= 1'b0;
        bx0_q <= '0; bx1_q <= '0; by0_q <= '0; by1_q <= '0;
        sx_q <= '0; sy_q <= '0; p_q <= '0; base_q <= '0;
        brk_q <= '0; ln_q <= 1'b0; poly_ln_q <= 1'b0; poly_pt_q <= 1'b0;
        // TP5 reuse state
        mi_q <= '0; vt_w <= '0; vt_m <= '0; vt_j <= '0; vt_e <= '0;
        vt_os <= '0; vt_ib <= '0; vt_gen <= '0;
        db_done_q <= 1'b0;
        for (int b = 0; b < 2; b++) begin
          for (int i = 0; i < 3; i++) ds_vz_q[b][i] <= '0;
          ds_span_q[b] <= '0;
        end
        f_q <= '0; nf_q <= '0;
        wr_bank_q <= 1'b0; pend_bank_q <= 1'b0; pend_v_q <= 1'b0;
        dnf_q <= '0; dret_q <= S_IDLE;
        fsi1_q <= '0;
        rs_q <= '0; fz_q <= '0; lc_q <= '0;
        lz_q <= '0; lzdone_q <= 1'b0; bat_front_q <= 1'b0;
        for (int i = 0; i < FSB; i++) begin
          for (int b = 0; b < 2; b++) begin
            fsxy_q[b][i] <= '0; fs_help_q[b][i] <= 1'b0; fsz_q[b][i] <= '0;
          end
        end
        for (int v = 0; v < 3; v++)
          for (int l = 0; l < 8; l++)
            for (int c = 0; c < 4; c++) var_q[v][l][c] <= '0;
        varm_q <= '0;
        lane_q <= '0; help_q <= 1'b0; px_q <= '0; py_q <= '0;
        front_q <= 1'b0;
        for (int v = 0; v < 3; v++) begin
          oc_q[v] <= '0; gw_q[v] <= '0;
        end
        cpm_q <= '0; cpl_q <= '0; cn_q <= '0; co_q <= '0;
        ce_q <= '0; ceb_q <= '0; cib_q <= '0; cob_q <= '0;
        clp_q <= '0; ctp_q <= '0;
        cmap_q <= 1'b0; cslot_q <= 1'b0; cemitb_q <= 1'b0;
        for (int v = 0; v < 9; v++) begin
          cpos_q[v] <= '{default: '0};
          cdis_q[v] <= '0;
        end
        cin_q <= '0;
        cva_q <= '{default: '0}; cvb_q <= '{default: '0};
        ctt_q <= '0; clip_q <= 1'b0; cfan_q <= '0; cpn_q <= '0;
        dz_q <= '0;
        r_q <= '0; at_q <= '0;
        src_q <= '0; dst_q <= '0; res_q <= '0;
        sf_q <= '0; df_q <= '0; bm1_q <= '0; bm2_q <= '0; omd3_q <= '0;
        dd_q <= '0; dcv_q <= '0;
        flr_q <= S_IDLE;
        shd_q <= 1'b0; shdp_q <= '0; shv_q <= 1'b0;
        fshd_q <= 1'b0; fsdp_q <= '0;
        done_o <= 1'b0; done_pl_o <= '0;
      end else begin
        done_o <= 1'b0;
        if (sh_done_i) begin
          // FP6: route graphics-wave dones by pseudo-ctype so a pending
          // FS frag-batch wave and an in-flight VS wave never collide on
          // the single done port (the overlap makes both able to be
          // outstanding at once).
          if (sh_done_pl_i.work_id == APU_SH_WORK_FS) begin
            fshd_q <= 1'b1; fsdp_q <= sh_done_pl_i;
          end else begin
            shd_q <= 1'b1; shdp_q <= sh_done_pl_i;
          end
        end
        // RP4 write-behind queue sequencing: pop the accepted head on
        // its response (entry 1, if valid, becomes the new head and
        // must be accepted afresh), else mark the head accepted when
        // the port takes it.  t_wq calls inside the case below issue
        // their assignments after this block, so a same-cycle push
        // overrides the tail slots and valid bits while the pop's
        // head shift still lands.
        if (wq_pop) begin
          wq_v_q <= {1'b0, wq_v_q[1]};
          wq_addr_q[0] <= wq_addr_q[1];
          wq_data_q[0] <= wq_data_q[1];
          wq_strb_q[0] <= wq_strb_q[1];
          wq_acked_q <= 1'b0;
        end else if (wq_v_q[0] && !wq_acked_q && mp_req_ready_i)
          wq_acked_q <= 1'b1;
        unique case (st_q)
          // ============================================================
          S_IDLE: begin
            if (work_valid_i) begin
              dr_q <= rd_i;
              desc_q <= desc_i;
              push_n_q <= push_n_i;
              push_q <= push_i;
              wid_q <= wid_q + 32'd1;
              robust_q <= '0;
              shd_q <= 1'b0; fshd_q <= 1'b0;
              // TP5: a fresh generation per DRAW invalidates every cache
              // entry from prior draws (same resolved index in a new
              // vertex buffer/shader must miss).  CLEAR ops don't gather
              // vertices; they harmlessly burn a generation value.
              if (rd_i.op == APU_RAST_OP_DRAW)
                vt_gen <= vt_gen + 31'd1;
              if (!scr_ok_q) st_q <= S_ALLOC;
              else           st_q <= S_OP;
            end
          end
          // ---- one-time private scratch allocation ---------------------
          S_ALLOC:
            if (pg_req_ready_i) st_q <= S_ALLOC_W;
          S_ALLOC_W:
            if (pg_cpl_valid_i) begin
              if (pg_cpl_i.status == APU_VGPAGES_OK) begin
                scr_ok_q <= 1'b1;
                // R3 note: the on-chip record store (apmem tc_sram
                // fast-path) is implemented but NOT yet activated —
                // the carve stays on its dynamic ALLOC_PRIV base until
                // the record aperture window is plumbed to apmem (the
                // fixed high-window re-point was reverted: it forced
                // every bypass-apmem memory model to cover a 128 MiB-
                // scale aperture offset the small unit benches cannot
                // afford).  See .cache/apu-perf/r3-brief.md.
                vsi_q <= pg_cpl_i.base + 32'(OFF_VSI);
                vso_q <= pg_cpl_i.base + 32'(OFF_VSO);
                fsi_q <= pg_cpl_i.base + 32'(OFF_FSI);
                fsi1_q <= pg_cpl_i.base + 32'(OFF_FSI1);
                fso_q <= pg_cpl_i.base + 32'(OFF_FSO);
                clp_q <= pg_cpl_i.base + 32'(OFF_CLP);
                ctp_q <= pg_cpl_i.base + 32'(OFF_CTP);
                st_q <= S_OP;
              end else begin
                code_q <= APU_SH_DONE_FAULT;
                st_q <= S_FIN_BAD;
              end
            end
          // ---- opcode dispatch -----------------------------------------
          S_OP: begin
            unique case (dr_q.op)
              APU_RAST_OP_CLEAR: begin
                if ((!dr_q.da_valid && !dr_q.ca_valid[0]) ||
                    !fmt_ok || clr_w == 16'd0 || clr_h == 16'd0)
                  begin code_q <= APU_SH_DONE_UNSUPPORTED;
                        st_q <= S_FIN_BAD; end
                else begin
                  // clr_pix is the two-pixel write pattern: an encoded
                  // color for 4 B formats, {u16,u16} for D16
                  if (clr_is_d)
                    clr_pix_q <=
                      dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                      ? {2{f_f32_u16(dr_q.clear_color[0])}}
                      : dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT)
                      // stencil clear byte = clear_color[1][7:0] (the
                      // VkClearDepthStencilValue.stencil wire slot); D32/
                      // D16 never reach this branch.
                      ? {dr_q.clear_color[1][7:0],
                         f_f32_u24(dr_q.clear_color[0])}
                      : dr_q.clear_color[0];
                  else
                    clr_pix_q <=
                      f_is_bgr(dr_q.ca[0].fmt)
                      ? {f_enc8(dr_q.ca[0].fmt, 2'd3,
                                dr_q.clear_color[3]),
                         f_enc8(dr_q.ca[0].fmt, 2'd0,
                                dr_q.clear_color[0]),
                         f_enc8(dr_q.ca[0].fmt, 2'd1,
                                dr_q.clear_color[1]),
                         f_enc8(dr_q.ca[0].fmt, 2'd2,
                                dr_q.clear_color[2])}
                      : {f_enc8(dr_q.ca[0].fmt, 2'd3,
                                dr_q.clear_color[3]),
                         f_enc8(dr_q.ca[0].fmt, 2'd2,
                                dr_q.clear_color[2]),
                         f_enc8(dr_q.ca[0].fmt, 2'd1,
                                dr_q.clear_color[1]),
                         f_enc8(dr_q.ca[0].fmt, 2'd0,
                                dr_q.clear_color[0])};
                  cy_q <= '0; cx_q <= '0;
                  st_q <= S_CLR_X;
                end
              end
              APU_RAST_OP_DRAW: begin
                // list topologies batch (S_DR_BATCH); strips and fans
                // carry vertices across primitives and stay one batch
                if ((dr_q.topology > 8'd5) ||
                    (!topo_list_w &&
                     dr_q.vertex_count > 32'(VSB)) ||
                    dr_q.ib_type > 2'd2 ||
                    (dr_q.ib_type != 2'd0 && dr_q.ib_size == 32'd0) ||
                    (dr_q.ca_valid == 4'h0 && !dr_q.da_valid) ||
                    (dr_q.ca_valid[0] && !f_cfmt_ok(dr_q.ca[0].fmt)) ||
                    (dr_q.ca_valid[1] && !f_cfmt_ok(dr_q.ca[1].fmt)) ||
                    (dr_q.ca_valid[2] && !f_cfmt_ok(dr_q.ca[2].fmt)) ||
                    (dr_q.ca_valid[3] && !f_cfmt_ok(dr_q.ca[3].fmt)) ||
                    (dr_q.da_valid && !f_dfmt_ok(dr_q.da.fmt)) ||
                    // T3: blending an integer attachment is invalid
                    // usage — refuse rather than blend raw bits as fp
                    (dr_q.ca_valid[0] && dr_q.blend[0].en &&
                     dr_q.ca[0].fmt == 8'(APU_IMG_FMT_R8G8B8A8_UINT)) ||
                    (dr_q.ca_valid[1] && dr_q.blend[1].en &&
                     dr_q.ca[1].fmt == 8'(APU_IMG_FMT_R8G8B8A8_UINT)) ||
                    (dr_q.ca_valid[2] && dr_q.blend[2].en &&
                     dr_q.ca[2].fmt == 8'(APU_IMG_FMT_R8G8B8A8_UINT)) ||
                    (dr_q.ca_valid[3] && dr_q.blend[3].en &&
                     dr_q.ca[3].fmt == 8'(APU_IMG_FMT_R8G8B8A8_UINT)) ||
                    (dr_q.ca_valid[0] && dr_q.blend[0].en &&
                     (dr_q.blend[0].src_c > 5'd14 ||
                      dr_q.blend[0].dst_c > 5'd14 ||
                      dr_q.blend[0].src_a > 5'd14 ||
                      dr_q.blend[0].dst_a > 5'd14 ||
                      dr_q.blend[0].op_c > 3'd4 ||
                      dr_q.blend[0].op_a > 3'd4)) ||
                    (dr_q.ca_valid[1] && dr_q.blend[1].en &&
                     (dr_q.blend[1].src_c > 5'd14 ||
                      dr_q.blend[1].dst_c > 5'd14 ||
                      dr_q.blend[1].src_a > 5'd14 ||
                      dr_q.blend[1].dst_a > 5'd14 ||
                      dr_q.blend[1].op_c > 3'd4 ||
                      dr_q.blend[1].op_a > 3'd4)) ||
                    (dr_q.ca_valid[2] && dr_q.blend[2].en &&
                     (dr_q.blend[2].src_c > 5'd14 ||
                      dr_q.blend[2].dst_c > 5'd14 ||
                      dr_q.blend[2].src_a > 5'd14 ||
                      dr_q.blend[2].dst_a > 5'd14 ||
                      dr_q.blend[2].op_c > 3'd4 ||
                      dr_q.blend[2].op_a > 3'd4)) ||
                    (dr_q.ca_valid[3] && dr_q.blend[3].en &&
                     (dr_q.blend[3].src_c > 5'd14 ||
                      dr_q.blend[3].dst_c > 5'd14 ||
                      dr_q.blend[3].src_a > 5'd14 ||
                      dr_q.blend[3].dst_a > 5'd14 ||
                      dr_q.blend[3].op_c > 3'd4 ||
                      dr_q.blend[3].op_a > 3'd4))) begin
                  code_q <= APU_SH_DONE_UNSUPPORTED;
                  st_q <= S_FIN_BAD;
                end else if (dr_q.vertex_count == 32'd0 ||
                             dr_q.instance_count == 32'd0) begin
                  st_q <= S_FIN_OK;
                end else begin
                  // fp chain: vp.w*0.5, vp.h*0.5, maxz-minz
                  fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
                  fp_a_q <= dr_q.vp.w;
                  fp_b_q <= 32'h3F000000;           // 0.5f
                  fp_ret_q <= S_DR_HW;
                  t_fpgo();
                end
              end
              default: begin
                code_q <= APU_SH_DONE_UNSUPPORTED;
                st_q <= S_FIN_BAD;
              end
            endcase
          end
          // ---- CLEAR: 8-byte beats across the clear target --------
          S_CLR_X: begin
            if (wq_ok) begin
              t_wq({32'h0, clr_base} +
                   64'(cy_q) * 64'(clr_pitch) +
                   {29'h0, cx_q, 3'h0},
                   {clr_pix_q, clr_pix_q},
                   (clr_rowb - {16'h0, cx_q, 3'h0} >= 32'd8)
                   ? 8'hFF
                   : 8'hFF >> (4'd8 - 4'(clr_rowb -
                                        {16'h0, cx_q, 3'h0})));
              st_q <= S_CLR_N;
            end
          end
          S_CLR_N: begin
            if ({16'h0, cx_q, 3'h0} + 32'd8 >= clr_rowb) begin
              cx_q <= '0;
              if (cy_q + 16'd1 >= clr_h) st_q <= S_FIN_OK;
              else begin
                cy_q <= cy_q + 16'd1;
                st_q <= S_CLR_X;
              end
            end else begin
              cx_q <= cx_q + 16'd1;
              st_q <= S_CLR_X;
            end
          end
          // ---- DRAW: viewport constants --------------------------------
          S_DR_HW: begin
            vphw_q <= fp_res_q;
            fp_a_q <= dr_q.vp.h; fp_b_q <= 32'h3F000000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_DR_HH; t_fpgo();
          end
          S_DR_HH: begin
            vphh_q <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= dr_q.vp.maxz; fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1; // SUB b-c
            fp_ret_q <= S_DR_DZ; t_fpgo();
          end
          S_DR_DZ: begin
            vpdz_q <= fp_res_q;
            inst_q <= dr_q.first_instance;
            bat_q <= '0;
            st_q <= S_DR_BATCH;
          end
          // ---- batch / gather ------------------------------------------
          S_DR_BATCH: begin
            if (!topo_list_w)
              // strips and fans stay in one vertex batch (≤63)
              nv_q <= 6'(dr_q.vertex_count[5:0]);
            else
              // point/line/triangle lists: independent primitives, so
              // batch boundaries fall on a primitive multiple (BatchV:
              // 63 points/triangles, 62 line-list vertices)
              nv_q <= 6'((dr_q.vertex_count - bat_q >= 32'(batch_v_w))
                         ? batch_v_w : dr_q.vertex_count - bat_q);
            j_q <= '0;
            brk_q <= '0;
            // TP5: packed-miss count restarts each batch; vt_gen is
            // per-draw so it deliberately persists across batches.
            mi_q <= '0;
            base_q <= '0;
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast batch nv=%0d vb0={b=%08x s=%08x st=%0d} a0={v=%0d b=%0d f=%0d o=%0d} a1={v=%0d b=%0d f=%0d o=%0d} t=%0t",
                     dr_q.vertex_count - bat_q, dr_q.vb_base[0],
                     dr_q.vb_size[0], dr_q.vb_stride[0],
                     dr_q.attr[0].valid, dr_q.attr[0].binding,
                     dr_q.attr[0].fmt, dr_q.attr[0].offset,
                     dr_q.attr[1].valid, dr_q.attr[1].binding,
                     dr_q.attr[1].fmt, dr_q.attr[1].offset, $time);
`endif
// pragma translate_on
            st_q <= S_GA_ISET;
          end
          S_GA_ISET: begin
            if (dr_q.ib_type == 2'd0) begin
              ib_i <= $signed(dr_q.first_vertex + bat_q + {26'h0, j_q});
              a_q <= '0;
              st_q <= S_GA_ATTR;
            end else begin
              caddr_q <= dr_q.ib_base +
                         (dr_q.first_index + bat_q + {26'h0, j_q}) *
                         (dr_q.ib_type == 2'd1 ? 32'd2 : 32'd4);
              csz_q <= (dr_q.ib_type == 2'd1) ? 5'd2 : 5'd4;
              gbase_q <= dr_q.ib_base;
              gsize_q <= dr_q.ib_size;
              gret_q <= S_GA_IBX;
              st_q <= S_GA_RD;
            end
          end
          S_GA_IBX: begin
            // Restart is the raw index, before vertexOffset.  The
            // slot stays in the batch so later assembly sees the
            // break, and no attribute fetch uses the sentinel.
            if (dr_q.restart && dr_q.ib_type != 2'd0 &&
                ((dr_q.ib_type == 2'd1 &&
                  win_q[8*caddr_q[2:0] +: 16] == 16'hFFFF) ||
                 (dr_q.ib_type == 2'd2 &&
                  win_q[8*caddr_q[2:0] +: 32] == 32'hFFFF_FFFF))) begin
              brk_q[j_q] <= 1'b1;
              if (j_q + 6'd1 >= nv_q) st_q <= S_VS_ISS;
              else begin
                j_q  <= j_q + 6'd1;
                st_q <= S_GA_ISET;
              end
            end else begin
              brk_q[j_q] <= 1'b0;
              ib_i <= vt_cur_ib;
              // j_q<nv_q keeps the j_q==nv_q terminator iteration (which
              // S_GA_ATTR turns into S_VS_ISS) from probing/filling the
              // cache for a vertex that does not exist.
              if (reuse_en && j_q < nv_q) begin
                // TP5 scatter-v1: probe the vertex-cache tag for this
                // resolved index.  vt_ib/vt_e latch the key + direct-map
                // slot; word0 of the entry is read through the shared mp
                // port and classified hit/miss in S_VT_TAG.
                vt_ib <= vt_cur_ib;
                vt_e  <= f_vt_ent(vt_cur_ib);
                mp_addr_q  <= vt_tag_addr_w;
                mp_we_q    <= 1'b0;
                mp_data_q  <= '0;
                mp_strb_q  <= '0;
                mp_ret_q   <= S_VT_TAG;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end else begin
                a_q <= '0;
                st_q <= S_GA_ATTR;
              end
            end
          end
          // ---- attribute gather -----------------------------------------
          S_GA_ATTR: begin
            if (j_q >= nv_q) begin
              st_q <= S_VS_ISS;
            end else if (!dr_q.attr[a_q].valid) begin
              if (a_q == 3'd7) begin
                a_q <= '0;
                st_q <= S_GA_S8A;   // slot-8 write ends vertex j
              end
              else a_q <= a_q + 3'd1;
            end else if (!attr_ok) begin
              // valid flag set but unknown format -> honest refusal
              code_q <= APU_SH_DONE_UNSUPPORTED;
              st_q <= S_FIN_BAD;
            end else begin
              // instance-rate bindings index by the absolute instance
              // index; vertex-rate bindings index by the (resolved)
              // vertex index
              caddr_q <= dr_q.vb_base[a_bnd] +
                         32'($signed(dr_q.vb_rate[a_bnd]
                                    ? inst_q : 32'(ib_i)) *
                             $signed({16'h0, dr_q.vb_stride[a_bnd]})) +
                         a_off;
              csz_q <= f_asz(a_fmt);
              gbase_q <= dr_q.vb_base[a_bnd];
              gsize_q <= dr_q.vb_size[a_bnd];
              gret_q <= S_GA_CVT;
              st_q <= S_GA_RD;
            end
          end
          // shared small window read (1..3 words) into win_q; bounds
          // checked against [gbase, gbase+gsize) — OOB reads a zero
          // window and counts robust
          S_GA_RD: begin
            if (g_oob) begin
              win_q <= '0;
              robust_q <= robust_q + 32'd1;
              st_q <= gret_q;
            end else begin
              wn_q <= 2'((caddr_q[2:0] + csz_q + 5'd7) >> 3) - 2'd1;
              i_q <= '0;
              win_q <= '0;
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, caddr_q[31:3], 3'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_GA_RD;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          S_GA_CVT: begin
            if (a_fmt == APU_RAST_VF_R8_UNORM ||
                a_fmt == APU_RAST_VF_RG8_UNORM ||
                a_fmt == APU_RAST_VF_RGB8_UNORM ||
                a_fmt == APU_RAST_VF_RGBA8_UNORM ||
                a_fmt == APU_RAST_VF_R8_SNORM ||
                a_fmt == APU_RAST_VF_RG8_SNORM ||
                a_fmt == APU_RAST_VF_RGB8_SNORM ||
                a_fmt == APU_RAST_VF_RGBA8_SNORM) begin
              // missing components are (0, 0, 0, 1)
              conv_q[0] <= '0; conv_q[1] <= '0; conv_q[2] <= '0;
              conv_q[3] <= 32'h3F800000;
              snorm_q <= a_fmt == APU_RAST_VF_R8_SNORM ||
                         a_fmt == APU_RAST_VF_RG8_SNORM ||
                         a_fmt == APU_RAST_VF_RGB8_SNORM ||
                         a_fmt == APU_RAST_VF_RGBA8_SNORM;
              u16_q <= 1'b0;
              u8n_q <= (a_fmt == APU_RAST_VF_R8_UNORM ||
                        a_fmt == APU_RAST_VF_R8_SNORM) ? 3'd1 :
                       (a_fmt == APU_RAST_VF_RG8_UNORM ||
                        a_fmt == APU_RAST_VF_RG8_SNORM) ? 3'd2 :
                       (a_fmt == APU_RAST_VF_RGB8_UNORM ||
                        a_fmt == APU_RAST_VF_RGB8_SNORM) ? 3'd3 : 3'd4;
              c_q <= '0;
              st_q <= S_GA_U8I;
            end else if (a_fmt == APU_RAST_VF_R16_UNORM ||
                         a_fmt == APU_RAST_VF_RG16_UNORM ||
                         a_fmt == APU_RAST_VF_RGBA16_UNORM ||
                         a_fmt == APU_RAST_VF_R16_SNORM ||
                         a_fmt == APU_RAST_VF_RG16_SNORM ||
                         a_fmt == APU_RAST_VF_RGB16_SNORM ||
                         a_fmt == APU_RAST_VF_RGBA16_SNORM ||
                         a_fmt == APU_RAST_VF_RGB16_UNORM) begin
              conv_q[0] <= '0; conv_q[1] <= '0; conv_q[2] <= '0;
              conv_q[3] <= 32'h3F800000;
              snorm_q <= a_fmt == APU_RAST_VF_R16_SNORM ||
                         a_fmt == APU_RAST_VF_RG16_SNORM ||
                         a_fmt == APU_RAST_VF_RGB16_SNORM ||
                         a_fmt == APU_RAST_VF_RGBA16_SNORM;
              u16_q <= 1'b1;
              u8n_q <= (a_fmt == APU_RAST_VF_R16_UNORM ||
                        a_fmt == APU_RAST_VF_R16_SNORM) ? 3'd1 :
                       (a_fmt == APU_RAST_VF_RG16_UNORM ||
                        a_fmt == APU_RAST_VF_RG16_SNORM) ? 3'd2 :
                       (a_fmt == APU_RAST_VF_RGB16_UNORM ||
                        a_fmt == APU_RAST_VF_RGB16_SNORM) ? 3'd3 : 3'd4;
              c_q <= '0;
              st_q <= S_GA_U8I;
            end else if (a_fmt == APU_RAST_VF_R16_SFLOAT ||
                         a_fmt == APU_RAST_VF_RG16_SFLOAT ||
                         a_fmt == APU_RAST_VF_RGB16_SFLOAT ||
                         a_fmt == APU_RAST_VF_RGBA16_SFLOAT) begin
              conv_q[0] <= f_f16_f32(win_q[8*caddr_q[2:0] +: 16]);
              conv_q[1] <= (csz_q >= 5'd4)
                  ? f_f16_f32(win_q[8*caddr_q[2:0] + 16 +: 16]) : '0;
              conv_q[2] <= (csz_q >= 5'd6)
                  ? f_f16_f32(win_q[8*caddr_q[2:0] + 32 +: 16]) : '0;
              conv_q[3] <= (csz_q >= 5'd8)
                  ? f_f16_f32(win_q[8*caddr_q[2:0] + 48 +: 16])
                  : 32'h3F800000;
              st_q <= S_GA_W0;
            end else if (f_is_i8(a_fmt) || f_is_i16(a_fmt)) begin
              conv_q[0] <= f_icomp(win_q, caddr_q[2:0], 2'd0, f_is_i16(a_fmt),
                                   f_is_sint(a_fmt), f_nc(a_fmt));
              conv_q[1] <= f_icomp(win_q, caddr_q[2:0], 2'd1, f_is_i16(a_fmt),
                                   f_is_sint(a_fmt), f_nc(a_fmt));
              conv_q[2] <= f_icomp(win_q, caddr_q[2:0], 2'd2, f_is_i16(a_fmt),
                                   f_is_sint(a_fmt), f_nc(a_fmt));
              conv_q[3] <= f_icomp(win_q, caddr_q[2:0], 2'd3, f_is_i16(a_fmt),
                                   f_is_sint(a_fmt), f_nc(a_fmt));
              st_q <= S_GA_W0;
            end else begin
              // f32 formats: unpack; missing comps read (0,0,0,1)
              conv_q[0] <= csz_q >= 5'd4
                  ? win_q[8*caddr_q[2:0] +: 32] : '0;
              conv_q[1] <= csz_q >= 5'd8
                  ? win_q[8*caddr_q[2:0] + 32 +: 32] : '0;
              conv_q[2] <= csz_q >= 5'd12
                  ? win_q[8*caddr_q[2:0] + 64 +: 32] : '0;
              conv_q[3] <= csz_q >= 5'd16
                  ? win_q[8*caddr_q[2:0] + 96 +: 32]
                  : (f_is_int(a_fmt) ? 32'h1 : 32'h3F800000);
              st_q <= S_GA_W0;
            end
          end
          S_GA_U8I: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd0;
            fp_mod_q <= snorm_q ? 1'b0 : 1'b1;
            fp_a_q <= u16_q
                ? (snorm_q
                   ? f_sxt16(win_q[8*caddr_q[2:0] + 16*c_q +: 16])
                   : {16'h0, win_q[8*caddr_q[2:0] + 16*c_q +: 16]})
                : snorm_q
                ? f_sxt8(win_q[8*caddr_q[2:0] + 8*c_q +: 8])
                : {24'h0, win_q[8*caddr_q[2:0] + 8*c_q +: 8]};
            fp_ret_q <= S_GA_U8M;
            t_fpgo();
          end
          S_GA_U8M: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_b_q <= (u16_q && snorm_q) ? 32'h38000100 :
                      u16_q ? 32'h38008001 :
                      snorm_q ? 32'h3C010204 : 32'h3B808081;
            fp_ret_q <= S_GA_U8S;
            t_fpgo();
          end
          S_GA_U8S: begin
            // SNORM -128 maps to -1.  Values below -1 from rounding do too.
            conv_q[c_q[1:0]] <= (snorm_q && f_f32_lt(fp_res_q, 32'hBF800000))
                               ? 32'hBF800000 : fp_res_q;
            if ({1'b0, c_q} + 4'd1 == {1'b0, u8n_q}) st_q <= S_GA_W0;
            else begin
              c_q <= c_q + 3'd1;
              st_q <= S_GA_U8I;
            end
          end
          // two-word record write into vs_in
          S_GA_W0: begin
            if (wq_ok) begin
              t_wq({32'h0, vsi_q} +
                   {26'h0, rec_idx_w} * 64'(ASTR) +
                   {29'h0, dr_q.attr[a_q].loc, 4'h0},
                   {conv_q[1], conv_q[0]}, 8'hFF);
              st_q <= S_GA_W1;
            end
          end
          S_GA_W1: begin
            if (wq_ok) begin
              t_wq({32'h0, vsi_q} +
                   {26'h0, rec_idx_w} * 64'(ASTR) +
                   {29'h0, dr_q.attr[a_q].loc, 4'h0} + 64'd8,
                   {conv_q[3], conv_q[2]}, 8'hFF);
              if (a_q == 3'd7) a_q <= '0;
              else             a_q <= a_q + 3'd1;
              st_q <= (a_q == 3'd7) ? S_GA_S8A : S_GA_ATTR;
            end
          end
          // slot 8 of the VS-in record = {VertexIndex, InstanceIndex,
          // 0, 0}; the ShaderCore reads the builtins from here (G2a)
          S_GA_S8A: begin
            if (wq_ok) begin
              t_wq({32'h0, vsi_q} +
                   {26'h0, rec_idx_w} * 64'(ASTR) + 64'd128,
                   {inst_q, 32'(ib_i)}, 8'hFF);
              st_q <= S_GA_S8B;
            end
          end
          S_GA_S8B: begin
            if (wq_ok) begin
              t_wq({32'h0, vsi_q} +
                   {26'h0, rec_idx_w} * 64'(ASTR) + 64'd136,
                   64'h0, 8'hFF);
              j_q <= j_q + 6'd1;
              // TP5: only misses reach this state under reuse_en, so
              // mi_q (the packed miss count) advances here; hits advance
              // j_q alone inside S_VT_CP.
              if (reuse_en) mi_q <= mi_q + 6'd1;
              st_q <= S_GA_ISET;
            end
          end
          // ---- TP5 vertex-cache reuse ------------------------------------
          // S_VT_TAG: mp_res_q holds the probed entry's tag word0.
          //   {gen[63:33], index[32:1], valid[0]} — a hit needs valid +
          //   this draw's generation + the full resolved index.
          S_VT_TAG: begin
            if (mp_res_q[0] && (mp_res_q[32:1] == vt_ib) &&
                (mp_res_q[63:33] == vt_gen))
              st_q <= S_VT_HIT;
            else
              st_q <= S_VT_MISS;
          end
          // S_VT_MISS: remember this miss's dense assembly position and
          // resolved index (for the post-VS scatter target + cache tag),
          // then gather its attributes into the packed vsi[mi_q] record.
          S_VT_MISS: begin
            out_sl_q[mi_q] <= j_q;
            m_idx_q[mi_q]  <= vt_ib;
            a_q <= '0;
            st_q <= S_GA_ATTR;
          end
          // S_VT_HIT: arm the 18-word cache->vso[j_q] copy burst.
          S_VT_HIT: begin
            vt_w <= 5'd0;
            vt_j <= j_q;
            mp_addr_q  <= vt_e_rec_w;
            mp_we_q    <= 1'b0;
            mp_data_q  <= '0;
            mp_strb_q  <= '0;
            mp_ret_q   <= S_VT_CP;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          // S_VT_CP: mp_res_q = cache record word vt_w; queue it into
          // vso[vt_j][vt_w], then read the next word (or finish the copy).
          // j_q advances (the hit consumed an assembly slot) but mi_q does
          // not — hits are not misses.
          S_VT_CP: begin
            if (wq_ok) begin
              t_wq(vt_vso_j + vt_woff, mp_res_q, 8'hFF);
              if (vt_w == 5'd17) begin
                j_q <= j_q + 6'd1;
                st_q <= S_GA_ISET;
              end else begin
                vt_w <= vt_w + 5'd1;
                mp_addr_q  <= vt_e_rec_w + vt_woff_n;
                mp_we_q    <= 1'b0;
                mp_data_q  <= '0;
                mp_strb_q  <= '0;
                mp_ret_q   <= S_VT_CP;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end
            end
          end
          // S_VT_SC: post-VS scatter.  mp_res_q = vso_c[vt_m][vt_w]; copy it
          // to the dense vso record at out_sl_q[vt_m] (held in vt_os).
          // Self-loops over the 18 record words then the mi_q misses.
          S_VT_SC: begin
            if (wq_ok) begin
              t_wq(vt_vso_os + vt_woff, mp_res_q, 8'hFF);
              if (vt_w != 5'd17) begin
                vt_w <= vt_w + 5'd1;
                mp_addr_q  <= vt_src_rec + vt_woff_n;
                mp_we_q    <= 1'b0;
                mp_data_q  <= '0;
                mp_strb_q  <= '0;
                mp_ret_q   <= S_VT_SC;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end else if (vt_m + 6'd1 < mi_q) begin
                vt_m  <= vt_m + 6'd1;
                vt_w  <= 5'd0;
                vt_os <= out_sl_q[vt_m + 6'd1];
                mp_addr_q  <= vt_src_rec_n;
                mp_we_q    <= 1'b0;
                mp_data_q  <= '0;
                mp_strb_q  <= '0;
                mp_ret_q   <= S_VT_SC;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end else begin
                // scatter complete -> fill miss 0
                vt_m <= '0; vt_w <= 5'd0;
                st_q <= S_VT_F0;
              end
            end
          end
          // S_VT_F0: fill setup for miss vt_m — latch the cache entry for
          // its resolved index, queue the tag word, and read vso_c[vt_m][0].
          S_VT_F0: begin
            if (wq_ok) begin
              vt_e <= f_vt_ent(m_idx_q[vt_m]);
              t_wq(vt_fill_tag,
                   {vt_gen, m_idx_q[vt_m], 1'b1}, 8'hFF);
              mp_addr_q  <= vt_src_rec;
              mp_we_q    <= 1'b0;
              mp_data_q  <= '0;
              mp_strb_q  <= '0;
              mp_ret_q   <= S_VT_FL;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          // S_VT_FL: post-VS cache fill.  mp_res_q = vso_c[vt_m][vt_w];
          // write it into cache[vt_e].record[vt_w].  Self-loops over the
          // 18 record words then the mi_q misses (each miss re-enters
          // S_VT_F0 for its tag + entry).
          S_VT_FL: begin
            if (wq_ok) begin
              t_wq(vt_cch_w, mp_res_q, 8'hFF);
              if (vt_w != 5'd17) begin
                vt_w <= vt_w + 5'd1;
                mp_addr_q  <= vt_src_rec + vt_woff_n;
                mp_we_q    <= 1'b0;
                mp_data_q  <= '0;
                mp_strb_q  <= '0;
                mp_ret_q   <= S_VT_FL;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end else if (vt_m + 6'd1 < mi_q) begin
                vt_m  <= vt_m + 6'd1;
                vt_w  <= 5'd0;
                st_q <= S_VT_F0;
              end else begin
                // fill complete -> primitive assembly
                if (dr_q.rast_discard)
                  st_q <= S_BATNEXT;
                else begin
                  p_q <= '0; base_q <= '0; f_q <= '0;
                  st_q <= S_PR_I0;
                end
              end
            end
          end
          // ---- VS batch wave ---------------------------------------------
          S_VS_ISS: begin
            // RP4: hold the wave launch while record writes are still
            // queued — the shader core must not start work that could
            // observe memory before those writes have responded.
            // TP5: under reuse the packed miss count is the wave size and
            // the VS writes compact records into vso_c (scattered back to
            // dense vso afterwards).  mi_q==0 means every vertex hit —
            // vso is already complete, so skip the wave and the
            // (empty) scatter/fill entirely.
            if (reuse_en && mi_q == 6'd0) begin
              if (dr_q.rast_discard)
                st_q <= S_BATNEXT;
              else begin
                p_q <= '0; base_q <= '0; f_q <= '0;
                st_q <= S_PR_I0;
              end
            end else if (!wq_v_q[0]) begin
              sh_ctype_o <= APU_SH_WORK_VS;
              sh_slot_o <= dr_q.vs_slot;
              sh_imm_o[0] <= {26'h0, reuse_en ? mi_q : nv_q};
              sh_imm_o[1] <= vsi_q;
              // sh_imm_o lanes are 32 b: the shader-side record base is
              // truncated exactly like vsi_q/vso_q — the whole scratch
              // aperture is 32 b-addressable by construction, so the
              // low word of the 64 b vso_c_w is the true byte address.
              sh_imm_o[2] <= reuse_en ? 32'(vso_c_w) : vso_q;
              sh_imm_o[3] <= (dr_q.ib_type == 2'd0)
                             ? dr_q.first_vertex + bat_q : '0;
              sh_imm_o[4] <= inst_q;
              sh_imm_o[5] <= '0; sh_imm_o[6] <= '0; sh_imm_o[7] <= '0;
              shv_q <= 1'b1;
              if (shv_q && sh_work_ready_i) begin
                shv_q <= 1'b0;
                shd_q <= 1'b0;
                st_q <= S_VS_WAIT;
              end
            end
          end
          S_VS_WAIT:
            if (shd_q) begin
              shd_q <= 1'b0;
              if (shdp_q.code != APU_SH_DONE_OK) begin
                code_q <= shdp_q.code;
                st_q <= S_FIN_BAD;
              end else begin
                robust_q <= robust_q + shdp_q.robust;
                if (reuse_en) begin
                  // TP5: scatter the compacted vso_c records back to their
                  // dense vso assembly slots, then fill the cache entries.
                  // Reached only with mi_q>0 (mi_q==0 skipped the wave).
                  vt_m <= '0; vt_w <= 5'd0; vt_os <= out_sl_q[0];
                  mp_addr_q  <= {32'h0, vso_c_w};
                  mp_we_q    <= 1'b0;
                  mp_data_q  <= '0;
                  mp_strb_q  <= '0;
                  mp_ret_q   <= S_VT_SC;
                  mp_acked_q <= 1'b0;
                  st_q <= S_MPW;
                end else if (dr_q.rast_discard)
                  st_q <= S_BATNEXT;
                else begin
                  p_q <= '0; base_q <= '0; f_q <= '0;
                  st_q <= S_PR_I0;
                end
              end
            end
          // ---- primitive loop ---------------------------------------------
          // Position fetch: two words per vertex, t_q = 0..2
          S_PR_I0: begin
            // clip mode: the fan cursor, not nv_q, bounds the loop —
            // exhaustion was already decided in the prim-done advance
            // A restart index ends the primitive.  The next index
            // is the first vertex of a new list element, strip, or
            // fan, and the strip/fan anchor moves with it.
            if (!clip_q && dr_q.restart && dr_q.ib_type != 2'd0 &&
                p_q < nv_q && brk_q[p_q]) begin
              p_q    <= p_q + 6'd1;
              base_q <= p_q + 6'd1;
            end else if (!clip_q && dr_q.restart && dr_q.ib_type != 2'd0 &&
                !point_w &&
                (line_w ? p_q + 8'd1 : p_q + 8'd2) < nv_q &&
                (brk_q[p_q + 6'd1] ||
                 (!line_w && brk_q[p_q + 6'd2]))) begin
              if (brk_q[p_q]) begin
                p_q    <= p_q + 6'd1;
                base_q <= p_q + 6'd1;
              end else if (brk_q[p_q + 6'd1]) begin
                p_q    <= p_q + 6'd2;
                base_q <= p_q + 6'd2;
              end else begin
                p_q    <= p_q + 6'd3;
                base_q <= p_q + 6'd3;
              end
            end else if (!clip_q &&
                         p_q + (point_w ? 8'd0 : line_w ? 8'd1 : 8'd2)
                         >= nv_q) begin
              if (f_q != 6'd0) begin
                nf_q <= {1'b0, f_q}; f_q <= '0;
                flr_q <= S_BATNEXT;
                dret_q <= S_FLUSH; st_q <= S_DGATE;
              end else
                st_q <= S_BATNEXT;
            end else begin
              t_q <= '0;
              st_q <= S_PR_I0B;
            end
          end
          S_PR_I0B: begin
            mp_we_q <= 1'b0;
            // clip fan tris read the clip_out ring, plain prims vso_q
            mp_addr_q <= {32'h0, clip_q ? clp_q : vso_q} +
                         64'(f_pi(t_q)) * 64'(VSTR);
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_PR_I1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_PR_I1: begin
            pos_q[t_q][0] <= mp_res_q[31:0];
            pos_q[t_q][1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_PR_I2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_PR_I2: begin
            pos_q[t_q][2] <= mp_res_q[31:0];
            pos_q[t_q][3] <= mp_res_q[63:32];
            if (t_q == 2'd2 || (line_w && t_q == 2'd1) ||
                (point_w && t_q == 2'd0)) st_q <= S_PR_W;
            else begin
              t_q <= t_q + 2'd1;
              st_q <= S_PR_I0B;
            end
          end
          S_PR_W: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast prim p=%0d pos0=%08x %08x %08x %08x pos1=%08x %08x %08x %08x pos2=%08x %08x %08x %08x t=%0t",
                     p_q, pos_q[0][0], pos_q[0][1], pos_q[0][2],
                     pos_q[0][3], pos_q[1][0], pos_q[1][1], pos_q[1][2],
                     pos_q[1][3], pos_q[2][0], pos_q[2][1], pos_q[2][2],
                     pos_q[2][3], $time);
`endif
// pragma translate_on
            // G2b: evaluate outcodes instead of the w<=0 skip.  gw =
            // 4096*w per vertex (guard band), then S_OC decides
            // trivial-reject / trivial-accept / clip.  Fan tris of an
            // already-clipped polygon skip the eval: the S-H output is
            // inside by construction, and re-clipping under f32 is not
            // idempotent — a lerped vertex can land 1 ulp outside its
            // plane and re-clip forever.
            if (clip_q) begin
              fp_kind_q <= 2'd1; fp_o_q <= '0;
              fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[0][3];
              fp_ret_q <= S_T0R;
            end else begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
              fp_a_q <= CLIP_GB; fp_b_q <= pos_q[0][3];
              fp_ret_q <= S_OC_G1;
            end
            t_fpgo();
          end
          S_OC_G1: begin
            gw_q[0] <= fp_res_q;
            // A point has one vertex.  A line has two.  The third
            // slot is stale and must not enter the outcode.
            if (point_w) begin
              oc_q[0] <= f_oc(pos_q[0], fp_res_q);
              oc_q[1] <= '0;
              oc_q[2] <= '0;
              st_q <= S_OC;
            end else begin
              fp_a_q <= CLIP_GB; fp_b_q <= pos_q[1][3];
              fp_ret_q <= S_OC_G2; t_fpgo();
            end
          end
          S_OC_G2: begin
            gw_q[1] <= fp_res_q;
            if (line_w) begin
              oc_q[0] <= f_oc(pos_q[0], gw_q[0]);
              oc_q[1] <= f_oc(pos_q[1], fp_res_q);
              oc_q[2] <= '0;
              st_q <= S_OC;
            end else begin
              fp_a_q <= CLIP_GB; fp_b_q <= pos_q[2][3];
              fp_ret_q <= S_OC_G3; t_fpgo();
            end
          end
          S_OC_G3: begin
            gw_q[2] <= fp_res_q;
            oc_q[0] <= f_oc(pos_q[0], gw_q[0]);
            oc_q[1] <= f_oc(pos_q[1], gw_q[1]);
            oc_q[2] <= f_oc(pos_q[2], fp_res_q);
            st_q <= S_OC;
          end
          S_OC: begin
            // Points and lines use only their own vertices.  A line
            // that straddles a plane is clipped in registers; both
            // ends behind the same plane are dropped.
            if (point_w) begin
              if (|oc_q[0]) begin
                t_pd();
                st_q <= S_PR_I0;
              end else begin
                fp_kind_q <= 2'd1; fp_o_q <= '0;
                fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[0][3];
                fp_ret_q <= S_T0R;
                t_fpgo();
              end
            end else if (line_w) begin
              if (|(oc_q[0] & oc_q[1])) begin
                t_pd();
                st_q <= S_PR_I0;
              end else if (!(|oc_q[0] || |oc_q[1])) begin
                fp_kind_q <= 2'd1; fp_o_q <= '0;
                fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[0][3];
                fp_ret_q <= S_T0R;
                t_fpgo();
              end else begin
                cpm_q <= oc_q[0] | oc_q[1];
                cpl_q <= f_lpl(oc_q[0] | oc_q[1]);
                ce_q  <= '0;
                st_q  <= S_LC_D0;
              end
            end else if (|(oc_q[0] & oc_q[1] & oc_q[2])) begin
              // trivially outside a common plane -> drop the prim
              if (dr_q.topology != 8'd3) p_q <= p_q + 6'd1;
              else                       p_q <= p_q + 6'd3;
              st_q <= S_PR_I0;
            end else if (!(|oc_q[0] || |oc_q[1] || |oc_q[2])) begin
              // all inside -> straight to perspective divide
              fp_kind_q <= 2'd1; fp_o_q <= '0;
              fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[0][3];
              fp_ret_q <= S_T0R;
              t_fpgo();
            end else begin
              // clip needed: Sutherland–Hodgman over the violated
              // planes.  in-ring = vso records (topology-mapped);
              // out-ring parity keeps the final polygon in clip_out
              // when popcount(cpm) is odd -> first out goes to clp_q
              cpm_q <= oc_q[0] | oc_q[1] | oc_q[2];
              cpl_q <= oc_q[0][0] | oc_q[1][0] | oc_q[2][0] ? 3'd0 :
                       oc_q[0][1] | oc_q[1][1] | oc_q[2][1] ? 3'd1 :
                       oc_q[0][2] | oc_q[1][2] | oc_q[2][2] ? 3'd2 :
                       oc_q[0][3] | oc_q[1][3] | oc_q[2][3] ? 3'd3 :
                                                             3'd4;
              cn_q   <= 4'd3; ce_q <= '0; co_q <= '0; cin_q <= '0;
              cib_q  <= vso_q; cmap_q <= 1'b1;
              cob_q  <= ^(oc_q[0] | oc_q[1] | oc_q[2]) ? clp_q : ctp_q;
              st_q <= S_CP_RP0;
            end
          end
          // ---- clip-space clipping (G2b) ---------------------------------
          // Per in-polygon vertex: fetch Position from the in-ring,
          // evaluate its signed distance to the current plane (f32 on
          // the fpnew units) and its inside bit, then the edge walk
          // emits the out-polygon as VS-out-format records.  Every
          // crossing interpolates Position and all fs_in_mask
          // locations linearly in CLIP space; the later perspective
          // divide restores exact perspective correctness because a
          // clip-space lerp commutes with it.
          S_CP_RP0: begin
            mp_we_q <= 1'b0;
            mp_addr_q <= f_crec(ce_q);
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_CP_RP1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_RP1: begin
            cpos_q[ce_q][0] <= mp_res_q[31:0];
            cpos_q[ce_q][1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_CP_RP2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_RP2: begin
            cpos_q[ce_q][2] <= mp_res_q[31:0];
            cpos_q[ce_q][3] <= mp_res_q[63:32];
            unique case (cpl_q)
              3'd0: begin                     // near: dist = z
                cdis_q[ce_q] <= mp_res_q[31:0];
                cin_q[ce_q]  <= !f_f32_lt(mp_res_q[31:0], 32'h0);
                if (ce_q == cn_q - 4'd1) begin
                  ce_q <= '0; st_q <= S_CP_EDGE;
                end else begin
                  ce_q <= ce_q + 4'd1; st_q <= S_CP_RP0;
                end
              end
              3'd3, 3'd4: begin               // guard: 4096*w first
                fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
                fp_a_q <= CLIP_GB; fp_b_q <= mp_res_q[63:32];
                fp_ret_q <= S_CP_DG;
                t_fpgo();
              end
              default: begin                  // far: w-z; eps: w-1e-5
                fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
                fp_a_q <= '0;
                fp_b_q <= mp_res_q[63:32];
                fp_c_q <= (cpl_q == 3'd1) ? mp_res_q[31:0] : CLIP_EPS;
                fp_ret_q <= S_CP_DD;
                t_fpgo();
              end
            endcase
          end
          S_CP_DG: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= fp_res_q;                // 4096*w
            fp_c_q <= {1'b0, cpos_q[ce_q][cpl_q == 3'd3 ? 0 : 1][30:0]};
            fp_ret_q <= S_CP_DD;
            t_fpgo();
          end
          S_CP_DD: begin
            cdis_q[ce_q] <= fp_res_q;
            cin_q[ce_q]  <= !f_f32_lt(fp_res_q, 32'h0);
            if (ce_q == cn_q - 4'd1) begin
              ce_q <= '0; st_q <= S_CP_EDGE;
            end else begin
              ce_q <= ce_q + 4'd1; st_q <= S_CP_RP0;
            end
          end
          // edge (a=ce_q -> b): emit rules of Sutherland–Hodgman
          S_CP_EDGE: begin
            ceb_q <= (ce_q == cn_q - 4'd1) ? 4'd0 : ce_q + 4'd1;
            unique case ({cin_q[ce_q],
                          cin_q[(ce_q == cn_q - 4'd1)
                                ? 4'd0 : ce_q + 4'd1]})
              2'b11:  st_q <= S_CP_CB0;              // in->in: copy b
              2'b01: begin                           // out->in: i, b
                     cemitb_q <= 1'b1; st_q <= S_CP_IT0; end
              2'b10: begin                           // in->out: i
                     cemitb_q <= 1'b0; st_q <= S_CP_IT0; end
              default: st_q <= S_CP_ENX;             // out->out: none
            endcase
          end
          S_CP_ENX: begin
            if (ce_q == cn_q - 4'd1)
              st_q <= S_CP_PDN;
            else begin
              ce_q <= ce_q + 4'd1;
              st_q <= S_CP_EDGE;
            end
          end
          // ---- interpolation t = da/(da-db), then record emit -------
          S_CP_IT0: begin                     // sub: da - db
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= cdis_q[ce_q];
            fp_c_q <= cdis_q[(ce_q == cn_q - 4'd1)
                             ? 4'd0 : ce_q + 4'd1];
            fp_ret_q <= S_CP_IT1; t_fpgo();
          end
          S_CP_IT1: begin                     // div: da/(da-db)
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= cdis_q[ce_q]; fp_b_q <= fp_res_q;
            fp_ret_q <= S_CP_IT2; t_fpgo();
          end
          S_CP_IT2: begin
            ctt_q <= fp_res_q;
            c_q <= '0; lc_q <= '0;
            cslot_q <= 1'b1;                  // Position slot first
            st_q <= S_CP_ILP;
          end
          // emit pump: slot 0, then every masked varying location
          S_CP_ILP: begin
            if (cslot_q) begin
              c_q <= '0;
              st_q <= S_CP_IS;
            end else if (lc_q == 4'd8) begin
              // record complete
              co_q <= co_q + 4'd1;
              if (cemitb_q) begin
                cemitb_q <= 1'b0;
                st_q <= S_CP_CB0;
              end else
                st_q <= S_CP_ENX;
            end else if (!dr_q.fs_in_mask[lc_q[2:0]]) begin
              lc_q <= lc_q + 4'd1;
            end else begin
              mp_we_q <= 1'b0;
              mp_addr_q <= f_crec(ce_q) + 64'd16 +
                           {28'h0, lc_q[2:0], 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_CP_IR0;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          // chain: a.lo, a.hi, b.lo, b.hi of the location
          S_CP_IR0: begin
            cva_q[0] <= mp_res_q[31:0]; cva_q[1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_CP_IR1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IR1: begin
            cva_q[2] <= mp_res_q[31:0]; cva_q[3] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= f_crec(ceb_q) + 64'd16 +
                         {28'h0, lc_q[2:0], 4'h0};
            mp_ret_q <= S_CP_IR2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IR2: begin
            cvb_q[0] <= mp_res_q[31:0]; cvb_q[1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_CP_IR3;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IR3: begin
            cvb_q[2] <= mp_res_q[31:0]; cvb_q[3] <= mp_res_q[63:32];
            c_q <= '0;
            st_q <= S_CP_IS;
          end
          // per comp: (vb - va), then t*(vb-va) + va
          S_CP_IS: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= cslot_q ? cpos_q[ceb_q][c_q[1:0]]
                              : cvb_q[c_q[1:0]];
            fp_c_q <= cslot_q ? cpos_q[ce_q][c_q[1:0]]
                              : cva_q[c_q[1:0]];
            fp_ret_q <= S_CP_IF; t_fpgo();
          end
          S_CP_IF: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= ctt_q; fp_b_q <= fp_res_q;
            fp_c_q <= cslot_q ? cpos_q[ce_q][c_q[1:0]]
                              : cva_q[c_q[1:0]];
            fp_ret_q <= S_CP_IW2; t_fpgo();
          end
          S_CP_IW2: begin
            conv_q[c_q[1:0]] <= fp_res_q;
            if (c_q[1:0] == 2'd3) begin
              mp_we_q <= 1'b1;
              mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR) +
                           (cslot_q ? 64'd0
                                    : 64'd16 + {28'h0, lc_q[2:0], 4'h0});
              mp_data_q <= {conv_q[1], conv_q[0]};
              mp_strb_q <= 8'hFF;
              mp_ret_q <= S_CP_IW3;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end else begin
              c_q <= c_q + 3'd1;
              st_q <= S_CP_IS;
            end
          end
          S_CP_IW3: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_data_q <= {conv_q[3], conv_q[2]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_IW4;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IW4: begin
            if (cslot_q) begin
              cslot_q <= 1'b0;
              st_q <= S_CP_ILP;
            end else begin
              lc_q <= lc_q + 4'd1;
              st_q <= S_CP_ILP;
            end
          end
          // ---- emit an unmodified inside vertex b --------------------
          S_CP_CB0: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR);
            mp_data_q <= {cpos_q[ceb_q][1], cpos_q[ceb_q][0]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CB1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_CB1: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_data_q <= {cpos_q[ceb_q][3], cpos_q[ceb_q][2]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CBL;
            mp_acked_q <= 1'b0;
            lc_q <= '0;
            st_q <= S_MPW;
          end
          S_CP_CBL: begin
            if (lc_q == 4'd8) begin
              co_q <= co_q + 4'd1;
              st_q <= S_CP_ENX;
            end else if (!dr_q.fs_in_mask[lc_q[2:0]]) begin
              lc_q <= lc_q + 4'd1;
            end else begin
              mp_we_q <= 1'b0;
              mp_addr_q <= f_crec(ceb_q) + 64'd16 +
                           {28'h0, lc_q[2:0], 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_CP_CBR;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          S_CP_CBR: begin                 // write loc lo, then read hi
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR) +
                         64'd16 + {28'h0, lc_q[2:0], 4'h0};
            mp_data_q <= mp_res_q;
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CBQ;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_CBQ: begin                 // read loc hi of vertex b
            mp_we_q <= 1'b0;
            mp_addr_q <= f_crec(ceb_q) + 64'd16 +
                         {28'h0, lc_q[2:0], 4'h0} + 64'd8;
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_CP_CBW;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_CBW: begin                 // write loc hi
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR) +
                         64'd16 + {28'h0, lc_q[2:0], 4'h0} + 64'd8;
            mp_data_q <= mp_res_q;
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CBL;
            mp_acked_q <= 1'b0;
            lc_q <= lc_q + 4'd1;
            st_q <= S_MPW;
          end
          // plane done: swap the rings, next plane or finish
          S_CP_PDN: begin
            if (co_q < 4'd3) begin
              // the clip consumed the whole primitive
              t_pd();
              st_q <= S_PR_I0;
            end else begin
              cn_q   <= co_q;
              co_q   <= '0; ce_q <= '0; cin_q <= '0;
              cmap_q <= 1'b0;
              cib_q  <= cob_q;
              cob_q  <= (cob_q == clp_q) ? ctp_q : clp_q;
              if (f_npl(cpm_q, cpl_q) == 3'd7) begin
                // final polygon: cob (now cib) — always clp_q by the
                // parity pick in S_OC — feeds the fan setup path
                clip_q <= 1'b1; cfan_q <= 4'd1; cpn_q <= co_q;
                st_q <= S_PR_I0;
              end else begin
                cpl_q <= f_npl(cpm_q, cpl_q);
                st_q <= S_CP_RP0;
              end
            end
          end
          // -- per-vertex: rcp_w then ndc = pos.xyz * rcp_w ----------------
          S_T0R: begin
            vrw_q[0] <= fp_res_q;
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[1][3];
            fp_ret_q <= S_T1R; t_fpgo();
          end
          S_T1R: begin
            vrw_q[1] <= fp_res_q;
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[2][3];
            fp_ret_q <= S_T2R; t_fpgo();
          end
          S_T2R: begin
            vrw_q[2] <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= pos_q[0][0]; fp_b_q <= vrw_q[0];
            fp_ret_q <= S_T0X; t_fpgo();
          end
          S_T0X: begin
            vnd_q[0][0] <= fp_res_q;
            fp_a_q <= pos_q[0][1]; fp_b_q <= vrw_q[0];
            fp_ret_q <= S_T0Y; t_fpgo();
          end
          S_T0Y: begin
            vnd_q[0][1] <= fp_res_q;
            fp_a_q <= pos_q[0][2]; fp_b_q <= vrw_q[0];
            fp_ret_q <= S_T0Z; t_fpgo();
          end
          S_T0Z: begin
            vnd_q[0][2] <= fp_res_q;
            fp_a_q <= pos_q[1][0]; fp_b_q <= vrw_q[1];
            fp_ret_q <= S_T1X; t_fpgo();
          end
          S_T1X: begin
            vnd_q[1][0] <= fp_res_q;
            fp_a_q <= pos_q[1][1]; fp_b_q <= vrw_q[1];
            fp_ret_q <= S_T1Y; t_fpgo();
          end
          S_T1Y: begin
            vnd_q[1][1] <= fp_res_q;
            fp_a_q <= pos_q[1][2]; fp_b_q <= vrw_q[1];
            fp_ret_q <= S_T1Z; t_fpgo();
          end
          S_T1Z: begin
            vnd_q[1][2] <= fp_res_q;
            fp_a_q <= pos_q[2][0]; fp_b_q <= vrw_q[2];
            fp_ret_q <= S_T2X; t_fpgo();
          end
          S_T2X: begin
            vnd_q[2][0] <= fp_res_q;
            fp_a_q <= pos_q[2][1]; fp_b_q <= vrw_q[2];
            fp_ret_q <= S_T2Y; t_fpgo();
          end
          S_T2Y: begin
            vnd_q[2][1] <= fp_res_q;
            fp_a_q <= pos_q[2][2]; fp_b_q <= vrw_q[2];
            fp_ret_q <= S_T2Z; t_fpgo();
          end
          S_T2Z: begin
            vnd_q[2][2] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[0][0]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0SA; t_fpgo();
          end
          // -- screen transform per vertex: x=fma(ndc.x+1,vphw,vp.x), ----
          //    xi=F2I(x*256 RNE); same for y; z=fma(ndc.z,vpdz,vp.minz)
          S_T0SA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphw_q; fp_c_q <= dr_q.vp.x;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0SF; t_fpgo();
          end
          S_T0SF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000; // *256
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0SM; t_fpgo();
          end
          S_T0SM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0; // F2I s32
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T0SC; t_fpgo();
          end
          S_T0SC: begin
            vxi_q[0] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[0][1]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0YA; t_fpgo();
          end
          S_T0YA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphh_q; fp_c_q <= dr_q.vp.y;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0YF; t_fpgo();
          end
          S_T0YF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0YM; t_fpgo();
          end
          S_T0YM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T0YC; t_fpgo();
          end
          S_T0YC: begin
            vyi_q[0] <= fp_res_q;
            fp_a_q <= vnd_q[0][2]; fp_b_q <= vpdz_q;
            fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0ZF; t_fpgo();
          end
          S_T0ZF: begin
            vz_q[0] <= fp_res_q;
            if (point_w) begin
              ln_q   <= 1'b1;
              varm_q <= dr_q.fs_in_mask;
              if (pos_q[0][3][31]) begin
                ln_q <= 1'b0;
                t_pd();
                st_q <= S_PR_I0;
              end else if (dr_q.fs_in_mask[0]) begin
                mp_we_q <= 1'b0;
                mp_addr_q <= {32'h0, vso_q} +
                             64'(f_pi(2'd0)) * 64'(VSTR) + 64'd16;
                mp_data_q <= '0; mp_strb_q <= '0;
                mp_ret_q <= S_LN_VF2;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end else
                st_q <= S_LN_INIT;
            end else begin
              fp_a_q <= '0;
              fp_b_q <= vnd_q[1][0]; fp_c_q <= 32'h3F800000;
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
              fp_ret_q <= S_T1SA; t_fpgo();
            end
          end
          S_T1SA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphw_q; fp_c_q <= dr_q.vp.x;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1SF; t_fpgo();
          end
          S_T1SF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1SM; t_fpgo();
          end
          S_T1SM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T1SC; t_fpgo();
          end
          S_T1SC: begin
            vxi_q[1] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[1][1]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1YA; t_fpgo();
          end
          S_T1YA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphh_q; fp_c_q <= dr_q.vp.y;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1YF; t_fpgo();
          end
          S_T1YF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1YM; t_fpgo();
          end
          S_T1YM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T1YC; t_fpgo();
          end
          S_T1YC: begin
            vyi_q[1] <= fp_res_q;
            fp_a_q <= vnd_q[1][2]; fp_b_q <= vpdz_q;
            fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1ZF; t_fpgo();
          end
          S_T1ZF: begin
            vz_q[1] <= fp_res_q;
            if (line_w) begin
              // no polygon: flat colour from endpoint 0, then Bresenham
              ln_q    <= 1'b1;
              varm_q  <= dr_q.fs_in_mask;
              if (pos_q[0][3][31] || pos_q[1][3][31]) begin
                ln_q <= 1'b0;
                t_pd();
                st_q <= S_PR_I0;
              end else if (dr_q.fs_in_mask[0]) begin
                mp_we_q <= 1'b0;
                mp_addr_q <= {32'h0, vso_q} +
                             64'(f_pi(2'd0)) * 64'(VSTR) + 64'd16;
                mp_data_q <= '0; mp_strb_q <= '0;
                mp_ret_q <= S_LN_VF2;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end else
                st_q <= S_LN_INIT;
            end else begin
              fp_a_q <= '0;
              fp_b_q <= vnd_q[2][0]; fp_c_q <= 32'h3F800000;
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
              fp_ret_q <= S_T2SA; t_fpgo();
            end
          end
          S_T2SA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphw_q; fp_c_q <= dr_q.vp.x;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2SF; t_fpgo();
          end
          S_T2SF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2SM; t_fpgo();
          end
          S_T2SM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T2SC; t_fpgo();
          end
          S_T2SC: begin
            vxi_q[2] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[2][1]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2YA; t_fpgo();
          end
          S_T2YA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphh_q; fp_c_q <= dr_q.vp.y;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2YF; t_fpgo();
          end
          S_T2YF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2YM; t_fpgo();
          end
          S_T2YM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T2YC; t_fpgo();
          end
          S_T2YC: begin
            vyi_q[2] <= fp_res_q;
            fp_a_q <= vnd_q[2][2]; fp_b_q <= vpdz_q;
            fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2ZF; t_fpgo();
          end
          S_T2ZF: begin
            vz_q[2] <= fp_res_q;
            area_q <= area_w;
            // Unclipped triangle.  LINE walks the three edges.  POINT
            // plots one pixel at each vertex.  A clipped polygon stays
            // on the fill walker.  poly_mode is the raw VkPolygonMode
            // (FILL 0, LINE 1, POINT 2) as the pipeline stored it.
            if ((dr_q.poly_mode == 2'd1 || dr_q.poly_mode == 2'd2) &&
                !line_w && !point_w &&
                !clip_q && !pos_q[0][3][31] && !pos_q[1][3][31] &&
                !pos_q[2][3][31]) begin
              le_q <= 2'd0;
              poly_ln_q <= (dr_q.poly_mode == 2'd1);
              poly_pt_q <= (dr_q.poly_mode == 2'd2);
              ln_q <= 1'b1;
              varm_q <= dr_q.fs_in_mask;
              if (dr_q.fs_in_mask[0]) begin
                mp_we_q <= 1'b0;
                mp_addr_q <= {32'h0, vso_q} +
                             64'(f_pi(2'd0)) * 64'(VSTR) + 64'd16;
                mp_data_q <= '0; mp_strb_q <= '0;
                mp_ret_q <= S_LN_VF2;
                mp_acked_q <= 1'b0;
                st_q <= S_MPW;
              end else
                st_q <= S_LN_INIT;
            end else
              st_q <= S_PR_AREA;
          end
          // -- area, cull, top-left, bbox, rcp_area --------------------------
          S_PR_AREA: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast area=%0d (%016x) front=%0d cull=%0d ff=%0d xy=(%0d,%0d)(%0d,%0d)(%0d,%0d) t=%0t",
                     area_q, area_q, front_w, dr_q.cull, dr_q.front_ccw,
                     32'(vxi_q[0]), 32'(vyi_q[0]), 32'(vxi_q[1]),
                     32'(vyi_q[1]), 32'(vxi_q[2]), 32'(vyi_q[2]), $time);
`endif
// pragma translate_on
            // front = (signed area > 0) == front_ccw, evaluated on the
            // PRE-swap area; cull[0]=FRONT, cull[1]=BACK.  G2b: the
            // face/cull decision is taken once on the clipped
            // polygon's first fan tri; later fan tris share its
            // winding (degenerate-area still drops each tri)
            if (clip_q && cfan_q > 4'd1) begin
              if (area_q == 64'sd0) begin
                t_pd();
                st_q <= S_PR_I0;
              end else begin
                vsw_q <= (area_q < 64'sd0);
                if (area_q < 64'sd0) begin
                  area_q <= -area_q;
                  {vxi_q[1], vxi_q[2]} <= {vxi_q[2], vxi_q[1]};
                  {vyi_q[1], vyi_q[2]} <= {vyi_q[2], vyi_q[1]};
                  {vz_q[1], vz_q[2]}   <= {vz_q[2], vz_q[1]};
                  {vrw_q[1], vrw_q[2]} <= {vrw_q[2], vrw_q[1]};
                end
                st_q <= S_PR_SHF;
              end
            end else if (area_q == 64'sd0 ||
                         (front_w && dr_q.cull[0]) ||
                         (!front_w && dr_q.cull[1])) begin
              clip_q <= 1'b0;      // cull aborts the whole clip fan
              if (dr_q.topology != 8'd3) p_q <= p_q + 6'd1;
              else                       p_q <= p_q + 6'd3;
              st_q <= S_PR_I0;
            end else begin
              front_q <= front_w;
              vsw_q <= (area_q < 64'sd0);
              if (area_q < 64'sd0) begin
                // swap v1/v2: the math below sees a positive area
                area_q <= -area_q;
                {vxi_q[1], vxi_q[2]} <= {vxi_q[2], vxi_q[1]};
                {vyi_q[1], vyi_q[2]} <= {vyi_q[2], vyi_q[1]};
                {vz_q[1], vz_q[2]}   <= {vz_q[2], vz_q[1]};
                {vrw_q[1], vrw_q[2]} <= {vrw_q[2], vrw_q[1]};
              end
              // A1.3: same-facing primitives merge into the open FS
              // batch; a facing change with fragments pending flushes
              // first so the wave's per-batch FrontFacing bit stays
              // uniform.  slope_bias_late additionally flushes at every
              // primitive boundary so the late-Z bias sees a single
              // primitive's vz_q/span_w.  The flush runs the whole FS
              // wave + ROP and resumes here (S_PR_SHF) — the prim's
              // vertex/varying state is untouched by the flush.
              if (f_q != 6'd0 && (front_w != bat_front_q || slope_bias_late)) begin
                nf_q <= {1'b0, f_q}; f_q <= '0;
                flr_q <= S_PR_SHF;
                dret_q <= S_FLUSH; st_q <= S_DGATE;
              end else
                st_q <= S_PR_SHF;
            end
          end
          S_PR_SHF: begin
            shf_q <= (f_msb(area_q) > 6'd28) ? f_msb(area_q) - 6'd28
                                             : 6'd0;
            // edge geometry (post-swap order); E_k anchored at (k+1)%3,
            // direction to (k+2)%3
            ex_q[0]  <= vxi_q[1]; ey_q[0]  <= vyi_q[1];
            edx_q[0] <= vxi_q[2] - vxi_q[1];
            edy_q[0] <= vyi_q[2] - vyi_q[1];
            ex_q[1]  <= vxi_q[2]; ey_q[1]  <= vyi_q[2];
            edx_q[1] <= vxi_q[0] - vxi_q[2];
            edy_q[1] <= vyi_q[0] - vyi_q[2];
            ex_q[2]  <= vxi_q[0]; ey_q[2]  <= vyi_q[0];
            edx_q[2] <= vxi_q[1] - vxi_q[0];
            edy_q[2] <= vyi_q[1] - vyi_q[0];
            // top-left flags: include a zero edge iff it goes "up"
            // (anchor.y > end.y) or is a horizontal top edge (same y,
            // anchor.x < end.x); the opposite direction is never
            // top-left, so shared edges draw exactly once
            tl_q[0] <= (vyi_q[1] > vyi_q[2]) ||
                       (vyi_q[1] == vyi_q[2] && vxi_q[1] < vxi_q[2]);
            tl_q[1] <= (vyi_q[2] > vyi_q[0]) ||
                       (vyi_q[2] == vyi_q[0] && vxi_q[2] < vxi_q[0]);
            tl_q[2] <= (vyi_q[0] > vyi_q[1]) ||
                       (vyi_q[0] == vyi_q[1] && vxi_q[0] < vxi_q[1]);
            st_q <= S_PR_BBX;
          end
          S_PR_BBX: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast bbox empty=%0d x=[%0d,%0d] y=[%0d,%0d] sc=%0d,%0d %0dx%0d t=%0t",
                     bbox_empty, blo_x, bhi_x, blo_y, bhi_y,
                     dr_q.sc_x, dr_q.sc_y, dr_q.sc_w, dr_q.sc_h, $time);
`endif
// pragma translate_on
            if (bbox_empty) begin
              t_pd();
              st_q <= S_PR_I0;
            end else begin
              bx0_q <= 16'(blo_x); bx1_q <= 16'(bhi_x);
              by0_q <= 16'(blo_y); by1_q <= 16'(bhi_y);
              // G2b: the scan walks even-aligned 2x2 blocks, so the
              // cursor starts at the even pixel <= the bbox corner
              sx_q <= 16'(blo_x) & ~16'd1;
              sy_q <= 16'(blo_y) & ~16'd1;
              // I2F(area >> shf) then 1/x
              fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
              fp_a_q <= 32'(area_q >>> shf_q);
              fp_ret_q <= S_PR_RCI;
              t_fpgo();
            end
          end
          S_PR_RCI: begin
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= 32'h3F800000; fp_b_q <= fp_res_q;
            fp_ret_q <= S_PR_RCD;
            t_fpgo();
          end
          S_PR_RCD: begin
            rcpa_q <= fp_res_q;
            varm_q <= dr_q.fs_in_mask;
            lc_q <= '0;
            t_q <= '0;                       // vertex cursor for fetch
            st_q <= S_PR_VF;
          end
          // -- varying prefetch: masked locs × 3 verts → var_q --------------
          // (S_MPW chains the second word for mp_ret S_PR_VF/S_PR_VF2)
          S_PR_VF: begin
            if (lc_q == 4'd8) begin
              st_q <= S_SCAN;
            end else if (!varm_q[lc_q[2:0]]) begin
              lc_q <= lc_q + 4'd1;
            end else begin
              mp_we_q <= 1'b0;
              // vsw_q: slots 1/2 swapped at S_PR_AREA, so the record for
              // post-swap vertex t lives at f_pi of the mirrored index
              mp_addr_q <= {32'h0, clip_q ? clp_q : vso_q} +
                           64'(f_pi(vsw_q && t_q != 2'd0
                                    ? 2'd3 - t_q : t_q)) * 64'(VSTR) +
                           64'd16 + {28'h0, lc_q[2:0], 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_PR_VF;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          // -- scan loop: 2x2 blocks; a block with any covered pixel
          // emits four lane records (uncovered lanes = helpers) ------
          S_SCAN: begin
            if (sx_q > bx1_q) begin
              sx_q <= bx0_q & ~16'd1;
              if (sy_q >= by1_q) begin
                t_pd();
                // A1.3: no per-primitive flush — same-facing
                // primitives merge into the open batch; the batch
                // closes on prim-stream end (S_PR_I0), a facing
                // change (S_PR_AREA), or FSB full (S_F_LSET)
                st_q <= S_PR_I0;
              end else
                sy_q <= sy_q + 16'd2;
            end else if (blk_hit) begin
              lane_q <= 2'd0;
              help_q <= !f_lcov(2'd0);
              px_q   <= sx_q;
              py_q   <= sy_q;
              e_q[0] <= f_le(0, 2'd0);
              e_q[1] <= f_le(1, 2'd0);
              e_q[2] <= f_le(2, 2'd0);
              st_q <= S_F_LE0;
            end else
              sx_q <= sx_q + 16'd2;
          end
          // next lane of the block: reload its edge functions and
          // helper flag, then rerun the interpolation sequence
          S_F_LNEXT: begin
            help_q <= !f_lcov(lane_q);
            px_q   <= sx_q + {15'h0, lane_q[0]};
            py_q   <= sy_q + {15'h0, lane_q[1]};
            e_q[0] <= f_le(0, lane_q);
            e_q[1] <= f_le(1, lane_q);
            e_q[2] <= f_le(2, lane_q);
            st_q <= S_F_LE0;
          end
          // -- per-fragment fp sequence (RP2): jobs issue one per
          //    cycle; each step captures the previous job's result and
          //    issues the next.  Step order matches the original arms
          //    except the divide moved ahead of the last two FMADDs so
          //    the divider works in parallel with them.  rs_q is the
          //    partial-sum scratch until the reciprocal lands in it.
          S_F_LE0: begin
            if (ik_q <= 5'd13) begin
              unique case (ik_q)
                5'd0: begin   // CVT(e0)
                  fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
                  fp_a_q <= 32'(e_q[0] >>> shf_q);
                  fp_iss_q <= 1'b1;
                end
                5'd1: begin lam_q[0] <= cv_res;
                       fp_a_q <= 32'(e_q[1] >>> shf_q);
                       fp_iss_q <= 1'b1; end
                5'd2: begin lam_q[1] <= cv_res;
                       fp_a_q <= 32'(e_q[2] >>> shf_q);
                       fp_iss_q <= 1'b1; end
                5'd3: begin lam_q[2] <= cv_res;
                       fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
                       fp_a_q <= lam_q[0]; fp_b_q <= rcpa_q;
                       fp_iss_q <= 1'b1; end
                5'd4: begin lam_q[0] <= fma_res;
                       fp_a_q <= lam_q[1]; fp_b_q <= rcpa_q;
                       fp_iss_q <= 1'b1; end
                5'd5: begin lam_q[1] <= fma_res;
                       fp_a_q <= lam_q[2]; fp_b_q <= rcpa_q;
                       fp_iss_q <= 1'b1; end
                5'd6: begin lam_q[2] <= fma_res;
                       fp_a_q <= lam_q[0]; fp_b_q <= vrw_q[0];
                       fp_iss_q <= 1'b1; end
                5'd7: begin pv_q[0] <= fma_res;
                       fp_a_q <= lam_q[1]; fp_b_q <= vrw_q[1];
                       fp_iss_q <= 1'b1; end
                5'd8: begin pv_q[1] <= fma_res;
                       fp_a_q <= lam_q[2]; fp_b_q <= vrw_q[2];
                       fp_iss_q <= 1'b1; end
                5'd9: begin pv_q[2] <= fma_res;   // ADD(pv0,pv1)
                       fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
                       fp_a_q <= '0; fp_b_q <= pv_q[0]; fp_c_q <= pv_q[1];
                       fp_iss_q <= 1'b1; end
                5'd10: begin rs_q <= fma_res;      // FMADD(l0,z0,0)
                        fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
                        fp_a_q <= lam_q[0]; fp_b_q <= vz_q[0];
                        fp_c_q <= 32'h0;
                        fp_iss_q <= 1'b1; end
                5'd11: begin fz_q <= fma_res;      // ADD(partial,pv2)
                        fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
                        fp_a_q <= '0; fp_b_q <= rs_q; fp_c_q <= pv_q[2];
                        fp_iss_q <= 1'b1; end
                5'd12: begin rs_q <= fma_res;      // FMADD(l1,z1,z0)
                        fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
                        fp_a_q <= lam_q[1]; fp_b_q <= vz_q[1];
                        fp_c_q <= fz_q;
                        fp_iss_q <= 1'b1; end
                5'd13: begin fz_q <= fma_res;      // DIV(1.0,wsum)
                        fp_kind_q <= 2'd1; fp_o_q <= 2'd0;
                        fp_a_q <= 32'h3F800000; fp_b_q <= rs_q;
                        fp_iss_q <= 1'b1; end
                default: ;
              endcase
              ik_q <= ik_q + 5'd1;
            end else if (ik_q == 5'd14) begin
              // the divider holds its accepted operands in its input
              // pipe register, so fp_a_q/fp_b_q are free for the next
              // FMA job as soon as dq_ir shows acceptance
              if (dq_ir) begin
                fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
                fp_a_q <= lam_q[2]; fp_b_q <= vz_q[2]; fp_c_q <= fz_q;
                fp_iss_q <= 1'b1;
                ik_q <= ik_q + 5'd1;
              end
            end else if (ik_q == 5'd15) begin
              fz_q <= fma_res;                    // z = Σ λ·z
              fp_iss_q <= 1'b0;
              if (dq_ov) begin rs_q <= dq_res; rsd_q <= 1'b1; end
              ik_q <= ik_q + 5'd1;
            end else if (ik_q == 5'd16) begin
              if (rsd_q || dq_ov) begin
                if (dq_ov) rs_q <= dq_res;        // 1/wsum
                rsd_q <= 1'b0;
                ik_q   <= '0;
                st_q   <= S_F_PXI;
              end else if (!dr_q.da_valid || help_q || dr_q.fs_late) begin
                // FP6: on the direct-to-W0 path (no early-Z states
                // between here and S_F_W1) no fp job issues and no
                // second divider can run, so defer the 1/wsum wait:
                // rdiv_q arms the asynchronous dq_res capture and the
                // stall moves to S_F_W1, the first rs_q consumer.
                rdiv_q <= 1'b1;
                ik_q    <= '0;
                st_q    <= S_F_PXI;
              end
            end
          end
          S_F_PXI: begin
            // fz_q already holds Σ λ·z from the merged chain above
            conv_q[0] <= f_pxc(px_q);            // px+0.5, exact
            st_q <= S_F_PY2;
          end
          S_F_PY2: begin
            conv_q[1] <= f_pxc(py_q);            // py+0.5, exact
            // Depth bounds uses the raster window z, including when
            // the fragment shader will write FragDepth.  A miss is a
            // helper: no colour, depth, or stencil update.
            if (dr_q.depth_bounds_en && dr_q.da_valid && !help_q &&
                (f_f32_lt(zc_w, dr_q.depth_bounds_min) ||
                 f_f32_lt(dr_q.depth_bounds_max, zc_w))) begin
              help_q <= 1'b1;
              st_q <= S_F_W0;
            end else begin
            // helpers skip early-Z entirely (G2b); so do draws with
            // no depth attachment; G3a-i fs_late draws defer the test
            // to the ROP (slot-8 FragDepth / discard must be known)
            st_q <= (!dr_q.da_valid || help_q || dr_q.fs_late) ? S_F_W0
                    : (dr_q.depth_bias_en &&
                       (dr_q.depth_test || dr_q.depth_write)) ? S_DB0
                    : dr_q.depth_test ? S_DZ_RD
                    : dr_q.depth_write ? S_DZ_WR
                    : S_F_W0;
            if (dr_q.depth_bias_en && dr_q.da_valid && !help_q &&
                !dr_q.fs_late &&
                (dr_q.depth_test || dr_q.depth_write)) begin
              db_late_q <= 1'b0;
              db_ret_q  <= dr_q.depth_test ? S_DZ_RD : S_DZ_WR;
            end
            end
          end
          // ---- early-Z: read depth, compare, optionally write ----
          S_DZ_RD: begin
            mp_we_q <= 1'b0;
            mp_addr_q <= {32'h0, dr_q.da.base} +
                         64'(py_q) * 64'(dpitch_w) +
                         64'((32'(px_q) *
                              (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                               ? 32'd2 : 32'd4)) & ~64'd7);
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_DZ_DI;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_DZ_DI: begin
            if (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)) begin
              // u16 -> f32 then *1/65535
              fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b1;
              fp_a_q <= {16'h0, mp_res_q[16*px_q[1:0] +: 16]};
              fp_ret_q <= S_DZ_DM;
              t_fpgo();
            end else if (dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT)) begin
              stn_q <= mp_res_q[32*px_q[0] + 24 +: 8];
              std_q <= mp_res_q[32*px_q[0] +: 24];
              fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b1;
              fp_a_q <= {8'h0, mp_res_q[32*px_q[0] +: 24]};
              fp_ret_q <= S_DZ_DM;
              t_fpgo();
            end else begin
              dz_q <= mp_res_q[32*px_q[0] +: 32];
              st_q <= S_DZ_C2;
            end
          end
          S_DZ_DM: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_b_q <= (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM))
                      ? 32'h38008001 : 32'h33800001;
            fp_ret_q <= S_DZ_C2;
            t_fpgo();
          end
          S_DZ_C2: begin
            if (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM) ||
                dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT))
              dz_q <= fp_res_q;
            // stencil on D24S8.  A fail still writes the stencil byte
            // and does not write colour.  A pass updates the byte and
            // then takes the normal depth result.
            if (dr_q.stencil_en &&
                dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT) &&
                !f_scmp(st_cmp_w, stn_q, st_ref_w, st_cmask_w)) begin
              stn_q <= f_sop(st_fail_w, stn_q, st_ref_w, st_wmask_w);
              st_hold_q <= 1'b1;
              help_q <= 1'b1;
              st_q <= S_DZ_WR;
            end else if (dr_q.stencil_en &&
                dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT) &&
                !f_dcmp(dr_q.depth_op, zc_w, fp_res_q)) begin
              stn_q <= f_sop(st_dfail_w, stn_q, st_ref_w, st_wmask_w);
              st_hold_q <= 1'b1;
              help_q <= 1'b1;
              st_q <= S_DZ_WR;
            end else begin
              st_hold_q <= 1'b0;
              if (dr_q.stencil_en &&
                  dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT))
                stn_q <= f_sop(st_pass_w, stn_q, st_ref_w, st_wmask_w);
              if (!f_dcmp(dr_q.depth_op, zc_w,
                          (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM) ||
                           dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT))
                          ? fp_res_q : dz_q)) begin
                help_q <= 1'b1;
                st_q <= S_F_W0;
              end else if (dr_q.depth_write ||
                           (dr_q.stencil_en &&
                            dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT)))
                st_q <= S_DZ_WR;
              else
                st_q <= S_F_W0;
            end
          end
          S_DZ_WR: begin
            if (wq_ok) begin
              t_wq({32'h0, dr_q.da.base} +
                   64'(py_q) * 64'(dpitch_w) +
                   64'((32'(px_q) *
                        (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                         ? 32'd2 : 32'd4)) & ~64'd7),
                   dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                   ? {4{f_f32_u16(zc_w)}}
                   : dr_q.da.fmt == 8'(APU_IMG_FMT_D24_UNORM_S8_UINT)
                   ? {2{stn_q, st_hold_q ? std_q : f_f32_u24(zc_w)}}
                   : {2{zc_w}},
                   dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                   ? 8'h03 << {px_q[1:0], 1'b0}
                   : 8'h0F << {px_q[0], 2'b00});
              st_q <= S_F_W0;
            end
          end
          // write fs_in slot0 {px+.5, py+.5, z, rcp_s}
          S_F_W0: begin
            if (wq_ok) begin
              t_wq({32'h0, fsi_wr_w} + {26'h0, f_q} * 64'(VSTR),
                   {conv_q[1], conv_q[0]}, 8'hFF);
              st_q <= S_F_W1;
            end
          end
          S_F_W1: begin
            // FP6: rdiv_q still armed means the deferred 1/wsum capture
            // has not landed — hold the {rs_q,fz_q} record write until
            // rs_q is valid (dq_ov grab in the always_ff tail).
            if (wq_ok && !rdiv_q) begin
              t_wq({32'h0, fsi_wr_w} + {26'h0, f_q} * 64'(VSTR) + 64'd8,
                   {rs_q, fz_q}, 8'hFF);
              lc_q <= '0;
              st_q <= S_F_LSET;
            end
          end
          // per-location interpolation
          S_F_LSET: begin
            if (lc_q == 4'd8) begin
              // fragment complete: record pixel + helper flag, then
              // the next lane of the 2x2 block (or the next block).
              // f_q is always ≡0 mod 4 at a block boundary, so a
              // batch-full flush can only split between blocks.
              // A line emits one fragment per pixel and returns to
              // the Bresenham step instead of the triangle scan.
              fsxy_q[wr_bank_q][f_q]   <= {py_q, px_q};
              fs_help_q[wr_bank_q][f_q] <= help_q;
              fsz_q[wr_bank_q][f_q]    <= fz_q;
              // A1.3: the first fragment of a fresh batch adopts the
              // accepting primitive's facing — a mid-draw flush
              // (facing change) keeps emitting the OLD batch's bit
              if (f_q == 6'd0) begin
                bat_front_q <= ln_q ? 1'b1 : front_q;
                // FP6-overlap: snapshot this batch's per-primitive late-Z
                // slope while vz_q/span_w still belong to the producing
                // primitive (a prim-boundary S_FLUSH already sees the
                // next prim's values, so the capture must happen here at
                // frag-production, not at flush).  Indexed by wr_bank_q
                // like the frag flops; only the late-Z drain path reads it.
                for (int i = 0; i < 3; i++) ds_vz_q[wr_bank_q][i] <= vz_q[i];
                ds_span_q[wr_bank_q] <= span_w;
              end
              if (ln_q) begin
                if ({1'b0, f_q} + 7'd1 == 7'(FSB)) begin
                  nf_q <= {1'b0, f_q} + 7'd1; f_q <= '0;
                  flr_q <= S_LN_STEP;
                  dret_q <= S_FLUSH; st_q <= S_DGATE;
                end else begin
                  f_q  <= f_q + 6'd1;
                  st_q <= S_LN_STEP;
                end
              end else begin
              lane_q <= lane_q + 2'd1;
              if ({1'b0, f_q} + 7'd1 == 7'(FSB)) begin
                nf_q <= {1'b0, f_q} + 7'd1; f_q <= '0;
                if (lane_q == 2'd3) sx_q <= sx_q + 16'd2;
                flr_q <= (lane_q == 2'd3) ? S_SCAN : S_F_LNEXT;
                dret_q <= S_FLUSH; st_q <= S_DGATE;
              end else begin
                f_q <= f_q + 6'd1;
                if (lane_q == 2'd3) sx_q <= sx_q + 16'd2;
                st_q <= (lane_q == 2'd3) ? S_SCAN : S_F_LNEXT;
              end
              end
            end else if (!varm_q[lc_q[2:0]]) begin
              lc_q <= f_nvar(varm_q, lc_q);
            end else begin
              c_q <= '0;
              st_q <= S_F_V0;
            end
          end
          S_F_V0: begin
            // per-location varying chain (RP2 + FP6-opt(i)): the 16
            // jobs form 4 independent per-component chains, so they
            // issue as 8 component PAIRS, two per cycle — ik_q counts
            // pair-steps 0..8 (8=done).  Step p covers jobs {2p,2p+1}:
            //   op = p[2:1]: 0 MUL pv0*V0[c]   1 FMADD pv1*V1[c]+acc
            //                 2 FMADD pv2*V2[c]+acc   3 MUL acc*rs_q
            //   lane A (i_fma) -> comp fp_ca, lane B (i_fma2) -> fp_cb.
            // The two jobs in a pair are the same op on adjacent
            // components — independent, so both lanes run in parallel;
            // per-component op order is unchanged (bit-identical).
            // conv_q[c] is the per-component accumulator: a pair-step
            // captures the previous pair's two results one cycle after
            // issue; the comp-pairs alternate {0,1}/{2,3} so the capture
            // and the next issue never touch the same conv_q slot.
            if (ik_q != 5'd0) begin
              conv_q[fp_pa] <= fma_res;
              conv_q[fp_pb] <= fma2_res;
              fp_res_q <= fma2_res;
            end
            if (ik_q == 5'd8) begin
              fp_iss_q <= 1'b0; fp2_iss_q <= 1'b0;
              ik_q <= '0; st_q <= S_F_VW0;
            end else begin
              fp_kind_q <= 2'd0; fp_mod_q <= 1'b0; fp_iss_q <= 1'b1;
              fp2_mod_q <= 1'b0; fp2_iss_q <= 1'b1;
              unique case (fp_op)
                2'd0: begin  // op0: pv0*V0[c]
                  fp_o_q <= 2'd2; fp_a_q <= pv_q[0];
                  fp_b_q <= var_q[0][lc_q[2:0]][fp_ca];
                  fp_c_q <= '0;
                  fp2_o_q <= 2'd2; fp2_a_q <= pv_q[0];
                  fp2_b_q <= var_q[0][lc_q[2:0]][fp_cb];
                  fp2_c_q <= '0;
                end
                2'd1: begin  // op1: pv1*V1[c]+conv[c]
                  fp_o_q <= 2'd0; fp_a_q <= pv_q[1];
                  fp_b_q <= var_q[1][lc_q[2:0]][fp_ca];
                  fp_c_q <= conv_q[fp_ca];
                  fp2_o_q <= 2'd0; fp2_a_q <= pv_q[1];
                  fp2_b_q <= var_q[1][lc_q[2:0]][fp_cb];
                  fp2_c_q <= conv_q[fp_cb];
                end
                2'd2: begin  // op2: pv2*V2[c]+conv[c]
                  fp_o_q <= 2'd0; fp_a_q <= pv_q[2];
                  fp_b_q <= var_q[2][lc_q[2:0]][fp_ca];
                  fp_c_q <= conv_q[fp_ca];
                  fp2_o_q <= 2'd0; fp2_a_q <= pv_q[2];
                  fp2_b_q <= var_q[2][lc_q[2:0]][fp_cb];
                  fp2_c_q <= conv_q[fp_cb];
                end
                default: begin  // op3: conv[c]*rs_q
                  fp_o_q <= 2'd2; fp_a_q <= conv_q[fp_ca];
                  fp_b_q <= rs_q; fp_c_q <= '0;
                  fp2_o_q <= 2'd2; fp2_a_q <= conv_q[fp_cb];
                  fp2_b_q <= rs_q; fp2_c_q <= '0;
                end
              endcase
              ik_q <= ik_q + 5'd1;
            end
          end
          S_F_VW0: begin
            if (wq_ok) begin
              t_wq({32'h0, fsi_wr_w} + {26'h0, f_q} * 64'(VSTR) +
                   64'd16 + {28'h0, lc_q[2:0], 4'h0},
                   {conv_q[1], conv_q[0]}, 8'hFF);
              st_q <= S_F_VW1;
            end
          end
          S_F_VW1: begin
            if (wq_ok) begin
              t_wq({32'h0, fsi_wr_w} + {26'h0, f_q} * 64'(VSTR) +
                   64'd16 + {28'h0, lc_q[2:0], 4'h0} + 64'd8,
                   {conv_q[3], conv_q[2]}, 8'hFF);
              // land the cursor on the next ACTIVE location (nva_w) or 8
              // = fragment done; a hit goes straight to V0 and skips the
              // LSET dispatch cycle, masked-off slots cost nothing.
              lc_q <= nva_w;
              c_q  <= '0;
              st_q <= (nva_w == 4'd8) ? S_F_LSET : S_F_V0;
            end
          end
          // ---- 1 px line list / strip (Bresenham) ----------------------
          S_LN_VF2: begin
            var_q[0][0][0] <= mp_res_q[31:0];
            var_q[0][0][1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_LN_VF3;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_LN_VF3: begin
            var_q[0][0][2] <= mp_res_q[31:0];
            var_q[0][0][3] <= mp_res_q[63:32];
            st_q <= S_LN_INIT;
          end
          S_LN_INIT: begin
            lx_q  <= 16'(vxi_q[l0_w] >>> 8);
            ly_q  <= 16'(vyi_q[l0_w] >>> 8);
            lxe_q <= 16'(vxi_q[l1_w] >>> 8);
            lye_q <= 16'(vyi_q[l1_w] >>> 8);
            ldx_q <= (vxi_q[l0_w] >>> 8) >= (vxi_q[l1_w] >>> 8)
                     ? 16'((vxi_q[l0_w] >>> 8) - (vxi_q[l1_w] >>> 8))
                     : 16'((vxi_q[l1_w] >>> 8) - (vxi_q[l0_w] >>> 8));
            ldy_q <= (vyi_q[l0_w] >>> 8) >= (vyi_q[l1_w] >>> 8)
                     ? 16'((vyi_q[l0_w] >>> 8) - (vyi_q[l1_w] >>> 8))
                     : 16'((vyi_q[l1_w] >>> 8) - (vyi_q[l0_w] >>> 8));
            lxs_q <= ((vxi_q[l0_w] >>> 8) < (vxi_q[l1_w] >>> 8))
                     ? 16'sd1 : -16'sd1;
            lys_q <= ((vyi_q[l0_w] >>> 8) < (vyi_q[l1_w] >>> 8))
                     ? 16'sd1 : -16'sd1;
            lerr_q <= 17'((vxi_q[l0_w] >>> 8) >= (vxi_q[l1_w] >>> 8)
                          ? (vxi_q[l0_w] >>> 8) - (vxi_q[l1_w] >>> 8)
                          : (vxi_q[l1_w] >>> 8) - (vxi_q[l0_w] >>> 8))
                      - 17'((vyi_q[l0_w] >>> 8) >= (vyi_q[l1_w] >>> 8)
                            ? (vyi_q[l0_w] >>> 8) - (vyi_q[l1_w] >>> 8)
                            : (vyi_q[l1_w] >>> 8) - (vyi_q[l0_w] >>> 8));
            pv_q[0] <= 32'h3F800000;
            pv_q[1] <= '0;
            pv_q[2] <= '0;
            rs_q    <= 32'h3F800000;
            fz_q    <= poly_pt_q ? vz_q[l0_w] : vz_q[0];
            help_q  <= 1'b0;
            st_q    <= S_LN_PIX;
          end
          S_LN_PIX: begin
            if (lx_q < 16'sd0 || ly_q < 16'sd0 ||
                lx_q < signed'(dr_q.sc_x) || ly_q < signed'(dr_q.sc_y) ||
                lx_q >= signed'(dr_q.sc_x) + signed'(dr_q.sc_w) ||
                ly_q >= signed'(dr_q.sc_y) + signed'(dr_q.sc_h))
              st_q <= S_LN_STEP;
            else begin
              px_q  <= 16'(lx_q);
              py_q  <= 16'(ly_q);
              lc_q  <= '0;
              c_q   <= '0;
              st_q  <= S_F_LSET;
            end
          end
          S_LN_STEP: begin
            if (lx_q == lxe_q && ly_q == lye_q) begin
              if ((poly_ln_q || poly_pt_q) && le_q != 2'd2) begin
                // A polygon point takes that vertex's attributes.
                // The line edges stay flat from vertex 0.
                if (poly_pt_q && dr_q.fs_in_mask[0]) begin
                  mp_we_q <= 1'b0;
                  mp_addr_q <= {32'h0, vso_q} +
                               64'(f_pi(le_q + 2'd1)) * 64'(VSTR) + 64'd16;
                  mp_data_q <= '0; mp_strb_q <= '0;
                  mp_ret_q <= S_LN_VF2;
                  mp_acked_q <= 1'b0;
                  le_q <= le_q + 2'd1;
                  st_q <= S_MPW;
                end else begin
                  le_q <= le_q + 2'd1;
                  st_q <= S_LN_INIT;
                end
              end else begin
              poly_ln_q <= 1'b0;
              poly_pt_q <= 1'b0;
              ln_q <= 1'b0;
              t_pd();
              if (f_q != 6'd0) begin
                nf_q <= {1'b0, f_q}; f_q <= '0;
                flr_q <= S_PR_I0;
                dret_q <= S_FLUSH; st_q <= S_DGATE;
              end else
                st_q <= S_PR_I0;
              end
            end else begin
              if ((32'(lerr_q) <<< 1) > -32'(ldy_q) &&
                  (32'(lerr_q) <<< 1) < 32'(ldx_q)) begin
                lerr_q <= lerr_q - 17'(ldy_q) + 17'(ldx_q);
                lx_q   <= lx_q + lxs_q;
                ly_q   <= ly_q + lys_q;
              end else if ((32'(lerr_q) <<< 1) > -32'(ldy_q)) begin
                lerr_q <= lerr_q - 17'(ldy_q);
                lx_q   <= lx_q + lxs_q;
              end else begin
                lerr_q <= lerr_q + 17'(ldx_q);
                ly_q   <= ly_q + lys_q;
              end
              st_q <= S_LN_PIX;
            end
          end
          // constantFactor * r, plus slopeFactor * max|dz|/span,
          // then depthBiasClamp, then add to z.
          S_DB0: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= dr_q.depth_bias_const;
            fp_b_q <= (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM))
                      ? 32'h37800000 : 32'h3F800000;
            fp_ret_q <= S_DBCR;
            t_fpgo();
          end
          S_DBCR: begin
            db_cr_q <= fp_res_q;
            if (point_w || line_w || poly_ln_q || poly_pt_q ||
                dr_q.depth_bias_slope[30:0] == 31'h0)
              st_q <= S_DB1;
            else begin
              fp_b_q <= svz1_w; fp_c_q <= svz0_w;
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_ret_q <= S_DS0;
              t_fpgo();
            end
          end
          S_DS0: begin
            db_dz_q <= {1'b0, fp_res_q[30:0]};
            fp_b_q <= svz2_w; fp_c_q <= svz0_w;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_ret_q <= S_DS1;
            t_fpgo();
          end
          S_DS1: begin
            if (f_f32_lt(db_dz_q, {1'b0, fp_res_q[30:0]}))
              db_dz_q <= {1'b0, fp_res_q[30:0]};
            fp_b_q <= svz2_w; fp_c_q <= svz1_w;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_ret_q <= S_DS2;
            t_fpgo();
          end
          S_DS2: begin
            if (f_f32_lt(db_dz_q, {1'b0, fp_res_q[30:0]}))
              db_dz_q <= {1'b0, fp_res_q[30:0]};
            fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= {16'h0, sspan_w};
            fp_ret_q <= S_DS3;
            t_fpgo();
          end
          S_DS3: begin
            fp_kind_q <= 2'd1; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= db_dz_q; fp_b_q <= fp_res_q;
            fp_ret_q <= S_DS4;
            t_fpgo();
          end
          S_DS4: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= dr_q.depth_bias_slope; fp_b_q <= fp_res_q;
            fp_ret_q <= S_DS5;
            t_fpgo();
          end
          S_DS5: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= 32'h3F800000; fp_b_q <= fp_res_q; fp_c_q <= db_cr_q;
            fp_ret_q <= S_DB1;
            t_fpgo();
          end
          S_DB1: begin
            if (dr_q.depth_bias_clamp[30:0] != 31'h0 &&
                !dr_q.depth_bias_clamp[31] &&
                f_f32_lt(dr_q.depth_bias_clamp, fp_res_q))
              db_bias_q <= dr_q.depth_bias_clamp;
            else if (dr_q.depth_bias_clamp[31] &&
                     dr_q.depth_bias_clamp[30:0] != 31'h0 &&
                     f_f32_lt(fp_res_q, dr_q.depth_bias_clamp))
              db_bias_q <= dr_q.depth_bias_clamp;
            else
              db_bias_q <= fp_res_q;
            st_q <= S_DB1B;
          end
          S_DB1B: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= 32'h3F800000;
            fp_b_q <= db_late_q ? lz_q : fz_q;
            fp_c_q <= db_bias_q;
            fp_ret_q <= S_DB2;
            t_fpgo();
          end
          S_DB2: begin
            if (db_late_q) lz_q <= fp_res_q;
            else           fz_q <= fp_res_q;
            db_done_q <= 1'b1;
            st_q <= db_ret_q;
          end
          // ---- FS batch flush ----------------------------------------------
          S_FLUSH: begin
            // RP4: hold the FS wave launch while record writes are
            // still queued — same drain rule as S_VS_ISS.
            if (!wq_v_q[0]) begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
              if (!shv_q)
                $display("[DBG] rast flush: nf=%0d ret=%0d t=%0t",
                         nf_q, flr_q, $time);
`endif
// pragma translate_on
              sh_ctype_o <= APU_SH_WORK_FS;
              sh_slot_o <= dr_q.fs_slot;
              sh_imm_o[0] <= {25'h0, nf_q};
              sh_imm_o[1] <= fsi_wr_w;
              sh_imm_o[2] <= fso_q;
              // imm[3].0 = the batch's front-facing bit for the
              // FrontFacing builtin; uniform because a facing change
              // flushes the open batch before the new primitive scans
              sh_imm_o[3] <= {31'h0, bat_front_q}; sh_imm_o[4] <= '0;
              // imm[5]/imm[6] = per-record helper-lane mask (bits
              // [223:160] of the dispatch payload — the wave engine
              // suppresses helper side effects: atomics, image writes,
              // device-memory stores)
              for (int i = 0; i < 32; i++) begin
                sh_imm_o[5][i] <= fs_help_q[wr_bank_q][i];
                sh_imm_o[6][i] <= fs_help_q[wr_bank_q][i + 32];
              end
              sh_imm_o[7] <= '0;
              shv_q <= 1'b1;
              if (shv_q && sh_work_ready_i) begin
                shv_q <= 1'b0;
                shd_q <= 1'b0; fshd_q <= 1'b0;
                // FP6 overlap: the just-launched wave becomes the
                // pending drain (pend_bank_q/dnf_q) the NEXT flush's
                // S_DGATE->S_FS_WAIT->S_ROP consumes; frag production
                // resumes immediately into the other bank (wr_bank_q
                // toggles) so interp hides the shader+ROP drain.
              pend_v_q    <= 1'b1;
                pend_bank_q <= wr_bank_q;
                dnf_q       <= nf_q;
                wr_bank_q   <= ~wr_bank_q;
                st_q <= flr_q;
              end
            end
          end
          // FP6: frag-batch flush gate — drain the previously launched
          // wave (its FS/ROP work ran under the batch just produced)
          // before launching this batch's wave, unless this is the
          // first batch (no pend).  dret_q is where control goes once
          // the drain finishes (S_FLUSH to launch, S_FIN_OK at draw end)
          // or immediately when there is nothing to drain.
          S_DGATE: begin
            if (pend_v_q) st_q <= S_FS_WAIT;
            else          st_q <= dret_q;
          end
          S_FS_WAIT:
            if (fshd_q) begin
              fshd_q <= 1'b0;
              if (fsdp_q.code != APU_SH_DONE_OK) begin
                code_q <= fsdp_q.code;
                st_q <= S_FIN_BAD;
              end else begin
                robust_q <= robust_q + fsdp_q.robust;
                r_q <= '0; at_q <= '0; lzdone_q <= 1'b0;
                st_q <= S_ROP_R0;
              end
            end
          // ---- ROP: per fragment × per valid attachment ---------------
          // FS-out location l -> ca[l]; dst read-back + f32 blend when
          // enabled, per-format encode, colorWriteMask strobes
          S_ROP_R0: begin
            db_done_q <= 1'b0;
            if (fs_help_q[pend_bank_q][r_q]) begin
              // helper invocation: it only exists to complete the
              // derivative quad — never let it reach a pixel write
              at_q <= '0; lzdone_q <= 1'b0;
              if ({1'b0, r_q} + 7'd1 >= dnf_q) begin pend_v_q <= 1'b0; st_q <= dret_q; end
              else begin
                r_q <= r_q + 6'd1;
                st_q <= S_ROP_R0;
              end
            end else if (dr_q.fs_late && !lzdone_q) begin
              // G3a-i: read FS-out record slot 8 (word0 FragDepth,
              // word1 flags bit0 discard) before any attachment work
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, fso_q} +
                           {26'h0, r_q} * 64'(ASTR) +
                           64'(APU_SH_FSOUT_BI * 16);
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_ROP_F8;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end else if (!dr_q.ca_valid[at_q]) begin
              // skip an absent attachment; at 3 the fragment is done
              if (at_q == 2'd3) begin
                at_q <= '0; lzdone_q <= 1'b0;
                if ({1'b0, r_q} + 7'd1 >= dnf_q) begin pend_v_q <= 1'b0; st_q <= dret_q; end
                else begin
                  r_q <= r_q + 6'd1;
                  st_q <= S_ROP_R0;
                end
              end else
                at_q <= at_q + 2'd1;
            end else begin
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, fso_q} +
                           {26'h0, r_q} * 64'(ASTR) +
                           {28'h0, at_q, 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_ROP_R1;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          S_ROP_R1: begin
            src_q[0] <= mp_res_q[31:0];
            src_q[1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_ROP_R2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_ROP_R2: begin
            src_q[2] <= mp_res_q[31:0];
            src_q[3] <= mp_res_q[63:32];
            if (dr_q.logic_op_en) begin
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, dr_q.ca[at_q].base} +
                           64'(fr_py) * 64'(cpitch_w) +
                           64'((32'(fr_px) * 32'd4) & ~64'd7);
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_ROP_LOP;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end else if (!dr_q.blend[at_q].en) begin
              res_q <= {mp_res_q[63:32], mp_res_q[31:0],
                        src_q[1], src_q[0]};
              st_q <= S_ROP_WR;
            end else begin
              // blend needs the dst texel decoded to f32
              c_q <= '0; dd_q <= '0;
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, dr_q.ca[at_q].base} +
                           64'(fr_py) * 64'(cpitch_w) +
                           64'((32'(fr_px) * 32'd4) & ~64'd7);
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_ROP_DI;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          // ---- G3a-i late-Z: slot-8 flags/FragDepth, then the ----
          // depth test+write that fs_late deferred from early-Z ----
          S_ROP_F8: begin
            if (mp_res_q[32]) begin
              // discard flag: no colour, no depth — next fragment
              at_q <= '0; lzdone_q <= 1'b0;
              if ({1'b0, r_q} + 7'd1 >= dnf_q) begin pend_v_q <= 1'b0; st_q <= dret_q; end
              else begin
                r_q <= r_q + 6'd1;
                st_q <= S_ROP_R0;
              end
            end else begin
              lz_q <= dr_q.fs_fdepth ? mp_res_q[31:0] : fsz_q[pend_bank_q][r_q];
              if (dr_q.da_valid &&
                  (dr_q.depth_test || dr_q.depth_write))
                st_q <= S_ROP_LRD;
              else begin
                lzdone_q <= 1'b1;
                st_q <= S_ROP_R0;
              end
            end
          end
          S_ROP_LRD: begin
            mp_we_q <= 1'b0;
            mp_addr_q <= {32'h0, dr_q.da.base} +
                         64'(fr_py) * 64'(dpitch_w) +
                         64'((32'(fr_px) *
                              (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                               ? 32'd2 : 32'd4)) & ~64'd7);
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_ROP_LDI;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_ROP_LDI: begin
            if (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)) begin
              fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b1;
              fp_a_q <= {16'h0, mp_res_q[16*fr_px[1:0] +: 16]};
              fp_ret_q <= S_ROP_LDM;
              t_fpgo();
            end else begin
              dz_q <= mp_res_q[32*fr_px[0] +: 32];
              st_q <= S_ROP_LC;
            end
          end
          S_ROP_LDM: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_b_q <= 32'h38008001;              // *1/65535
            fp_ret_q <= S_ROP_LC;
            t_fpgo();
          end
          S_ROP_LC: begin
            if (dr_q.depth_bias_en && !db_done_q) begin
              db_late_q <= 1'b1;
              db_ret_q  <= S_ROP_LC;
              st_q <= S_DB0;
            end else begin
            db_done_q <= 1'b0;
            if (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM))
              dz_q <= fp_res_q;
            if (!f_dcmp(dr_q.depth_op, lzc_w,
                        dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                        ? fp_res_q : dz_q)) begin
              // late-Z fail: neither colour nor depth — next fragment
              at_q <= '0; lzdone_q <= 1'b0;
              if ({1'b0, r_q} + 7'd1 >= dnf_q) begin pend_v_q <= 1'b0; st_q <= dret_q; end
              else begin
                r_q <= r_q + 6'd1;
                st_q <= S_ROP_R0;
              end
            end else if (dr_q.depth_write) begin
              lzdone_q <= 1'b1;
              st_q <= S_ROP_LWR;
            end else begin
              lzdone_q <= 1'b1;
              st_q <= S_ROP_R0;
            end
            end
          end
          S_ROP_LWR: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, dr_q.da.base} +
                         64'(fr_py) * 64'(dpitch_w) +
                         64'((32'(fr_px) *
                              (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                               ? 32'd2 : 32'd4)) & ~64'd7);
            mp_data_q <=
              dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
              ? {4{f_f32_u16(lzc_w)}} : {2{lzc_w}};
            mp_strb_q <=
              dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
              ? 8'h03 << {fr_px[1:0], 1'b0}
              : 8'h0F << {fr_px[0], 2'b00};
            mp_ret_q <= S_ROP_R0;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          // dst decode: UNORM byte -> I2F *1/255; sRGB -> LUT16 -> I2F
          // *1/65535 (alpha stays on the linear byte path)
          // dst decode: UNORM byte -> I2F *1/255; sRGB -> LUT16 -> I2F
          // *1/65535 (alpha stays on the linear byte path).  RP3: the
          // eight per-channel jobs (4x I2F on i_cvt, 4x scale-MUL on
          // i_fma) issue back-to-back one per cycle and each step
          // captures the previous job's result — the S_F_LE0 in-order
          // discipline, since both units are ~1-cycle here.  dd_q==8
          // lands the last MUL, then runs 1-dst.a through the normal
          // fp wait so S_BL_SAT captures it and picks the blend op.
          S_ROP_DI: begin
            if (dd_q != 4'd8) begin
              fp_iss_q <= 1'b1;
              unique case (dd_q)
                4'd0: begin fp_kind_q <= 2'd2; fp_o_q <= 2'd0;
                       fp_mod_q <= 1'b1; fp_a_q <= f_dec_i2f(2'd0); end
                4'd1: begin dcv_q[0] <= cv_res;
                       fp_kind_q <= 2'd2; fp_o_q <= 2'd0;
                       fp_mod_q <= 1'b1; fp_a_q <= f_dec_i2f(2'd1); end
                4'd2: begin dcv_q[1] <= cv_res;
                       fp_kind_q <= 2'd2; fp_o_q <= 2'd0;
                       fp_mod_q <= 1'b1; fp_a_q <= f_dec_i2f(2'd2); end
                4'd3: begin dcv_q[2] <= cv_res;
                       fp_kind_q <= 2'd2; fp_o_q <= 2'd0;
                       fp_mod_q <= 1'b1; fp_a_q <= f_dec_i2f(2'd3); end
                4'd4: begin dcv_q[3] <= cv_res;
                       fp_kind_q <= 2'd0; fp_o_q <= 2'd2;
                       fp_mod_q <= 1'b0;
                       fp_a_q <= dcv_q[0];
                       fp_b_q <= f_dec_scale(2'd0); end
                4'd5: begin dst_q[0] <= fma_res;
                       fp_kind_q <= 2'd0; fp_o_q <= 2'd2;
                       fp_mod_q <= 1'b0;
                       fp_a_q <= dcv_q[1];
                       fp_b_q <= f_dec_scale(2'd1); end
                4'd6: begin dst_q[1] <= fma_res;
                       fp_kind_q <= 2'd0; fp_o_q <= 2'd2;
                       fp_mod_q <= 1'b0;
                       fp_a_q <= dcv_q[2];
                       fp_b_q <= f_dec_scale(2'd2); end
                4'd7: begin dst_q[2] <= fma_res;
                       fp_kind_q <= 2'd0; fp_o_q <= 2'd2;
                       fp_mod_q <= 1'b0;
                       fp_a_q <= dcv_q[3];
                       fp_b_q <= f_dec_scale(2'd3); end
                default: ;
              endcase
              dd_q <= dd_q + 4'd1;
              st_q <= S_ROP_DI;
            end else begin
              dst_q[3] <= fma_res;
              // precompute 1 - dst.a for SRC_ALPHA_SATURATE
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= 32'h3F800000; fp_c_q <= fma_res;
              fp_ret_q <= S_BL_SAT;
              t_fpgo();
            end
          end
          S_BL_SAT: begin
            omd3_q <= fp_res_q;
            c_q <= '0;
            st_q <= (dr_q.blend[at_q].op_c >= 3'd3) ? S_BL_MM
                                                    : S_BL_F1;
          end
          // MIN/MAX ignore the factors (fp f32 compare in int domain)
          S_BL_MM: begin
            res_q[c_q[1:0]] <=
              (bop_w == APU_RAST_BO_MIN)
              ? (f_f32_lt(src_q[c_q[1:0]], dst_q[c_q[1:0]])
                 ? src_q[c_q[1:0]] : dst_q[c_q[1:0]])
              : (f_f32_lt(dst_q[c_q[1:0]], src_q[c_q[1:0]])
                 ? src_q[c_q[1:0]] : dst_q[c_q[1:0]]);
            if (c_q[1:0] == 2'd3) st_q <= S_ROP_WR;
            else begin
              c_q <= c_q + 3'd1;
              st_q <= (c_q[1:0] == 2'd2 &&
                       dr_q.blend[at_q].op_a >= 3'd3) ? S_BL_MM
                      : (c_q[1:0] == 2'd2 ||
                         dr_q.blend[at_q].op_c < 3'd3) ? S_BL_F1
                      : S_BL_MM;
            end
          end
          // factor selects: ONE_MINUS_* issue SUB(1.0, base)
          S_BL_F1: begin
            if (f_fminus(bsf_w)) begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= 32'h3F800000;
              fp_c_q <= f_fbase(bsf_w, c_q[1:0]);
              fp_ret_q <= S_BL_F1B;
              t_fpgo();
            end else begin
              // RP3: fuse S_BL_F2's dst-factor dispatch here (S_BL_F1B does
              // the same for the OM-src path), leaving S_BL_F2 unreachable.
              // sf_q captures f_fbase(bsf_w) this cycle; the src*sf operand
              // uses f_fbase(bsf_w) directly since sf_q is not yet updated.
              sf_q <= f_fbase(bsf_w, c_q[1:0]);
              if (f_fminus(bdf_w)) begin
                fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
                fp_a_q <= '0;
                fp_b_q <= 32'h3F800000;
                fp_c_q <= f_fbase(bdf_w, c_q[1:0]);
                fp_ret_q <= S_BL_F2B;
                t_fpgo();
              end else begin
                df_q <= f_fbase(bdf_w, c_q[1:0]);
                fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
                fp_a_q <= src_q[c_q[1:0]];
                fp_b_q <= f_fbase(bsf_w, c_q[1:0]);
                fp_ret_q <= S_BL_M2;
                t_fpgo();
              end
            end
          end
          S_BL_F1B: begin
            // RP3: fuse the src-factor capture with S_BL_F2's dst-factor
            // dispatch, which would otherwise cost a dedicated cycle. On the
            // non-ONE_MINUS dst path the src*sf FMA is issued inline; its sf
            // operand is fp_res_q (the value sf_q is capturing this cycle),
            // not sf_q, since nonblocking captures have not yet updated it.
            sf_q <= fp_res_q;
            if (f_fminus(bdf_w)) begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= 32'h3F800000;
              fp_c_q <= f_fbase(bdf_w, c_q[1:0]);
              fp_ret_q <= S_BL_F2B;
              t_fpgo();
            end else begin
              df_q <= f_fbase(bdf_w, c_q[1:0]);
              fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
              fp_a_q <= src_q[c_q[1:0]]; fp_b_q <= fp_res_q;
              fp_ret_q <= S_BL_M2;
              t_fpgo();
            end
          end
          S_BL_F2B: begin
            // RP3: fuse the dst-factor capture with the src*sf FMA issue that
            // S_BL_M1 would otherwise spend a dedicated cycle on. df_q is not
            // an operand of this job (it feeds S_BL_M2 two jobs later), and
            // src_q/sf_q are already stable, so the merge is operand-safe.
            df_q <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= src_q[c_q[1:0]]; fp_b_q <= sf_q;
            fp_ret_q <= S_BL_M2;
            t_fpgo();
          end
          S_BL_M2: begin
            bm1_q <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= dst_q[c_q[1:0]]; fp_b_q <= df_q;
            fp_ret_q <= S_BL_OP;
            t_fpgo();
          end
          S_BL_OP: begin
            bm2_q <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1;
            fp_a_q <= '0;
            // ADD: b+c; SUBTRACT: s-d; REVERSE_SUBTRACT: d-s
            fp_b_q <= (bop_w == APU_RAST_BO_REVERSE_SUBTRACT)
                      ? fp_res_q : bm1_q;
            fp_c_q <= (bop_w == APU_RAST_BO_REVERSE_SUBTRACT)
                      ? bm1_q : fp_res_q;
            fp_mod_q <= (bop_w != APU_RAST_BO_ADD);
            fp_ret_q <= S_BL_ST;
            t_fpgo();
          end
          S_BL_ST: begin
            res_q[c_q[1:0]] <= fp_res_q;
            if (c_q[1:0] == 2'd3) st_q <= S_ROP_WR;
            else begin
              c_q <= c_q + 3'd1;
              st_q <= (c_q[1:0] == 2'd2 &&
                       dr_q.blend[at_q].op_a >= 3'd3) ? S_BL_MM
                      : (c_q[1:0] == 2'd2 ||
                         dr_q.blend[at_q].op_c < 3'd3) ? S_BL_F1
                      : S_BL_MM;
            end
          end
          S_ROP_LOP: begin
            lop_pix_q <= f_lop_pix(dr_q.ca[at_q].fmt, dr_q.logic_op,
                                   src_q[0], src_q[1], src_q[2], src_q[3],
                                   mp_res_q[32*fr_px[0] +: 32]);
            st_q <= S_ROP_WR;
          end
          S_ROP_WR: begin
            if (wq_ok) begin
              t_wq({32'h0, dr_q.ca[at_q].base} +
                   64'(fr_py) * 64'(cpitch_w) +
                   64'((32'(fr_px) * 32'd4) & ~64'd7),
                   {2{dr_q.logic_op_en ? lop_pix_q : rop_pix}},
                   rop_strb);
              st_q <= S_ROP_NX;
            end
          end
          S_ROP_NX: begin
            if (at_q == 2'd3) begin
              at_q <= '0; lzdone_q <= 1'b0;
              if ({1'b0, r_q} + 7'd1 >= dnf_q) begin pend_v_q <= 1'b0; st_q <= dret_q; end
              else begin
                r_q <= r_q + 6'd1;
                st_q <= S_ROP_R0;
              end
            end else begin
              at_q <= at_q + 2'd1;
              st_q <= S_ROP_R0;
            end
          end
          // ---- batch / instance advance ------------------------------------
          S_BATNEXT: begin
            if (bat_q + {26'h0, nv_q} >= dr_q.vertex_count) begin
              bat_q <= '0;
              if (inst_q + 32'd1 >=
                  dr_q.first_instance + dr_q.instance_count)
                // FP6: a frag wave may still be pending drain — route
                // through S_DGATE so S_FS_WAIT/S_ROP finish it before
                // S_FIN_OK reports the draw done (dret_q=S_FIN_OK).
                begin dret_q <= S_FIN_OK; st_q <= S_DGATE; end
              else begin
                inst_q <= inst_q + 32'd1;
                st_q <= S_DR_BATCH;
              end
            end else begin
              bat_q <= bat_q + {26'h0, nv_q};
              st_q <= S_DR_BATCH;
            end
          end
          // ---- shared sequencers ------------------------------------------
          S_MPW: begin
            // RP4: while the write-behind queue is non-empty the port
            // is serving its head — this read's request is neither
            // accepted nor its response consumed until the queue has
            // drained, so no read can observe memory ahead of an
            // earlier write.
            if (!wq_v_q[0]) begin
              if (!mp_acked_q && mp_req_ready_i) mp_acked_q <= 1'b1;
              if (mp_acked_q && mp_rsp_valid_i) begin
                mp_res_q <= mp_rsp_i.rdata;
                if (mp_ret_q == S_GA_RD) begin
                  // windowed gather: chain until the byte range is covered
                  win_q[64 * i_q +: 64] <= mp_rsp_i.rdata;
                  if (wn_q != 2'd0) begin
                    wn_q <= wn_q - 2'd1;
                    i_q <= i_q + 2'd1;
                    mp_addr_q <= mp_addr_q + 64'd8;
                    mp_acked_q <= 1'b0;
                  end else
                    st_q <= gret_q;
                end else if (mp_ret_q == S_PR_VF) begin
                  var_q[t_q][lc_q[2:0]][0] <= mp_rsp_i.rdata[31:0];
                  var_q[t_q][lc_q[2:0]][1] <= mp_rsp_i.rdata[63:32];
                  mp_addr_q <= mp_addr_q + 64'd8;
                  mp_acked_q <= 1'b0;
                  mp_ret_q <= S_PR_VF2;
                end else if (mp_ret_q == S_PR_VF2) begin
                  var_q[t_q][lc_q[2:0]][2] <= mp_rsp_i.rdata[31:0];
                  var_q[t_q][lc_q[2:0]][3] <= mp_rsp_i.rdata[63:32];
                  if (t_q == 2'd2) begin
                    t_q <= '0;
                    lc_q <= lc_q + 4'd1;
                  end else
                    t_q <= t_q + 2'd1;
                  st_q <= S_PR_VF;
                end else
                  st_q <= mp_ret_q;
              end
            end
          end
          S_FPS: begin
            fp_iss_q <= 1'b1;
            st_q <= S_FPW;
          end
          S_FPW: begin
            if ((fp_kind_q == 2'd0 && fma_ir) ||
                (fp_kind_q == 2'd1 && dq_ir) ||
                (fp_kind_q == 2'd2 && cv_ir)) fp_iss_q <= 1'b0;
            if (fma_ov || dq_ov || cv_ov) begin
              fp_res_q <= fma_ov ? fma_res : dq_ov ? dq_res : cv_res;
              st_q <= fp_ret_q;
            end
          end
          // ---- completion --------------------------------------------------
          // ---- line segment against one frustum plane -----------------
          // Distances match the triangle clipper.  The outside
          // endpoint moves onto the plane.  Flat colour stays the
          // original vertex 0 record.
          S_LC_D0: begin
            if (cpl_q == 3'd0) begin
              cdis_q[ce_q] <= pos_q[ce_q[0]][2];
              if (ce_q == 4'd0) begin
                ce_q <= 4'd1;
                st_q <= S_LC_D0;
              end else
                st_q <= S_LC_T0;
            end else if (cpl_q == 3'd1) begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= pos_q[ce_q[0]][3];
              fp_c_q <= pos_q[ce_q[0]][2];
              fp_ret_q <= S_LC_DD;
              t_fpgo();
            end else if (cpl_q == 3'd2) begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= pos_q[ce_q[0]][3];
              fp_c_q <= CLIP_EPS;
              fp_ret_q <= S_LC_DD;
              t_fpgo();
            end else begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
              fp_a_q <= CLIP_GB; fp_b_q <= pos_q[ce_q[0]][3];
              fp_ret_q <= S_LC_DG;
              t_fpgo();
            end
          end
          S_LC_DG: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= fp_res_q;
            fp_c_q <= {1'b0, pos_q[ce_q[0]][cpl_q == 3'd3 ? 0 : 1][30:0]};
            fp_ret_q <= S_LC_DD;
            t_fpgo();
          end
          S_LC_DD: begin
            cdis_q[ce_q] <= fp_res_q;
            if (ce_q == 4'd0) begin
              ce_q <= 4'd1;
              st_q <= S_LC_D0;
            end else
              st_q <= S_LC_T0;
          end
          S_LC_T0: begin
            if (f_f32_lt(cdis_q[0], 32'h0) && f_f32_lt(cdis_q[1], 32'h0)) begin
              t_pd();
              st_q <= S_PR_I0;
            end else if (!f_f32_lt(cdis_q[0], 32'h0) &&
                         !f_f32_lt(cdis_q[1], 32'h0)) begin
              st_q <= S_LC_N;
            end else begin
              // Index of the outside endpoint.
              lc_out_q <= !f_f32_lt(cdis_q[0], 32'h0);
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= f_f32_lt(cdis_q[0], 32'h0) ? cdis_q[0] : cdis_q[1];
              fp_c_q <= f_f32_lt(cdis_q[0], 32'h0) ? cdis_q[1] : cdis_q[0];
              fp_ret_q <= S_LC_T1;
              t_fpgo();
            end
          end
          S_LC_T1: begin
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= cdis_q[lc_out_q];
            fp_b_q <= fp_res_q;
            fp_ret_q <= S_LC_TL;
            t_fpgo();
          end
          S_LC_TL: begin
            ctt_q <= fp_res_q;
            c_q   <= '0;
            st_q  <= S_LC_C0;
          end
          S_LC_C0: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= pos_q[!lc_out_q][c_q[1:0]];
            fp_c_q <= pos_q[lc_out_q][c_q[1:0]];
            fp_ret_q <= S_LC_C1;
            t_fpgo();
          end
          S_LC_C1: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= ctt_q; fp_b_q <= fp_res_q;
            fp_c_q <= pos_q[lc_out_q][c_q[1:0]];
            fp_ret_q <= S_LC_C2;
            t_fpgo();
          end
          S_LC_C2: begin
            pos_q[lc_out_q][c_q[1:0]] <= fp_res_q;
            if (c_q[1:0] == 2'd3) st_q <= S_LC_N;
            else begin
              c_q  <= c_q + 3'd1;
              st_q <= S_LC_C0;
            end
          end
          S_LC_N: begin
            if (f_lpl(cpm_q & ~(5'b1 << cpl_q)) == 3'd7) begin
              fp_kind_q <= 2'd1; fp_o_q <= '0;
              fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[0][3];
              fp_ret_q <= S_T0R;
              t_fpgo();
            end else begin
              cpm_q <= cpm_q & ~(5'b1 << cpl_q);
              cpl_q <= f_lpl(cpm_q & ~(5'b1 << cpl_q));
              ce_q  <= '0;
              st_q  <= S_LC_D0;
            end
          end
          S_FIN_OK: begin
            // RP4: never report done while a queued write is still
            // awaiting its memory-port response.
            if (!wq_v_q[0]) begin
              pend_v_q <= 1'b0;             // FP6: last frag drain done
              done_o <= 1'b1;
              done_pl_o <= '{code: APU_SH_DONE_OK, wave: '0, pc: '0,
                             robust: robust_q, work_id: wid_q - 32'd1};
              st_q <= S_IDLE;
            end
          end
          S_FIN_BAD: begin
            // RP4: same drain rule as S_FIN_OK.
            if (!wq_v_q[0]) begin
              pend_v_q <= 1'b0;             // FP6
              done_o <= 1'b1;
              done_pl_o <= '{code: code_q, wave: '0, pc: '0,
                             robust: robust_q, work_id: wid_q - 32'd1};
              st_q <= S_IDLE;
            end
          end
          default: st_q <= S_IDLE;
        endcase
        // FP6 deferred divider capture: while rdiv_q is armed the FSM
        // is on the direct S_F_PY2->S_F_W0 frag path, where no other fp
        // job issues and no second divider can run — so a dq_ov here is
        // unambiguously this frag's 1/wsum result.  Grab it into rs_q;
        // S_F_W1 holds until rdiv_q clears before consuming rs_q.
        if (dq_ov && rdiv_q) begin
          rs_q   <= dq_res;
          rdiv_q <= 1'b0;
        end
      end
    end

// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
    // debug probe: which state reaches S_FIN_BAD + the shader code
    // when a VS/FS wave fails (temporary G1c bring-up aid)
    logic [7:0] dbg_st_q;
    always_ff @(posedge clk_i) begin
      if (st_q == S_FIN_BAD && dbg_st_q != S_FIN_BAD)
        $display("[DBG] rast FIN_BAD: from=%0d code=%0d op=%0d topo=%0d ibt=%0d vc=%0d ic=%0d fmtok=%0d shcode=%0d t=%0t",
                 dbg_st_q, code_q, dr_q.op, dr_q.topology, dr_q.ib_type,
                 dr_q.vertex_count, dr_q.instance_count, fmt_ok,
                 shdp_q.code, $time);
      if (sh_done_i && sh_done_pl_i.code != APU_SH_DONE_OK)
        $display("[DBG] rast sh wave fault: st=%0d code=%0d wid=%08x t=%0t",
                 st_q, sh_done_pl_i.code, sh_done_pl_i.work_id, $time);
      // blend decode evidence: dump the draw record's attachment-0
      // blend state on work accept (guest blend_layers mismatch)
      if (st_q == S_IDLE && work_valid_i &&
          rd_i.op == APU_RAST_OP_DRAW)
        $display("[DBG] rast draw blend0={en=%0d sc=%0d dc=%0d oc=%0d sa=%0d da=%0d oa=%0d mask=%x} cav=%x t=%0t",
                 rd_i.blend[0].en, rd_i.blend[0].src_c,
                 rd_i.blend[0].dst_c, rd_i.blend[0].op_c,
                 rd_i.blend[0].src_a, rd_i.blend[0].dst_a,
                 rd_i.blend[0].op_a, rd_i.blend[0].mask,
                 rd_i.ca_valid, $time);
      dbg_st_q <= 8'(st_q);
    end
`endif
// pragma translate_on

    // pragma translate_off
    // F5 wedge hunt invariants:
    //  - S_MPW consumes a response only while mp_acked_q is set, so a
    //    response arriving the same cycle as (or before) request
    //    acceptance would be dropped and the FSM would wait forever
    // RP4: a response is only legal for an accepted request — the
    // write-behind queue head when one is valid, else the S_MPW read.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        mp_rsp_valid_i |-> (wq_v_q[0] ? wq_acked_q : mp_acked_q));
    // RP4: wq_push marks a cycle where a converted write state accepts
    // a queue entry (its wq_ok guard passed) — sim-only observability.
    // A converted site never pushes when !wq_ok: every push implies
    // wq_ok, and a blocked converted state holds in place.
    logic wq_push;
    assign wq_push = wq_ok && (st_q inside {
        S_CLR_X, S_GA_W0, S_GA_W1, S_GA_S8A, S_GA_S8B,
        S_DZ_WR, S_F_W0, S_F_W1, S_F_VW0, S_F_VW1, S_ROP_WR});
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        wq_push |-> wq_ok);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (st_q inside {S_CLR_X, S_GA_W0, S_GA_W1, S_GA_S8A, S_GA_S8B,
                      S_DZ_WR, S_F_W0, S_F_W1, S_F_VW0, S_F_VW1,
                      S_ROP_WR} && !wq_ok)
        |=> (st_q == $past(st_q)));
    //  - fpnew ops issue from S_FPW (the t_fpgo path) or from the
    //    merged interpolation chains S_F_LE0 / S_F_V0 (RP2); in_valid
    //    is only raised in those states
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (fma_iv || fma2_iv || dq_iv || cv_iv) |->
        (st_q == S_FPW || st_q == S_F_LE0 || st_q == S_F_V0 ||
         st_q == S_ROP_DI));
    //  - out_valid pulses are consumed in S_FPW, or land inside the
    //    merged chains whose steps read fma_res/cv_res directly and
    //    handshake dq_ov (divider result pending).  FP6: a deferred
    //    1/wsum capture (rdiv_q) legally observes dq_ov on the direct
    //    S_F_PY2->S_F_W0 frag path before S_F_W1 consumes rs_q.
    //    RP3: S_ROP_DI is the pipelined dst-decode chain (reads
    //    cv_res/fma_res one step after issue, S_F_LE0 discipline).
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (fma_ov || fma2_ov || cv_ov) |->
        (st_q == S_FPW || st_q == S_F_LE0 || st_q == S_F_V0 ||
         st_q == S_ROP_DI));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        dq_ov |->
        (st_q == S_FPW || st_q == S_F_LE0 || st_q == S_F_V0 || rdiv_q));
    // wedge watchdog: non-idle states are all bounded waits — print
    // once when a state parks far past any legal latency so a guest
    // freeze names its FSM instead of hanging silently
    logic [23:0] dbg_wd_q;
    st_e         dbg_wd_st_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        dbg_wd_q    <= '0;
        dbg_wd_st_q <= S_IDLE;
      end else begin
        if (st_q != dbg_wd_st_q) begin
          dbg_wd_q    <= '0;
          dbg_wd_st_q <= st_q;
        end else if (st_q != S_IDLE && !(&dbg_wd_q)) begin
          dbg_wd_q <= dbg_wd_q + 24'd1;
        end
        if (dbg_wd_q == 24'h7ffffe && st_q != S_IDLE)
          $display("[DBG] rast WATCHDOG: st_q=%0d parked mp_acked=%0d fp_iss=%0d ret=%0d fret=%0d t=%0t",
                   st_q, mp_acked_q, fp_iss_q, mp_ret_q, fp_ret_q, $time);
      end
    end
    // pragma translate_on
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_rast_fixture
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit Enable = 1'b0,
  parameter int unsigned VtxCacheEntries = 0
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_rast_draw_t    rd_i,
  input  apu_sh_desc_t      desc_i,
  input  logic [5:0]        push_n_i,
  input  logic [1023:0]     push_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  output logic              sh_work_valid_o,
  input  logic              sh_work_ready_i,
  output logic [31:0]       sh_ctype_o,
  output logic [7:0][31:0]  sh_imm_o,
  output logic [2:0]        sh_slot_o,
  output apu_sh_desc_t      sh_desc_o,
  output logic [5:0]        sh_push_n_o,
  output logic [1023:0]     sh_push_o,
  input  logic              sh_done_i,
  input  apu_sh_done_t      sh_done_pl_i,
  output logic              mp_req_valid_o,
  input  logic              mp_req_ready_i,
  output apu_mp_req_t       mp_req_o,
  input  logic              mp_rsp_valid_i,
  input  apu_mp_rsp_t       mp_rsp_i,
  output logic              pg_req_valid_o,
  input  logic              pg_req_ready_i,
  output apu_vgpages_req_t  pg_req_o,
  input  logic              pg_cpl_valid_i,
  output logic              pg_cpl_ready_o,
  input  apu_vgpages_cpl_t  pg_cpl_i,
  output logic              busy_o,
  output logic [3*32-1:0]   stat_o,
  output logic [4*32-1:0]   qry_stat_o
);
  // R3 scratch-carve observability outputs sink here (i_dut .* binds by
  // name); the unit bench does not drive the apmem record window, so the
  // bases are captured but unused.
  logic [31:0] scratch_base_o;
  logic        scratch_valid_o;
  g6lc_apu_rast #(.Enable(Enable),
                  .VtxCacheEntries(VtxCacheEntries)) i_dut (.*);
endmodule
