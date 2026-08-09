// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 20.09.2018
// Description: Buffers AMO requests
// This unit buffers an atomic memory operation for the cache subsystem.
// Furthermore it handles interfacing with the commit stage

module amo_buffer #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input logic clk_i,   // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i, // pipeline flush
    // Soft-ladder B1 (b1-amo-spin-lock / hang-7): younger-cancel can drop an
    // already-posted AMO at commit without flush_ex. Kill the depth-1 entry so
    // subsequent correct-path amoadd (OpenSBI spin_lock) is not wedged.
    input logic cancel_i,

    input logic valid_i,  // AMO is valid
    output logic ready_o,  // AMO unit is ready
    input ariane_pkg::amo_t amo_op_i,  // AMO Operation
    input  logic [CVA6Cfg.PLEN-1:0]      paddr_i,            // physical address of store which needs to be placed in the queue
    input logic [CVA6Cfg.XLEN-1:0] data_i,  // data which is placed in the queue (AMOCAS: swap/new)
    input logic [CVA6Cfg.XLEN-1:0] data_cmp_i,  // Zacas expected value (0 if unused)
    input logic [CVA6Cfg.XLEN-1:0] data_hi_i,  // AMOCAS.Q new high
    input logic [CVA6Cfg.XLEN-1:0] data_cmp_hi_i,  // AMOCAS.Q expected high
    input logic is_quad_i,  // AMOCAS.Q
    input logic [1:0] data_size_i,  // type of request we are making (e.g.: bytes to write)
    // D$
    output ariane_pkg::amo_req_t amo_req_o,  // request to cache subsystem
    input ariane_pkg::amo_resp_t amo_resp_i,  // response from cache subsystem
    // Auxiliary signals
    input logic amo_valid_commit_i,  // We have a valid AMO in the commit stage
    input logic no_st_pending_i  // there is currently no store pending anymore
);
  logic flush_amo_buffer;
  logic amo_valid;

  typedef struct packed {
    ariane_pkg::amo_t        op;
    logic [CVA6Cfg.PLEN-1:0] paddr;
    logic [CVA6Cfg.XLEN-1:0] data;
    logic [CVA6Cfg.XLEN-1:0] data_cmp;
    logic [CVA6Cfg.XLEN-1:0] data_hi;
    logic [CVA6Cfg.XLEN-1:0] data_cmp_hi;
    logic                    is_quad;
    logic [1:0]              size;
  } amo_op_t;

  amo_op_t amo_data_in, amo_data_out;

  // validate this request as soon as all stores have drained and the AMO is in the commit stage
  assign amo_req_o.req = no_st_pending_i & amo_valid_commit_i & amo_valid;
  assign amo_req_o.amo_op = amo_data_out.op;
  assign amo_req_o.size = amo_data_out.size;
  assign amo_req_o.operand_a = {{64 - CVA6Cfg.PLEN{1'b0}}, amo_data_out.paddr};
  assign amo_req_o.operand_b = {{64 - CVA6Cfg.XLEN{1'b0}}, amo_data_out.data};
  assign amo_req_o.operand_c = {{64 - CVA6Cfg.XLEN{1'b0}}, amo_data_out.data_cmp};
  assign amo_req_o.operand_b_hi = {{64 - CVA6Cfg.XLEN{1'b0}}, amo_data_out.data_hi};
  assign amo_req_o.operand_c_hi = {{64 - CVA6Cfg.XLEN{1'b0}}, amo_data_out.data_cmp_hi};
  assign amo_req_o.is_quad = amo_data_out.is_quad;

  assign amo_data_in.op = amo_op_i;
  assign amo_data_in.data = data_i;
  assign amo_data_in.data_cmp = data_cmp_i;
  assign amo_data_in.data_hi = data_hi_i;
  assign amo_data_in.data_cmp_hi = data_cmp_hi_i;
  assign amo_data_in.is_quad = is_quad_i;
  assign amo_data_in.paddr = paddr_i;
  assign amo_data_in.size = data_size_i;

  // Flush on full pipeline flush *or* younger-cancel of the buffered AMO.
  // Never flush while the AMO is non-speculative at commit (cache request live).
  assign flush_amo_buffer = (flush_i | cancel_i) & !amo_valid_commit_i;

  cva6_fifo_v3 #(
      .DEPTH  (1),
      .dtype  (amo_op_t),
      .FPGA_EN(CVA6Cfg.FpgaEn)
  ) i_amo_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (flush_amo_buffer),
      .testmode_i(1'b0),
      .full_o    (amo_valid),
      .empty_o   (ready_o),
      .usage_o   (),                  // left open
      .data_i    (amo_data_in),
      .push_i    (valid_i),
      .data_o    (amo_data_out),
      .pop_i     (amo_resp_i.ack)
  );

endmodule
