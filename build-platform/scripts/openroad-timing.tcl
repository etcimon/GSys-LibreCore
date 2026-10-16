# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Static timing report for one mapped netlist. Structural FO4 is not this
# report. Requires a liberty, a gate-level netlist, and an SDC.
#
#   OR_LIBERTY=slow.lib OR_VERILOG=top.v OR_SDC=top.sdc OR_TOP=cva6 \
#     openroad -no_init -exit build-platform/scripts/openroad-timing.tcl
#
# Optional:
#   OR_LEF          space-separated LEF files (technology first, then the
#                   standard cells). Required by the `openroad` binary, whose
#                   link_design builds an ODB database and needs a technology;
#                   OpenSTA's `sta` links from the liberty alone and ignores it.
#   OR_THREADS      set_thread_count (default: every host core — OpenSTA's
#                   search parallelises over endpoints; `timings sta-rtl`
#                   passes toolchain.openroad.threads)
#   OR_GROUP_COUNT  paths per report_checks (default 20)
#   OR_REPORT_DIR   also write paths-max.rpt / paths-min.rpt / summary.txt there
#   OR_IGNORE_FANOUT_ABOVE
#                   study knob: disable timing through the driver cells of
#                   nets with more loads than this. A mapped netlist that has
#                   not been through repair_design carries unbuffered
#                   broadcast nets (reset, flush: tens of nF) whose delays
#                   are placement artifacts, not logic depth; with them out
#                   of the way the report ranks the datapath cones the
#                   structural FO4 model estimates. The count of disabled
#                   drivers is printed (STA_IGNORED_FANOUT) and the result is
#                   labelled a study, never sign-off.
#
# Both binaries come from the tools/openroad fork
# (build-platform/scripts/install-openroad-g6lc.sh installs openroad and sta).

foreach {name} {OR_LIBERTY OR_VERILOG OR_SDC OR_TOP} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "$name is required"
  }
}

# set_thread_count is openroad's; OpenSTA's sta has no thread knob here.
if {[info commands set_thread_count] ne ""} {
  if {[info exists ::env(OR_THREADS)] && $::env(OR_THREADS) ne "" && $::env(OR_THREADS) > 0} {
    set_thread_count $::env(OR_THREADS)
  } elseif {[info commands cpu_count] ne ""} {
    set_thread_count [cpu_count]
  }
}
set group_count 20
if {[info exists ::env(OR_GROUP_COUNT)] && $::env(OR_GROUP_COUNT) ne ""} {
  set group_count $::env(OR_GROUP_COUNT)
}

set is_openroad [expr {[info commands read_lef] ne ""}]
if {$is_openroad} {
  if {![info exists ::env(OR_LEF)] || $::env(OR_LEF) eq ""} {
    error "openroad's link_design needs a technology: set OR_LEF to the tech + std-cell LEF files, or run this script with the fork's sta binary (<prefix>/bin/sta)"
  }
  foreach lef $::env(OR_LEF) {
    read_lef $lef
  }
}
foreach lib $::env(OR_LIBERTY) {
  read_liberty $lib
}
read_verilog $::env(OR_VERILOG)
if {$is_openroad} {
  link_design $::env(OR_TOP)
} else {
  link_design -no_black_boxes $::env(OR_TOP)
}
read_sdc $::env(OR_SDC)
set ignored_fanout 0
if {[info exists ::env(OR_IGNORE_FANOUT_ABOVE)] && $::env(OR_IGNORE_FANOUT_ABOVE) ne "" \
    && $::env(OR_IGNORE_FANOUT_ABOVE) > 0} {
  # The fanout check counts the flat (leaf) loads of each net — a hierarchical
  # net's own pin list does not — so let the checker find the broadcast nets,
  # then take their leaf driver cells out of the timing graph.
  set lim $::env(OR_IGNORE_FANOUT_ABOVE)
  set_max_fanout $lim [current_design]
  set tmp [file join [file dirname $::env(OR_VERILOG)] "fanout-violators.rpt"]
  report_check_types -max_fanout -violators > $tmp
  set fh [open $tmp r]
  set nets_over 0
  while {[gets $fh line] >= 0} {
    if {![string match "*(VIOLATED)*" $line]} continue
    set name [lindex $line 0]
    set pins [get_pins -quiet $name]
    foreach drv $pins {
      if {![$drv is_leaf]} continue
      incr nets_over
      set inst [get_cells -quiet -of_objects $drv]
      if {$inst ne ""} {
        set_disable_timing $inst
        incr ignored_fanout
      }
    }
  }
  close $fh
  puts "STA_IGNORED_FANOUT limit=$lim nets_over=$nets_over drivers_disabled=$ignored_fanout (study: broadcast nets excluded)"
}
if {[llength [find_timing_paths -path_delay max -group_path_count 1]] == 0} {
  error "no constrained maximum-delay path; this is not a timing result"
}

report_checks -path_delay max -fields {slew cap input_pins} -digits 3 \
  -group_count $group_count
report_worst_slack -max
report_tns -max
report_checks -path_delay min -fields {slew cap input_pins} -digits 3 \
  -group_count $group_count
report_worst_slack -min
report_tns -min
report_check_types -max_slew -max_capacitance -max_fanout -violators -digits 3

if {[info exists ::env(OR_REPORT_DIR)] && $::env(OR_REPORT_DIR) ne ""} {
  set dir $::env(OR_REPORT_DIR)
  file mkdir $dir
  report_checks -path_delay max -fields {slew cap input_pins nets} \
    -format full_clock_expanded -digits 3 -group_count $group_count \
    > [file join $dir paths-max.rpt]
  report_checks -path_delay min -fields {slew cap input_pins} -digits 3 \
    -group_count $group_count > [file join $dir paths-min.rpt]
  set f [open [file join $dir summary.txt] w]
  puts $f "top [sta::network_instance_count] instances"
  puts $f "wns_max [sta::worst_slack -max]"
  puts $f "tns_max [sta::total_negative_slack -max]"
  puts $f "wns_min [sta::worst_slack -min]"
  puts $f "tns_min [sta::total_negative_slack -min]"
  close $f
}
puts "STA_RESULT top=$::env(OR_TOP) wns_max=[sta::worst_slack -max] tns_max=[sta::total_negative_slack -max] wns_min=[sta::worst_slack -min] tns_min=[sta::total_negative_slack -min] ignored_fanout_drivers=$ignored_fanout"
