// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// virtio-gpu control-queue processor (§6b of
// architecture/uncore/apu-vulkan-engine.md).  Consumes one descriptor
// chain (<= 4 descriptors; READ descriptors carry the request, the
// first WRITE descriptor receives the response), executes the UAPI
// control command, writes the response header + body, and reports the
// truthful used length.  `SUBMIT_3D` is handed to the Venus ring pump
// (`xs_*`); every other command is answered locally.
//
// Supported commands (UAPI values in g6lc_apu_vg_pkg): GET_CAPSET_INFO
// (index 0 -> Venus capset, generated APU_VN_CAPSET words),
// GET_CAPSET, CTX_CREATE (context_init & 0xff must be 4), CTX_DESTROY,
// CTX_ATTACH/DETACH_RESOURCE, RESOURCE_CREATE_BLOB (HOST3D|MAPPABLE;
// blob_id 0 -> 4 KiB-page aperture allocation + ObjTab BLOB entry
// with bind_offset/size; blob_id != 0 resolves a VkDeviceMemory
// object of that driver id and maps the resource onto the memory's
// aperture extent, aux[0]=1 marking it memory-backed so UNREF does
// not free the pages — the memory object owns them),
// RESOURCE_MAP_BLOB (RESP_OK_MAP_INFO, VIRTIO_GPU_MAP_CACHE_WC, the
// window-relative offset), RESOURCE_UNMAP_BLOB, RESOURCE_UNREF,
// SUBMIT_3D (execbuffer handoff; `size` beyond the chain payload is
// RESP_ERR_UNSPEC).  Unknown type -> RESP_ERR_UNSPEC; a chain too
// short for the declared request gets a header-only response and a
// truthful used length.  flags&FENCE echoes fence_id in the response
// and pulses fence_done_o after the command completes (after the pump
// finishes for SUBMIT_3D).
//
// Aperture pages come from the shared g6lc_apu_vgpages allocator
// (pg_* port, grant-arbitrated in vgtop with the vnfront
// vkAllocateMemory path).  ObjTab kind APU_VN_KIND_APU_BLOB_SHMEM
// entries carry bind_offset = APU_VG_SHM_BASE + window offset and
// size.
//
// Timing impact: one guest-mem word or one ObjTab transaction per
// micro-step; the page scan is a single 256-entry first-fit cone.
// The 64-word request and 48-word response staging buffers are flops.
//
// Review checklist: async active-low reset; no latches; single
// always_ff for state; Enable=0 elaborates no datapath.

