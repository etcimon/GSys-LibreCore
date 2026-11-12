// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Integration test of g6lc_apu_cmdexec against the real g6lc_apu_cmdrec
// and g6lc_apu_objtab.  The TB owns the request ports during setup
// (allocating objects, recording buffers) then hands them to the
// executor.  The work port is modelled with a few-cycle accept plus a
// deferred work_done_i completion.
//
// Cases: ordered work issue across one submit, multi-buffer submit,
// pipeline-barrier drain, stale-record handle -> DEVICE_LOST, unsealed
// buffer -> DEVICE_LOST, fence clear, Enable=0 quiet.
module tb_g6lc_apu_cmdexec;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_mp_pkg::*;

  localparam int Fences = 16;
  localparam int unsigned ObjEntries = 256;
  localparam int unsigned PayMemB    = 64 * 1024;

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- executor ports ------------------------------------------------
  logic               sub_v = 0, sub_r;
  apu_cmdexec_submit_t sub;
  logic               xcr_v, xcr_r;
  apu_cmdrec_req_t    xcr_req;
  logic               xcr_cv, xcr_cr;
  apu_cmdrec_cpl_t    xcr_cpl;
  logic               xot_v, xot_r;
  apu_objtab_req_t    xot_req;
  logic               xot_cv, xot_cr;
  apu_objtab_cpl_t    xot_cpl;
  logic               w_v, w_r = 0;
  apu_cmdexec_work_t  w_o;
  logic               w_done = 0;
  logic [15:0]        done_seq;
  logic [Fences-1:0]  fsig, flost, fclr = '0, ffail = '0;
  logic               osub_r, ow_v, oxcr_v, oxcr_cr, oxot_v, oxot_cr;
  logic               odl_v, odl_dead;
  logic [7:0]         odl_ctx;
  logic [15:0]        odone;
  logic [Fences-1:0]  ofsig, oflost;
  apu_cmdexec_work_t  ow_o;
  apu_cmdrec_req_t    oxcr_req;
  apu_objtab_req_t    oxot_req;
  // §7b/5a-ii: ObjPay port + shcore dispatch sideband.  G3b-ii made
  // the op port real: dispatch assembly reads the pipeline's module
  // block ({handle,{chunk,words}}) so a behavioural ObjPay answers,
  // and the sm client gets a residency model (hit/miss/pin/LRU-lite)
  logic               xop_v, oop_v, xop_cr, oop_cr;
  apu_objpay_req_t    xop_req, oop_req;
  apu_objpay_cpl_t    xop_cpl;
  apu_sh_done_t       w_done_pl;
  // G3b-ii sm client: level-held req until gnt; 1-cycle model cpl
  logic               xsm_v, xsm_cv = 1'b0;
  apu_sh_sm_req_t     xsm_pl;
  apu_sh_sm_cpl_t     xsm_cpl;
  logic               osm_v;
  // residency model state: 8 slots, handle->valid/pins/age
  bit    m_rs_v   [8];
  int    m_rs_h   [8];
  int    m_rs_pin [8];
  int    m_rs_age [8];
  bit    m_fill_fault = 0;   // force the next FILL to a scan fault
  int    m_fill_i = 0;       // FILL attempts so far
  int    m_fill_fault_at = -1;  // fault the Nth FILL attempt
  logic [2:0]         dslot, odslot;
  apu_sh_desc_t       ddesc, oddesc;
  logic [5:0]         dpushn, odpushn;
  logic [1023:0]      dpush, odpush;
  // §12.3 3d-d: relocation hold — cmdexec must stop dequeuing new
  // submissions while high and report true drain on idle_o
  logic               hold = 1'b0;
  // §3a query-stat counter bus into the DUT — driven per-case so a
  // Begin/End window can be given a known counter trajectory
  logic [4*32-1:0]    qstat_drv = '0;
  logic               ce_idle;
  // §7b exception contract: the done model returns a per-item code —
  // work index fault_at completes with APU_SH_DONE_FAULT; pc/wave/
  // work_id below let the sticky-register check see real tags
  logic [7:0]         code_at [64];
  int                 fault_at = -1, done_i = 0;
  logic               pend_hold = 1'b0;   // starve the done model
  logic [7:0]         dl_ctx;
  logic               dl_v, dl_dead, dl_seen = 1'b0;
  // payload latched with the w_done pulse — done_i advances on the
  // same edge, so a combinational read would return the NEXT item
  initial w_done_pl = '{code: APU_SH_DONE_OK, default: '0};

  g6lc_apu_cmdexec #(.Enable(1'b1), .Fences(Fences),
                     // small watchdog budget so the expiry vector is
                     // reachable in a directed run
                     .WorkBudgetLog2(8)) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .submit_valid_i(sub_v), .submit_ready_o(sub_r), .submit_i(sub),
    .cr_req_valid_o(xcr_v), .cr_req_ready_i(xcr_r), .cr_req_o(xcr_req),
    .cr_cpl_valid_i(xcr_cv), .cr_cpl_ready_o(xcr_cr), .cr_cpl_i(xcr_cpl),
    .ot_req_valid_o(xot_v), .ot_req_ready_i(xot_r), .ot_req_o(xot_req),
    .ot_cpl_valid_i(xot_cv), .ot_cpl_ready_o(xot_cr), .ot_cpl_i(xot_cpl),
    .op_req_valid_o(xop_v), .op_req_ready_i(1'b1), .op_req_o(xop_req),
    .op_cpl_valid_i(xop_cv), .op_cpl_ready_o(xop_cr), .op_cpl_i(xop_cpl),
    .sm_req_o(xsm_v), .sm_req_pl_o(xsm_pl),
    .sm_gnt_i(xsm_v), .sm_cpl_i(xsm_cv), .sm_cpl_pl_i(xsm_cpl),
    .work_valid_o(w_v), .work_ready_i(w_r), .work_o(w_o),
    .work_done_i(w_done), .work_done_pl_i(w_done_pl),
    .disp_slot_o(dslot), .desc_o(ddesc),
    .push_n_o(dpushn), .push_o(dpush),
    .done_seq_o(done_seq),
    .fence_signaled_o(fsig), .fence_lost_o(flost),
    .fence_clr_i(fclr), .fence_fail_i(ffail), .xf_o(), .rd_o(),
    .devlost_valid_o(dl_v), .devlost_ctx_o(dl_ctx),
    .dead_o(dl_dead),
    .mp_req_valid_o(emp_v), .mp_req_ready_i(emr),
    .mp_req_o(emp_req),
    .mp_rsp_valid_i(emp_rv), .mp_rsp_i(emp_rsp),
    .hold_i(hold), .idle_o(ce_idle), .busy_o(),
    .qry_stat_i(qstat_drv));
  // §5a G3b-iii + §COPY: the EXEC aperture port now backs a real word
  // store — indirect-operand reads return apm data and
  // COPY_QUERY_POOL_RESULTS writes are observable at i_emem.apm
  logic        emp_v, emp_rv = 1'b0, emr;
  apu_mp_req_t emp_req;
  apu_mp_rsp_t emp_rsp;
  tb_apu_mp_mem #(.N(1), .GMW(1), .APW(32'h40000),
                  .PWB(1), .PPW(1)) i_emem (
    .clk_i(clk), .rst_ni(rst_ni),
    .req_valid_i(emp_v), .req_ready_o(emr), .req_i('{emp_req}),
    .rsp_valid_o(emp_rv), .rsp_o('{emp_rsp}));
  g6lc_apu_cmdexec_fixture #(.Enable(1'b0), .Fences(Fences)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .submit_valid_i(sub_v), .submit_ready_o(osub_r), .submit_i(sub),
    .cr_req_valid_o(oxcr_v), .cr_req_ready_i(xcr_r), .cr_req_o(oxcr_req),
    .cr_cpl_valid_i(xcr_cv), .cr_cpl_ready_o(oxcr_cr), .cr_cpl_i(xcr_cpl),
    .ot_req_valid_o(oxot_v), .ot_req_ready_i(xot_r), .ot_req_o(oxot_req),
    .ot_cpl_valid_i(xot_cv), .ot_cpl_ready_o(oxot_cr), .ot_cpl_i(xot_cpl),
    .op_req_valid_o(oop_v), .op_req_ready_i(1'b1), .op_req_o(oop_req),
    .op_cpl_valid_i(1'b0), .op_cpl_ready_o(oop_cr), .op_cpl_i('0),
    .sm_req_o(osm_v), .sm_req_pl_o(),
    .sm_gnt_i(1'b0), .sm_cpl_i(1'b0), .sm_cpl_pl_i('0),
    .work_valid_o(ow_v), .work_ready_i(w_r), .work_o(ow_o),
    .work_done_i(w_done), .work_done_pl_i(w_done_pl),
    .disp_slot_o(odslot), .desc_o(oddesc),
    .push_n_o(odpushn), .push_o(odpush),
    .done_seq_o(odone),
    .fence_signaled_o(ofsig), .fence_lost_o(oflost),
    .fence_clr_i(fclr), .fence_fail_i(ffail), .xf_o(), .rd_o(),
    .devlost_valid_o(odl_v), .devlost_ctx_o(odl_ctx),
    .dead_o(odl_dead),
    .mp_req_valid_o(), .mp_req_ready_i(1'b0),
    .mp_req_o(),
    .mp_rsp_valid_i(1'b0), .mp_rsp_i(apu_mp_rsp_t'('0)),
    .hold_i(hold), .idle_o(), .busy_o(), .qry_stat_i('0));

  // ---- backend mux: TB setup vs executor ------------------------------
  // The real cmdrec/objtab buses fan out to both masters; tb_drv selects
  // who drives req_valid/req payload (completions are broadcast).
  logic tb_drv = 1'b1;
  logic tcr_v = 0, tcr_r, tcr_cv;
  apu_cmdrec_req_t tcr_req;
  logic tot_v = 0, tot_r, tot_cv;
  apu_objtab_req_t tot_req;

  logic            cr_rdy, cr_cvld;
  apu_cmdrec_cpl_t cr_cpl;
  logic            ot_rdy, ot_cvld;
  apu_objtab_cpl_t ot_cpl;
  assign tcr_r  = cr_rdy;  assign xcr_r  = cr_rdy;
  assign tcr_cv = cr_cvld; assign xcr_cv = cr_cvld;
  assign xcr_cpl = cr_cpl;
  assign tot_r  = ot_rdy;  assign xot_r  = ot_rdy;
  assign tot_cv = ot_cvld; assign xot_cv = ot_cvld;
  assign xot_cpl = ot_cpl;

  wire cr_vld  = tb_drv ? tcr_v   : xcr_v;
  wire ot_vld  = tb_drv ? tot_v   : xot_v;
  wire cr_crdy = tb_drv ? 1'b1    : xcr_cr;
  wire ot_crdy = tb_drv ? 1'b1    : xot_cr;
  wire apu_cmdrec_req_t cr_req = tb_drv ? tcr_req : xcr_req;
  wire apu_objtab_req_t ot_req = tb_drv ? tot_req : xot_req;

  logic        tpay_v = 1'b0, tpay_r;
  logic [31:0] tpay_d = '0;

  // §5a G3b-iii: cmdrec's ObjPay client rides the same behavioural
  // paymem as the executor's op port (descriptor blocks, record/
  // payload chunks, and the executor's payload reads share one image)
  logic            rop_v, rop_r = 1'b1, rop_cv, rop_cr;
  apu_objpay_req_t rop_req;
  apu_objpay_cpl_t rop_cpl;

  g6lc_apu_cmdrec #(.Enable(1'b1)) i_rec (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(cr_vld), .req_ready_o(cr_rdy), .req_i(cr_req),
    .cpl_valid_o(cr_cvld), .cpl_ready_i(cr_crdy), .cpl_o(cr_cpl),
    .pay_valid_i(tpay_v), .pay_data_i(tpay_d),
    .pay_ready_o(tpay_r),
    .op_req_valid_o(rop_v), .op_req_ready_i(rop_r),
    .op_req_o(rop_req),
    .op_cpl_valid_i(rop_cv), .op_cpl_ready_o(rop_cr),
    .op_cpl_i(rop_cpl));
  // ---- objmem plumbing (ObjTab-V DRAM backing) --------------------
  logic         omt_v, omt_r, omt_rv;
  apu_omt_req_t omt_req;
  apu_omt_rsp_t omt_rsp;
  logic         ompr_r, ompr_rv;
  apu_omp_rsp_t ompr_rsp;
  logic         mp_v, mp_r, mp_rv;
  apu_mp_req_t  mp_req;
  apu_mp_rsp_t  mp_rsp;

  g6lc_apu_objtab #(.Enable(1'b1), .ObjEntries(ObjEntries)) i_obj (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(ot_vld), .req_ready_o(ot_rdy), .req_i(ot_req),
    .cpl_valid_o(ot_cvld), .cpl_ready_i(ot_crdy), .cpl_o(ot_cpl),
    .live_o(),
    .omt_req_valid_o(omt_v), .omt_req_ready_i(omt_r),
    .omt_req_o(omt_req),
    .omt_rsp_valid_i(omt_rv), .omt_rsp_i(omt_rsp));

  g6lc_apu_objmem #(.Enable(1'b1), .ObjEntries(ObjEntries),
                    .PayMemBytes(PayMemB),
                    .DirCacheSets(16), .EntCacheLines(8),
                    .PayCacheLines(4)) i_omm (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .omt_req_valid_i(omt_v), .omt_req_ready_o(omt_r),
    .omt_req_i(omt_req),
    .omt_rsp_valid_o(omt_rv), .omt_rsp_o(omt_rsp),
    .omp_req_valid_i(1'b0), .omp_req_ready_o(ompr_r),
    .omp_req_i(apu_omp_req_t'(0)),
    .omp_rsp_valid_o(ompr_rv), .omp_rsp_o(ompr_rsp),
    .mp_req_valid_o(mp_v), .mp_req_ready_i(mp_r),
    .mp_req_o(mp_req),
    .mp_rsp_valid_i(mp_rv), .mp_rsp_i(mp_rsp));

  // aperture responder over the static carve window only
  tb_apu_mp_mem #(.N(1), .GMW(1), .APW(0),
                  .PWB(32'(APU_OBJMEM_OFF >> 2)),
                  .PPW(32'((apu_objmem_pay_off(ObjEntries) +
                            64'(PayMemB) - APU_OBJMEM_OFF) >> 2) +
                        64))
      i_mem (
    .clk_i(clk), .rst_ni(rst_ni),
    .req_valid_i(mp_v), .req_ready_o(mp_r), .req_i('{mp_req}),
    .rsp_valid_o(mp_rv), .rsp_o('{mp_rsp}));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) if (ow_v || oxcr_v || oxcr_cr || oxot_v ||
                            oxot_cr || oop_v || oop_cr || osub_r ||
                            osm_v ||
                            odone !== '0 || ofsig !== '0 ||
                            oflost !== '0 || odslot !== '0 ||
                            oddesc !== '0 || odpushn !== '0 ||
                            odpush !== '0 || odl_v || odl_dead)
    $fatal(1, "disabled cmdexec active");

  // ---- G3b-ii: behavioural ObjPay + residency-manager models ------
  // exec reads pipeline module blocks ({handle,{chunk,words}}) from
  // paymem — the TB writes them directly during setup.  §5a G3b-iii:
  // cmdrec's descriptor blocks and record/payload chunks live in the
  // same image — the rop model is a bump allocator above the TB
  // fixtures (chunks 40..52) implementing ALLOC/WRITE/READ/READN/FREE
  // (FREE is a no-op — no reclaim is needed for these cases).  The sm
  // model mirrors shcore's residency table loosely: LOOKUP hit/miss,
  // FILL takes the lowest free then the oldest unpinned slot (BUSY
  // when all eight are pinned), UNPIN/INVAL bookkeeping.  1-cycle cpl.
  logic [31:0] paymem [32768];
  logic [31:0] pay_bump = 32'd4096;   // first word above the fixtures
  logic [3:0]  m_rn_rem = 0;
  logic [31:0] m_rn_addr = '0;
  // executor-side READN continuation: COPY_QUERY_POOL_RESULTS issues a
  // burst slot fetch; the model streams one completion per word in
  // address order like the rop model does for cmdrec
  logic [4:0]  m_xn_rem = 0;
  logic [31:0] m_xn_addr = '0;
  logic        xop_cv = 1'b0;
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      xop_cv <= 1'b0; xop_cpl <= '0;
      rop_cv <= 1'b0; rop_cpl <= '0; rop_r <= 1'b1;
      m_rn_rem <= '0; m_rn_addr <= '0;
      m_xn_rem <= '0; m_xn_addr <= '0;
    end else begin
      xop_cv <= 1'b0;
      if (m_xn_rem != 0) begin
        // READN continuation beat — one completion per remaining word
        xop_cv    <= 1'b1;
        xop_cpl   <= '{status: APU_OBJPAY_OK,
                      rdata: paymem[m_xn_addr[14:0]], default: '0};
        m_xn_addr <= m_xn_addr + 32'd1;
        m_xn_rem  <= m_xn_rem - 5'd1;
      end else if (xop_v) begin
        // §3a query results: the executor's ObjPay WRITE lands in the
        // same paymem image so cases can observe result-slot contents
        if (xop_req.op == APU_OBJPAY_OP_WRITE)
          paymem[xop_req.addr[14:0]] <= xop_req.wdata;
        xop_cv  <= 1'b1;
        xop_cpl <= '{status: APU_OBJPAY_OK,
                     rdata: (xop_req.op == APU_OBJPAY_OP_READ ||
                             xop_req.op == APU_OBJPAY_OP_READN)
                            ? paymem[xop_req.addr[14:0]] : 32'h0,
                     default: '0};
        if (xop_req.op == APU_OBJPAY_OP_READN &&
            xop_req.words > 32'd1) begin
          m_xn_rem  <= xop_req.words[4:0] - 5'd1;
          m_xn_addr <= xop_req.addr + 32'd1;
        end
      end
      // cmdrec ObjPay client — one outstanding op, READN streams one
      // completion per word (ready rises on the last beat)
      rop_cv <= 1'b0;
      if (m_rn_rem != 0) begin
        rop_cv    <= 1'b1;
        rop_cpl   <= '{status: APU_OBJPAY_OK,
                      rdata: paymem[m_rn_addr[14:0]], default: '0};
        m_rn_addr <= m_rn_addr + 32'd1;
        m_rn_rem  <= m_rn_rem - 4'd1;
        if (m_rn_rem == 4'd1) rop_r <= 1'b1;
      end else if (rop_v && rop_r) begin
        unique case (rop_req.op)
          APU_OBJPAY_OP_ALLOC: begin
            rop_cv    <= 1'b1;
            rop_cpl   <= '{status: APU_OBJPAY_OK, base: pay_bump,
                          default: '0};
            pay_bump  <= (pay_bump + rop_req.words + 32'd63) &
                         ~32'd63;
          end
          APU_OBJPAY_OP_WRITE: begin
            paymem[rop_req.addr[14:0]] <= rop_req.wdata;
            rop_cv  <= 1'b1;
            rop_cpl <= '{status: APU_OBJPAY_OK, default: '0};
          end
          APU_OBJPAY_OP_READN: begin
            rop_cv  <= 1'b1;
            rop_cpl <= '{status: APU_OBJPAY_OK,
                        rdata: paymem[rop_req.addr[14:0]],
                        default: '0};
            if (rop_req.words > 1) begin
              m_rn_rem  <= rop_req.words[3:0] - 4'd1;
              m_rn_addr <= rop_req.addr + 32'd1;
              rop_r     <= 1'b0;
            end
          end
          default: begin  // READ; FREE returns OK with no reclaim
            rop_cv  <= 1'b1;
            rop_cpl <= '{status: APU_OBJPAY_OK,
                        rdata: rop_req.op == APU_OBJPAY_OP_READ
                               ? paymem[rop_req.addr[14:0]] : 32'h0,
                        default: '0};
          end
        endcase
      end
    end
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      xsm_cv <= 1'b0; xsm_cpl <= '0;
      for (int i = 0; i < 8; i++) begin
        m_rs_v[i] = 0; m_rs_h[i] = 0; m_rs_pin[i] = 0; m_rs_age[i] = 0;
      end
    end else begin
      xsm_cv <= 1'b0;
      if (xsm_v) begin         // gnt == req: sole client, always idle
        automatic int hit = -1, vic = -1, vage = -1;
        for (int i = 0; i < 8; i++)
          if (m_rs_v[i] && m_rs_h[i] == xsm_pl.handle) hit = i;
        xsm_cv <= 1'b1;
        unique case (xsm_pl.op)
          APU_SH_SM_LOOKUP: begin
            if (hit >= 0) begin
              if (xsm_pl.pin) m_rs_pin[hit]++;
              for (int i = 0; i < 8; i++)
                if (m_rs_v[i] && i != hit && m_rs_age[i] < m_rs_age[hit])
                  m_rs_age[i]++;
              m_rs_age[hit] = 0;
              xsm_cpl <= '{ok: 1'b1, busy: 1'b0, slot: 3'(hit),
                           default: '0};
            end else begin
              xsm_cpl <= '{ok: 1'b0, busy: 1'b0, default: '0};
            end
          end
          APU_SH_SM_FILL: begin
            m_fill_i++;
            for (int i = 0; i < 8; i++)
              if (!m_rs_v[i] && vic < 0) vic = i;
            if (vic < 0)
              for (int i = 0; i < 8; i++)
                if (m_rs_pin[i] == 0 &&
                    (vage < 0 || m_rs_age[i] > vage)) begin
                  vic = i; vage = m_rs_age[i];
                end
            if (hit >= 0) begin
              if (xsm_pl.pin) m_rs_pin[hit]++;
              xsm_cpl <= '{ok: 1'b1, busy: 1'b0, slot: 3'(hit),
                           default: '0};
            end else if (vic < 0) begin
              xsm_cpl <= '{ok: 1'b0, busy: 1'b1, default: '0};
            end else if (m_fill_fault ||
                         m_fill_i - 1 == m_fill_fault_at) begin
              m_fill_fault = 0;
              xsm_cpl <= '{ok: 1'b0, busy: 1'b0,
                           fault: '{code: 8'h11, default: '0},
                           default: '0};
            end else begin
              m_rs_v[vic]   = 1;
              m_rs_h[vic]   = xsm_pl.handle;
              m_rs_pin[vic] = xsm_pl.pin ? 1 : 0;
              for (int i = 0; i < 8; i++)
                if (m_rs_v[i] && i != vic) m_rs_age[i]++;
              m_rs_age[vic] = 0;
              xsm_cpl <= '{ok: 1'b1, busy: 1'b0, slot: 3'(vic),
                           default: '0};
            end
          end
          APU_SH_SM_UNPIN: begin
            if (m_rs_pin[xsm_pl.slot] > 0) begin
              m_rs_pin[xsm_pl.slot]--;
              xsm_cpl <= '{ok: 1'b1, busy: 1'b0, slot: xsm_pl.slot,
                           default: '0};
            end else begin
              xsm_cpl <= '{ok: 1'b0, busy: 1'b0, default: '0};
            end
          end
          default: begin       // INVAL
            if (hit >= 0) m_rs_v[hit] = 0;
            xsm_cpl <= '{ok: 1'b1, busy: 1'b0, default: '0};
          end
        endcase
      end
    end
  end

  // watchdog pulse latch
  always @(posedge clk) if (dl_v) dl_seen <= 1'b1;

  // ---- work port model ----------------------------------------------
  logic [31:0] got_work [64];
  apu_cmdexec_state_t got_snap [64];
  int work_i = 0, pend = 0, dtimer = 0;
  always @(posedge clk) begin
    if (w_v && w_r) begin
      got_work[work_i] <= w_o.ctype;
      got_snap[work_i] <= w_o.snap;
      code_at[work_i]  <= work_i == fault_at ? APU_SH_DONE_FAULT
                                             : APU_SH_DONE_OK;
      work_i <= work_i + 1;
      pend   <= pend + 1;
    end
    w_done <= 1'b0;
    if (dtimer != 0) begin
      dtimer <= dtimer - 1;
      if (dtimer == 1) begin
        w_done <= 1'b1;
        w_done_pl <= '{code: code_at[done_i], wave: 16'h5,
                       pc: 16'h7C, work_id: 32'hF000_0002,
                       default: '0};
        done_i <= done_i + 1;
        pend   <= pend - 1 + (w_v && w_r ? 1 : 0);
      end
    end else if (pend != 0 && !pend_hold) begin
      dtimer <= 3;
    end
  end
  // work_ready: deasserted for a cycle out of every 5
  always @(negedge clk) w_r <= (cycles % 5) != 4;

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL: %s", name);
      if (errors > 16) $fatal(1, "too many errors");
    end
  endtask

  // ---- backend setup helpers ------------------------------------------
  // pay stream magic — cases may switch it to keep streams
  // distinguishable in paymem (case 7's push check)
  logic [31:0] pay_magic = 32'hCAFE_0000;

  task automatic cr_op(input apu_cmdrec_op_e o, input logic [31:0] b,
                       input logic [15:0] ix, input apu_cmdrec_rec_t r,
                       input logic [15:0] pn = '0);
    @(negedge clk); tcr_v = 1'b1;
    tcr_req = '{op: o, cbd: b, idx: ix, rec: r, pay_n: pn, flags: '0};
    @(posedge clk);
    while (!tcr_r) @(posedge clk);
    @(negedge clk); tcr_v = 1'b0;
    // APPEND with pay_n streams its payload words while the recorder
    // walks its descriptor-open/ALLOC preamble to StPayW — each word
    // holds until pay_ready_o is high at a negedge (the accepting
    // posedge follows), then through that posedge before advancing
    if (pn != 0) begin
      @(negedge clk); tpay_v = 1'b1;
      for (int i = 0; i < pn; i++) begin
        tpay_d = pay_magic + 32'(i);
        while (!tpay_r) @(negedge clk);
        @(negedge clk);
      end
      tpay_v = 1'b0;
    end
    while (!tcr_cv) @(negedge clk);
  endtask

  task automatic ot_op(input apu_objtab_op_e o, input logic [63:0] id,
                       input logic [7:0] k,
                       input logic [63:0] size = '0,
                       input logic [63:0] mem_id = '0,
                       input logic [63:0] offset = '0,
                       input logic [31:0] mask = '0,
                       input logic [31:0] value = '0);
    @(negedge clk); tot_v = 1'b1;
    tot_req = '{op: o, id: id, kind: k[5:0], size: size,
                mem_id: mem_id, offset: offset, mask: mask,
                value: value, default: '0};
    @(posedge clk);
    while (!tot_r) @(posedge clk);
    @(negedge clk); tot_v = 1'b0;
    while (!tot_cv) @(negedge clk);
  endtask

  function automatic apu_cmdrec_rec_t mkrec(input logic [31:0] ty,
                                            input logic [31:0] h0,
                                            input logic [7:0] k0,
                                            input logic [31:0] i0);
    apu_cmdrec_rec_t r;
    r = '0;
    r.ctype = ty;
    r.handle[0] = h0; r.kind[0] = k0;
    r.imm[0] = i0;
    return r;
  endfunction

  logic [31:0] cb_h, pipe_h, dset_h, buf0_h, buf1_h;
  logic [31:0] lay_h, gpipe_h, rp_h, fb_h, view_h, img_h;
  logic [31:0] img2_h, view2_h, rp2_h, fb2_h, gpipe1_h;
  logic [31:0] qry_h, qry2_h, qry3_h;
  logic [31:0] cp_mem_h, cp_buf_h;
  localparam int QRY_EXT = 28672;   // result-extent word base in paymem
  // COPY dst aperture: dedicated memory at byte base 0x8000 -> apm
  // word 0x2000, kept clear of the shared buf0/buf1 region (0x4000)
  localparam int CP_AP_MEM = 32'h8000;
  logic [15:0] seq0;
  // §5a G3b-iii: cmdrec buffer identifiers are PayMem descriptor
  // block addresses (allocated by vnfront in the real system — the
  // TB plays that role at chunks 20..31)
  logic [31:0] cbd [20];

  task automatic submit(input logic [4:0] f, input int nb,
                        input logic [31:0] r0, input logic [31:0] h0,
                        input logic [31:0] r1, input logic [31:0] h1);
    sub_v = 1'b1;
    sub = '{fence_idx: f, nbufs: 3'(nb), ctx: 8'h0,
            crec: '{32'h0, 32'h0, r1, r0},
            chndl: '{32'h0, 32'h0, h1, h0}};
    // wait for handshake
    while (!sub_r) @(posedge clk);
    @(posedge clk);
    @(negedge clk); sub_v = 1'b0;
  endtask

  task automatic wait_fence(input int f, input int timeout);
    int t = 0;
    while (!fsig[f] && t < timeout) begin
      @(negedge clk); t++;
    end
    check("fence signaled", fsig[f]);
  endtask

  initial begin
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;

    // ---- setup: objects ------------------------------------------------
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0001,
          APU_VN_KIND_VK_COMMAND_BUFFER);
    cb_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0002,
          APU_VN_KIND_VK_PIPELINE);
    pipe_h = ot_cpl.handle;
    // §12.3 F5: dispatch assembly resolves the pipeline's layout —
    // give the fake pipeline a live (empty) PIPELINE_LAYOUT handle in
    // aux[63:32] like vnfront's vkCreateComputePipelines does
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0007,
          APU_VN_KIND_VK_PIPELINE_LAYOUT);
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0002,
          APU_VN_KIND_VK_PIPELINE,
          .mask(32'hFFFF_FFFF), .value(ot_cpl.handle));
    // G3b-ii: aux[31:16] = the pipeline's ObjPay block chunk — the
    // block carries {module handle, {pCode chunk,words}} that the
    // assembly resolves through the sm residency model.  Block at
    // chunk 40 (word base 2560); the fake module parks at chunk 60.
    paymem[(40 << 6) + 0] = 32'h0001_0009;
    paymem[(40 << 6) + 1] = {16'd60, 16'd96};
    ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0002,
          APU_VN_KIND_VK_PIPELINE,
          .mask(32'hFFFF_FFFF), .value({16'd40, 16'h0}));
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0003,
          APU_VN_KIND_VK_DESCRIPTOR_SET);
    dset_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0004,
          APU_VN_KIND_VK_BUFFER, .size(64'd128));
    buf0_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0005,
          APU_VN_KIND_VK_BUFFER, .size(64'd128));
    buf1_h = ot_cpl.handle;
    // §12.3 C/5a: the XFER operand assembly re-resolves the operand
    // buffers' bound memory, so give them a device-memory object with
    // an aperture page base in aux[63:32] and SETBIND both buffers
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0006,
          APU_VN_KIND_VK_DEVICE_MEMORY, .size(64'd256));
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0006,
          APU_VN_KIND_VK_DEVICE_MEMORY,
          .mask(32'hFFFF_FFFF), .value(32'h0000_4000));
    ot_op(APU_OBJTAB_OP_SETBIND, 64'h1000_0000_0000_0004,
          APU_VN_KIND_VK_BUFFER,
          .mem_id(64'h1000_0000_0000_0006));
    ot_op(APU_OBJTAB_OP_SETBIND, 64'h1000_0000_0000_0005,
          APU_VN_KIND_VK_BUFFER,
          .mem_id(64'h1000_0000_0000_0006), .offset(64'd128));
    check("alloc cb", cb_h !== '0);

    // §5a G3b-iii: 64-word zeroed descriptor block per buffer
    for (int i = 0; i < 20; i++) begin
      cbd[i] = 32'(20 + i) << 6;
      for (int w = 0; w < 64; w++)
        paymem[cbd[i] + 32'(w)] = 32'h0;
    end

    // ---- case 1: record + submit buf0 ------------------------------------
    cr_op(APU_CMDREC_OP_BEGIN, cbd[0], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[0], 0,
          mkrec(APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT, pipe_h,
                APU_VN_KIND_VK_PIPELINE, 0));
    cr_op(APU_CMDREC_OP_APPEND, cbd[0], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, 0, 0, 32'h8));
    cr_op(APU_CMDREC_OP_APPEND, cbd[0], 0,
          mkrec(APU_VN_TYPE_VK_CMD_PIPELINE_BARRIER_EXT, 0, 0, 0));
    begin
      // one real region descriptor ({srcOff,dstOff,size} u64s = 6
      // payload words) so imm[7] carries a pay_base like a recorded
      // vkCmdCopyBuffer
      apu_cmdrec_rec_t rr = mkrec(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT,
                                  buf0_h, APU_VN_KIND_VK_BUFFER, 1);
      rr.handle[1] = buf1_h; rr.kind[1] = APU_VN_KIND_VK_BUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[0], 0, rr, 6);
    end
    cr_op(APU_CMDREC_OP_END, cbd[0], 0, '0);
    check("record buf0", cr_cpl.status == APU_CMDREC_OK);

    tb_drv = 1'b0;
    seq0 = done_seq;
    submit(5'd0, 1, cbd[0], cb_h, 32'h0, 32'h0);
    wait_fence(0, 4000);
    check("work count", work_i == 2);
    check("work0 dispatch",
          got_work[0] == APU_VN_TYPE_VK_CMD_DISPATCH_EXT);
    check("work1 copy",
          got_work[1] == APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT);
    check("snap pipeline", got_snap[1].pipeline == pipe_h);
    check("no lost", flost[0] === 1'b0);
    check("seq adv", done_seq == seq0 + 16'h1);
    cases++;

    // ---- case 2: fence clear ---------------------------------------------
    fclr[0] = 1'b1;
    @(negedge clk); fclr[0] = 1'b0;
    @(negedge clk);
    check("fence cleared", fsig[0] === 1'b0 && flost[0] === 1'b0);
    cases++;

    // ---- case 3: stale record handle -> DEVICE_LOST ----------------------
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[1], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[1], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, buf0_h + 32'h10000,
                APU_VN_KIND_VK_BUFFER, 0));
    cr_op(APU_CMDREC_OP_END, cbd[1], 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      submit(5'd1, 1, cbd[1], cb_h, 32'h0, 32'h0);
      wait_fence(1, 4000);
      check("stale lost", flost[1] === 1'b1);
      check("stale no work", work_i == w0);
      cases++;
    end

    // ---- case 4: unsealed buffer -> DEVICE_LOST ---------------------------
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[2], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[2], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, 0, 0, 1));
    tb_drv = 1'b0;   // buffer left unsealed
    begin
      int w0 = work_i;
      submit(5'd2, 1, cbd[2], cb_h, 32'h0, 32'h0);
      wait_fence(2, 4000);
      check("unsealed lost", flost[2] === 1'b1);
      check("unsealed no work", work_i == w0);
      cases++;
    end

    // ---- case 5: two buffers in one submit -------------------------------
    // (DRAW_EXT would now gate on a bound graphics pipeline + active
    // attachment; RESOLVE_IMAGE stays a plain work record)
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[3], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[3], 0,
          mkrec(APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT, 0, 0, 4));
    cr_op(APU_CMDREC_OP_END, cbd[3], 0, '0);
    cr_op(APU_CMDREC_OP_BEGIN, cbd[4], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[4], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, 0, 0, 2));
    cr_op(APU_CMDREC_OP_END, cbd[4], 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      submit(5'd3, 2, cbd[3], cb_h, cbd[4], cb_h);
      wait_fence(3, 4000);
      check("two-buf work", work_i == w0 + 2);
      check("buf order0",
            got_work[w0] == APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT);
      check("buf order1",
            got_work[w0 + 1] == APU_VN_TYPE_VK_CMD_DISPATCH_EXT);
      check("two-buf ok", flost[3] === 1'b0);
      cases++;
    end

    // ---- case 6: unpin after completion ----------------------------------
    tb_drv = 1'b1;
    ot_op(APU_OBJTAB_OP_LOOKUP, {32'h0, cb_h},
          APU_VN_KIND_VK_COMMAND_BUFFER);
    check("cb unpinned", ot_cpl.status == APU_OBJTAB_OK &&
                         ot_cpl.entry.pins == 8'h0);
    tb_drv = 1'b0;
    cases++;

    // ---- case 7: §7b BindDS payload walk + push-constant state ------------
    // Two payload records share the buffer's pay arena: BindDS lands at
    // base 0 (imm[7]=0), PushConstants at base 2 (imm[7]=2).
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[5], 0, '0);
    begin
      // §12.3 F5 stream: {handle,ndyn} pairs then the call's
      // dynamic-offset words — 2 sets x 2 + 2 dyn = 6 words
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT, 0, 0, 0);
      rr.imm[1] = 32'd1;   // firstSet
      rr.imm[2] = 32'd2;   // descriptorSetCount
      rr.imm[3] = 32'd2;   // dynamicOffsetCount
      cr_op(APU_CMDREC_OP_APPEND, cbd[5], 0, rr, 16'd6);
    end
    begin
      apu_cmdrec_rec_t pr = mkrec(
          APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT, 0, 0, 0);
      pr.imm[0] = 32'hAB;  // stageFlags
      pr.imm[2] = 32'd8;   // size bytes
      pay_magic = 32'hFEED_0000;
      cr_op(APU_CMDREC_OP_APPEND, cbd[5], 0, pr, 16'd2);
      pay_magic = 32'hCAFE_0000;
    end
    // §7b/5a-ii: a DISPATCH here would enter the full descriptor
    // assembly (the CAFE dset handles resolve to nothing) and a DRAW
    // now loses the submission without a bound graphics pipeline +
    // attachment; probe the snap through a plain work record instead.
    // Dispatch assembly itself is covered end-to-end in
    // tb_g6lc_apu_vgtop.
    cr_op(APU_CMDREC_OP_APPEND, cbd[5], 0,
          mkrec(APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT, 0, 0, 32'h4));
    cr_op(APU_CMDREC_OP_END, cbd[5], 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      submit(5'd4, 1, cbd[5], cb_h, 32'h0, 32'h0);
      wait_fence(4, 4000);
      check("bindds work", work_i == w0 + 1);
      // streamed pay words are CAFE_0000+i; F5 pairs then dyn words:
      // {hnd0,ndyn0=1,hnd1,ndyn1=3,dyn,dyn} -> dset[1]=0000,
      // dset[2]=0002, dyn[1][0]=0004, dyn[2][0]=0005 (set 2 asked 3,
      // one word left before the stream ends)
      check("dset1", got_snap[w0].dset[1] === 32'hCAFE0000);
      check("dset2", got_snap[w0].dset[2] === 32'hCAFE0002);
      check("dyn1_0", got_snap[w0].dyn[1][0] === 32'hCAFE0004);
      check("dyn2_0", got_snap[w0].dyn[2][0] === 32'hCAFE0005);
      // §5a G3b-iii: push_base is the absolute PayMem word address of
      // the record's payload — the FEED stream must sit there
      check("push_base",
            got_snap[w0].push_base !== 32'h0 &&
            paymem[got_snap[w0].push_base[14:0]] === 32'hFEED_0000 &&
            paymem[got_snap[w0].push_base[14:0] + 1] === 32'hFEED_0001);
      check("push_len",  got_snap[w0].push_len === 16'd8);
      check("bindds no lost", flost[4] === 1'b0);
      cases++;
    end

    // ---- case 8: vnfront failed-submit fence pulse -----------------------
    // §7b exception contract: when vnfront rejects a submit that
    // carried a fence it pulses fence_fail_i; the slot goes
    // signaled+lost immediately so the guest's fence wait returns
    // DEVICE_LOST instead of hanging on an unarmed fence
    ffail[5] = 1'b1;
    @(negedge clk); ffail[5] = 1'b0;
    @(negedge clk);
    check("fail signaled", fsig[5] === 1'b1 && flost[5] === 1'b1);
    fclr[5] = 1'b1;
    @(negedge clk); fclr[5] = 1'b0;
    @(negedge clk);
    check("fail cleared", fsig[5] === 1'b0 && flost[5] === 1'b0);
    cases++;

    // ---- case 9: exec-time fault, second CB still runs --------------------
    // §7b exception contract (2026-10-16): a work item that completes
    // with DONE_FAULT retires with undefined results and the executor
    // continues — the remaining buffer executes, the fence signals
    // normally (no DEVICE_LOST), and the context's sticky fault
    // register counts the fault.
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[6], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[6], 0,
          mkrec(APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT, 0, 0, 32'h8));
    cr_op(APU_CMDREC_OP_END, cbd[6], 0, '0);
    cr_op(APU_CMDREC_OP_BEGIN, cbd[7], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[7], 0,
          mkrec(APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT, 0, 0, 32'h9));
    cr_op(APU_CMDREC_OP_END, cbd[7], 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      fault_at = work_i;       // first work of this submit faults
      submit(5'd6, 2, cbd[6], cb_h, cbd[7], cb_h);
      wait_fence(6, 4000);
      check("fault cont work", work_i == w0 + 2);
      check("fault cont ok", flost[6] === 1'b0);
      check("fault reg cnt",
            i_dut.gen_on.fault_q[0][63:48] === 16'h0001);
      check("fault reg code",
            i_dut.gen_on.fault_q[0][39:32] === 8'(APU_SH_DONE_FAULT));
      check("fault reg pc/wave",
            i_dut.gen_on.fault_q[0][31:0] === 32'h007C_0005);
      check("fault reg wid",
            i_dut.gen_on.fault_q[0][47:40] === 8'h02);
      cases++;
    end

    // ---- case 10: late completion still unpins (A1) --------------------
    // Pins must not outlive a submission: pend_hold starves the done
    // model so the dispatch's completion lands well after issue (the
    // record's own StDsDone wait holds).  The pop->unpq->StUnpD drain
    // must still release the slot before StDone — a stranded bundle
    // pins the slot forever and a later module-create FILL starves on
    // an all-pinned victim set (StShFillC -> StSmReq livelock).  After
    // the fence every slot must be unpinned.
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[10], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[10], 0,
          mkrec(APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT, pipe_h,
                APU_VN_KIND_VK_PIPELINE, 0));
    cr_op(APU_CMDREC_OP_APPEND, cbd[10], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, 0, 0, 32'h8));
    cr_op(APU_CMDREC_OP_END, cbd[10], 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      int pins = 0;
      pend_hold = 1'b1;          // no dones — the walk parks in FinalDrain
      submit(5'd9, 1, cbd[10], cb_h, 32'h0, 32'h0);
      repeat (600) @(negedge clk);
      for (int i = 0; i < 8; i++) pins += m_rs_pin[i];
      check("fd work issued", work_i == w0 + 1);
      check("fd pin held", pins == 1);
      pend_hold = 1'b0;          // the done now lands inside FinalDrain
      wait_fence(9, 8000);
      pins = 0;
      for (int i = 0; i < 8; i++) pins += m_rs_pin[i];
      check("fd pins drained", pins == 0);
      check("fd no lost", flost[9] === 1'b0);
      cases++;
    end

    // ---- case 11: FS fill fault releases the VS pin (A2) ----------------
    // Draw whose FS module FILL faults after the VS resolve already
    // pinned its slot: the VS pin is not riding pinq (the draw never
    // issued work) and must be released by the fault path.  Minimal
    // rp/fb scaffolding gives the draw an active attachment.
    tb_drv = 1'b1;
    // graphics pipeline: aux[6] = graphics bit, aux[31:16] = ObjPay
    // block chunk 52; module handles live at w44..47
    ot_op(APU_OBJTAB_OP_LOOKUP, 64'h1000_0000_0000_0007,
          APU_VN_KIND_VK_PIPELINE_LAYOUT);
    lay_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0035,
          APU_VN_KIND_VK_PIPELINE);
    gpipe_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0035,
          APU_VN_KIND_VK_PIPELINE,
          .mask(32'hFFFF_FFFF), .value(lay_h));
    ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0035,
          APU_VN_KIND_VK_PIPELINE,
          .mask(32'hFFFF_FFFF), .value({16'd52, 9'h0, 1'b1, 6'h0}));
    // {VS handle, VS {chunk,words}, FS handle, FS {chunk,words}}
    paymem[(52 << 6) + 44] = 32'h0001_00A1;
    paymem[(52 << 6) + 45] = {16'd61, 16'd96};
    paymem[(52 << 6) + 46] = 32'h0001_00B2;
    paymem[(52 << 6) + 47] = {16'd62, 16'd96};
    // image + view + rp + fb for one colour attachment
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0010,
          APU_VN_KIND_VK_IMAGE, .size(64'd4096));
    img_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0010,
          APU_VN_KIND_VK_IMAGE,
          .mask(32'hFFFF_FFFF), .value(32'h0040_0040));   // {h,w}
    ot_op(APU_OBJTAB_OP_SETBIND, 64'h1000_0000_0000_0010,
          APU_VN_KIND_VK_IMAGE,
          .mem_id(64'h1000_0000_0000_0006));
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h0000_0002_0000_0030,
          APU_VN_KIND_VK_IMAGE_VIEW);
    view_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUX, 64'h0000_0002_0000_0030,
          APU_VN_KIND_VK_IMAGE_VIEW,
          .mask(32'h0000_FFFF), .value({16'h0, img_h[15:0]}));
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0033,
          APU_VN_KIND_VK_RENDER_PASS);
    rp_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0033,
          APU_VN_KIND_VK_RENDER_PASS,
          .mask(32'hFFFF_FFFF), .value({16'd50, 16'd7}));
    // rp block: 1 attachment {fmt,loadOp=LOAD,storeOp}, 1 subpass,
    // colour ref -> att 0, no depth word (words = 7)
    paymem[(50 << 6) + 0] = 32'd1;
    paymem[(50 << 6) + 1] = 32'h0;
    paymem[(50 << 6) + 2] = 32'h0;
    paymem[(50 << 6) + 3] = 32'h0;
    paymem[(50 << 6) + 4] = 32'd1;
    paymem[(50 << 6) + 5] = 32'd1;
    paymem[(50 << 6) + 6] = 32'd0;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0034,
          APU_VN_KIND_VK_FRAMEBUFFER);
    fb_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0034,
          APU_VN_KIND_VK_FRAMEBUFFER,
          .mask(32'hFFFF_FFFF), .value({16'd51, 16'd8}));
    // fb block: {rp id 2w, attachmentCount, view id 2w, w, h, layers}
    paymem[(51 << 6) + 0] = 32'h0000_0033;
    paymem[(51 << 6) + 1] = 32'h1000_0000;
    paymem[(51 << 6) + 2] = 32'd1;
    paymem[(51 << 6) + 3] = 32'h0000_0030;
    paymem[(51 << 6) + 4] = 32'h0000_0002;
    paymem[(51 << 6) + 5] = 32'd64;
    paymem[(51 << 6) + 6] = 32'd64;
    paymem[(51 << 6) + 7] = 32'd1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[11], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[11], 0,
          mkrec(APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT, gpipe_h,
                APU_VN_KIND_VK_PIPELINE, 0));
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT, rp_h,
          APU_VN_KIND_VK_RENDER_PASS, 0);
      rr.handle[1] = fb_h; rr.kind[1] = APU_VN_KIND_VK_FRAMEBUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[11], 0, rr, 16'd1);
    end
    cr_op(APU_CMDREC_OP_APPEND, cbd[11], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DRAW_EXT, 0, 0, 32'd3));
    cr_op(APU_CMDREC_OP_APPEND, cbd[11], 0,
          mkrec(APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_END, cbd[11], 0, '0);
    tb_drv = 1'b0;
    begin
      int pins = 0;
      m_fill_fault_at = m_fill_i + 1;   // the second FILL (FS) faults
      submit(5'd10, 1, cbd[11], cb_h, 32'h0, 32'h0);
      wait_fence(10, 8000);
      for (int i = 0; i < 8; i++) pins += m_rs_pin[i];
      check("fsflt pins drained", pins == 0);
      check("fsflt no lost", flost[10] === 1'b0);
      check("fsflt fault cnt",
            i_dut.gen_on.fault_q[0][63:48] === 16'h0002);
      // resolve-fault word: {count16, rec_i16, code8, pad24}
      check("fsflt fault code",
            i_dut.gen_on.fault_q[0][31:24] === 8'h11);
      cases++;
    end

    // ---- case 12: multi-subpass render pass --------------------------
    // rp2 ObjPay carries subpassCount=2 with depth-free {C,refs}
    // blocks: subpass0 -> att0 (img 64x64), subpass1 -> att1 (img2
    // 32x32).  Begin snapshots ca[0]=att0's image; NEXT_SUBPASS
    // re-snapshots ca[0]=att1's image; the pass completes cleanly.
    // A NEXT_SUBPASS past the last subpass and a draw inside subpass 1
    // both lose the submission (pipeline-subpass admission is not
    // wired yet, so draws are subpass-0 only).
    tb_drv = 1'b1;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0011,
          APU_VN_KIND_VK_IMAGE, .size(64'd4096));
    img2_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0011,
          APU_VN_KIND_VK_IMAGE,
          .mask(32'hFFFF_FFFF), .value(32'h0020_0020));   // {h,w}=32
    ot_op(APU_OBJTAB_OP_SETBIND, 64'h1000_0000_0000_0011,
          APU_VN_KIND_VK_IMAGE,
          .mem_id(64'h1000_0000_0000_0006));
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h0000_0003_0000_0071,
          APU_VN_KIND_VK_IMAGE_VIEW);
    view2_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUX, 64'h0000_0003_0000_0071,
          APU_VN_KIND_VK_IMAGE_VIEW,
          .mask(32'h0000_FFFF), .value({16'h0, img2_h[15:0]}));
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0040,
          APU_VN_KIND_VK_RENDER_PASS);
    rp2_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0040,
          APU_VN_KIND_VK_RENDER_PASS,
          .mask(32'hFFFF_FFFF), .value({16'd54, 16'd12}));
    // rp2 block @54: attCount=2, two {fmt,loadOp=LOAD,storeOp} rows,
    // subpassCount=2, {C=1,ref->0},{C=1,ref->1} — 12 words, depth-free
    paymem[(54 << 6) + 0] = 32'd2;
    paymem[(54 << 6) + 1] = 32'h0;
    paymem[(54 << 6) + 2] = 32'h0;
    paymem[(54 << 6) + 3] = 32'h0;
    paymem[(54 << 6) + 4] = 32'h0;
    paymem[(54 << 6) + 5] = 32'h0;
    paymem[(54 << 6) + 6] = 32'h0;
    paymem[(54 << 6) + 7] = 32'd2;
    paymem[(54 << 6) + 8] = 32'd1;
    paymem[(54 << 6) + 9] = 32'd0;
    paymem[(54 << 6) +10] = 32'd1;
    paymem[(54 << 6) +11] = 32'd1;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0041,
          APU_VN_KIND_VK_FRAMEBUFFER);
    fb2_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0041,
          APU_VN_KIND_VK_FRAMEBUFFER,
          .mask(32'hFFFF_FFFF), .value({16'd55, 16'd10}));
    // fb2 block @55: {rp id 2w, count=2, view0 2w, view1 2w, w,h,l}
    paymem[(55 << 6) + 0] = 32'h0000_0040;
    paymem[(55 << 6) + 1] = 32'h1000_0000;
    paymem[(55 << 6) + 2] = 32'd2;
    paymem[(55 << 6) + 3] = 32'h0000_0030;
    paymem[(55 << 6) + 4] = 32'h0000_0002;
    paymem[(55 << 6) + 5] = 32'h0000_0071;
    paymem[(55 << 6) + 6] = 32'h0000_0003;
    paymem[(55 << 6) + 7] = 32'd64;
    paymem[(55 << 6) + 8] = 32'd64;
    paymem[(55 << 6) + 9] = 32'd1;
    // S_A: Begin+End only — subpass 0 snapshot binds att0's image
    cr_op(APU_CMDREC_OP_BEGIN, cbd[12], 0, '0);
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT, rp2_h,
          APU_VN_KIND_VK_RENDER_PASS, 0);
      rr.handle[1] = fb2_h; rr.kind[1] = APU_VN_KIND_VK_FRAMEBUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[12], 0, rr, 16'd1);
    end
    cr_op(APU_CMDREC_OP_APPEND, cbd[12], 0,
          mkrec(APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_END, cbd[12], 0, '0);
    tb_drv = 1'b0;
    begin
      submit(5'd11, 1, cbd[12], cb_h, 32'h0, 32'h0);
      wait_fence(11, 8000);
      check("mspa no lost", flost[11] === 1'b0);
      check("mspa subpass0", i_dut.gen_on.snap_q.subpass === 4'd0);
      check("mspa ca w64", i_dut.gen_on.ca_q[0].w === 16'd64);
      check("mspa ca valid", i_dut.gen_on.ca_valid_q[0] === 1'b1);
    end
    // S_B: Begin+NextSubpass+End — the snapshot re-binds att1's image
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[13], 0, '0);
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT, rp2_h,
          APU_VN_KIND_VK_RENDER_PASS, 0);
      rr.handle[1] = fb2_h; rr.kind[1] = APU_VN_KIND_VK_FRAMEBUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[13], 0, rr, 16'd1);
    end
    cr_op(APU_CMDREC_OP_APPEND, cbd[13], 0,
          mkrec(APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_APPEND, cbd[13], 0,
          mkrec(APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_END, cbd[13], 0, '0);
    tb_drv = 1'b0;
    begin
      submit(5'd12, 1, cbd[13], cb_h, 32'h0, 32'h0);
      wait_fence(12, 8000);
      check("mspb no lost", flost[12] === 1'b0);
      check("mspb subpass1", i_dut.gen_on.snap_q.subpass === 4'd1);
      check("mspb ca w32", i_dut.gen_on.ca_q[0].w === 16'd32);
      check("mspb ca valid", i_dut.gen_on.ca_valid_q[0] === 1'b1);
    end
    // S_C: a second NEXT_SUBPASS is past the last subpass -> lost
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[14], 0, '0);
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT, rp2_h,
          APU_VN_KIND_VK_RENDER_PASS, 0);
      rr.handle[1] = fb2_h; rr.kind[1] = APU_VN_KIND_VK_FRAMEBUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[14], 0, rr, 16'd1);
    end
    cr_op(APU_CMDREC_OP_APPEND, cbd[14], 0,
          mkrec(APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_APPEND, cbd[14], 0,
          mkrec(APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_APPEND, cbd[14], 0,
          mkrec(APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_END, cbd[14], 0, '0);
    tb_drv = 1'b0;
    begin
      submit(5'd13, 1, cbd[14], cb_h, 32'h0, 32'h0);
      wait_fence(13, 8000);
      check("mspc fence lost", flost[13] === 1'b1);
    end
    // S_D: a draw inside subpass 1 loses — gpipe_h declares subpass 0
    // (aux[9:8]=0) and StDsPipeCpl requires it to equal the active
    // subpass, so the mismatch loses the submission
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[15], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[15], 0,
          mkrec(APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT, gpipe_h,
                APU_VN_KIND_VK_PIPELINE, 0));
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT, rp2_h,
          APU_VN_KIND_VK_RENDER_PASS, 0);
      rr.handle[1] = fb2_h; rr.kind[1] = APU_VN_KIND_VK_FRAMEBUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[15], 0, rr, 16'd1);
    end
    cr_op(APU_CMDREC_OP_APPEND, cbd[15], 0,
          mkrec(APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_APPEND, cbd[15], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DRAW_EXT, 0, 0, 32'd3));
    cr_op(APU_CMDREC_OP_APPEND, cbd[15], 0,
          mkrec(APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_END, cbd[15], 0, '0);
    tb_drv = 1'b0;
    begin
      submit(5'd14, 1, cbd[15], cb_h, 32'h0, 32'h0);
      wait_fence(14, 8000);
      check("mspd fence lost", flost[14] === 1'b1);
      cases++;
    end
    // S_E/S_F: pipeline-subpass admission — gpipe1_h shares gpipe_h's
    // ObjPay block (chunk 52, same module words) but declares
    // subpass 1 in aux[9:8].  A draw in subpass 1 matches and runs;
    // the same pipeline in subpass 0 mismatches and loses.
    tb_drv = 1'b1;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0036,
          APU_VN_KIND_VK_PIPELINE);
    gpipe1_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0036,
          APU_VN_KIND_VK_PIPELINE,
          .mask(32'hFFFF_FFFF), .value(lay_h));
    ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0036,
          APU_VN_KIND_VK_PIPELINE,
          .mask(32'hFFFF_FFFF),
          .value({16'd52, 6'h0, 2'd1, 1'h0, 1'b1, 6'h0}));
    // S_E: Begin+Bind(gpipe1)+NextSubpass+Draw+End — subpass 1 ==
    // aux[9:8] so the draw assembles and the submission completes
    cr_op(APU_CMDREC_OP_BEGIN, cbd[16], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[16], 0,
          mkrec(APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT, gpipe1_h,
                APU_VN_KIND_VK_PIPELINE, 0));
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT, rp2_h,
          APU_VN_KIND_VK_RENDER_PASS, 0);
      rr.handle[1] = fb2_h; rr.kind[1] = APU_VN_KIND_VK_FRAMEBUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[16], 0, rr, 16'd1);
    end
    cr_op(APU_CMDREC_OP_APPEND, cbd[16], 0,
          mkrec(APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_APPEND, cbd[16], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DRAW_EXT, 0, 0, 32'd3));
    cr_op(APU_CMDREC_OP_APPEND, cbd[16], 0,
          mkrec(APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_END, cbd[16], 0, '0);
    // S_F: same pipeline in subpass 0 — aux[9:8]=1 != snap 0 -> lost
    cr_op(APU_CMDREC_OP_BEGIN, cbd[17], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[17], 0,
          mkrec(APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT, gpipe1_h,
                APU_VN_KIND_VK_PIPELINE, 0));
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT, rp2_h,
          APU_VN_KIND_VK_RENDER_PASS, 0);
      rr.handle[1] = fb2_h; rr.kind[1] = APU_VN_KIND_VK_FRAMEBUFFER;
      cr_op(APU_CMDREC_OP_APPEND, cbd[17], 0, rr, 16'd1);
    end
    cr_op(APU_CMDREC_OP_APPEND, cbd[17], 0,
          mkrec(APU_VN_TYPE_VK_CMD_DRAW_EXT, 0, 0, 32'd3));
    cr_op(APU_CMDREC_OP_APPEND, cbd[17], 0,
          mkrec(APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT, 0, 0, 0));
    cr_op(APU_CMDREC_OP_END, cbd[17], 0, '0);
    tb_drv = 1'b0;
    begin
      submit(5'd15, 1, cbd[16], cb_h, 32'h0, 32'h0);
      wait_fence(15, 8000);
      check("mspe no lost", flost[15] === 1'b0);
      check("mspe subpass1", i_dut.gen_on.snap_q.subpass === 4'd1);
      check("mspe ca w32", i_dut.gen_on.ca_q[0].w === 16'd32);
      // fence 15 is sticky: clear it before the mismatch submission
      // reuses the slot so wait_fence observes the new signal
      @(negedge clk); fclr[15] = 1'b1; @(negedge clk); fclr[15] = 1'b0;
      submit(5'd15, 1, cbd[17], cb_h, 32'h0, 32'h0);
      wait_fence(15, 8000);
      check("mspf fence lost", flost[15] === 1'b1);
      cases++;
    end

    // ---- §3a case: query pool WRITE_TIMESTAMP ---------------------------
    // Runs before case 13 (watchdog device-death): a dead device rejects
    // new ObjTab ALLOCs, so the pools must be created while the device is
    // still live.  timestamp pool (type 2): WRITE_TIMESTAMP stores
    // avail=1 + honest-0 counter at slot {QRY_EXT + q*16}.  The xop model
    // lands executor ObjPay WRITEs in paymem so the slot is observable.
    begin
      apu_cmdrec_rec_t wq;
      tb_drv = 1'b1;
      // result extent = QRY_EXT word base; aux[63:48]=QRY_EXT>>6 chunk,
      // aux[31:8]=stats mask, aux[7:0]=type (0 occ, 1 stats, 2 ts)
      ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0050,
            APU_VN_KIND_VK_QUERY_POOL, .size(64'd4));
      qry_h = ot_cpl.handle;
      ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0050,
            APU_VN_KIND_VK_QUERY_POOL, .mask(32'hFFFF_FFFF), .value(32'h2));
      ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0050,
            APU_VN_KIND_VK_QUERY_POOL,
            .mask(32'hFFFF_FFFF),
            .value(32'(QRY_EXT >> 6) << 16));
      // occlusion pool (type 0, one counter) for BEGIN/END
      ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0051,
            APU_VN_KIND_VK_QUERY_POOL, .size(64'd4));
      qry2_h = ot_cpl.handle;
      ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0051,
            APU_VN_KIND_VK_QUERY_POOL, .mask(32'hFFFF_FFFF), .value(32'h0));
      ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0051,
            APU_VN_KIND_VK_QUERY_POOL,
            .mask(32'hFFFF_FFFF),
            .value(32'(QRY_EXT >> 6) << 16));
      // statistics pool (type 1) — aux[31:8]=stat mask {0,1}={ia_vtx,
      // ia_prim} for a two-counter spec-ordered BEGIN/END delta
      ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0052,
            APU_VN_KIND_VK_QUERY_POOL, .size(64'd4));
      qry3_h = ot_cpl.handle;
      ot_op(APU_OBJTAB_OP_SETAUX, 64'h1000_0000_0000_0052,
            APU_VN_KIND_VK_QUERY_POOL, .mask(32'hFFFF_FFFF),
            .value(32'h0000_0301));   // type=1, stats mask bits{0,1}
      ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0052,
            APU_VN_KIND_VK_QUERY_POOL,
            .mask(32'hFFFF_FFFF),
            .value(32'(QRY_EXT >> 6) << 16));
      check("alloc query pools", qry_h !== '0 && qry2_h !== '0 &&
                                   qry3_h !== '0);
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_WRITE_TIMESTAMP_EXT, qry_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'h0);
      wq.imm[1] = 32'd2;               // query index
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      // clear fence 0 so wait_fence observes this submission's signal
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      // query 2 slot: word0 avail=1, word1 counter=0
      check("ts avail",   paymem[QRY_EXT + 2*16 + 0] == 32'h1);
      check("ts counter", paymem[QRY_EXT + 2*16 + 1] == 32'h0);
      check("ts no lost", flost[0] === 1'b0);
      cases++;

      // ---- RESET_QUERY_POOL: clears availability over [first,+count) --
      // ts pool q2 was just stamped avail=1; RESET(first=2,count=1)
      // rewrites word0=0 for exactly that slot.
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[19], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_RESET_QUERY_POOL_EXT, qry_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd2);   // firstQuery=2
      wq.imm[1] = 32'd1;                              // queryCount=1
      cr_op(APU_CMDREC_OP_APPEND, cbd[19], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[19], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[19], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("rst avail clr", paymem[QRY_EXT + 2*16 + 0] == 32'h0);
      check("rst no lost",   flost[0] === 1'b0);
      cases++;

      // ---- WRITE_TIMESTAMP_2: query at imm[0], stageFlags at imm[1] ----
      // TS2 shares the timestamp write path (qry_op_q=1) but packs the
      // query index at imm[0] and a stageFlags scalar at imm[1]; imm[2:7]
      // must stay zero (qspare_bad).  Verifies slot targeting on an
      // untouched query (index 1): avail=1 + honest-0 counter.
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[19], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_WRITE_TIMESTAMP_2_EXT, qry_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'h0);
      wq.imm[0] = 32'd1;                   // query index (TS2: imm[0])
      wq.imm[1] = 32'h5;                   // stageFlags (used operand)
      cr_op(APU_CMDREC_OP_APPEND, cbd[19], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[19], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[19], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("ts2 avail",   paymem[QRY_EXT + 1*16 + 0] == 32'h1);
      check("ts2 counter", paymem[QRY_EXT + 1*16 + 1] == 32'h0);
      check("ts2 no lost", flost[0] === 1'b0);
      cases++;

      // ---- BEGIN/END_QUERY on the timestamp pool (type 2) --------------
      // Degenerate path: aux[7:0]==2 reduces both ops to a QueryStamp —
      // avail=1 + honest-0 counter at imm[0], flags/imm[1] must be 0, and
      // no open-table entry is taken (matches the model's unconditional
      // stamp).  BEGIN stamps query 0; END stamps query 3 without a prior
      // BEGIN (timestamp END needs no open state).
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[19], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT, qry_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd0);   // query index 0
      wq.imm[1] = 32'd0;                               // flags = 0
      cr_op(APU_CMDREC_OP_APPEND, cbd[19], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[19], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[19], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("tsbeg avail",   paymem[QRY_EXT + 0*16 + 0] == 32'h1);
      check("tsbeg counter", paymem[QRY_EXT + 0*16 + 1] == 32'h0);
      check("tsbeg no lost", flost[0] === 1'b0);
      cases++;
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[19], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_END_QUERY_EXT, qry_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd3);   // query index 3
      wq.imm[1] = 32'd0;                               // imm[1] must be 0
      cr_op(APU_CMDREC_OP_APPEND, cbd[19], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[19], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[19], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("tsend avail",   paymem[QRY_EXT + 3*16 + 0] == 32'h1);
      check("tsend counter", paymem[QRY_EXT + 3*16 + 1] == 32'h0);
      check("tsend no lost", flost[0] === 1'b0);
      cases++;
      // BEGIN on a timestamp pool with flags!=0 must be rejected — the
      // aux[7:0]==2 branch requires qry_n_q(=imm[1])==0.
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[19], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT, qry_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd1);   // query index 1
      wq.imm[1] = 32'd1;                               // flags = 1 -> lost
      cr_op(APU_CMDREC_OP_APPEND, cbd[19], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[19], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[19], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("tsbeg bad flags lost", flost[0] === 1'b1);
      cases++;

      // ---- BEGIN/END_QUERY on the occlusion pool (type 0) ---------------
      // Open-table + drain-then-delta: BEGIN snapshots qry_stat_i, END
      // differences the drained counters and writes avail + occ delta.
      // Drive qstat_drv occ field [95:64] 100 -> 200 across the two
      // submissions so the delta is a deterministic 100.
      //   qstat layout: {fs_inv[127:96], occ[95:64], ia_prim[63:32],
      //                  ia_vtx[31:0]}
      qstat_drv = {32'h0, 32'h64, 32'h0, 32'h0};   // occ = 100
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd3);  // query index 3
      wq.imm[1] = 32'd0;                             // flags = 0
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("beg no lost", flost[0] === 1'b0);
      // advance the occlusion counter, then close the query
      qstat_drv = {32'h0, 32'hC8, 32'h0, 32'h0};   // occ = 200
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[19], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_END_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd3);
      // imm[1] already 0 (required for END)
      cr_op(APU_CMDREC_OP_APPEND, cbd[19], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[19], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[19], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      // occ-pool q3 slot: word0 avail=1, word1 = occ delta = 200-100
      check("end avail",  paymem[QRY_EXT + 3*16 + 0] == 32'h1);
      check("end occ dlt",paymem[QRY_EXT + 3*16 + 1] == 32'd100);
      check("end no lost",flost[0] === 1'b0);
      cases++;

      // ---- BEGIN/END_QUERY on the statistics pool (type 1) --------------
      // stats mask {0,1}={ia_vtx,ia_prim}: END packs two spec-ordered
      // deltas {vtx,prim} after avail.  Drive both counters 1000/500 ->
      // 1200/600 for deltas {200,100}.
      qstat_drv = {32'h0, 32'h0, 32'd500, 32'd1000};  // prim=500 vtx=1000
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT, qry3_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd1);   // stats q index 1
      wq.imm[1] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("sbeg no lost", flost[0] === 1'b0);
      qstat_drv = {32'h0, 32'h0, 32'd600, 32'd1200}; // prim=600 vtx=1200
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[19], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_END_QUERY_EXT, qry3_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd1);
      cr_op(APU_CMDREC_OP_APPEND, cbd[19], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[19], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[19], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      // stats-pool q1 slot: avail + {vtx_d=200, prim_d=100}
      check("send avail", paymem[QRY_EXT + 1*16 + 0] == 32'h1);
      check("send vtx d", paymem[QRY_EXT + 1*16 + 1] == 32'd200);
      check("send prm d", paymem[QRY_EXT + 1*16 + 2] == 32'd100);
      check("send no lost",flost[0] === 1'b0);
      cases++;

      // ---- COPY_QUERY_POOL_RESULTS on the occlusion pool --------------
      // q3 holds avail=1 + occ delta=100.  COPY(first=3,count=1,
      // flags=0x9 64_BIT|AVAILABILITY,dstOffset=0,stride=16) into buf0
      // (mem ...0060 aperture byte 0x8000 -> apm word 0x2000) must
      // emit [u64 counter=100][u64 avail=1] = 4 words.  SETBIND
      // carries the buffer's declared size like production vnfront
      // (entry.size feeds the extent check).
      tb_drv = 1'b1;
      ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0060,
            APU_VN_KIND_VK_DEVICE_MEMORY, .size(64'd1024));
      cp_mem_h = ot_cpl.handle;
      ot_op(APU_OBJTAB_OP_SETAUXHI, 64'h1000_0000_0000_0060,
            APU_VN_KIND_VK_DEVICE_MEMORY,
            .mask(32'hFFFF_FFFF), .value(CP_AP_MEM[31:0]));
      ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0061,
            APU_VN_KIND_VK_BUFFER, .size(64'd256));
      cp_buf_h = ot_cpl.handle;
      ot_op(APU_OBJTAB_OP_SETBIND, 64'h1000_0000_0000_0061,
            APU_VN_KIND_VK_BUFFER, .size(64'd256),
            .mem_id(64'h1000_0000_0000_0060));
      check("alloc copy dst", cp_mem_h !== '0 && cp_buf_h !== '0);
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry2_h, APU_VN_KIND_VK_QUERY_POOL, 32'd3); // first=3
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd1;      // queryCount
      wq.imm[2] = 32'h9;      // flags = 64_BIT | WITH_AVAILABILITY
      wq.imm[3] = 32'd0;      // dstOffset lo
      wq.imm[4] = 32'd0;      // dstOffset hi
      wq.imm[5] = 32'd16;     // stride
      wq.imm[6] = 32'd0;      // stride hi
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpy no lost", flost[0] === 1'b0);
      // aperture 0x8000 -> apm word 0x2000: {ctr=100,0, avail=1,0}
      check("cpy ctr lo",  i_emem.apm[32'h2000] == 32'd100);
      check("cpy ctr hi",  i_emem.apm[32'h2001] == 32'h0);
      check("cpy av lo",   i_emem.apm[32'h2002] == 32'd1);
      check("cpy av hi",   i_emem.apm[32'h2003] == 32'h0);
      cases++;
      qstat_drv = '0;

      // ---- COPY 32-bit records (flags=0x8 avail only) ----------------
      // occlusion q3 {avail=1,occ=100}: [ctr u32][avail u32] = 8B
      // record, stride=8 -> apm {ctr=100, avail=1}
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry2_h, APU_VN_KIND_VK_QUERY_POOL, 32'd3);
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd1; wq.imm[2] = 32'h8;    // count=1, AVAIL(32b)
      wq.imm[3] = 32'd0; wq.imm[4] = 32'd0;    // dstOffset=0
      wq.imm[5] = 32'd8;  wq.imm[6] = 32'd0;    // stride=8
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpy32 no lost", flost[0] === 1'b0);
      check("cpy32 ctr", i_emem.apm[32'h2000] == 32'd100);
      check("cpy32 av",  i_emem.apm[32'h2001] == 32'd1);
      cases++;

      // ---- COPY stride padding (flags=0x9 stride=32 > record 16) -----
      // pre-fill the pad words nonzero so the zero-pad writes are
      // observable; data {100,0,1,0} then four zero pad words
      i_emem.apm[32'h2004] = 32'hDEAD_BEEF;
      i_emem.apm[32'h2005] = 32'hDEAD_BEEF;
      i_emem.apm[32'h2006] = 32'hDEAD_BEEF;
      i_emem.apm[32'h2007] = 32'hDEAD_BEEF;
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry2_h, APU_VN_KIND_VK_QUERY_POOL, 32'd3);
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd1; wq.imm[2] = 32'h9;    // count=1, 64b+AVAIL
      wq.imm[3] = 32'd0; wq.imm[4] = 32'd0;    // dstOffset=0
      wq.imm[5] = 32'd32; wq.imm[6] = 32'd0;    // stride=32
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpypad no lost", flost[0] === 1'b0);
      check("cpypad ctr", i_emem.apm[32'h2000] == 32'd100);
      check("cpypad av",  i_emem.apm[32'h2002] == 32'd1);
      check("cpypad p0",  i_emem.apm[32'h2004] == 32'd0);
      check("cpypad p3",  i_emem.apm[32'h2007] == 32'd0);
      cases++;

      // ---- COPY loss: query range out of bounds (first=3,count=2) ----
      // pool size=4 -> 3+2=5 > 4 -> lost before any dst resolve
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry2_h, APU_VN_KIND_VK_QUERY_POOL, 32'd3); // first=3
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd2; wq.imm[2] = 32'h9;    // count=2, 64b+AVAIL
      wq.imm[3] = 32'd0; wq.imm[4] = 32'd0;
      wq.imm[5] = 32'd16; wq.imm[6] = 32'd0;    // stride=16
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpy range lost", flost[0] === 1'b1);
      cases++;

      // ---- COPY loss: stride < record (stride=4 < 16B record) --------
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry2_h, APU_VN_KIND_VK_QUERY_POOL, 32'd3);
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd1; wq.imm[2] = 32'h9;    // count=1, 64b+AVAIL
      wq.imm[3] = 32'd0; wq.imm[4] = 32'd0;
      wq.imm[5] = 32'd4;  wq.imm[6] = 32'd0;    // stride=4 < record
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpy stride lost", flost[0] === 1'b1);
      cases++;

      // ---- COPY statistics pool: two counters (nc=2) ------------------
      // qry3_h stats mask {0,1}={ia_vtx,ia_prim}; q1 slot holds
      // {avail=1, vtx_d=200, prim_d=100}.  COPY emits spec-order
      // [vtx][prim][avail].  64-bit: each value u64 -> 24B record.
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry3_h, APU_VN_KIND_VK_QUERY_POOL, 32'd1); // stats q1
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd1; wq.imm[2] = 32'h9;    // count=1, 64b+AVAIL
      wq.imm[3] = 32'd0; wq.imm[4] = 32'd0;    // dstOffset=0
      wq.imm[5] = 32'd24; wq.imm[6] = 32'd0;    // stride=24
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpyst no lost", flost[0] === 1'b0);
      check("cpyst vtx lo", i_emem.apm[32'h2000] == 32'd200);
      check("cpyst vtx hi", i_emem.apm[32'h2001] == 32'h0);
      check("cpyst prm lo", i_emem.apm[32'h2002] == 32'd100);
      check("cpyst prm hi", i_emem.apm[32'h2003] == 32'h0);
      check("cpyst av lo",  i_emem.apm[32'h2004] == 32'd1);
      check("cpyst av hi",  i_emem.apm[32'h2005] == 32'h0);
      cases++;

      // ---- COPY statistics pool, 32-bit packed (flags=0x8) ------------
      // record = [vtx u32][prim u32][avail u32] = 12B, stride=12,
      // dstOffset=64 -> apm word 0x2010
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry3_h, APU_VN_KIND_VK_QUERY_POOL, 32'd1);
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd1; wq.imm[2] = 32'h8;    // count=1, AVAIL(32b)
      wq.imm[3] = 32'd64; wq.imm[4] = 32'd0;    // dstOffset=64
      wq.imm[5] = 32'd12; wq.imm[6] = 32'd0;    // stride=12
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpyst32 no lost", flost[0] === 1'b0);
      check("cpyst32 vtx", i_emem.apm[32'h2010] == 32'd200);
      check("cpyst32 prm", i_emem.apm[32'h2011] == 32'd100);
      check("cpyst32 av",  i_emem.apm[32'h2012] == 32'd1);
      cases++;

      // ---- COPY count=2: exercises the query-iteration loop ------------
      // first=2,count=2 on the occ pool -> q2 (never written, zero slot)
      // then q3 {avail=1,occ=100}.  64-bit stride=16 packs two 16B
      // records: q2 {0,0,0,0} at 0x2000, q3 {100,0,1,0} at 0x2004.
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_COPY_QUERY_POOL_RESULTS_EXT,
                 qry2_h, APU_VN_KIND_VK_QUERY_POOL, 32'd2); // first=2
      wq.handle[1] = cp_buf_h; wq.kind[1] = APU_VN_KIND_VK_BUFFER;
      wq.imm[1] = 32'd2; wq.imm[2] = 32'h9;    // count=2, 64b+AVAIL
      wq.imm[3] = 32'd0; wq.imm[4] = 32'd0;    // dstOffset=0
      wq.imm[5] = 32'd16; wq.imm[6] = 32'd0;    // stride=16
      wq.imm[7] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("cpy2 no lost", flost[0] === 1'b0);
      check("cpy2 q2 ctr", i_emem.apm[32'h2000] == 32'h0);
      check("cpy2 q2 av",  i_emem.apm[32'h2002] == 32'h0);
      check("cpy2 q3 ctr", i_emem.apm[32'h2004] == 32'd100);
      check("cpy2 q3 av",  i_emem.apm[32'h2006] == 32'd1);
      cases++;

      // ---- query-op validation loss arms (each -> flost[0], recover) --
      // BEGIN_QUERY out-of-range: index 4 >= pool size 4
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd4);
      wq.imm[1] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qbeg range lost", flost[0] === 1'b1);
      cases++;

      // END_QUERY out-of-range: index 4 >= size 4
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_END_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd4);
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qend range lost", flost[0] === 1'b1);
      cases++;

      // BEGIN_QUERY flags=2 (>PRECISE=1) -> lost
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd0);
      wq.imm[1] = 32'd2;               // flags = 2 (invalid)
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qbeg flags lost", flost[0] === 1'b1);
      cases++;

      // END_QUERY imm[1]!=0 -> lost (END requires imm[1]==0)
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_END_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd3);
      wq.imm[1] = 32'd1;               // must be 0 for END
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qend imm lost", flost[0] === 1'b1);
      cases++;

      // END_QUERY on a query never opened (q0; only q3 was begun+ended)
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_END_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd0); // q0 never opened
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qend unopened lost", flost[0] === 1'b1);
      cases++;

      // WRITE_TIMESTAMP on an occlusion pool (type 0 != timestamp 2)
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_WRITE_TIMESTAMP_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd0); // occ pool, not ts
      wq.imm[1] = 32'd0;
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qts wrongpool lost", flost[0] === 1'b1);
      cases++;

      // BEGIN_QUERY (plain) with spare imm[2]!=0 -> spare-check lost
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT, qry2_h,
                 APU_VN_KIND_VK_QUERY_POOL, 32'd0);
      wq.imm[1] = 32'd0;
      wq.imm[2] = 32'd1;               // spare operand -> lost
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qbeg spare lost", flost[0] === 1'b1);
      cases++;

      // BEGIN_QUERY_INDEXED with index(imm[2])!=0 -> spare-check lost
      tb_drv = 1'b1;
      cr_op(APU_CMDREC_OP_BEGIN, cbd[18], 0, '0);
      wq = mkrec(APU_VN_TYPE_VK_CMD_BEGIN_QUERY_INDEXED_EXT_EXT,
                 qry2_h, APU_VN_KIND_VK_QUERY_POOL, 32'd0);
      wq.imm[1] = 32'd0;
      wq.imm[2] = 32'd1;               // index != 0 (multiview) -> lost
      cr_op(APU_CMDREC_OP_APPEND, cbd[18], 0, wq);
      cr_op(APU_CMDREC_OP_END, cbd[18], 0, '0);
      tb_drv = 1'b0;
      fclr[0] = 1'b1; @(negedge clk); fclr[0] = 1'b0; @(negedge clk);
      submit(5'd0, 1, cbd[18], cb_h, 32'h0, 32'h0);
      wait_fence(0, 8000);
      check("qbegidx lost", flost[0] === 1'b1);
      cases++;
    end

    // ---- case 13: watchdog expiry = true device loss ----------------------
    // The engine never returns: pend_hold starves the done model, the
    // work-budget watchdog expires, the submission retires lost,
    // devlost pulses (vnpump marks the ctx's rings FATAL), dead stays
    // set and a follow-on submission retires lost without issuing work
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, cbd[8], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[8], 0,
          mkrec(APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT, 0, 0, 32'hA));
    cr_op(APU_CMDREC_OP_END, cbd[8], 0, '0);
    cr_op(APU_CMDREC_OP_BEGIN, cbd[9], 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, cbd[9], 0,
          mkrec(APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT, 0, 0, 32'hB));
    cr_op(APU_CMDREC_OP_END, cbd[9], 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      int fault_cnt0 = i_dut.gen_on.fault_q[0][63:48];
      pend_hold = 1'b1;
      submit(5'd7, 1, cbd[8], cb_h, 32'h0, 32'h0);
      wait_fence(7, 8000);
      check("wd fence lost", flost[7] === 1'b1);
      check("wd devlost", dl_seen === 1'b1);
      check("wd dead", dl_dead === 1'b1);
      check("wd ctx", dl_ctx === 8'h00);
      // device dead: the next submission retires without issuing work
      seq0 = done_seq;
      submit(5'd8, 1, cbd[9], cb_h, 32'h0, 32'h0);
      wait_fence(8, 4000);
      check("dead fence lost", flost[8] === 1'b1);
      check("dead no work", work_i == w0 + 1);
      check("dead seq adv", done_seq == seq0 + 16'h1);
      // the fault register is NOT a device-loss record — unchanged
      check("wd no fault rec",
            i_dut.gen_on.fault_q[0][63:48] === 16'(fault_cnt0));
      pend_hold = 1'b0;
      cases++;
    end

    $display("PASS tb_g6lc_apu_cmdexec cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "cmdexec %0d errors", errors);
    $finish;
  end

  initial begin #120_000_000; $fatal(1, "cmdexec timeout"); end
endmodule
