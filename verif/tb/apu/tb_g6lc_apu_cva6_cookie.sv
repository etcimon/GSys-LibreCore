// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Dual-core g6lc_cluster PerCoreBoot: hart 1 runs apu_fw.hex through firmware
// RAM and the protected control mailbox to cookie 0x600D000A. L2/L3 off.
// Not OpenSBI, not UART/PLIC/DRAM, not TEX, not FPGA.

`timescale 1ns/1ps
`include "rvfi_types.svh"

package g6lc_cva6_cookie_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  import axi_pkg::*;
  localparam int unsigned NRules = 6;
  localparam int unsigned DramIdx = 0;
  localparam int unsigned RomIdx = 8;
  localparam int unsigned GuestIdx = 10;
  localparam int unsigned CtrlIdx = 11;
  localparam int unsigned RamIdx = 12;
  localparam logic [63:0] AppBoot = 64'h1_0000;
  localparam logic [63:0] DramBase = 64'h8000_0000;
  localparam logic [63:0] DramBytes = 64'h4000_0000;
  localparam logic [31:0] CookieAddr = 32'h9003_FF00;
  localparam logic [31:0] CookieOk = 32'h600D_000A;

  function automatic config_pkg::cva6_cfg_t cluster_cfg();
    config_pkg::cva6_cfg_t c;
    c = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
    c.L2En = 1'b0;
    c.L3En = 1'b0;
    c.ServerPrefetchEn = 1'b0;
    return c;
  endfunction
  function automatic apu_cfg_t ram_cfg();
    apu_cfg_t cfg = ApuHarness;
    return cfg;
  endfunction
  function automatic apu_cfg_t rom_cfg();
    apu_cfg_t cfg = ApuHarness;
    cfg.FirmwareRamBase = AppBoot;
    cfg.FirmwareRamBytes = 64'h1000;
    return cfg;
  endfunction
  function automatic apu_cfg_t fw_cfg();
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = 1'b1;
    cfg.ExecEn = 1'b1;
    cfg.ExecQuadThreads = 4;
    cfg.ExecRegs = 8;
    cfg.ExecMemWords = 64;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t fw_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
  function automatic int last_match(input logic [63:0] a,
      input xbar_rule_64_t [NRules-1:0] rules);
    int idx;
    int i;
    idx = -1;
    for (i = 0; i < int'(NRules); i++)
      if (a >= rules[i].start_addr && a < rules[i].end_addr)
        idx = int'(rules[i].idx);
    return idx;
  endfunction
endpackage

module g6lc_apu_cookie_mux
  import axi_pkg::*;
  import g6lc_cva6_cookie_test_pkg::*;
#(
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  axi_req_t mem_req_i,
  output axi_rsp_t mem_rsp_o,
  output axi_req_t ram_req_o,
  input  axi_rsp_t ram_rsp_i,
  output axi_req_t rom_req_o,
  input  axi_rsp_t rom_rsp_i,
  output axi_req_t ctrl_req_o,
  input  axi_rsp_t ctrl_rsp_i,
  output axi_req_t dram_req_o,
  input  axi_rsp_t dram_rsp_i,
  input  xbar_rule_64_t [NRules-1:0] rules_i
);
  typedef enum logic [2:0] {
    DestDram, DestRom, DestRam, DestCtrl, DestNone
  } dest_e;
  function automatic dest_e dest_of(input int idx);
    unique case (idx)
      int'(DramIdx): return DestDram;
      int'(RomIdx):  return DestRom;
      int'(RamIdx):  return DestRam;
      int'(CtrlIdx): return DestCtrl;
      default:       return DestNone;
    endcase
  endfunction
  function automatic axi_rsp_t pick(input dest_e d);
    unique case (d)
      DestRam:  return ram_rsp_i;
      DestRom:  return rom_rsp_i;
      DestCtrl: return ctrl_rsp_i;
      default:  return dram_rsp_i;
    endcase
  endfunction

  dest_e r_dest_q, w_dest_q, dest_ar, dest_aw;
  logic r_busy_q, w_busy_q;
  axi_rsp_t sel, ar_pick, aw_pick, w_pick;

  assign dest_ar = dest_of(last_match(mem_req_i.ar.addr, rules_i));
  assign dest_aw = dest_of(last_match(mem_req_i.aw.addr, rules_i));
  assign sel = r_busy_q ? pick(r_dest_q) :
               w_busy_q ? pick(w_dest_q) : dram_rsp_i;
  assign ar_pick = pick(dest_ar);
  assign aw_pick = pick(dest_aw);
  assign w_pick = pick(w_busy_q ? w_dest_q : dest_aw);

  always_comb begin
    ram_req_o = mem_req_i;
    rom_req_o = mem_req_i;
    ctrl_req_o = mem_req_i;
    dram_req_o = mem_req_i;
    ram_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && dest_ar == DestRam;
    rom_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && dest_ar == DestRom;
    ctrl_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && dest_ar == DestCtrl;
    dram_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q && dest_ar == DestDram;
    ram_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && dest_aw == DestRam;
    rom_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && dest_aw == DestRom;
    ctrl_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && dest_aw == DestCtrl;
    dram_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q && dest_aw == DestDram;
    ram_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestRam) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestRam));
    rom_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestRom) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestRom));
    ctrl_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestCtrl) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestCtrl));
    dram_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestDram) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestDram));
    ram_req_o.r_ready = mem_req_i.r_ready && r_busy_q && r_dest_q == DestRam;
    rom_req_o.r_ready = mem_req_i.r_ready && r_busy_q && r_dest_q == DestRom;
    ctrl_req_o.r_ready = mem_req_i.r_ready && r_busy_q && r_dest_q == DestCtrl;
    dram_req_o.r_ready = mem_req_i.r_ready && r_busy_q && r_dest_q == DestDram;
    ram_req_o.b_ready = mem_req_i.b_ready && w_busy_q && w_dest_q == DestRam;
    rom_req_o.b_ready = mem_req_i.b_ready && w_busy_q && w_dest_q == DestRom;
    ctrl_req_o.b_ready = mem_req_i.b_ready && w_busy_q && w_dest_q == DestCtrl;
    dram_req_o.b_ready = mem_req_i.b_ready && w_busy_q && w_dest_q == DestDram;

    mem_rsp_o = sel;
    mem_rsp_o.ar_ready = !r_busy_q && dest_ar != DestNone && ar_pick.ar_ready;
    mem_rsp_o.aw_ready = !w_busy_q && dest_aw != DestNone && aw_pick.aw_ready;
    mem_rsp_o.w_ready = w_busy_q ? w_pick.w_ready :
        (mem_req_i.aw_valid && dest_aw != DestNone && aw_pick.w_ready);
    if (r_busy_q) begin
      mem_rsp_o.r_valid = sel.r_valid;
      mem_rsp_o.r = sel.r;
    end else
      mem_rsp_o.r_valid = 1'b0;
    if (w_busy_q) begin
      mem_rsp_o.b_valid = sel.b_valid;
      mem_rsp_o.b = sel.b;
    end else
      mem_rsp_o.b_valid = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_busy_q <= 1'b0;
      w_busy_q <= 1'b0;
      r_dest_q <= DestNone;
      w_dest_q <= DestNone;
    end else begin
      if (!r_busy_q && mem_req_i.ar_valid && mem_rsp_o.ar_ready) begin
        r_busy_q <= 1'b1;
        r_dest_q <= dest_ar;
      end else if (r_busy_q && mem_rsp_o.r_valid && mem_req_i.r_ready &&
                   mem_rsp_o.r.last)
        r_busy_q <= 1'b0;
      if (!w_busy_q && mem_req_i.aw_valid && mem_rsp_o.aw_ready) begin
        w_busy_q <= 1'b1;
        w_dest_q <= dest_aw;
      end else if (w_busy_q && mem_rsp_o.b_valid && mem_req_i.b_ready)
        w_busy_q <= 1'b0;
    end
  end
