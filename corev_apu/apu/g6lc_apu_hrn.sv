// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// HandlePath create/dispatch plus SpirvSubset. vkCreateShaderModule
// allocates a MODULE handle and commits SPIR-V. vkCmdDispatch looks
// up a live CMDBUF and kicks the committed module. Duplicate live
// module ids, dispatch before create, MODULE-as-cmdbuf, and
// vkCreateInstance fault. Enable=0 elaborates no datapath. Not wired
// into g6lc_apu_sys. FeatureVirgl stays illegal.

// HandleRun (hrn): HandlePath create/dispatch then SpirvSubset kick. Default-off. FeatureVirgl stays illegal.
// Interplay: HandleRun (hrn) --> VenusEncode (vnenc) --> GenHandle (gnh) --> VenusDispatch (vnd) --> SpirvSubset (spirv) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_hrn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_hrn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hrn_cpl_t cpl_o,
  output apu_hrn_t hrn_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign hrn_o = '0;
    assign irq_o = 1'b0;
    assign result_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i) | (|req_i) | (|in_a_i) |
                    (|in_b_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, FireEnc, WaitEnc, FireVnd, WaitVnd, FireGnh, WaitGnh,
      Load, Commit, Kick, WaitEx, Done
    } state_e;
    state_e state_q;
    apu_hrn_cpl_t cpl_q;
    apu_hrn_t rec_q;
    logic create_q, disp_q, look_q, loaded_q;
    logic [7:0] load_q, n_q, enc_idx;
    logic [31:0] in_a_q, in_b_q, result_q, enc_rdata, vnd_rdata;
    logic enc_req, enc_rdy, enc_cpl, enc_ack, enc_we;
    logic vnd_req, vnd_rdy, vnd_cpl, vnd_ack, vnd_we;
    logic gnh_req_v, gnh_rdy, gnh_cpl, gnh_ack;
    logic [3:0] vnd_idx;
    logic spv_we, spv_commit, spv_start, spv_idle, spv_busy, spv_done;
    logic spv_fault, spv_irq;
    logic [6:0] spv_idx;
    logic [31:0] spv_wdata, spv_res;
    logic [7:0] spv_len;
    apu_gnh_req_t gnh_req_q;
    apu_vnenc_cpl_t enc_c;
    apu_vnenc_t enc_rec;
    apu_vnd_cpl_t vnd_c;
    apu_vnd_t vnd_rec;
    apu_gnh_cpl_t gnh_c;
    apu_gnh_t gnh_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_hrn_cpl_t'('0);
    assign hrn_o = rec_q;
    assign irq_o = state_q == Done && rec_q.valid && rec_q.dispatch;
    assign result_o = result_q;
    assign cs_rdata_o = enc_rdata;
    assign enc_we = cs_we_i && (state_q == Idle);
    assign enc_idx = (state_q == Load) ? (8'(APU_VNENC_CODE0) + load_q) : cs_idx_i;
    assign vnd_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vnd_idx = cs_idx_i[3:0];
    assign enc_req = state_q == FireEnc;
    assign enc_ack = state_q == WaitEnc;
    assign vnd_req = state_q == FireVnd;
    assign vnd_ack = state_q == WaitVnd;
    assign gnh_req_v = state_q == FireGnh;
    assign gnh_ack = state_q == WaitGnh;
    assign spv_we = state_q == Load;
    assign spv_idx = load_q[6:0];
    assign spv_wdata = enc_rdata;
    assign spv_len = n_q;
    assign spv_commit = state_q == Commit;
    assign spv_start = state_q == Kick;

    g6lc_apu_vnenc #(.Enable(1'b1)) i_enc (
      .clk_i, .rst_ni, .cs_we_i(enc_we), .cs_idx_i(enc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(enc_rdata),
      .req_valid_i(enc_req), .req_ready_o(enc_rdy),
      .cpl_valid_o(enc_cpl), .cpl_ready_i(enc_ack), .cpl_o(enc_c),
      .vnenc_o(enc_rec)
    );
    g6lc_apu_vnd #(.Enable(1'b1)) i_vnd (
      .clk_i, .rst_ni, .cs_we_i(vnd_we), .cs_idx_i(vnd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vnd_rdata),
      .req_valid_i(vnd_req), .req_ready_o(vnd_rdy),
      .cpl_valid_o(vnd_cpl), .cpl_ready_i(vnd_ack), .cpl_o(vnd_c),
      .vnd_o(vnd_rec)
    );
    g6lc_apu_gnh #(.Enable(1'b1)) i_gnh (
      .clk_i, .rst_ni,
      .req_valid_i(gnh_req_v), .req_ready_o(gnh_rdy), .req_i(gnh_req_q),
      .cpl_valid_o(gnh_cpl), .cpl_ready_i(gnh_ack), .cpl_o(gnh_c),
      .gnh_o(gnh_rec)
    );
    g6lc_apu_spirv #(.Enable(1'b1)) i_spv (
      .clk_i, .rst_ni, .prog_we_i(spv_we), .prog_idx_i(spv_idx),
      .prog_wdata_i(spv_wdata), .prog_len_i(spv_len), .commit_i(spv_commit),
      .start_i(spv_start), .in_a_i(in_a_q), .in_b_i(in_b_q),
      .idle_o(spv_idle), .busy_o(spv_busy), .done_o(spv_done),
      .fault_o(spv_fault), .irq_o(spv_irq), .result_o(spv_res)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        create_q <= 1'b0;
        disp_q <= 1'b0;
        look_q <= 1'b0;
        loaded_q <= 1'b0;
        load_q <= '0;
        n_q <= '0;
        in_a_q <= '0;
        in_b_q <= '0;
        result_q <= '0;
        gnh_req_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          create_q <= req_i.op == APU_HRN_CREATE;
          disp_q <= req_i.op == APU_HRN_DISPATCH;
          look_q <= 1'b0;
          in_a_q <= in_a_i;
          in_b_q <= in_b_i;
          unique case (req_i.op)
            APU_HRN_GNH: begin
              gnh_req_q <= req_i.gnh;
              state_q <= FireGnh;
            end
            APU_HRN_CREATE: state_q <= FireEnc;
            APU_HRN_DISPATCH: begin
              if (!loaded_q) begin
                cpl_q.status <= APU_HRN_FAULT;
                state_q <= Done;
              end else state_q <= FireVnd;
            end
            default: begin
              cpl_q.status <= APU_HRN_FAULT;
              state_q <= Done;
            end
          endcase
        end
        FireEnc: if (enc_rdy) state_q <= WaitEnc;
        WaitEnc: if (enc_cpl) begin
          if (enc_c.status != APU_VNENC_OK || !enc_rec.valid ||
              enc_rec.first_word != APU_SPIRV_MAGIC ||
              enc_rec.module_id[63:32] != 32'd0 ||
              enc_rec.module_id[31:0] == 32'd0 ||
              enc_rec.code_words == 32'd0 ||
              enc_rec.code_words > 32'(APU_VNENC_MAX_WORDS)) begin
            cpl_q.status <= APU_HRN_FAULT;
            state_q <= Done;
          end else begin
            rec_q.code_words <= enc_rec.code_words;
            n_q <= enc_rec.code_words[7:0];
            load_q <= '0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_MODULE,
              object_id: enc_rec.module_id[31:0],
              handle: '0
            };
            state_q <= FireGnh;
          end
        end
        FireVnd: if (vnd_rdy) state_q <= WaitVnd;
        WaitVnd: if (vnd_cpl) begin
          if (vnd_c.status != APU_VND_OK || !vnd_rec.valid ||
              vnd_rec.command_buffer[63:32] != 32'd0) begin
            cpl_q.status <= APU_HRN_FAULT;
            state_q <= Done;
          end else begin
            rec_q.group_x <= vnd_rec.group_x;
            rec_q.group_y <= vnd_rec.group_y;
            rec_q.group_z <= vnd_rec.group_z;
            rec_q.handle <= vnd_rec.command_buffer[31:0];
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: vnd_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireGnh: if (gnh_rdy) state_q <= WaitGnh;
        WaitGnh: if (gnh_cpl) begin
          if (gnh_c.status != APU_GNH_OK ||
              (look_q && gnh_rec.kind != APU_GNH_CMDBUF)) begin
            rec_q.valid <= 1'b0;
            cpl_q.status <= APU_HRN_FAULT;
            state_q <= Done;
          end else begin
            rec_q.valid <= gnh_rec.valid;
            rec_q.create <= create_q;
            rec_q.dispatch <= disp_q;
            rec_q.loaded <= loaded_q;
            rec_q.slot <= gnh_rec.slot;
            rec_q.gen <= gnh_rec.gen;
            rec_q.kind <= gnh_rec.kind;
            rec_q.object_id <= gnh_rec.object_id;
            rec_q.handle <= gnh_rec.handle;
            if (disp_q) state_q <= Kick;
            else if (create_q) state_q <= Load;
            else begin
              cpl_q.status <= APU_HRN_OK;
              state_q <= Done;
            end
          end
        end
        Load: begin
          if (load_q + 8'd1 == n_q) state_q <= Commit;
          else load_q <= load_q + 8'd1;
        end
        Commit: begin
          loaded_q <= 1'b1;
          rec_q.loaded <= 1'b1;
          cpl_q.status <= APU_HRN_OK;
          state_q <= Done;
        end
        Kick: state_q <= WaitEx;
        WaitEx: begin
          if (spv_fault) begin
            rec_q.valid <= 1'b0;
            cpl_q.status <= APU_HRN_FAULT;
            state_q <= Done;
          end else if (spv_irq) begin
            result_q <= spv_res;
            rec_q.result <= spv_res;
            rec_q.loaded <= 1'b1;
            cpl_q.status <= APU_HRN_OK;
            state_q <= Done;
          end
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

// HandleRun (hrn) enable-0 fixture: HandlePath then SpirvSubset kick.
module g6lc_apu_hrn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_hrn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hrn_cpl_t cpl_o,
  output apu_hrn_t hrn_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  g6lc_apu_hrn #(.Enable(Enable)) i_dut (.*);
endmodule
