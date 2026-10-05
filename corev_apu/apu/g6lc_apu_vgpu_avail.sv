// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One avail-ring slot and the descriptor it names. The driver may publish
// only the next index. A walk reads that one ring entry, checks the
// descriptor, and returns its 40-byte command. NEXT, WRITE, and INDIRECT
// are faults and do not consume the slot. Queue length is 8. This does
// not follow a chain and does not read guest memory.

// AvailDescriptor (avail): One avail-ring descriptor. Default-off. Not a descriptor chain.
// Interplay: AvailDescriptor (avail) --? SceneChain (chn) --? GuestNextWalk (gnw). NEXT is a fault. See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_avail
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_avail_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_avail_cpl_t cpl_o,
  output logic [15:0] avail_idx_o,
  output logic [15:0] device_idx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign avail_idx_o = '0;
    assign device_idx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|req_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_avail_cpl_t cpl_q;
    logic [15:0] avail_q, dev_q, ring_q [0:APU_VGPU_USED_NUM-1];
    logic [15:0] flag_q [0:APU_VGPU_USED_NUM-1];
    logic [31:0] len_q [0:APU_VGPU_USED_NUM-1];
    logic [319:0] cmd_q [0:APU_VGPU_USED_NUM-1];
    logic armed_q;
    logic [2:0] ring_slot, desc_slot;
    logic [15:0] ring_id;
    logic bad_desc;

    assign ring_slot = dev_q[2:0];
    assign ring_id = ring_q[ring_slot];
    assign desc_slot = ring_id[2:0];
    assign bad_desc = ring_id >= APU_VGPU_USED_NUM ||
                      len_q[desc_slot] != VGPU_CMD_BYTES ||
                      |(flag_q[desc_slot] &
                        (VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_INDIRECT));
    assign avail_idx_o = avail_q;
    assign device_idx_o = dev_q;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_avail_cpl_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        avail_q <= '0;
        dev_q <= '0;
        armed_q <= 1'b0;
        for (int i = 0; i < APU_VGPU_USED_NUM; i++) begin
          ring_q[i] <= '0;
          flag_q[i] <= '0;
          len_q[i] <= '0;
          cmd_q[i] <= '0;
        end
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          apu_vgpu_avail_cpl_t nxt;
          nxt = '0;
          nxt.device_idx = dev_q;
          if (req_i.op == APU_VGPU_AVAIL_POST) begin
            if (req_i.avail_idx != avail_q + 16'd1 ||
                req_i.desc_id >= APU_VGPU_USED_NUM) begin
              nxt.status = APU_VGPU_AVAIL_FAULT;
            end else begin
              ring_q[avail_q[2:0]] <= req_i.desc_id;
              flag_q[req_i.desc_id[2:0]] <= req_i.flags;
              len_q[req_i.desc_id[2:0]] <= req_i.len;
              cmd_q[req_i.desc_id[2:0]] <= req_i.cmd;
              avail_q <= req_i.avail_idx;
              nxt.status = APU_VGPU_AVAIL_OK;
            end
          end else if (dev_q == avail_q) begin
            nxt.status = APU_VGPU_AVAIL_EMPTY;
          end else if (bad_desc) begin
            nxt.status = APU_VGPU_AVAIL_FAULT;
          end else begin
            nxt.status = APU_VGPU_AVAIL_OK;
            nxt.desc_id = ring_id;
            nxt.cmd = cmd_q[desc_slot];
            nxt.device_idx = dev_q + 16'd1;
            dev_q <= dev_q + 16'd1;
          end
          cpl_q <= nxt;
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
      cpl_valid_o && cpl_o.status != APU_VGPU_AVAIL_OK |-> cpl_o.cmd == '0);
    `endif
  end
endmodule

// AvailDescriptor (avail) enable-0 fixture: One avail-ring descriptor. Default-off. Not a descriptor chain.
module g6lc_apu_vgpu_avail_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_avail_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_avail_cpl_t cpl_o,
  output logic [15:0] avail_idx_o,
  output logic [15:0] device_idx_o
);
  g6lc_apu_vgpu_avail #(.Enable(Enable)) i_dut (.*);
endmodule
