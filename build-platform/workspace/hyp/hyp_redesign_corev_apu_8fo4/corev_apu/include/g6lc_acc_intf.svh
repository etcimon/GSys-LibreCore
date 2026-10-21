// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Copied from vendor/ara/upstream/hardware/include/ara/intf_typedef.svh so the
// G6LC APU can type accelerator interfaces without requiring Ara on every
// build. Keep in sync with upstream when Ara intf macros change.
// Local path: corev_apu/include/g6lc_acc_intf.svh

`ifndef G6LC_ACC_INTF_SVH
`define G6LC_ACC_INTF_SVH

`define G6LC_INTF_TYPEDEF_ACC_REQ(accelerator_req_t, G6LCCfg, roundmode_e) \
  typedef struct packed {                                                  \
    logic                             req_valid;                           \
    logic                             resp_ready;                          \
    logic [31:0]                      insn;                                \
    logic [G6LCCfg.XLEN-1:0]          rs1;                                 \
    logic [G6LCCfg.XLEN-1:0]          rs2;                                 \
    roundmode_e                       frm;                                 \
    logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id;                            \
    logic                             store_pending;                       \
    logic                             acc_cons_en;                         \
    logic                             inval_ready;                         \
  } accelerator_req_t;

`define G6LC_INTF_TYPEDEF_ACC_RESP(accelerator_resp_t, G6LCCfg, exception_t) \
  typedef struct packed {                                                    \
    logic                              req_ready;                            \
    logic                              resp_valid;                           \
    logic [G6LCCfg.XLEN-1:0]           result;                               \
    logic [G6LCCfg.TRANS_ID_BITS-1:0]  trans_id;                             \
    exception_t                        exception;                            \
    logic                              store_pending;                        \
    logic                              store_complete;                       \
    logic                              load_complete;                        \
    logic [4:0]                        fflags;                               \
    logic                              fflags_valid;                         \
    logic                              inval_valid;                          \
    logic [63:0]                       inval_addr;                           \
  } accelerator_resp_t;

`define G6LC_INTF_TYPEDEF_MMU_REQ(acc_mmu_req_t, G6LCCfg) \
  typedef struct packed {                                 \
    logic                    acc_mmu_misaligned_ex;       \
    logic                    acc_mmu_req;                 \
    logic [G6LCCfg.VLEN-1:0] acc_mmu_vaddr;               \
    logic                    acc_mmu_is_store;            \
  } acc_mmu_req_t;

`define G6LC_INTF_TYPEDEF_MMU_RESP(acc_mmu_resp_t, G6LCCfg, exception_t) \
  typedef struct packed {                                                \
    logic                    acc_mmu_dtlb_hit;                           \
    logic [G6LCCfg.PPNW-1:0] acc_mmu_dtlb_ppn;                           \
    logic                    acc_mmu_valid;                              \
    logic [G6LCCfg.PLEN-1:0] acc_mmu_paddr;                              \
    exception_t              acc_mmu_exception;                          \
  } acc_mmu_resp_t;

`define G6LC_INTF_TYPEDEF_G6LC_TO_ACC(g6lc_to_acc_t, accelerator_req_t, acc_mmu_resp_t) \
  typedef struct packed {                                                               \
    accelerator_req_t acc_req;                                                          \
    logic             acc_mmu_en;                                                       \
    acc_mmu_resp_t    acc_mmu_resp;                                                     \
  } g6lc_to_acc_t;

`define G6LC_INTF_TYPEDEF_ACC_TO_G6LC(acc_to_g6lc_t, accelerator_resp_t, acc_mmu_req_t) \
  typedef struct packed {                                                               \
    accelerator_resp_t acc_resp;                                                        \
    acc_mmu_req_t      acc_mmu_req;                                                     \
  } acc_to_g6lc_t;

`define G6LC_TYPEDEF_EXCEPTION(exception_t, G6LCCfg)           \
  typedef struct packed {                                      \
    logic [G6LCCfg.XLEN-1:0] cause;                            \
    logic [G6LCCfg.XLEN-1:0] tval;                             \
    logic [G6LCCfg.GPLEN-1:0] tval2;                           \
    logic [31:0] tinst;                                        \
    logic gva  ;                                               \
    logic valid;                                               \
  } exception_t;

`endif
