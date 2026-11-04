// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-036 virtio-blk backend (contract: architecture/virtio-mmio.md
// "virtio-blk backend contract"). Executes one request handed over by the
// ST-035 ring engine: header parse, IN/OUT/GET_ID, UNSUPP for everything else,
// IOERR checks that complete before any store write, then the status byte.
//
// Ports: its own single-beat DMA port (same seam as the ring engine) and a
// block-store seam addressed in bytes (sector * 512 + 8 * k). Both allow one
// outstanding beat; a presented request is held until grant, except that
// reset_pending_i withdraws an ungranted one. The first binding is a volatile
// labelled model store: an OUT completion is not a durability claim.
//
// Profile limits (IOERR, no store side effect): data segments must be 8-byte
// aligned with lengths that are multiples of 8; the GET_ID buffer must be
// 8-byte aligned. The header and status byte may sit at any byte address.
module g6lc_storamic_virtio_blk #(
  parameter int unsigned MaxSegs = 8,
  localparam int unsigned SegW = $clog2(MaxSegs + 1)
) (
  input logic clk_i,
  input logic rst_ni,
  input logic reset_pending_i,
  output logic idle_o,
  // request from the ring engine
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [SegW-1:0] req_nsegs_i,
  input logic [MaxSegs-1:0][63:0] req_seg_addr_i,
  input logic [MaxSegs-1:0][31:0] req_seg_len_i,
  input logic [MaxSegs-1:0] req_seg_write_i,
  output logic rsp_valid_o,
  output logic [31:0] rsp_written_len_o,
  output logic rsp_fault_o,
  // DMA window and port
  input logic [63:0] dma_base_i,
  input logic [63:0] dma_size_i,
  output logic dma_req_o,
  input logic dma_gnt_i,
  output logic dma_we_o,
  output logic [63:0] dma_addr_o,
  output logic [63:0] dma_wdata_o,
  output logic [7:0] dma_be_o,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  // block store
  input logic store_ready_i,
  input logic [63:0] capacity_i,
  input logic [159:0] serial_i,
  output logic st_req_o,
  input logic st_gnt_i,
  output logic st_we_o,
  output logic [63:0] st_addr_o,
  output logic [63:0] st_wdata_o,
  output logic [7:0] st_be_o,
  input logic st_rvalid_i,
  input logic [63:0] st_rdata_i,
  input logic st_err_i
);
  if (MaxSegs < 2) begin : gen_param_guard
    // pragma translate_off
    initial $fatal(1, "STORAMIC_VIRTIO_BLK_PARAM");
    // pragma translate_on
  end

  localparam logic [7:0] StOk = 8'd0, StIoErr = 8'd1, StUnsupp = 8'd2;
  localparam logic [31:0] TIn = 32'd0, TOut = 32'd1, TGetId = 32'd8;

  typedef enum logic [3:0] {
    SIdle, SHdr, SParse, SCheck, SInRd, SInWr, SOutRd, SOutWr, SId, SStatus, SRsp,
    SFault, SDrain
  } state_t;

  state_t state_q;
  logic [SegW-1:0] nsegs_q, seg_q;
  logic [MaxSegs-1:0][63:0] saddr_q;
  logic [MaxSegs-1:0][31:0] slen_q;
  logic [MaxSegs-1:0] swr_q;
  logic [191:0] hdr_q;
  logic [1:0] hbeat_q, hbeats_q;
  logic [31:0] type_q;
  logic [63:0] sector_q;
  logic [31:0] off_q;            // byte offset inside the current data segment
  logic [63:0] st_off_q;         // byte offset inside the store
  logic [63:0] word_q;
  logic [7:0] status_q;
  logic [31:0] wlen_q;
  logic [31:0] total_q;
  // port state
  logic dpend_q, dout_q, dwe_q, spend_q, sout_q, swe_q;
  logic [63:0] daddr_q, dwdata_q, saddr_st_q, swdata_q;
  logic [7:0] dbe_q;
  logic rsp_q, rsp_fault_q;

  assign idle_o = !dpend_q && !dout_q && !spend_q && !sout_q;
  // A beat abandoned by reset may still be outstanding: accept the next
  // request only once both ports are quiet (found by vblk-formal).
  assign req_ready_o = (state_q == SIdle) && !reset_pending_i && idle_o;
  assign rsp_valid_o = rsp_q;
  assign rsp_written_len_o = wlen_q;
  assign rsp_fault_o = rsp_fault_q;
  assign dma_req_o = dpend_q;
  assign dma_we_o = dwe_q;
  assign dma_addr_o = daddr_q;
  assign dma_wdata_o = dwdata_q;
  assign dma_be_o = dbe_q;
  assign st_req_o = spend_q;
  assign st_we_o = swe_q;
  assign st_addr_o = saddr_st_q;
  assign st_wdata_o = swdata_q;
  assign st_be_o = 8'hFF;

  // The window is clipped at 2^64 and beat addresses are formed in 65 bits, so
  // no accepted beat wraps to a low address (found by vblk-formal).
  logic [64:0] win_sum, win_end;
  assign win_sum = {1'b0, dma_base_i} + {1'b0, dma_size_i};
  assign win_end = win_sum[64] ? {1'b1, 64'h0} : win_sum;
  function automatic logic beat_ok(input logic [64:0] a, input logic [63:0] base,
                                   input logic [64:0] wend);
    return (a >= {1'b0, base}) && (a + 65'd8 <= wend);
  endfunction

  logic [64:0] hdr_a0;
  assign hdr_a0 = {1'b0, req_seg_addr_i[0] & ~64'h7};

  logic drsp, srsp;
  assign drsp = dout_q && dma_rvalid_i;
  assign srsp = sout_q && st_rvalid_i;

  // Structural and semantic checks over the latched segment table.
  logic [SegW-1:0] last;
  assign last = nsegs_q - 1'b1;
  logic [127:0] hdr_bytes;
  assign hdr_bytes = 128'(hdr_q >> (8 * saddr_q[0][2:0]));
  // win_ok: every data beat lies inside the DMA window (found by vblk-formal;
  // the contract requires the backend's own window check). data_total is
  // summed wide so a wrapped 32-bit sum cannot defeat the capacity check.
  logic dir_ok, align_ok, ok_len, win_ok;
  logic [39:0] data_total;
  logic [64:0] end_sector;
  always_comb begin
    dir_ok = 1'b1; align_ok = 1'b1; win_ok = 1'b1; data_total = '0;
    for (int i = 1; i < MaxSegs; i++) begin
      if (i < int'(last)) begin
        data_total = data_total + 40'(slen_q[i]);
        // The transfer loop moves at least one beat per data segment, so an
        // empty segment is refused rather than read out of bounds.
        if (saddr_q[i][2:0] != 0 || slen_q[i][2:0] != 0 || slen_q[i] == 0) align_ok = 1'b0;
        if ({1'b0, saddr_q[i]} < {1'b0, dma_base_i} ||
            {1'b0, saddr_q[i]} + 65'(slen_q[i]) > win_end) win_ok = 1'b0;
        if (type_q == TIn && !swr_q[i]) dir_ok = 1'b0;
        if (type_q == TOut && swr_q[i]) dir_ok = 1'b0;
      end
    end
    ok_len = data_total[8:0] == 9'd0 && data_total < 40'hFFFF_FFFF;
    end_sector = {1'b0, sector_q} + 65'(data_total >> 9);
  end
  logic id_ok;
  assign id_ok = last == 2 && swr_q[1] && slen_q[1] >= 32'd20 && saddr_q[1][2:0] == 0 &&
                 {1'b0, saddr_q[1]} >= {1'b0, dma_base_i} &&
                 {1'b0, saddr_q[1]} + 65'd24 <= win_end;

  // Next data segment index (skipping none: all data segments are non-empty).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= SIdle;
      nsegs_q <= '0; seg_q <= '0; saddr_q <= '0; slen_q <= '0; swr_q <= '0;
      hdr_q <= '0; hbeat_q <= '0; hbeats_q <= '0; type_q <= '0; sector_q <= '0;
      off_q <= '0; st_off_q <= '0; word_q <= '0; status_q <= '0;
      wlen_q <= '0; total_q <= '0;
      dpend_q <= 1'b0; dout_q <= 1'b0; dwe_q <= 1'b0; daddr_q <= '0;
      dwdata_q <= '0; dbe_q <= '0;
      spend_q <= 1'b0; sout_q <= 1'b0; swe_q <= 1'b0; saddr_st_q <= '0;
      swdata_q <= '0;
      rsp_q <= 1'b0; rsp_fault_q <= 1'b0;
    end else begin
      rsp_q <= 1'b0;
      rsp_fault_q <= 1'b0;
      if (dpend_q && dma_gnt_i) begin dpend_q <= 1'b0; dout_q <= 1'b1; end
      if (drsp) dout_q <= 1'b0;
      if (spend_q && st_gnt_i) begin spend_q <= 1'b0; sout_q <= 1'b1; end
      if (srsp) sout_q <= 1'b0;

      if (reset_pending_i) begin
        if (!(dpend_q && dma_gnt_i)) dpend_q <= 1'b0;
        if (!(spend_q && st_gnt_i)) spend_q <= 1'b0;
        state_q <= SIdle;
      end else begin
        unique case (state_q)
          SIdle: if (req_valid_i && req_ready_o) begin
            nsegs_q <= req_nsegs_i; saddr_q <= req_seg_addr_i;
            slen_q <= req_seg_len_i; swr_q <= req_seg_write_i;
            if (req_nsegs_i < 2 || req_seg_write_i[0] || req_seg_len_i[0] < 32'd16 ||
                !req_seg_write_i[req_nsegs_i - 1'b1] ||
                !beat_ok(hdr_a0, dma_base_i, win_end) ||
                !beat_ok(hdr_a0 + 65'd16, dma_base_i, win_end) &&
                    req_seg_addr_i[0][2:0] != 0 ||
                !beat_ok(hdr_a0 + 65'd8, dma_base_i, win_end) ||
                !beat_ok({1'b0, req_seg_addr_i[req_nsegs_i - 1'b1] & ~64'h7}, dma_base_i,
                         win_end)) begin
              state_q <= SFault;
            end else begin
              hbeat_q <= '0;
              hbeats_q <= (req_seg_addr_i[0][2:0] == 0) ? 2'd2 : 2'd3;
              dpend_q <= 1'b1; dwe_q <= 1'b0; dbe_q <= '0; dwdata_q <= '0;
              daddr_q <= req_seg_addr_i[0] & ~64'h7;
              state_q <= SHdr;
            end
          end
          SHdr: if (drsp) begin
            if (dma_err_i) state_q <= SFault;
            else begin
              hdr_q[64 * hbeat_q +: 64] <= dma_rdata_i;
              if (hbeat_q + 2'd1 == hbeats_q) state_q <= SParse;
              else begin
                hbeat_q <= hbeat_q + 2'd1;
                dpend_q <= 1'b1; daddr_q <= daddr_q + 64'd8;
              end
            end
          end
          SParse: begin
            type_q <= hdr_bytes[31:0];
            sector_q <= hdr_bytes[127:64];
            state_q <= SCheck;
          end
          SCheck: begin
            // type_q/sector_q are latched; dir/align/length checks read them.
            wlen_q <= 32'd1;
            state_q <= SStatus;
            if (type_q == TIn || type_q == TOut) begin
              if (!dir_ok || !align_ok || !ok_len || !win_ok || !store_ready_i ||
                  end_sector > {1'b0, capacity_i}) begin
                status_q <= StIoErr;
              end else if (data_total == 0) begin
                status_q <= StOk;
              end else begin
                total_q <= data_total[31:0];
                seg_q <= 1; off_q <= '0;
                st_off_q <= {sector_q[54:0], 9'h0};
                if (type_q == TIn) begin
                  spend_q <= 1'b1; swe_q <= 1'b0;
                  saddr_st_q <= {sector_q[54:0], 9'h0};
                  state_q <= SInRd;
                end else begin
                  dpend_q <= 1'b1; dwe_q <= 1'b0; dbe_q <= '0;
                  daddr_q <= saddr_q[1];
                  state_q <= SOutRd;
                end
              end
            end else if (type_q == TGetId) begin
              if (!id_ok) status_q <= StIoErr;
              else begin
                off_q <= '0;
                dpend_q <= 1'b1; dwe_q <= 1'b1; dbe_q <= 8'hFF;
                daddr_q <= saddr_q[1]; dwdata_q <= serial_i[63:0];
                state_q <= SId;
              end
            end else status_q <= StUnsupp;
          end
          SInRd: if (srsp) begin
            if (st_err_i) begin
              status_q <= StIoErr; state_q <= SStatus;
            end else begin
              dpend_q <= 1'b1; dwe_q <= 1'b1; dbe_q <= 8'hFF;
              daddr_q <= saddr_q[seg_q] + {32'h0, off_q}; dwdata_q <= st_rdata_i;
              state_q <= SInWr;
            end
          end
          SInWr: if (drsp) begin
            if (dma_err_i) state_q <= SFault;
            else if (off_q + 32'd8 < slen_q[seg_q] || seg_q + 1'b1 < last) begin
              if (off_q + 32'd8 < slen_q[seg_q]) off_q <= off_q + 32'd8;
              else begin off_q <= '0; seg_q <= seg_q + 1'b1; end
              st_off_q <= st_off_q + 64'd8;
              spend_q <= 1'b1; swe_q <= 1'b0; saddr_st_q <= st_off_q + 64'd8;
              state_q <= SInRd;
            end else begin
              status_q <= StOk; wlen_q <= total_q + 32'd1; state_q <= SStatus;
            end
          end
          SOutRd: if (drsp) begin
            if (dma_err_i) state_q <= SFault;
            else begin
              spend_q <= 1'b1; swe_q <= 1'b1; saddr_st_q <= st_off_q;
              swdata_q <= dma_rdata_i;
              state_q <= SOutWr;
            end
          end
          SOutWr: if (srsp) begin
            if (st_err_i) begin
              status_q <= StIoErr; state_q <= SStatus;
            end else if (off_q + 32'd8 < slen_q[seg_q] || seg_q + 1'b1 < last) begin
              if (off_q + 32'd8 < slen_q[seg_q]) begin
                off_q <= off_q + 32'd8;
                daddr_q <= saddr_q[seg_q] + {32'h0, off_q} + 64'd8;
              end else begin
                off_q <= '0; seg_q <= seg_q + 1'b1;
                daddr_q <= saddr_q[seg_q + 1'b1];
              end
              st_off_q <= st_off_q + 64'd8;
              dpend_q <= 1'b1; dwe_q <= 1'b0; dbe_q <= '0;
              state_q <= SOutRd;
            end else begin
              status_q <= StOk; state_q <= SStatus;
            end
          end
          SId: if (drsp) begin
            if (dma_err_i) state_q <= SFault;
            else if (off_q == 32'd0) begin
              off_q <= 32'd8; dpend_q <= 1'b1; daddr_q <= daddr_q + 64'd8;
              dwdata_q <= serial_i[127:64];
            end else if (off_q == 32'd8) begin
              off_q <= 32'd16; dpend_q <= 1'b1; daddr_q <= daddr_q + 64'd8;
              dwdata_q <= {32'h0, serial_i[159:128]}; dbe_q <= 8'h0F;
            end else begin
              status_q <= StOk; wlen_q <= 32'd21; state_q <= SStatus;
            end
          end
          SStatus: if (!dout_q && !sout_q && !dpend_q && !spend_q) begin
            // Status byte, single byte enable, after every data beat.
            dpend_q <= 1'b1; dwe_q <= 1'b1;
            daddr_q <= saddr_q[last] & ~64'h7;
            dbe_q <= 8'h01 << saddr_q[last][2:0];
            dwdata_q <= {56'h0, status_q} << (8 * saddr_q[last][2:0]);
            if (status_q != StOk) wlen_q <= 32'd1;
            state_q <= SRsp;
          end
          SRsp: if (drsp) begin
            if (dma_err_i) state_q <= SFault;
            else begin
              rsp_q <= 1'b1; state_q <= SIdle;
            end
          end
          SFault: if (!dout_q && !sout_q && !dpend_q && !spend_q) begin
            rsp_q <= 1'b1; rsp_fault_q <= 1'b1; state_q <= SIdle;
          end
          default: state_q <= SIdle;
        endcase
      end
    end
  end
endmodule
