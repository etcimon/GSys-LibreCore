// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// G6LC APU (API-neutral graphics) configuration package — uncore plane.
//
// The APU is deliberately not part of config_pkg::ai_cfg_t and does not consume
// a core issue port. This package owns the SoC-visible grant surface: transport,
// queue depth, firmware reservation, DMA limits and the features that may be
// advertised. The implementation mask is checked against the requested grant;
// a profile that cannot execute the promised contract must fail legality instead
// of silently dropping feature bits.
//
// P1 status: modern virtio-mmio transport/register state only. Virgl, EDID,
// indirect descriptors, event_idx and in-order completion remain unimplemented
// and are therefore rejected by apu_cfg_legal until their datapaths exist.

package g6lc_apu_cfg_pkg;

  // Guest-absolute P1 testharness placement. This is adjacent to, and not an
  // alias of, the GPIO/AI island window at 0x4000_0000..0x4000_0fff.
  localparam logic [63:0] APU_MMIO_BASE = 64'h0000_0000_4000_1000;
  localparam logic [63:0] APU_MMIO_LEN  = 64'd4096;
  localparam logic [63:0] APU_CONTROL_BASE = 64'h0000_0000_4000_2000;
  localparam logic [63:0] APU_CONTROL_LEN = 64'd4096;
  // Linux PLIC specifier (1-based) → irq_sources[N-1]. Source 8 is the AI
  // island (`irq_sources[7]`); the APU takes the next free line.
  localparam int unsigned APU_IRQ_SOURCE = 9;

  // virtio-gpu has a control queue and a cursor queue. Keep the count explicit
  // so a future multi-queue device cannot silently reinterpret queue 0/1.
  localparam int unsigned APU_NUM_QUEUES = 2;

  // A P1 transport-only profile has no reserved resident-firmware hart. Virgl
  // profiles must name a real hart and private RAM before they are legal.
  localparam int unsigned APU_FW_HART_UNASSIGNED = 32'hffff_ffff;

  // Virtio feature numbers implemented by the current RTL. VERSION_1 is the
  // modern-device bit; RING_RESET is implemented by the queue-state block.
  localparam int unsigned VIRTIO_F_VERSION_1_BIT  = 32;
  localparam int unsigned VIRTIO_F_RING_RESET_BIT = 40;
  localparam logic [63:0] APU_IMPL_FEATURES =
      (64'd1 << VIRTIO_F_VERSION_1_BIT) |
      (64'd1 << VIRTIO_F_RING_RESET_BIT);

  typedef struct packed {
    logic        Enable;
    // Requested device features. Fields are split by semantic grant so a
    // compiler cannot accidentally set an unrelated bit in a raw mask.
    logic        FeatureVirgl;
    logic        FeatureEdid;
    logic        FeatureIndirectDesc;
    logic        FeatureEventIdx;
    logic        FeatureInOrder;
    logic        FeatureRingReset;
    int unsigned NumQueues;
    int unsigned QueueDepth;
    int unsigned MaxContexts;
    int unsigned MaxResources;
    int unsigned MaxCmdBytes;
    int unsigned MaxShaderBytes;
    int unsigned DmaMaxOutstanding;
    logic        DmaCoherent;
    logic        DmaReadEn;
    logic        DmaWriteEn;
    int unsigned DmaWriteMaxBytes;
    int unsigned DmaReadMaxBytes;
    int unsigned DmaReadBurstBeats;
    logic [63:0] DmaWindowBase;
    logic [63:0] DmaWindowBytes;
    logic        SgEn;
    int unsigned SgMaxEntries;
    int unsigned SgMaxTransferBytes;
    int unsigned NumScanouts;
    int unsigned NumCapsets;
    int unsigned FirmwareHart;
    logic [63:0] FirmwareRamBase;
    logic [63:0] FirmwareRamBytes;
    logic [63:0] MmioBase;
    logic [63:0] MmioLength;
    logic [63:0] ControlBase;
    logic [63:0] ControlLength;
    int unsigned IrqSource;
    // Native execution cluster: one physical FP32/integer lane, lockstep
    // fragment-quad contexts. Default-off; FeatureVirgl stays illegal.
    logic        ExecEn;
    int unsigned ExecQuadThreads;
    int unsigned ExecRegs;
    int unsigned ExecMemWords;
  } apu_cfg_t;

  localparam apu_cfg_t ApuOff = '{
      Enable:             1'b0,
      FeatureVirgl:       1'b0,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b0,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(1),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(0),
      FirmwareHart:       unsigned'(APU_FW_HART_UNASSIGNED),
      FirmwareRamBase:    64'h0,
      FirmwareRamBytes:   64'h0,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(4),
      ExecRegs:           unsigned'(8),
      ExecMemWords:       unsigned'(64)
  };

  // P1 transport bring-up profile: modern virtio-mmio, control/cursor queue
  // state, feature negotiation, reset and interrupt plumbing. No virgl capset,
  // scanout, or command execution is advertised yet.
  localparam apu_cfg_t ApuP1Transport = '{
      Enable:             1'b1,
      FeatureVirgl:       1'b0,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b1,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(2),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(0),
      FirmwareHart:       unsigned'(APU_FW_HART_UNASSIGNED),
      FirmwareRamBase:    64'h0,
      FirmwareRamBytes:   64'h0,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(4),
      ExecRegs:           unsigned'(8),
      ExecMemWords:       unsigned'(64)
  };

  // Testharness bring-up: same transport grant as P1, with a reserved
  // firmware hart. Requires two physical cores and NrHarts=1 (apu_soc_legal).
  localparam apu_cfg_t ApuHarness = '{
      Enable:             1'b1,
      FeatureVirgl:       1'b0,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b1,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(2),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(0),
      FirmwareHart:       unsigned'(1),
      FirmwareRamBase:    64'h9000_0000,
      FirmwareRamBytes:   64'h40000,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(4),
      ExecRegs:           unsigned'(8),
      ExecMemWords:       unsigned'(64)
  };

  // Negative control for the grant legality check: virgl cannot be advertised
  // without resident-firmware resources and the command/resource tables.
  localparam apu_cfg_t ApuBadVirglGrant = '{
      Enable:             1'b1,
      FeatureVirgl:       1'b1,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b1,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(2),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(2),
      FirmwareHart:       unsigned'(APU_FW_HART_UNASSIGNED),
      FirmwareRamBase:    64'h0,
      FirmwareRamBytes:   64'h0,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(4),
      ExecRegs:           unsigned'(8),
      ExecMemWords:       unsigned'(64)
  };

  function automatic bit pow2(input int unsigned v);
    return (v != 0) && ((v & (v - 1)) == 0);
  endfunction

  function automatic bit addr_aligned(
      input logic [63:0] base,
      input logic [63:0] length
  );
    return (length != 0) && ((length & (length - 64'd1)) == 0) &&
           ((base & (length - 64'd1)) == 0) && (base <= ~length + 64'd1);
  endfunction

  function automatic bit apu_ranges_overlap(
      input logic [63:0] base_a, length_a, base_b, length_b
  );
    if (length_a == 0 || length_b == 0) return 1'b0;
    return base_a <= base_b ? base_b - base_a < length_a : base_a - base_b < length_b;
  endfunction

  function automatic logic [63:0] apu_desired_features(input apu_cfg_t cfg);
    logic [63:0] mask;
    mask = 64'd1 << VIRTIO_F_VERSION_1_BIT;
    if (cfg.FeatureRingReset)    mask |= 64'd1 << VIRTIO_F_RING_RESET_BIT;
    if (cfg.FeatureVirgl)        mask |= 64'd1 << 0;
    if (cfg.FeatureEdid)         mask |= 64'd1 << 1;
    if (cfg.FeatureIndirectDesc) mask |= 64'd1 << 28;
    if (cfg.FeatureEventIdx)     mask |= 64'd1 << 29;
    if (cfg.FeatureInOrder)      mask |= 64'd1 << 35;
    return mask;
  endfunction

  // Features actually published in DeviceFeatures. Because cfg legality rejects
  // every desired bit outside APU_IMPL_FEATURES, this is not a silent mask.
  function automatic logic [63:0] apu_device_features(input apu_cfg_t cfg);
    return apu_desired_features(cfg) & APU_IMPL_FEATURES;
  endfunction

  function automatic bit apu_cfg_legal(input apu_cfg_t cfg);
    logic [63:0] desired;
    desired = apu_desired_features(cfg);
    if (!cfg.Enable) return 1'b1;
    if (cfg.NumQueues != APU_NUM_QUEUES) return 1'b0;
    if (!pow2(cfg.QueueDepth) || cfg.QueueDepth < 8 || cfg.QueueDepth > 1024)
      return 1'b0;
    if (cfg.MmioLength < APU_MMIO_LEN) return 1'b0;
    if (!addr_aligned(cfg.MmioBase, cfg.MmioLength)) return 1'b0;
    if (cfg.ControlLength < APU_CONTROL_LEN ||
        !addr_aligned(cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    if (apu_ranges_overlap(cfg.MmioBase, cfg.MmioLength,
                           cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    if (cfg.IrqSource == 0 || cfg.IrqSource > 29) return 1'b0;
    if (cfg.DmaMaxOutstanding < 1 || cfg.DmaMaxOutstanding > 8) return 1'b0;
    if (cfg.DmaReadEn && (cfg.DmaReadMaxBytes == 0 || cfg.DmaReadMaxBytes > 1048576 ||
        cfg.DmaReadBurstBeats == 0 || cfg.DmaReadBurstBeats > 256)) return 1'b0;
    if (cfg.DmaWriteEn && (cfg.DmaWriteMaxBytes == 0 || cfg.DmaWriteMaxBytes > 1048576))
      return 1'b0;
    if (cfg.DmaReadEn || cfg.DmaWriteEn || cfg.MaxResources != 0) begin
      if (cfg.DmaCoherent) return 1'b0;
      if (!addr_aligned(cfg.DmaWindowBase, cfg.DmaWindowBytes)) return 1'b0;
      if (apu_ranges_overlap(cfg.DmaWindowBase, cfg.DmaWindowBytes,
                             cfg.MmioBase, cfg.MmioLength) ||
          apu_ranges_overlap(cfg.DmaWindowBase, cfg.DmaWindowBytes,
                             cfg.ControlBase, cfg.ControlLength) ||
          apu_ranges_overlap(cfg.DmaWindowBase, cfg.DmaWindowBytes,
                             cfg.FirmwareRamBase, cfg.FirmwareRamBytes)) return 1'b0;
    end
    if (cfg.SgEn && (!cfg.DmaReadEn || !pow2(cfg.SgMaxEntries) ||
        cfg.SgMaxEntries < 64 || cfg.SgMaxEntries > 4096 ||
        cfg.SgMaxEntries > cfg.DmaReadMaxBytes / 16 ||
        cfg.SgMaxTransferBytes == 0 || cfg.SgMaxTransferBytes > 1048576)) return 1'b0;
    if (cfg.MaxResources != 0 && (!pow2(cfg.MaxResources) ||
        cfg.MaxResources < 8 || cfg.MaxResources > 4096)) return 1'b0;
    if (cfg.MaxCmdBytes != 0 && (!pow2(cfg.MaxCmdBytes) ||
        cfg.MaxCmdBytes < 256 || cfg.MaxCmdBytes > 65536)) return 1'b0;
    if ((desired & ~APU_IMPL_FEATURES) != 64'h0) return 1'b0;
    if (cfg.NumCapsets != 0 && !cfg.FeatureVirgl) return 1'b0;
    if (cfg.NumScanouts != 0) return 1'b0;
    if (cfg.FeatureVirgl) begin
      if (cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b0;
      if (cfg.FirmwareRamBytes < 64'd262144) return 1'b0;
      if (cfg.MaxContexts == 0 || cfg.MaxResources == 0) return 1'b0;
      if (cfg.MaxCmdBytes < 256 || cfg.MaxShaderBytes == 0) return 1'b0;
      if (cfg.NumCapsets != 2) return 1'b0;
    end
    if (cfg.FeatureEdid && cfg.NumScanouts == 0) return 1'b0;
    if (cfg.FirmwareHart != APU_FW_HART_UNASSIGNED) begin
      if (cfg.FirmwareRamBytes < 64'd262144 ||
          !addr_aligned(cfg.FirmwareRamBase, cfg.FirmwareRamBytes)) return 1'b0;
      if (apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                             cfg.MmioBase, cfg.MmioLength) ||
          apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                             cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    end
    if (cfg.ExecEn) begin
      if (cfg.ExecQuadThreads != 4) return 1'b0;
      if (!pow2(cfg.ExecRegs) || cfg.ExecRegs < 8 || cfg.ExecRegs > 32) return 1'b0;
      if (!pow2(cfg.ExecMemWords) || cfg.ExecMemWords < 16 || cfg.ExecMemWords > 256)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // SoC-facing check: a firmware-backed APU must reserve a real hart while at
  // least one application hart remains. A transport-only device may be hartless.
  function automatic bit apu_soc_legal(
      input apu_cfg_t cfg,
      input config_pkg::cva6_cfg_t core_cfg
  );
    logic [63:0] total_harts;
    if (!apu_cfg_legal(cfg)) return 1'b0;
    if (!cfg.Enable) return 1'b1;
    total_harts = 64'(core_cfg.NrCores) * 64'(core_cfg.NrHarts);
    if (cfg.FirmwareHart != APU_FW_HART_UNASSIGNED) begin
      if (core_cfg.NrCores < 2 || core_cfg.NrHarts != 1) return 1'b0;
      if (64'(cfg.FirmwareHart) >= total_harts) return 1'b0;
    end
    return 1'b1;
  endfunction

  // OpenSBI domain memregion order: size = 2^order, 3 <= order <= 64.
  function automatic int unsigned apu_region_order(input logic [63:0] bytes);
    if (bytes < 64'd8 || (bytes & (bytes - 64'd1)) != 0) return 0;
    return $clog2(bytes);
  endfunction

  // RISC-V PMP NAPOT address field for a naturally aligned power-of-two region.
  function automatic logic [63:0] apu_pmp_napot(
      input logic [63:0] base,
      input logic [63:0] bytes
  );
    return (base >> 2) | ((bytes >> 3) - 64'd1);
  endfunction

  // OpenSBI/PMP firmware-domain contract on top of apu_soc_legal.
  // Guest virtio is not firmware-private. Control and FirmwareRam are.
  // GPIO/AI at 0x40000000 is never an APU region.
  function automatic bit apu_domain_legal(
      input apu_cfg_t cfg,
      input config_pkg::cva6_cfg_t core_cfg
  );
    int unsigned ram_ord, guest_ord, ctrl_ord;
    if (!apu_soc_legal(cfg, core_cfg)) return 1'b0;
    if (!cfg.Enable) return 1'b1;
    guest_ord = apu_region_order(cfg.MmioLength);
    ctrl_ord = apu_region_order(cfg.ControlLength);
    if (guest_ord < 12 || ctrl_ord < 12) return 1'b0;
    if (apu_ranges_overlap(cfg.MmioBase, cfg.MmioLength,
                           64'h4000_0000, 64'h1000) ||
        apu_ranges_overlap(cfg.ControlBase, cfg.ControlLength,
                           64'h4000_0000, 64'h1000))
      return 1'b0;
    if (cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b1;
    ram_ord = apu_region_order(cfg.FirmwareRamBytes);
    if (ram_ord < 18) return 1'b0;
    if (!addr_aligned(cfg.FirmwareRamBase, cfg.FirmwareRamBytes)) return 1'b0;
    if (apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                           64'h4000_0000, 64'h1000) ||
        apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                           cfg.MmioBase, cfg.MmioLength) ||
        apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                           cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    return 1'b1;
  endfunction

  // Testharness DRAM hole. Firmware RAM must sit strictly inside DRAM so the
  // xbar can emit two DRAM fragments (lo/hi) without overlapping the SRAM
  // window. Empty fragments (RAM at DRAM start or end) are illegal: addr_decode
  // fatals when start_addr >= end_addr. Last matching rule wins, so a full
  // DRAM range listed after the RAM rule aliases 0x90000000 back to DRAM.
  function automatic bit apu_dram_contains_ram(
      input logic [63:0] ram_base, ram_bytes,
      input logic [63:0] dram_base, dram_bytes
  );
    if (ram_bytes == 0 || dram_bytes == 0) return 1'b0;
    if (ram_base < dram_base) return 1'b0;
    return (ram_base - dram_base) + ram_bytes <= dram_bytes;
  endfunction

  function automatic logic [63:0] apu_dram_lo_end(input logic [63:0] ram_base);
    return ram_base;
  endfunction

  function automatic logic [63:0] apu_dram_hi_start(
      input logic [63:0] ram_base, ram_bytes
  );
    return ram_base + ram_bytes;
  endfunction

  function automatic bit apu_dram_hole_legal(
      input logic [63:0] ram_base, ram_bytes,
      input logic [63:0] dram_base, dram_bytes
  );
    logic [63:0] ram_end, dram_end;
    if (!apu_dram_contains_ram(ram_base, ram_bytes, dram_base, dram_bytes))
      return 1'b0;
    ram_end = ram_base + ram_bytes;
    dram_end = dram_base + dram_bytes;
    if (!(dram_base < ram_base)) return 1'b0;
    if (!(ram_end < dram_end)) return 1'b0;
    return 1'b1;
  endfunction

  // Testharness boot split: application cores keep the ROM reset vector;
  // the firmware hart resets at FirmwareRamBase. Does not prove a CVA6 fetch.
  function automatic logic [63:0] apu_core_boot_addr(
      input apu_cfg_t cfg,
      input int unsigned core,
      input logic [63:0] app_boot
  );
    if (cfg.Enable && cfg.FirmwareHart != APU_FW_HART_UNASSIGNED &&
        core == cfg.FirmwareHart)
      return cfg.FirmwareRamBase;
    return app_boot;
  endfunction

  function automatic bit apu_boot_split_legal(
      input apu_cfg_t cfg,
      input config_pkg::cva6_cfg_t core_cfg,
      input logic [63:0] app_boot
  );
    int unsigned i, ncores;
    bit found_app;
    if (!apu_domain_legal(cfg, core_cfg)) return 1'b0;
    if (!cfg.Enable || cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b1;
    if (app_boot == cfg.FirmwareRamBase) return 1'b0;
    if (apu_ranges_overlap(app_boot, 64'd4, cfg.FirmwareRamBase,
                           cfg.FirmwareRamBytes))
      return 1'b0;
    if (apu_core_boot_addr(cfg, cfg.FirmwareHart, app_boot) !=
        cfg.FirmwareRamBase)
      return 1'b0;
    ncores = core_cfg.NrCores < 1 ? 1 : core_cfg.NrCores;
    found_app = 1'b0;
    for (i = 0; i < ncores; i++) begin
      if (i != cfg.FirmwareHart &&
          apu_core_boot_addr(cfg, i, app_boot) == app_boot)
        found_app = 1'b1;
    end
    return found_app;
  endfunction

endpackage
