// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Protected resource mapping table and one immutable command snapshot.
// Firmware inserts/looks up/invalidates mappings; command bytes are copied
// from a trusted stream into tc_sram and cannot be mutated until release.
// Optional ICG is power-only (IS_FUNCTIONAL=0) and does not drop SRAM state.

module g6lc_apu_storage
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  logic enable_i,
  input  logic cancel_i,
  input  logic invalidate_i,

  input  logic            map_valid_i,
  output logic            map_ready_o,
  input  apu_map_insert_t map_i,
  output logic            map_cpl_valid_o,
  input  logic            map_cpl_ready_i,
  output apu_map_cpl_t    map_cpl_o,

  input  logic            lookup_valid_i,
  output logic            lookup_ready_o,
  input  apu_map_lookup_t lookup_i,
  output logic            lookup_cpl_valid_o,
  input  logic            lookup_cpl_ready_i,
  output apu_map_cpl_t    lookup_cpl_o,
  output apu_dma_mapping_t lookup_mapping_o,

  input  logic           inval_valid_i,
  output logic           inval_ready_o,
  input  apu_map_inval_t inval_i,
  output logic           inval_cpl_valid_o,
  input  logic           inval_cpl_ready_i,
  output apu_map_cpl_t   inval_cpl_o,

  input  logic          cmd_valid_i,
  output logic          cmd_ready_o,
  input  apu_cmd_req_t  cmd_i,
  input  logic          cmd_data_valid_i,
  output logic          cmd_data_ready_o,
  input  apu_dma_read_data_t cmd_data_i,
  output logic          cmd_cpl_valid_o,
  input  logic          cmd_cpl_ready_i,
  output apu_map_cpl_t  cmd_cpl_o,
  input  logic          cmd_rd_valid_i,
  output logic          cmd_rd_ready_o,
  input  logic [31:0]   cmd_rd_offset_i,
  output logic          cmd_rd_data_valid_o,
  input  logic          cmd_rd_data_ready_i,
  output logic [63:0]   cmd_rd_data_o,
  input  logic          cmd_release_i,

  output logic idle_o,
  output logic cmd_held_o,
  output logic bus_fault_o
);
  localparam bit MapEn = ApuCfg.Enable && ApuCfg.MaxResources != 0;
  localparam bit CmdEn = ApuCfg.Enable && ApuCfg.MaxCmdBytes != 0;

  `ifndef SYNTHESIS
  initial assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU storage: invalid configuration");
  `endif

  if (!MapEn && !CmdEn) begin : gen_off
    assign map_ready_o = 1'b0;
    assign map_cpl_valid_o = 1'b0;
    assign map_cpl_o = '0;
    assign lookup_ready_o = 1'b0;
    assign lookup_cpl_valid_o = 1'b0;
    assign lookup_cpl_o = '0;
    assign lookup_mapping_o = '0;
    assign inval_ready_o = 1'b0;
    assign inval_cpl_valid_o = 1'b0;
    assign inval_cpl_o = '0;
    assign cmd_ready_o = 1'b0;
    assign cmd_data_ready_o = 1'b0;
    assign cmd_cpl_valid_o = 1'b0;
    assign cmd_cpl_o = '0;
    assign cmd_rd_ready_o = 1'b0;
    assign cmd_rd_data_valid_o = 1'b0;
    assign cmd_rd_data_o = '0;
    assign idle_o = 1'b1;
    assign cmd_held_o = 1'b0;
    assign bus_fault_o = 1'b0;
  end else begin : gen_on
    typedef enum logic [4:0] {
      Idle, InsScanReq, InsScanCap, InsWrite, LkReq, LkCap,
      InvalReq, InvalCap, InvalWrite, CmdFill, CmdWrite, CmdReadReq, CmdReadCap,
      Done, Halted
    } state_e;
    typedef enum logic [2:0] {OpNone, OpMap, OpLookup, OpInval, OpCmd} op_e;

    state_e state_q;
    op_e op_q;
    apu_dma_status_e status_q;
    apu_map_insert_t ins_q;
    apu_map_lookup_t lk_q;
    apu_map_inval_t inval_q;
    apu_cmd_req_t cmd_q;
    apu_dma_mapping_t found_q, scan_map;
    logic [31:0] scan_q, found_slot_q, received_q, cmd_bytes_q, rd_off_q;
    logic [63:0] tag_q, beat_data_q, rd_data_q;
    logic [7:0] beat_keep_q;
    logic beat_last_q, found_q_valid, cmd_held_q, rd_valid_q, fault_q, kill;
    logic map_req, map_we, cmd_req, cmd_we;
    logic [255:0] map_wdata, map_rdata_word;
    logic [63:0] cmd_wdata, cmd_rdata_word;
    logic [7:0] cmd_be;
    logic [3:0] stream_bytes, beat_bytes;
    logic stream_bad, inval_match;
    logic [0:0][255:0] map_rdata;
    logic [0:0][63:0] cmd_rdata;

    assign kill = cancel_i || invalidate_i || !enable_i;
    assign idle_o = state_q == Idle && !fault_q;
    assign bus_fault_o = fault_q;
    assign cmd_held_o = cmd_held_q && !invalidate_i && enable_i;
    assign map_ready_o = MapEn && idle_o && !kill && rst_ni;
    assign lookup_ready_o = MapEn && idle_o && !kill && !map_valid_i && rst_ni;
    assign inval_ready_o = MapEn && idle_o && !kill && !map_valid_i && !lookup_valid_i && rst_ni;
    assign cmd_ready_o = CmdEn && idle_o && !kill && !cmd_held_q && !map_valid_i &&
                         !lookup_valid_i && !inval_valid_i && rst_ni;
    assign cmd_data_ready_o = state_q == CmdFill && !kill && status_q == APU_DMA_OK;
    assign cmd_rd_ready_o = CmdEn && idle_o && cmd_held_q && !kill && !map_valid_i &&
                            !lookup_valid_i && !inval_valid_i && !cmd_valid_i && rst_ni;
    assign map_cpl_valid_o = state_q == Done && op_q == OpMap;
    assign lookup_cpl_valid_o = state_q == Done && op_q == OpLookup;
    assign inval_cpl_valid_o = state_q == Done && op_q == OpInval;
    assign cmd_cpl_valid_o = state_q == Done && op_q == OpCmd;
    assign cmd_rd_data_valid_o = rd_valid_q;
    assign cmd_rd_data_o = rd_valid_q ? rd_data_q : 64'h0;
    assign lookup_mapping_o = lookup_cpl_valid_o && status_q == APU_DMA_OK ? found_q : '0;
    assign stream_bytes = 4'($countones(cmd_data_i.keep));
    assign beat_bytes = 4'($countones(beat_keep_q));
    assign stream_bad = stream_bytes == 0 || cmd_data_i.offset[2:0] != 0 ||
                        cmd_data_i.keep != (8'hff >> (8 - 32'(stream_bytes))) ||
                        cmd_data_i.offset != received_q ||
                        32'(stream_bytes) > cmd_q.bytes - received_q ||
                        cmd_data_i.last != (received_q + 32'(stream_bytes) == cmd_q.bytes);

    function automatic apu_map_cpl_t mk_cpl();
      mk_cpl = '0;
      mk_cpl.status = status_q;
      mk_cpl.tag = tag_q;
      unique case (op_q)
        OpMap: begin
          mk_cpl.slot = ins_q.slot;
          mk_cpl.resource_id = ins_q.mapping.resource_id;
          mk_cpl.context_id = ins_q.mapping.context_id;
          mk_cpl.epoch = ins_q.mapping.epoch;
        end
        OpLookup: begin
          mk_cpl.slot = found_slot_q;
          mk_cpl.resource_id = lk_q.resource_id;
          mk_cpl.context_id = lk_q.context_id;
          mk_cpl.epoch = lk_q.epoch;
        end
        OpInval: begin
          mk_cpl.slot = inval_q.slot;
          mk_cpl.resource_id = inval_q.resource_id;
          mk_cpl.context_id = inval_q.context_id;
          mk_cpl.bytes = scan_q;
        end
        default: begin
          mk_cpl.resource_id = cmd_q.resource_id;
          mk_cpl.context_id = cmd_q.context_id;
          mk_cpl.epoch = cmd_q.epoch;
          mk_cpl.bytes = received_q;
        end
      endcase
    endfunction

    assign map_cpl_o = map_cpl_valid_o ? mk_cpl() : apu_map_cpl_t'('0);
    assign lookup_cpl_o = lookup_cpl_valid_o ? mk_cpl() : apu_map_cpl_t'('0);
    assign inval_cpl_o = inval_cpl_valid_o ? mk_cpl() : apu_map_cpl_t'('0);
    assign cmd_cpl_o = cmd_cpl_valid_o ? mk_cpl() : apu_map_cpl_t'('0);

    if (MapEn) begin : gen_map
      localparam int MapAddrWidth = $clog2(ApuCfg.MaxResources);
      logic map_clk;
      logic [MapAddrWidth-1:0] map_addr;
      assign map_rdata_word = map_rdata[0];
      assign scan_map = apu_map_unpack(map_rdata_word);
      assign map_addr = (state_q == InsWrite) ? ins_q.slot[MapAddrWidth-1:0]
                                              : scan_q[MapAddrWidth-1:0];
      assign map_wdata = (state_q == InsWrite) ? apu_map_pack(ins_q.mapping)
                                               : apu_map_pack('0);
      assign map_req = !fault_q && status_q == APU_DMA_OK &&
                       (state_q == InsScanReq || state_q == InsWrite ||
                        state_q == LkReq || state_q == InvalReq || state_q == InvalWrite);
      assign map_we = state_q == InsWrite || state_q == InvalWrite;
      assign inval_match = scan_map.valid &&
                           ((inval_q.mode == APU_INVAL_SLOT && scan_q == inval_q.slot) ||
                            (inval_q.mode == APU_INVAL_RESOURCE &&
                             scan_map.resource_id == inval_q.resource_id) ||
                            (inval_q.mode == APU_INVAL_CONTEXT &&
                             scan_map.context_id == inval_q.context_id) ||
                            inval_q.mode == APU_INVAL_ALL);
      tc_clk_gating #(.IS_FUNCTIONAL(0)) i_map_icg (
        .clk_i, .en_i(testmode_i | ~idle_o | map_valid_i | lookup_valid_i | inval_valid_i),
        .test_en_i(testmode_i), .clk_o(map_clk)
      );
      tc_sram #(.NumWords(ApuCfg.MaxResources), .DataWidth(256), .NumPorts(1),
                .Latency(1), .SimInit("zeros")) i_map (
        .clk_i(map_clk), .rst_ni, .req_i(map_req), .we_i(map_we), .addr_i(map_addr),
        .wdata_i(map_wdata), .be_i({32{1'b1}}), .rdata_o(map_rdata)
      );
    end else begin : gen_map_off
      assign map_rdata_word = '0;
      assign scan_map = '0;
      assign map_req = 1'b0;
      assign map_we = 1'b0;
      assign inval_match = 1'b0;
      assign map_rdata = '0;
    end

    if (CmdEn) begin : gen_cmd
      localparam int CmdWords = ApuCfg.MaxCmdBytes / 8;
      localparam int CmdAddrWidth = $clog2(CmdWords);
      logic cmd_clk;
      logic [CmdAddrWidth-1:0] cmd_addr;
      assign cmd_rdata_word = cmd_rdata[0];
      assign cmd_addr = (state_q == CmdReadReq || state_q == CmdReadCap)
                        ? rd_off_q[CmdAddrWidth+2:3]
                        : received_q[CmdAddrWidth+2:3];
      assign cmd_wdata = beat_data_q;
      assign cmd_be = beat_keep_q;
      assign cmd_req = !fault_q &&
                       ((state_q == CmdWrite && status_q == APU_DMA_OK) ||
                        state_q == CmdReadReq);
      assign cmd_we = state_q == CmdWrite;
      tc_clk_gating #(.IS_FUNCTIONAL(0)) i_cmd_icg (
        .clk_i, .en_i(testmode_i | ~idle_o | cmd_valid_i | cmd_rd_valid_i | cmd_data_valid_i),
        .test_en_i(testmode_i), .clk_o(cmd_clk)
      );
      tc_sram #(.NumWords(CmdWords), .DataWidth(64), .NumPorts(1),
                .Latency(1), .SimInit("none")) i_cmd (
        .clk_i(cmd_clk), .rst_ni, .req_i(cmd_req), .we_i(cmd_we), .addr_i(cmd_addr),
        .wdata_i(cmd_wdata), .be_i(cmd_be), .rdata_o(cmd_rdata)
      );
    end else begin : gen_cmd_off
      assign cmd_rdata_word = '0;
      assign cmd_wdata = '0;
      assign cmd_be = '0;
      assign cmd_req = 1'b0;
      assign cmd_we = 1'b0;
      assign cmd_rdata = '0;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        op_q <= OpNone;
        status_q <= APU_DMA_OK;
        ins_q <= '0;
        lk_q <= '0;
        inval_q <= '0;
        cmd_q <= '0;
        found_q <= '0;
        scan_q <= '0;
        found_slot_q <= '0;
        received_q <= '0;
        cmd_bytes_q <= '0;
        rd_off_q <= '0;
        tag_q <= '0;
        beat_data_q <= '0;
        beat_keep_q <= '0;
        beat_last_q <= 1'b0;
        rd_data_q <= '0;
        found_q_valid <= 1'b0;
        cmd_held_q <= 1'b0;
        rd_valid_q <= 1'b0;
        fault_q <= 1'b0;
      end else begin
        if (invalidate_i || !enable_i) begin
          cmd_held_q <= 1'b0;
          rd_valid_q <= 1'b0;
        end
        if (kill && status_q == APU_DMA_OK && state_q != Idle &&
            state_q != Done && state_q != Halted)
          status_q <= APU_DMA_CANCELLED;
        if (cmd_rd_data_valid_o && cmd_rd_data_ready_i) rd_valid_q <= 1'b0;
        unique case (state_q)
          Idle: begin
            status_q <= APU_DMA_OK;
            found_q_valid <= 1'b0;
            found_q <= '0;
            found_slot_q <= '0;
            scan_q <= '0;
            received_q <= '0;
            if (MapEn && map_valid_i && map_ready_o) begin
              ins_q <= map_i;
              tag_q <= map_i.tag;
              op_q <= OpMap;
              if (map_i.slot >= ApuCfg.MaxResources || !map_i.mapping.valid ||
                  map_i.mapping.resource_id == 0 || map_i.mapping.bytes == 0 ||
                  !apu_dma_mapping_in_window(ApuCfg, map_i.mapping)) begin
                status_q <= (map_i.slot >= ApuCfg.MaxResources ||
                             map_i.mapping.resource_id == 0 || !map_i.mapping.valid)
                            ? APU_DMA_BAD_RESOURCE : APU_DMA_BOUNDS;
                state_q <= Done;
              end else state_q <= InsScanReq;
            end else if (MapEn && lookup_valid_i && lookup_ready_o) begin
              lk_q <= lookup_i;
              tag_q <= lookup_i.tag;
              op_q <= OpLookup;
              if (lookup_i.resource_id == 0) begin
                status_q <= APU_DMA_BAD_RESOURCE;
                state_q <= Done;
              end else state_q <= LkReq;
            end else if (MapEn && inval_valid_i && inval_ready_o) begin
              inval_q <= inval_i;
              tag_q <= inval_i.tag;
              op_q <= OpInval;
              if (inval_i.mode == APU_INVAL_SLOT && inval_i.slot >= ApuCfg.MaxResources) begin
                status_q <= APU_DMA_BAD_RESOURCE;
                state_q <= Done;
              end else state_q <= InvalReq;
            end else if (CmdEn && cmd_valid_i && cmd_ready_o) begin
              cmd_q <= cmd_i;
              tag_q <= cmd_i.tag;
              op_q <= OpCmd;
              if (cmd_i.bytes == 0 || cmd_i.bytes > ApuCfg.MaxCmdBytes) begin
                status_q <= APU_DMA_LIMIT;
                state_q <= Done;
              end else state_q <= CmdFill;
            end else if (CmdEn && cmd_rd_valid_i && cmd_rd_ready_o) begin
              rd_off_q <= cmd_rd_offset_i;
              if (cmd_rd_offset_i[2:0] != 0 || cmd_rd_offset_i >= cmd_bytes_q) begin
                // Drop illegal firmware reads; do not mutate the snapshot.
              end else state_q <= CmdReadReq;
            end else if (CmdEn && cmd_release_i && cmd_held_q) begin
              cmd_held_q <= 1'b0;
              cmd_bytes_q <= '0;
            end
          end
          InsScanReq: begin
            if (kill) state_q <= Done;
            else if (scan_q >= ApuCfg.MaxResources) state_q <= InsWrite;
            else state_q <= InsScanCap;
          end
          InsScanCap: begin
            if (kill) state_q <= Done;
            else if (scan_map.valid && scan_map.resource_id == ins_q.mapping.resource_id &&
                     scan_q != ins_q.slot) begin
              status_q <= APU_DMA_BAD_RESOURCE;
              state_q <= Done;
            end else begin
              scan_q <= scan_q + 1;
              state_q <= InsScanReq;
            end
          end
          InsWrite: if (kill) state_q <= Done; else state_q <= Done;
          LkReq: begin
            if (kill) state_q <= Done;
            else if (scan_q >= ApuCfg.MaxResources) begin
              if (!found_q_valid) status_q <= APU_DMA_BAD_RESOURCE;
              state_q <= Done;
            end else state_q <= LkCap;
          end
          LkCap: begin
            if (kill) state_q <= Done;
            else begin
              if (scan_map.valid && scan_map.resource_id == lk_q.resource_id) begin
                found_q_valid <= 1'b1;
                found_q <= scan_map;
                found_slot_q <= scan_q;
                if (scan_map.context_id != lk_q.context_id ||
                    !scan_map.permissions[lk_q.write_access])
                  status_q <= APU_DMA_PERMISSION;
                else if (scan_map.epoch != lk_q.epoch) status_q <= APU_DMA_STALE;
                scan_q <= ApuCfg.MaxResources;
                state_q <= LkReq;
              end else begin
                scan_q <= scan_q + 1;
                state_q <= LkReq;
              end
            end
          end
          InvalReq: begin
            if (kill) state_q <= Done;
            else if (scan_q >= ApuCfg.MaxResources) state_q <= Done;
            else state_q <= InvalCap;
          end
          InvalCap: begin
            if (kill) state_q <= Done;
            else if (inval_match) state_q <= InvalWrite;
            else begin
              scan_q <= scan_q + 1;
              state_q <= InvalReq;
            end
          end
          InvalWrite: begin
            scan_q <= scan_q + 1;
            state_q <= InvalReq;
          end
          CmdFill: begin
            if (kill) state_q <= Done;
            else if (cmd_data_valid_i && cmd_data_ready_o) begin
              if (stream_bad) begin
                status_q <= APU_DMA_STREAM;
                state_q <= Done;
              end else begin
                beat_data_q <= cmd_data_i.data;
                beat_keep_q <= cmd_data_i.keep;
                beat_last_q <= cmd_data_i.last;
                state_q <= CmdWrite;
              end
            end
          end
          CmdWrite: begin
            if (kill) state_q <= Done;
            else begin
              received_q <= received_q + 32'(beat_bytes);
              if (beat_last_q) begin
                cmd_held_q <= status_q == APU_DMA_OK;
                cmd_bytes_q <= cmd_q.bytes;
                state_q <= Done;
              end else state_q <= CmdFill;
            end
          end
          CmdReadReq: state_q <= CmdReadCap;
          CmdReadCap: begin
            rd_data_q <= cmd_rdata_word;
            rd_valid_q <= 1'b1;
            state_q <= Idle;
          end
          Done: begin
            if ((op_q == OpMap && map_cpl_ready_i) ||
                (op_q == OpLookup && lookup_cpl_ready_i) ||
                (op_q == OpInval && inval_cpl_ready_i) ||
                (op_q == OpCmd && cmd_cpl_ready_i))
              state_q <= fault_q ? Halted : Idle;
          end
          Halted: ;
          default: state_q <= Halted;
        endcase
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      map_cpl_valid_o && !map_cpl_ready_i |=> map_cpl_valid_o && $stable(map_cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      lookup_cpl_valid_o && !lookup_cpl_ready_i |=> lookup_cpl_valid_o && $stable(lookup_cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cmd_cpl_valid_o && !cmd_cpl_ready_i |=> cmd_cpl_valid_o && $stable(cmd_cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cmd_rd_data_valid_o && !cmd_rd_data_ready_i |=> cmd_rd_data_valid_o && $stable(cmd_rd_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q != Idle |-> !map_ready_o && !lookup_ready_o && !cmd_ready_o);
    `endif
  end
endmodule