module g6lc_apu_vgctl
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable   = 1'b0
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  // one descriptor chain (avail element -> <=4 descriptors)
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  // guest memory word port (§6c handshake form): mem_req_o held until
  // mem_ready_i, one mem_rvalid_i per request (writes included);
  // mem_err_i returns zero data — a read err truncates the chain like
  // a short chain, a write err sets mem_fault_o and finishes
  output logic            mem_req_o,
  output logic            mem_we_o,
  output logic            mem_dom_o,   // 1 = aperture-relative (mover)
  output logic [63:0]     mem_addr_o,
  output logic [63:0]     mem_wdata_o,
  output logic [7:0]      mem_wstrb_o,
  input  logic            mem_ready_i,
  input  logic            mem_rvalid_i,
  input  logic [63:0]     mem_rdata_i,
  input  logic            mem_err_i,
  output logic            mem_fault_o,   // sticky write fault
  // ObjTab port
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
  // aperture page allocator port (§7b/5a-ii, arbitrated in vgtop)
  output logic             pg_req_valid_o,
  input  logic             pg_req_ready_i,
  output apu_vgpages_req_t pg_req_o,
  input  logic             pg_cpl_valid_i,
  output logic             pg_cpl_ready_o,
  input  apu_vgpages_cpl_t pg_cpl_i,
  // ObjPay + ShaderCore-slot ports for the RESET_CTX reap: the sweep
  // reports each tombstoned entry (APU_OBJTAB_SWEEP) and vgctl frees
  // the resource it owned — layout payload extents here, module/
  // pipeline slot refs on the sm port (level-held request; sm_gnt_i
  // marks the cycle the arbiter accepted it)
  output logic            op_req_valid_o,
  input  logic            op_req_ready_i,
  output apu_objpay_req_t op_req_o,
  input  logic            op_cpl_valid_i,
  output logic            op_cpl_ready_o,
  input  apu_objpay_cpl_t op_cpl_i,
  output logic            sm_req_o,
  output apu_sh_sm_req_t  sm_req_pl_o,
  input  logic            sm_gnt_i,
  input  logic            sm_cpl_i,
  input  apu_sh_sm_cpl_t  sm_cpl_pl_i,
  // pump handoff: SUBMIT_3D execbuffer stream (guest memory)
  output logic            xs_valid_o,
  input  logic            xs_ready_i,
  output apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_desc_o,
  output logic [3:0]      xs_ndesc_o,      // READ descriptors
  output logic [31:0]     xs_off_o,        // payload byte off in read space
  output logic [31:0]     xs_bytes_o,
  output logic [7:0]      xs_ctx_o,
  input  logic            xs_done_i,
  input  logic            xs_fault_i,
  // context kill: one registered pulse per CTX_DESTROY so the ring
  // pump can retire that context's rings deterministically (they
  // would otherwise linger as defence-in-depth ring_overlap only)
  output logic            ctx_kill_valid_o,
  output logic [7:0]      ctx_kill_id_o,
  // §12.3 3d-d: DEVBACKED MAP_BLOB relocation — hold_o blocks new
  // cmdexec submissions for the whole move; drain_idle_i
  // (cmdexec+xfer+shcore all at rest, aggregated in vgtop) gates the
  // first word move.  The kernel waits on the map fence, so stalling
  // the control queue here is legal.
  output logic            hold_o,
  input  logic            drain_idle_i,
  // completion
  output logic            busy_o,
  output logic            done_o,          // pulse: resp+used published
  output logic [31:0]     used_len_o,
  output logic            fence_done_o,    // pulse {fence_id, ring_idx}
  output logic [63:0]     fence_id_o,
  output logic [7:0]      fence_ring_o
);
  localparam int unsigned REQW   = 64;    // request staging words
  localparam int unsigned RESPW  = 48;    // response staging words
  // request sizes in 32-bit words (UAPI struct = 6-word hdr + body)
  function automatic logic [8:0] req_words(input logic [31:0] ty);
    case (ty)
      APU_VG_GET_CAPSET_INFO: return 9'd8;
      APU_VG_GET_CAPSET:      return 9'd8;
      APU_VG_CTX_CREATE:      return 9'd24;
      APU_VG_CTX_DESTROY:     return 9'd6;
      APU_VG_CTX_ATTACH:      return 9'd8;
      APU_VG_CTX_DETACH:      return 9'd8;
      APU_VG_SUBMIT_3D:       return 9'd8;
      APU_VG_MAP_BLOB:        return 9'd10;
      APU_VG_UNMAP_BLOB:      return 9'd8;
      APU_VG_CREATE_BLOB:     return 9'd14;
      APU_VG_UNREF:           return 9'd8;
      default:                return 9'd0;   // unknown: stage all reads
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign chain_ready_o = 1'b0;
    assign mem_req_o = 1'b0;     assign mem_we_o = 1'b0;
    assign mem_dom_o = 1'b0;
    assign mem_addr_o = '0;      assign mem_wdata_o = '0;
    assign mem_wstrb_o = '0;     assign mem_fault_o = 1'b0;
    assign ot_req_valid_o = 1'b0; assign ot_req_o = '0;
    assign ot_cpl_ready_o = 1'b0;
    assign pg_req_valid_o = 1'b0; assign pg_req_o = '0;
    assign pg_cpl_ready_o = 1'b0;
    assign op_req_valid_o = 1'b0; assign op_req_o = '0;
    assign op_cpl_ready_o = 1'b0;
    assign sm_req_o = 1'b0;       assign sm_req_pl_o = '0;
    assign xs_valid_o = 1'b0;    assign xs_desc_o = '{default: '0};
    assign xs_ndesc_o = '0;      assign xs_off_o = '0;
    assign xs_bytes_o = '0;      assign xs_ctx_o = '0;
    assign ctx_kill_valid_o = 1'b0; assign ctx_kill_id_o = '0;
    assign hold_o = 1'b0;
    assign busy_o = 1'b0;        assign done_o = 1'b0;
    assign used_len_o = '0;
    assign fence_done_o = 1'b0;  assign fence_id_o = '0;
    assign fence_ring_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | chain_valid_i |
                    (|chain_n_i) | (|chain_desc_i[0]) | mem_rdata_i |
                    mem_ready_i | mem_rvalid_i | mem_err_i |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    pg_req_ready_i | pg_cpl_valid_i | (|pg_cpl_i) |
                    op_req_ready_i | op_cpl_valid_i | (|op_cpl_i) |
                    sm_gnt_i | sm_cpl_i | (|sm_cpl_pl_i) |
                    xs_ready_i | xs_done_i | xs_fault_i |
                    drain_idle_i |
                    (|chain_desc_i[1]) | (|chain_desc_i[2]) |
                    (|chain_desc_i[3]);
  end else begin : gen_on
    typedef enum logic [5:0] {
      StIdle, StRdDesc, StRdFire, StRdCap, StHdr, StBody,
      StDispatch, StOtReq, StOtCpl, StBindReq, StBindCpl,
      StMemReq, StMemCpl, StAuxReq, StAuxCpl, StAuxHiReq, StAuxHiCpl,
      StPgReq, StPgCpl, StXsFire, StXsWait,
      StMapAllocAt, StMapBind, StMapMemReq, StMapMemCpl,
      StMapAuxReq, StMapAuxCpl, StUnmapPriv,
      // §12.3 3d-d: DEVBACKED relocation — drain, squatter eviction
      // scan, word mover, base publish, flag clear
      StMapDrain, StMapScan, StMapScanC,
      StMapEvMv, StMapEvFree, StMapEvPub, StMapEvPubC,
      StMapMv, StMapMvF, StMapDevAux, StMapDevAuxC, StMapMvFail,
      StMvRd, StMvRdC, StMvWr, StMvWrC,
      StReapDec, StReapOpReq, StReapOpCpl, StReapSmReq, StReapSmCpl,
      StWrPrep, StWrFind, StWrFire, StWrCap, StDone, StFence
    } state_e;
    state_e state_q;

    apu_vg_desc_t [APU_VG_MAX_DESC-1:0] desc_q;
    logic [3:0]   ndesc_q;
    logic [2:0]   rd_d_q;        // current read-desc index
    logic [2:0]   wr_d_q;        // first write-desc index
    logic [31:0]  rd_off_q;      // byte offset into current read desc
    logic [31:0]  read_len_q;    // total READ bytes staged so far
    logic [8:0]   stage_q;       // words staged into req_ram
    logic [31:0]  req_ram [REQW];
    logic [31:0]  resp_ram [RESPW];
    logic [8:0]   resp_n_q;      // response words
    logic [8:0]   wr_w_q;        // response write cursor (words)
    logic [63:0]  resp_addr_q;   // current write-desc byte addr
    logic [31:0]  resp_left_q;   // bytes left in write desc
    logic [31:0]  used_q;
    logic [8:0]   need_q;        // request size in words
    logic [31:0]  rtype_q, rflags_q, rctx_q, rring_q;
    logic [63:0]  rfence_q;
    logic         trunc_q;       // chain short of the declared request
    logic [31:0]  payload_b_q;   // SUBMIT_3D payload bytes handed off
    logic [63:0]  blob_addr_q, blob_size_q;
    // §7b: blob_id != 0 maps a DEVICE_MEMORY object; aux[0] marks the
    // blob memory-backed so UNREF leaves the pages to the memory.
    logic         blob_mem_q;
    // MAP_BLOB relocation state: the guest kernel dictates the SHM
    // offset, so a map onto a different extent frees/reallocates pages
    logic [63:0]  map_size_q;
    logic         map_memb_q;    // memory-backed blob (aux[0])
    logic [31:0]  map_memh_q;    // {gen,slot} of the DEVICE_MEMORY
    logic [31:0]  auxv_q;        // SETAUXHI value (map offset / priv base)
    logic         map_unmap_q;   // StMapMem* serving UNMAP_BLOB
    logic         mem_fault_q;   // sticky write fault (§6c)
    // §12.3 3d-d: DEVBACKED relocation bookkeeping
    logic         map_hold_q;    // cmdexec submission hold (hold_o)
    logic         map_dev_q;     // M was DEVBACKED — clear at publish
    logic         map_unb_q;     // M was UNBACKED — publish via CAS
    logic [31:0]  map_oldb_q;    // M's device-chosen base B
    logic [31:0]  ovl_h_q;       // squatter {gen,slot}
    logic [31:0]  ovl_base_q;    // squatter extent base
    logic [63:0]  ovl_size_q;    // squatter extent size
    logic [31:0]  ovl_newb_q;    // squatter's evicted base (ALLOC_HI)
    // word mover: aperture-relative src/dst + byte cursors, one
    // 64-bit read then write per beat (≤1 outstanding — a rare path;
    // an xfer-DMA variant is a documented follow-up).  mv_rev_q walks
    // the copy backwards when dst > src so an overlapping move cannot
    // read what it already rewrote (the evicted extent's new base can
    // sit above the kernel range and still touch the old extent)
    logic [31:0]  mv_src_q, mv_dst_q, mv_len_q, mv_i_q;
    logic         mv_rev_q;
    logic [63:0]  mv_word_q;
    state_e       mv_ret_q;
    // relocation cost observability: cumulative cycles under the
    // submission hold (drain + evictions + move + publish), read out
    // through the bridge debug taps / unit TBs
    logic [31:0]  reloc_cyc_q;
    // page-allocator in-flight op
    apu_vgpages_op_e pg_op_q;
    logic [31:0]  pg_base_q, pg_bytes_q;
    logic [31:0]  pg_exclh_q;    // ALLOC_HI exclusion high
    state_e       pg_ret_q;
    // RESET_CTX reap: tombstoned entry fields reported by the sweep's
    // interim SWEEP completions (§6c teardown order — the kernel unmaps
    // the resources after CTX_DESTROY, so the extents must already be
    // back in the allocator)
    logic [5:0]   reap_kind_q;
    logic [63:0]  reap_aux_q, reap_size_q;
    // G3b-ii: the swept entry's {gen,slot} (module INVAL needs the
    // handle form) plus reap-path selectors — a module sweeps its
    // pCode extent AND its residency line; a pipeline sweeps its
    // module-descriptor/state block at aux[31:16] (aux[6] = graphics)
    logic [15:0]  reap_gen_q, reap_slot_q;
    logic         reap_inval_q, reap_ppipe_q;

    // bytes remaining in current read desc
    logic [31:0] rd_rem;
    assign rd_rem = desc_q[rd_d_q[1:0]].len - rd_off_q;
    // request words needed: unknown type -> stage everything readable
    logic [8:0] stage_goal;
    assign stage_goal = (need_q == 9'd0) ? 9'(REQW) : need_q;

    assign chain_ready_o = state_q == StIdle && rst_ni;
    assign busy_o = state_q != StIdle;
    // §12.3 3d-d: submission hold spans the entire DEVBACKED
    // relocation (drain + evictions + move + publish); every exit —
    // success or refusal — lands in StWrPrep, which clears it
    assign hold_o = map_hold_q;
    assign done_o = state_q == StDone;
    assign used_len_o = used_q;
    assign fence_done_o = state_q == StFence;
    assign fence_id_o = rfence_q;
    assign fence_ring_o = 8'(rring_q);

    // ---- guest mem port (handshake) ----------------------------------------
    // 32-bit accesses at 4-byte-aligned guest addresses; the AXI beat
    // is 8 bytes, so wdata/wstrb/rdata are positioned by addr[2].
    // the word mover rides this port in the aperture domain (dom=1):
    // mv_*_q/mv_i_q are already aperture-relative byte offsets, so no
    // SHM base is added — the requester-facing contract stays byte
    // granularity on both domains
    assign mem_req_o   = state_q == StRdFire || state_q == StWrFire ||
                         state_q == StMvRd || state_q == StMvWr;
    assign mem_we_o    = state_q == StWrFire || state_q == StMvWr;
    assign mem_dom_o   = state_q == StMvRd || state_q == StMvWr;
    assign mem_addr_o  = state_q == StMvRd
                         ? 64'(mv_src_q) + 64'(mv_i_q)
                       : state_q == StMvWr
                         ? 64'(mv_dst_q) + 64'(mv_i_q)
                       : (state_q == StWrFire) ? resp_addr_q :
                         desc_q[rd_d_q[1:0]].addr + 64'(rd_off_q);
    assign mem_wdata_o = state_q == StMvWr ? mv_word_q
                       : mem_addr_o[2] ? {resp_ram[wr_w_q[5:0]], 32'h0}
                                       : {32'h0, resp_ram[wr_w_q[5:0]]};
    assign mem_wstrb_o = state_q == StMvWr ? 8'hFF
                                           : mem_addr_o[2] ? 8'hF0
                                                           : 8'h0F;
    assign mem_fault_o = mem_fault_q;
    // bit2 of the issued read address, for the rdata half-select
    logic rd_hi;
    assign rd_hi = desc_q[rd_d_q[1:0]].addr[2] ^ rd_off_q[2];

    // ---- ObjTab port -------------------------------------------------------
    logic ot_fire;
    assign ot_fire = state_q == StOtReq || state_q == StBindReq ||
                     state_q == StMemReq || state_q == StAuxReq ||
                     state_q == StAuxHiReq ||
                     state_q == StMapMemReq || state_q == StMapAuxReq ||
                     state_q == StMapScan  || state_q == StMapEvPub ||
                     state_q == StMapDevAux;
    assign ot_req_valid_o = ot_fire;
    assign ot_cpl_ready_o = state_q == StOtCpl || state_q == StBindCpl ||
                            state_q == StMemCpl || state_q == StAuxCpl ||
                            state_q == StAuxHiCpl ||
                            state_q == StMapMemCpl ||
                            state_q == StMapAuxCpl ||
                            state_q == StMapScanC ||
                            state_q == StMapEvPubC ||
                            state_q == StMapDevAuxC;
    always_comb begin
      ot_req_o = apu_objtab_req_t'('0);
      unique case (state_q)
        StMemReq: ot_req_o = '{op: APU_OBJTAB_OP_LOOKUP,
            // blob_id = the VkDeviceMemory client object id; tag it
            // into the client-id namespace (APU_VN_ID_TAG, bit 33),
            // disjoint from the resource-id namespace below
            id: APU_VN_ID_TAG | {req_ram[11], req_ram[10]},
            kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY), default: '0};
        StAuxReq: ot_req_o = '{op: APU_OBJTAB_OP_SETAUX,
            id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
            kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM),
            // aux[0] = memory-backed; aux[31:8] = low 24 bits of the
            // memory client id (debug shadow; resolution uses the
            // {gen,slot} handle in aux[63:32])
            mask: 32'hFF_FF_FF_01,
            value: {req_ram[10][23:0], 8'h1},
            default: '0};
        StAuxHiReq: ot_req_o = '{op: APU_OBJTAB_OP_SETAUXHI,
            id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
            kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM),
            // aux[63:32] = {gen,slot} of the backing VkDeviceMemory
            mask: 32'hFF_FF_FF_FF, value: map_memh_q, default: '0};
        StMapMemReq: ot_req_o = '{op: APU_OBJTAB_OP_LOOKUP,
            // map_memh_q is the VkDeviceMemory {gen,slot} handle
            // recorded in the blob's aux[63:32] at create — handle
            // form survives 64-bit client ids (aux[31:8] truncates)
            id: {32'h0, map_memh_q},
            kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY), default: '0};
        StMapAuxReq: begin
          if (!map_unmap_q && !map_dev_q && map_unb_q) begin
            // §12.3 3d-d: plain path on an UNBACKED memory — publish
            // the kernel offset atomically.  A ring-queue bind can
            // land between our LOOKUP and this write; if its DEVBACKED
            // publish won, the CAS reports CONFLICT and the map
            // restarts as a relocation (StMapAuxCpl).  A backed base
            // (type-0 private extent or a kernel remap) goes through
            // the unconditional publish — the bind-side CAS only ever
            // fires on UNBACKED, so it cannot lose a race here
            ot_req_o = '{op: APU_OBJTAB_OP_SETAUXHI_CAS,
                id: {32'h0, map_memh_q},
                kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
                offset: {32'h0, APU_MEM_UNBACKED},
                mask: 32'h0, value: auxv_q, default: '0};
          end else begin
            ot_req_o = '{op: APU_OBJTAB_OP_SETAUXHI,
                id: {32'h0, map_memh_q},             // {gen,slot} handle
                // ObjTab enforces kind on every non-ALLOC op — required
                kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
                // map path: the kernel's offset; unmap path: the
                // UNBACKED sentinel a re-mappable lazy memory rests at
                mask: 32'hFF_FF_FF_FF, value: auxv_q, default: '0};
          end
        end
        StMapScan: ot_req_o = '{op: APU_OBJTAB_OP_SCAN_OVL,
            // §12.3 3d-d: first live DEVBACKED DEVICE_MEMORY ≠ M whose
            // extent overlaps the kernel's [K, K+S) — id[15:0] is the
            // excluded slot, {offset,size} is the probe window
            id: {48'h0, map_memh_q[15:0]},
            kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
            offset: 64'({req_ram[9], req_ram[8]}),
            size: 64'({req_ram[9], req_ram[8]}) + map_size_q,
            default: '0};
        StMapEvPub: ot_req_o = '{op: APU_OBJTAB_OP_SETAUXHI,
            id: {32'h0, ovl_h_q},
            kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
            // the squatter's evicted base; it stays DEVBACKED — a later
            // kernel map of it relocates it the same way
            mask: 32'hFF_FF_FF_FF, value: ovl_newb_q, default: '0};
        StMapDevAux: ot_req_o = '{op: APU_OBJTAB_OP_SETAUX,
            id: {32'h0, map_memh_q},
            kind: 6'(APU_VN_KIND_VK_DEVICE_MEMORY),
            // relocation done: M now sits at the kernel's offset and is
            // no longer device-relocatable
            mask: 32'h0000_0001, value: 32'h0, default: '0};
        StOtReq: begin
          unique case (rtype_q)
            APU_VG_CTX_CREATE: ot_req_o = '{op: APU_OBJTAB_OP_ALLOC,
                id: APU_VG_CTX_TAG | {32'h0, rctx_q},
                kind: 6'(APU_VN_KIND_APU_VIRTIO_CTX),
                ctx: 8'(rctx_q), default: '0};
            APU_VG_CTX_DESTROY: ot_req_o = '{op: APU_OBJTAB_OP_RESET_CTX,
                ctx: 8'(rctx_q), default: '0};
            APU_VG_CREATE_BLOB: ot_req_o = '{op: APU_OBJTAB_OP_ALLOC,
                id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
                kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM),
                // blobs are device-global resources — attach/detach is
                // access control, not ownership — so they live in the
                // never-destroyed context 0 and UNREF retires them,
                // not a CTX_DESTROY sweep (vn_golden parity)
                ctx: 8'h0, default: '0};
            APU_VG_UNREF: ot_req_o = '{op: APU_OBJTAB_OP_RETIRE,
                id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
                kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM), default: '0};
            default: ot_req_o = '{op: APU_OBJTAB_OP_LOOKUP,
                id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
                kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM), default: '0};
          endcase
        end
        default: ot_req_o = '{op: APU_OBJTAB_OP_SETBIND,
            id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
            kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM),
            mem_id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
            offset: blob_addr_q, size: blob_size_q, default: '0};
      endcase
    end

    // ---- page-allocator port ----------------------------------------------
    assign pg_req_valid_o = state_q == StPgReq;
    assign pg_cpl_ready_o = state_q == StPgCpl;
    assign pg_req_o = '{op: pg_op_q, base: pg_base_q,
                       excl_hi: pg_exclh_q,
                       bytes: pg_bytes_q};

    // ---- ObjPay / ShaderCore-slot reap ports ------------------------------
    assign op_req_valid_o = state_q == StReapOpReq;
    assign op_cpl_ready_o = state_q == StReapOpCpl;
    // aux[63:32] = {base>>6[15:0], words[15:0]} — vnfront parks the
    // ObjPay extent's chunk index; the FREE port takes the word
    // address back, so the packed base unparks with <<6.  G3b-ii: a
    // pipeline parks its block in aux[31:16] instead (state block +
    // module descriptors) — aux[6] (graphics) picks the word count
    assign op_req_o = '{op: APU_OBJPAY_OP_FREE,
                       addr: reap_ppipe_q
                             ? ({16'h0, reap_aux_q[31:16]} << 6)
                             : ({16'h0, reap_aux_q[63:48]} << 6),
                       words: reap_ppipe_q
                              ? (reap_aux_q[6] ? 32'd48 : 32'd2)
                              : {16'h0, reap_aux_q[47:32]},
                       default: '0};
    assign sm_req_o    = state_q == StReapSmReq;
    // G3b-ii: a swept module's residency line is invalidated by its
    // {gen,slot} handle — the entry is already tombstoned, so no
    // ObjTab walk is needed for the tag
    assign sm_req_pl_o = '{op: APU_SH_SM_INVAL,
                          handle: {reap_gen_q, reap_slot_q},
                          default: '0};

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        desc_q <= '{default: '0};
        ndesc_q <= '0; rd_d_q <= '0; wr_d_q <= '0;
        rd_off_q <= '0; read_len_q <= '0; stage_q <= '0;
        resp_n_q <= '0; wr_w_q <= '0; resp_addr_q <= '0;
        resp_left_q <= '0; used_q <= '0; need_q <= '0;
        rtype_q <= '0; rflags_q <= '0; rctx_q <= '0; rring_q <= '0;
        rfence_q <= '0; trunc_q <= 1'b0; payload_b_q <= '0;
        blob_addr_q <= '0; blob_size_q <= '0; blob_mem_q <= 1'b0;
        map_size_q <= '0; map_memb_q <= 1'b0;
        map_memh_q <= '0;
        auxv_q <= '0; map_unmap_q <= 1'b0;
        mem_fault_q <= 1'b0;
        map_hold_q <= 1'b0; map_dev_q <= 1'b0; map_unb_q <= 1'b0;
        map_oldb_q <= '0;
        ovl_h_q <= '0; ovl_base_q <= '0; ovl_size_q <= '0;
        ovl_newb_q <= '0;
        mv_src_q <= '0; mv_dst_q <= '0; mv_len_q <= '0;
        mv_i_q <= '0; mv_rev_q <= 1'b0; mv_word_q <= '0;
        mv_ret_q <= StIdle;
        reloc_cyc_q <= '0;
        pg_op_q <= APU_VGPAGES_OP_ALLOC; pg_base_q <= '0;
        pg_exclh_q <= '0;
        pg_bytes_q <= '0; pg_ret_q <= StIdle;
        reap_kind_q <= '0; reap_aux_q <= '0; reap_size_q <= '0;
        reap_gen_q <= '0; reap_slot_q <= '0;
        reap_inval_q <= 1'b0; reap_ppipe_q <= 1'b0;
        ctx_kill_valid_o <= 1'b0; ctx_kill_id_o <= '0;
        for (int i = 0; i < REQW; i++) req_ram[i] <= '0;
        for (int i = 0; i < RESPW; i++) resp_ram[i] <= '0;
      end else begin
        ctx_kill_valid_o <= 1'b0;
        if (map_hold_q) reloc_cyc_q <= reloc_cyc_q + 1;
        unique case (state_q)
          // ----------------------------------------------------------
          StIdle: begin
            if (chain_valid_i) begin
              desc_q <= chain_desc_i;
              ndesc_q <= chain_n_i;
              rd_d_q <= '0; rd_off_q <= '0; read_len_q <= '0;
              stage_q <= '0; wr_w_q <= '0; resp_n_q <= '0;
              used_q <= '0; need_q <= '0; trunc_q <= 1'b0;
              map_dev_q <= 1'b0;
              // mem_fault_q is NOT cleared here: it is sticky across
              // chains and resets only with rst_ni (the §6c engine
              // reset — vgtop's mem_fault_o feeds vgsys bus_fault_o)
              payload_b_q <= '0;
              state_q <= StRdDesc;
            end
          end

          // ---- stage request words across all READ descriptors --------
          StRdDesc: begin
            if (4'(rd_d_q) >= 4'(ndesc_q) ||
                stage_q >= stage_goal ||
                stage_q >= 9'(REQW)) begin
              state_q <= StHdr;
            end else if (desc_q[rd_d_q[1:0]].write) begin
              rd_d_q <= rd_d_q + 2'd1;   // skip WRITE descriptors
            end else if (rd_rem == 32'd0) begin
              rd_d_q <= rd_d_q + 2'd1;
              rd_off_q <= '0;
            end else begin
              state_q <= StRdFire;
            end
          end
          StRdFire: if (mem_ready_i) state_q <= StRdCap;
          StRdCap: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) begin
                // out-of-window chain buffer: answer like a truncated
                // chain (header-only response, truthful used length)
                trunc_q <= 1'b1;
                state_q <= StHdr;
              end else begin
                req_ram[stage_q[5:0]] <=
                  rd_hi ? mem_rdata_i[63:32] : mem_rdata_i[31:0];
                stage_q <= stage_q + 9'd1;
                rd_off_q <= rd_off_q + 32'd4;
                read_len_q <= read_len_q + 32'd4;
                state_q <= StRdDesc;
              end
            end
          end

          // ---- header parse --------------------------------------------
          StHdr: begin
            if (stage_q < 9'd6) begin
              // truncated before even the header: nothing to answer
              trunc_q <= 1'b1;
              rtype_q <= '0;
              state_q <= StDispatch;
            end else begin
              rtype_q <= req_ram[0];
              rflags_q <= req_ram[1];
              rfence_q <= {req_ram[3], req_ram[2]};
              rctx_q <= req_ram[4];
              rring_q <= req_ram[5];
              need_q <= req_words(req_ram[0]);
              state_q <= StBody;
            end
          end
          StBody: begin
            // all needed request words are staged; mark truncation
            if (stage_q < req_words(req_ram[0])) trunc_q <= 1'b1;
            state_q <= StDispatch;
          end

          // ---- dispatch --------------------------------------------------
          StDispatch: begin
            // response header always staged first
            resp_ram[0] <= APU_VG_RESP_NODATA;   // overwritten per arm
            resp_ram[1] <= (rflags_q & APU_VG_FLAG_FENCE) != 0
                           ? APU_VG_FLAG_FENCE : 32'h0;
            resp_ram[2] <= rfence_q[31:0];
            resp_ram[3] <= rfence_q[63:32];
            resp_ram[4] <= rctx_q;
            resp_ram[5] <= rring_q;
            resp_n_q <= 9'd6;
            if (trunc_q) begin
              resp_ram[0] <= APU_VG_ERR_PARAM;
              state_q <= StWrPrep;
            end else begin
              unique case (rtype_q)
                APU_VG_GET_CAPSET_INFO: begin
                  if (req_ram[6] == 32'd0) begin
                    resp_ram[0] <= APU_VG_RESP_CAPSET_INFO;
                    resp_ram[6] <= APU_VG_CAPSET_VENUS;
                    resp_ram[7] <= 32'd1;   // capset_max_version
                    resp_ram[8] <= 32'(APU_VN_CAPSET_WORDS * 4); // max_size
                    resp_ram[9] <= 32'd0;
                    resp_n_q <= 9'd10;
                  end else begin
                    resp_ram[0] <= APU_VG_ERR_PARAM;
                  end
                  state_q <= StWrPrep;
                end
                APU_VG_GET_CAPSET: begin
                  if (req_ram[6] == APU_VG_CAPSET_VENUS) begin
                    resp_ram[0] <= APU_VG_RESP_CAPSET;
                    for (int i = 0; i < APU_VN_CAPSET_WORDS; i++)
                      resp_ram[6 + i] <= APU_VN_CAPSET[i];
                    resp_n_q <= 9'(6 + APU_VN_CAPSET_WORDS);
                  end else begin
                    resp_ram[0] <= APU_VG_ERR_PARAM;
                  end
                  state_q <= StWrPrep;
                end
                APU_VG_CTX_CREATE: begin
                  if ((req_ram[7] & APU_VG_CTX_INIT_MASK)
                      != APU_VG_CAPSET_VENUS) begin
                    resp_ram[0] <= APU_VG_ERR_PARAM;
                    state_q <= StWrPrep;
                  end else begin
                    state_q <= StOtReq;   // ALLOC the context entry
                  end
                end
                APU_VG_CTX_DESTROY: begin
                  // deterministic ring retirement: notify vnpump the
                  // context is dead so its rings stop publishing
                  ctx_kill_valid_o <= 1'b1;
                  ctx_kill_id_o    <= 8'(rctx_q);
                  state_q          <= StOtReq;   // RESET_CTX
                end
                APU_VG_CTX_ATTACH, APU_VG_CTX_DETACH: begin
                  state_q <= StOtReq;     // LOOKUP the resource
                end
                APU_VG_CREATE_BLOB: begin
                  if (req_ram[7] != APU_VG_BLOB_HOST3D ||
                      (req_ram[8] & APU_VG_BLOB_MAPPABLE) == 32'h0 ||
                      {req_ram[13], req_ram[12]} == 64'h0) begin
                    resp_ram[0] <= APU_VG_ERR_PARAM;
                    state_q <= StWrPrep;
                  end else if ({req_ram[11], req_ram[10]} != 64'h0) begin
                    // blob_id != 0: resolve the VkDeviceMemory of that
                    // driver id; the resource maps onto its aperture
                    // extent (LOOKUP -> ALLOC -> SETBIND -> aux[0]).
                    blob_mem_q <= 1'b1;
                    state_q    <= StMemReq;
                  end else begin
                    // §12.3 F5: blob-owned backing is LAZY — every
                    // MAPPABLE blob is moved into the guest window by
                    // MAP_BLOB immediately, so an extent taken at
                    // create would only sit in the private arena until
                    // freed again (and Mesa's 8 MiB cs pool does not
                    // fit an 8 MiB private arena at all).  An unmapped
                    // blob is bind_offset 0 — the same sentinel the
                    // unmap path already tests.
                    blob_mem_q  <= 1'b0;
                    blob_addr_q <= '0;
                    blob_size_q <= {req_ram[13], req_ram[12]};
                    state_q     <= StOtReq;
                  end
                end
                APU_VG_MAP_BLOB, APU_VG_UNMAP_BLOB, APU_VG_UNREF: begin
                  state_q <= StOtReq;     // LOOKUP / RETIRE
                end
                APU_VG_SUBMIT_3D: begin
                  if (req_ram[6] == 32'd0) begin
                    // empty execbuffer: a sync-only batch (Mesa signals
                    // fences/syncobjs through size-0 SUBMIT_3D); nothing
                    // to execute, answer OK_NODATA and let the fence fire
                    state_q <= StWrPrep;
                  end else if (64'(req_ram[6]) >
                               64'(read_len_q) - 64'd32) begin
                    resp_ram[0] <= APU_VG_ERR_UNSPEC;
                    state_q <= StWrPrep;
                  end else begin
                    // payload begins 32 bytes into the READ space
                    state_q <= StXsFire;
                  end
                end
                default: begin
                  resp_ram[0] <= APU_VG_ERR_UNSPEC;
                  state_q <= StWrPrep;
                end
              endcase
            end
          end

          // ---- aperture page allocator (§7b) -------------------------
          StPgReq: if (pg_req_ready_i) state_q <= StPgCpl;
          StPgCpl: begin
            if (pg_cpl_valid_i) begin
              if (pg_op_q == APU_VGPAGES_OP_ALLOC ||
                  pg_op_q == APU_VGPAGES_OP_ALLOC_PRIV) begin
                if (pg_cpl_i.status == APU_VGPAGES_OK) begin
                  // window-relative byte offset -> SHM window address
                  blob_addr_q <= APU_VG_SHM_BASE +
                                 64'(pg_cpl_i.base);
                  auxv_q      <= pg_cpl_i.base;
                  state_q <= pg_ret_q;
                end else begin
                  resp_ram[0] <= APU_VG_ERR_PARAM;  // aperture exhausted
                  state_q <= StWrPrep;
                end
              end else if (pg_op_q == APU_VGPAGES_OP_ALLOC_AT) begin
                if (pg_cpl_i.status == APU_VGPAGES_OK)
                  state_q <= pg_ret_q;
                else begin
                  // the kernel's offset collides with a live allocation
                  // or lies outside the window: honest refusal
                  resp_ram[0] <= APU_VG_ERR_UNSPEC;
                  state_q <= StWrPrep;
                end
              end else if (pg_op_q == APU_VGPAGES_OP_ALLOC_HI) begin
                if (pg_cpl_i.status == APU_VGPAGES_OK) begin
                  // squatter's new high-window extent (§12.3 3d-d)
                  ovl_newb_q <= pg_cpl_i.base;
                  state_q    <= pg_ret_q;
                end else begin
                  // no room to evict: the map fails, M and X unchanged
                  // (the hold drops in StWrPrep)
                  resp_ram[0] <= APU_VG_ERR_OUT_OF_MEMORY;
                  state_q <= StWrPrep;
                end
              end else begin
                state_q <= pg_ret_q;                // FREE result ignored
              end
            end
          end

          // ---- MAP_BLOB relocation (kernel-chosen SHM offset) --------
          // blob-owned: free ran first; reserve the requested extent.
          // A DEVBACKED memory (map_dev_q) resumes at the word mover —
          // its contents follow it to the kernel's offset.
          StMapAllocAt: begin
            pg_op_q    <= APU_VGPAGES_OP_ALLOC_AT;
            pg_base_q  <= req_ram[8];
            pg_bytes_q <= map_size_q[31:0];
            pg_ret_q   <= map_dev_q ? StMapMv : StMapBind;
            state_q    <= StPgReq;
          end

          // ---- §12.3 3d-d: DEVBACKED relocation ---------------------
          // hold_o is already up: block new submissions until the
          // engines drain (the kernel waits on the map fence)
          StMapDrain: if (drain_idle_i) state_q <= StMapScan;
          // squatter sweep: first DEVBACKED DEVICE_MEMORY ≠ M whose
          // extent overlaps the kernel's [K, K+S)
          StMapScan:  if (ot_req_ready_i) state_q <= StMapScanC;
          StMapScanC: begin
            if (ot_cpl_valid_i) begin
              if (ot_cpl_i.status == APU_OBJTAB_MISS) begin
                // no squatter left: reserve the kernel's extent for M
                state_q <= StMapAllocAt;
              end else if (ot_cpl_i.status != APU_OBJTAB_OK) begin
                resp_ram[0] <= APU_VG_ERR_UNSPEC;
                state_q     <= StWrPrep;
              end else if (|ot_cpl_i.entry.size[63:32]) begin
                // a squatter too large to re-place honestly (cannot
                // happen for ALLOC_HI extents — truthful refusal)
                resp_ram[0] <= APU_VG_ERR_OUT_OF_MEMORY;
                state_q     <= StWrPrep;
              end else begin
                // evict X: ALLOC_HI(size_X, excl=[K,K+S)) keeps its
                // new extent out of the kernel's range
                ovl_h_q    <= ot_cpl_i.handle;
                ovl_base_q <= ot_cpl_i.entry.aux[63:32];
                ovl_size_q <= ot_cpl_i.entry.size;
                pg_op_q    <= APU_VGPAGES_OP_ALLOC_HI;
                pg_base_q  <= req_ram[8];                  // excl_lo
                pg_exclh_q <= 32'(64'({req_ram[9], req_ram[8]}) +
                                  map_size_q);             // excl_hi
                pg_bytes_q <= ot_cpl_i.entry.size[31:0];
                pg_ret_q   <= StMapEvMv;
                state_q    <= StPgReq;
              end
            end
          end
          // evicted extent landed (ovl_newb_q): word-move X old->new
          StMapEvMv: begin
            mv_src_q <= ovl_base_q;
            mv_dst_q <= ovl_newb_q;
            mv_len_q <= ovl_size_q[31:0];
            mv_rev_q <= ovl_newb_q > ovl_base_q;
            mv_i_q   <= ovl_newb_q > ovl_base_q
                        ? ovl_size_q[31:0] - 32'd8 : '0;
            mv_ret_q <= StMapEvFree;
            state_q  <= StMvRd;
          end
          // copy done: release X's old extent, then publish the new base
          StMapEvFree: begin
            pg_op_q    <= APU_VGPAGES_OP_FREE;
            pg_base_q  <= ovl_base_q;
            pg_bytes_q <= ovl_size_q[31:0];
            pg_ret_q   <= StMapEvPub;
            state_q    <= StPgReq;
          end
          StMapEvPub:  if (ot_req_ready_i) state_q <= StMapEvPubC;
          // X published at its new base (still DEVBACKED): rescan —
          // another squatter may overlap the kernel's range
          StMapEvPubC: if (ot_cpl_valid_i) state_q <= StMapScan;
          // kernel extent reserved: move M's contents B -> K
          StMapMv: begin
            mv_src_q <= map_oldb_q;
            mv_dst_q <= req_ram[8];   // K < APU_VG_GUEST_BYTES < 2^32
            mv_len_q <= map_size_q[31:0];
            mv_rev_q <= req_ram[8] > map_oldb_q;
            mv_i_q   <= req_ram[8] > map_oldb_q
                        ? map_size_q[31:0] - 32'd8 : '0;
            mv_ret_q <= StMapMvF;
            state_q  <= StMvRd;
          end
          // M's contents are at K: release the device-chosen extent
          StMapMvF: begin
            pg_op_q    <= APU_VGPAGES_OP_FREE;
            pg_base_q  <= map_oldb_q;
            pg_bytes_q <= map_size_q[31:0];
            pg_ret_q   <= StMapBind;
            state_q    <= StPgReq;
          end
          // kernel base published (StMapAux*): clear DEVBACKED — M's
          // extent is kernel-chosen now
          StMapDevAux:  if (ot_req_ready_i) state_q <= StMapDevAuxC;
          StMapDevAuxC: if (ot_cpl_valid_i) state_q <= StWrPrep;
          StMapMvFail: begin
            // mover fault (read/write err): refuse the map truthfully;
            // extents moved so far stay live at their new bases
            resp_ram[0] <= APU_VG_ERR_UNSPEC;
            state_q     <= StWrPrep;
          end

          // ---- word mover: one 64-bit read then write per beat ------
          StMvRd:  if (mem_ready_i)  state_q <= StMvRdC;
          StMvRdC: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) begin
                state_q <= StMapMvFail;
              end else begin
                mv_word_q <= mem_rdata_i;
                state_q   <= StMvWr;
              end
            end
          end
          StMvWr:  if (mem_ready_i)  state_q <= StMvWrC;
          StMvWrC: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) begin
                mem_fault_q <= 1'b1;   // aperture write fault (§6c)
                state_q     <= StMapMvFail;
              end else if (mv_rev_q ? mv_i_q == 32'h0
                                   : mv_i_q + 32'd8 >= mv_len_q) begin
                state_q <= mv_ret_q;
              end else begin
                mv_i_q  <= mv_rev_q ? mv_i_q - 32'd8 : mv_i_q + 32'd8;
                state_q <= StMvRd;
              end
            end
          end
          // memory-backed: the VkDeviceMemory owns the extent; look it
          // up (rid recorded in the blob's aux[31:8] at create) so its
          // pages and page base move with the blob
          StMapMemReq: if (ot_req_ready_i) state_q <= StMapMemCpl;
          StMapMemCpl: begin
            if (ot_cpl_valid_i) begin
              if (ot_cpl_i.status != APU_OBJTAB_OK) begin
                if (map_unmap_q) begin
                  // §6c teardown order: the kernel unmaps the GEM
                  // resources after CTX_DESTROY, so the backing
                  // VkDeviceMemory is already tombstoned and the sweep
                  // (or an earlier vkFreeMemory retire) has reclaimed
                  // its extent.  The mapping is therefore already
                  // gone — rebind the blob lazy and answer OK; a
                  // MAP_BLOB on a dead memory still refuses.
                  state_q <= StBindReq;
                end else begin
                  resp_ram[0] <= APU_VG_ERR_RID;
                  state_q <= StWrPrep;
                end
              end else begin
                map_memh_q <= ot_cpl_i.handle;
                map_unb_q  <= ot_cpl_i.entry.aux[63:32] ==
                              APU_MEM_UNBACKED;
                if (!map_unmap_q &&
                    (ot_cpl_i.entry.aux & APU_MEM_DEVBACKED) != 64'h0 &&
                    ot_cpl_i.entry.aux[63:32] != APU_MEM_UNBACKED) begin
                  // §12.3 3d-d: the memory sits on a device-chosen
                  // extent — hold new submissions, drain the engines,
                  // then evict squatters and word-move it to the
                  // kernel's offset
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
                  $display("[DBG] reloc start memh=%08x oldb=%08x K=%08x sz=%x t=%0t",
                           map_memh_q, ot_cpl_i.entry.aux[63:32],
                           auxv_q, map_size_q[31:0], $time);
`endif
// pragma translate_on
                  map_hold_q <= 1'b1;
                  map_dev_q  <= 1'b1;
                  map_oldb_q <= ot_cpl_i.entry.aux[63:32];
                  state_q    <= StMapDrain;
                end else begin
                  pg_op_q    <= APU_VGPAGES_OP_FREE;
                  pg_base_q  <= ot_cpl_i.entry.aux[63:32];
                  pg_bytes_q <= map_size_q[31:0];
                  // §12.3 C: UNMAP_BLOB drops the memory back to the
                  // unbacked sentinel (lazy type-1 has no private
                  // extent to return to); MAP_BLOB goes to ALLOC_AT.
                  // A FREE of the unbacked sentinel is BOUNDS and is
                  // ignored, so a first map needs no special case.
                  pg_ret_q   <= map_unmap_q ? StUnmapPriv
                                            : StMapAllocAt;
                  state_q    <= StPgReq;
                end
              end
            end
          end
          // pages placed: rebind the blob at the kernel's offset
          StMapBind: begin
            blob_addr_q <= APU_VG_SHM_BASE +
                           64'({req_ram[9], req_ram[8]});
            auxv_q      <= req_ram[8];
            blob_size_q <= map_size_q;
            resp_ram[0] <= APU_VG_RESP_MAP_INFO;
            resp_ram[6] <= APU_VG_MAP_WC;
            resp_ram[7] <= req_ram[8];
            resp_n_q    <= 9'd8;
            state_q     <= StBindReq;
          end
          // memory-backed tail: publish the new page base on the memory
          // object so engine-side addressing follows the guest's map
          StMapAuxReq: if (ot_req_ready_i) state_q <= StMapAuxCpl;
          // unmap path: rebind the blob to 0 (lazy) after the memory's
          // base was re-privatized; a relocated memory still owes the
          // DEVBACKED clear; otherwise the map path is done — unless
          // the plain-path CAS lost to a racing bind, in which case
          // release the kernel extent and re-resolve (the fresh lookup
          // sees DEVBACKED and takes the relocation path)
          StMapAuxCpl: if (ot_cpl_valid_i) begin
            if (!map_unmap_q && !map_dev_q && map_unb_q &&
                ot_cpl_i.status == APU_OBJTAB_CONFLICT) begin
              pg_op_q    <= APU_VGPAGES_OP_FREE;
              pg_base_q  <= auxv_q;
              pg_bytes_q <= map_size_q[31:0];
              pg_ret_q   <= StMapMemReq;
              state_q    <= StPgReq;
            end else begin
              state_q <= map_unmap_q ? StBindReq :
                         map_dev_q   ? StMapDevAux : StWrPrep;
            end
          end

          // ---- RESET_CTX reap -------------------------------------------
          // One tombstoned entry per SWEEP completion: release the
          // resource it owned — vnfront's retire path does the same per
          // kind (vn_golden parity).  Command-buffer/fence arena slots
          // are vnfront-internal and are never held by entries a live
          // guest context can lose this way (CTX_DESTROY follows idle
          // — an in-flight buffer tombstone leaks only its arena slot,
          // documented §12.3).
          StReapDec: begin
            unique case (reap_kind_q)
              6'(APU_VN_KIND_VK_DEVICE_MEMORY): begin
                // aperture extent at aux[63:32] (private base, or the
                // guest-window offset a MAP_BLOB moved it to)
                pg_op_q    <= APU_VGPAGES_OP_FREE;
                pg_base_q  <= reap_aux_q[63:32];
                pg_bytes_q <= reap_size_q[31:0];
                pg_ret_q   <= StOtCpl;
                state_q    <= StPgReq;
              end
              6'(APU_VN_KIND_VK_DESCRIPTOR_POOL): begin
                // F5: descriptor record store at aux[31:0]
                pg_op_q    <= APU_VGPAGES_OP_FREE;
                pg_base_q  <= reap_aux_q[31:0];
                pg_bytes_q <= reap_size_q[31:0];
                pg_ret_q   <= StOtCpl;
                state_q    <= StPgReq;
              end
              6'(APU_VN_KIND_VK_DESCRIPTOR_SET_LAYOUT),
              6'(APU_VN_KIND_VK_PIPELINE_LAYOUT): begin
                // ObjPay extent {base[15:0], words[15:0]} at aux[63:32]
                reap_ppipe_q <= 1'b0;
                reap_inval_q <= 1'b0;
                state_q      <= StReapOpReq;
              end
              6'(APU_VN_KIND_VK_SHADER_MODULE): begin
                // G3b-ii: pCode extent at aux[63:32], then invalidate
                // the module's residency line by {gen,slot}
                reap_ppipe_q <= 1'b0;
                reap_inval_q <= 1'b1;
                state_q      <= StReapOpReq;
              end
              6'(APU_VN_KIND_VK_PIPELINE): begin
                // G3b-ii: module-descriptor/state block at aux[31:16]
                // (aux[6] = graphics -> 48 words; compute -> 2).  The
                // pipeline's module pins die with the context's
                // ObjTab entries — no per-module UNPIN needed here
                reap_ppipe_q <= 1'b1;
                reap_inval_q <= 1'b0;
                state_q      <= StReapOpReq;
              end
              default: state_q <= StOtCpl;   // stateless kind
            endcase
          end
          StReapOpReq: if (op_req_ready_i) state_q <= StReapOpCpl;
          // reclaim status is advisory — the object is already dead;
          // a module chains its residency INVAL after the extent free
          StReapOpCpl: if (op_cpl_valid_i) begin
            reap_inval_q <= 1'b0;
            state_q      <= reap_inval_q ? StReapSmReq : StOtCpl;
          end
          StReapSmReq: if (sm_gnt_i)       state_q <= StReapSmCpl;
          StReapSmCpl: if (sm_cpl_i)       state_q <= StOtCpl;

          // ---- UNMAP_BLOB: memory returns to unbacked ---------------
          // §12.3 C: the guest extent is freed; a type-1 memory has no
          // private extent to return to — publish APU_MEM_UNBACKED so
          // engine uses fail truthfully until the next MAP_BLOB
          StUnmapPriv: begin
            auxv_q  <= APU_MEM_UNBACKED;
            state_q <= map_memb_q ? StMapAuxReq : StBindReq;
          end

          // ---- blob_id != 0: memory-object resolve -------------------
          StMemReq: if (ot_req_ready_i) state_q <= StMemCpl;
          StMemCpl: begin
            if (ot_cpl_valid_i) begin
              if (ot_cpl_i.status != APU_OBJTAB_OK) begin
                resp_ram[0] <= APU_VG_ERR_RID;   // unknown memory id
                state_q <= StWrPrep;
              end else if ({req_ram[13], req_ram[12]} >
                           ((ot_cpl_i.entry.size +
                             64'(APU_VG_PAGE_BYTES - 1)) &
                            ~64'(APU_VG_PAGE_BYTES - 1))) begin
                // the guest kernel rounds the BO to its page size; the
                // truthful bound is the memory's page-granular extent
                resp_ram[0] <= APU_VG_ERR_PARAM; // blob larger than mem
                state_q <= StWrPrep;
              end else begin
                // map onto the memory's aperture extent; §12.3 C: a
                // lazy (not yet MAP_BLOB'd) type-1 memory has no base
                // — bind the blob at 0 so MAP_BLOB relocates it
                blob_addr_q <= ot_cpl_i.entry.aux[63:32] ==
                               APU_MEM_UNBACKED
                               ? 64'h0
                               : APU_VG_SHM_BASE +
                                 ot_cpl_i.entry.aux[63:32];
                blob_size_q <= ot_cpl_i.entry.size;
                // {gen,slot} of the backing VkDeviceMemory — written
                // to the blob's aux[63:32] at StAuxHiReq so a later
                // MAP_BLOB relocation resolves it by handle (the
                // 24-bit aux[31:8] client-id shadow cannot express
                // 64-bit client ids)
                map_memh_q  <= ot_cpl_i.handle;
                state_q     <= StOtReq;          // ALLOC the blob entry
              end
            end
          end

          // mark the blob memory-backed so UNREF skips the page free
          StAuxReq: if (ot_req_ready_i) state_q <= StAuxCpl;
          StAuxCpl: if (ot_cpl_valid_i) begin
            // a second aux word records the memory's {gen,slot} handle
            state_q <= (rtype_q == APU_VG_CREATE_BLOB && blob_mem_q)
                       ? StAuxHiReq : StWrPrep;
          end
          StAuxHiReq: if (ot_req_ready_i) state_q <= StAuxHiCpl;
          StAuxHiCpl: if (ot_cpl_valid_i) state_q <= StWrPrep;

          // ---- ObjTab transactions ------------------------------------------
          // the request holds valid until the table is ready: the
          // shared/arbitrated ObjTab may not accept on the first cycle
          StOtReq:  if (ot_req_ready_i) state_q <= StOtCpl;
          StOtCpl: begin
            if (ot_cpl_valid_i) begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
              if (ot_cpl_i.status != APU_OBJTAB_OK)
                $display("[DBG] ot-fail rtype=%02x st=%0d id=%016x ctx=%x t=%0t",
                         rtype_q, ot_cpl_i.status,
                         64'h0, rctx_q, $time);
`endif
// pragma translate_on
              unique case (rtype_q)
                APU_VG_CTX_CREATE,
                APU_VG_MAP_BLOB,
                APU_VG_CTX_ATTACH, APU_VG_CTX_DETACH: begin
                  if (ot_cpl_i.status != APU_OBJTAB_OK) begin
                    resp_ram[0] <= (rtype_q == APU_VG_MAP_BLOB ||
                                    rtype_q == APU_VG_CTX_ATTACH ||
                                    rtype_q == APU_VG_CTX_DETACH)
                                   ? APU_VG_ERR_RID : APU_VG_ERR_CID;
                    state_q <= StWrPrep;
                  end else if (rtype_q == APU_VG_MAP_BLOB) begin
                    // The guest kernel owns the SHM layout: the request
                    // offset is the window offset it will mmap.  Bind the
                    // blob exactly there (relocating when our create-time
                    // extent differs), else the guest's writes land where
                    // the engines never look.
                    if (req_ram[9] != 32'h0 ||
                        64'({req_ram[9], req_ram[8]}) +
                            ot_cpl_i.entry.size > APU_VG_GUEST_BYTES) begin
                      resp_ram[0] <= APU_VG_ERR_PARAM;
                      state_q     <= StWrPrep;
                    end else if ({req_ram[9], req_ram[8]} ==
                                 ot_cpl_i.entry.bind_offset -
                                 APU_VG_SHM_BASE) begin
                      resp_ram[0] <= APU_VG_RESP_MAP_INFO;
                      resp_ram[6] <= APU_VG_MAP_WC;
                      resp_ram[7] <= req_ram[8];
                      resp_n_q    <= 9'd8;
                      state_q     <= StWrPrep;
                    end else begin
                      map_size_q  <= ot_cpl_i.entry.size;
                      map_memb_q  <= ot_cpl_i.entry.aux[0];
                      // {gen,slot} of the backing memory recorded at
                      // create (aux[63:32])
                      map_memh_q  <= ot_cpl_i.entry.aux[63:32];
                      map_unmap_q <= 1'b0;
                      if (ot_cpl_i.entry.aux[0]) begin
                        // memory-backed: the pages belong to the
                        // VkDeviceMemory; resolve it, then free+relocate
                        // the whole extent it sits on
                        state_q <= StMapMemReq;
                      end else begin
                        // blob-owned: bind_offset==0 means the lazy
                        // create never allocated — go straight to
                        // ALLOC_AT; else free the extent it holds
                        pg_op_q    <= APU_VGPAGES_OP_FREE;
                        pg_base_q  <= 32'(ot_cpl_i.entry.bind_offset -
                                          APU_VG_SHM_BASE);
                        pg_bytes_q <= ot_cpl_i.entry.size[31:0];
                        pg_ret_q   <= StMapAllocAt;
                        state_q    <= (ot_cpl_i.entry.bind_offset !=
                                       64'h0) ? StPgReq : StMapAllocAt;
                      end
                    end
                  end else begin
                    state_q <= StWrPrep;
                  end
                end
                APU_VG_UNMAP_BLOB: begin
                  if (ot_cpl_i.status == APU_OBJTAB_OK &&
                      ot_cpl_i.entry.bind_offset != 64'h0) begin
                    // kernel released its SHM slot: free the guest
                    // extent and drop the blob back to unmapped
                    // (bind_offset 0 — a later MAP re-allocates at the
                    // new offset).  Memory-backed blobs also re-base
                    // the VkDeviceMemory onto a fresh private extent.
                    map_size_q  <= ot_cpl_i.entry.size;
                    map_memb_q  <= ot_cpl_i.entry.aux[0];
                    blob_addr_q <= '0;
                    blob_size_q <= ot_cpl_i.entry.size;
                    if (ot_cpl_i.entry.aux[0]) begin
                      map_memh_q  <= ot_cpl_i.entry.aux[63:32];
                      map_unmap_q <= 1'b1;
                      state_q     <= StMapMemReq;
                    end else begin
                      pg_op_q     <= APU_VGPAGES_OP_FREE;
                      pg_base_q   <= 32'(ot_cpl_i.entry.bind_offset -
                                         APU_VG_SHM_BASE);
                      pg_bytes_q  <= ot_cpl_i.entry.size[31:0];
                      pg_ret_q    <= StBindReq;
                      state_q     <= StPgReq;
                    end
                  end else begin
                    state_q <= StWrPrep;
                  end
                end
                APU_VG_CREATE_BLOB: begin
                  if (ot_cpl_i.status != APU_OBJTAB_OK) begin
                    resp_ram[0] <= APU_VG_ERR_RID;
                    state_q <= StWrPrep;
                  end else begin
                    state_q <= StBindReq;   // SETBIND offset/size
                  end
                end
                APU_VG_UNREF: begin
                  if (ot_cpl_i.status != APU_OBJTAB_OK) begin
                    resp_ram[0] <= APU_VG_ERR_RID;
                    state_q <= StWrPrep;
                  end else if (ot_cpl_i.entry.aux[0]) begin
                    // memory-backed blob: the pages belong to the
                    // DEVICE_MEMORY object (freed at vkFreeMemory)
                    state_q <= StWrPrep;
                  end else if (ot_cpl_i.entry.bind_offset != 64'h0) begin
                    // blob-owned mapped pages: return them to the
                    // allocator (bind_offset 0 = lazy create, nothing
                    // was ever allocated)
                    pg_op_q    <= APU_VGPAGES_OP_FREE;
                    pg_base_q  <= 32'(ot_cpl_i.entry.bind_offset -
                                      APU_VG_SHM_BASE);
                    pg_bytes_q <= ot_cpl_i.entry.size[31:0];
                    pg_ret_q   <= StWrPrep;
                    state_q    <= StPgReq;
                  end else begin
                    state_q <= StWrPrep;
                  end
                end
                // CTX_DESTROY (RESET_CTX): the sweep streams one SWEEP
                // completion per tombstoned entry — reap the resource
                // each owned — then a final OK carries the pinned count
                default: if (ot_cpl_i.status == APU_OBJTAB_SWEEP) begin
                  reap_kind_q <= ot_cpl_i.entry.kind;
                  reap_aux_q  <= ot_cpl_i.entry.aux;
                  reap_size_q <= ot_cpl_i.entry.size;
                  reap_gen_q  <= ot_cpl_i.entry.gen;
                  reap_slot_q <= ot_cpl_i.handle[15:0];
                  state_q     <= StReapDec;
                end else begin
                  state_q <= StWrPrep;
                end
              endcase
            end
          end
          StBindReq: if (ot_req_ready_i) state_q <= StBindCpl;
          StBindCpl: begin
            if (ot_cpl_valid_i) begin
              if (ot_cpl_i.status != APU_OBJTAB_OK) begin
                resp_ram[0] <= APU_VG_ERR_RID;
                state_q <= StWrPrep;
              end else if (rtype_q == APU_VG_CREATE_BLOB && blob_mem_q) begin
                state_q <= StAuxReq;   // mark memory-backed (aux[0])
              end else if (rtype_q == APU_VG_MAP_BLOB && map_memb_q) begin
                // move the VkDeviceMemory page base to the new offset
                state_q <= StMapAuxReq;
              end else begin
                state_q <= StWrPrep;
              end
            end
          end

          // ---- SUBMIT_3D pump handoff -------------------------------------
          StXsFire: begin
            if (xs_ready_i) begin
              payload_b_q <= req_ram[6];
              state_q <= StXsWait;
            end
          end
          StXsWait: begin
            if (xs_done_i) begin
              if (xs_fault_i) resp_ram[0] <= APU_VG_ERR_UNSPEC;
              state_q <= StWrPrep;
            end
          end

          // ---- response write into the first WRITE descriptor --------------
          StWrPrep: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            if (map_hold_q)
              $display("[DBG] reloc done rtype=%02x t=%0t", rtype_q, $time);
            if (resp_ram[0] >= APU_VG_ERR_UNSPEC)
              $display("[DBG] vgerr rtype=%02x resp=%08x trunc=%0d stage=%0d nd=%0d len=%x r7=%08x r8=%08x r9=%08x r10=%08x r11=%08x r12=%08x r13=%08x ctx=%x t=%0t",
                       rtype_q, resp_ram[0], trunc_q, stage_q, ndesc_q,
                       read_len_q, req_ram[7], req_ram[8], req_ram[9],
                       req_ram[10], req_ram[11], req_ram[12], req_ram[13],
                       rctx_q, $time);
`endif
// pragma translate_on
            // §12.3 3d-d: relocation over (success or refusal) —
            // release the submission hold
            map_hold_q <= 1'b0;
            // locate the first WRITE descriptor
            wr_d_q <= '0; wr_w_q <= '0;
            if (desc_q[2'd0].write) begin
              resp_addr_q <= desc_q[2'd0].addr;
              resp_left_q <= desc_q[2'd0].len;
            end else begin
              resp_addr_q <= '0; resp_left_q <= '0;
            end
            used_q <= 32'(compute_used());
            state_q <= StWrFind;
          end
          StWrFind: begin
            if (4'(wr_d_q) >= 4'(ndesc_q) ||
                desc_q[wr_d_q[1:0]].write) begin
              if (4'(wr_d_q) < 4'(ndesc_q)) begin
                resp_addr_q <= desc_q[wr_d_q[1:0]].addr;
                resp_left_q <= desc_q[wr_d_q[1:0]].len;
                state_q <= StWrFire;
              end else begin
                // no write desc: the response is never emitted, so the
                // truthful used length carries only the consumed bytes
                used_q <= used_q - 32'({resp_n_q, 2'b00});
                state_q <= StDone;       // no write desc: no response
              end
            end else begin
              wr_d_q <= wr_d_q + 2'd1;
            end
          end
          StWrFire: if (mem_ready_i) state_q <= StWrCap;
          StWrCap: begin
            if (mem_rvalid_i) begin
              if (mem_err_i) begin
                mem_fault_q <= 1'b1;   // sticky
                // the faulted word never reached the buffer: only
                // words actually written count toward used length
                used_q <= used_q - 32'd4;
              end
              wr_w_q <= wr_w_q + 9'd1;
              resp_addr_q <= resp_addr_q + 64'd4;
              resp_left_q <= resp_left_q - 32'd4;
              if (wr_w_q + 9'd1 >= resp_n_q || resp_left_q <= 32'd4)
                state_q <= StDone;
              else
                state_q <= StWrFire;
            end
          end

          // ---- completion ----------------------------------------------------
          StDone: begin
// pragma translate_off
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] vgdone rtype=%02x flags=%08x used=%0d fid=%016x ring=%0d t=%0t",
                     rtype_q, rflags_q, used_q, rfence_q, rring_q, $time);
`endif
// pragma translate_on
            if ((rflags_q & APU_VG_FLAG_FENCE) != 32'h0)
              state_q <= StFence;
            else                            state_q <= StIdle;
          end
          StFence: state_q <= StIdle;
          default: state_q <= StIdle;
        endcase
      end
    end

    function automatic logic [63:0] compute_used();
      logic [31:0] rd_used;
      if (rtype_q == APU_VG_SUBMIT_3D)
        rd_used = 32'd32 + payload_b_q;
      else if (need_q == 9'd0)
        rd_used = read_len_q;                   // unknown: all staged
      else if (read_len_q < 32'(need_q) * 32'd4)
        rd_used = read_len_q;                   // truncated
      else
        rd_used = 32'(need_q) * 32'd4;
      return 64'(rd_used) + 64'(resp_n_q) * 64'd4;
    endfunction

    // SUBMIT_3D handoff fields
    logic unused;
    assign unused = testmode_i | ot_req_ready_i | (|ot_cpl_i) |
                    (|op_cpl_i) | (|sm_cpl_pl_i);
    assign xs_ndesc_o = ndesc_q;
    assign xs_off_o = 32'd32;
    assign xs_bytes_o = req_ram[6];
    assign xs_ctx_o = 8'(rctx_q);
    assign xs_valid_o = state_q == StXsFire;
    assign xs_desc_o = desc_q;
  end
endmodule

// Fixture wrapper for the *_SYNTH=1 screens: identical port list so
// read_slang can sweep -GEnable.
module g6lc_apu_vgctl_fixture
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_sh_pkg::*;
#(
  parameter bit          Enable   = 1'b0
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  output logic            mem_req_o,
  output logic            mem_we_o,
  output logic            mem_dom_o,
  output logic [63:0]     mem_addr_o,
  output logic [63:0]     mem_wdata_o,
  output logic [7:0]      mem_wstrb_o,
  input  logic            mem_ready_i,
  input  logic            mem_rvalid_i,
  input  logic [63:0]     mem_rdata_i,
  input  logic            mem_err_i,
  output logic            mem_fault_o,
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
  output logic             pg_req_valid_o,
  input  logic             pg_req_ready_i,
  output apu_vgpages_req_t pg_req_o,
  input  logic             pg_cpl_valid_i,
  output logic             pg_cpl_ready_o,
  input  apu_vgpages_cpl_t pg_cpl_i,
  output logic            op_req_valid_o,
  input  logic            op_req_ready_i,
  output apu_objpay_req_t op_req_o,
  input  logic            op_cpl_valid_i,
  output logic            op_cpl_ready_o,
  input  apu_objpay_cpl_t op_cpl_i,
  output logic            sm_req_o,
  output apu_sh_sm_req_t  sm_req_pl_o,
  input  logic            sm_gnt_i,
  input  logic            sm_cpl_i,
  input  apu_sh_sm_cpl_t  sm_cpl_pl_i,
  output logic            xs_valid_o,
  input  logic            xs_ready_i,
  output apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_desc_o,
  output logic [3:0]      xs_ndesc_o,
  output logic [31:0]     xs_off_o,
  output logic [31:0]     xs_bytes_o,
  output logic [7:0]      xs_ctx_o,
  input  logic            xs_done_i,
  input  logic            xs_fault_i,
  output logic            ctx_kill_valid_o,
  output logic [7:0]      ctx_kill_id_o,
  output logic            hold_o,
  input  logic            drain_idle_i,
  output logic            busy_o,
  output logic            done_o,
  output logic [31:0]     used_len_o,
  output logic            fence_done_o,
  output logic [63:0]     fence_id_o,
  output logic [7:0]      fence_ring_o
);
  g6lc_apu_vgctl #(.Enable(Enable)) i_dut (.*);
endmodule
