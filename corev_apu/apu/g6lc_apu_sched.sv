// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One mailbox, one memory client, and one exec client. An op is presented
// to exactly one of them. The other stays idle until that op completes.
// Exec does not read the mapping. This is not a handle resolver.

module g6lc_apu_sched
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter bit Enable = 1'b0,
  parameter type reg_req_t = apu_reg_req_t,
  parameter type reg_rsp_t = apu_reg_rsp_t,
  parameter type dma_req_t = apu_dma_axi_req_t,
  parameter type dma_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  reg_req_t req_i,
  output reg_rsp_t rsp_o,
  input  logic cancel_i,
  output logic idle_o,
  output logic bus_fault_o,
  output dma_req_t dma_req_o,
  input  dma_rsp_t dma_rsp_i
);
  if (!Enable) begin : gen_off
    assign rsp_o = '{rdata: '0, error: req_i.valid, ready: req_i.valid};
    assign idle_o = 1'b1;
    assign bus_fault_o = 1'b0;
    assign dma_req_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | cancel_i | |dma_rsp_i;
  end else begin : gen_on
    logic op_v, op_r, cpl_v, cpl_r, mem_idle, ex_idle, cmd_held, is_exec;
    logic mem_v, mem_r, mem_cpl_v, mem_cpl_r;
    logic ex_v, ex_r, ex_cpl_v, ex_cpl_r;
    apu_mem_op_e op;
    apu_exec_job_t job;
    apu_map_cpl_t cpl, mem_cpl, ex_cpl;
    apu_map_insert_t insert;
    apu_map_lookup_t lookup;
    apu_map_inval_t inval;
    apu_sg_load_t sg_load;
    apu_dma_mapping_t sg_list, sg_back, cmd_map, lmap;
    apu_sg_query_t sg_query;
    apu_cmd_req_t cmd;
    apu_dma_read_req_t cmd_dma;
    apu_used_req_t used;
    logic crv, crr, crdv, crdr;
    logic [31:0] croff;
    logic [63:0] crdata;

    `ifndef SYNTHESIS
    initial begin
      assert (apu_cfg_legal(ApuCfg))
        else $fatal(1, "APU sched: invalid configuration");
      assert (ApuCfg.Enable && ApuCfg.ExecEn)
        else $fatal(1, "APU sched: exec is required");
      assert (ApuCfg.MaxResources != 0 || ApuCfg.MaxCmdBytes != 0 ||
              ApuCfg.SgEn || ApuCfg.DmaReadEn || ApuCfg.DmaWriteEn)
        else $fatal(1, "APU sched: a memory client is required");
    end
    `endif

    assign is_exec = apu_op_is_exec(op);
    assign mem_v = op_v && !is_exec;
    assign ex_v = op_v && is_exec;
    assign op_r = is_exec ? ex_r : mem_r;
    assign cpl_v = is_exec ? ex_cpl_v : mem_cpl_v;
    assign cpl = is_exec ? ex_cpl : mem_cpl;
    assign mem_cpl_r = cpl_r && !is_exec;
    assign ex_cpl_r = cpl_r && is_exec;
    assign idle_o = mem_idle && ex_idle;

    g6lc_apu_mbox #(.ApuCfg(ApuCfg)) i_mbox (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1), .cancel_i,
      .req_i, .rsp_o,
      .op_valid_o(op_v), .op_ready_i(op_r), .op_o(op),
      .insert_o(insert), .lookup_o(lookup), .inval_o(inval),
      .sg_load_o(sg_load), .sg_list_o(sg_list), .sg_backing_o(sg_back),
      .sg_query_o(sg_query), .cmd_o(cmd), .cmd_dma_o(cmd_dma), .cmd_map_o(cmd_map),
      .used_o(used), .exec_o(job),
      .op_cpl_valid_i(cpl_v), .op_cpl_ready_o(cpl_r), .op_cpl_i(cpl),
      .lookup_mapping_i(lmap),
      .cmd_rd_valid_o(crv), .cmd_rd_ready_i(crr),
      .cmd_rd_offset_o(croff), .cmd_rd_data_valid_i(crdv),
      .cmd_rd_data_ready_o(crdr), .cmd_rd_data_i(crdata),
      .idle_i(idle_o), .cmd_held_i(cmd_held)
    );
    g6lc_apu_mem #(
      .ApuCfg(ApuCfg), .axi_req_t(dma_req_t), .axi_rsp_t(dma_rsp_t)
    ) i_mem (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1),
      .cancel_i, .invalidate_i(cancel_i),
      .op_valid_i(mem_v), .op_ready_o(mem_r), .op_i(op),
      .insert_i(insert), .lookup_i(lookup), .inval_i(inval),
      .sg_load_i(sg_load), .sg_list_i(sg_list), .sg_backing_i(sg_back),
      .sg_query_i(sg_query), .cmd_i(cmd), .cmd_dma_i(cmd_dma), .cmd_map_i(cmd_map),
      .used_i(used),
      .op_cpl_valid_o(mem_cpl_v), .op_cpl_ready_i(mem_cpl_r), .op_cpl_o(mem_cpl),
      .lookup_mapping_o(lmap),
      .cmd_rd_valid_i(crv), .cmd_rd_ready_o(crr),
      .cmd_rd_offset_i(croff), .cmd_rd_data_valid_o(crdv),
      .cmd_rd_data_ready_i(crdr), .cmd_rd_data_o(crdata),
      .idle_o(mem_idle), .cmd_held_o(cmd_held), .bus_fault_o,
      .axi_req_o(dma_req_o), .axi_rsp_i(dma_rsp_i)
    );
    g6lc_apu_exec_bind #(.ApuCfg(ApuCfg)) i_exec (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1), .cancel_i,
      .op_valid_i(ex_v), .op_ready_o(ex_r), .op_i(op), .exec_i(job),
      .op_cpl_valid_o(ex_cpl_v), .op_cpl_ready_i(ex_cpl_r), .op_cpl_o(ex_cpl),
      .idle_o(ex_idle)
    );

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni) !(mem_v && ex_v));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      mem_v |-> !apu_op_is_exec(op));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      ex_v |-> apu_op_is_exec(op));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      !(mem_cpl_v && ex_cpl_v));
    `endif
  end
endmodule
