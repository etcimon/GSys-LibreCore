// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_ring_layout (head 0, tail 64, status 128, buffer 192,
// buffer_size 512) feeds vn_protocol vkCreateShaderModule into
// SpirvSubset. A later request with the committed module dispatches
// new inputs. Enable=0 elaborates no datapath. Not wired into
// g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusPath (vnp): vn_ring buffer feeds vnenc into SpirvSubset. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusPath (vnp) --> VenusEncode (vnenc) --> SpirvSubset (spirv) --? VenusRing (vnring) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vnp
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic shm_we_i,
  input  logic [7:0] shm_idx_i,
  input  logic [31:0] shm_wdata_i,
  output logic [31:0] shm_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vnp_cpl_t cpl_o,
  output apu_vnp_t vnp_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  if (!Enable) begin : gen_off
    assign shm_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vnp_o = '0;
    assign irq_o = 1'b0;
    assign result_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | shm_we_i | req_valid_i | cpl_ready_i |
                    (|shm_idx_i) | (|shm_wdata_i) | (|in_a_i) | (|in_b_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, Copy, FireEnc, WaitEnc, Load, Commit, Kick, WaitEx, Done, Fault
    } state_e;
    state_e state_q;
    logic [31:0] shm_q [APU_VNP_SHM_WORDS];
    logic loaded_q;
    logic [7:0] copy_q, load_q, dw_q, n_q;
    logic [31:0] in_a_q, in_b_q, result_q;
    logic [63:0] mod_q;
    apu_vnp_cpl_t cpl_q;
    apu_vnp_t rec_q;
    logic [31:0] head, tail, delta;
    logic enc_we, enc_req, enc_rdy, enc_cpl, enc_ack;
    logic [7:0] enc_idx;
    logic [31:0] enc_wdata, enc_rdata;
    apu_vnenc_cpl_t enc_c;
    apu_vnenc_t enc_rec;
    logic spv_we, spv_commit, spv_start, spv_idle, spv_busy, spv_done;
    logic spv_fault, spv_irq;
    logic [6:0] spv_idx;
    logic [31:0] spv_wdata, spv_res;
    logic [7:0] spv_len;

    assign shm_rdata_o = shm_q[shm_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = (state_q == Done) || (state_q == Fault);
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vnp_cpl_t'('0);
    assign vnp_o = rec_q;
    assign irq_o = state_q == Done && rec_q.valid;
    assign result_o = result_q;
    assign head = shm_q[7'(APU_VNRING_HEAD_OFF >> 2)];
    assign tail = shm_q[7'(APU_VNRING_TAIL_OFF >> 2)];
    assign delta = head - tail;
    assign enc_ack = state_q == WaitEnc;
    assign spv_idx = load_q[6:0];
    assign spv_wdata = shm_q[8'(APU_VNP_BUF_OFF >> 2) + 8'(APU_VNENC_CODE0) + load_q];
    assign spv_len = n_q;
    assign spv_we = state_q == Load;
    assign spv_commit = state_q == Commit;
    assign spv_start = state_q == Kick;
    assign enc_we = state_q == Copy;
    assign enc_idx = copy_q;
    assign enc_wdata = shm_q[8'(APU_VNP_BUF_OFF >> 2) + copy_q];
    assign enc_req = state_q == FireEnc;

    g6lc_apu_vnenc #(.Enable(1'b1)) i_enc (
      .clk_i, .rst_ni, .cs_we_i(enc_we), .cs_idx_i(enc_idx),
      .cs_wdata_i(enc_wdata), .cs_rdata_o(enc_rdata),
      .req_valid_i(enc_req), .req_ready_o(enc_rdy),
      .cpl_valid_o(enc_cpl), .cpl_ready_i(enc_ack), .cpl_o(enc_c),
      .vnenc_o(enc_rec)
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
        shm_q <= '{default: '0};
        loaded_q <= 1'b0;
        copy_q <= '0;
        load_q <= '0;
        dw_q <= '0;
        n_q <= '0;
        in_a_q <= '0;
        in_b_q <= '0;
        result_q <= '0;
        mod_q <= '0;
        cpl_q <= '0;
        rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (shm_we_i) shm_q[shm_idx_i] <= shm_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            in_a_q <= in_a_i;
            in_b_q <= in_b_i;
            if (loaded_q) state_q <= Kick;
            else begin
              rec_q <= '0;
              if (head[1:0] != 2'b00 || tail != 32'd0 ||
                  delta > 32'(APU_VNP_BUF_BYTES)) begin
                cpl_q.status <= APU_VNP_FAULT;
                state_q <= Fault;
              end else if (delta == 32'd0) begin
                shm_q[7'(APU_VNRING_STATUS_OFF >> 2)] <= APU_VNRING_STATUS_IDLE;
                cpl_q.status <= APU_VNP_OK;
                state_q <= Done;
              end else if (delta[31:2] == 30'd0 ||
                           delta[31:2] > 30'(APU_VNENC_WORDS)) begin
                cpl_q.status <= APU_VNP_FAULT;
                state_q <= Fault;
              end else begin
                dw_q <= delta[9:2];
                copy_q <= '0;
                state_q <= Copy;
              end
            end
          end
        end
        Copy: begin
          if (copy_q + 8'd1 == dw_q) state_q <= FireEnc;
          else copy_q <= copy_q + 8'd1;
        end
        FireEnc: if (enc_rdy) state_q <= WaitEnc;
        WaitEnc: if (enc_cpl) begin
          if (enc_c.status != APU_VNENC_OK || !enc_rec.valid ||
              enc_rec.first_word != APU_SPIRV_MAGIC) begin
            cpl_q.status <= APU_VNP_FAULT;
            state_q <= Fault;
          end else begin
            n_q <= enc_rec.code_words[7:0];
            mod_q <= enc_rec.module_id;
            load_q <= '0;
            state_q <= Load;
          end
        end
        Load: begin
          if (load_q + 8'd1 == n_q) state_q <= Commit;
          else load_q <= load_q + 8'd1;
        end
        Commit: state_q <= Kick;
        Kick: state_q <= WaitEx;
        WaitEx: begin
          if (spv_fault) begin
            cpl_q.status <= APU_VNP_FAULT;
            state_q <= Fault;
          end else if (spv_irq) begin
            result_q <= spv_res;
            rec_q.valid <= 1'b1;
            rec_q.loaded <= 1'b1;
            rec_q.module_id <= mod_q;
            rec_q.code_words <= {24'h0, n_q};
            rec_q.result <= spv_res;
            loaded_q <= 1'b1;
            shm_q[7'(APU_VNRING_TAIL_OFF >> 2)] <= head;
            shm_q[7'(APU_VNRING_STATUS_OFF >> 2)] <= APU_VNRING_STATUS_IDLE;
            cpl_q.status <= APU_VNP_OK;
            state_q <= Done;
          end
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

// VenusPath (vnp) enable-0 fixture: vn_ring buffer into SpirvSubset.
module g6lc_apu_vnp_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic shm_we_i,
  input  logic [7:0] shm_idx_i,
  input  logic [31:0] shm_wdata_i,
  output logic [31:0] shm_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vnp_cpl_t cpl_o,
  output apu_vnp_t vnp_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  g6lc_apu_vnp #(.Enable(Enable)) i_dut (.*);
endmodule
