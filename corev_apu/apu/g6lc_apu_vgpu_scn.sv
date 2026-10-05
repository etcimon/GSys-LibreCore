// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// SET_SCANOUT of scanout 0 onto resource 4, rectangle 0,0,640,480.
// A 64 by 64 rectangle records nothing. This is not g6lc_hdmi_scanout
// and it does not change a video mode.

// ScanoutSet (scn): SET_SCANOUT of resource 4. Default-off. Not a HDMI mode.
module g6lc_apu_vgpu_scn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_att_t att_i,
  input  apu_vgpu_rsp_t rsp_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_scn_cpl_t cpl_o,
  output apu_vgpu_scn_t scn_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign scn_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|att_i) | (|rsp_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, ReadBody, Commit, Done } state_e;

    state_e state_q;
    apu_vgpu_scn_cpl_t cpl_q;
    apu_vgpu_scn_t scn_q;
    logic [31:0] body_q [0:11];
    logic [3:0] idx_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = 32'(idx_q) << 2;
    assign peek_addr_o = state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_scn_cpl_t'('0);
    assign scn_o = scn_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        scn_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (scn_q.valid) begin
            cpl_q.status <= APU_VGPU_SCN_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !rsp_i.valid || !att_i.rt || !att_i.vbo ||
                       !att_i.scan || att_i.next != APU_VGPU_CTL_END) begin
            cpl_q.status <= APU_VGPU_SCN_EMPTY;
            state_q <= Done;
          end else if (APU_VGPU_SCN_BYTES > buf_i.size) begin
            cpl_q.status <= APU_VGPU_SCN_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= '0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 4'd11) state_q <= Commit;
          else idx_q <= idx_q + 4'd1;
        end
        Commit: begin
          if (body_q[0] != VGPU_CMD_SET_SCANOUT || body_q[1] != 32'h0 ||
              body_q[2] != 32'h0 || body_q[3] != 32'h0 || body_q[4] != 32'h0 ||
              body_q[5] != 32'h0 || body_q[6] != 32'h0 || body_q[7] != 32'h0 ||
              body_q[8] != APU_VGPU_RT_W || body_q[9] != APU_VGPU_RT_H ||
              body_q[10] != 32'h0 || body_q[11] != APU_VGPU_RES_RT) begin
            cpl_q.status <= APU_VGPU_SCN_FAULT;
          end else begin
            scn_q.valid <= 1'b1;
            scn_q.scanout_id <= body_q[10];
            scn_q.resource_id <= body_q[11];
            scn_q.width <= body_q[8];
            scn_q.height <= body_q[9];
            scn_q.next <= APU_VGPU_SCN_BYTES;
            cpl_q.status <= APU_VGPU_SCN_OK;
          end
          state_q <= Done;
        end
        Done: begin
          if (!armed_q) armed_q <= 1'b1;
          else if (cpl_ready_i) begin
            armed_q <= 1'b0;
            state_q <= Idle;
          end
        end
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(scn_o));
    `endif
  end
endmodule

// ScanoutSet (scn) enable-0 fixture: SET_SCANOUT of resource 4. Default-off. Not a HDMI mode.
module g6lc_apu_vgpu_scn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_att_t att_i,
  input  apu_vgpu_rsp_t rsp_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_scn_cpl_t cpl_o,
  output apu_vgpu_scn_t scn_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_scn #(.Enable(Enable)) i_dut (.*);
endmodule
