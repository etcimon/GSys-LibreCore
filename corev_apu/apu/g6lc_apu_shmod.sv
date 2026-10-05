// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// ShaderCore commit scanner (§7a of
// architecture/uncore/apu-vulkan-engine.md).  `wr_*` stages module
// words into the slot's program SRAM; `commit_i` zero-fills the
// slot's tables, walks the module once enforcing the 4a subset
// (mirroring tools/shader/spirv_scan.py word-for-word), fills the
// tc_sram tables and reports {ok | fault{code,opcode,word}}.
// `retire_i` marks the slot dead.
//
// Table geometry (per slot, all tc_sram): program 1 w/word,
// type 3 w/id, const 16 w/id, member 2 w/entry, decor 2 w/id,
// var 2 w/id, regmap 1 w/id, init 2 w/entry, block 1 w/label,
// phi 5 w/result-id, entry 4 w.  regmap = {tag[31:30] (0 reg/1 const),
// aux[29:26] (const word count), type_id[25:16], idx[15:0]}.
// var word0 = {flags[3:0][31:28], builtin[7:0], binding[7:0],
// set[7:0], storage[3:0]}; phi row (§7c, one per OpPhi result id,
// keyed by that id): word0 = parent/value pair count (1..4), word k
// (1..4) = {parent label id[31:16], value id[15:0]}, in operand
// order — spirv_scan.py phi_words() emits the same layout.
// OpMemberDecorate targets are staged in a MDN-entry flop window
// (they precede the OpTypeStruct they annotate); <=16 OpBranch
// targets are queued and re-checked forward-only after the walk.
// An id operand >= ShaderIds faults FWDREF on table reads (a Python
// dict miss) or BOUND on table writes/results.
//
// Timing impact: one SRAM access per phase, ~2-5 phases per module
// word plus a ShaderIds-cycle table clear at commit start.  The
// wave/TB read ports are owned by the scanner while busy_o (shcore
// serializes commit and dispatch in 4a).
//
// Review checklist: async active-low reset; single always_ff;
// all tables tc_sram; Enable=0 ties outputs off, no datapath.
// Array ports are packed (Verilator-5.008 lesson).

