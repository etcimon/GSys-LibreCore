// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Fabric-side trusted grant for the APU control aperture. Authorization is
// the firmware hart ID plus a control-window address, never AXI PROT.
// Guest virtio MMIO is a separate port and is not gated here. Default-off.

module g6lc_apu_grant
  import g6lc_apu_cfg_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter int unsigned HartIdWidth = 32
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  logic [HartIdWidth-1:0] aw_hart_i,
  input  logic [HartIdWidth-1:0] ar_hart_i,
  input  logic [63:0] aw_addr_i,
  input  logic [63:0] ar_addr_i,
  input  logic guest_irq_i,
  input  logic control_irq_i,
  output logic control_aw_authorized_o,
  output logic control_ar_authorized_o,
  output logic plic_irq_o,
  output logic [31:0] plic_source_o,
  output logic fw_irq_o
);
  `ifndef SYNTHESIS
  initial assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU grant: invalid configuration");
  `endif

  if (!ApuCfg.Enable) begin : gen_off
    assign control_aw_authorized_o = 1'b0;
    assign control_ar_authorized_o = 1'b0;
    assign plic_irq_o = 1'b0;
    assign plic_source_o = '0;
    assign fw_irq_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | guest_irq_i | control_irq_i |
                    |aw_hart_i | |ar_hart_i | |aw_addr_i | |ar_addr_i;
  end else begin : gen_on
    function automatic logic in_control(input logic [63:0] addr);
      return addr >= ApuCfg.ControlBase &&
             (addr - ApuCfg.ControlBase) < ApuCfg.ControlLength;
    endfunction
    assign control_aw_authorized_o =
        apu_source_is_fw(ApuCfg, 32'(aw_hart_i)) && in_control(aw_addr_i);
    assign control_ar_authorized_o =
        apu_source_is_fw(ApuCfg, 32'(ar_hart_i)) && in_control(ar_addr_i);
    assign plic_irq_o = guest_irq_i;
    assign plic_source_o = 32'(ApuCfg.IrqSource);
    assign fw_irq_o = control_irq_i;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i;
  end
endmodule
