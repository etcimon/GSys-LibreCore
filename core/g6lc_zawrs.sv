// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zawrs wait policy. WRS.NTO/STO:
//   - no reservation  -> NOP (do not enter wait)
//   - reservation     -> wait until it is lost, an interrupt, or (STO) timeout
// Off-config: both outputs stay 0. Decoder already illegalises WRS.

module g6lc_zawrs #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input  logic wrs_i,
    input  logic nto_i,
    input  logic res_valid_i,
    input  logic irq_i,
    input  logic timeout_i,
    output logic enter_wait_o,
    output logic wake_o
);

  assign enter_wait_o = CVA6Cfg.ZawrsEn && wrs_i && res_valid_i && !irq_i &&
                        !(!nto_i && timeout_i);
  assign wake_o = CVA6Cfg.ZawrsEn &&
                  (!res_valid_i || irq_i || (!nto_i && timeout_i));

endmodule
