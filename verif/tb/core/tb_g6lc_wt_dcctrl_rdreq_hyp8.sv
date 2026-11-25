// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 wt_dcache_ctrl leaf verifying Run-704-driven READ_V fix:
//   S1: Back-to-back load hit (data_req=1 during READ_V) keeps rd_req_o=1 and
//       issues immediate data_gnt=1 with zero added latency.
//   S2: Idle READ_V (data_req=0 during READ_V) MUST deassert rd_req_o=0 so
//       wt_dcache_mem yields its read port to wbuffer tag checks / PTW walks.
//
// Review mutation (must fail):
//   -DG6LC_MUT_DCCTRL_IDLE_RD_STEAL -> fails S2_IDLE_READV_YIELDS_RD_REQ
//
// PASS token: PASS tb_g6lc_wt_dcctrl_rdreq_hyp8
module tb_g6lc_wt_dcctrl_rdreq_hyp8;
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned CL_IDX_W = C.DCACHE_INDEX_WIDTH - C.DCACHE_OFFSET_WIDTH;

  typedef struct packed {
    logic [C.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [C.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [C.XLEN-1:0]               data_wdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                            data_req;
    logic                            data_we;
    logic [(C.XLEN/8)-1:0]           data_be;
    logic [1:0]                      data_size;
    logic [C.DcacheIdWidth-1:0]      data_id;
    logic [2:0]                      data_prot;
    logic                            kill_req;
    logic                            tag_valid;
  } dcache_req_i_t;

  typedef struct packed {
    logic                            data_gnt;
    logic                            data_rvalid;
    logic [C.DcacheIdWidth-1:0]      data_rid;
    logic [C.XLEN-1:0]               data_rdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_ruser;
  } dcache_req_o_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_wt_dcctrl_rdreq_hyp8");
    end
  endtask

  dcache_req_i_t req_i = '0;
  dcache_req_o_t req_o;
  logic rd_req_o, rd_ack_i = 1'b1;
  logic [C.DCACHE_SET_ASSOC-1:0] rd_hit_oh = '0;

  wt_dcache_ctrl #(
      .G6LCCfg       (C),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t)
  ) dut (
      .clk_i            (clk),
      .rst_ni           (rst_n),
      .cache_en_i       (1'b1),
      .req_port_i       (req_i),
      .req_port_o       (req_o),
      .miss_req_o       (),
      .miss_ack_i       (1'b0),
      .miss_we_o        (),
      .miss_wdata_o     (),
      .miss_wuser_o     (),
      .miss_vld_bits_o  (),
      .miss_paddr_o     (),
      .miss_nc_o        (),
      .miss_size_o      (),
      .miss_id_o        (),
      .miss_prot_o      (),
      .miss_replay_i    (1'b0),
      .miss_rtrn_vld_i  (1'b0),
      .wr_cl_vld_i      (1'b0),
      .rd_tag_o         (),
      .rd_idx_o         (),
      .rd_off_o         (),
      .rd_req_o         (rd_req_o),
      .rd_tag_only_o    (),
      .rd_ack_i         (rd_ack_i),
      .rd_data_i        (64'h1234_5678_9abc_def0),
      .rd_user_i        ('0),
      .rd_vld_bits_i    ('1),
      .rd_hit_oh_i      (rd_hit_oh),
      .wbuffer_fwd_hit_i(1'b0)
  );

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // S1: Issue load 1 -> IDLE -> READ (tag_valid=1) -> READ_WAIT -> READ_V (hit!)
    //     With back-to-back data_req=1 during READ_V: rd_req_o MUST be 1 and data_gnt MUST be 1!
    req_i = '0;
    req_i.data_req = 1'b1;
    #1; check(req_o.data_gnt === 1'b1, "S1_LD1_GNT");
    tick(); // now READ
    req_i.data_req  = 1'b0;
    req_i.tag_valid = 1'b1;
    tick(); // now READ_WAIT
    req_i.tag_valid = 1'b0;
    tick(); // now READ_V
    req_i.data_req  = 1'b1; // back-to-back load 2!
    rd_hit_oh       = {{C.DCACHE_SET_ASSOC-1{1'b0}}, 1'b1};
    #1;
    check(rd_req_o === 1'b1 && req_o.data_rvalid === 1'b1 && req_o.data_gnt === 1'b1,
          "S1_B2B_HIT_ZERO_BUBBLE");
    tick(); // load 2 now in READ!

    // S2: Load 2 completes with NO back-to-back load (data_req=0 during READ_V):
    //     rd_req_o MUST be 0 so wbuffer / PTW can use the read port!
    req_i.data_req  = 1'b0;
    req_i.tag_valid = 1'b1;
    rd_hit_oh       = '0;
    tick(); // now READ_WAIT
    req_i.tag_valid = 1'b0;
    tick(); // now READ_V (idle!)
    rd_hit_oh       = {{C.DCACHE_SET_ASSOC-1{1'b0}}, 1'b1};
    #1;
    check(req_o.data_rvalid === 1'b1, "S2_LD2_RVALID");
    check(rd_req_o === 1'b0, "S2_IDLE_READV_YIELDS_RD_REQ");

    $display("PASS tb_g6lc_wt_dcctrl_rdreq_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
