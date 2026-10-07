// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Table-driven Venus reply builder: executes the generated
// APU_VN_REPLY_ROM micro-program for a decoded apu_vn_op_t and writes
// the reply words into a caller-provided word-addressed window
// (rep_base_i .. rep_base_i+rep_len_i).  Semantics mirror the Python
// golden sim (vn_golden.py ReplySim):
//
//   ROM word {op[47:40], a[39:32], b[31:0]}:
//     RTYPE         : emit op.cmd_type
//     RRESULT       : emit result_i (VkResult from the sequencer)
//     RU32/RU64 a b : emit 1/2 words from src a:
//                     IMM -> op.imm[b], Q -> op.q[b], CNT -> op.cnt[b],
//                     CONST -> APU_VN_CONST[b] (u64 zero-extends),
//                     EXEC -> exec_w_i[] at a sequential cursor
//     RHANDLE a     : emit op.q[a] as u64
//     RPTR a b      : emit u64(pres[a]); absent -> mpc += b (skip the
//                     pointee program)
//     RCONST b={idx,cnt} : emit APU_VN_PROFILE[idx..idx+cnt)
//     RCHAIN b=tbl  : replay op.chain[] (absolute APU_VN_CHAIN indices):
//                     each recorded node's sType is looked up in the
//                     0-terminated reply table at b; a match emits
//                     {u64(1), sType} then the reply body at the
//                     entry's mpc runs; non-members (request-side
//                     chain nodes recorded by earlier PNEXT ops) are
//                     skipped.  Bodies nest (their own RCHAIN
//                     continues the same cursor) so headers come out
//                     forward and bodies in reverse; u64(0)
//                     terminates when no member node remains.
//     RBLOB a       : emit the recorded u64 element/byte count (CS
//                     words at off-2/off-1) then op.blob[a].words CS
//                     payload words, one per cycle through the CS read
//                     port
//     REXBUF a b    : emit u64(count) taken from exec_w_i, then
//                     ceil(count*b/4) exec words
//     REXEC b       : emit b exec words
//     RRET          : pop the return stack (chain body end)
//     REND          : program end
//
//   GENERATE_REPLY (op.cmd_flags[0]) clear, a faulted decode, or
//   reply_prog == 0 -> done immediately with rep_words_o = 0 and no
//   writes.  Overrun of rep_len_i, an exec buffer read past exec_n_i,
//   a bad chain index, a return-stack overflow, or an mpc out of ROM
//   bounds -> fault_o; the builder stops and reports rep_words_o so
//   the caller can discard the window.  No write is ever issued at or
//   past rep_len_i.
//
// Timing impact: all table lookups are combinational localparam muxes
// (REPLY_ROM 316x48, CHAIN 132x48, CONST 67x32, PROFILE 400x32); the
// per-cycle work is one word write plus one micro-op decision.  The
// widest cones are the reply-ROM word mux, the PROFILE copy mux and
// the exec-word select.  One CS read per cycle for RBLOB.
//
// Review checklist: async active-low reset; no latches; single
// always_ff plus combinational port steering; Enable=0 elaborates no
// datapath; done_o is a one-cycle pulse; rep_words_o held until the
// next start_i.

