// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext walk, DMA-read the first payload into BeginRun CS, then
// ALLOC, BEGIN, CREATE, DISPATCH, END, SUBMIT, WAIT, or QUEUE. A WRITE
// last descriptor publishes result (SPIR-V, handle, or VK_SUCCESS),
// used.idx, and ISR. DISPATCH/SUBMIT/WAIT without WRITE fault.
// ALLOC/BEGIN/CREATE/END/QUEUE without WRITE stay quiet. EMPTY fetches
// nothing. Enable=0 elaborates no datapath. Does not edit
// g6lc_apu_vgpu_avail. Not wired into g6lc_apu_sys. FeatureVirgl stays
// illegal.

// QueueBegin (qbn): AvailNext CS into BeginRun; WRITE publishes used.idx/ISR. Default-off. FeatureVirgl stays illegal.
// Interplay: QueueBegin (qbn) --> AvailNext (avn) --> BeginRun (bru) ==> WRITE then used then ISR. --? QueueAlloc (qal) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qbn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qbn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qbn_cpl_t cpl_o,
  output apu_qbn_t qbn_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qbn_o = '0;
    assign irq_o = 1'b0;
    assign isr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | ack_valid_i |
                    rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i |
                    wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) | (|in_a_i) |
                    (|in_b_i) | (|ack_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                    (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, FireAvn, WaitAvn, RdPay, WaitRd, LoadCs, FireBru, WaitBru,
      WrPay, WaitWr, WrElem, WaitElem, WrIdx, WaitIdx, Done
    } state_e;
    state_e state_q;
    apu_qbn_cpl_t cpl_q;
    apu_qbn_t rec_q;
    apu_qbn_req_t req_q;
    logic [63:0] pay_addr_q, pay_rd_addr, last_addr_q, used_q, elem_addr_q;
    logic [31:0] pay_len_q, off_q, beat_q, last_len_q, remain, beat, isr_q, result_q;
    logic [15:0] last_flags_q, desc_id_q, uidx_q, next_idx;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] beat_data_q;
    logic [7:0] wbase_q, qsize_q, uslot;
    logic [3:0] load_i_q, nwords_q;
    logic [31:0] cmd_q;
    logic pay_rd, avn_req_v, avn_rdy, avn_cpl, avn_ack;
    logic avn_rd_v, avn_rd_r, avn_rsp_v, avn_rsp_r;
    logic [63:0] avn_rd_addr;
    logic [31:0] avn_rd_len;
    logic bru_req_v, bru_rdy, bru_cpl, bru_ack, bru_cs_we, bru_irq;
    logic [7:0] bru_cs_idx;
    logic [31:0] bru_cs_wdata, bru_cs_rdata, bru_res;
    apu_avn_req_t avn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    apu_bru_req_t bru_req_q;
    apu_bru_cpl_t bru_c;
    apu_bru_t bru_rec;
    logic pay_ok, disp_need, is_create, is_disp, is_alloc, is_begin, is_end;
    logic is_submit, is_wait, is_queue, is_device, is_instance, is_enum, is_qfam;
    logic is_feat, is_props, is_mem, is_vkmem, is_buf, is_bind, is_map, is_unmap;
    logic is_bufreq, is_flush, is_inval, is_memc, is_dsl, is_pl, is_cpipe;
    logic is_dset, is_upd, is_bp, is_bd;
    logic is_pool, is_img, is_bindimg, is_imgreq;
    logic is_view, is_samp, is_rpass, is_gpipe;
    logic is_fbuf, is_beginrp, is_draw, is_endrp;
    logic is_bindvtx, is_bindidx, is_drawidx;
    logic is_setvp, is_setsc, is_barrier, is_nextsp;
    logic is_dfb, is_dvw, is_dsm, is_drp;
    logic is_dbf, is_dim, is_fme, is_dmd;
    logic is_dpl, is_dyo, is_dds, is_dpo;
    logic is_fds, is_rcb, is_fcb, is_ddv;
    logic is_rcp, is_dcp, is_din;
    logic is_gfp, is_ifp, is_dex, is_rdp;
    logic is_iex, is_dwi, is_isl, is_rag;
    logic is_slw, is_sdb, is_sbc, is_sbb;
    logic is_scm, is_swm, is_srf;
    logic is_ccb, is_cci, is_bli, is_cbi;
    logic is_cib, is_ubf, is_fil, is_ccl;
    logic is_dri, is_dxi, is_cds, is_cat;
    logic is_dsi, is_rsi;
    logic is_gfs, is_wfe, is_rfe, is_dfe;
    logic wr_busy, pub_ok;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qbn_cpl_t'('0);
    assign qbn_o = rec_q;
    assign irq_o = isr_q[0];
    assign isr_o = isr_q;
    assign remain = (off_q < pay_len_q) ? (pay_len_q - off_q) : 32'd0;
    assign beat = (remain > 32'(APU_VGPU_BEAT_BYTES)) ? 32'(APU_VGPU_BEAT_BYTES)
                                                      : remain;
    assign pay_rd = state_q == RdPay;
    assign rd_valid_o = pay_rd || avn_rd_v;
    assign rd_addr_o = pay_rd ? pay_rd_addr : avn_rd_addr;
    assign rd_len_o = pay_rd ? beat_q : avn_rd_len;
    assign rd_rsp_ready_o = (state_q == WaitRd) || avn_rsp_r;
    assign avn_rd_r = rd_ready_i && !pay_rd;
    assign avn_rsp_v = rd_rsp_valid_i && (state_q == WaitAvn);
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign avn_req.avail_base = req_q.avu.avail_base;
    assign avn_req.desc_base = req_q.avu.desc_base;
    assign avn_req.queue_size = req_q.avu.queue_size;
    assign avn_req.device_idx = req_q.avu.device_idx;
    assign avn_req.max_chain = req_q.avu.max_chain;
    assign pay_rd_addr = pay_addr_q + 64'(off_q);
    assign bru_req_v = state_q == FireBru;
    assign bru_ack = state_q == WaitBru;
    assign bru_cs_we = state_q == LoadCs;
    assign bru_cs_idx = wbase_q + {4'b0, load_i_q};
    assign bru_cs_wdata = beat_data_q[{load_i_q[2:0], 5'b0} +: 32];
    assign pay_ok = (avn_rec.first_len != 32'd0) &&
                    (avn_rec.first_len[1:0] == 2'd0) &&
                    (avn_rec.first_addr[1:0] == 2'd0) &&
                    (avn_rec.first_len <= 32'(APU_VNENC_WORDS * 4));
    assign is_create = cmd_q == APU_VNENC_CMD_CREATE_SHADER_MODULE;
    assign is_disp = cmd_q == APU_VND_CMD_DISPATCH;
    assign is_alloc = cmd_q == APU_VAC_CMD_ALLOC;
    assign is_begin = cmd_q == APU_VBG_CMD_BEGIN;
    assign is_end = cmd_q == APU_VEN_CMD_END;
    assign is_submit = cmd_q == APU_VQS_CMD_SUBMIT;
    assign is_wait = cmd_q == APU_VWI_CMD_WAIT;
    assign is_queue = cmd_q == APU_VGQ_CMD_QUEUE;
    assign is_device = cmd_q == APU_VCD_CMD_DEVICE;
    assign is_instance = cmd_q == APU_VCI_CMD_INSTANCE;
    assign is_enum = cmd_q == APU_VEP_CMD_ENUM;
    assign is_qfam = cmd_q == APU_VQF_CMD_QFAM;
    assign is_feat = cmd_q == APU_VPF_CMD_FEAT;
    assign is_props = cmd_q == APU_VPP_CMD_PROPS;
    assign is_mem = cmd_q == APU_VMP_CMD_MEM;
    assign is_vkmem = cmd_q == APU_VAM_CMD_MEMORY;
    assign is_buf = cmd_q == APU_VXB_CMD_BUFFER;
    assign is_bind = cmd_q == APU_VBB_CMD_BIND;
    assign is_map = cmd_q == APU_VMM_CMD_MAP;
    assign is_unmap = cmd_q == APU_VUM_CMD_UNMAP;
    assign is_bufreq = cmd_q == APU_VBM_CMD_BUFREQ;
    assign is_flush = cmd_q == APU_VFM_CMD_FLUSH;
    assign is_inval = cmd_q == APU_VIM_CMD_INVAL;
    assign is_memc = cmd_q == APU_VMC_CMD_MEMC;
    assign is_dsl = cmd_q == APU_VDL_CMD_DSLAYOUT;
    assign is_pl = cmd_q == APU_VPL_CMD_PLAYOUT;
    assign is_cpipe = cmd_q == APU_VCP_CMD_CPIPE;
    assign is_dset = cmd_q == APU_VDA_CMD_DESCSET;
    assign is_upd = cmd_q == APU_VUD_CMD_UPDATE;
    assign is_bp = cmd_q == APU_VBP_CMD_BINDPIPE;
    assign is_bd = cmd_q == APU_VBD_CMD_BINDDESC;
    assign is_pool = cmd_q == APU_VPO_CMD_POOL;
    assign is_img = cmd_q == APU_VXI_CMD_IMAGE;
    assign is_bindimg = cmd_q == APU_VBI_CMD_BINDIMG;
    assign is_imgreq = cmd_q == APU_VMI_CMD_IMGREQ;
    assign is_view = cmd_q == APU_VXV_CMD_VIEW;
    assign is_samp = cmd_q == APU_VSM_CMD_SAMPLER;
    assign is_rpass = cmd_q == APU_VRP_CMD_RPASS;
    assign is_gpipe = cmd_q == APU_VGP_CMD_GPIPE;
    assign is_fbuf = cmd_q == APU_VFB_CMD_FBUF;
    assign is_beginrp = cmd_q == APU_VRB_CMD_BEGINRP;
    assign is_draw = cmd_q == APU_VDW_CMD_DRAW;
    assign is_endrp = cmd_q == APU_VRE_CMD_ENDRP;
    assign is_bindvtx = cmd_q == APU_VVB_CMD_BINDVTX;
    assign is_bindidx = cmd_q == APU_VIB_CMD_BINDIDX;
    assign is_drawidx = cmd_q == APU_VDI_CMD_DRAWIDX;
    assign is_setvp = cmd_q == APU_VVP_CMD_SETVP;
    assign is_setsc = cmd_q == APU_VSI_CMD_SETSC;
    assign is_barrier = cmd_q == APU_VPB_CMD_BARRIER;
    assign is_nextsp = cmd_q == APU_VNS_CMD_NEXTSP;
    assign is_dfb = cmd_q == APU_DFB_CMD_DFB;
    assign is_dvw = cmd_q == APU_DVW_CMD_DVW;
    assign is_dsm = cmd_q == APU_DSM_CMD_DSM;
    assign is_drp = cmd_q == APU_DRP_CMD_DRP;
    assign is_dbf = cmd_q == APU_DBF_CMD_DBF;
    assign is_dim = cmd_q == APU_DIM_CMD_DIM;
    assign is_fme = cmd_q == APU_FME_CMD_FME;
    assign is_dmd = cmd_q == APU_DMD_CMD_DMD;
    assign is_dpl = cmd_q == APU_DPL_CMD_DPL;
    assign is_dyo = cmd_q == APU_DYO_CMD_DYO;
    assign is_dds = cmd_q == APU_DDS_CMD_DDS;
    assign is_dpo = cmd_q == APU_DPO_CMD_DPO;
    assign is_fds = cmd_q == APU_FDS_CMD_FDS;
    assign is_rcb = cmd_q == APU_RCB_CMD_RCB;
    assign is_fcb = cmd_q == APU_FCB_CMD_FCB;
    assign is_ddv = cmd_q == APU_DDV_CMD_DDV;
    assign is_rcp = cmd_q == APU_RCP_CMD_RCP;
    assign is_dcp = cmd_q == APU_DCP_CMD_DCP;
    assign is_din = cmd_q == APU_DIN_CMD_DIN;
    assign is_gfp = cmd_q == APU_GFP_CMD_GFP;
    assign is_ifp = cmd_q == APU_IFP_CMD_IFP;
    assign is_dex = cmd_q == APU_DEX_CMD_DEX;
    assign is_rdp = cmd_q == APU_RDP_CMD_RDP;
    assign is_iex = cmd_q == APU_IEX_CMD_IEX;
    assign is_dwi = cmd_q == APU_DWI_CMD_DWI;
    assign is_isl = cmd_q == APU_ISL_CMD_ISL;
    assign is_rag = cmd_q == APU_RAG_CMD_RAG;
    assign is_slw = cmd_q == APU_SLW_CMD_SLW;
    assign is_sdb = cmd_q == APU_SDB_CMD_SDB;
    assign is_sbc = cmd_q == APU_SBC_CMD_SBC;
    assign is_sbb = cmd_q == APU_SBB_CMD_SBB;
    assign is_scm = cmd_q == APU_SCM_CMD_SCM;
    assign is_swm = cmd_q == APU_SWM_CMD_SWM;
    assign is_srf = cmd_q == APU_SRF_CMD_SRF;
    assign is_ccb = cmd_q == APU_CCB_CMD_CCB;
    assign is_cci = cmd_q == APU_CCI_CMD_CCI;
    assign is_bli = cmd_q == APU_BLI_CMD_BLI;
    assign is_cbi = cmd_q == APU_CBI_CMD_CBI;
    assign is_cib = cmd_q == APU_CIB_CMD_CIB;
    assign is_ubf = cmd_q == APU_UBF_CMD_UBF;
    assign is_fil = cmd_q == APU_FIL_CMD_FIL;
    assign is_ccl = cmd_q == APU_CCL_CMD_CCL;
    assign is_dri = cmd_q == APU_DRI_CMD_DRI;
    assign is_dxi = cmd_q == APU_IXI_CMD_IXI;
    assign is_cds = cmd_q == APU_CDS_CMD_CDS;
    assign is_cat = cmd_q == APU_CAT_CMD_CAT;
    assign is_dsi = cmd_q == APU_DSI_CMD_DSI;
    assign is_rsi = cmd_q == APU_RSI_CMD_RSI;
    assign is_gfs = cmd_q == APU_GFS_CMD_GFS;
    assign is_wfe = cmd_q == APU_WFE_CMD_WFE;
    assign is_rfe = cmd_q == APU_RFE_CMD_RFE;
    assign is_dfe = cmd_q == APU_DFE_CMD_DFE;
    assign disp_need = (last_flags_q & VIRTQ_DESC_F_WRITE) != 16'd0 &&
                       (last_len_q >= 32'd4) &&
                       (last_addr_q[1:0] == 2'd0) &&
                       (req_q.avu.used_base[1:0] == 2'd0);
    assign uslot = 8'(uidx_q) & (qsize_q - 8'd1);
    assign next_idx = uidx_q + 16'd1;
    assign wr_busy = (state_q == WrPay) || (state_q == WrElem) || (state_q == WrIdx);
    assign wr_valid_o = wr_busy;
    assign wr_rsp_ready_o = (state_q == WaitWr) || (state_q == WaitElem) ||
                            (state_q == WaitIdx);
    assign pub_ok = (last_addr_q[1:0] == 2'd0) && (used_q[1:0] == 2'd0) &&
                    (qsize_q != 8'd0);

    always_comb begin
      wr_addr_o = last_addr_q;
      wr_len_o = 32'd4;
      wr_data_o = '0;
      unique case (state_q)
        WrPay, WaitWr: begin
          wr_addr_o = last_addr_q;
          wr_len_o = 32'd4;
          wr_data_o[31:0] = result_q;
        end
        WrElem, WaitElem: begin
          wr_addr_o = elem_addr_q;
          wr_len_o = 32'd8;
          wr_data_o[31:0]  = {16'h0, desc_id_q};
          wr_data_o[63:32] = 32'd4;
        end
        WrIdx, WaitIdx: begin
          wr_addr_o = used_q;
          wr_len_o = 32'd4;
          wr_data_o[31:0] = {next_idx, 16'h0};
        end
        default: ;
      endcase
    end

    g6lc_apu_avn #(.Enable(1'b1)) i_avn (
      .clk_i, .rst_ni,
      .req_valid_i(avn_req_v), .req_ready_o(avn_rdy), .req_i(avn_req),
      .cpl_valid_o(avn_cpl), .cpl_ready_i(avn_ack), .cpl_o(avn_c), .avn_o(avn_rec),
      .rd_valid_o(avn_rd_v), .rd_ready_i(avn_rd_r),
      .rd_addr_o(avn_rd_addr), .rd_len_o(avn_rd_len),
      .rd_rsp_valid_i(avn_rsp_v), .rd_rsp_ready_o(avn_rsp_r),
      .rd_rsp_ok_i(rd_rsp_ok_i), .rd_rsp_addr_i(rd_rsp_addr_i),
      .rd_rsp_len_i(rd_rsp_len_i), .rd_rsp_data_i(rd_rsp_data_i)
    );

    g6lc_apu_bru #(.Enable(1'b1)) i_bru (
      .clk_i, .rst_ni, .cs_we_i(bru_cs_we), .cs_idx_i(bru_cs_idx),
      .cs_wdata_i(bru_cs_wdata), .cs_rdata_o(bru_cs_rdata),
      .req_valid_i(bru_req_v), .req_ready_o(bru_rdy), .req_i(bru_req_q),
      .in_a_i, .in_b_i,
      .cpl_valid_o(bru_cpl), .cpl_ready_i(bru_ack), .cpl_o(bru_c), .bru_o(bru_rec),
      .irq_o(bru_irq), .result_o(bru_res)
    );

    logic unused_bru;
    assign unused_bru = |bru_cs_rdata | bru_irq;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
        pay_addr_q <= '0;
        pay_len_q <= '0;
        last_addr_q <= '0;
        last_len_q <= '0;
        last_flags_q <= '0;
        desc_id_q <= '0;
        off_q <= '0;
        beat_q <= '0;
        beat_data_q <= '0;
        wbase_q <= '0;
        load_i_q <= '0;
        nwords_q <= '0;
        cmd_q <= '0;
        bru_req_q <= '0;
        isr_q <= '0;
        result_q <= '0;
        used_q <= '0;
        elem_addr_q <= '0;
        uidx_q <= '0;
        qsize_q <= '0;
      end else begin
        if (ack_valid_i && ack_i[0]) isr_q[0] <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            req_q <= req_i;
            off_q <= '0;
            used_q <= req_i.avu.used_base;
            uidx_q <= req_i.avu.used_idx;
            qsize_q <= req_i.avu.queue_size;
            if (req_i.gnh_only) begin
              bru_req_q <= '{op: APU_BRU_GNH, gnh: req_i.gnh};
              state_q <= FireBru;
            end else state_q <= FireAvn;
          end
          FireAvn: if (avn_rdy) state_q <= WaitAvn;
          WaitAvn: if (avn_cpl) begin
            if (avn_c.status == APU_AVN_EMPTY) begin
              cpl_q <= '{status: APU_QBN_EMPTY};
              state_q <= Done;
            end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid || !pay_ok) begin
              cpl_q <= '{status: APU_QBN_FAULT};
              state_q <= Done;
            end else begin
              pay_addr_q <= avn_rec.first_addr;
              pay_len_q <= avn_rec.first_len;
              last_addr_q <= avn_rec.last_addr;
              last_len_q <= avn_rec.last_len;
              last_flags_q <= avn_rec.last_flags;
              desc_id_q <= avn_rec.desc_id;
              off_q <= '0;
              beat_q <= (avn_rec.first_len > 32'(APU_VGPU_BEAT_BYTES)) ?
                        32'(APU_VGPU_BEAT_BYTES) : avn_rec.first_len;
              rec_q <= '{
                valid:     1'b0,
                alloc:     1'b0,
                begin_cmd: 1'b0,
                end_cmd:   1'b0,
                submit:    1'b0,
                wait_idle:  1'b0,
                dispatch:  1'b0,
                irq:       isr_q[0],
                cmd:       '0,
                result:    '0,
                handle:    '0,
                used_idx:  req_q.avu.used_idx,
                resp_addr: avn_rec.last_addr
              };
              state_q <= RdPay;
            end
          end
          RdPay: if (rd_ready_i) state_q <= WaitRd;
          WaitRd: if (rd_rsp_valid_i) begin
            if (!rd_rsp_ok_i || rd_rsp_addr_i != pay_rd_addr ||
                rd_rsp_len_i != beat_q) begin
              cpl_q <= '{status: APU_QBN_FAULT};
              state_q <= Done;
            end else begin
              beat_data_q <= rd_rsp_data_i;
              wbase_q <= off_q[9:2];
              nwords_q <= beat_q[5:2];
              load_i_q <= '0;
              if (off_q == 32'd0) cmd_q <= rd_rsp_data_i[31:0];
              state_q <= LoadCs;
            end
          end
          LoadCs: begin
            if (load_i_q + 4'd1 == nwords_q) begin
              if ((off_q + beat_q) == pay_len_q) begin
                if (!(is_create || is_disp || is_alloc || is_begin || is_end ||
                      is_submit || is_wait || is_queue || is_device ||
                      is_instance || is_enum || is_qfam || is_feat ||
                      is_props || is_mem || is_vkmem || is_buf || is_bind ||
                      is_map || is_unmap || is_bufreq || is_flush ||
                      is_inval || is_memc || is_dsl || is_pl || is_cpipe ||
                      is_dset || is_upd || is_bp || is_bd ||
                      is_pool || is_img || is_bindimg || is_imgreq ||
                      is_view || is_samp || is_rpass || is_gpipe ||
                      is_fbuf || is_beginrp || is_draw || is_endrp ||
                      is_bindvtx || is_bindidx || is_drawidx ||
                      is_setvp || is_setsc || is_barrier || is_nextsp ||
                      is_dfb || is_dvw || is_dsm || is_drp ||
                      is_dbf || is_dim || is_fme || is_dmd ||
                      is_dpl || is_dyo || is_dds || is_dpo ||
                      is_fds || is_rcb || is_fcb || is_ddv ||
                      is_rcp || is_dcp || is_din ||
                      is_gfp || is_ifp || is_dex || is_rdp ||
                      is_iex || is_dwi || is_isl || is_rag ||
                      is_slw || is_sdb || is_sbc || is_sbb ||
                      is_scm || is_swm || is_srf ||
                      is_ccb || is_cci || is_bli || is_cbi ||
                      is_cib || is_ubf || is_fil || is_ccl ||
                      is_dri || is_dxi || is_cds || is_cat ||
                      is_dsi || is_rsi ||
                      is_gfs || is_wfe || is_rfe || is_dfe) ||
                    ((is_disp || is_submit || is_wait) && !disp_need)) begin
                  cpl_q <= '{status: APU_QBN_FAULT};
                  state_q <= Done;
                end else begin
                  bru_req_q <= '{
                    op: is_disp ? APU_BRU_DISPATCH :
                        (is_alloc ? APU_BRU_ALLOC :
                         (is_begin ? APU_BRU_BEGIN :
                          (is_end ? APU_BRU_END :
                           (is_submit ? APU_BRU_SUBMIT :
                            (is_wait ? APU_BRU_WAIT :
                             (is_queue ? APU_BRU_QUEUE :
                              (is_device ? APU_BRU_DEVICE :
                               (is_instance ? APU_BRU_INSTANCE :
                                (is_enum ? APU_BRU_ENUM :
                                 (is_qfam ? APU_BRU_QFAM :
                                  (is_feat ? APU_BRU_FEAT :
                                   (is_props ? APU_BRU_PROPS :
                                    (is_mem ? APU_BRU_MEM :
                                     (is_vkmem ? APU_BRU_VKMEM :
                                      (is_buf ? APU_BRU_BUFFER :
                                       (is_bind ? APU_BRU_BIND :
                                        (is_map ? APU_BRU_MAP :
                                         (is_unmap ? APU_BRU_UNMAP :
                                          (is_bufreq ? APU_BRU_BUFREQ :
                                           (is_flush ? APU_BRU_FLUSH :
                                            (is_inval ? APU_BRU_INVAL :
                                             (is_memc ? APU_BRU_MEMC :
                                              (is_dsl ? APU_BRU_DSLAYOUT :
                                               (is_pl ? APU_BRU_PLAYOUT :
                                                (is_cpipe ? APU_BRU_CPIPE :
                                                 (is_dset ? APU_BRU_DESCSET :
                                                  (is_upd ? APU_BRU_UPDATE :
                                                   (is_bp ? APU_BRU_BINDPIPE :
                                                    (is_bd ? APU_BRU_BINDDESC :
                                                     (is_pool ? APU_BRU_POOL :
                                                      (is_img ? APU_BRU_IMAGE :
                                                       (is_bindimg ? APU_BRU_BINDIMG :
                                                        (is_imgreq ? APU_BRU_IMGREQ :
                                                        (is_view ? APU_BRU_VIEW :
                                                         (is_samp ? APU_BRU_SAMPLER :
                                                          (is_rpass ? APU_BRU_RPASS :
                                                           (is_gpipe ? APU_BRU_GPIPE :
                                                            (is_fbuf ? APU_BRU_FBUF :
                                                             (is_beginrp ? APU_BRU_BEGINRP :
                                                              (is_draw ? APU_BRU_DRAW :
                                                               (is_endrp ? APU_BRU_ENDRP :
                                                                (is_bindvtx ? APU_BRU_BINDVTX :
                                                                 (is_bindidx ? APU_BRU_BINDIDX :
                                                                  (is_drawidx ? APU_BRU_DRAWIDX :
                                                                   (is_setvp ? APU_BRU_SETVP :
                                                                    (is_setsc ? APU_BRU_SETSC :
                                                                     (is_barrier ? APU_BRU_BARRIER :
                                                                      (is_nextsp ? APU_BRU_NEXTSP :
                                                                       (is_dfb ? APU_BRU_DFB :
                                                                        (is_dvw ? APU_BRU_DVW :
                                                                         (is_dsm ? APU_BRU_DSM :
                                                                          (is_drp ? APU_BRU_DRP :
                                                                           (is_dbf ? APU_BRU_DBF :
                                                                            (is_dim ? APU_BRU_DIM :
                                                                             (is_fme ? APU_BRU_FME :
                                                                              (is_dmd ? APU_BRU_DMD :
                                                                               (is_dpl ? APU_BRU_DPL :
                                                                                (is_dyo ? APU_BRU_DYO :
                                                                                 (is_dds ? APU_BRU_DDS :
                                                                                  (is_dpo ? APU_BRU_DPO :
                                                                                   (is_fds ? APU_BRU_FDS :
                                                                                    (is_rcb ? APU_BRU_RCB :
                                                                                     (is_fcb ? APU_BRU_FCB :
                                                                                      (is_ddv ? APU_BRU_DDV :
                                                                                       (is_rcp ? APU_BRU_RCP :
                                                                                        (is_dcp ? APU_BRU_DCP :
                                                                                         (is_din ? APU_BRU_DIN :
                                                                                          (is_gfp ? APU_BRU_GFP :
                                                                                           (is_ifp ? APU_BRU_IFP :
                                                                                            (is_dex ? APU_BRU_DEX :
                                                                                             (is_rdp ? APU_BRU_RDP :
                                                                                              (is_iex ? APU_BRU_IEX :
                                                                                               (is_dwi ? APU_BRU_DWI :
                                                                                                (is_isl ? APU_BRU_ISL :
                                                                                                 (is_rag ? APU_BRU_RAG :
                                                                                                  (is_slw ? APU_BRU_SLW :
                                                                                                   (is_sdb ? APU_BRU_SDB :
                                                                                                    (is_sbc ? APU_BRU_SBC :
                                                                                                     (is_sbb ? APU_BRU_SBB :
                                                                                                      (is_scm ? APU_BRU_SCM :
                                                                                                       (is_swm ? APU_BRU_SWM :
                                                                                                        (is_srf ? APU_BRU_SRF :
                                                                                                         (is_ccb ? APU_BRU_CCB :
                                                                                                          (is_cci ? APU_BRU_CCI :
                                                                                                           (is_bli ? APU_BRU_BLI :
                                                                                                            (is_cbi ? APU_BRU_CBI :
                                                                                                             (is_cib ? APU_BRU_CIB :
                                                                                                              (is_ubf ? APU_BRU_UBF :
                                                                                                               (is_fil ? APU_BRU_FIL :
                                                                                                                (is_ccl ? APU_BRU_CCL :
                                                                                                                 (is_dri ? APU_BRU_DRI :
                                                                                                                  (is_dxi ? APU_BRU_DXI :
                                                                                                                   (is_cds ? APU_BRU_CDS :
                                                                                                                    (is_cat ? APU_BRU_CAT :
                                                                                                                     (is_dsi ? APU_BRU_DSI :
                                                                                                                      (is_rsi ? APU_BRU_RSI :
                                                                                                                       (is_gfs ? APU_BRU_GFS :
                                                                                                                        (is_wfe ? APU_BRU_WFE :
                                                                                                                         (is_rfe ? APU_BRU_RFE :
                                                                                                                          (is_dfe ? APU_BRU_DFE :
                                                                                                                           APU_BRU_CREATE)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))),
                    gnh: '0
                  };
                  rec_q <= '{
                    valid:     1'b0,
                    alloc:     is_alloc,
                    begin_cmd: is_begin,
                    end_cmd:   is_end,
                    submit:    is_submit,
                    wait_idle:  is_wait,
                    dispatch:  is_disp,
                    irq:       isr_q[0],
                    cmd:       cmd_q,
                    result:    '0,
                    handle:    '0,
                    used_idx:  uidx_q,
                    resp_addr: last_addr_q
                  };
                  state_q <= FireBru;
                end
              end else begin
                off_q <= off_q + beat_q;
                beat_q <= ((pay_len_q - (off_q + beat_q)) > 32'(APU_VGPU_BEAT_BYTES)) ?
                          32'(APU_VGPU_BEAT_BYTES) : (pay_len_q - (off_q + beat_q));
                state_q <= RdPay;
              end
            end else load_i_q <= load_i_q + 4'd1;
          end
          FireBru: if (bru_rdy) state_q <= WaitBru;
          WaitBru: if (bru_cpl) begin
            if (bru_c.status != APU_BRU_OK || !bru_rec.valid) begin
              rec_q <= '{
                valid:     1'b0,
                alloc:     1'b0,
                begin_cmd: 1'b0,
                end_cmd:   1'b0,
                submit:    1'b0,
                wait_idle:  1'b0,
                dispatch:  1'b0,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    '0,
                handle:    '0,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QBN_FAULT};
              state_q <= Done;
            end else if (!disp_need) begin
              rec_q <= '{
                valid:     1'b1,
                alloc:     bru_rec.alloc,
                begin_cmd: bru_rec.begin_cmd,
                end_cmd:   bru_rec.end_cmd,
                submit:    bru_rec.submit,
                wait_idle: bru_rec.wait_idle,
                dispatch:  bru_rec.dispatch,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    bru_rec.result,
                handle:    bru_rec.handle,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QBN_OK};
              state_q <= Done;
            end else if (!pub_ok) begin
              rec_q <= '{
                valid:     1'b0,
                alloc:     1'b0,
                begin_cmd: 1'b0,
                end_cmd:   1'b0,
                submit:    1'b0,
                wait_idle:  1'b0,
                dispatch:  1'b0,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    '0,
                handle:    '0,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QBN_FAULT};
              state_q <= Done;
            end else begin
              result_q <= bru_rec.dispatch ? bru_res :
                          (bru_rec.alloc_mem ? bru_rec.handle :
                           (bru_rec.create_buffer ? bru_rec.handle :
                           (bru_rec.create_dslayout ? bru_rec.handle :
                           (bru_rec.create_playout ? bru_rec.handle :
                           (bru_rec.create_cpipe ? bru_rec.handle :
                           (bru_rec.alloc_descset ? bru_rec.handle :
                           (bru_rec.create_pool ? bru_rec.handle :
                           (bru_rec.create_image ? bru_rec.handle :
                           (bru_rec.create_view ? bru_rec.handle :
                           (bru_rec.create_sampler ? bru_rec.handle :
                           (bru_rec.create_rpass ? bru_rec.handle :
                           (bru_rec.create_gpipe ? bru_rec.handle :
                           (bru_rec.create_fbuf ? bru_rec.handle :
                           (bru_rec.begin_rp ? 32'd0 :
                           (bru_rec.draw_cmd ? APU_VDW_VERTS :
                           (bru_rec.end_rp ? 32'd0 :
                           (bru_rec.bind_vtx ? 32'd0 :
                           (bru_rec.bind_idx ? 32'd0 :
                           (bru_rec.draw_idx ? APU_VDI_INDICES :
                           (bru_rec.set_vp ? 32'd0 :
                           (bru_rec.set_sc ? 32'd0 :
                           (bru_rec.barrier ? 32'd0 :
                           (bru_rec.next_sp ? 32'd0 :
                           (bru_rec.dest_fbuf ? 32'd0 :
                           (bru_rec.dest_view ? 32'd0 :
                           (bru_rec.dest_samp ? 32'd0 :
                           (bru_rec.dest_rpass ? 32'd0 :
                           (bru_rec.dest_buf ? 32'd0 :
                           (bru_rec.dest_img ? 32'd0 :
                           (bru_rec.free_mem ? 32'd0 :
                           (bru_rec.dest_mod ? 32'd0 :
                           (bru_rec.dest_pipe ? 32'd0 :
                           (bru_rec.dest_play ? 32'd0 :
                           (bru_rec.dest_dsl ? 32'd0 :
                           (bru_rec.dest_pool ? 32'd0 :
                           (bru_rec.free_dset ? 32'd0 :
                           (bru_rec.reset_cbuf ? 32'd0 :
                           (bru_rec.free_cbuf ? 32'd0 :
                           (bru_rec.dest_dev ? 32'd0 :
                           (bru_rec.reset_cpool ? 32'd0 :
                           (bru_rec.dest_cpool ? 32'd0 :
                           (bru_rec.dest_inst ? 32'd0 :
                           (bru_rec.get_fmt ? APU_GFP_FEATURES :
                           (bru_rec.get_ifmt ? APU_IFP_MAX_EXTENT :
                           (bru_rec.get_dext ? APU_DEX_COUNT :
                           (bru_rec.reset_dpool ? 32'd0 :
                           (bru_rec.get_iext ? APU_IEX_COUNT :
                           (bru_rec.wait_dev ? 32'd0 :
                           (bru_rec.get_isl ? APU_VMI_SIZE :
                           (bru_rec.get_rag ? APU_RAG_GRAN :
                           (bru_rec.set_lw ? 32'd0 :
                           (bru_rec.set_bias ? 32'd0 :
                           (bru_rec.set_blend ? 32'd0 :
                           (bru_rec.set_bounds ? 32'd0 :
                           (bru_rec.set_scmp ? 32'd0 :
                           (bru_rec.set_swm ? 32'd0 :
                           (bru_rec.set_sref ? 32'd0 :
                           (bru_rec.copy_buf ? 32'd0 :
                           (bru_rec.copy_img ? 32'd0 :
                           (bru_rec.blit_img ? 32'd0 :
                           (bru_rec.copy_b2i ? 32'd0 :
                           (bru_rec.copy_i2b ? 32'd0 :
                           (bru_rec.update_buf ? 32'd0 :
                           (bru_rec.fill_buf ? 32'd0 :
                           (bru_rec.clear_col ? 32'd0 :
                           (bru_rec.draw_indr ? APU_DRI_COUNT :
                           (bru_rec.draw_iindr ? APU_IXI_COUNT :
                           (bru_rec.clear_ds ? 32'd0 :
                           (bru_rec.clear_att ? 32'd0 :
                           (bru_rec.disp_indr ? 32'd0 :
                           (bru_rec.resolve_img ? 32'd0 :
                           (bru_rec.get_fence ? 32'd0 :
                           (bru_rec.wait_fence ? 32'd0 :
                           (bru_rec.reset_fence ? 32'd0 :
                           (bru_rec.dest_fence ? 32'd0 :
                           (bru_rec.update_desc ? 32'd0 :
                           (bru_rec.bind_pipe ? 32'd0 :
                           (bru_rec.bind_desc ? 32'd0 :
                           (bru_rec.bind_image ? 32'd0 :
                           (bru_rec.img_req ? APU_VMI_SIZE :
                           (bru_rec.bind_buffer ? 32'd0 :
                           (bru_rec.map_mem ? bru_rec.result :
                           (bru_rec.unmap_mem ? 32'd0 :
                           (bru_rec.buf_req ? APU_VBM_SIZE :
                           (bru_rec.flush_mem ? 32'd0 :
                           (bru_rec.inval_mem ? 32'd0 :
                           (bru_rec.mem_commit ? APU_VMC_COMMITTED :
                           (bru_rec.get_mem ? APU_VMP_TYPE_COUNT :
                           (bru_rec.get_props ? APU_VPP_MAX_BOUND_DESCRIPTOR_SETS :
                            (bru_rec.get_feat ? APU_VPF_FRAGMENT_STORES :
                             (bru_rec.get_qfam ? APU_VQF_FAMILY_COUNT :
                              ((bru_rec.create || bru_rec.alloc || bru_rec.get_queue ||
                                bru_rec.create_device || bru_rec.create_instance ||
                                bru_rec.enum_phys)
                               ? bru_rec.handle : 32'd0))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))));
              rec_q <= '{
                valid:     1'b0,
                alloc:     bru_rec.alloc,
                begin_cmd: bru_rec.begin_cmd,
                end_cmd:   bru_rec.end_cmd,
                submit:    bru_rec.submit,
                wait_idle: bru_rec.wait_idle,
                dispatch:  bru_rec.dispatch,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    bru_rec.dispatch ? bru_res :
                           (bru_rec.alloc_mem ? bru_rec.handle :
                            (bru_rec.create_buffer ? bru_rec.handle :
                            (bru_rec.create_dslayout ? bru_rec.handle :
                            (bru_rec.create_playout ? bru_rec.handle :
                            (bru_rec.create_cpipe ? bru_rec.handle :
                            (bru_rec.alloc_descset ? bru_rec.handle :
                            (bru_rec.create_pool ? bru_rec.handle :
                            (bru_rec.create_image ? bru_rec.handle :
                            (bru_rec.create_view ? bru_rec.handle :
                            (bru_rec.create_sampler ? bru_rec.handle :
                            (bru_rec.create_rpass ? bru_rec.handle :
                            (bru_rec.create_gpipe ? bru_rec.handle :
                            (bru_rec.create_fbuf ? bru_rec.handle :
                            (bru_rec.begin_rp ? 32'd0 :
                            (bru_rec.draw_cmd ? APU_VDW_VERTS :
                            (bru_rec.end_rp ? 32'd0 :
                            (bru_rec.bind_vtx ? 32'd0 :
                            (bru_rec.bind_idx ? 32'd0 :
                            (bru_rec.draw_idx ? APU_VDI_INDICES :
                            (bru_rec.set_vp ? 32'd0 :
                            (bru_rec.set_sc ? 32'd0 :
                            (bru_rec.barrier ? 32'd0 :
                            (bru_rec.next_sp ? 32'd0 :
                            (bru_rec.dest_fbuf ? 32'd0 :
                            (bru_rec.dest_view ? 32'd0 :
                            (bru_rec.dest_samp ? 32'd0 :
                            (bru_rec.dest_rpass ? 32'd0 :
                            (bru_rec.dest_buf ? 32'd0 :
                            (bru_rec.dest_img ? 32'd0 :
                            (bru_rec.free_mem ? 32'd0 :
                            (bru_rec.dest_mod ? 32'd0 :
                            (bru_rec.dest_pipe ? 32'd0 :
                            (bru_rec.dest_play ? 32'd0 :
                            (bru_rec.dest_dsl ? 32'd0 :
                            (bru_rec.dest_pool ? 32'd0 :
                            (bru_rec.free_dset ? 32'd0 :
                            (bru_rec.reset_cbuf ? 32'd0 :
                            (bru_rec.free_cbuf ? 32'd0 :
                            (bru_rec.dest_dev ? 32'd0 :
                            (bru_rec.reset_cpool ? 32'd0 :
                            (bru_rec.dest_cpool ? 32'd0 :
                            (bru_rec.dest_inst ? 32'd0 :
                            (bru_rec.get_fmt ? APU_GFP_FEATURES :
                            (bru_rec.get_ifmt ? APU_IFP_MAX_EXTENT :
                            (bru_rec.get_dext ? APU_DEX_COUNT :
                            (bru_rec.reset_dpool ? 32'd0 :
                            (bru_rec.get_iext ? APU_IEX_COUNT :
                            (bru_rec.wait_dev ? 32'd0 :
                            (bru_rec.get_isl ? APU_VMI_SIZE :
                            (bru_rec.get_rag ? APU_RAG_GRAN :
                            (bru_rec.set_lw ? 32'd0 :
                            (bru_rec.set_bias ? 32'd0 :
                            (bru_rec.set_blend ? 32'd0 :
                            (bru_rec.set_bounds ? 32'd0 :
                            (bru_rec.set_scmp ? 32'd0 :
                            (bru_rec.set_swm ? 32'd0 :
                            (bru_rec.set_sref ? 32'd0 :
                            (bru_rec.copy_buf ? 32'd0 :
                            (bru_rec.copy_img ? 32'd0 :
                            (bru_rec.blit_img ? 32'd0 :
                            (bru_rec.copy_b2i ? 32'd0 :
                            (bru_rec.copy_i2b ? 32'd0 :
                            (bru_rec.update_buf ? 32'd0 :
                            (bru_rec.fill_buf ? 32'd0 :
                            (bru_rec.clear_col ? 32'd0 :
                            (bru_rec.draw_indr ? APU_DRI_COUNT :
                            (bru_rec.draw_iindr ? APU_IXI_COUNT :
                            (bru_rec.clear_ds ? 32'd0 :
                            (bru_rec.clear_att ? 32'd0 :
                            (bru_rec.disp_indr ? 32'd0 :
                            (bru_rec.resolve_img ? 32'd0 :
                            (bru_rec.get_fence ? 32'd0 :
                            (bru_rec.wait_fence ? 32'd0 :
                            (bru_rec.reset_fence ? 32'd0 :
                            (bru_rec.dest_fence ? 32'd0 :
                            (bru_rec.update_desc ? 32'd0 :
                            (bru_rec.bind_pipe ? 32'd0 :
                            (bru_rec.bind_desc ? 32'd0 :
                            (bru_rec.bind_image ? 32'd0 :
                            (bru_rec.img_req ? APU_VMI_SIZE :
                            (bru_rec.bind_buffer ? 32'd0 :
                            (bru_rec.map_mem ? bru_rec.result :
                            (bru_rec.unmap_mem ? 32'd0 :
                            (bru_rec.buf_req ? APU_VBM_SIZE :
                            (bru_rec.flush_mem ? 32'd0 :
                            (bru_rec.inval_mem ? 32'd0 :
                            (bru_rec.mem_commit ? APU_VMC_COMMITTED :
                            (bru_rec.get_mem ? APU_VMP_TYPE_COUNT :
                            (bru_rec.get_props ? APU_VPP_MAX_BOUND_DESCRIPTOR_SETS :
                             (bru_rec.get_feat ? APU_VPF_FRAGMENT_STORES :
                              (bru_rec.get_qfam ? APU_VQF_FAMILY_COUNT :
                               ((bru_rec.create || bru_rec.alloc || bru_rec.get_queue ||
                                 bru_rec.create_device || bru_rec.create_instance ||
                                 bru_rec.enum_phys)
                                ? bru_rec.handle : 32'd0)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))), 
                handle:    bru_rec.handle,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              elem_addr_q <= used_q + 64'd4 + (64'(uslot) << 3);
              state_q <= WrPay;
            end
          end
          WrPay: if (wr_ready_i) state_q <= WaitWr;
          WaitWr: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q <= '{status: APU_QBN_FAULT};
              state_q <= Done;
            end else state_q <= WrElem;
          end
          WrElem: if (wr_ready_i) state_q <= WaitElem;
          WaitElem: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q <= '{status: APU_QBN_FAULT};
              state_q <= Done;
            end else state_q <= WrIdx;
          end
          WrIdx: if (wr_ready_i) state_q <= WaitIdx;
          WaitIdx: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              rec_q <= '0;
              cpl_q <= '{status: APU_QBN_FAULT};
              state_q <= Done;
            end else begin
              isr_q <= APU_UIR_ISR_VRING;
              rec_q <= '{
                valid:     1'b1,
                alloc:     rec_q.alloc,
                begin_cmd: rec_q.begin_cmd,
                end_cmd:   rec_q.end_cmd,
                submit:    rec_q.submit,
                wait_idle: rec_q.wait_idle,
                dispatch:  rec_q.dispatch,
                irq:       1'b1,
                cmd:       cmd_q,
                result:    result_q,
                handle:    rec_q.handle,
                used_idx:  next_idx,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QBN_OK};
              state_q <= Done;
            end
          end
          Done: if (cpl_ready_i) state_q <= Idle;
          default: state_q <= Idle;
        endcase
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// QueueBegin (qbn) enable-0 fixture: AvailNext CS into BeginRun ALLOC/BEGIN/CREATE/DISPATCH/END.
module g6lc_apu_qbn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qbn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qbn_cpl_t cpl_o,
  output apu_qbn_t qbn_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  g6lc_apu_qbn #(.Enable(Enable)) i_dut (.*);
endmodule
