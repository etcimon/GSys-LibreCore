// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Closed parameterisation of the hierarchical core unit (g6lc_core_hb): the
// target package's configuration and the port types derived from it, so the
// wrapper carries no parameter at all across the hier_block boundary.

`include "rvfi_types.svh"

package g6lc_core_hb_pkg;

  localparam config_pkg::cva6_cfg_t Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  localparam int unsigned VLEN = Cfg.VLEN;
  localparam int unsigned XLEN = Cfg.XLEN;
  localparam int unsigned PLEN = Cfg.PLEN;
  localparam int unsigned NH   = (Cfg.NrHarts < 1) ? 1 : Cfg.NrHarts;

  localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(Cfg);
  localparam type rvfi_probes_csr_t   = `RVFI_PROBES_CSR_T(Cfg);
  localparam type rvfi_probes_t = struct packed {
    rvfi_probes_csr_t   csr;
    rvfi_probes_instr_t instr;
  };

endpackage
