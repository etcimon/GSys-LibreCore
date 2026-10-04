// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Submit-time command executor (§6 of
// architecture/uncore/apu-vulkan-engine.md).  A depth-4 submit FIFO
// carries {fence slot, up to 4 command buffers}; each buffer's records
// are read back from cmdrec, every stored handle re-resolved through
// objtab LOOKUP by {gen,slot} so a destroyed object between record and
// submit loses the submission (DEVICE_LOST on the fence).  State
// records update the executor state registers; work records are issued
// on work_valid_o/work_ready_i with a state snapshot; PipelineBarrier
// and submit end drain outstanding work via work_done_i.  Buffers are
// PINned at submit and UNPINned when their records complete.
//
// done_seq_o counts completed submissions; fence_signaled_o /
// fence_lost_o give the WAIT class per-fence OK / DEVICE_LOST;
// fence_clr_i (one-cycle mask pulse) implements vkResetFences.
//
// Timing impact: one objtab or cmdreq transaction per micro-step, all
// handshakes registered; the widest cones are the 512-bit record
// unpacking and the state-register update mux.  The submit FIFO and
// state registers are flops; no SRAM.
//
// Review checklist: async active-low reset; no latches; single
// always_ff; Enable=0 elaborates no datapath; done_seq wraps mod 2^16.

