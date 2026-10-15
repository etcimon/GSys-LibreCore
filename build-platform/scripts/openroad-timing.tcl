# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Static timing report for one mapped netlist. Structural FO4 is not this
# report. Requires a liberty, a gate-level netlist, and an SDC.
#
#   OR_LIBERTY=slow.lib OR_VERILOG=top.v OR_SDC=top.sdc OR_TOP=cva6 \
#     openroad -no_init -exit build-platform/scripts/openroad-timing.tcl
#
# The openroad binary is the tools/openroad fork
# (build-platform/scripts/install-openroad-g6lc.sh).

foreach {name} {OR_LIBERTY OR_VERILOG OR_SDC OR_TOP} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "$name is required"
  }
}

read_liberty $::env(OR_LIBERTY)
read_verilog $::env(OR_VERILOG)
link_design $::env(OR_TOP)
read_sdc $::env(OR_SDC)
report_checks -path_delay max -fields {slew cap input_pins} -digits 3
report_worst_slack -max
report_tns -max
report_checks -path_delay min -fields {slew cap input_pins} -digits 3
report_worst_slack -min
