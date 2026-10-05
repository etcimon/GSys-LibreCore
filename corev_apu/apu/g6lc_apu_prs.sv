// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext then a WRITE-window store of a programmed response (≤32
// bytes). The bytes come from the resp poke port, not a pixel oracle.
// EMPTY writes nothing. Enable=0 elaborates no datapath. Does not edit
// g6lc_apu_vgpu_avail. Not wired into g6lc_apu_sys. FeatureVirgl stays
// illegal.

// PayResp (prs): AvailNext WRITE-window response store. Default-off. FeatureVirgl stays illegal.
// Interplay: PayResp (prs) --> AvailNext (avn) ==> WRITE payload. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_prs
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic resp_we_i,
  input  logic [2:0] resp_idx_i,
  input  logic [31:0] resp_wdata_i,
  input  logic [31:0] resp_len_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_prs_cpl_t cpl_o,
  output apu_prs_t prs_o,
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
    assign prs_o = '0;
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
    assign unused = clk_i | rst_ni | resp_we_i | req_valid_i | cpl_ready_i |
                    rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i |
                    wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) | (|resp_idx_i) |
                    (|resp_wdata_i) | (|resp_len_i) | (|rd_rsp_addr_i) |
                    (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireAvn, WaitAvn, WrPay, WaitWr, Done
    } state_e;
    state_e state_q;
    apu_prs_cpl_t cpl_q;
    apu_prs_t rec_q;
    logic [31:0] resp_q [APU_PRS_WORDS];
    logic [31:0] rlen_q;
    logic [63:0] waddr_q;
    logic wr_ok_shape;
    logic avn_req_v, avn_rdy, avn_cpl, avn_ack;
    apu_avn_req_t req_q;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_prs_cpl_t'('0);
    assign prs_o = rec_q;
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign wr_valid_o = state_q == WrPay;
    assign wr_addr_o = waddr_q;
    assign wr_len_o = rlen_q;
    assign wr_rsp_ready_o = state_q == WaitWr;
    assign wr_ok_shape = (avn_rec.last_flags & VIRTQ_DESC_F_WRITE) != 16'd0 &&
                         (avn_rec.last_len != 32'd0) &&
                         (avn_rec.last_len <= 32'(APU_PRS_BYTES)) &&
                         (avn_rec.last_len[1:0] == 2'd0) &&
                         (avn_rec.last_addr[1:0] == 2'd0) &&
                         (avn_rec.last_len == rlen_q);

    always_comb begin
      wr_data_o = '0;
      wr_data_o[31:0]    = resp_q[0];
      wr_data_o[63:32]   = resp_q[1];
      wr_data_o[95:64]   = resp_q[2];
      wr_data_o[127:96]  = resp_q[3];
      wr_data_o[159:128] = resp_q[4];
      wr_data_o[191:160] = resp_q[5];
      wr_data_o[223:192] = resp_q[6];
      wr_data_o[255:224] = resp_q[7];
    end

    g6lc_apu_avn #(.Enable(1'b1)) i_avn (
      .clk_i, .rst_ni,
      .req_valid_i(avn_req_v), .req_ready_o(avn_rdy), .req_i(req_q),
      .cpl_valid_o(avn_cpl), .cpl_ready_i(avn_ack), .cpl_o(avn_c), .avn_o(avn_rec),
      .rd_valid_o, .rd_ready_i, .rd_addr_o, .rd_len_o,
      .rd_rsp_valid_i, .rd_rsp_ready_o, .rd_rsp_ok_i,
      .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        resp_q <= '{default: '0};
        rlen_q <= '0;
        waddr_q <= '0;
        req_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (resp_we_i) resp_q[resp_idx_i] <= resp_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            req_q <= req_i;
            rlen_q <= resp_len_i;
            state_q <= FireAvn;
          end
        end
        FireAvn: if (avn_rdy) state_q <= WaitAvn;
        WaitAvn: if (avn_cpl) begin
          if (avn_c.status == APU_AVN_EMPTY) begin
            cpl_q.status <= APU_PRS_EMPTY;
            state_q <= Done;
          end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid ||
                       !wr_ok_shape) begin
            cpl_q.status <= APU_PRS_FAULT;
            state_q <= Done;
          end else begin
            waddr_q <= avn_rec.last_addr;
            rec_q.addr <= avn_rec.last_addr;
            rec_q.bytes <= avn_rec.last_len;
            rec_q.word0 <= resp_q[0];
            state_q <= WrPay;
          end
        end
        WrPay: if (wr_ready_i) state_q <= WaitWr;
        WaitWr: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i) begin
            rec_q.valid <= 1'b0;
            cpl_q.status <= APU_PRS_FAULT;
          end else begin
            rec_q.valid <= 1'b1;
            cpl_q.status <= APU_PRS_OK;
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

// PayResp (prs) enable-0 fixture: AvailNext WRITE-window response store.
module g6lc_apu_prs_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic resp_we_i,
  input  logic [2:0] resp_idx_i,
  input  logic [31:0] resp_wdata_i,
  input  logic [31:0] resp_len_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_prs_cpl_t cpl_o,
  output apu_prs_t prs_o,
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
  g6lc_apu_prs #(.Enable(Enable)) i_dut (.*);
endmodule
