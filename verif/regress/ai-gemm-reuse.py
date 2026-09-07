#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
import importlib.util
import os
from pathlib import Path
import signal
import sys

sys.dont_write_bytecode = True
BASIS_PATH = "verif/regress/ai-gemm-codec-basis.py"
SCRIPT_PATH = "verif/regress/ai-gemm-reuse.py"
_basis_dir = Path(os.environ["TH_DATA_DIR"]) if os.environ.get("TH_DATA_DIR") else Path(__file__).resolve().parent
_basis_spec = importlib.util.spec_from_file_location("ai_gemm_codec_basis", _basis_dir / Path(BASIS_PATH).name)
if _basis_spec is None or _basis_spec.loader is None:
    raise RuntimeError("cannot load the codec-basis manifest")
basis = importlib.util.module_from_spec(_basis_spec)
_basis_spec.loader.exec_module(basis)

TOP = "tb_g6lc_ai_gemm_concurrent"
POLICY = "corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv"
RUNNER = "verif/tb/ai_island/run-gemm-concurrent.sh"
SOURCES = tuple(
    added
    for source in basis.SOURCES
    for added in ((POLICY, source) if source.endswith("/g6lc_ai_fp_pkg.sv") else
                  (str(Path(source).with_name(TOP + ".sv")).replace("\\", "/"),)
                  if Path(source).stem == basis.TOP else (source,))
)
VENDOR = basis.VENDOR
INCLUDES = basis.INCLUDES
FORMATS = basis.FORMATS
MANIFEST = (*VENDOR, *SOURCES, *(header for header, _ in INCLUDES), RUNNER, BASIS_PATH, SCRIPT_PATH)
KNOBS = (
    ("engines", "N_ENGINES", (1, 2, 4), 1),
    ("channels", "NCH", (1, 2, 4, 8), 1),
    ("va_turbo", "VA_TURBO", (0, 1), 1),
    ("dot_pipe_float", "DOT_PIPE_FLOAT", (0, 1), 0),
    ("lanes", "PE_LANES", (8, 16, 32, 64), 8),
)
MARKER_RE = basis.re.compile(r"^(CONC|REUSE)(?:\b|_)")
PASS_RE = basis.re.compile(r"^PASS (?:tb_)?g6lc_ai_gemm_concurrent(?:\s|$)")
FAIL_RE = basis.re.compile(r"(?:^FAIL\b|%Error|Assertion failed|\bAborting\b)")
FIELD_RE = basis.re.compile(r"\b([A-Za-z_][A-Za-z_0-9]*)=([^\s]+)")


def validate_manifest(manifest=MANIFEST):
    names = {}
    for relative in manifest:
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts:
            raise RuntimeError("non-relative manifest entry: " + relative)
        name = path.name.casefold()
        if name in names:
            raise RuntimeError("flattened payload collision: " + names[name] + " / " + relative)
        names[name] = relative


def configuration(args):
    return {name: getattr(args, name) for name, _, _, _ in KNOBS}


def build_command(tool, root, mdir, args):
    command = [str(tool), "--binary", "--timing", "--assert", "-j", "2",
               "-Wno-fatal", "-Wno-TIMESCALEMOD", "-Wno-UNUSED", "-Wno-UNOPTFLAT",
               "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND", "-Wno-PINCONNECTEMPTY", "-Wno-CASEINCOMPLETE"]
    include_dirs = [Path(header).parent.parent for header, _ in INCLUDES]
    include_dirs += [Path(source).parent for source in SOURCES if Path(source).parent.name == "include"]
    command += ["-I" + str(root / directory) for directory in dict.fromkeys(include_dirs)]
    command += ["-G%s=%d" % (parameter, getattr(args, name)) for name, parameter, _, _ in KNOBS]
    command += [str(root / source) for source in (*VENDOR, *SOURCES)]
    return command + ["--top-module", TOP, "-Mdir", str(mdir), "-o", TOP]


def parse_output(text):
    result = {"conc_lines": [], "reuse_lines": [], "pass_lines": [], "failure_lines": [],
              "conc_records": [], "reuse_records": []}
    for line in text.splitlines():
        stripped = line.strip()
        match = MARKER_RE.match(stripped)
        if match:
            kind = match.group(1).lower()
            result[kind + "_lines"].append(line)
            fields = dict(FIELD_RE.findall(stripped))
            if fields and (kind == "reuse" or stripped.startswith("CONC ")):
                result[kind + "_records"].append(fields)
        if PASS_RE.match(stripped):
            result["pass_lines"].append(line)
        if FAIL_RE.search(stripped):
            result["failure_lines"].append(line)
    return result


