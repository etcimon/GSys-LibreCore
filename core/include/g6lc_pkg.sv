// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_pkg — GSys LibreCore naming seam.
//
// WHY THIS EXISTS
// ---------------
// The configuration struct type `config_pkg::cva6_cfg_t` and the parameter name
// `CVA6Cfg` are threaded through ~200 modules and appear at ~5,900 sites, the
// overwhelming majority of them inside tier-U files owned by ETH Zurich,
// University of Bologna, Thales DIS, CEA and others.
//
// Renaming them would:
//   * buy no legal benefit whatsoever — an internal parameter identifier is not
//     a trademark-significant position (see AGENTS-branding.md §3);
//   * forfeit the ability to rebase on upstream OpenHW CVA6 permanently;
//   * force a full-core re-verify and re-synth for a cosmetic change, which
//     AGENTS.md §0.3 names as a cost-driver anti-pattern.
//
// So the legacy names stay, and NEW LibreCore modules use the brand-correct
// aliases below. Zero churn, zero risk, brand-correct new code.
//
// USAGE (new tier-R modules)
// --------------------------
//   module g6lc_something
//     import g6lc_pkg::*;
//   #(
//       parameter g6lc_pkg::g6lc_cfg_t G6LCCfg = '0
//   ) ( ... );
//
// and pass G6LCCfg straight through to legacy submodules expecting CVA6Cfg —
// they are the same type, so this is a pure rename at the call site.
//
// TIMING IMPACT: none. This package declares types and constants only; it emits
// no logic and adds no combinational path.

package g6lc_pkg;

  // ---- configuration struct alias -------------------------------------------
  // Identical type, brand-correct name. `config_pkg` remains the definition site.
  typedef config_pkg::cva6_cfg_t g6lc_cfg_t;

  // ---- brand identity ------------------------------------------------------
  // Human-readable identifiers for trace/version surfaces. These are NOT the
  // architectural identification registers: mvendorid/marchid/mimpid are
  // assigned externally (JEDEC / RISC-V International) and are tracked as
  // release blockers in AGENTS-todo.md. Do not invent values for them here.
  localparam string G6LC_PRODUCT_NAME = "GSys LibreCore";
  localparam string G6LC_SHORT_NAME   = "LibreCore";
  localparam string G6LC_CODE_PREFIX  = "G6LC";

  // Source Location as required by CERN-OHL-S-2.0 §1.9/§3.3(c)/§4 and specified
  // in the repository NOTICE. Keep in sync with NOTICE §1.
  localparam string G6LC_SOURCE_LOCATION = "https://github.com/GlobecSys/librecore";

endpackage
