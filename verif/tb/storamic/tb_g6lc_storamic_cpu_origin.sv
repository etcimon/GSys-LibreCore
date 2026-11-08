// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`include "axi/typedef.svh"
module tb_g6lc_storamic_cpu_origin;
  parameter bit OriginEnabled = 1;
  parameter bit IntegerDiagnostic = 0;
  localparam logic [63:0] Boot = 64'h8000_0000, Probe = 64'h5000_0000;
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_user_cfg_t u = cva6_config_pkg::cva6_cfg;
    config_pkg::cva6_cfg_t c;
    if (IntegerDiagnostic) begin u.RVF = 0; u.RVD = 0; end
    c = build_config_pkg::build_config(u);
    if (OriginEnabled) begin
      c.StoramicEn = 1;
      c.StoramicIoEn = 1;
      c.StoramicCheckpointEn = 1;
    end
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  typedef logic [Cfg.AxiAddrWidth-1:0] addr_t;
  typedef logic [Cfg.AxiIdWidth-1:0] id_t;
  typedef logic [Cfg.AxiDataWidth-1:0] data_t;
  typedef logic [Cfg.AxiDataWidth/8-1:0] strb_t;
  typedef logic [Cfg.AxiUserWidth-1:0] user_t;
  `AXI_TYPEDEF_ALL(cpu, addr_t, id_t, data_t, strb_t, user_t)
  logic clk = 0, rst_n = 0;
  cpu_req_t req;
  cpu_resp_t resp;
  cpu_aw_chan_t write_header;
  cpu_ar_chan_t read_header;
  logic write_owned = 0, read_owned = 0, b_valid = 0;
  logic [7:0] read_beat = 0;
  id_t b_id;
  int read_delay = 0, delay_cycles = 0, cycles = 0;
  int write_checks = 0, read_checks = 0;
  logic [31:0] rom [0:1023];
  logic [31:0] probe_words [0:15];
  bit negative;
  string rom_path;
  always #5 clk = ~clk;

  cva6 #(.CVA6Cfg(Cfg), .noc_req_t(cpu_req_t), .noc_resp_t(cpu_resp_t)) cpu (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(Boot), .hart_id_i('0),
    .irq_i('0), .ipi_i('0), .time_irq_i('0), .rtc_time_i('0), .debug_req_i(1'b0),
    .core_wfi_all_o(), .core_wake_o(), .rvfi_probes_o(), .cvxif_req_o(), .cvxif_resp_i('0),
    .ai_aicfg_o(), .ai_ais_o(), .ai_issue_ok_o(), .ai_q_en_o(), .ai_qid_o(),
    .dirty_ai_state_i(1'b0), .ai_setcfg_we_i(1'b0), .ai_setcfg_wdata_i('0),
    .ai_pmu_op_i(1'b0), .ai_pmu_mma_i(1'b0), .ai_pmu_post_i(1'b0),
    .ai_pmu_t0_i(1'b0), .ai_pmu_busy_i(1'b0), .noc_req_o(req), .noc_resp_i(resp),
    .l1_inval_addr_i('0), .l1_inval_valid_i(1'b0), .l1_inval_ready_o(),
    .cmo_valid_o(), .cmo_op_o(), .cmo_addr_o(), .cmo_ready_i(1'b0), .cmo_done_i(1'b0),
    .l2_miss_i(1'b0), .l3_hit_i(1'b0), .l3_miss_i(1'b0), .pf_issue_i(1'b0),
    .pf_train_i(1'b0), .l2_pwhold_i(1'b0), .l3_pwhold_i(1'b0),
    .l2_pf_issue_i(1'b0), .l2_pf_useful_i(1'b0),
    .coh_sf_filtered_i(1'b0), .coh_sf_broadcast_i(1'b0)
  );

  function automatic bit is_probe(input logic [63:0] a);
    return a >= Probe && a < Probe + 64'h40;
  endfunction
  function automatic logic [2:0] expected_prot(input logic [63:0] a);
    logic [2:0] result;
    case (a - Probe)
      0: result = 3'b001;      // M
      8, 24: result = 3'b011;  // S and M executing with MPRV/MPP=S
      16, 32: result = 3'b010; // U, including completion
      default: result = 3'b000;
    endcase
    if (!OriginEnabled) result = 3'b000;
    if (negative && a == Probe) result[0] = ~result[0];
    return result;
  endfunction
  function automatic data_t read_data(input logic [63:0] a);
    int index;
    if (is_probe(a)) begin
      index = int'((a - Probe) >> 2);
      return {2{probe_words[index]}};
    end
    if (a >= Boot && a < Boot + 4096) begin
      index = int'(((a - Boot) >> 3) << 1);
      return {rom[index + 1], rom[index]};
    end
    return '0;
  endfunction
  always_comb begin
    resp = '0;
    resp.aw_ready = !write_owned && !b_valid;
    resp.w_ready = write_owned && !b_valid;
    resp.b_valid = b_valid;
    resp.b.id = b_id;
    resp.ar_ready = !read_owned;
    resp.r_valid = read_owned && read_delay == 0;
    resp.r.id = read_header.id;
    resp.r.last = read_beat == read_header.len;
    resp.r.data = read_data(read_header.addr +
        (64'(read_beat) << read_header.size));
  end
  always @(posedge clk) if (rst_n) begin
    cycles <= cycles + 1;
    if (cycles > 200000) $fatal(1, "CPU_ORIGIN_FAIL timeout writes=%0d reads=%0d",
                              write_checks, read_checks);
    if (req.aw_valid && resp.aw_ready) begin
      write_owned <= 1;
      write_header <= req.aw;
      if (is_probe(req.aw.addr) && req.aw.addr != Probe + 36) begin
        assert(req.aw.prot == expected_prot(req.aw.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL aw-prot addr=%h got=%h expected=%h",
                 req.aw.addr, req.aw.prot, expected_prot(req.aw.addr));
        assert(req.aw.len == 0 && req.aw.size == 2 && !req.aw.lock &&
               req.aw.atop == 0 && req.aw.cache == axi_pkg::CACHE_MODIFIABLE) else
          $fatal(1, "CPU_ORIGIN_FAIL probe-write-shape addr=%h len=%0d size=%0d lock=%0d atop=%h cache=%h",
                 req.aw.addr, req.aw.len, req.aw.size, req.aw.lock, req.aw.atop, req.aw.cache);
        write_checks <= write_checks + 1;
      end
    end
    if (req.w_valid && resp.w_ready) begin
      assert(req.w.last) else $fatal(1, "CPU_ORIGIN_FAIL write-burst");
      write_owned <= 0;
      b_valid <= 1;
      b_id <= write_header.id;
      if (write_header.addr == Probe + 36)
        $fatal(1, "CPU_ORIGIN_FAIL architectural-trap");
      if (is_probe(write_header.addr)) begin
        probe_words[int'((write_header.addr - Probe) >> 2)] <=
            write_header.addr[2] ? req.w.data[63:32] : req.w.data[31:0];
        if (write_header.addr == Probe + 32) begin
          assert(write_checks == 5 && read_checks == 4 &&
                 req.w.data[31:0] == 32'h55) else
            $fatal(1, "CPU_ORIGIN_FAIL incomplete-program writes=%0d reads=%0d",
                   write_checks, read_checks);
          $display("CPU_ORIGIN_PASS enabled=%0d integer=%0d delay=%0d cycles=%0d writes=%0d reads=%0d",
                   OriginEnabled, IntegerDiagnostic, delay_cycles, cycles, write_checks, read_checks);
          $finish;
        end
      end
    end
    if (b_valid && req.b_ready) b_valid <= 0;
    if (req.ar_valid && resp.ar_ready) begin
      read_header <= req.ar;
      read_owned <= 1;
      read_beat <= 0;
      read_delay <= delay_cycles;
      if (is_probe(req.ar.addr)) begin
        assert(req.ar.prot == expected_prot(req.ar.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL ar-prot");
        assert(req.ar.cache == axi_pkg::CACHE_MODIFIABLE && !req.ar.lock && req.ar.len == 0) else
          $fatal(1, "CPU_ORIGIN_FAIL probe-read-shape addr=%h len=%0d lock=%0d cache=%h",
                 req.ar.addr, req.ar.len, req.ar.lock, req.ar.cache);
        read_checks <= read_checks + 1;
      end
    end
    if (read_delay > 0) read_delay <= read_delay - 1;
    if (resp.r_valid && req.r_ready) begin
      if (resp.r.last) read_owned <= 0;
      else begin read_beat <= read_beat + 1; read_delay <= delay_cycles; end
    end
  end
  initial begin
    if (OriginEnabled && !config_pkg::g6lc_storamic_origin_supported(Cfg))
      $fatal(1, "CPU_ORIGIN_UNSUPPORTED_PROFILE");
    negative = $test$plusargs("oracle_negative");
    if (!$value$plusargs("rom=%s", rom_path)) $fatal(1, "CPU_ORIGIN_ROM_REQUIRED");
    if (!$value$plusargs("delay=%d", delay_cycles)) delay_cycles = 0;
    foreach (rom[i]) rom[i] = 32'h0000_0013;
    foreach (probe_words[i]) probe_words[i] = 0;
    $readmemh(rom_path, rom);
    repeat (8) @(negedge clk);
    rst_n = 1;
  end
endmodule
