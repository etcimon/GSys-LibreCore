// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// HOST_VISIBLE blob create/map into the virtio-mmio SHM window, and
// CTX_CREATE with context_init capset Venus (4). Virgl capset 1 is a
// fault. RESOURCE_BLOB and CONTEXT_INIT stay outside APU_IMPL_FEATURES.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.
// FeatureVirgl stays illegal.

// HostVisible (hvis): RESOURCE_CREATE_BLOB map into SHM and CTX_CREATE context_init Venus. Default-off. FeatureVirgl stays illegal.
// Interplay: HostVisible (hvis) --? HostVisibleShm (shm) --? ApuSys. Diagnostic TB client. See AGENTS-impl-interplays.md.
module g6lc_apu_hvis
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_hvis_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hvis_cpl_t cpl_o,
  output apu_hvis_t hvis_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign hvis_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|req_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_hvis_cpl_t cpl_q;
    apu_hvis_t hvis_q;
    logic blob_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_hvis_cpl_t'('0);
    assign hvis_o = hvis_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        hvis_q <= '0;
        blob_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          unique case (req_i.op)
            APU_HVIS_BLOB: begin
              if (blob_q || req_i.resource_id == 32'd0 ||
                  req_i.size == 64'd0 || req_i.size > APU_SHM_BYTES ||
                  req_i.size[11:0] != 12'd0 ||
                  req_i.blob_mem != APU_BLOB_MEM_HOST3D ||
                  req_i.blob_flags != APU_BLOB_FLAG_MAPPABLE) begin
                cpl_q.status <= APU_HVIS_FAULT;
              end else begin
                blob_q <= 1'b1;
                hvis_q.resource_id <= req_i.resource_id;
                hvis_q.size <= req_i.size;
                hvis_q.map_offset <= '0;
                cpl_q.status <= APU_HVIS_OK;
              end
              state_q <= Done;
            end
            APU_HVIS_MAP: begin
              if (!blob_q || req_i.map_offset[11:0] != 12'd0 ||
                  req_i.map_offset >= APU_SHM_BYTES ||
                  hvis_q.size > APU_SHM_BYTES - req_i.map_offset) begin
                cpl_q.status <= APU_HVIS_FAULT;
              end else begin
                hvis_q.map_offset <= req_i.map_offset;
                hvis_q.valid <= 1'b1;
                cpl_q.status <= APU_HVIS_OK;
              end
              state_q <= Done;
            end
            APU_HVIS_CTX: begin
              if ((req_i.context_init & 32'hff) != APU_VGPU_CAPSET_VENUS ||
                  req_i.ctx_id == 32'd0) begin
                cpl_q.status <= APU_HVIS_FAULT;
              end else begin
                hvis_q.ctx_id <= req_i.ctx_id;
                hvis_q.capset_id <= APU_VGPU_CAPSET_VENUS;
                cpl_q.status <= APU_HVIS_OK;
              end
              state_q <= Done;
            end
            default: begin
              cpl_q.status <= APU_HVIS_FAULT;
              state_q <= Done;
            end
          endcase
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

// HostVisible (hvis) enable-0 fixture: blob map and Venus context_init.
module g6lc_apu_hvis_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_hvis_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hvis_cpl_t cpl_o,
  output apu_hvis_t hvis_o
);
  g6lc_apu_hvis #(.Enable(Enable)) i_dut (.*);
endmodule
