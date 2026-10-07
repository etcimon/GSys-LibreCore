// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Table-driven Venus command decoder: executes the generated
// APU_VN_DEC_ROM micro-program against a word-addressed command stream
// and produces the apu_vn_op_t record the executor and reply engine
// consume.  Semantics mirror the Python golden sim (vn_golden.py Sim):
//
//   word0 = command type, word1 = flags; cs_len_i < 2 -> BOUND.
//   APU_VN_DEC_ENTRY[type] = mpc or 16'hFFFF -> UNKNOWN_TYPE.
//   ROM word {op[47:40], a[39:32], b[31:0]}:
//     U32 a        : 1 word -> imm[a] (a=FF discards)
//     U64 a        : 2 words -> q[a]
//     HANDLE a={slot,role} b=kind : 2 words -> q/kind/role; id==0 and
//                    role not NEW/OPTIONAL -> HANDLE_ZERO
//     PTR a b=skip : 2 words presence -> pres[a]; zero -> mpc += 1+skip
//     STYPE b      : 1 word vs APU_VN_CONST[b] -> STYPE fault
//     PNEXT b=tbl  : u64 presence + u32 sType header loop; each nonzero
//                    header is looked up in APU_VN_CHAIN (0-terminated
//                    {sType,mpc} pairs), appended to chain[] (BOUND at 8),
//                    its body mpc collected; after the zero header the
//                    bodies run in REVERSE order via the return stack;
//                    unknown sType -> PNEXT fault carrying the sType
//     ARRAY a b=meta : u64 count vs APU_VN_ARRMETA[b] -> BOUND; count==0
//                    skips the element program (scan to matching ENDARR),
//                    else pushes the 2-deep loop stack (LOOP at depth 3)
//     ENDARR       : decrement top loop; re-enter body or pop
//     BLOB a b=meta : u64 count; APU_VN_BLOBMETA[b]={eb,maxw};
//                    words=ceil(count*eb/4); BOUND if >maxw or past len;
//                    blob[a]={pos,words}; pos advances words
//     FLAGS a b    : 1 word; word & ~CONST[b] -> FLAGS fault; else imm[a]
//     SKIPW b      : pos += b (BOUND if past len)
//     CHECK a b    : 1 word vs CONST[b] -> STYPE fault; else imm[a]
//     OBJ b        : rec.obj_kind = b
//     END a        : rec.reply_prog = a; command complete
//     RET          : pop return stack (chain body end); empty stack ends
//                    the program like the golden sim (reply_prog stays 0)
//
//   KEEP (a[7] of the ROM word on U32/U64/HANDLE/BLOB/PTR, §7b): the
//   words the op consumes are also streamed on pay_valid_o/pay_data_o
//   in decode order — U32 1 word, U64/HANDLE the 2 raw words, PTR the
//   0/1 presence word, BLOB its data words (the decoder steps through
//   them instead of skipping).  pay_words counts them in op_o.
//
//   Every fault leaves pos at the offending word; words/fault_word are
//   CS-relative indices, fault_val the diagnostic payload.  CS reads are
//   issued one cycle ahead (cs_re_o/cs_addr_o -> cs_rdata_i next cycle);
//   multi-word ops stream at one word per cycle.  Payload emission is
//   gated on the op completing without fault so a truncated or rejected
//   word is never reported (matches the golden sim).
//
// Timing impact: all table lookups are combinational localparam muxes
// (DEC_ROM 1648x48, CHAIN 147x48, CONST/ARRMETA/BLOBMETA small); the
// per-cycle work is one CS word plus one micro-op decision.  The widest
// cones are the ROM word mux and the 64x8 BLOB product (only in the
// count-consume state).  The return stack (32 x 16b) covers PNEXT bodies
// nested to the chain bound; overflow -> ROM fault.
//
// Review checklist: async active-low reset; no latches; single always_ff
// plus combinational SRAM-request steering; Enable=0 elaborates no
// datapath; done_o is a one-cycle pulse, op_o held until next start_i.

