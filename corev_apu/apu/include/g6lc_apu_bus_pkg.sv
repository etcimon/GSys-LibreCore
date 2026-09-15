// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

`include "axi/typedef.svh"
`include "register_interface/typedef.svh"

package g6lc_apu_bus_pkg;
  typedef logic [63:0] apu_addr_t;
  typedef logic [96:0] apu_tagged_addr_t;
  typedef logic [31:0] apu_data_t;
  typedef logic [3:0] apu_strb_t;
  typedef logic [63:0] apu_dma_data_bus_t;
  typedef logic [7:0] apu_dma_strb_t;
  typedef logic [3:0] apu_dma_id_t;
  typedef logic apu_dma_user_t;
  `AXI_TYPEDEF_ALL(apu_dma_axi, apu_addr_t, apu_dma_id_t, apu_dma_data_bus_t,
                  apu_dma_strb_t, apu_dma_user_t)
  `AXI_LITE_TYPEDEF_ALL(apu_axi, apu_addr_t, apu_data_t, apu_strb_t)
  `AXI_LITE_TYPEDEF_ALL(apu_tagged_axi, apu_tagged_addr_t, apu_data_t, apu_strb_t)
  `REG_BUS_TYPEDEF_ALL(apu_reg, apu_addr_t, apu_data_t, apu_strb_t)
  `REG_BUS_TYPEDEF_ALL(apu_tagged_reg, apu_tagged_addr_t, apu_data_t, apu_strb_t)
endpackage
