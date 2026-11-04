// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-008A region map/capacity validation — pure elaboration-time functions.
// This package contains no hardware: it checks a declared heterogeneous map
// against slot capacity, identity, ordering and backing-extent rules only.
package g6lc_storamic_region_pkg;

  import g6lc_storamic_cfg_pkg::MaxSupportedSticks;

  localparam int unsigned MaxRegions = 16;
  localparam int unsigned TotalWidth = 68; // 64 + ceil(log2(MaxSupportedSticks+1))

  typedef struct packed {
    logic present;
    logic [31:0] identity;       // nonzero, unique among present slots; synthetic fixture owner id
    logic [63:0] ram_bytes;      // before reservation
    logic [63:0] reserved_bytes;
  } slot_desc_t;

  typedef struct packed {
    logic valid;                 // entries at index >= n_regions are ignored entirely
    logic [63:0] base;
    logic [63:0] bytes;
    logic [7:0] slot;            // checked against n_slots before any narrowing
    logic [31:0] slot_identity;
    logic [63:0] offset;         // within the slot's usable domain [0, ram-reserved)
    logic read, write;
  } region_t;

  typedef slot_desc_t [MaxSupportedSticks-1:0] slot_map_t;
  typedef region_t [MaxRegions-1:0] region_map_t;

  typedef enum logic [4:0] {
    MapOk, MapSlotCount, MapRegionCount, MapWordBytes, MapReservation, MapIdentityZero,
    MapIdentityDuplicate, MapRegionInvalid, MapRegionEmpty, MapRegionAlign, MapRegionOverflow,
    MapRegionOrder, MapSlotIndex, MapSlotAbsent, MapIdentityMismatch, MapPermission,
    MapBackingExtent, MapBackingAlias
  } map_status_t;

  // Validates the declared map and returns the FIRST failure in the documented
  // priority order; MapOk when every rule holds. Constant-evaluable, no state.
  function automatic map_status_t map_check(
      slot_map_t slots, int unsigned n_slots,
      region_map_t regions, int unsigned n_regions, int unsigned word_bytes);
    logic [64:0] extent, prev_end;
    logic [63:0] usable;
    if (n_slots < 1 || n_slots > MaxSupportedSticks) return MapSlotCount;
    if (n_regions < 1 || n_regions > MaxRegions) return MapRegionCount;
    if (word_bytes < 1 || word_bytes > 128 || (word_bytes & (word_bytes - 1)) != 0)
      return MapWordBytes;
    for (int i = 0; i < n_slots; i++) begin
      if (slots[i].present) begin
        if (slots[i].reserved_bytes > slots[i].ram_bytes) return MapReservation;
        if (slots[i].identity == '0) return MapIdentityZero;
        for (int j = 0; j < i; j++)
          if (slots[j].present && slots[j].identity == slots[i].identity)
            return MapIdentityDuplicate;
      end
    end
    for (int i = 0; i < n_regions; i++) begin
      if (!regions[i].valid) return MapRegionInvalid;
      if (regions[i].bytes == '0) return MapRegionEmpty;
      if ((regions[i].base & 64'(word_bytes - 1)) != 0 ||
          (regions[i].bytes & 64'(word_bytes - 1)) != 0 ||
          (regions[i].offset & 64'(word_bytes - 1)) != 0) return MapRegionAlign;
      extent = {1'b0, regions[i].base} + {1'b0, regions[i].bytes};
      if (extent > 65'h1_0000_0000_0000_0000) return MapRegionOverflow;
      if (i > 0) begin
        prev_end = {1'b0, regions[i-1].base} + {1'b0, regions[i-1].bytes};
        if ({1'b0, regions[i].base} < prev_end) return MapRegionOrder;
      end
      if (int'(regions[i].slot) >= int'(n_slots)) return MapSlotIndex;
      if (!slots[regions[i].slot].present) return MapSlotAbsent;
      if (regions[i].slot_identity != slots[regions[i].slot].identity)
        return MapIdentityMismatch;
      if (!regions[i].read && !regions[i].write) return MapPermission;
      usable = slots[regions[i].slot].ram_bytes - slots[regions[i].slot].reserved_bytes;
      if ({1'b0, regions[i].offset} + {1'b0, regions[i].bytes} > {1'b0, usable})
        return MapBackingExtent;
    end
    for (int i = 0; i < n_regions; i++)
      for (int j = i + 1; j < n_regions; j++)
        if (regions[i].slot == regions[j].slot &&
            regions[i].offset < regions[j].offset + regions[j].bytes &&
            regions[j].offset < regions[i].offset + regions[i].bytes)
          return MapBackingAlias;
    return MapOk;
  endfunction

  // Sum of (ram - reserved) over present slots at index < n_slots.
  function automatic logic [TotalWidth-1:0] usable_total(
      slot_map_t slots, int unsigned n_slots);
    logic [TotalWidth-1:0] total;
    total = '0;
    for (int i = 0; i < n_slots && i < MaxSupportedSticks; i++)
      if (slots[i].present)
        total = total + TotalWidth'(slots[i].ram_bytes - slots[i].reserved_bytes);
    return total;
  endfunction

  // Sum of bytes across valid region entries at index < n_regions.
  function automatic logic [TotalWidth-1:0] mapped_total(
      region_map_t regions, int unsigned n_regions);
    logic [TotalWidth-1:0] total;
    total = '0;
    for (int i = 0; i < n_regions && i < MaxRegions; i++)
      if (regions[i].valid) total = total + TotalWidth'(regions[i].bytes);
    return total;
  endfunction

endpackage
