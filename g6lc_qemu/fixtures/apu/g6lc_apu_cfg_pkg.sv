// SYNTHETIC FIXTURE. Invented content (see ../README.md).
// SPDX-License-Identifier: MIT
//
// Minimal APU configuration package for the bridge-ingest test. Shaped like
// the real g6lc_apu_cfg_pkg.sv (one struct literal per profile, scalar
// localparams the fields resolve through), but every address and count is
// invented.

package g6lc_apu_cfg_pkg;

  localparam logic [63:0] APU_MMIO_BASE    = 64'h0000_0000_6000_1000;
  localparam logic [63:0] APU_MMIO_LEN     = 64'd4096;
  localparam logic [63:0] APU_CONTROL_BASE = 64'h0000_0000_6000_2000;
  localparam logic [63:0] APU_CONTROL_LEN  = 64'd4096;
  localparam int unsigned APU_IRQ_SOURCE   = 11;
  localparam int unsigned APU_NUM_QUEUES   = 2;

  typedef struct packed {
    logic        Enable;
    logic        FeatureVirgl;
    logic [63:0] MmioBase;
    logic [63:0] MmioLength;
    logic [63:0] ControlBase;
    logic [63:0] ControlLength;
    int unsigned IrqSource;
    int unsigned NumQueues;
    int unsigned QueueDepth;
    int unsigned NumCapsets;
    int unsigned NumScanouts;
    logic [63:0] DmaWindowBase;
    logic [63:0] DmaWindowBytes;
  } apu_cfg_t;

  localparam apu_cfg_t ApuVenus = '{
      Enable:         1'b1,
      FeatureVirgl:   1'b1,
      MmioBase:       APU_MMIO_BASE,
      MmioLength:     APU_MMIO_LEN,
      ControlBase:    APU_CONTROL_BASE,
      ControlLength:  APU_CONTROL_LEN,
      IrqSource:      unsigned'(APU_IRQ_SOURCE),
      NumQueues:      unsigned'(APU_NUM_QUEUES),
      QueueDepth:     unsigned'(32),
      NumCapsets:     unsigned'(1),
      NumScanouts:    unsigned'(0),
      DmaWindowBase:  64'h8000_0000,
      DmaWindowBytes: 64'h0800_0000
  };

endpackage