module g6lc_apu_vndec
  import g6lc_apu_vn_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,
  input  logic [15:0] cs_base_i,
  input  logic [15:0] cs_len_i,
  output logic        cs_re_o,
  output logic [15:0] cs_addr_o,
  input  logic        cs_ready_i,
  input  logic        cs_rvalid_i,
  input  logic [31:0] cs_rdata_i,
  input  logic        cs_err_i,
  output logic        busy_o,
  output logic        done_o,
  output apu_vn_op_t  op_o,
  output logic        pay_valid_o,
  output logic [31:0] pay_data_o
);
  if (!Enable) begin : gen_off
    assign cs_re_o   = 1'b0;
    assign cs_addr_o = '0;
    assign busy_o    = 1'b0;
    assign done_o    = 1'b0;
    assign op_o      = '{fault: APU_VN_FAULT_NONE, default: '0};
    assign pay_valid_o = 1'b0;
    assign pay_data_o  = '0;
    logic unused;
    assign unused = clk_i | rst_ni | start_i | cs_rdata_i[0] |
                    cs_ready_i | cs_rvalid_i | cs_err_i |
                    (|cs_base_i) | (|cs_len_i) | (|cs_rdata_i);
  end else begin : gen_on
    // micro-op encodings (must match gen_vn_tables.py DEC_OPS)
    localparam logic [7:0] O_U32    = 8'd1;
    localparam logic [7:0] O_U64    = 8'd2;
    localparam logic [7:0] O_HANDLE = 8'd3;
    localparam logic [7:0] O_PTR    = 8'd4;
    localparam logic [7:0] O_STYPE  = 8'd5;
    localparam logic [7:0] O_PNEXT  = 8'd6;
    localparam logic [7:0] O_ARRAY  = 8'd7;
    localparam logic [7:0] O_ENDARR = 8'd8;
    localparam logic [7:0] O_BLOB   = 8'd9;
    localparam logic [7:0] O_FLAGS  = 8'd10;
    localparam logic [7:0] O_SKIPW  = 8'd11;
    localparam logic [7:0] O_CHECK  = 8'd12;
    localparam logic [7:0] O_OBJ    = 8'd13;
    localparam logic [7:0] O_END    = 8'd14;
    localparam logic [7:0] O_RET    = 8'd15;

    typedef enum logic [4:0] {
      StIdle, StHdrType, StHdrFlags, StOp,
      StW1, StW2Lo, StW2Hi, StW3, StBPay,
      StPnLo, StPnHi, StPnSt, StPnScan, StPnPop,
      StArrSkip, StDone
    } state_e;

    state_e        state_q;
    logic [15:0]   base_q, len_q, pos_q, mpc_q;
    apu_vn_op_t    rec_q;
    // unpacked record arrays live outside rec_q: Verilator cannot take a
    // variable index into an unpacked array field of an unpacked struct.
    logic [63:0]   q_q [8];
    logic [5:0]    qkind_q [8];
    logic [2:0]    qrole_q [8];
    logic [31:0]   imm_q [16];
    logic [31:0]   cnt_q [4];
    apu_vn_blob_t  blob_q [2];
    logic [15:0]   chain_q [8];
    logic [7:0]    qv_q, pres_q; // op_o.qv / .pres (see note above)
    logic [15:0]   immv_q;       // op_o.immv
    logic [31:0]   tmp_q;        // low word of a pending u64
    // loop stack (ARRAY), depth <= 2
    logic [31:0]   loop_rem_q [2];
    logic [15:0]   loop_mpc_q [2];
    logic [1:0]    loop_sp_q;
    // return stack (PNEXT bodies + resume points)
    logic [15:0]   ret_stk_q [32];
    logic [5:0]    ret_sp_q;
    // collected chain bodies for the in-flight PNEXT
    logic [15:0]   body_q [8];
    logic [3:0]    body_n_q;
    logic [15:0]   scan_q;       // chain-table scan index
    logic [31:0]   pnext_st_q;   // sType being looked up
    logic [15:0]   skip_d_q;     // ARRAY cnt==0 skip depth
    // §7b payload: KEEP latched per op, hi word held for StW3, BLOB
    // keep walks the data words in StBPay
    logic          keep_q;
    logic [31:0]   payw_q;
    logic [16:0]   bpay_rem_q;

    logic [47:0]   rom_w;
    logic [7:0]    rom_op, rom_a;
    logic [31:0]   rom_b;
    assign rom_w  = 32'(mpc_q) < APU_VN_DEC_ROM_WORDS
                    ? APU_VN_DEC_ROM[mpc_q[APU_VN_DEC_MPC_AW-1:0]] : 48'h0;
    assign rom_op = rom_w[47:40];
    assign rom_a  = rom_w[39:32];
    assign rom_b  = rom_w[31:0];

    logic [47:0]   chain_w;
    assign chain_w = 32'(scan_q) < APU_VN_CHAIN_WORDS
                     ? APU_VN_CHAIN[scan_q[APU_VN_CHAIN_AW-1:0]] : 48'h0;

    logic [15:0]   ent_mpc;
    // consumed in StHdrFlags: rdata there is the flags word, so the
    // entry lookup must key off the latched cmd_type
    assign ent_mpc = rec_q.cmd_type <= 32'(APU_VN_DEC_TYPE_MAX)
                     ? APU_VN_DEC_ENTRY[rec_q.cmd_type[8:0]] : 16'hFFFF;

    // BLOB product, evaluated in the consume state only
    logic [71:0]   blob_prod;
    logic [31:0]   blob_meta;
    assign blob_meta = rom_b < APU_VN_BLOBMETA_WORDS
                       ? APU_VN_BLOBMETA[rom_b[APU_VN_BLOBMETA_AW-1:0]] : 32'h0;
    assign blob_prod = 72'({cs_rdata_i, tmp_q}) * 72'(blob_meta[7:0]);
    logic [33:0] blob_wn;
    assign blob_wn = (blob_prod[33:0] + 34'd3) >> 2;

    // Handshake CS port (§6c Settled bullet 3): cs_re_o holds until
    // cs_ready_i, one response returns per request on cs_rvalid_i, and
    // the consuming state advances only when that response lands.  The
    // old one-word-per-cycle pipeline is serialized: a word is issued
    // (pos_q indexes the word being requested, incremented at accept),
    // its rvalid consumed, and only then is the next word requested —
    // at most one request in flight.
    logic rd_pend_q;    // request accepted, response outstanding
    logic cons_q;       // lo word consumed; second issue allowed
    logic pnz_q;        // PNEXT presence pair nonzero
    assign cs_addr_o = base_q + pos_q;

    // per-state read intent (before the rd_pend gate)
    logic want_rd;
    always_comb begin
      unique case (state_q)
        StHdrType: want_rd = 1'b1;                        // w0 then w1
        StOp:      want_rd = rom_op inside {O_U32, O_STYPE, O_FLAGS,
                                            O_CHECK, O_U64, O_HANDLE,
                                            O_PTR, O_ARRAY, O_BLOB,
                                            O_PNEXT} && pos_q < len_q;
        StW2Lo, StPnLo: want_rd = cons_q && pos_q < len_q; // hi word
        StPnHi:    want_rd = cons_q && pnz_q && pos_q < len_q;
        StBPay:    want_rd = bpay_rem_q > 17'd0;         // next data word
        StPnScan:  want_rd = chain_w != 48'h0 &&
                             chain_w[31:0] == pnext_st_q &&
                             pos_q < len_q &&
                             rec_q.chain_n < 4'd8;
        default:   want_rd = 1'b0;
      endcase
    end
    assign cs_re_o = want_rd && !rd_pend_q;

    // ---- §7b payload stream -------------------------------------------
    // One word per cycle, decode order; emitted only where the op cannot
    // fault after this point (a truncated u64 or a rejected HANDLE_ZERO
    // emits nothing, matching the golden sim).
    logic handle_ok;
    assign handle_ok = !rom_a[6] &&
                       !({cs_rdata_i, tmp_q} == 64'h0 &&
                          rom_a[2:0] != 3'(APU_VN_ROLE_NEW) &&
                          rom_a[2:0] != 3'(APU_VN_ROLE_OPTIONAL));
    // payload words emit on the response cycle (a faulted or
    // out-of-window read emits nothing — the fault arm wins anyway)
    logic cs_good;
    assign cs_good = cs_rvalid_i && !cs_err_i;
    assign pay_valid_o =
        (state_q == StW1 && keep_q && rom_op == O_U32 && cs_good) ||
        (state_q == StW2Hi && keep_q && cs_good &&
         (rom_op == O_U64 ||
          (rom_op == O_HANDLE && handle_ok) ||
          rom_op == O_PTR)) ||
        state_q == StW3 ||
        (state_q == StBPay && cs_good);
    assign pay_data_o =
        state_q == StW3 ? payw_q :
        (state_q == StW2Hi &&
         rom_op inside {O_U64, O_HANDLE}) ? tmp_q :
        (state_q == StW2Hi && rom_op == O_PTR)
            ? 32'(|{cs_rdata_i, tmp_q}) : cs_rdata_i;

    assign busy_o = state_q != StIdle;
    assign done_o = state_q == StDone;
    always_comb begin
      op_o = rec_q;
      op_o.qv   = qv_q;
      op_o.immv = immv_q;
      op_o.pres = pres_q;
      for (int i = 0; i < 8; i++) begin
        op_o.q[i]     = q_q[i];
        op_o.qkind[i] = qkind_q[i];
        op_o.qrole[i] = qrole_q[i];
        op_o.chain[i] = chain_q[i];
      end
      for (int i = 0; i < 16; i++) op_o.imm[i] = imm_q[i];
      for (int i = 0; i < 4; i++)  op_o.cnt[i] = cnt_q[i];
      for (int i = 0; i < 2; i++)  op_o.blob[i] = blob_q[i];
    end

    // fault helper fields set inline below
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= StIdle;
        base_q <= '0; len_q <= '0; pos_q <= '0; mpc_q <= '0;
        rec_q <= '{fault: APU_VN_FAULT_NONE, default: '0}; tmp_q <= '0;
        q_q <= '{default: '0}; qkind_q <= '{default: '0};
        qrole_q <= '{default: '0}; imm_q <= '{default: '0};
        cnt_q <= '{default: '0}; blob_q <= '{default: '0};
        chain_q <= '{default: '0};
        qv_q <= '0; pres_q <= '0; immv_q <= '0;
        loop_rem_q <= '{default: '0}; loop_mpc_q <= '{default: '0};
        loop_sp_q <= '0;
        ret_stk_q <= '{default: '0}; ret_sp_q <= '0;
        body_q <= '{default: '0}; body_n_q <= '0;
        scan_q <= '0; pnext_st_q <= '0; skip_d_q <= '0;
        keep_q <= 1'b0; payw_q <= '0; bpay_rem_q <= '0;
        rd_pend_q <= 1'b0; cons_q <= 1'b0; pnz_q <= 1'b0;
      end else begin
        if (pay_valid_o)
          rec_q.pay_words <= rec_q.pay_words + 16'd1;
        // CS handshake bookkeeping: accept sets pend, rvalid clears it
        if (cs_rvalid_i)      rd_pend_q <= 1'b0;
        else if (cs_re_o && cs_ready_i) rd_pend_q <= 1'b1;
        if (state_q == StIdle) rd_pend_q <= 1'b0;
        unique case (state_q)
        // ------------------------------------------------ idle / header
        StIdle: if (start_i) begin
          rec_q <= '{fault: APU_VN_FAULT_NONE, default: '0};
          q_q <= '{default: '0}; qkind_q <= '{default: '0};
          qrole_q <= '{default: '0}; imm_q <= '{default: '0};
          cnt_q <= '{default: '0}; blob_q <= '{default: '0};
          chain_q <= '{default: '0};
          qv_q <= '0; pres_q <= '0; immv_q <= '0;
          pos_q <= '0;
          tmp_q <= '0;
          loop_sp_q <= '0; ret_sp_q <= '0; body_n_q <= '0;
          cons_q <= 1'b0; pnz_q <= 1'b0;
          if (cs_len_i < 16'd2) begin
            rec_q.fault      <= APU_VN_FAULT_BOUND;
            rec_q.fault_word <= cs_len_i;
            rec_q.fault_val  <= 32'h0;
            rec_q.words      <= cs_len_i;
            state_q          <= StDone;
          end else begin
            base_q  <= cs_base_i;
            len_q   <= cs_len_i;
            state_q <= StHdrType;
          end
        end
        // word0: issued here (pos 0), consumed on rvalid; then word1
        // is issued (pos 1) and consumed by StHdrFlags
        StHdrType: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              rec_q.cmd_type <= cs_rdata_i;
              cons_q         <= 1'b1;
            end
          end
          if (cs_re_o && cs_ready_i) begin
            pos_q <= pos_q + 16'd1;
            if (cons_q) begin
              cons_q  <= 1'b0;
              state_q <= StHdrFlags;
            end
          end
        end
        StHdrFlags: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              rec_q.cmd_flags <= cs_rdata_i;
              if (ent_mpc == 16'hFFFF) begin
                rec_q.fault     <= APU_VN_FAULT_UNKNOWN_TYPE;
                rec_q.fault_val <= rec_q.cmd_type;
                rec_q.words     <= 16'd2;
                state_q         <= StDone;
              end else begin
                mpc_q   <= ent_mpc;
                state_q <= StOp;
              end
            end
          end
        end

        // ------------------------------------------------ micro-op dispatch
        StOp: begin
          // KEEP lives in a[7] of keepable ops only
          keep_q <= rom_a[7] &&
                    rom_op inside {O_U32, O_U64, O_HANDLE, O_PTR, O_BLOB};
          if (mpc_q >= APU_VN_DEC_ROM_WORDS) begin
            rec_q.fault      <= APU_VN_FAULT_ROM;
            rec_q.fault_word <= pos_q;
            rec_q.fault_val  <= 32'(mpc_q);
            rec_q.words      <= pos_q;
            state_q          <= StDone;
          end else unique case (rom_op)
            O_U32, O_STYPE, O_FLAGS, O_CHECK: begin
              if (pos_q >= len_q) begin
                rec_q.fault      <= APU_VN_FAULT_BOUND;
                rec_q.fault_word <= pos_q;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (cs_re_o && cs_ready_i) begin
                pos_q   <= pos_q + 16'd1;
                state_q <= StW1;
              end
            end
            O_U64, O_HANDLE, O_PTR, O_ARRAY, O_BLOB: begin
              if (pos_q >= len_q) begin
                rec_q.fault      <= APU_VN_FAULT_BOUND;
                rec_q.fault_word <= pos_q;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (cs_re_o && cs_ready_i) begin
                pos_q   <= pos_q + 16'd1;
                state_q <= StW2Lo;
              end
            end
            O_PNEXT: begin
              if (pos_q >= len_q) begin
                rec_q.fault      <= APU_VN_FAULT_BOUND;
                rec_q.fault_word <= pos_q;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (cs_re_o && cs_ready_i) begin
                body_n_q <= '0;
                pos_q    <= pos_q + 16'd1;
                state_q  <= StPnLo;
              end
            end
            O_SKIPW: begin
              if (32'(pos_q) + rom_b > 32'(len_q)) begin
                rec_q.fault      <= APU_VN_FAULT_BOUND;
                rec_q.fault_word <= pos_q;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else begin
                pos_q   <= pos_q + 16'(rom_b);
                mpc_q   <= mpc_q + 16'd1;
              end
            end
            O_OBJ: begin
              rec_q.obj_kind <= rom_b[5:0];
              mpc_q          <= mpc_q + 16'd1;
            end
            O_ENDARR: begin
              if (loop_sp_q == 2'd0) begin
                rec_q.fault      <= APU_VN_FAULT_ROM;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= 32'(mpc_q);
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (loop_rem_q[loop_sp_q[0] ^ 1'b1] > 32'd1) begin
                loop_rem_q[loop_sp_q[0] ^ 1'b1] <=
                    loop_rem_q[loop_sp_q[0] ^ 1'b1] - 32'd1;
                mpc_q <= loop_mpc_q[loop_sp_q[0] ^ 1'b1];
              end else begin
                loop_sp_q <= loop_sp_q - 2'd1;
                mpc_q     <= mpc_q + 16'd1;
              end
            end
            O_END: begin
              rec_q.reply_prog <= rom_a;
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end
            O_RET: begin
              if (ret_sp_q == 6'd0) begin
                // top-level RET: golden returns normally
                rec_q.words <= pos_q;
                state_q     <= StDone;
              end else begin
                ret_sp_q <= ret_sp_q - 6'd1;
                mpc_q    <= ret_stk_q[ret_sp_q[4:0] - 5'd1];
              end
            end
            default: begin
              rec_q.fault      <= APU_VN_FAULT_ROM;
              rec_q.fault_word <= pos_q;
              rec_q.fault_val  <= 32'(mpc_q);
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end
          endcase
        end

        // ------------------------------------------------ one-word ops
        StW1: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              state_q <= StOp;
              mpc_q   <= mpc_q + 16'd1;
              unique case (rom_op)
            O_U32: begin
              if (rom_a[6:0] != 7'h7F) begin
                imm_q[rom_a[3:0]]  <= cs_rdata_i;
                immv_q[rom_a[3:0]] <= 1'b1;
              end
            end
            O_STYPE: begin
              if (rom_b >= APU_VN_CONST_WORDS) begin
                rec_q.fault      <= APU_VN_FAULT_ROM;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= 32'(mpc_q);
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (cs_rdata_i != APU_VN_CONST[rom_b[APU_VN_CONST_AW-1:0]]) begin
                rec_q.fault      <= APU_VN_FAULT_STYPE;
                rec_q.fault_word <= pos_q - 16'd1;
                rec_q.fault_val  <= cs_rdata_i;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end
            end
            O_FLAGS: begin
              if (rom_b >= APU_VN_CONST_WORDS) begin
                rec_q.fault      <= APU_VN_FAULT_ROM;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= 32'(mpc_q);
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if ((cs_rdata_i & ~APU_VN_CONST[rom_b[APU_VN_CONST_AW-1:0]]) != 32'h0) begin
                rec_q.fault      <= APU_VN_FAULT_FLAGS;
                rec_q.fault_word <= pos_q - 16'd1;
                rec_q.fault_val  <= cs_rdata_i;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (rom_a != 8'hFF) begin
                imm_q[rom_a[3:0]]  <= cs_rdata_i;
                immv_q[rom_a[3:0]] <= 1'b1;
              end
            end
            O_CHECK: begin
              if (rom_b >= APU_VN_CONST_WORDS) begin
                rec_q.fault      <= APU_VN_FAULT_ROM;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= 32'(mpc_q);
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (cs_rdata_i != APU_VN_CONST[rom_b[APU_VN_CONST_AW-1:0]]) begin
                rec_q.fault      <= APU_VN_FAULT_STYPE;
                rec_q.fault_word <= pos_q - 16'd1;
                rec_q.fault_val  <= cs_rdata_i;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (rom_a != 8'hFF) begin
                imm_q[rom_a[3:0]]  <= cs_rdata_i;
                immv_q[rom_a[3:0]] <= 1'b1;
              end
            end
            default: begin
              rec_q.fault      <= APU_VN_FAULT_ROM;
              rec_q.fault_word <= pos_q;
              rec_q.fault_val  <= 32'(mpc_q);
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end
              endcase
            end
          end
        end

        // ------------------------------------------------ two-word ops
        // lo word lands on rvalid; only then is the hi word requested
        StW2Lo: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              tmp_q  <= cs_rdata_i;
              cons_q <= 1'b1;
            end
          end else if (cons_q && !rd_pend_q) begin
            if (pos_q >= len_q) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q;
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end else if (cs_re_o && cs_ready_i) begin
              pos_q   <= pos_q + 16'd1;
              cons_q  <= 1'b0;
              state_q <= StW2Hi;
            end
          end
        end
        StW2Hi: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              state_q <= StOp;
              mpc_q   <= mpc_q + 16'd1;
              unique case (rom_op)
            O_U64: begin
              // KEEP emits the lo word this cycle, the hi in StW3
              if (keep_q) begin
                payw_q  <= cs_rdata_i;
                state_q <= StW3;
              end
              if (rom_a[6:0] != 7'h7F) begin
                q_q[rom_a[2:0]]  <= {cs_rdata_i, tmp_q};
                qv_q[rom_a[2:0]] <= 1'b1;
              end
            end
            O_HANDLE: begin
              if (rom_a[6]) begin
                // slot field wider than q[] can express: malformed ROM
                rec_q.fault      <= APU_VN_FAULT_ROM;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= 32'(mpc_q);
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if ({cs_rdata_i, tmp_q} == 64'h0 &&
                  rom_a[2:0] != 3'(APU_VN_ROLE_NEW) &&
                  rom_a[2:0] != 3'(APU_VN_ROLE_OPTIONAL)) begin
                rec_q.fault      <= APU_VN_FAULT_HANDLE_ZERO;
                rec_q.fault_word <= pos_q - 16'd2;
                rec_q.fault_val  <= 32'h0;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else begin
                // KEEP emits the lo id word this cycle, the hi in StW3
                if (keep_q) begin
                  payw_q  <= cs_rdata_i;
                  state_q <= StW3;
                end
                q_q[rom_a[5:3]]     <= {cs_rdata_i, tmp_q};
                qkind_q[rom_a[5:3]] <= rom_b[5:0];
                qrole_q[rom_a[5:3]] <= rom_a[2:0];
                qv_q[rom_a[5:3]]    <= 1'b1;
              end
            end
            O_PTR: begin
              if (rom_a[6:0] != 7'h7F)
                pres_q[rom_a[2:0]] <= |{cs_rdata_i, tmp_q};
              if ({cs_rdata_i, tmp_q} == 64'h0)
                mpc_q <= mpc_q + 16'd1 + 16'(rom_b);
            end
            O_ARRAY: begin
              if (rom_b >= APU_VN_ARRMETA_WORDS) begin
                rec_q.fault      <= APU_VN_FAULT_ROM;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= 32'(mpc_q);
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if ({cs_rdata_i, tmp_q} >
                           64'(APU_VN_ARRMETA[rom_b[APU_VN_ARRMETA_AW-1:0]])) begin
                rec_q.fault      <= APU_VN_FAULT_BOUND;
                rec_q.fault_word <= pos_q - 16'd2;
                rec_q.fault_val  <= tmp_q;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else begin
                cnt_q[rom_a[1:0]] <= tmp_q;
                if ({cs_rdata_i, tmp_q} == 64'h0) begin
                  skip_d_q <= 16'd1;
                  state_q  <= StArrSkip;
                end else if (loop_sp_q == 2'd2) begin
                  rec_q.fault      <= APU_VN_FAULT_LOOP;
                  rec_q.fault_word <= pos_q - 16'd2;
                  rec_q.fault_val  <= tmp_q;
                  rec_q.words      <= pos_q;
                  state_q          <= StDone;
                end else begin
                  loop_rem_q[loop_sp_q[0]] <= tmp_q;
                  loop_mpc_q[loop_sp_q[0]] <= mpc_q + 16'd1;
                  loop_sp_q             <= loop_sp_q + 2'd1;
                end
              end
            end
            O_BLOB: begin
              if (rom_b >= APU_VN_BLOBMETA_WORDS) begin
                rec_q.fault      <= APU_VN_FAULT_ROM;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= 32'(mpc_q);
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (|blob_prod[71:34] ||
                             blob_wn > 34'(blob_meta[31:8])) begin
                rec_q.fault      <= APU_VN_FAULT_BOUND;
                rec_q.fault_word <= pos_q - 16'd2;
                rec_q.fault_val  <= tmp_q;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else if (|blob_wn[33:16] ||
                             17'(pos_q) + 17'(blob_wn[15:0]) > 17'(len_q)) begin
                rec_q.fault      <= APU_VN_FAULT_BOUND;
                rec_q.fault_word <= pos_q;
                rec_q.fault_val  <= tmp_q;
                rec_q.words      <= pos_q;
                state_q          <= StDone;
              end else begin
                blob_q[rom_a[0]].off   <= pos_q;
                blob_q[rom_a[0]].words <=
                    blob_wn > 34'h1FFFF ? 17'h1FFFF : 17'(blob_wn);
                if (keep_q) begin
                  // step through the data words, one per StBPay cycle;
                  // wn == 0 emits nothing and falls straight to StOp
                  if (blob_wn != 34'h0) begin
                    bpay_rem_q <= 17'(blob_wn[15:0]);
                    state_q    <= StBPay;
                  end
                end else begin
                  pos_q <= pos_q + 16'(blob_wn[15:0]);
                end
              end
            end
            default: begin
              rec_q.fault      <= APU_VN_FAULT_ROM;
              rec_q.fault_word <= pos_q;
              rec_q.fault_val  <= 32'(mpc_q);
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end
              endcase
            end
          end
        end

        // ------------------------------------------------ payload walk
        // hi word of a kept 2-word op (payw_q latched in StW2Hi)
        StW3:    state_q <= StOp;
        // kept BLOB: issue the next data word (one in flight), emit it
        // on rvalid; the last consume returns to StOp
        StBPay: begin
          if (cs_re_o && cs_ready_i)
            pos_q <= pos_q + 16'd1;
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else if (bpay_rem_q <= 17'd1) begin
              bpay_rem_q <= '0;
              state_q    <= StOp;
            end else begin
              bpay_rem_q <= bpay_rem_q - 17'd1;
            end
          end
        end

        // ------------------------------------------------ pNext chain
        // presence lo consumed on rvalid; then the hi word is issued
        StPnLo: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              tmp_q  <= cs_rdata_i;
              cons_q <= 1'b1;
            end
          end else if (cons_q && !rd_pend_q) begin
            if (pos_q >= len_q) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q;
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end else if (cs_re_o && cs_ready_i) begin
              pos_q   <= pos_q + 16'd1;
              cons_q  <= 1'b0;
              pnz_q   <= 1'b0;
              state_q <= StPnHi;
            end
          end
        end
        // presence hi consumed on rvalid; a nonzero pair issues the
        // sType word, a null pointer pops back out
        StPnHi: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              pnz_q  <= {cs_rdata_i, tmp_q} != 64'h0;
              cons_q <= 1'b1;
            end
          end else if (cons_q && !rd_pend_q) begin
            if (!pnz_q) begin
              cons_q  <= 1'b0;
              state_q <= StPnPop;
            end else if (pos_q >= len_q) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q;
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end else if (cs_re_o && cs_ready_i) begin
              pos_q   <= pos_q + 16'd1;
              cons_q  <= 1'b0;
              state_q <= StPnSt;
            end
          end
        end
        StPnSt: begin
          if (cs_rvalid_i) begin
            if (cs_err_i) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= 32'h0;
              rec_q.words      <= pos_q - 16'd1;
              state_q          <= StDone;
            end else begin
              pnext_st_q <= cs_rdata_i;
              scan_q     <= 16'(rom_b);
              state_q    <= StPnScan;
            end
          end
        end
        StPnScan: begin
          if (scan_q >= APU_VN_CHAIN_WORDS || chain_w == 48'h0) begin
            rec_q.fault      <= APU_VN_FAULT_PNEXT;
            rec_q.fault_word <= pos_q - 16'd1;
            rec_q.fault_val  <= pnext_st_q;
            rec_q.words      <= pos_q;
            state_q          <= StDone;
          end else if (chain_w[31:0] == pnext_st_q) begin
            if (rec_q.chain_n == 4'd8) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q - 16'd1;
              rec_q.fault_val  <= pnext_st_q;
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end else if (pos_q >= len_q) begin
              rec_q.fault      <= APU_VN_FAULT_BOUND;
              rec_q.fault_word <= pos_q;
              rec_q.words      <= pos_q;
              state_q          <= StDone;
            end else if (cs_re_o && cs_ready_i) begin
              chain_q[rec_q.chain_n[2:0]] <= 16'(scan_q);
              rec_q.chain_n                   <= rec_q.chain_n + 4'd1;
              body_q[body_n_q[2:0]]           <= chain_w[47:32];
              body_n_q                        <= body_n_q + 4'd1;
              pos_q                           <= pos_q + 16'd1;
              state_q                         <= StPnLo;
            end
          end else begin
            scan_q <= scan_q + 16'd1;
          end
        end
        StPnPop: begin
          // push resume + bodies[0..n-2], enter bodies[n-1] first so the
          // body programs run in reverse order; each RET pops the next.
          if (body_n_q == 4'd0) begin
            mpc_q   <= mpc_q + 16'd1;
            state_q <= StOp;
          end else if (ret_sp_q + 6'(body_n_q) > 6'd32) begin
            rec_q.fault      <= APU_VN_FAULT_ROM;
            rec_q.fault_word <= pos_q;
            rec_q.fault_val  <= 32'(mpc_q);
            rec_q.words      <= pos_q;
            state_q          <= StDone;
          end else begin
            ret_stk_q[ret_sp_q[4:0]] <= mpc_q + 16'd1;
            for (int i = 0; i < 8; i++)
              if (i < 32'(body_n_q) - 1)
                ret_stk_q[5'(ret_sp_q) + 5'd1 + 5'(i)] <= body_q[i];
            ret_sp_q <= ret_sp_q + 6'(body_n_q);
            mpc_q    <= body_q[body_n_q[2:0] - 3'd1];
            state_q  <= StOp;
          end
        end

        // ------------------------------------------------ ARRAY count==0 skip
        StArrSkip: begin
          // scan forward to the matching ENDARR (nested ARRAYs counted)
          if (mpc_q >= APU_VN_DEC_ROM_WORDS) begin
            rec_q.fault      <= APU_VN_FAULT_ROM;
            rec_q.fault_word <= pos_q;
            rec_q.fault_val  <= 32'(mpc_q);
            rec_q.words      <= pos_q;
            state_q          <= StDone;
          end else if (rom_op == O_ARRAY) begin
            skip_d_q <= skip_d_q + 16'd1;
            mpc_q    <= mpc_q + 16'd1;
          end else if (rom_op == O_ENDARR) begin
            if (skip_d_q == 16'd1) begin
              mpc_q   <= mpc_q + 16'd1;
              state_q <= StOp;
            end else begin
              skip_d_q <= skip_d_q - 16'd1;
              mpc_q    <= mpc_q + 16'd1;
            end
          end else begin
            mpc_q <= mpc_q + 16'd1;
          end
        end

        // ------------------------------------------------ done pulse
        StDone:  state_q <= StIdle;
        default: state_q <= StIdle;
        endcase
      end
    end

`ifndef SYNTHESIS
    // done is a one-cycle pulse; the record holds while idle.  $stable
    // cannot compare unpacked structs on older Verilators, so the check
    // covers the scalar fields (arrays are written only during decode).
    logic [351:0] op_sig;
    assign op_sig = {op_o.cmd_type, op_o.cmd_flags, op_o.qv, op_o.immv,
                     op_o.pres, op_o.chain_n, op_o.obj_kind,
                     op_o.reply_prog, op_o.words, op_o.fault,
                     op_o.fault_word, op_o.fault_val};
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      done_o |=> !busy_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      !busy_o && !start_i |=> $stable(op_sig) || done_o);
`endif
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_vndec_fixture
  import g6lc_apu_vn_pkg::*;
#(parameter bit Enable = 1'b0) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,
  input  logic [15:0] cs_base_i,
  input  logic [15:0] cs_len_i,
  output logic        cs_re_o,
  output logic [15:0] cs_addr_o,
  input  logic        cs_ready_i,
  input  logic        cs_rvalid_i,
  input  logic [31:0] cs_rdata_i,
  input  logic        cs_err_i,
  output logic        busy_o,
  output logic        done_o,
  output apu_vn_op_t  op_o,
  output logic        pay_valid_o,
  output logic [31:0] pay_data_o
);
  g6lc_apu_vndec #(.Enable(Enable)) i_dut (.*);
endmodule
