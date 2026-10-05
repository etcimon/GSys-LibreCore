// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// GET_CAPSET_INFO and GET_CAPSET for VIRTIO_GPU_CAPSET_VENUS (4).
// The blob is virgl_renderer_capset_venus (40 words). Virgl id 1 is a
// fault. NumCapsets stays 0 on virtio_gpu_config. RESOURCE_BLOB and
// CONTEXT_INIT stay outside APU_IMPL_FEATURES. Enable=0 elaborates no
// datapath. Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusCapset (vcap): GET_CAPSET_INFO/GET_CAPSET for Venus id 4. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCapset (vcap) --? CapsetGet (cap) --? HostVisible (hvis) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vcap
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vcap_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vcap_cpl_t cpl_o,
  output apu_vcap_t vcap_o,
  input  logic [5:0] blob_idx_i,
  output logic [31:0] blob_word_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vcap_o = '0;
    assign blob_word_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                    (|req_i) | (|blob_idx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vcap_cpl_t cpl_q;
    apu_vcap_t vcap_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vcap_cpl_t'('0);
    assign vcap_o = vcap_q;
    assign blob_word_o = (vcap_q.valid && blob_idx_i < 6'(APU_VCAP_WORDS)) ?
                         apu_vcap_word(blob_idx_i) : 32'h0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vcap_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (req_i.capset_id != APU_VGPU_CAPSET_VENUS ||
              (req_i.op == APU_VCAP_GET && req_i.capset_version > 32'd1)) begin
            cpl_q.status <= APU_VCAP_FAULT;
          end else begin
            vcap_q.valid <= (req_i.op == APU_VCAP_GET);
            vcap_q.capset_id <= APU_VGPU_CAPSET_VENUS;
            vcap_q.max_version <= 32'd1;
            vcap_q.max_size <= 32'(APU_VCAP_BYTES);
            cpl_q.status <= APU_VCAP_OK;
          end
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

// VenusCapset (vcap) enable-0 fixture: Venus id 4 INFO/GET.
module g6lc_apu_vcap_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vcap_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vcap_cpl_t cpl_o,
  output apu_vcap_t vcap_o,
  input  logic [5:0] blob_idx_i,
  output logic [31:0] blob_word_o
);
  g6lc_apu_vcap #(.Enable(Enable)) i_dut (.*);
endmodule
