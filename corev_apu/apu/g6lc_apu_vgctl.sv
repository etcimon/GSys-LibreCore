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
// CTX_ATTACH/DETACH_RESOURCE, RESOURCE_CREATE_BLOB (HOST3D|MAPPABLE,
// blob_id 0 only -> 4 KiB-page aperture allocation + ObjTab BLOB entry
// with bind_offset/size), RESOURCE_MAP_BLOB (RESP_OK_MAP_INFO,
// VIRTIO_GPU_MAP_CACHE_WC), RESOURCE_UNMAP_BLOB, RESOURCE_UNREF,
// SUBMIT_3D (execbuffer handoff; `size` beyond the chain payload is
// RESP_ERR_UNSPEC).  Unknown type -> RESP_ERR_UNSPEC; a chain too
// short for the declared request gets a header-only response and a
// truthful used length.  flags&FENCE echoes fence_id in the response
// and pulses fence_done_o after the command completes (after the pump
// finishes for SUBMIT_3D).
//
// Aperture allocator: ShmPages x 4 KiB pages over APU_VG_SHM_BASE,
// first-fit bitmap.  ObjTab kind APU_VN_KIND_APU_BLOB_SHMEM entries
// carry bind_offset = APU_VG_SHM_BASE + page*4KiB and size.
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
#(
  parameter bit          Enable   = 1'b0,
  parameter int unsigned ShmPages = 256     // APU aperture 1 MiB / 4 KiB
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  // one descriptor chain (avail element -> <=4 descriptors)
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  // guest memory word port (1-cycle read model)
  output logic            mem_re_o,
  output logic            mem_we_o,
  output logic [63:0]     mem_addr_o,
  output logic [31:0]     mem_wdata_o,
  input  logic [31:0]     mem_rdata_i,
  // ObjTab port
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
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
  localparam int unsigned PAGE_W = $clog2(ShmPages);
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
    assign mem_re_o = 1'b0;      assign mem_we_o = 1'b0;
    assign mem_addr_o = '0;      assign mem_wdata_o = '0;
    assign ot_req_valid_o = 1'b0; assign ot_req_o = '0;
    assign ot_cpl_ready_o = 1'b0;
    assign xs_valid_o = 1'b0;    assign xs_desc_o = '{default: '0};
    assign xs_ndesc_o = '0;      assign xs_off_o = '0;
    assign xs_bytes_o = '0;      assign xs_ctx_o = '0;
    assign busy_o = 1'b0;        assign done_o = 1'b0;
    assign used_len_o = '0;
    assign fence_done_o = 1'b0;  assign fence_id_o = '0;
    assign fence_ring_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | chain_valid_i |
                    (|chain_n_i) | (|chain_desc_i[0]) | mem_rdata_i |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    xs_ready_i | xs_done_i | xs_fault_i |
                    (|chain_desc_i[1]) | (|chain_desc_i[2]) |
                    (|chain_desc_i[3]);
  end else begin : gen_on
    typedef enum logic [4:0] {
      StIdle, StRdDesc, StRdFire, StRdCap, StHdr, StBody,
      StDispatch, StOtReq, StOtCpl, StBindReq, StBindCpl,
      StPageScan, StXsFire, StXsWait,
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
    logic [ShmPages-1:0] page_q;
    logic [PAGE_W:0]   scan_q;
    logic [PAGE_W-1:0] free_q;   // first page of the found run
    logic [PAGE_W:0]   run_q;    // pages still needed in the run
    logic [63:0]  blob_addr_q, blob_size_q;

    // bytes remaining in current read desc
    logic [31:0] rd_rem;
    assign rd_rem = desc_q[rd_d_q[1:0]].len - rd_off_q;
    // request words needed: unknown type -> stage everything readable
    logic [8:0] stage_goal;
    assign stage_goal = (need_q == 9'd0) ? 9'(REQW) : need_q;

    assign chain_ready_o = state_q == StIdle && rst_ni;
    assign busy_o = state_q != StIdle;
    assign done_o = state_q == StDone;
    assign used_len_o = used_q;
    assign fence_done_o = state_q == StFence;
    assign fence_id_o = rfence_q;
    assign fence_ring_o = 8'(rring_q);

    // ---- guest mem port ---------------------------------------------------
    assign mem_re_o = state_q == StRdFire;
    assign mem_we_o = state_q == StWrFire;
    assign mem_addr_o = (state_q == StWrFire) ? resp_addr_q :
                        desc_q[rd_d_q[1:0]].addr + 64'(rd_off_q);
    assign mem_wdata_o = resp_ram[wr_w_q[5:0]];

    // ---- ObjTab port -------------------------------------------------------
    logic ot_fire;
    assign ot_fire = state_q == StOtReq || state_q == StBindReq;
    assign ot_req_valid_o = ot_fire;
    assign ot_cpl_ready_o = state_q == StOtCpl || state_q == StBindCpl;
    always_comb begin
      ot_req_o = apu_objtab_req_t'('0);
      unique case (state_q)
        StOtReq: begin
          unique case (rtype_q)
            APU_VG_CTX_CREATE: ot_req_o = '{op: APU_OBJTAB_OP_ALLOC,
                id: APU_VG_ID_TAG | {32'h0, rctx_q},
                kind: 6'(APU_VN_KIND_APU_VIRTIO_CTX),
                ctx: 8'(rctx_q), default: '0};
            APU_VG_CTX_DESTROY: ot_req_o = '{op: APU_OBJTAB_OP_RESET_CTX,
                ctx: 8'(rctx_q), default: '0};
            APU_VG_CREATE_BLOB: ot_req_o = '{op: APU_OBJTAB_OP_ALLOC,
                id: APU_VG_ID_TAG | {32'h0, req_ram[6]},
                kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM),
                ctx: 8'(rctx_q), default: '0};
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
        page_q <= '0; scan_q <= '0; free_q <= '0; run_q <= '0;
        blob_addr_q <= '0; blob_size_q <= '0;
        for (int i = 0; i < REQW; i++) req_ram[i] <= '0;
        for (int i = 0; i < RESPW; i++) resp_ram[i] <= '0;
      end else begin
        unique case (state_q)
          // ----------------------------------------------------------
          StIdle: begin
            if (chain_valid_i) begin
              desc_q <= chain_desc_i;
              ndesc_q <= chain_n_i;
              rd_d_q <= '0; rd_off_q <= '0; read_len_q <= '0;
              stage_q <= '0; wr_w_q <= '0; resp_n_q <= '0;
              used_q <= '0; need_q <= '0; trunc_q <= 1'b0;
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
          StRdFire: state_q <= StRdCap;
          StRdCap: begin
            req_ram[stage_q[5:0]] <= mem_rdata_i;
            stage_q <= stage_q + 9'd1;
            rd_off_q <= rd_off_q + 32'd4;
            read_len_q <= read_len_q + 32'd4;
            state_q <= StRdDesc;
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
                    resp_ram[7] <= 32'(APU_VN_CAPSET_WORDS * 4);
                    resp_ram[8] <= 32'd0;   // max_version
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
                APU_VG_CTX_DESTROY: state_q <= StOtReq;   // RESET_CTX
                APU_VG_CTX_ATTACH, APU_VG_CTX_DETACH: begin
                  state_q <= StOtReq;     // LOOKUP the resource
                end
                APU_VG_CREATE_BLOB: begin
                  if (req_ram[7] != APU_VG_BLOB_HOST3D ||
                      (req_ram[8] & APU_VG_BLOB_MAPPABLE) == 32'h0 ||
                      {req_ram[11], req_ram[10]} != 64'h0 ||
                      {req_ram[13], req_ram[12]} == 64'h0) begin
                    resp_ram[0] <= APU_VG_ERR_PARAM;
                    state_q <= StWrPrep;
                  end else begin
                    blob_size_q <= {req_ram[13], req_ram[12]};
                    scan_q <= '0;
                    free_q <= '0;
                    run_q <= (PAGE_W + 1)'(
                        ({req_ram[13], req_ram[12]} + 64'd4095) >> 12);
                    state_q <= StPageScan;
                  end
                end
                APU_VG_MAP_BLOB, APU_VG_UNMAP_BLOB, APU_VG_UNREF: begin
                  state_q <= StOtReq;     // LOOKUP / RETIRE
                end
                APU_VG_SUBMIT_3D: begin
                  if (req_ram[6] == 32'd0 ||
                      64'(req_ram[6]) >
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

          // ---- aperture first-fit page scan -------------------------------
          // free_q = candidate run start; scan_q walks pages; run_q =
          // pages still needed to satisfy the allocation.
          StPageScan: begin
            if (run_q == '0) begin
              // run found: mark the pages and allocate the ObjTab entry
              blob_addr_q <= APU_VG_SHM_BASE + (64'(free_q) << 12);
              for (int i = 0; i < ShmPages; i++)
                if (i >= free_q &&
                    64'(i) < 64'(free_q) +
                    ((blob_size_q + 64'd4095) >> 12))
                  page_q[i] <= 1'b1;
              state_q <= StOtReq;
            end else if (scan_q >= (PAGE_W + 1)'(ShmPages)) begin
              resp_ram[0] <= APU_VG_ERR_PARAM;   // aperture exhausted
              state_q <= StWrPrep;
            end else if (page_q[scan_q[PAGE_W-1:0]]) begin
              free_q <= PAGE_W'(scan_q) + 1'b1;
              scan_q <= scan_q + 1'b1;
            end else begin
              if ((PAGE_W + 2)'(scan_q) + 10'd1 - (PAGE_W + 2)'(free_q)
                  >= (PAGE_W + 2)'(run_q)) begin
                run_q <= '0;               // found: commit next cycle
              end else begin
                scan_q <= scan_q + 1'b1;
              end
            end
          end

          // ---- ObjTab transactions ------------------------------------------
          // the request holds valid until the table is ready: the
          // shared/arbitrated ObjTab may not accept on the first cycle
          StOtReq:  if (ot_req_ready_i) state_q <= StOtCpl;
          StOtCpl: begin
            if (ot_cpl_valid_i) begin
              unique case (rtype_q)
                APU_VG_CTX_CREATE,
                APU_VG_MAP_BLOB,
                APU_VG_CTX_ATTACH, APU_VG_CTX_DETACH: begin
                  if (ot_cpl_i.status != APU_OBJTAB_OK)
                    resp_ram[0] <= (rtype_q == APU_VG_MAP_BLOB ||
                                    rtype_q == APU_VG_CTX_ATTACH ||
                                    rtype_q == APU_VG_CTX_DETACH)
                                   ? APU_VG_ERR_RID : APU_VG_ERR_CID;
                  else if (rtype_q == APU_VG_MAP_BLOB) begin
                    resp_ram[0] <= APU_VG_RESP_MAP_INFO;
                    resp_ram[6] <= APU_VG_MAP_WC;
                    resp_ram[7] <= 32'd0;
                    resp_n_q <= 9'd8;
                  end
                  state_q <= StWrPrep;
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
                  if (ot_cpl_i.status == APU_OBJTAB_OK) begin
                    // free the blob's aperture pages
                    for (int i = 0; i < ShmPages; i++)
                      if (64'(i) >= ((ot_cpl_i.entry.bind_offset -
                                     APU_VG_SHM_BASE) >> 12) &&
                          64'(i) < ((ot_cpl_i.entry.bind_offset -
                                     APU_VG_SHM_BASE +
                                     ot_cpl_i.entry.size + 64'd4095)
                                    >> 12))
                        page_q[i] <= 1'b0;
                  end else begin
                    resp_ram[0] <= APU_VG_ERR_RID;
                  end
                  state_q <= StWrPrep;
                end
                default: state_q <= StWrPrep;   // CTX_DESTROY (RESET_CTX)
              endcase
            end
          end
          StBindReq: if (ot_req_ready_i) state_q <= StBindCpl;
          StBindCpl: begin
            if (ot_cpl_valid_i) begin
              if (ot_cpl_i.status != APU_OBJTAB_OK)
                resp_ram[0] <= APU_VG_ERR_RID;
              state_q <= StWrPrep;
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
                state_q <= StDone;       // no write desc: no response
              end
            end else begin
              wr_d_q <= wr_d_q + 2'd1;
            end
          end
          StWrFire: state_q <= StWrCap;
          StWrCap: begin
            wr_w_q <= wr_w_q + 9'd1;
            resp_addr_q <= resp_addr_q + 64'd4;
            resp_left_q <= resp_left_q - 32'd4;
            if (wr_w_q + 9'd1 >= resp_n_q || resp_left_q <= 32'd4)
              state_q <= StDone;
            else
              state_q <= StWrFire;
          end

          // ---- completion ----------------------------------------------------
          StDone: begin
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
    assign unused = testmode_i | ot_req_ready_i | (|ot_cpl_i);
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
#(
  parameter bit          Enable   = 1'b0,
  parameter int unsigned ShmPages = 256
) (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            testmode_i,
  input  logic            chain_valid_i,
  output logic            chain_ready_o,
  input  logic [3:0]      chain_n_i,
  input  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_i,
  output logic            mem_re_o,
  output logic            mem_we_o,
  output logic [63:0]     mem_addr_o,
  output logic [31:0]     mem_wdata_o,
  input  logic [31:0]     mem_rdata_i,
  output logic            ot_req_valid_o,
  input  logic            ot_req_ready_i,
  output apu_objtab_req_t ot_req_o,
  input  logic            ot_cpl_valid_i,
  output logic            ot_cpl_ready_o,
  input  apu_objtab_cpl_t ot_cpl_i,
  output logic            xs_valid_o,
  input  logic            xs_ready_i,
  output apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_desc_o,
  output logic [3:0]      xs_ndesc_o,
  output logic [31:0]     xs_off_o,
  output logic [31:0]     xs_bytes_o,
  output logic [7:0]      xs_ctx_o,
  input  logic            xs_done_i,
  input  logic            xs_fault_i,
  output logic            busy_o,
  output logic            done_o,
  output logic [31:0]     used_len_o,
  output logic            fence_done_o,
  output logic [63:0]     fence_id_o,
  output logic [7:0]      fence_ring_o
);
  g6lc_apu_vgctl #(.Enable(Enable), .ShmPages(ShmPages)) i_dut (.*);
endmodule
