// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One covered sample becomes one RGBA8 pixel. Byte 0 is red, then green,
// blue, and alpha. The address is y * stride + x * 4. A miss leaves the
// surface unchanged. A fault leaves it unchanged. Channel math is
// (w0*c0 + w1*c1 + w2*c2) / area, rounded half up after the signs are
// folded positive. Weights outside signed 16-bit magnitude are a fault.
// use_texel stores the one RGBA8 texel at (0,0) instead of the weighted
// color. Any other texel coordinate is a fault. There is no filter.
// use_image copies one covered sample from the resource-image bytes
// at the same address. use_prog stores the color of one LDC immediate.
// 0, 0.5, and 1 are different pixels. Any other program is a fault.
// Enable=0 stores nothing. This is not the HDMI scanout buffer.

module g6lc_apu_frag
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_img_t img_i,
  input  logic img_we_i,
  input  logic [APU_FRAG_ADDR_BITS-1:0] img_wa_i,
  input  logic [31:0] img_wd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_frag_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_frag_cpl_t cpl_o,
  input  logic [15:0] peek_x_i,
  input  logic [15:0] peek_y_i,
  input  logic [15:0] peek_stride_i,
  output logic [31:0] peek_px_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign peek_px_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|req_i) |
                        (|img_i) | img_we_i | (|img_wa_i) | (|img_wd_i) |
                        (|peek_x_i) | (|peek_y_i) | (|peek_stride_i);
  end else begin : gen_on
    localparam int unsigned MemBytes = APU_FRAG_MEM_BYTES;
    typedef enum logic [2:0] { Idle, Div, Commit, Done } state_e;
    state_e state_q;
    apu_frag_cpl_t cpl_q;
    logic [7:0] mem_q [0:MemBytes-1];
    logic [7:0] img_mem [0:APU_VGPU_IMG_BYTES-1];
    logic [31:0] num_q [0:3];
    logic [15:0] den_q;
    logic [31:0] rem_q, quot_q;
    logic [4:0] bit_q;
    logic [1:0] chan_q;
    logic armed_q;
    logic [7:0] ch_q [0:3];
    logic [APU_FRAG_ADDR_BITS-1:0] addr_q;
    logic [31:0] rem_next, quot_next;

    function automatic logic [7:0] chan_of(input logic [31:0] px, input int unsigned i);
      return px[8*i +: 8];
    endfunction

    function automatic logic fit16(input logic signed [47:0] v);
      return v <= 48'sd32767 && v >= -48'sd32767;
    endfunction

    typedef struct packed {
      logic miss, fault, direct;
      logic [31:0] num0, num1, num2, num3;
      logic [15:0] den;
      logic [APU_FRAG_ADDR_BITS-1:0] addr;
    } prep_t;
    logic [31:0] texel_q;

    function automatic prep_t classify(input apu_frag_req_t req);
      logic signed [47:0] area, w0, w1, w2;
      logic signed [15:0] s0, s1, s2, dens;
      logic signed [31:0] acc;
      logic [31:0] row, pix, lastb;
      logic bad;
      classify = '0;
      classify.miss = !req.frag.covered;
      if (classify.miss) return classify;
      if (req.use_texel) begin
        bad = req.tu != 16'd0 || req.tv != 16'd0;
        bad |= req.x < 0 || req.y < 0;
        bad |= req.width == 0 || req.height == 0 ||
               req.width > APU_FRAG_MAX_W || req.height > APU_FRAG_MAX_H ||
               req.stride > APU_FRAG_MAX_STRIDE || req.stride < {req.width, 2'b00};
        if (!bad) begin
          row = 32'(req.y) * 32'(req.stride);
          pix = row + 32'(req.x) * 32'd4;
          lastb = pix + 32'd3;
          if (lastb >= MemBytes || 32'(req.x) >= 32'(req.width) ||
              32'(req.y) >= 32'(req.height)) bad = 1'b1;
          else classify.addr = pix[APU_FRAG_ADDR_BITS-1:0];
        end
        classify.direct = !bad;
        classify.fault = bad;
        return classify;
      end
      area = req.frag.area;
      w0 = req.frag.w0;
      w1 = req.frag.w1;
      w2 = req.frag.w2;
      bad = area == 0 || (w0 + w1 + w2) != area;
      bad |= !fit16(area) || !fit16(w0) || !fit16(w1) || !fit16(w2);
      bad |= req.x < 0 || req.y < 0;
      bad |= req.width == 0 || req.height == 0 ||
             req.width > APU_FRAG_MAX_W || req.height > APU_FRAG_MAX_H ||
             req.stride > APU_FRAG_MAX_STRIDE || req.stride < {req.width, 2'b00};
      if (!bad) begin
        row = 32'(req.y) * 32'(req.stride);
        pix = row + 32'(req.x) * 32'd4;
        lastb = pix + 32'd3;
        if (lastb >= MemBytes || 32'(req.x) >= 32'(req.width) ||
            32'(req.y) >= 32'(req.height)) bad = 1'b1;
        else classify.addr = pix[APU_FRAG_ADDR_BITS-1:0];
      end
      if (!bad && area < 0) begin
        dens = -area[15:0];
        s0 = -w0[15:0];
        s1 = -w1[15:0];
        s2 = -w2[15:0];
      end else if (!bad) begin
        dens = area[15:0];
        s0 = w0[15:0];
        s1 = w1[15:0];
        s2 = w2[15:0];
      end else begin
        dens = '0;
        s0 = '0;
        s1 = '0;
        s2 = '0;
      end
      for (int c = 0; c < 4; c++) begin
        acc = 32'(s0) * 32'(chan_of(req.c0, c)) +
              32'(s1) * 32'(chan_of(req.c1, c)) +
              32'(s2) * 32'(chan_of(req.c2, c));
        if (acc < 0) bad = 1'b1;
        case (c)
          0: classify.num0 = acc + 32'(dens >>> 1);
          1: classify.num1 = acc + 32'(dens >>> 1);
          2: classify.num2 = acc + 32'(dens >>> 1);
          default: classify.num3 = acc + 32'(dens >>> 1);
        endcase
      end
      classify.den = dens;
      classify.fault = bad || dens == 0;
    endfunction

    always_comb begin
      rem_next = {rem_q[30:0], num_q[chan_q][bit_q]};
      if (rem_next >= {16'd0, den_q}) begin
        rem_next = rem_next - {16'd0, den_q};
        quot_next = {quot_q[30:0], 1'b1};
      end else begin
        quot_next = {quot_q[30:0], 1'b0};
      end
    end

    function automatic logic [31:0] peek_word(
      input logic [15:0] x, y, stride
    );
      logic [31:0] a;
      logic [APU_FRAG_ADDR_BITS-1:0] i0, i1, i2, i3;
      peek_word = '0;
      a = 32'(y) * 32'(stride) + 32'(x) * 32'd4;
      if (a + 32'd3 < MemBytes) begin
        i0 = a[APU_FRAG_ADDR_BITS-1:0];
        i1 = i0 + 5'd1;
        i2 = i0 + 5'd2;
        i3 = i0 + 5'd3;
        peek_word = {mem_q[i3], mem_q[i2], mem_q[i1], mem_q[i0]};
      end
    endfunction

    assign peek_px_o = peek_word(peek_x_i, peek_y_i, peek_stride_i);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_frag_cpl_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        den_q <= '0;
        rem_q <= '0;
        quot_q <= '0;
        bit_q <= '0;
        chan_q <= '0;
        addr_q <= '0;
        armed_q <= 1'b0;
        texel_q <= '0;
        for (int i = 0; i < 4; i++) begin
          num_q[i] <= '0;
          ch_q[i] <= '0;
        end
        mem_q <= '{default: '0};
        img_mem <= '{default: '0};
      end else begin
        if (img_we_i) begin
          img_mem[img_wa_i] <= img_wd_i[7:0];
          img_mem[img_wa_i + APU_FRAG_ADDR_BITS'(1)] <= img_wd_i[15:8];
          img_mem[img_wa_i + APU_FRAG_ADDR_BITS'(2)] <= img_wd_i[23:16];
          img_mem[img_wa_i + APU_FRAG_ADDR_BITS'(3)] <= img_wd_i[31:24];
        end
        unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          prep_t prep;
          logic [31:0] row, pix, lastb, need, px;
          logic bad, go_commit;
          cpl_q.color <= '0;
          go_commit = 1'b0;
          if (req_i.use_prog) begin
            if (!req_i.frag.covered) begin
              cpl_q.status <= APU_FRAG_MISS;
            end else if (req_i.use_image || req_i.use_texel || req_i.texel_write ||
                         req_i.prog0 != APU_EX_LDC_R4_WORD) begin
              cpl_q.status <= APU_FRAG_FAULT;
            end else begin
              if (req_i.prog1 == APU_EX_F32_ZERO) px = 32'hFF00_0000;
              else if (req_i.prog1 == APU_EX_F32_HALF) px = 32'hFF80_8080;
              else if (req_i.prog1 == APU_EX_F32_ONE) px = 32'hFFFF_FFFF;
              else px = '0;
              bad = req_i.prog1 != APU_EX_F32_ZERO &&
                    req_i.prog1 != APU_EX_F32_HALF &&
                    req_i.prog1 != APU_EX_F32_ONE;
              bad |= req_i.x < 0 || req_i.y < 0;
              bad |= req_i.width == 0 || req_i.height == 0 ||
                     req_i.width > APU_FRAG_MAX_W || req_i.height > APU_FRAG_MAX_H ||
                     req_i.stride > APU_FRAG_MAX_STRIDE ||
                     req_i.stride < {req_i.width, 2'b00};
              row = 32'(req_i.y) * 32'(req_i.stride);
              pix = row + 32'(req_i.x) * 32'd4;
              lastb = pix + 32'd3;
              if (!bad && (lastb >= MemBytes || 32'(req_i.x) >= 32'(req_i.width) ||
                           32'(req_i.y) >= 32'(req_i.height))) bad = 1'b1;
              if (bad) begin
                cpl_q.status <= APU_FRAG_FAULT;
              end else begin
                addr_q <= pix[APU_FRAG_ADDR_BITS-1:0];
                ch_q[0] <= px[7:0];
                ch_q[1] <= px[15:8];
                ch_q[2] <= px[23:16];
                ch_q[3] <= px[31:24];
                go_commit = 1'b1;
              end
            end
            if (go_commit) state_q <= Commit;
            else state_q <= Done;
          end else if (req_i.use_image) begin
            if (!req_i.frag.covered) begin
              cpl_q.status <= APU_FRAG_MISS;
            end else if (req_i.use_texel || req_i.texel_write) begin
              cpl_q.status <= APU_FRAG_FAULT;
            end else begin
              bad = !img_i.valid;
              bad |= req_i.x < 0 || req_i.y < 0;
              bad |= req_i.width == 0 || req_i.height == 0 ||
                     req_i.width > APU_FRAG_MAX_W || req_i.height > APU_FRAG_MAX_H ||
                     req_i.stride > APU_FRAG_MAX_STRIDE ||
                     32'(req_i.stride) != 32'(req_i.width) * 32'd4;
              need = 32'(req_i.width) * 32'(req_i.height) * 32'd4;
              bad |= img_i.length != need;
              row = 32'(req_i.y) * 32'(req_i.stride);
              pix = row + 32'(req_i.x) * 32'd4;
              lastb = pix + 32'd3;
              if (!bad && (lastb >= MemBytes || lastb >= img_i.length ||
                           32'(req_i.x) >= 32'(req_i.width) ||
                           32'(req_i.y) >= 32'(req_i.height))) bad = 1'b1;
              if (bad) begin
                cpl_q.status <= APU_FRAG_FAULT;
              end else begin
                px = {img_mem[pix[APU_FRAG_ADDR_BITS-1:0] + APU_FRAG_ADDR_BITS'(3)],
                      img_mem[pix[APU_FRAG_ADDR_BITS-1:0] + APU_FRAG_ADDR_BITS'(2)],
                      img_mem[pix[APU_FRAG_ADDR_BITS-1:0] + APU_FRAG_ADDR_BITS'(1)],
                      img_mem[pix[APU_FRAG_ADDR_BITS-1:0]]};
                addr_q <= pix[APU_FRAG_ADDR_BITS-1:0];
                ch_q[0] <= px[7:0];
                ch_q[1] <= px[15:8];
                ch_q[2] <= px[23:16];
                ch_q[3] <= px[31:24];
                go_commit = 1'b1;
              end
            end
            if (go_commit) state_q <= Commit;
            else state_q <= Done;
          end else if (req_i.texel_write) begin
            if (req_i.use_texel) begin
              cpl_q.status <= APU_FRAG_FAULT;
            end else begin
              texel_q <= req_i.texel;
              cpl_q.status <= APU_FRAG_OK;
              cpl_q.color <= req_i.texel;
            end
            state_q <= Done;
          end else begin
          prep = classify(req_i);
          if (prep.miss) begin
            cpl_q.status <= APU_FRAG_MISS;
            state_q <= Done;
          end else if (prep.fault) begin
            cpl_q.status <= APU_FRAG_FAULT;
            state_q <= Done;
          end else if (prep.direct) begin
            addr_q <= prep.addr;
            ch_q[0] <= texel_q[7:0];
            ch_q[1] <= texel_q[15:8];
            ch_q[2] <= texel_q[23:16];
            ch_q[3] <= texel_q[31:24];
            state_q <= Commit;
          end else begin
            num_q[0] <= prep.num0;
            num_q[1] <= prep.num1;
            num_q[2] <= prep.num2;
            num_q[3] <= prep.num3;
            den_q <= prep.den;
            addr_q <= prep.addr;
            rem_q <= '0;
            quot_q <= '0;
            bit_q <= 5'd31;
            chan_q <= '0;
            state_q <= Div;
          end
          end
        end
        Div: begin
          if (bit_q == 0) begin
            if (quot_next > 32'd255) begin
              cpl_q.status <= APU_FRAG_FAULT;
              cpl_q.color <= '0;
              state_q <= Done;
            end else begin
              ch_q[chan_q] <= quot_next[7:0];
              if (chan_q == 2'd3) state_q <= Commit;
              else begin
                chan_q <= chan_q + 2'd1;
                bit_q <= 5'd31;
                rem_q <= '0;
                quot_q <= '0;
              end
            end
          end else begin
            rem_q <= rem_next;
            quot_q <= quot_next;
            bit_q <= bit_q - 5'd1;
          end
        end
        Commit: begin
          mem_q[addr_q] <= ch_q[0];
          mem_q[addr_q + 5'd1] <= ch_q[1];
          mem_q[addr_q + 5'd2] <= ch_q[2];
          mem_q[addr_q + 5'd3] <= ch_q[3];
          cpl_q.status <= APU_FRAG_OK;
          cpl_q.color <= {ch_q[3], ch_q[2], ch_q[1], ch_q[0]};
          state_q <= Done;
        end
        // The result is visible for a cycle before ready can retire it.
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
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status != APU_FRAG_OK |-> cpl_o.color == '0);
    `endif
  end
endmodule

module g6lc_apu_frag_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_img_t img_i,
  input  logic img_we_i,
  input  logic [APU_FRAG_ADDR_BITS-1:0] img_wa_i,
  input  logic [31:0] img_wd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_frag_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_frag_cpl_t cpl_o,
  input  logic [15:0] peek_x_i,
  input  logic [15:0] peek_y_i,
  input  logic [15:0] peek_stride_i,
  output logic [31:0] peek_px_o
);
  g6lc_apu_frag #(.Enable(Enable)) i_dut (.*);
endmodule