def validate_output(text, args):
    result = parse_output(text)
    errors = []
    if result["failure_lines"]:
        errors.append("testbench reported a failure")
    if not result["conc_records"]:
        errors.append("no CONC measurement records")
    if not result["reuse_records"]:
        errors.append("no nonempty REUSE records")
    seen_formats = set()
    for record in result["conc_records"]:
        try:
            fmt = int(record["fmt"])
            if fmt not in FORMATS:
                raise ValueError("unsupported format")
            if int(record["eng"]) != args.engines:
                raise ValueError("engine count differs from requested configuration")
            if int(record["serial"]) <= 0 or int(record["concurrent"]) <= 0:
                raise ValueError("nonpositive cycle count")
            seen_formats.add(fmt)
        except (KeyError, ValueError) as error:
            errors.append("invalid CONC record: " + str(error))
    missing = sorted(set(FORMATS) - seen_formats)
    if missing:
        errors.append("missing CONC formats: " + ", ".join(FORMATS[fmt] for fmt in missing))
    if not result["pass_lines"]:
        errors.append("missing final testbench PASS")
    else:
        final = result["pass_lines"][-1].strip()
        last_marker = next((line.strip() for line in reversed(text.splitlines())
                            if MARKER_RE.match(line.strip()) or PASS_RE.match(line.strip())), "")
        if last_marker != final:
            errors.append("testbench PASS precedes the final CONC/REUSE record")
        fields = dict(FIELD_RE.findall(final))
        for key, expected in (("eng", args.engines), ("nch", args.channels),
                              ("lanes", args.lanes), ("va_turbo", args.va_turbo)):
            if fields.get(key) != str(expected):
                errors.append("final PASS does not confirm %s=%d" % (key, expected))
    result["formats_seen"] = [FORMATS[fmt] for fmt in sorted(seen_formats)]
    result["validation_errors"] = errors
    return result


def run_logged(command, name, cwd, out, timeout, report):
    command = list(map(str, command))
    entry = {"name": name, "command": command, "log": name + ".log", "timeout_seconds": timeout,
             "returncode": None, "timed_out": False}
    report["commands"].append(entry)
    process = None
    with (out / entry["log"]).open("wb") as log:
        try:
            process = basis.subprocess.Popen(command, cwd=cwd, stdout=log,
                                             stderr=basis.subprocess.STDOUT,
                                             stdin=basis.subprocess.DEVNULL,
                                             start_new_session=True)
            try:
                entry["returncode"] = process.wait(timeout=timeout)
            except basis.subprocess.TimeoutExpired:
                entry["timed_out"] = True
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                entry["returncode"] = process.wait()
        except OSError as error:
            entry["error"] = str(error)
            log.write((str(error) + "\n").encode("utf-8", errors="replace"))
        finally:
            log.flush()
    return entry


def check_command(entry):
    if entry.get("error"):
        raise RuntimeError(entry["name"] + ": " + entry["error"])
    if entry["timed_out"]:
        raise RuntimeError("%s timed out after %ds; see %s" %
                           (entry["name"], entry["timeout_seconds"], entry["log"]))
    if entry["returncode"] != 0:
        raise RuntimeError("%s failed (rc=%s); see %s" %
                           (entry["name"], entry["returncode"], entry["log"]))


def write_json(path, value):
    path.write_text(basis.json.dumps(value, indent=2) + "\n", encoding="utf-8")


