// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Unrestricted Boolean inputs: debug wins, every non-debug priority is retained.
module g6lc_debug_redirect_priority (
  input logic en_restore, restore, debug_en, commit, peer, ex, eret, misp,
  output logic good,
  output logic [3:0] selected, legacy, expected
);
  import g6lc_fetch_pkg::*;
  assign selected = arch_src_sel(en_restore, restore, debug_en, commit, peer, ex, eret, misp);
  assign legacy = ex ? SRC_EX : eret ? SRC_ERET : commit ? SRC_COMMIT :
                  peer ? SRC_PEER : debug_en ? SRC_DEBUG :
                  en_restore && restore ? SRC_RESTORE : misp ? SRC_MISP : SRC_NONE;
  assign expected = debug_en ? SRC_DEBUG : legacy;
  assign good = selected == expected && (debug_en || selected == legacy);
endmodule
