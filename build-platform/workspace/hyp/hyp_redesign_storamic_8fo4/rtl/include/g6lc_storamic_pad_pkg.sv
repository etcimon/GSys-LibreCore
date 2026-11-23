// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

package g6lc_storamic_pad_pkg;
  typedef struct packed {
    logic [7:0] dq;
    logic [7:0] dq_oe;
    logic rwds;
    logic rwds_oe;
    logic ck_p;
    logic ck_n;
    logic ram_cs_n;
    logic ram_reset_n;
    logic [3:0] flash_dq;
    logic [3:0] flash_dq_oe;
    logic flash_ck;
    logic flash_cs_n;
  } pad_out_t;

  localparam pad_out_t PadSafe = '{
    ck_n: 1'b1, ram_cs_n: 1'b1, flash_cs_n: 1'b1, default: '0
  };
endpackage
