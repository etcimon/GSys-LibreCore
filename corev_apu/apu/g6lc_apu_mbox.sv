// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Firmware mailbox for g6lc_apu_mem. Word packing:
//   0 slot / {idx[31:16], queue_num[15:0]}
//   1 resource_id  2 context_id  3 epoch
//   4 {write_access, permissions[1:0], valid}
//   5/6 mapping base lo/hi  7/8 mapping bytes lo/hi
//   9/10 tag lo/hi  11/12 offset lo/hi  13 transfer/cmd bytes
//   14 desc_id  15 used len  16 qid  17/18 fence lo/hi
//   19/20 sg list base  21/22 sg list bytes  23 sg list resource
// Exec ops 9-12 reuse 0 idx/thread/shader, 1 inst/reg, 2 poke data.

// Interplay: firmware hart ==> Mailbox <-> ApuMem or ExecBind. See AGENTS-impl-interplays.md.
module g6lc_apu_mbox
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter type reg_req_t = apu_reg_req_t,
  parameter type reg_rsp_t = apu_reg_rsp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  logic enable_i,
  input  logic cancel_i,
  input  reg_req_t req_i,
  output reg_rsp_t rsp_o,
  output logic          op_valid_o,
  input  logic          op_ready_i,
  output apu_mem_op_e   op_o,
  output apu_map_insert_t insert_o,
  output apu_map_lookup_t lookup_o,
  output apu_map_inval_t  inval_o,
  output apu_sg_load_t    sg_load_o,
  output apu_dma_mapping_t sg_list_o,
  output apu_dma_mapping_t sg_backing_o,
  output apu_sg_query_t    sg_query_o,
  output apu_cmd_req_t     cmd_o,
  output apu_dma_read_req_t cmd_dma_o,
  output apu_dma_mapping_t  cmd_map_o,
  output apu_used_req_t     used_o,
  output apu_exec_job_t     exec_o,
  input  logic          op_cpl_valid_i,
  output logic          op_cpl_ready_o,
  input  apu_map_cpl_t  op_cpl_i,
  input  apu_dma_mapping_t lookup_mapping_i,
  output logic          cmd_rd_valid_o,
  input  logic          cmd_rd_ready_i,
  output logic [31:0]   cmd_rd_offset_o,
  input  logic          cmd_rd_data_valid_i,
  output logic          cmd_rd_data_ready_o,
  input  logic [63:0]   cmd_rd_data_i,
  input  logic idle_i,
  input  logic cmd_held_i
);
  logic [31:0] mail_q [APU_MAIL_WORDS];
  logic [31:0] idx_q, stat_q, cpl0_q, cpl1_q, cpl2_q, cpl3_q;
  logic busy_q, go_q;
  apu_mem_op_e op_q;
  integer i;

  function automatic apu_dma_mapping_t map_of();
    map_of = '{
      valid: mail_q[4][0],
      permissions: mail_q[4][2:1],
      resource_id: mail_q[1],
      context_id: mail_q[2],
      epoch: mail_q[3],
      base: {mail_q[6], mail_q[5]},
      bytes: {mail_q[8], mail_q[7]}
    };
  endfunction

  assign op_o = op_q;
  assign op_valid_o = go_q && busy_q;
  assign op_cpl_ready_o = busy_q;
  assign insert_o = '{slot: mail_q[0], mapping: map_of(), tag: {mail_q[10], mail_q[9]}};
  assign lookup_o = '{resource_id: mail_q[1], context_id: mail_q[2], epoch: mail_q[3],
                      write_access: mail_q[4][3], tag: {mail_q[10], mail_q[9]}};
  assign inval_o = '{mode: apu_inval_mode_e'(mail_q[0][1:0]), slot: mail_q[0],
                     resource_id: mail_q[1], context_id: mail_q[2],
                     tag: {mail_q[10], mail_q[9]}};
  assign sg_load_o = '{resource_id: mail_q[1], context_id: mail_q[2], epoch: mail_q[3],
                       permissions: mail_q[4][2:1], bytes: {32'h0, mail_q[13]},
                       entries: mail_q[0],
                       list_offset: {mail_q[12], mail_q[11]}, tag: {mail_q[10], mail_q[9]}};
  assign sg_list_o = '{valid: 1'b1, permissions: 2'b01, resource_id: mail_q[23],
                       context_id: mail_q[2], epoch: mail_q[3],
                       base: {mail_q[20], mail_q[19]}, bytes: {mail_q[22], mail_q[21]}};
  assign sg_backing_o = map_of();
  assign sg_query_o = '{req: '{resource_id: mail_q[1], context_id: mail_q[2],
      epoch: mail_q[3], offset: {mail_q[12], mail_q[11]}, bytes: mail_q[13],
      tag: {mail_q[10], mail_q[9]}}, write_access: mail_q[4][3]};
  assign cmd_o = '{bytes: mail_q[13], resource_id: mail_q[1], context_id: mail_q[2],
                   epoch: mail_q[3], tag: {mail_q[10], mail_q[9]}};
  assign cmd_dma_o = '{resource_id: mail_q[1], context_id: mail_q[2], epoch: mail_q[3],
                       offset: {mail_q[12], mail_q[11]}, bytes: mail_q[13],
                       tag: {mail_q[10], mail_q[9]}};
  assign cmd_map_o = map_of();
  assign used_o = '{mapping: map_of(), offset: {mail_q[12], mail_q[11]},
                    queue_num: mail_q[0][15:0], idx: mail_q[0][31:16],
                    desc_id: mail_q[14], len: mail_q[15], qid: mail_q[16],
                    context_id: mail_q[2], fence: {mail_q[18], mail_q[17]},
                    tag: {mail_q[10], mail_q[9]}};
  assign exec_o = '{idx: mail_q[0][3:0], inst: mail_q[1], thread: mail_q[0][1:0],
                    regno: mail_q[1][2:0], data: mail_q[2], shader: mail_q[0][0]};
  assign cmd_rd_valid_o = 1'b0;
  assign cmd_rd_offset_o = '0;
  assign cmd_rd_data_ready_o = 1'b0;

  always_comb begin
    rsp_o = '0;
    rsp_o.ready = req_i.valid;
    if (req_i.valid) begin
      rsp_o.error = req_i.addr[1:0] != 0 || (req_i.write && req_i.wstrb != 4'hf) || !enable_i;
      if (req_i.write) begin
        unique case (req_i.addr[15:0])
          ACTRL_MAIL_IDX: rsp_o.error |= req_i.wdata >= APU_MAIL_WORDS;
          ACTRL_MAIL_DATA: rsp_o.error |= busy_q || idx_q >= APU_MAIL_WORDS;
          ACTRL_MAIL_GO: rsp_o.error |= busy_q || req_i.wdata == 0 ||
                           req_i.wdata > (ApuCfg.ExecEn ? 32'(APU_MEM_EXEC_DPEEK)
                                                        : 32'(APU_MEM_USED)) ||
                           (apu_op_is_exec(apu_mem_op_e'(req_i.wdata[3:0])) &&
                            !ApuCfg.ExecEn);
          default: rsp_o.error = 1'b1;
        endcase
      end else begin
        unique case (req_i.addr[15:0])
          ACTRL_MAIL_IDX:  rsp_o.rdata = idx_q;
          ACTRL_MAIL_DATA: rsp_o.rdata = (idx_q < APU_MAIL_WORDS) ? mail_q[idx_q] : '0;
          ACTRL_MAIL_GO:   rsp_o.rdata = 32'(op_q);
          ACTRL_MAIL_STAT: rsp_o.rdata = {busy_q, cmd_held_i, 26'h0, stat_q[3:0]};
          ACTRL_MAIL_CPL0: rsp_o.rdata = cpl0_q;
          ACTRL_MAIL_CPL1: rsp_o.rdata = cpl1_q;
          ACTRL_MAIL_CPL2: rsp_o.rdata = cpl2_q;
          ACTRL_MAIL_CPL3: rsp_o.rdata = cpl3_q;
          default: rsp_o.error = 1'b1;
        endcase
      end
      if (rsp_o.error) rsp_o.rdata = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (i = 0; i < APU_MAIL_WORDS; i++) mail_q[i] <= '0;
      idx_q <= '0; stat_q <= '0; cpl0_q <= '0; cpl1_q <= '0; cpl2_q <= '0; cpl3_q <= '0;
      busy_q <= 1'b0; go_q <= 1'b0; op_q <= APU_MEM_NONE;
    end else begin
      // A job the backend already took must finish, including a cancel
      // completion. Drop only a GO that was never accepted.
      if (busy_q && op_cpl_valid_i) begin
        busy_q <= 1'b0;
        stat_q <= 32'(op_cpl_i.status);
        cpl0_q <= op_cpl_i.resource_id;
        cpl1_q <= op_cpl_i.bytes;
        cpl2_q <= op_cpl_i.tag[31:0];
        cpl3_q <= op_cpl_i.tag[63:32];
        if (op_q == APU_MEM_MAP_LOOKUP && op_cpl_i.status == APU_DMA_OK) begin
          mail_q[5] <= lookup_mapping_i.base[31:0];
          mail_q[6] <= lookup_mapping_i.base[63:32];
          mail_q[7] <= lookup_mapping_i.bytes[31:0];
          mail_q[8] <= lookup_mapping_i.bytes[63:32];
        end
      end else if (cancel_i && go_q && busy_q) begin
        go_q <= 1'b0;
        busy_q <= 1'b0;
        stat_q <= 32'(APU_DMA_CANCELLED);
      end else if (cancel_i) begin
        go_q <= 1'b0;
      end
      if (go_q && op_ready_i && !cancel_i) go_q <= 1'b0;
      if (req_i.valid && req_i.write && !rsp_o.error) begin
        unique case (req_i.addr[15:0])
          ACTRL_MAIL_IDX: idx_q <= req_i.wdata;
          ACTRL_MAIL_DATA: mail_q[idx_q[4:0]] <= req_i.wdata;
          ACTRL_MAIL_GO: begin
            op_q <= apu_mem_op_e'(req_i.wdata[3:0]);
            busy_q <= 1'b1;
            go_q <= 1'b1;
            stat_q <= '0;
          end
          default: ;
        endcase
      end
    end
  end

  logic unused_idle;
  assign unused_idle = idle_i | testmode_i;
endmodule