endmodule

module g6lc_apu_cookie_poison
  import axi_pkg::*;
#(
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic,
  parameter logic [63:0] HoleBase = 64'h9000_0000,
  parameter logic [63:0] HoleBytes = 64'h40000
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  axi_req_t slv_req_i,
  output axi_rsp_t slv_rsp_o,
  output logic hole_hit_o
);
  localparam int unsigned IdW = $bits(slv_req_i.aw.id);
  localparam int unsigned LenW = $bits(slv_req_i.ar.len);
  typedef enum logic [1:0] { Idle, SendR, SendB } state_e;
  state_e state_q;
  logic [IdW-1:0] id_q;
  logic [LenW-1:0] beats_q;
  logic hole_q;
  function automatic logic in_hole(input logic [63:0] a);
    return a >= HoleBase && (a - HoleBase) < HoleBytes;
  endfunction

  assign hole_hit_o = hole_q;
  always_comb begin
    slv_rsp_o = '0;
    unique case (state_q)
      Idle: begin
        slv_rsp_o.aw_ready = 1'b1;
        slv_rsp_o.w_ready  = slv_req_i.aw_valid;
        slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
      end
      SendB: begin
        slv_rsp_o.b_valid = 1'b1;
        slv_rsp_o.b.id = id_q;
        slv_rsp_o.b.resp = RESP_SLVERR;
      end
      default: begin
        slv_rsp_o.r_valid = 1'b1;
        slv_rsp_o.r.id = id_q;
        slv_rsp_o.r.resp = RESP_SLVERR;
        slv_rsp_o.r.last = (beats_q == '0);
      end
    endcase
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle;
      id_q <= '0;
      beats_q <= '0;
      hole_q <= 1'b0;
    end else unique case (state_q)
      Idle: begin
        if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
          id_q <= slv_req_i.aw.id;
          if (in_hole(slv_req_i.aw.addr)) hole_q <= 1'b1;
          state_q <= SendB;
        end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
          id_q <= slv_req_i.ar.id;
          beats_q <= slv_req_i.ar.len;
          if (in_hole(slv_req_i.ar.addr)) hole_q <= 1'b1;
          state_q <= SendR;
        end
      end
      SendB: if (slv_req_i.b_ready) state_q <= Idle;
      default: if (slv_req_i.r_ready) begin
        if (beats_q == '0) state_q <= Idle;
        else beats_q <= beats_q - 1;
      end
    endcase
  end
endmodule

module tb_g6lc_apu_cva6_cookie;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_cva6_cookie_test_pkg::*;
  import axi_pkg::*;
  localparam config_pkg::cva6_cfg_t CoreCfg = cluster_cfg();
  typedef `RVFI_PROBES_INSTR_T(CoreCfg) rvfi_instr_t;
  typedef `RVFI_PROBES_CSR_T(CoreCfg) rvfi_csr_t;
  typedef struct packed {
    rvfi_csr_t csr;
    rvfi_instr_t instr;
  } rvfi_probes_t;

  logic clk = 0, rst_ni = 0, fw_ready, hole_hit;
  logic [1:0][CoreCfg.VLEN-1:0] boot;
  logic [63:0] boot0_full, boot1_full;
  ariane_axi::req_t mem_req, ram_req, rom_req, dram_req, ctrl4_req;
  ariane_axi::resp_t mem_rsp, ram_rsp, rom_rsp, dram_rsp, ctrl4_rsp;
  apu_axi_req_t ctrl_lite_req, guest_req;
  apu_axi_resp_t ctrl_lite_rsp, guest_rsp;
  apu_dma_axi_req_t dma_req;
  apu_dma_axi_resp_t dma_rsp;
  rvfi_probes_t rvfi0, rvfi1;
  xbar_rule_64_t [NRules-1:0] rules;
  logic [1:0] saw_ar, saw_commit, saw_ctrl;
  logic [31:0] cookie_q, aw_addr_q;
  logic cookie_aw_q;
  wire [31:0] cookie_aw_now = (ram_req.aw_valid && ram_rsp.aw_ready)
      ? ram_req.aw.addr[31:0] : aw_addr_q;
  int errors = 0, checks = 0, cycles = 0;
  logic [APU_NUM_QUEUES-1:0] qen, qstop;
  logic guest_irq, control_irq, reset_req, bus_fault, used_ready;
  apu_vq_state_t vq [APU_NUM_QUEUES];

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  assign boot0_full = apu_core_boot_addr(ApuHarness, 0, AppBoot);
  assign boot1_full = apu_core_boot_addr(ApuHarness, 1, AppBoot);
  assign boot[0] = CoreCfg.VLEN'(boot0_full);
  assign boot[1] = CoreCfg.VLEN'(boot1_full);
  assign guest_req = '0;
  assign dma_rsp = '0;

  assign rules[0] = '{idx: RomIdx, start_addr: AppBoot,
                      end_addr: AppBoot + 64'h1_0000};
  assign rules[1] = '{idx: DramIdx, start_addr: DramBase,
                      end_addr: apu_dram_lo_end(ApuHarness.FirmwareRamBase)};
  assign rules[2] = '{idx: GuestIdx, start_addr: ApuHarness.MmioBase,
                      end_addr: ApuHarness.MmioBase + ApuHarness.MmioLength};
  assign rules[3] = '{idx: CtrlIdx, start_addr: ApuHarness.ControlBase,
                      end_addr: ApuHarness.ControlBase + ApuHarness.ControlLength};
  assign rules[4] = '{idx: RamIdx, start_addr: ApuHarness.FirmwareRamBase,
                      end_addr: ApuHarness.FirmwareRamBase +
                                ApuHarness.FirmwareRamBytes};
  assign rules[5] = '{idx: DramIdx,
                      start_addr: apu_dram_hi_start(ApuHarness.FirmwareRamBase,
                                                    ApuHarness.FirmwareRamBytes),
                      end_addr: DramBase + DramBytes};

  initial begin
    fw_ready = 1'b0;
    #1;
    fw_ready = 1'b1;
  end

  g6lc_cluster #(
    .CVA6Cfg(CoreCfg),
    .NR_CORES(2),
    .L2_ENABLE(1'b0),
    .IDENTITY_FAST(1'b1),
    .INCLUSIVE_L3(1'b0),
    .PerCoreBoot(1'b1),
    .AXI_ADDR_WIDTH(ariane_axi::AddrWidth),
    .AXI_DATA_WIDTH(ariane_axi::DataWidth),
    .AXI_ID_WIDTH(ariane_axi::IdWidth),
    .AXI_USER_WIDTH(ariane_axi::UserWidth),
    .axi_req_t(ariane_axi::req_t),
    .axi_resp_t(ariane_axi::resp_t),
    .rvfi_probes_t(rvfi_probes_t)
  ) i_cluster (
    .clk_i(clk),
    .rst_ni(rst_ni),
    .boot_addr_i(boot[0]),
    .boot_addr_core_i(boot),
    .irq_i('0),
    .ipi_i('0),
    .time_irq_i('0),
    .rtc_time_i('0),
    .debug_req_i('0),
    .mem_req_o(mem_req),
    .mem_resp_i(mem_rsp),
    .rvfi_probes_o(rvfi0),
    .l2_miss_o(),
    .l3_hit_o(),
    .l3_miss_o(),
    .pf_issue_o(),
    .pf_train_o(),
    .ai_sb_enq_valid_o(),
    .ai_sb_qid_o(),
    .ai_sb_ticket_o(),
    .ai_sb_desc_ptr_o(),
    .ai_isl_has_completion_i(1'b0),
    .ai_isl_last_ticket_i('0),
    .ai_isl_last_status_i('0)
  );

  assign rvfi1 = i_cluster.gen_core[1].i_ariane.rvfi_probes_o;

  g6lc_apu_cookie_mux #(
    .axi_req_t(ariane_axi::req_t),
    .axi_rsp_t(ariane_axi::resp_t)
  ) i_mux (
    .clk_i(clk),
    .rst_ni,
    .mem_req_i(mem_req),
    .mem_rsp_o(mem_rsp),
    .ram_req_o(ram_req),
    .ram_rsp_i(ram_rsp),
    .rom_req_o(rom_req),
    .rom_rsp_i(rom_rsp),
    .ctrl_req_o(ctrl4_req),
    .ctrl_rsp_i(ctrl4_rsp),
    .dram_req_o(dram_req),
    .dram_rsp_i(dram_rsp),
    .rules_i(rules)
  );

  g6lc_apu_fwram #(
    .ApuCfg(rom_cfg()),
    .RamIdx(RomIdx),
    .HexFile("rom_spin.hex"),
    .axi4_req_t(ariane_axi::req_t),
    .axi4_rsp_t(ariane_axi::resp_t)
  ) i_rom (
    .clk_i(clk),
    .rst_ni,
    .testmode_i(1'b1),
    .aw_hart_i(32'd1),
    .ar_hart_i(32'd1),
    .slv_req_i(rom_req),
    .slv_rsp_o(rom_rsp),
    .ram_rule_o(),
    .ram_base_o(),
    .ram_end_o()
  );

  g6lc_apu_fwram #(
    .ApuCfg(ram_cfg()),
    .RamIdx(RamIdx),
    .HexFile("apu_fw.hex"),
    .axi4_req_t(ariane_axi::req_t),
    .axi4_rsp_t(ariane_axi::resp_t)
  ) i_ram (
    .clk_i(clk),
    .rst_ni,
    .testmode_i(1'b1),
    .aw_hart_i(32'd1),
    .ar_hart_i(32'd1),
    .slv_req_i(ram_req),
    .slv_rsp_o(ram_rsp),
    .ram_rule_o(),
    .ram_base_o(),
    .ram_end_o()
  );

  g6lc_apu_cookie_poison #(
    .axi_req_t(ariane_axi::req_t),
    .axi_rsp_t(ariane_axi::resp_t),
    .HoleBase(ApuHarness.FirmwareRamBase),
    .HoleBytes(ApuHarness.FirmwareRamBytes)
  ) i_dram (
    .clk_i(clk),
    .rst_ni,
    .slv_req_i(dram_req),
    .slv_rsp_o(dram_rsp),
    .hole_hit_o(hole_hit)
  );

  g6lc_apu_axi4_lite #(
    .Enable(1'b1),
    .axi4_req_t(ariane_axi::req_t),
    .axi4_rsp_t(ariane_axi::resp_t),
    .lite_req_t(apu_axi_req_t),
    .lite_rsp_t(apu_axi_resp_t)
  ) i_ctrl_ad (
    .clk_i(clk),
    .rst_ni,
    .testmode_i(1'b1),
    .slv_req_i(ctrl4_req),
    .slv_rsp_o(ctrl4_rsp),
    .lite_req_o(ctrl_lite_req),
    .epoch_i('0),
    .hold_o(),
    .admitted_o(),
    .lite_rsp_i(ctrl_lite_rsp)
  );

  g6lc_apu_fw #(
    .ApuCfg(fw_cfg()),
    .CoreCfg(fw_core())
  ) i_fw (
    .clk_i(clk),
    .rst_ni,
    .testmode_i(1'b1),
    .guest_req_i(guest_req),
    .guest_rsp_o(guest_rsp),
    .control_req_i(ctrl_lite_req),
    .control_rsp_o(ctrl_lite_rsp),
    .control_aw_authorized_i(1'b1),
    .control_ar_authorized_i(1'b1),
    .guest_irq_o(guest_irq),
    .control_irq_o(control_irq),
    .vq_state_o(vq),
    .queue_enable_o(qen),
    .backend_reset_req_o(reset_req),
    .backend_queue_stop_req_o(qstop),
    .backend_reset_done_i(1'b1),
    .backend_idle_i({APU_NUM_QUEUES{1'b1}}),
    .used_valid_i(1'b0),
    .used_qid_i('0),
    .used_context_i('0),
    .used_fence_i('0),
    .used_len_i('0),
    .used_ready_o(used_ready),
    .cfg_display_event_i(1'b0),
    .bus_fault_o(bus_fault),
    .dma_req_o(dma_req),
    .dma_rsp_i(dma_rsp)
  );

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s cycle=%0d cookie=%h", name, cycles, cookie_q);
    end
  endtask

  initial begin
    #200000000;
    $fatal(1, "cva6 cookie timeout ar=%b commit=%b ctrl=%b cookie=%h cycles=%0d",
           saw_ar, saw_commit, saw_ctrl, cookie_q, cycles);
  end

  always @(posedge clk) begin
    if (rst_ni && rom_req.ar_valid && rom_rsp.ar_ready &&
        rom_req.ar.addr[31:16] == 16'h1)
      saw_ar[0] <= 1'b1;
    if (rst_ni && ram_req.ar_valid && ram_rsp.ar_ready &&
        ram_req.ar.addr[31:16] == 16'h9000 &&
        ram_req.ar.size == 3'd3 && ram_req.ar.len == 8'd1)
      saw_ar[1] <= 1'b1;
    if (rst_ni && ctrl4_req.ar_valid && ctrl4_rsp.ar_ready &&
        ctrl4_req.ar.addr[31:12] == 20'h40002)
      saw_ctrl[0] <= 1'b1;
    if (rst_ni && ctrl4_req.aw_valid && ctrl4_rsp.aw_ready &&
        ctrl4_req.aw.addr[31:12] == 20'h40002)
      saw_ctrl[1] <= 1'b1;
    if (rst_ni && rvfi0.instr.commit_instr_valid[0] &&
        rvfi0.instr.commit_ack[0] && !rvfi0.instr.commit_drop[0] &&
        rvfi0.instr.commit_instr_pc[0] == CoreCfg.VLEN'(AppBoot))
      saw_commit[0] <= 1'b1;
    if (rst_ni && rvfi1.instr.commit_instr_valid[0] &&
        rvfi1.instr.commit_ack[0] && !rvfi1.instr.commit_drop[0] &&
        rvfi1.instr.commit_instr_pc[0] ==
            CoreCfg.VLEN'(ApuHarness.FirmwareRamBase))
      saw_commit[1] <= 1'b1;
    if (rst_ni && ram_req.aw_valid && ram_rsp.aw_ready) begin
      aw_addr_q <= ram_req.aw.addr[31:0];
      cookie_aw_q <= ram_req.aw.addr[31:0] == CookieAddr;
    end
    if (rst_ni && ram_req.w_valid && ram_rsp.w_ready &&
        cookie_aw_now == CookieAddr) begin
      if (|ram_req.w.strb[3:0])
        cookie_q <= ram_req.w.data[31:0];
      else if (|ram_req.w.strb[7:4])
        cookie_q <= ram_req.w.data[63:32];
    end
  end

  initial begin
    apu_cfg_t fw_on;
    saw_ar = '0;
    saw_commit = '0;
    saw_ctrl = '0;
    cookie_aw_q = 1'b0;
    cookie_q = '0;
    aw_addr_q = '0;
    fw_on = fw_cfg();
    repeat (8) @(negedge clk);
    check("fw_ready hold", fw_ready === 1'b1);
    check("hart 0 boot ROM", boot0_full == AppBoot);
    check("hart 1 boot firmware RAM",
          boot1_full == ApuHarness.FirmwareRamBase);
    check("exec enabled on firmware DUT", fw_on.ExecEn === 1'b1);
    check("ApuHarness exec stays off", ApuHarness.ExecEn === 1'b0);
    rst_ni = fw_ready;
    while (cookie_q !== CookieOk) @(posedge clk);
    @(posedge clk);
    check("ROM AR", saw_ar[0]);
    check("firmware I$ fill", saw_ar[1]);
    check("core0 committed ROM", saw_commit[0]);
    check("core1 committed firmware RAM", saw_commit[1]);
    check("control MMIO read", saw_ctrl[0]);
    check("control MMIO write", saw_ctrl[1]);
    check("cookie 0x600D000A", cookie_q == CookieOk);
    check("DRAM hole not stolen", hole_hit === 1'b0);
    check("DMA initiator idle", !dma_req.ar_valid && !dma_req.aw_valid);
    if (errors != 0) $fatal(1, "APU cva6 cookie errors=%0d", errors);
    $display("PASS tb_g6lc_apu_cva6_cookie checks=%0d cycles=%0d cookie=%h errors=0",
             checks, cycles, cookie_q);
    $finish;
  end
endmodule
