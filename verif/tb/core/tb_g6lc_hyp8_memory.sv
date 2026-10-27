// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 memory/PRF ownership leaf — "preserve accepted operation
// ownership under staging" (the caller-worklist memory batch).
//
// A. g6lc_prf read_enable: a launched read keeps its captured address
//    while the owning lane stalls — holding read_enable low across
//    address changes must leave rdata answering the staged operation.
//    Checked at 64- and 32-bit widths (the 32-bit instance also proves
//    the DATA_WIDTH-parameterized write select drops no fixed hi/lo
//    slice). Highest-port same-address write wins; phys 0 stays zero.
// B. stb_insert: the staged S1 record reserves its slot — consecutive
//    stores capture distinct slots with both payloads surviving, and the
//    younger arrival's age row counts the pending owner (installing at
//    the same edge) as older. A cancelled or flushed pending record
//    never installs; no accepted store sees an empty free mask.
// C. stb_fwd: F1 snapshots the represented data with the match — a slot
//    freed and reused with different data before F3 must still answer
//    the ORIGINAL bytes. Partial-byte and cbo.zero sources; the pending
//    spec->commit transfer is a committed source ahead of the queued
//    commit entries but behind speculative/live sources.
// D/E. store_buffer commit-ready ownership + drain grant/release timing.
// F. load_unit: a granted misaligned load completes once with
//    LD_ADDR_MISALIGNED on its killed tag's own dummy rvalid — the
//    ex_pub rresp/last_id term (r30, scalar-r12 witness).
//
// The queue model beside the DUTs replays store_buffer's wrapper
// semantics only (removal set -> live_after -> S2 install -> commit pop
// -> pend push); it is not a second implementation of the DUTs.
// Stimulus is driven on the clock-low phase and outputs sampled after
// the posedge (one sample point per tick, the leaf-bench discipline).
module tb_g6lc_hyp8_memory;
  import g6lc_core_pkg::*;

  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.IS_XLEN64 = 1;
    c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4;
    c.OoOEn = 1; c.SpeculativeSb = 1; c.SuperscalarEn = 1; c.NrHarts = 1;
    c.MaxOutstandingStores = 4; c.DeepSpecEn = 0; c.RVZiCboz = 1;
    c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44; c.DCACHE_LINE_WIDTH = 128;
    c.DCACHE_USER_WIDTH = 1; c.DcacheIdWidth = 1;
    // F: load_unit DUT — GPLEN for the exception record, TvalEn matching the
    // scalar config's tval contract, two load-buffer slots so the kill-cycle
    // publish can be checked against the tag's own rid.
    c.GPLEN = 64; c.TvalEn = 1; c.NrLoadBufEntries = 2;
    c.PPNW = 44;  // XLEN64 physical-tag width (build_config); cfg_empty
                  // leaves it 0 and dtlb_ppn_i degenerates to [-1:0]
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  // The deep-publish profile selects Hyp8Deep (LoadPubStages==2): the
  // same bench runs both profiles; LU_PUB_LAT is the load-WB retime the
  // data-arm publish checks must absorb.
