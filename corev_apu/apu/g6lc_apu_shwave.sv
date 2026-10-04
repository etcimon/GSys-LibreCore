// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// ShaderCore wave engine (g6lc_apu_shwave) — §7a of
// architecture/uncore/apu-vulkan-engine.md.  Executes the 4a
// straight-line SPIR-V subset of a committed module over
// ShaderLanes × ShaderVec SIMT lanes, one wave at a time and one
// instruction at a time (fetch → decode → operand read → execute →
// writeback; no overlap, no bypass).  Register file, scratch and
// Workgroup slab are tc_sram; storage buffers live behind one 64-bit
// word memory port with robustBufferAccess semantics (out-of-range
// load → 0, store → dropped, counted in done_pl_o.robust).
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

module g6lc_apu_shwave
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
  parameter int unsigned WaitBound     = 32'd4096
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  // dispatch (single-cycle strobe; only while !busy_o)
  input  logic         disp_i,
  input  apu_sh_dispatch_t disp_pl_i,
  input  logic [16*113-1:0] binds_i,   // {set,binding,base,size,valid}
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
  input  logic [127:0] entry_data_i,
  // guest memory word port (64-bit; TB memory model)
  output logic         mem_re_o,
  output logic         mem_we_o,
  output logic [63:0]  mem_addr_o,
  output logic [63:0]  mem_wdata_o,
  output logic [7:0]   mem_wstrb_o,
  input  logic [63:0]  mem_rdata_i
);
  if (!Enable) begin : gen_off
    assign busy_o = 1'b0;   assign done_o = 1'b0;
    assign done_pl_o = '0;
    assign rd_slot_o = '0;  assign prog_addr_o = '0;
    assign type_id_o = '0;  assign const_id_o = '0;
    assign memb_id_o = '0;  assign rm_id_o = '0;
    assign init_id_o = '0;  assign blk_id_o = '0;
    assign mem_re_o = 1'b0; assign mem_we_o = 1'b0;
    assign mem_addr_o = '0; assign mem_wdata_o = '0;
    assign mem_wstrb_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | disp_i |
                    (|disp_pl_i) | (|binds_i) | (|push_n_i) |
                    (|push_i) | (|prog_data_i) | (|type_data_i) |
                    (|const_data_i) | (|memb_data_i) | (|rm_data_i) |
                    (|init_data_i) | (|blk_data_i) | (|entry_data_i) |
                    (|mem_rdata_i);
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
    localparam int unsigned OPB  = 8;

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

    // ---- states --------------------------------------------------------------
    typedef enum logic [6:0] {
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
      W_WB, W_NEXT, W_EOW, W_DONE
    } st_e;
    st_e st_q, ret_q;

    // dispatch latches
    logic [2:0]   slot_q;
    logic [15:0]  gx_q, gy_q, gz_q;
    logic [31:0]  wid_q;
    logic [15:0][112:0] binds_q;
    logic [31:0]  push_q [32];
    logic [5:0]   push_n_q;
    // entry record
    logic [15:0]  eoff_q, escratch_q;
    logic [7:0]   lx_q, ly_q, lz_q, ninit_q;
    // workgroup/wave iteration
    logic [15:0]  wgx_q, wgy_q, wgz_q;
    logic [RL-1:0] wave_q;
    logic [7:0]   nwaves_q, lanes_q;
    // instruction state
    logic [15:0]  pc_q;
    logic [15:0]  opc_q, wc_q;
    logic [31:0]  ops_q [OPB];
    logic [3:0]   rkind_q;
    logic [2:0]   rcomps_q;
    logic [9:0]   relem_q;
    logic [2:0]   ncomp_q;
    logic [2:0]   ot_comps_q;
    // operand values / types
    vt_t          va_q [4];
    logic [9:0]   vty_q [4];
    logic [2:0]   nva_q, vk_q;
    logic [9:0]   res_id_q;
    logic [1:0]   res_slot_q;
    logic [RI-1:0] ridx_q;            // reg idx captured at W_RMC (operand)
    logic [3:0]   raux_q;             // rm_aux captured at W_RMC
    logic [RI-1:0] ir_idx_q;          // same for chain-index resolve
    logic [3:0]   ir_aux_q;
    logic [1:0]   ir_tag_q;
    vt_t          vix_q;          // resolved chain index operand
    // composite construct
    logic [2:0]   ccp_q;          // accumulated comp position
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
    logic [5:0]   ja_q, jb_q, jc_q; // {cmode[1:0], src[3:0]}
    logic [1:0]   jdst_q;         // 0 wb, 1 t0, 2 t1, 3 t2
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
    logic [1:0]   ls_comp_q;
    logic [31:0]  ls_off_q;
    logic [3:0]   ls_sc_q;
    logic [7:0]   ls_bi_q;
    logic         ls_store_q;
    logic [63:0]  ls_bind_q;
    logic [31:0]  ls_bsz_q;
    logic         ls_bok_q;
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
    logic [1:0]   ca_q, cb_q, ccc_q;
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
    wire [7:0]  iw_set    = init_data_i[39:32];
    wire [7:0]  iw_bd     = init_data_i[47:40];
    wire [15:0] iw_off    = init_data_i[63:48];
    wire [15:0] mb_off    = memb_data_i[15:0];
    wire [15:0] mb_mst    = memb_data_i[31:16];
    // member row: {14'h0, ty[9:0], flags[7:0], mstride[15:0], off[15:0]}
    wire [9:0]  mb_ty     = memb_data_i[49:40];
    wire [14:0] blk_pc    = blk_data_i[14:0];
    wire        blk_ok    = blk_data_i[15];

    function automatic logic f_nan(input logic [31:0] w);
      f_nan = (w[30:23] == 8'hFF) && (w[22:0] != 0);
    endfunction
    function automatic logic [2:0] f_nc(input logic [2:0] c);
      f_nc = (c == 0) ? 3'd1 : c;
    endfunction
    function automatic logic f_has_rty(input logic [15:0] o);
      unique case (o)
        12,61,65,66,68,79,80,81,82,109,110,111,112,124,126,127,128,129,
        130,131,132,133,134,135,136,137,138,139,142,148,164,165,166,
        167,168,169,170,171,172,173,174,175,176,177,178,179,180,181,
        182,183,184,185,186,187,188,189,190,191,194,195,196,197,198,
        199,200:
          f_has_rty = 1'b1;
        default: f_has_rty = 1'b0;
      endcase
    endfunction
    function automatic logic [2:0] f_nva(input logic [15:0] o,
                                         input logic [15:0] wc);
      unique case (o)
        62:      f_nva = 3'd2;
        80:      f_nva = (wc > 7) ? 3'd4 : 3'(wc - 3);
        169:     f_nva = 3'd3;
        82:      f_nva = 3'd2;
        12:      f_nva = (wc > 8) ? 3'd3
                       : (wc > 5 ? 3'(wc - 5) : 3'd0);
        61,65,66,68,81,109,110,111,112,124,126,127,146,168,200:
                 f_nva = 3'd1;
        54,56,248,249,253: f_nva = 3'd0;
        default: f_nva = 3'd2;
      endcase
    endfunction
    function automatic logic [31:0] f_opid(input logic [15:0] o,
                                           input logic [2:0] k,
                                           input logic [31:0] oq [OPB]);
      if (o == 62)      f_opid = oq[k];
      else if (o == 12) f_opid = oq[4 + k];
      else              f_opid = oq[2 + k];
    endfunction
    function automatic logic [9:0] f_opid10(input logic [15:0] o,
                                            input logic [2:0] k,
                                            input logic [31:0] oq [OPB]);
      f_opid10 = 10'(f_opid(o, k, oq));
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
          default: f_bi = 0;
        endcase
      end
    endfunction
    // binding match {set,binding} → {base,size,ok} packed
    // bind table entry: {set[112:105], binding[104:97],
    // base[96:33], size[32:1], valid[0]}; returns {v,base,size}
    function automatic logic [96:0] f_bind(input logic [7:0] st,
                                           input logic [7:0] bd);
      logic [96:0] r;
      begin
        r = '0;
        for (int b = 0; b < 16; b++)
          if (binds_q[b][0] && binds_q[b][112:105] == st &&
              binds_q[b][104:97] == bd)
            r = {binds_q[b][96:33], binds_q[b][32:1], 1'b1};
        f_bind = r;
      end
    endfunction
    // unit operand source: {cmode[1:0], src[3:0]} → 32-bit operand
    localparam logic [3:0] S_V0 = 0, S_V1 = 1, S_V2 = 2, S_V3 = 3,
                         S_T0 = 4, S_T1 = 5, S_T2 = 6,
                         S_ONE = 7, S_TWO = 8, S_THREE = 9,
                         S_NEG2 = 10, S_ZERO = 11, S_HALF = 12;
    function automatic logic [31:0] f_src(input logic [5:0] s,
                                          input logic [3:0] l,
                                          input logic [2:0] c);
      logic [2:0] cc;
      begin
        unique case (s[5:4])
          2'd1: cc = 3'd0;                    // broadcast comp0
          2'd2: cc = jrev_q ? 3'(ncomp_q - 3'd1 - tc_q)
                            : tc_q;           // iterate comp (rev for dot)
          2'd3: cc = {1'b0, ((s[3:0] == S_V0) ? ca_q : cb_q)};
          default: cc = c;                    // per-unit comp
        endcase
        unique case (s[3:0])
          S_V0:    f_src = va_q[0][l][cc];
          S_V1:    f_src = va_q[1][l][cc];
          S_V2:    f_src = va_q[2][l][cc];
          S_V3:    f_src = va_q[3][l][cc];
          S_T0:    f_src = t0_q[l][cc];
          S_T1:    f_src = t1_q[l][cc];
          S_T2:    f_src = t2_q[l][cc];
          S_ONE:   f_src = 32'h3F80_0000;
          S_TWO:   f_src = 32'h4000_0000;
          S_THREE: f_src = 32'h4040_0000;
          S_NEG2:  f_src = 32'hC000_0000;
          S_HALF:  f_src = 32'h3F00_0000;
          default: f_src = 32'h0;
        endcase
      end
    endfunction
    // unit job descriptor: jmode 0=fma-vec,1=dsq,2=cvt,3=nc
    task automatic jset(input logic [1:0] jm, input logic [4:0] xo,
                        input logic [5:0] a, b, c,
                        input logic [1:0] dst, input logic dot,
                        input st_e ret, input logic uccc = 1'b0,
                        input logic rev = 1'b0);
      jmode_q <= jm; xop_q <= xo; ja_q <= a; jb_q <= b; jc_q <= c;
      jdst_q <= dst; jdot_q <= dot; tc_q <= '0; ret_q <= ret;
      jucc_q <= uccc; jrev_q <= rev;
      fu_got_q <= '0; fu_dn_q <= '0;
      dq_got_q <= '0; dq_dn_q <= '0;
      cv_got_q <= '0; cv_dn_q <= '0;
      nc_got_q <= '0; nc_dn_q <= '0;
      st_q <= (jm == 0) ? W_FU0 : (jm == 1) ? W_DQ0
              : (jm == 2) ? W_CVT0 : W_NC0;
    endtask

    // write unit result into dst register for lane l comp c
    task automatic jstore(input logic [1:0] dst, input logic [3:0] l,
                          input logic [2:0] c, input logic [31:0] v);
      unique case (dst)
        2'd0: wb_q[l][c] <= v;
        2'd1: t0_q[l][c] <= v;
        2'd2: t1_q[l][c] <= v;
        default: t2_q[l][c] <= v;
      endcase
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
                fma_ops[l][c][0] = f_src(ja_q, 4'(l), 3'(c));
                fma_ops[l][c][1] = f_src(jb_q, 4'(l), 3'(c));
                fma_ops[l][c][2] = f_src(jc_q, 4'(l), 3'(c));
                fma_iv[l][c] = (st_q == W_FU0) && (l < lanes_q) &&
                               !fu_got_q[l][c] &&
                               (jdot_q ? (c == 0) : 1'b1);
              end
            end
        end
        2'd1: begin                              // divsqrt, comp tc
          dq_op = xop_q[0] ? fpnew_pkg::SQRT : fpnew_pkg::DIV;
          for (int l = 0; l < LAN; l++) begin
            dq_ops[l][0] = f_src(ja_q, 4'(l), tc_q);
            dq_ops[l][1] = f_src(jb_q, 4'(l), tc_q);
            dq_iv[l] = (st_q == W_DQ0) && (l < lanes_q) && !dq_got_q[l];
          end
        end
        2'd2: begin                              // cast, comp tc
          cv_op = xop_q[0] ? fpnew_pkg::I2F : fpnew_pkg::F2I;
          cv_rnd = fpnew_pkg::roundmode_e'(xop_q[3:1]);
          cv_mod = xop_q[4];
          for (int l = 0; l < LAN; l++) begin
            cv_ops[l] = f_src(ja_q, 4'(l), tc_q);
            cv_iv[l] = (st_q == W_CVT0) && (l < lanes_q) && !cv_got_q[l];
          end
        end
        default: begin                           // noncomp, comp tc
          nc_op = xop_q[0] ? fpnew_pkg::MINMAX : fpnew_pkg::CMP;
          nc_rnd = fpnew_pkg::roundmode_e'(xop_q[3:1]);
          nc_mod = xop_q[4];
          for (int l = 0; l < LAN; l++) begin
            nc_ops[l][0] = f_src(ja_q, 4'(l), tc_q);
            nc_ops[l][1] = f_src(jb_q, 4'(l), tc_q);
            nc_iv[l] = (st_q == W_NC0) && (l < lanes_q) && !nc_got_q[l];
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

    // ---- shmod read port addresses ------------------------------------------
    logic [15:0] pa_w;
    logic [9:0]  ty_w, rm_w, mb_w;
    logic [9:0]  cty2_q, al_ty2_q;
    always_comb begin
      pa_w = pc_q;
      if (st_q == W_LD0) pa_w = pc_q + {13'h0, vk_q} + 1;
      ty_w = '0; rm_w = '0; mb_w = '0;
      unique case (st_q)
        W_TY0:  ty_w = ops_q[0][9:0];
        W_OT0:  ty_w = oty_id_q;
        W_CC0:  ty_w = vty_q[vk_q[1:0]];
        W_RMI:  rm_w = f_opid10(opc_q, vk_q, ops_q);
        W_IR0:  rm_w = res_id_q;
        W_RW0:  rm_w = ops_q[1][9:0];
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
    assign rd_slot_o   = slot_q;
    assign prog_addr_o = pa_w;
    assign type_id_o   = ty_w;
    assign const_id_o  = res_id_q;
    assign memb_id_o   = mb_w;
    assign rm_id_o     = rm_w;
    assign init_id_o   = init_i_q[9:0];
    assign blk_id_o    = ops_q[0][9:0];

    // ---- integer combinational ALU ------------------------------------------
    vt_t int_alu;
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
          default: ;
        endcase
        default: ;
      endcase
    end

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
            rf_wdata[l*128 + 32 +: 32] = {4'h0, iw_bd, iw_set,
                                          iw_bi, iw_sc};
            rf_wdata[l*128 + 64 +: 32] = '0;
            rf_wdata[l*128 + 96 +: 32] = '0;
          end
          rf_be = '1;
        end
        W_RV0: begin
          rf_req = 1'b1;
          rf_addr = {wave_q, ridx_q};
        end
        W_IR2: begin
          rf_req = 1'b1;
          rf_addr = {wave_q, ir_idx_q};
        end
        W_WB: begin
          rf_req = 1'b1; rf_we = 1'b1;
          rf_addr = {wave_q, wreg_q};
          rf_wdata = wb_q;
          for (int l = 0; l < LAN; l++)
            for (int c = 0; c < VEC; c++)
              if (wbm_q[c]) rf_be[l*16 + c*4 +: 4] = 4'hF;
        end
        W_SSB: begin
          if (ls_sc_q == APU_SH_SC_WORKGROUP) begin
            sb_req = 1'b1;
            sb_we = ls_store_q && ((ls_off_q >> 2) < SLW);
            sb_addr = SLWA'(ls_off_q >> 2);
            sb_wdata = va_q[1][ls_lane_q[2:0]][ls_comp_q];
            sb_be = 4'hF;
          end else begin
            sc_req = 1'b1;
            sc_we = ls_store_q && ((ls_off_q >> 2) < SCW) &&
                    (ls_off_q < {16'h0, escratch_q});
            sc_addr = SDW'((32'(wave_q) * LAN + ls_lane_q) * SCW +
                           (ls_off_q >> 2));
            sc_wdata = va_q[1][ls_lane_q[2:0]][ls_comp_q];
            sc_be = 4'hF;
          end
        end
        default: ;
      endcase
    end

    wire ls_mem = (ls_sc_q == APU_SH_SC_UNIFORM) ||
                  (ls_sc_q == APU_SH_SC_SBUF);
    assign mem_re_o    = (st_q == W_LS1) && ls_mem && !ls_store_q &&
                         ls_bok_q;
    assign mem_we_o    = (st_q == W_LS1) && ls_mem && ls_store_q &&
                         ls_bok_q;
    assign mem_addr_o  = ls_addr_q & ~64'h7;
    assign mem_wdata_o = ls_addr_q[2]
                         ? {va_q[1][ls_lane_q[2:0]][ls_comp_q], 32'h0}
                         : {32'h0, va_q[1][ls_lane_q[2:0]][ls_comp_q]};
    assign mem_wstrb_o = ls_addr_q[2] ? 8'hF0 : 8'h0F;

    // =========================================================================
    // main FSM
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        st_q <= W_IDLE; ret_q <= W_EX;
        slot_q <= '0; gx_q <= '0; gy_q <= '0; gz_q <= '0; wid_q <= '0;
        binds_q <= '0; push_n_q <= '0;
        for (int i = 0; i < 32; i++) push_q[i] <= '0;
        eoff_q <= '0; escratch_q <= '0;
        lx_q <= '0; ly_q <= '0; lz_q <= '0; ninit_q <= '0;
        wgx_q <= '0; wgy_q <= '0; wgz_q <= '0;
        wave_q <= '0; nwaves_q <= '0; lanes_q <= '0;
        pc_q <= '0; opc_q <= '0; wc_q <= '0;
        for (int i = 0; i < OPB; i++) ops_q[i] <= '0;
        rkind_q <= '0; rcomps_q <= '0; relem_q <= '0;
        ncomp_q <= '0; ot_comps_q <= '0;
        for (int i = 0; i < 4; i++) begin
          va_q[i] <= '0; vty_q[i] <= '0;
        end
        nva_q <= '0; vk_q <= '0; res_id_q <= '0; res_slot_q <= '0;
        vix_q <= '0; ccp_q <= '0;
        cty_q <= '0; poff_q <= '0; ctag_q <= '0; ck_q <= '0;
        cmstride_q <= '0; cty2_q <= '0;
        wb_q <= '0; wbm_q <= '0; wreg_q <= '0;
        xq_q <= '0; xop_q <= '0; jmode_q <= '0;
        ja_q <= '0; jb_q <= '0; jc_q <= '0; jdst_q <= '0;
        t0_q <= '0; t1_q <= '0; t2_q <= '0; tc_q <= '0; jdot_q <= '0;
        jrev_q <= '0;
        ls_lane_q <= '0; ls_comp_q <= '0; ls_off_q <= '0;
        ls_sc_q <= '0; ls_bi_q <= '0; ls_store_q <= '0;
        ls_bind_q <= '0; ls_bsz_q <= '0; ls_bok_q <= '0;
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
        done_o <= 1'b0;
      end else begin
        done_o <= 1'b0;
        // bounded waits: only the unit-wait states count cycles
        if (st_q == W_FU0 || st_q == W_FU1 || st_q == W_DQ0 ||
            st_q == W_DQ1 || st_q == W_CVT0 || st_q == W_CVT1 ||
            st_q == W_NC0 || st_q == W_NC1 || st_q == W_LS2 ||
            st_q == W_SSB1)
          wait_q <= (wait_q != 16'hFFFF) ? wait_q + 1 : wait_q;
        else wait_q <= '0;
        if (wait_q > 16'(WaitBound)) begin
          done_code_q <= APU_SH_DONE_FAULT;
          fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
          st_q <= W_DONE;
        end else unique case (st_q)
          // -------------------------------------------------- dispatch --
          W_IDLE: if (disp_i) begin
            slot_q <= disp_pl_i.slot;
            gx_q <= disp_pl_i.gx; gy_q <= disp_pl_i.gy;
            gz_q <= disp_pl_i.gz; wid_q <= disp_pl_i.work_id;
            push_n_q <= push_n_i;
            for (int i = 0; i < 16; i++)
              binds_q[i] <= binds_i[i*113 +: 113];
            for (int i = 0; i < 32; i++)
              push_q[i] <= push_i[i*32 +: 32];
            wgx_q <= '0; wgy_q <= '0; wgz_q <= '0;
            wave_q <= '0; insns_q <= '0; robust_q <= '0;
            done_code_q <= '0; wait_q <= '0;
            st_q <= W_ENT0;
          end
          W_ENT0: st_q <= W_ENT1;       // entry read issued
          W_ENT1: begin
            eoff_q <= entry_data_i[15:0];
            lx_q <= entry_data_i[39:32]; ly_q <= entry_data_i[47:40];
            lz_q <= entry_data_i[55:48]; ninit_q <= entry_data_i[63:56];
            escratch_q <= entry_data_i[79:64];
            nwaves_q <= 8'((32'(entry_data_i[39:32]) *
                            32'(entry_data_i[47:40]) *
                            32'(entry_data_i[55:48]) + LAN - 1) / LAN);
            lanes_q <= (LAN < 32'(entry_data_i[39:32]) *
                        entry_data_i[47:40] * entry_data_i[55:48])
                       ? LAN : 8'(32'(entry_data_i[39:32]) *
                                  entry_data_i[47:40] *
                                  entry_data_i[55:48]);
            init_i_q <= '0;
            st_q <= W_IW0;
          end
          // ------------------------------------------- wave reg init --
          W_IW0: begin
            if (init_i_q >= 16'(ninit_q)) begin
              pc_q <= eoff_q; insns_q <= '0; init_i_q <= '0;
              st_q <= W_F0;
            end else st_q <= W_IW1;
          end
          W_IW1: begin                  // init row arrived; RF write
            init_i_q <= init_i_q + 1;
            st_q <= W_IW0;
          end
          // ---------------------------------------------------- fetch --
          W_F0: begin wait_q <= '0; st_q <= W_F1; end
          W_F1: begin
            wc_q <= prog_data_i[31:16];
            opc_q <= prog_data_i[15:0];
            if (prog_data_i[31:16] == 0 ||
                prog_data_i[31:16] > 16'(OPB) + 1 ||
                32'(pc_q) + prog_data_i[31:16] > 32'(ShaderWords)) begin
              done_code_q <= APU_SH_DONE_FAULT;
              fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else begin
              vk_q <= '0;
              st_q <= (prog_data_i[31:16] > 1) ? W_LD0 : W_TY0A;
            end
          end
          W_LD0: st_q <= W_LD1;
          W_LD1: begin
            ops_q[vk_q[2:0]] <= prog_data_i;
            if (vk_q + 1 >= 16'(wc_q) - 1) begin
              vk_q <= '0; st_q <= W_TY0A;
            end else begin
              vk_q <= vk_q + 1; st_q <= W_LD0;
            end
          end
          // ------------------------------ result-type / operand resolve
          W_TY0A: begin
            nva_q <= f_nva(opc_q, wc_q);
            if (f_has_rty(opc_q)) st_q <= W_TY0;
            else begin
              ncomp_q <= 4'd1;
              st_q <= (f_nva(opc_q, wc_q) != 0) ? W_RMI : W_EX;
            end
          end
          W_TY0: st_q <= W_TY1;
          W_TY1: begin
            rkind_q <= ty_kind; rcomps_q <= ty_comps;
            relem_q <= ty_elem;
            ncomp_q <= 4'(f_nc(ty_comps));
            vk_q <= '0;
            st_q <= (nva_q != 0) ? W_RMI : W_EX;
          end
          W_OT0: st_q <= W_OT1;
          W_OT1: begin
            ot_comps_q <= f_nc(ty_comps);
            ot_elem_q <= ty_elem;
            if (opc_q == 62) ncomp_q <= 4'(f_nc(ty_comps));
            st_q <= W_EX;
          end
          W_RMI: begin
            if (vk_q >= nva_q) begin
              vk_q <= '0; st_q <= W_RW0;
            end else begin
              res_id_q <= f_opid10(opc_q, vk_q, ops_q);
              res_slot_q <= vk_q[1:0];
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
            st_q <= (rm_tag == APU_SH_RT_CONST) ? W_CV0 : W_RV0;
          end
          W_CV0: st_q <= W_CV1;
          W_CV1: begin
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
                  wb_q[l][ccp_q + c] <= va_q[vk_q[1:0]][l][c];
            ccp_q <= ccp_q + f_nc(ty_comps);
            vk_q <= vk_q + 1;
            st_q <= (vk_q + 1 >= nva_q) ? W_WB : W_CC0;
          end
          // ------------------ pre-exec: extra operand type reads ------
          W_PRE: begin
            unique case (opc_q)
              62:  begin oty_id_q <= vty_q[1]; st_q <= W_OT0; end
              142,148,169:
                   begin oty_id_q <= vty_q[0]; st_q <= W_OT0; end
              65,66: begin
                // chain: pointer's pointee type = elem of its PTR type
                oty_id_q <= vty_q[0]; st_q <= W_OT0;
              end
              68:  st_q <= W_AL0;
              80:  begin vk_q <= '0; ccp_q <= '0;
                         wbm_q <= 4'b1111; st_q <= W_CC0; end
              12:  begin
                xnum_q <= ops_q[3][6:0];
                if (ops_q[3][6:0] == 66 || ops_q[3][6:0] == 67 ||
                    ops_q[3][6:0] == 69) begin
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
            // count, so only latch it on the first entry (xq==0)
            if (xq_q == 0) wbm_q <= 4'((4'b1 << ncomp_q) - 1);
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
              136: jset(1, 5'd0, {2'd0, S_V0}, {2'd0, S_V1}, 6'h0,
                        0, 0, W_WB);                          // FDiv
              // converts: {mod,rnd,i2f}; F2I uses RTZ, I2F RNE,
              // mod=1 selects the UNSIGNED int side (fpnew_cast
              // convention: int_sign = msb & ~op_mod)
              109: jset(2, {1'b1, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, 6'h0, 6'h0, 0, 0, W_WB);  // FToU
              110: jset(2, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, 6'h0, 6'h0, 0, 0, W_WB);  // FToS
              111: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                        {2'd0, S_V0}, 6'h0, 6'h0, 0, 0, W_WB);  // SToF
              112: jset(2, {1'b1, fpnew_pkg::RNE[2:0], 1'b1},
                        {2'd0, S_V0}, 6'h0, 6'h0, 0, 0, W_WB);  // UToF
              // fp compares via noncomp CMP (180..191);
              // rnd selects predicate (RNE=LE, RTZ=LT, RDN=EQ),
              // mod inverts; FUnord* map to the same predicates
              // (EQ's NaN→mod rule gives FUNE's NaN→true for free)
              180: jset(3, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FOE
              181: jset(3, {1'b0, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FUE
              182: jset(3, {1'b1, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FONE
              183: jset(3, {1'b1, fpnew_pkg::RDN[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FUNE
              184: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FOLT
              185: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FULT
              186: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 6'h0, 0, 0,
                        W_WB);                                // FOGT
              187: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 6'h0, 0, 0,
                        W_WB);                                // FUGT
              188: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FOLE
              189: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                        W_WB);                                // FULE
              190: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 6'h0, 0, 0,
                        W_WB);                                // FOGE
              191: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                        {2'd0, S_V1}, {2'd0, S_V0}, 6'h0, 0, 0,
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
              // memory / pointer ops
              61,62: begin
                ls_store_q <= (opc_q == 62);
                ls_lane_q <= '0; ls_comp_q <= '0;
                st_q <= W_LS0;
              end
              65,66: begin
                // walk starts at the pointer's pointee type
                cty_q <= ot_elem_q;
                ck_q <= '0;
                for (int l = 0; l < LAN; l++) begin
                  poff_q[l][0] <= va_q[0][l][0];
                  poff_q[l][1] <= va_q[0][l][1];
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
                for (int l = 0; l < LAN; l++)
                  wb_q[l][0] <= va_q[0][l][ops_q[3][1:0]];
                st_q <= W_WB;
              end
              82: begin                            // CompositeInsert
                wb_q <= va_q[1];
                for (int l = 0; l < LAN; l++)
                  wb_q[l][ops_q[4][1:0]] <= va_q[0][l][0];
                st_q <= W_WB;
              end
              // flow
              249: begin                           // OpBranch
                if (blk_ok) begin
                  pc_q <= {1'b0, blk_pc};
                  insns_q <= insns_q + 1;
                  st_q <= W_F0;
                end else begin
                  done_code_q <= APU_SH_DONE_FAULT;
                  fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
                  st_q <= W_DONE;
                end
              end
              253,56: st_q <= W_EOW;               // Return/FunctionEnd
              // Function/Label/Nop/Variable — the W_IW init walk already
              // wrote every variable's pointer register, so OpVariable in
              // the body only advances the program counter.
              54,59,248,0: st_q <= W_NEXT;
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
                                {2'd0, S_V0}, 6'h0, 6'h0, 1, 0, W_XCNT);
                        9: jset(2, {1'b0, fpnew_pkg::RUP[2:0], 1'b0},
                                {2'd0, S_V0}, 6'h0, 6'h0, 1, 0, W_XCNT);
                        3: jset(2, {1'b0, fpnew_pkg::RTZ[2:0], 1'b0},
                                {2'd0, S_V0}, 6'h0, 6'h0, 1, 0, W_XCNT);
                        1: jset(2, {1'b0, fpnew_pkg::RMM[2:0], 1'b0},
                                {2'd0, S_V0}, 6'h0, 6'h0, 1, 0, W_XCNT);
                        default:
                          jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b0},
                               {2'd0, S_V0}, 6'h0, 6'h0, 1, 0, W_XCNT);
                      endcase
                    end
                    1: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, 6'h0, 6'h0, 2, 0, W_XCNT);
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
                            {2'd0, S_V0}, 6'h0, 6'h0, 1, 0, W_XCNT);
                    1: jset(2, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T0}, 6'h0, 6'h0, 2, 0, W_XCNT);
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
                  31: jset(1, 5'd1, {2'd0, S_V0}, 6'h0, 6'h0, 0, 0,
                           W_WB);                               // Sqrt
                  32: unique case (xq_q)                         // IvtSqrt
                    0: jset(1, 5'd1, {2'd0, S_V0}, 6'h0, 6'h0, 1, 0,
                            W_XCNT);
                    default:
                      jset(1, 5'd0, {2'd0, S_ONE}, {2'd0, S_T0}, 6'h0,
                           0, 0, W_WB);
                  endcase
                  // fpnew_noncomp MINMAX: rnd RNE=MIN, RTZ=MAX
                  37: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                           {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                           W_WB);                                // FMin
                  40: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                           {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 0, 0,
                           W_WB);                                // FMax
                  43: unique case (xq_q)                         // FClamp
                    0: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},  // max
                            {2'd0, S_V0}, {2'd0, S_V1}, 6'h0, 1, 0,
                            W_XCNT);
                    default:
                      jset(3, {1'b0, 3'b000, 1'b1},                // min
                           {2'd0, S_T0}, {2'd0, S_V2}, 6'h0, 0, 0,
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
                            {2'd0, S_V1}, {2'd0, S_V0}, 6'h0, 1, 0,
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
                    2: jset(1, 5'd0, {2'd0, S_T0}, {2'd0, S_T1}, 6'h0,
                            1, 0, W_XCNT);                       // t → t0
                    3: jset(3, {1'b0, fpnew_pkg::RTZ[2:0], 1'b1},
                            {2'd0, S_T0}, {2'd0, S_ZERO}, 6'h0, 2, 0,
                            W_XCNT);                             // max(t,0) → t1
                    4: jset(3, {1'b0, fpnew_pkg::RNE[2:0], 1'b1},
                            {2'd0, S_T1}, {2'd0, S_ONE}, 6'h0, 2, 0,
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
                      jset(1, 5'd1, {2'd0, S_T0}, 6'h0, 6'h0, 0, 0,
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
                      jset(1, 5'd1, {2'd0, S_T0}, 6'h0, 6'h0, 0, 0,
                           W_WB);
                  endcase
                  68: unique case (xq_q)                         // Cross
                    // t0 = {a1b2, a2b0, a0b1}; t1 = {a2b1, a0b2, a1b0}
                    0: begin ca_q <= 1; cb_q <= 2; ccc_q <= 0;
                      ncomp_q <= 4'd1;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 1, 0, W_XCNT, 1'b1); end
                    1: begin ca_q <= 2; cb_q <= 0; ccc_q <= 1;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 1, 0, W_XCNT, 1'b1); end
                    2: begin ca_q <= 0; cb_q <= 1; ccc_q <= 2;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 1, 0, W_XCNT, 1'b1); end
                    3: begin ca_q <= 2; cb_q <= 1; ccc_q <= 0;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT, 1'b1); end
                    4: begin ca_q <= 0; cb_q <= 2; ccc_q <= 1;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT, 1'b1); end
                    5: begin ca_q <= 1; cb_q <= 0; ccc_q <= 2;
                      jset(0, 5'd2, {2'd3, S_V0}, {2'd3, S_V1},
                           {2'd0, S_ZERO}, 2, 0, W_XCNT, 1'b1); end
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
                    2: jset(1, 5'd1, {2'd0, S_T0}, 6'h0, 6'h0, 1, 0,
                            W_XCNT);                             // √dot
                    3: jset(1, 5'd0, {2'd0, S_ONE}, {2'd0, S_T0},
                            6'h0, 1, 0, W_XCNT);                 // 1/√dot
                    default: begin
                      ncomp_q <= 4'(ot_comps_q);
                      jset(0, 5'd2, {2'd0, S_V0}, {2'd1, S_T0},
                           {2'd0, S_ZERO}, 0, 0, W_WB);
                    end
                  endcase
                  default: begin
                    done_code_q <= APU_SH_DONE_FAULT;
                    fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
                    st_q <= W_DONE;
                  end
                endcase
              end
              default: begin
                done_code_q <= APU_SH_DONE_FAULT;
                fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
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
                  if (l < lanes_q)
                    t0_q[l][0] <= fma_ov[l][0] ? fma_res[l][0]
                                               : fu_rc_q[l][0];
                if (tc_q + 1 >= ncomp_q) begin
                  for (int l = 0; l < LAN; l++)
                    if (l < lanes_q)
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
                    if (l < lanes_q && c < ncomp_q)
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
                if (l < lanes_q &&
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
                if (l < lanes_q)
                  jstore(jdst_q, 4'(l), tc_q,
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
                if (l < lanes_q &&
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
                if (l < lanes_q)
                  jstore(jdst_q, 4'(l), tc_q,
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
                if (l < lanes_q &&
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
                if (l < lanes_q)
                  jstore(jdst_q, 4'(l), tc_q,
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
                if (ty_stride != 0) begin
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
            for (int l = 0; l < LAN; l++)
              poff_q[l][0] <= poff_q[l][0] + {16'h0, mb_off};
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
              wb_q[l][2] <= '0; wb_q[l][3] <= '0;
            end
            wbm_q <= 4'b1111;
            st_q <= W_WB;
          end
          // OpArrayLength: ptr → struct → member(off, mtype) → stride
          W_AL0: begin
            logic [96:0] bn;
            bn = f_bind(va_q[0][0][1][19:12], va_q[0][0][1][27:20]);
            ls_bind_q <= bn[96:33];
            ls_bsz_q  <= bn[32:1];
            ls_bok_q  <= bn[0];
            st_q <= W_AL1;
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
            logic [96:0] bn;
            o32 = va_q[0][ls_lane_q[2:0]][0] +
                  {28'h0, ls_comp_q, 2'b00};
            tg  = va_q[0][ls_lane_q[2:0]][1];
            bn  = f_bind(tg[19:12], tg[27:20]);
            ls_off_q <= o32;
            ls_sc_q  <= tg[3:0];
            ls_bi_q  <= tg[11:4];
            ls_bind_q <= bn[96:33];
            ls_bsz_q  <= bn[32:1];
            ls_bok_q  <= bn[0];
            if (ls_lane_q >= {1'b0, lanes_q}) st_q <= W_LSA;
            else if (tg[3:0] == APU_SH_SC_INPUT) begin
              // builtin vec component comes from the pointer byte
              // offset (scalar extracts load .y/.z too), not from the
              // output component cursor
              if (!ls_store_q)
                wb_q[ls_lane_q[2:0]][ls_comp_q] <=
                  f_bi(tg[11:4], ls_lane_q, 3'(o32 >> 2));
              st_q <= W_LSA;
            end else if (tg[3:0] == APU_SH_SC_PUSHCONST) begin
              if ((o32 >> 2) >= {26'h0, push_n_q}) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][ls_comp_q] <= '0;
              end else if (!ls_store_q) begin
                wb_q[ls_lane_q[2:0]][ls_comp_q] <=
                  push_q[o32[31:2] > 31 ? 5'd31 : o32[6:2]];
              end
              st_q <= W_LSA;
            end else if (tg[3:0] == APU_SH_SC_UNIFORM ||
                         tg[3:0] == APU_SH_SC_SBUF) begin
              if (!bn[0] || {32'h0, o32} + 4 > {32'h0, bn[32:1]}) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][ls_comp_q] <= '0;
                st_q <= W_LSA;
              end else begin
                ls_addr_q <= bn[96:33] + {32'h0, o32};
                st_q <= W_LS1;
              end
            end else if (tg[3:0] == APU_SH_SC_WORKGROUP ||
                         tg[3:0] == APU_SH_SC_FUNCTION ||
                         tg[3:0] == APU_SH_SC_PRIVATE) begin
              st_q <= W_SSB;
            end else begin
              robust_q <= robust_q + 1;
              if (!ls_store_q)
                wb_q[ls_lane_q[2:0]][ls_comp_q] <= '0;
              st_q <= W_LSA;
            end
          end
          W_LS1: st_q <= W_LS2;               // mem_re/we issued
          W_LS2: begin
            if (!ls_store_q)
              wb_q[ls_lane_q[2:0]][ls_comp_q] <=
                ls_addr_q[2] ? mem_rdata_i[63:32]
                             : mem_rdata_i[31:0];
            st_q <= W_LSA;
          end
          W_SSB: st_q <= W_SSB1;              // sb/sc issued
          W_SSB1: begin
            if (ls_sc_q == APU_SH_SC_WORKGROUP) begin
              if ((ls_off_q >> 2) >= SLW) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][ls_comp_q] <= '0;
              end else if (!ls_store_q) begin
                wb_q[ls_lane_q[2:0]][ls_comp_q] <= sb_rdata;
              end
            end else begin
              if ((ls_off_q >> 2) >= SCW ||
                  ls_off_q >= {16'h0, escratch_q}) begin
                robust_q <= robust_q + 1;
                if (!ls_store_q)
                  wb_q[ls_lane_q[2:0]][ls_comp_q] <= '0;
              end else if (!ls_store_q) begin
                wb_q[ls_lane_q[2:0]][ls_comp_q] <= sc_rdata;
              end
            end
            st_q <= W_LSA;
          end
          W_LSA: begin
            if (ls_comp_q + 1 < ncomp_q) begin
              ls_comp_q <= ls_comp_q + 1; st_q <= W_LS0;
            end else if (ls_lane_q + 1 < LAN) begin
              ls_comp_q <= '0; ls_lane_q <= ls_lane_q + 1;
              st_q <= W_LS0;
            end else begin
              ls_comp_q <= '0; ls_lane_q <= '0;
              st_q <= ls_store_q ? W_NEXT : W_WB;
            end
          end
          W_WB: begin
            st_q <= W_NEXT;
          end
          W_NEXT: begin
            pc_q <= pc_q + wc_q;
            insns_q <= insns_q + 1;
            xq_q <= '0;      // ExtInst step counter is per instruction
            if (insns_q + 1 > ShaderBudget) begin
              done_code_q <= APU_SH_DONE_BUDGET;
              fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
              st_q <= W_DONE;
            end else st_q <= W_F0;
          end
          W_EOW: begin
            if (wave_q + 1 < nwaves_q) begin
              wave_q <= wave_q + 1;
              lanes_q <= (32'(wave_q + 1) * LAN + LAN <
                          32'(lx_q) * ly_q * lz_q)
                         ? LAN
                         : 8'(32'(lx_q) * ly_q * lz_q -
                              32'(wave_q + 1) * LAN);
              init_i_q <= '0; st_q <= W_IW0;
            end else begin
              wave_q <= '0;
              lanes_q <= (LAN < 32'(lx_q) * ly_q * lz_q)
                         ? LAN : 8'(32'(lx_q) * ly_q * lz_q);
              if (wgx_q + 1 < gx_q) begin
                wgx_q <= wgx_q + 1; init_i_q <= '0; st_q <= W_IW0;
              end else if (wgy_q + 1 < gy_q) begin
                wgx_q <= '0; wgy_q <= wgy_q + 1; init_i_q <= '0;
                st_q <= W_IW0;
              end else if (wgz_q + 1 < gz_q) begin
                wgx_q <= '0; wgy_q <= '0; wgz_q <= wgz_q + 1;
                init_i_q <= '0; st_q <= W_IW0;
              end else begin
                done_code_q <= APU_SH_DONE_OK;
                fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
                st_q <= W_DONE;
              end
            end
          end
          W_DONE: begin
            done_o <= 1'b1;
            st_q <= W_IDLE;
          end
          default: begin
            done_code_q <= APU_SH_DONE_FAULT;
            fl_pc_q <= pc_q; fl_wave_q <= {8'h0, wave_q};
            st_q <= W_DONE;
          end
        endcase
      end
    end
  end
endmodule

// Thin fixture for the yosys Enable=0/1 screens (generic flow).
module g6lc_apu_shwave_fixture
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
  parameter int unsigned WaitBound     = 32'd4096
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  input  logic         disp_i,
  input  apu_sh_dispatch_t disp_pl_i,
  input  logic [16*113-1:0] binds_i,
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
  input  logic [127:0] entry_data_i,
  output logic         mem_re_o,
  output logic         mem_we_o,
  output logic [63:0]  mem_addr_o,
  output logic [63:0]  mem_wdata_o,
  output logic [7:0]   mem_wstrb_o,
  input  logic [63:0]  mem_rdata_i
);
  g6lc_apu_shwave #(.Enable(Enable), .ShaderLanes(ShaderLanes),
      .ShaderVec(ShaderVec), .ShaderRegs(ShaderRegs),
      .MaxWaves(MaxWaves), .ShaderIds(ShaderIds),
      .ShaderSlots(ShaderSlots), .ShaderWords(ShaderWords),
      .ShaderInit(ShaderInit), .ShaderMembers(ShaderMembers),
      .ScratchBytes(ScratchBytes), .SlabBytes(SlabBytes),
      .ShaderBudget(ShaderBudget), .WaitBound(WaitBound)
    ) i_dut (.*);
endmodule
