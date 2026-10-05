// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// NextChain joined to checked DmaRead. Descriptor fetches go through the
// existing DMA mapping/window checks and 64-bit AXI read master. Enable=0
// elaborates no datapath. Not wired into g6lc_apu_sys. g6lc_apu_vgpu_avail
// still faults NEXT. FeatureVirgl stays illegal.

// ChainDma (cdma): NextChain joined to checked DmaRead. Default-off. FeatureVirgl stays illegal.
// Interplay: ChainDma (cdma) --> NextChain (chain) --> DmaRead ==> AXI. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_cdma
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_chain_req_t req_i,
  input  apu_dma_mapping_t mapping_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_chain_cpl_t cpl_o,
  output apu_chain_t chain_o,
  output logic idle_o,
  output logic bus_fault_o,
  output apu_dma_axi_req_t axi_req_o,
  input  apu_dma_axi_resp_t axi_rsp_i
);
  function automatic apu_cfg_t cdma_cfg();
    apu_cfg_t cfg;
    cfg = ApuP1Transport;
    cfg.DmaReadEn = 1'b1;
    cfg.DmaWindowBase = APU_CDMA_WIN_BASE;
    cfg.DmaWindowBytes = APU_CDMA_WIN_BYTES;
    cfg.DmaReadBurstBeats = unsigned'(16);
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = APU_CDMA_WIN_BASE + APU_CDMA_WIN_BYTES;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign chain_o = '0;
    assign idle_o = 1'b1;
    assign bus_fault_o = 1'b0;
    assign axi_req_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                    (|req_i) | (|mapping_i) | (|axi_rsp_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, DmaReq, DmaCollect, DmaCpl, ChainRsp } state_e;
    state_e state_q;
    logic chain_rd_v, chain_rd_r, chain_rsp_v, chain_rsp_r, chain_rsp_ok;
    logic [63:0] chain_rd_addr;
    logic [31:0] chain_rd_len;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] chain_rsp_data;
    logic dma_req_v, dma_req_r, dma_data_v, dma_data_r, dma_cpl_v, dma_cpl_r;
    logic dma_idle, dma_fault;
    apu_dma_read_req_t dma_req;
    apu_dma_read_data_t dma_data;
    apu_dma_read_cpl_t dma_cpl;
    logic [127:0] desc_q;
    logic [63:0] addr_q;
    logic ok_q;

    g6lc_apu_chain #(.Enable(1'b1)) i_chain (
      .clk_i, .rst_ni,
      .req_valid_i, .req_ready_o, .req_i,
      .cpl_valid_o, .cpl_ready_i, .cpl_o, .chain_o,
      .rd_valid_o(chain_rd_v), .rd_ready_i(chain_rd_r),
      .rd_addr_o(chain_rd_addr), .rd_len_o(chain_rd_len),
      .rd_rsp_valid_i(chain_rsp_v), .rd_rsp_ready_o(chain_rsp_r),
      .rd_rsp_ok_i(chain_rsp_ok), .rd_rsp_addr_i(addr_q),
      .rd_rsp_len_i(32'(APU_CHAIN_DESC_BYTES)), .rd_rsp_data_i(chain_rsp_data)
    );

    g6lc_apu_dma_read #(.ApuCfg(cdma_cfg())) i_dma (
      .clk_i, .rst_ni, .testmode_i(1'b1), .enable_i(1'b1), .cancel_i(1'b0),
      .req_valid_i(dma_req_v), .req_ready_o(dma_req_r), .req_i(dma_req),
      .mapping_i(mapping_i),
      .data_valid_o(dma_data_v), .data_ready_i(dma_data_r), .data_o(dma_data),
      .cpl_valid_o(dma_cpl_v), .cpl_ready_i(dma_cpl_r), .cpl_o(dma_cpl),
      .idle_o(dma_idle), .bus_fault_o(dma_fault),
      .axi_req_o, .axi_rsp_i
    );

    assign idle_o = (state_q == Idle) && dma_idle && !chain_rd_v;
    assign bus_fault_o = dma_fault;
    assign chain_rd_r = state_q == Idle;
    assign dma_req_v = state_q == DmaReq;
    assign dma_data_r = state_q == DmaCollect;
    assign dma_cpl_r = state_q == DmaCpl;
    assign chain_rsp_v = state_q == ChainRsp;
    assign chain_rsp_ok = ok_q;
    assign chain_rsp_data = {128'h0, desc_q};
    assign dma_req = '{
      resource_id: mapping_i.resource_id,
      context_id: mapping_i.context_id,
      epoch: mapping_i.epoch,
      offset: addr_q - mapping_i.base,
      bytes: 32'(APU_CHAIN_DESC_BYTES),
      tag: addr_q
    };

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        desc_q <= '0;
        addr_q <= '0;
        ok_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (chain_rd_v && chain_rd_r) begin
          addr_q <= chain_rd_addr;
          desc_q <= '0;
          ok_q <= 1'b0;
          if (!mapping_i.valid || chain_rd_len != 32'(APU_CHAIN_DESC_BYTES) ||
              chain_rd_addr < mapping_i.base ||
              64'(APU_CHAIN_DESC_BYTES) > mapping_i.bytes ||
              (chain_rd_addr - mapping_i.base) >
                  mapping_i.bytes - 64'(APU_CHAIN_DESC_BYTES))
            state_q <= ChainRsp;
          else
            state_q <= DmaReq;
        end
        DmaReq: if (dma_req_r) state_q <= DmaCollect;
        DmaCollect: begin
          if (dma_data_v) begin
            if (dma_data.offset == 32'd0) desc_q[63:0] <= dma_data.data;
            else if (dma_data.offset == 32'd8) desc_q[127:64] <= dma_data.data;
            if (dma_data.last) state_q <= DmaCpl;
          end else if (dma_cpl_v) begin
            ok_q <= 1'b0;
            state_q <= DmaCpl;
          end
        end
        DmaCpl: if (dma_cpl_v) begin
          ok_q <= (dma_cpl.status == APU_DMA_OK);
          state_q <= ChainRsp;
        end
        ChainRsp: if (chain_rsp_r) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end
  end
endmodule

// ChainDma (cdma) enable-0 fixture: NextChain joined to checked DmaRead.
module g6lc_apu_cdma_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_chain_req_t req_i,
  input  apu_dma_mapping_t mapping_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_chain_cpl_t cpl_o,
  output apu_chain_t chain_o,
  output logic idle_o,
  output logic bus_fault_o,
  output apu_dma_axi_req_t axi_req_o,
  input  apu_dma_axi_resp_t axi_rsp_i
);
  g6lc_apu_cdma #(.Enable(Enable)) i_dut (.*);
endmodule
