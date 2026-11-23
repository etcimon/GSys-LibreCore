// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

package g6lc_storamic_pkg;
  localparam logic [1:0] RespSlvErr = 2'b10;

  typedef struct packed {
    logic [7:0] id;
    logic [63:0] addr;
    logic [7:0] len;
    logic [2:0] size;
    logic [1:0] burst;
    logic lock;
    logic [3:0] cache;
    logic [2:0] prot;
    logic [3:0] qos;
    logic [3:0] region;
    logic user;
  } addr_t;

  typedef struct packed {
    logic [63:0] data;
    logic [7:0] strb;
    logic last;
    logic user;
  } write_t;

  typedef struct packed {
    logic [7:0] id;
    logic [1:0] resp;
    logic user;
  } b_t;

  typedef struct packed {
    logic [7:0] id;
    logic [63:0] data;
    logic [1:0] resp;
    logic last;
    logic user;
  } read_t;

  typedef struct packed {
    addr_t aw;
    logic aw_valid;
    write_t w;
    logic w_valid;
    logic b_ready;
    addr_t ar;
    logic ar_valid;
    logic r_ready;
  } axi_req_t;

  typedef struct packed {
    logic aw_ready;
    logic w_ready;
    b_t b;
    logic b_valid;
    logic ar_ready;
    read_t r;
    logic r_valid;
  } axi_resp_t;

  typedef struct packed {
    logic [63:0] addr;
    logic [2:0] prot;
  } axil_addr_t;

  typedef struct packed {
    logic [31:0] data;
    logic [3:0] strb;
  } axil_write_t;

  typedef struct packed {
    axil_addr_t aw;
    logic aw_valid;
    axil_write_t w;
    logic w_valid;
    logic b_ready;
    axil_addr_t ar;
    logic ar_valid;
    logic r_ready;
  } axil_req_t;

  typedef struct packed {
    logic [1:0] resp;
  } axil_b_t;

  typedef struct packed {
    logic [31:0] data;
    logic [1:0] resp;
  } axil_read_t;

  typedef struct packed {
    logic aw_ready;
    logic w_ready;
    axil_b_t b;
    logic b_valid;
    logic ar_ready;
    axil_read_t r;
    logic r_valid;
  } axil_resp_t;

  // Opaque identity echoed by the memory binding; no active-link replay grant.
  // `epoch` separates the finite `seq` spaces of successive fail-safe
  // renewals: after sequence exhaustion the frontend drains, advances the
  // epoch and reuses seq from zero, so a completion from an older epoch can
  // never alias a live tag.
  typedef struct packed {
    logic [31:0] reset_generation;
    logic [7:0] epoch;
    logic [31:0] seq;
    logic [15:0] axi_id;
    logic [7:0] source;
    logic [7:0] beat;
  } txn_id_t;

  // Pulses distinguish admission, media completion, and response retirement.
  typedef struct packed {
    logic aw_accept, ar_accept, w_accept;
    logic b_retire, r_retire;
    logic aw_refuse, ar_refuse;
    logic b_error, r_error, w_protocol_error;
    logic mem_read, mem_write, mem_error, stale_completion;
    logic [1:0] seq_refuse; // [1] AW, [0] AR; both may refuse in one cycle.
    logic seq_renew; // fail-safe renewal: space drained and reused under a new epoch.
    logic [7:0] mem_bytes;  // successful memory-completion bytes only.
  } model_events_t;

  // Maintenance-control results, not a software register ABI.
  typedef enum logic [3:0] {
    CP_OK, CP_DENIED, CP_NOT_READY, CP_RECOVERY_REQUIRED,
    CP_NO_CHECKPOINT, CP_GENERATION_EXHAUSTED, CP_CONTEXT_CHANGED,
    CP_PRODUCER_ERROR, CP_MEDIA_ERROR, CP_TIMEOUT, CP_POWER_CUT,
    CP_PROTOCOL_ERROR
  } checkpoint_result_e;
endpackage
