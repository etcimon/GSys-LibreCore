#!/usr/bin/env python3
# Full worst-path reports (fanout>64 drivers disabled, as the module board) for
# selected modules of the latest streamed whole-core map: cell-by-cell traces.
import glob, os, re, subprocess, sys

D = sorted(glob.glob("/home/ubuntu/.cache/g6lc-sta/g6lc64_ooo-streamed-*/"), key=os.path.getmtime)[-1]
LIB = "/opt/testharness/src/openroad-g6lc/test/Nangate45/Nangate45_typ.lib"
STA = "/opt/testharness/toolchains/openroad-g6lc-pgo/bin/sta"
OUT = "/tmp/pathrep"
os.makedirs(OUT, exist_ok=True)
pats = (os.environ.get("PATHREP_MODULES") or "wt_dcache_wbuffer frontend_cva6 g6lc_iq_cva6 g6lc_ooo_dispatch g6lc_lsq_cva6").split()
for pat in pats:
    vs = sorted(glob.glob(f"{D}/mapped/*{pat}*.v"))
    if not vs:
        print("no netlist for", pat); continue
    v = vs[0]
    mod = re.search(r"^module\s+(\S+?)\s*\(", open(v).read(200000), re.M).group(1).lstrip("\\")
    tcl = f"""
read_liberty {LIB}
read_verilog {v}
link_design {{{mod}}}
create_clock -name mclk -period 0.25 [get_ports clk_i]
set ins [delete_from_list [all_inputs] [get_ports clk_i]]
set_input_delay 0 -clock mclk $ins
set_input_transition 0.01 $ins
set_output_delay 0 -clock mclk [all_outputs]
set_load 0.005 [all_outputs]
set_false_path -from [get_ports rst_ni]
set_max_fanout 64 [current_design]
report_check_types -max_fanout -violators > {OUT}/{pat}.fan
set fh [open {OUT}/{pat}.fan r]
while {{[gets $fh line] >= 0}} {{
  if {{![string match "*(VIOLATED)*" $line]}} continue
  foreach drv [get_pins -quiet [lindex $line 0]] {{ if {{[$drv is_leaf]}} {{ set_disable_timing [get_cells -of_objects $drv] }} }}
}}
close $fh
report_checks -path_delay max -path_group mclk -group_path_count 2 -fields {{net fanout}} -format full > {OUT}/{pat}.rpt
"""
    open(f"{OUT}/{pat}.tcl", "w").write(tcl)
    subprocess.run([STA, "-exit", f"{OUT}/{pat}.tcl"], stdout=open(f"{OUT}/{pat}.log", "w"), stderr=subprocess.STDOUT)
    print(f"=== {pat} ({mod})", flush=True)
    t = open(f"{OUT}/{pat}.rpt").read() if os.path.exists(f"{OUT}/{pat}.rpt") else open(f"{OUT}/{pat}.log").read()[-1500:]
    for b in t.split("Startpoint:")[1:3]:
        lines = b.splitlines()
        print("Startpoint:" + lines[0].strip())
        print(next((l.strip() for l in lines if l.strip().startswith("Endpoint")), "?"))
        for l in lines:
            if re.search(r"\([A-Z]+[0-9]*_X\d\)", l) and re.match(r"\s*\S+\s+\S+", l):
                print("  " + re.sub(r"\s+", " ", l.strip())[:150])
        for l in lines:
            if "data arrival time" in l:
                print("  " + l.strip()); break
        print("---")
