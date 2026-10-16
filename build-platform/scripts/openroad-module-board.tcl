# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Module-level mapped timing row from a streamed `sta-rtl` run: read ONE
# module's mapped netlist (its children become black boxes — they have their
# own rows), link it as top, constrain its clock, and report the module's own
# worst register-to-register path with its cell count, plus the worst path of
# any kind with inputs/outputs ideal, and how many broadcast-net drivers were
# taken out of the graph (OR_IGNORE_FANOUT_ABOVE, default 64 loads). Inputs
# are ideal at a module boundary,
# so the unbuffered broadcast nets of the whole-core report (A97) do not reach
# these numbers; what remains is the module's own logic depth after mapping —
# the quantity the structural FO4 model estimates per module, and the ranking
# of which module to rewrite next. A study, not sign-off: no placement, no
# parasitics, every input arrives at the clock edge.
#
#   OR_LIBERTY=lib OR_VERILOG=mapped/0025_instr_queue….v \
#   OR_TOP='instr_queue$cva6.i_frontend.i_instr_queue' OR_PERIOD_NS=0.25 \
#     sta -exit openroad-module-board.tcl >> module-board.tsv
#
# OR_TOP is the RTLIL module name without its leading backslash (OpenSTA
# strips the Verilog escape when it reads the module). The row is one
# tab-separated line on stdout prefixed with `ROW\t`; the streamed recipe's
# `board_all.sh` runs one process per module in parallel and collects them.
# OpenSTA deletes the module definitions on link, so one process links one
# top; reading a single module file keeps that cheap.

foreach {name} {OR_LIBERTY OR_VERILOG OR_TOP} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "$name is required"
  }
}
set period 0.25
if {[info exists ::env(OR_PERIOD_NS)] && $::env(OR_PERIOD_NS) ne ""} {
  set period $::env(OR_PERIOD_NS)
}
set top $::env(OR_TOP)

foreach lib $::env(OR_LIBERTY) {
  read_liberty $lib
}
read_verilog $::env(OR_VERILOG)
# Children are black boxes here (their own rows carry their depth).
set ok 0
if {[catch {set ok [link_design $top]} err] || !$ok} {
  puts "ROW\t$top\t-\t-\t-\t-\tlink failed\t-\t-\t-\t-\t-\t-"
  exit
}
set n [sta::network_instance_count]
set clk_port [get_ports -quiet clk_i]
if {$clk_port eq ""} {
  puts "ROW\t$top\t$n\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-"
  exit
}
create_clock -name mclk -period $period $clk_port
set ins [delete_from_list [all_inputs] $clk_port]
if {[llength $ins] > 0} {
  set_input_delay 0 -clock mclk $ins
  set_input_transition 0.01 $ins
}
if {[llength [all_outputs]] > 0} {
  set_output_delay 0 -clock mclk [all_outputs]
  set_load 0.005 [all_outputs]
}
# A module's own broadcast nets (valid/flush fan-out to every slot) are as
# unbuffered as the core's; without `repair_design` their driver delay is a
# placement artifact (store_buffer: 22 cells, 299 ns). Take the leaf drivers
# of nets with more than OR_IGNORE_FANOUT_ABOVE loads (default 64) out of the
# timing graph and report how many, so the delay column is logic depth.
set fan_lim 64
if {[info exists ::env(OR_IGNORE_FANOUT_ABOVE)] && $::env(OR_IGNORE_FANOUT_ABOVE) ne ""} {
  set fan_lim $::env(OR_IGNORE_FANOUT_ABOVE)
}
set disabled 0
if {$fan_lim > 0} {
  set_max_fanout $fan_lim [current_design]
  set tmp "$::env(OR_VERILOG).fanout.rpt"
  report_check_types -max_fanout -violators > $tmp
  set fh [open $tmp r]
  while {[gets $fh line] >= 0} {
    if {![string match "*(VIOLATED)*" $line]} continue
    foreach drv [get_pins -quiet [lindex $line 0]] {
      if {![$drv is_leaf]} continue
      set inst [get_cells -quiet -of_objects $drv]
      if {$inst ne ""} {
        set_disable_timing $inst
        incr disabled
      }
    }
  }
  close $fh
  file delete $tmp
}
# Worst path of any kind (inputs/outputs ideal) and the worst register-to-
# register path: the latter is the module's own single-cycle depth.
set any [find_timing_paths -path_delay max -group_path_count 1 -sort_by_slack]
# PathEnd times are seconds; the board is in ns. With ideal clocks the data
# arrival time is the path delay itself.
set any_ns "-"
if {[llength $any] > 0} {
  set any_ns [format %.3f [expr {[[lindex $any 0] data_arrival_time] * 1e9}]]
}
set regs [all_registers]
if {[llength $regs] == 0} {
  puts "ROW\t$top\t$n\tclk_i\t-\t0\t-\t-\t$any_ns\t$disabled\t-\t-\t-"
  exit
}
set r2r [find_timing_paths -path_delay max -group_path_count 1 -sort_by_slack \
           -from [all_registers -clock_pins] -to [all_registers -data_pins]]
if {[llength $r2r] == 0} {
  puts "ROW\t$top\t$n\tclk_i\t-\t0\t-\t-\t$any_ns\t$disabled\t-\t-\t-"
  exit
}
set pe [lindex $r2r 0]
set delay [format %.3f [expr {[$pe data_arrival_time] * 1e9}]]
set path [$pe path]
set cells 0
set start "-"
set endp "-"
set first 1
# The flop instances are yosys auto names (`_12988_`); the nets keep their
# RTL names (`issue_pointer_q[3]`). Report the start flop's Q net and the
# net driving the end flop's D pin so a row points at RTL registers, plus
# the RTL-named nets along the path (a legible trace of the cone).
set start_net "-"
set end_net "-"
set trace {}
set driver_pins {}
foreach pin [$path pins] {
  if {[$pin is_leaf] && ![$pin is_top_level_port]} {
    set inst [get_full_name [get_cells -of_objects $pin]]
    if {$first} { set start $inst; set first 0 }
    set endp $inst
    if {[$pin is_driver]} {
      incr cells
      lappend driver_pins $pin
    }
  }
}
proc rtl_net_of {pin} {
  # `$path pins` yields raw Pin handles; go through the SDC collection API.
  set p [get_pins -quiet [get_full_name $pin]]
  if {[llength $p] == 0} { return "" }
  set net [get_nets -quiet -of_objects $p]
  if {[llength $net] == 0} { return "" }
  set nm [get_full_name [lindex $net 0]]
  # yosys auto nets are `_123_`; keep RTL names only
  if {[regexp {^_[0-9]+_$} $nm]} { return "" }
  return $nm
}
if {[llength $driver_pins] > 0} {
  set start_net [rtl_net_of [lindex $driver_pins 0]]
  if {$start_net eq ""} { set start_net "-" }
  set last_pin [lindex [$path pins] end]
  set en [rtl_net_of $last_pin]
  if {$en eq ""} { set en [rtl_net_of [lindex $driver_pins end]] }
  set end_net [expr {$en eq "" ? "-" : $en}]
  foreach dp $driver_pins {
    set nm [rtl_net_of $dp]
    if {$nm ne "" && [lsearch -exact $trace $nm] < 0} { lappend trace $nm }
  }
}
if {[llength $trace] > 12} { set trace [concat [lrange $trace 0 5] {...} [lrange $trace end-5 end]] }
puts "ROW\t$top\t$n\tclk_i\t$delay\t$cells\t$start\t$endp\t$any_ns\t$disabled\t$start_net\t$end_net\t[join $trace { > }]"
exit
