// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// cpu-pause: real cva6 (qualified origin config) -> g6lc_storamic_axi_gate ->
// bench AXI memory, with g6lc_storamic_cpu_pause driving storamic_pause_i and
// gate close. Black-box oracles o1..o4 plus a bounded no-progress watchdog.
// The committed-store reference (o2) is built from the formatted RVFI retire
// stream (cva6_rvfi fed by cpu.rvfi_probes_o): mem_wmask!=0 marks a committed
// store, mem_addr/mem_wdata carry addr+data, AMO results included, failed SC
// masked out. This is independent of the AXI write timing the gate controls.
`include "axi/typedef.svh"
`include "rvfi_types.svh"
module tb_g6lc_storamic_cpu_pause;
  localparam logic [63:0] Boot = 64'h8000_0000, Data = 64'h5000_0000;
  localparam int DataBytes = 2048;
  localparam int DoneOff = 19'h780;    // Data+0x780 completion store (0x5a)
  localparam int TrapOff = 19'h7F8;    // Data+0x7F8 trap store     (0x7f)
  localparam int WatchdogBound = 50000;
  // ---- C5 resync-on-release observability ----------------------------------
  // The whole Boot image (0x8000_0000, CachedRegion len 0x4000_0000) is
  // cacheable for I$ and D$; rom[] is its writable backing. rom[] indices must
  // match g6lc_cpu_pause_program.py (CDataIdx/PATCH_IDX/RESYNC_PROBE_IDX).
  localparam int CDataIdx  = 500;      // cacheable data word (Boot+0x7D0)
  localparam int PatchIdx  = 300;      // patchable addi (Boot+0x4B0)
  localparam int ScratchIdx= 502;      // cacheable CPU-writable scratch
  // Non-cacheable Data log offsets (mirror the program's *_OFF constants).
  localparam int ProbeOff = 19'h740;   // packed {salt,gen} observation (sd)
  localparam int ArmOff   = 19'h748;   // LR/SC armed flag
  localparam int GoOff    = 19'h74C;   // LR/SC go flag
  localparam int RsvOff   = 19'h750;   // LR/SC reserved word
  localparam int ScOff    = 19'h758;   // packed {sc_result,0x5C} (sd)
  localparam int HBOff    = 19'h760;   // probe heartbeat counter (sw)

  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_user_cfg_t u = cva6_config_pkg::cva6_cfg;
    config_pkg::cva6_cfg_t c;
    c = build_config_pkg::build_config(u);
    // qualified origin config: origin_supported() must hold
    c.StoramicEn = 1;
    c.StoramicIoEn = 1;
    c.StoramicCheckpointEn = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  // ---- C5 resync liveness: minimum pause-to-pause run window --------------
  // A release first runs the resync FSM (D$ flush held to ack + commit-head
  // wait, commit still halted) and then the I-cache flush blocks fetch for
  // ICACHE_NUM_WORDS cycles before the refetched head can retire. Both flush
  // lengths are the cache SET count = 2^(INDEX_WIDTH - clog2(LINE_WIDTH/8));
  // the qualified cv64a6_imafdc_sv39 geometries (I$ 16KB/4w, D$ 32KB/8w, 16B
  // lines) give INDEX-OFFSET = 8 -> 256 sets -> a 256-cycle flush each.
  localparam int IC_LINE_OFF_W = $clog2(Cfg.ICACHE_LINE_WIDTH / 8);
  localparam int IC_FLUSH_CYC  = 2 ** (Cfg.ICACHE_INDEX_WIDTH - IC_LINE_OFF_W);
  localparam int DC_FLUSH_CYC = Cfg.DCACHE_NUM_WORDS;
  // The pause-to-pause gap must leave a post-release run window >=
  // IC_FLUSH_CYC + ~150 productive cycles on top of the resync overhead
  // (D$ flush + commit-head wait + release). The +260 covers that overhead
  // (~60 head-wait/release, incl. Sv39 TLB-fill slack) plus the ~150-cycle
  // productive floor and margin; below it the hart livelocks (C5 liveness is
  // the pause requester's obligation -- see cpu-pause-provider.md).
  localparam int RUN_GAP_MIN = DC_FLUSH_CYC + IC_FLUSH_CYC + 260;
  typedef logic [Cfg.AxiAddrWidth-1:0] addr_t;
  typedef logic [Cfg.AxiIdWidth-1:0] id_t;
  typedef logic [Cfg.AxiDataWidth-1:0] data_t;
  typedef logic [Cfg.AxiDataWidth/8-1:0] strb_t;
  typedef logic [Cfg.AxiUserWidth-1:0] user_t;
  `AXI_TYPEDEF_ALL(cpu, addr_t, id_t, data_t, strb_t, user_t)

  // ---- RVFI types (same construction as ariane_testharness) ----
  localparam type rvfi_instr_t = `RVFI_INSTR_T(Cfg);
  localparam type rvfi_csr_elmt_t = `RVFI_CSR_ELMT_T(Cfg);
  localparam type rvfi_csr_t = `RVFI_CSR_T(Cfg, rvfi_csr_elmt_t);
  localparam type rvfi_to_iti_t = `RVFI_TO_ITI_T(Cfg);
  localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(Cfg);
  localparam type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(Cfg);
  localparam type rvfi_probes_t = struct packed {
    rvfi_probes_csr_t csr;
    rvfi_probes_instr_t instr;
  };

  logic clk = 0, rst_n = 0;
  cpu_req_t up_req, dn_req;
  cpu_resp_t up_resp, dn_resp;
  cpu_aw_chan_t write_header;
  cpu_ar_chan_t read_header;
  logic write_owned = 0, read_owned = 0, b_valid = 0;
  logic [7:0] read_beat = 0;
  id_t b_id;
  logic [1:0] b_resp = axi_pkg::RESP_OKAY;
  int read_delay = 0, delay_cycles = 0, cycles = 0;
  int write_checks = 0, read_checks = 0;
  // Liveness watchdog budget (cycles). Deep bus back-pressure legitimately
  // stretches a correct pause/resume stream well past the unstalled figure, so
  // the runner raises this for high +wstall cases; the oracles are unchanged.
  int max_cycles = 400000;
  logic [31:0] rom [0:1023];
  logic [7:0] data_mem [0:DataBytes-1];   // bench AXI memory (gate dn side)
  logic [7:0] ref_mem  [0:DataBytes-1];   // committed-store reference (o2)
  int rvfi_dump_count = 0;                // bounded RVFI field dump (debug)
  string rom_path;
  logic [1:0] write_atomic = 2'b00;
  logic atomic_r_valid = 0;
  logic [1:0] atomic_r_resp = axi_pkg::RESP_OKAY;
  id_t atomic_r_id;
  data_t atomic_r_data;
  int atomic_r_delay = 0;
  logic reserved_valid = 0;
  logic [63:0] reserved_addr = '0;
  bit trace;
  bit ptrace;
  int ptrace_lo = 0, ptrace_hi = -1;
  bit ptrace_hdr = 0;
  // +ostale: fine-grained C5 stale-code trace (replaces, resync/gate edges,
  // retires of the patched addi, o5 probe evals). Simulation-only.
  bit ostale;
  bit directed;
  // ---- AXI ready back-pressure: +wstall/+rstall pseudo-random stretches ----
  // Committed stores linger in the commit queue / D$ write buffer while the
  // downstream AW/W (or AR) ready is deasserted, so a drain acknowledgement
  // that ignores no_st_pending_commit closes the gate over a pending write.
  int wstall_max = 0, rstall_max = 0;
  int wstall_left = 0, wstall_gap = 0, rstall_left = 0, rstall_gap = 0;
  logic [31:0] wstall_lfsr = 32'h9e3779b9, rstall_lfsr = 32'h85ebca6b;
  logic w_stall_act = 1'b0, r_stall_act = 1'b0;
  always #5 clk = ~clk;

  // ---- cva6 with the pause sideband wired to the sequencer ----
  logic core_pause, core_drained;
  cva6 #(.CVA6Cfg(Cfg), .noc_req_t(cpu_req_t), .noc_resp_t(cpu_resp_t),
         .rvfi_probes_instr_t(rvfi_probes_instr_t),
         .rvfi_probes_csr_t(rvfi_probes_csr_t),
         .rvfi_probes_t(rvfi_probes_t)) cpu (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(Boot), .hart_id_i('0),
    .irq_i('0), .ipi_i('0), .time_irq_i('0), .rtc_time_i('0), .debug_req_i(1'b0),
    .core_wfi_all_o(), .core_wake_o(), .rvfi_probes_o(rvfi_probes), .cvxif_req_o(), .cvxif_resp_i('0),
    .ai_aicfg_o(), .ai_ais_o(), .ai_issue_ok_o(), .ai_q_en_o(), .ai_qid_o(),
    .dirty_ai_state_i(1'b0), .ai_setcfg_we_i(1'b0), .ai_setcfg_wdata_i('0),
    .ai_pmu_op_i(1'b0), .ai_pmu_mma_i(1'b0), .ai_pmu_post_i(1'b0),
    .ai_pmu_t0_i(1'b0), .ai_pmu_busy_i(1'b0), .noc_req_o(up_req), .noc_resp_i(up_resp),
    .l1_inval_addr_i('0), .l1_inval_valid_i(1'b0), .l1_inval_ready_o(),
    .cmo_valid_o(), .cmo_op_o(), .cmo_addr_o(), .cmo_ready_i(1'b0), .cmo_done_i(1'b0),
    .l2_miss_i(1'b0), .l3_hit_i(1'b0), .l3_miss_i(1'b0), .pf_issue_i(1'b0),
    .pf_train_i(1'b0), .l2_pwhold_i(1'b0), .l3_pwhold_i(1'b0),
    .l2_pf_issue_i(1'b0), .l2_pf_useful_i(1'b0),
    .coh_sf_filtered_i(1'b0), .coh_sf_broadcast_i(1'b0),
    .storamic_pause_i(core_pause), .storamic_drained_o(core_drained)
  );
  rvfi_probes_t rvfi_probes;

  // ---- AXI gate: CPU boundary -> bench memory ----
  logic gate_close, gate_closed, gate_inflight;
  g6lc_storamic_axi_gate #(.req_t(cpu_req_t), .resp_t(cpu_resp_t)) u_gate (
    .clk_i(clk), .rst_ni(rst_n), .close_i(gate_close),
    .closed_o(gate_closed), .inflight_o(gate_inflight),
    .up_req_i(up_req), .up_resp_o(up_resp),
    .dn_req_o(dn_req), .dn_resp_i(dn_resp)
  );

  // ---- pause sequencer ----
  logic pause_req, paused_o, error_o, gate_close_o;
  g6lc_storamic_cpu_pause u_pause (
    .clk_i(clk), .rst_ni(rst_n), .pause_req_i(pause_req),
    .paused_o(paused_o), .error_o(error_o), .core_pause_o(core_pause),
    .core_drained_i(core_drained), .gate_close_o(gate_close_o),
    .gate_closed_i(gate_closed), .gate_inflight_i(gate_inflight)
  );
  assign gate_close = gate_close_o;

  // ---- formatted RVFI -> committed-store reference (o2) ----
  rvfi_instr_t [Cfg.NrCommitPorts-1:0] rvfi_instr;
  rvfi_csr_t rvfi_csr;
  rvfi_to_iti_t rvfi_to_iti;
  logic [Cfg.NrCommitPorts-1:0][7:0] rvfi_hart;
  cva6_rvfi #(.CVA6Cfg(Cfg), .rvfi_instr_t(rvfi_instr_t),
              .rvfi_csr_t(rvfi_csr_t),
              .rvfi_probes_instr_t(rvfi_probes_instr_t),
              .rvfi_probes_csr_t(rvfi_probes_csr_t),
              .rvfi_probes_t(rvfi_probes_t),
              .rvfi_to_iti_t(rvfi_to_iti_t)) u_rvfi (
    .clk_i(clk), .rst_ni(rst_n), .rvfi_probes_i(rvfi_probes),
    .rvfi_instr_o(rvfi_instr), .rvfi_to_iti_o(rvfi_to_iti),
    .rvfi_csr_o(rvfi_csr), .rvfi_hart_o(rvfi_hart)
  );

  function automatic bit is_data(input logic [63:0] a);
    return a >= Data && a < Data + DataBytes;
  endfunction
  // cacheable Boot image backing (rom[]): CPU stores here are real RAM writes.
  function automatic bit is_boot(input logic [63:0] a);
    return a >= Boot && a < Boot + 4096;
  endfunction
  function automatic logic [63:0] nbytes_mask(input int nbytes);
    return (nbytes >= 8) ? 64'hffff_ffff_ffff_ffff
                        : ((64'(1) << (8 * nbytes)) - 1);
  endfunction
  function automatic logic [63:0] beat_bytes(input data_t d, input int lane,
                                            input int nbytes);
    return (64'(d) >> (8 * lane)) & nbytes_mask(nbytes);
  endfunction
  function automatic data_t data_aligned(input logic [63:0] a);
    int woff;
    data_t w;
    woff = int'(a - Data) & ~7;
    w = '0;
    for (int i = 0; i < 8; i++) w[8*i +: 8] = data_mem[woff + i];
    return w;
  endfunction
  function automatic logic [63:0] atop_compute(input logic [5:0] atop,
      input logic [63:0] old_v, input logic [63:0] operand, input int nbytes);
    logic [63:0] mask, result;
    mask = nbytes_mask(nbytes);
    old_v &= mask; operand &= mask;
    if (atop == axi_pkg::ATOP_ATOMICSWAP) begin
      result = operand;
    end else if (atop[5:4] == 2'b10) begin
      unique case (atop[2:0])
        3'b000: result = (old_v + operand) & mask;
        3'b001: result = old_v & ~operand & mask;
        3'b010: result = (old_v ^ operand) & mask;
        3'b011: result = (old_v | operand) & mask;
        default: result = 'x;
      endcase
    end else begin
      result = 'x;
    end
    return result & mask;
  endfunction
  function automatic data_t read_data(input logic [63:0] a);
    int index;
    if (is_data(a)) return data_aligned(a);
    if (a >= Boot && a < Boot + 4096) begin
      index = int'(((a - Boot) >> 3) << 1);
      return {rom[index + 1], rom[index]};
    end
    return '0;
  endfunction

  // ---- bench AXI slave response (dn side of the gate) ----
  always_comb begin
    dn_resp = '0;
    dn_resp.aw_ready = !write_owned && !b_valid && !w_stall_act;
    dn_resp.w_ready = write_owned && !b_valid && !w_stall_act;
    dn_resp.b_valid = b_valid;
    dn_resp.b.id = b_id;
    dn_resp.b.resp = b_resp;
    dn_resp.ar_ready = !read_owned && !r_stall_act;
    if (atomic_r_valid) begin
      dn_resp.r_valid = atomic_r_delay == 0;
      dn_resp.r.id = atomic_r_id;
      dn_resp.r.resp = atomic_r_resp;
      dn_resp.r.data = atomic_r_data;
      dn_resp.r.last = 1'b1;
    end else begin
      dn_resp.r_valid = read_owned && read_delay == 0;
      dn_resp.r.id = read_header.id;
      dn_resp.r.last = read_beat == read_header.len;
      dn_resp.r.data = read_data(read_header.addr +
          (64'(read_beat) << read_header.size));
    end
  end

  // ---- pseudo-random ready back-pressure (AXI: ready may toggle freely) ----
  // Each channel alternates stall stretches of length 0..max with gaps; the
  // LFSRs are seeded from +seed so different seeds see different patterns.
  always @(posedge clk) if (rst_n) begin
    wstall_lfsr <= {wstall_lfsr[30:0],
                    wstall_lfsr[31] ^ wstall_lfsr[21] ^ wstall_lfsr[1] ^ wstall_lfsr[0]};
    rstall_lfsr <= {rstall_lfsr[30:0],
                    rstall_lfsr[31] ^ rstall_lfsr[21] ^ rstall_lfsr[1] ^ rstall_lfsr[0]};
    if (wstall_max > 0) begin
      if (wstall_left > 0) begin
        wstall_left <= wstall_left - 1;
        w_stall_act  <= 1'b1;
      end else begin
        w_stall_act <= 1'b0;
        if (wstall_gap > 0) wstall_gap <= wstall_gap - 1;
        else begin
          wstall_left <= int'(wstall_lfsr % (wstall_max + 1));
          wstall_gap  <= 6 + int'(wstall_lfsr[15:9] % 30);
        end
      end
    end else w_stall_act <= 1'b0;
    if (rstall_max > 0) begin
      if (rstall_left > 0) begin
        rstall_left <= rstall_left - 1;
        r_stall_act  <= 1'b1;
      end else begin
        r_stall_act <= 1'b0;
        if (rstall_gap > 0) rstall_gap <= rstall_gap - 1;
        else begin
          rstall_left <= int'(rstall_lfsr % (rstall_max + 1));
          rstall_gap  <= 6 + int'(rstall_lfsr[15:9] % 30);
        end
      end
    end else r_stall_act <= 1'b0;
  end

  // ---- cycle-window hierarchical probe: +ptrace +ptrace_lo=N +ptrace_hi=M --
  // One compact line per cycle. Sections: pause/seq | commit | lsu_ctrl |
  // store_buffer+wbuffer | load_unit | bus(up/dn). Field order is fixed; the
  // header line (printed once) names each column group.
  always @(posedge clk) if (rst_n && ptrace && cycles >= ptrace_lo && cycles <= ptrace_hi) begin
    if (!ptrace_hdr) begin
      ptrace_hdr <= 1;
      $display("PTRHDR cyc|PQ CP SHQ SH HC DR SEQ GC GCL GINF PA|CV CPF CFU COP CAK EXV FEX FID FCM SPC ERET|LV LFU LOP LVA LTI|SBV SBWF SBPA SBF SBC SPCNT CCCNT SBEM NSTP WBEM|LDV LDS LPOFF LPOM STFC STFD LDRQ LDGNT LDRV LDKL LPOP LDVO LRES LDTI LPVLD LPADDR|UARV UARR UAAR UAV UAR UAV2 UAR2 UWV URV UBV|DARV DARR DAWV");
    end
    $display("PTR %0d|%b%b%b%b%b%b%0d%b%b%b%b|%b%h%0d%0d%b%b%b%b%b%b%b|%b%0d%0d%h%0d|%b%b%h%b%b%0d%0d%b%b%b|%b%0d%h%b%b%b%b%b%b%b%b%b%h%0d%b%h|%b%b%h%b%b%h%b%b%b%b%b%b",
      cycles,
      pause_req, core_pause, cpu.storamic_halt_q, cpu.storamic_halt,
      cpu.halt_ctrl, core_drained, int'(u_pause.state_q),
      gate_close, gate_closed, gate_inflight, paused_o,
      cpu.commit_instr_id_commit[0].valid, cpu.commit_instr_id_commit[0].pc,
      int'(cpu.commit_instr_id_commit[0].fu), int'(cpu.commit_instr_id_commit[0].op),
      cpu.commit_ack[0], cpu.ex_commit.valid,
      cpu.flush_ctrl_ex, cpu.flush_ctrl_id, cpu.flush_commit,
      cpu.set_pc_ctrl_pcgen, cpu.eret,
      cpu.ex_stage_i.lsu_i.lsu_ctrl.valid, int'(cpu.ex_stage_i.lsu_i.lsu_ctrl.fu),
      int'(cpu.ex_stage_i.lsu_i.lsu_ctrl.operation), cpu.ex_stage_i.lsu_i.lsu_ctrl.vaddr,
      cpu.ex_stage_i.lsu_i.lsu_ctrl.trans_id,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_i,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_without_flush_i,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.paddr_i,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.flush_i,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_i,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_status_cnt_q,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_status_cnt_q,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.store_buffer_empty_o,
      cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.no_st_pending_o,
      cpu.dcache_commit_wbuffer_empty,
      cpu.ex_stage_i.lsu_i.i_load_unit.valid_i, int'(cpu.ex_stage_i.lsu_i.i_load_unit.state_q),
      cpu.ex_stage_i.lsu_i.i_load_unit.page_offset_o,
      cpu.ex_stage_i.lsu_i.i_load_unit.page_offset_matches_i,
      cpu.ex_stage_i.lsu_i.i_load_unit.st_fwd_covers, cpu.ex_stage_i.lsu_i.i_load_unit.st_fwd_done,
      cpu.ex_stage_i.lsu_i.i_load_unit.req_port_o.data_req,
      cpu.ex_stage_i.lsu_i.i_load_unit.req_port_i.data_gnt,
      cpu.ex_stage_i.lsu_i.i_load_unit.req_port_i.data_rvalid,
      cpu.ex_stage_i.lsu_i.i_load_unit.req_port_o.kill_req,
      cpu.ex_stage_i.lsu_i.i_load_unit.pop_ld_o, cpu.ex_stage_i.lsu_i.i_load_unit.valid_o,
      cpu.ex_stage_i.lsu_i.i_load_unit.result_o, cpu.ex_stage_i.lsu_i.i_load_unit.trans_id_o,
      cpu.ex_stage_i.lsu_i.i_load_unit.load_paddr_valid_o, cpu.ex_stage_i.lsu_i.i_load_unit.load_paddr_o,
      up_req.ar_valid, up_resp.ar_ready, up_req.ar.addr,
      up_req.aw_valid, up_resp.aw_ready, up_req.aw.addr,
      up_req.w_valid, up_resp.r_valid, up_resp.b_valid,
      dn_req.ar_valid, dn_resp.ar_ready, dn_req.aw_valid);
  end

  // ================= oracle / monitor sequential block =================
  always @(posedge clk) if (rst_n) begin
    cycles <= cycles + 1;
    // progress heartbeat: distinguishes slow-progress from a hard hang
    if ((cycles % 30000) == 0) begin
      $display("[PROG] cyc=%0d cmt_pc=%h npc=%h cmt_val=%0d rs=%0d rh=%0d hq=%0d pg=%0d",
               cycles, cpu.commit_instr_id_commit[0].pc,
               cpu.smt_npc_live, cpu.commit_instr_id_commit[0].valid,
               cpu.storamic_resync_state_q, cpu.resync_held,
               cpu.storamic_halt_q, cpu.storamic_pause_gated);
      $display("[FE]   fa=%h npcq=%h av=%b apc=%h rpd=%b rpc=%h icv=%b icva=%h icst=%0d infl=%b ia=%h ifr=%b fev=%b ireq=%b iva=%h iresp=%b",
               cpu.i_frontend.fetch_address, cpu.i_frontend.npc_q,
               cpu.i_frontend.arch_valid, cpu.i_frontend.arch_pc,
               cpu.i_frontend.redirect_pend_q, cpu.i_frontend.redirect_pc_q,
               cpu.i_frontend.icache_valid_q, cpu.i_frontend.icache_vaddr_q,
               int'(cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.state_q),
               cpu.i_frontend.inflight_q, cpu.i_frontend.inflight_addr_q,
               cpu.i_frontend.if_ready, cpu.fetch_valid_if_id[0],
               cpu.icache_dreq_if_cache.req, cpu.icache_dreq_if_cache.vaddr,
               cpu.icache_dreq_cache_if.valid);
    end
    // ---- (o3) error_o never ----
    if (error_o) $fatal(1, "CPU_PAUSE_FAIL error_o cycles=%0d", cycles);
    // ---- (o1) while paused_o, zero aw/ar/w valid downstream of the gate ----
    if (paused_o && (dn_req.aw_valid || dn_req.ar_valid || dn_req.w_valid))
      $fatal(1, "CPU_PAUSE_FAIL o1 dn_valid aw=%0d ar=%0d w=%0d cycles=%0d",
             dn_req.aw_valid, dn_req.ar_valid, dn_req.w_valid, cycles);
    if (cycles > max_cycles) begin
      $display("[STALL] dmu_st=%0d mvld=%0d mcnt=%0d wb_empty=%0d | sb_empty=%0d sb_cmt=%0d sb_spec=%0d nstp=%0d | ldu_st=%0d",
               int'(cpu.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.state_q),
               cpu.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.mshr_vld_q,
               cpu.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.cnt_q,
               cpu.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.empty_o,
               cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.store_buffer_empty_o,
               cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_status_cnt_q,
               cpu.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_status_cnt_q,
               cpu.ex_stage_i.lsu_i.no_st_pending_o,
               int'(cpu.ex_stage_i.lsu_i.i_load_unit.state_q));
      $display("[CMT] cmt_pc=%h cmt_val=%0d cmt_fu=%0d cmt_op=%0d cmt_ack=%0d | sbhd=%0d | npc=%h | gate_cl=%0d cls=%0d infl=%0d",
               cpu.commit_instr_id_commit[0].pc,
               cpu.commit_instr_id_commit[0].valid,
               int'(cpu.commit_instr_id_commit[0].fu),
               int'(cpu.commit_instr_id_commit[0].op),
               cpu.commit_ack[0],
               cpu.sb_head_valid[0],
               cpu.smt_npc_live,
               gate_close, gate_closed, gate_inflight);
      $display("[BUS] awv=%0d wr=%0d wv=%0d ar=%0d br=%0d | dn awv=%0d wv=%0d arv=%0d rv=%0d rr=%0d | ar_own=%0d rd_own=%0d bval=%0d arvr=%0d",
               up_req.aw_valid, up_resp.aw_ready, up_req.w_valid,
               up_req.ar_valid, up_resp.b_valid, dn_req.aw_valid,
               dn_req.w_valid, dn_req.ar_valid, dn_resp.r_valid, dn_req.r_ready,
               read_owned, write_owned, b_valid, dn_resp.ar_ready);
      $display("[PAUSE] req=%0d corep=%0d paused=%0d err=%0d drained=%0d gcl=%0d gcls=%0d ginfl=%0d | gen=%0d rw=%0d pd=%0d | lsu_cex=%0d lsu_rdy=%0d stu_st=%0d",
               pause_req, core_pause, paused_o, error_o, core_drained,
               gate_close, gate_closed, gate_inflight,
               gen_state, req_wait, pauses_done,
               cpu.lsu_commit_commit_ex, cpu.lsu_commit_ready_ex_commit,
               int'(cpu.ex_stage_i.lsu_i.i_store_unit.state_q));
      $display("[FE] fa=%h npcq=%h av=%b apc=%h rpd=%b rpc=%h icv=%b icva=%h infl=%b ia=%h ifr=%b fev=%b ireq=%b iva=%h iresp=%b",
               cpu.i_frontend.fetch_address, cpu.i_frontend.npc_q,
               cpu.i_frontend.arch_valid, cpu.i_frontend.arch_pc,
               cpu.i_frontend.redirect_pend_q, cpu.i_frontend.redirect_pc_q,
               cpu.i_frontend.icache_valid_q, cpu.i_frontend.icache_vaddr_q,
               cpu.i_frontend.inflight_q, cpu.i_frontend.inflight_addr_q,
               cpu.i_frontend.if_ready, cpu.fetch_valid_if_id[0],
               cpu.icache_dreq_if_cache.req, cpu.icache_dreq_if_cache.vaddr,
               cpu.icache_dreq_cache_if.valid);
      $display("[FE2] rs=%0d rh=%0d hq=%0d pg=%0d sbh0=%b sbhpc=%h cmtack=%0d exv=%b setpc=%b fif=%b fid=%b fex=%b fic=%b",
               cpu.storamic_resync_state_q, cpu.resync_held, cpu.storamic_halt_q,
               cpu.storamic_pause_gated, cpu.sb_head_valid[0], cpu.sb_head_pc[0],
               cpu.commit_ack[0], cpu.ex_commit.valid,
               cpu.set_pc_ctrl_pcgen, cpu.flush_ctrl_if, cpu.flush_ctrl_id,
               cpu.flush_ctrl_ex, cpu.icache_flush_ctrl_cache);
      $display("[AREQ] icst=%0d fcnt=%0d fen=%0d fdone=%0d areq_req=%b areq_va=%h areq_val=%b areq_pa=%h dreq_rdy=%b mem_req=%b mem_ack=%b en=%b cen=%b",
               int'(cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.state_q),
               int'(cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.flush_cnt_q),
               cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.flush_en,
               cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.flush_done,
               cpu.icache_areq_cache_ex.fetch_req, cpu.icache_areq_cache_ex.fetch_vaddr,
               cpu.icache_areq_ex_cache.fetch_valid, cpu.icache_areq_ex_cache.fetch_paddr,
               cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.dreq_ready_o,
               cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.mem_data_req_o,
               cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.mem_data_ack_i,
               cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.en_i,
               cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.cache_en_q);
      $fatal(1, "CPU_PAUSE_FAIL timeout cycles=%0d writes=%0d reads=%0d",
             cycles, write_checks, read_checks);
    end
    // ---- committed-store reference update from formatted RVFI (o2 source) --
    // RVFI store encoding (verified against be_gen/load_store_unit/store_unit):
    //   mem_addr  = exact store vaddr (lsu_ctrl_i.vaddr)
    //   mem_wmask = lsu_ctrl_i.be = be_gen(vaddr[2:0],size): BUS-LANE byte-enable
    //               over the 8B word (e.g. sh@+2 -> 8'h0c), popcount = nbytes
    //   mem_wdata = wbdata[STORE_WB] = store_unit.result_o = raw rs2 operand,
    //               store value in the LOW nbytes (little-endian), NOT bus-aligned
    // => the committed store writes mem_wdata[8*i +: 8] to mem_addr+i for
    //    i in [0,nbytes).  (AMO wdata = compute_amo_wdata result, same rule.)
    for (int k = 0; k < Cfg.NrCommitPorts; k++) begin
      if (|rvfi_instr[k].valid &&
          (|rvfi_instr[k].mem_wmask) &&
          is_data(rvfi_instr[k].mem_addr)) begin
        int boff, nbytes;
        boff = int'(rvfi_instr[k].mem_addr - Data);
        nbytes = $countones(rvfi_instr[k].mem_wmask[Cfg.XLEN/8-1:0]);
        if (rvfi_dump_count < 48) begin
          rvfi_dump_count <= rvfi_dump_count + 1;
          $display("[RVFI] a=%h wm=%h wd=%h n=%0d", rvfi_instr[k].mem_addr,
                   rvfi_instr[k].mem_wmask, rvfi_instr[k].mem_wdata, nbytes);
        end
        for (int i = 0; i < nbytes; i++)
          if ((boff + i) < DataBytes)
            ref_mem[boff + i] = rvfi_instr[k].mem_wdata[8*i +: 8];
      end
    end
    // ---- write address channel ----
    if (dn_req.aw_valid && dn_resp.aw_ready) begin
      write_owned <= 1;
      write_header <= dn_req.aw;
      if (trace) $display("[AW] t=%0d a=%h atop=%h lk=%0d sz=%0d", cycles,
          dn_req.aw.addr, dn_req.aw.atop, dn_req.aw.lock, dn_req.aw.size);
      if ((dn_req.aw.atop != '0) || dn_req.aw.lock) begin
        write_atomic <= dn_req.aw.atop != '0 ? 2'b01 : 2'b10;
      end else begin
        write_atomic <= 2'b00;
      end
    end
    // ---- write data channel ----
    if (dn_req.w_valid && dn_resp.w_ready) begin
      write_owned <= 0;
      b_valid <= 1;
      b_id <= write_header.id;
      b_resp <= axi_pkg::RESP_OKAY;
      if (trace) $display("[W ] t=%0d a=%h d=%h wat=%0d", cycles,
          write_header.addr, dn_req.w.data, write_atomic);
      if (write_header.addr == Data + TrapOff) begin
        // trap stub stored mepc at Data+0x7F0 just before the 0x7f marker
        $display("CPU_PAUSE_TRAP mepc=%h", data_aligned(Data + 19'h7F0));
        $fatal(1, "CPU_PAUSE_FAIL trap addr=%h", write_header.addr);
      end
      if (is_data(write_header.addr)) begin
        if (write_atomic == 2'b01) begin
          int nbytes, lane, off;
          logic [63:0] old_word, old_v, operand, new_v;
          nbytes = 1 << write_header.size;
          lane = int'(write_header.addr[2:0]);
          off = int'(write_header.addr - Data);
          old_word = 64'(data_aligned(write_header.addr));
          old_v = beat_bytes(old_word, lane, nbytes);
          operand = beat_bytes(dn_req.w.data, lane, nbytes);
          new_v = atop_compute(write_header.atop, old_v, operand, nbytes);
          for (int i = 0; i < nbytes; i++)
            data_mem[off + i] = new_v[8*i +: 8];
          // AMO/SC retire-latency: the RMW bus write lands in data_mem before
          // the instruction commits (atomic_r round-trip + halt blocks retire),
          // so RVFI ref_mem would lag for the whole pause -> false o2 dirty.
          // The write is irrevocable once issued; mirror the same result into
          // ref_mem now. RVFI later rewrites the identical compute_amo_wdata.
          for (int i = 0; i < nbytes; i++)
            if ((off + i) < DataBytes)
              ref_mem[off + i] = new_v[8*i +: 8];
          atomic_r_valid <= 1;
          atomic_r_id <= write_header.id;
          atomic_r_data <= old_word[Cfg.AxiDataWidth-1:0];
          atomic_r_resp <= axi_pkg::RESP_OKAY;
          atomic_r_delay <= delay_cycles;
        end else if (write_atomic == 2'b10) begin
          int nbytes, lane, off;
          nbytes = 1 << write_header.size;
          lane = int'(write_header.addr[2:0]);
          off = int'(write_header.addr - Data);
          if (reserved_valid && reserved_addr == write_header.addr) begin
            for (int i = 0; i < nbytes; i++)
              data_mem[off + i] = dn_req.w.data[8*(lane+i) +: 8];
            // Successful SC: same retire-latency skew as AMO — mirror the
            // irrevocable write into ref_mem (RVFI rewrites it identically).
            for (int i = 0; i < nbytes; i++)
              if ((off + i) < DataBytes)
                ref_mem[off + i] = dn_req.w.data[8*(lane+i) +: 8];
            b_resp <= axi_pkg::RESP_EXOKAY;
            reserved_valid <= 0;
          end else begin
            b_resp <= axi_pkg::RESP_OKAY;
          end
        end else begin
          int nbytes, lane, off;
          nbytes = 1 << write_header.size;
          lane = int'(write_header.addr[2:0]);
          off = int'(write_header.addr - Data);
          for (int i = 0; i < nbytes; i++)
            data_mem[off + i] = dn_req.w.data[8*(lane+i) +: 8];
          write_checks <= write_checks + 1;
          if (write_header.addr == Data + DoneOff) begin
            if (dn_req.w.data[63:0] != 64'h5a)
              $fatal(1, "CPU_PAUSE_FAIL bad-done data=%h", dn_req.w.data);
            // Defer the o4/signature check one cycle: the DONE store's
            // data_mem write above is nonblocking, so compare after it lands.
            finish_pending <= 1'b1;
          end
        end
      end else if (is_boot(write_header.addr) && write_atomic == 2'b00) begin
        // C5: cacheable Boot-region store -> rom[] backing (CPU-writable RAM).
        int nbytes, lane, boff, bidx, bin;
        nbytes = 1 << write_header.size;
        lane = int'(write_header.addr[2:0]);
        for (int i = 0; i < nbytes; i++) begin
          boff = int'(write_header.addr - Boot) + i;
          bidx = boff >> 2;
          bin  = boff & 3;
          if (bidx >= 0 && bidx < 1024)
            rom[bidx][8*bin +: 8] = dn_req.w.data[8*(lane+i) +: 8];
        end
        write_checks <= write_checks + 1;
      end
    end
    if (b_valid && dn_req.b_ready) begin
      if (trace) $display("[B ] t=%0d id=%h resp=%h", cycles, b_id, b_resp);
      b_valid <= 0;
    end
    // ---- read address channel ----
    if (dn_req.ar_valid && dn_resp.ar_ready) begin
      read_header <= dn_req.ar;
      read_owned <= 1;
      read_beat <= 0;
      read_delay <= delay_cycles;
      if (trace) $display("[AR] t=%0d a=%h lk=%0d sz=%0d", cycles,
          dn_req.ar.addr, dn_req.ar.lock, dn_req.ar.size);
      if (dn_req.ar.lock) begin
        reserved_valid <= 1;
        reserved_addr <= dn_req.ar.addr;
      end else if (is_data(dn_req.ar.addr)) begin
        read_checks <= read_checks + 1;
      end
    end
    if (read_delay > 0) read_delay <= read_delay - 1;
    if (atomic_r_delay > 0) atomic_r_delay <= atomic_r_delay - 1;
    if (atomic_r_valid && dn_resp.r_valid && dn_req.r_ready) begin
      if (trace) $display("[Ra] t=%0d id=%h d=%h", cycles, atomic_r_id, atomic_r_data);
      atomic_r_valid <= 0;
    end
    if (dn_resp.r_valid && dn_req.r_ready && !atomic_r_valid) begin
      if (trace) $display("[R ] t=%0d id=%h d=%h", cycles, read_header.id, dn_resp.r.data);
      if (dn_resp.r.last) read_owned <= 0;
      else begin read_beat <= read_beat + 1; read_delay <= delay_cycles; end
    end
  end

  // ---- (o2) committed-store equality: full compare, called at pause entry --
  function automatic bit ref_eq();
    for (int i = 0; i < DataBytes; i++)
      if (data_mem[i] !== ref_mem[i]) return 1'b0;
    return 1'b1;
  endfunction
  function automatic logic [63:0] mem_sig();
    logic [63:0] s;
    s = 64'h9e3779b97f4a7c15;
    for (int i = 0; i < DataBytes; i++) begin
      // C5 observation log [ProbeOff, ScOff+8): packed gen/salt probes, the
      // LR/SC arm/go/reserved/result fields. These legitimately differ between
      // the never-paused reference (no replaces -> constant gen) and paused
      // runs (gen/salt advance per replace), so they are excluded from the
      // cross-run signature; their correctness is covered by o5/o6 instead.
      if (i >= ProbeOff && i < ScOff + 8) continue;
      s = (s ^ {56'h0, data_mem[i]}) * 64'h100000001b3;
    end
    return s;
  endfunction
  // 256-byte block hash over the same exclusion as mem_sig: bisects which
  // region a cross-run signature mismatch lives in (cpu-pause C5 debug).
  function automatic logic [63:0] sig_block(input int base);
    logic [63:0] s;
    s = 64'h9e3779b97f4a7c15;
    for (int i = base; i < base + 256; i++)
      if (!(i >= ProbeOff && i < ScOff + 8))
        s = (s ^ {56'h0, data_mem[i]}) * 64'h100000001b3;
    return s;
  endfunction
  // find first data/ref mismatch byte offset (for the dirty report)
  function automatic int first_diff();
    for (int i = 0; i < DataBytes; i++)
      if (data_mem[i] !== ref_mem[i]) return i;
    return -1;
  endfunction

  // ================= pause request generator =================
  logic [31:0] lfsr_q;
  int gen_state = 0;          // 0 idle-gap, 1 req-high-await-paused, 2 paused-hold
  int gap_cnt = 0, gap_target = 0;
  int hold_cnt = 0, hold_target = 0;
  int req_wait = 0, req_at_cycle = 0;
  int pauses_done = 0, max_drain = 0;
  int seed_val = 1;
  bit gen_en = 1;
  bit withdraw_pending = 0;
  int withdraw_at = 0;
  bit o2_checked = 0;
  logic finish_pending = 0;
  always @(posedge clk) if (rst_n) begin
    // ---- deferred (o4) final check, one cycle after the DONE store lands --
    if (finish_pending) begin
      finish_pending <= 1'b0;
      if (!ref_eq()) begin
        int fd;
        fd = first_diff();
        $display("CPU_PAUSE_FAIL dirty addr=%h off=%0d cycles=%0d",
                 Data + fd, fd, cycles);
        $fatal(1, "CPU_PAUSE_FAIL o4-final-mismatch off=%0d", fd);
      end
      // C5: cacheable CPU-writable scratch must have reached rom[] (D$ drain).
      // (+directed: the directed load_unit program has no C5 phases.)
      if (!directed && rom[ScratchIdx] !== 32'h0000005C)
        $fatal(1, "CPU_PAUSE_FAIL cacheable-scratch rom=%h", rom[ScratchIdx]);
      // cross-run signature bisection: 8 x 256B block hashes + C5 field dump
      for (int b = 0; b < 8; b++)
        $display("SIGBLK %0d %h", b, sig_block(b * 256));
      // word-level dump of the differing work_sub block (0x300..0x3ff) so the
      // exact slots/values can be compared across runs.
      for (int i = 12'h300; i < 12'h400; i = i + 8)
        $display("W3 %h %h", i, data_aligned(Data + i));
      $display("C5FLD hb=%h probe=%h sc=%h done=%h trap=%h",
               data_aligned(Data + HBOff), data_aligned(Data + ProbeOff),
               data_aligned(Data + ScOff), data_aligned(Data + DoneOff),
               data_aligned(Data + TrapOff));
      if (!gen_en) begin
        $display("CPU_PAUSE_REF sig=%h cycles=%0d", mem_sig(), cycles);
      end else begin
        $display("CPU_PAUSE_PASS pauses=%0d max_drain_cycles=%0d seed=%0d delay=%0d sig=%h wstall=%0d rstall=%0d replaces=%0d repause=%0d code_chk=%0d data_chk=%0d",
                 pauses_done, max_drain, seed_val, delay_cycles, mem_sig(),
                 wstall_max, rstall_max, replace_count, repause_mod, code_chk, data_chk);
      end
      $finish;
    end
    // xorshift32
    lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
    case (gen_state)
      0: begin // idle: count gap then request
        gap_cnt <= gap_cnt + 1;
        if (gen_en && gap_cnt >= gap_target) begin
          pause_req <= 1'b1;
          gen_state <= 1;
          req_wait <= 0;
          req_at_cycle <= cycles;
          // ~1/8 of requests are withdrawn before Paused
          withdraw_pending <= (lfsr_q[2:0] == 3'b000);
          withdraw_at <= 1 + int'(lfsr_q[7:4]);
          gap_cnt <= 0;
        end
      end
      1: begin // pause_req high, awaiting paused_o (or withdraw)
        req_wait <= req_wait + 1;
        if (paused_o) begin
          int d;
          d = cycles - req_at_cycle;
          if (d > max_drain) max_drain <= d;
          pauses_done <= pauses_done + 1;
          gen_state <= 2;
          hold_cnt <= 0;
          hold_target <= 1 + int'(lfsr_q[15:8] % 200);
          o2_checked <= 0;
        end else if (withdraw_pending && req_wait >= withdraw_at) begin
          pause_req <= 1'b0;         // withdrawn before Paused
          gen_state <= 0;
          gap_cnt <= 0;
          gap_target <= RUN_GAP_MIN + int'(lfsr_q[20:12] % 60);
        end else if (req_wait > WatchdogBound) begin
          $display("CPU_PAUSE_FAIL stuck drained=%b closed=%b inflight=%b paused=%b error=%b",
                   core_drained, gate_closed, gate_inflight, paused_o, error_o);
          $fatal(1, "CPU_PAUSE_FAIL stuck cycles=%0d", cycles);
        end
      end
      2: begin // paused_o high: hold then release
        if (paused_o) begin
          hold_cnt <= hold_cnt + 1;
          // (o2) one committed-store compare per pause, a couple cycles in
          if (!o2_checked && hold_cnt >= 2) begin
            o2_checked <= 1;
            if (!ref_eq()) begin
              int fd;
              fd = first_diff();
              $display("CPU_PAUSE_FAIL dirty addr=%h off=%0d cycles=%0d dat=%02x ref=%02x ctx_d=%02x%02x%02x%02x ctx_r=%02x%02x%02x%02x",
                       Data + fd, fd, cycles, data_mem[fd], ref_mem[fd],
                       data_mem[fd+3], data_mem[fd+2], data_mem[fd+1], data_mem[fd],
                       ref_mem[fd+3], ref_mem[fd+2], ref_mem[fd+1], ref_mem[fd]);
              $display("[DRN] drained=%b closed=%b inflight=%b paused=%b err=%b noreq=%b",
                       core_drained, gate_closed, gate_inflight, paused_o, error_o,
                       !(dn_req.aw_valid || dn_req.ar_valid || dn_req.w_valid));
              $fatal(1, "CPU_PAUSE_FAIL dirty off=%0d", fd);
            end
          end
        end
        if (hold_cnt >= hold_target) begin
          pause_req <= 1'b0;         // release -> sequencer unwinds
          gen_state <= 0;
          gap_cnt <= 0;
          // +repause=N: every Nth release re-requests after 1..3 idle cycles so
          // pause_req rises while the core is still inside resync (re-pause
          // during resync must keep commit halted and still complete).
          if (repause_mod > 0 && (pauses_done % repause_mod) == 0)
            gap_target <= 1 + int'(lfsr_q[7:6] % 3);
          // back-to-back: sometimes a tiny gap (re-pause lands inside resync,
          // commit still halted -- drain/arrival stress, not a run window)
          else gap_target <= (lfsr_q[3:0] == 4'h5) ? (1 + int'(lfsr_q[9:6]))
                                                 : (RUN_GAP_MIN + int'(lfsr_q[20:12] % 60));
        end
      end
      default: gen_state <= 0;
    endcase
  end

  // ================= C5 resync-on-release replace + oracles ================
  // While paused_o holds, the bench rewrites the cacheable data word and the
  // patchable hot-loop instruction in rom[] (the "RAM replacement" the resync
  // exists for), plus -- once the program has armed -- the LR/SC reserved word
  // in data_mem with a bus-side reservation clear and a go flag. After release
  // the resync must have flushed D$/I$ and squashed+refetched, so the program's
  // post-release observations equal the NEW contents.
  //
  // o5 is exact and retire-based (see o5 block). o6 requires the SC to fail
  // (bus-side reservation cleared).
  int replace_count = 0;
  int code_chk = 0, data_chk = 0;
  logic [31:0] exp_gen = 32'h5EED0000, exp_salt = 32'h0;
  logic [31:0] rep_imm_v = 32'h0, rep_word_v = 32'h0;
  logic in_pause_q = 1'b0, arm_seen = 1'b0, rsv_done = 1'b0;
  logic post_rel_q = 1'b0, was_paused_q = 1'b0;
  logic sc_done_seen = 1'b0;
  bit go_nopause = 0;
  int repause_mod = 0;

  // bench-initiated Data-window write: mirror into ref_mem so o2 (committed-
  // store equality) stays consistent -- the replace is an external memory
  // change, not a lost CPU store.
  task automatic bench_wr32(input int off, input logic [31:0] val);
    for (int i = 0; i < 4; i++) begin
      data_mem[off + i] <= val[8*i +: 8];
      ref_mem[off  + i] <= val[8*i +: 8];
    end
  endtask

  always @(posedge clk) if (rst_n) begin
    // arm detect: program committed ArmOff!=0 (lr done, spinning on go)
    if (data_mem[ArmOff] != 8'h00) arm_seen <= 1'b1;
    // +nopause reference: no pause ever runs the replace block that raises
    // GO_OFF, so raise it once armed to let the program's sc.w complete. The
    // reserved word is NOT replaced and the reservation is NOT cleared, so sc
    // succeeds -- o6 (sc-must-fail) is gated off under nopause below.
    if (!gen_en && arm_seen && !go_nopause) begin
      go_nopause <= 1'b1;
      bench_wr32(GoOff, 32'h00000001);
    end
    // post-release observation window (release -> next paused_o)
    if (paused_o) begin post_rel_q <= 1'b0; was_paused_q <= 1'b1; end
    else if (was_paused_q) begin post_rel_q <= 1'b1; was_paused_q <= 1'b0; end
    // replace on each new pause hold
    if (paused_o && !in_pause_q) begin
      in_pause_q <= 1'b1;
      replace_count <= replace_count + 1;
      rom[CDataIdx] <= 32'h5EED0000 + 32'(replace_count);
      exp_gen     <= 32'h5EED0000 + 32'(replace_count);
      // patchable addi x26,x0,imm : imm = 0x40 + (count % 0x700), stays <0x800
      // so the addi result (and the packed salt field) is a clean positive.
      rep_imm_v  = (32'h040 + 32'(replace_count % 32'h700)) & 32'hFFF;
      rep_word_v = (rep_imm_v << 20) | (26 << 7) | 32'h13;
      rom[PatchIdx] <= rep_word_v;
      exp_salt <= rep_imm_v;
      if (ostale)
        $display("[OST] t=%0d REPLACE cnt=%0d patch %h->%h salt %h->%h gen=%h",
                 cycles, replace_count, rom[PatchIdx], rep_word_v,
                 32'(rom[PatchIdx] >> 20) & 32'hFFF, rep_imm_v, exp_gen);
      if (arm_seen && !rsv_done) begin
        rsv_done <= 1'b1;
        bench_wr32(RsvOff, 32'h00000077);   // replace reserved word
        reserved_valid <= 1'b0;             // clear bus-side reservation (h3)
        bench_wr32(GoOff, 32'h00000001);     // raise go -> program runs sc
      end
    end else if (!paused_o) in_pause_q <= 1'b0;
    // ---- o5: exact, retire-based staleness check (zero tolerance) ----
    // The bench only replaces rom[] while paused_o, when nothing retires, so
    // every retire of the patched addi must produce the CURRENT immediate and
    // every retire of a load from the cacheable data word must return the
    // CURRENT word. An instruction that retired before the pause legitimately
    // carries the old value and is simply checked against the old contents.
    for (int k = 0; k < Cfg.NrCommitPorts; k++) begin
      if (!directed && |rvfi_instr[k].valid && !rvfi_instr[k].trap) begin
        if (rvfi_instr[k].pc_rdata == 64'(Boot + 4*PatchIdx)) begin
          if (replace_count != 0) code_chk <= code_chk + 1;
          if (rvfi_instr[k].rd_wdata != 64'(rom[PatchIdx] >> 20))
            $fatal(1, "CPU_PAUSE_FAIL stale kind=code got=%h exp=%h cyc=%0d",
                   rvfi_instr[k].rd_wdata, 64'(rom[PatchIdx] >> 20), cycles);
        end
        if ((|rvfi_instr[k].mem_rmask) && !(|rvfi_instr[k].mem_wmask) &&
            rvfi_instr[k].mem_addr == 64'(Boot + 4*CDataIdx)) begin
          if (replace_count != 0) data_chk <= data_chk + 1;
          if (rvfi_instr[k].rd_wdata != 64'(rom[CDataIdx]))
            $fatal(1, "CPU_PAUSE_FAIL stale kind=data got=%h exp=%h cyc=%0d",
                   rvfi_instr[k].rd_wdata, 64'(rom[CDataIdx]), cycles);
        end
      end
    end
    // ---- o6: packed {sc_result,0x5C} at ScOff; sc must have FAILED ----
    begin : o6chk
      logic [63:0] scv;
      scv = data_aligned(Data + ScOff);
      if (gen_en && !sc_done_seen && scv[31:0] == 32'h0000005C) begin
        sc_done_seen <= 1'b1;
        if (scv[63:32] == 32'h00000000)
          $fatal(1, "CPU_PAUSE_FAIL lrsc reservation-not-cleared cyc=%0d", cycles);
      end
    end
  end

  // +ostale: fine-grained C5 stale-code trace — pause/gate/resync edges and
  // every retire of the patched addi (0x800004B0). commit_instr_result is the
  // addi's rd write-data == the salt, so it reveals old-vs-new code directly.
  logic ost_p, ost_g, ost_sq;
  always @(posedge clk) if (rst_n && ostale) begin
    if (paused_o !== ost_p)
      $display("[OST] t=%0d paused_o %b->%b", cycles, ost_p, paused_o);
    if (gate_closed !== ost_g)
      $display("[OST] t=%0d gate_closed %b->%b", cycles, ost_g, gate_closed);
    if (cpu.resync_squash !== ost_sq)
      $display("[OST] t=%0d resync_squash %b->%b state=%0d halt=%b",
               cycles, ost_sq, cpu.resync_squash,
               int'(cpu.storamic_resync_state_q), cpu.storamic_halt);
    if (rvfi_probes.instr.commit_instr_valid[0] && rvfi_probes.instr.commit_ack[0] &&
        rvfi_probes.instr.commit_instr_pc[0] == 64'h800004B0)
      $display("[OST] t=%0d RETIRE pc=%h salt=%h", cycles,
               rvfi_probes.instr.commit_instr_pc[0],
               rvfi_probes.instr.commit_instr_result[0]);
    ost_p <= paused_o; ost_g <= gate_closed; ost_sq <= cpu.resync_squash;
  end

  initial begin
    trace = $test$plusargs("trace");
    ostale = $test$plusargs("ostale");
    directed = $test$plusargs("directed");
    gen_en = !$test$plusargs("nopause");
    if (!$value$plusargs("rom=%s", rom_path)) $fatal(1, "CPU_PAUSE_ROM_REQUIRED");
    if (!$value$plusargs("delay=%d", delay_cycles)) delay_cycles = 0;
    if (!$value$plusargs("seed=%d", seed_val)) seed_val = 1;
    ptrace = $test$plusargs("ptrace");
    if (!$value$plusargs("ptrace_lo=%d", ptrace_lo)) ptrace_lo = 0;
    if (!$value$plusargs("ptrace_hi=%d", ptrace_hi)) ptrace_hi = ptrace_lo;
    if (!$value$plusargs("wstall=%d", wstall_max)) wstall_max = 0;
    if (!$value$plusargs("rstall=%d", rstall_max)) rstall_max = 0;
    if (!$value$plusargs("repause=%d", repause_mod)) repause_mod = 0;
    if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 400000;
    if (max_cycles < 1) max_cycles = 400000;
    if (wstall_max < 0) wstall_max = 0;
    if (rstall_max < 0) rstall_max = 0;
    wstall_lfsr = 32'h9e3779b9 ^ (seed_val * 32'h85ebca6b);
    rstall_lfsr = 32'h85ebca6b ^ (seed_val * 32'h27d4eb2f);
    if (seed_val == 0) seed_val = 1;
    lfsr_q = 32'h9e3779b9 ^ (seed_val * 32'h85ebca6b);
    gap_target = RUN_GAP_MIN + int'(lfsr_q[15:8] % 40);
    foreach (rom[i]) rom[i] = 32'h0000_0013;
    foreach (data_mem[i]) data_mem[i] = 8'h00;
    foreach (ref_mem[i])  ref_mem[i]  = 8'h00;
    $readmemh(rom_path, rom);
    repeat (8) @(negedge clk);
    rst_n = 1;
    if (gen_en == 0) begin
      // never-paused reference run: same program, no pause requests
      // (still prints a signature the runner compares against paused runs)
    end
  end
  // reference run completion is handled by the same DONE-store path; for a
  // nopause run we still reach Data+DoneOff and print the signature via PASS
  // with pauses=0 -- the runner treats pauses<40 as the reference signature.
endmodule
