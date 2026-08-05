// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Minimal stand-in for monorepo config_pkg (cva6_cfg_t) used by issue_read_operands patterns.

package config_pkg;
  typedef struct packed {
    int unsigned NrIssuePorts;
    int unsigned NrCommitPorts;
    int unsigned NR_SB_ENTRIES;
    int unsigned XLEN;
    int unsigned VLEN;
    int unsigned TRANS_ID_BITS;
  } cva6_cfg_t;

  localparam cva6_cfg_t cva6_cfg_empty = '{
      NrIssuePorts: 1,
      NrCommitPorts: 1,
      NR_SB_ENTRIES: 8,
      XLEN: 64,
      VLEN: 39,
      TRANS_ID_BITS: 3
  };
endpackage