module g6lc_apu_shmod
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ShaderInit    = 128
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  // module word staging (slot program SRAM)
  input  logic         wr_en_i,
  input  logic [2:0]   wr_slot_i,
  input  logic [15:0]  wr_addr_i,
  input  logic [31:0]  wr_data_i,
  // commit / retire
  input  logic         commit_i,
  input  apu_sh_commit_t commit_pl_i,
  output logic         busy_o,
  output logic         done_o,
  output apu_sh_cpl_t  done_pl_o,
  input  logic         retire_i,
  input  logic [2:0]   retire_slot_i,
  // wave/TB read ports (1-cycle SRAM latency; !busy_o only)
  input  logic [2:0]   rd_slot_i,
  input  logic [15:0]  prog_addr_i,
  output logic [31:0]  prog_data_o,
  input  logic [9:0]   type_id_i,
  output logic [95:0]  type_data_o,
  input  logic [9:0]   const_id_i,
  output logic [511:0] const_data_o,
  input  logic [9:0]   memb_id_i,
  output logic [63:0]  memb_data_o,
  input  logic [9:0]   decor_id_i,
  output logic [63:0]  decor_data_o,
  input  logic [9:0]   var_id_i,
  output logic [63:0]  var_data_o,
  input  logic [9:0]   rm_id_i,
  output logic [31:0]  rm_data_o,
  input  logic [9:0]   init_id_i,
  output logic [63:0]  init_data_o,
  input  logic [9:0]   blk_id_i,
  output logic [31:0]  blk_data_o,
  input  logic [9:0]   phi_id_i,
  output logic [159:0] phi_data_o,
  output logic [127:0] entry_data_o
);
  if (!Enable) begin : gen_off
    assign busy_o = 1'b0;      assign done_o = 1'b0;
    assign done_pl_o = '0;
    assign prog_data_o = '0;   assign type_data_o = '0;
    assign const_data_o = '0;  assign memb_data_o = '0;
    assign decor_data_o = '0;  assign var_data_o = '0;
    assign rm_data_o = '0;     assign init_data_o = '0;
    assign blk_data_o = '0;    assign phi_data_o = '0;
    assign entry_data_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | wr_en_i |
                    (|wr_slot_i) | (|wr_addr_i) | (|wr_data_i) |
                    commit_i | (|commit_pl_i) | retire_i |
                    (|retire_slot_i) | (|rd_slot_i) |
                    (|prog_addr_i) | (|type_id_i) | (|const_id_i) |
                    (|memb_id_i) | (|decor_id_i) | (|var_id_i) |
                    (|rm_id_i) | (|init_id_i) | (|blk_id_i) |
                    (|phi_id_i);
  end else begin : gen_on
    localparam int unsigned SW  = $clog2(ShaderSlots);
    localparam int unsigned PW  = $clog2(ShaderSlots * ShaderWords);
    localparam int unsigned LSW = $clog2(ShaderWords);
    localparam int unsigned IW  = $clog2(ShaderIds);
    localparam int unsigned MW  = $clog2(ShaderMembers);
    localparam int unsigned INW = $clog2(ShaderInit);
    localparam int unsigned OPB = 32;   // operand staging words
    localparam int unsigned MDN = 64;   // pending member-decor window
    localparam int unsigned BRN = 48;   // queued branch targets
    localparam int unsigned CFD = 8;    // commit loop-nesting bound (CfDepth)

    // ---- table SRAM port signals ---------------------------------------
    logic                  pr_req, pr_we;
    logic [PW-1:0]         pr_addr;
    logic [31:0]           pr_wdata, pr_rdata;
    logic                  ty_req, ty_we;
    logic [IW+SW-1:0]      ty_addr;
    logic [95:0]           ty_wdata, ty_rdata;
    logic                  co_req, co_we;
    logic [IW+SW-1:0]      co_addr;
    logic [511:0]          co_wdata, co_rdata;
    logic                  de_req, de_we;
    logic [IW+SW-1:0]      de_addr;
    logic [63:0]           de_wdata, de_rdata;
    logic                  va_req, va_we;
    logic [IW+SW-1:0]      va_addr;
    logic [63:0]           va_wdata, va_rdata;
    logic                  rm_req, rm_we;
    logic [IW+SW-1:0]      rm_addr;
    logic [31:0]           rm_wdata, rm_rdata;
    logic                  bk_req, bk_we;
    logic [IW+SW-1:0]      bk_addr;
    logic [31:0]           bk_wdata, bk_rdata;
    logic                  mb_req, mb_we;
    logic [MW+SW-1:0]      mb_addr;
    logic [63:0]           mb_wdata, mb_rdata;
    logic                  in_req, in_we;
    logic [INW+SW-1:0]     in_addr;
    logic [63:0]           in_wdata, in_rdata;
    logic                  en_req, en_we;
    logic [SW-1:0]         en_addr;
    logic [127:0]          en_wdata, en_rdata;
    logic                  ph_req, ph_we;
    logic [IW+SW-1:0]      ph_addr;
    logic [159:0]          ph_wdata, ph_rdata;

    // ---- FSM state ------------------------------------------------------
    typedef enum logic [4:0] {
      S_IDLE, S_CLR, S_HDR, S_IW, S_W0, S_LD, S_OP,
      S_DRC, S_MDC, S_TYC, S_CON, S_VRB, S_RES, S_BRC, S_ENT, S_DONE
    } st_e;
    st_e st_q;
    logic [2:0]  slot_q;
    logic [15:0] nw_q, at_q, i_q, nl_q;
    logic [31:0] w0_q;
    logic [31:0] ops_q [OPB];
    logic [15:0] opc_q, wc_q;
    logic [5:0]  ph_q;
    logic [IW-1:0] clr_q;
    logic [15:0] n_regs_q, n_init_q, n_memb_q, scratch_q, slab_q;
    logic [7:0]  lx_q, ly_q, lz_q;
    logic [15:0] entry_off_q;
    logic [9:0]  glsl_id_q, elem_q;
    logic        entry_seen_q, in_func_q;
    logic [15:0] esize_q, stride_q, sz_q, voff_q;
    logic [511:0] crow_q;
    logic [4:0]   cn_q, cn_i_q;
    // member-decor window
    logic [9:0]  md_id_q  [MDN];
    logic [4:0]  md_m_q   [MDN];
    logic [15:0] md_off_q [MDN];
    logic [15:0] md_ms_q  [MDN];
    logic [7:0]  md_fl_q  [MDN];
    logic [6:0]  md_n_q;
    // forward-branch check queue
    logic [15:0] br_at_q [BRN];
    logic [9:0]  br_tg_q [BRN];
    logic [5:0]  br_n_q;
    // structured-flow commit state (4b): mp_q = previous instruction was
    // OpLoopMerge/OpSelectionMerge; lp_* = open loop {merge,continue} stack
    logic        mp_q;
    logic [9:0]  lp_m_q [CFD];
    logic [9:0]  lp_c_q [CFD];
    logic [3:0]  lp_n_q;
    // deferred single-row writes from S_OP (land next cycle)
    logic        dw_rm_q, dw_bk_q, dw_ph_q;
    logic [9:0]  dw_rm_id_q, dw_bk_id_q, dw_ph_id_q;
    logic [31:0] dw_rm_w_q, dw_bk_w_q;
    logic [159:0] dw_ph_w_q;
    // fault
    logic [7:0]  fl_code_q;
    logic [15:0] fl_opc_q, fl_word_q;
    logic        fail_q;
    logic [ShaderSlots-1:0] live_q;
    logic        busy_q;
    assign busy_o = busy_q;

    // type row fields (w0..w2 packed in one 96-bit row)
    wire [3:0]  ty_kind    = ty_rdata[3:0];
    wire [2:0]  ty_comps   = ty_rdata[7:5];
    wire [2:0]  ty_cols    = ty_rdata[10:8];
    wire [3:0]  ty_storage = ty_rdata[14:11];
    wire [9:0]  ty_elem    = ty_rdata[24:15];
    wire [15:0] ty_size    = ty_rdata[79:64];

    // ---- mdecor window lookups (combinational) ------------------------
    logic [6:0]  md_hit_d, md_hit_s;
    logic        md_found_d, md_found_s;
    logic [15:0] mdv_off, mdv_ms;
    logic [7:0]  mdv_fl;
    always_comb begin
      md_hit_d = md_n_q; md_found_d = 1'b0;
      md_hit_s = md_n_q; md_found_s = 1'b0;
      for (int t = 0; t < MDN; t++) begin
        if (t < md_n_q && md_id_q[t] == ops_q[0][9:0] &&
            md_m_q[t] == ops_q[1][4:0]) begin
          md_hit_d = 7'(t); md_found_d = 1'b1;
        end
        if (t < md_n_q && md_id_q[t] == ops_q[0][9:0] &&
            md_m_q[t] == 5'(ph_q >> 1)) begin
          md_hit_s = 7'(t); md_found_s = 1'b1;
        end
      end
      mdv_off = md_found_s ? md_off_q[md_hit_s] : 16'h0;
      mdv_ms  = md_found_s ? md_ms_q[md_hit_s]  : 16'h0;
      mdv_fl  = md_found_s ? md_fl_q[md_hit_s]  : 8'h0;
    end

    // ---- opcode predicates -------------------------------------------
    function automatic logic is_accepted(input logic [15:0] o);
      unique case (o)
        0,3,5,6,7,8,11,12,14,15,16,17,19,20,21,22,23,24,28,29,30,32,33,
        41,42,43,44,46,48,49,50,51,52,54,56,59,61,62,65,66,68,71,72,
        79,80,81,82,84,109,110,111,112,124,126,127,128,129,130,131,132,
        133,134,135,136,137,138,139,142,143,144,145,146,147,148,
        164,165,166,167,168,169,
        170,171,172,173,174,175,176,177,178,179,180,182,183,184,186,
        188,190,194,195,196,197,198,199,200,224,225,245,246,247,248,
        249,250,251,253,255:
          is_accepted = 1'b1;
        default: is_accepted = 1'b0;
      endcase
    endfunction
    function automatic logic has_result(input logic [15:0] o);
      unique case (o)
        61,65,66,68,79,80,81,82,84,109,110,111,112,124,126,127,128,129,
        130,131,132,133,134,135,136,137,138,139,142,143,144,145,146,
        147,148,164,165,166,
        167,168,169,170,171,172,173,174,175,176,177,178,179,180,182,
        183,184,186,188,190,194,195,196,197,198,199,200,245:
          has_result = 1'b1;
        default: has_result = 1'b0;
      endcase
    endfunction
    function automatic logic is_type_op(input logic [15:0] o);
      unique case (o)
        19,20,21,22,23,24,28,29,30,32,33: is_type_op = 1'b1;
        default: is_type_op = 1'b0;
      endcase
    endfunction
    function automatic logic is_const_op(input logic [15:0] o);
      unique case (o)
        41,42,43,44,46,48,49,50,51: is_const_op = 1'b1;
        default: is_const_op = 1'b0;
      endcase
    endfunction
    function automatic logic is_ext450(input logic [15:0] n);
      unique case (n)
        1,2,3,4,5,6,7,8,9,10,31,32,37,38,39,40,41,42,43,44,45,46,48,
        49,50,66,67,68,69: is_ext450 = 1'b1;
        default: is_ext450 = 1'b0;
      endcase
    endfunction
    function automatic logic is_dec_id(input logic [15:0] d);
      unique case (d)
        0,1,2,3,6,11,19,20,24,25,26,33,34,42: is_dec_id = 1'b1;
        default: is_dec_id = 1'b0;
      endcase
    endfunction
    function automatic logic is_dec_mbr(input logic [15:0] d);
      unique case (d)
        0,1,4,5,7,24,25,35,42: is_dec_mbr = 1'b1;
        default: is_dec_mbr = 1'b0;
      endcase
    endfunction
    function automatic logic is_sc_ok(input logic [3:0] s);
      unique case (s)
        APU_SH_SC_UNIFORMCONST, APU_SH_SC_INPUT, APU_SH_SC_UNIFORM,
        APU_SH_SC_WORKGROUP, APU_SH_SC_PRIVATE, APU_SH_SC_FUNCTION,
        APU_SH_SC_PUSHCONST, APU_SH_SC_SBUF: is_sc_ok = 1'b1;
        default: is_sc_ok = 1'b0;
      endcase
    endfunction
    function automatic logic [15:0] ops_need(input logic [15:0] o,
                                             input logic [15:0] n);
      unique case (o)
        0,3,5,6,7,8:        ops_need = 0;
        15:                 ops_need = 2;
        17,248,249:         ops_need = 1;
        14:                 ops_need = 2;
        16:                 ops_need = 5;
        11:                 ops_need = (n < 5) ? n : 5;
        12:                 ops_need = 4;
        71:                 ops_need = 3;
        72:                 ops_need = 4;
        54:                 ops_need = 2;
        59:                 ops_need = (n < 4) ? n : 4;
        default:            ops_need = n;
      endcase
    endfunction
    // {st, sz, ln, mb, 0, nmemb, elem, sc, cols, comps, sign, kind}
    function automatic logic [95:0] mk_type(
      input logic [3:0] kind, input logic sgn, input logic [2:0] comps,
      input logic [2:0] cols, input logic [3:0] sc, input logic [9:0] el,
      input logic [3:0] nm, input logic [15:0] mb, input logic [15:0] ln,
      input logic [15:0] sz, input logic [15:0] st);
      mk_type = {st, sz, ln, mb, 3'h0, nm, el, sc, cols, comps, sgn,
                 kind};
    endfunction
    // target == innermost open loop merge or continue label (the
    // merge-free conditional / switch escape hatch of the commit rule)
    function automatic logic tg_is_lc(input logic [9:0] tg);
      return (lp_n_q != 0) &&
             (tg == lp_m_q[lp_n_q-4'd1] || tg == lp_c_q[lp_n_q-4'd1]);
    endfunction
    function automatic logic sw_merge_free();
      logic mf;
      mf = mp_q | tg_is_lc(ops_q[1][9:0]);
      for (int k = 0; k < 15; k++)
        if (k < (wc_q - 3) >> 1 && tg_is_lc(ops_q[3+2*k][9:0]))
          mf = 1'b1;
      return mf;
    endfunction
    // OpPhi table row: word0 = pair count, word(1+k) = {parent, value}
    function automatic logic [159:0] phi_pack();
      logic [159:0] r;
      r = '0;
      r[15:0] = (wc_q - 3) >> 1;
      for (int k = 0; k < 4; k++)
        if (k < (wc_q - 3) >> 1)
          r[32*(k+1) +: 32] = {ops_q[3+2*k][15:0], ops_q[2+2*k][15:0]};
      return r;
    endfunction

    wire id_ok0 = ops_q[0] < 32'(ShaderIds);
    wire id_ok1 = ops_q[1] < 32'(ShaderIds);
    wire [15:0] ld_sum = at_q + i_q + 16'd1;

    // var/init row assembly (from the ph2 captures)
    logic [31:0] var_w0, var_w1, init_w0, init_w1;
    logic [7:0]  drc_nb;
    always_comb begin
      // undecorated variables default builtin to 8'hFF (Python
      // d.get('builtin', 0xFF)); the decor table row itself keeps 0.
      var_w0 = {de_rdata[28:24],
                (de_rdata[23:16] == 8'h0) ? 8'hFF : de_rdata[23:16],
                de_rdata[15:8], de_rdata[7:0], ops_q[2][3:0]};
      var_w1 = {6'h0, elem_q, voff_q};
      init_w0 = {4'h0,
                 (de_rdata[23:16] == 8'h0) ? 8'hFF : de_rdata[23:16],
                 ops_q[2][3:0], n_regs_q};
      init_w1 = {voff_q, de_rdata[15:8], de_rdata[7:0]};
    end

    // ---- SRAM port drives (combinational) -----------------------------
    always_comb begin
      pr_req = 1'b0; pr_we = 1'b0; pr_addr = '0; pr_wdata = '0;
      ty_req = 1'b0; ty_we = 1'b0; ty_addr = '0; ty_wdata = '0;
      co_req = 1'b0; co_we = 1'b0; co_addr = '0; co_wdata = '0;
      de_req = 1'b0; de_we = 1'b0; de_addr = '0; de_wdata = '0;
      va_req = 1'b0; va_we = 1'b0; va_addr = '0; va_wdata = '0;
      rm_req = 1'b0; rm_we = 1'b0; rm_addr = '0; rm_wdata = '0;
      bk_req = 1'b0; bk_we = 1'b0; bk_addr = '0; bk_wdata = '0;
      mb_req = 1'b0; mb_we = 1'b0; mb_addr = '0; mb_wdata = '0;
      in_req = 1'b0; in_we = 1'b0; in_addr = '0; in_wdata = '0;
      en_req = 1'b0; en_we = 1'b0; en_addr = '0; en_wdata = '0;
      ph_req = 1'b0; ph_we = 1'b0; ph_addr = '0; ph_wdata = '0;
      if (!busy_q) begin
        if (wr_en_i) begin
          pr_req = 1'b1; pr_we = 1'b1;
          pr_addr = {wr_slot_i, wr_addr_i[LSW-1:0]};
          pr_wdata = wr_data_i;
        end else begin
          pr_req = 1'b1;
          pr_addr = {rd_slot_i, prog_addr_i[LSW-1:0]};
        end
        ty_req = 1'b1; ty_addr = {rd_slot_i, type_id_i};
        co_req = 1'b1; co_addr = {rd_slot_i, const_id_i};
        de_req = 1'b1; de_addr = {rd_slot_i, decor_id_i};
        va_req = 1'b1; va_addr = {rd_slot_i, var_id_i};
        rm_req = 1'b1; rm_addr = {rd_slot_i, rm_id_i};
        bk_req = 1'b1; bk_addr = {rd_slot_i, blk_id_i};
        mb_req = 1'b1; mb_addr = {rd_slot_i, memb_id_i[MW-1:0]};
        in_req = 1'b1; in_addr = {rd_slot_i, init_id_i[INW-1:0]};
        en_req = 1'b1; en_addr = rd_slot_i;
        ph_req = 1'b1; ph_addr = {rd_slot_i, phi_id_i};
      end else begin
        if (dw_rm_q) begin
          rm_req = 1'b1; rm_we = 1'b1;
          rm_addr = {slot_q, dw_rm_id_q}; rm_wdata = dw_rm_w_q;
        end
        if (dw_bk_q) begin
          bk_req = 1'b1; bk_we = 1'b1;
          bk_addr = {slot_q, dw_bk_id_q}; bk_wdata = dw_bk_w_q;
        end
        if (dw_ph_q) begin
          ph_req = 1'b1; ph_we = 1'b1;
          ph_addr = {slot_q, dw_ph_id_q}; ph_wdata = dw_ph_w_q;
        end
        unique case (st_q)
          S_CLR: begin
            ty_req = 1'b1; ty_we = 1'b1; ty_addr = {slot_q, clr_q};
            co_req = 1'b1; co_we = 1'b1; co_addr = {slot_q, clr_q};
            de_req = 1'b1; de_we = 1'b1; de_addr = {slot_q, clr_q};
            va_req = 1'b1; va_we = 1'b1; va_addr = {slot_q, clr_q};
            rm_req = 1'b1; rm_we = 1'b1; rm_addr = {slot_q, clr_q};
            bk_req = 1'b1; bk_we = 1'b1; bk_addr = {slot_q, clr_q};
            if (clr_q < 10'(ShaderMembers)) begin
              mb_req = 1'b1; mb_we = 1'b1;
              mb_addr = {slot_q, clr_q[MW-1:0]};
            end
            if (clr_q < 10'(ShaderInit)) begin
              in_req = 1'b1; in_we = 1'b1;
              in_addr = {slot_q, clr_q[INW-1:0]};
            end
            ph_req = 1'b1; ph_we = 1'b1; ph_addr = {slot_q, clr_q};
          end
          S_HDR: begin
            pr_req = (i_q < 5); pr_addr = {slot_q, PW'(i_q)};
          end
          S_IW: begin
            pr_req = 1'b1; pr_addr = {slot_q, at_q[LSW-1:0]};
          end
          S_LD: begin
            pr_req = (i_q < nl_q);
            pr_addr = {slot_q, ld_sum[LSW-1:0]};
          end
          S_DRC: begin
            de_req = 1'b1; de_addr = {slot_q, ops_q[0][9:0]};
            if (ph_q == 1) begin
              de_we = 1'b1;
              // builtin field defaults to 8'hFF (Python
              // decor.get('builtin', 0xFF)); a written row with the
              // field still zero means "not yet decorated".
              drc_nb = (de_rdata[23:16] == 8'h0) ? 8'hFF
                       : de_rdata[23:16];
              unique case (ops_q[1][15:0])
                33: de_wdata = {de_rdata[63:32], de_rdata[31:24],
                                drc_nb, ops_q[2][7:0],
                                de_rdata[7:0]};
                34: de_wdata = {de_rdata[63:32], de_rdata[31:24],
                                drc_nb, de_rdata[15:8],
                                ops_q[2][7:0]};
                11: de_wdata = {de_rdata[63:32], de_rdata[31:24],
                                ops_q[2][7:0], de_rdata[15:0]};
                6:  de_wdata = {ops_q[2], de_rdata[31:24], drc_nb,
                                de_rdata[15:0]};
                default: de_wdata = {de_rdata[63:32],
                      de_rdata[31:24] | 8'(8'h1 << ops_q[1][2:0]),
                      drc_nb, de_rdata[15:0]};
              endcase
            end
          end
          S_TYC: begin
            unique case (opc_q)
              23,24,32: begin
                if (ph_q == 0) begin
                  ty_req = 1'b1;
                  ty_addr = {slot_q,
                             ops_q[(opc_q == 32) ? 2 : 1][9:0]};
                end else if (ph_q == 2) begin
                  ty_req = 1'b1; ty_we = 1'b1;
                  ty_addr = {slot_q, ops_q[0][9:0]};
                  unique case (opc_q)
                    23: ty_wdata = mk_type(APU_SH_TK_VEC, 0,
                                   ops_q[2][2:0], 0, 0, ops_q[1][9:0],
                                   0, 0, 0, 16'(ops_q[2] * 4), 0);
                    24: ty_wdata = mk_type(APU_SH_TK_MAT, 0, ty_comps,
                                   ops_q[2][2:0], 0, ops_q[1][9:0],
                                   0, 0, 0,
                                   16'(ops_q[2] * 4 * 32'(ty_comps)),
                                   0);
                    default: ty_wdata = mk_type(APU_SH_TK_PTR, 0, 0, 0,
                                   ops_q[1][3:0], ops_q[2][9:0],
                                   0, 0, 0, 16, 0);
                  endcase
                end
              end
              28: begin
                unique case (ph_q)
                  0: begin ty_req = 1'b1;
                       ty_addr = {slot_q, ops_q[1][9:0]}; end
                  2: begin rm_req = 1'b1;
                       rm_addr = {slot_q, ops_q[2][9:0]}; end
                  3: begin co_req = 1'b1;
                       co_addr = {slot_q, ops_q[2][9:0]}; end
                  4: begin de_req = 1'b1;
                       de_addr = {slot_q, ops_q[0][9:0]}; end
                  6: begin ty_req = 1'b1; ty_we = 1'b1;
                       ty_addr = {slot_q, ops_q[0][9:0]};
                       ty_wdata = mk_type(APU_SH_TK_ARRAY, 0, 0, 0, 0,
                                   ops_q[1][9:0], 0, 0, sz_q,
                                   esize_q, stride_q); end
                  default: ;
                endcase
              end
              29: begin
                unique case (ph_q)
                  0: begin ty_req = 1'b1;
                       ty_addr = {slot_q, ops_q[1][9:0]}; end
                  2: begin de_req = 1'b1;
                       de_addr = {slot_q, ops_q[0][9:0]}; end
                  4: begin ty_req = 1'b1; ty_we = 1'b1;
                       ty_addr = {slot_q, ops_q[0][9:0]};
                       ty_wdata = mk_type(APU_SH_TK_RARRAY, 0, 0, 0, 0,
                                   ops_q[1][9:0], 0, 0, 0, 0,
                                   stride_q); end
                  default: ;
                endcase
              end
              30: begin
                if (!ph_q[0] && (ph_q >> 1) < 6'(wc_q - 2)) begin
                  ty_req = 1'b1;
                  ty_addr = {slot_q, ops_q[1 + (ph_q >> 1)][9:0]};
                end
                if (ph_q[0] && (ph_q >> 1) < 6'(wc_q - 2)) begin
                  mb_req = 1'b1; mb_we = 1'b1;
                  mb_addr = {slot_q, MW'(n_memb_q + (ph_q >> 1))};
                  mb_wdata = {14'h0, ops_q[1 + (ph_q >> 1)][9:0],
                              mdv_fl, mdv_ms, mdv_off};
                end
                if (ph_q == 6'(2 * (wc_q - 2))) begin
                  ty_req = 1'b1; ty_we = 1'b1;
                  ty_addr = {slot_q, ops_q[0][9:0]};
                  ty_wdata = mk_type(APU_SH_TK_STRUCT, 0, 0, 0, 0, 0,
                                     4'(wc_q - 2), n_memb_q, 0,
                                     sz_q, 0);
                end
              end
              33: begin
                if (ph_q == 0) begin
                  ty_req = 1'b1; ty_addr = {slot_q, ops_q[1][9:0]};
                end else if (ph_q == 2) begin
                  ty_req = 1'b1; ty_we = 1'b1;
                  ty_addr = {slot_q, ops_q[0][9:0]};
                  ty_wdata = mk_type(APU_SH_TK_FUNC, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0);
                end
              end
              default: begin
                if (ph_q == 1) begin
                  ty_req = 1'b1; ty_we = 1'b1;
                  ty_addr = {slot_q, ops_q[0][9:0]};
                  unique case (opc_q)
                    19: ty_wdata = mk_type(APU_SH_TK_VOID, 0, 0, 0, 0,
                                           0, 0, 0, 0, 0, 0);
                    20: ty_wdata = mk_type(APU_SH_TK_BOOL, 0, 1, 0, 0,
                                           0, 0, 0, 0, 4, 0);
                    21: ty_wdata = mk_type(APU_SH_TK_INT, ops_q[2][0],
                                           1, 0, 0, 0, 0, 0, 0, 4, 0);
                    default: ty_wdata = mk_type(APU_SH_TK_FLOAT, 0, 1,
                                           0, 0, 0, 0, 0, 0, 4, 0);
                  endcase
                end
              end
            endcase
          end
          S_CON: begin
            unique case (opc_q)
              46: begin
                unique case (ph_q)
                  0: begin ty_req = 1'b1;
                       ty_addr = {slot_q, ops_q[0][9:0]}; end
                  2: begin co_req = 1'b1; co_we = 1'b1;
                       co_addr = {slot_q, ops_q[1][9:0]};
                       co_wdata = crow_q; end
                  3: begin rm_req = 1'b1; rm_we = 1'b1;
                       rm_addr = {slot_q, ops_q[1][9:0]};
                       rm_wdata = {2'b01, cn_q[3:0], ops_q[0][9:0],
                                   ops_q[1][15:0]}; end
                  default: ;
                endcase
              end
              44,51: begin
                if (ph_q < 6'(3 * (wc_q - 3))) begin
                  if (ph_q % 3 == 0) begin
                    rm_req = 1'b1;
                    rm_addr = {slot_q, ops_q[2 + (ph_q / 3)][9:0]};
                  end else if (ph_q % 3 == 1) begin
                    co_req = 1'b1;
                    co_addr = {slot_q, ops_q[2 + (ph_q / 3)][9:0]};
                  end
                end else if (ph_q == 6'(3 * (wc_q - 3))) begin
                  co_req = 1'b1; co_we = 1'b1;
                  co_addr = {slot_q, ops_q[1][9:0]};
                  co_wdata = crow_q;
                end else begin
                  rm_req = 1'b1; rm_we = 1'b1;
                  rm_addr = {slot_q, ops_q[1][9:0]};
                  rm_wdata = {2'b01, cn_q[3:0], ops_q[0][9:0],
                              ops_q[1][15:0]};
                end
              end
              default: begin
                unique case (ph_q)
                  1: begin co_req = 1'b1; co_we = 1'b1;
                       co_addr = {slot_q, ops_q[1][9:0]};
                       co_wdata = crow_q; end
                  2: begin rm_req = 1'b1; rm_we = 1'b1;
                       rm_addr = {slot_q, ops_q[1][9:0]};
                       rm_wdata = {2'b01, cn_q[3:0], ops_q[0][9:0],
                                   ops_q[1][15:0]}; end
                  default: ;
                endcase
              end
            endcase
          end
          S_VRB: begin
            unique case (ph_q)
              0: begin ty_req = 1'b1;
                   ty_addr = {slot_q, ops_q[0][9:0]}; end
              1: begin
                   ty_req = 1'b1; ty_addr = {slot_q, ty_elem};
                   de_req = 1'b1; de_addr = {slot_q, ops_q[1][9:0]};
                end
              3: begin
                   va_req = 1'b1; va_we = 1'b1;
                   va_addr = {slot_q, ops_q[1][9:0]};
                   va_wdata = {var_w1, var_w0};
                   in_req = 1'b1; in_we = 1'b1;
                   in_addr = {slot_q, n_init_q[INW-1:0]};
                   in_wdata = {init_w1, init_w0};
                   rm_req = 1'b1; rm_we = 1'b1;
                   rm_addr = {slot_q, ops_q[1][9:0]};
                   rm_wdata = {2'b00, 4'h0, ops_q[0][9:0], n_regs_q};
                end
              default: ;
            endcase
          end
          S_BRC: begin
            bk_req = (ph_q < 6'(br_n_q));
            bk_addr = {slot_q, br_tg_q[ph_q[5:0]]};
          end
          S_RES: begin
            // read the result type row: matrix results occupy one regmap
            // slot per column (ty_cols)
            ty_req = (ph_q == 0); ty_addr = {slot_q, ops_q[0][9:0]};
          end
          S_ENT: begin
            en_req = 1'b1; en_we = 1'b1; en_addr = slot_q;
            en_wdata = {32'(slab_q), 32'(scratch_q),
                        8'(n_init_q), lz_q, ly_q, lx_q,
                        n_regs_q, entry_off_q};
          end
          default: ;
        endcase
      end
    end

    tc_sram #(.NumWords(ShaderSlots*ShaderWords), .DataWidth(32),
              .NumPorts(1)) i_prog (
      .clk_i, .rst_ni, .req_i(pr_req), .we_i(pr_we), .addr_i(pr_addr),
      .wdata_i(pr_wdata), .be_i(4'hF), .rdata_o(pr_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderIds), .DataWidth(96),
              .NumPorts(1)) i_type (
      .clk_i, .rst_ni, .req_i(ty_req), .we_i(ty_we), .addr_i(ty_addr),
      .wdata_i(ty_wdata), .be_i(12'hFFF), .rdata_o(ty_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderIds), .DataWidth(512),
              .NumPorts(1)) i_const (
      .clk_i, .rst_ni, .req_i(co_req), .we_i(co_we), .addr_i(co_addr),
      .wdata_i(co_wdata), .be_i('1), .rdata_o(co_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderIds), .DataWidth(64),
              .NumPorts(1)) i_decor (
      .clk_i, .rst_ni, .req_i(de_req), .we_i(de_we), .addr_i(de_addr),
      .wdata_i(de_wdata), .be_i(8'hFF), .rdata_o(de_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderIds), .DataWidth(64),
              .NumPorts(1)) i_var (
      .clk_i, .rst_ni, .req_i(va_req), .we_i(va_we), .addr_i(va_addr),
      .wdata_i(va_wdata), .be_i(8'hFF), .rdata_o(va_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderIds), .DataWidth(32),
              .NumPorts(1)) i_rm (
      .clk_i, .rst_ni, .req_i(rm_req), .we_i(rm_we), .addr_i(rm_addr),
      .wdata_i(rm_wdata), .be_i(4'hF), .rdata_o(rm_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderIds), .DataWidth(32),
              .NumPorts(1)) i_blk (
      .clk_i, .rst_ni, .req_i(bk_req), .we_i(bk_we), .addr_i(bk_addr),
      .wdata_i(bk_wdata), .be_i(4'hF), .rdata_o(bk_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderMembers), .DataWidth(64),
              .NumPorts(1)) i_memb (
      .clk_i, .rst_ni, .req_i(mb_req), .we_i(mb_we), .addr_i(mb_addr),
      .wdata_i(mb_wdata), .be_i(8'hFF), .rdata_o(mb_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderInit), .DataWidth(64),
              .NumPorts(1)) i_init (
      .clk_i, .rst_ni, .req_i(in_req), .we_i(in_we), .addr_i(in_addr),
      .wdata_i(in_wdata), .be_i(8'hFF), .rdata_o(in_rdata));
    tc_sram #(.NumWords(ShaderSlots*ShaderIds), .DataWidth(160),
              .NumPorts(1)) i_phi (
      .clk_i, .rst_ni, .req_i(ph_req), .we_i(ph_we), .addr_i(ph_addr),
      .wdata_i(ph_wdata), .be_i('1), .rdata_o(ph_rdata));
    tc_sram #(.NumWords(ShaderSlots), .DataWidth(128), .NumPorts(1))
      i_entry (
      .clk_i, .rst_ni, .req_i(en_req), .we_i(en_we), .addr_i(en_addr),
      .wdata_i(en_wdata), .be_i('1), .rdata_o(en_rdata));

    assign prog_data_o  = pr_rdata;
    assign type_data_o  = ty_rdata;
    assign const_data_o = co_rdata;
    assign memb_data_o  = mb_rdata;
    assign decor_data_o = de_rdata;
    assign var_data_o   = va_rdata;
    assign rm_data_o    = rm_rdata;
    assign init_data_o  = in_rdata;
    assign blk_data_o   = bk_rdata;
    assign phi_data_o   = ph_rdata;
    assign entry_data_o = en_rdata;

    integer t;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        st_q <= S_IDLE; busy_q <= 1'b0; done_o <= 1'b0;
        done_pl_o <= '0; fail_q <= 1'b0; fl_code_q <= '0;
        fl_opc_q <= '0; fl_word_q <= '0; live_q <= '0;
        at_q <= '0; i_q <= '0; nl_q <= '0; w0_q <= '0; opc_q <= '0;
        wc_q <= '0; ph_q <= '0; slot_q <= '0; nw_q <= '0;
        clr_q <= '0; n_regs_q <= '0; n_init_q <= '0; n_memb_q <= '0;
        scratch_q <= '0; slab_q <= '0; lx_q <= '0; ly_q <= '0;
        lz_q <= '0; entry_off_q <= '0; glsl_id_q <= '0; elem_q <= '0;
        entry_seen_q <= 1'b0; in_func_q <= 1'b0;
        esize_q <= '0; stride_q <= '0; sz_q <= '0; voff_q <= '0;
        crow_q <= '0; cn_q <= '0; cn_i_q <= '0;
        dw_rm_q <= 1'b0; dw_bk_q <= 1'b0; dw_ph_q <= 1'b0;
        dw_rm_id_q <= '0; dw_bk_id_q <= '0; dw_ph_id_q <= '0;
        dw_rm_w_q <= '0; dw_bk_w_q <= '0; dw_ph_w_q <= '0;
        md_n_q <= '0; br_n_q <= '0; mp_q <= 1'b0; lp_n_q <= '0;
        for (t = 0; t < OPB; t++) ops_q[t] <= '0;
        for (t = 0; t < MDN; t++) begin
          md_id_q[t] <= '0; md_m_q[t] <= '0; md_off_q[t] <= '0;
          md_ms_q[t] <= '0; md_fl_q[t] <= '0;
        end
        for (t = 0; t < BRN; t++) begin
          br_at_q[t] <= '0; br_tg_q[t] <= '0;
        end
      end else begin
        done_o <= 1'b0;
        dw_rm_q <= 1'b0; dw_bk_q <= 1'b0; dw_ph_q <= 1'b0;
        if (st_q == S_MDC) begin
          if (md_found_d) begin
            if (ops_q[2] == 35) md_off_q[md_hit_d] <= ops_q[3][15:0];
            else if (ops_q[2] == 7) md_ms_q[md_hit_d] <=
                                     ops_q[3][15:0];
            else md_fl_q[md_hit_d] <= md_fl_q[md_hit_d] |
                                      8'(8'h1 << ops_q[2][2:0]);
          end else begin
            md_id_q[md_hit_d] <= ops_q[0][9:0];
            md_m_q[md_hit_d]  <= ops_q[1][4:0];
            md_off_q[md_hit_d] <= (ops_q[2] == 35) ?
                                   ops_q[3][15:0] : '0;
            md_ms_q[md_hit_d] <= (ops_q[2] == 7) ? ops_q[3][15:0] : '0;
            md_fl_q[md_hit_d] <= (ops_q[2] == 35 || ops_q[2] == 7) ?
                                  8'h0 : 8'(8'h1 << ops_q[2][2:0]);
            md_n_q <= md_n_q + 1;
          end
        end
        unique case (st_q)
          S_IDLE: begin
            busy_q <= 1'b0;
            if (retire_i) live_q[retire_slot_i] <= 1'b0;
            if (commit_i && !busy_q) begin
              busy_q <= 1'b1; slot_q <= commit_pl_i.slot;
              nw_q <= commit_pl_i.nwords;
              fail_q <= 1'b0; fl_code_q <= '0; fl_opc_q <= '0;
              fl_word_q <= '0; n_regs_q <= '0; n_init_q <= '0;
              n_memb_q <= '0; scratch_q <= '0; slab_q <= '0;
              lx_q <= '0; ly_q <= '0; lz_q <= '0; entry_off_q <= '0;
              glsl_id_q <= '0; entry_seen_q <= 1'b0;
              in_func_q <= 1'b0; md_n_q <= '0; br_n_q <= '0;
              mp_q <= 1'b0; lp_n_q <= '0;
              sz_q <= '0; cn_q <= '0;
              live_q[commit_pl_i.slot] <= 1'b0;
              if (commit_pl_i.nwords < 5) begin
                fl_code_q <= APU_SH_FAULT_MAGIC; fail_q <= 1'b1;
                st_q <= S_DONE;
              end else begin
                clr_q <= '0; st_q <= S_CLR;
              end
            end
          end
          S_CLR: begin
            if (clr_q == IW'(ShaderIds - 1)) begin
              i_q <= '0; at_q <= '0; st_q <= S_HDR;
            end else clr_q <= clr_q + 1;
          end
          // ---- header: issue words 0..4, check on arrival ------------
          S_HDR: begin
            if (i_q == 1) begin
              if (pr_rdata != 32'h0723_0203) begin
                fl_code_q <= APU_SH_FAULT_MAGIC; fl_word_q <= '0;
                fail_q <= 1'b1; st_q <= S_DONE;
              end else i_q <= i_q + 1;
            end else if (i_q == 2) begin
              if (pr_rdata[23:16] > 8'd6) begin
                fl_code_q <= APU_SH_FAULT_VERSION; fl_word_q <= 1;
                fail_q <= 1'b1; st_q <= S_DONE;
              end else i_q <= i_q + 1;
            end else if (i_q == 4) begin
              if (pr_rdata > 32'(ShaderIds)) begin
                fl_code_q <= APU_SH_FAULT_BOUND; fl_word_q <= 3;
                fail_q <= 1'b1; st_q <= S_DONE;
              end else i_q <= i_q + 1;
            end else if (i_q >= 5) begin
              at_q <= 5; st_q <= S_IW;
            end else i_q <= i_q + 1;
          end
          // ---- instruction walk ---------------------------------------
          S_IW: begin
            if (at_q >= nw_q) begin
              if (!entry_seen_q) begin
                fl_code_q <= APU_SH_FAULT_ENTRY; fail_q <= 1'b1;
                st_q <= S_DONE;
              end else if (in_func_q) begin
                fl_code_q <= APU_SH_FAULT_WORDS;
                fl_word_q <= nw_q - 1; fail_q <= 1'b1; st_q <= S_DONE;
              end else if (br_n_q != 0) begin
                ph_q <= '0; st_q <= S_BRC;
              end else st_q <= S_ENT;
            end else st_q <= S_W0;
          end
          S_W0: begin
            w0_q <= pr_rdata; opc_q <= pr_rdata[15:0];
            wc_q <= pr_rdata[31:16];
            // remember whether the instruction just dispatched was a
            // structured merge (gates the next conditional/switch)
            mp_q <= (opc_q == 246 || opc_q == 247);
            if (pr_rdata[31:16] == 0 ||
                32'(at_q) + 32'(pr_rdata[31:16]) > 32'(nw_q)) begin
              fl_code_q <= APU_SH_FAULT_WORDS;
              fl_opc_q <= pr_rdata[15:0]; fl_word_q <= at_q;
              fail_q <= 1'b1; st_q <= S_DONE;
            end else if (!is_accepted(pr_rdata[15:0])) begin
              fl_code_q <= APU_SH_FAULT_OPCODE;
              fl_opc_q <= pr_rdata[15:0]; fl_word_q <= at_q;
              fail_q <= 1'b1; st_q <= S_DONE;
            end else if (ops_need(pr_rdata[15:0],
                                  pr_rdata[31:16] - 1) > 16'(OPB)) begin
              fl_code_q <= APU_SH_FAULT_WORDS;
              fl_opc_q <= pr_rdata[15:0]; fl_word_q <= at_q;
              fail_q <= 1'b1; st_q <= S_DONE;
            end else begin
              nl_q <= ops_need(pr_rdata[15:0], pr_rdata[31:16] - 1);
              i_q <= '0; st_q <= S_LD;
            end
          end
          S_LD: begin
            if (i_q != 0) ops_q[i_q - 1] <= pr_rdata;
            if (i_q == nl_q) begin
              ph_q <= '0; st_q <= S_OP;
            end else i_q <= i_q + 1;
          end
          S_OP: begin
            unique case (opc_q)
              0,3,5,6,7,8: begin
                at_q <= at_q + wc_q; st_q <= S_IW;
              end
              17: begin
                if (ops_q[0] != 1) begin
                  fl_code_q <= APU_SH_FAULT_CAP; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              14: begin
                if (ops_q[0] != 0 || ops_q[1] != 1) begin
                  fl_code_q <= APU_SH_FAULT_MEMMODEL;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              15: begin
                if (ops_q[0] != 5) begin
                  fl_code_q <= APU_SH_FAULT_ENTRY; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else if (entry_seen_q) begin
                  fl_code_q <= APU_SH_FAULT_TWO_ENTRY;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  entry_seen_q <= 1'b1;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              16: begin
                if (ops_q[1] != 17) begin
                  fl_code_q <= APU_SH_FAULT_EXECMODE;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (ops_q[2] * ops_q[3] * ops_q[4] == 0 ||
                             ops_q[2] * ops_q[3] * ops_q[4] > 64) begin
                  fl_code_q <= APU_SH_FAULT_LOCALSIZE;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  lx_q <= ops_q[2][7:0]; ly_q <= ops_q[3][7:0];
                  lz_q <= ops_q[4][7:0];
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              11: begin
                // OpExtInstImport "GLSL.std.450\0": id + 4 name words
                if (nl_q < 5 || ops_q[1] != 32'h4C53_4C47 ||
                    ops_q[2] != 32'h6474_732E ||
                    ops_q[3] != 32'h3035_342E || ops_q[4] != 0) begin
                  fl_code_q <= APU_SH_FAULT_OPCODE;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  glsl_id_q <= ops_q[0][9:0];
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              12: begin
                if (ops_q[2][9:0] != glsl_id_q ||
                    !is_ext450(ops_q[3][15:0])) begin
                  fl_code_q <= APU_SH_FAULT_OPCODE;
                  fl_opc_q <= ops_q[3][15:0]; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (n_regs_q >= 16'(ShaderRegs)) begin
                  fl_code_q <= APU_SH_FAULT_REGS; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (!id_ok1) begin
                  fl_code_q <= APU_SH_FAULT_BOUND; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  dw_rm_q <= 1'b1; dw_rm_id_q <= ops_q[1][9:0];
                  dw_rm_w_q <= {2'b00, 4'h0, ops_q[0][9:0], n_regs_q};
                  n_regs_q <= n_regs_q + 1;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              71: begin
                if (!is_dec_id(ops_q[1][15:0]) ||
                    (ops_q[1] == 11 &&
                     !(ops_q[2] >= 24 && ops_q[2] <= 29))) begin
                  fl_code_q <= APU_SH_FAULT_DECOR;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (!id_ok0) begin
                  fl_code_q <= APU_SH_FAULT_BOUND; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  ph_q <= '0; st_q <= S_DRC;
                end
              end
              72: begin
                if (!is_dec_mbr(ops_q[2][15:0])) begin
                  fl_code_q <= APU_SH_FAULT_DECOR;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (!md_found_d && md_n_q >= 7'(MDN)) begin
                  fl_code_q <= APU_SH_FAULT_DECOR;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  st_q <= S_MDC;
                end
              end
              245: begin
                // OpPhi {rty, rid, (value,parent)*}: the pair table row
                // rides into the phi SRAM from S_RES; parents become
                // branch-existence checks like any jump target.
                if (wc_q < 5 || !wc_q[0] || wc_q > 11) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else if (br_n_q + 6'((wc_q - 3) >> 1) > 6'(BRN)) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else if (!id_ok1) begin
                  fl_code_q <= APU_SH_FAULT_BOUND; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  for (int k = 0; k < 4; k++)
                    if (k < (wc_q - 3) >> 1) begin
                      br_at_q[br_n_q + 6'(k)] <= at_q;
                      br_tg_q[br_n_q + 6'(k)] <= ops_q[3+2*k][9:0];
                    end
                  br_n_q <= br_n_q + 6'((wc_q - 3) >> 1);
                  ph_q <= '0; st_q <= S_RES;
                end
              end
              246: begin
                // OpLoopMerge {merge, continue, ctl}: push the open loop
                // so merge-less BranchConditional/Switch inside it may
                // still target its merge/continue blocks (commit rule).
                if (lp_n_q >= 4'(CFD) || br_n_q + 6'd2 > 6'(BRN)) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  br_at_q[br_n_q] <= at_q;
                  br_tg_q[br_n_q] <= ops_q[0][9:0];
                  br_at_q[br_n_q+6'd1] <= at_q;
                  br_tg_q[br_n_q+6'd1] <= ops_q[1][9:0];
                  br_n_q <= br_n_q + 2;
                  lp_m_q[lp_n_q] <= ops_q[0][9:0];
                  lp_c_q[lp_n_q] <= ops_q[1][9:0];
                  lp_n_q <= lp_n_q + 1;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              247: begin
                if (br_n_q >= 6'(BRN)) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  br_at_q[br_n_q] <= at_q;
                  br_tg_q[br_n_q] <= ops_q[0][9:0];
                  br_n_q <= br_n_q + 1;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              248: begin
                if (!id_ok0) begin
                  fl_code_q <= APU_SH_FAULT_BOUND; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  dw_bk_q <= 1'b1; dw_bk_id_q <= ops_q[0][9:0];
                  dw_bk_w_q <= {16'h0, 1'b1, at_q[14:0]};
                  // reaching a loop merge label closes the innermost
                  // open loop (commit-time nesting depth tracking)
                  if (lp_n_q != 0 &&
                      lp_m_q[lp_n_q-4'd1] == ops_q[0][9:0])
                    lp_n_q <= lp_n_q - 4'd1;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              249: begin
                if (br_n_q >= 6'(BRN)) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (!id_ok0) begin
                  fl_code_q <= APU_SH_FAULT_BOUND; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  br_at_q[br_n_q] <= at_q;
                  br_tg_q[br_n_q] <= ops_q[0][9:0];
                  br_n_q <= br_n_q + 1;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              250: begin
                // OpBranchConditional {cond, T, F}: merge-free allowed
                // only when the previous instruction was a merge op or
                // a target is the innermost loop merge/continue (the
                // continue path of a structured loop).
                if (!mp_q && !tg_is_lc(ops_q[1][9:0]) &&
                    !tg_is_lc(ops_q[2][9:0])) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else if (br_n_q + 6'd2 > 6'(BRN)) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  br_at_q[br_n_q] <= at_q;
                  br_tg_q[br_n_q] <= ops_q[1][9:0];
                  br_at_q[br_n_q+6'd1] <= at_q;
                  br_tg_q[br_n_q+6'd1] <= ops_q[2][9:0];
                  br_n_q <= br_n_q + 2;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              251: begin
                // OpSwitch {sel, default, (lit,label)*}
                if (!sw_merge_free()) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else if (wc_q < 3 ||
                    br_n_q + 6'(((wc_q - 3) >> 1) + 1) > 6'(BRN)) begin
                  fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  br_at_q[br_n_q] <= at_q;
                  br_tg_q[br_n_q] <= ops_q[1][9:0];
                  for (int k = 0; k < 15; k++)
                    if (k < (wc_q - 3) >> 1) begin
                      br_at_q[br_n_q + 6'(k) + 6'd1] <= at_q;
                      br_tg_q[br_n_q + 6'(k) + 6'd1] <=
                        ops_q[3+2*k][9:0];
                    end
                  br_n_q <= br_n_q + 6'(((wc_q - 3) >> 1) + 1);
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              52: begin
                fl_code_q <= APU_SH_FAULT_SPEC; fl_opc_q <= opc_q;
                fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
              end
              54: begin
                if (in_func_q) begin
                  fl_code_q <= APU_SH_FAULT_WORDS; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  in_func_q <= 1'b1; entry_off_q <= at_q;
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              56: begin
                in_func_q <= 1'b0;
                at_q <= at_q + wc_q; st_q <= S_IW;
              end
              59: begin
                if (wc_q > 4) begin
                  fl_code_q <= APU_SH_FAULT_VAR; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else if (!is_sc_ok(ops_q[2][3:0]) ||
                             ops_q[2][3:0] == APU_SH_SC_UNIFORMCONST) begin
                  fl_code_q <= APU_SH_FAULT_STORAGE;
                  fl_opc_q <= opc_q; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (n_regs_q >= 16'(ShaderRegs) ||
                             n_init_q >= 16'(ShaderInit)) begin
                  fl_code_q <= APU_SH_FAULT_REGS; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else if (!id_ok0 || !id_ok1) begin
                  fl_code_q <= APU_SH_FAULT_BOUND; fl_word_q <= at_q;
                  fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  ph_q <= '0; st_q <= S_VRB;
                end
              end
              default: begin
                if (is_type_op(opc_q)) begin
                  if (!id_ok0) begin
                    fl_code_q <= APU_SH_FAULT_BOUND;
                    fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                  end else begin
                    ph_q <= '0; st_q <= S_TYC;
                  end
                end else if (is_const_op(opc_q)) begin
                  if (!id_ok1) begin
                    fl_code_q <= APU_SH_FAULT_BOUND;
                    fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                  end else begin
                    ph_q <= '0; st_q <= S_CON;
                  end
                end else if (has_result(opc_q)) begin
                  if (!id_ok1) begin
                    fl_code_q <= APU_SH_FAULT_BOUND;
                    fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                  end else begin
                    // the result type row decides how many regmap slots
                    // the value reserves (matrices = one per column)
                    ph_q <= '0; st_q <= S_RES;
                  end
                end else begin
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
            endcase
          end
          // ---- OpDecorate RMW -----------------------------------------
          S_DRC: begin
            if (ph_q == 0) ph_q <= 1;
            else begin
              at_q <= at_q + wc_q; st_q <= S_IW;
            end
          end
          // ---- OpMemberDecorate window append -------------------------
          S_MDC: begin
            at_q <= at_q + wc_q; st_q <= S_IW;
          end
          // ---- type ops ----------------------------------------------
          S_TYC: begin
            unique case (opc_q)
              19,20,21,22: begin
                if (ph_q == 0) begin
                  if ((opc_q == 21 || opc_q == 22) && ops_q[1] != 32) begin
                    fl_code_q <= APU_SH_FAULT_TYPE; fl_opc_q <= opc_q;
                    fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                  end else ph_q <= 1;
                end else begin
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              23,24: begin
                unique case (ph_q)
                  0: begin
                    if (ops_q[1] >= 32'(ShaderIds)) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else if (ops_q[2] == 0 || ops_q[2] > 4) begin
                      fl_code_q <= APU_SH_FAULT_TYPE;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 1;
                  end
                  1: begin
                    if (ty_kind == APU_SH_TK_NONE) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 2;
                  end
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              28: begin
                unique case (ph_q)
                  0: begin
                    if (ops_q[1] >= 32'(ShaderIds) ||
                        ops_q[2] >= 32'(ShaderIds)) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 1;
                  end
                  1: begin
                    if (ty_kind == APU_SH_TK_NONE) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else begin
                      esize_q <= ty_size; ph_q <= 2;
                    end
                  end
                  2: ph_q <= 3;
                  3: begin
                    // length operand must be a registered constant
                    if (rm_rdata[31:30] != 2'b01) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 4;
                  end
                  4: begin
                    esize_q <= 16'(32'(esize_q) * co_rdata[31:0]);
                    sz_q <= co_rdata[15:0];
                    ph_q <= 5;
                  end
                  5: begin
                    stride_q <= de_rdata[63:32]; ph_q <= 6;
                  end
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              29: begin
                unique case (ph_q)
                  0: begin
                    if (ops_q[1] >= 32'(ShaderIds)) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 1;
                  end
                  1: begin
                    if (ty_kind == APU_SH_TK_NONE) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 2;
                  end
                  2: ph_q <= 3;
                  3: begin
                    stride_q <= de_rdata[63:32]; ph_q <= 4;
                  end
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              30: begin
                if (ph_q[0] && (ph_q >> 1) < 6'(wc_q - 2)) begin
                  if (ty_kind == APU_SH_TK_NONE ||
                      ops_q[1 + (ph_q >> 1)] >= 32'(ShaderIds)) begin
                    fl_code_q <= APU_SH_FAULT_FWDREF;
                    fl_opc_q <= opc_q; fl_word_q <= at_q;
                    fail_q <= 1'b1; st_q <= S_DONE;
                  end else if (n_memb_q + (ph_q >> 1) >=
                               16'(ShaderMembers)) begin
                    fl_code_q <= APU_SH_FAULT_WORDS;
                    fl_opc_q <= opc_q; fl_word_q <= at_q;
                    fail_q <= 1'b1; st_q <= S_DONE;
                  end else begin
                    if (mdv_off + ty_size > sz_q)
                      sz_q <= mdv_off + ty_size;
                    ph_q <= ph_q + 1;
                  end
                end else if (ph_q == 6'(2 * (wc_q - 2)) + 1) begin
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end else if (ph_q == 6'(2 * (wc_q - 2))) begin
                  n_memb_q <= n_memb_q + (wc_q - 2);
                  ph_q <= ph_q + 1;
                end else begin
                  // ph0: start the struct-size max-accumulation clean —
                  // sz_q may still hold a preceding OpTypeArray length.
                  if (ph_q == 0) sz_q <= '0;
                  ph_q <= ph_q + 1;
                end
              end
              32: begin
                unique case (ph_q)
                  0: begin
                    if (!is_sc_ok(ops_q[1][3:0])) begin
                      fl_code_q <= APU_SH_FAULT_STORAGE;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else if (ops_q[2] >= 32'(ShaderIds)) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 1;
                  end
                  1: begin
                    if (ty_kind == APU_SH_TK_NONE) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 2;
                  end
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              33: begin
                unique case (ph_q)
                  0: begin
                    if (wc_q != 3 || ops_q[1] >= 32'(ShaderIds)) begin
                      fl_code_q <= APU_SH_FAULT_TYPE;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 1;
                  end
                  1: begin
                    if (ty_kind != APU_SH_TK_VOID) begin
                      fl_code_q <= APU_SH_FAULT_TYPE;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 2;
                  end
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              default: begin
                at_q <= at_q + wc_q; st_q <= S_IW;
              end
            endcase
          end
          // ---- constant ops ------------------------------------------
          S_CON: begin
            unique case (opc_q)
              41,42,48,49: begin
                unique case (ph_q)
                  0: begin
                    crow_q <= '0;
                    crow_q[0] <= (opc_q == 41 || opc_q == 48);
                    cn_q <= 1; ph_q <= 1;
                  end
                  1: ph_q <= 2;
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              43,50: begin
                unique case (ph_q)
                  0: begin
                    if (wc_q - 3 > 16) begin
                      fl_code_q <= APU_SH_FAULT_CONST;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else begin
                      crow_q <= '0;
                      for (t = 0; t < 16; t++)
                        if (t < 5'(wc_q - 3))
                          crow_q[32*t +: 32] <= ops_q[2 + t];
                      cn_q <= 5'(wc_q - 3);
                      ph_q <= 1;
                    end
                  end
                  1: ph_q <= 2;
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              46: begin
                unique case (ph_q)
                  0: begin
                    if (ops_q[0] >= 32'(ShaderIds)) begin
                      fl_code_q <= APU_SH_FAULT_FWDREF;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else ph_q <= 1;
                  end
                  1: begin
                    cn_q <= ty_size == 0 ? 5'd1 :
                            5'((32'(ty_size) + 3) >> 2);
                    crow_q <= '0;
                    ph_q <= 2;
                  end
                  2: ph_q <= 3;
                  default: begin
                    at_q <= at_q + wc_q; st_q <= S_IW;
                  end
                endcase
              end
              44,51: begin
                if (ph_q == 0) begin
                  crow_q <= '0; cn_q <= '0; ph_q <= ph_q + 1;
                end else if (ph_q < 6'(3 * (wc_q - 3))) begin
                  if (ph_q % 3 == 0) begin
                    ph_q <= ph_q + 1;
                  end else if (ph_q % 3 == 1) begin
                    if (rm_rdata[31:30] != 2'b01) begin
                      fl_code_q <= APU_SH_FAULT_CONST;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else begin
                      cn_i_q <= rm_rdata[29:26] == 0 ? 5'd1
                                : {1'b0, rm_rdata[29:26]};
                      ph_q <= ph_q + 1;
                    end
                  end else begin
                    if (cn_q + cn_i_q > 16) begin
                      fl_code_q <= APU_SH_FAULT_CONST;
                      fl_opc_q <= opc_q; fl_word_q <= at_q;
                      fail_q <= 1'b1; st_q <= S_DONE;
                    end else begin
                      for (t = 0; t < 16; t++)
                        if (t >= 5'(cn_q) && t < 5'(cn_q) + cn_i_q)
                          crow_q[32*t +: 32] <=
                            co_rdata[32*(t - cn_q) +: 32];
                      cn_q <= cn_q + cn_i_q;
                      ph_q <= ph_q + 1;
                    end
                  end
                end else if (ph_q == 6'(3 * (wc_q - 3))) begin
                  ph_q <= ph_q + 1;
                end else begin
                  at_q <= at_q + wc_q; st_q <= S_IW;
                end
              end
              default: begin
                at_q <= at_q + wc_q; st_q <= S_IW;
              end
            endcase
          end
          // ---- variable ----------------------------------------------
          S_VRB: begin
            unique case (ph_q)
              0: ph_q <= 1;
              1: begin
                if (ty_kind != APU_SH_TK_PTR) begin
                  fl_code_q <= APU_SH_FAULT_TYPE; fl_opc_q <= opc_q;
                  fl_word_q <= at_q; fail_q <= 1'b1; st_q <= S_DONE;
                end else begin
                  elem_q <= ty_elem; ph_q <= 2;
                end
              end
              2: begin
                unique case (ops_q[2][3:0])
                  APU_SH_SC_WORKGROUP: begin
                    voff_q <= slab_q;
                    slab_q <= slab_q +
                              16'((32'(ty_size) + 15) & 32'hFFFF_FFF0);
                  end
                  APU_SH_SC_FUNCTION, APU_SH_SC_PRIVATE: begin
                    voff_q <= scratch_q;
                    scratch_q <= scratch_q +
                                 16'((32'(ty_size) + 15) &
                                     32'hFFFF_FFF0);
                  end
                  default: voff_q <= '0;
                endcase
                ph_q <= 3;
              end
              default: begin
                n_regs_q <= n_regs_q + 1;
                n_init_q <= n_init_q + 1;
                at_q <= at_q + wc_q; st_q <= S_IW;
              end
            endcase
          end
          // ---- result-id register allocation --------------------------
          // one extra state so the result type row is in hand: matrix
          // results reserve one regmap slot per column.
          S_RES: begin
            if (ph_q == 0) begin
              ph_q <= 1;
            end else if (n_regs_q + ((ty_kind == APU_SH_TK_MAT) ?
                            16'(ty_cols) : 16'd1) > 16'(ShaderRegs)) begin
              fl_code_q <= APU_SH_FAULT_REGS; fl_word_q <= at_q;
              fail_q <= 1'b1; st_q <= S_DONE;
            end else begin
              dw_rm_q <= 1'b1; dw_rm_id_q <= ops_q[1][9:0];
              dw_rm_w_q <= {2'b00, 4'h0, ops_q[0][9:0], n_regs_q};
              n_regs_q <= n_regs_q + ((ty_kind == APU_SH_TK_MAT) ?
                                      16'(ty_cols) : 16'd1);
              if (opc_q == 245) begin
                dw_ph_q <= 1'b1; dw_ph_id_q <= ops_q[1][9:0];
                dw_ph_w_q <= phi_pack();
              end
              at_q <= at_q + wc_q; st_q <= S_IW;
            end
          end
          // ---- queued branch-target existence check ------------------
          // (targets may be backward edges to a loop continue block, so
          // only the label-existence bit is verified)
          S_BRC: begin
            if (ph_q != 0) begin
              if (!bk_rdata[15]) begin
                fl_code_q <= APU_SH_FAULT_BRANCH; fl_opc_q <= 249;
                fl_word_q <= br_at_q[ph_q - 1];
                fail_q <= 1'b1; st_q <= S_DONE;
              end
            end
            if (st_q != S_DONE) begin
              if (ph_q == 6'(br_n_q)) st_q <= S_ENT;
              else ph_q <= ph_q + 1;
            end
          end
          S_ENT: st_q <= S_DONE;
          S_DONE: begin
            busy_q <= 1'b0;
            done_o <= 1'b1;
            if (!fail_q) live_q[slot_q] <= 1'b1;
            done_pl_o.ok <= !fail_q;
            done_pl_o.fault.code <= fl_code_q;
            done_pl_o.fault.opcode <= fl_opc_q;
            done_pl_o.fault.word <= fl_word_q;
            done_pl_o.entry.entry_off <= entry_off_q;
            done_pl_o.entry.lx <= lx_q;
            done_pl_o.entry.ly <= ly_q;
            done_pl_o.entry.lz <= lz_q;
            done_pl_o.entry.scratch <= scratch_q;
            done_pl_o.entry.slab <= slab_q;
            done_pl_o.n_regs <= n_regs_q;
            done_pl_o.n_vars <= n_init_q;
            st_q <= S_IDLE;
          end
          default: st_q <= S_IDLE;
        endcase
      end
    end

    logic unused_tm;
    assign unused_tm = testmode_i | (|live_q) | (|w0_q) |
                       (|mb_rdata) | (|in_rdata) | (|va_rdata) |
                       (|ty_storage);
  end
endmodule

// Fixture wrapper for the *_SYNTH=1 screens: identical port list so
// read_slang can sweep -GEnable.
module g6lc_apu_shmod_fixture
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ShaderInit    = 128
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  input  logic         wr_en_i,
  input  logic [2:0]   wr_slot_i,
  input  logic [15:0]  wr_addr_i,
  input  logic [31:0]  wr_data_i,
  input  logic         commit_i,
  input  apu_sh_commit_t commit_pl_i,
  output logic         busy_o,
  output logic         done_o,
  output apu_sh_cpl_t  done_pl_o,
  input  logic         retire_i,
  input  logic [2:0]   retire_slot_i,
  input  logic [2:0]   rd_slot_i,
  input  logic [15:0]  prog_addr_i,
  output logic [31:0]  prog_data_o,
  input  logic [9:0]   type_id_i,
  output logic [95:0]  type_data_o,
  input  logic [9:0]   const_id_i,
  output logic [511:0] const_data_o,
  input  logic [9:0]   memb_id_i,
  output logic [63:0]  memb_data_o,
  input  logic [9:0]   decor_id_i,
  output logic [63:0]  decor_data_o,
  input  logic [9:0]   var_id_i,
  output logic [63:0]  var_data_o,
  input  logic [9:0]   rm_id_i,
  output logic [31:0]  rm_data_o,
  input  logic [9:0]   init_id_i,
  output logic [63:0]  init_data_o,
  input  logic [9:0]   blk_id_i,
  output logic [31:0]  blk_data_o,
  input  logic [9:0]   phi_id_i,
  output logic [159:0] phi_data_o,
  output logic [127:0] entry_data_o
);
  g6lc_apu_shmod #(.Enable(Enable), .ShaderSlots(ShaderSlots),
                   .ShaderIds(ShaderIds), .ShaderRegs(ShaderRegs),
                   .ShaderWords(ShaderWords),
                   .ShaderMembers(ShaderMembers),
                   .ShaderInit(ShaderInit)) i_dut (.*);
endmodule
