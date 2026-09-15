// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Firmware-facing APU memory backend. Binds the mapping table, command
// snapshot, SG walker, DMA leaves and used-ring publisher behind one AXI
// master. One firmware operation at a time; reset/cancel wait for idle.

module g6lc_apu_mem
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  logic enable_i,
  input  logic cancel_i,
  input  logic invalidate_i,

  input  logic          op_valid_i,
  output logic          op_ready_o,
  input  apu_mem_op_e   op_i,
  input  apu_map_insert_t insert_i,
  input  apu_map_lookup_t lookup_i,
  input  apu_map_inval_t  inval_i,
  input  apu_sg_load_t    sg_load_i,
  input  apu_dma_mapping_t sg_list_i,
  input  apu_dma_mapping_t sg_backing_i,
  input  apu_sg_query_t    sg_query_i,
  input  apu_cmd_req_t     cmd_i,
  input  apu_dma_read_req_t cmd_dma_i,
  input  apu_dma_mapping_t  cmd_map_i,
  input  apu_used_req_t     used_i,
  output logic          op_cpl_valid_o,
  input  logic          op_cpl_ready_i,
  output apu_map_cpl_t  op_cpl_o,
  output apu_dma_mapping_t lookup_mapping_o,
  input  logic          cmd_rd_valid_i,
  output logic          cmd_rd_ready_o,
  input  logic [31:0]   cmd_rd_offset_i,
  output logic          cmd_rd_data_valid_o,
  input  logic          cmd_rd_data_ready_i,
  output logic [63:0]   cmd_rd_data_o,

  output logic idle_o,
  output logic cmd_held_o,
  output logic bus_fault_o,
  output axi_req_t axi_req_o,
  input  axi_rsp_t axi_rsp_i
);
  localparam bit MemEn = ApuCfg.Enable &&
      (ApuCfg.MaxResources != 0 || ApuCfg.MaxCmdBytes != 0 ||
       ApuCfg.SgEn || ApuCfg.DmaReadEn || ApuCfg.DmaWriteEn);

  `ifndef SYNTHESIS
  initial assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU mem: invalid configuration");
  `endif

  if (!MemEn) begin : gen_off
    assign op_ready_o = 1'b0;
    assign op_cpl_valid_o = 1'b0;
    assign op_cpl_o = '0;
    assign lookup_mapping_o = '0;
    assign cmd_rd_ready_o = 1'b0;
    assign cmd_rd_data_valid_o = 1'b0;
    assign cmd_rd_data_o = '0;
    assign idle_o = 1'b1;
    assign cmd_held_o = 1'b0;
    assign bus_fault_o = 1'b0;
    assign axi_req_o = '0;
  end else begin : gen_on
    typedef enum logic [4:0] {
      Idle, Issue, WaitCpl, FragIssue, FragData, FragWait, CmdIssue, CmdPump, CmdWait, Done
    } state_e;
    typedef enum logic [1:0] {RNone, RSg, RRd} rsel_e;
    typedef enum logic [1:0] {WNone, WWr, WQ} wsel_e;

    state_e state_q;
    apu_mem_op_e op_q;
    apu_map_cpl_t cpl_q;
    apu_dma_mapping_t lmap_q, frag_map_q;
    apu_sg_fragment_t frag_q;
    apu_dma_read_req_t dma_req_q;
    logic [31:0] sink_off_q;
    logic kill, children_idle, children_fault, fcv, crv, frag_fail_q, cmd_taken_q, rd_taken_q;
    logic dma_done_q, st_done_q;
    rsel_e rsel_q, rsel;
    wsel_e wsel_q, wsel;
    apu_dma_write_data_t wrbeat_q;

    logic map_v, map_r, map_cv, map_cr, lk_v, lk_r, lk_cv, lk_cr, inv_v, inv_r, inv_cv, inv_cr;
    logic cmd_v, cmd_r, cdv, cdr, ccv, ccr, crr, crdv, crdr, crel;
    logic sg_lv, sg_lr, sg_lcv, sg_lcr, sg_qv, sg_qr, sg_qcv, sg_qcr;
    logic fv, fr, fcr, fcan, sg_idle, sg_fault, sg_table;
    logic rd_v, rd_r, rdv, rdr, rdcv, rdcr, rd_idle, rd_fault;
    logic wr_v, wr_r, wdv, wdr, wcv, wcr, wr_idle, wr_fault;
    logic uv, ur, ucv, ucr, u_idle, u_fault;
    logic st_idle, st_held, st_fault;
    logic [31:0] crdoff;
    logic [63:0] crddata;
    apu_map_insert_t minst;
    apu_map_lookup_t look;
    apu_map_inval_t inval;
    apu_sg_load_t sgl;
    apu_sg_query_t sgq;
    apu_cmd_req_t creq;
    apu_dma_read_data_t cdata, rddata, wrdata;
    apu_map_cpl_t mcpl, lcpl, icpl, ccpl, ucpl;
    apu_dma_mapping_t lmap, list_m, back_m;
    apu_dma_read_cpl_t slcpl, sqcpl, fcpl, rdcpl, wrcpl;
    apu_sg_fragment_t frag;
    apu_dma_read_req_t rdreq, wrreq;
    apu_dma_mapping_t rdmap, wrmap;
    apu_used_req_t ureq;
    axi_req_t sg_req, rd_axi, wr_axi, q_axi;
    axi_rsp_t sg_rsp, rd_rsp, wr_rsp, q_rsp;

    assign kill = cancel_i || invalidate_i || !enable_i;
    assign children_idle = st_idle && sg_idle && rd_idle && wr_idle && u_idle;
    assign children_fault = st_fault || sg_fault || rd_fault || wr_fault || u_fault;
    assign idle_o = state_q == Idle && children_idle && !children_fault;
    assign bus_fault_o = children_fault;
    assign cmd_held_o = st_held;
    assign cmd_rd_ready_o = state_q == Idle && crr;
    assign cmd_rd_data_valid_o = state_q == Idle && crdv;
    assign cmd_rd_data_o = crddata;
    assign op_ready_o = idle_o && !kill && rst_ni;
    assign op_cpl_valid_o = state_q == Done;
    assign op_cpl_o = op_cpl_valid_o ? cpl_q : apu_map_cpl_t'('0);
    assign lookup_mapping_o = (op_cpl_valid_o && op_q == APU_MEM_MAP_LOOKUP &&
                               cpl_q.status == APU_DMA_OK) ? lmap_q : '0;

    assign minst = insert_i;
    assign look = lookup_i;
    assign inval = inval_i;
    assign sgl = sg_load_i;
    assign list_m = sg_list_i;
    assign back_m = sg_backing_i;
    assign sgq = sg_query_i;
    assign creq = cmd_i;
    assign ureq = used_i;

    assign map_v = state_q == Issue && op_q == APU_MEM_MAP_INSERT;
    assign lk_v  = state_q == Issue && op_q == APU_MEM_MAP_LOOKUP;
    assign inv_v = state_q == Issue && op_q == APU_MEM_MAP_INVAL;
    assign sg_lv = state_q == Issue && op_q == APU_MEM_SG_LOAD;
    assign sg_qv = state_q == Issue && op_q == APU_MEM_SG_XFER;
    assign uv    = state_q == Issue && op_q == APU_MEM_USED;
    assign crel  = state_q == Issue && op_q == APU_MEM_CMD_RELEASE;
    assign cmd_v = state_q == CmdIssue && !cmd_taken_q;
    assign rd_v  = (state_q == CmdIssue && !rd_taken_q) ||
                   (state_q == FragWait && !frag_q.write_access && !rd_taken_q);
    assign wr_v  = state_q == FragWait && frag_q.write_access && !frag_fail_q &&
                   st_held && frag_q.transfer_offset[2:0] == 0 && !rd_taken_q;
    assign cdv   = state_q == CmdPump && rdv;
    assign rdr   = (state_q == CmdPump && cdr) ||
                   (state_q == FragWait && !frag_q.write_access && rd_taken_q);
    assign wdv   = state_q == FragData;
    assign map_cr = state_q == WaitCpl && op_q == APU_MEM_MAP_INSERT;
    assign lk_cr  = state_q == WaitCpl && op_q == APU_MEM_MAP_LOOKUP;
    assign inv_cr = state_q == WaitCpl && op_q == APU_MEM_MAP_INVAL;
    assign sg_lcr = op_q == APU_MEM_SG_LOAD &&
                    (state_q == WaitCpl || state_q == Done);
    assign sg_qcr = op_q == APU_MEM_SG_XFER &&
                    (state_q == WaitCpl || state_q == FragIssue || state_q == FragWait ||
                     state_q == Done);
    assign ccr    = state_q == CmdWait;
    assign rdcr   = (state_q == CmdWait) ||
                    (state_q == FragWait && !frag_q.write_access && fcv && fcr);
    assign wcr    = state_q == FragWait && frag_q.write_access && fcv && fcr;
    assign ucr    = state_q == WaitCpl && op_q == APU_MEM_USED;
    assign fr     = state_q == FragIssue && fv;
    assign crdr   = state_q == FragData;

    assign rdreq = (op_q == APU_MEM_CMD_DMA) ? cmd_dma_i : dma_req_q;
    assign rdmap = (op_q == APU_MEM_CMD_DMA) ? cmd_map_i : frag_map_q;
    assign wrreq = dma_req_q;
    assign wrmap = frag_map_q;
    assign cdata = rddata;
    assign fcpl = frag_fail_q
                  ? apu_dma_read_cpl_t'{status: APU_DMA_STREAM, resource_id: frag_q.req.resource_id,
                      context_id: frag_q.req.context_id, epoch: frag_q.req.epoch, bytes: 0,
                      tag: frag_q.req.tag}
                  : (frag_q.write_access ? wrcpl : rdcpl);
    assign crdoff = frag_q.transfer_offset + sink_off_q;
    always_comb begin
      wrdata = '0;
      if (state_q == FragData && crdv) begin
        wrdata.data = crddata;
        wrdata.keep = (sink_off_q + 32'd8 >= frag_q.req.bytes)
                      ? 8'((1 << (frag_q.req.bytes - sink_off_q)) - 1) : 8'hff;
        wrdata.offset = sink_off_q;
        wrdata.last = sink_off_q + 32'd8 >= frag_q.req.bytes;
      end
    end

    g6lc_apu_storage #(.ApuCfg(ApuCfg)) i_storage (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .cancel_i, .invalidate_i,
      .map_valid_i(map_v), .map_ready_o(map_r), .map_i(minst),
      .map_cpl_valid_o(map_cv), .map_cpl_ready_i(map_cr), .map_cpl_o(mcpl),
      .lookup_valid_i(lk_v), .lookup_ready_o(lk_r), .lookup_i(look),
      .lookup_cpl_valid_o(lk_cv), .lookup_cpl_ready_i(lk_cr), .lookup_cpl_o(lcpl),
      .lookup_mapping_o(lmap),
      .inval_valid_i(inv_v), .inval_ready_o(inv_r), .inval_i(inval),
      .inval_cpl_valid_o(inv_cv), .inval_cpl_ready_i(inv_cr), .inval_cpl_o(icpl),
      .cmd_valid_i(cmd_v), .cmd_ready_o(cmd_r), .cmd_i(creq),
      .cmd_data_valid_i(cdv), .cmd_data_ready_o(cdr), .cmd_data_i(cdata),
      .cmd_cpl_valid_o(ccv), .cmd_cpl_ready_i(ccr), .cmd_cpl_o(ccpl),
      .cmd_rd_valid_i(crv || (state_q == Idle && cmd_rd_valid_i)),
      .cmd_rd_ready_o(crr), .cmd_rd_offset_i(crv ? crdoff : cmd_rd_offset_i),
      .cmd_rd_data_valid_o(crdv),
      .cmd_rd_data_ready_i(crv ? crdr : cmd_rd_data_ready_i),
      .cmd_rd_data_o(crddata),
      .cmd_release_i(crel), .idle_o(st_idle), .cmd_held_o(st_held), .bus_fault_o(st_fault)
    );
    g6lc_apu_sg #(.ApuCfg(ApuCfg)) i_sg (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .cancel_i, .invalidate_i,
      .load_valid_i(sg_lv), .load_ready_o(sg_lr), .load_i(sgl),
      .list_mapping_i(list_m), .backing_mapping_i(back_m),
      .load_cpl_valid_o(sg_lcv), .load_cpl_ready_i(sg_lcr), .load_cpl_o(slcpl),
      .query_valid_i(sg_qv), .query_ready_o(sg_qr), .query_i(sgq),
      .query_cpl_valid_o(sg_qcv), .query_cpl_ready_i(sg_qcr), .query_cpl_o(sqcpl),
      .fragment_valid_o(fv), .fragment_ready_i(fr), .fragment_o(frag),
      .fragment_cancel_o(fcan), .fragment_cpl_valid_i(fcv), .fragment_cpl_ready_o(fcr),
      .fragment_cpl_i(fcpl), .fragment_idle_i((rd_idle || rdcv) && (wr_idle || wcv)),
      .fragment_bus_fault_i(rd_fault || wr_fault),
      .table_valid_o(sg_table), .idle_o(sg_idle), .bus_fault_o(sg_fault),
      .axi_req_o(sg_req), .axi_rsp_i(sg_rsp)
    );
    g6lc_apu_dma_read #(.ApuCfg(ApuCfg)) i_read (
      .clk_i, .rst_ni, .testmode_i, .enable_i,
      .cancel_i(kill || (op_q == APU_MEM_SG_XFER && fcan)),
      .req_valid_i(rd_v), .req_ready_o(rd_r), .req_i(rdreq), .mapping_i(rdmap),
      .data_valid_o(rdv), .data_ready_i(rdr), .data_o(rddata),
      .cpl_valid_o(rdcv), .cpl_ready_i(rdcr), .cpl_o(rdcpl),
      .idle_o(rd_idle), .bus_fault_o(rd_fault), .axi_req_o(rd_axi), .axi_rsp_i(rd_rsp)
    );
    g6lc_apu_dma_write #(.ApuCfg(ApuCfg)) i_write (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .cancel_i(kill || fcan),
      .req_valid_i(wr_v), .req_ready_o(wr_r), .req_i(wrreq), .mapping_i(wrmap),
      .data_valid_i(wdv), .data_ready_o(wdr), .data_i(wrdata),
      .cpl_valid_o(wcv), .cpl_ready_i(wcr), .cpl_o(wrcpl),
      .idle_o(wr_idle), .bus_fault_o(wr_fault), .axi_req_o(wr_axi), .axi_rsp_i(wr_rsp)
    );
    g6lc_apu_queue #(.ApuCfg(ApuCfg)) i_queue (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .cancel_i(kill),
      .used_valid_i(uv), .used_ready_o(ur), .used_i(ureq),
      .used_cpl_valid_o(ucv), .used_cpl_ready_i(ucr), .used_cpl_o(ucpl),
      .idle_o(u_idle), .bus_fault_o(u_fault), .axi_req_o(q_axi), .axi_rsp_i(q_rsp)
    );

    assign rsel = rsel_q != RNone ? rsel_q :
                  (rd_axi.ar_valid ? RRd : sg_req.ar_valid ? RSg : RNone);
    assign wsel = wsel_q != WNone ? wsel_q :
                  ((q_axi.aw_valid || q_axi.w_valid) ? WQ :
                   (wr_axi.aw_valid || wr_axi.w_valid) ? WWr : WNone);
    always_comb begin
      axi_req_o = '0;
      sg_rsp = '0; rd_rsp = '0; wr_rsp = '0; q_rsp = '0;
      unique case (rsel)
        RRd: begin
          axi_req_o.ar = rd_axi.ar; axi_req_o.ar_valid = rd_axi.ar_valid;
          rd_rsp.ar_ready = axi_rsp_i.ar_ready;
        end
        RSg: begin
          axi_req_o.ar = sg_req.ar; axi_req_o.ar_valid = sg_req.ar_valid;
          sg_rsp.ar_ready = axi_rsp_i.ar_ready;
        end
        default: ;
      endcase
      // R data only after the AR grant is registered, so a master in Address
      // cannot see RVALID while ARREADY is low (that is a dma_read protocol fault).
      unique case (rsel_q)
        RRd: begin
          axi_req_o.r_ready = rd_axi.r_ready;
          rd_rsp.r_valid = axi_rsp_i.r_valid;
          rd_rsp.r = axi_rsp_i.r;
        end
        RSg: begin
          axi_req_o.r_ready = sg_req.r_ready;
          sg_rsp.r_valid = axi_rsp_i.r_valid;
          sg_rsp.r = axi_rsp_i.r;
        end
        default: ;
      endcase
      unique case (wsel)
        WWr: begin
          axi_req_o.aw = wr_axi.aw; axi_req_o.aw_valid = wr_axi.aw_valid;
          axi_req_o.w = wr_axi.w; axi_req_o.w_valid = wr_axi.w_valid;
          axi_req_o.b_ready = wr_axi.b_ready;
          wr_rsp.aw_ready = axi_rsp_i.aw_ready; wr_rsp.w_ready = axi_rsp_i.w_ready;
          wr_rsp.b_valid = axi_rsp_i.b_valid; wr_rsp.b = axi_rsp_i.b;
        end
        WQ: begin
          axi_req_o.aw = q_axi.aw; axi_req_o.aw_valid = q_axi.aw_valid;
          axi_req_o.w = q_axi.w; axi_req_o.w_valid = q_axi.w_valid;
          axi_req_o.b_ready = q_axi.b_ready;
          q_rsp.aw_ready = axi_rsp_i.aw_ready; q_rsp.w_ready = axi_rsp_i.w_ready;
          q_rsp.b_valid = axi_rsp_i.b_valid; q_rsp.b = axi_rsp_i.b;
        end
        default: ;
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; op_q <= APU_MEM_NONE; cpl_q <= '0; lmap_q <= '0;
        frag_q <= '0; frag_map_q <= '0; dma_req_q <= '0; sink_off_q <= '0;
        wrbeat_q <= '0; rsel_q <= RNone; wsel_q <= WNone; crv <= 1'b0; fcv <= 1'b0;
        frag_fail_q <= 1'b0; cmd_taken_q <= 1'b0; rd_taken_q <= 1'b0;
        dma_done_q <= 1'b0; st_done_q <= 1'b0;
      end else begin
        if (rsel_q == RNone && rsel != RNone && axi_req_o.ar_valid && axi_rsp_i.ar_ready)
          rsel_q <= rsel;
        else if (rsel_q != RNone && axi_rsp_i.r_valid && axi_req_o.r_ready && axi_rsp_i.r.last)
          rsel_q <= RNone;
        if (wsel_q == WNone && wsel != WNone &&
            ((axi_req_o.aw_valid && axi_rsp_i.aw_ready) ||
             (axi_req_o.w_valid && axi_rsp_i.w_ready)))
          wsel_q <= wsel;
        else if (wsel_q != WNone && axi_rsp_i.b_valid && axi_req_o.b_ready)
          wsel_q <= WNone;
        if (fcv && fcr) fcv <= 1'b0;
        if (crv && crr) crv <= 1'b0;
        unique case (state_q)
          Idle: if (op_valid_i && op_ready_o) begin
            op_q <= op_i; cpl_q <= '0; sink_off_q <= '0;
            cmd_taken_q <= 1'b0; rd_taken_q <= 1'b0; frag_fail_q <= 1'b0;
            dma_done_q <= 1'b0; st_done_q <= 1'b0;
            state_q <= (op_i == APU_MEM_CMD_DMA) ? CmdIssue : Issue;
          end
          Issue: begin
            if (kill) begin cpl_q.status <= APU_DMA_CANCELLED; state_q <= Done; end
            else if (op_q == APU_MEM_CMD_RELEASE) begin
              cpl_q.status <= APU_DMA_OK; state_q <= Done;
            end else if ((op_q == APU_MEM_MAP_INSERT && map_r) ||
                     (op_q == APU_MEM_MAP_LOOKUP && lk_r) ||
                     (op_q == APU_MEM_MAP_INVAL && inv_r) ||
                     (op_q == APU_MEM_SG_LOAD && sg_lr) ||
                     (op_q == APU_MEM_SG_XFER && sg_qr) ||
                     (op_q == APU_MEM_USED && ur))
              state_q <= (op_q == APU_MEM_SG_XFER) ? FragIssue : WaitCpl;
          end
          WaitCpl: begin
            if (op_q == APU_MEM_MAP_INSERT && map_cv) begin cpl_q <= mcpl; state_q <= Done; end
            if (op_q == APU_MEM_MAP_LOOKUP && lk_cv) begin
              cpl_q <= lcpl; lmap_q <= lmap; state_q <= Done;
            end
            if (op_q == APU_MEM_MAP_INVAL && inv_cv) begin cpl_q <= icpl; state_q <= Done; end
            if (op_q == APU_MEM_SG_LOAD && sg_lcv) begin
              cpl_q.status <= slcpl.status; cpl_q.bytes <= slcpl.bytes; cpl_q.tag <= slcpl.tag;
              state_q <= Done;
            end
            if (op_q == APU_MEM_USED && ucv) begin cpl_q <= ucpl; state_q <= Done; end
          end
          FragIssue: begin
            if (kill) begin cpl_q.status <= APU_DMA_CANCELLED; state_q <= Done; end
            else if (sg_qcv) begin
              cpl_q.status <= sqcpl.status; cpl_q.bytes <= sqcpl.bytes; cpl_q.tag <= sqcpl.tag;
              state_q <= Done;
            end else if (fv && fr) begin
              frag_q <= frag; frag_map_q <= frag.mapping; dma_req_q <= frag.req;
              sink_off_q <= '0; rd_taken_q <= 1'b0;
              frag_fail_q <= frag.write_access && !(st_held && frag.transfer_offset[2:0] == 0);
              if (frag.write_access && st_held && frag.transfer_offset[2:0] == 0) begin
                crv <= 1'b1; state_q <= FragData;
              end else state_q <= FragWait;
            end
          end
          FragData: begin
            if (kill) begin cpl_q.status <= APU_DMA_CANCELLED; state_q <= Done; end
            else if (crdv && wdr) begin
              if (sink_off_q + 32'd8 >= frag_q.req.bytes) state_q <= FragWait;
              else begin sink_off_q <= sink_off_q + 32'd8; crv <= 1'b1; end
            end
          end
          FragWait: begin
            if (rd_v && rd_r) rd_taken_q <= 1'b1;
            if (wr_v && wr_r) rd_taken_q <= 1'b1;
            if ((frag_q.write_access && (wcv || frag_fail_q)) ||
                (!frag_q.write_access && rdcv))
              fcv <= 1'b1;
            if (fcv && fcr) state_q <= FragIssue;
          end
          CmdIssue: begin
            if (cmd_v && cmd_r) cmd_taken_q <= 1'b1;
            if (rd_v && rd_r) rd_taken_q <= 1'b1;
            if (kill) begin cpl_q.status <= APU_DMA_CANCELLED; state_q <= Done; end
            else if ((cmd_taken_q || (cmd_v && cmd_r)) && (rd_taken_q || (rd_v && rd_r)))
              state_q <= CmdPump;
          end
          CmdPump: begin
            if (rdcv) dma_done_q <= 1'b1;
            if (ccv) st_done_q <= 1'b1;
            if (kill) begin cpl_q.status <= APU_DMA_CANCELLED; state_q <= Done; end
            else if (rd_fault) begin cpl_q.status <= APU_DMA_PROTOCOL; state_q <= Done; end
            else if (rdcv || st_done_q || (rdv && cdr && rddata.last)) state_q <= CmdWait;
          end
          CmdWait: begin
            if (rdcv) dma_done_q <= 1'b1;
            if (ccv) begin st_done_q <= 1'b1; cpl_q <= ccpl; end
            if (rd_fault) begin cpl_q.status <= APU_DMA_PROTOCOL; state_q <= Done; end
            else if ((ccv || st_done_q) && (rdcv || dma_done_q)) state_q <= Done;
          end
          Done: if (op_cpl_ready_i) state_q <= Idle;
          default: state_q <= Idle;
        endcase
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      op_cpl_valid_o && !op_cpl_ready_i |=> op_cpl_valid_o && $stable(op_cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q != Idle |-> !op_ready_o);
    `endif
  end
endmodule