def remote(args):
    required = ("TH_DATA_DIR", "TH_OUT_DIR", "TH_RUN_DIR", "TH_PROXY_TAG")
    if os.name != "posix" or any(not os.environ.get(name) for name in required):
        raise RuntimeError("RTL execution requires the remote testharness py environment")
    data = Path(os.environ["TH_DATA_DIR"]).resolve()
    parent = Path(os.environ["TH_OUT_DIR"]).resolve()
    if not data.is_dir() or not parent.is_dir():
        raise RuntimeError("proxy data/output parents must exist")
    out = Path(basis.tempfile.mkdtemp(prefix="gemm-reuse-", dir=parent))
    snapshot = out / "sources"
    work = None
    report = {"schema": "g6lc.gemm-reuse.v1", "status": "RUNNING",
              "tag": os.environ["TH_PROXY_TAG"], "configuration": configuration(args),
              "default_shape": {"m": 8, "n": 8, "k": 16}, "formats": FORMATS,
              "scope": "RTL simulation on the class-0 SRAM memory model, not silicon or MAC/s",
              "build_mode": "direct-verilator", "manifest": list(MANIFEST), "sha256": {},
              "commands": [], "conc_lines": [], "reuse_lines": [], "pass_lines": []}
    try:
        validate_manifest()
        snapshot.mkdir()
        for relative in MANIFEST:
            original = data / Path(relative).name
            if not original.is_file():
                raise RuntimeError("missing remote manifest input: " + str(original))
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            basis.shutil.copy2(original, target)
            report["sha256"][relative] = basis.hashlib.sha256(target.read_bytes()).hexdigest()
        if report["sha256"][SCRIPT_PATH] != basis.hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
            raise RuntimeError("executed runner differs from the uploaded manifest snapshot")
        write_json(out / "manifest.json", {"files": list(MANIFEST), "sha256": report["sha256"]})
        work = Path(basis.tempfile.mkdtemp(prefix="g6lc-gemm-reuse-"))
        tool = next((candidate for candidate in
                     (basis.shutil.which("verilator"),
                      "/opt/testharness/toolchains/verilator-v5.008/bin/verilator",
                      "/root/tools/verilator-v5.008/bin/verilator")
                     if candidate and Path(candidate).is_file()), None)
        if tool is None:
            raise RuntimeError("no verilator on the remote host; SKIP is not a passing regression")
        version = run_logged([tool, "--version"], "verilator-version", snapshot, out, 30, report)
        check_command(version)
        report["verilator"] = (out / version["log"]).read_text(encoding="utf-8", errors="replace").strip()
        mdir = work / "obj_dir"
        build = run_logged(build_command(tool, snapshot, mdir, args), "build", snapshot, out,
                           args.build_timeout, report)
        check_command(build)
        simulation = run_logged([mdir / TOP], "simulation", snapshot, out, args.sim_timeout, report)
        text = (out / simulation["log"]).read_text(encoding="utf-8", errors="replace")
        report.update(validate_output(text, args))
        check_command(simulation)
        if report["validation_errors"]:
            raise RuntimeError("; ".join(report["validation_errors"]))
        report["status"] = "PASS"
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        print("GEMM_REUSE_FAIL " + str(error), file=sys.stderr, flush=True)
    finally:
        write_json(out / "manifest.json", {"files": list(MANIFEST), "sha256": report["sha256"]})
        write_json(out / "results.json", report)
        if work is not None:
            basis.shutil.rmtree(work, ignore_errors=True)
    print("GEMM_REUSE %s results=%s" % (report["status"], out / "results.json"), flush=True)
    return 0 if report["status"] == "PASS" else 1


def proxy_path(path):
    if os.name != "nt":
        return str(path)
    if len(path.drive) != 2 or path.drive[1] != ":":
        raise RuntimeError("WSL proxy requires a drive-qualified input: " + str(path))
    return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]


