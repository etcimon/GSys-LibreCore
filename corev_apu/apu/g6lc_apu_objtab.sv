// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Generational object table: driver 64-bit object ids -> generational
// handles {gen[15:0], slot[15:0]}.
//
// Storage (both tc_sram, retained for synthesis):
//   - entry RAM  : Slots x apu_objtab_entry_t (one port)
//   - directory  : 2*Slots buckets of {valid, tomb, id[63:0], slot[15:0]},
//                  XOR-fold hash, linear probing capped at 8.
//
// Semantics:
//   - ALLOC probes the directory for a live bucket with the same id (DUP),
//     else claims the first tombstone/never-used/dead-entry bucket found
//     within 8 probes (FULL if none, even with free slots - by design)
//     and the first dead slot (FULL if none).  The slot's stored gen is
//     incremented, skipping 0 on wrap (first handle is gen 1).  A non-zero
//     parent_id must resolve live (PARENT_MISS); its refcnt++ commits
//     after the child entry.
//   - LOOKUP/PIN/UNPIN/RETIRE/SETSTATE/SETBIND resolve `id`: high word
//     non-zero -> directory id (MISS/KIND); high word zero -> {gen,slot}
//     handle (stale gen or dead slot -> GEN, then KIND).  SETBIND's
//     mem_id and ALLOC's parent_id resolve the same way; 0 = unbind/none.
//   - RETIRE refuses while pins!=0 (PINNED) or refcnt!=0 (BUSY_CHILDREN),
//     else clears live (gen persists), tombstones the directory bucket for
//     id-addressed retires and decrements a live parent's refcnt.
//   - RESET_CTX sweeps the entry RAM: unpinned slots of the context are
//     retired (a live parent's refcnt is decremented), pinned ones
//     counted; the count returns in cpl.handle[15:0].
//   - Lazy tombstoning: a directory bucket left pointing at a dead slot
//     (handle-addressed retire, RESET_CTX) is rewritten as a tombstone
//     the next time a probe matches its tag, so retired ids never alias.
//   - Driver ids are expected to have id[63:32] != 0 (opaque Venus ids);
//     ids in handle form alias with handle addressing.
//
// Timing impact: resolution is serialized (one directory read per cycle,
// <=8 probes, plus one entry read); every SRAM update is its own cycle on
// the single ports.  Widest combinational cones: the first-dead-slot OR
// tree over the live bitmap (Slots wide) and the 64-bit directory tag
// compare.  RESET_CTX worst case ~4*Slots cycles.
//
// Review checklist: async active-low reset; no latches; single always_ff;
// SRAMs behind tc_sram; Enable=0 elaborates no datapath; multi-cycle ops
// behind ready/valid with one completion each.

