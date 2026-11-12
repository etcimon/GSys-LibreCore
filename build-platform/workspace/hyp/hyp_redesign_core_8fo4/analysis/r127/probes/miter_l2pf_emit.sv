// SPDX-License-Identifier: MIT
// miter_l2pf_emit — equivalence miter for the g6lc_l2_pf emit-walk rewrite
// (r127-aa). Compares the SERIAL early-exit round-robin walk (OLD, copied
// verbatim from g6lc_l2_pf.sv) against the PARALLEL per-stream evaluation
// (NEW) over randomized stream tables / round-robin pointers / train events.
//
// Compared outputs (the emit block's full contribution):
//   cnd_vld_d, cnd_line_d, rr_d, and the whole st_d array (emit touches only
//   pend/ahead, but the full struct is compared so nothing is missed).
//
// Build/run: compile this file with the --binary --timing flags and run the
// resulting model with +N=<iterations> to set the cycle count.

module miter_l2pf_emit;

  // ---- parameters: mirror g6lc_l2_pf defaults (bench config) ----
  `ifdef MITER_NR_STREAMS
  localparam int unsigned NR_STREAMS    = `MITER_NR_STREAMS;
  `else
  localparam int unsigned NR_STREAMS    = 4;
  `endif
  localparam int unsigned PF_DISTANCE   = 2;
  localparam int unsigned LINE_BYTES    = 64;
  localparam int unsigned AXI_ADDR_WIDTH= 64;
  localparam int unsigned OFF_BITS      = $clog2(LINE_BYTES);
  localparam int unsigned PAGE_LBITS    = 12 - OFF_BITS;
  localparam int unsigned LINE_BITS     = AXI_ADDR_WIDTH - OFF_BITS;
  localparam int unsigned PAGETAG_W     = LINE_BITS - PAGE_LBITS;
  localparam int unsigned SW            = (NR_STREAMS <= 1) ? 1 : $clog2(NR_STREAMS);
  localparam int unsigned PW            = (PF_DISTANCE <= 1) ? 1 : $clog2(PF_DISTANCE + 1);
  localparam int unsigned DLT_W         = PAGE_LBITS + 1;
  localparam int unsigned EM_W          = DLT_W + PW + 2;
  localparam int unsigned QW            = 4;   // quiet_d driven directly

  typedef struct packed {
    logic                      valid;
    logic [PAGETAG_W-1:0]      page;
    logic [LINE_BITS-1:0]      last;
    logic signed [DLT_W-1:0]   stride;
    logic                      seen;
    logic [1:0]                conf;
    logic [PW-1:0]             pend;
    logic [PW-1:0]             ahead;
  } stream_t;

  // ---- inputs ----
  stream_t [NR_STREAMS-1:0] st_q;
  logic [SW-1:0]            rr_q;
  logic                     train_i, train_hit;
  logic [SW-1:0]            train_hit_idx;
  logic                     cnd_vld_d_in;   // entry value into emit walk
  logic [LINE_BITS-1:0]     cnd_line_q_in;  // default cnd_line_d
  logic [QW-1:0]            quiet_d_in;     // emit guard: ==0 to run

  // ---- OLD outputs ----
  logic                     o_vld, o_rr_vld;
  logic [LINE_BITS-1:0]     o_line;
  logic [SW-1:0]            o_rr;
  stream_t [NR_STREAMS-1:0] o_st;

  // ---- NEW outputs ----
  logic                     n_vld;
  logic [LINE_BITS-1:0]     n_line;
  logic [SW-1:0]            n_rr;
  stream_t [NR_STREAMS-1:0] n_st;

  // shared temps
  int unsigned em_s;
  logic [LINE_BITS-1:0] em_base;
  logic signed [DLT_W-1:0] tr_d, tr_str;
  logic signed [EM_W-1:0] em_prod, es;
  logic signed [EM_W:0]   xs;

  // ============================================================ OLD (serial)
  always_comb begin
    em_s='0; em_base='0; tr_d='0; tr_str='0; es='0; em_prod='0; xs='0;
    o_st = st_q;
    o_rr = rr_q;
    o_vld = cnd_vld_d_in;
    o_line = cnd_line_q_in;
    if (!o_vld && (quiet_d_in == '0)) begin
      for (int unsigned k = 0; k < NR_STREAMS; k++) begin
        em_s = (rr_q + k) % NR_STREAMS;
        if (!o_vld && st_q[em_s].valid && (st_q[em_s].pend != '0) &&
            !(train_i && train_hit && (train_hit_idx == SW'(em_s)))) begin
          es      = $signed(st_q[em_s].stride);
          em_prod = '0;
          for (int unsigned b = 0; b < PW; b++) begin
            if (st_q[em_s].ahead[b])
              em_prod = em_prod + (es <<< b);
          end
          xs = $signed({{(EM_W+1-PAGE_LBITS){1'b0}},
                        st_q[em_s].last[PAGE_LBITS-1:0]}) + em_prod;
          em_base = st_q[em_s].last + LINE_BITS'(em_prod);
          if (!(|xs[EM_W:PAGE_LBITS])) begin
            o_vld  = 1'b1;
            o_line = em_base;
            o_st[em_s].pend  = st_q[em_s].pend - 1'b1;
            o_st[em_s].ahead = st_q[em_s].ahead + 1'b1;
            o_rr   = SW'((em_s + 1) % NR_STREAMS);
          end else begin
            o_st[em_s].pend = '0;
          end
        end
      end
    end
  end

  // ============================================================ NEW (parallel)
  // Per-stream results at constant indices, then a position-priority winner.
  logic [NR_STREAMS-1:0] em_ok, em_pc, em_win, em_blk;
  logic [LINE_BITS-1:0]  em_bs [NR_STREAMS];
  logic [SW-1:0]         em_ps [NR_STREAMS], em_wpos;
  logic                  em_any;
  logic signed [EM_W-1:0] pr_s;
  logic signed [EM_W:0]   xs_s;

  always_comb begin
    // defaults
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      em_ok[s]=0; em_pc[s]=0; em_win[s]=0; em_blk[s]=0; em_bs[s]='0;
      em_ps[s]='0;
    end
    em_any=0; em_wpos='0;
    n_st = st_q;
    n_rr = rr_q;
    n_vld = cnd_vld_d_in;
    n_line = cnd_line_q_in;

    if (!n_vld && (quiet_d_in == '0)) begin
      // ---- per-stream constant-index evaluation ----
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        // retrain guard: stream being retrained keeps its new epoch
        if (st_q[s].valid && (st_q[s].pend != '0) &&
            !(train_i && train_hit && (train_hit_idx == SW'(s)))) begin
          es   = $signed(st_q[s].stride);
          pr_s = '0;
          for (int unsigned b = 0; b < PW; b++)
            if (st_q[s].ahead[b]) pr_s = pr_s + (es <<< b);
          xs_s   = $signed({{(EM_W+1-PAGE_LBITS){1'b0}},
                           st_q[s].last[PAGE_LBITS-1:0]}) + pr_s;
          em_bs[s] = st_q[s].last + LINE_BITS'(pr_s);
          if (!(|xs_s[EM_W:PAGE_LBITS])) begin
            em_ok[s] = 1'b1;                 // armed && in-page => emit candidate
          end else begin
            em_pc[s] = 1'b1;                 // armed && page-bound => pend clear
          end
        end
        // rr-order position of stream s: forward distance from rr_q, mod N.
        // Works for any NR_STREAMS (no power-of-2 assumption).
        em_ps[s] = SW'( (int'(s) >= int'(rr_q))
                        ? (int'(s) - int'(rr_q))
                        : (int'(s) - int'(rr_q) + NR_STREAMS) );
      end
      // ---- winner: emitter with smallest rr-position ----
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        for (int unsigned t = 0; t < NR_STREAMS; t++) begin
          if (em_ok[t] && (em_ps[t] < em_ps[s])) em_blk[s] = 1'b1;
        end
        em_win[s] = em_ok[s] && !em_blk[s];
      end
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        if (em_win[s]) begin
          em_any  = 1'b1;
          em_wpos = em_ps[s];
        end
      end
      // ---- apply ----
      if (em_any) n_vld = 1'b1;
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        if (em_win[s]) begin
          n_line = em_bs[s];
          n_st[s].pend  = st_q[s].pend - 1'b1;
          n_st[s].ahead = st_q[s].ahead + 1'b1;
          n_rr = SW'( (int'(s) + 1) % NR_STREAMS );
        end else if (em_pc[s] && (!em_any || (em_ps[s] < em_wpos))) begin
          n_st[s].pend = '0;
        end
      end
    end
  end

  // ============================================================ compare
  int unsigned errors = 0, checked = 0;
  int unsigned iters;
  initial begin
    if (!$value$plusargs("N=%d", iters)) iters = 1000000;
    repeat (20) @(posedge clk);
    for (int i = 0; i < iters; i++) begin
      @(posedge clk);
      // randomize inputs
      for (int s = 0; s < NR_STREAMS; s++) begin
        st_q[s].valid = $urandom_range(0,1);
        st_q[s].page  = $urandom;
        st_q[s].last  = $urandom;
        st_q[s].stride= $urandom_range(-64, 63);
        st_q[s].seen  = $urandom_range(0,1);
        st_q[s].conf  = $urandom_range(0,3);
        st_q[s].pend  = $urandom_range(0, (1<<PW)-1);
        st_q[s].ahead = $urandom_range(0, (1<<PW)-1);
      end
      rr_q           = SW'($urandom_range(0, NR_STREAMS-1));
      train_i        = $urandom_range(0,1);
      train_hit      = $urandom_range(0,1);
      train_hit_idx  = SW'($urandom_range(0, NR_STREAMS-1));
      cnd_vld_d_in   = ($urandom_range(0,9) < 8) ? 1'b0 : 1'b1;  // mostly open
      quiet_d_in     = ($urandom_range(0,9) < 8) ? '0    : $urandom_range(1,3);
      cnd_line_q_in  = $urandom;
      #1; // settle comb
      checked++;
      if (o_vld !== n_vld || o_line !== n_line || o_rr !== n_rr ||
          o_st !== n_st) begin
        errors++;
        if (errors <= 8) begin
          $display("MISMATCH it=%0d vld %b/%b line %h/%h rr %0d/%0d",
                   i, o_vld, n_vld, o_line, n_line, o_rr, n_rr);
          for (int s=0;s<NR_STREAMS;s++)
            if (o_st[s] !== n_st[s])
              $display("  st[%0d] old=%p new=%p", s, o_st[s], n_st[s]);
          $display("  rr_q=%0d train_i=%b hit=%b hidx=%0d cndv=%b quiet=%0d",
                   rr_q, train_i, train_hit, train_hit_idx, cnd_vld_d_in, quiet_d_in);
        end
      end
    end
    $display("MITER checked=%0d errors=%0d", checked, errors);
    if (errors == 0) $display("MITER PASS"); else $display("MITER FAIL");
    $finish;
  end

  logic clk = 0;
  always #5 clk = ~clk;

endmodule
