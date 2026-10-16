// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Generational object table (§5a G3b-i "ObjTab-V"): driver 64-bit
// object ids -> generational handles {gen[15:0], entry[15:0]}.
//
// Storage moved out of the on-chip SRAMs of the original ObjTab and
// into device-private DRAM ("objmem") behind g6lc_apu_objmem:
//   - entries:    64-B records in objmem (entry cache in objmem)
//   - directory:  8-B open-addressed buckets in objmem, Fibonacci
//                 hash, linear probe capped at 32 (dir cache there)
//   - free slots: global free stack in objmem + bump allocator
//   - ctx list:   per-context doubly-linked live list through the
//                 entry records; heads in flops: MaxCtx heads plus
//                 one shared overflow head for ctx >= MaxCtx (a
//                 RESET_CTX on an overflow ctx walks the shared list
//                 and only kills its own ctx's entries)
//   - kind list:  one global doubly-linked list for the payload-
//                 carrying DEVICE_MEMORY kind (SCAN_OVL walks it)
//
// Semantics are IDENTICAL to the SRAM ObjTab on the ot_* port:
//   - ALLOC probes the directory for a live entry with the same id
//     (DUP), else claims the first tombstone/empty bucket found
//     within 32 probes (FULL if none) and pops a free entry (FULL if
//     none).  The entry's stored gen is incremented, skipping 0.
//     A non-zero parent_id must resolve live (PARENT_MISS); its
//     refcnt++ commits after the child entry.
//   - LOOKUP/PIN/UNPIN/RETIRE/SETSTATE/SETBIND resolve `id`: high
//     word non-zero -> directory id (MISS/KIND); high word zero ->
//     {gen,slot} handle (stale gen or dead entry -> GEN, then KIND).
//   - RETIRE refuses while pins!=0 (PINNED) or refcnt!=0
//     (BUSY_CHILDREN), else clears live (gen persists), unlinks both
//     lists, tombstones the directory row for id-addressed retires,
//     pushes the entry to the free stack, writes the entry line
//     back (OMT_EWB — the §5a write-back point) and decrements a
//     live parent's refcnt.
//   - RESET_CTX writes back all dirty entry lines (OMT_FLUSH — the
//     §5a point) then walks the context's ctx_next list: unpinned
//     entries of that ctx are retired (live parent's refcnt
//     decremented, SWEEP stream emitted per entry), everything else
//     stays linked; the pinned count returns in cpl.handle[15:0].
//     The walk is interruptible per entry — it only advances
//     between objmem round-trips and stalls on cpl_ready_i during
//     SWEEP emits.
//   - Lazy tombstoning lives in objmem's probe: rows whose entry is
//     dead, re-idd or epoch-stale are rewritten as tombstones.
//
// Timing impact: every op is serialized across objmem round-trips
// (DRAM latency); latency dominates throughput by design for the
// vnfront/cmdexec clients.  Widest cones: the link-patch field
// muxes and the SCAN_OVL overlap comparator.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; no SRAMs here (objmem owns them); Enable=0 elaborates
// no datapath; one completion per request.

module g6lc_apu_objtab
  import g6lc_apu_objtab_pkg::*;
