// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

package g6lc_storamic_soc_cfg_pkg;
  localparam int unsigned MaxSticks =
`ifdef G6LC_STORAMIC_MAX_STICKS
      `G6LC_STORAMIC_MAX_STICKS;
`else
      1;
`endif
  localparam bit Skeleton =
`ifdef G6LC_STORAMIC_SKELETON
      1'b1;
`else
      1'b0;
`endif
  // ST-011B: simulation model memory backing for the primary-memory role
  // (only meaningful together with G6LC_STORAMIC; the Makefile enforces it).
  localparam bit SimModel =
`ifdef G6LC_STORAMIC_MODEL
      1'b1;
`else
      1'b0;
`endif
  localparam bit DirectBackendSelected = 1'b0
`ifdef G6LC_AI_DRAM_CLASS1
      || 1'b1
`endif
`ifdef G6LC_AI_DRAM_CHANS_2
      || 1'b1
`endif
`ifdef G6LC_AI_DRAM_CHANS_4
      || 1'b1
`endif
`ifdef G6LC_AI_DRAM_CHANS_8
      || 1'b1
`endif
`ifdef G6LC_AI_DRAM_SIM_CHANS_2
      || 1'b1
`endif
`ifdef G6LC_AI_DRAM_SIM_CHANS_4
      || 1'b1
`endif
`ifdef G6LC_AI_DRAM_SIM_CHANS_8
      || 1'b1
`endif
`ifdef G6LC_AI_DRAM_TIMING
      || 1'b1
`endif
      ;

  function automatic g6lc_storamic_cfg_pkg::storamic_cfg_t make_cfg(bit enable,
      logic [63:0] model_base = '0, logic [63:0] model_bytes = '0);
    return '{Enable: enable,
      Profile: enable && SimModel ? g6lc_storamic_cfg_pkg::ProfileModel :
               enable && Skeleton ? g6lc_storamic_cfg_pkg::ProfileRefuse :
                                    g6lc_storamic_cfg_pkg::ProfileOff,
      MaxSticks: MaxSticks, RequestedMediaCaps: '0,
      ModelBase: SimModel ? model_base : '0,
      ModelBytes: SimModel ? model_bytes : '0};
  endfunction
endpackage
