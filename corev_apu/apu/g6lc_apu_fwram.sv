// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness-shaped firmware RAM at ApuHarness FirmwareRamBase (0x90000000 /
// 256 KiB). AXI4-64 slave: byte/half/word single-beat and 64-bit INCR fills
// (CVA6 I$/D$ 16-byte lines are size=3 len=1; D$ lbu is size=0). The window
// is the full physical range. A sign-extended or other upper-bit alias is
// not that range, and the SRAM index is the offset from the base. Writes
// stay single-beat. Narrow reads are one beat and aligned to their size.
// A 64-bit INCR fill stays inside one 4 KiB page. Exclusive lock and ATOP
// are rejected and do not modify SRAM. An ATOP that carries a read result
// also completes one R. A reserved firmware hart is the only admitted
// source; the hart id is captured with AW/AR. AXI id and PROT are not
// authority. fault_o stays high while a mismatched WLAST is quarantined,
// with no response, until reset. Default-off is a SLVERR error slave.
// Not a CVA6 fetch proof, not TEX, not on FPGA/Altera maps.
// FeatureVirgl stays illegal.

// Interplay: TestharnessLoad --> FwRam ==> 0x90000000. See AGENTS-impl-interplays.md.
module g6lc_apu_fwram
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter int unsigned RamIdx = 12,
  // Simulation-only image. "none" skips preload. 32-bit hex words packed LE
  // into the 64-bit SRAM. Not a CVA6 fetch proof.
  parameter HexFile = "none",
  parameter int unsigned HartIdWidth = 32,
  parameter type axi4_req_t = apu_dma_axi_req_t,
  parameter type axi4_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  logic [HartIdWidth-1:0] aw_hart_i,
  input  logic [HartIdWidth-1:0] ar_hart_i,
  input  axi4_req_t slv_req_i,
  output axi4_rsp_t slv_rsp_o,
  output axi_pkg::xbar_rule_64_t ram_rule_o,
  output logic [63:0] ram_base_o,
  output logic [63:0] ram_end_o,
  output logic fault_o
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
    Idle, WaitW, DoWrite, SendB, DoRead, ReadCap, SendR, ErrB, ErrR, DrainW, Fault
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
  // Normal store. Exclusive lock and every ATOP are a different transaction.
  function automatic logic aw_plain(input axi4_req_t r);
    return r.aw.lock == 1'b0 && r.aw.atop == '0;
  endfunction
  // AtomicLoad, AtomicSwap, and AtomicCompare return the old data on R.
  // AtomicStore does not. A master that only waits for B must not see R.
  function automatic logic atop_returns_r(input axi_pkg::atop_t atop);
    return atop[5:4] == axi_pkg::ATOP_ATOMICLOAD ||
           atop[5:4] == axi_pkg::ATOP_ATOMICSWAP[5:4];
  endfunction
  function automatic logic [7:0] write_mask(input logic [63:0] addr,
      input logic [2:0] size);
    return size == 3'd3 ? 8'hff : (addr[2] ? 8'hf0 : 8'h0f);
  endfunction
  // Full physical range. A wrapped offset is not inside, so an address
  // below the base cannot alias in through unsigned subtraction.
  function automatic logic in_win(input logic [63:0] a);
    return a >= RamBase && (a - RamBase) < ApuCfg.FirmwareRamBytes;
  endfunction
  // Every byte of [addr, addr+nbytes) stays in the window. A span that
  // wraps the top of the physical space is outside.
  function automatic logic span_in_win(input logic [63:0] addr,
      input logic [63:0] nbytes);
    logic [63:0] last;
    if (nbytes == 64'd0) return 1'b0;
    if (addr > (64'hffff_ffff_ffff_ffff - (nbytes - 64'd1))) return 1'b0;
    last = addr + nbytes - 64'd1;
    return in_win(addr) && in_win(last);
  endfunction
  // AXI: a burst stays inside one 4 KiB page. A wrapped span crosses.
  function automatic logic crosses_4k(input logic [63:0] addr,
      input logic [63:0] nbytes);
    logic [63:0] last;
    if (nbytes == 64'd0) return 1'b1;
    if (addr > (64'hffff_ffff_ffff_ffff - (nbytes - 64'd1))) return 1'b1;
    last = addr + nbytes - 64'd1;
    return addr[63:12] != last[63:12];
  endfunction
  function automatic logic rd_ok(input axi4_req_t r);
    logic ok;
    logic [63:0] bytes;
    ok = in_win(r.ar.addr) && r.ar.lock == 1'b0;
    if (r.ar.size == 3'd0)
      ok = ok && r.ar.len == '0;
    else if (r.ar.size == 3'd1)
      ok = ok && r.ar.len == '0 && r.ar.addr[0] == 1'b0;
    else if (r.ar.size == 3'd2)
      ok = ok && r.ar.len == '0 && r.ar.addr[1:0] == 2'b00;
    else if (r.ar.size == 3'd3) begin
      ok = ok && r.ar.burst == axi_pkg::BURST_INCR && r.ar.addr[2:0] == 3'b000 &&
           8'(r.ar.len) <= MaxLen;
      bytes = (64'(r.ar.len) + 64'd1) << 3;
      ok = ok && span_in_win(r.ar.addr, bytes) && !crosses_4k(r.ar.addr, bytes);
    end else
      ok = 1'b0;
    return ok;
  endfunction

  if (!RamEn) begin : gen_off
    state_e state_q;
    logic [IdW-1:0] id_q;
    logic [LenW-1:0] beats_q;
    logic atomic_r_q;
    assign fault_o = (state_q == Fault);
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
        Fault: ;
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
        state_q <= Idle; id_q <= '0; beats_q <= '0; atomic_r_q <= 1'b0;
      end else unique case (state_q)
        Idle: begin
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            beats_q <= slv_req_i.aw.len;
            atomic_r_q <= atop_returns_r(slv_req_i.aw.atop);
            state_q <= WaitW;
            if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
              if (slv_req_i.w.last != (slv_req_i.aw.len == '0)) state_q <= Fault;
              else if (slv_req_i.aw.len == '0) state_q <= ErrB;
              else beats_q <= slv_req_i.aw.len - 1'b1;
            end
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            beats_q <= slv_req_i.ar.len;
            state_q <= ErrR;
          end
        end
        WaitW: if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
          if (slv_req_i.w.last != (beats_q == '0)) state_q <= Fault;
          else if (beats_q == '0) state_q <= ErrB;
          else beats_q <= beats_q - 1'b1;
        end
        ErrB: if (slv_req_i.b_ready) begin
          if (atomic_r_q) begin
            beats_q <= '0;
            atomic_r_q <= 1'b0;
            state_q <= ErrR;
          end else state_q <= Idle;
        end
        SendB: if (slv_req_i.b_ready) state_q <= Idle;
        Fault: ;
        default: if (slv_req_i.r_ready) begin
          if (beats_q == '0) state_q <= Idle;
          else beats_q <= beats_q - 1;
        end
      endcase
    end
    logic unused;
    assign unused = testmode_i | (|aw_hart_i) | (|ar_hart_i);
    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fault_o == (state_q == Fault));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fault_o |-> !slv_rsp_o.aw_ready && !slv_rsp_o.w_ready && !slv_rsp_o.ar_ready &&
                   !slv_rsp_o.b_valid && !slv_rsp_o.r_valid);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      slv_rsp_o.b_valid |-> slv_rsp_o.b.resp != axi_pkg::RESP_EXOKAY);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      slv_rsp_o.r_valid |-> slv_rsp_o.r.resp != axi_pkg::RESP_EXOKAY);
    `endif
  end else begin : gen_on
    state_e state_q;
    logic [IdW-1:0] id_q;
    logic [LenW-1:0] beats_q;
    logic aw_grant_q, ar_grant_q, aw_plain_q, atomic_r_q;
    assign fault_o = (state_q == Fault);
    logic [63:0] addr_q, data_q;
    logic [7:0] strb_q, write_mask_q;
    logic ram_req, ram_we;
    logic [AddrWidth-1:0] ram_addr;
    logic [63:0] ram_wdata, ram_rdata;
    logic [7:0] ram_be;
    logic [63:0] off;

    assign off = addr_q - RamBase;
    assign ram_addr = off[AddrWidth+2:3];
    assign ram_wdata = data_q;
    assign ram_be = strb_q;
    assign ram_req = state_q == DoWrite || state_q == DoRead;
    assign ram_we = state_q == DoWrite;
    `ifndef SYNTHESIS
    always @(posedge clk_i) if (rst_ni && ram_req && !in_win(addr_q))
      $fatal(1, "APU fwram: SRAM access outside the physical window");
    `endif

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
        WaitW, DrainW: slv_rsp_o.w_ready = 1'b1;
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
        aw_grant_q <= 1'b0; ar_grant_q <= 1'b0;
        aw_plain_q <= 1'b0; atomic_r_q <= 1'b0;
        addr_q <= '0; data_q <= '0; strb_q <= '0; write_mask_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            addr_q <= slv_req_i.aw.addr;
            beats_q <= slv_req_i.aw.len;
            aw_grant_q <= apu_ram_source_ok(ApuCfg, 32'(aw_hart_i));
            aw_plain_q <= aw_plain(slv_req_i);
            atomic_r_q <= atop_returns_r(slv_req_i.aw.atop);
            write_mask_q <= write_mask(slv_req_i.aw.addr, slv_req_i.aw.size);
            if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
              data_q <= slv_req_i.w.data;
              strb_q <= slv_req_i.w.strb;
              if (slv_req_i.w.last != (slv_req_i.aw.len == '0)) state_q <= Fault;
              else if (slv_req_i.aw.len != '0) begin
                beats_q <= slv_req_i.aw.len - 1'b1;
                state_q <= DrainW;
              end else
                state_q <= (wr_ok(slv_req_i) && in_win(slv_req_i.aw.addr) &&
                            aw_plain(slv_req_i) &&
                            apu_ram_source_ok(ApuCfg, 32'(aw_hart_i)) &&
                            (slv_req_i.w.strb & ~write_mask(slv_req_i.aw.addr,
                                                          slv_req_i.aw.size)) == '0)
                           ? DoWrite : ErrB;
            end else
              state_q <= (wr_ok(slv_req_i) && in_win(slv_req_i.aw.addr) &&
                          aw_plain(slv_req_i) &&
                          apu_ram_source_ok(ApuCfg, 32'(aw_hart_i)))
                         ? WaitW : DrainW;
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            addr_q <= slv_req_i.ar.addr;
            beats_q <= slv_req_i.ar.len;
            ar_grant_q <= apu_ram_source_ok(ApuCfg, 32'(ar_hart_i));
            state_q <= (rd_ok(slv_req_i) && in_win(slv_req_i.ar.addr) &&
                        apu_ram_source_ok(ApuCfg, 32'(ar_hart_i)))
                       ? DoRead : ErrR;
          end
        end
        WaitW: if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
          data_q <= slv_req_i.w.data;
          strb_q <= slv_req_i.w.strb;
          if (!slv_req_i.w.last) state_q <= Fault;
          else state_q <= (aw_grant_q && aw_plain_q &&
                           (slv_req_i.w.strb & ~write_mask_q) == '0)
                          ? DoWrite : ErrB;
        end
        DrainW: if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
          if (slv_req_i.w.last != (beats_q == '0)) state_q <= Fault;
          else if (beats_q == '0) state_q <= ErrB;
          else beats_q <= beats_q - 1'b1;
        end
        Fault: ;
        DoWrite: state_q <= SendB;
        SendB: if (slv_req_i.b_ready) begin
          atomic_r_q <= 1'b0;
          state_q <= Idle;
        end
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
        ErrB: if (slv_req_i.b_ready) begin
          if (atomic_r_q) begin
            beats_q <= '0;
            atomic_r_q <= 1'b0;
            state_q <= ErrR;
          end else state_q <= Idle;
        end
        default: if (slv_req_i.r_ready) begin
          if (beats_q == '0) state_q <= Idle;
          else beats_q <= beats_q - 1;
        end
      endcase
    end
    logic unused;
    assign unused = testmode_i;
    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == DoWrite |-> aw_grant_q);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == DoRead |-> ar_grant_q);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == DoWrite |-> aw_plain_q && !atomic_r_q);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fault_o == (state_q == Fault));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fault_o |-> !slv_rsp_o.aw_ready && !slv_rsp_o.w_ready && !slv_rsp_o.ar_ready &&
                   !slv_rsp_o.b_valid && !slv_rsp_o.r_valid);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      slv_rsp_o.b_valid |-> slv_rsp_o.b.resp != axi_pkg::RESP_EXOKAY);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      slv_rsp_o.r_valid |-> slv_rsp_o.r.resp != axi_pkg::RESP_EXOKAY);
    `endif
  end
endmodule
