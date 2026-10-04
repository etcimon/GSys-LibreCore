// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// ShaderCore composition (§7a of
// architecture/uncore/apu-vulkan-engine.md): `g6lc_apu_shmod`
// commit scanner + `g6lc_apu_shwave` wave engine.  The work port
// accepts the `cmdexec` work-port record with valid/ready
// handshaking (`work_ready_o`): vkCmdDispatch
// (APU_VN_TYPE_VK_CMD_DISPATCH_EXT) drives a dispatch with
// {gx,gy,gz} from the record's imm words; vkCmdDispatchIndirect and
// every other record completes with APU_SH_DONE_UNSUPPORTED
// (indirect needs a buffer read of the group counts — a 5-series
// integration item).  A record presented while `work_ready_o` is
// low is NOT consumed — the caller must hold it.  In increment 4a
// the pipeline → slot resolution and descriptor state are supplied
// directly on the sideband inputs (disp_slot_i/binds_i/push_*), one
// outstanding dispatch at a time; commit and dispatch are
// serialized by the caller (shmod owns its read ports while busy).
//
// Timing impact: pure wiring plus a two-state accept FSM; no new
// datapath.  Enable=0 ties every output off.

module g6lc_apu_shcore
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderLanes   = 8,
  parameter int unsigned ShaderVec     = 4,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  // module word staging + commit/retire (to shmod)
  input  logic         wr_en_i,
  input  logic [2:0]   wr_slot_i,
  input  logic [15:0]  wr_addr_i,
  input  logic [31:0]  wr_data_i,
  input  logic         commit_i,
  input  apu_sh_commit_t commit_pl_i,
  output logic         c_busy_o,
  output logic         c_done_o,
  output apu_sh_cpl_t  c_done_pl_o,
  input  logic         retire_i,
  input  logic [2:0]   retire_slot_i,
  // cmdexec work-port record: {ctype[31:0], imm[0..2]=gx,gy,gz}
  input  logic         work_i,
  output logic         work_ready_o,
  input  logic [31:0]  work_ctype_i,
  input  logic [8*32-1:0] work_imm_i,   // first 8 imm words
  // dispatch sideband (4a: direct slot + descriptor state)
  input  logic [2:0]   disp_slot_i,
  input  logic [16*113-1:0] binds_i,
  input  logic [5:0]   push_n_i,
  input  logic [1023:0] push_i,
  // completion
  output logic         busy_o,
  output logic         done_o,
  output apu_sh_done_t done_pl_o,
  // guest memory word port (64-bit)
  output logic         mem_re_o,
  output logic         mem_we_o,
  output logic [63:0]  mem_addr_o,
  output logic [63:0]  mem_wdata_o,
  output logic [7:0]   mem_wstrb_o,
  input  logic [63:0]  mem_rdata_i
);
  if (!Enable) begin : gen_off
    assign c_busy_o = 1'b0;    assign c_done_o = 1'b0;
    assign c_done_pl_o = '0;
    assign work_ready_o = 1'b0;
    assign busy_o = 1'b0;      assign done_o = 1'b0;
    assign done_pl_o = '0;
    assign mem_re_o = 1'b0;    assign mem_we_o = 1'b0;
    assign mem_addr_o = '0;    assign mem_wdata_o = '0;
    assign mem_wstrb_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | wr_en_i |
                    (|wr_slot_i) | (|wr_addr_i) | (|wr_data_i) |
                    commit_i | (|commit_pl_i) | retire_i |
                    (|retire_slot_i) | work_i | (|work_ctype_i) |
                    (|work_imm_i) | (|disp_slot_i) | (|binds_i) |
                    (|push_n_i) | (|push_i) | (|mem_rdata_i);
  end else begin : gen_on
    typedef enum logic [0:0] { C_IDLE, C_SENT } cast_e;
    cast_e cast_q;
    apu_sh_dispatch_t disp_q;
    logic             disp_q_valid;
    apu_sh_done_t     wdone_pl;
    logic             wdone, wbusy;
    logic [31:0]      wid_q;

    // shmod ↔ shwave read-port fabric
    logic [2:0]   rd_slot;
    logic [15:0]  prog_addr;
    logic [31:0]  prog_data;
    logic [9:0]   type_id, const_id, memb_id, rm_id, init_id, blk_id;
    logic [95:0]  type_data;
    logic [511:0] const_data;
    logic [63:0]  memb_data, init_data;
    logic [31:0]  rm_data, blk_data;
    logic [127:0] entry_data;

    wire is_dispatch = (work_ctype_i ==
                        32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT));

    // valid/ready: the record is consumed only when the accept FSM is
    // idle and nothing is in flight; a work_i held while !ready is
    // retried by the caller, never dropped.
    assign work_ready_o = (cast_q == C_IDLE) && !wbusy &&
                          !disp_q_valid;
    assign busy_o = wbusy | (cast_q == C_SENT) | disp_q_valid;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cast_q <= C_IDLE; disp_q <= '0; disp_q_valid <= 1'b0;
        wid_q <= '0;
        done_o <= 1'b0; done_pl_o <= '0;
      end else begin
        done_o <= 1'b0;
        if (work_i && work_ready_o) begin
          wid_q <= wid_q + 1;
          if (is_dispatch) begin
            disp_q.slot    <= disp_slot_i;
            disp_q.gx      <= work_imm_i[15:0];
            disp_q.gy      <= work_imm_i[47:32];
            disp_q.gz      <= work_imm_i[79:64];
            disp_q.work_id <= wid_q;
            disp_q_valid   <= 1'b1;
            cast_q <= C_SENT;
          end else begin
            // vkCmdDispatchIndirect and every unknown ctype:
            // unsupported in 4a — never silently succeed.
            done_o <= 1'b1;
            done_pl_o <= '{code: APU_SH_DONE_UNSUPPORTED, wave: '0,
                          pc: '0, robust: '0, work_id: wid_q};
          end
        end
        if (disp_q_valid && !wbusy) disp_q_valid <= 1'b0;
        if (wdone) begin
          cast_q <= C_IDLE;
          done_o <= 1'b1;
          done_pl_o <= wdone_pl;
        end
      end
    end

    g6lc_apu_shmod #(
      .Enable(Enable), .ShaderSlots(ShaderSlots),
      .ShaderIds(ShaderIds), .ShaderRegs(ShaderRegs),
      .ShaderWords(ShaderWords), .ShaderMembers(ShaderMembers),
      .ShaderInit(ShaderInit)
    ) i_mod (
      .clk_i, .rst_ni, .testmode_i,
      .wr_en_i, .wr_slot_i, .wr_addr_i, .wr_data_i,
      .commit_i, .commit_pl_i,
      .busy_o(c_busy_o), .done_o(c_done_o), .done_pl_o(c_done_pl_o),
      .retire_i, .retire_slot_i,
      .rd_slot_i(rd_slot), .prog_addr_i(prog_addr),
      .prog_data_o(prog_data),
      .type_id_i(type_id), .type_data_o(type_data),
      .const_id_i(const_id), .const_data_o(const_data),
      .memb_id_i(memb_id), .memb_data_o(memb_data),
      .decor_id_i(10'h0), .decor_data_o(),
      .var_id_i(10'h0), .var_data_o(),
      .rm_id_i(rm_id), .rm_data_o(rm_data),
      .init_id_i(init_id), .init_data_o(init_data),
      .blk_id_i(blk_id), .blk_data_o(blk_data),
      .entry_data_o(entry_data)
    );

    g6lc_apu_shwave #(
      .Enable(Enable), .ShaderLanes(ShaderLanes),
      .ShaderVec(ShaderVec), .ShaderRegs(ShaderRegs),
      .MaxWaves(MaxWaves), .ShaderIds(ShaderIds),
      .ShaderSlots(ShaderSlots), .ShaderWords(ShaderWords),
      .ShaderInit(ShaderInit), .ShaderMembers(ShaderMembers),
      .ScratchBytes(ScratchBytes), .SlabBytes(SlabBytes),
      .ShaderBudget(ShaderBudget)
    ) i_wave (
      .clk_i, .rst_ni, .testmode_i,
      .disp_i(disp_q_valid && !wbusy), .disp_pl_i(disp_q),
      .binds_i, .push_n_i, .push_i,
      .busy_o(wbusy), .done_o(wdone), .done_pl_o(wdone_pl),
      .rd_slot_o(rd_slot), .prog_addr_o(prog_addr),
      .prog_data_i(prog_data),
      .type_id_o(type_id), .type_data_i(type_data),
      .const_id_o(const_id), .const_data_i(const_data),
      .memb_id_o(memb_id), .memb_data_i(memb_data),
      .rm_id_o(rm_id), .rm_data_i(rm_data),
      .init_id_o(init_id), .init_data_i(init_data),
      .blk_id_o(blk_id), .blk_data_i(blk_data),
      .entry_data_i(entry_data),
      .mem_re_o, .mem_we_o, .mem_addr_o, .mem_wdata_o,
      .mem_wstrb_o, .mem_rdata_i
    );
  end
endmodule

// Thin fixture for the yosys Enable=0/1 screens (generic flow).
module g6lc_apu_shcore_fixture
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderLanes   = 8,
  parameter int unsigned ShaderVec     = 4,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 8,
  parameter int unsigned ShaderIds     = 1024,
  parameter int unsigned ShaderSlots   = 8,
  parameter int unsigned ShaderWords   = 2048,
  parameter int unsigned ShaderInit    = 128,
  parameter int unsigned ShaderMembers = 256,
  parameter int unsigned ScratchBytes  = 1024,
  parameter int unsigned SlabBytes     = 16384,
  parameter int unsigned ShaderBudget  = 32'h0010_0000
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         testmode_i,
  input  logic         wr_en_i,
  input  logic [2:0]   wr_slot_i,
  input  logic [15:0]  wr_addr_i,
  input  logic [31:0]  wr_data_i,
  input  logic         commit_i,
  input  apu_sh_commit_t commit_pl_i,
  output logic         c_busy_o,
  output logic         c_done_o,
  output apu_sh_cpl_t  c_done_pl_o,
  input  logic         retire_i,
  input  logic [2:0]   retire_slot_i,
  input  logic         work_i,
  output logic         work_ready_o,
  input  logic [31:0]  work_ctype_i,
  input  logic [8*32-1:0] work_imm_i,
  input  logic [2:0]   disp_slot_i,
  input  logic [16*113-1:0] binds_i,
  input  logic [5:0]   push_n_i,
  input  logic [1023:0] push_i,
  output logic         busy_o,
  output logic         done_o,
  output apu_sh_done_t done_pl_o,
  output logic         mem_re_o,
  output logic         mem_we_o,
  output logic [63:0]  mem_addr_o,
  output logic [63:0]  mem_wdata_o,
  output logic [7:0]   mem_wstrb_o,
  input  logic [63:0]  mem_rdata_i
);
  g6lc_apu_shcore #(.Enable(Enable), .ShaderLanes(ShaderLanes),
      .ShaderVec(ShaderVec), .ShaderRegs(ShaderRegs),
      .MaxWaves(MaxWaves), .ShaderIds(ShaderIds),
      .ShaderSlots(ShaderSlots), .ShaderWords(ShaderWords),
      .ShaderInit(ShaderInit), .ShaderMembers(ShaderMembers),
      .ScratchBytes(ScratchBytes), .SlabBytes(SlabBytes),
      .ShaderBudget(ShaderBudget)
    ) i_dut (.*);
endmodule
