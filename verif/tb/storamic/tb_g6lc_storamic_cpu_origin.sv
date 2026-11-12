// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`include "axi/typedef.svh"
module tb_g6lc_storamic_cpu_origin;
  parameter bit OriginEnabled = 1;
  parameter bit IntegerDiagnostic = 0;
  // cpu-origin-unsupported variant: keep the Storamic origin flags on but
  // force RVH=1 so g6lc_storamic_origin_supported() is false and every data
  // access must carry prot==000. Default off; cpu-origin is unaffected.
  parameter bit UnsupportedProfile = 0;
  // cpu-origin-atomic variant: run the AMO/LR/SC program. The core emits AXI4
  // ATOP read-modify-write writes (atop!=0, old value returns on R) and AXI
  // exclusive transactions for LR (AR.lock) / SC (AW.lock, B.exokay). This
  // bench is the AXI slave: it performs the ATOP RMW and models the exclusive
  // monitor. Default off; cpu-origin is unaffected.
  parameter bit AtomicProfile = 0;
  localparam logic [63:0] Boot = 64'h8000_0000, Probe = 64'h5000_0000;
  localparam int ProbeBytes = AtomicProfile ? 256 : 64;
  localparam int AtomicDoneOff = 120;   // Probe+120 completion store (atomic)
  localparam int AtomicTrapOff = 36;    // Probe+36 trap store (shared)
  // Expected atomic-profile counts: per privilege 5 ordinary writes,
  // 5 ordinary reads, 3 atomic writes (amoswap,amoadd,sc), 1 atomic read (lr);
  // M+U plus the U completion store.
  localparam int AtomicOrdWrites = 11, AtomicOrdReads = 8;
  localparam int AtomicWr = 6, AtomicRd = 1 + 1;
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_user_cfg_t u = cva6_config_pkg::cva6_cfg;
    config_pkg::cva6_cfg_t c;
    if (IntegerDiagnostic) begin u.RVF = 0; u.RVD = 0; end
    if (UnsupportedProfile) u.RVH = 1;
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
  logic [1:0] b_resp = axi_pkg::RESP_OKAY;
  int read_delay = 0, delay_cycles = 0, cycles = 0;
  int write_checks = 0, read_checks = 0;
  int atomic_writes = 0, atomic_reads = 0;
  logic [31:0] rom [0:1023];
  // Byte-addressable Probe storage: supports 1/2/4/8-byte ordinary accesses and
  // the AMO/LR/SC widths (.w=4, .d=8) uniformly.
  logic [7:0] probe_mem [0:255];
  bit negative;
  bit expect_supported;
  bit expect_atomic_origin;
  bit trace;
  string rom_path;
  // atomic write classification captured at AW accept, consumed at W accept
  logic [1:0] write_atomic = 2'b00;   // 00 ordinary, 01 ATOP RMW, 10 SC exclusive
  // atomic old-value return channel (AMO RMW): returns on R with the AW id
  logic atomic_r_valid = 0;
  logic [1:0] atomic_r_resp = axi_pkg::RESP_OKAY;
  id_t atomic_r_id;
  data_t atomic_r_data;
  int atomic_r_delay = 0;
  // exclusive monitor: reservation set by LR (AR.lock), checked by SC (AW.lock)
  logic reserved_valid = 0;
  logic [63:0] reserved_addr = '0;
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
    .coh_sf_filtered_i(1'b0), .coh_sf_broadcast_i(1'b0),
    .storamic_pause_i(1'b0), .storamic_drained_o()
  );

  function automatic bit is_probe(input logic [63:0] a);
    return a >= Probe && a < Probe + ProbeBytes;
  endfunction
  function automatic bit is_atomic_write(input cpu_aw_chan_t aw);
    return (aw.atop != '0) || aw.lock;
  endfunction
  function automatic logic [2:0] expected_prot(input logic [63:0] a);
    logic [2:0] result;
    if (AtomicProfile) begin
      // Ordinary (non-atomic) accesses keep the firmware origin: M section
      // slots live below Probe+64, U section slots at/above it.
      result = ((a - Probe) < 64) ? 3'b001 : 3'b010;
      if (!OriginEnabled) result = 3'b000;
    end else if (UnsupportedProfile && !expect_supported) begin
      // Unsupported origin profile: the core must emit prot==000 on every
      // data request regardless of privilege.
      result = 3'b000;
    end else begin
      case (a - Probe)
        0: result = 3'b001;      // M
        8, 24: result = 3'b011;  // S and M executing with MPRV/MPP=S
        16, 32: result = 3'b010; // U, including completion
        default: result = 3'b000;
      endcase
      if (!OriginEnabled) result = 3'b000;
      if (negative && a == Probe) result[0] = ~result[0];
    end
    return result;
  endfunction
  // Expected prot for an atomic-generated AW/AR. Normally the core emits 000
  // (atomics carry no firmware origin). +expect_atomic_origin instead demands
  // the firmware origin so the oracle rejects the mis-tagged build.
  function automatic logic [2:0] expected_atomic_prot(input logic [63:0] a);
    logic [2:0] result;
    if (expect_atomic_origin && OriginEnabled)
      result = ((a - Probe) < 64) ? 3'b001 : 3'b010;
    else
      result = 3'b000;
    return result;
  endfunction
  // Read the 64-bit aligned bus word containing address a from Probe storage.
  function automatic data_t probe_aligned(input logic [63:0] a);
    int woff;
    data_t w;
    woff = int'(a - Probe) & ~7;
    w = '0;
    for (int i = 0; i < 8; i++) w[8*i +: 8] = probe_mem[woff + i];
    return w;
  endfunction
  // Extract nbytes (1,2,4,8) starting at byte lane within a 64-bit data beat.
  function automatic logic [63:0] nbytes_mask(input int nbytes);
    return (nbytes >= 8) ? 64'hffff_ffff_ffff_ffff
                        : ((64'(1) << (8 * nbytes)) - 1);
  endfunction
  function automatic logic [63:0] beat_bytes(input data_t d, input int lane,
                                            input int nbytes);
    return (64'(d) >> (8 * lane)) & nbytes_mask(nbytes);
  endfunction
  // AXI4 ATOP read-modify-write: return the new nbytes value for old OP operand.
  function automatic logic [63:0] atop_compute(input logic [5:0] atop,
      input logic [63:0] old_v, input logic [63:0] operand, input int nbytes);
    logic [63:0] mask, result;
    logic signed [63:0] so, sn;
    mask = nbytes_mask(nbytes);
    old_v &= mask; operand &= mask;
    if (atop == axi_pkg::ATOP_ATOMICSWAP) begin
      result = operand;
    end else if (atop[5:4] == 2'b10) begin
      unique case (atop[2:0])
        3'b000: result = (old_v + operand) & mask;              // ADD
        3'b001: result = old_v & ~operand & mask;               // CLR
        3'b010: result = (old_v ^ operand) & mask;              // EOR
        3'b011: result = (old_v | operand) & mask;              // SET
        default: begin
          // signed/unsigned min/max on the nbytes-wide value
          so = (nbytes == 8) ? $signed(old_v) : $signed({{(64-32){old_v[31]}}, old_v[31:0]});
          sn = (nbytes == 8) ? $signed(operand) : $signed({{(64-32){operand[31]}}, operand[31:0]});
          unique case (atop[2:0])
            3'b100: result = (so > sn) ? old_v : operand;       // SMAX
            3'b101: result = (so < sn) ? old_v : operand;       // SMIN
            3'b110: result = (old_v > operand) ? old_v : operand; // UMAX
            3'b111: result = (old_v < operand) ? old_v : operand; // UMIN
            default: result = 'x;
          endcase
        end
      endcase
    end else begin
      result = 'x;  // ATOMICSTORE/ATOMICCMP/unknown: not produced by this core
    end
    return result & mask;
  endfunction
  function automatic data_t read_data(input logic [63:0] a);
    int index;
    if (is_probe(a)) begin
      return probe_aligned(a);
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
    resp.b.resp = b_resp;
    resp.ar_ready = !read_owned;
    // atomic old-value return (AMO RMW) has priority: the core drains all other
    // traffic before an atomic, so no ordinary read can be in flight.
    if (atomic_r_valid) begin
      resp.r_valid = atomic_r_delay == 0;
      resp.r.id = atomic_r_id;
      resp.r.resp = atomic_r_resp;
      resp.r.data = atomic_r_data;
      resp.r.last = 1'b1;
    end else begin
      resp.r_valid = read_owned && read_delay == 0;
      resp.r.id = read_header.id;
      resp.r.last = read_beat == read_header.len;
      resp.r.data = read_data(read_header.addr +
          (64'(read_beat) << read_header.size));
    end
  end
  always @(posedge clk) if (rst_n) begin
    cycles <= cycles + 1;
    if (cycles > 200000) begin
      // Stall anatomy (sim-only hierarchical probes): which backend structure is
      // still occupied when commit stops retiring. Mirrors the +smt_stats dump.
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
      $display("[CMT] cmt_pc=%h cmt_val=%0d cmt_fu=%0d cmt_op=%0d cmt_ack=%0d | sbhd=%0d | npc=%h",
               cpu.commit_instr_id_commit[0].pc,
               cpu.commit_instr_id_commit[0].valid,
               int'(cpu.commit_instr_id_commit[0].fu),
               int'(cpu.commit_instr_id_commit[0].op),
               cpu.commit_ack[0],
               cpu.sb_head_valid[0],
               cpu.smt_npc_live);
      $fatal(1, "CPU_ORIGIN_FAIL timeout w=%0d r=%0d aw=%0d ar=%0d decpc=%h retpc=%h | wo=%0d ro=%0d bv=%0d arv=%0d arvr=%0d rvd=%0d ard=%0d res=%0d wot=%0d",
                              write_checks, read_checks, atomic_writes, atomic_reads,
                              cpu.id_stage_i.decoded_instruction[0].pc,
                              cpu.smt_retire_pc[0],
                              write_owned, read_owned, b_valid, req.ar_valid,
                              resp.ar_ready, resp.r_valid, read_delay, reserved_valid,
                              write_atomic);
    end
    // ---- write address channel ----
    if (req.aw_valid && resp.aw_ready) begin
      write_owned <= 1;
      write_header <= req.aw;
      if (trace) $display("[AW] t=%0d a=%h p=%h atop=%h lk=%0d sz=%0d ln=%0d id=%h at=%0d",
          cycles, req.aw.addr, req.aw.prot, req.aw.atop, req.aw.lock,
          req.aw.size, req.aw.len, req.aw.id, is_atomic_write(req.aw));
      if (is_atomic_write(req.aw)) begin
        // Atomic-generated write: AMO RMW (atop) or SC exclusive store (lock).
        assert(req.aw.prot == expected_atomic_prot(req.aw.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL atomic-aw-prot addr=%h atop=%h lock=%0d got=%h expected=%h",
                 req.aw.addr, req.aw.atop, req.aw.lock, req.aw.prot,
                 expected_atomic_prot(req.aw.addr));
        assert(req.aw.len == 0 && req.aw.size <= 3) else
          $fatal(1, "CPU_ORIGIN_FAIL atomic-aw-shape addr=%h len=%0d size=%0d",
                 req.aw.addr, req.aw.len, req.aw.size);
        assert(is_probe(req.aw.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL atomic-aw-range addr=%h", req.aw.addr);
        atomic_writes <= atomic_writes + 1;
        write_atomic <= req.aw.atop != '0 ? 2'b01 : 2'b10;
      end else if (is_probe(req.aw.addr) && req.aw.addr != Probe + AtomicTrapOff) begin
        assert(req.aw.prot == expected_prot(req.aw.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL aw-prot addr=%h got=%h expected=%h",
                 req.aw.addr, req.aw.prot, expected_prot(req.aw.addr));
        assert(req.aw.len == 0 &&
               (AtomicProfile ? (req.aw.size == 2 || req.aw.size == 3)
                              : req.aw.size == 2) &&
               !req.aw.lock && req.aw.atop == 0 &&
               req.aw.cache == axi_pkg::CACHE_MODIFIABLE) else
          $fatal(1, "CPU_ORIGIN_FAIL probe-write-shape addr=%h len=%0d size=%0d lock=%0d atop=%h cache=%h",
                 req.aw.addr, req.aw.len, req.aw.size, req.aw.lock, req.aw.atop, req.aw.cache);
        write_checks <= write_checks + 1;
        write_atomic <= 2'b00;
      end else begin
        write_atomic <= 2'b00;
      end
    end
    // ---- write data channel ----
    if (req.w_valid && resp.w_ready) begin
      assert(req.w.last) else $fatal(1, "CPU_ORIGIN_FAIL write-burst");
      write_owned <= 0;
      b_valid <= 1;
      b_id <= write_header.id;
      b_resp <= axi_pkg::RESP_OKAY;
      if (trace) $display("[W ] t=%0d a=%h d=%h wat=%0d", cycles,
          write_header.addr, req.w.data, write_atomic);
      if (write_header.addr == Probe + AtomicTrapOff)
        $fatal(1, "CPU_ORIGIN_FAIL architectural-trap");
      if (is_probe(write_header.addr)) begin
        if (write_atomic == 2'b01) begin
          // ---- ATOP read-modify-write ----
          // nbytes = 2^aw.size; lane = byte offset of the access in the beat.
          int nbytes, lane, off;
          logic [63:0] old_word, old_v, operand, new_v;
          nbytes = 1 << write_header.size;
          lane = int'(write_header.addr[2:0]);
          off = int'(write_header.addr - Probe);
          old_word = 64'(probe_aligned(write_header.addr));
          old_v = beat_bytes(old_word, lane, nbytes);
          operand = beat_bytes(req.w.data, lane, nbytes);
          new_v = atop_compute(write_header.atop, old_v, operand, nbytes);
          assert(!($isunknown(new_v))) else
            $fatal(1, "CPU_ORIGIN_FAIL atomic-atop addr=%h atop=%h",
                   write_header.addr, write_header.atop);
          // commit the RMW result to Probe storage
          for (int i = 0; i < nbytes; i++)
            probe_mem[off + i] = new_v[8*i +: 8];
          // return the OLD aligned word on R with the atomic write id
          atomic_r_valid <= 1;
          atomic_r_id <= write_header.id;
          atomic_r_data <= old_word[Cfg.AxiDataWidth-1:0];
          atomic_r_resp <= axi_pkg::RESP_OKAY;
          atomic_r_delay <= delay_cycles;
        end else if (write_atomic == 2'b10) begin
          // ---- SC exclusive store ----
          int nbytes, lane, off;
          nbytes = 1 << write_header.size;
          lane = int'(write_header.addr[2:0]);
          off = int'(write_header.addr - Probe);
          if (reserved_valid && reserved_addr == write_header.addr) begin
            // reservation held: perform the store, report EXOKAY
            for (int i = 0; i < nbytes; i++)
              probe_mem[off + i] = req.w.data[8*(lane+i) +: 8];
            b_resp <= axi_pkg::RESP_EXOKAY;
            reserved_valid <= 0;
          end else begin
            // reservation lost: no store, report OKAY (exclusive failed)
            b_resp <= axi_pkg::RESP_OKAY;
          end
        end else begin
          // ---- ordinary store: byte-write the accessed lanes ----
          int nbytes, lane, off;
          nbytes = 1 << write_header.size;
          lane = int'(write_header.addr[2:0]);
          off = int'(write_header.addr - Probe);
          for (int i = 0; i < nbytes; i++)
            probe_mem[off + i] = req.w.data[8*(lane+i) +: 8];
          if (AtomicProfile) begin
            if (write_header.addr == Probe + AtomicDoneOff) begin
              assert(write_checks == AtomicOrdWrites &&
                     read_checks == AtomicOrdReads &&
                     atomic_writes == AtomicWr &&
                     atomic_reads == AtomicRd &&
                     req.w.data[63:0] == 64'h5a) else
                $fatal(1, "CPU_ORIGIN_FAIL incomplete-atomic ow=%0d or=%0d aw=%0d ar=%0d",
                       write_checks, read_checks, atomic_writes, atomic_reads);
              $display("CPU_ORIGIN_PASS enabled=%0d integer=%0d delay=%0d cycles=%0d writes=%0d reads=%0d awrites=%0d areads=%0d",
                       OriginEnabled, IntegerDiagnostic, delay_cycles, cycles,
                       write_checks, read_checks, atomic_writes, atomic_reads);
              $finish;
            end
          end else if (write_header.addr == Probe + 32) begin
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
    end
    if (b_valid && req.b_ready) begin
      if (trace) $display("[B ] t=%0d id=%h resp=%h", cycles, b_id, b_resp);
      b_valid <= 0;
    end
    // ---- read address channel ----
    if (req.ar_valid && resp.ar_ready) begin
      read_header <= req.ar;
      read_owned <= 1;
      read_beat <= 0;
      read_delay <= delay_cycles;
      if (trace) $display("[AR] t=%0d a=%h p=%h lk=%0d sz=%0d ln=%0d id=%h",
          cycles, req.ar.addr, req.ar.prot, req.ar.lock, req.ar.size,
          req.ar.len, req.ar.id);
      if (req.ar.lock) begin
        // LR exclusive read: record the reservation, expect prot==000.
        assert(req.ar.prot == expected_atomic_prot(req.ar.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL atomic-ar-prot addr=%h lock=%0d got=%h expected=%h",
                 req.ar.addr, req.ar.lock, req.ar.prot,
                 expected_atomic_prot(req.ar.addr));
        assert(req.ar.len == 0) else
          $fatal(1, "CPU_ORIGIN_FAIL atomic-ar-len addr=%h len=%0d",
                 req.ar.addr, req.ar.len);
        assert(is_probe(req.ar.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL atomic-ar-range addr=%h", req.ar.addr);
        reserved_valid <= 1;
        reserved_addr <= req.ar.addr;
        atomic_reads <= atomic_reads + 1;
      end else if (is_probe(req.ar.addr)) begin
        assert(req.ar.prot == expected_prot(req.ar.addr)) else
          $fatal(1, "CPU_ORIGIN_FAIL ar-prot");
        assert(req.ar.cache == axi_pkg::CACHE_MODIFIABLE && !req.ar.lock && req.ar.len == 0) else
          $fatal(1, "CPU_ORIGIN_FAIL probe-read-shape addr=%h len=%0d lock=%0d cache=%h",
                 req.ar.addr, req.ar.len, req.ar.lock, req.ar.cache);
        read_checks <= read_checks + 1;
      end
    end
    if (read_delay > 0) read_delay <= read_delay - 1;
    if (atomic_r_delay > 0) atomic_r_delay <= atomic_r_delay - 1;
    if (atomic_r_valid && resp.r_valid && req.r_ready) begin
      if (trace) $display("[Ra] t=%0d id=%h d=%h rp=%h", cycles, atomic_r_id, atomic_r_data, atomic_r_resp);
      atomic_r_valid <= 0;
    end
    if (resp.r_valid && req.r_ready && !atomic_r_valid) begin
      if (trace) $display("[R ] t=%0d id=%h d=%h", cycles, read_header.id, resp.r.data);
      if (resp.r.last) read_owned <= 0;
      else begin read_beat <= read_beat + 1; read_delay <= delay_cycles; end
    end
  end
  initial begin
    if (UnsupportedProfile) begin
      // The variant must actually be an unsupported origin configuration;
      // otherwise the all-zero oracle would be vacuous.
      if (config_pkg::g6lc_storamic_origin_supported(Cfg))
        $fatal(1, "CPU_ORIGIN_UNSUPPORTED_PROFILE_STILL_SUPPORTED");
    end else if (OriginEnabled &&
                 !config_pkg::g6lc_storamic_origin_supported(Cfg))
      $fatal(1, "CPU_ORIGIN_UNSUPPORTED_PROFILE");
    negative = $test$plusargs("oracle_negative");
    expect_supported = $test$plusargs("expect_supported");
    expect_atomic_origin = $test$plusargs("expect_atomic_origin");
    trace = $test$plusargs("trace");
    if (!$value$plusargs("rom=%s", rom_path)) $fatal(1, "CPU_ORIGIN_ROM_REQUIRED");
    if (!$value$plusargs("delay=%d", delay_cycles)) delay_cycles = 0;
    foreach (rom[i]) rom[i] = 32'h0000_0013;
    foreach (probe_mem[i]) probe_mem[i] = 8'h00;
    $readmemh(rom_path, rom);
    repeat (8) @(negedge clk);
    rst_n = 1;
  end
endmodule
