// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness-shaped firmware RAM at ApuHarness FirmwareRamBase (0x90000000 /
// 256 KiB). AXI4-64 slave: byte/half/word single-beat and 64-bit INCR fills
// (CVA6 I$/D$ 16-byte lines are size=3 len=1; D$ lbu is size=0). CVA6 auipc
// of 0x9000xxxx may sign-extend; the window and SRAM index use addr[31:0].
// Writes stay single-beat. Default-off is a SLVERR error slave. Not a CVA6
// fetch proof, not TEX, not on FPGA/Altera maps. FeatureVirgl stays illegal.

module g6lc_apu_fwram
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter int unsigned RamIdx = 12,
  // Simulation-only image. "none" skips preload. 32-bit hex words packed LE
  // into the 64-bit SRAM. Not a CVA6 fetch proof.
  parameter HexFile = "none",
  parameter type axi4_req_t = apu_dma_axi_req_t,
  parameter type axi4_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  axi4_req_t slv_req_i,
  output axi4_rsp_t slv_rsp_o,
  output axi_pkg::xbar_rule_64_t ram_rule_o,
  output logic [63:0] ram_base_o,
  output logic [63:0] ram_end_o
);
  localparam bit RamEn = ApuCfg.Enable && ApuCfg.FirmwareRamBytes != 64'h0;
  localparam logic [63:0] RamBase = ApuCfg.FirmwareRamBase;
  localparam logic [63:0] RamBytes = ApuCfg.FirmwareRamBytes == 0
      ? 64'h8 : ApuCfg.FirmwareRamBytes;
  localparam int unsigned NumWords = int'(RamBytes / 64'd8);
  localparam int unsigned AddrWidth = NumWords > 1 ? $clog2(NumWords) : 1;
  localparam int unsigned IdW = $bits(slv_req_i.aw.id);
  localparam int unsigned LenW = $bits(slv_req_i.ar.len);
  // 16 beats / 128 B covers stream8 16-byte I$/D$ lines with headroom.
  localparam logic [7:0] MaxLen = 8'd15;

  typedef enum logic [3:0] {
    Idle, WaitW, DoWrite, SendB, DoRead, ReadCap, SendR, ErrB, ErrR
  } state_e;

  `ifndef SYNTHESIS
  initial begin
    if (RamEn) begin
      assert (ApuCfg.FirmwareRamBytes[2:0] == 3'b000 &&
              ApuCfg.FirmwareRamBytes >= 64'h8)
        else $fatal(1, "APU fwram: bytes must be 8-byte aligned and >= 8");
      assert (!apu_ranges_overlap(RamBase, ApuCfg.FirmwareRamBytes,
                                  64'h4000_0000, 64'h1000))
        else $fatal(1, "APU fwram: GPIO/AI overlap");
    end
  end
  `endif

  assign ram_rule_o = '{
      idx: RamIdx,
      start_addr: ApuCfg.FirmwareRamBase,
      end_addr: ApuCfg.FirmwareRamBase + ApuCfg.FirmwareRamBytes
  };
  assign ram_base_o = ApuCfg.FirmwareRamBase;
  assign ram_end_o = ApuCfg.FirmwareRamBase + ApuCfg.FirmwareRamBytes;

  function automatic logic wr_ok(input axi4_req_t r);
    logic ok;
    ok = r.aw.len == '0 && r.aw.addr[1:0] == 2'b00 &&
         (r.aw.size == 3'd2 || r.aw.size == 3'd3);
    if (r.aw.size == 3'd3) ok = ok && r.aw.addr[2] == 1'b0;
    return ok;
  endfunction
  function automatic logic in_win(input logic [63:0] a);
    logic [31:0] pa, base, bytes;
    pa = a[31:0];
    base = RamBase[31:0];
    bytes = ApuCfg.FirmwareRamBytes[31:0];
    return pa >= base && (pa - base) < bytes;
  endfunction
  function automatic logic [LenW-1:0] cap_len(input logic [LenW-1:0] len);
    return (8'(len) > MaxLen) ? LenW'(MaxLen) : len;
  endfunction
  function automatic logic rd_ok(input axi4_req_t r);
    logic ok;
    logic [63:0] bytes, last;
    ok = in_win(r.ar.addr);
    if (r.ar.size == 3'd0 || r.ar.size == 3'd1)
      ok = ok && r.ar.len == '0;
    else if (r.ar.size == 3'd2)
      ok = ok && r.ar.len == '0 && r.ar.addr[1:0] == 2'b00;
    else if (r.ar.size == 3'd3) begin
      ok = ok && r.ar.burst == axi_pkg::BURST_INCR && r.ar.addr[2] == 1'b0 &&
           8'(r.ar.len) <= MaxLen;
      bytes = (64'(r.ar.len) + 64'd1) << 3;
      last = {32'b0, r.ar.addr[31:0]} + bytes - 64'd1;
      ok = ok && in_win(last);
    end else
      ok = 1'b0;
    return ok;
  endfunction

  if (!RamEn) begin : gen_off
    state_e state_q;
    logic [IdW-1:0] id_q;
    logic [LenW-1:0] beats_q;
    always_comb begin
      slv_rsp_o = '0;
      unique case (state_q)
        Idle: begin
          slv_rsp_o.aw_ready = 1'b1;
          slv_rsp_o.w_ready  = slv_req_i.aw_valid;
          slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
        end
        WaitW: slv_rsp_o.w_ready = 1'b1;
        ErrB, SendB: begin
          slv_rsp_o.b_valid = 1'b1;
          slv_rsp_o.b.id = id_q;
          slv_rsp_o.b.resp = axi_pkg::RESP_SLVERR;
        end
        default: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = axi_pkg::RESP_SLVERR;
          slv_rsp_o.r.last = (beats_q == '0);
        end
      endcase
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; id_q <= '0; beats_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            state_q <= (slv_req_i.w_valid && slv_rsp_o.w_ready) ? ErrB : WaitW;
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            beats_q <= cap_len(slv_req_i.ar.len);
            state_q <= ErrR;
          end
        end
        WaitW: if (slv_req_i.w_valid) state_q <= ErrB;
        ErrB, SendB: if (slv_req_i.b_ready) state_q <= Idle;
        default: if (slv_req_i.r_ready) begin
          if (beats_q == '0) state_q <= Idle;
          else beats_q <= beats_q - 1;
        end
      endcase
    end
    logic unused;
    assign unused = testmode_i;
  end else begin : gen_on
    state_e state_q;
    logic [IdW-1:0] id_q;
    logic [LenW-1:0] beats_q;
    logic [63:0] addr_q, data_q;
    logic [7:0] strb_q;
    logic ram_req, ram_we;
    logic [AddrWidth-1:0] ram_addr;
    logic [63:0] ram_wdata, ram_rdata;
    logic [7:0] ram_be;
    logic [63:0] off;

    assign off = {32'b0, addr_q[31:0] - RamBase[31:0]};
    assign ram_addr = off[AddrWidth+2:3];
    assign ram_wdata = data_q;
    assign ram_be = strb_q;
    assign ram_req = state_q == DoWrite || state_q == DoRead;
    assign ram_we = state_q == DoWrite;

    tc_sram #(.NumWords(NumWords), .DataWidth(64), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_ram (
      .clk_i, .rst_ni, .req_i(ram_req), .we_i(ram_we), .addr_i(ram_addr),
      .wdata_i(ram_wdata), .be_i(ram_be), .rdata_o(ram_rdata)
    );

    `ifndef SYNTHESIS
    if (HexFile != "none") begin : gen_hex
      logic [31:0] hex32 [0:NumWords*2-1];
      initial begin
        string hexpath;
        integer i, n, lim;
        hexpath = HexFile;
        void'($value$plusargs("APU_FW_HEX=%s", hexpath));
        $readmemh(hexpath, hex32);
        // Prefix only: a full 256 KiB blocking init is Verilator BLKLOOPINIT.
        // Unwritten words stay SimInit("none"). Not a BSS-zero contract.
        n = 0;
        for (i = 0; i < int'(NumWords * 2); i++)
          if (hex32[i] != 32'h0) n = i + 1;
        lim = (n + 1) / 2;
        for (i = 0; i < lim; i++)
          i_ram.sram[i] = {hex32[2*i+1], hex32[2*i]};
      end
    end
    `endif

    always_comb begin
      slv_rsp_o = '0;
      unique case (state_q)
        Idle: begin
          slv_rsp_o.aw_ready = 1'b1;
          slv_rsp_o.w_ready  = slv_req_i.aw_valid;
          slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
        end
        WaitW: slv_rsp_o.w_ready = 1'b1;
        SendB: begin
          slv_rsp_o.b_valid = 1'b1;
          slv_rsp_o.b.id = id_q;
          slv_rsp_o.b.resp = axi_pkg::RESP_OKAY;
        end
        SendR: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = axi_pkg::RESP_OKAY;
          slv_rsp_o.r.last = (beats_q == '0);
          slv_rsp_o.r.data = data_q;
        end
        ErrB: begin
          slv_rsp_o.b_valid = 1'b1;
          slv_rsp_o.b.id = id_q;
          slv_rsp_o.b.resp = axi_pkg::RESP_SLVERR;
        end
        ErrR: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = axi_pkg::RESP_SLVERR;
          slv_rsp_o.r.last = (beats_q == '0);
        end
        default: ;
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; id_q <= '0; beats_q <= '0;
        addr_q <= '0; data_q <= '0; strb_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            addr_q <= slv_req_i.aw.addr;
            if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
              data_q <= slv_req_i.w.data;
              strb_q <= slv_req_i.w.strb;
              state_q <= (wr_ok(slv_req_i) && in_win(slv_req_i.aw.addr) &&
                          slv_req_i.w.last) ? DoWrite : ErrB;
            end else
              state_q <= (wr_ok(slv_req_i) && in_win(slv_req_i.aw.addr))
                         ? WaitW : ErrB;
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            addr_q <= slv_req_i.ar.addr;
            beats_q <= cap_len(slv_req_i.ar.len);
            state_q <= (rd_ok(slv_req_i) && in_win(slv_req_i.ar.addr))
                       ? DoRead : ErrR;
          end
        end
        WaitW: if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
          data_q <= slv_req_i.w.data;
          strb_q <= slv_req_i.w.strb;
          state_q <= slv_req_i.w.last ? DoWrite : ErrB;
        end
        DoWrite: state_q <= SendB;
        SendB: if (slv_req_i.b_ready) state_q <= Idle;
        DoRead: state_q <= ReadCap;
        ReadCap: begin
          data_q <= ram_rdata;
          state_q <= SendR;
        end
        SendR: if (slv_req_i.r_ready) begin
          if (beats_q == '0) state_q <= Idle;
          else begin
            addr_q <= addr_q + 64'd8;
            beats_q <= beats_q - 1;
            state_q <= DoRead;
          end
        end
        ErrB: if (slv_req_i.b_ready) state_q <= Idle;
        default: if (slv_req_i.r_ready) begin
          if (beats_q == '0) state_q <= Idle;
          else beats_q <= beats_q - 1;
        end
      endcase
    end
    logic unused;
    assign unused = testmode_i;
  end
endmodule
