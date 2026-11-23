// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Narrow, timing-clean AXI4 request legality, extent, and byte-lane decode
// extracted from g6lc_storamic_axi_memory (hyp8 8-FO4 redesign).
// Replaces 65-bit loop-based lanes() (144 FO4) and 65-bit extent arithmetic
// with narrow offset/13-bit page-crossing math (exact for all legal AXI4
// INCR/WRAP/FIXED requests up to DataWidth=1024).

module g6lc_storamic_axi_lanes #(
  parameter int unsigned Bytes = 8
) (
  input  logic [((Bytes > 1) ? $clog2(Bytes) : 1)-1:0] off_i,
  input  logic [2:0]                                   size_i,
  output logic [Bytes-1:0]                             lanes_o
);
  localparam int unsigned OffW = (Bytes > 1) ? $clog2(Bytes) : 1;
  localparam int unsigned MaxSize = (Bytes > 1) ? $clog2(Bytes) : 0;

  // For a legal AXI beat (size <= Log2Bytes), the transfer spans bytes
  // [off_i .. (off_i | ((1 << size) - 1))] inside the DataWidth-aligned word.
  // Computed in OffW bits (~3 bits for 64-bit AXI) instead of 65-bit loops.
  logic [OffW-1:0] align_mask, last_off;
  for (genvar b = 0; b < OffW; b++) begin : gen_amask
    assign align_mask[b] = (3'(b) < size_i);
  end
  assign last_off = off_i | align_mask;

  for (genvar i = 0; i < Bytes; i++) begin : gen_lane
    assign lanes_o[i] = (int'(size_i) <= int'(MaxSize)) &&
                        (OffW'(i) >= off_i) && (OffW'(i) <= last_off);
  end
endmodule

module g6lc_storamic_axi_req_check #(
  parameter int unsigned Bytes       = 8,
  parameter bit          MapEn       = 1'b0,
  parameter logic [63:0] BaseAddr    = 64'h8000_0000,
  parameter logic [63:0] RegionBytes = 64'h0001_0000
) (
  input  logic [63:0] addr_i,
  input  logic [7:0]  len_i,
  input  logic [2:0]  size_i,
  input  logic [1:0]  burst_i,
  input  logic        lock_i,
  output logic        legal_o,
  output logic [64:0] first_byte_o,
  output logic [64:0] last_byte_o
);
  localparam int unsigned MaxSize = (Bytes > 1) ? $clog2(Bytes) : 0;
  localparam logic [64:0] RegionEnd = {1'b0, BaseAddr} + {1'b0, RegionBytes};

  // Narrow beat-count / span arithmetic (max legal len=255, size<=7 -> span <= 32768, 16 bits).
  logic [15:0] unit_m1, span_m1;
  logic [12:0] addr_lo12, aligned_lo12, first_lo12, last_lo12;
  logic [11:0] wrap_mask12;
  logic        size_ok, burst_ok, wrap_len_ok, wrap_align_ok, page_ok, win_ok;
  logic [63:0] first_addr, last_addr;
  logic        last_ovf;

  assign size_ok   = !lock_i && (int'(size_i) <= int'(MaxSize));
  assign unit_m1   = (16'd1 << size_i) - 16'd1;
  assign span_m1   = ((16'(len_i) + 16'd1) << size_i) - 16'd1;
  assign addr_lo12 = {1'b0, addr_i[11:0]};
  assign aligned_lo12 = addr_lo12 & ~{1'b0, unit_m1[11:0]};
  assign wrap_mask12  = span_m1[11:0];

  assign wrap_len_ok   = (len_i == 8'd1) || (len_i == 8'd3) ||
                         (len_i == 8'd7) || (len_i == 8'd15);
  assign wrap_align_ok = ((addr_i[11:0] & unit_m1[11:0]) == 12'd0);

  always_comb begin
    burst_ok   = 1'b0;
    first_lo12 = addr_lo12;
    last_lo12  = aligned_lo12 + {1'b0, unit_m1[11:0]};
    unique case (burst_i)
      2'b00: begin
        burst_ok = (len_i <= 8'd15);
      end
      2'b01: begin
        burst_ok  = 1'b1;
        last_lo12 = aligned_lo12 + {1'b0, span_m1[11:0]};
      end
      2'b10: begin
        // For legal WRAP bursts span is a power of two, so wrap_mask12 = 2^k-1:
        // (addr & ~mask) + mask == (addr | mask) with zero 13-bit adder!
        burst_ok   = wrap_len_ok && wrap_align_ok;
        first_lo12 = {1'b0, addr_i[11:0] & ~wrap_mask12};
        last_lo12  = {1'b0, addr_i[11:0] |  wrap_mask12};
      end
      default: burst_ok = 1'b0;
    endcase
  end

  // A legal burst never crosses a 4 KiB page boundary (span_m1[15:12] == 0 and
  // last_lo12[12] == 0). Upper 52 address bits stay constant within the page.
  assign page_ok = (burst_i == 2'b00)
      ? !last_lo12[12]
      : ((span_m1[15:12] == 4'd0) && !last_lo12[12]);
  assign first_addr = {addr_i[63:12], first_lo12[11:0]};
  assign last_addr  = {addr_i[63:12], last_lo12[11:0]};
  assign last_ovf   = !page_ok && (&addr_i[63:12]);
  assign first_byte_o = {1'b0, first_addr};
  assign last_byte_o  = {last_ovf, last_addr};

  if (MapEn) begin : gen_mapped
    assign win_ok = 1'b1;
  end else begin : gen_flat
    assign win_ok = ({1'b0, first_addr} >= {1'b0, BaseAddr}) &&
                    ({1'b0, last_addr}  <  RegionEnd);
  end
  assign legal_o = size_ok && burst_ok && page_ok && !last_ovf && win_ok;
endmodule
