# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Paired IQ placement/buffering discriminator. A pre-CTS, unrouted module
# study, not whole-core sign-off. No fanout drivers or timing arcs are
# disabled. Both variants use the same floorplan, pins, RC and constraints.
foreach key {STUDY_PLATFORM OR_VERILOG OR_TOP STUDY_OUTPUT STUDY_VARIANT} {
  if {![info exists ::env($key)]} { error "$key is required" }
}
set platform $::env(STUDY_PLATFORM)
set out $::env(STUDY_OUTPUT)
file mkdir $out
set_thread_count 8
sta::set_thread_count 1
read_lef "$platform/Nangate45_tech.lef"
read_lef "$platform/Nangate45_stdcell.lef"
read_liberty "$platform/Nangate45_typ.lib"
read_verilog $::env(OR_VERILOG)
link_design $::env(OR_TOP)

create_clock -name core_clock -period 0.25 [get_ports clk_i]
set_clock_uncertainty 0.05 [get_clocks core_clock]
set ins [delete_from_list [all_inputs] [get_ports clk_i]]
set_input_delay 0 -clock core_clock $ins
set_input_transition 0.01 $ins
set_output_delay 0 -clock core_clock [all_outputs]
set_load 0.005 [all_outputs]
set_max_fanout 16 [current_design]

initialize_floorplan -site FreePDK45_38x28_10R_NP_162NW_34O \
  -die_area {0 0 900 900} -core_area {10 10 890 890}
source "$platform/Nangate45.tracks"
remove_buffers
global_placement -density 0.40 -skip_io
place_pins -hor_layers metal3 -ver_layers metal2
global_placement -density 0.40
source "$platform/Nangate45.rc"
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal6
set_dont_use {CLKBUF_* AOI211_X1 OAI211_X1}
estimate_parasitics -placement
# Guardband the placement RC change caused by legalization. The zero-margin
# trial left a few electrical violations after detailed placement.
repair_design -slew_margin 10 -cap_margin 10
repair_tie_fanout -separation 5 LOGIC0_X1/Z
repair_tie_fanout -separation 5 LOGIC1_X1/Z
puts "PLACE_STAGE detailed_placement"
flush stdout
detailed_placement
puts "PLACE_STAGE check_placement"
flush stdout
check_placement -verbose
puts "PLACE_STAGE estimate_parasitics"
flush stdout
estimate_parasitics -placement

proc max_arrival_ns {paths} {
  if {[llength $paths] == 0} { return "-" }
  set worst 0.0
  foreach p $paths {
    set worst [expr {max($worst, [$p data_arrival_time] * 1e9)}]
  }
  return [format %.3f $worst]
}
puts "PLACE_STAGE timing"
flush stdout
# PathEnd handles belong to the current search. Read their values before
# another find_timing_paths/report_checks replaces that search's objects.
set any_ns [max_arrival_ns [find_timing_paths -path_delay max -group_path_count 1 -sort_by_slack]]
set rr_ns [max_arrival_ns [find_timing_paths -path_delay max -group_path_count 1 -sort_by_slack \
  -from [all_registers -clock_pins] -to [all_registers -data_pins]]]
if {$any_ns eq "-" || $rr_ns eq "-"} {
  error "placed IQ has no constrained data path"
}
report_checks -path_delay max -group_path_count 3 -fields {slew cap fanout} > "$out/paths.rpt"
report_check_types -max_slew -max_capacitance -max_fanout -violators > "$out/electrical.rpt"
write_db "$out/placed.odb"
puts "PLACE_STUDY variant=$::env(STUDY_VARIANT) any_ns=$any_ns reg2reg_ns=$rr_ns area_um2=[sta::format_area [rsz::design_area] 3] buffers=[rsz::repair_design_buffer_count] wns_max=[sta::worst_slack -max] disabled_arcs=0"
exit
