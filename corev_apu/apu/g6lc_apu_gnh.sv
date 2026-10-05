// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Generational context/resource/program/cmdbuf/queue table. Alloc publishes
// {gen, slot}. Lookup/pin/unpin/retire require a live matching
// generation. Retire is refused while pinned. Duplicate live
// (kind, object_id) and a full table fault. Enable=0 elaborates no
// datapath. Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// GenHandle (gnh): generational context/resource/program table with pin/retire. Default-off. FeatureVirgl stays illegal.
// Interplay: GenHandle (gnh) --? HostVisible (hvis) --? VenusPath (vnp) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_gnh
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_gnh_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_gnh_cpl_t cpl_o,
  output apu_gnh_t gnh_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gnh_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|req_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_gnh_cpl_t cpl_q;
    apu_gnh_t rec_q;
    logic [APU_GNH_SLOTS-1:0] live_q;
    apu_gnh_kind_e kind_q [APU_GNH_SLOTS];
    logic [15:0] gen_q [APU_GNH_SLOTS];
    logic [31:0] id_q [APU_GNH_SLOTS];
    logic [7:0] pin_q [APU_GNH_SLOTS];
    logic [4:0] slot, free_slot;
    logic [15:0] req_gen, next_gen;
    logic has_free, dup, h_ok, pad_ok;
    logic [31:0] pub;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_gnh_cpl_t'('0);
    assign gnh_o = rec_q;
    assign slot = req_i.handle[4:0];
    assign req_gen = req_i.handle[31:16];
    assign pad_ok = req_i.handle[15:5] == 11'd0;
    assign h_ok = pad_ok && live_q[slot] && gen_q[slot] == req_gen &&
                  req_gen != 16'd0;
    assign pub = apu_gnh_handle(next_gen, free_slot);
    assign next_gen = (gen_q[free_slot] + 16'd1 == 16'd0) ?
                      16'd1 : (gen_q[free_slot] + 16'd1);

    always_comb begin
      has_free = 1'b0;
      free_slot = 5'd0;
      dup = 1'b0;
      for (int unsigned s = 0; s < APU_GNH_SLOTS; s++) begin
        if (!has_free && !live_q[s]) begin
          has_free = 1'b1;
          free_slot = 5'(s);
        end
        if (live_q[s] && kind_q[s] == req_i.kind && id_q[s] == req_i.object_id)
          dup = 1'b1;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        live_q <= '0;
        kind_q <= '{default: APU_GNH_CTX};
        gen_q <= '{default: '0};
        id_q <= '{default: '0};
        pin_q <= '{default: '0};
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          unique case (req_i.op)
            APU_GNH_ALLOC: begin
              if (req_i.object_id == 32'd0 || !has_free || dup) begin
                cpl_q.status <= APU_GNH_FAULT;
              end else begin
                live_q[free_slot] <= 1'b1;
                kind_q[free_slot] <= req_i.kind;
                gen_q[free_slot] <= next_gen;
                id_q[free_slot] <= req_i.object_id;
                pin_q[free_slot] <= 8'd0;
                rec_q.valid <= 1'b1;
                rec_q.slot <= free_slot;
                rec_q.gen <= next_gen;
                rec_q.pin <= 8'd0;
                rec_q.kind <= req_i.kind;
                rec_q.object_id <= req_i.object_id;
                rec_q.handle <= pub;
                cpl_q.status <= APU_GNH_OK;
              end
            end
            APU_GNH_LOOKUP: begin
              if (!h_ok) cpl_q.status <= APU_GNH_FAULT;
              else begin
                rec_q.valid <= 1'b1;
                rec_q.slot <= slot;
                rec_q.gen <= gen_q[slot];
                rec_q.pin <= pin_q[slot];
                rec_q.kind <= kind_q[slot];
                rec_q.object_id <= id_q[slot];
                rec_q.handle <= req_i.handle;
                cpl_q.status <= APU_GNH_OK;
              end
            end
            APU_GNH_PIN: begin
              if (!h_ok || pin_q[slot] == 8'hff) cpl_q.status <= APU_GNH_FAULT;
              else begin
                pin_q[slot] <= pin_q[slot] + 8'd1;
                rec_q.valid <= 1'b1;
                rec_q.slot <= slot;
                rec_q.gen <= gen_q[slot];
                rec_q.pin <= pin_q[slot] + 8'd1;
                rec_q.kind <= kind_q[slot];
                rec_q.object_id <= id_q[slot];
                rec_q.handle <= req_i.handle;
                cpl_q.status <= APU_GNH_OK;
              end
            end
            APU_GNH_UNPIN: begin
              if (!h_ok || pin_q[slot] == 8'd0) cpl_q.status <= APU_GNH_FAULT;
              else begin
                pin_q[slot] <= pin_q[slot] - 8'd1;
                rec_q.valid <= 1'b1;
                rec_q.slot <= slot;
                rec_q.gen <= gen_q[slot];
                rec_q.pin <= pin_q[slot] - 8'd1;
                rec_q.kind <= kind_q[slot];
                rec_q.object_id <= id_q[slot];
                rec_q.handle <= req_i.handle;
                cpl_q.status <= APU_GNH_OK;
              end
            end
            APU_GNH_RETIRE: begin
              if (!h_ok || pin_q[slot] != 8'd0) cpl_q.status <= APU_GNH_FAULT;
              else begin
                live_q[slot] <= 1'b0;
                rec_q.slot <= slot;
                rec_q.gen <= gen_q[slot];
                rec_q.kind <= kind_q[slot];
                rec_q.object_id <= id_q[slot];
                rec_q.handle <= req_i.handle;
                cpl_q.status <= APU_GNH_OK;
              end
            end
            default: cpl_q.status <= APU_GNH_FAULT;
          endcase
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

// GenHandle (gnh) enable-0 fixture: generational handle table.
module g6lc_apu_gnh_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_gnh_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_gnh_cpl_t cpl_o,
  output apu_gnh_t gnh_o
);
  g6lc_apu_gnh #(.Enable(Enable)) i_dut (.*);
endmodule
