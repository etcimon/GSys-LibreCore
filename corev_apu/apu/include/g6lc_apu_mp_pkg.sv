// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// APU memory-port protocol (apu_mp) — §6c Settled bullet 1.
// One shared word port per requester over a single AXI master
// (g6lc_apu_apmem).  dom selects the address domain:
//   0 = absolute guest byte address (virtqueue control queue)
//   1 = aperture-relative byte offset (virtio-gpu resource/shm window)
// Semantics: a requester holds req_valid until req_ready; at most one
// request is outstanding per requester; exactly one rsp_valid pulse per
// accepted request, writes included (after the AXI B beat).  rsp.err
// means zero data, no usable beat, and a counted fault.
package g6lc_apu_mp_pkg;
  typedef struct packed {
    logic        dom;
    logic        we;
    logic [63:0] addr;
    logic [63:0] wdata;
    logic [7:0]  wstrb;
  } apu_mp_req_t;

  typedef struct packed {
    logic [63:0] rdata;
    logic        err;
  } apu_mp_rsp_t;

  localparam int unsigned
    APU_MP_PUB  = 0,
    APU_MP_VQ   = 1,
    APU_MP_CTL  = 2,
    APU_MP_PUMP = 3,
    APU_MP_SH   = 4,
    APU_MP_N    = 5;
endpackage
