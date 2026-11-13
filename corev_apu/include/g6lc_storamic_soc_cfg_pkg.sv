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

  // Native checkpoint composition platform boundary (native-composition.md).
  // Packed structs cross the backend/attach hierarchy only; no loose ports.
  typedef struct packed {
    logic [4:0]  providers_ready;
    logic        present;
    logic        identity_valid;
    logic        protection_ok;
    logic        power_cut;
    logic [159:0] module_id;
    logic [31:0] mapping_generation;
    logic [31:0] reset_generation;
    logic        update_valid;
    logic [31:0] update_policy;
    logic [2:0]  producer_paused;
    logic [2:0]  producer_error;
    logic [2:0]  ingress_hold;
    logic        route_hold;
    logic        maintenance_hold;
    logic        service_enable;
    logic        aw_authorized;
    logic        ar_authorized;
    logic        restore_resume_safe;
  } ckpt_plat_in_t;

  typedef struct packed {
    logic issue, refuse, revoke, done, error;
    logic policy_commit, policy_revoke, policy_exhaust, policy_reject;
  } ckpt_events_t;

  typedef struct packed {
    logic        pause_req;
    logic        policy_quiesce;
    logic        update_ready;
    logic        policy_ready;
    logic [31:0] policy_epoch;
    logic        policy_revoked;
    logic        initialized;
    logic        busy;
    logic        recovery_locked;
    logic        checkpoint_valid;
    logic        metadata_ok;
    logic        axi_quiesce;
    logic [63:0] checkpoint_generation;
    logic [3:0]  phase;
    logic        boot_ready;
    // Boot recovery agent (C6b): running / terminally failed (pause held).
    logic        recovery_active;
    logic        recovery_failed;
    ckpt_events_t events;
  } ckpt_plat_out_t;

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
