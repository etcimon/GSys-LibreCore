#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Local-only frozen checkpoint-route checks; not native qualification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--interconnect", action="store_true",
                        help="exercise real AXI mux/ID insertion and AW-owner routing")
    parser.add_argument("--crossbar", action="store_true",
                        help="exercise complete real crossbar decode/demux/mux")
    parser.add_argument("--native", action="store_true",
                        help="crossbar with the real ariane dimensions and "
                             "concurrent 3-port adversarial drive")
    args = parser.parse_args()
    if args.crossbar or args.native:
        args.interconnect = True
    if args.native:
        args.crossbar = True
    root = Path(__file__).resolve().parents[3]
    out = Path(args.output_root).resolve()
    if not out.is_relative_to((root / "build-platform/workspace").resolve()):
        parser.error("output must be contained in build-platform/workspace")
    out.mkdir(parents=True, exist_ok=False)
    source = out / "source"
    files = [
        "vendor/pulp-platform/axi/src/axi_pkg.sv",
        "g6lc_storamic/rtl/include/g6lc_storamic_pkg.sv",
        "g6lc_storamic/rtl/fabric/g6lc_storamic_checkpoint_service.sv",
        "corev_apu/storamic/g6lc_storamic_ctrl_bridge.sv",
        "corev_apu/storamic/g6lc_storamic_checkpoint_route.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_route.sv",
        "verif/tb/storamic/tb_g6lc_storamic_ctrl_bridge.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_route.sv",
    ]
    if args.interconnect:
        vendor = "vendor/pulp-platform/"
        files = ["verif/tb/storamic/route_interconnect.vlt"] + [
            vendor + "common_cells/src/" + name + ".sv" for name in (
            "cf_math_pkg", "lzc", "rr_arb_tree", "fifo_v3",
            "spill_register_flushable", "spill_register")] + [
                vendor + "axi/src/axi_pkg.sv", vendor + "axi/src/axi_intf.sv",
                vendor + "axi/src/axi_id_prepend.sv", vendor + "axi/src/axi_mux.sv"] + files
        files += [p.relative_to(root).as_posix() for p in
                  (root / (vendor + "common_cells/include")).rglob("*.svh")]
        files += [p.relative_to(root).as_posix() for p in
                  (root / (vendor + "axi/include")).rglob("*.svh")]
        if args.crossbar:
            files += [vendor + "common_cells/src/" + name + ".sv" for name in (
                "addr_decode", "delta_counter", "counter", "deprecated/fifo_v2", "stream_register")]
            files += [vendor + "axi/src/" + name + ".sv" for name in (
                "axi_atop_filter", "axi_err_slv", "axi_demux", "axi_xbar")]
    files = list(dict.fromkeys(files))
    legacy = "verif/tb/storamic/tb_g6lc_storamic_ctrl_bridge.sv"
    hashes = {}
    for name in files:
        dest = source / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, dest)
        hashes[name] = hashlib.sha256(dest.read_bytes()).hexdigest()
    # MIT fixture channel types match the existing native control-bridge bench.
    original = (source / legacy).read_text(encoding="utf-8")
    definitions = original[original.index("  typedef struct packed {"):original.index("  logic clk")]
    header = source / "route-axi-types.svh"
    header.write_text("// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n" +
                      definitions, encoding="utf-8")
    hashes["generated:route-axi-types.svh"] = hashlib.sha256(header.read_bytes()).hexdigest()
    local_definitions = re.sub(r"\b(aw_t|ar_t|w_t|b_t|r_t|req_t|resp_t)\b",
                               lambda match: "local_" + match.group(0), definitions)
    local_definitions = re.sub(r"\bIdW\b", "4", local_definitions)
    local_header = source / "route-local-types.svh"
    local_header.write_text("// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n" +
                            local_definitions, encoding="utf-8")
    hashes["generated:route-local-types.svh"] = hashlib.sha256(local_header.read_bytes()).hexdigest()
    setup = source / "route-axi-setup.sv"
    setup.write_text('// Copyright 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n'
                     '`include "axi/typedef.svh"\n`include "axi/assign.svh"\n', encoding="utf-8")
    hashes["generated:route-axi-setup.sv"] = hashlib.sha256(setup.read_bytes()).hexdigest()
    verilator = Path(shutil.which("verilator") or parser.error("verilator unavailable")).resolve()
    if os.name == "posix":
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    report = {"qualification": False, "scope": "local-route-service", "status": "incomplete",
              "sources": hashes, "results": [],
              "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "verilator_version": subprocess.check_output([str(verilator), "--version"], text=True)}
    for tool in (verilator, verilator.with_name("verilator_bin")):
        if tool.is_file():
            report[str(tool)] = hashlib.sha256(tool.read_bytes()).hexdigest()

    def save():
        (out / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    save()
    try:
        # (enabled, masters, spill, native). NativeProfile uses the real ariane
        # crossbar dimensions with 3 concurrent requester ports; its adversarial
        # port-1/port-2 refusal is baked into the bench (no +oracle_negative).
        if args.native:
            builds = [(e, 3, 0, True) for e in (0, 1)]
        else:
            builds = [(e, m, s, False) for e, m, s in
                      ([(0, 3, 0), (1, 3, 0), (0, 3, 1), (1, 3, 1), (1, 2, 0)]
                       if args.interconnect else [(0, 3, 0), (1, 3, 0), (1, 2, 0)])]
        for enabled, masters, spill, native in builds:
            name = (f"native-enabled{enabled}" if native else
                    f"enabled{enabled}-masters{masters}-mux{int(args.interconnect)}"
                    f"-spill{spill}-xbar{int(args.crossbar)}")
            command = [str(verilator), "--binary", "--timing", "--assert", "-j", "2",
                       "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT", "-Werror-PINMISSING",
                       "--top-module", "tb_g6lc_storamic_checkpoint_route", "-I" + str(source),
                       "-I" + str(source / "vendor/pulp-platform/common_cells/include"),
                       "-I" + str(source / "vendor/pulp-platform/axi/include"),
                       "--Mdir", str(out / name), "-o", "test",
                       f"-GEnabled={enabled}", f"-GMasterCount={masters}",
                       f"-GUseMux={int(args.interconnect)}", f"-GSpillRequests={spill}",
                       f"-GUseXbar={int(args.crossbar)}",
                       f"-GNativeProfile={int(native)}",
                       "-GNativeMstPorts=16", "-GStoramicIdx=13",
                       *([str(source / "verif/tb/storamic/route_interconnect.vlt"),
                          str(setup)] if args.interconnect else []),
                       *[str(source / n) for n in files if n != legacy and n.endswith(".sv")
                         and not Path(n).name.startswith("formal_")]]
            (out / f"{name}-command.json").write_text(json.dumps(command), encoding="utf-8")
            with (out / f"{name}-build.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=600 if native else 300)
            for negative in ((False, True) if (masters == 3 and not native) else (False,)):
                label = name + ("-negative" if negative else "")
                result = subprocess.run([str(out / name / "test"),
                                         *(["+oracle_negative"] if negative else [])],
                                        capture_output=True, text=True, timeout=60)
                text = result.stdout + result.stderr
                (out / f"{label}.log").write_text(text, encoding="utf-8")
                marker = ("STORAMIC_CHECKPOINT_ROUTE_CONFIG" if masters != 3 else
                          "CHECKPOINT_ROUTE_FAIL negative-oracle" if negative else "CHECKPOINT_ROUTE_PASS")
                matched = marker in text and ((result.returncode != 0) if negative or masters != 3
                                               else result.returncode == 0)
                report["results"].append({"case": label, "matched": matched, "rc": result.returncode})
                save()
                if not matched:
                    raise RuntimeError(label)
        report["status"] = "pass"
    except (subprocess.SubprocessError, RuntimeError) as error:
        report["status"] = "fail"
        report["error"] = str(error)
        raise
    finally:
        save()


if __name__ == "__main__":
    main()
