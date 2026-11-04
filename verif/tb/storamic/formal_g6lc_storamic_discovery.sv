// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-009B bounded safety + reachability for one discovery slot with small
// parameters so covers are reachable. All inputs are free.
module formal_g6lc_storamic_discovery (
  input logic clk_i,
  input logic rst_ni,
  input logic presence_i,
  input logic [3:0] profile_strap_i,
  input logic power_good_i,
  input logic desc_valid_i,
  input logic [31:0] desc_data_i,
  input logic desc_error_i,
  input logic init_done_i,
  input logic init_error_i,
  input logic quiesce_req_i,
  input logic drain_i,
  input logic fault_clear_i,
  output logic cover_ready_o,
  output logic cover_cksum_o,
  output logic cover_quiesced_o
);
  import g6lc_storamic_discovery_pkg::*;

  logic pen, dreq, ireq, rready, fready, pcap, fev, rev;
  logic [7:0] daddr;
  state_t st;
  fault_t ft;
  g6lc_storamic_region_pkg::slot_desc_t sdesc;

  g6lc_storamic_discovery #(
    .DebounceCycles(2), .PowerTimeout(4), .DescTimeout(4), .InitTimeout(4),
    .DescMaxWords(12), .MaxRamBytes(64'h10000), .MaxFlashBytes(64'h10000),
    .SupportedProfile(4'h5)
  ) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0),
    .presence_i, .profile_strap_i, .power_good_i,
    .power_en_o(pen), .desc_req_o(dreq), .desc_addr_o(daddr),
    .desc_valid_i, .desc_data_i, .desc_error_i,
    .init_req_o(ireq), .init_done_i, .init_error_i,
    .quiesce_req_i, .drain_i, .fault_clear_i,
    .state_o(st), .fault_o(ft), .slot_desc_o(sdesc),
    .ram_ready_o(rready), .flash_ready_o(fready), .persist_ready_o(),
    .persist_cap_o(pcap), .flash_bytes_o(), .erase_bytes_o(),
    .fault_event_o(fev), .ready_event_o(rev)
  );

  // Shadow model of the synchronized + debounced presence and the strap check,
  // so assertions refer to observable inputs rather than internals.
  logic [1:0] pres_pipe;
  logic [3:0] strap_s0, strap_s1;
  logic pres_db;
  int unsigned deb;
  logic strap_ok;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pres_pipe <= '0;
      strap_s0 <= '0;
      strap_s1 <= '0;
      pres_db <= 1'b0;
      deb <= 0;
      strap_ok <= 1'b0;
    end else begin
      pres_pipe <= {pres_pipe[0], presence_i};
      strap_s0 <= profile_strap_i;
      strap_s1 <= strap_s0;
      if (pres_pipe[1] != pres_db) begin
        if (deb >= 1) begin pres_db <= pres_pipe[1]; deb <= 0; end
        else deb <= deb + 1;
      end else deb <= 0;
      if (st == Absent) strap_ok <= 1'b0;
      else if (st == PowerCheck && strap_s1 == 4'h5) strap_ok <= 1'b1;
    end
  end

  // pres_db_eff mirrors the RTL commit timing for the fault-exit check.
  logic pres_db_eff;
  assign pres_db_eff = (pres_pipe[1] != pres_db && deb >= 1) ? pres_pipe[1] :
                       pres_db;

  // Safety: power implies accepted strap + debounced presence; desc and init
  // requests only while powered; a published descriptor implies Ready; faults
  // are sticky until cleared while absent.
  always @(posedge clk_i) if (rst_ni) begin
    assert (!(pen && !strap_ok));
    assert (!(pen && !pres_db));
    assert (!(dreq && !pen));
    assert (!(ireq && !pen));
    assert (!(sdesc.present && st != Ready));
    if (st == Fault)
      assert (ft != FaultNone);
    assert (int'(st) <= 10);
    if ($past(st == Fault) && st != Fault)
      assert ($past(!pres_db_eff && fault_clear_i));
  end

  // Covers.
  logic cov_ready, cov_cksum, cov_quiesced;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cov_ready <= 0; cov_cksum <= 0; cov_quiesced <= 0;
    end else begin
      if (st == Ready) cov_ready <= 1;
      if (st == Fault && ft == FaultChecksum) cov_cksum <= 1;
      if (st == Quiesced) cov_quiesced <= 1;
    end
  end
  assign cover_ready_o = cov_ready;
  assign cover_cksum_o = cov_cksum;
  assign cover_quiesced_o = cov_quiesced;
endmodule