module g6lc_apu_objtab
  import g6lc_apu_objtab_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Slots  = 256
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
  output logic [15:0]     live_o   // popcount of the live bitmap (§6b CK_LIVE)
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o       = '0;
    assign live_o      = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | req_valid_i | cpl_ready_i |
                    (|req_i);
  end else begin : gen_on
    localparam int unsigned SlotBits = $clog2(Slots);
    localparam int unsigned DirWords = 2 * Slots;
    localparam int unsigned DirBits  = $clog2(DirWords);
    localparam int unsigned EntWidth = $bits(apu_objtab_entry_t);
    localparam int unsigned DirWidth = 1 + 1 + 64 + 16; // valid,tomb,id,slot

    typedef enum logic [1:0] { ResOk, ResMiss, ResGen, ResKind } res_e;

    typedef enum logic [4:0] {
      StInit, StIdle,
      StResProbe, StResCmp, StResEntRd, StResEntCmp, StResTomb,
      StAfter,
      StRetEntWr, StRetTomb, StRetParRd, StRetParCap, StRetParWr,
      StRetDone,
      StBindMemRes,
      StMutWr,
      StAllocPar, StAllocSlot, StAllocGen, StAllocWrE, StAllocWrD,
      StAllocParW,
      StScanRd, StScanCmp, StScanWr, StScanParRd, StScanParCap,
      StScanParWr, StScanDone,
      StCpl
    } state_e;

    state_e state_q, res_ret_q;
    apu_objtab_req_t req_q;
    apu_objtab_cpl_t cpl_q;
    logic [DirBits:0]   init_q;
    // resolve subroutine registers
    logic [63:0]        res_id_q;
    logic               res_hnd_q;    // handle-mode id allowed
    logic               res_knd_q;    // enforce kind == req_q.kind
    logic               res_alloc_q;  // ALLOC dup/reclaim mode
    logic [3:0]         probe_q;
    logic [DirBits-1:0] probe_base_q;
    logic [DirBits-1:0] tomb_first_q;
    logic               tomb_v_q;
    res_e               res_st_q;
    logic [DirBits-1:0] res_bucket_q;
    logic               res_bkv_q;
    logic [DirBits-1:0] alloc_bucket_q; // claimed dir bucket, held across
                                        // the parent resolve
    logic [15:0]        res_slot_q;
    apu_objtab_entry_t  res_ent_q;
    logic               res_hdl_q;    // resolution came via handle
    // operation working registers
    logic [15:0]        hit_slot_q;
    apu_objtab_entry_t  wr_ent_q;
    logic [15:0]        wr_slot_q;
    apu_objtab_entry_t  par_ent_q;
    logic [15:0]        par_slot_q;
    logic [SlotBits:0]  scan_q;
    logic [15:0]        pinned_q;
    logic [Slots-1:0]   live_q;
    assign live_o = 16'($countones(live_q));

    // ---- SRAM ports --------------------------------------------------------
    logic                  ent_req, ent_we;
    logic [SlotBits-1:0]   ent_addr;
    apu_objtab_entry_t     ent_wdata;
    logic [EntWidth-1:0]   ent_rdata_raw;
    apu_objtab_entry_t     ent_rdata_t;
    logic                  dir_req, dir_we;
    logic [DirBits-1:0]    dir_addr;
    logic [DirWidth-1:0]   dir_wdata, dir_rdata;

    tc_sram #(.NumWords(Slots), .DataWidth(EntWidth), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_entries (
      .clk_i, .rst_ni, .req_i(ent_req), .we_i(ent_we), .addr_i(ent_addr),
      .wdata_i(ent_wdata), .be_i('1), .rdata_o(ent_rdata_raw)
    );
    assign ent_rdata_t = apu_objtab_entry_t'(ent_rdata_raw);
    tc_sram #(.NumWords(DirWords), .DataWidth(DirWidth), .NumPorts(1),
              .Latency(1), .SimInit("none")) i_dir (
      .clk_i, .rst_ni, .req_i(dir_req), .we_i(dir_we), .addr_i(dir_addr),
      .wdata_i(dir_wdata), .be_i('1), .rdata_o(dir_rdata)
    );

    // XOR-fold the 64-bit id down to DirBits.
    function automatic logic [DirBits-1:0] dir_hash(logic [63:0] id);
      logic [DirBits-1:0] h;
      h = '0;
      for (int c = 0; c < 64; c += DirBits)
        h ^= DirBits'(id >> c);
      return h;
    endfunction

    logic        bk_valid, bk_tomb;
    logic [63:0] bk_id;
    logic [15:0] bk_slot;
    assign {bk_valid, bk_tomb, bk_id, bk_slot} = dir_rdata;

    // first dead slot - wide OR tree (see header note)
    logic [15:0] free_slot;
    logic        free_v;
    always_comb begin
      free_v    = 1'b0;
      free_slot = '0;
      for (int i = Slots - 1; i >= 0; i--)
        if (!live_q[i]) begin
          free_v    = 1'b1;
          free_slot = 16'(i);
        end
    end

    logic res_is_hnd;
    assign res_is_hnd = res_hnd_q && (res_id_q[63:32] == 32'h0);

    // ---- SRAM request steering ----------------------------------------------
    always_comb begin
      ent_req   = 1'b0; ent_we = 1'b0; ent_addr = '0; ent_wdata = '0;
      dir_req   = 1'b0; dir_we = 1'b0; dir_addr = '0; dir_wdata = '0;
      unique case (state_q)
        StInit: begin
          dir_req   = 1'b1;
          dir_we    = 1'b1;
          dir_addr  = init_q[DirBits-1:0];
          dir_wdata = '0;
          if (init_q < Slots) begin
            ent_req   = 1'b1;
            ent_we    = 1'b1;
            ent_addr  = init_q[SlotBits-1:0];
            ent_wdata = '0;
          end
        end
        StResProbe: begin
          dir_req  = 1'b1;
          dir_addr = probe_base_q + DirBits'(probe_q);
        end
        StResEntRd: begin
          ent_req  = 1'b1;
          ent_addr = res_slot_q[SlotBits-1:0];
        end
        StResTomb, StRetTomb: begin
          dir_req   = 1'b1;
          dir_we    = 1'b1;
          dir_addr  = res_bucket_q;
          dir_wdata = {1'b0, 1'b1, res_id_q, 16'h0};
        end
        StRetEntWr, StMutWr: begin
          ent_req   = 1'b1;
          ent_we    = 1'b1;
          ent_addr  = wr_slot_q[SlotBits-1:0];
          ent_wdata = wr_ent_q;
        end
        StRetParRd, StScanParRd: begin
          ent_req  = 1'b1;
          ent_addr = par_slot_q[SlotBits-1:0];
        end
        // StRetParCap / StScanParCap: entry rdata settles here.
        StRetParWr, StScanParWr, StAllocParW: begin
          ent_req   = 1'b1;
          ent_we    = 1'b1;
          ent_addr  = par_slot_q[SlotBits-1:0];
          ent_wdata = par_ent_q;
        end
        StAllocSlot: begin
          ent_req  = 1'b1;
          ent_addr = free_slot[SlotBits-1:0];
        end
        StAllocWrE: begin
          ent_req   = 1'b1;
          ent_we    = 1'b1;
          ent_addr  = hit_slot_q[SlotBits-1:0];
          ent_wdata = wr_ent_q;
        end
        StAllocWrD: begin
          dir_req   = 1'b1;
          dir_we    = 1'b1;
          dir_addr  = alloc_bucket_q;
          dir_wdata = {1'b1, 1'b0, req_q.id, hit_slot_q};
        end
        StScanRd: begin
          ent_req  = 1'b1;
          ent_addr = scan_q[SlotBits-1:0];
        end
        StScanWr: begin
          ent_req   = 1'b1;
          ent_we    = 1'b1;
          ent_addr  = scan_q[SlotBits-1:0];
          ent_wdata = wr_ent_q;
        end
        default: ;
      endcase
    end

    assign req_ready_o = state_q == StIdle;
    assign cpl_valid_o = state_q == StCpl;
    assign cpl_o       = cpl_q;

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

    // enter the resolve subroutine for `id` (dir probe unless handle form)
    // - replicated at each call site: sets res_* registers and the state.
    task automatic res_start(
        input logic [63:0] id,
        input logic        hnd_en,
        input logic        knd_en,
        input logic        alloc,
        input state_e      ret);
      res_id_q     <= id;
      res_hnd_q    <= hnd_en;
      res_knd_q    <= knd_en;
      res_alloc_q  <= alloc;
      res_ret_q    <= ret;
      probe_q      <= '0;
      probe_base_q <= dir_hash(id);
      tomb_v_q     <= 1'b0;
      res_bkv_q    <= 1'b0;
      if (hnd_en && id[63:32] == 32'h0) begin
        res_hdl_q <= 1'b1;
        if (id[15:0] >= Slots) begin
          res_st_q <= ResGen;
          state_q  <= ret;
        end else begin
          res_slot_q <= id[15:0];
          state_q    <= StResEntRd;
        end
      end else begin
        res_hdl_q <= 1'b0;
        state_q   <= StResProbe;
      end
    endtask

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StInit; res_ret_q <= StIdle;
        req_q <= '0; cpl_q <= '0; init_q <= '0;
        res_id_q <= '0; res_hnd_q <= 1'b0; res_knd_q <= 1'b0;
        res_alloc_q <= 1'b0; probe_q <= '0; probe_base_q <= '0;
        tomb_first_q <= '0; tomb_v_q <= 1'b0;
        res_st_q <= ResMiss; res_bucket_q <= '0; res_bkv_q <= 1'b0;
        alloc_bucket_q <= '0;
        res_slot_q <= '0; res_ent_q <= '0; res_hdl_q <= 1'b0;
        hit_slot_q <= '0; wr_ent_q <= '0; wr_slot_q <= '0;
        par_ent_q <= '0; par_slot_q <= '0;
        scan_q <= '0; pinned_q <= '0; live_q <= '0;
      end else begin
        unique case (state_q)
        // ---------------- init sweep ----------------
        StInit: begin
          init_q <= init_q + 1'b1;
          if (init_q == DirWords - 1) state_q <= StIdle;
        end

        // ---------------- request accept ----------------
        StIdle: if (req_valid_i) begin
          req_q <= req_i;
          if (req_i.op == APU_OBJTAB_OP_RESET_CTX) begin
            scan_q   <= '0;
            pinned_q <= '0;
            state_q  <= StScanRd;
          end else begin
            res_start(req_i.id,
                      req_i.op != APU_OBJTAB_OP_ALLOC,
                      req_i.op != APU_OBJTAB_OP_ALLOC,
                      req_i.op == APU_OBJTAB_OP_ALLOC,
                      StAfter);
          end
        end

        // ---------------- resolve subroutine ----------------
        StResProbe: state_q <= StResCmp;
        StResCmp: begin
          if (bk_valid && !bk_tomb && bk_id == res_id_q) begin
            res_bucket_q <= probe_base_q + DirBits'(probe_q);
            res_slot_q   <= bk_slot;
            state_q      <= StResEntRd;
          end else if ((!bk_valid && !bk_tomb) || probe_q == 4'd7) begin
            // absent: never-used bucket or probe cap (8 buckets max)
            if (res_alloc_q) begin
              if (tomb_v_q) begin
                res_bucket_q <= tomb_first_q;
                res_bkv_q    <= 1'b1;
              end else if (bk_tomb || (!bk_valid && !bk_tomb)) begin
                res_bucket_q <= probe_base_q + DirBits'(probe_q);
                res_bkv_q    <= 1'b1;
              end else begin
                res_bkv_q <= 1'b0; // cap reached with no reusable bucket
              end
            end
            res_st_q <= ResMiss;
            state_q  <= res_ret_q;
          end else begin
            if (res_alloc_q && !tomb_v_q && bk_tomb) begin
              tomb_v_q     <= 1'b1;
              tomb_first_q <= probe_base_q + DirBits'(probe_q);
            end
            probe_q <= probe_q + 1'b1;
            state_q <= StResProbe;
          end
        end
        StResEntRd: state_q <= StResEntCmp;
        StResEntCmp: begin
          res_ent_q <= ent_rdata_t;
          if (res_hdl_q) begin
            if (!ent_rdata_t.live || ent_rdata_t.gen != res_id_q[31:16]) begin
              res_st_q <= ResGen;
              state_q  <= res_ret_q;
            end else if (res_knd_q && ent_rdata_t.kind != req_q.kind) begin
              res_st_q <= ResKind;
              state_q  <= res_ret_q;
            end else begin
              res_st_q <= ResOk;
              state_q  <= res_ret_q;
            end
          end else if (!ent_rdata_t.live) begin
            if (res_alloc_q) begin
              // dead entry behind a live bucket: reclaim the bucket
              res_st_q  <= ResMiss;
              res_bkv_q <= 1'b1;
              state_q   <= res_ret_q;
            end else begin
              res_st_q <= ResMiss;
              state_q  <= StResTomb; // lazy tombstone, then return
            end
          end else if (res_alloc_q) begin
            res_st_q <= ResOk;      // live same-id -> DUP for ALLOC
            state_q  <= res_ret_q;
          end else if (res_knd_q && ent_rdata_t.kind != req_q.kind) begin
            res_st_q <= ResKind;
            state_q  <= res_ret_q;
          end else begin
            res_st_q <= ResOk;
            state_q  <= res_ret_q;
          end
        end
        StResTomb: state_q <= res_ret_q;

        // ---------------- post-resolve dispatch ----------------
        StAfter: begin
          unique case (req_q.op)
            APU_OBJTAB_OP_ALLOC: begin
              if (res_st_q == ResOk) begin
                cpl_q   <= '{status: APU_OBJTAB_DUP, handle: '0, entry: '0};
                state_q <= StCpl;
              end else if (!res_bkv_q) begin
                cpl_q   <= '{status: APU_OBJTAB_FULL, handle: '0, entry: '0};
                state_q <= StCpl;
              end else if (req_q.parent_id != 64'h0) begin
                alloc_bucket_q <= res_bucket_q;
                res_start(req_q.parent_id, 1'b1, 1'b0, 1'b0, StAllocPar);
              end else begin
                alloc_bucket_q <= res_bucket_q;
                par_slot_q     <= APU_OBJTAB_SLOT_NONE;
                state_q        <= StAllocSlot;
              end
            end
            APU_OBJTAB_OP_LOOKUP: begin
              if (res_st_q == ResOk)
                cpl_q <= '{status: APU_OBJTAB_OK,
                           handle: {res_ent_q.gen, res_slot_q},
                           entry: res_ent_q};
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
              end else if (res_ent_q.pins != 8'h0) begin
                cpl_q   <= '{status: APU_OBJTAB_PINNED, handle: '0, entry: '0};
                state_q <= StCpl;
              end else if (res_ent_q.refcnt != 16'h0) begin
                cpl_q   <= '{status: APU_OBJTAB_BUSY_CHILDREN, handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                wr_ent_q      <= res_ent_q;
                wr_ent_q.live <= 1'b0;
                wr_slot_q     <= res_slot_q;
                hit_slot_q    <= res_slot_q;
                par_slot_q    <= res_ent_q.parent_slot;
                state_q       <= StRetEntWr;
              end
            end
            APU_OBJTAB_OP_PIN, APU_OBJTAB_OP_UNPIN: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                wr_ent_q  <= res_ent_q;
                wr_ent_q.pins <= req_q.op == APU_OBJTAB_OP_PIN
                    ? (res_ent_q.pins == 8'hFF ? 8'hFF
                                               : res_ent_q.pins + 8'h1)
                    : (res_ent_q.pins == 8'h0  ? 8'h0
                                               : res_ent_q.pins - 8'h1);
                wr_slot_q <= res_slot_q;
                cpl_q     <= '{status: APU_OBJTAB_OK,
                               handle: {res_ent_q.gen, res_slot_q},
                               entry: res_ent_q};
                state_q   <= StMutWr;
              end
            end
            APU_OBJTAB_OP_SETSTATE: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                wr_ent_q       <= res_ent_q;
                wr_ent_q.state <= (res_ent_q.state & ~req_q.mask) |
                                  (req_q.value & req_q.mask);
                wr_slot_q      <= res_slot_q;
                cpl_q          <= '{status: APU_OBJTAB_OK,
                                    handle: {res_ent_q.gen, res_slot_q},
                                    entry: res_ent_q};
                state_q        <= StMutWr;
              end
            end
            APU_OBJTAB_OP_SETAUX, APU_OBJTAB_OP_SETAUXHI: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                wr_ent_q     <= res_ent_q;
                if (req_q.op == APU_OBJTAB_OP_SETAUXHI)
                  wr_ent_q.aux <= {((res_ent_q.aux[63:32] &
                                     ~req_q.mask) |
                                    (req_q.value & req_q.mask)),
                                   res_ent_q.aux[31:0]};
                else
                  wr_ent_q.aux <= (res_ent_q.aux & ~64'(req_q.mask)) |
                                  (64'(req_q.value) & 64'(req_q.mask));
                wr_slot_q    <= res_slot_q;
                cpl_q        <= '{status: APU_OBJTAB_OK,
                                  handle: {res_ent_q.gen, res_slot_q},
                                  entry: res_ent_q};
                state_q      <= StMutWr;
              end
            end
            APU_OBJTAB_OP_SETBIND: begin
              if (res_st_q != ResOk) begin
                cpl_q   <= '{status: res_status(res_st_q), handle: '0,
                             entry: '0};
                state_q <= StCpl;
              end else begin
                wr_ent_q  <= res_ent_q;
                wr_slot_q <= res_slot_q;
                if (req_q.mem_id == 64'h0) begin
                  wr_ent_q.bind_mem_slot <= APU_OBJTAB_SLOT_NONE;
                  wr_ent_q.bind_offset   <= 64'h0;
                  wr_ent_q.size          <= 64'h0;
                  cpl_q                  <= '{status: APU_OBJTAB_OK,
                                               handle: {res_ent_q.gen,
                                                        res_slot_q},
                                               entry: res_ent_q};
                  state_q                <= StMutWr;
                end else begin
                  res_start(req_q.mem_id, 1'b1, 1'b0, 1'b0, StBindMemRes);
                end
              end
            end
            default: begin
              cpl_q   <= '{status: APU_OBJTAB_MISS, handle: '0, entry: '0};
              state_q <= StCpl;
            end
          endcase
        end

        // ---------------- SETBIND memory resolved ----------------
        StBindMemRes: begin
          if (res_st_q != ResOk) begin
            cpl_q   <= '{status: APU_OBJTAB_MISS, handle: '0, entry: '0};
            state_q <= StCpl;
          end else begin
            wr_ent_q.bind_mem_slot <= res_slot_q;
            wr_ent_q.bind_offset   <= req_q.offset;
            wr_ent_q.size          <= req_q.size;
            cpl_q                  <= '{status: APU_OBJTAB_OK,
                                         handle: {wr_ent_q.gen, wr_slot_q},
                                         entry: wr_ent_q};
            state_q                <= StMutWr;
          end
        end

        // ---------------- ALLOC tail ----------------
        StAllocPar: begin
          if (res_st_q != ResOk) begin
            cpl_q   <= '{status: APU_OBJTAB_PARENT_MISS, handle: '0,
                         entry: '0};
            state_q <= StCpl;
          end else begin
            par_slot_q <= res_slot_q;
            par_ent_q  <= res_ent_q;
            state_q    <= StAllocSlot;
          end
        end
        StAllocSlot: begin
          // entry read of free_slot issued combinationally this cycle
          if (!free_v) begin
            cpl_q   <= '{status: APU_OBJTAB_FULL, handle: '0, entry: '0};
            state_q <= StCpl;
          end else begin
            hit_slot_q <= free_slot;
            state_q    <= StAllocGen;
          end
        end
        StAllocGen: begin
          wr_ent_q <= '{live: 1'b1, kind: req_q.kind,
                        gen: gen_next(ent_rdata_t.gen),
                        parent_slot: par_slot_q,
                        refcnt: 16'h0, pins: 8'h0, state: 32'h0,
                        bind_mem_slot: APU_OBJTAB_SLOT_NONE,
                        bind_offset: 64'h0, size: 64'h0,
                        aux: 64'h0, ctx: req_q.ctx};
          state_q  <= StAllocWrE;
        end
        StAllocWrE: begin
          live_q[hit_slot_q[SlotBits-1:0]] <= 1'b1;
          state_q <= StAllocWrD;
        end
        StAllocWrD: begin
          if (par_slot_q != APU_OBJTAB_SLOT_NONE) begin
            par_ent_q.refcnt <= par_ent_q.refcnt == 16'hFFFF ? 16'hFFFF
                                  : par_ent_q.refcnt + 16'h1;
            state_q <= StAllocParW;
          end else begin
            cpl_q   <= '{status: APU_OBJTAB_OK,
                         handle: {wr_ent_q.gen, hit_slot_q},
                         entry: wr_ent_q};
            state_q <= StCpl;
          end
        end
        StAllocParW: begin
          cpl_q   <= '{status: APU_OBJTAB_OK,
                       handle: {wr_ent_q.gen, hit_slot_q},
                       entry: wr_ent_q};
          state_q <= StCpl;
        end

        // ---------------- RETIRE tail ----------------
        StRetEntWr: begin
          live_q[wr_slot_q[SlotBits-1:0]] <= 1'b0;
          if (!res_hdl_q)      state_q <= StRetTomb;
          else if (par_slot_q != APU_OBJTAB_SLOT_NONE) state_q <= StRetParRd;
          else                 state_q <= StRetDone;
        end
        StRetTomb: begin
          if (par_slot_q != APU_OBJTAB_SLOT_NONE) state_q <= StRetParRd;
          else                 state_q <= StRetDone;
        end
        StRetParRd:  state_q <= StRetParCap;
        StRetParCap: state_q <= StRetParWr;
        StRetParWr:  state_q <= StRetDone;
        StRetDone: begin
          cpl_q   <= '{status: APU_OBJTAB_OK,
                       handle: {res_ent_q.gen, hit_slot_q},
                       entry: res_ent_q};
          state_q <= StCpl;
        end

        // ---------------- simple mutator write ----------------
        StMutWr: state_q <= StCpl;

        // ---------------- RESET_CTX sweep ----------------
        StScanRd: state_q <= StScanCmp;
        StScanCmp: begin
          if (ent_rdata_t.live && ent_rdata_t.ctx == req_q.ctx) begin
            if (ent_rdata_t.pins != 8'h0) begin
              pinned_q <= pinned_q + 16'h1;
              scan_q   <= scan_q + 1'b1;
              state_q  <= scan_q == Slots - 1 ? StScanDone : StScanRd;
            end else begin
              wr_ent_q      <= ent_rdata_t;
              wr_ent_q.live <= 1'b0;
              par_slot_q    <= ent_rdata_t.parent_slot;
              state_q       <= StScanWr;
            end
          end else begin
            scan_q  <= scan_q + 1'b1;
            state_q <= scan_q == Slots - 1 ? StScanDone : StScanRd;
          end
        end
        StScanWr: begin
          live_q[scan_q[SlotBits-1:0]] <= 1'b0;
          scan_q  <= scan_q + 1'b1;
          if (par_slot_q != APU_OBJTAB_SLOT_NONE) state_q <= StScanParRd;
          else state_q <= scan_q == Slots - 1 ? StScanDone : StScanRd;
        end
        StScanParRd:  state_q <= StScanParCap;
        StScanParCap: state_q <= StScanParWr;
        StScanParWr: begin
          // scan_q was already incremented in StScanWr
          state_q <= scan_q == Slots ? StScanDone : StScanRd;
        end
        StScanDone: begin
          cpl_q   <= '{status: APU_OBJTAB_OK,
                       handle: {16'h0, pinned_q}, entry: '0};
          state_q <= StCpl;
        end

        StCpl: if (cpl_ready_i) state_q <= StIdle;
        default: state_q <= StIdle;
        endcase
      // parent refcnt decrement staging: the *Cap state's entry data is
      // consumed here so the *Wr state's combinational write drives the
      // decremented value.
      if (state_q == StRetParCap || state_q == StScanParCap) begin
        par_ent_q        <= ent_rdata_t;
        par_ent_q.refcnt <= ent_rdata_t.live && ent_rdata_t.refcnt != 16'h0
                            ? ent_rdata_t.refcnt - 16'h1 : ent_rdata_t.refcnt;
      end
      end
    end

`ifndef SYNTHESIS
    // ALLOC must never emit gen 0; completions hold while stalled.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == StCpl && cpl_q.status == APU_OBJTAB_OK &&
      req_q.op == APU_OBJTAB_OP_ALLOC |-> cpl_q.handle[31:16] != 16'h0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_q));
    // no two live slots may share a (kind,id): enforced by the ALLOC
    // dup probe; the TB model + final SRAM sweep assert it globally.
`endif
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_objtab_fixture
  import g6lc_apu_objtab_pkg::*;
#(parameter bit Enable = 1'b0, parameter int unsigned Slots = 256) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            req_valid_i,
  output logic            req_ready_o,
  input  apu_objtab_req_t req_i,
  output logic            cpl_valid_o,
  input  logic            cpl_ready_i,
  output apu_objtab_cpl_t cpl_o,
  output logic [15:0]     live_o
);
  g6lc_apu_objtab #(.Enable(Enable), .Slots(Slots)) i_dut (.*);
endmodule
