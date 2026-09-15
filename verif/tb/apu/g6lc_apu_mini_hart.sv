// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Tiny RV64I hart for resident APU firmware. Not a CVA6. Fetches and stores
// through AXI-Lite: image at 0x90000000, MMIO at 0x40002000, cookie at
// 0x9003FF00.

`timescale 1ns/1ps

module g6lc_apu_mini_hart
  import g6lc_apu_bus_pkg::*;
#(
  parameter logic [63:0] RamBase = 64'h9000_0000,
  parameter logic [63:0] RamBytes = 64'h40000,
  parameter logic [63:0] CtrlBase = 64'h4000_2000,
  parameter logic [63:0] CookieAddr = 64'h9003_FF00,
  parameter logic [63:0] SpinPc = 64'h9000_000c
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic enable_i,
  output apu_axi_req_t  axi_req_o,
  input  apu_axi_resp_t axi_rsp_i,
  output logic [31:0] cookie_o,
  output logic        halt_o,
  output logic [63:0] pc_o
);
  typedef enum logic [1:0] {Fetch, Exec, Bus} state_e;
  state_e state_q;
  logic [63:0] pc_q, addr_q;
  logic [31:0] inst_q, store_q, cookie_q;
  logic [63:0] rf_q [32];
  logic [4:0] rd_q;
  logic store_m_q, fetch_q, load64_q;
  logic aw_done_q, w_done_q, ar_done_q;

  assign pc_o = pc_q;
  assign cookie_o = cookie_q;
  assign halt_o = enable_i && state_q == Fetch && pc_q == SpinPc;

  function automatic logic in_ctrl(input logic [63:0] ea);
    return ea >= CtrlBase && ea < CtrlBase + 64'h1000;
  endfunction
  function automatic logic in_ram(input logic [63:0] ea);
    return ea >= RamBase && (ea - RamBase) < RamBytes;
  endfunction
  function automatic logic in_bus(input logic [63:0] ea);
    return in_ctrl(ea) || in_ram(ea);
  endfunction

  always_comb begin
    axi_req_o = '0;
    if (state_q == Bus) begin
      if (store_m_q) begin
        axi_req_o.aw.addr = addr_q;
        axi_req_o.aw.prot = 3'b000;
        axi_req_o.w.data = store_q;
        axi_req_o.w.strb = 4'hf;
        axi_req_o.aw_valid = !aw_done_q;
        axi_req_o.w_valid = !w_done_q;
        axi_req_o.b_ready = 1'b1;
      end else begin
        axi_req_o.ar.addr = addr_q;
        axi_req_o.ar.prot = 3'b000;
        axi_req_o.ar_valid = !ar_done_q;
        axi_req_o.r_ready = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Fetch;
      pc_q <= RamBase;
      inst_q <= '0;
      addr_q <= '0;
      store_q <= '0;
      cookie_q <= '0;
      rd_q <= '0;
      store_m_q <= 1'b0;
      fetch_q <= 1'b0;
      load64_q <= 1'b0;
      aw_done_q <= 1'b0;
      w_done_q <= 1'b0;
      ar_done_q <= 1'b0;
      for (int i = 0; i < 32; i++) rf_q[i] <= '0;
    end else if (!enable_i) begin
      state_q <= Fetch;
      aw_done_q <= 1'b0;
      w_done_q <= 1'b0;
      ar_done_q <= 1'b0;
      fetch_q <= 1'b0;
      store_m_q <= 1'b0;
    end else unique case (state_q)
      Fetch: begin
        addr_q <= pc_q;
        store_m_q <= 1'b0;
        fetch_q <= 1'b1;
        ar_done_q <= 1'b0;
        aw_done_q <= 1'b0;
        w_done_q <= 1'b0;
        state_q <= Bus;
      end
      Exec: begin
        automatic logic [31:0] inst = inst_q;
        automatic logic [6:0] opc = inst[6:0];
        automatic logic [4:0] rd = inst[11:7];
        automatic logic [4:0] rs1 = inst[19:15];
        automatic logic [4:0] rs2 = inst[24:20];
        automatic logic [2:0] f3 = inst[14:12];
        automatic logic signed [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
        automatic logic signed [31:0] imm_s =
            {{20{inst[31]}}, inst[31:25], inst[11:7]};
        automatic logic signed [31:0] imm_b =
            {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
        automatic logic signed [31:0] imm_j =
            {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
        automatic logic [63:0] imm_u = {{32{inst[31]}}, inst[31:12], 12'b0};
        automatic logic [63:0] rs1v = (rs1 == 0) ? 64'h0 : rf_q[rs1];
        automatic logic [63:0] rs2v = (rs2 == 0) ? 64'h0 : rf_q[rs2];
        automatic logic [63:0] ea;
        automatic logic [63:0] next_pc;
        automatic logic [31:0] w32;
        automatic logic take = 1'b0;
        next_pc = pc_q + 64'd4;
        store_m_q <= 1'b0;
        fetch_q <= 1'b0;
        aw_done_q <= 1'b0;
        w_done_q <= 1'b0;
        ar_done_q <= 1'b0;
        unique case (opc)
          7'b0110111: if (rd != 0) rf_q[rd] <= imm_u;
          7'b0010111: if (rd != 0) rf_q[rd] <= pc_q + imm_u;
          7'b1101111: begin
            if (rd != 0) rf_q[rd] <= pc_q + 64'd4;
            next_pc = pc_q + 64'(imm_j);
          end
          7'b1100111: begin
            if (rd != 0) rf_q[rd] <= pc_q + 64'd4;
            next_pc = (rs1v + 64'(imm_i)) & ~64'd1;
          end
          7'b1100011: begin
            unique case (f3)
              3'b000: take = rs1v == rs2v;
              3'b001: take = rs1v != rs2v;
              3'b100: take = $signed(rs1v) < $signed(rs2v);
              3'b101: take = $signed(rs1v) >= $signed(rs2v);
              default: take = 1'b0;
            endcase
            if (take) next_pc = pc_q + 64'(imm_b);
          end
          7'b0010011: begin
            unique case (f3)
              3'b000: if (rd != 0) rf_q[rd] <= rs1v + 64'(imm_i);
              3'b001: if (rd != 0) rf_q[rd] <= rs1v << inst[25:20];
              3'b101: if (rd != 0 && !inst[30])
                rf_q[rd] <= rs1v >> inst[25:20];
              3'b111: if (rd != 0) rf_q[rd] <= rs1v & 64'(imm_i);
              default: ;
            endcase
          end
          7'b0011011: if (rd != 0 && f3 == 3'b000) begin
            w32 = rs1v[31:0] + 32'(imm_i);
            rf_q[rd] <= {{32{w32[31]}}, w32};
          end
          7'b0110011: if (rd != 0 && f3 == 3'b000 && inst[31:25] == 7'd0)
            rf_q[rd] <= rs1v + rs2v;
          7'b0111011: if (rd != 0 && f3 == 3'b000 && inst[31:25] == 7'd0) begin
            w32 = rs1v[31:0] + rs2v[31:0];
            rf_q[rd] <= {{32{w32[31]}}, w32};
          end
          7'b0000011, 7'b0100011: begin
            ea = rs1v + ((opc == 7'b0000011) ? 64'(imm_i) : 64'(imm_s));
            addr_q <= ea;
            rd_q <= rd;
            load64_q <= (opc == 7'b0000011 && f3 == 3'b011);
            if (opc == 7'b0100011) begin
              store_q <= rs2v[31:0];
              if (ea == CookieAddr) cookie_q <= rs2v[31:0];
              if (in_bus(ea)) store_m_q <= 1'b1;
            end
            if (in_bus(ea)) state_q <= Bus;
          end
          default: ;
        endcase
        ea = rs1v + ((opc == 7'b0000011) ? 64'(imm_i) :
                     (opc == 7'b0100011) ? 64'(imm_s) : 64'h0);
        if (!(opc == 7'b0000011 || opc == 7'b0100011) || !in_bus(ea)) begin
          pc_q <= next_pc;
          state_q <= Fetch;
        end
      end
      Bus: begin
        if (store_m_q) begin
          if (!aw_done_q && axi_req_o.aw_valid && axi_rsp_i.aw_ready)
            aw_done_q <= 1'b1;
          if (!w_done_q && axi_req_o.w_valid && axi_rsp_i.w_ready)
            w_done_q <= 1'b1;
          if (axi_rsp_i.b_valid && axi_req_o.b_ready) begin
            pc_q <= pc_q + 64'd4;
            state_q <= Fetch;
            aw_done_q <= 1'b0;
            w_done_q <= 1'b0;
            store_m_q <= 1'b0;
          end
        end else begin
          if (!ar_done_q && axi_req_o.ar_valid && axi_rsp_i.ar_ready)
            ar_done_q <= 1'b1;
          if (axi_rsp_i.r_valid && axi_req_o.r_ready) begin
            if (fetch_q) inst_q <= axi_rsp_i.r.data;
            else if (rd_q != 0)
              rf_q[rd_q] <= load64_q ? {32'h0, axi_rsp_i.r.data}
                  : {{32{axi_rsp_i.r.data[31]}}, axi_rsp_i.r.data};
            if (fetch_q) state_q <= Exec;
            else begin
              pc_q <= pc_q + 64'd4;
              state_q <= Fetch;
            end
            fetch_q <= 1'b0;
            ar_done_q <= 1'b0;
          end
        end
      end
      default: state_q <= Fetch;
    endcase
  end
endmodule
