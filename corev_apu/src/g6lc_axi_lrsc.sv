// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AXI exclusive monitor with multi-outstanding regular traffic.
// pulp axi_riscv_lrsc serializes every AR and AW to 1 (R_WAIT_R / W_FORWARD).
// This module forwards regular INCR up to MaxOut, strips AxLOCK downstream,
// and still snoops stores so SC sees intervening writes. Exclusive LR/SC
// stays one-at-a-time per address. Not a cva6_cfg_t field. S4/CLASS1 only.
//
// ---------------------------------------------------------------------------
// Why the reservation is a TABLE and not a single register
// ---------------------------------------------------------------------------
// The first version held one global reservation. That is correct for a single
// software hart and *livelocks* two:
//
//   hart A: LR x      -> res = x
//   hart B: LR y      -> res = y        (A's reservation is destroyed)
//   hart A: SC x      -> fails, retries
//   hart B: SC y      -> may in turn be destroyed by A's retry LR
//
// Neither hart is guaranteed to make progress, and they are contending on
// *different* addresses — so no amount of backoff in the guest fixes it. This
// is exactly the shape of the OpenSBI/Linux spinlock and of `__atomic` CAS, so
// it blocks any multi-hart boot on the builds that select this monitor.
//
// A table keyed by address is the fix, and it needs no hart id — which matters,
// because there is none available here: HPDCACHE LDEX uses the read ID space
// and STEX uses uncached-write id='1 (hpdcache.sv
// hpdcache_req_write_sel_id), so the same hart's LR and SC do not even share an
// AXI ID. Keying on the address gives the required semantics directly:
//
//   * different addresses  -> independent entries, both SCs can succeed;
//   * same address         -> one entry, the first SC consumes it and the
//                             second fails, which is the mutual exclusion
//                             LR/SC exists to provide;
//   * any intervening store to a reserved address clears that entry only.
//
// Eviction when the table is full makes an SC fail spuriously, which the ISA
// permits; `NRes` is sized at or above the logical-hart budget (PLIC contexts
// cap S <= 8) so the steady state never evicts, and the victim pointer rotates
// so a full table cannot starve one requester forever.
//
// `NRes = 1` reproduces the original single-reservation behaviour exactly, for
// bisecting against earlier results.