def dispatch(args):
    validate_manifest()
    root = Path(__file__).resolve().parents[2]
    proxy = root / "verif/regress/remote/testharness_proxy.py"
    files = [root / source for source in MANIFEST]
    for path in [proxy, *files]:
        if not path.is_file():
            raise RuntimeError("required input missing: " + str(path))
    tag = ("ai-gemm-reuse-" + basis.datetime.datetime.now(basis.datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
           + basis.uuid.uuid4().hex[:12])
    launcher = ["wsl.exe", "--exec", "python3", "-B"] if os.name == "nt" else [sys.executable, "-B"]
    command = [*launcher, proxy_path(proxy), "py", proxy_path(Path(__file__).resolve()),
               "--tag", tag, "--threads", "1", "--pull"]
    settings = configuration(args)
    settings.update(build_timeout=args.build_timeout, sim_timeout=args.sim_timeout)
    for name, value in settings.items():
        command += ["--env", "AI_GEMM_CONC_%s=%s" % (name.upper(), value)]
    command += ["--env", "PYTHONDONTWRITEBYTECODE=1"]
    for path in files:
        command += ["--data", proxy_path(path)]
    print("PROXY_ONLY " + basis.shlex.join(command), flush=True)
    print("PULL_OUTPUT " + str(root / "remote-runs" / tag / "output"), flush=True)
    if args.dry_run:
        print("REMOTE_BUILD " + basis.shlex.join(build_command("verilator", Path("SNAPSHOT_ROOT"),
                                                              Path("REMOTE_WORK/obj_dir"), args)), flush=True)
        return 0
    return basis.subprocess.run(command, cwd=root, check=False).returncode


def self_test():
    compile(Path(__file__).read_bytes(), SCRIPT_PATH, "exec")
    compile(Path(basis.__file__).read_bytes(), BASIS_PATH, "exec")
    validate_manifest()
    assert VENDOR is basis.VENDOR and INCLUDES is basis.INCLUDES and FORMATS is basis.FORMATS
    assert SOURCES.count(POLICY) == 1 and SOURCES[-1].endswith(TOP + ".sv")
    assert not any(Path(source).stem == basis.TOP for source in SOURCES)
    args = basis.argparse.Namespace(**{name: default for name, _, _, default in KNOBS})
    conc = ["CONC fmt=%d shared_b=0 eng=1 macs_total=1024 serial=101 concurrent=100" % fmt for fmt in FORMATS]
    reuse = "REUSE fmt=0 case=warm hits=1 r_beats=16"
    passed = "PASS g6lc_ai_gemm_concurrent class=0 nch=1 eng=1 lanes=8 va_turbo=1"
    text = "\n".join([*conc, reuse, passed, "- testbench.sv:1: Verilog $finish"])
    good = validate_output(text, args)
    assert not good["validation_errors"] and good["reuse_lines"] == [reuse]
    assert len(good["formats_seen"]) == len(FORMATS)
    bad_texts = ("", "SKIP no verilator", passed, text.replace(reuse, ""),
                 text.replace(reuse, "REUSE"), text.replace(passed, ""),
                 text.replace(conc[0], ""), text.replace("eng=1", "eng=2"),
                 text.replace("nch=1", "nch=2"), text.replace("lanes=8", "lanes=16"),
                 text.replace("va_turbo=1", "va_turbo=0"),
                 text.replace("serial=101", "serial=0"), text + "\nFAIL arithmetic",
                 text + "\n%Error: assertion", text + "\n" + reuse)
    for bad in bad_texts:
        assert validate_output(bad, args)["validation_errors"], bad
    assert parse_output("CONC_PMU fmt=0 eng_cycles=100")["conc_records"] == []
    assert parse_output("REUSE_CHECK case=invalidate hits=0")["reuse_lines"]
    for manifest in (("a/x.sv", "b/x.sv"), ("../escape.sv",)):
        try:
            validate_manifest(manifest)
        except RuntimeError:
            pass
        else:
            raise AssertionError("invalid manifest accepted")
    command = build_command("verilator", Path("snapshot"), Path("obj_dir"), args)
    assert "--assert" in command and command[command.index("-j") + 1] == "2"
    for name, parameter, choices, _ in KNOBS:
        for value in choices:
            setattr(args, name, value)
            assert "-G%s=%d" % (parameter, value) in build_command("verilator", Path("s"), Path("o"), args)
    for entry in ({"name": "build", "log": "build.log", "returncode": 1, "timed_out": False},
                  {"name": "simulation", "log": "simulation.log", "returncode": 0,
                   "timed_out": True, "timeout_seconds": 1}):
        try:
            check_command(entry)
        except RuntimeError:
            pass
        else:
            raise AssertionError("failed command accepted")
    print("PASS ai-gemm-reuse self-test: syntax, manifest, commands, markers and negative controls")
    return 0


def main(argv=None):
    parser = basis.argparse.ArgumentParser(description="Remote-only GSys LibreCore GEMM reuse regression; one configuration per invocation")
    aliases = {"va_turbo": ["--va"], "dot_pipe_float": ["--dpf"], "lanes": ["--lane"]}
    for name, _, choices, default in KNOBS:
        parser.add_argument("--" + name.replace("_", "-"), *aliases.get(name, []),
                            dest=name, type=int, choices=choices,
                            default=os.environ.get("AI_GEMM_CONC_" + name.upper(), str(default)))
    for name, default in (("build_timeout", 1800), ("sim_timeout", 300)):
        parser.add_argument("--" + name.replace("_", "-"), type=int,
                            default=os.environ.get("AI_GEMM_CONC_" + name.upper(), str(default)),
                            help="positive timeout in seconds (default %d)" % default)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="print commands without dispatching or writing files")
    mode.add_argument("--self-test", action="store_true", help="no-write local syntax and parser checks; no RTL execution")
    args = parser.parse_args(argv)
    for name, _, choices, _ in KNOBS:
        if getattr(args, name) not in choices:
            parser.error("invalid AI_GEMM_CONC_" + name.upper())
    if min(args.build_timeout, args.sim_timeout) <= 0:
        parser.error("timeouts must be positive")
    if args.self_test:
        return self_test()
    if os.environ.get("TH_DATA_DIR"):
        if args.dry_run:
            parser.error("--dry-run is a local dispatch option")
        return remote(args)
    return dispatch(args)


if __name__ == "__main__":
    sys.exit(main())