module g6lc_apu_vnrep
  import g6lc_apu_vn_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,
  input  apu_vn_op_t  op_i,
  input  logic [31:0] result_i,
  input  logic [APU_VN_EXEC_WORDS*32-1:0] exec_w_i,
  input  logic [7:0]  exec_n_i,
  // §7b/5a-ii: per-element null-echo mask for the RBLOB out-id echo
  // of a multi-create (vkCreateComputePipelines).  Element i masked
  // -> its two id payload words echo 0 (VK_NULL_HANDLE).  Driven by
  // vnfront; zero for every other command.
  input  logic [31:0] rep_null_mask_i,
  input  logic [15:0] rep_base_i,
  input  logic [15:0] rep_len_i,
  input  logic [15:0] cs_base_i,   // command base: blob.off is
                                  // command-relative, echo reads at
                                  // cs_base_i + off - 2
  output logic        cs_re_o,
  output logic [15:0] cs_addr_o,
  input  logic        cs_ready_i,
  input  logic        cs_rvalid_i,
  input  logic [31:0] cs_rdata_i,
  input  logic        cs_err_i,
  output logic        rep_we_o,
  output logic [15:0] rep_addr_o,
  output logic [31:0] rep_wdata_o,
  input  logic        rep_ready_i,
  input  logic        rep_done_i,
  input  logic        rep_err_i,
  output logic        busy_o,
  output logic        done_o,
  output logic [15:0] rep_words_o,
  output logic        fault_o
);
  if (!Enable) begin : gen_off
    assign cs_re_o     = 1'b0;
    assign cs_addr_o   = '0;
    assign rep_we_o    = 1'b0;
    assign rep_addr_o  = '0;
    assign rep_wdata_o = '0;
    assign busy_o      = 1'b0;
    assign done_o      = 1'b0;
    assign rep_words_o = '0;
    assign fault_o     = 1'b0;
    apu_vn_op_t unused_op;
    logic unused;
    assign unused_op = op_i;
    assign unused = clk_i | rst_ni | start_i | cs_rdata_i[0] |
                    cs_ready_i | cs_rvalid_i | cs_err_i |
                    rep_ready_i | rep_done_i | rep_err_i |
                    (|result_i) | (|exec_n_i) | (|exec_w_i) |
                    (|rep_null_mask_i) |
                    (|rep_base_i) | (|rep_len_i) | (|cs_rdata_i) |
                    (|cs_base_i);
  end else begin : gen_on
    // reply micro-op encodings (must match gen_vn_tables.py REP_OPS)
    localparam logic [7:0] R_RTYPE   = 8'd1;
    localparam logic [7:0] R_RRESULT = 8'd2;
    localparam logic [7:0] R_RU32    = 8'd3;
    localparam logic [7:0] R_RU64    = 8'd4;
    localparam logic [7:0] R_RHANDLE = 8'd5;
    localparam logic [7:0] R_RPTR    = 8'd6;
    localparam logic [7:0] R_RCONST  = 8'd7;
    localparam logic [7:0] R_RCHAIN  = 8'd8;
    localparam logic [7:0] R_RBLOB   = 8'd9;
    localparam logic [7:0] R_REXBUF  = 8'd10;
    localparam logic [7:0] R_REND    = 8'd11;
    localparam logic [7:0] R_RRET    = 8'd12;
    localparam logic [7:0] R_REXEC   = 8'd13;
    // SRC encodings (must match gen_vn_tables.py SRC)
    localparam logic [7:0] S_IMM   = 8'd0;
    localparam logic [7:0] S_Q     = 8'd1;
    localparam logic [7:0] S_CNT   = 8'd2;
    localparam logic [7:0] S_CONST = 8'd3;
    localparam logic [7:0] S_EXEC  = 8'd4;

    typedef enum logic [3:0] {
      StIdle, StOp, StEmit2, StEmit3,
      StConstCp, StBlob, StXbuf,
      StChainScan, StChkNext,
      StDone
    } state_e;

    state_e        state_q;
    apu_vn_op_t    op_q;
    logic [31:0]   result_q;
    logic [15:0]   rep_base_q, rep_len_q;
    logic [15:0]   mpc_q;
    logic [15:0]   wpos_q;        // words emitted so far
    logic [7:0]    ecur_q;        // exec_w cursor
    logic [3:0]    cpos_q;        // op.chain[] cursor
    logic [15:0]   cs_base_q;     // command base for RBLOB echo
    logic [31:0]   tmp_q;         // staged second/third emit word
    logic [15:0]   cnt_q;         // remaining loop count
    logic [15:0]   ridx_q;        // loop index (profile copy)
    logic [31:0]   xbuf_cnt_q;    // REXBUF exec count
    logic [15:0]   aux_q;         // RPTR skip / REXBUF element bytes
    logic [15:0]   blob_off_q;    // CS read address cursor
    logic          blob_first_q;  // StBlob read-ahead marker
    logic [15:0]   blob_em_q;     // emitted-word index in this blob
    logic [4:0]    blob_el;       // blob element index (emitted word/2)
                                  // (0 = count hi; payload starts at 1)
    logic [15:0]   ret_stk_q [8];
    logic [3:0]    ret_sp_q;
    logic          fault_q;
    logic [15:0]   done_words_q;
    logic [15:0]   tcur_q;        // RCHAIN reply-table scan cursor
    logic [31:0]   node_st_q;     // recorded node's sType
    logic [15:0]   chain_tgt_q;   // matched reply-body mpc
    // §6c Settled bullet 3: both ports are now handshake ports —
    // rep_we_o/cs_re_o hold until rep_ready_i/cs_ready_i and each
    // request completes with exactly one rep_done_i/cs_rvalid_i pulse
    // (err flagged on *_err_i).  At most one request outstanding on
    // each port, so a write state advances on rep_done_i and StBlob
    // alternates read (-> rd_data_q) and write (-> wpos_q) phases.
    logic          rd_pend_q;     // CS request accepted, rsp pending
    logic          wr_pend_q;     // rep request accepted, rsp pending
    logic          blob_ph_q;     // StBlob: 0 = read phase, 1 = write
    logic [31:0]   rd_data_q;     // CS word captured at cs_rvalid_i

    logic [47:0]   rom_w;
    assign rom_w = 32'(mpc_q) < APU_VN_REPLY_ROM_WORDS
                   ? APU_VN_REPLY_ROM[
                       mpc_q[APU_VN_REPLY_MPC_AW-1:0]] : 48'h0;
    assign blob_el = 5'((blob_em_q >> 1) - 16'd1);
    logic [7:0]    rom_op;
    logic [7:0]    rom_a;
    logic [31:0]   rom_b;
    assign rom_op = rom_w[47:40];
    assign rom_a  = rom_w[39:32];
    assign rom_b  = rom_w[31:0];

    // recorded node entry (sType lo, decode mpc hi -- only the sType
    // is used; reply bodies are found by scanning the reply table)
    logic [47:0]   chain_w;
    assign chain_w = (cpos_q < op_q.chain_n) &&
                     (32'(op_q.chain[cpos_q[2:0]]) < APU_VN_CHAIN_WORDS)
                     ? APU_VN_CHAIN[op_q.chain[cpos_q[2:0]]
                                    [APU_VN_CHAIN_AW-1:0]] : 48'h0;

    // reply-table scan word (0-terminated entries {mpc, sType})
    logic [47:0]   scan_w;
    assign scan_w = 32'(tcur_q) < APU_VN_CHAIN_WORDS
                    ? APU_VN_CHAIN[tcur_q[APU_VN_CHAIN_AW-1:0]] : 48'h0;

    // profile word source: first word at StOp indexes the operand
    // directly, the copy loop indexes through ridx_q
    logic [15:0]   prof_idx;
    assign prof_idx = state_q == StConstCp ? ridx_q : 16'(rom_b[15:0]);
    logic [31:0]   prof_w;
    assign prof_w = 32'(prof_idx) < APU_VN_PROFILE_WORDS
                    ? APU_VN_PROFILE[prof_idx[APU_VN_PROFILE_AW-1:0]]
                    : 32'h0;

    logic [31:0]   exec_w;
    assign exec_w = ecur_q < exec_n_i
                    ? exec_w_i[32*ecur_q +: 32] : 32'h0;

    // selected RU32/RU64 source words
    logic [31:0]   src_lo, src_hi;
    always_comb begin
      case (rom_a)
        S_IMM:   src_lo = op_q.imm[rom_b[3:0]];
        S_Q:     src_lo = op_q.q[rom_b[2:0]][31:0];
        S_CNT:   src_lo = op_q.cnt[rom_b[1:0]];
        S_CONST: src_lo = rom_b < APU_VN_CONST_WORDS
                          ? APU_VN_CONST[rom_b[APU_VN_CONST_AW-1:0]]
                          : 32'h0;
        default: src_lo = exec_w;
      endcase
    end
    always_comb begin
      case (rom_a)
        S_Q:     src_hi = op_q.q[rom_b[2:0]][63:32];
        default: src_hi = (ecur_q + 8'd1) < exec_n_i &&
                          rom_a == S_EXEC
                          ? exec_w_i[32*(ecur_q + 8'd1) +: 32]
                          : 32'h0;
      endcase
    end

    // EXEC word demand of the current op's first emission
    logic [7:0]    exec_need;
    always_comb begin
      exec_need = 8'd0;
      if (rom_op == R_RU32 && rom_a == S_EXEC)
        exec_need = 8'd1;
      else if (rom_op == R_RU64 && rom_a == S_EXEC)
        exec_need = 8'd2;
      else if (rom_op == R_REXBUF)
        exec_need = 8'd1;
      else if (rom_op == R_REXEC)
        exec_need = 8'(rom_b > 32'd64 ? 32'd64 : rom_b);
    end

    // StOp emits a word for every op except REND/RRET, a zero-count
    // RCONST/REXEC, and RCHAIN while a node scan is still pending
    // (the chain terminator emits only when nodes are exhausted).
    logic          emits_word;
    assign emits_word = rom_op != R_REND && rom_op != R_RRET &&
                        rom_op != 8'h0 &&
                        !(rom_op == R_REXEC && rom_b == 32'h0) &&
                        !(rom_op == R_RCONST && rom_b[31:16] == 16'h0) &&
                        !(rom_op == R_RCHAIN && cpos_q < op_q.chain_n);

    assign busy_o = state_q != StIdle;

    logic          wpos_ok;
    assign wpos_ok = wpos_q < rep_len_q;

    logic          want_wr;
    always_comb begin
      cs_re_o     = 1'b0;
      cs_addr_o   = blob_off_q;
      want_wr     = 1'b0;
      rep_addr_o  = rep_base_q + wpos_q;
      rep_wdata_o = 32'h0;
      case (state_q)
        StOp: begin
          if (wpos_ok) begin
            case (rom_op)
              R_RTYPE:   begin want_wr = 1'b1;
                               rep_wdata_o = op_q.cmd_type; end
              R_RRESULT: begin want_wr = 1'b1;
                               rep_wdata_o = result_q; end
              R_RU32, R_RU64: begin want_wr = 1'b1;
                               rep_wdata_o = src_lo; end
              R_RHANDLE: begin want_wr = 1'b1;
                               rep_wdata_o = op_q.q[rom_a[2:0]][31:0];
                         end
              R_RPTR:    begin want_wr = 1'b1;
                               rep_wdata_o =
                                 {31'h0, op_q.pres[rom_a[2:0]]}; end
              R_RCONST:  begin
                           want_wr = rom_b[31:16] != 16'h0;
                           rep_wdata_o = prof_w; end
              R_RCHAIN:  begin want_wr = (cpos_q >= op_q.chain_n);
                               rep_wdata_o = 32'h0; end
              R_REXBUF:  begin want_wr = 1'b1; rep_wdata_o = exec_w; end
              R_REXEC:   begin want_wr = rom_b != 32'h0;
                               rep_wdata_o = exec_w; end
              default: ;
            endcase
          end
        end
        StEmit2, StEmit3: begin
          want_wr     = wpos_ok;
          rep_wdata_o = tmp_q;
        end
        StConstCp: begin
          want_wr     = wpos_ok;
          rep_wdata_o = prof_w;
        end
        StBlob: begin
          // read phase issues one CS word; write phase emits the
          // word captured at cs_rvalid_i
          cs_re_o     = !blob_ph_q && !rd_pend_q && cnt_q != 16'h0;
          cs_addr_o   = blob_off_q;
          want_wr     = blob_ph_q && wpos_ok;
          // payload words (emission index >= 2, after the u64 count
          // pair) echo VK_NULL_HANDLE for elements marked in
          // rep_null_mask_i: element i's two id words emit at 2+2i
          rep_wdata_o = (blob_em_q >= 16'd2 &&
                         rep_null_mask_i[blob_el])
                        ? 32'h0 : rd_data_q;
        end
        StChainScan: begin
          // u64(1) presence lo word on a table match
          want_wr     = scan_w != 48'h0 && scan_w[31:0] == node_st_q &&
                        wpos_ok;
          rep_wdata_o = 32'h1;
        end
        StChkNext: begin
          // u64(0) terminator lo word when nodes are exhausted
          want_wr     = cpos_q >= op_q.chain_n && wpos_ok;
          rep_wdata_o = 32'h0;
        end
        StXbuf: begin
          want_wr     = wpos_ok;
          rep_wdata_o = exec_w;
        end
        default: ;
      endcase
    end
    assign rep_we_o = want_wr && !wr_pend_q;
    logic wr_done_ok, wr_done_err;
    assign wr_done_ok  = rep_done_i && !rep_err_i;
    assign wr_done_err = rep_done_i && rep_err_i;

    assign done_o      = state_q == StDone;
    assign fault_o     = fault_q;
    assign rep_words_o = done_words_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q      <= StIdle;
        op_q         <= '{fault: APU_VN_FAULT_NONE, default: '0};
        result_q     <= '0;
        rep_base_q   <= '0;
        rep_len_q    <= '0;
        cs_base_q    <= '0;
        mpc_q        <= '0;
        wpos_q       <= '0;
        ecur_q       <= '0;
        cpos_q       <= '0;
        tmp_q        <= '0;
        cnt_q        <= '0;
        ridx_q       <= '0;
        xbuf_cnt_q   <= '0;
        aux_q        <= '0;
        blob_off_q   <= '0;
        blob_first_q <= 1'b0;
        blob_em_q    <= '0;
        ret_stk_q    <= '{default: '0};
        ret_sp_q     <= '0;
        fault_q      <= 1'b0;
        done_words_q <= '0;
        tcur_q       <= '0;
        node_st_q    <= '0;
        chain_tgt_q  <= '0;
        rd_pend_q    <= 1'b0;
        wr_pend_q    <= 1'b0;
        blob_ph_q    <= 1'b0;
        rd_data_q    <= '0;
      end else begin
        // handshake bookkeeping: accept sets pend, response clears it
        if (cs_rvalid_i)      rd_pend_q <= 1'b0;
        else if (cs_re_o && cs_ready_i) begin
          rd_pend_q  <= 1'b1;
          blob_off_q <= blob_off_q + 16'd1;
          if (blob_first_q) blob_first_q <= 1'b0;
          else              cnt_q        <= cnt_q - 16'd1;
        end
        if (rep_done_i)       wr_pend_q <= 1'b0;
        else if (rep_we_o && rep_ready_i) wr_pend_q <= 1'b1;
        case (state_q)
          StIdle: begin
            fault_q <= 1'b0;
            if (start_i) begin
              op_q       <= op_i;
              result_q   <= result_i;
              rep_base_q <= rep_base_i;
              rep_len_q  <= rep_len_i;
              cs_base_q  <= cs_base_i;
              wpos_q     <= '0;
              ecur_q     <= '0;
              cpos_q     <= '0;
              ret_sp_q   <= '0;
              if (op_i.fault != APU_VN_FAULT_NONE ||
                  op_i.reply_prog == 8'h0 ||
                  !op_i.cmd_flags[0] ||
                  rep_len_i == 16'h0) begin
                done_words_q <= '0;
                state_q      <= StDone;
              end else if (op_i.reply_prog > 8'(APU_VN_REPLY_PROG_MAX) ||
                           APU_VN_REPLY_ENTRY[op_i.reply_prog[6:0]]
                           == 16'hFFFF ||
                           32'(APU_VN_REPLY_ENTRY[op_i.reply_prog[6:0]])
                           >= APU_VN_REPLY_ROM_WORDS) begin
                done_words_q <= '0;
                fault_q      <= 1'b1;
                state_q      <= StDone;
              end else begin
                mpc_q   <= APU_VN_REPLY_ENTRY[op_i.reply_prog[6:0]];
                state_q <= StOp;
              end
            end
          end

          StOp: begin
            if (32'(mpc_q) >= APU_VN_REPLY_ROM_WORDS) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if (emits_word && !wpos_ok) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if ({1'b0, ecur_q} + {1'b0, exec_need} >
                         {1'b0, exec_n_i}) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else begin
              case (rom_op)
                R_RTYPE, R_RRESULT, R_RU32: begin
                  if (rep_done_i) begin
                    if (rep_err_i) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q;
                      state_q      <= StDone;
                    end else begin
                      wpos_q <= wpos_q + 16'd1;
                      mpc_q  <= mpc_q + 16'd1;
                      if (rom_op == R_RU32 && rom_a == S_EXEC)
                        ecur_q <= ecur_q + 8'd1;
                    end
                  end
                end
                R_RU64: begin
                  if (rep_done_i) begin
                    if (rep_err_i) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q;
                      state_q      <= StDone;
                    end else begin
                      wpos_q  <= wpos_q + 16'd1;
                      tmp_q   <= src_hi;
                      state_q <= StEmit2;
                      if (rom_a == S_EXEC)
                        ecur_q <= ecur_q + 8'd2;
                    end
                  end
                end
                R_RHANDLE: begin
                  if (rep_done_i) begin
                    if (rep_err_i) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q;
                      state_q      <= StDone;
                    end else begin
                      wpos_q  <= wpos_q + 16'd1;
                      tmp_q   <= op_q.q[rom_a[2:0]][63:32];
                      state_q <= StEmit2;
                    end
                  end
                end
                R_RPTR: begin
                  if (rep_done_i) begin
                    if (rep_err_i) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q;
                      state_q      <= StDone;
                    end else begin
                      wpos_q  <= wpos_q + 16'd1;
                      tmp_q   <= 32'h0;
                      aux_q   <= rom_b[15:0];
                      state_q <= StEmit2;
                    end
                  end
                end
                R_RCONST: begin
                  if (32'(rom_b[15:0]) + {16'h0, rom_b[31:16]} >
                      APU_VN_PROFILE_WORDS) begin
                    fault_q      <= 1'b1;
                    done_words_q <= wpos_q + 16'd1;
                    state_q      <= StDone;
                  end else if (rom_b[31:16] == 16'h0) begin
                    mpc_q <= mpc_q + 16'd1;
                  end else if (rep_done_i) begin
                    if (rep_err_i) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q;
                      state_q      <= StDone;
                    end else if (rom_b[31:16] == 16'h1) begin
                      wpos_q <= wpos_q + 16'd1;
                      mpc_q  <= mpc_q + 16'd1;
                    end else begin
                      wpos_q  <= wpos_q + 16'd1;
                      ridx_q  <= 16'(rom_b[15:0]) + 16'd1;
                      cnt_q   <= rom_b[31:16] - 16'd1;
                      state_q <= StConstCp;
                    end
                  end
                end
                R_RCHAIN: begin
                  if (cpos_q >= op_q.chain_n) begin
                    // u64(0) terminator lo word write
                    if (rep_done_i) begin
                      if (rep_err_i) begin
                        fault_q      <= 1'b1;
                        done_words_q <= wpos_q;
                        state_q      <= StDone;
                      end else begin
                        wpos_q  <= wpos_q + 16'd1;
                        tmp_q   <= 32'h0;
                        state_q <= StEmit2;
                      end
                    end
                  end else if (chain_w == 48'h0) begin
                    fault_q      <= 1'b1;
                    done_words_q <= wpos_q;
                    state_q      <= StDone;
                  end else begin
                    // scan the reply table (rom_b) for the recorded
                    // node's sType; request-side nodes are skipped
                    node_st_q <= chain_w[31:0];
                    tcur_q    <= 16'(rom_b);
                    state_q   <= StChainScan;
                  end
                end
                R_RBLOB: begin
                  blob_off_q   <= cs_base_q +
                                  op_q.blob[rom_a[0]].off - 16'd2;
                  cnt_q        <= 16'(op_q.blob[rom_a[0]].words)
                                  + 16'd1;
                  blob_first_q <= 1'b1;
                  blob_ph_q    <= 1'b0;
                  blob_em_q    <= '0;
                  state_q      <= StBlob;
                end
                R_REXBUF: begin
                  // count word write; StEmit2 emits the u64
                  // high word (0), StXbuf streams the payload
                  if (rep_done_i) begin
                    if (rep_err_i) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q;
                      state_q      <= StDone;
                    end else begin
                      tmp_q      <= 32'h0;
                      xbuf_cnt_q <= exec_w;
                      aux_q      <= rom_b[15:0];
                      wpos_q     <= wpos_q + 16'd1;
                      ecur_q     <= ecur_q + 8'd1;
                      state_q    <= StEmit2;
                    end
                  end
                end
                R_REXEC: begin
                  if (rom_b == 32'd0) begin
                    mpc_q <= mpc_q + 16'd1;
                  end else if (rep_done_i) begin
                    if (rep_err_i) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q;
                      state_q      <= StDone;
                    end else if (rom_b == 32'd1) begin
                      wpos_q <= wpos_q + 16'd1;
                      ecur_q <= ecur_q + 8'd1;
                      mpc_q  <= mpc_q + 16'd1;
                    end else begin
                      wpos_q  <= wpos_q + 16'd1;
                      ecur_q  <= ecur_q + 8'd1;
                      cnt_q   <= 16'(rom_b) - 16'd1;
                      state_q <= StXbuf;
                    end
                  end
                end
                R_REND: begin
                  done_words_q <= wpos_q;
                  state_q      <= StDone;
                end
                R_RRET: begin
                  if (ret_sp_q != 4'h0) begin
                    ret_sp_q <= ret_sp_q - 4'd1;
                    mpc_q    <= ret_stk_q[ret_sp_q[2:0] - 3'd1];
                  end else begin
                    done_words_q <= wpos_q;
                    state_q      <= StDone;
                  end
                end
                default: begin
                  fault_q      <= 1'b1;
                  done_words_q <= wpos_q;
                  state_q      <= StDone;
                end
              endcase
            end
          end

          StEmit2: begin
            if (!wpos_ok) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if (rep_done_i) begin
              if (rep_err_i) begin
                fault_q      <= 1'b1;
                done_words_q <= wpos_q;
                state_q      <= StDone;
              end else begin
                wpos_q <= wpos_q + 16'd1;
                case (rom_op)
                  R_RPTR: begin
                    if (!op_q.pres[rom_a[2:0]])
                      mpc_q <= mpc_q + 16'd1 + 16'(aux_q);
                    else
                      mpc_q <= mpc_q + 16'd1;
                    state_q <= StOp;
                  end
                  R_RCHAIN: begin
                    if (cpos_q >= op_q.chain_n) begin
                      mpc_q   <= mpc_q + 16'd1;
                      state_q <= StOp;
                    end else if (chain_w == 48'h0) begin
                      fault_q      <= 1'b1;
                      done_words_q <= wpos_q + 16'd1;
                      state_q      <= StDone;
                    end else begin
                      // third emit = recorded sType, then the body runs
                      tmp_q   <= node_st_q;
                      state_q <= StEmit3;
                    end
                  end
                  R_REXBUF: begin
                    // ceil(count * elem_bytes / 4) payload words;
                    // a zero-payload buffer skips StXbuf entirely
                    if (((34'(xbuf_cnt_q) * 34'(aux_q)) + 34'd3) >> 2
                        == 34'd0) begin
                      mpc_q   <= mpc_q + 16'd1;
                      state_q <= StOp;
                    end else begin
                      cnt_q   <= 16'(((34'(xbuf_cnt_q) * 34'(aux_q))
                                      + 34'd3) >> 2);
                      state_q <= StXbuf;
                    end
                  end
                  default: begin
                    mpc_q   <= mpc_q + 16'd1;
                    state_q <= StOp;
                  end
                endcase
              end
            end
          end

          StEmit3: begin
            if (!wpos_ok || ret_sp_q[3]) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if (rep_done_i) begin
              if (rep_err_i) begin
                fault_q      <= 1'b1;
                done_words_q <= wpos_q;
                state_q      <= StDone;
              end else begin
                wpos_q <= wpos_q + 16'd1;
                ret_stk_q[ret_sp_q[2:0]] <= mpc_q + 16'd1;
                ret_sp_q <= ret_sp_q + 4'd1;
                mpc_q    <= chain_tgt_q;
                cpos_q   <= cpos_q + 4'd1;
                state_q  <= StOp;
              end
            end
          end

          StConstCp: begin
            if (!wpos_ok) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if (rep_done_i) begin
              if (rep_err_i) begin
                fault_q      <= 1'b1;
                done_words_q <= wpos_q;
                state_q      <= StDone;
              end else begin
                wpos_q <= wpos_q + 16'd1;
                ridx_q <= ridx_q + 16'd1;
                if (cnt_q == 16'd1) begin
                  mpc_q   <= mpc_q + 16'd1;
                  state_q <= StOp;
                end else begin
                  cnt_q <= cnt_q - 16'd1;
                end
              end
            end
          end

          // serialized read->write pair per emitted word: read phase
          // issues the CS word (cnt_q counts reads still to issue,
          // decremented at accept; blob_first_q covers the count-lo
          // read), the captured word is written out in write phase
          StBlob: begin
            if (!blob_ph_q) begin
              if (cs_rvalid_i) begin
                if (cs_err_i) begin
                  fault_q      <= 1'b1;
                  done_words_q <= wpos_q;
                  state_q      <= StDone;
                end else begin
                  rd_data_q <= cs_rdata_i;
                  blob_ph_q <= 1'b1;
                end
              end
            end else if (!wpos_ok) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if (rep_done_i) begin
              if (rep_err_i) begin
                fault_q      <= 1'b1;
                done_words_q <= wpos_q;
                state_q      <= StDone;
              end else begin
                wpos_q    <= wpos_q + 16'd1;
                blob_ph_q <= 1'b0;
                // emits = count pair + payload = words + 2 words
                if (blob_em_q ==
                    16'(op_q.blob[rom_a[0]].words) + 16'd1) begin
                  mpc_q   <= mpc_q + 16'd1;
                  state_q <= StOp;
                end else begin
                  blob_em_q <= blob_em_q + 16'd1;
                end
              end
            end
          end

          StXbuf: begin
            if (!wpos_ok || {1'b0, ecur_q} >= {1'b0, exec_n_i}) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if (rep_done_i) begin
              if (rep_err_i) begin
                fault_q      <= 1'b1;
                done_words_q <= wpos_q;
                state_q      <= StDone;
              end else begin
                wpos_q <= wpos_q + 16'd1;
                ecur_q <= ecur_q + 8'd1;
                if (cnt_q <= 16'd1) begin
                  mpc_q   <= mpc_q + 16'd1;
                  state_q <= StOp;
                end else begin
                  cnt_q <= cnt_q - 16'd1;
                end
              end
            end
          end

          StChainScan: begin
            if (32'(tcur_q) >= APU_VN_CHAIN_WORDS ||
                (scan_w != 48'h0 && scan_w[31:0] == node_st_q &&
                 !wpos_ok)) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else if (scan_w == 48'h0) begin
              // not a member of this reply table: skip the node
              cpos_q  <= cpos_q + 4'd1;
              state_q <= StChkNext;
            end else if (scan_w[31:0] == node_st_q) begin
              if (rep_done_i) begin
                if (rep_err_i) begin
                  fault_q      <= 1'b1;
                  done_words_q <= wpos_q;
                  state_q      <= StDone;
                end else begin
                  wpos_q      <= wpos_q + 16'd1;
                  tmp_q       <= 32'h0;
                  chain_tgt_q <= scan_w[47:32];
                  state_q     <= StEmit2;
                end
              end
            end else begin
              tcur_q <= tcur_q + 16'd1;
            end
          end

          StChkNext: begin
            if (cpos_q >= op_q.chain_n) begin
              if (!wpos_ok) begin
                fault_q      <= 1'b1;
                done_words_q <= wpos_q;
                state_q      <= StDone;
              end else if (rep_done_i) begin
                if (rep_err_i) begin
                  fault_q      <= 1'b1;
                  done_words_q <= wpos_q;
                  state_q      <= StDone;
                end else begin
                  wpos_q  <= wpos_q + 16'd1;
                  tmp_q   <= 32'h0;
                  state_q <= StEmit2;
                end
              end
            end else if (chain_w == 48'h0) begin
              fault_q      <= 1'b1;
              done_words_q <= wpos_q;
              state_q      <= StDone;
            end else begin
              node_st_q <= chain_w[31:0];
              tcur_q    <= 16'(rom_b);
              state_q   <= StChainScan;
            end
          end

          default: state_q <= StIdle;
        endcase
      end
    end
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_vnrep_fixture
  import g6lc_apu_vn_pkg::*;
#(parameter bit Enable = 1'b0) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,
  input  apu_vn_op_t  op_i,
  input  logic [31:0] result_i,
  input  logic [APU_VN_EXEC_WORDS*32-1:0] exec_w_i,
  input  logic [7:0]  exec_n_i,
  input  logic [31:0] rep_null_mask_i,
  input  logic [15:0] rep_base_i,
  input  logic [15:0] rep_len_i,
  input  logic [15:0] cs_base_i,
  output logic        cs_re_o,
  output logic [15:0] cs_addr_o,
  input  logic        cs_ready_i,
  input  logic        cs_rvalid_i,
  input  logic [31:0] cs_rdata_i,
  input  logic        cs_err_i,
  output logic        rep_we_o,
  output logic [15:0] rep_addr_o,
  output logic [31:0] rep_wdata_o,
  input  logic        rep_ready_i,
  input  logic        rep_done_i,
  input  logic        rep_err_i,
  output logic        busy_o,
  output logic        done_o,
  output logic [15:0] rep_words_o,
  output logic        fault_o
);
  g6lc_apu_vnrep #(.Enable(Enable)) i_dut (.*);
endmodule
