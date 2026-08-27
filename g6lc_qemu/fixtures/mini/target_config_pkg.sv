// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// SYNTHETIC FIXTURE. Invented content, shaped like a real configuration package.
// Not copied from any design project (see ../README.md).
//
// Exercises the narrow reader in crates/g6q-svcfg:
//   * plain and sized integer literals
//   * boolean flags written as 1'b1 / 1'b0
//   * a symbolic enum member, which must be carried by NAME not by value
//   * a nested struct literal
//   * one member the reader must refuse to guess at -> Value::Unresolved

package mini_target_config_pkg;

  localparam int unsigned MiniXlen  = 64;
  localparam int unsigned MiniBtb   = 32;

  typedef struct packed {
    int unsigned XLEN;
    bit          HasCompressed;
    bit          HasVector;
    bit          HasAtomicCas;
    bit          HasHypervisor;
    predictor_e  PredictorType;
    int unsigned BtbEntries;
    int unsigned RasDepth;
    int unsigned HartsPerCore;
    int unsigned CoreCount;
  } mini_cfg_t;

  localparam mini_cfg_t MiniCfg = '{
    XLEN:          64,
    HasCompressed: 1'b1,
    // Enabled here, but the implementing unit is deliberately absent from
    // manifest.f -- the reader reports the bit, and membership reports the stub.
    HasVector:     1'b1,
    HasAtomicCas:  1'b1,
    // Live in the design; board.dts deliberately omits the token.
    HasHypervisor: 1'b1,
    // Must survive as the identifier "TAGGED", never as a number.
    PredictorType: TAGGED,
    BtbEntries:    32'd32,
    // Intentionally an expression the narrow reader cannot resolve. It must become
    // Unresolved rather than silently defaulting to something plausible.
    RasDepth:      MiniBtb / 4,
    HartsPerCore:  2,
    CoreCount:     2
  };

endpackage
