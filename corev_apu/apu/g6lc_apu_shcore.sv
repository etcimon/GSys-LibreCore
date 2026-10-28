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
// directly on the sideband inputs (disp_slot_i/desc_i/push_*), one
// outstanding dispatch at a time; commit and dispatch are
// serialized by the caller (shmod owns its read ports while busy).
//
// Timing impact: pure wiring plus a two-state accept FSM; no new
// datapath.  Enable=0 ties every output off.

module g6lc_apu_shcore
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderLanes   = 8,
  parameter int unsigned ShaderVec     = 4,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 16,
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
  // slot manager (§7b): module/pipeline slot ownership.  sm_req_i is a
  // one-cycle request pulse; sm_cpl_o pulses on the next cycle.
  input  logic         sm_req_i,
  input  apu_sh_sm_req_t sm_req_pl_i,
  output logic         sm_cpl_o,
  output apu_sh_sm_cpl_t sm_cpl_pl_o,
  // cmdexec work-port record: {ctype[31:0], imm[0..2]=gx,gy,gz}
  input  logic         work_i,
  output logic         work_ready_o,
  input  logic [31:0]  work_ctype_i,
  input  logic [8*32-1:0] work_imm_i,   // first 8 imm words
  // dispatch sideband (4a: direct slot + descriptor state)
  input  logic [2:0]   disp_slot_i,
  input  apu_sh_desc_t desc_i,
  input  logic [5:0]   push_n_i,
  input  logic [1023:0] push_i,
  // completion
  output logic         busy_o,
  output logic         done_o,
  output apu_sh_done_t done_pl_o,
  // guest memory word port (64-bit, handshake: request held until
  // mem_ready_i, one mem_rvalid_i per request, mem_err_i = zero data)
  output logic         mem_re_o,
  output logic         mem_we_o,
  output logic [63:0]  mem_addr_o,
  output logic [63:0]  mem_wdata_o,
  output logic [7:0]   mem_wstrb_o,
  input  logic         mem_ready_i,
  input  logic         mem_rvalid_i,
  input  logic [63:0]  mem_rdata_i,
  input  logic         mem_err_i,
  // §12.3 3d-d: wave-engine ObjTab port — descriptor record memory
  // handles resolve their current base through a READSLOT here
  // (vgtop's 5th, lowest-priority requester)
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
  // G3b-ii: ObjPay payload port — the FILL engine streams a module's
  // parked pCode words through here (fourth op_* client, arbitrated
  // inside vgtop below front/exec/ctl)
  output logic              op_req_valid_o,
  input  logic              op_req_ready_i,
  output apu_objpay_req_t   op_req_o,
  input  logic              op_cpl_valid_i,
  input  apu_objpay_cpl_t   op_cpl_i,
  // residency manager busy (a FILL is streaming/committing) — sm
  // requesters must be gated off while high
  output logic              sm_busy_o
);
  if (!Enable) begin : gen_off
    assign c_busy_o = 1'b0;    assign c_done_o = 1'b0;
    assign c_done_pl_o = '0;
    assign sm_cpl_o = 1'b0;    assign sm_cpl_pl_o = '0;
    assign work_ready_o = 1'b0;
    assign busy_o = 1'b0;      assign done_o = 1'b0;
    assign done_pl_o = '0;
    assign mem_re_o = 1'b0;    assign mem_we_o = 1'b0;
    assign mem_addr_o = '0;    assign mem_wdata_o = '0;
    assign mem_wstrb_o = '0;
    assign ot_req_valid_o = 1'b0; assign ot_req_o = '0;
    assign ot_cpl_ready_o = 1'b0;
    assign op_req_valid_o = 1'b0; assign op_req_o = '0;
    assign sm_busy_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | wr_en_i |
                    (|wr_slot_i) | (|wr_addr_i) | (|wr_data_i) |
                    commit_i | (|commit_pl_i) | retire_i |
                    (|retire_slot_i) | sm_req_i | (|sm_req_pl_i) |
                    work_i | (|work_ctype_i) |
                    (|work_imm_i) | (|disp_slot_i) | (|desc_i) |
                    (|push_n_i) | (|push_i) | (|mem_rdata_i) |
                    mem_ready_i | mem_rvalid_i | mem_err_i |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    op_req_ready_i | op_cpl_valid_i | (|op_cpl_i);
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
    logic [9:0]   phi_id;
    // G3a-i: function/param table read fabric
    logic [9:0]   func_id, parm_id;
    logic [31:0]  func_data;
    logic [15:0]  parm_data;
    logic [95:0]  type_data;
    logic [511:0] const_data;
    logic [63:0]  memb_data, init_data;
    logic [31:0]  rm_data, blk_data;
    logic [159:0] phi_data;
    logic [127:0] entry_data;

    // §5a G3b-iii: DispatchIndirect arrives with its {gx,gy,gz} already
    // fetched into imm[0..2] by the executor; DispatchBase carries
    // {baseX,Y,Z} in imm[0..2] and the counts in imm[3..5]
    wire is_dbase = (work_ctype_i ==
                     32'(APU_VN_TYPE_VK_CMD_DISPATCH_BASE_EXT));
    wire is_dispatch = (work_ctype_i ==
                        32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT)) ||
                       (work_ctype_i ==
                        32'(APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT)) ||
                       is_dbase;
    // graphics wave work (APU_SH_WORK_VS/FS pseudo-ctypes): a dispatch
    // whose imm words carry the record batch instead of gx/gy/gz; the
    // pseudo-ctype itself doubles as the work_id so completions are
    // distinguishable from compute dispatches
    wire is_gfx = (work_ctype_i == APU_SH_WORK_VS) ||
                  (work_ctype_i == APU_SH_WORK_FS);

    // ---- residency manager (G3b-ii) -----------------------------------
    // tag_q[s] = {valid, module handle, entry record, pins, lru age}.
    // Slots index the full 3-bit space; >= ShaderSlots stay invalid.
    typedef struct packed {
      logic          valid;
      logic [31:0]   handle;
      logic [31:0]   spec;
      apu_sh_entry_t entry;
      logic [7:0]    pins;
      logic [3:0]    age;    // 0 = most recently resolved
    } shres_t;
    shres_t        res_q [8];
    logic          sm_cpl_v_q;
    apu_sh_sm_cpl_t sm_cpl_q;

    // LOOKUP hit scan / FILL victim select (combinational over res_q)
    logic       res_hit;
    logic [2:0] res_hit_idx;
    logic       vic_free;          // an unpinned unused slot exists
    logic [2:0] vic_free_idx;
    logic       vic_any;           // an evictable (unpinned) slot
    logic [2:0] vic_idx;
    logic [3:0] vic_age;
    always_comb begin
      res_hit     = 1'b0;
      res_hit_idx = '0;
      vic_free    = 1'b0;
      vic_free_idx = '0;
      vic_any     = 1'b0;
      vic_idx     = '0;
      vic_age     = '0;
      for (int i = 0; i < 8; i++) begin
        if (i < ShaderSlots) begin
          if (res_q[i].valid &&
              res_q[i].handle == sm_req_pl_i.handle &&
              res_q[i].spec == sm_req_pl_i.spec &&
              !res_hit) begin
            res_hit     = 1'b1;
            res_hit_idx = 3'(i);
          end
          if (res_q[i].pins == 8'h0) begin
            if (!res_q[i].valid && !vic_free) begin
              vic_free     = 1'b1;
              vic_free_idx = 3'(i);
            end
            if (!vic_any || res_q[i].age > vic_age) begin
              vic_any = 1'b1;
              vic_idx = 3'(i);
              vic_age = res_q[i].age;
            end
          end
        end
      end
      // prefer never-used slots over evicting a resident one
      if (vic_free) begin
        vic_idx = vic_free_idx;
      end else if (!vic_any) begin
        vic_idx = '0;
      end
    end
    wire logic vic_ok = vic_free | vic_any;

    // ---- FILL engine: stream the pCode words from ObjPay through the
    // shmod staging port, then run the commit scan ----------------------
    typedef enum logic [2:0] {
      F_IDLE, F_SP0, F_SP1, F_READ, F_COMMIT, F_WAIT
    } fs_e;
    fs_e         fstate_q;
    logic [2:0]  f_slot_q;
    logic [31:0] f_handle_q;
    logic [31:0] f_base_q;       // chunk << 6, word address
    logic [15:0] f_idx_q, f_words_q;
    logic        f_pin_q;
    logic        f_reqd_q;       // op READ request accepted
    logic [31:0] f_spec_q;
    logic [5:0]  f_specn_q;
    logic [6:0]  f_spi_q;
    logic [31:0] f_spid_q [32];
    logic [31:0] f_spv_q [32];
    logic [1023:0] f_spid_p, f_spv_p;
    always_comb begin
      f_spid_p = '0;
      f_spv_p  = '0;
      for (int i = 0; i < 32; i++) begin
        f_spid_p[32*i +: 32] = f_spid_q[i];
        f_spv_p[32*i +: 32]  = f_spv_q[i];
      end
    end

    assign sm_busy_o      = fstate_q != F_IDLE;
    assign op_req_valid_o = (fstate_q == F_READ || fstate_q == F_SP0 ||
                             fstate_q == F_SP1) && !f_reqd_q;
    assign op_req_o       = '{op: APU_OBJPAY_OP_READ,
                             addr: fstate_q == F_READ
                                   ? f_base_q + 32'(f_idx_q)
                                   : {1'b0, f_spec_q[30:0]} + 32'(f_spi_q),
                             words: '0, wdata: '0};

    // staged word lands the cycle the ObjPay completion does
    wire fill_wr = (fstate_q == F_READ) && f_reqd_q && op_cpl_valid_i &&
                   op_cpl_i.status == APU_OBJPAY_OK;
    // the scanner owns the shmod read ports while busy_o — a wave on
    // another slot must have drained before the commit rewrites tables
    wire fill_commit = fstate_q == F_COMMIT && !wbusy;

    assign sm_cpl_o    = sm_cpl_v_q;
    assign sm_cpl_pl_o = sm_cpl_q;

    // LRU aging helper: mark slot `mrk` MRU, age the valid slots that
    // were younger than it
    task automatic res_touch(input logic [2:0] mrk);
      for (int i = 0; i < 8; i++)
        if (res_q[i].valid && 3'(i) != mrk &&
            res_q[i].age < res_q[mrk].age)
          res_q[i].age <= res_q[i].age + 4'd1;
      res_q[mrk].age <= 4'h0;
    endtask

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int i = 0; i < 8; i++) res_q[i] <= '0;
        sm_cpl_v_q <= 1'b0; sm_cpl_q <= '0;
        fstate_q <= F_IDLE; f_slot_q <= '0; f_handle_q <= '0;
        f_base_q <= '0; f_idx_q <= '0; f_words_q <= '0;
        f_pin_q <= 1'b0; f_reqd_q <= 1'b0;
        f_spec_q <= '0; f_specn_q <= '0; f_spi_q <= '0;
      end else begin
        sm_cpl_v_q <= 1'b0;
        // external retire drops residency alongside the shmod mark
        if (retire_i) res_q[retire_slot_i].valid <= 1'b0;
        unique case (fstate_q)
          F_IDLE: if (sm_req_i) begin
            unique case (sm_req_pl_i.op)
              APU_SH_SM_LOOKUP: begin
                sm_cpl_v_q <= 1'b1;
                if (res_hit) begin
                  res_touch(res_hit_idx);
                  if (sm_req_pl_i.pin &&
                      res_q[res_hit_idx].pins != 8'hFF)
                    res_q[res_hit_idx].pins <=
                      res_q[res_hit_idx].pins + 8'd1;
                  sm_cpl_q <= '{ok: 1'b1, busy: 1'b0,
                                slot: res_hit_idx,
                                entry: res_q[res_hit_idx].entry,
                                fault: '0};
                end else begin
                  sm_cpl_q <= '{ok: 1'b0, busy: 1'b0, slot: '0,
                                entry: '0, fault: '0};
                end
              end
              APU_SH_SM_FILL: begin
                if (res_hit) begin
                  // already resident: behaves as a LOOKUP
                  sm_cpl_v_q <= 1'b1;
                  res_touch(res_hit_idx);
                  if (sm_req_pl_i.pin &&
                      res_q[res_hit_idx].pins != 8'hFF)
                    res_q[res_hit_idx].pins <=
                      res_q[res_hit_idx].pins + 8'd1;
                  sm_cpl_q <= '{ok: 1'b1, busy: 1'b0,
                                slot: res_hit_idx,
                                entry: res_q[res_hit_idx].entry,
                                fault: '0};
                end else if (!vic_ok || c_busy_o) begin
                  // every slot pinned (or the scanner is busy) —
                  // the caller retries after in-flight work drains
                  sm_cpl_v_q <= 1'b1;
                  sm_cpl_q <= '{ok: 1'b0, busy: 1'b1, slot: '0,
                                entry: '0, fault: '0};
                end else if (sm_req_pl_i.words == 16'd0) begin
                  // degenerate extent: nothing to stream — the scan
                  // cannot succeed, answer the bound fault directly
                  sm_cpl_v_q <= 1'b1;
                  sm_cpl_q <= '{ok: 1'b0, busy: 1'b0, slot: '0,
                                entry: '0,
                                fault: '{code: APU_SH_FAULT_BOUND,
                                         opcode: '0, word: '0}};
                end else begin
                  // the tag stays invalid until the commit lands —
                  // a concurrent LOOKUP for this handle must not hit
                  // a half-staged slot (sm_busy gates that anyway)
                  f_slot_q   <= vic_idx;
                  f_handle_q <= sm_req_pl_i.handle;
                  f_base_q   <= 32'(sm_req_pl_i.chunk)
                                << APU_OBJPAY_CHUNK_SHIFT;
                  f_idx_q    <= '0;
                  f_words_q  <= sm_req_pl_i.words;
                  f_pin_q    <= sm_req_pl_i.pin;
                  f_spec_q   <= sm_req_pl_i.spec;
                  f_specn_q  <= '0;
                  f_spi_q    <= '0;
                  f_reqd_q   <= 1'b0;
                  res_q[vic_idx].valid <= 1'b0;
                  res_q[vic_idx].pins  <= '0;
                  res_q[vic_idx].age   <= 4'hF;   // MRU after fill:
                                                   // every other tag
                                                   // is younger
                  fstate_q   <= sm_req_pl_i.spec[31] ? F_SP0 : F_READ;
                end
              end
              APU_SH_SM_UNPIN: begin
                sm_cpl_v_q <= 1'b1;
                if (res_q[sm_req_pl_i.slot].pins != 8'h0) begin
                  res_q[sm_req_pl_i.slot].pins <=
                    res_q[sm_req_pl_i.slot].pins - 8'd1;
                  sm_cpl_q <= '{ok: 1'b1, busy: 1'b0,
                                slot: sm_req_pl_i.slot,
                                entry: res_q[sm_req_pl_i.slot].entry,
                                fault: '0};
                end else begin
                  sm_cpl_q <= '{ok: 1'b0, busy: 1'b0,
                                slot: sm_req_pl_i.slot,
                                entry: '0, fault: '0};
                end
              end
              default: begin // APU_SH_SM_INVAL
                sm_cpl_v_q <= 1'b1;
                for (int i = 0; i < 8; i++)
                  if (res_q[i].valid &&
                      res_q[i].handle == sm_req_pl_i.handle)
                    res_q[i].valid <= 1'b0;
                sm_cpl_q <= '{ok: 1'b1, busy: 1'b0, slot: '0,
                              entry: '0, fault: '0};
              end
            endcase
          end
          F_SP0: begin
            if (!f_reqd_q && op_req_ready_i) f_reqd_q <= 1'b1;
            if (f_reqd_q && op_cpl_valid_i) begin
              f_reqd_q <= 1'b0;
              if (op_cpl_i.status != APU_OBJPAY_OK ||
                  op_cpl_i.rdata > 32'd32) begin
                res_q[f_slot_q].valid <= 1'b0;
                sm_cpl_v_q <= 1'b1;
                sm_cpl_q <= '{ok: 1'b0, busy: 1'b0, slot: f_slot_q,
                              entry: '0,
                              fault: '{code: APU_SH_FAULT_CONST,
                                       opcode: '0, word: '0}};
                fstate_q <= F_IDLE;
              end else if (op_cpl_i.rdata == 32'h0) begin
                f_specn_q <= '0;
                fstate_q  <= F_READ;
              end else begin
                f_specn_q <= op_cpl_i.rdata[5:0];
                f_spi_q   <= 7'd1;   // first id word
                fstate_q  <= F_SP1;
              end
            end
          end
          F_SP1: begin
            if (!f_reqd_q && op_req_ready_i) f_reqd_q <= 1'b1;
            if (f_reqd_q && op_cpl_valid_i) begin
              f_reqd_q <= 1'b0;
              if (op_cpl_i.status != APU_OBJPAY_OK) begin
                res_q[f_slot_q].valid <= 1'b0;
                sm_cpl_v_q <= 1'b1;
                sm_cpl_q <= '{ok: 1'b0, busy: 1'b0, slot: f_slot_q,
                              entry: '0,
                              fault: '{code: APU_SH_FAULT_CONST,
                                       opcode: '0, word: 16'(f_spi_q)}};
                fstate_q <= F_IDLE;
              end else begin
                if (f_spi_q[0] == 1'b1)
                  f_spid_q[f_spi_q[6:1]] <= op_cpl_i.rdata;
                else
                  f_spv_q[f_spi_q[6:1] - 6'd1] <= op_cpl_i.rdata;
                if (f_spi_q + 7'd1 == {f_specn_q, 1'b0} + 7'd1) begin
                  // spi was the last value word (2*count)
                  fstate_q <= F_READ;
                end else begin
                  f_spi_q <= f_spi_q + 7'd1;
                end
              end
            end
          end
          F_READ: begin
            if (!f_reqd_q && op_req_ready_i) f_reqd_q <= 1'b1;
            if (f_reqd_q && op_cpl_valid_i) begin
              f_reqd_q <= 1'b0;
              if (op_cpl_i.status != APU_OBJPAY_OK) begin
                // extent went away or mis-sized — surface a fault,
                // the slot stays invalid
                res_q[f_slot_q].valid <= 1'b0;
                sm_cpl_v_q <= 1'b1;
                sm_cpl_q <= '{ok: 1'b0, busy: 1'b0, slot: f_slot_q,
                              entry: '0,
                              fault: '{code: APU_SH_FAULT_BOUND,
                                       opcode: '0,
                                       word: f_idx_q}};
                fstate_q <= F_IDLE;
              end else if (f_idx_q == f_words_q - 16'd1) begin
                fstate_q <= F_COMMIT;
              end else begin
                f_idx_q <= f_idx_q + 16'd1;
              end
            end
          end
          F_COMMIT: if (!wbusy) fstate_q <= F_WAIT; // commit pulses
          default: begin // F_WAIT
            if (c_done_o) begin
              if (c_done_pl_o.ok) begin
                res_q[f_slot_q].valid  <= 1'b1;
                res_q[f_slot_q].handle <= f_handle_q;
                res_q[f_slot_q].spec   <= f_spec_q;
                res_q[f_slot_q].entry  <= c_done_pl_o.entry;
                res_q[f_slot_q].pins   <= f_pin_q ? 8'd1 : 8'h0;
                res_touch(f_slot_q);
                sm_cpl_q <= '{ok: 1'b1, busy: 1'b0, slot: f_slot_q,
                              entry: c_done_pl_o.entry, fault: '0};
              end else begin
                res_q[f_slot_q].valid <= 1'b0;
                sm_cpl_q <= '{ok: 1'b0, busy: 1'b0, slot: f_slot_q,
                              entry: '0, fault: c_done_pl_o.fault};
              end
              sm_cpl_v_q <= 1'b1;
              fstate_q   <= F_IDLE;
            end
          end
        endcase
      end
    end

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
          if (is_dispatch || is_gfx) begin
            disp_q.slot    <= disp_slot_i;
            disp_q.gx      <= is_gfx ? '0 :
                              is_dbase ? work_imm_i[111:96]
                                       : work_imm_i[15:0];
            disp_q.gy      <= is_gfx ? '0 :
                              is_dbase ? work_imm_i[143:128]
                                       : work_imm_i[47:32];
            disp_q.gz      <= is_gfx ? '0 :
                              is_dbase ? work_imm_i[175:160]
                                       : work_imm_i[79:64];
            disp_q.gbx     <= is_gfx || !is_dbase ? '0
                                                  : work_imm_i[15:0];
            disp_q.gby     <= is_gfx || !is_dbase ? '0
                                                  : work_imm_i[47:32];
            disp_q.gbz     <= is_gfx || !is_dbase ? '0
                                                  : work_imm_i[79:64];
            disp_q.imm     <= is_gfx ? work_imm_i : '0;
            disp_q.work_id <= is_gfx ? work_ctype_i : wid_q;
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
      // G3b-ii: the fill engine shares the staging/commit ports;
      // external wr/commit are a TB backdoor (callers serialize)
      .wr_en_i(wr_en_i | fill_wr),
      .wr_slot_i(fill_wr ? f_slot_q : wr_slot_i),
      .wr_addr_i(fill_wr ? f_idx_q : wr_addr_i),
      .wr_data_i(fill_wr ? op_cpl_i.rdata : wr_data_i),
      .spec_n_i(f_specn_q),
      .spec_id_i(f_spid_p),
      .spec_val_i(f_spv_p),
      .commit_i(commit_i | fill_commit),
      .commit_pl_i(fill_commit
                   ? '{slot: f_slot_q, nwords: f_words_q}
                   : commit_pl_i),
      .busy_o(c_busy_o), .done_o(c_done_o), .done_pl_o(c_done_pl_o),
      .retire_i(retire_i),
      .retire_slot_i(retire_slot_i),
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
      .phi_id_i(phi_id), .phi_data_o(phi_data),
      .func_id_i(func_id), .func_data_o(func_data),
      .parm_id_i(parm_id), .parm_data_o(parm_data),
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
      .desc_i, .push_n_i, .push_i,
      .busy_o(wbusy), .done_o(wdone), .done_pl_o(wdone_pl),
      .rd_slot_o(rd_slot), .prog_addr_o(prog_addr),
      .prog_data_i(prog_data),
      .type_id_o(type_id), .type_data_i(type_data),
      .const_id_o(const_id), .const_data_i(const_data),
      .memb_id_o(memb_id), .memb_data_i(memb_data),
      .rm_id_o(rm_id), .rm_data_i(rm_data),
      .init_id_o(init_id), .init_data_i(init_data),
      .blk_id_o(blk_id), .blk_data_i(blk_data),
      .phi_id_o(phi_id), .phi_data_i(phi_data),
      .func_id_o(func_id), .func_data_i(func_data),
      .parm_id_o(parm_id), .parm_data_i(parm_data),
      .entry_data_i(entry_data),
      .mem_re_o, .mem_we_o, .mem_addr_o, .mem_wdata_o,
      .mem_wstrb_o, .mem_ready_i, .mem_rvalid_i, .mem_rdata_i,
      .mem_err_i,
      .ot_req_valid_o, .ot_req_ready_i, .ot_req_o,
      .ot_cpl_valid_i, .ot_cpl_ready_o, .ot_cpl_i
    );
  end
