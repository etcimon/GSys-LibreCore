// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-010C AXI4-to-AXI-Lite bridge for the native Storamic control window.
// The SoC crossbar routes [Base, Base+1MiB) here; offsets 0x0000..0x0FFF are
// the g6lc_storamic_regs AXI-Lite registers (word accesses only; with
// CtrlPageEn=0 — the ST-037C IO-only role — this page answers DECERR like the
// reserved pages and drives no AXI-Lite traffic) and
// 0x1000..0xF_FFFF are reserved for future per-stick virtio-blk MMIO
// apertures, which answer DECERR with no AXI-Lite traffic. Legal shapes are
// single-beat (len==0) transfers of size<=2 with atop==0; anything else gets
// SLVERR after draining the W beats (writes) or len+1 R beats (reads). IDs
// echo, user fields are zero, responses are held stable under backpressure,
// and exclusive accesses never return EXOKAY (atop!=0 is already illegal).
// One write and one read may be outstanding independently. DataWidth must
// be 64.
module g6lc_storamic_ctrl_bridge #(
  parameter int unsigned AddrWidth = 64,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned IdWidth = 4,
  parameter int unsigned UserWidth = 1,
  parameter logic [63:0] Base = 64'h5000_0000,
  // ST-037C: when 0 (IO role without the primary-memory role), page 0 answers
  // DECERR exactly like the reserved pages and ctrl_req_o stays idle.
  parameter bit CtrlPageEn = 1'b1,
  parameter type axi_req_t = logic,
  parameter type axi_resp_t = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input axi_req_t axi_req_i,
  output axi_resp_t axi_resp_o,
  // Page 0 (0x0000-0x0FFF): Storamic control registers.
  output g6lc_storamic_pkg::axil_req_t ctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t ctrl_resp_i,
  // Page 1 (0x1000-0x1FFF): the first virtio-blk MMIO transport (ST-037B).
  output g6lc_storamic_pkg::axil_req_t vctrl_req_o,
  input g6lc_storamic_pkg::axil_resp_t vctrl_resp_i
);

  if (DataWidth != 64) begin : gen_datawidth_guard
    // pragma translate_off
    initial $fatal(1, "STORAMIC_CTRL_BRIDGE_DATAWIDTH");
    // pragma translate_on
  end else begin : gen_impl

  // Internal AXI-Lite master, demultiplexed by the page latched at AW/AR.
  g6lc_storamic_pkg::axil_req_t lreq;
  g6lc_storamic_pkg::axil_resp_t lresp;

  typedef enum logic [1:0] {WIdle, WBeat, WDrain, WResp} wstate_t;
  typedef enum logic [1:0] {RIdle, RLite, RResp} rstate_t;
  localparam logic [1:0] SlvErr = 2'b10, DecErr = 2'b11;

  // ---- write channel ----
  wstate_t w_q, w_d;
  logic [IdWidth-1:0] w_id_q, w_id_d;
  logic [11:0] w_off_q, w_off_d;
  logic w_page_q, w_page_d;       // 0: control page, 1: virtio page
  logic [1:0] w_code_q, w_code_d;
  logic w_lite_q, w_lite_d;       // this txn goes to the AXI-Lite side
  logic w_axi_w_q, w_axi_w_d;     // master's W beat captured
  logic [31:0] w_wdata_q, w_wdata_d;
  logic [3:0] w_wstrb_q, w_wstrb_d;
  logic lite_aw_q, lite_aw_d;     // AXI-Lite AW accepted
  logic lite_w_q, lite_w_d;       // AXI-Lite W accepted

  logic [63:0] aw_addr, aw_off;
  assign aw_addr = axi_req_i.aw.addr;
  assign aw_off = aw_addr - Base;
  logic aw_shape, aw_ctrl;
  assign aw_shape = axi_req_i.aw.len == 8'h0 && axi_req_i.aw.size <= 3'd2 &&
                    axi_req_i.aw.atop == '0;
  assign aw_ctrl = aw_addr >= Base && aw_off < 64'h2000;

  // ---- read channel ----
  rstate_t r_q, r_d;
  logic [IdWidth-1:0] r_id_q, r_id_d;
  logic [7:0] r_len_q, r_len_d;   // error beats remaining
  logic [11:0] r_off_q, r_off_d;
  logic r_page_q, r_page_d;
  logic [1:0] r_code_q, r_code_d;
  logic r_lite_q, r_lite_d;
  logic [31:0] r_data_q, r_data_d;
  logic lite_ar_q, lite_ar_d;

  logic [63:0] ar_addr, ar_off;
  assign ar_addr = axi_req_i.ar.addr;
  assign ar_off = ar_addr - Base;
  logic ar_shape, ar_ctrl;
  assign ar_shape = axi_req_i.ar.len == 8'h0 && axi_req_i.ar.size <= 3'd2;
  assign ar_ctrl = ar_addr >= Base && ar_off < 64'h2000;

  // Assembled channel outputs: each struct member is driven by exactly one
  // combinational assignment below.
  logic aw_ready_c, w_ready_c, b_valid_c;
  logic [IdWidth-1:0] b_id_c;
  logic [1:0] b_resp_c;
  logic ar_ready_c, r_valid_c, r_last_c;
  logic [IdWidth-1:0] r_id_c;
  logic [DataWidth-1:0] r_data_c;
  logic [1:0] r_resp_c;
  logic l_aw_valid_c, l_w_valid_c, l_b_ready_c;
  logic l_ar_valid_c, l_r_ready_c;

  always_comb begin : p_write
    w_d = w_q; w_id_d = w_id_q; w_off_d = w_off_q; w_code_d = w_code_q;
    w_page_d = w_page_q;
    w_lite_d = w_lite_q; w_axi_w_d = w_axi_w_q;
    w_wdata_d = w_wdata_q; w_wstrb_d = w_wstrb_q;
    lite_aw_d = lite_aw_q; lite_w_d = lite_w_q;
    aw_ready_c = 1'b0; w_ready_c = 1'b0;
    b_valid_c = 1'b0; b_id_c = w_id_q; b_resp_c = w_code_q;
    l_aw_valid_c = 1'b0; l_w_valid_c = 1'b0; l_b_ready_c = 1'b0;
    lreq.aw.addr = '0; lreq.aw.prot = '0;
    lreq.w.data = '0; lreq.w.strb = '0;
    unique case (w_q)
      WIdle: begin
        aw_ready_c = 1'b1;
        if (axi_req_i.aw_valid) begin
          w_id_d = axi_req_i.aw.id;
          w_off_d = aw_off[11:0];
          w_page_d = aw_off[12];
          w_lite_d = aw_shape && aw_ctrl && (CtrlPageEn || aw_off[12]);
          if (aw_addr < Base || aw_off >= 64'h10_0000) w_code_d = DecErr;
          else if (aw_off >= 64'h2000) w_code_d = DecErr;
          else if (!CtrlPageEn && aw_off < 64'h1000) w_code_d = DecErr;
          else if (!aw_shape) w_code_d = SlvErr;
          else w_code_d = 2'b00;
          w_d = w_lite_d ? WBeat : WDrain;
          lite_aw_d = 1'b0; lite_w_d = 1'b0;
        end
      end
      WBeat: begin
        // Capture the single W beat, present AW and W independently to the
        // AXI-Lite side, each valid held until its own ready.
        if (!w_axi_w_q) begin
          w_ready_c = 1'b1;
          if (axi_req_i.w_valid) begin
            w_axi_w_d = 1'b1;
            w_wdata_d = w_off_q[2] ? axi_req_i.w.data[63:32]
                                   : axi_req_i.w.data[31:0];
            w_wstrb_d = w_off_q[2] ? axi_req_i.w.strb[7:4]
                                   : axi_req_i.w.strb[3:0];
          end
        end
        if (w_axi_w_q || axi_req_i.w_valid) begin
          if (!lite_aw_q) begin
            l_aw_valid_c = 1'b1;
            lreq.aw.addr = {52'h0, w_off_q[11:2], 2'b00};
            if (lresp.aw_ready) lite_aw_d = 1'b1;
          end
          if (!lite_w_q) begin
            l_w_valid_c = 1'b1;
            lreq.w.data = w_axi_w_q ? w_wdata_q :
                (w_off_q[2] ? axi_req_i.w.data[63:32]
                            : axi_req_i.w.data[31:0]);
            lreq.w.strb = w_axi_w_q ? w_wstrb_q :
                (w_off_q[2] ? axi_req_i.w.strb[7:4]
                            : axi_req_i.w.strb[3:0]);
            if (lresp.w_ready) lite_w_d = 1'b1;
          end
          if ((lite_aw_q || lresp.aw_ready) &&
              (lite_w_q || lresp.w_ready)) w_d = WResp;
        end
      end
      WDrain: begin
        // Illegal write: consume every W beat until w_last, then respond.
        w_ready_c = 1'b1;
        if (axi_req_i.w_valid && axi_req_i.w.last) w_d = WResp;
      end
      WResp: begin
        if (w_lite_q) begin
          // Pass B through: the register block holds it until the master
          // accepts, so upstream backpressure never drops the response.
          l_b_ready_c = axi_req_i.b_ready;
          if (lresp.b_valid) begin
            b_valid_c = 1'b1;
            b_id_c = w_id_q;
            b_resp_c = lresp.b.resp;
            if (axi_req_i.b_ready) begin
              w_d = WIdle; w_lite_d = 1'b0; w_axi_w_d = 1'b0;
            end
          end
        end else begin
          b_valid_c = 1'b1;
          if (axi_req_i.b_ready) w_d = WIdle;
        end
      end
      default: w_d = WIdle;
    endcase
  end

  always_comb begin : p_read
    r_d = r_q; r_id_d = r_id_q; r_len_d = r_len_q;
    r_off_d = r_off_q; r_code_d = r_code_q; r_lite_d = r_lite_q;
    r_page_d = r_page_q;
    r_data_d = r_data_q;
    lite_ar_d = lite_ar_q;
    ar_ready_c = 1'b0;
    r_valid_c = 1'b0; r_last_c = 1'b0;
    r_id_c = r_id_q; r_data_c = '0; r_resp_c = r_code_q;
    l_ar_valid_c = 1'b0; l_r_ready_c = 1'b0;
    lreq.ar.addr = '0; lreq.ar.prot = '0;
    unique case (r_q)
      RIdle: begin
        ar_ready_c = 1'b1;
        if (axi_req_i.ar_valid) begin
          r_id_d = axi_req_i.ar.id;
          r_len_d = axi_req_i.ar.len;
          r_off_d = ar_off[11:0];
          r_page_d = ar_off[12];
          r_lite_d = ar_shape && ar_ctrl && (CtrlPageEn || ar_off[12]);
          if (ar_addr < Base || ar_off >= 64'h10_0000) r_code_d = DecErr;
          else if (ar_off >= 64'h2000) r_code_d = DecErr;
          else if (!CtrlPageEn && ar_off < 64'h1000) r_code_d = DecErr;
          else if (!ar_shape) r_code_d = SlvErr;
          else r_code_d = 2'b00;
          r_d = r_lite_d ? RLite : RResp;
          lite_ar_d = 1'b0;
        end
      end
      RLite: begin
        if (!lite_ar_q) begin
          l_ar_valid_c = 1'b1;
          lreq.ar.addr = {52'h0, r_off_q[11:2], 2'b00};
          if (lresp.ar_ready) lite_ar_d = 1'b1;
        end
        if (lite_ar_q || lresp.ar_ready) begin
          l_r_ready_c = 1'b1;
          if (lresp.r_valid) begin
            r_data_d = lresp.r.data;
            r_code_d = lresp.r.resp;
            r_d = RResp; lite_ar_d = 1'b0;
          end
        end
      end
      RResp: begin
        r_valid_c = 1'b1;
        r_data_c = r_lite_q ? {r_data_q, r_data_q} : '0;
        r_last_c = r_lite_q || (r_len_q == 0);
        if (axi_req_i.r_ready) begin
          if (r_lite_q || r_len_q == 0) begin
            r_d = RIdle; r_lite_d = 1'b0;
          end else r_len_d = r_len_q - 1;
        end
      end
      default: r_d = RIdle;
    endcase
  end

  // Struct assembly: one continuous assignment per struct, members from the
  // channel wires above (no struct is driven by two processes).
  assign axi_resp_o.aw_ready = aw_ready_c;
  assign axi_resp_o.w_ready = w_ready_c;
  assign axi_resp_o.b_valid = b_valid_c;
  assign axi_resp_o.b.id = b_id_c;
  assign axi_resp_o.b.resp = b_resp_c;
  assign axi_resp_o.b.user = '0;
  assign axi_resp_o.ar_ready = ar_ready_c;
  assign axi_resp_o.r_valid = r_valid_c;
  assign axi_resp_o.r.id = r_id_c;
  assign axi_resp_o.r.data = r_data_c;
  assign axi_resp_o.r.resp = r_resp_c;
  assign axi_resp_o.r.last = r_last_c;
  assign axi_resp_o.r.user = '0;
  assign lreq.aw_valid = l_aw_valid_c;
  assign lreq.w_valid = l_w_valid_c;
  assign lreq.b_ready = l_b_ready_c;
  assign lreq.ar_valid = l_ar_valid_c;
  assign lreq.r_ready = l_r_ready_c;


  // Page demux: write channels follow w_page_q, read channels r_page_q. The
  // unselected port sees no valid; its ready/response is ignored.
  always_comb begin
    ctrl_req_o = '0;
    vctrl_req_o = '0;
    ctrl_req_o.aw = lreq.aw; ctrl_req_o.w = lreq.w; ctrl_req_o.ar = lreq.ar;
    vctrl_req_o.aw = lreq.aw; vctrl_req_o.w = lreq.w; vctrl_req_o.ar = lreq.ar;
    if (w_page_q) begin
      vctrl_req_o.aw_valid = lreq.aw_valid; vctrl_req_o.w_valid = lreq.w_valid;
      vctrl_req_o.b_ready = lreq.b_ready;
    end else if (CtrlPageEn) begin
      ctrl_req_o.aw_valid = lreq.aw_valid; ctrl_req_o.w_valid = lreq.w_valid;
      ctrl_req_o.b_ready = lreq.b_ready;
    end
    if (r_page_q) begin
      vctrl_req_o.ar_valid = lreq.ar_valid; vctrl_req_o.r_ready = lreq.r_ready;
    end else if (CtrlPageEn) begin
      ctrl_req_o.ar_valid = lreq.ar_valid; ctrl_req_o.r_ready = lreq.r_ready;
    end
  end
  always_comb begin
    lresp = '0;
    lresp.aw_ready = w_page_q ? vctrl_resp_i.aw_ready : ctrl_resp_i.aw_ready;
    lresp.w_ready = w_page_q ? vctrl_resp_i.w_ready : ctrl_resp_i.w_ready;
    lresp.b_valid = w_page_q ? vctrl_resp_i.b_valid : ctrl_resp_i.b_valid;
    lresp.b = w_page_q ? vctrl_resp_i.b : ctrl_resp_i.b;
    lresp.ar_ready = r_page_q ? vctrl_resp_i.ar_ready : ctrl_resp_i.ar_ready;
    lresp.r_valid = r_page_q ? vctrl_resp_i.r_valid : ctrl_resp_i.r_valid;
    lresp.r = r_page_q ? vctrl_resp_i.r : ctrl_resp_i.r;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_q <= WIdle; w_id_q <= '0; w_off_q <= '0; w_code_q <= '0; w_page_q <= 1'b0;
      w_lite_q <= '0; w_axi_w_q <= '0; w_wdata_q <= '0; w_wstrb_q <= '0;
      lite_aw_q <= '0; lite_w_q <= '0;
      r_q <= RIdle; r_id_q <= '0; r_len_q <= '0; r_off_q <= '0; r_page_q <= 1'b0;
      r_code_q <= '0; r_lite_q <= '0; r_data_q <= '0;
      lite_ar_q <= '0;
    end else begin
      w_q <= w_d; w_id_q <= w_id_d; w_off_q <= w_off_d; w_page_q <= w_page_d;
      w_code_q <= w_code_d; w_lite_q <= w_lite_d;
      w_axi_w_q <= w_axi_w_d; w_wdata_q <= w_wdata_d;
      w_wstrb_q <= w_wstrb_d; lite_aw_q <= lite_aw_d; lite_w_q <= lite_w_d;
      r_q <= r_d; r_id_q <= r_id_d; r_len_q <= r_len_d;
      r_off_q <= r_off_d; r_code_q <= r_code_d; r_lite_q <= r_lite_d;
      r_page_q <= r_page_d;
      r_data_q <= r_data_d; lite_ar_q <= lite_ar_d;
    end
  end
  end
endmodule
