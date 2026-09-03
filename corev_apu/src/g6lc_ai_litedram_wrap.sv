// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// I3 class-1: AXI4 slave → LiteDRAM native port (user_port_native_0_*).
// 4×64-bit AXI beats pack into one 256-bit native word. Completed words sit
// in a 2-deep FIFO so packing the next word cannot overwrite a word waiting
// for the native engine (64 B INCR = two native cmds). Native cmds are
// pipelined; rdata sits in a FIFO so CAS can overlap AXI emission.
// NrArSlots outstanding AR / NrAwSlots outstanding AW (default 8).
// Native has no ID. AXI is held off until init_done (ForceInitDone in --sim).
// CLASS1 testharness ELF preload steals the native write engine (pl_*);
// directed TBs tie pl_req_i=0. Not a PHY backdoor.
// Multi-beat WRAP/FIXED/RESERVED and size>3 handshake then SLVERR
// (never stall aw_ready; no native cmd). Single-beat WRAP/FIXED is INCR.
// L1 I$/D$ fills are 16 B INCR (len=1); L2 is 64 B INCR. Extra ARs wait on
// ar_ready (backpressure, not stall). Atomics sit above.

`include "axi/assign.svh"

module g6lc_ai_litedram_wrap #(
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter bit          ForceInitDone  = 1'b1,
    // S4: L2 MSHR / island MaxAROut. AW covers NrCores + island DMA writes.
    parameter int unsigned NrArSlots      = 8,
    parameter int unsigned NrAwSlots      = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    AXI_BUS.Slave slave,
    output logic init_done_o,
    // CLASS1 testharness native ELF preload. Tie pl_req_i=0 in directed TBs.
    input  logic        pl_req_i,
    output logic        pl_gnt_o,
    input  logic [25:0] pl_na_i,
    input  logic [255:0] pl_data_i,
    input  logic [31:0] pl_be_i,
    output logic        pl_idle_o
);

`ifdef G6LC_HAVE_LITEDRAM
  localparam int unsigned NAT_W  = 256;
  localparam int unsigned NAT_AW = 26;
  // 8 × 64 B AR = 16 native words; keep spare so rdata pulses are not dropped.
  localparam int unsigned QN     = 32;
  localparam int unsigned QW     = 6;
  localparam int unsigned ARW    = (NrArSlots <= 1) ? 1 : $clog2(NrArSlots);
  localparam int unsigned NARW   = $clog2(NrArSlots + 1);
  localparam int unsigned AWW    = (NrAwSlots <= 1) ? 1 : $clog2(NrAwSlots);
  localparam int unsigned NAWW   = $clog2(NrAwSlots + 1);
  // pragma translate_off
  initial begin
    assert (NrArSlots >= 1 && NrArSlots <= 16)
      else $error("g6lc_ai_litedram_wrap: NrArSlots=%0d not in [1,16]", NrArSlots);
    assert (NrAwSlots >= 1 && NrAwSlots <= 16)
      else $error("g6lc_ai_litedram_wrap: NrAwSlots=%0d not in [1,16]", NrAwSlots);
  end
  // pragma translate_on

  logic core_init_done, core_init_error, user_clk, user_rst;
  logic wb_ack, wb_err;
  logic [31:0] wb_dat_r;
  logic n_cmd_valid, n_cmd_ready, n_cmd_we;
  logic [NAT_AW-1:0] n_cmd_addr;
  logic n_w_valid, n_w_ready;
  logic [NAT_W-1:0] n_w_data;
  logic [NAT_W/8-1:0] n_w_we;
  logic n_r_valid, n_r_ready;
  logic [NAT_W-1:0] n_r_data;

  wire inited = ForceInitDone | core_init_done;
  assign init_done_o = inited;

  function automatic logic [1:0] sl_of(input logic [63:0] a);
    return a[4:3];
  endfunction
  function automatic logic [25:0] na_of(input logic [63:0] a);
    return a[30:5];
  endfunction
  function automatic logic [2:0] take(input logic [1:0] sl, input logic [8:0] beats);
    logic [8:0] room;
    room = 9'd4 - 9'(sl);
    return 3'((beats < room) ? beats : room);
  endfunction
  function automatic logic [255:0] ins64(
      input logic [255:0] w, input logic [1:0] sl, input logic [63:0] d
  );
    logic [255:0] r;
    r = w;
    r[64*sl +: 64] = d;
    return r;
  endfunction
  function automatic logic [31:0] inswe(
      input logic [31:0] we, input logic [1:0] sl, input logic [7:0] strb
  );
    logic [31:0] r;
    r = we;
    r[8*sl +: 8] = strb;
    return r;
  endfunction

  // Write slots: packing register + 2-deep completed-word FIFO per slot.
  logic [NrAwSlots-1:0] wv, wfill, wb, werr;
  logic [AXI_ID_WIDTH-1:0] wid [NrAwSlots];
  logic [25:0] wna [NrAwSlots];
  logic [1:0]  wsl [NrAwSlots];
  logic [8:0]  wbt [NrAwSlots];
  logic [255:0] wwd [NrAwSlots];
  logic [31:0] wwe [NrAwSlots];
  logic [1:0]  wqn [NrAwSlots];
  logic        wqh [NrAwSlots], wqt [NrAwSlots];
  logic [255:0] wqd [NrAwSlots][2];
  logic [31:0]  wqe [NrAwSlots][2];
  logic [25:0]  wqa [NrAwSlots][2];
  logic [NAWW-1:0] naw;
  logic                w_has_free, w_pack_v, w_err_v, w_b_v, w_launch_v, wqn_any;
  logic [AWW-1:0]      w_alloc, w_pack_i, w_err_i, w_b_i, w_launch_i;

  // Native write engine (one cmd + wdata handshake)
  logic        nwb, nw_cd, nw_wd;
  logic [AWW-1:0] nw_from;
  logic [25:0] nwa;
  logic [255:0] nwd;
  logic [31:0] nwe;
  assign pl_idle_o = !nwb;
  assign pl_gnt_o  = inited && !nwb && pl_req_i;

  // Read slots (NrArSlots). Completion uses the slot stored in the data FIFO,
  // not an ID CAM — two same-ID bursts stay in-order via native cmd order.
  logic [NrArSlots-1:0] rv, rerr;
  logic [AXI_ID_WIDTH-1:0] rid [NrArSlots];
  logic [25:0] rna [NrArSlots];
  logic [1:0]  rsl [NrArSlots];
  logic [8:0]  rbi [NrArSlots];
  logic [4:0]  rinf [NrArSlots];
  logic [NARW-1:0] nar;

  logic                r_has_free, iss_v, rerr_v;
  logic [ARW-1:0]      r_alloc, iss_i, rerr_i;

  // Native-read meta FIFO (pushed at cmd, popped at rdata)
  logic [1:0]  ms[QN];
  logic [2:0]  mn[QN];
  logic [AXI_ID_WIDTH-1:0] mi[QN];
  logic        ml[QN];
  logic [ARW-1:0] msrc[QN];
  logic [QW-1:0]  mw, mr, mc;

  // Rdata FIFO
  logic [255:0] dd[QN];
  logic [1:0]   ds[QN];
  logic [2:0]   dn[QN];
  logic [AXI_ID_WIDTH-1:0] di[QN];
  logic         dl[QN];
  logic [ARW-1:0] dslot[QN];
  logic [QW-1:0]  dw, dr, dc;

  // AXI R emitter (legal native path)
  logic        ev;
  logic [255:0] ew;
  logic [1:0]  es;
  logic [2:0]  el;
  logic [AXI_ID_WIDTH-1:0] ei;
  logic [ARW-1:0] eslot;
  logic        e_last;

  // Illegal-burst R emitter (SLVERR, no native). Never overlaps ev.
  logic        re_v;
  logic [ARW-1:0] re_src;
  logic [AXI_ID_WIDTH-1:0] re_id;
  logic [8:0]  re_left;

  // INCR any AXI size 0–3 (core WT stores are often size 0/1/2). Single-beat
  // FIXED/WRAP (len=0) is the same as INCR len=0. Multi-beat WRAP/FIXED/
  // RESERVED and size>3 handshake then SLVERR — never stall aw_ready.
  // W packing uses w_strb, not size.
  wire aw_ok = (slave.aw_size <= 3'd3) &&
               ((slave.aw_burst == 2'b01) ||
                (slave.aw_len == 8'd0 &&
                 (slave.aw_burst == 2'b00 || slave.aw_burst == 2'b10)));
  wire ar_ok = (slave.ar_size <= 3'd3) &&
               ((slave.ar_burst == 2'b01) ||
                (slave.ar_len == 8'd0 &&
                 (slave.ar_burst == 2'b00 || slave.ar_burst == 2'b10)));
  always_comb begin
    r_has_free = 1'b0;
    r_alloc    = '0;
    iss_v      = 1'b0;
    iss_i      = '0;
    rerr_v     = 1'b0;
    rerr_i     = '0;
    for (int unsigned i = 0; i < NrArSlots; i++) begin
      if (!rv[i] && !r_has_free) begin
        r_has_free = 1'b1;
        r_alloc    = ARW'(i);
      end
      if (rv[i] && !rerr[i] && (rbi[i] != 0) && !iss_v) begin
        iss_v = 1'b1;
        iss_i = ARW'(i);
      end
      if (rv[i] && rerr[i] && (rbi[i] != 0) && !rerr_v) begin
        rerr_v = 1'b1;
        rerr_i = ARW'(i);
      end
    end
    w_has_free = 1'b0;
    w_alloc    = '0;
    w_pack_v   = 1'b0;
    w_pack_i   = '0;
    w_err_v    = 1'b0;
    w_err_i    = '0;
    w_b_v      = 1'b0;
    w_b_i      = '0;
    w_launch_v = 1'b0;
    w_launch_i = '0;
    wqn_any    = 1'b0;
    for (int unsigned i = 0; i < NrAwSlots; i++) begin
      if (!wv[i] && !w_has_free) begin
        w_has_free = 1'b1;
        w_alloc    = AWW'(i);
      end
      if (wv[i] && wfill[i] && ((wqn[i] != 2'd2) || !(slave.w_last || (wsl[i] == 2'd3)))
          && !w_pack_v) begin
        w_pack_v = 1'b1;
        w_pack_i = AWW'(i);
      end
      if (wv[i] && werr[i] && !wb[i] && !w_err_v) begin
        w_err_v = 1'b1;
        w_err_i = AWW'(i);
      end
      if (wv[i] && wb[i] && !w_b_v) begin
        w_b_v = 1'b1;
        w_b_i = AWW'(i);
      end
      if ((wqn[i] != 2'd0) && !w_launch_v) begin
        w_launch_v = 1'b1;
        w_launch_i = AWW'(i);
      end
      if (wqn[i] != 2'd0)
        wqn_any = 1'b1;
    end
  end

  assign slave.aw_ready = inited && w_has_free;
  assign slave.ar_ready = inited && r_has_free;
  assign slave.w_ready  = inited &&
                          ((slave.aw_valid && slave.aw_ready) || w_pack_v || w_err_v);

  assign slave.b_valid = w_b_v;
  assign slave.b_id    = wid[w_b_i];
  assign slave.b_resp  = werr[w_b_i] ? 2'b10 : 2'b00;
  assign slave.b_user  = '0;

  assign slave.r_valid = ev || re_v;
  assign slave.r_id    = re_v ? re_id : ei;
  assign slave.r_data  = re_v ? '0 : ew[64*es +: 64];
  assign slave.r_last  = re_v ? (re_left == 9'd1) : (e_last && (el == 3'd1));
  assign slave.r_resp  = re_v ? 2'b10 : 2'b00;
  assign slave.r_user  = '0;

  wire wr_pend = nwb || wqn_any;
  // LiteDRAM crossbar does not backpressure rdata (AXI frontend ties ready=1).
  // A delayed pulse with ready=0 is lost. Issue only while FIFO + inflight
  // still fit, and always accept rdata.
  wire [QW:0] r_occ = {1'b0, dc} + {1'b0, mc};
  wire fifo_room = r_occ < (QW+1)'(QN - 2);
  wire iss = iss_v && fifo_room && !wr_pend;

  assign n_cmd_valid = nwb ? !nw_cd : iss;
  assign n_cmd_we    = nwb;
  assign n_cmd_addr  = nwb ? nwa : rna[iss_i];
  assign n_w_valid   = nwb && !nw_wd;
  assign n_w_data    = nwd;
  assign n_w_we      = nwe;
  assign n_r_ready   = 1'b1;

  wire r_start = !ev && !re_v && (dc != 0);
  wire r_chain = ev && slave.r_ready && (el == 3'd1) && !e_last && (dc != 0);
  wire r_pop   = r_start || r_chain;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wv<='0; wfill<='0; wb<='0; werr<='0; naw<='0;
      for (int unsigned wi = 0; wi < NrAwSlots; wi++) begin
        wid[wi]<='0; wna[wi]<='0; wsl[wi]<='0; wbt[wi]<='0;
        wwd[wi]<='0; wwe[wi]<='0; wqn[wi]<='0; wqh[wi]<=0; wqt[wi]<=0;
        wqd[wi][0]<='0; wqd[wi][1]<='0;
        wqe[wi][0]<='0; wqe[wi][1]<='0;
        wqa[wi][0]<='0; wqa[wi][1]<='0;
      end
      nwb<=0; nw_cd<=0; nw_wd<=0; nw_from<='0; nwa<='0; nwd<='0; nwe<='0;
      rv<='0; rerr<='0; nar<='0;
      for (int unsigned ri = 0; ri < NrArSlots; ri++) begin
        rid[ri]<='0; rna[ri]<='0; rsl[ri]<='0; rbi[ri]<='0; rinf[ri]<='0;
      end
      mw<='0; mr<='0; mc<='0; dw<='0; dr<='0; dc<='0;
      ev<=0; ew<='0; es<='0; el<='0; ei<='0; eslot<='0; e_last<=0;
      re_v<=0; re_src<='0; re_id<='0; re_left<='0;
    end else begin
      automatic logic [NrAwSlots-1:0] w_enq, w_deq;
      automatic logic naw_inc, naw_dec;
      automatic logic nar_inc, nar_dec;
      automatic logic [2:0] ntake;
      automatic logic [1:0] sl_aw;
      automatic logic [255:0] pwd;
      automatic logic [31:0] pwe;
      automatic logic fin;
      automatic logic [AWW-1:0] ws;
      w_enq    = '0;
      w_deq    = '0;
      naw_inc  = 1'b0;
      naw_dec  = 1'b0;
      nar_inc  = 1'b0;
      nar_dec  = 1'b0;

      // AW
      if (slave.aw_valid && slave.aw_ready) begin
        ws = w_alloc;
        wv[ws]   <= 1'b1;
        wb[ws]   <= 1'b0;
        wid[ws]  <= slave.aw_id;
        werr[ws] <= !aw_ok;
        if (aw_ok) begin
          wfill[ws] <= 1'b1;
          wna[ws]   <= na_of(slave.aw_addr);
          wsl[ws]   <= sl_of(slave.aw_addr);
          wbt[ws]   <= 9'(unsigned'(slave.aw_len)+1);
          wwd[ws]   <= '0;
          wwe[ws]   <= '0;
        end else begin
          wfill[ws] <= 1'b0;
          wbt[ws]   <= '0;
          wwd[ws]   <= '0;
          wwe[ws]   <= '0;
          wsl[ws]   <= '0;
        end
        naw_inc = 1'b1;
      end

      // W pack: same-cycle AW+W uses the slot just allocated (w_alloc).
      // Illegal AW drains W until w_last then SLVERR B; no native enqueue.
      if (slave.w_valid && slave.w_ready) begin
        if (slave.aw_valid && slave.aw_ready && !aw_ok) begin
          if (slave.w_last)
            wb[w_alloc] <= 1'b1;
        end else if (w_err_v) begin
          if (slave.w_last)
            wb[w_err_i] <= 1'b1;
        end else if (slave.aw_valid && slave.aw_ready && w_has_free) begin
          ws    = w_alloc;
          sl_aw = sl_of(slave.aw_addr);
          pwd   = ins64('0, sl_aw, slave.w_data);
          pwe   = inswe('0, sl_aw, slave.w_strb);
          fin   = slave.w_last || (sl_aw == 2'd3);
          wbt[ws] <= 9'(unsigned'(slave.aw_len));
          if (fin) begin
            wqd[ws][wqt[ws]] <= pwd;
            wqe[ws][wqt[ws]] <= pwe;
            wqa[ws][wqt[ws]] <= na_of(slave.aw_addr);
            wqt[ws]   <= ~wqt[ws];
            wna[ws]   <= na_of(slave.aw_addr) + 26'd1;
            wwd[ws]   <= '0;
            wwe[ws]   <= '0;
            wsl[ws]   <= 2'd0;
            wfill[ws] <= !slave.w_last;
            w_enq[ws] = 1'b1;
          end else begin
            wwd[ws] <= pwd;
            wwe[ws] <= pwe;
            wsl[ws] <= sl_aw + 2'd1;
          end
        end else if (w_pack_v) begin
          ws  = w_pack_i;
          pwd = ins64(wwd[ws], wsl[ws], slave.w_data);
          pwe = inswe(wwe[ws], wsl[ws], slave.w_strb);
          fin = slave.w_last || (wsl[ws] == 2'd3);
          wbt[ws] <= wbt[ws] - 9'd1;
          if (fin) begin
            wqd[ws][wqt[ws]] <= pwd;
            wqe[ws][wqt[ws]] <= pwe;
            wqa[ws][wqt[ws]] <= wna[ws];
            wqt[ws]   <= ~wqt[ws];
            wna[ws]   <= wna[ws] + 26'd1;
            wwd[ws]   <= '0;
            wwe[ws]   <= '0;
            wsl[ws]   <= 2'd0;
            wfill[ws] <= !slave.w_last;
            w_enq[ws] = 1'b1;
          end else begin
            wwd[ws] <= pwd;
            wwe[ws] <= pwe;
            wsl[ws] <= wsl[ws] + 2'd1;
          end
        end
      end

      // Launch native write from completed-word FIFO. Preload (cluster held)
      // steals the engine; pl_req_i=0 is the AXI path (directed TBs).
      if (!nwb) begin
        if (pl_req_i) begin
          nwb<=1; nw_cd<=0; nw_wd<=0; nw_from<='0;
          nwa<=pl_na_i; nwd<=pl_data_i; nwe<=pl_be_i;
        end else if (w_launch_v) begin
          ws = w_launch_i;
          nwb<=1; nw_cd<=0; nw_wd<=0; nw_from<=ws;
          nwa<=wqa[ws][wqh[ws]]; nwd<=wqd[ws][wqh[ws]]; nwe<=wqe[ws][wqh[ws]];
          wqh[ws] <= ~wqh[ws];
          w_deq[ws] = 1'b1;
        end
      end else begin
        if (n_cmd_valid && n_cmd_ready) nw_cd<=1;
        if (n_w_valid && n_w_ready) nw_wd<=1;
        if ((nw_cd || (n_cmd_valid && n_cmd_ready))
            && (nw_wd || (n_w_valid && n_w_ready))) begin
          nwb<=0;
          if (!wfill[nw_from] && (wbt[nw_from] == 0) && (wqn[nw_from] == 2'd0)
              && !w_enq[nw_from])
            wb[nw_from] <= 1'b1;
        end
      end

      if (slave.b_valid && slave.b_ready && w_b_v) begin
        wv[w_b_i]   <= 1'b0;
        wb[w_b_i]   <= 1'b0;
        werr[w_b_i] <= 1'b0;
        naw_dec = 1'b1;
      end

      unique case ({naw_inc, naw_dec})
        2'b10: naw <= naw + NAWW'(1);
        2'b01: naw <= naw - NAWW'(1);
        default: ;
      endcase
      for (int unsigned s = 0; s < NrAwSlots; s++) begin
        unique case ({w_enq[s], w_deq[s]})
          2'b10: wqn[s] <= wqn[s] + 2'd1;
          2'b01: wqn[s] <= wqn[s] - 2'd1;
          default: ;
        endcase
      end

      // AR
      if (slave.ar_valid && slave.ar_ready) begin
        rv[r_alloc]   <= 1'b1;
        rid[r_alloc]  <= slave.ar_id;
        rerr[r_alloc] <= !ar_ok;
        rbi[r_alloc]  <= 9'(unsigned'(slave.ar_len)+1);
        rinf[r_alloc] <= '0;
        if (ar_ok) begin
          rna[r_alloc] <= na_of(slave.ar_addr);
          rsl[r_alloc] <= sl_of(slave.ar_addr);
        end else begin
          rna[r_alloc] <= '0;
          rsl[r_alloc] <= '0;
        end
        nar_inc = 1'b1;
      end

      // Native read cmd + meta
      if (!nwb && n_cmd_valid && n_cmd_ready && iss) begin
        ntake = take(rsl[iss_i], rbi[iss_i]);
        ms[mw[4:0]]   <= rsl[iss_i];
        mn[mw[4:0]]   <= ntake;
        mi[mw[4:0]]   <= rid[iss_i];
        ml[mw[4:0]]   <= (rbi[iss_i] <= 9'(ntake));
        msrc[mw[4:0]] <= iss_i;
        mw <= mw + QW'(1);
        rbi[iss_i]  <= rbi[iss_i] - 9'(ntake);
        rna[iss_i]  <= rna[iss_i] + 26'd1;
        rsl[iss_i]  <= 2'd0;
        rinf[iss_i] <= rinf[iss_i] + 5'd1;
      end

      // Rdata → data FIFO, pop meta
      if (n_r_valid && n_r_ready && (mc != 0)) begin
        dd[dw[4:0]]    <= n_r_data;
        ds[dw[4:0]]    <= ms[mr[4:0]];
        dn[dw[4:0]]    <= mn[mr[4:0]];
        di[dw[4:0]]    <= mi[mr[4:0]];
        dl[dw[4:0]]    <= ml[mr[4:0]];
        dslot[dw[4:0]] <= msrc[mr[4:0]];
        dw <= dw + QW'(1);
        mr <= mr + QW'(1);
        if (rinf[msrc[mr[4:0]]] != 0)
          rinf[msrc[mr[4:0]]] <= rinf[msrc[mr[4:0]]] - 5'd1;
      end

      // Illegal AR: emit SLVERR beats with no native cmd. Idle when ev/dc live.
      if (!ev && !re_v && (dc == 0)) begin
        if (rerr_v) begin
          re_v<=1; re_id<=rid[rerr_i]; re_left<=rbi[rerr_i]; re_src<=rerr_i;
        end
      end else if (re_v && slave.r_ready) begin
        if (re_left == 9'd1) begin
          re_v<=0;
          rv[re_src]<=0; rerr[re_src]<=0; rbi[re_src]<=0;
          nar_dec = 1'b1;
        end else
          re_left <= re_left - 9'd1;
      end

      // Start / continue / chain AXI R (chain avoids a 1-cycle gap every 32 B)
      if (r_start) begin
        ev<=1; ew<=dd[dr[4:0]]; es<=ds[dr[4:0]]; el<=dn[dr[4:0]];
        ei<=di[dr[4:0]]; eslot<=dslot[dr[4:0]]; e_last<=dl[dr[4:0]];
        dr<=dr+QW'(1);
      end else if (ev && slave.r_ready) begin
        if (el == 3'd1) begin
          if (e_last) begin
            ev<=0;
            rv[eslot]<=0; rerr[eslot]<=0;
            nar_dec = 1'b1;
          end else if (dc != 0) begin
            ew<=dd[dr[4:0]]; es<=ds[dr[4:0]]; el<=dn[dr[4:0]];
            ei<=di[dr[4:0]]; eslot<=dslot[dr[4:0]]; e_last<=dl[dr[4:0]];
            dr<=dr+QW'(1);
          end else
            ev<=0;
        end else begin
          es<=es+2'd1; el<=el-3'd1;
        end
      end

      unique case ({nar_inc, nar_dec})
        2'b10: nar <= nar + NARW'(1);
        2'b01: nar <= nar - NARW'(1);
        default: ;
      endcase
      unique case ({( !nwb && n_cmd_valid && n_cmd_ready && iss ),
                    ( n_r_valid && n_r_ready && (mc != 0) )})
        2'b10: mc <= mc + QW'(1);
        2'b01: mc <= mc - QW'(1);
        default: ;
      endcase
      unique case ({( n_r_valid && n_r_ready && (mc != 0) ), r_pop})
        2'b10: dc <= dc + QW'(1);
        2'b01: dc <= dc - QW'(1);
        default: ;
      endcase
    end
  end

  // verilator lint_off UNUSEDSIGNAL
  logic _unused;
  assign _unused = ^{user_clk, user_rst, core_init_error, slave.aw_lock, slave.ar_lock,
                     slave.aw_cache, slave.ar_cache, slave.aw_prot, slave.ar_prot,
                     slave.aw_qos, slave.ar_qos, slave.aw_region, slave.ar_region,
                     slave.aw_atop, slave.aw_user, slave.ar_user, slave.w_user,
                     AXI_USER_WIDTH'(0), nar};
  // verilator lint_on UNUSEDSIGNAL

  litedram_core i_litedram_core (
      .clk                           ( clk_i ),
      .init_done                     ( core_init_done ),
      .init_error                    ( core_init_error ),
      .sim_trace                     ( 1'b0 ),
      .user_clk                      ( user_clk ),
      .user_rst                      ( user_rst ),
      .user_port_native_0_cmd_addr   ( n_cmd_addr ),
      .user_port_native_0_cmd_ready  ( n_cmd_ready ),
      .user_port_native_0_cmd_valid  ( n_cmd_valid ),
      .user_port_native_0_cmd_we     ( n_cmd_we ),
      .user_port_native_0_rdata_data ( n_r_data ),
      .user_port_native_0_rdata_ready( n_r_ready ),
      .user_port_native_0_rdata_valid( n_r_valid ),
      .user_port_native_0_wdata_data ( n_w_data ),
      .user_port_native_0_wdata_ready( n_w_ready ),
      .user_port_native_0_wdata_valid( n_w_valid ),
      .user_port_native_0_wdata_we   ( n_w_we ),
      .wb_ctrl_ack                   ( wb_ack ),
      .wb_ctrl_adr                   ( 30'b0 ),
      .wb_ctrl_bte                   ( 2'b0 ),
      .wb_ctrl_cti                   ( 3'b0 ),
      .wb_ctrl_cyc                   ( 1'b0 ),
      .wb_ctrl_dat_r                 ( wb_dat_r ),
      .wb_ctrl_dat_w                 ( 32'b0 ),
      .wb_ctrl_err                   ( wb_err ),
      .wb_ctrl_sel                   ( 4'b0 ),
      .wb_ctrl_stb                   ( 1'b0 ),
      .wb_ctrl_we                    ( 1'b0 )
  );
`else
  // pragma translate_off
  initial
    $error("g6lc_ai_litedram_wrap: define G6LC_HAVE_LITEDRAM after litedram_gen --sim");
  // pragma translate_on
  assign init_done_o    = 1'b0;
  assign pl_gnt_o       = 1'b0;
  assign pl_idle_o      = 1'b1;
  assign slave.aw_ready = 1'b0;
  assign slave.w_ready  = 1'b0;
  assign slave.ar_ready = 1'b0;
  assign slave.b_valid  = 1'b0;
  assign slave.r_valid  = 1'b0;
  assign slave.b_id     = '0;
  assign slave.b_resp   = '0;
  assign slave.b_user   = '0;
  assign slave.r_id     = '0;
  assign slave.r_data   = '0;
  assign slave.r_resp   = '0;
  assign slave.r_last   = 1'b0;
  assign slave.r_user   = '0;
`endif

endmodule
