#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Run install-verilator-g6lc.sh remotely with VLT_PGO=1 against the staged
fork checkout and hyp8 PGO repo uploaded via --data.

The stock script computes PIN via `git -C $REPO ls-tree HEAD tools/verilator`
under `set -euo pipefail`; an un-populated .git makes that pipeline return
128 and aborts before any output. This runner therefore initialises throwaway
git repos: repo-pgo gets a commit with NO tools/verilator gitlink (ls-tree
prints nothing, rc=0 -> PIN empty -> checkout skipped, $SRC used as-is), and
src/verilator-g6lc gets its own commit whose SHA is exported as VLT_PIN so
the script's fetch||true + checkout is a harmless no-op on HEAD.

Env contract:
  REPO_ROOT  -> /opt/testharness/repo-pgo   (moved from data/hyp8-pgo-repo)
  VLT_SRC    -> /opt/testharness/src/verilator-g6lc
  VLT_PREFIX -> /opt/testharness/toolchains/verilator-v5.008-g6lc
  VLT_PGO    -> 1
  VLT_PGO_TRAIN_TARGET -> g6lc64_hyp8_mc
  VLT_PGO_TRAIN_THREADS -> 4
  JOBS       -> nproc
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path("/opt/testharness")
DATA = Path("data")
OUT = Path("output").resolve()
OUT.mkdir(exist_ok=True)

REPO = ROOT / "repo-pgo"
SRC = ROOT / "src" / "verilator-g6lc"
PREFIX = ROOT / "toolchains" / "verilator-v5.008-g6lc"
SCRIPT = REPO / "build-platform" / "scripts" / "install-verilator-g6lc.sh"
GIT_ID = ["-c", "user.email=devin@local", "-c", "user.name=devin"]


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def git_init_commit(path: Path) -> str:
    if not (path / ".git").exists():
        p = run(["git", "init", "-q"], cwd=path)
        assert p.returncode == 0, p.stderr
    p = run(["git", "add", "-A"], cwd=path)
    assert p.returncode == 0, p.stderr
    p = run(["git", *GIT_ID, "commit", "-qm", "stage", "--allow-empty"], cwd=path)
    # commit may be a no-op on rerun; HEAD still resolves
    p = run(["git", "rev-parse", "HEAD"], cwd=path)
    assert p.returncode == 0, p.stderr
    return p.stdout.strip()


def sh(cmd: str, env: dict, log) -> int:
    p = subprocess.run(["bash", "-lc", cmd], env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write(p.stdout)
    log.flush()
    print(p.stdout[-4000:] if len(p.stdout) > 4000 else p.stdout)
    return p.returncode


def main() -> int:
    t0 = time.time()
    report = {"steps": []}

    src_repo = DATA / "hyp8-pgo-repo"
    if src_repo.is_dir() and not REPO.exists():
        shutil.move(str(src_repo), str(REPO))
        report["steps"].append({"step": "repo", "action": "moved"})
    elif REPO.exists():
        report["steps"].append({"step": "repo", "action": "present"})
    else:
        print("FATAL: no hyp8-pgo-repo data and no existing repo-pgo", file=sys.stderr)
        return 2

    for need in (REPO / "verif/regress/remote/hyp8/Flist.hyp8_mc_sim",
                 REPO / "verif/regress/remote/hyp8/hyp8-build-harness.sh",
                 REPO / "build-platform/scripts/verilator-split-loops.vlt",
                 SRC / "src/V3Const.cpp",
                 SCRIPT):
        if not need.exists():
            print(f"FATAL: missing {need}", file=sys.stderr)
            return 2

    # throwaway git identities so the script's set -euo pipefail survives
    repo_head = git_init_commit(REPO)
    src_head = git_init_commit(SRC)
    # ls-tree sanity: must print nothing for tools/verilator -> PIN empty
    p = run(["git", "ls-tree", "HEAD", "tools/verilator"], cwd=REPO)
    report["steps"].append({"step": "preflight", "ok": True,
                            "repo_head": repo_head, "src_head": src_head,
                            "ls_tree_rc": p.returncode,
                            "ls_tree_out": p.stdout.strip()})

    env = dict(os.environ)
    env.update({
        "REPO_ROOT": str(REPO),
        "VLT_SRC": str(SRC),
        "VLT_PREFIX": str(PREFIX),
        "VLT_PIN": src_head,
        "VLT_PGO": "1",
        "VLT_PGO_TRAIN_TARGET": "g6lc64_hyp8_mc",
        "VLT_PGO_TRAIN_THREADS": "4",
        "JOBS": str(os.cpu_count() or 8),
    })

    log = open(OUT / "vlt-pgo-build.log", "w")
    rc = sh(f"source {ROOT}/env.sh 2>/dev/null; bash {SCRIPT}", env=env, log=log)
    log.close()
    report["steps"].append({"step": "install", "rc": rc,
                            "seconds": round(time.time() - t0, 1)})

    ver = subprocess.run(["bash", "-lc",
                          f"{PREFIX}/bin/verilator --version 2>&1 | head -1; "
                          f"sha256sum {PREFIX}/bin/verilator_bin 2>/dev/null | cut -d' ' -f1; "
                          f"ls {PREFIX}/runtime/bin/ 2>/dev/null; "
                          f"{PREFIX}/bin/verilator --help 2>/dev/null | grep -c 'prof-pgo\\|prof-exec' || true"],
                         capture_output=True, text=True)
    report["verify"] = ver.stdout.strip()
    (OUT / "pgo-build-report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2)[:3000])
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