`include "axi/assign.svh"

module g6lc_axi_lrsc #(
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter int unsigned MaxOut         = 8,
    // Concurrent reservations. Must be >= the logical-hart count for the
    // steady state to be eviction-free; 8 covers the PLIC context budget.
    parameter int unsigned NRes           = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    AXI_BUS.Slave  slv,
    AXI_BUS.Master mst
);

  localparam int unsigned OW   = (MaxOut <= 1) ? 1 : $clog2(MaxOut + 1);
  localparam int unsigned NIDS = 1 << AXI_ID_WIDTH;
  localparam int unsigned RW   = (NRes <= 1) ? 1 : $clog2(NRes);
  localparam logic [1:0]  OKAY   = 2'b00;
  localparam logic [1:0]  EXOKAY = 2'b01;

  // pragma translate_off
  initial begin
    assert (MaxOut >= 1 && MaxOut <= 16)
      else $error("g6lc_axi_lrsc: MaxOut=%0d not in [1,16]", MaxOut);
    assert (NRes >= 1 && NRes <= 16)
      else $error("g6lc_axi_lrsc: NRes=%0d not in [1,16]", NRes);
  end
  // pragma translate_on

  logic [OW-1:0] nar, naw, nwl;
  logic sc_drop, inj_b;
  // No res_id: the table is keyed on address, deliberately (see header). A
  // reservation ID would be written and never read, and would suggest the
  // monitor can tell harts apart at this seam -- it cannot.
  logic [AXI_ID_WIDTH-1:0] drop_id, inj_id;
  logic [NIDS-1:0] ar_ex, aw_ex;

  // Reservation table, keyed by address. Exact-address match is the minimal
  // legal reservation set (the ISA requires only that the set contain the LR
  // address), and it is what the previous single-entry version compared, so
  // the snoop behaviour of existing directed tests is unchanged.
  logic [NRes-1:0]           res_v;
  logic [AXI_ADDR_WIDTH-1:0] res_addr [NRes];
  logic [RW-1:0]             vic_q;  // rotating victim, so a full table is fair

  wire ar_is_ex = slv.ar_lock && (slv.ar_len == 8'd0);
  wire aw_is_ex = slv.aw_lock && (slv.aw_len == 8'd0);
  wire ar_room  = nar != OW'(MaxOut);
  wire aw_room  = naw != OW'(MaxOut);

  // --- reservation lookup ----------------------------------------------------
  // AW side: does any entry reserve the address this write targets? Used both
  // for the SC verdict and for the store snoop.
  logic          aw_hit;
  logic [RW-1:0] aw_hit_idx;
  always_comb begin
    aw_hit     = 1'b0;
    aw_hit_idx = '0;
    for (int unsigned i = 0; i < NRes; i++) begin
      if (res_v[i] && (res_addr[i] == slv.aw_addr)) begin
        aw_hit     = 1'b1;
        aw_hit_idx = RW'(i);
      end
    end
  end

  // AR side: refresh an existing entry for this address, else take a free slot,
  // else evict the rotating victim. Refreshing rather than allocating keeps a
  // repeated LR to the same address from consuming the whole table.
  logic          ar_same;
  logic [RW-1:0] ar_same_idx;
  logic          ar_free;
  logic [RW-1:0] ar_free_idx;
  always_comb begin
    ar_same     = 1'b0;
    ar_same_idx = '0;
    ar_free     = 1'b0;
    ar_free_idx = '0;
    for (int unsigned i = 0; i < NRes; i++) begin
      if (res_v[i] && (res_addr[i] == slv.ar_addr)) begin
        ar_same     = 1'b1;
        ar_same_idx = RW'(i);
      end
    end
    for (int unsigned i = NRes; i > 0; i--) begin
      if (!res_v[i-1]) begin
        ar_free     = 1'b1;
        ar_free_idx = RW'(i-1);
      end
    end
  end
  wire [RW-1:0] ar_alloc_idx = ar_same ? ar_same_idx : (ar_free ? ar_free_idx : vic_q);

  wire sc_ok    = aw_hit;
  wire aw_drop  = aw_is_ex && !sc_ok;
  wire aw_fwd   = !aw_drop && aw_room && !sc_drop && !inj_b;
  // SC waits for prior regular writes so the reservation check is stable.
  wire sc_wait  = aw_is_ex && (naw != 0 || nwl != 0);

  assign mst.ar_addr   = slv.ar_addr;
  assign mst.ar_prot   = slv.ar_prot;
  assign mst.ar_region = slv.ar_region;
  assign mst.ar_len    = slv.ar_len;
  assign mst.ar_size   = slv.ar_size;
  assign mst.ar_burst  = slv.ar_burst;
  assign mst.ar_lock   = 1'b0;
  assign mst.ar_cache  = slv.ar_cache;
  assign mst.ar_qos    = slv.ar_qos;
  assign mst.ar_id     = slv.ar_id;
  assign mst.ar_user   = slv.ar_user;
  assign mst.ar_valid  = slv.ar_valid && ar_room && !sc_drop;
  assign slv.ar_ready  = mst.ar_ready && ar_room && !sc_drop;

  assign mst.aw_addr   = slv.aw_addr;
  assign mst.aw_prot   = slv.aw_prot;
  assign mst.aw_region = slv.aw_region;
  assign mst.aw_atop   = slv.aw_atop;
  assign mst.aw_len    = slv.aw_len;
  assign mst.aw_size   = slv.aw_size;
  assign mst.aw_burst  = slv.aw_burst;
  assign mst.aw_lock   = 1'b0;
  assign mst.aw_cache  = slv.aw_cache;
  assign mst.aw_qos    = slv.aw_qos;
  assign mst.aw_id     = slv.aw_id;
  assign mst.aw_user   = slv.aw_user;
  assign mst.aw_valid  = slv.aw_valid && aw_fwd && !sc_wait;
  assign slv.aw_ready  = aw_drop ? (!sc_drop && !inj_b && !sc_wait)
                                 : (mst.aw_ready && aw_fwd && !sc_wait);

  wire aw_hs = slv.aw_valid && slv.aw_ready;
  wire w_has = (nwl != 0) || (aw_hs && !aw_drop);
  assign mst.w_data  = slv.w_data;
  assign mst.w_strb  = slv.w_strb;
  assign mst.w_user  = slv.w_user;
  assign mst.w_last  = slv.w_last;
  assign mst.w_valid = slv.w_valid && w_has && !sc_drop && !aw_drop;
  assign slv.w_ready = sc_drop || aw_drop
                       ? 1'b1
                       : (mst.w_ready && w_has);

  assign slv.r_data  = mst.r_data;
  assign slv.r_last  = mst.r_last;
  assign slv.r_id    = mst.r_id;
  assign slv.r_user  = mst.r_user;
  assign slv.r_valid = mst.r_valid;
  assign slv.r_resp  = (mst.r_valid && mst.r_resp == OKAY && ar_ex[mst.r_id])
                       ? EXOKAY : mst.r_resp;
  assign mst.r_ready = slv.r_ready;

  assign slv.b_id    = inj_b ? inj_id : mst.b_id;
  assign slv.b_user  = inj_b ? '0 : mst.b_user;
  assign slv.b_resp  = inj_b ? OKAY
                             : ((mst.b_valid && mst.b_resp == OKAY && aw_ex[mst.b_id])
                                ? EXOKAY : mst.b_resp);
  assign slv.b_valid = inj_b || mst.b_valid;
  assign mst.b_ready = slv.b_ready && !inj_b;

  wire ar_hs = slv.ar_valid && slv.ar_ready;
  wire w_hs  = slv.w_valid && slv.w_ready && slv.w_last;
  wire r_hs  = slv.r_valid && slv.r_ready && slv.r_last;
  wire b_hs  = slv.b_valid && slv.b_ready;
  wire aw_fwd_hs = aw_hs && !aw_drop;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      nar <= '0;
      naw <= '0;
      nwl <= '0;
      res_v <= '0;
      for (int unsigned i = 0; i < NRes; i++) res_addr[i] <= '0;
      vic_q <= '0;
      sc_drop <= 1'b0;
      inj_b <= 1'b0;
      drop_id <= '0;
      inj_id <= '0;
      ar_ex <= '0;
      aw_ex <= '0;
    end else begin
      unique case ({ar_hs, r_hs})
        2'b10: nar <= nar + OW'(1);
        2'b01: nar <= nar - OW'(1);
        default: ;
      endcase
      unique case ({aw_fwd_hs, (b_hs && !inj_b)})
        2'b10: naw <= naw + OW'(1);
        2'b01: naw <= naw - OW'(1);
        default: ;
      endcase
      unique case ({(aw_fwd_hs), (w_hs && !sc_drop && !aw_drop)})
        2'b10: nwl <= nwl + OW'(1);
        2'b01: nwl <= nwl - OW'(1);
        default: ;
      endcase

      // LR: reserve this address. Refresh in place when it is already
      // reserved, otherwise take a free slot, otherwise evict the rotating
      // victim and advance it so a full table cannot starve one requester.
      if (ar_hs) begin
        ar_ex[slv.ar_id] <= ar_is_ex;
        if (ar_is_ex) begin
          res_v[ar_alloc_idx]    <= 1'b1;
          res_addr[ar_alloc_idx] <= slv.ar_addr;
          if (!ar_same && !ar_free)
            vic_q <= (NRes <= 1) ? '0 : RW'((vic_q + 1) % NRes);
        end
      end
      if (r_hs)
        ar_ex[slv.r_id] <= 1'b0;

      if (aw_fwd_hs) begin
        aw_ex[slv.aw_id] <= aw_is_ex;
        // A store clears only the entry it actually hits. Clearing the whole
        // table here is what destroyed a peer hart's unrelated reservation.
        // A winning SC consumes its own entry, so a second SC to the same
        // address fails -- that is the mutual exclusion, and it is why the
        // clear is unconditional on a hit rather than gated on `!aw_is_ex`.
        if (aw_hit)
          res_v[aw_hit_idx] <= 1'b0;
      end
      if (b_hs && !inj_b)
        aw_ex[mst.b_id] <= 1'b0;

      // A failing SC had no entry by construction (`aw_drop` means `!aw_hit`),
      // so there is nothing to clear. The old code cleared the global
      // reservation here, which let a failed SC on one hart cancel a valid
      // reservation on another.
      if (aw_hs && aw_drop) begin
        drop_id <= slv.aw_id;
        if (slv.w_valid && slv.w_last) begin
          inj_b  <= 1'b1;
          inj_id <= slv.aw_id;
        end else
          sc_drop <= 1'b1;
      end
      if (sc_drop && w_hs) begin
        sc_drop <= 1'b0;
        inj_b   <= 1'b1;
        inj_id  <= drop_id;
      end
      if (inj_b && slv.b_ready)
        inj_b <= 1'b0;
    end
  end

  // pragma translate_off
  // The table must never hold two entries for one address: `aw_hit_idx` keeps
  // only the last match, so a duplicate would leave a stale reservation behind
  // after a store and let a later SC succeed against a killed one. Allocation
  // refreshes in place precisely to maintain this, so it is asserted rather
  // than assumed.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned a = 0; a < NRes; a++)
        for (int unsigned b = a + 1; b < NRes; b++)
          assert (!(res_v[a] && res_v[b] && (res_addr[a] == res_addr[b])))
            else $error("g6lc_axi_lrsc: duplicate reservation for %h in slots %0d/%0d",
                        res_addr[a], a, b);
    end
  end
  // pragma translate_on

endmodule