`ifdef G6LC_HYP8_DEEP
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t TB_HYP = g6lc_hyp_pkg::Hyp8Deep;
`else
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t TB_HYP = g6lc_hyp_pkg::Hyp8;
`endif
  localparam type cbo_t = logic [7:0];
  localparam cbo_t CBO_NONE_V = cbo_t'(g6lc_core_pkg::CBO_NONE);
  localparam cbo_t CBO_ZERO_V = cbo_t'(g6lc_core_pkg::CBO_ZERO);
  localparam int DS = 4, DC = 4, TID = C.TRANS_ID_BITS;

  typedef struct packed {
    logic [C.PLEN-1:0]       address;
    logic [C.XLEN-1:0]       data;
    logic [(C.XLEN/8)-1:0]   be;
    logic [1:0]              data_size;
    cbo_t                    cbo_op;
    logic [TID-1:0]          trans_id;
    logic                    hart;
    logic                    valid;
    logic                    wait_rvalid;
    logic                    fwd_keep;
  } entry_t;

  logic clk = 0, rst_n = 0, flush = 0;
  logic [15:0] cancel = '0;
  logic [TID-1:0] oldest = '0;
  int checked = 0;
  int cycles = 0;

  // ---------------------- PRF instances ----------------------
  logic [1:0][5:0]  prf_ra;  logic [1:0]        prf_ren;
  logic [1:0][63:0] prf_rd;
  logic [1:0][5:0]  prf_wa;  logic [1:0][63:0]  prf_wd;  logic [1:0] prf_we;
  logic [2:0][5:0]  fprf_ra; logic [2:0]        fprf_ren;
  logic [2:0][31:0] fprf_rd;
  logic [1:0][5:0]  fprf_wa; logic [1:0][31:0]  fprf_wd; logic [1:0] fprf_we;

  g6lc_prf #(
      .DATA_WIDTH(64), .PRF_ENTRIES(48), .NR_READ(2), .NR_WRITE(2),
      .PRF_W(6), .ZERO_REG_ZERO(1'b1)
  ) i_prf64 (
      .clk_i(clk), .rst_ni(rst_n),
      .raddr_i(prf_ra), .read_enable_i(prf_ren), .rdata_o(prf_rd),
      .waddr_i(prf_wa), .wdata_i(prf_wd), .we_i(prf_we));

  g6lc_prf #(
      .DATA_WIDTH(32), .PRF_ENTRIES(48), .NR_READ(3), .NR_WRITE(2),
      .PRF_W(6), .ZERO_REG_ZERO(1'b0)
  ) i_prf32 (
      .clk_i(clk), .rst_ni(rst_n),
      .raddr_i(fprf_ra), .read_enable_i(fprf_ren), .rdata_o(fprf_rd),
      .waddr_i(fprf_wa), .wdata_i(fprf_wd), .we_i(fprf_we));

  // --------------- speculative queue / commit model ---------------
  entry_t [DS-1:0] spec_q;
  logic [DS-1:0]   spec_v;
  logic [DS-1:0][DS-1:0] older_q;
  entry_t [DC-1:0] cmt_q;
  logic [DC-1:0]   cmt_v;
  logic [1:0]      cmt_rd = '0, cmt_wr = '0;
  // pend record (stb_commit's push): commit at T -> held during T+1 ->
  // lands in the commit queue at the T+1 edge
  logic   pend_v_q;
  entry_t pend_entry_q;

  // store arrival / commit / forward-request drivers
  logic                st_valid, st_valid_wof, commit;
  logic [C.PLEN-1:0]   st_pa;
  logic [C.XLEN-1:0]   st_data;
  logic [7:0]          st_be;
  logic [1:0]          st_size;
  cbo_t                st_cbo;
  logic [TID-1:0]      st_tid;
  logic                req_valid;
  logic [C.PLEN-1:0]   req_pa;
  logic [TID-1:0]      req_tid;
  logic [1:0]          req_tag_in;

  // stb_insert outputs
  logic                ins_s1v, s2_v;
  logic [DS-1:0]       s2_oh, s2_row, s2_col;
  entry_t              s2_entry;
  logic [DS-1:0]       live_after;
  logic [DS-1:0][TID-1:0] spec_tids;

  stb_insert #(
      .G6LCCfg(C), .DEPTH_SPEC(DS), .entry_t(entry_t), .cbo_t(cbo_t),
      .AGE_EN(1'b1)
  ) i_ins (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .cancelled_mask_i(cancel),
      .valid_i(st_valid), .paddr_i(st_pa), .data_i(st_data), .be_i(st_be),
      .data_size_i(st_size), .cbo_op_i(st_cbo), .trans_id_i(st_tid),
      .st_hart_i('0), .fwd_keep_i(1'b0),
      .spec_valid_i(spec_v), .spec_tid_i(spec_tids),
      .live_after_i(live_after), .oldest_live_tid_i(oldest),
      .s1_v_o(ins_s1v), .s2_wr_valid_o(s2_v), .s2_slot_oh_o(s2_oh),
      .s2_entry_o(s2_entry), .s2_older_row_o(s2_row),
      .s2_older_col_o(s2_col));

  // mirror of the queue valid/tid fields the DUTs see
  for (genvar i = 0; i < DS; i++) begin : g_mirror
    assign spec_v[i]    = spec_q[i].valid;
    assign spec_tids[i] = spec_q[i].trans_id;
  end

  // head select + removal model (store_buffer core_if semantics)
  logic [DS-1:0] head_oh, rem_oh;
  logic          head_valid;
  entry_t        head_entry;
  always_comb begin
    for (int i = 0; i < DS; i++) begin
      automatic logic any_older;
      any_older = 1'b0;
      for (int j = 0; j < DS; j++) any_older |= spec_v[j] && older_q[j][i];
      head_oh[i] = spec_v[i] && !any_older;
      rem_oh[i]  = spec_v[i] &&
                   (flush || cancel[spec_q[i].trans_id] ||
                    (commit && head_oh[i]));
    end
    head_valid = |head_oh;
    head_entry = '0;
    for (int i = 0; i < DS; i++)
      if (head_oh[i]) head_entry = head_entry | spec_q[i];
    live_after = spec_v & ~rem_oh;
  end

  always_ff @(posedge clk or negedge rst_n) begin : p_model
    if (!rst_n) begin
      for (int i = 0; i < DS; i++) spec_q[i] <= '0;
      older_q <= '0;
      for (int i = 0; i < DC; i++) cmt_q[i] <= '0;
      cmt_v <= '0; cmt_rd <= '0; cmt_wr <= '0;
      pend_v_q <= 1'b0; pend_entry_q <= '0;
    end else begin
      for (int i = 0; i < DS; i++) begin
        if (rem_oh[i]) begin
          spec_q[i].valid    <= 1'b0;
          spec_q[i].fwd_keep <= 1'b0;
          for (int j = 0; j < DS; j++) begin
            older_q[i][j] <= 1'b0;
            older_q[j][i] <= 1'b0;
          end
        end
        if (s2_v && s2_oh[i]) begin
          spec_q[i] <= s2_entry;
          for (int j = 0; j < DS; j++) begin
            older_q[j][i] <= s2_row[j] && live_after[j];
            older_q[i][j] <= s2_col[j] && live_after[j];
          end
        end
      end
      pend_v_q <= commit && head_valid;
      if (commit && head_valid) pend_entry_q <= head_entry;
      if (pend_v_q) begin
        cmt_q[cmt_wr] <= pend_entry_q;
        cmt_v[cmt_wr] <= 1'b1;
        cmt_wr <= cmt_wr + 1;
      end
    end
  end

  // ------------------------- stb_fwd -------------------------
  logic [1:0]          ins_v;
  logic [1:0][TID-1:0] ins_tid;
  logic [1:0][0:0]     ins_hart;
  logic [1:0][C.PLEN-1:0] ins_pa;
  logic [1:0][C.XLEN-1:0] ins_data;
  logic [1:0][7:0]     ins_be;
  cbo_t [1:0]          ins_cbo;
  logic                f3_v, f3_pos;
  logic [C.XLEN-1:0]   f3_data;
  logic [7:0]          f3_be;
  logic [1:0]          f3_tag;

  assign ins_v[0]    = st_valid_wof && !cancel[st_tid];
  assign ins_tid[0]  = st_tid;
  assign ins_hart[0] = '0;
  assign ins_pa[0]   = st_pa;
  assign ins_data[0] = st_data;
  assign ins_be[0]   = st_be;
  assign ins_cbo[0]  = st_cbo;
  assign ins_v[1]    = s2_v;
  assign ins_tid[1]  = s2_entry.trans_id;
  assign ins_hart[1] = s2_entry.hart;
  assign ins_pa[1]   = s2_entry.address;
  assign ins_data[1] = s2_entry.data;
  assign ins_be[1]   = s2_entry.be;
  assign ins_cbo[1]  = s2_entry.cbo_op;

  stb_fwd #(
      .G6LCCfg(C), .DEPTH_SPEC(DS), .DEPTH_COMMIT(DC), .CBOZ_OFF_W(6),
      .TAG_W(2), .AGE_EN(1'b1), .HART_OWN(1'b0),
      .entry_t(entry_t), .cbo_t(cbo_t)
  ) i_fwd (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .req_valid_i(req_valid), .req_pa_i(req_pa), .req_size_i(2'b11),
      .req_tid_i(req_tid), .req_hart_i('0), .req_tag_i(req_tag_in),
      .spec_entries_i(spec_q), .spec_valid_i(spec_v),
      .spec_older_i(older_q),
      .cmt_entries_i(cmt_q), .cmt_valid_i(cmt_v), .cmt_rd_ptr_i(cmt_rd),
      .cmt_pending_valid_i(pend_v_q), .cmt_pending_entry_i(pend_entry_q),
      .ins_valid_i(ins_v), .ins_tid_i(ins_tid), .ins_hart_i(ins_hart),
      .ins_pa_i(ins_pa), .ins_data_i(ins_data), .ins_be_i(ins_be),
      .ins_cbo_i(ins_cbo), .oldest_live_tid_i(oldest),
      .rsp_valid_o(f3_v), .rsp_data_o(f3_data), .rsp_be_o(f3_be),
      .rsp_possible_o(f3_pos), .rsp_tag_o(f3_tag));

  // ---------------- actual store_buffer (commit-ready ownership) ---------
  // The staged S1->S2 insertion means a store completing on valid_i is not
  // visible to stb_commit for two edges; commit_ready_o must hold the
  // commit until the committing tid is INSTALLED (h34-r4 underflow).
  localparam type dcache_req_i_t = struct packed {
    logic [C.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [C.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [C.XLEN-1:0]               data_wdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                            data_req;
    logic                            data_we;
    logic [(C.XLEN/8)-1:0]           data_be;
    logic [1:0]                      data_size;
    logic [C.DcacheIdWidth-1:0]      data_id;
    logic                            kill_req;
    logic                            tag_valid;
    cbo_t                            cbo_op;
  };
  localparam type dcache_req_o_t = struct packed {
    logic                            data_gnt;
    logic                            data_rvalid;
    logic [C.DcacheIdWidth-1:0]      data_rid;
    logic [C.XLEN-1:0]               data_rdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_ruser;
  };

  logic              sb_commit;
  logic [TID-1:0]    sb_ctid;
  dcache_req_o_t     sb_rpi;
  dcache_req_i_t     sb_rpo;
  logic              sb_cready, sb_ready_o, sb_nopend, sb_empty;
  logic              sb_pom, sb_poso, sb_fwd_v;
  // E: parked-load interlock drivers (tied off for A-D)
  logic              sb_wbe = 1'b1;
  logic [C.PLEN-1:0] ld_pa  = '0;
  logic              ld_pav = 1'b0;
  logic [11:0]       ld_po  = '0;
  logic [TID-1:0]    ld_tid = '0;
  logic [C.XLEN-1:0] sb_fwd_d;
  logic [7:0]        sb_fwd_be;
  logic [C.PLEN-1:0] sb_rvfi_pa;
  logic [75:0]       sb_rsp_dump;

  store_buffer #(
      .G6LCCfg(C), .HypCfg(TB_HYP),
      .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t),
      .cbo_t(cbo_t)
  ) i_stb (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .cancelled_mask_i(cancel), .sb_live_i('1), .stall_st_pending_i(1'b0),
      .no_st_pending_o(sb_nopend), .store_buffer_empty_o(sb_empty),
      .page_offset_i(ld_po), .load_paddr_i(ld_pa),
      .load_paddr_valid_i(ld_pav),
      .load_trans_id_i(ld_tid), .commit_trans_id_i(sb_ctid),
      .oldest_live_tid_i(oldest), .head_phys_pending_i(1'b0),
      .load_hart_i('0), .dcache_wbuffer_empty_i(sb_wbe),
      .page_offset_matches_o(sb_pom), .page_offset_spec_only_o(sb_poso),
      .st_fwd_valid_o(sb_fwd_v), .st_fwd_data_o(sb_fwd_d),
      .st_fwd_be_o(sb_fwd_be),
      .fwd_req_i('0), .fwd_rsp_o(sb_rsp_dump),
      .commit_i(sb_commit), .commit_ready_o(sb_cready), .ready_o(sb_ready_o),
      .valid_i(st_valid), .valid_without_flush_i(st_valid_wof),
      .paddr_i(st_pa), .trans_id_i(st_tid), .st_hart_i('0),
      .rvfi_mem_paddr_o(sb_rvfi_pa),
      .data_i(st_data), .be_i(st_be), .data_size_i(st_size),
      .cbo_op_i(st_cbo),
      .req_port_i(sb_rpi), .req_port_o(sb_rpo));

  always @(posedge clk)
    if (rst_n && sb_commit)
      check(i_stb.speculative_status_cnt_q != 0, "SB_EMPTY_COMMIT");

  // ---------------- load_unit: kill-cycle exception publish ------------
  // Section F DUT. The misaligned exception belongs to the tag in flight:
  // it must publish on that tag's own dummy rvalid (rresp == last_id), the
  // r30 ex_pub term — never suppressed for the kill's own response and never
  // attributed to a different slot's response during a kill.
  typedef struct packed {
    logic [C.XLEN-1:0]  cause;
    logic [C.XLEN-1:0]  tval;
    logic [C.GPLEN-1:0] tval2;
    logic [31:0]        tinst;
    logic               gva;
    logic               valid;
  } lu_exception_t;
  typedef struct packed {
    logic                  valid;
    logic [C.VLEN-1:0]     vaddr;
    logic [31:0]           tinst;
    logic                  hs_ld_st_inst;
    logic                  hlvx_inst;
    logic                  overflow;
    logic                  g_overflow;
    logic [C.XLEN-1:0]     data;
    logic [C.XLEN-1:0]     data_cmp;
    logic [C.XLEN-1:0]     data_hi;
    logic [C.XLEN-1:0]     data_cmp_hi;
    logic [(C.XLEN/8)-1:0] be;
    fu_t                   fu;
    fu_op                  operation;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
    logic                  hart;
    logic                  is_speculative_load;
    logic                  is_speculative_load_miss;
  } lu_ctrl_t;

  lu_ctrl_t       lu_ctrl = '0;
  logic           lu_vld = 1'b0;
  logic           lu_rdy_v;
  logic [TID-1:0] lu_tid_o, lu_ctid = '0;
  logic [C.XLEN-1:0] lu_res;
  lu_exception_t  lu_ex_o, lu_ex_i = '{default: '0};
  logic           lu_dtlb_hit = 1'b1;
  logic [C.PLEN-1:0] lu_paddr = '0;
  logic [43:0]    lu_ppn = '0;
  dcache_req_o_t  lu_rpi = '{default: '0};
  dcache_req_i_t  lu_rpo;
  logic [C.DcacheIdWidth-1:0] lu_rid = '0;
  // r44: publish/drain tree stimulus — verdict mask and the staged
  // forward response are driven (were '1/'0 constants).
  logic [C.NR_SB_ENTRIES-1:0] lu_lchk = '1;
  // F15: the STQ-forward head-completion drivers (page-offset match,
  // coverage valid/data/be) — constants until the collision case.
  logic               lu_pom = 1'b0;
  logic               lu_sfv = 1'b0;
  logic [C.XLEN-1:0]  lu_sfd = '0;
  logic [(C.XLEN/8)-1:0] lu_sfbe = '0;
  typedef struct packed {
    logic                                        valid;
    logic [C.XLEN-1:0]                           data;
    logic [(C.XLEN/8)-1:0]                       be;
    logic                                        forward_possible;
    logic [(C.NrLoadBufEntries > 1 ? $clog2(C.NrLoadBufEntries) : 1)-1:0] tag;
  } lu_frsp_t;
  lu_frsp_t       lu_frsp = '{default: '0};
  // write-only dump nets for unprobed outputs (sb_rsp_dump convention)
  logic           lu_d_pop, lu_d_treq, lu_d_hs, lu_d_hlvx, lu_d_pav,
                  lu_d_repl, lu_d_physv, lu_d_rpl;
  logic [TID-1:0] lu_d_ltid, lu_d_rid1, lu_d_pid, lu_d_rid2;
  logic [C.VLEN-1:0] lu_d_va;
  logic [C.PLEN-1:0] lu_d_lpa, lu_d_physa;
  logic [11:0]    lu_d_po;
  logic [31:0]    lu_d_ti;
  logic [1:0]     lu_d_ps;
  logic           lu_d_lh, lu_d_ph;

  load_unit #(
      .G6LCCfg(C), .HypCfg(TB_HYP),
      .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t),
      .exception_t(lu_exception_t), .lsu_ctrl_t(lu_ctrl_t)
  ) i_lu (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .cancelled_mask_i(cancel),
      .valid_i(lu_vld), .lsu_ctrl_i(lu_ctrl), .pop_ld_o(lu_d_pop),
      .valid_o(lu_rdy_v), .trans_id_o(lu_tid_o), .result_o(lu_res),
      .ex_o(lu_ex_o), .mbe_i(1'b0),
      .translation_req_o(lu_d_treq), .vaddr_o(lu_d_va),
      .tinst_o(lu_d_ti), .hs_ld_st_inst_o(lu_d_hs),
      .hlvx_inst_o(lu_d_hlvx), .paddr_i(lu_paddr), .ex_i(lu_ex_i),
      .ex_ptw_i(1'b0), .dtlb_hit_i(lu_dtlb_hit), .dtlb_ppn_i(lu_ppn),
      .page_offset_o(lu_d_po), .load_paddr_o(lu_d_lpa),
      .load_paddr_valid_o(lu_d_pav), .load_trans_id_o(lu_d_ltid),
      .load_hart_o(lu_d_lh),
      .page_offset_matches_i(lu_pom), .page_offset_spec_only_i(1'b0),
      .lu_replay_o(lu_d_repl), .lu_replay_id_o(lu_d_rid1),
      .store_buffer_empty_i(1'b1), .no_st_pending_i(1'b1),
      .st_fwd_valid_i(lu_sfv), .st_fwd_data_i(lu_sfd),
      .st_fwd_be_i(lu_sfbe),
      .commit_tran_id_i(lu_ctid),
      .req_port_i(lu_rpi), .req_port_o(lu_rpo),
      .dcache_wbuffer_not_ni_i(1'b1), .dcache_wbuffer_empty_i(1'b1),
      .phys_valid_o(lu_d_physv), .phys_addr_o(lu_d_physa),
      .phys_id_o(lu_d_pid), .phys_hart_o(lu_d_ph),
      .phys_size_o(lu_d_ps), .ld_checked_i(lu_lchk),
      .fwd_req_o(), .fwd_rsp_i(lu_frsp),
      .replay_o(lu_d_rpl), .replay_tid_o(lu_d_rid2));

  // ------------------------- stimulus -------------------------
  task automatic tick;
    // no accepted store may ever see an empty free mask — sampled while
    // the drive-phase inputs still hold, i.e. the values the capture at
    // the upcoming posedge actually sees (the DUT's own SVA guards the
    // same fact at the edge; the leaf makes it an explicit checked fact)
    if (i_ins.ins_take) check(|i_ins.free_slots, "STB_NO_FULL_TAKE");
    clk = 1; #2; clk = 0; #2;
    cycles++;
    if (cycles > 400) $fatal(1, "tb_g6lc_hyp8_memory watchdog");
  endtask

  task automatic clear_inputs;
    flush = 0; commit = 0; st_valid = 0; st_valid_wof = 0; req_valid = 0;
    st_pa = '0; st_data = '0; st_be = '0; st_size = 2'b11;
    st_cbo = CBO_NONE_V; st_tid = '0; req_pa = '0; req_tid = '0;
    prf_ren = '0; prf_we = '0; fprf_ren = '0; fprf_we = '0; cancel = '0;
    sb_commit = 0; sb_ctid = '0; sb_rpi = '0;
    sb_wbe = 1'b1; ld_pav = 1'b0; ld_pa = '0; ld_po = '0; ld_tid = '0;
  endtask

  // present a store for one cycle (AGU time), driven on the low phase
  task automatic store(input int id, input logic [C.PLEN-1:0] pa,
                       input logic [C.XLEN-1:0] data,
                       input logic [7:0] be, input cbo_t cbo);
    st_valid = 1; st_valid_wof = 1; st_tid = TID'(id); st_pa = pa;
    st_data = data; st_be = be; st_cbo = cbo;
    tick(); clear_inputs(); #2;
  endtask

  // issue a forward request for one cycle; response lands two ticks later
  task automatic fwd_req(input int id, input logic [C.PLEN-1:0] pa);
    req_valid = 1; req_tid = TID'(id); req_pa = pa;
    tick(); req_valid = 0; #2;
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) $fatal(1, "%s", tag);
    checked++;
  endtask

  // model helpers for the free/reuse probe (bench-owned queue state)
  task automatic slot_remove(input int i);
    spec_q[i].valid = 1'b0;
    for (int j = 0; j < DS; j++) begin
      older_q[i][j] = 1'b0; older_q[j][i] = 1'b0;
    end
  endtask
  task automatic slot_install(input int i, input logic [C.PLEN-1:0] pa,
                              input logic [C.XLEN-1:0] data, input int id);
    spec_q[i] = '{address: pa, data: data, be: 8'hFF, data_size: 2'b11,
                  cbo_op: CBO_NONE_V, trans_id: TID'(id), hart: 1'b0,
                  valid: 1'b1, wait_rvalid: 1'b0, fwd_keep: 1'b0};
  endtask

  // Modeled like commit_stage: commit_i asserted ONLY on a cycle where
  // commit_ready_o is high, then exactly one memory request must drain.
  task automatic sb_commit_and_drain(input logic [43:0] exptag,
                                   input logic [C.XLEN-1:0] expdata,
                                   input logic [7:0] expbe, input string tag);
    int guard = 0;
    int reqs = 0;
    while (!sb_cready) begin
      tick(); guard++;
      if (guard > 10) begin check(1'b0, {tag, "_RDY_TO"}); return; end
    end
    // commit_stage contract: the committing store must be the queue head.
    check(i_stb.spec_head_valid && i_stb.spec_head.trans_id == sb_ctid,
          {tag, "_HEAD"});
    sb_commit = 1; tick(); sb_commit = 0;
    guard = 0;
    while (reqs == 0) begin
      if (sb_rpo.data_req) begin
        reqs++;
        check(sb_rpo.address_tag == exptag, {tag, "_TAG"});
        check(sb_rpo.data_wdata == expdata, {tag, "_DATA"});
        check(sb_rpo.data_be == expbe, {tag, "_BE"});
        check(sb_rpo.data_size == 2'b11, {tag, "_SIZE"});
      end
      tick(); guard++;
      if (guard > 16) begin check(1'b0, {tag, "_DRAIN_TO"}); return; end
    end
    tick(); tick();
    check(!sb_rpo.data_req, {tag, "_ONCE"});
  endtask

  // r44: load_unit publish/drain drivers — grant one LD (the slot id is
  // left in lu_rid), pulse a D$ response into a slot, pulse a staged
  // store-forward response into a slot. All stimulus via ports.
  task automatic lu_grant(input int tid, input logic [C.VLEN-1:0] va,
                          input string tag);
    lu_ctrl = '0;
    lu_ctrl.valid = 1'b1; lu_ctrl.fu = LOAD; lu_ctrl.operation = LD;
    lu_ctrl.vaddr = va; lu_ctrl.trans_id = TID'(tid); lu_ctrl.be = '1;
    lu_ctid = TID'(tid); lu_paddr = va[C.PLEN-1:0];
    lu_vld = 1'b1; lu_rpi.data_gnt = 1'b1;
    #2;
    lu_rid = lu_rpo.data_id;
    check(lu_rpo.data_req && !lu_rpo.kill_req, {tag, "_REQ"});
    tick();
    lu_vld = 0; lu_ctrl = '0; lu_rpi.data_gnt = 0;
  endtask

  task automatic lu_rvalid(input int rid, input logic [C.XLEN-1:0] data);
    lu_rpi.data_rvalid = 1'b1;
    lu_rpi.data_rid    = C.DcacheIdWidth'(rid);
    lu_rpi.data_rdata  = data;
    tick();
    lu_rpi.data_rvalid = 1'b0; lu_rpi.data_rdata = '0; lu_rpi.data_rid = '0;
  endtask

  task automatic lu_fresp(input int tag_, input logic [C.XLEN-1:0] data,
                          input logic [(C.XLEN/8)-1:0] be, input logic poss);
    lu_frsp = '{valid: 1'b1, data: data, be: be, forward_possible: poss,
                tag: $bits(lu_frsp.tag)'(tag_)};
    tick();
    lu_frsp = '{default: '0};
  endtask

  function automatic int slot_of(input logic [DS-1:0] oh);
    for (int i = 0; i < DS; i++) if (oh[i]) return i;
    return -1;
  endfunction

  initial begin
    automatic int a_slot, b_slot;
    automatic int ridA, ridB, ridC, ridD;
    clear_inputs();
    spec_q = '{default: '0}; older_q = '0;
    cmt_q = '{default: '0}; cmt_v = '0;
    #2; tick(); rst_n = 1; #2;

    // =============== A: g6lc_prf read-ownership ===============
    // A1: write p5, launch the read, then hold ren=0 across 3 cycles of
    // changing addresses — the captured address must persist.
    prf_we[0] = 1; prf_wa[0] = 6'd5; prf_wd[0] = 64'hDEAD_BEEF_1234_5678;
    tick(); prf_we = '0;
    prf_ra[0] = 6'd5; prf_ren[0] = 1; tick();
    check(prf_rd[0] == 64'hDEAD_BEEF_1234_5678, "PRF_READ_LAUNCH");
    prf_ren[0] = 0; prf_ra[0] = 6'd7;  tick();
    check(prf_rd[0] == 64'hDEAD_BEEF_1234_5678, "PRF_HOLD_1");
    prf_ra[0] = 6'd9;  tick();
    check(prf_rd[0] == 64'hDEAD_BEEF_1234_5678, "PRF_HOLD_2");
    prf_ra[0] = 6'd11; tick();
    check(prf_rd[0] == 64'hDEAD_BEEF_1234_5678, "PRF_HOLD_3");
    // A2: same-address writes on both ports — the highest port wins.
    prf_we = 2'b11; prf_wa[0] = 6'd9; prf_wd[0] = 64'h1111_0000_0000_0001;
    prf_wa[1] = 6'd9; prf_wd[1] = 64'h2222_0000_0000_0002; tick(); prf_we = '0;
    prf_ra[0] = 6'd9; prf_ren[0] = 1; tick();
    check(prf_rd[0] == 64'h2222_0000_0000_0002, "PRF_HIGH_PORT_WINS");
    // A3: phys 0 stays zero even when written.
    prf_we[0] = 1; prf_wa[0] = '0; prf_wd[0] = 64'hFFFF_FFFF_FFFF_FFFF;
    tick(); prf_we = '0;
    prf_ra[0] = '0; prf_ren[0] = 1; tick();
    check(prf_rd[0] == '0, "PRF_X0_STAYS_ZERO");
    prf_ren = '0;

    // A4: 32-bit bank — write, launch, hold across 3 address changes.
    fprf_we[0] = 1; fprf_wa[0] = 6'd12; fprf_wd[0] = 32'h89AB_CDEF;
    tick(); fprf_we = '0;
    fprf_ra[0] = 6'd12; fprf_ren[0] = 1; tick();
    check(fprf_rd[0] == 32'h89AB_CDEF, "FPRF32_READ_LAUNCH");
    fprf_ren[0] = 0; fprf_ra[0] = 6'd1; tick();
    check(fprf_rd[0] == 32'h89AB_CDEF, "FPRF32_HOLD_1");
    fprf_ra[0] = 6'd2; tick();
    check(fprf_rd[0] == 32'h89AB_CDEF, "FPRF32_HOLD_2");
    fprf_ra[0] = 6'd3; tick();
    check(fprf_rd[0] == 32'h89AB_CDEF, "FPRF32_HOLD_3");
    fprf_ren = '0;

    // =============== B: stb_insert reservation ownership ===============
    // B1: A and B arrive on consecutive cycles — B must not take A's
    // staged slot, and B's age row must count the still-pending A older.
    store(2, 56'h8000_1000, 64'hAAAA_0000_0000_0002, 8'hFF, CBO_NONE_V);
    a_slot = slot_of(s2_oh);
    store(3, 56'h8000_2000, 64'hBBBB_0000_0000_0003, 8'hFF, CBO_NONE_V);
    b_slot = slot_of(s2_oh);
    tick();
    check(a_slot >= 0 && b_slot >= 0 && a_slot != b_slot, "STB_DISTINCT_SLOTS");
    check(spec_q[a_slot].valid && spec_q[a_slot].data == 64'hAAAA_0000_0000_0002,
          "STB_PAYLOAD_A");
    check(spec_q[b_slot].valid && spec_q[b_slot].data == 64'hBBBB_0000_0000_0003,
          "STB_PAYLOAD_B");
    check(older_q[a_slot][b_slot] && !older_q[b_slot][a_slot],
          "STB_PENDING_SEEN_OLDER");
    // B2: cancelled pending record never installs.
    st_valid = 1; st_valid_wof = 1; st_tid = 4'd4; st_pa = 56'h8000_4000;
    st_data = 64'hCCCC_0000_0000_0004; st_be = 8'hFF; tick(); st_valid = 0; st_valid_wof = 0;
    cancel = 16'h0010; tick(); cancel = '0;
    check(!spec_q[0].valid || spec_q[0].trans_id != 4'd4, "STB_CANCEL_NO_INSTALL_A");
    check(!spec_q[1].valid || spec_q[1].trans_id != 4'd4, "STB_CANCEL_NO_INSTALL_B");
    check(!spec_q[2].valid || spec_q[2].trans_id != 4'd4, "STB_CANCEL_NO_INSTALL_C");
    check(!spec_q[3].valid || spec_q[3].trans_id != 4'd4, "STB_CANCEL_NO_INSTALL_D");
    // B3: a flush while the record is staged prevents installation too.
    st_valid = 1; st_valid_wof = 0; st_tid = 4'd5; st_pa = 56'h8000_5000;
    st_data = 64'hDDDD_0000_0000_0005; st_be = 8'hFF; tick(); st_valid = 0;
    flush = 1; tick(); flush = 0;
    for (int i = 0; i < DS; i++)
      check(!spec_q[i].valid, "STB_FLUSH_NO_INSTALL");
    // B4: four consecutive arrivals claim four distinct slots; the last
    // arrival's cycle leaves free_slots empty with no further take.
    store(1, 56'h8000_6000, 64'hE000_0000_0000_0001, 8'hFF, CBO_NONE_V);
    store(2, 56'h8000_7000, 64'hE000_0000_0000_0002, 8'hFF, CBO_NONE_V);
    store(3, 56'h8000_8000, 64'hE000_0000_0000_0003, 8'hFF, CBO_NONE_V);
    st_valid = 1; st_valid_wof = 1; st_tid = 4'd4; st_pa = 56'h8000_9000;
    st_data = 64'hE000_0000_0000_0004; st_be = 8'hFF;
    tick(); st_valid = 0; st_valid_wof = 0; #2;
    check(ins_s1v, "STB_PENDING_HELD");
    tick();  // the fourth record installs
    check($countones(spec_v) == 4, "STB_FULL_COUNT");
    check(i_ins.free_slots == '0, "STB_FREE_MASK_EMPTY_AT_FULL");
    check(spec_q[0].data == 64'hE000_0000_0000_0001 &&
          spec_q[1].data == 64'hE000_0000_0000_0002 &&
          spec_q[2].data == 64'hE000_0000_0000_0003 &&
          spec_q[3].data == 64'hE000_0000_0000_0004, "STB_FULL_PAYLOADS");
    // drain the queue for the forward scenarios
    flush = 1; tick(); flush = 0; #2;
    check($countones(spec_v) == 0, "STB_DRAINED");

    // =============== C: stb_fwd snapshot + pending commit ===============
    // C1: F1 captures the represented data — free the matched slot and
    // reuse it with different data before F3; the ORIGINAL bytes answer.
    store(2, 56'h8000_1000, 64'hD100_0000_0000_00D1, 8'hFF, CBO_NONE_V);
    tick();  // entry installed
    a_slot = 0;
    for (int i = 0; i < DS; i++) if (spec_q[i].valid) a_slot = i;
    req_valid = 1; req_tid = 4'd6; req_pa = 56'h8000_1000;
    tick(); req_valid = 0;       // F1 captured
    slot_remove(a_slot); tick();  // slot freed mid-pipeline (F2 window)
    slot_install(a_slot, 56'h8000_1000, 64'hD200_0000_0000_00D2, 9);
    tick();                       // slot reused mid-pipeline (F3 window)
    check(f3_v, "FWD_RSP_PRESENT");
    check(f3_pos, "FWD_RSP_POSSIBLE");
    check(f3_tag == req_tag_in, "FWD_RSP_TAG");
    check(f3_data == 64'hD100_0000_0000_00D1, "FWD_ORIGINAL_SNAPSHOT");
    check(f3_be == 8'hFF, "FWD_ORIGINAL_BE");
    flush = 1; tick(); flush = 0; #2;
    slot_remove(a_slot);

    // C2: partial bytes — a half-word store forwards exactly its bytes.
    store(2, 56'h8000_1000, 64'hAABB_CCDD_1122_3344, 8'h0F, CBO_NONE_V);
    tick();
    req_valid = 1; req_tid = 4'd6; req_pa = 56'h8000_1000;
    tick(); req_valid = 0; tick(); tick();
    check(f3_v && f3_be == 8'h0F, "FWD_PARTIAL_BE");
    check(f3_data[31:0] == 32'h1122_3344 && f3_data[63:32] == '0,
          "FWD_PARTIAL_DATA");
    flush = 1; tick(); flush = 0; #2;

    // C3: cbo.zero source — every covered byte forwards 0.
    store(2, 56'h8000_2000, 64'h0, 8'hFF, CBO_ZERO_V);
    tick();
    req_valid = 1; req_tid = 4'd6; req_pa = 56'h8000_2010;
    tick(); req_valid = 0; tick(); tick();
    check(f3_v && f3_be == 8'hFF && f3_data == '0, "FWD_CBOZ_ZERO");
    flush = 1; tick(); flush = 0; #2;

    // C4: pending committed push outranks the queued committed entries —
    // commit the older W-store, then a W-store with a different payload:
    // during its pend window the request must take the pend payload.
    store(2, 56'h8000_3000, 64'hC000_0000_0000_00C0, 8'hFF, CBO_NONE_V);
    tick();
    commit = 1; tick(); commit = 0;
    tick(); tick();  // pend pushed into commit queue
    check($countones(cmt_v) == 1, "CMT_QUEUE_SEEDED");
    store(3, 56'h8000_3000, 64'hC000_0000_0000_00D9, 8'hFF, CBO_NONE_V);
    tick();
    commit = 1; tick(); commit = 0;
    // pend window is THIS cycle: the request must see the push record
    req_valid = 1; req_tid = 4'd6; req_pa = 56'h8000_3000;
    check(pend_v_q, "CMT_PEND_WINDOW");
    tick(); req_valid = 0; tick(); tick();
    check(f3_v && f3_data == 64'hC000_0000_0000_00D9, "FWD_PEND_BEATS_QUEUE");
    check(f3_be == 8'hFF, "FWD_PEND_BE");
    flush = 1; tick(); flush = 0; #2;

    // C5: a visible speculative source still outranks the pending push.
    store(2, 56'h8000_4000, 64'hD000_0000_0000_00D9, 8'hFF, CBO_NONE_V);
    store(3, 56'h8000_4000, 64'hD000_0000_0000_00A5, 8'hFF, CBO_NONE_V);
    tick();
    commit = 1; tick(); commit = 0;
    req_valid = 1; req_tid = 4'd6; req_pa = 56'h8000_4000;
    check(pend_v_q, "CMT_PEND_WINDOW_2");
    tick(); req_valid = 0; tick(); tick();
    check(f3_v && f3_data == 64'hD000_0000_0000_00A5, "FWD_SPEC_BEATS_PEND");

    // =============== D: commit-ready ownership gate =====================
    // The staged S1->S2 insertion means a store completing on valid_i is
    // not committable until its tid is INSTALLED in the speculative queue
    // (the h34-r4 speculative_buffer_underflow defect). commit_i is only
    // asserted on a commit_ready_o cycle, like commit_stage.
    sb_rpi = '0;
    sb_rpi.data_gnt = 1'b1;               // D$ accepts every request
    flush = 1; tick(); flush = 0; #2;     // clean the real speculative queue

    // D1: store T=10 presented; committing tid visible from t+1 — ready is
    // held while the entry is staged (S1), releases once installed, and
    // the commit drains exactly one memory request.
    st_valid = 1; st_valid_wof = 1; st_tid = 4'd10;
    st_pa = 56'h00_8000_5000; st_data = 64'hAAAA_0000_0000_00AA;
    st_be = 8'hFF; st_cbo = CBO_NONE_V;
    tick();                                // S1 capture edge
    st_valid = 0; st_valid_wof = 0;
    sb_ctid = 4'd10;
    check(!sb_cready, "SB_RDY_HELD_S1");   // staged, not yet installed
    tick();                                // S2 writeback -> installed
    check(sb_cready, "SB_RDY_INSTALLED");
    sb_commit_and_drain(44'h80005, 64'hAAAA_0000_0000_00AA, 8'hFF, "SB_T10");

    // D2: a tid that was never inserted must never become committable
    sb_ctid = 4'd15;
    for (int k = 0; k < 4; k++) begin
      check(!sb_cready, "SB_RDY_PHANTOM");
      tick();
    end

    // D3: T1=11 and T2=12 on consecutive cycles, committed in program
    // order, each reaching memory exactly once.
    st_valid = 1; st_valid_wof = 1; st_tid = 4'd11;
    st_pa = 56'h00_8000_6000; st_data = 64'hBBBB_0000_0000_00B1;
    st_be = 8'hFF; st_cbo = CBO_NONE_V;
    tick();                                // T1 S1
    st_tid = 4'd12;
    st_pa = 56'h00_8000_7000; st_data = 64'hCCCC_0000_0000_00C1;
    tick();                                // T1 installs; T2 S1
    st_valid = 0; st_valid_wof = 0;
    sb_ctid = 4'd11;
    tick();                                // T2 installs
    sb_commit_and_drain(44'h80006, 64'hBBBB_0000_0000_00B1, 8'hFF, "SB_T11");
    sb_ctid = 4'd12;
    sb_commit_and_drain(44'h80007, 64'hCCCC_0000_0000_00C1, 8'hFF, "SB_T12");
    check(sb_empty, "SB_DRAINED");

    // =============== E: drain grant -> record release -> interlock free ==
    // The h33-r7 wedge pair: two committed stores in the same 8-byte lane
    // (0x80001090/0x80001091) draining back-to-back. Producer contract the
    // wbuffer must tolerate: on the grant edge the head pops and the NEXT
    // head's data_req rises on the immediately following cycle -- no
    // inter-request gap. Release contract: a same-page-offset load stays
    // interlocked while the wbuffer handoff is in flight (the
    // st_to_wbuf_grant sticky) and is free once dcache_wbuffer_empty_i
    // reports the handoff complete.
    sb_rpi = '0;
    sb_wbe = 1'b0;                       // the wbuffer holds the handoff
    ld_pav = 1'b1; ld_po = 12'h090;
    ld_pa  = 56'h00_8000_1090; ld_tid = 4'd15;   // younger than T13/T14
    // Section D's commits drained i_stb only; the bench model's spec_q is
    // still full. Flush clears both queues (and the DUT's sticky state).
    flush = 1; tick(); flush = 0; #2;
    st_valid = 1; st_valid_wof = 1; st_tid = 4'd13;
    st_pa = 56'h00_8000_1090; st_data = 64'hE100_0000_0000_0090;
    st_be = 8'hFF; st_cbo = CBO_NONE_V;
    tick();                                // T13 S1
    st_tid = 4'd14; st_pa = 56'h00_8000_1091;
    st_data = 64'hE200_0000_0000_0091;
    tick();                                // T13 installs; T14 S1
    st_valid = 0; st_valid_wof = 0;
    tick();                                // T14 installs
    // E1: both entries interlock the parked load BEFORE any commit grant
    check(sb_pom, "E_INTERLOCK_QUEUED");
    // commit T13 -> pend -> queue; commit T14 on the next cycle. With
    // data_gnt held high the head requests and drains the same cycle; the
    // cycle after T13's grant the next head's request must already be on
    // the port (the zero-gap re-presentation).
    sb_rpi.data_gnt = 1'b1;               // grant every drain
    sb_ctid = 4'd13;
    for (int g = 0; g < 10 && !sb_cready; g++) tick();
    check(sb_cready, "E_RDY_T13");
    sb_commit = 1; tick(); sb_commit = 0;  // T13 spec pop -> pend
    sb_ctid = 4'd14;
    sb_commit = 1; tick(); sb_commit = 0;  // T14 spec pop -> pend; T13 pushes
    check(sb_rpo.data_req, "E_REQ_T13");   // T13 head now; drains this edge
    check(sb_rpo.address_index ==
          C.DCACHE_INDEX_WIDTH'(56'h00_8000_1090), "E_REQ_T13_IDX");
    tick();                                // T13 popped; T14 pushed
    check(sb_rpo.data_req, "E_REGAP_T14"); // next head, still asserting
    check(sb_rpo.address_index ==
          C.DCACHE_INDEX_WIDTH'(56'h00_8000_1091), "E_REGAP_T14_IDX");
    tick();                                // T14 popped; queue empty
    check(!sb_rpo.data_req, "E_REQ_DONE");
    check(sb_nopend && sb_empty, "E_RECORDS_RELEASED");
    // E2: same-lane load still interlocked by the grant sticky while the
    // wbuffer handoff is in flight -- then free once it reports empty.
    check(sb_pom, "E_STICKY_HOLD");
    sb_wbe = 1'b1;
    tick();
    check(!sb_pom, "E_INTERLOCK_FREE");

    // =============== F: load_unit misaligned kill-cycle publish ===========
    // r30 (hyp8-osbi-scalar-r12, load_unit.sv misaligned_entry_excepts at
    // cycle 1,168,793): a granted misaligned load completes once on its
    // killed tag's OWN dummy rvalid, with LD_ADDR_MISALIGNED — the ex_pub
    // rresp/last_id term must include (not exclude) the kill's own response.
    lu_ctrl = '0; lu_vld = 0; lu_ex_i = '{default: '0}; lu_rpi = '{default: '0};
    lu_dtlb_hit = 1'b1; lu_ppn = 44'h8_0045; lu_paddr = '0;
    flush = 1; tick(); flush = 0; tick();  // WAIT_FLUSH -> IDLE return edge

    // F1: misaligned LD (offset 1) — grant at IDLE, then the kill cycle
    // publishes the exception on the tag's own dummy response.
    lu_ctrl.valid = 1'b1; lu_ctrl.fu = LOAD; lu_ctrl.operation = LD;
    lu_ctrl.vaddr = 64'h1; lu_ctrl.trans_id = TID'(5); lu_ctrl.be = '1;
    lu_ctid = TID'(5); lu_paddr = 56'h1;
    lu_vld = 1'b1; lu_rpi.data_gnt = 1'b1;
    #2;
    lu_rid = lu_rpo.data_id;              // the entry's own slot id
    check(lu_rpo.data_req && !lu_rpo.kill_req, "LU_MIS_REQ");
    tick();                               // grant edge -> SEND_TAG
    lu_vld = 0; lu_ctrl = '0; lu_rpi.data_gnt = 0;
    check(i_lu.state_q[2], "LU_MIS_SEND_TAG");
    // kill cycle: the registered exception and the dummy rvalid arrive
    lu_ex_i.valid = 1'b1; lu_ex_i.cause = 64'd4; lu_ex_i.tval = 64'h1;
    lu_rpi.data_rvalid = 1'b1; lu_rpi.data_rid = lu_rid;
    lu_rpi.data_rdata = 64'hDEAD_BEEF;
    #2;
    check(lu_rpo.kill_req && lu_rpo.tag_valid, "LU_MIS_KILL");
    check(lu_rdy_v && lu_ex_o.valid && lu_ex_o.cause == 64'd4 &&
          lu_ex_o.tval == 64'h1, "LU_MIS_EX_PUBLISH");
    check(lu_tid_o == TID'(5), "LU_MIS_EX_TID");
    tick();                               // publish consumed -> IDLE, freed
    lu_rpi = '{default: '0}; lu_ex_i = '{default: '0}; #2;
    check(!lu_rdy_v, "LU_MIS_ONCE");
    check(!i_lu.ldbuf_valid_q[lu_rid], "LU_MIS_FREED");

    // F2: the publish follows the killed tag's own slot — a second
    // misaligned LD must retire the same way on its own rid.
    lu_ctrl.valid = 1'b1; lu_ctrl.fu = LOAD; lu_ctrl.operation = LD;
    lu_ctrl.vaddr = 64'h5; lu_ctrl.trans_id = TID'(7); lu_ctrl.be = '1;
    lu_ctid = TID'(7); lu_paddr = 56'h5;
    lu_vld = 1'b1; lu_rpi.data_gnt = 1'b1; #2;
    lu_rid = lu_rpo.data_id;
    tick();
    lu_vld = 0; lu_ctrl = '0; lu_rpi.data_gnt = 0;
    check(i_lu.state_q[2], "LU_MIS2_SEND_TAG");
    lu_ex_i.valid = 1'b1; lu_ex_i.cause = 64'd4; lu_ex_i.tval = 64'h5;
    lu_rpi.data_rvalid = 1'b1; lu_rpi.data_rid = lu_rid; #2;
    check(lu_rpo.kill_req, "LU_MIS2_KILL");
    check(lu_rdy_v && lu_ex_o.valid && lu_ex_o.cause == 64'd4 &&
          lu_tid_o == TID'(7), "LU_MIS2_EX_PUBLISH");
    tick();
    lu_rpi = '{default: '0}; lu_ex_i = '{default: '0}; #2;
    check(!lu_rdy_v && !(|i_lu.ldbuf_valid_q), "LU_MIS2_FREED");

    // =============== G: r44 publish/drain heap trees ===============
    // The L5 publication select (balanced {valid,index,payload} trees):
    // simultaneous eligible slots publish lowest-index first, the merged
    // forward overlay rides the same payload, a tombstoned slot drains
    // without a writeback, and an empty buffer presents the leaf-0
    // default. Stimulus only via the request/response/fwd/verdict ports;
    // the in-DUT miter checks the tree against the old first-hit scan.
    lu_lchk = '1; lu_frsp = '{default: '0};

    // G1: two slots eligible in the same cycle — lowest publishes first,
    // the next slot publishes the following cycle.
    lu_grant(10, 64'h0000_0000_0000_1000, "G1A"); ridA = lu_rid;
    lu_grant(11, 64'h0000_0000_0000_1008, "G1B"); ridB = lu_rid;
    check(ridB != ridA, "G1_SLOTS");
    lu_fresp(ridA, '0, '0, 1'b0);
    lu_fresp(ridB, '0, '0, 1'b0);
    lu_lchk[10] = 1'b0; lu_lchk[11] = 1'b0;
    lu_rvalid(ridA, 64'hAAAA_0001_1111_0001);
    lu_rvalid(ridB, 64'hBBBB_0002_2222_0002);
    check(!lu_rdy_v, "G1_HOLD0");
    tick();
    #2; check(!lu_rdy_v, "G1_HOLD1");
    lu_lchk = '1; #2;
    check(lu_rdy_v && !lu_ex_o.valid, "G1_PUB_A");
    // the lowest-index slot publishes first, whichever tid that is
    check(lu_tid_o == TID'((ridA < ridB) ? 10 : 11), "G1_TID_A");
    check(lu_res == ((ridA < ridB) ? 64'hAAAA_0001_1111_0001
                                  : 64'hBBBB_0002_2222_0002), "G1_DATA_A");
    tick();
    #2;
    check(lu_rdy_v && !lu_ex_o.valid, "G1_PUB_B");
    check(lu_tid_o == TID'((ridA < ridB) ? 11 : 10), "G1_TID_B");
    check(lu_res == ((ridA < ridB) ? 64'hBBBB_0002_2222_0002
                                  : 64'hAAAA_0001_1111_0001), "G1_DATA_B");
    tick();
    #2;
    check(!lu_rdy_v, "G1_DONE");
    check(lu_tid_o == i_lu.ldbuf_q[0].trans_id, "G1_DEF0");

    // G2: partial forward overlay — different bytes from the D$ word and
    // the forward response, merged by the publishing slot's payload.
    lu_grant(12, 64'h0000_0000_0000_2000, "G2A"); ridC = lu_rid;
    lu_fresp(ridC, 64'h0000_0000_AABB_CCDD, 8'h0F, 1'b1);
    lu_rvalid(ridC, 64'h1122_3344_5566_7788);
    #2;
    check(lu_rdy_v && lu_tid_o == TID'(12), "G2_PUB");
    check(lu_res == 64'h1122_3344_AABB_CCDD, "G2_MERGED");
    tick();
    #2;
    check(!lu_rdy_v, "G2_DONE");

    // G3: tombstone drain — the slot is flushed while its response is in
    // flight; the captured response drains without publishing.
    lu_grant(13, 64'h0000_0000_0000_3000, "G3A"); ridD = lu_rid;
    flush = 1; tick(); flush = 0; tick();
    lu_rvalid(ridD, 64'hDEAD_CAFE_0000_0013);
    check(!lu_rdy_v, "G3_NOPUB");
    tick();
    #2;
    check(!i_lu.ldbuf_valid_q[ridD], "G3_FREE");
    check(!lu_rdy_v, "G3_EMPTY");

    // =============== H: r45 PA-capture decode ===============
    // load_pa_now_v now decodes state_q[1]/[6]/[0|2] directly instead of
    // reading translation_req_o back.  Three port-driven edges qualify
    // it: a held WAIT_GNT load must NOT capture while dtlb_hit_i=0, MUST
    // capture the cycle the hit lands (still ungranted), and must NOT
    // capture while cancelled.  The in-DUT g6lc_pa_now_eq invariant
    // compares the new form to valid_i && translation_req_o && dtlb_hit_i
    // every cycle; these checks make that equality non-vacuous on the
    // inputs this decode actually reads.
    lu_ctrl = '0; lu_vld = 0; lu_ex_i = '{default: '0}; lu_rpi = '{default: '0};
    lu_dtlb_hit = 1'b0; lu_ppn = 44'h8_1234; lu_paddr = '0;
    lu_lchk = '1; cancel = '0;
    flush = 1; tick(); flush = 0; tick();

    lu_ctrl.valid = 1'b1; lu_ctrl.fu = LOAD; lu_ctrl.operation = LD;
    lu_ctrl.vaddr = 64'h0000_0000_0000_4000; lu_ctrl.trans_id = TID'(14);
    lu_ctrl.be = '1; lu_ctid = TID'(14);
    lu_vld = 1'b1; lu_rpi.data_gnt = 1'b0;
    #2;
    check(!i_lu.load_pa_now_v, "H_IDLE_HIT0_NOCAP");
    check(!i_lu.load_pa_v_q, "H_PA_V0");
    tick();                               // ungranted -> WAIT_GNT
    #2;
    check(i_lu.state_q[1], "H_WAIT_GNT");
    check(!i_lu.load_pa_now_v, "H_GNT_HIT0_NOCAP");
    lu_dtlb_hit = 1'b1;                   // translation lands, still WAIT_GNT
    #2;
    check(i_lu.load_pa_now_v, "H_GNT_HIT1_CAP");
    tick();
    #2;
    check(i_lu.load_pa_v_q, "H_PA_HELD");
    check(i_lu.load_pa_q == 56'({44'h8_1234, 12'h000}), "H_PA_VAL");
    cancel[14] = 1'b1;                    // cancelled: no new capture
    #2;
    check(!i_lu.load_pa_now_v, "H_CANCEL_NOCAP");
    tick();
    lu_vld = 0; lu_ctrl = '0; cancel = '0; lu_rpi = '{default: '0};
    tick(); #2;
    check(!i_lu.load_pa_v_q, "H_PA_CLEARED");

    // =============== I: r51 sticky exception pending ===============
    // F1/F2 above are the r51 L4 control: the same-cycle kill publish is
    // unchanged when nothing competes for the port.  The r26/r27/r48b
    // witness failure (cycle 19,466,403) was the pre-r51 shape — a kill
    // whose completion could lose the publish port to an unrelated slot
    // or miss a late dummy response.  I1-I3 pin the new contract.
    lu_ctrl = '0; lu_vld = 0; lu_ex_i = '{default: '0}; lu_rpi = '{default: '0};
    lu_dtlb_hit = 1'b1; lu_ppn = 44'h8_0045; lu_paddr = '0;
    lu_lchk = '1; cancel = '0;
    flush = 1; tick(); flush = 0; tick();

    // I1 (L1): an unrelated slot becomes publish-eligible in the same
    // cycle as the kill's dummy response — the exception still publishes
    // with strict priority and the data publishes the following cycle.
    lu_grant(8, 64'h0000_0000_0000_5000, "I1A"); ridA = lu_rid;
    lu_fresp(ridA, '0, '0, 1'b0);             // forward verdict for A
    lu_rvalid(ridA, 64'h5A5A_5A5A_5A5A_5A5A);
    lu_lchk[8] = 1'b0;                        // hold A's publish verdict
    lu_grant(9, 64'h0000_0000_0000_6001, "I1B"); ridB = lu_rid;
    check(i_lu.state_q[2], "I1_SEND_TAG");    // B's tag goes out now
    lu_ex_i.valid = 1'b1; lu_ex_i.cause = 64'd4; lu_ex_i.tval = 64'h6001;
    lu_rpi.data_rvalid = 1'b1; lu_rpi.data_rid = C.DcacheIdWidth'(ridB);
    lu_lchk[8] = 1'b1;                        // A eligible this same cycle
    #2;
    check(lu_rpo.kill_req && lu_rpo.tag_valid, "I1_KILL");
    check(lu_rdy_v && lu_ex_o.valid && lu_ex_o.cause == 64'd4 &&
          lu_ex_o.tval == 64'h6001 && lu_tid_o == TID'(9), "I1_EX_WINS");
    tick();                                   // publish consumed
    lu_rpi = '{default: '0}; lu_ex_i = '{default: '0}; #2;
    check(lu_rdy_v && !lu_ex_o.valid && lu_tid_o == TID'(8) &&
          lu_res == 64'h5A5A_5A5A_5A5A_5A5A, "I1_DATA_NEXT");
    tick(); #2;
    check(!lu_rdy_v, "I1_ONCE");
    check(!(|i_lu.ldbuf_valid_q), "I1_FREED");

    // I2 (L2): the dummy response is a cycle late — the pending bit
    // holds the faulted entry and the captured record publishes once the
    // response lands, even with ex_i already cleared.
    lu_grant(12, 64'h0000_0000_0000_7003, "I2"); ridB = lu_rid;
    check(i_lu.state_q[2], "I2_SEND_TAG");
    lu_ex_i.valid = 1'b1; lu_ex_i.cause = 64'd4; lu_ex_i.tval = 64'h7003;
    #2;
    check(lu_rpo.kill_req, "I2_KILL");
    check(!lu_rdy_v, "I2_NO_PUB_AT_KILL");
    tick();                                   // pend set at this edge
    lu_ex_i = '{default: '0};                 // ex_i moves on
    lu_rvalid(ridB, 64'h0);                   // delayed dummy captured
    #2;
    check(!lu_rdy_v, "I2_RDY_REG");           // head readiness registers a cycle
    tick(); #2;
    check(lu_rdy_v && lu_ex_o.valid && lu_ex_o.cause == 64'd4 &&
          lu_ex_o.tval == 64'h7003 && lu_tid_o == TID'(12), "I2_DEFER_PUB");
    tick(); #2;
    check(!lu_rdy_v, "I2_ONCE");        // drain pop is silent
    tick(); #2;
    check(!(|i_lu.ldbuf_valid_q), "I2_FREED");

    // I3 (L3): the faulting tid is cancelled in the kill cycle — precise
    // drop: no publish of any kind, the slot drains silently.
    lu_grant(3, 64'h0000_0000_0000_8005, "I3"); ridB = lu_rid;
    check(i_lu.state_q[2], "I3_SEND_TAG");
    lu_ex_i.valid = 1'b1; lu_ex_i.cause = 64'd4; lu_ex_i.tval = 64'h8005;
    cancel[3] = 1'b1;
    lu_rpi.data_rvalid = 1'b1; lu_rpi.data_rid = C.DcacheIdWidth'(ridB);
    #2;
    check(lu_rpo.kill_req, "I3_KILL");
    check(!lu_rdy_v, "I3_NO_PUB");
    tick();
    lu_rpi = '{default: '0}; lu_ex_i = '{default: '0}; cancel = '0; #2;
    check(!lu_rdy_v, "I3_STILL");
    tick(); #2;
    tick(); #2;
    check(!i_lu.ldbuf_valid_q[ridB], "I3_DRAINED");
    check(!lu_rdy_v, "I3_NEVER");

    // =============== F15: publish-port collision (L5) ===============
    // r76 F15: under hyp8 L5 a data slot publishes >=1 cycle after its
    // rvalid, so a publish pick can coincide with an FSM-head
    // completion. Slot A (older) has its response captured and its
    // verdict asserted at t; at the same t younger load B is at the FSM
    // head in IDLE, fully covered by the STQ with its own verdict
    // final: B publishes at t (st_fwd_done), A publishes at t+1 with
    // its D$ data — both completions seen, no slot lost. Under
    // G6LC_MUT_LU_PUB_COLLIDE (the ungated pick) A is popped at t and
    // never presents: F15_SLOT_PUB fails by name (and the in-DUT
    // lu_pop_is_presented assertion fires on the stolen cycle).
    lu_ctrl = '0; lu_vld = 0; lu_ex_i = '{default: '0}; lu_rpi = '{default: '0};
    lu_dtlb_hit = 1'b1; lu_ppn = 44'h8_0045; lu_paddr = '0;
    lu_lchk = '1; cancel = '0;
    lu_pom = 1'b0; lu_sfv = 1'b0; lu_sfd = '0; lu_sfbe = '0;
    flush = 1; tick(); flush = 0; tick();

    lu_grant(4, 64'h0000_0000_0000_9000, "F15A"); ridA = lu_rid;
    lu_fresp(ridA, '0, '0, 1'b0);
    lu_lchk[4] = 1'b0;
    lu_rvalid(ridA, 64'hF150_0000_0000_00A4);
    #2; check(!lu_rdy_v, "F15_HOLD");
    // t: B at the head, STQ-covered with its verdict final; A's verdict
    // lands this same cycle.
    lu_ctrl.valid = 1'b1; lu_ctrl.fu = LOAD; lu_ctrl.operation = LD;
    lu_ctrl.vaddr = 64'h0000_0000_0000_A000; lu_ctrl.trans_id = TID'(6);
    lu_ctrl.be = '1; lu_ctid = TID'(6); lu_paddr = 56'h0000_0000_00A000;
    lu_vld = 1'b1;
    lu_lchk[4] = 1'b1;
    lu_pom = 1'b1;
    lu_sfv = 1'b1; lu_sfd = 64'hF15F_0000_0000_00B6; lu_sfbe = '1;
    #2;
    check(lu_rdy_v && !lu_ex_o.valid && lu_tid_o == TID'(6),
          "F15_HEAD_PUB");
    check(lu_res == 64'hF15F_0000_0000_00B6, "F15_HEAD_DATA");
    tick();                                  // B's completion consumed
    lu_vld = 0; lu_ctrl = '0;
    lu_pom = 1'b0; lu_sfv = 1'b0; lu_sfd = '0; lu_sfbe = '0;
    #2;
    check(lu_rdy_v && !lu_ex_o.valid && lu_tid_o == TID'(4),
          "F15_SLOT_PUB");
    check(lu_res == 64'hF150_0000_0000_00A4, "F15_SLOT_DATA");
    tick(); #2;
    check(!lu_rdy_v && !(|i_lu.ldbuf_valid_q), "F15_FREED");
    check(i_lu.lu_f15_collide_n >= 1, "F15_COLLIDE_SEEN");

    $display("HYP8_MEMORY_PASS checked=%0d", checked);
    $finish;
  end
endmodule