module g6lc_apu_cmdexec
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
#(
  parameter bit          Enable = 1'b0,
  parameter int unsigned Fences = 16
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               testmode_i,
  input  logic               submit_valid_i,
  output logic               submit_ready_o,
  input  apu_cmdexec_submit_t submit_i,
  output logic               cr_req_valid_o,
  input  logic               cr_req_ready_i,
  output apu_cmdrec_req_t    cr_req_o,
  input  logic               cr_cpl_valid_i,
  output logic               cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t    cr_cpl_i,
  output logic               ot_req_valid_o,
  input  logic               ot_req_ready_i,
  output apu_objtab_req_t    ot_req_o,
  input  logic               ot_cpl_valid_i,
  output logic               ot_cpl_ready_o,
  input  apu_objtab_cpl_t    ot_cpl_i,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  output logic [15:0]        done_seq_o,
  output logic [Fences-1:0]  fence_signaled_o,
  output logic [Fences-1:0]  fence_lost_o,
  input  logic [Fences-1:0]  fence_clr_i
);
  if (!Enable) begin : gen_off
    assign submit_ready_o  = 1'b0;
    assign cr_req_valid_o  = 1'b0;
    assign cr_req_o        = '0;
    assign cr_cpl_ready_o  = 1'b0;
    assign ot_req_valid_o  = 1'b0;
    assign ot_req_o        = '0;
    assign ot_cpl_ready_o  = 1'b0;
    assign work_valid_o    = 1'b0;
    assign work_o          = '0;
    assign done_seq_o      = '0;
    assign fence_signaled_o = '0;
    assign fence_lost_o    = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | submit_valid_i |
                    cr_req_ready_i | cr_cpl_valid_i | (|cr_cpl_i) |
                    ot_req_ready_i | ot_cpl_valid_i | (|ot_cpl_i) |
                    work_ready_i | work_done_i | (|fence_clr_i) |
                    (|submit_i);
  end else begin : gen_on
    localparam int unsigned Fifo = 4;
    localparam logic [4:0]   FENCE_NONE = 5'd31;

    typedef enum logic [4:0] {
      StIdle, StPinReq, StPinCpl, StCntReq, StCntCpl,
      StRdReq, StRdCpl, StResReq, StResCpl, StDispatch,
      StWork, StDrain, StUnpReq, StUnpCpl, StNextBuf,
      StBufDone, StFinalDrain, StDone
    } state_e;
    state_e              state_q;
    // submit FIFO (flops)
    apu_cmdexec_submit_t fifo_q [Fifo];
    logic [2:0]          fifo_head_q, fifo_tail_q, fifo_n_q;
    // execution registers
    apu_cmdexec_submit_t cur_q;
    logic [2:0]          buf_i_q;       // buffer index within submit
    logic [2:0]          pin_i_q;       // pin substep
    logic [7:0]          rec_i_q;       // record cursor
    logic [7:0]          rec_n_q;       // record count
    apu_cmdrec_rec_t     rec_q;         // current record
    logic [2:0]          h_i_q;         // handle resolve cursor
    logic [3:0]          pinned_q;      // per-buffer pin success
    logic                lost_q;        // DEVICE_LOST on this submit
    logic [7:0]          outst_q;       // outstanding work items
    logic [15:0]         done_seq_q;
    logic [Fences-1:0]   fsig_q, flost_q;
    apu_cmdexec_state_t  snap_q;

    // ---- record classification --------------------------------------
    function automatic apu_cmdexec_cls_e rec_cls(logic [31:0] t);
      case (t)
        APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT,
        APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT,
        APU_VN_TYPE_VK_CMD_BIND_VERTEX_BUFFERS_EXT,
        APU_VN_TYPE_VK_CMD_BIND_INDEX_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT,
        APU_VN_TYPE_VK_CMD_SET_VIEWPORT_EXT,
        APU_VN_TYPE_VK_CMD_SET_SCISSOR_EXT,
        APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT,
        APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_2_EXT,
        APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT,
        APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT,
        APU_VN_TYPE_VK_CMD_END_RENDER_PASS_2_EXT,
        APU_VN_TYPE_VK_CMD_RESET_QUERY_POOL_EXT,
        APU_VN_TYPE_VK_CMD_BEGIN_QUERY_EXT,
        APU_VN_TYPE_VK_CMD_END_QUERY_EXT,
        APU_VN_TYPE_VK_CMD_WRITE_TIMESTAMP_EXT:
          return APU_CMDEXEC_CLS_STATE;
        APU_VN_TYPE_VK_CMD_PIPELINE_BARRIER_EXT:
          return APU_CMDEXEC_CLS_BARRIER;
        APU_VN_TYPE_VK_CMD_DRAW_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_DRAW_INDEXED_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_DISPATCH_EXT,
        APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT,
        APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_COPY_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_COPY_BUFFER_TO_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_COPY_IMAGE_TO_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_BLIT_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_FILL_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_UPDATE_BUFFER_EXT,
        APU_VN_TYPE_VK_CMD_CLEAR_COLOR_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_CLEAR_DEPTH_STENCIL_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT,
        APU_VN_TYPE_VK_CMD_RESOLVE_IMAGE_EXT,
        APU_VN_TYPE_VK_CMD_EXECUTE_COMMANDS_EXT:
          return APU_CMDEXEC_CLS_WORK;
        default: return APU_CMDEXEC_CLS_NOP;
      endcase
    endfunction

    // ---- port steering -----------------------------------------------
    assign submit_ready_o = fifo_n_q != 3'(Fifo);
    assign done_seq_o     = done_seq_q;
    assign fence_signaled_o = fsig_q;
    assign fence_lost_o   = flost_q;
    assign cr_cpl_ready_o = 1'b1;
    assign ot_cpl_ready_o = 1'b1;

    always_comb begin
      cr_req_valid_o = 1'b0;
      cr_req_o       = '0;
      ot_req_valid_o = 1'b0;
      ot_req_o       = '0;
      work_valid_o   = 1'b0;
      work_o         = '0;
      case (state_q)
        StPinReq: begin
          ot_req_valid_o = 1'b1;
          ot_req_o       = '{op: APU_OBJTAB_OP_PIN,
                             id: {32'h0, cur_q.chndl[pin_i_q[1:0]]},
                             kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                             default: '0};
        end
        StCntReq: begin
          cr_req_valid_o = 1'b1;
          cr_req_o       = '{op: APU_CMDREC_OP_COUNT,
                             cbuf: cur_q.crec[buf_i_q[1:0]],
                             default: '0};
        end
        StRdReq: begin
          cr_req_valid_o = 1'b1;
          cr_req_o       = '{op: APU_CMDREC_OP_READ,
                             cbuf: cur_q.crec[buf_i_q[1:0]],
                             idx: rec_i_q, default: '0};
        end
        StResReq: begin
          ot_req_valid_o = h_i_q != 3'd4 &&
                           rec_q.handle[h_i_q[1:0]] != 32'h0;
          ot_req_o       = '{op: APU_OBJTAB_OP_LOOKUP,
                             id: {32'h0, rec_q.handle[h_i_q[1:0]]},
                             kind: 6'(rec_q.kind[h_i_q[1:0]]),
                             default: '0};
        end
        StUnpReq: begin
          ot_req_valid_o = pinned_q[buf_i_q[1:0]];
          ot_req_o       = '{op: APU_OBJTAB_OP_UNPIN,
                             id: {32'h0, cur_q.chndl[buf_i_q[1:0]]},
                             kind: 6'(APU_VN_KIND_VK_COMMAND_BUFFER),
                             default: '0};
        end
        StWork: begin
          work_valid_o = 1'b1;
          work_o       = '{ctype: rec_q.ctype, snap: snap_q, rec: rec_q};
        end
        default: ;
      endcase
    end

    // ---- sequential --------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q     <= StIdle;
        for (int i = 0; i < Fifo; i++) fifo_q[i] <= '0;
        fifo_head_q <= '0;
        fifo_tail_q <= '0;
        fifo_n_q    <= '0;
        cur_q       <= '0;
        buf_i_q     <= '0;
        pin_i_q     <= '0;
        rec_i_q     <= '0;
        rec_n_q     <= '0;
        rec_q       <= '0;
        h_i_q       <= '0;
        pinned_q    <= '0;
        lost_q      <= 1'b0;
        outst_q     <= '0;
        done_seq_q  <= '0;
        fsig_q      <= '0;
        flost_q     <= '0;
        snap_q      <= '0;
      end else begin
        // work completions retire outstanding items
        if (work_done_i && outst_q != 8'h0) outst_q <= outst_q - 8'h1;
        // fence clear mask (vkResetFences)
        fsig_q  <= fsig_q & ~fence_clr_i;
        flost_q <= flost_q & ~fence_clr_i;
        // submit FIFO push
        if (submit_valid_i && submit_ready_o) begin
          fifo_q[fifo_tail_q[1:0]] <= submit_i;
          fifo_tail_q <= fifo_tail_q + 3'd1;
          fifo_n_q    <= fifo_n_q + 3'd1;
        end

        case (state_q)
          StIdle: begin
            if (fifo_n_q != 3'd0) begin
              cur_q       <= fifo_q[fifo_head_q[1:0]];
              fifo_head_q <= fifo_head_q + 3'd1;
              fifo_n_q    <= fifo_n_q - 3'd1;
              pin_i_q     <= '0;
              buf_i_q     <= '0;
              pinned_q    <= '0;
              lost_q      <= 1'b0;
              state_q     <= fifo_q[fifo_head_q[1:0]].nbufs == 3'd0
                             ? StDone : StPinReq;
            end
          end

          // ---- pin each buffer's objtab handle ----------------------
          StPinReq: if (ot_req_ready_i) state_q <= StPinCpl;
          StPinCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status == APU_OBJTAB_OK)
              pinned_q[pin_i_q[1:0]] <= 1'b1;
            else
              lost_q <= 1'b1;
            if (pin_i_q + 3'd1 >= {2'b0, cur_q.nbufs}) begin
              state_q <= StCntReq;
            end else begin
              pin_i_q <= pin_i_q + 3'd1;
              state_q <= StPinReq;
            end
          end

          // ---- per-buffer record walk --------------------------------
          StCntReq: if (cr_req_ready_i) state_q <= StCntCpl;
          StCntCpl: if (cr_cpl_valid_i) begin
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else if (cr_cpl_i.count == 8'h0) begin
              state_q <= StUnpReq;
            end else begin
              rec_n_q <= cr_cpl_i.count;
              rec_i_q <= '0;
              state_q <= StRdReq;
            end
          end
          StRdReq: if (cr_req_ready_i) state_q <= StRdCpl;
          StRdCpl: if (cr_cpl_valid_i) begin
            if (cr_cpl_i.status != APU_CMDREC_OK) begin
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              rec_q   <= cr_cpl_i.rec;
              h_i_q   <= '0;
              state_q <= StResReq;
            end
          end

          // ---- re-resolve stored handles -----------------------------
          StResReq: begin
            if (h_i_q == 3'd4) begin
              state_q <= StDispatch;
            end else if (rec_q.handle[h_i_q[1:0]] == 32'h0) begin
              h_i_q <= h_i_q + 3'd1;
            end else if (ot_req_valid_o && ot_req_ready_i) begin
              state_q <= StResCpl;
            end
          end
          StResCpl: if (ot_cpl_valid_i) begin
            if (ot_cpl_i.status != APU_OBJTAB_OK) begin
              // stale generation / dead object: submission lost
              lost_q  <= 1'b1;
              state_q <= StUnpReq;
            end else begin
              h_i_q   <= h_i_q + 3'd1;
              state_q <= StResReq;
            end
          end

          // ---- dispatch ----------------------------------------------
          StDispatch: begin
            case (rec_cls(rec_q.ctype))
              APU_CMDEXEC_CLS_STATE: begin
                case (rec_q.ctype)
                  APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT:
                    snap_q.pipeline <= rec_q.handle[0];
                  APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT:
                    snap_q.dset <= rec_q.handle[2];
                  APU_VN_TYPE_VK_CMD_BIND_VERTEX_BUFFERS_EXT:
                    snap_q.vtx <= rec_q.handle[1];
                  APU_VN_TYPE_VK_CMD_BIND_INDEX_BUFFER_EXT:
                    snap_q.ibo <= rec_q.handle[1];
                  APU_VN_TYPE_VK_CMD_SET_VIEWPORT_EXT:
                    snap_q.vp <= rec_q.imm[0];
                  APU_VN_TYPE_VK_CMD_SET_SCISSOR_EXT:
                    snap_q.sc <= rec_q.imm[0];
                  APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT:
                    snap_q.push <= rec_q.imm[0][15:0];
                  APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_EXT,
                  APU_VN_TYPE_VK_CMD_BEGIN_RENDER_PASS_2_EXT: begin
                    snap_q.rp_active <= 1'b1;
                    snap_q.subpass   <= '0;
                  end
                  APU_VN_TYPE_VK_CMD_NEXT_SUBPASS_EXT:
                    snap_q.subpass <= snap_q.subpass + 4'd1;
                  APU_VN_TYPE_VK_CMD_END_RENDER_PASS_EXT,
                  APU_VN_TYPE_VK_CMD_END_RENDER_PASS_2_EXT:
                    snap_q.rp_active <= 1'b0;
                  default: ;
                endcase
                state_q <= StNextBuf;
              end
              APU_CMDEXEC_CLS_WORK:     state_q <= StWork;
              APU_CMDEXEC_CLS_BARRIER:  state_q <= StDrain;
              default:                  state_q <= StNextBuf;
            endcase
          end
          StWork: if (work_ready_i) begin
            outst_q <= outst_q + 8'h1 -
                       ((work_done_i && outst_q != 8'h0) ? 8'h1 : 8'h0);
            state_q <= StNextBuf;
          end
          StDrain: if (outst_q == 8'h0 ||
                       (outst_q == 8'h1 && work_done_i)) begin
            state_q <= StNextBuf;
          end

          // ---- next record / buffer -----------------------------------
          StNextBuf: begin
            if (rec_i_q + 8'h1 < rec_n_q) begin
              rec_i_q <= rec_i_q + 8'h1;
              state_q <= StRdReq;
            end else begin
              state_q <= StUnpReq;
            end
          end
          StUnpReq: begin
            if (!pinned_q[buf_i_q[1:0]]) begin
              state_q <= StBufDone;      // nothing pinned: skip UNPIN
            end else if (ot_req_ready_i) begin
              state_q <= StUnpCpl;
            end
          end
          StUnpCpl: if (ot_cpl_valid_i) state_q <= StBufDone;
          StBufDone: begin
            if (buf_i_q + 3'd1 < {2'b0, cur_q.nbufs}) begin
              buf_i_q <= buf_i_q + 3'd1;
              rec_i_q <= '0;
              state_q <= StCntReq;
            end else begin
              state_q <= StFinalDrain;
            end
          end
          // a submit is complete when all its issued work is done
          StFinalDrain: begin
            if (outst_q == 8'h0 ||
                (outst_q == 8'h1 && work_done_i)) begin
              state_q <= StDone;
            end
          end

          StDone: begin
            done_seq_q <= done_seq_q + 16'h1;
            if (cur_q.fence_idx != FENCE_NONE &&
                cur_q.fence_idx < 5'(Fences)) begin
              fsig_q[cur_q.fence_idx[$clog2(Fences)-1:0]] <= 1'b1;
              if (lost_q)
                flost_q[cur_q.fence_idx[$clog2(Fences)-1:0]] <= 1'b1;
            end
            state_q <= StIdle;
          end

          default: state_q <= StIdle;
        endcase
      end
    end
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_cmdexec_fixture
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
#(parameter bit Enable = 1'b0,
  parameter int unsigned Fences = 16) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               testmode_i,
  input  logic               submit_valid_i,
  output logic               submit_ready_o,
  input  apu_cmdexec_submit_t submit_i,
  output logic               cr_req_valid_o,
  input  logic               cr_req_ready_i,
  output apu_cmdrec_req_t    cr_req_o,
  input  logic               cr_cpl_valid_i,
  output logic               cr_cpl_ready_o,
  input  apu_cmdrec_cpl_t    cr_cpl_i,
  output logic               ot_req_valid_o,
  input  logic               ot_req_ready_i,
  output apu_objtab_req_t    ot_req_o,
  input  logic               ot_cpl_valid_i,
  output logic               ot_cpl_ready_o,
  input  apu_objtab_cpl_t    ot_cpl_i,
  output logic               work_valid_o,
  input  logic               work_ready_i,
  output apu_cmdexec_work_t  work_o,
  input  logic               work_done_i,
  output logic [15:0]        done_seq_o,
  output logic [Fences-1:0]  fence_signaled_o,
  output logic [Fences-1:0]  fence_lost_o,
  input  logic [Fences-1:0]  fence_clr_i
);
  g6lc_apu_cmdexec #(.Enable(Enable), .Fences(Fences)) i_dut (.*);
endmodule
