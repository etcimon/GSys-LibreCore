// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_ring_get_layout walker: 64-byte aligned head, tail, status,
// then the command buffer. head/tail are monotonically increasing byte
// seqnos; the buffer index is seqno modulo 256. This is the stock ring
// geometry, not Mesa vn_protocol vk* encode. Enable=0 elaborates no
// datapath. Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusRing (vnring): Mesa vn_ring_layout head/tail/status/buffer walker. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusRing (vnring) --? VenusCs (vncs) --? ApuSys. Stock layout. See AGENTS-impl-interplays.md.
module g6lc_apu_vnring
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic shm_we_i,
  input  logic [6:0] shm_idx_i,
  input  logic [31:0] shm_wdata_i,
  output logic [31:0] shm_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vnring_cpl_t cpl_o,
  output apu_vnring_t vnring_o
);
  if (!Enable) begin : gen_off
    assign shm_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vnring_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | shm_we_i | req_valid_i | cpl_ready_i |
                    (|shm_idx_i) | (|shm_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Commit, Done, Fault } state_e;
    state_e state_q;
    logic [31:0] shm_q [APU_VNRING_WORDS];
    apu_vnring_cpl_t cpl_q;
    apu_vnring_t rec_q;
    logic [31:0] head, tail, delta;
    logic [7:0] bidx;
    logic [6:0] widx;

    assign shm_rdata_o = shm_q[shm_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = (state_q == Done) || (state_q == Fault);
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vnring_cpl_t'('0);
    assign vnring_o = rec_q;
    assign head = shm_q[7'(APU_VNRING_HEAD_OFF >> 2)];
    assign tail = shm_q[7'(APU_VNRING_TAIL_OFF >> 2)];
    assign delta = head - tail;
    assign bidx = tail[7:0];
    assign widx = 7'(APU_VNRING_BUF_OFF >> 2) + 7'(bidx[7:2]);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        shm_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (shm_we_i) shm_q[shm_idx_i] <= shm_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (head[1:0] != 2'b00 || tail[1:0] != 2'b00 ||
                delta > 32'(APU_VNRING_BUF_BYTES)) begin
              cpl_q.status <= APU_VNRING_FAULT;
              state_q <= Fault;
            end else begin
              rec_q.head <= head;
              rec_q.tail <= tail;
              rec_q.bytes <= delta;
              rec_q.first_word <= (delta == 32'd0) ? 32'h0 : shm_q[widx];
              rec_q.valid <= (delta != 32'd0);
              cpl_q.status <= APU_VNRING_OK;
              state_q <= Commit;
            end
          end
        end
        Commit: begin
          shm_q[7'(APU_VNRING_TAIL_OFF >> 2)] <= head;
          shm_q[7'(APU_VNRING_STATUS_OFF >> 2)] <= APU_VNRING_STATUS_IDLE;
          state_q <= Done;
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        Fault: if (cpl_ready_i) state_q <= Idle;
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

// VenusRing (vnring) enable-0 fixture: Mesa vn_ring_layout walker.
module g6lc_apu_vnring_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic shm_we_i,
  input  logic [6:0] shm_idx_i,
  input  logic [31:0] shm_wdata_i,
  output logic [31:0] shm_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vnring_cpl_t cpl_o,
  output apu_vnring_t vnring_o
);
  g6lc_apu_vnring #(.Enable(Enable)) i_dut (.*);
endmodule
