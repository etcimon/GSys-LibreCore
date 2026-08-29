// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// SYNTHETIC FIXTURE. Invented content (see ../README.md).
//
// A minimal SoC configuration package for an AI-enabled target. This exists so the
// `g6lc-ai-soc` machine can be generated from fixtures alone without reaching into a
// host monorepo. The AI island placement is deliberately published here as test values
// so the forward path from F1 (architecture/RTL_FEEDBACK.md) is exercisable.

package ai_soc_config_pkg;

  localparam int unsigned AiSocXlen  = 64;

  typedef struct packed {
    int unsigned XLEN;
    bit          HasCompressed;
    bit          HasVector;
    bit          HasAtomic;
    bit          HasHypervisor;
    int unsigned HartsPerCore;
    int unsigned CoreCount;
  } ai_soc_cfg_t;

  localparam ai_soc_cfg_t AiSocCfg = '{
    XLEN:          64,
    HasCompressed: 1'b1,
    HasVector:     1'b1,
    HasAtomic:     1'b1,
    HasHypervisor: 1'b0,
    HartsPerCore:  1,
    CoreCount:     1
  };

endpackage
