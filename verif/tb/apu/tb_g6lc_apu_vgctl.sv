// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Unit test of g6lc_apu_vgctl (§6b control-queue processor) with the
// real g6lc_apu_objtab.  Directed cases: capset info/capset payloads,
// ctx create/destroy, blob create/map/unref, unknown type, a
// truncated chain, blob_id != 0, context_init != 4, and the FENCE
// flag echo/pulse.  The session-level tape covers the ring paths;
// this TB exercises the request/response edge cases directly.

module tb_g6lc_apu_vgctl;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_vgpages_pkg::*;

  localparam int unsigned GMW = 32'h40000;
  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  logic            ch_v = 0, ch_r;
  logic [3:0]      ch_n = '0;
  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] ch_d;
  logic            m_req, m_we;
  logic [63:0]     m_addr;
  logic [63:0]     m_wdata;
  logic [7:0]      m_wstrb;
  logic            m_rv = 0, m_fault;
  logic [63:0]     m_rdata = '0;
  logic            ot_v, ot_r, ot_cv, ot_cr;
  apu_objtab_req_t ot_req;
  apu_objtab_cpl_t ot_cpl;
  logic            xs_v, xs_done = 0, xs_fault = 0;
  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_d;
  logic [3:0]      xs_n;
  logic [31:0]     xs_off, xs_bytes;
  logic [7:0]      xs_ctx;
  logic            busy, dn;
  logic [31:0]     used_len;
  logic            f_dn;
  logic [63:0]     f_id;
  logic [7:0]      f_ring;

  g6lc_apu_vgctl #(.Enable(1'b1)) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .chain_valid_i(ch_v), .chain_ready_o(ch_r),
    .chain_n_i(ch_n), .chain_desc_i(ch_d),
    .mem_req_o(m_req), .mem_we_o(m_we), .mem_addr_o(m_addr),
    .mem_wdata_o(m_wdata), .mem_wstrb_o(m_wstrb),
    .mem_ready_i(1'b1), .mem_rvalid_i(m_rv), .mem_rdata_i(m_rdata),
    .mem_err_i(1'b0), .mem_fault_o(m_fault),
    .ot_req_valid_o(ot_v), .ot_req_ready_i(ot_r), .ot_req_o(ot_req),
    .ot_cpl_valid_i(ot_cv), .ot_cpl_ready_o(ot_cr), .ot_cpl_i(ot_cpl),
    .pg_req_valid_o(pg_v), .pg_req_ready_i(pg_r), .pg_req_o(pg_req),
    .pg_cpl_valid_i(pg_cv), .pg_cpl_ready_o(pg_cr), .pg_cpl_i(pg_cpl),
    .xs_valid_o(xs_v), .xs_ready_i(1'b0),
    .xs_desc_o(xs_d), .xs_ndesc_o(xs_n), .xs_off_o(xs_off),
    .xs_bytes_o(xs_bytes), .xs_ctx_o(xs_ctx),
    .xs_done_i(xs_done), .xs_fault_i(xs_fault),
    .busy_o(busy), .done_o(dn), .used_len_o(used_len),
    .fence_done_o(f_dn), .fence_id_o(f_id), .fence_ring_o(f_ring));

  g6lc_apu_objtab #(.Enable(1'b1)) i_tab (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(ot_v), .req_ready_o(ot_r), .req_i(ot_req),
    .cpl_valid_o(ot_cv), .cpl_ready_i(ot_cr), .cpl_o(ot_cpl),
    .live_o());

  // §7b: the page allocator lives outside vgctl now
  logic            pg_v, pg_r, pg_cv, pg_cr;
  apu_vgpages_req_t pg_req;
  apu_vgpages_cpl_t pg_cpl;
  g6lc_apu_vgpages #(.Enable(1'b1), .Pages(64)) i_pages (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(pg_v), .req_ready_o(pg_r), .req_i(pg_req),
    .cpl_valid_o(pg_cv), .cpl_ready_i(pg_cr), .cpl_o(pg_cpl));

  logic [31:0] gmem [GMW];
  // handshake guest-memory model: ready=1, one rvalid next cycle;
  // returns the aligned 64-bit beat containing the request address
  // (vgctl picks the half by addr[2]); writes apply wstrb bytes.
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      m_rv <= 1'b0; m_rdata <= '0;
    end else begin
      m_rv <= 1'b0;
      if (m_req && !m_we)
        begin m_rv <= 1'b1;
          m_rdata <= {gmem[((m_addr[31:0] >> 2) & ~32'h1) + 1],
                      gmem[(m_addr[31:0] >> 2) & ~32'h1]}; end
      else if (m_req && m_we) begin
        m_rv <= 1'b1;
        // wstrb/wdata are beat-positioned; byte b lands in word
        // (m_addr & ~7)>>2 + b[2] at byte lane b[1:0]
        for (int b = 0; b < 8; b++)
          if (m_wstrb[b])
            gmem[32'((m_addr[31:0] >> 3) * 2) + (b >= 4 ? 1 : 0)]
                [b[1:0] * 8 +: 8] <= m_wdata[b * 8 +: 8];
      end
    end
  end

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  task automatic check(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL %s (t=%0d)", msg, cycles);
      if (errors > 40) $fatal(1, "too many errors");
    end
  endtask

  localparam logic [63:0] GREQ  = 64'h4000;
  localparam logic [63:0] GRESP = 64'h10000;

  // write request words into guest memory, submit {req,resp} chain,
  // wait done, return with response checked by the caller
  task automatic run_chain(input int unsigned nreq,
                           input int unsigned nresp_bytes);
    ch_d[0] = '{addr: GREQ, len: 32'(nreq * 4), write: 1'b0,
                default: '0};
    ch_d[1] = '{addr: GRESP, len: 32'(nresp_bytes), write: 1'b1,
                default: '0};
    ch_d[2] = '0; ch_d[3] = '0;
    ch_n = 4'd2;
    // wait for the previous chain to finish completely (done is a
    // pulse; a FENCE response spends one extra cycle in StFence)
    begin
      int unsigned t = 0;
      while (!ch_r && t < 2_000_000) begin @(posedge clk); t++; end
      check(ch_r, "vgctl not idle before chain");
    end
    // accept = chain_ready_o drops (FSM latched the chain and left
    // StIdle); hold valid until then, then wait for the done pulse
    ch_v = 1;
    begin
      int unsigned t = 0;
      @(posedge clk);
      while (ch_r && t < 1000) begin @(posedge clk); t++; end
      check(!ch_r, "chain not accepted");
    end
    ch_v = 0;
    begin
      int unsigned t = 0;
      // done_o is a one-cycle pulse; sample mid-cycle at negedge
      while (!dn && t < 2_000_000) begin @(negedge clk); t++; end
      check(dn, "done timeout");
      @(posedge clk);
    end
    cases++;
  endtask

  task automatic wr(input int unsigned i, input logic [31:0] w);
    gmem[32'(GREQ >> 2) + i] = w;
  endtask
  function automatic logic [31:0] resp(input int unsigned i);
    return gmem[32'(GRESP >> 2) + i];
  endfunction

  // fence-pulse observability: NBA-only writes (no mixed blocking/
  // nonblocking on the same variable in the TB)
  int unsigned f_count = 0;
  logic [63:0] f_seen_id;
  logic [7:0]  f_seen_ring;
  always @(posedge clk or negedge rst_ni)
    if (!rst_ni) begin
      f_count <= 0; f_seen_id <= '0; f_seen_ring <= '0;
    end else if (f_dn) begin
      f_count <= f_count + 1;
      f_seen_id <= f_id; f_seen_ring <= f_ring;
    end

  // response header builder check: type at resp[0]
  task automatic exp_resp(input logic [31:0] ty);
    check(resp(0) == ty,
          $sformatf("resp type got=%08x exp=%08x", resp(0), ty));
  endtask

  initial begin
    for (int i = 0; i < GMW; i++) gmem[i] = '0;
    repeat (8) @(posedge clk);
    rst_ni = 1;
    repeat (4) @(posedge clk);

    // ---- A1: GET_CAPSET_INFO idx 0 -------------------------------------
    // hdr 6w {type,flags,fence_lo,fence_hi,ctx,ring} + body {idx,pad}
    wr(0, 32'h0108); wr(1, 0); wr(2, 0); wr(3, 0); wr(4, 0); wr(5, 0);
    wr(6, 0); wr(7, 0);
    run_chain(8, 40);
    exp_resp(APU_VG_RESP_CAPSET_INFO);
    check(resp(6) == 4,  "capset id 4");
    check(resp(7) == 1,  "capset max_version 1");
    check(resp(8) == 160, "capset size 160");
    check(used_len == 8 * 4 + 40, "capset-info used_len");

    // ---- A2: GET_CAPSET id 4 ---------------------------------------------
    wr(0, 32'h0109); wr(6, 4); wr(7, 0);
    run_chain(8, 24 + 160);
    exp_resp(APU_VG_RESP_CAPSET);
    check(resp(6) == APU_VN_CAPSET[0], "capset[0] wire fmt");
    check(resp(6 + 39) == APU_VN_CAPSET[39], "capset[39]");
    check(used_len == 32 + 24 + 160, "capset used_len");

    // ---- A3: CTX_CREATE ctx=4 context_init=4 ------------------------------
    wr(0, 32'h0200); wr(4, 4);
    wr(6, 12);           // nlen
    wr(7, 4);            // context_init = 4 -> Venus
    for (int i = 0; i < 16; i++) wr(8 + i, 0);
    run_chain(24, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- A4: CREATE_BLOB valid (rid 10, 8 KiB) ----------------------------
    wr(0, 32'h010C); wr(4, 4);
    wr(6, 10);           // resource_id
    wr(7, APU_VG_BLOB_HOST3D);
    wr(8, APU_VG_BLOB_MAPPABLE);
    wr(9, 0);            // pad
    wr(10, 0);           // blob_id 0
    wr(11, 0);
    wr(12, 32'h2000); wr(13, 0);   // size 8 KiB
    run_chain(14, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- A5: MAP_BLOB rid 10 -> MAP_INFO {WC,0} ----------------------------
    wr(0, 32'h0208); wr(4, 4);
    wr(6, 10); wr(7, 0); wr(8, 0); wr(9, 0);
    run_chain(10, 32);
    exp_resp(APU_VG_RESP_MAP_INFO);
    check(resp(6) == 3, "map WC");
    check(resp(7) == 0, "map pad");

    // ---- A6: UNMAP_BLOB --------------------------------------------------
    wr(0, 32'h0209); wr(6, 10); wr(7, 0); wr(8, 0); wr(9, 0);
    run_chain(10, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- A7: UNREF rid 10 ---------------------------------------------------
    wr(0, 32'h0102); wr(6, 10); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- C1: unknown type 0x0999 -> ERR_UNSPEC -------------------------------
    wr(0, 32'h0999); wr(6, 0); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_ERR_UNSPEC);

    // ---- C2: truncated chain: header alone (6w) declares CTX_CREATE ---------
    wr(0, 32'h0200);
    run_chain(6, 24);
    exp_resp(APU_VG_ERR_PARAM);
    check(used_len == 24 + 24, "truncated used_len");

    // ---- C3: CREATE_BLOB blob_id != 0, unknown memory -> ERR_RID -----
    // 5a-ii: blob_id != 0 resolves a VkDeviceMemory object of that id;
    // no such object here -> the resource-refusal path (ERR_RID).
    wr(0, 32'h010C); wr(4, 4);
    wr(6, 20); wr(7, APU_VG_BLOB_HOST3D);
    wr(8, APU_VG_BLOB_MAPPABLE); wr(9, 0);
    wr(10, 0); wr(11, 1);          // blob_id = 1<<32 (unknown memory)
    wr(12, 32'h1000); wr(13, 0);
    run_chain(14, 24);
    exp_resp(APU_VG_ERR_RID);

    // ---- C4: CTX_CREATE context_init = 5 -> ERR_PARAM ------------------------
    wr(0, 32'h0200); wr(4, 7);
    wr(6, 4); wr(7, 5);
    for (int i = 0; i < 16; i++) wr(8 + i, 0);
    run_chain(24, 24);
    exp_resp(APU_VG_ERR_PARAM);

    // ---- C5: MAP_BLOB unknown rid -> ERR_RESOURCE ----------------------------
    wr(0, 32'h0208); wr(4, 4);
    wr(6, 77); wr(7, 0); wr(8, 0); wr(9, 0);
    run_chain(10, 24);
    exp_resp(APU_VG_ERR_RID);

    // ---- C6: UNREF unknown rid -> ERR_RESOURCE --------------------------------
    wr(0, 32'h0102); wr(6, 77); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_ERR_RID);

    // ---- F1: FENCE echo on a NODATA response -----------------------------------
    begin int unsigned fc0 = f_count;
    wr(0, 32'h0999);
    wr(1, APU_VG_FLAG_FENCE);
    wr(2, 32'h1234); wr(3, 32'h5678);
    wr(4, 0); wr(5, 2);
    wr(6, 0); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_ERR_UNSPEC);
    check((resp(1) & APU_VG_FLAG_FENCE) != 32'h0,
          "fence flag echoed");
    check(resp(2) == 32'h1234 && resp(3) == 32'h5678,
          "fence id echoed");
    check(resp(5) == 2, "ring_idx echoed");
    // the fence pulse fires in StFence, one cycle after done_o
    begin
      int unsigned t = 0;
      while (f_count == fc0 && t < 100) begin @(posedge clk); t++; end
      check(f_count == fc0 + 1 &&
            f_seen_id == 64'h00005678_00001234 && f_seen_ring == 2,
            "fence pulse");
    end
    end

    // ---- CTX_DESTROY ctx 4 (teardown) -----------------------------------------
    wr(0, 32'h0201); wr(1, 0); wr(2, 0); wr(3, 0); wr(4, 4); wr(5, 0);
    wr(6, 0); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_RESP_NODATA);

    if (errors == 0)
      $display("PASS tb_g6lc_apu_vgctl cases=%0d checks=%0d cycles=%0d",
               cases, checks, cycles);
    else
      $display("FAIL tb_g6lc_apu_vgctl cases=%0d checks=%0d errors=%0d",
               cases, checks, errors);
    $finish;
  end
endmodule
