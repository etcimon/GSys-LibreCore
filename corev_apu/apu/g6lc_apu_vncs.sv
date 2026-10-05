// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Diagnostic Venus command stream on a HOST_VISIBLE ring: CREATE_MODULE
// loads SPIR-V into SpirvSubset; DISPATCH runs it and stores the result
// back into the ring. This is not Mesa vn_protocol and not a stock ICD.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.
// FeatureVirgl stays illegal.

// VenusCs (vncs): HOST_VISIBLE ring CREATE_MODULE/DISPATCH into SpirvSubset. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCs (vncs) --> SpirvSubset (spirv) --? HostVisible (hvis) --? ApuSys. Diagnostic ring. See AGENTS-impl-interplays.md.
module g6lc_apu_vncs
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic ring_we_i,
  input  logic [6:0] ring_idx_i,
  input  logic [31:0] ring_wdata_i,
  output logic [31:0] ring_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vncs_cpl_t cpl_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  if (!Enable) begin : gen_off
    assign ring_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign irq_o = 1'b0;
    assign result_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | ring_we_i | req_valid_i | cpl_ready_i |
                    (|ring_idx_i) | (|ring_wdata_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, Decode, Load, Commit, Kick, WaitEx, Store, Finish, Fault
    } state_e;
    state_e state_q;
    logic [31:0] ring_q [APU_VNCS_RING_WORDS];
    logic [7:0] pc_q, prod_q, n_q, load_q;
    logic [6:0] roff_q;
    logic [31:0] in_a_q, in_b_q, result_q;
    apu_vncs_cpl_t cpl_q;
    logic spv_we, spv_commit, spv_start, spv_idle, spv_busy, spv_done;
    logic spv_fault, spv_irq;
    logic [6:0] spv_idx;
    logic [31:0] spv_wdata, spv_res;
    logic [7:0] spv_len;
    logic [31:0] cmd, nword, rword;

    assign ring_rdata_o = ring_q[ring_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = (state_q == Finish) || (state_q == Fault);
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vncs_cpl_t'('0);
    assign irq_o = state_q == Finish;
    assign result_o = result_q;
    assign cmd = ring_q[pc_q[6:0]];
    assign nword = ring_q[pc_q[6:0] + 7'd1];
    assign rword = ring_q[pc_q[6:0] + 7'd3];
    assign spv_idx = load_q[6:0];
    assign spv_wdata = ring_q[pc_q[6:0] + 7'd2 + load_q[6:0]];
    assign spv_len = n_q;
    assign spv_we = state_q == Load;
    assign spv_commit = state_q == Commit;
    assign spv_start = state_q == Kick;

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
        ring_q <= '{default: '0};
        pc_q <= '0;
        prod_q <= '0;
        n_q <= '0;
        load_q <= '0;
        roff_q <= '0;
        in_a_q <= '0;
        in_b_q <= '0;
        result_q <= '0;
        cpl_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (ring_we_i) ring_q[ring_idx_i] <= ring_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            prod_q <= ring_q[0][7:0];
            if (ring_q[0][7:0] > 8'(APU_VNCS_RING_WORDS) ||
                ring_q[1][7:0] > ring_q[0][7:0]) begin
              cpl_q.status <= APU_VNCS_FAULT;
              state_q <= Fault;
            end else if (ring_q[1][7:0] == ring_q[0][7:0] ||
                         ring_q[0][7:0] <= 8'd2) begin
              cpl_q.status <= APU_VNCS_OK;
              state_q <= Finish;
            end else begin
              pc_q <= (ring_q[1][7:0] < 8'd2) ? 8'd2 : ring_q[1][7:0];
              state_q <= Decode;
            end
          end
        end
        Decode: begin
          if (pc_q >= prod_q) begin
            cpl_q.status <= APU_VNCS_OK;
            state_q <= Finish;
          end else if (cmd == APU_VNCS_CREATE) begin
            if ((pc_q + 8'd2 + nword[7:0]) > prod_q || nword == 32'd0 ||
                nword > 32'(APU_SPIRV_IMEM_WORDS)) begin
              cpl_q.status <= APU_VNCS_FAULT;
              state_q <= Fault;
            end else begin
              n_q <= nword[7:0];
              load_q <= '0;
              state_q <= Load;
            end
          end else if (cmd == APU_VNCS_DISPATCH) begin
            if ((pc_q + 8'd4) > prod_q || rword >= 32'(APU_VNCS_RING_WORDS)) begin
              cpl_q.status <= APU_VNCS_FAULT;
              state_q <= Fault;
            end else begin
              in_a_q <= ring_q[pc_q[6:0] + 7'd1];
              in_b_q <= ring_q[pc_q[6:0] + 7'd2];
              roff_q <= rword[6:0];
              state_q <= Kick;
            end
          end else begin
            cpl_q.status <= APU_VNCS_FAULT;
            state_q <= Fault;
          end
        end
        Load: begin
          if (load_q + 8'd1 == n_q) state_q <= Commit;
          else load_q <= load_q + 8'd1;
        end
        Commit: begin
          pc_q <= pc_q + 8'd2 + n_q;
          state_q <= Decode;
        end
        Kick: state_q <= WaitEx;
        WaitEx: begin
          if (spv_fault) begin
            cpl_q.status <= APU_VNCS_FAULT;
            state_q <= Fault;
          end else if (spv_irq) begin
            result_q <= spv_res;
            state_q <= Store;
          end
        end
        Store: begin
          ring_q[roff_q] <= result_q;
          pc_q <= pc_q + 8'd4;
          state_q <= Decode;
        end
        Finish: begin
          ring_q[1] <= {24'h0, prod_q};
          if (cpl_ready_i) state_q <= Idle;
        end
        Fault: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end
  end
endmodule

// VenusCs (vncs) enable-0 fixture: HOST_VISIBLE ring into SpirvSubset.
module g6lc_apu_vncs_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic ring_we_i,
  input  logic [6:0] ring_idx_i,
  input  logic [31:0] ring_wdata_i,
  output logic [31:0] ring_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vncs_cpl_t cpl_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  g6lc_apu_vncs #(.Enable(Enable)) i_dut (.*);
endmodule