#(
  parameter bit          Enable      = 1'b0,
  parameter int unsigned ObjEntries  = 65536,
  parameter int unsigned MaxCtx      = 32,
  // kind linked into the global SCAN_OVL list — must equal
  // g6lc_apu_vn_pkg::APU_VN_KIND_VK_DEVICE_MEMORY (kept a parameter
  // so this module needs no vn_pkg dependency)
  parameter int unsigned KindListKind = 8
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_objtab_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_objtab_cpl_t cpl_o,
  output logic [15:0]     live_o,
  // objmem service port
  output logic            omt_req_valid_o,
  input  logic            omt_req_ready_i,
  output apu_omt_req_t    omt_req_o,
  input  logic            omt_rsp_valid_i,
  input  apu_omt_rsp_t    omt_rsp_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o     = 1'b0;
    assign cpl_valid_o     = 1'b0;
    assign cpl_o           = '0;
    assign live_o          = '0;
    assign omt_req_valid_o = 1'b0;
    assign omt_req_o       = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i |
                    cpl_ready_i | omt_req_ready_i |
                    omt_rsp_valid_i | (|req_i) | (|omt_rsp_i);
  end else begin : gen_on
    localparam logic [15:0] LINK_NONE = 16'hFFFF;
    // ctx_head has MaxCtx direct heads plus one overflow head at
    // index MaxCtx shared by every ctx >= MaxCtx
    localparam int unsigned NHEAD = MaxCtx + 1;

    typedef enum logic [1:0] { ResOk, ResMiss, ResGen, ResKind } res_e;

    typedef enum logic [5:0] {
      StIdle,
      StOmReq, StOmWait,
      StResHEnt, StResFEnt,
      StAfter, StBindMemRes,
      // ALLOC
      StClmGot, StAllocPopPar, StAllocGen, StAllocGenRd,
      StAllocWrE, StAllocCtxDo, StAllocCtxRd, StAllocCtxWr,
      StAllocCtxHd, StAllocKindChk, StAllocKindRd, StAllocKindWr,
      StAllocKindHd, StAllocDWr, StAllocParChk, StAllocParW,
      // RETIRE
      StRetKindChk, StRetKill, StRetPush, StRetWb,
      StRetTomb, StRetParChk, StRetDone,
      // unlink subroutine (prev/next of a dying entry, one list)
      StUnlPr, StUnlPrW, StUnlNChk, StUnlNr, StUnlNrW,
      // parent refcnt update subroutine
      StParRd, StParWr,
      // list walk (RESET_CTX / RETIRE_KIDS / SCAN_OVL)
      StScanRdInit, StScanParInit,
      StScanRd, StScanCmp,
      StScanKeep, StScanKeepP, StScanKeepN,
      StScanKill, StScanPush, StScanKind, StScanPar,
      StScanEmitS, StScanEmit,
      StScanDone, StScanTail, StScanFin,
      StCpl
    } state_e;

    state_e state_q, res_ret_q, om_ret_q, unl_ret_q, par_ret_q;
    apu_objtab_req_t  req_q;
    apu_objtab_cpl_t  cpl_q;
    apu_omt_req_t     om_req_q;
    apu_omt_rsp_t     om_rsp_q;

    // resolve subroutine registers
    logic [63:0]        res_id_q;
    logic               res_knd_q;
    logic               res_nogen_q;
    res_e               res_st_q;
    logic [15:0]        res_slot_q;
    apu_objent_mem_t    res_rec_q;
    logic               res_hdl_q;

    // op working registers
    logic [15:0]        hit_slot_q;
    apu_objent_mem_t    wr_rec_q;
    logic [15:0]        wr_slot_q;
    apu_objent_mem_t    par_rec_q;
    logic [15:0]        par_slot_q;
    logic [31:0]        alloc_bucket_q;
    logic [15:0]        alloc_gen_q;
    // unlink subroutine
    apu_objent_mem_t    unl_rec_q;   // the dying entry's record
    logic               unl_kind_q;  // 0 = ctx list, 1 = kind list
    // list heads (MaxCtx direct + one overflow)
    logic [15:0]        ctx_head_q [NHEAD];
    logic [15:0]        mem_head_q;
    // ctx walk
    logic [15:0]        walk_q, walk_nxt_q;
    apu_objent_mem_t    walk_rec_q;
    logic [15:0]        keep_q;
    apu_objent_mem_t    keep_rec_q;
    logic               keep_v_q, head_set_q;
    logic               scan_kids_q;   // RETIRE_KIDS filter mode
    logic               scan_ovl_q;    // SCAN_OVL read-only mode
    logic [15:0]        rtk_slot_q;
    logic               rtk_par_q;
    apu_objent_mem_t    swe_rec_q;
    logic [15:0]        swe_slot_q;
    logic [15:0]        pinned_q;
    logic [15:0]        live_q;
    assign live_o = live_q;

    // ---- objmem request plumbing -----------------------------------------
    assign omt_req_valid_o = state_q == StOmReq;
    assign omt_req_o       = om_req_q;
    assign req_ready_o     = state_q == StIdle;
    assign cpl_valid_o     = state_q == StCpl || state_q == StScanEmit;
    assign cpl_o           = cpl_q;

    // ctx -> head index: ctx < MaxCtx -> ctx, else the shared
    // overflow head
    function automatic logic [$clog2(MaxCtx+1)-1:0] cidx(
        logic [7:0] ctx);
      return 32'(ctx) >= 32'(MaxCtx)
             ? $clog2(MaxCtx+1)'(MaxCtx)
             : $clog2(MaxCtx+1)'(ctx);
    endfunction

    task automatic om_call(
        input apu_omt_op_e op,
        input logic [63:0]  id,
        input logic [31:0]  bucket,
        input logic [15:0]  entry,
        input apu_objent_mem_t rec,
        input state_e       ret);
      om_req_q <= '{op: op, id: id, bucket: bucket, entry: entry,
                    rec: rec};
      om_ret_q <= ret;
      state_q  <= StOmReq;
    endtask

    task automatic res_start(
        input logic [63:0] id,
        input logic        hnd_en,
        input logic        knd_en,
        input logic        nogen,
        input state_e      ret);
      res_id_q    <= id;
      res_knd_q   <= knd_en;
      res_nogen_q <= nogen;
      res_ret_q   <= ret;
      res_hdl_q   <= hnd_en && id[63:32] == 32'h0 &&
                     id[31:16] != 16'h0;
      if (hnd_en && id[63:32] == 32'h0 && id[31:16] != 16'h0) begin
        if (32'(id[15:0]) >= 32'(ObjEntries)) begin
          res_st_q <= ResGen;
          state_q  <= ret;
        end else begin
          om_call(APU_OMT_ERD, '0, '0, id[15:0], '0, StResHEnt);
        end
      end else begin
        om_call(APU_OMT_FIND, id, '0, '0, '0, StResFEnt);
      end
    endtask

    function automatic logic [15:0] gen_next(logic [15:0] g);
      return g == 16'hFFFF ? 16'd1 : g + 16'd1;
    endfunction

    function automatic apu_objtab_status_e res_status(res_e r);
      unique case (r)
        ResOk:   return APU_OBJTAB_OK;
        ResGen:  return APU_OBJTAB_GEN;
        ResKind: return APU_OBJTAB_KIND;
        default: return APU_OBJTAB_MISS;
      endcase
    endfunction

    function automatic apu_objtab_entry_t ent_of(apu_objent_mem_t r);
      return '{live: r.live, kind: r.kind, gen: r.gen,
               parent_slot: r.parent_slot, refcnt: r.refcnt,
               pins: r.pins, state: r.state, bind_mem: r.bind_mem,
               bind_offset: r.bind_offset, size: r.size, aux: r.aux,
               ctx: r.ctx};
    endfunction

    // field-patch helpers (avoid blocking writes on flops)
    function automatic apu_objent_mem_t set_ctxprev(
        apu_objent_mem_t r, logic [15:0] v);
      r.ctx_prev = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_ctxnext(
        apu_objent_mem_t r, logic [15:0] v);
      r.ctx_next = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_kindprev(
        apu_objent_mem_t r, logic [15:0] v);
      r.kind_prev = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_kindnext(
        apu_objent_mem_t r, logic [15:0] v);
      r.kind_next = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_dead(apu_objent_mem_t r);
      r.live = 1'b0; return r;
    endfunction
    function automatic apu_objent_mem_t set_ref(
        apu_objent_mem_t r, logic [15:0] v);
      r.refcnt = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_aux(
        apu_objent_mem_t r, logic [63:0] v);
      r.aux = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_state(
        apu_objent_mem_t r, logic [31:0] v);
      r.state = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_pins(
        apu_objent_mem_t r, logic [7:0] v);
      r.pins = v; return r;
    endfunction
    function automatic apu_objent_mem_t set_bind(
        apu_objent_mem_t r, logic [31:0] bm, logic [63:0] bo,
        logic [63:0] sz);
      r.bind_mem = bm; r.bind_offset = bo; r.size = sz; return r;
    endfunction

    wire logic [15:0] ctx_head_cur = ctx_head_q[cidx(req_q.ctx)];

    // unlink unl_rec_q from list unl_kind_q; returns via unl_ret_q
    task automatic unl_start(input apu_objent_mem_t rec,
                             input logic kind_list,
                             input state_e ret);
      unl_rec_q  <= rec;
      unl_kind_q <= kind_list;
      unl_ret_q  <= ret;
      if ((kind_list ? rec.kind_prev : rec.ctx_prev) != LINK_NONE) begin
        state_q <= StUnlPr;
      end else begin
        if (kind_list) mem_head_q             <= rec.kind_next;
        else           ctx_head_q[cidx(rec.ctx)] <= rec.ctx_next;
        if ((kind_list ? rec.kind_next : rec.ctx_next) != LINK_NONE)
          state_q <= StUnlNr;
        else
          state_q <= ret;
      end
    endtask

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle; res_ret_q <= StIdle; om_ret_q <= StIdle;
        unl_ret_q <= StIdle; par_ret_q <= StIdle;
        req_q <= '0; cpl_q <= '0; om_req_q <= '0; om_rsp_q <= '0;
        res_id_q <= '0; res_knd_q <= 1'b0;
        res_nogen_q <= 1'b0; res_st_q <= ResMiss; res_slot_q <= '0;
        res_rec_q <= '0; res_hdl_q <= 1'b0;
        hit_slot_q <= '0; wr_rec_q <= '0; wr_slot_q <= '0;
        par_rec_q <= '0; par_slot_q <= '0;
        alloc_bucket_q <= '0; alloc_gen_q <= '0;
        unl_rec_q <= '0; unl_kind_q <= 1'b0;
        mem_head_q <= LINK_NONE;
        walk_q <= '0; walk_nxt_q <= '0; walk_rec_q <= '0;
        keep_q <= '0; keep_rec_q <= '0; keep_v_q <= 1'b0;
        head_set_q <= 1'b0;
        scan_kids_q <= 1'b0; scan_ovl_q <= 1'b0;
        rtk_slot_q <= '0; rtk_par_q <= 1'b0;
        swe_rec_q <= '0; swe_slot_q <= '0; pinned_q <= '0;
        live_q <= '0;
        for (int c = 0; c < NHEAD; c++) ctx_head_q[c] <= LINK_NONE;
      end else begin
        unique case (state_q)
        // ---------------- objmem round-trip ------------------------------
        StOmReq:  if (omt_req_ready_i) state_q <= StOmWait;
        StOmWait: if (omt_rsp_valid_i) begin
          om_rsp_q <= omt_rsp_i;
          state_q  <= om_ret_q;
        end

        // ---------------- request accept ---------------------------------
        StIdle: if (req_valid_i) begin
          req_q <= req_i;
          if (req_i.op == APU_OBJTAB_OP_RESET_CTX) begin
            // §5a write-back point: flush dirty entry lines before
            // the ctx-list walk
            scan_kids_q <= 1'b0;
            scan_ovl_q  <= 1'b0;
            pinned_q    <= '0;
            om_call(APU_OMT_FLUSH, '0, '0, '0, '0, StScanRdInit);
          end else if (req_i.op == APU_OBJTAB_OP_SCAN_OVL) begin
            scan_ovl_q <= 1'b1;
            walk_q     <= mem_head_q;
            state_q    <= StScanRd;
          end else if (req_i.op == APU_OBJTAB_OP_RETIRE_KIDS) begin
            if (32'(req_i.id[15:0]) >= 32'(ObjEntries)) begin
              cpl_q   <= '{status: APU_OBJTAB_MISS, handle: '0,
                           entry: '0};
              state_q <= StCpl;
            end else begin
              rtk_slot_q  <= req_i.id[15:0];
              rtk_par_q   <= 1'b0;
              pinned_q    <= '0;
              scan_kids_q <= 1'b1;
              scan_ovl_q  <= 1'b0;
              // the walk covers the parent's ctx list: read the
              // parent for its ctx
              om_call(APU_OMT_ERD, '0, '0, req_i.id[15:0], '0,
                      StScanParInit);
            end
          end else if (req_i.op == APU_OBJTAB_OP_READSLOT) begin
            res_id_q    <= req_i.id;
            res_nogen_q <= 1'b1;
            res_knd_q   <= req_i.kind != 6'h0;
            res_ret_q   <= StAfter;
            res_hdl_q   <= 1'b1;
            if (32'(req_i.id[15:0]) >= 32'(ObjEntries)) begin
              res_st_q <= ResMiss;
              state_q  <= StAfter;
            end else begin
              om_call(APU_OMT_ERD, '0, '0, req_i.id[15:0], '0,
                      StResHEnt);
            end
          end else if (req_i.op == APU_OBJTAB_OP_ALLOC) begin
            // CLAIM does the dup-probe + bucket claim in objmem
            om_call(APU_OMT_CLAIM, req_i.id, '0, '0, '0, StClmGot);
          end else begin
            // kind 0 is a wildcard exactly as for READSLOT
            res_start(req_i.id, 1'b1,
                      req_i.kind != 6'h0, 1'b0, StAfter);
          end
        end

        // ---------------- resolve returns --------------------------------
        StResHEnt: begin
          // ERD of a handle-addressed slot (or READSLOT)
          res_rec_q  <= om_rsp_q.rec;
          res_slot_q <= res_id_q[15:0];
          if (!om_rsp_q.rec.live ||
              (!res_nogen_q &&
               om_rsp_q.rec.gen != res_id_q[31:16])) begin
            res_st_q <= res_nogen_q ? ResMiss : ResGen;
            state_q  <= res_ret_q;
          end else if (res_knd_q &&
                       om_rsp_q.rec.kind != req_q.kind) begin
            res_st_q <= ResKind;
            state_q  <= res_ret_q;
          end else begin
            res_st_q <= ResOk;
            state_q  <= res_ret_q;
          end
        end
        StResFEnt: begin
          if (om_rsp_q.status != APU_OMT_OK) begin
            res_st_q <= ResMiss;
            state_q  <= res_ret_q;
          end else begin
            res_rec_q  <= om_rsp_q.rec;
            res_slot_q <= om_rsp_q.entry;
            if (res_knd_q && om_rsp_q.rec.kind != req_q.kind) begin
              res_st_q <= ResKind;
              state_q  <= res_ret_q;
            end else begin
              res_st_q <= ResOk;
              state_q  <= res_ret_q;
            end
          end
        end

        // ---------------- ALLOC -------------------------------------------
        StClmGot: begin
          unique case (om_rsp_q.status)
            APU_OMT_DUP: begin
              cpl_q   <= '{status: APU_OBJTAB_DUP, handle: '0,
                           entry: '0};
              state_q <= StCpl;
            end
            APU_OMT_FULL: begin
              cpl_q   <= '{status: APU_OBJTAB_FULL, handle: '0,
                           entry: '0};
              state_q <= StCpl;
            end
            default: begin
              alloc_bucket_q <= om_rsp_q.bucket;
              if (req_q.parent_id != 64'h0)
                res_start(req_q.parent_id, 1'b1, 1'b0, 1'b0,
                          StAllocPopPar);
              else begin
                par_slot_q <= APU_OBJTAB_SLOT_NONE;
                om_call(APU_OMT_POP, '0, '0, '0, '0, StAllocGen);
              end
            end
          endcase
        end
        StAllocPopPar: begin
          if (res_st_q != ResOk) begin
            cpl_q   <= '{status: APU_OBJTAB_PARENT_MISS, handle: '0,
                         entry: '0};
            state_q <= StCpl;
          end else begin
            par_slot_q <= res_slot_q;
            par_rec_q  <= res_rec_q;
            om_call(APU_OMT_POP, '0, '0, '0, '0, StAllocGen);
          end
        end
        StAllocGen: begin
          hit_slot_q <= om_rsp_q.entry;
          if (om_rsp_q.status != APU_OMT_OK) begin
            cpl_q   <= '{status: APU_OBJTAB_FULL, handle: '0,
                         entry: '0};
            state_q <= StCpl;
          end else if (om_rsp_q.fresh) begin
            alloc_gen_q <= 16'd1;
            state_q     <= StAllocWrE;
          end else begin
            om_call(APU_OMT_ERD, '0, '0, om_rsp_q.entry, '0,
                    StAllocGenRd);
          end
        end
        StAllocGenRd: begin
          alloc_gen_q <= gen_next(om_rsp_q.rec.gen);
          state_q     <= StAllocWrE;
        end
        StAllocWrE: begin
          wr_rec_q <= '{live: 1'b1, kind: req_q.kind,
                        gen: alloc_gen_q,
                        parent_slot: par_slot_q,
                        refcnt: 16'h0, pins: 8'h0, state: 32'h0,
                        bind_mem: {16'h0, APU_OBJTAB_SLOT_NONE},
                        bind_offset: 64'h0, size: req_q.size,
                        aux: req_q.offset, ctx: req_q.ctx,
                        ctx_next: ctx_head_cur,
                        ctx_prev: LINK_NONE,
                        kind_next: req_q.kind == 6'(KindListKind)
                                   ? mem_head_q : LINK_NONE,
                        kind_prev: LINK_NONE,
                        id: req_q.id, epoch: '0, pad2: '0,
                        pad7: '0, pad0: '0};
          state_q  <= StAllocCtxDo;
        end
        StAllocCtxDo: begin
          // commit the new record first so the head patch below
          // always sees a valid entry
          om_call(APU_OMT_EWR, '0, '0, hit_slot_q, wr_rec_q,
                  StAllocCtxRd);
        end
        StAllocCtxRd: begin
          if (ctx_head_cur != LINK_NONE)
            om_call(APU_OMT_ERD, '0, '0, ctx_head_cur, '0,
                    StAllocCtxWr);
          else begin
            ctx_head_q[cidx(req_q.ctx)] <= hit_slot_q;
            state_q <= StAllocKindChk;
          end
        end
        StAllocCtxWr: begin
          om_call(APU_OMT_EWR, '0, '0, ctx_head_cur,
                  set_ctxprev(om_rsp_q.rec, hit_slot_q),
                  StAllocCtxHd);
        end
        StAllocCtxHd: begin
          ctx_head_q[cidx(req_q.ctx)] <= hit_slot_q;
          state_q <= StAllocKindChk;
        end
        StAllocKindChk: begin
          if (req_q.kind == 6'(KindListKind)) begin
            if (mem_head_q != LINK_NONE)
              om_call(APU_OMT_ERD, '0, '0, mem_head_q, '0,
                      StAllocKindWr);
            else begin
              mem_head_q <= hit_slot_q;
              state_q    <= StAllocDWr;
            end
          end else begin
            state_q <= StAllocDWr;
          end
        end
        StAllocKindWr: begin
          om_call(APU_OMT_EWR, '0, '0, mem_head_q,
                  set_kindprev(om_rsp_q.rec, hit_slot_q),
                  StAllocKindHd);
        end
        StAllocKindHd: begin
          mem_head_q <= hit_slot_q;
          state_q    <= StAllocDWr;
        end
        StAllocDWr: begin
          om_call(APU_OMT_DWR, req_q.id, alloc_bucket_q,
                  hit_slot_q, '0, StAllocParChk);
        end
        StAllocParChk: begin
          if (par_slot_q != APU_OBJTAB_SLOT_NONE)
            om_call(APU_OMT_EWR, '0, '0, par_slot_q,
                    set_ref(par_rec_q, par_rec_q.refcnt + 16'h1),
                    StAllocParW);
          else
            state_q <= StAllocParW;
        end
        StAllocParW: begin
          cpl_q   <= '{status: APU_OBJTAB_OK,
                       handle: {alloc_gen_q, hit_slot_q},
                       entry: ent_of(wr_rec_q)};
          live_q  <= live_q == 16'hFFFF ? live_q : live_q + 16'd1;
          state_q <= StCpl;
        end

        // ---------------- post-resolve dispatch --------------------------
        StAfter: begin
          unique case (req_q.op)
            APU_OBJTAB_OP_LOOKUP, APU_OBJTAB_OP_READSLOT: begin
              if (res_st_q == ResOk)
                cpl_q <= '{status: APU_OBJTAB_OK,
                           handle: {res_rec_q.gen, res_slot_q},
                           entry: ent_of(res_rec_q)};
              else
                cpl_q <= '{status: res_status(res_st_q), handle: '0,
                           entry: '0};
              state_q <= StCpl;
            end
            APU_OBJTAB_OP_RETIRE: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else if (res_rec_q.pins != 8'h0) begin
                cpl_q   <= '{status: APU_OBJTAB_PINNED, handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else if (res_rec_q.refcnt != 16'h0) begin
                cpl_q   <= '{status: APU_OBJTAB_BUSY_CHILDREN,
                             handle: '0, entry: '0};
                state_q <= StCpl;
              end else begin
                hit_slot_q <= res_slot_q;
                par_slot_q <= res_rec_q.parent_slot;
                rtk_par_q  <= 1'b0;
                unl_start(res_rec_q, 1'b0, StRetKindChk);
              end
            end
            APU_OBJTAB_OP_PIN, APU_OBJTAB_OP_UNPIN: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                cpl_q <= '{status: APU_OBJTAB_OK,
                           handle: {res_rec_q.gen, res_slot_q},
                           entry: ent_of(res_rec_q)};
                om_call(APU_OMT_EWR, '0, '0, res_slot_q,
                        set_pins(res_rec_q,
                          req_q.op == APU_OBJTAB_OP_PIN
                          ? (res_rec_q.pins == 8'hFF ? 8'hFF
                             : res_rec_q.pins + 8'h1)
                          : (res_rec_q.pins == 8'h0 ? 8'h0
                             : res_rec_q.pins - 8'h1)),
                        StCpl);
              end
            end
            APU_OBJTAB_OP_SETSTATE: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                cpl_q <= '{status: APU_OBJTAB_OK,
                           handle: {res_rec_q.gen, res_slot_q},
                           entry: ent_of(res_rec_q)};
                om_call(APU_OMT_EWR, '0, '0, res_slot_q,
                        set_state(res_rec_q,
                          (res_rec_q.state & ~req_q.mask) |
                          (req_q.value & req_q.mask)),
                        StCpl);
              end
            end
            APU_OBJTAB_OP_SETAUX, APU_OBJTAB_OP_SETAUXHI: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                cpl_q <= '{status: APU_OBJTAB_OK,
                           handle: {res_rec_q.gen, res_slot_q},
                           entry: ent_of(res_rec_q)};
                om_call(APU_OMT_EWR, '0, '0, res_slot_q,
                        set_aux(res_rec_q,
                          req_q.op == APU_OBJTAB_OP_SETAUXHI
                          ? {((res_rec_q.aux[63:32] & ~req_q.mask) |
                              (req_q.value & req_q.mask)),
                             res_rec_q.aux[31:0]}
                          : (res_rec_q.aux & ~64'(req_q.mask)) |
                            (64'(req_q.value) & 64'(req_q.mask))),
                        StCpl);
              end
            end
            APU_OBJTAB_OP_SETAUXHI_CAS: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else if (res_rec_q.aux[63:32] !=
                           req_q.offset[31:0]) begin
                cpl_q   <= '{status: APU_OBJTAB_CONFLICT,
                             handle: {res_rec_q.gen, res_slot_q},
                             entry: ent_of(res_rec_q)};
                state_q <= StCpl;
              end else begin
                cpl_q <= '{status: APU_OBJTAB_OK,
                           handle: {res_rec_q.gen, res_slot_q},
                           entry: ent_of(res_rec_q)};
                om_call(APU_OMT_EWR, '0, '0, res_slot_q,
                        set_aux(res_rec_q,
                          {req_q.value,
                           res_rec_q.aux[31:0] | req_q.mask}),
                        StCpl);
              end
            end
            APU_OBJTAB_OP_SETBIND: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else if (req_q.mem_id == 64'h0) begin
                cpl_q <= '{status: APU_OBJTAB_OK,
                           handle: {res_rec_q.gen, res_slot_q},
                           entry: ent_of(res_rec_q)};
                om_call(APU_OMT_EWR, '0, '0, res_slot_q,
                        set_bind(res_rec_q,
                                 {16'h0, APU_OBJTAB_SLOT_NONE},
                                 64'h0, 64'h0),
                        StCpl);
              end else begin
                wr_rec_q  <= res_rec_q;
                wr_slot_q <= res_slot_q;
                res_start(req_q.mem_id, 1'b1, 1'b0, 1'b0,
                          StBindMemRes);
              end
            end
            default: begin
              cpl_q   <= '{status: APU_OBJTAB_MISS, handle: '0,
                           entry: '0};
              state_q <= StCpl;
            end
          endcase
        end

        StBindMemRes: begin
          if (res_st_q != ResOk) begin
            cpl_q   <= '{status: APU_OBJTAB_MISS, handle: '0,
                         entry: '0};
            state_q <= StCpl;
          end else begin
            cpl_q <= '{status: APU_OBJTAB_OK,
                       handle: {wr_rec_q.gen, wr_slot_q},
                       entry: ent_of(wr_rec_q)};
            om_call(APU_OMT_EWR, '0, '0, wr_slot_q,
                    set_bind(wr_rec_q,
                             {res_rec_q.gen, res_slot_q},
                             req_q.offset, req_q.size),
                    StCpl);
          end
        end

        // ---------------- RETIRE ------------------------------------------
        StRetKindChk: begin
          if (res_rec_q.kind == 6'(KindListKind))
            unl_start(res_rec_q, 1'b1, StRetKill);
          else
            state_q <= StRetKill;
        end
        StRetKill: begin
          om_call(APU_OMT_EWR, '0, '0, hit_slot_q,
                  set_dead(res_rec_q), StRetPush);
        end
        StRetPush: begin
          live_q <= live_q - 16'd1;
          om_call(APU_OMT_PUSH, '0, '0, hit_slot_q, '0, StRetWb);
        end
        StRetWb: begin
          // §5a write-back point before the completion lands
          om_call(APU_OMT_EWB, '0, '0, hit_slot_q, '0, StRetTomb);
        end
        StRetTomb: begin
          if (!res_hdl_q)
            om_call(APU_OMT_DTOMB, res_id_q, '0, '0, '0,
                    StRetParChk);
          else
            state_q <= StRetParChk;
        end
        StRetParChk: begin
          if (par_slot_q != APU_OBJTAB_SLOT_NONE) begin
            par_ret_q <= StRetDone;
            state_q   <= StParRd;
          end else begin
            state_q <= StRetDone;
          end
        end
        StRetDone: begin
          cpl_q   <= '{status: APU_OBJTAB_OK,
                       handle: {res_rec_q.gen, hit_slot_q},
                       entry: ent_of(res_rec_q)};
          state_q <= StCpl;
        end

        // ---------------- unlink subroutine -------------------------------
        StUnlPr: begin
          om_call(APU_OMT_ERD, '0, '0,
                  unl_kind_q ? unl_rec_q.kind_prev
                             : unl_rec_q.ctx_prev,
                  '0, StUnlPrW);
        end
        StUnlPrW: begin
          om_call(APU_OMT_EWR, '0, '0,
                  unl_kind_q ? unl_rec_q.kind_prev
                             : unl_rec_q.ctx_prev,
                  unl_kind_q
                    ? set_kindnext(om_rsp_q.rec, unl_rec_q.kind_next)
                    : set_ctxnext(om_rsp_q.rec, unl_rec_q.ctx_next),
                  StUnlNChk);
        end
        StUnlNChk: begin
          if ((unl_kind_q ? unl_rec_q.kind_next
                         : unl_rec_q.ctx_next) != LINK_NONE)
            state_q <= StUnlNr;
          else
            state_q <= unl_ret_q;
        end
        StUnlNr: begin
          om_call(APU_OMT_ERD, '0, '0,
                  unl_kind_q ? unl_rec_q.kind_next
                             : unl_rec_q.ctx_next,
                  '0, StUnlNrW);
        end
        StUnlNrW: begin
          om_call(APU_OMT_EWR, '0, '0,
                  unl_kind_q ? unl_rec_q.kind_next
                             : unl_rec_q.ctx_next,
                  unl_kind_q
                    ? set_kindprev(om_rsp_q.rec, unl_rec_q.kind_prev)
                    : set_ctxprev(om_rsp_q.rec, unl_rec_q.ctx_prev),
                  unl_ret_q);
        end

        // ---------------- parent refcnt subroutine ------------------------
        StParRd: begin
          om_call(APU_OMT_ERD, '0, '0, par_slot_q, '0, StParWr);
        end
        StParWr: begin
          om_call(APU_OMT_EWR, '0, '0, par_slot_q,
                  set_ref(om_rsp_q.rec,
                          rtk_par_q ? 16'h0 :
                          (om_rsp_q.rec.refcnt == 16'h0
                           ? 16'h0
                           : om_rsp_q.rec.refcnt - 16'h1)),
                  par_ret_q);
        end

        // ---------------- walk setup --------------------------------------
        StScanRdInit: begin
          walk_q     <= ctx_head_cur;
          keep_v_q   <= 1'b0;
          head_set_q <= 1'b0;
          state_q    <= StScanRd;
        end
        StScanParInit: begin
          // RETIRE_KIDS: parent record read — walk its ctx list.  A
          // dead/never-written slot keeps a readable ctx field (erd
          // masks only `live`), so an already-reaped or empty parent
          // sweeps an empty list -> OK count 0, never MISS.
          par_rec_q <= om_rsp_q.rec;
          walk_q    <= ctx_head_q[cidx(om_rsp_q.rec.ctx)];
          keep_v_q   <= 1'b0;
          head_set_q <= 1'b0;
          state_q    <= StScanRd;
        end

        // ---------------- ctx/kind-list walk ------------------------------
        StScanRd: begin
          if (walk_q == LINK_NONE) state_q <= StScanDone;
          else
            om_call(APU_OMT_ERD, '0, '0, walk_q, '0, StScanCmp);
        end
        StScanCmp: begin
          walk_rec_q <= om_rsp_q.rec;
          walk_nxt_q <= scan_ovl_q ? om_rsp_q.rec.kind_next
                                   : om_rsp_q.rec.ctx_next;
          if (scan_ovl_q) begin
            // read-only overlap probe over the DEVICE_MEMORY list
            if (om_rsp_q.rec.live &&
                walk_q != req_q.id[15:0] &&
                (om_rsp_q.rec.aux & APU_MEM_DEVBACKED) != 64'h0 &&
                om_rsp_q.rec.aux[63:32] != APU_MEM_UNBACKED &&
                64'(om_rsp_q.rec.aux[63:32]) < req_q.size &&
                req_q.offset <
                    64'(om_rsp_q.rec.aux[63:32]) +
                    om_rsp_q.rec.size) begin
              cpl_q   <= '{status: APU_OBJTAB_OK,
                           handle: {om_rsp_q.rec.gen, walk_q},
                           entry: ent_of(om_rsp_q.rec)};
              state_q <= StCpl;
            end else begin
              walk_q  <= om_rsp_q.rec.kind_next;
              state_q <= StScanRd;
            end
          end else if (!om_rsp_q.rec.live ||
              (scan_kids_q &&
               om_rsp_q.rec.parent_slot != rtk_slot_q) ||
              (!scan_kids_q &&
               om_rsp_q.rec.ctx != req_q.ctx)) begin
            // survivor: dead node (shouldn't normally appear —
            // links are maintained), a non-child, or a different
            // ctx sharing the overflow head — keep it linked
            state_q <= StScanKeep;
          end else if (!scan_kids_q &&
                      om_rsp_q.rec.pins != 8'h0) begin
            pinned_q <= pinned_q + 16'h1;
            state_q  <= StScanKeep;
          end else begin
            // kill: dead write, push, kind unlink, parent--
            swe_rec_q  <= om_rsp_q.rec;
            swe_slot_q <= walk_q;
            state_q    <= StScanKill;
          end
        end
        StScanKeep: begin
          // survivor stays linked: patch its ctx_prev to the last
          // keeper (or NONE) — the keeper's ctx_next is patched in
          // StScanKeepP; first survivor becomes the head
          if (!head_set_q) begin
            head_set_q <= 1'b1;
            ctx_head_q[cidx(scan_kids_q ? par_rec_q.ctx
                                        : req_q.ctx)] <= walk_q;
          end
          if (walk_rec_q.ctx_prev !=
              (keep_v_q ? keep_q : LINK_NONE))
            om_call(APU_OMT_EWR, '0, '0, walk_q,
                    set_ctxprev(walk_rec_q,
                                keep_v_q ? keep_q : LINK_NONE),
                    StScanKeepP);
          else
            state_q <= StScanKeepP;
        end
        StScanKeepP: begin
          if (keep_v_q && keep_rec_q.ctx_next != walk_q)
            om_call(APU_OMT_EWR, '0, '0, keep_q,
                    set_ctxnext(keep_rec_q, walk_q),
                    StScanKeepN);
          else
            state_q <= StScanKeepN;
        end
        StScanKeepN: begin
          keep_v_q   <= 1'b1;
          keep_q     <= walk_q;
          keep_rec_q <= set_ctxprev(walk_rec_q,
                                    keep_v_q ? keep_q : LINK_NONE);
          walk_q     <= walk_nxt_q;
          state_q    <= StScanRd;
        end
        StScanKill: begin
          om_call(APU_OMT_EWR, '0, '0, walk_q,
                  set_dead(walk_rec_q), StScanPush);
        end
        StScanPush: begin
          live_q <= live_q - 16'd1;
          om_call(APU_OMT_PUSH, '0, '0, walk_q, '0, StScanKind);
        end
        StScanKind: begin
          if (swe_rec_q.kind == 6'(KindListKind))
            unl_start(swe_rec_q, 1'b1, StScanPar);
          else
            state_q <= StScanPar;
        end
        StScanPar: begin
          // parent refcnt-- unless the parent was already reaped
          par_slot_q <= swe_rec_q.parent_slot;
          if (swe_rec_q.parent_slot != APU_OBJTAB_SLOT_NONE) begin
            rtk_par_q <= 1'b0;
            par_ret_q <= StScanEmitS;
            state_q   <= StParRd;
          end else begin
            state_q <= StScanEmitS;
          end
        end
        StScanEmitS: begin
          if (scan_kids_q) begin
            pinned_q <= pinned_q + 16'h1;
            walk_q   <= walk_nxt_q;
            state_q  <= StScanRd;
          end else begin
            cpl_q   <= '{status: APU_OBJTAB_SWEEP,
                         handle: {16'h0, swe_slot_q},
                         entry: ent_of(swe_rec_q)};
            state_q <= StScanEmit;
          end
        end
        StScanEmit: begin
          if (cpl_ready_i) begin
            walk_q  <= walk_nxt_q;
            state_q <= StScanRd;
          end
        end
        StScanDone: begin
          if (scan_ovl_q) begin
            cpl_q   <= '{status: APU_OBJTAB_MISS, handle: '0,
                         entry: '0};
            state_q <= StCpl;
          end else if (keep_v_q &&
                       keep_rec_q.ctx_next != LINK_NONE) begin
            // close the surviving list at its tail
            om_call(APU_OMT_EWR, '0, '0, keep_q,
                    set_ctxnext(keep_rec_q, LINK_NONE),
                    StScanTail);
          end else if (!head_set_q) begin
            ctx_head_q[cidx(scan_kids_q ? par_rec_q.ctx
                                        : req_q.ctx)] <= LINK_NONE;
            state_q <= StScanTail;
          end else begin
            state_q <= StScanTail;
          end
        end
        StScanTail: begin
          if (scan_kids_q && !rtk_par_q) begin
            // zero the parent's refcnt once so its own RETIRE can
            // never stall on BUSY_CHILDREN
            rtk_par_q  <= 1'b1;
            par_slot_q <= rtk_slot_q;
            par_ret_q  <= StScanFin;
            state_q    <= StParRd;
          end else begin
            state_q <= StScanFin;
          end
        end
        StScanFin: begin
          cpl_q   <= '{status: APU_OBJTAB_OK,
                       handle: {16'h0, pinned_q}, entry: '0};
          state_q <= StCpl;
        end

        // ---------------- completion --------------------------------------
        StCpl: if (cpl_ready_i) state_q <= StIdle;
        default: state_q <= StIdle;
        endcase
      end
    end

`ifndef SYNTHESIS
    // ALLOC must never emit gen 0; completions hold while stalled.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == StCpl && cpl_q.status == APU_OBJTAB_OK &&
      req_q.op == APU_OBJTAB_OP_ALLOC |-> cpl_q.handle[31:16] != 16'h0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_q));
`endif
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_objtab_fixture
  import g6lc_apu_objtab_pkg::*;
#(parameter bit          Enable       = 1'b0,
  parameter int unsigned ObjEntries   = 1024,
  parameter int unsigned MaxCtx       = 8,
  parameter int unsigned KindListKind = 8) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_objtab_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_objtab_cpl_t cpl_o,
  output logic [15:0]     live_o,
  output logic            omt_req_valid_o,
  input  logic            omt_req_ready_i,
  output apu_omt_req_t    omt_req_o,
  input  logic            omt_rsp_valid_i,
  input  apu_omt_rsp_t    omt_rsp_i
);
  g6lc_apu_objtab #(.Enable(Enable), .ObjEntries(ObjEntries),
                    .MaxCtx(MaxCtx), .KindListKind(KindListKind))
      i_dut (.*);
endmodule