endmodule

// Thin fixture for the yosys Enable=0/1 screens (generic flow).
module g6lc_apu_shcore_fixture
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable        = 1'b0,
  parameter int unsigned ShaderLanes   = 8,
  parameter int unsigned ShaderVec     = 4,
  parameter int unsigned ShaderRegs    = 256,
  parameter int unsigned MaxWaves      = 16,
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
  input  logic         sm_req_i,
  input  apu_sh_sm_req_t sm_req_pl_i,
  output logic         sm_cpl_o,
  output apu_sh_sm_cpl_t sm_cpl_pl_o,
  input  logic         work_i,
  output logic         work_ready_o,
  input  logic [31:0]  work_ctype_i,
  input  logic [8*32-1:0] work_imm_i,
  input  logic [2:0]   disp_slot_i,
  input  apu_sh_desc_t desc_i,
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
  input  logic         mem_ready_i,
  input  logic         mem_rvalid_i,
  input  logic [63:0]  mem_rdata_i,
  input  logic         mem_err_i,
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
  output logic              op_req_valid_o,
  input  logic              op_req_ready_i,
  output apu_objpay_req_t   op_req_o,
  input  logic              op_cpl_valid_i,
  input  apu_objpay_cpl_t   op_cpl_i,
  output logic              sm_busy_o
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
