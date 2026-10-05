// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One covered sample copied from the resource-image bytes onto an
// RGBA8 surface. The ceiling is 64 by 64. The address is y * stride + x * 4. Byte 0 is
// red. A miss leaves the surface unchanged. A fault leaves it
// unchanged. The image must already hold width*height*4 bytes, and
// the stride must be width*4. This is not g6lc_apu_frag, not a draw
// command, and not the HDMI scanout buffer.

// ResourceSurface (surf): One covered sample from the resource image. Default-off. Not a draw command and not the HDMI buffer.
// Interplay: FragStore (frag) --? ResourceSurface (surf); packed-image sample. See AGENTS-impl-interplays.md.
module g6lc_apu_rsurf
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
  input  apu_rsurf_req_t req_i,
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
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|img_i) |
                        img_we_i | (|img_wa_i) | (|img_wd_i) | (|req_i) |
                        (|peek_x_i) | (|peek_y_i) | (|peek_stride_i);
  end else begin : gen_on
    localparam int unsigned MemBytes = APU_FRAG_MEM_BYTES;
    typedef enum logic { Idle, Done } state_e;
    typedef struct packed {
      apu_frag_status_e status;
      logic write;
      logic [31:0] color;
      logic [APU_FRAG_ADDR_BITS-1:0] addr;
    } dec_t;

    state_e state_q;
    apu_frag_cpl_t cpl_q;
    logic [7:0] mem_q [0:MemBytes-1];
    logic [7:0] img_mem [0:APU_VGPU_IMG_BYTES-1];
    logic armed_q;

    function automatic dec_t decode(
      input apu_vgpu_img_t img,
      input apu_rsurf_req_t req
    );
      logic [31:0] row, pix, lastb, need;
      logic bad;
      decode = '0;
      decode.status = APU_FRAG_MISS;
      if (!req.covered) return decode;
      bad = !img.valid;
      bad |= req.x < 0 || req.y < 0;
      bad |= req.width == 0 || req.height == 0 ||
             req.width > APU_FRAG_MAX_W || req.height > APU_FRAG_MAX_H ||
             req.stride > APU_FRAG_MAX_STRIDE ||
             32'(req.stride) != 32'(req.width) * 32'd4;
      need = 32'(req.width) * 32'(req.height) * 32'd4;
      bad |= img.length != need;
      if (!bad) begin
        row = 32'(req.y) * 32'(req.stride);
        pix = row + 32'(req.x) * 32'd4;
        lastb = pix + 32'd3;
        if (lastb >= MemBytes || lastb >= img.length ||
            32'(req.x) >= 32'(req.width) || 32'(req.y) >= 32'(req.height))
          bad = 1'b1;
        else begin
          decode.addr = pix[APU_FRAG_ADDR_BITS-1:0];
          decode.color = {img_mem[decode.addr + APU_FRAG_ADDR_BITS'(3)],
                          img_mem[decode.addr + APU_FRAG_ADDR_BITS'(2)],
                          img_mem[decode.addr + APU_FRAG_ADDR_BITS'(1)],
                          img_mem[decode.addr]};
          decode.write = 1'b1;
          decode.status = APU_FRAG_OK;
        end
      end
      if (bad) begin
        decode.status = APU_FRAG_FAULT;
        decode.write = 1'b0;
        decode.color = '0;
        decode.addr = '0;
      end
    endfunction

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
        armed_q <= 1'b0;
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
          dec_t got;
          got = decode(img_i, req_i);
          cpl_q.status <= got.status;
          cpl_q.color <= got.color;
          if (got.write) begin
            mem_q[got.addr] <= got.color[7:0];
            mem_q[got.addr + 5'd1] <= got.color[15:8];
            mem_q[got.addr + 5'd2] <= got.color[23:16];
            mem_q[got.addr + 5'd3] <= got.color[31:24];
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
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status != APU_FRAG_OK |-> cpl_o.color == 32'h0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(peek_px_o));
    `endif
  end
endmodule

// ResourceSurface (surf) enable-0 fixture: One covered sample from the resource image.
module g6lc_apu_rsurf_fixture
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
  input  apu_rsurf_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_frag_cpl_t cpl_o,
  input  logic [15:0] peek_x_i,
  input  logic [15:0] peek_y_i,
  input  logic [15:0] peek_stride_i,
  output logic [31:0] peek_px_o
);
  g6lc_apu_rsurf #(.Enable(Enable)) i_dut (.*);
endmodule
