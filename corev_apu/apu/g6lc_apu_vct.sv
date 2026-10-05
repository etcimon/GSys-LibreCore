// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Private virtio-gpu control face: virtio_gpu_config.num_capsets
// reads as 1 and GET_CAPSET_INFO index 0 is Venus id 4. QueueNotify
// of control queue 0 fires QueueType. Cursor queue 1 faults.
// ApuCfg.NumCapsets stays 0; this is not virtio_mmio advertisement.
// Enable=0 elaborates no datapath. Does not edit g6lc_apu_vgpu_avail
// or g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusCtrl (vct): Private Venus num_capsets=1 and QueueNotify into QueueType. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCtrl (vct) --> VenusCapset (vcap) --> QueueType (qty). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vct
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vct_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vct_cpl_t cpl_o,
  output apu_vct_t vct_o,
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
    assign vct_o = '0;
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
    typedef enum logic [2:0] {
      Idle, FireVcap, WaitVcap, FireQty, WaitQty, Done
    } state_e;
    state_e state_q;
    apu_vct_cpl_t cpl_q;
    apu_vct_t rec_q;
    apu_vct_req_t req_q;
    logic cfg_ok;
    logic [31:0] cfg_word;
    logic vcap_req_v, vcap_rdy, vcap_cpl, vcap_ack;
    logic qty_req_v, qty_rdy, qty_cpl, qty_ack, qty_irq;
    logic [31:0] qty_isr;
    apu_vcap_req_t vcap_req;
    apu_vcap_cpl_t vcap_c;
    apu_vcap_t vcap_rec;
    logic [31:0] vcap_blob_unused;
    apu_qty_req_t qty_req;
    apu_qty_cpl_t qty_c;
    apu_qty_t qty_rec;

    assign req_ready_o = state_q == Idle && rst_ni && vcap_rdy && qty_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vct_cpl_t'('0);
    assign vct_o = rec_q;
    assign irq_o = qty_irq;
    assign isr_o = qty_isr;
    assign cfg_ok = (req_i.cfg_addr == VCFG_NUM_CAPSETS) ||
                    (req_i.cfg_addr == VCFG_NUM_SCANOUTS) ||
                    (req_i.cfg_addr == VCFG_EVENTS_READ);
    assign cfg_word = (req_i.cfg_addr == VCFG_NUM_CAPSETS) ?
                      32'(APU_VCT_NUM_CAPSETS) : 32'd0;
    assign vcap_req_v = state_q == FireVcap;
    assign vcap_ack = state_q == WaitVcap;
    assign qty_req_v = state_q == FireQty;
    assign qty_ack = state_q == WaitQty;
    assign vcap_req.op = APU_VCAP_INFO;
    assign vcap_req.capset_id = APU_VGPU_CAPSET_VENUS;
    assign vcap_req.capset_version = 32'd0;
    assign qty_req = req_q.qty;

    g6lc_apu_vcap #(.Enable(1'b1)) i_vcap (
      .clk_i, .rst_ni,
      .req_valid_i(vcap_req_v), .req_ready_o(vcap_rdy), .req_i(vcap_req),
      .cpl_valid_o(vcap_cpl), .cpl_ready_i(vcap_ack), .cpl_o(vcap_c),
      .vcap_o(vcap_rec),
      .blob_idx_i(6'd0), .blob_word_o(vcap_blob_unused)
    );

    g6lc_apu_qty #(.Enable(1'b1)) i_qty (
      .clk_i, .rst_ni,
      .req_valid_i(qty_req_v), .req_ready_o(qty_rdy), .req_i(qty_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qty_cpl), .cpl_ready_i(qty_ack), .cpl_o(qty_c), .qty_o(qty_rec),
      .irq_o(qty_irq), .isr_o(qty_isr), .ack_valid_i, .ack_i,
      .rd_valid_o, .rd_ready_i, .rd_addr_o, .rd_len_o,
      .rd_rsp_valid_i, .rd_rsp_ready_o,
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o, .wr_ready_i, .wr_addr_o, .wr_len_o, .wr_data_o,
      .wr_rsp_valid_i, .wr_rsp_ready_o, .wr_rsp_ok_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          unique case (req_i.op)
            APU_VCT_CFG: begin
              if (!cfg_ok) begin
                cpl_q <= '{status: APU_VCT_FAULT};
              end else begin
                rec_q <= '{
                  valid:       1'b1,
                  capset:      1'b0,
                  info:        1'b0,
                  dispatch:    1'b0,
                  irq:         1'b0,
                  cfg_rdata:   cfg_word,
                  num_capsets: 32'(APU_VCT_NUM_CAPSETS),
                  capset_id:   (req_i.cfg_addr == VCFG_NUM_CAPSETS) ?
                               APU_VGPU_CAPSET_VENUS : 32'd0,
                  max_version: 32'd0,
                  max_size:    32'd0,
                  type_word:   32'd0,
                  cmd:         32'd0,
                  result:      32'd0,
                  handle:      32'd0,
                  resp_word0:  32'd0,
                  used_idx:    16'd0,
                  resp_addr:   64'd0
                };
                cpl_q <= '{status: APU_VCT_OK};
              end
              state_q <= Done;
            end
            APU_VCT_INFO: begin
              if (req_i.capset_index != 32'd0) begin
                cpl_q <= '{status: APU_VCT_FAULT};
                state_q <= Done;
              end else state_q <= FireVcap;
            end
            APU_VCT_NOTIFY: begin
              if (req_i.queue_sel != 32'd0) begin
                cpl_q <= '{status: APU_VCT_FAULT};
                state_q <= Done;
              end else state_q <= FireQty;
            end
            default: begin
              cpl_q <= '{status: APU_VCT_FAULT};
              state_q <= Done;
            end
          endcase
        end
        FireVcap: if (vcap_rdy) state_q <= WaitVcap;
        WaitVcap: if (vcap_cpl) begin
          if (vcap_c.status != APU_VCAP_OK) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_VCT_FAULT};
          end else begin
            rec_q <= '{
              valid:       1'b1,
              capset:      1'b0,
              info:        1'b1,
              dispatch:    1'b0,
              irq:         1'b0,
              cfg_rdata:   32'd0,
              num_capsets: 32'(APU_VCT_NUM_CAPSETS),
              capset_id:   vcap_rec.capset_id,
              max_version: vcap_rec.max_version,
              max_size:    vcap_rec.max_size,
              type_word:   32'd0,
              cmd:         32'd0,
              result:      32'd0,
              handle:      32'd0,
              resp_word0:  32'd0,
              used_idx:    16'd0,
              resp_addr:   64'd0
            };
            cpl_q <= '{status: APU_VCT_OK};
          end
          state_q <= Done;
        end
        FireQty: if (qty_rdy) state_q <= WaitQty;
        WaitQty: if (qty_cpl) begin
          rec_q <= '{
            valid:       qty_rec.valid,
            capset:      qty_rec.capset,
            info:        qty_rec.info,
            dispatch:    qty_rec.dispatch,
            irq:         qty_rec.irq,
            cfg_rdata:   32'd0,
            num_capsets: 32'(APU_VCT_NUM_CAPSETS),
            capset_id:   qty_rec.capset_id,
            max_version: 32'd0,
            max_size:    32'd0,
            type_word:   qty_rec.type_word,
            cmd:         qty_rec.cmd,
            result:      qty_rec.result,
            handle:      qty_rec.handle,
            resp_word0:  qty_rec.resp_word0,
            used_idx:    qty_rec.used_idx,
            resp_addr:   qty_rec.resp_addr
          };
          cpl_q <= '{status: apu_vct_status_e'(qty_c.status)};
          state_q <= Done;
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// VenusCtrl (vct) enable-0 fixture: private Venus config and QueueNotify.
module g6lc_apu_vct_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vct_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vct_cpl_t cpl_o,
  output apu_vct_t vct_o,
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
  g6lc_apu_vct #(.Enable(Enable)) i_dut (.*);
endmodule
