// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Interplay: ApuMem --> ScatterGather --> DmaRead. See AGENTS-impl-interplays.md.
module g6lc_apu_sg
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i, invalidate_i,
  input logic load_valid_i,
  output logic load_ready_o,
  input apu_sg_load_t load_i,
  input apu_dma_mapping_t list_mapping_i, backing_mapping_i,
  output logic load_cpl_valid_o,
  input logic load_cpl_ready_i,
  output apu_dma_read_cpl_t load_cpl_o,
  input logic query_valid_i,
  output logic query_ready_o,
  input apu_sg_query_t query_i,
  output logic query_cpl_valid_o,
  input logic query_cpl_ready_i,
  output apu_dma_read_cpl_t query_cpl_o,
  output logic fragment_valid_o,
  input logic fragment_ready_i,
  output apu_sg_fragment_t fragment_o,
  output logic fragment_cancel_o,
  input logic fragment_cpl_valid_i,
  output logic fragment_cpl_ready_o,
  input apu_dma_read_cpl_t fragment_cpl_i,
  input logic fragment_idle_i, fragment_bus_fault_i,
  output logic table_valid_o, idle_o, bus_fault_o,
  output axi_req_t axi_req_o,
  input axi_rsp_t axi_rsp_i
);
  `ifndef SYNTHESIS
  initial assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU SG: invalid configuration");
  `endif
  if (!ApuCfg.Enable || !ApuCfg.SgEn) begin : gen_off
    assign load_ready_o = 0;
    assign load_cpl_valid_o = 0;
    assign load_cpl_o = '0;
    assign query_ready_o = 0;
    assign query_cpl_valid_o = 0;
    assign query_cpl_o = '0;
    assign fragment_valid_o = 0;
    assign fragment_o = '0;
    assign fragment_cancel_o = 0;
    assign fragment_cpl_ready_o = 0;
    assign table_valid_o = 0;
    assign idle_o = 1;
    assign bus_fault_o = 0;
    assign axi_req_o = '0;
  end else begin : gen_on
    localparam int AddrWidth = $clog2(ApuCfg.SgMaxEntries);
    typedef enum logic [4:0] {Idle, LoadCheck, Fetch, Stream, Validate, DupReq,
      DupCapture, Store, LoadFinish, Drain, QueryCheck, RamReq, RamCapture,
      Build, Offer, WaitCpl, WaitIdle, Done, Halted} state_e;
    state_e state_q;
    apu_sg_load_t load_q;
    apu_sg_query_t query_q;
    apu_sg_fragment_t fragment_q, fragment_next;
    apu_dma_mapping_t list_q, backing_q, segment_mapping;
    apu_dma_read_req_t read_req;
    apu_dma_read_data_t read_data;
    apu_dma_read_cpl_t read_cpl;
    apu_dma_status_e status_q, load_status, query_status;
    logic op_load_q, valid_q, fault_q, kill, load_active;
    logic read_ready, read_data_valid, read_data_ready, read_cpl_valid, read_cpl_ready;
    logic read_idle, read_fault, read_cancel, read_done_q;
    logic [31:0] index_q, scan_q, received_q, read_bytes_q, remaining_q, completed_q, fragment_bytes;
    logic [63:0] total_q, cursor_q, segment_start_q, segment_end_q, segment_base_q;
    logic [63:0] word_q;
    logic [3:0] word_left_q, byte_index_q;
    logic [127:0] entry_q;
    logic [64:0] total_next, entry_end, prior_end;
    logic entry_ok, entry_overlap, child_cpl_ok, sg_retire;
    logic ram_req, ram_we;
    logic [AddrWidth-1:0] ram_addr;
    logic [159:0] ram_wdata;
    logic [0:0][159:0] ram_rdata;

    assign kill = cancel_i || invalidate_i || !enable_i;
    assign bus_fault_o = fault_q || read_fault || fragment_bus_fault_i;
    assign idle_o = state_q == Idle && read_idle && fragment_idle_i && !bus_fault_o;
    assign load_ready_o = idle_o && !kill && rst_ni;
    assign query_ready_o = idle_o && !kill && !load_valid_i && rst_ni;
    // The table stays published through an invalidate until the list reader
    // and the fragment DMA are both idle and this unit is not mid-query.
    assign sg_retire = read_idle && fragment_idle_i &&
                       (state_q == Idle || state_q == Done || state_q == Halted);
    assign table_valid_o = valid_q && !bus_fault_o && (enable_i || !sg_retire);
    assign load_cpl_valid_o = state_q == Done && op_load_q;
    assign query_cpl_valid_o = state_q == Done && !op_load_q;
    assign load_cpl_o = load_cpl_valid_o ? apu_dma_read_cpl_t'{status: status_q,
      resource_id: load_q.resource_id, context_id: load_q.context_id, epoch: load_q.epoch,
      bytes: read_bytes_q, tag: load_q.tag} : apu_dma_read_cpl_t'('0);
    assign query_cpl_o = query_cpl_valid_o ? apu_dma_read_cpl_t'{status: status_q,
      resource_id: query_q.req.resource_id, context_id: query_q.req.context_id,
      epoch: query_q.req.epoch, bytes: completed_q, tag: query_q.req.tag} : apu_dma_read_cpl_t'('0);
    assign fragment_valid_o = state_q == Offer;
    assign fragment_o = fragment_valid_o ? fragment_q : apu_sg_fragment_t'('0);
    assign fragment_cpl_ready_o = state_q == WaitCpl;
    assign fragment_cancel_o = (state_q == WaitCpl || state_q == WaitIdle || (fault_q && !op_load_q)) &&
                               (kill || status_q != APU_DMA_OK || fault_q);
    assign load_active = state_q inside {LoadCheck, Fetch, Stream, Validate, DupReq,
      DupCapture, Store, LoadFinish, Drain};
    assign read_cancel = load_active && state_q != Fetch && (kill || status_q != APU_DMA_OK);
    assign read_req = '{resource_id: list_q.resource_id, context_id: list_q.context_id,
      epoch: list_q.epoch, offset: load_q.list_offset, bytes: load_q.entries << 4, tag: load_q.tag};
    assign read_data_ready = load_active && (state_q == Drain || state_q == LoadFinish ||
      kill || status_q != APU_DMA_OK || (state_q == Stream && word_left_q == 0));
    assign read_cpl_ready = load_active && !read_done_q;
    assign total_next = {1'b0, total_q} + {33'h0, entry_q[95:64]};
    assign entry_ok = entry_q[95:64] != 0 && !total_next[64] &&
      entry_q[63:0] >= backing_q.base && 64'(entry_q[95:64]) <= backing_q.bytes &&
      entry_q[63:0] - backing_q.base <= backing_q.bytes - 64'(entry_q[95:64]);
    assign entry_end = {1'b0, entry_q[63:0]} + {33'h0, entry_q[95:64]};
    assign prior_end = {1'b0, ram_rdata[0][63:0]} + {33'h0, ram_rdata[0][95:64]};
    assign entry_overlap = {1'b0, entry_q[63:0]} < prior_end &&
                           {1'b0, ram_rdata[0][63:0]} < entry_end;
    assign child_cpl_ok = fragment_cpl_i.resource_id == fragment_q.req.resource_id &&
      fragment_cpl_i.context_id == fragment_q.req.context_id && fragment_cpl_i.epoch == fragment_q.req.epoch &&
      fragment_cpl_i.tag == fragment_q.req.tag && fragment_cpl_i.bytes <= fragment_q.req.bytes &&
      (fragment_cpl_i.status != APU_DMA_OK || fragment_cpl_i.bytes == fragment_q.req.bytes) &&
      fragment_cpl_i.status <= APU_DMA_STREAM;

    always_comb begin
      load_status = APU_DMA_OK;
      if (!backing_q.valid || load_q.resource_id == 0 || backing_q.resource_id != load_q.resource_id)
        load_status = APU_DMA_BAD_RESOURCE;
      else if (backing_q.context_id != load_q.context_id || list_q.context_id != load_q.context_id ||
               load_q.permissions == 0 || (load_q.permissions & ~backing_q.permissions) != 0)
        load_status = APU_DMA_PERMISSION;
      else if (backing_q.epoch != load_q.epoch) load_status = APU_DMA_STALE;
      else if (load_q.entries == 0 || load_q.entries > ApuCfg.SgMaxEntries || load_q.bytes == 0)
        load_status = APU_DMA_LIMIT;
      else if (!apu_dma_mapping_in_window(ApuCfg, backing_q)) load_status = APU_DMA_BOUNDS;
      else load_status = apu_dma_read_check(ApuCfg, list_q, read_req);

      query_status = APU_DMA_OK;
      if (!table_valid_o || query_q.req.resource_id != load_q.resource_id) query_status = APU_DMA_BAD_RESOURCE;
      else if (query_q.req.context_id != load_q.context_id || !load_q.permissions[query_q.write_access] ||
               (query_q.write_access && !ApuCfg.DmaWriteEn)) query_status = APU_DMA_PERMISSION;
      else if (query_q.req.epoch != load_q.epoch) query_status = APU_DMA_STALE;
      else if (query_q.req.bytes == 0 || query_q.req.bytes > ApuCfg.SgMaxTransferBytes) query_status = APU_DMA_LIMIT;
      else if (query_q.req.offset >= load_q.bytes || 64'(query_q.req.bytes) > load_q.bytes - query_q.req.offset)
        query_status = APU_DMA_BOUNDS;

      segment_mapping = '{valid: 1'b1, permissions: load_q.permissions, resource_id: load_q.resource_id,
        context_id: load_q.context_id, epoch: load_q.epoch, base: segment_base_q,
        bytes: segment_end_q - segment_start_q};
      fragment_bytes = remaining_q;
      if (64'(fragment_bytes) > segment_end_q - cursor_q) fragment_bytes = 32'(segment_end_q - cursor_q);
      if (fragment_bytes > (query_q.write_access ? ApuCfg.DmaWriteMaxBytes : ApuCfg.DmaReadMaxBytes))
        fragment_bytes = query_q.write_access ? ApuCfg.DmaWriteMaxBytes : ApuCfg.DmaReadMaxBytes;
      fragment_next = '0;
      fragment_next.mapping = segment_mapping;
      fragment_next.req = query_q.req;
      fragment_next.req.offset = cursor_q - segment_start_q;
      fragment_next.req.bytes = fragment_bytes;
      fragment_next.transfer_offset = completed_q;
      fragment_next.write_access = query_q.write_access;
      fragment_next.last = fragment_bytes == remaining_q;
    end

    assign ram_req = !kill && !bus_fault_o && status_q == APU_DMA_OK &&
                     (state_q == Store || (state_q == DupReq && scan_q < index_q) ||
                      (state_q == RamReq && index_q < load_q.entries));
    assign ram_we = state_q == Store;
    assign ram_addr = state_q == DupReq ? scan_q[AddrWidth-1:0] : index_q[AddrWidth-1:0];
    assign ram_wdata = {total_next[63:0], entry_q[95:0]};
    tc_sram #(.NumWords(ApuCfg.SgMaxEntries), .DataWidth(160), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_table (
      .clk_i, .rst_ni, .req_i(ram_req), .we_i(ram_we), .addr_i(ram_addr),
      .wdata_i(ram_wdata), .be_i(20'hfffff), .rdata_o(ram_rdata)
    );
    g6lc_apu_dma_read #(.ApuCfg(ApuCfg), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t)) i_list_reader (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1), .cancel_i(read_cancel),
      .req_valid_i(state_q == Fetch), .req_ready_o(read_ready), .req_i(read_req), .mapping_i(list_q),
      .data_valid_o(read_data_valid), .data_ready_i(read_data_ready), .data_o(read_data),
      .cpl_valid_o(read_cpl_valid), .cpl_ready_i(read_cpl_ready), .cpl_o(read_cpl),
      .idle_o(read_idle), .bus_fault_o(read_fault), .axi_req_o, .axi_rsp_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        load_q <= '0; query_q <= '0; fragment_q <= '0; list_q <= '0; backing_q <= '0;
        status_q <= APU_DMA_OK;
        op_load_q <= 0; valid_q <= 0; fault_q <= 0; read_done_q <= 0;
        index_q <= 0; scan_q <= 0; received_q <= 0; read_bytes_q <= 0; remaining_q <= 0; completed_q <= 0;
        total_q <= 0; cursor_q <= 0; segment_start_q <= 0; segment_end_q <= 0; segment_base_q <= 0;
        word_q <= 0; word_left_q <= 0; byte_index_q <= 0; entry_q <= 0;
      end else begin
        if ((invalidate_i || !enable_i) && sg_retire) valid_q <= 0;
        if (kill && status_q == APU_DMA_OK && state_q != Idle && state_q != Done && state_q != Halted)
          status_q <= APU_DMA_CANCELLED;
        if (read_cpl_valid && read_cpl_ready) begin
          read_done_q <= 1;
          read_bytes_q <= read_cpl.bytes;
          if (read_cpl.resource_id != read_req.resource_id || read_cpl.context_id != read_req.context_id ||
              read_cpl.epoch != read_req.epoch || read_cpl.tag != read_req.tag ||
              (read_cpl.status == APU_DMA_OK && read_cpl.bytes != read_req.bytes)) begin
            status_q <= APU_DMA_PROTOCOL;
            fault_q <= 1;
          end else if (status_q == APU_DMA_OK && read_cpl.status != APU_DMA_OK)
            status_q <= read_cpl.status;
        end
        unique case (state_q)
          Idle: begin
            if (load_valid_i && load_ready_o) begin
              load_q <= load_i; list_q <= list_mapping_i; backing_q <= backing_mapping_i;
              op_load_q <= 1; valid_q <= 0; read_done_q <= 0;
              index_q <= 0; scan_q <= 0; received_q <= 0; read_bytes_q <= 0; total_q <= 0;
              word_left_q <= 0; byte_index_q <= 0; entry_q <= 0;
              status_q <= APU_DMA_OK; state_q <= LoadCheck;
            end else if (query_valid_i && query_ready_o) begin
              query_q <= query_i; op_load_q <= 0; completed_q <= 0;
              status_q <= APU_DMA_OK; state_q <= QueryCheck;
            end
          end
          LoadCheck: begin
            if (kill) state_q <= Done;
            else if (load_status != APU_DMA_OK) begin status_q <= load_status; state_q <= Done; end
            else state_q <= Fetch;
          end
          Fetch: if (read_ready) state_q <= Stream;
          Stream: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Drain;
            else if (word_left_q != 0) begin
              entry_q[32'(byte_index_q)*8 +: 8] <= word_q[7:0];
              word_q <= word_q >> 8;
              word_left_q <= word_left_q - 1'b1;
              byte_index_q <= byte_index_q + 1'b1;
              if (byte_index_q == 15) state_q <= Validate;
            end else if (read_data_valid && read_data_ready) begin
              word_q <= read_data.data;
              word_left_q <= 4'($countones(read_data.keep));
              received_q <= received_q + 32'($countones(read_data.keep));
            end
          end
          Validate: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Drain;
            else if (!entry_ok) begin status_q <= APU_DMA_BOUNDS; state_q <= Drain; end
            else begin scan_q <= 0; state_q <= DupReq; end
          end
          DupReq: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Drain;
            else if (scan_q >= index_q) state_q <= Store;
            else state_q <= DupCapture;
          end
          DupCapture: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Drain;
            else if (entry_overlap) begin status_q <= APU_DMA_BOUNDS; state_q <= Drain; end
            else begin scan_q <= scan_q + 1; state_q <= DupReq; end
          end
          Store: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Drain;
            else begin
              total_q <= total_next[63:0];
              index_q <= index_q + 1;
              state_q <= index_q + 1 == load_q.entries ? LoadFinish : Stream;
            end
          end
          LoadFinish: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Drain;
            else if (read_done_q && read_idle) begin
              if (total_q < load_q.bytes || received_q != read_req.bytes || word_left_q != 0 || byte_index_q != 0)
                status_q <= APU_DMA_BOUNDS;
              else valid_q <= 1;
              state_q <= Done;
            end
          end
          Drain: if (read_done_q && (read_idle || read_fault)) state_q <= Done;
          QueryCheck: begin
            if (kill) state_q <= Done;
            else if (query_status != APU_DMA_OK) begin status_q <= query_status; state_q <= Done; end
            else begin
              cursor_q <= query_q.req.offset; remaining_q <= query_q.req.bytes;
              index_q <= 0; segment_start_q <= 0; state_q <= RamReq;
            end
          end
          RamReq: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Done;
            else if (index_q >= load_q.entries) begin status_q <= APU_DMA_BOUNDS; valid_q <= 0; state_q <= Done; end
            else state_q <= RamCapture;
          end
          RamCapture: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Done;
            else if (ram_rdata[0][159:96] <= segment_start_q || ram_rdata[0][159:96] > total_q) begin
              status_q <= APU_DMA_BOUNDS; valid_q <= 0; state_q <= Done;
            end else if (cursor_q >= ram_rdata[0][159:96]) begin
              segment_start_q <= ram_rdata[0][159:96]; index_q <= index_q + 1; state_q <= RamReq;
            end else begin
              segment_end_q <= ram_rdata[0][159:96]; segment_base_q <= ram_rdata[0][63:0]; state_q <= Build;
            end
          end
          Build: begin
            if (kill || status_q != APU_DMA_OK || bus_fault_o) state_q <= Done;
            else if (segment_mapping.base < backing_q.base || segment_mapping.bytes > backing_q.bytes ||
                     segment_mapping.base - backing_q.base > backing_q.bytes - segment_mapping.bytes ||
                     apu_dma_check(ApuCfg, segment_mapping, fragment_next.req, query_q.write_access) != APU_DMA_OK) begin
              status_q <= APU_DMA_BOUNDS; valid_q <= 0; state_q <= Done;
            end else begin fragment_q <= fragment_next; state_q <= Offer; end
          end
          Offer: if (fragment_ready_i) state_q <= WaitCpl;
          WaitCpl: if (fragment_cpl_valid_i) begin
            if (!child_cpl_ok) begin status_q <= APU_DMA_PROTOCOL; fault_q <= 1; valid_q <= 0; state_q <= Done; end
            else begin
              completed_q <= completed_q + fragment_cpl_i.bytes;
              remaining_q <= remaining_q - fragment_cpl_i.bytes;
              cursor_q <= cursor_q + 64'(fragment_cpl_i.bytes);
              if (fragment_cpl_i.status != APU_DMA_OK) status_q <= fragment_cpl_i.status;
              state_q <= WaitIdle;
              if (fragment_cpl_i.status == APU_DMA_PROTOCOL) begin fault_q <= 1; valid_q <= 0; state_q <= Done; end
            end
          end
          WaitIdle: if (fragment_idle_i) begin
            if (kill || status_q != APU_DMA_OK || remaining_q == 0) state_q <= Done;
            else if (cursor_q == segment_end_q) begin
              segment_start_q <= segment_end_q; index_q <= index_q + 1; state_q <= RamReq;
            end else state_q <= Build;
          end
          Done: if ((op_load_q && load_cpl_ready_i) || (!op_load_q && query_cpl_ready_i))
            state_q <= bus_fault_o ? Halted : Idle;
          Halted: ;
          default: state_q <= Halted;
        endcase
        if (read_fault || fragment_bus_fault_i) begin
          fault_q <= 1; valid_q <= 0;
          if (state_q != Idle && state_q != Done && state_q != Halted) status_q <= APU_DMA_PROTOCOL;
        end
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fragment_valid_o && !fragment_ready_i |=> fragment_valid_o && $stable(fragment_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      query_cpl_valid_o && !query_cpl_ready_i |=> query_cpl_valid_o && $stable(query_cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      load_cpl_valid_o && !load_cpl_ready_i |=> load_cpl_valid_o && $stable(load_cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q != Idle |-> !load_ready_o && !query_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      ram_req |-> index_q < ApuCfg.SgMaxEntries);
    `endif
  end
endmodule
