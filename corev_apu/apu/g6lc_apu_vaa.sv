// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// VqTakeAlloc guest beats on 64-bit AXI. 4-byte windows use SIZE=2;
// 8-byte and longer windows use SIZE=3 INCR. Enable=0 elaborates no
// datapath. Does not edit virtio_mmio, g6lc_apu_vgpu_avail, or
// g6lc_apu_sys. FeatureVirgl stays illegal. ApuCfg.NumCapsets
// stays 0.

// VqAxiAlloc (vaa): VqTakeAlloc guest beats on 64-bit AXI. Default-off. FeatureVirgl stays illegal.
// Interplay: VqAxiAlloc (vaa) --> VqTakeAlloc (vqa) ==> AXI. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vaa
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b0,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vaa_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vaa_cpl_t cpl_o,
  output apu_vaa_t vaa_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output axi_req_t axi_req_o,
  input  axi_rsp_t axi_rsp_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign notify_clear_o = '0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vaa_o = '0;
    assign irq_o = 1'b0;
    assign isr_o = '0;
    assign axi_req_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | ack_valid_i |
                    (|req_i) | (|in_a_i) | (|in_b_i) | (|ack_i) |
                    (|notify_pending_i) | (|vq0_i) | (|vq1_i) | (|axi_rsp_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Ar, Rbeat, RdHold, Aw, Wbeat, Bwait, WrHold } xfer_e;
    xfer_e xfer_q;
    logic [63:0] addr_q;
    logic [31:0] len_q;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] data_q, wr_data_q;
    logic [2:0] beat_q, nbeat;
    logic [2:0] asize;
    logic [7:0] alen;
    logic rd_v, rd_r, rsp_v, rsp_r, rsp_ok;
    logic wr_v, wr_r, wr_rsp_v, wr_rsp_r, wr_ok;
    logic [63:0] rd_addr, wr_addr;
    logic [31:0] rd_len, wr_len;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_bus, rsp_data;
    apu_vqa_cpl_t vqa_c;
    apu_vqa_t vqa_rec;

    assign asize = (len_q <= 32'd4) ? 3'd2 : 3'd3;
    assign nbeat = (len_q <= 32'd4) ? 3'd1 : 3'(len_q[7:3]);
    assign alen = 8'(nbeat - 3'd1);
    assign rd_r = (xfer_q == Idle);
    assign wr_r = (xfer_q == Idle) && !rd_v;
    assign rsp_data = data_q;
    assign rsp_v = (xfer_q == RdHold);
    assign wr_rsp_v = (xfer_q == WrHold);
    always_comb begin
      axi_req_o = '0;
      axi_req_o.ar_valid = (xfer_q == Ar);
      axi_req_o.ar.addr = addr_q;
      axi_req_o.ar.len = alen;
      axi_req_o.ar.size = asize;
      axi_req_o.ar.burst = axi_pkg::BURST_INCR;
      axi_req_o.r_ready = (xfer_q == Rbeat);
      axi_req_o.aw_valid = (xfer_q == Aw);
      axi_req_o.aw.addr = addr_q;
      axi_req_o.aw.len = alen;
      axi_req_o.aw.size = asize;
      axi_req_o.aw.burst = axi_pkg::BURST_INCR;
      axi_req_o.w_valid = (xfer_q == Wbeat);
      axi_req_o.w.last = (beat_q + 3'd1) == nbeat;
      axi_req_o.w.data = (asize == 3'd2) ?
          (addr_q[2] ? {wr_data_q[31:0], 32'd0} : {32'd0, wr_data_q[31:0]}) :
          wr_data_q[{beat_q[1:0], 6'd0} +: 64];
      axi_req_o.w.strb = (asize == 3'd2) ?
          (addr_q[2] ? 8'hF0 : 8'h0F) : 8'hFF;
      axi_req_o.b_ready = (xfer_q == Bwait);
    end

    g6lc_apu_vqa #(.Enable(1'b1)) i_vqa (
      .clk_i, .rst_ni,
      .req_valid_i, .req_ready_o, .req_i(req_i.vqa),
      .in_a_i, .in_b_i,
      .vq0_i, .vq1_i,
      .notify_pending_i, .notify_clear_o,
      .cpl_valid_o, .cpl_ready_i, .cpl_o(vqa_c), .vqa_o(vqa_rec),
      .irq_o, .isr_o, .ack_valid_i, .ack_i,
      .rd_valid_o(rd_v), .rd_ready_i(rd_r), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
      .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_r),
      .rd_rsp_ok_i(rsp_ok), .rd_rsp_addr_i(addr_q), .rd_rsp_len_i(len_q),
      .rd_rsp_data_i(rsp_data),
      .wr_valid_o(wr_v), .wr_ready_i(wr_r), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
      .wr_data_o(wr_bus),
      .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_r), .wr_rsp_ok_i(wr_ok)
    );

    assign cpl_o = '{status: apu_vaa_status_e'(vqa_c.status)};
    assign vaa_o = '{
      valid:       vqa_rec.valid,
      bound:       vqa_rec.bound,
      capset:      vqa_rec.capset,
      info:        vqa_rec.info,
      alloc:       vqa_rec.alloc,
      dispatch:    vqa_rec.dispatch,
      irq:         vqa_rec.irq,
      clear:       vqa_rec.clear,
      count:       vqa_rec.count,
      cfg_rdata:   vqa_rec.cfg_rdata,
      num_capsets: vqa_rec.num_capsets,
      capset_id:   vqa_rec.capset_id,
      max_version: vqa_rec.max_version,
      max_size:    vqa_rec.max_size,
      type_word:   vqa_rec.type_word,
      cmd:         vqa_rec.cmd,
      result:      vqa_rec.result,
      handle:      vqa_rec.handle,
      resp_word0:  vqa_rec.resp_word0,
      used_idx:    vqa_rec.used_idx,
      resp_addr:   vqa_rec.resp_addr
    };

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        xfer_q <= Idle;
        addr_q <= '0;
        len_q <= '0;
        data_q <= '0;
        wr_data_q <= '0;
        beat_q <= '0;
        rsp_ok <= 1'b1;
        wr_ok <= 1'b1;
      end else unique case (xfer_q)
        Idle: if (rd_v) begin
          addr_q <= rd_addr;
          len_q <= rd_len;
          data_q <= '0;
          beat_q <= '0;
          rsp_ok <= 1'b1;
          xfer_q <= Ar;
        end else if (wr_v) begin
          addr_q <= wr_addr;
          len_q <= wr_len;
          wr_data_q <= wr_bus;
          beat_q <= '0;
          wr_ok <= 1'b1;
          xfer_q <= Aw;
        end
        Ar: if (axi_rsp_i.ar_ready) xfer_q <= Rbeat;
        Rbeat: if (axi_rsp_i.r_valid) begin
          if (asize == 3'd2)
            data_q[31:0] <= addr_q[2] ? axi_rsp_i.r.data[63:32] :
                                        axi_rsp_i.r.data[31:0];
          else
            data_q[{beat_q[1:0], 6'd0} +: 64] <= axi_rsp_i.r.data;
          if (axi_rsp_i.r.resp != axi_pkg::RESP_OKAY) begin
            rsp_ok <= 1'b0;
            xfer_q <= RdHold;
          end else if (axi_rsp_i.r.last || (beat_q + 3'd1) == nbeat) begin
            beat_q <= '0;
            xfer_q <= RdHold;
          end else beat_q <= beat_q + 3'd1;
        end
        RdHold: if (rsp_r) xfer_q <= Idle;
        Aw: if (axi_rsp_i.aw_ready) xfer_q <= Wbeat;
        Wbeat: if (axi_rsp_i.w_ready) begin
          if ((beat_q + 3'd1) == nbeat) xfer_q <= Bwait;
          else beat_q <= beat_q + 3'd1;
        end
        Bwait: if (axi_rsp_i.b_valid) begin
          wr_ok <= (axi_rsp_i.b.resp == axi_pkg::RESP_OKAY);
          xfer_q <= WrHold;
        end
        WrHold: if (wr_rsp_r) xfer_q <= Idle;
        default: xfer_q <= Idle;
      endcase
    end
  end
endmodule

// VqAxiAlloc (vaa) enable-0 fixture: VqTakeAlloc guest beats on 64-bit AXI.
module g6lc_apu_vaa_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b0,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vaa_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vaa_cpl_t cpl_o,
  output apu_vaa_t vaa_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output axi_req_t axi_req_o,
  input  axi_rsp_t axi_rsp_i
);
  g6lc_apu_vaa #(.Enable(Enable)) i_dut (.*);
endmodule
