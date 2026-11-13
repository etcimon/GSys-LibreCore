// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Native checkpoint platform providers (native-composition.md §4). One
// discovery slot reads the stick's synthetic v1 ("STRM") descriptor through
// the descriptor bus; a model descriptor responder answers it combinationally
// from the bound stick's published geometry. The five provider facts feed
// plat_in.providers_ready; present/identity_valid/protection_ok/module_id and
// the mapping/reset generations are the live platform views consumed by the
// endpoint. Policy update is issued once per mapping generation after all
// providers are ready and held until the policy's update_ready acknowledges.
//
// Init/drain ownership (documented hypothesis resolution): discovery's
// init_done is bound to an independent model-stick init that completes
// immediately — it must NOT depend on the endpoint's initialized_o or a
// deadlock results (endpoint waits on providers_ready which waits on init).
// drain_i is supplied by the harness producer-drain observation.
module g6lc_storamic_native_providers #(
  parameter int unsigned DebounceCycles = 4,
  parameter int unsigned PowerTimeout = 64,
  parameter int unsigned DescTimeout = 64,
  parameter int unsigned InitTimeout = 256,
  parameter int unsigned DescMaxWords = 32,
  parameter logic [63:0] MaxRamBytes = 64'hFFFF_FFFF_FFFF_FFFF,
  parameter logic [63:0] MaxFlashBytes = 64'hFFFF_FFFF_FFFF_FFFF,
  // Bound-stick geometry the descriptor advertises and the binding check uses.
  parameter logic [63:0] ModelBytes = 64'h4_0000,     // 256 KiB default window
  parameter logic [63:0] RawFlashBytes = 64'h1000,    // checkpoint raw flash
  parameter logic [31:0] EraseBytes = 32'd4096,
  parameter logic [31:0] Identity = 32'h5354_4D31,    // "STM1"
  // Alternate stick presented when desc_alt_i is set (bench hot-swap): a
  // different identity with the same geometry.
  parameter logic [31:0] AltIdentity = 32'h5354_4D32, // "STM2"
  // Provider fact 5 statics: the bounded hart is resync-capable by construction.
  parameter bit ResyncCapable = 1'b1,
  parameter logic [3:0] SupportedProfile = 4'h1
) (
  input logic clk_i, rst_ni, testmode_i,
  // Slot pads/trigger page (presence, power-good; profile strap is tied to the
  // model profile inside — there is no real strap pin on the model stick).
  input logic presence_i,
  input logic power_good_i,
  // Lifecycle controls from the harness (checkpoint quiesce drain, fault clear).
  input logic quiesce_req_i, drain_i, fault_clear_i,
  // Selects which stick answers the descriptor bus (sampled by discovery on
  // its next descriptor read, i.e. effective at the next insertion).
  input logic desc_alt_i,
  // Reset generation: owned by the platform power/reset controller (POR-only
  // counter), presented here unchanged.
  input logic [31:0] reset_generation_i,
  // Provider fact 0 live term: the transaction-policy path (origin transport,
  // route) is intact. Provider fact 4 live term: no pause/gate error latched.
  input logic txn_policy_ok_i,
  input logic pause_error_i,
  // Policy update_ready loopback (plat_out.update_ready) for the hold-until-
  // accepted handshake.
  input logic update_ready_i,
  // Provider-side plat_in fields.
  output logic [4:0] providers_ready_o,
  output logic present_o,
  output logic identity_valid_o,
  output logic protection_ok_o,
  output logic [159:0] module_id_o,
  output logic [31:0] mapping_generation_o,
  output logic [31:0] reset_generation_o,
  output logic update_valid_o,
  output logic [31:0] update_policy_o
);
  import g6lc_storamic_discovery_pkg::*;
  import g6lc_storamic_region_pkg::*;

  // ---- model descriptor (static: every field is a parameter) ----
  // Word layout per discovery_pkg: 0 magic,1 ver|len,2 ident,3 flags,
  // 4/5 ram lo/hi,6/7 reserved,8/9 flash lo/hi,10 erase,11 checksum(0-sum).
  localparam int unsigned DescLen = 12;
  localparam logic [31:0] DescFlags =
      32'h7 | (32'(SupportedProfile) << 8);   // RAM|flash|persist | profile
  function automatic logic [31:0] ram_word(input int unsigned i);
    if (i == 4) return ModelBytes[31:0];
    if (i == 5) return ModelBytes[63:32];
    return '0;
  endfunction
  function automatic logic [31:0] flash_word(input int unsigned i);
    if (i == 8) return RawFlashBytes[31:0];
    if (i == 9) return RawFlashBytes[63:32];
    return '0;
  endfunction
  function automatic logic [31:0] desc_word(input logic [7:0] a, input logic alt);
    logic [31:0] w [DescLen];
    logic [31:0] s;
    if (32'(a) >= DescLen) return '0;   // never index past the descriptor
    w[0] = DescMagic;
    w[1] = (32'(DescVersion) << 16) | 32'(DescLen);
    w[2] = alt ? AltIdentity : Identity;
    w[3] = DescFlags;
    w[4] = ram_word(4); w[5] = ram_word(5);
    w[6] = '0; w[7] = '0;
    w[8] = flash_word(8); w[9] = flash_word(9);
    w[10] = EraseBytes;
    s = '0;
    for (int i = 0; i < DescLen - 1; i++) s += w[i];
    w[11] = 0 - s;
    return (32'(a) < DescLen) ? w[a] : '0;
  endfunction

  // ---- descriptor responder: level valid, combinational data aligned to addr
  logic desc_req, desc_valid;
  logic [7:0] desc_addr;
  logic [31:0] desc_data;
  logic desc_error;
  assign desc_valid = desc_req;         // static descriptor: always available
  assign desc_data = desc_word(desc_addr, desc_alt_i);
  assign desc_error = 1'b0;

  // ---- init: independent model-stick init, completes one cycle after req ----
  logic init_req, init_done, init_error;
  logic init_done_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) init_done_q <= 1'b0;
    else init_done_q <= init_req;
  end
  assign init_done = init_done_q;
  assign init_error = 1'b0;

  // ---- power_good synchronizer for the live protection fact ----
  logic pg_sync;
  g6lc_storamic_sync #(.Width(1)) i_pg (
    .clk_i, .rst_ni, .testmode_i, .in_i(power_good_i), .out_o(pg_sync)
  );

  // ---- discovery slot ----
  state_t state;
  fault_t fault;
  slot_desc_t slot_desc;
  logic ram_ready, flash_ready, persist_cap, fault_event, ready_event;
  logic [63:0] flash_bytes, erase_bytes;
  logic power_en;
  g6lc_storamic_discovery #(
    .DebounceCycles(DebounceCycles), .PowerTimeout(PowerTimeout),
    .DescTimeout(DescTimeout), .InitTimeout(InitTimeout),
    .DescMaxWords(DescMaxWords), .MaxRamBytes(MaxRamBytes),
    .MaxFlashBytes(MaxFlashBytes), .SupportedProfile(SupportedProfile)
  ) i_disc (
    .clk_i, .rst_ni, .testmode_i,
    .presence_i(presence_i), .profile_strap_i(SupportedProfile),
    .power_good_i(power_good_i), .power_en_o(power_en),
    .desc_req_o(desc_req), .desc_addr_o(desc_addr),
    .desc_valid_i(desc_valid), .desc_data_i(desc_data), .desc_error_i(desc_error),
    .init_req_o(init_req), .init_done_i(init_done), .init_error_i(init_error),
    .quiesce_req_i(quiesce_req_i), .drain_i(drain_i), .fault_clear_i(fault_clear_i),
    .state_o(state), .fault_o(fault), .slot_desc_o(slot_desc),
    .ram_ready_o(ram_ready), .flash_ready_o(flash_ready),
    .persist_ready_o(), .persist_cap_o(persist_cap),
    .flash_bytes_o(flash_bytes), .erase_bytes_o(erase_bytes),
    .fault_event_o(fault_event), .ready_event_o(ready_event)
  );

  // ---- provider facts ----
  // persist_ready is the model's persistence-capability qualification: the
  // descriptor advertises persistence (flags[2]) and discovery reached READY.
  // discovery.persist_ready_o is hardwired 0 on this model (no qualified media
  // yet); the model qualifies protection as capability && power-good instead.
  logic persist_ready;
  logic protection;
  logic binding;
  logic resume;
  assign persist_ready = persist_cap;             // READY && flags[2]
  assign protection = persist_ready && pg_sync;   // persist_ready && power good
  assign binding = slot_desc.present &&
                  (slot_desc.ram_bytes == ModelBytes) &&
                  (flash_bytes >= RawFlashBytes);
  assign resume = ResyncCapable && !pause_error_i;

  // Mapping generation: one per entry to Ready (a re-inserted or swapped stick
  // is a new mapping). Starts at 0 = "never mapped"; the first Ready is 1.
  logic [31:0] mapping_generation_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mapping_generation_q <= '0;
    else if (ready_event && mapping_generation_q != '1)
      mapping_generation_q <= mapping_generation_q + 32'd1;
  end

  // Live platform views (present = stick detected; identity/protection gate on
  // the captured READY descriptor and live power-good).
  assign present_o = (state != Absent) && (state != Fault);
  assign identity_valid_o = slot_desc.present && (slot_desc.identity != '0);
  assign protection_ok_o = protection;
  // Persistent module identity is the captured descriptor, never a parameter.
  assign module_id_o = {slot_desc.identity, slot_desc.ram_bytes, flash_bytes};
  assign mapping_generation_o = mapping_generation_q;
  assign reset_generation_o = reset_generation_i;

  // providers_ready[4:0]: 0 transaction policy, 1 persistent identity,
  // 2 qualified protection, 3 descriptor binding, 4 resume synchronization.
  assign providers_ready_o = {
    resume,
    binding,
    protection,
    slot_desc.present && (slot_desc.identity != '0),
    slot_desc.present && txn_policy_ok_i
  };

  // ---- policy update: once per mapping generation, held until accepted ----
  logic [31:0] sent_gen_q;
  logic providers_all;
  assign providers_all = &providers_ready_o;
  assign update_valid_o = providers_all && (mapping_generation_q != sent_gen_q);
  assign update_policy_o = mapping_generation_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sent_gen_q <= '0;
    else if (update_valid_o && update_ready_i) sent_gen_q <= mapping_generation_q;
  end

  // pragma translate_off
  initial begin
    if (SupportedProfile > 4'h7)
      $fatal(1, "STORAMIC_NATIVE_PROVIDERS_PROFILE");  // bit[11] must stay 0
    if (ModelBytes == 0 || RawFlashBytes == 0 || EraseBytes == 0 ||
        (EraseBytes & (EraseBytes - 1)) != 0)
      $fatal(1, "STORAMIC_NATIVE_PROVIDERS_GEOMETRY");
  end
  // pragma translate_on
endmodule
