// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Private virtio-gpu control face: virtio_gpu_config.num_capsets
// reads as 1 and GET_CAPSET_INFO index 0 is Venus id 4. QueueNotify
// of control queue 0 fires QueueTypeBegin. Cursor queue 1 faults.
// ApuCfg.NumCapsets stays 0; this is not virtio_mmio advertisement.
// Enable=0 elaborates no datapath. Does not edit g6lc_apu_vgpu_avail
// or g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusCtrlBegin (vcb): Private Venus num_capsets=1 and QueueNotify into QueueTypeBegin. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCtrlBegin (vcb) --> VenusCapset (vcap) --> QueueTypeBegin (qtb). --? VenusCtrlAlloc (vca) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vcb
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vcb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vcb_cpl_t cpl_o,
  output apu_vcb_t vcb_o,
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
    assign vcb_o = '0;
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
      Idle, FireVcap, WaitVcap, FireQtb, WaitQtb, Done
    } state_e;
    state_e state_q;
    apu_vcb_cpl_t cpl_q;
    apu_vcb_t rec_q;
    apu_vcb_req_t req_q;
    logic cfg_ok;
    logic [31:0] cfg_word;
    logic vcap_req_v, vcap_rdy, vcap_cpl, vcap_ack;
    logic qtb_req_v, qtb_rdy, qtb_cpl, qtb_ack, qtb_irq;
    logic [31:0] qtb_isr;
    apu_vcap_req_t vcap_req;
    apu_vcap_cpl_t vcap_c;
    apu_vcap_t vcap_rec;
    logic [31:0] vcap_blob_unused;
    apu_qtb_req_t qtb_req;
    apu_qtb_cpl_t qtb_c;
    apu_qtb_t qtb_rec;

    assign req_ready_o = state_q == Idle && rst_ni && vcap_rdy && qtb_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vcb_cpl_t'('0);
    assign vcb_o = rec_q;
    assign irq_o = qtb_irq;
    assign isr_o = qtb_isr;
    assign cfg_ok = (req_i.cfg_addr == VCFG_NUM_CAPSETS) ||
                    (req_i.cfg_addr == VCFG_NUM_SCANOUTS) ||
                    (req_i.cfg_addr == VCFG_EVENTS_READ);
    assign cfg_word = (req_i.cfg_addr == VCFG_NUM_CAPSETS) ?
                      32'(APU_VCB_NUM_CAPSETS) : 32'd0;
    assign vcap_req_v = state_q == FireVcap;
    assign vcap_ack = state_q == WaitVcap;
    assign qtb_req_v = state_q == FireQtb;
    assign qtb_ack = state_q == WaitQtb;
    assign vcap_req.op = APU_VCAP_INFO;
    assign vcap_req.capset_id = APU_VGPU_CAPSET_VENUS;
    assign vcap_req.capset_version = 32'd0;
    assign qtb_req = req_q.qtb;

    g6lc_apu_vcap #(.Enable(1'b1)) i_vcap (
      .clk_i, .rst_ni,
      .req_valid_i(vcap_req_v), .req_ready_o(vcap_rdy), .req_i(vcap_req),
      .cpl_valid_o(vcap_cpl), .cpl_ready_i(vcap_ack), .cpl_o(vcap_c),
      .vcap_o(vcap_rec),
      .blob_idx_i(6'd0), .blob_word_o(vcap_blob_unused)
    );

    g6lc_apu_qtb #(.Enable(1'b1)) i_qtb (
      .clk_i, .rst_ni,
      .req_valid_i(qtb_req_v), .req_ready_o(qtb_rdy), .req_i(qtb_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qtb_cpl), .cpl_ready_i(qtb_ack), .cpl_o(qtb_c), .qtb_o(qtb_rec),
      .irq_o(qtb_irq), .isr_o(qtb_isr), .ack_valid_i, .ack_i,
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
            APU_VCB_CFG: begin
              if (!cfg_ok) begin
                cpl_q <= '{status: APU_VCB_FAULT};
              end else begin
                rec_q <= '{
                  valid:       1'b1,
                  capset:      1'b0,
                  info:        1'b0,
                  alloc:       1'b0,
                  begin_cmd:   1'b0,
                  dispatch:    1'b0,
                  irq:         1'b0,
                  cfg_rdata:   cfg_word,
                  num_capsets: 32'(APU_VCB_NUM_CAPSETS),
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
                cpl_q <= '{status: APU_VCB_OK};
              end
              state_q <= Done;
            end
            APU_VCB_INFO: begin
              if (req_i.capset_index != 32'd0) begin
                cpl_q <= '{status: APU_VCB_FAULT};
                state_q <= Done;
              end else state_q <= FireVcap;
            end
            APU_VCB_NOTIFY: begin
              if (req_i.queue_sel != 32'd0) begin
                cpl_q <= '{status: APU_VCB_FAULT};
                state_q <= Done;
              end else state_q <= FireQtb;
            end
            default: begin
              cpl_q <= '{status: APU_VCB_FAULT};
              state_q <= Done;
            end
          endcase
        end
        FireVcap: if (vcap_rdy) state_q <= WaitVcap;
        WaitVcap: if (vcap_cpl) begin
          if (vcap_c.status != APU_VCAP_OK) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_VCB_FAULT};
          end else begin
            rec_q <= '{
              valid:       1'b1,
              capset:      1'b0,
              info:        1'b1,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              dispatch:    1'b0,
              irq:         1'b0,
              cfg_rdata:   32'd0,
              num_capsets: 32'(APU_VCB_NUM_CAPSETS),
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
            cpl_q <= '{status: APU_VCB_OK};
          end
          state_q <= Done;
        end
        FireQtb: if (qtb_rdy) state_q <= WaitQtb;
        WaitQtb: if (qtb_cpl) begin
          rec_q <= '{
            valid:       qtb_rec.valid,
            capset:      qtb_rec.capset,
            info:        qtb_rec.info,
            alloc:       qtb_rec.alloc,
            begin_cmd:   qtb_rec.begin_cmd,
            dispatch:    qtb_rec.dispatch,
            irq:         qtb_rec.irq,
            cfg_rdata:   32'd0,
            num_capsets: 32'(APU_VCB_NUM_CAPSETS),
            capset_id:   qtb_rec.capset_id,
            max_version: 32'd0,
            max_size:    32'd0,
            type_word:   qtb_rec.type_word,
            cmd:         qtb_rec.cmd,
            result:      qtb_rec.result,
            handle:      qtb_rec.handle,
            resp_word0:  qtb_rec.resp_word0,
            used_idx:    qtb_rec.used_idx,
            resp_addr:   qtb_rec.resp_addr
          };
          cpl_q <= '{status: apu_vcb_status_e'(qtb_c.status)};
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

// VenusCtrlBegin (vcb) enable-0 fixture: private Venus config and QueueNotify.
module g6lc_apu_vcb_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vcb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vcb_cpl_t cpl_o,
  output apu_vcb_t vcb_o,
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
  g6lc_apu_vcb #(.Enable(Enable)) i_dut (.*);
endmodule
