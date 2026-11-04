// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-008A leaf: hand-computed oracle for g6lc_storamic_region_pkg map_check /
// usable_total / mapped_total. The oracle never calls the package to derive
// expected results; every expected value below is literal arithmetic.
module tb_g6lc_storamic_region;
  import g6lc_storamic_cfg_pkg::MaxSupportedSticks;
  import g6lc_storamic_region_pkg::*;

  int cases = 0, checks = 0;

  task automatic check(input string name,
      input slot_map_t slots, input int unsigned n_slots,
      input region_map_t regions, input int unsigned n_regions,
      input int unsigned word_bytes, input map_status_t want);
    map_status_t got;
    cases++;
    got = map_check(slots, n_slots, regions, n_regions, word_bytes);
    checks++;
    if (got != want)
      $fatal(1, "STORAMIC_REGION_MISMATCH %s got=%s want=%s", name, got.name(), want.name());
  endtask

  function automatic slot_map_t slots_of(input int unsigned n, input logic [63:0] ram,
      input logic [63:0] reserved, input logic [31:0] id_base);
    slot_map_t s;
    s = '{default: '0};
    for (int i = 0; i < n && i < MaxSupportedSticks; i++)
      s[i] = '{present: 1'b1, identity: id_base + 32'(i), ram_bytes: ram,
               reserved_bytes: reserved};
    return s;
  endfunction

  function automatic region_t region(input logic [63:0] base, bytes, offset,
      input int slot, input logic [31:0] id, input logic rd, wr);
    return '{valid: 1'b1, base: base, bytes: bytes, slot: 8'(slot),
             slot_identity: id, offset: offset, read: rd, write: wr};
  endfunction

  task automatic check_totals(input string name, slot_map_t slots, int unsigned n_slots,
      region_map_t regions, int unsigned n_regions,
      logic [TotalWidth-1:0] want_usable, want_mapped);
    checks += 2;
    if (usable_total(slots, n_slots) != want_usable)
      $fatal(1, "STORAMIC_REGION_USABLE %s", name);
    if (mapped_total(regions, n_regions) != want_mapped)
      $fatal(1, "STORAMIC_REGION_MAPPED %s", name);
  endtask

  // Elaboration-time proof: map_check must be constant-evaluable.
  localparam slot_map_t ElabSlots = '{0: '{present: 1'b1, identity: 32'h1,
      ram_bytes: 64'h1000, reserved_bytes: 64'h0}, default: '0};
  localparam region_map_t ElabRegions = '{0: '{valid: 1'b1, base: 64'h0,
      bytes: 64'h400, slot: 8'd0, slot_identity: 32'h1, offset: 64'h0,
      read: 1'b1, write: 1'b0}, default: '0};
  localparam map_status_t ElabStatus = map_check(ElabSlots, 1, ElabRegions, 1, 8);

  initial begin
    slot_map_t s;
    region_map_t r;
    if (ElabStatus != MapOk) $fatal(1, "STORAMIC_REGION_ELAB");
    if ($test$plusargs("oracle_negative"))
      assert (ElabStatus == MapBackingAlias) else $fatal(1, "STORAMIC_REGION_ORACLE_NEGATIVE");

    // ---- Positive maps -----------------------------------------------------
    s = slots_of(1, 64'h1_0000, 64'h100, 32'h11);
    r = '{0: region(64'h0, 64'h400, 64'h0, 0, 32'h11, 1, 1), default: '0};
    check("one-slot", s, 1, r, 1, 8, MapOk);
    check_totals("one-slot", s, 1, r, 1, 68'hff00, 68'h400);

    s = slots_of(2, 64'h8000, 64'h0, 32'h21);
    s[1].ram_bytes = 64'h2_0000; s[1].reserved_bytes = 64'h1_0000;
    r = '{0: region(64'h0, 64'h400, 64'h0, 0, 32'h21, 1, 0),
          1: region(64'h1000, 64'h800, 64'h0, 1, 32'h22, 0, 1), default: '0};
    check("two-slot-hole", s, 2, r, 2, 8, MapOk);
    check_totals("two-slot-hole", s, 2, r, 2, 68'h1_8000, 68'hc00);

    s = slots_of(3, 64'h4000, 64'h0, 32'h31);
    r = '{0: region(64'h0, 64'h200, 64'h0, 0, 32'h31, 1, 0),
          1: region(64'h2000, 64'h200, 64'h100, 1, 32'h32, 1, 1),
          2: region(64'h4000, 64'h200, 64'h0, 2, 32'h33, 1, 1), default: '0};
    check("three-slot", s, 3, r, 3, 8, MapOk);

    s = slots_of(4, 64'h2000, 64'h0, 32'h41);
    r = '{0: region(64'h0, 64'h100, 64'h0, 0, 32'h41, 1, 0),
          1: region(64'h800, 64'h100, 64'h0, 1, 32'h42, 0, 1),
          2: region(64'h1000, 64'h100, 64'h0, 2, 32'h43, 1, 0),
          3: region(64'h1800, 64'h100, 64'h0, 3, 32'h44, 1, 0), default: '0};
    check("four-slot-holes", s, 4, r, 4, 8, MapOk);

    // Region ending exactly at 2^64 is legal (base = 2^64 - bytes).
    s = slots_of(1, 64'h1_0000, 64'h0, 32'h51);
    r = '{0: region(64'hFFFF_FFFF_FFFF_F000, 64'h1000, 64'h0, 0, 32'h51, 1, 0),
          default: '0};
    check("end-at-2^64", s, 1, r, 1, 8, MapOk);

    // Two regions on one slot with disjoint backing intervals.
    s = slots_of(1, 64'h1_0000, 64'h0, 32'h61);
    r = '{0: region(64'h0, 64'h100, 64'h0, 0, 32'h61, 1, 0),
          1: region(64'h1000, 64'h100, 64'h200, 0, 32'h61, 0, 1), default: '0};
    check("same-slot-disjoint", s, 1, r, 2, 8, MapOk);

    // Absent slot referenced by no region.
    s = slots_of(3, 64'h4000, 64'h0, 32'h71); s[1].present = 0; s[1].identity = 0;
    r = '{0: region(64'h0, 64'h100, 64'h0, 0, 32'h71, 1, 0),
          1: region(64'h1000, 64'h100, 64'h0, 2, 32'h73, 0, 1), default: '0};
    check("absent-unreferenced", s, 3, r, 2, 8, MapOk);

    // 8 slots, ram = 2^64-1 each, no reservation: total needs > 64 bits.
    s = slots_of(8, 64'hFFFF_FFFF_FFFF_FFFF, 64'h0, 32'h80);
    r = '{0: region(64'h0, 64'h8, 64'h0, 0, 32'h80, 1, 1), default: '0};
    check("eight-slot", s, 8, r, 1, 8, MapOk);
    check_totals("eight-slot", s, 8, r, 1, 68'h7_FFFF_FFFF_FFFF_FFF8, 68'h8);

    // ---- Negative maps, one per status ------------------------------------
    s = slots_of(8, 64'h1000, 0, 32'h90);
    check("slot-count-zero", s, 0, r, 1, 8, MapSlotCount);
    check("slot-count-over", s, 9, r, 1, 8, MapSlotCount);
    check("region-count-zero", s, 1, r, 0, 8, MapRegionCount);
    check("region-count-over", s, 1, r, 17, 8, MapRegionCount);
    check("word-bytes-3", s, 1, r, 1, 3, MapWordBytes);
    check("word-bytes-256", s, 1, r, 1, 256, MapWordBytes);
    check("word-bytes-zero", s, 1, r, 1, 0, MapWordBytes);

    s = slots_of(1, 64'h1000, 64'h2000, 32'ha1);
    r = '{0: region(64'h0, 64'h8, 64'h0, 0, 32'ha1, 1, 0), default: '0};
    check("reservation", s, 1, r, 1, 8, MapReservation);

    s = slots_of(1, 64'h1000, 0, 32'ha1); s[0].identity = 0;
    check("identity-zero", s, 1, r, 1, 8, MapIdentityZero);

    s = slots_of(2, 64'h1000, 0, 32'ha1); s[1].identity = 32'ha1;
    r = '{0: region(64'h0, 64'h8, 64'h0, 0, 32'ha1, 1, 0), default: '0};
    check("identity-duplicate", s, 2, r, 1, 8, MapIdentityDuplicate);

    s = slots_of(1, 64'h1000, 0, 32'hb1);
    r = '{0: '{valid: 1'b0, default: '0}, default: '0};
    check("region-invalid", s, 1, r, 1, 8, MapRegionInvalid);

    r = '{0: region(64'h0, 64'h0, 64'h0, 0, 32'hb1, 1, 0), default: '0};
    check("region-empty", s, 1, r, 1, 8, MapRegionEmpty);

    r = '{0: region(64'h4, 64'h8, 64'h0, 0, 32'hb1, 1, 0), default: '0};
    check("region-align", s, 1, r, 1, 8, MapRegionAlign);

    r = '{0: region(64'hFFFF_FFFF_FFFF_F000, 64'h2000, 64'h0, 0, 32'hb1, 1, 0),
          default: '0};
    check("region-overflow", s, 1, r, 1, 8, MapRegionOverflow);

    r = '{0: region(64'h1000, 64'h100, 64'h0, 0, 32'hb1, 1, 0),
          1: region(64'h800, 64'h100, 64'h0, 0, 32'hb1, 1, 0), default: '0};
    check("region-order", s, 1, r, 2, 8, MapRegionOrder);

    s = slots_of(3, 64'h1000, 0, 32'hc1);
    r = '{0: region(64'h0, 64'h100, 64'h0, 8, 32'hc1, 1, 0), default: '0};
    check("slot-index-8", s, 3, r, 1, 8, MapSlotIndex);
    r = '{0: region(64'h0, 64'h100, 64'h0, 255, 32'hc1, 1, 0), default: '0};
    check("slot-index-255", s, 3, r, 1, 8, MapSlotIndex);

    s = slots_of(3, 64'h1000, 0, 32'hd1); s[1].present = 0;
    r = '{0: region(64'h0, 64'h100, 64'h0, 1, 32'hd2, 1, 0), default: '0};
    check("slot-absent", s, 3, r, 1, 8, MapSlotAbsent);

    s = slots_of(1, 64'h1000, 0, 32'he1);
    r = '{0: region(64'h0, 64'h100, 64'h0, 0, 32'he2, 1, 0), default: '0};
    check("identity-mismatch", s, 1, r, 1, 8, MapIdentityMismatch);

    r = '{0: region(64'h0, 64'h100, 64'h0, 0, 32'he1, 0, 0), default: '0};
    check("permission", s, 1, r, 1, 8, MapPermission);

    s = slots_of(1, 64'h1000, 64'h800, 32'hf1);
    r = '{0: region(64'h0, 64'h400, 64'h600, 0, 32'hf1, 1, 0), default: '0};
    check("backing-extent", s, 1, r, 1, 8, MapBackingExtent);

    s = slots_of(1, 64'h1000, 0, 32'hf2);
    r = '{0: region(64'h0, 64'h100, 64'h80, 0, 32'hf2, 1, 0),
          1: region(64'h1000, 64'h100, 64'h100, 0, 32'hf2, 0, 1), default: '0};
    check("backing-alias", s, 1, r, 2, 8, MapBackingAlias);

    // Priority: slot reservation error precedes region empty error.
    s = slots_of(1, 64'h1000, 64'h2000, 32'hf3);
    r = '{0: region(64'h0, 64'h0, 64'h0, 0, 32'hf3, 1, 0), default: '0};
    check("priority", s, 1, r, 1, 8, MapReservation);

    // Entries at index >= n_regions are ignored entirely.
    s = slots_of(1, 64'h1000, 0, 32'hf4);
    r = '{0: region(64'h0, 64'h100, 64'h0, 0, 32'hf4, 1, 0),
          1: '{valid: 1'b0, default: '0}, default: '0};
    check("ignored-tail", s, 1, r, 1, 8, MapOk);

    $display("STORAMIC_REGION_PASS cases=%0d checks=%0d", cases, checks);
    $finish;
  end
endmodule
