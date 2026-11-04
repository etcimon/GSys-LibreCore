// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-009A discovery/lifecycle package: per-slot state machine states, fault
// codes, and the synthetic descriptor v1 fixture layout. The descriptor format
// is a test fixture, not a published ABI (ST-014 selects a real device).
package g6lc_storamic_discovery_pkg;

  typedef enum logic [3:0] {
    Absent     = 4'd0,
    Present    = 4'd1,
    PowerCheck = 4'd2,
    PowerWait  = 4'd3,
    Identify   = 4'd4,
    Validate   = 4'd5,
    Initialize = 4'd6,
    Ready      = 4'd7,
    Quiesce    = 4'd8,
    Quiesced   = 4'd9,
    Fault      = 4'd10
  } state_t;

  typedef enum logic [3:0] {
    FaultNone         = 4'd0,
    FaultProfile      = 4'd1,
    FaultPowerTimeout = 4'd2,
    FaultDescRead     = 4'd3,
    FaultDescTimeout  = 4'd4,
    FaultMagic        = 4'd5,
    FaultVersion      = 4'd6,
    FaultLength       = 4'd7,
    FaultChecksum     = 4'd8,
    FaultIdentity     = 4'd9,
    FaultFlags        = 4'd10,
    FaultCapacity     = 4'd11,
    FaultGeometry     = 4'd12,
    FaultReserved     = 4'd13,
    FaultInit         = 4'd14,
    FaultRemoved      = 4'd15
  } fault_t;

  // Synthetic descriptor v1 word indices and fields.
  localparam logic [31:0] DescMagic = 32'h5354_524D; // "STRM"
  localparam int unsigned DescMagicWord = 0;
  localparam int unsigned DescVersionWord = 1;
  localparam int unsigned DescIdentityWord = 2;
  localparam int unsigned DescFlagsWord = 3;
  localparam int unsigned DescRamLoWord = 4;
  localparam int unsigned DescRamHiWord = 5;
  localparam int unsigned DescResLoWord = 6;
  localparam int unsigned DescResHiWord = 7;
  localparam int unsigned DescFlashLoWord = 8;
  localparam int unsigned DescFlashHiWord = 9;
  localparam int unsigned DescEraseWord = 10;
  localparam int unsigned DescReservedFirst = 11;
  localparam int unsigned DescMinWords = 12;
  localparam logic [15:0] DescVersion = 16'd1;
  // flags word: [0] RAM, [1] flash, [2] persistence-capable, [11:8] profile.
  localparam logic [31:0] DescFlagsKnown = 32'h0000_0707;

endpackage
