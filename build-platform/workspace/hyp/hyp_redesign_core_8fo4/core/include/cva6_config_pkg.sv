// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// cva6_config_pkg -- U10b Ara compatibility shim.
//
// The vendored upstream vector unit (vendor/ara, tier-U, unmodified) and the
// upstream `ariane_pkg` take their default configuration and a few struct-width
// constants from `cva6_config_pkg`. The hyp8 workspace builds its live
// `g6lc_cfg_t` via `build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg)`
// (see g6lc_core_hb_pkg::Cfg). This package re-exports exactly that instance
// plus the upstream-named width constants mapped onto the hyp8 fields, so the
// vendored sources elaborate against the *real* configuration -- not an empty
// default. `g6lc_ara_attach` still overrides `.CVA6Cfg` explicitly; this value
// only has to be type-correct and field-correct for the parts that read
// `cva6_config_pkg::` directly (ariane_pkg struct widths, default params).
//
// NOTE: package order matters -- this file must follow config_pkg,
// build_config_pkg and the active *config_pkg (which defines g6lc_config_pkg).

package cva6_config_pkg;

  import config_pkg::*;

  /// The live core configuration, identical to g6lc_core_hb_pkg::Cfg and the
  /// testbenches, so every width/field the vector unit reads matches silicon.
  localparam config_pkg::g6lc_cfg_t cva6_cfg =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);

  /// ariane_pkg sizes DCACHE_USER_WIDTH from this; map to the live AXI data
  /// user width (== XLEN on the hyp8 targets).
  localparam int unsigned CVA6ConfigDataUserWidth = cva6_cfg.AxiUserWidth;

  /// ariane_pkg gates RVFI tracing on this; hyp8 mc keeps RVFI on.
  localparam CVA6ConfigRvfiTrace = g6lc_config_pkg::G6LCConfigRvfiTrace;

endpackage : cva6_config_pkg
