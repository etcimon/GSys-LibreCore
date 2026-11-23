// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-009A slot set: Slots discovery machines plus a registered duplicate-
// identity check over the READY-published identities. A duplicate withdraws
// both entries from slot_map_o via dup_o; neither slot faults, because
// identity ownership is a provisioning policy. Entries >= Slots in slot_map_o
// are zero. Discovery never builds or changes an address map.
module g6lc_storamic_discovery_set #(
  parameter int unsigned Slots = 1,
  parameter int unsigned DebounceCycles = 4,
  parameter int unsigned PowerTimeout = 64,
  parameter int unsigned DescTimeout = 64,
  parameter int unsigned InitTimeout = 256,
  parameter int unsigned DescMaxWords = 32,
  parameter logic [63:0] MaxRamBytes = 64'hFFFF_FFFF_FFFF_FFFF,
  parameter logic [63:0] MaxFlashBytes = 64'hFFFF_FFFF_FFFF_FFFF,
  parameter logic [3:0] SupportedProfile = 4'h0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic [Slots-1:0] presence_i,
  input logic [Slots-1:0][3:0] profile_strap_i,
  input logic [Slots-1:0] power_good_i,
  output logic [Slots-1:0] power_en_o,
  output logic [Slots-1:0] desc_req_o,
  output logic [Slots-1:0][7:0] desc_addr_o,
  input logic [Slots-1:0] desc_valid_i,
  input logic [Slots-1:0][31:0] desc_data_i,
  input logic [Slots-1:0] desc_error_i,
  output logic [Slots-1:0] init_req_o,
  input logic [Slots-1:0] init_done_i,
  input logic [Slots-1:0] init_error_i,
  input logic [Slots-1:0] quiesce_req_i,
  input logic [Slots-1:0] drain_i,
  input logic [Slots-1:0] fault_clear_i,
  output logic [Slots-1:0][3:0] state_o,
  output logic [Slots-1:0][3:0] fault_o,
  output g6lc_storamic_region_pkg::slot_map_t slot_map_o,
  output logic [Slots-1:0] dup_o,
  output logic [Slots-1:0] ram_ready_o,
  output logic [Slots-1:0] flash_ready_o,
  output logic [Slots-1:0] persist_cap_o,
  output logic [Slots-1:0] fault_event_o,
  output logic [Slots-1:0] ready_event_o
);
  // pragma translate_off
  initial begin
    if (Slots < 1 || Slots > g6lc_storamic_cfg_pkg::MaxSupportedSticks)
      $fatal(1, "STORAMIC_DISC_PARAM_SLOTS");
  end
  // pragma translate_on

  g6lc_storamic_region_pkg::slot_desc_t desc [Slots];
  logic [Slots-1:0] pub;

  for (genvar s = 0; s < Slots; s++) begin : gen_slot
    g6lc_storamic_discovery #(
      .DebounceCycles(DebounceCycles), .PowerTimeout(PowerTimeout),
      .DescTimeout(DescTimeout), .InitTimeout(InitTimeout),
      .DescMaxWords(DescMaxWords), .MaxRamBytes(MaxRamBytes),
      .MaxFlashBytes(MaxFlashBytes), .SupportedProfile(SupportedProfile)
    ) i_slot (
      .clk_i, .rst_ni, .testmode_i,
      .presence_i(presence_i[s]), .profile_strap_i(profile_strap_i[s]),
      .power_good_i(power_good_i[s]), .power_en_o(power_en_o[s]),
      .desc_req_o(desc_req_o[s]), .desc_addr_o(desc_addr_o[s]),
      .desc_valid_i(desc_valid_i[s]), .desc_data_i(desc_data_i[s]),
      .desc_error_i(desc_error_i[s]),
      .init_req_o(init_req_o[s]), .init_done_i(init_done_i[s]),
      .init_error_i(init_error_i[s]),
      .quiesce_req_i(quiesce_req_i[s]), .drain_i(drain_i[s]),
      .fault_clear_i(fault_clear_i[s]),
      .state_o(state_o[s]), .fault_o(fault_o[s]),
      .slot_desc_o(desc[s]),
      .ram_ready_o(ram_ready_o[s]), .flash_ready_o(flash_ready_o[s]),
      .persist_ready_o(), .persist_cap_o(persist_cap_o[s]),
      .flash_bytes_o(), .erase_bytes_o(),
      .fault_event_o(fault_event_o[s]), .ready_event_o(ready_event_o[s])
    );
    assign pub[s] = desc[s].present;
  end

  // Registered duplicate-identity detection over published descriptors.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) dup_o <= '0;
    else begin
      for (int i = 0; i < Slots; i++) begin
        dup_o[i] <= 1'b0;
        for (int j = 0; j < Slots; j++)
          if (j != i && pub[i] && pub[j] &&
              desc[i].identity == desc[j].identity)
            dup_o[i] <= 1'b1;
      end
    end
  end

  always_comb begin
    slot_map_o = '{default: '0};
    for (int i = 0; i < Slots; i++) begin
      slot_map_o[i].present = pub[i] && !dup_o[i];
      slot_map_o[i].identity = pub[i] ? desc[i].identity : '0;
      slot_map_o[i].ram_bytes = pub[i] ? desc[i].ram_bytes : '0;
      slot_map_o[i].reserved_bytes = pub[i] ? desc[i].reserved_bytes : '0;
    end
  end
endmodule
