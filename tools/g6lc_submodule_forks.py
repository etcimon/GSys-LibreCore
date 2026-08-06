#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon / GlobecSys Inc.
"""
Push *isolated* G6LC submodule changes to github.com/etcimon forks and pin
the monorepo gitlinks to those forks.

Problem this solves
-------------------
Dirty submodule worktrees are easy to lose and disastrous to absorb as plain
directories (huge commits, wrong history). Intermediate monorepo-only commits
on a fork (e.g. temporary victim-policy experiments) also obscure the real
LibreCore delta. This tool:

  1. Ensures etcimon forks of the upstream submodule remotes exist
  2. Isolates the net local delta vs a clean upstream-ancestor base SHA
  3. Stages *only* those intended paths (never whole-tree rsync / ``git add -A``)
  4. Rewrites ``g6lc`` as a single commit on top of that base (optional)
  5. Skips push when the remote tip already has the same intended content
  6. Updates monorepo ``.gitmodules`` URLs + ``160000`` gitlink pins

Default targets (LibreCore residual stack)
------------------------------------------

  | monorepo path                 | upstream                    | fork                |
  |-------------------------------|-----------------------------|---------------------|
  | core/cache_subsystem/hpdcache | openhwgroup/cv-hpdcache     | etcimon/cv-hpdcache |
  | verif/core-v-verif            | openhwgroup/core-v-verif    | etcimon/core-v-verif|
  | verif/sim/dv                  | google/riscv-dv             | etcimon/riscv-dv   |

Isolation model
---------------
  base_sha     = last pure upstream commit the monorepo actually depended on
                 (openhw/google ancestor — NOT an intermediate local tip)
  content_ref  = tree that holds the desired final file bytes
                 (usually current origin/g6lc, or a monorepo absorb commit)
  intended     = paths whose blob at content_ref differs from base_sha
                 (auto via ``isolate``, or explicit allowlist)

Examples
--------
  python tools/g6lc_submodule_forks.py status
  python tools/g6lc_submodule_forks.py isolate              # discover net paths
  python tools/g6lc_submodule_forks.py isolate --write-config .g6lc-forks.json
  python tools/g6lc_submodule_forks.py sync --rewrite       # single-commit g6lc
  python tools/g6lc_submodule_forks.py sync --rewrite --commit-monorepo --push-monorepo
  python tools/g6lc_submodule_forks.py point --from-remote
  python tools/g6lc_submodule_forks.py verify
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Sequence
from urllib.parse import urlparse


# ---------------------------------------------------------------------------
# Default G6LC fork plan
#
# base_sha is the *upstream ancestor* (openhw/google), not an intermediate
# monorepo-only commit. intended_paths are the net delta vs that base.
# content_ref (optional) is where final bytes are read from during rewrite;
# default is the current remote g6lc tip.
# ---------------------------------------------------------------------------

DEFAULT_TARGETS: list[dict] = [
    {
        "name": "cv-hpdcache",
        "path": "core/cache_subsystem/hpdcache",
        "upstream": "https://github.com/openhwgroup/cv-hpdcache.git",
        "upstream_gh": "openhwgroup/cv-hpdcache",
        "fork_gh": "etcimon/cv-hpdcache",
        "fork_url": "https://github.com/etcimon/cv-hpdcache.git",
        "branch": "g6lc",
        # Last openhw pin before LibreCore-only commits (735da55/9e5c953/…).
        # Net G6LC delta vs this base is the 5 RTL files below (no victim_rrip
        # churn — those intermediate edits cancel out vs openhw).
        "base_sha": "b25a1605f5bb1719046e372b0acad3ca9cb7ff42",
        "extra_fetch": [],
        "intended_paths": [
            "rtl/src/hpdcache_amo.sv",
            "rtl/src/hpdcache_ctrl.sv",
            "rtl/src/hpdcache_pkg.sv",
            "rtl/src/hpdcache_uncached.sv",
            "rtl/src/utils/hpdcache_mem_to_axi_write.sv",
        ],
        "delete_paths": [],
        "include_globs": [
            "rtl/**/*.sv",
            "rtl/**/*.svh",
            "rtl/**/*.Flist",
            "rtl/**/*.flist",
        ],
        "exclude_globs": [
            "*.pdf",
            "*.docx",
            "*.o",
            "*.a",
            "*.so",
            "*.exe",
            "*.bin",
            "docs/**",
            "rtl/tb/**",
            "rtl/tests/**",
            ".github/**",
            "**/.git/**",
        ],
        "commit_message": (
            "G6LC: HPDCache AMOCAS/Zacas + uncached path bring-up.\n\n"
            "Isolated LibreCore delta on top of openhw b25a160 "
            "(async-reset pin). Single-commit rewrite — no intermediate "
            "SRRIP/victim experiments. Touches only AMO/ctrl/pkg/uncached "
            "and the AXI write util."
        ),
    },
    {
        "name": "core-v-verif",
        "path": "verif/core-v-verif",
        "upstream": "https://github.com/openhwgroup/core-v-verif.git",
        "upstream_gh": "openhwgroup/core-v-verif",
        "fork_gh": "etcimon/core-v-verif",
        "fork_url": "https://github.com/etcimon/core-v-verif.git",
        "branch": "g6lc",
        "base_sha": "b3149ab0da3ac8bf2179e24595a4b7a860b668ff",
        "extra_fetch": [],
        "intended_paths": [
            "vendor/riscv/riscv-isa-sim/riscv/Proc.cc",
            "vendor/riscv/riscv-isa-sim/riscv/Simulation.cc",
            "vendor/riscv/riscv-isa-sim/spike_main/spike.cc",
        ],
        "delete_paths": [],
        "include_globs": [
            "vendor/riscv/riscv-isa-sim/**/*.cc",
            "vendor/riscv/riscv-isa-sim/**/*.h",
            "vendor/riscv/riscv-isa-sim/**/*.c",
        ],
        "exclude_globs": ["*.o", "*.a", "*.so", "docs/**", ".github/**"],
        "commit_message": (
            "G6LC: Spike Proc/Simulation/spike patches for LibreCore dual-hart.\n\n"
            "Isolated residual-verification edits only (not full tree absorb)."
        ),
    },
    {
        "name": "riscv-dv",
        "path": "verif/sim/dv",
        "upstream": "https://github.com/google/riscv-dv.git",
        "upstream_gh": "google/riscv-dv",
        "fork_gh": "etcimon/riscv-dv",
        "fork_url": "https://github.com/etcimon/riscv-dv.git",
        "branch": "g6lc",
        "base_sha": "7e54b678ab7499040336255550cdbd99ae887431",
        "extra_fetch": [],
        "intended_paths": [
            "scripts/lib.py",
        ],
        "delete_paths": [],
        "include_globs": ["scripts/**/*.py"],
        "exclude_globs": [],
        "commit_message": (
            "G6LC: riscv-dv scripts/lib.py fixes for LibreCore regress.\n\n"
            "Isolated monorepo script fix only (not full tree absorb)."
        ),
    },
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


class CmdError(RuntimeError):
    pass


def run(
    args: Sequence[str],
    *,
    cwd: Optional[Path] = None,
    check: bool = True,
    capture: bool = True,
    input_bytes: Optional[bytes] = None,
    env: Optional[dict] = None,
) -> subprocess.CompletedProcess:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    merged.setdefault("GIT_TERMINAL_PROMPT", "0")
    r = subprocess.run(
        list(args),
        cwd=str(cwd) if cwd else None,
        input=input_bytes,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        env=merged,
    )
    if check and r.returncode != 0:
        out = (r.stdout or b"").decode("utf-8", "replace")
        err = (r.stderr or b"").decode("utf-8", "replace")
        raise CmdError(
            f"command failed ({r.returncode}): {' '.join(args)}\n"
            f"stdout:\n{out}\nstderr:\n{err}"
        )
    return r


def run_out(args: Sequence[str], *, cwd: Optional[Path] = None) -> str:
    return run(args, cwd=cwd).stdout.decode("utf-8", "replace").strip()


def which(name: str) -> Optional[str]:
    return shutil.which(name)


def monorepo_root(start: Optional[Path] = None) -> Path:
    here = (start or Path.cwd()).resolve()
    r = run(["git", "rev-parse", "--show-toplevel"], cwd=here, check=False)
    if r.returncode != 0:
        raise CmdError("not inside a git repository")
    return Path(r.stdout.decode().strip())


def gitlink_sha(repo: Path, rel: str) -> Optional[str]:
    line = run_out(["git", "ls-files", "-s", "--", rel], cwd=repo)
    if not line:
        return None
    parts = line.split()
    if len(parts) >= 2 and parts[0] == "160000":
        return parts[1]
    return None


def submodule_git_dir(repo: Path, rel: str) -> Optional[Path]:
    mod = repo / ".git" / "modules" / Path(rel)
    if (mod / "HEAD").exists() or (mod / "objects").exists():
        return mod
    wt = repo / rel
    gitfile = wt / ".git"
    if gitfile.is_file():
        text = gitfile.read_text(encoding="utf-8", errors="replace").strip()
        m = re.match(r"gitdir:\s*(.+)", text)
        if m:
            p = Path(m.group(1))
            if not p.is_absolute():
                p = (wt / p).resolve()
            return p
    if (wt / ".git").is_dir():
        return wt / ".git"
    return None


def path_excluded(rel: str, globs: list[str]) -> bool:
    rel = rel.replace("\\", "/")
    return any(_glob_match(g.replace("\\", "/"), rel) for g in globs)


def path_included(rel: str, globs: list[str]) -> bool:
    """Empty include list => allow all (then exclude applies)."""
    if not globs:
        return True
    rel = rel.replace("\\", "/")
    return any(_glob_match(g.replace("\\", "/"), rel) for g in globs)


def _glob_match(pattern: str, path: str) -> bool:
    i = 0
    out = ["^"]
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    out.append("$")
    return re.match("".join(out), path) is not None


def porcelain_paths(
    repo: Path, rel_root: str, *, exclude_globs: Optional[list[str]] = None
) -> tuple[list[str], list[str]]:
    gd = submodule_git_dir(repo, rel_root)
    wt = repo / rel_root
    if gd is None or not wt.is_dir():
        return [], []
    out = run_out(
        [
            "git",
            "--git-dir",
            str(gd),
            "--work-tree",
            str(wt),
            "status",
            "--porcelain",
            "-uall",
        ],
        cwd=wt,
    )
    mod: list[str] = []
    deleted: list[str] = []
    ex = exclude_globs or []
    for line in out.splitlines():
        if len(line) < 4:
            continue
        code, path = line[:2], line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        path = path.strip().strip('"').replace("\\", "/")
        if path_excluded(path, ex):
            continue
        if code.strip().startswith("D") or code[0] == "D" or code[1] == "D":
            deleted.append(path)
        else:
            mod.append(path)
    return mod, deleted


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def content_fingerprint(files: dict[str, bytes], deletes: list[str]) -> str:
    h = hashlib.sha256()
    for p in sorted(files):
        h.update(b"W:")
        h.update(p.encode())
        h.update(b"\0")
        h.update(hashlib.sha256(files[p]).digest())
    for p in sorted(set(deletes)):
        h.update(b"D:")
        h.update(p.encode())
        h.update(b"\0")
    return h.hexdigest()[:16]


def normalize_github_url(url: str) -> str:
    url = url.strip().rstrip("/")
    core = url[:-4] if url.endswith(".git") else url
    m = re.match(r"git@github\.com:([^/]+)/(.+)$", core)
    if m:
        return f"https://github.com/{m.group(1)}/{m.group(2)}.git"
    m = re.match(r"https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?$", core)
    if m:
        return f"https://github.com/{m.group(1)}/{m.group(2)}.git"
    return url if url.endswith(".git") else url + ".git"


def is_etcimon_url(url: str) -> bool:
    try:
        p = urlparse(normalize_github_url(url))
        return p.netloc == "github.com" and p.path.startswith("/etcimon/")
    except Exception:
        return "github.com/etcimon/" in url


# ---------------------------------------------------------------------------
# Target model
# ---------------------------------------------------------------------------


@dataclass
class Target:
    name: str
    path: str
    upstream: str
    upstream_gh: str
    fork_gh: str
    fork_url: str
    branch: str
    base_sha: str
    commit_message: str
    intended_paths: list[str] = field(default_factory=list)
    delete_paths: list[str] = field(default_factory=list)
    extra_fetch: list[str] = field(default_factory=list)
    exclude_globs: list[str] = field(default_factory=list)
    include_globs: list[str] = field(default_factory=list)
    # Optional monorepo commit that holds intended trees under path/
    source_commit: Optional[str] = None
    # Optional ref/sha in the fork clone to read final content from
    content_ref: Optional[str] = None

    @staticmethod
    def from_dict(d: dict) -> "Target":
        known = set(Target.__dataclass_fields__)
        return Target(**{k: d[k] for k in d if k in known})  # type: ignore[arg-type]

    def to_dict(self) -> dict:
        d = {
            "name": self.name,
            "path": self.path,
            "upstream": self.upstream,
            "upstream_gh": self.upstream_gh,
            "fork_gh": self.fork_gh,
            "fork_url": self.fork_url,
            "branch": self.branch,
            "base_sha": self.base_sha,
            "intended_paths": list(self.intended_paths),
            "delete_paths": list(self.delete_paths),
            "extra_fetch": list(self.extra_fetch),
            "include_globs": list(self.include_globs),
            "exclude_globs": list(self.exclude_globs),
            "commit_message": self.commit_message,
        }
        if self.content_ref:
            d["content_ref"] = self.content_ref
        if self.source_commit:
            d["source_commit"] = self.source_commit
        return d


# ---------------------------------------------------------------------------
# Fork / clone / isolation
# ---------------------------------------------------------------------------


def ensure_fork(t: Target, *, dry_run: bool) -> None:
    if not which("gh"):
        raise CmdError("`gh` CLI not found; install GitHub CLI and `gh auth login`")
    view = run(["gh", "repo", "view", t.fork_gh], check=False)
    if view.returncode == 0:
        print(f"  fork ok: {t.fork_gh}")
        return
    print(f"  creating fork {t.upstream_gh} -> {t.fork_gh}")
    if dry_run:
        return
    fork_name = t.fork_gh.split("/", 1)[1]
    run(
        [
            "gh",
            "repo",
            "fork",
            t.upstream_gh,
            "--fork-name",
            fork_name,
            "--default-branch-only",
        ],
        check=True,
        capture=True,
    )


def monorepo_blob(repo: Path, commit: str, mono_rel: str) -> Optional[bytes]:
    rev = f"{commit}:{mono_rel.replace(chr(92), '/')}"
    r = run(["git", "show", rev], cwd=repo, check=False)
    if r.returncode != 0:
        return None
    return r.stdout


def worktree_blob(repo: Path, t: Target, sub_rel: str) -> Optional[bytes]:
    fp = repo / t.path / sub_rel
    if fp.is_file():
        return fp.read_bytes()
    return None


def blob_at(clone: Path, rev: str, path: str) -> Optional[bytes]:
    r = run(["git", "show", f"{rev}:{path}"], cwd=clone, check=False)
    if r.returncode != 0:
        return None
    return r.stdout


def remote_branch_sha(t: Target) -> str:
    out = run_out(["git", "ls-remote", t.fork_url, f"refs/heads/{t.branch}"])
    if not out:
        raise CmdError(f"no remote branch {t.fork_gh}@{t.branch}")
    return out.split()[0]


def modules_candidates(repo: Path, t: Target) -> list[Path]:
    cands: list[Path] = []
    env_key = f"G6LC_{t.name.upper().replace('-', '_')}_GITDIR"
    if os.environ.get(env_key):
        cands.append(Path(os.environ[env_key]))
    if os.environ.get("G6LC_HPDCACHE_GITDIR") and t.name == "cv-hpdcache":
        cands.append(Path(os.environ["G6LC_HPDCACHE_GITDIR"]))
    cands.append(repo / ".git" / "modules" / Path(t.path))
    cands.append(repo / ".git" / "modules" / t.name)
    gd = submodule_git_dir(repo, t.path)
    if gd:
        cands.append(gd)
    return [c for c in cands if c and Path(c).exists()]


def ensure_object(clone: Path, sha: str, t: Target, repo: Path) -> None:
    r = run(["git", "cat-file", "-t", sha], cwd=clone, check=False)
    if r.returncode == 0:
        return
    for remote in ("origin", "upstream"):
        run(["git", "fetch", remote, sha], cwd=clone, check=False)
        r = run(["git", "cat-file", "-t", sha], cwd=clone, check=False)
        if r.returncode == 0:
            return
    for extra in t.extra_fetch:
        run(["git", "fetch", extra, sha], cwd=clone, check=False)
    for cand in modules_candidates(repo, t):
        run(["git", "fetch", str(cand), sha], cwd=clone, check=False)
        r = run(["git", "cat-file", "-t", sha], cwd=clone, check=False)
        if r.returncode == 0:
            print(f"  fetched {sha[:12]} from {cand}")
            return
    # monorepo may store the submodule commit as a gitlink object only — try
    # fetching the monorepo itself if it has the commit (rare)
    run(["git", "fetch", str(repo), sha], cwd=clone, check=False)
    r = run(["git", "cat-file", "-t", sha], cwd=clone, check=False)
    if r.returncode == 0:
        return
    raise CmdError(
        f"{t.name}: object {sha} not found after fetch; "
        f"set G6LC_{t.name.upper().replace('-', '_')}_GITDIR or push base first"
    )


def prepare_clone(
    t: Target, work_dir: Path, repo: Path, *, dry_run: bool, reuse: bool
) -> Path:
    dest = work_dir / t.name
    if dry_run:
        return dest
    work_dir.mkdir(parents=True, exist_ok=True)

    if reuse and dest.exists() and ((dest / ".git").exists() or (dest / ".git").is_file()):
        print(f"  reuse clone {dest}")
        run(["git", "remote", "set-url", "origin", t.fork_url], cwd=dest, check=False)
        run(["git", "fetch", "origin"], cwd=dest, check=False)
        run(["git", "remote", "add", "upstream", t.upstream], cwd=dest, check=False)
        run(["git", "remote", "set-url", "upstream", t.upstream], cwd=dest, check=False)
        run(["git", "fetch", "upstream", "--tags"], cwd=dest, check=False)
    else:
        if dest.exists():
            shutil.rmtree(dest, ignore_errors=True)
        print(f"  clone {t.fork_url} -> {dest}")
        run(["git", "clone", t.fork_url, str(dest)])
        run(["git", "remote", "add", "upstream", t.upstream], cwd=dest, check=False)
        run(["git", "fetch", "upstream", "--tags"], cwd=dest, check=False)

    ensure_object(dest, t.base_sha, t, repo)
    return dest


def name_status(clone: Path, base: str, tip: str) -> list[tuple[str, str]]:
    """Return list of (status, path) for base..tip."""
    out = run_out(["git", "diff", "--name-status", base, tip], cwd=clone)
    rows: list[tuple[str, str]] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status = parts[0].strip()
        # renames: R100\told\tnew
        path = parts[-1].strip().replace("\\", "/")
        rows.append((status[0], path))
    return rows


def filter_status_rows(
    rows: list[tuple[str, str]], t: Target
) -> tuple[list[str], list[str]]:
    """Apply include/exclude globs → (modified_or_added, deleted)."""
    mod: list[str] = []
    deleted: list[str] = []
    for status, path in rows:
        if path_excluded(path, t.exclude_globs):
            continue
        if not path_included(path, t.include_globs):
            continue
        if status == "D":
            deleted.append(path)
        else:
            # M, A, C, R, T, …
            mod.append(path)
    return sorted(set(mod)), sorted(set(deleted))


def isolate_paths(
    clone: Path, t: Target, content_ref: str
) -> tuple[list[str], list[str], str]:
    """
    Discover intended paths as net delta of content_ref vs base_sha,
    filtered by include/exclude globs.
    Returns (intended_paths, delete_paths, note).
    """
    ensure_object(clone, t.base_sha, t, monorepo_root())
    # content_ref may already be local
    r = run(["git", "cat-file", "-t", content_ref], cwd=clone, check=False)
    if r.returncode != 0:
        run(["git", "fetch", "origin", content_ref], cwd=clone, check=False)
    rows = name_status(clone, t.base_sha, content_ref)
    raw_n = len(rows)
    mod, deleted = filter_status_rows(rows, t)
    note = (
        f"base={t.base_sha[:12]} content={content_ref[:12]} "
        f"raw_delta={raw_n} kept_mod={len(mod)} kept_del={len(deleted)}"
    )
    return mod, deleted, note


def resolve_intended(
    repo: Path,
    t: Target,
    *,
    prefer_dirty: bool,
    work_dir: Path,
    clone: Optional[Path] = None,
    content_ref: Optional[str] = None,
) -> tuple[dict[str, bytes], list[str], str]:
    """
    Returns (path->bytes, paths_to_delete, source_note).

    Never walks the full submodule tree. Only configured intended_paths
    (or filtered dirty porcelain when intended_paths is empty).
    """
    files: dict[str, bytes] = {}
    deletes = [p.replace("\\", "/") for p in t.delete_paths]
    notes: list[str] = []

    if t.intended_paths:
        use_paths = [p.replace("\\", "/") for p in t.intended_paths]
    else:
        mod, deleted = porcelain_paths(
            repo, t.path, exclude_globs=t.exclude_globs
        )
        use_paths = mod
        deletes = sorted(set(deletes) | set(deleted))
        notes.append(f"auto-dirty ({len(use_paths)} paths)")

    if not use_paths and not deletes:
        raise CmdError(
            f"{t.name}: no intended paths (configure intended_paths, "
            f"run isolate, or dirty worktree)"
        )

    # Prefer explicit content_ref (isolated tip), then remote tip, then dirty/source
    cref = content_ref or t.content_ref
    remote_tip: Optional[str] = None
    try:
        remote_tip = remote_branch_sha(t)
    except CmdError:
        remote_tip = None
    if not cref:
        cref = remote_tip

    for p in use_paths:
        data: Optional[bytes] = None
        src = ""

        # 1) clone content_ref (best for rewrite isolation)
        if data is None and clone and cref:
            data = blob_at(clone, cref, p)
            if data is not None:
                src = f"content_ref:{cref[:12]}"

        # 2) monorepo source_commit
        if data is None and t.source_commit:
            data = monorepo_blob(repo, t.source_commit, f"{t.path}/{p}")
            if data is not None:
                src = f"source-commit:{t.source_commit[:12]}"

        # 3) dirty worktree
        if data is None and prefer_dirty:
            data = worktree_blob(repo, t, p)
            if data is not None:
                src = "dirty-worktree"

        # 4) monorepo historical absorb fallback
        if data is None and t.source_commit is None:
            for cand in ("HEAD", "d6a03a042"):
                data = monorepo_blob(repo, cand, f"{t.path}/{p}")
                if data is not None:
                    src = f"monorepo:{cand[:12]}"
                    break

        # 5) remote tip via clone
        if data is None and clone and remote_tip:
            data = blob_at(clone, remote_tip, p)
            if data is not None:
                src = f"remote-tip:{remote_tip[:12]}"

        if data is None:
            raise CmdError(
                f"{t.name}: cannot resolve intended path {p}; "
                f"ensure origin/{t.branch} has it, or pass --source-commit"
            )
        files[p] = data
        notes.append(f"{p} <- {src}")

    note = "; ".join(notes[:8])
    if len(notes) > 8:
        note += f" … (+{len(notes) - 8})"
    return files, deletes, note


def filter_noop_against_base(
    clone: Path, t: Target, files: dict[str, bytes], deletes: list[str]
) -> tuple[dict[str, bytes], list[str]]:
    kept: dict[str, bytes] = {}
    for p, data in files.items():
        base = blob_at(clone, t.base_sha, p)
        if base is not None and base == data:
            print(f"    skip unchanged vs base: {p}")
            continue
        kept[p] = data
    kept_del: list[str] = []
    for p in deletes:
        base = blob_at(clone, t.base_sha, p)
        if base is None:
            print(f"    skip delete (absent at base): {p}")
            continue
        kept_del.append(p)
    return kept, kept_del


def tip_already_matches(
    clone: Path, tip: str, files: dict[str, bytes], deletes: list[str]
) -> bool:
    if not tip:
        return False
    for p, data in files.items():
        if blob_at(clone, tip, p) != data:
            return False
    for p in deletes:
        if blob_at(clone, tip, p) is not None:
            return False
    # Also ensure tip has no *extra* delta vs base beyond intended?
    # For rewrite isolation we only care that intended content matches;
    # use --rewrite to force a clean single-commit tip.
    return True


def tip_is_clean_rewrite(
    clone: Path, tip: str, base: str, files: dict[str, bytes], deletes: list[str]
) -> bool:
    """True if tip == single-parent base and tree delta == exactly intended."""
    if not tip:
        return False
    parents = run_out(["git", "rev-list", "--parents", "-n", "1", tip], cwd=clone).split()
    # format: sha parent1 parent2...
    if len(parents) != 2 or parents[1] != base:
        return False
    rows = name_status(clone, base, tip)
    got_mod = sorted(p for s, p in rows if s != "D")
    got_del = sorted(p for s, p in rows if s == "D")
    want_mod = sorted(files)
    want_del = sorted(set(deletes))
    if got_mod != want_mod or got_del != want_del:
        return False
    return tip_already_matches(clone, tip, files, deletes)


def apply_and_push(
    t: Target,
    clone: Path,
    files: dict[str, bytes],
    deletes: list[str],
    *,
    dry_run: bool,
    force: bool,
    rewrite: bool,
) -> tuple[str, bool]:
    """
    Apply path-scoped changes and push. Returns (tip_sha, pushed).
    Stages only intended paths — never ``git add -A``.

    rewrite=True: always check out base_sha and make a single fresh commit,
    dropping intermediate monorepo-only history on g6lc.
    """
    print(f"  apply {len(files)} file(s), delete {len(deletes)} (rewrite={rewrite})")
    if dry_run:
        for p in sorted(files):
            print(f"    write {p} ({len(files[p])} bytes)")
        for p in deletes:
            print(f"    delete {p}")
        return t.base_sha, False

    ensure_object(clone, t.base_sha, t, monorepo_root())
    files, deletes = filter_noop_against_base(clone, t, files, deletes)

    remote_tip = ""
    r = run(
        ["git", "rev-parse", f"refs/remotes/origin/{t.branch}"],
        cwd=clone,
        check=False,
    )
    if r.returncode == 0:
        remote_tip = r.stdout.decode().strip()
    else:
        try:
            remote_tip = remote_branch_sha(t)
        except CmdError:
            remote_tip = ""

    if remote_tip and files:
        if rewrite and tip_is_clean_rewrite(
            clone, remote_tip, t.base_sha, files, deletes
        ):
            print(
                f"  idempotent clean rewrite already on origin/{t.branch} "
                f"@ {remote_tip[:12]}"
            )
            run(["git", "checkout", "-B", t.branch, remote_tip], cwd=clone)
            return remote_tip, False
        if not rewrite and tip_already_matches(clone, remote_tip, files, deletes):
            print(
                f"  idempotent: origin/{t.branch} already has intended content "
                f"@ {remote_tip[:12]}"
            )
            run(["git", "checkout", "-B", t.branch, remote_tip], cwd=clone)
            return remote_tip, False

    # Always start from clean base for path-scoped apply
    run(["git", "checkout", "-B", t.branch, t.base_sha], cwd=clone)
    run(["git", "reset", "--hard", t.base_sha], cwd=clone)
    run(["git", "clean", "-fdx"], cwd=clone, check=False)

    if not files and not deletes:
        print("  no delta vs base after filtering")
        if remote_tip:
            return remote_tip, False
        push_cmd = ["git", "push", "-u", "origin", t.branch]
        if force:
            push_cmd.append("--force-with-lease")
        run(push_cmd, cwd=clone)
        return run_out(["git", "rev-parse", "HEAD"], cwd=clone), True

    for p, data in files.items():
        write_bytes(clone / p, data)
        run(["git", "add", "--", p], cwd=clone)

    for p in deletes:
        if blob_at(clone, "HEAD", p) is not None:
            run(["git", "rm", "-f", "--", p], cwd=clone, check=False)

    st = run_out(["git", "status", "--porcelain"], cwd=clone)
    if not st:
        print("  index clean after path-stage; nothing to commit")
        tip = run_out(["git", "rev-parse", "HEAD"], cwd=clone)
        return tip, False

    cached = run_out(["git", "diff", "--cached", "--name-only"], cwd=clone)
    allowed = set(files) | set(deletes)
    unexpected = [p for p in cached.splitlines() if p and p not in allowed]
    if unexpected:
        raise CmdError(
            f"{t.name}: refusing to commit unexpected paths: {unexpected}. "
            f"Only intended_paths/delete_paths are allowed."
        )

    print(run_out(["git", "diff", "--cached", "--stat"], cwd=clone))
    author_env = {
        "GIT_AUTHOR_NAME": os.environ.get("GIT_AUTHOR_NAME", "Etienne Cimon"),
        "GIT_AUTHOR_EMAIL": os.environ.get(
            "GIT_AUTHOR_EMAIL", "etienne@cimons.com"
        ),
        "GIT_COMMITTER_NAME": os.environ.get(
            "GIT_COMMITTER_NAME", "Etienne Cimon"
        ),
        "GIT_COMMITTER_EMAIL": os.environ.get(
            "GIT_COMMITTER_EMAIL", "etienne@cimons.com"
        ),
    }
    run(
        ["git", "commit", "--no-verify", "-m", t.commit_message],
        cwd=clone,
        env=author_env,
    )
    tip = run_out(["git", "rev-parse", "HEAD"], cwd=clone)

    push_cmd = ["git", "push", "-u", "origin", t.branch]
    # rewrite always needs force-with-lease (history replaced)
    if force or rewrite:
        push_cmd.append("--force-with-lease")
    print(
        f"  push origin {t.branch} @ {tip[:12]}"
        + (" (force-with-lease)" if force or rewrite else "")
    )
    run(push_cmd, cwd=clone)
    return tip, True


def update_gitmodules(repo: Path, t: Target) -> bool:
    gm = repo / ".gitmodules"
    text = gm.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"(?ms)(\[submodule \"[^\"]+\"\]\s*\n"
        rf"(?:(?!\[submodule).)*?"
        rf"path = {re.escape(t.path)}\s*\n"
        rf"(?:(?!\[submodule).)*?"
        rf"url = )([^\n]+)"
    )
    want = t.fork_url
    new_text, n = pattern.subn(rf"\g<1>{want}", text)
    if n == 0:
        pattern2 = re.compile(
            rf"(?ms)(\[submodule \"[^\"]+\"\]\s*\n"
            rf"(?:(?!\[submodule).)*?"
            rf"url = )([^\n]+)("
            rf"(?:(?!\[submodule).)*?"
            rf"path = {re.escape(t.path)}\s*\n)"
        )
        new_text, n = pattern2.subn(rf"\g<1>{want}\g<3>", text)
    if n == 0:
        raise CmdError(f"could not find .gitmodules entry for path {t.path}")
    if new_text == text:
        return False
    gm.write_text(new_text, encoding="utf-8")
    return True


def pin_gitlink(repo: Path, t: Target, sha: str) -> None:
    run(["git", "update-index", "--cacheinfo", f"160000,{sha},{t.path}"], cwd=repo)


def retarget_submodule_origin(repo: Path, t: Target) -> None:
    wt = repo / t.path
    if not wt.is_dir():
        return
    gd = submodule_git_dir(repo, t.path)
    if gd is None:
        return
    r = run(
        ["git", "--git-dir", str(gd), "--work-tree", str(wt), "remote"],
        check=False,
    )
    if r.returncode != 0:
        return
    remotes = r.stdout.decode().split()
    args_base = ["git", "--git-dir", str(gd), "--work-tree", str(wt)]
    if "origin" in remotes:
        run(args_base + ["remote", "set-url", "origin", t.fork_url], check=False)
    else:
        run(args_base + ["remote", "add", "origin", t.fork_url], check=False)
    if "upstream" in remotes:
        run(args_base + ["remote", "set-url", "upstream", t.upstream], check=False)
    else:
        run(args_base + ["remote", "add", "upstream", t.upstream], check=False)
    print(f"  retargeted {t.path} origin -> {t.fork_url}")


def gitmodules_url(repo: Path, path: str) -> str:
    gm = (repo / ".gitmodules").read_text(encoding="utf-8")
    m = re.search(rf"path = {re.escape(path)}\s*\n\s*url = ([^\n]+)", gm)
    if m:
        return m.group(1).strip()
    m = re.search(
        rf"url = ([^\n]+)\s*\n(?:(?!\[submodule).)*?path = {re.escape(path)}\s*\n",
        gm,
        re.S,
    )
    return m.group(1).strip() if m else ""


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def select_targets(
    targets: list[Target], only: Optional[list[str]]
) -> list[Target]:
    if not only:
        return targets
    return [t for t in targets if t.name in only or t.path in only]


def cmd_status(repo: Path, targets: list[Target]) -> int:
    print(f"monorepo: {repo}")
    ok = True
    for t in targets:
        print(f"\n[{t.name}] path={t.path}")
        print(f"  upstream: {t.upstream_gh}")
        print(f"  fork:     {t.fork_gh} ({t.branch})")
        print(f"  base:     {t.base_sha[:12]}  (upstream ancestor)")
        sha = gitlink_sha(repo, t.path)
        print(f"  gitlink:  {sha or '(missing)'}")
        url_line = gitmodules_url(repo, t.path)
        print(f"  gitmodules url: {url_line or '(missing)'}")
        if url_line and not is_etcimon_url(url_line):
            print("  WARN: .gitmodules URL is not github.com/etcimon/")
            ok = False
        mod, deleted = porcelain_paths(
            repo, t.path, exclude_globs=t.exclude_globs
        )
        if mod or deleted:
            print(f"  dirty worktree: +{len(mod)} ~del {len(deleted)}")
            for p in mod[:12]:
                print(f"    M {p}")
            for p in deleted[:12]:
                print(f"    D {p}")
        else:
            print("  dirty worktree: clean/unavailable")
        if t.intended_paths:
            print(f"  intended_paths ({len(t.intended_paths)}):")
            for p in t.intended_paths:
                print(f"    - {p}")
        if t.delete_paths:
            print(f"  delete_paths: {t.delete_paths}")
        try:
            tip = remote_branch_sha(t)
            print(f"  remote {t.branch}: {tip}")
            if sha == tip:
                print("  pin: matches remote tip")
            elif sha:
                print("  pin: DIFFERS from remote tip")
                ok = False
            # Show whether tip is a clean single-commit rewrite on base
            # (best-effort via ls-remote only — parent check needs clone)
        except CmdError as e:
            print(f"  remote {t.branch}: ({e})")
            ok = False
    return 0 if ok else 2


def cmd_verify(repo: Path, targets: list[Target]) -> int:
    errors: list[str] = []
    for t in targets:
        url = gitmodules_url(repo, t.path)
        if not is_etcimon_url(url):
            errors.append(f"{t.name}: .gitmodules url not etcimon: {url!r}")
        if normalize_github_url(url) != normalize_github_url(t.fork_url):
            errors.append(
                f"{t.name}: .gitmodules url {url!r} != config {t.fork_url!r}"
            )
        sha = gitlink_sha(repo, t.path)
        try:
            tip = remote_branch_sha(t)
        except CmdError as e:
            errors.append(f"{t.name}: {e}")
            continue
        if sha != tip:
            errors.append(
                f"{t.name}: gitlink {sha} != remote {t.branch} {tip}"
            )
        else:
            print(f"OK  {t.name}: {t.fork_gh}@{t.branch} = {tip[:12]}")
    if errors:
        for e in errors:
            print(f"ERR {e}", file=sys.stderr)
        return 1
    print("all targets verified")
    return 0


def cmd_isolate(
    repo: Path,
    targets: list[Target],
    *,
    work_dir: Path,
    dry_run: bool,
    write_config: Optional[Path],
    content_ref_flag: Optional[str],
    apply_to_defaults: bool,
) -> int:
    """
    Discover net local paths: diff(base_sha, content_ref) ∩ include/exclude.
    content_ref defaults to origin/g6lc tip (current fork content).
    """
    results: list[dict] = []
    for t in targets:
        print(f"\n==> isolate {t.name}")
        ensure_fork(t, dry_run=False)
        clone = prepare_clone(t, work_dir, repo, dry_run=False, reuse=True)
        if content_ref_flag:
            cref = content_ref_flag
        elif t.content_ref:
            cref = t.content_ref
        else:
            try:
                cref = remote_branch_sha(t)
            except CmdError:
                # fall back to monorepo gitlink
                cref = gitlink_sha(repo, t.path) or ""
        if not cref:
            raise CmdError(f"{t.name}: no content_ref / remote g6lc / gitlink")
        ensure_object(clone, cref, t, repo)
        mod, deleted, note = isolate_paths(clone, t, cref)
        print(f"  {note}")
        print(f"  intended_paths ({len(mod)}):")
        for p in mod:
            # show whether it differs from configured list
            mark = " " if p in t.intended_paths else "+"
            print(f"   {mark} {p}")
        if deleted:
            print(f"  delete_paths ({len(deleted)}):")
            for p in deleted:
                mark = " " if p in t.delete_paths else "+"
                print(f"   {mark} D {p}")
        dropped_cfg = sorted(set(t.intended_paths) - set(mod))
        if dropped_cfg:
            print(f"  config paths no longer in net delta (drop):")
            for p in dropped_cfg:
                print(f"    - {p}")
        if apply_to_defaults or write_config:
            t.intended_paths = mod
            t.delete_paths = deleted
            t.content_ref = cref
        results.append(t.to_dict())
        # Show commit ancestry noise on current tip
        parents = run_out(
            ["git", "rev-list", "--count", f"{t.base_sha}..{cref}"], cwd=clone
        )
        print(f"  commits on content_ref not in base: {parents}")
        if parents and parents != "0" and parents != "1":
            print(
                "  note: content_ref has multi-commit history above base; "
                "use `sync --rewrite` to squash to a single isolated commit"
            )

    if write_config:
        write_config.write_text(
            json.dumps({"targets": results}, indent=2) + "\n", encoding="utf-8"
        )
        print(f"\nwrote config: {write_config}")
    elif dry_run:
        print("\n(dry-run: config not written; pass --write-config PATH)")
    return 0


def cmd_sync(
    repo: Path,
    targets: list[Target],
    *,
    work_dir: Path,
    dry_run: bool,
    force: bool,
    prefer_dirty: bool,
    source_commit: Optional[str],
    commit_monorepo: bool,
    push_monorepo: bool,
    only: Optional[list[str]],
    reuse_clones: bool,
    retarget_remotes: bool,
    rewrite: bool,
    reisolate: bool,
) -> int:
    if source_commit:
        for t in targets:
            t.source_commit = source_commit

    selected = select_targets(targets, only)
    tips: dict[str, str] = {}

    for t in selected:
        print(f"\n==> {t.name}")
        if not is_etcimon_url(t.fork_url):
            raise CmdError(
                f"{t.name}: fork_url must be github.com/etcimon/: {t.fork_url}"
            )
        ensure_fork(t, dry_run=dry_run)
        if dry_run:
            files, deletes, note = resolve_intended(
                repo, t, prefer_dirty=prefer_dirty, work_dir=work_dir
            )
            print(f"  resolve: {note}")
            print(f"  fingerprint: {content_fingerprint(files, deletes)}")
            tip, pushed = apply_and_push(
                t,
                work_dir / t.name,
                files,
                deletes,
                dry_run=True,
                force=force,
                rewrite=rewrite,
            )
            tips[t.path] = tip
            continue

        clone = prepare_clone(
            t, work_dir, repo, dry_run=False, reuse=reuse_clones
        )

        # Optional: re-discover intended paths from current tip vs base
        content_ref = t.content_ref
        if not content_ref:
            try:
                content_ref = remote_branch_sha(t)
            except CmdError:
                content_ref = gitlink_sha(repo, t.path)

        if reisolate and content_ref:
            mod, deleted, inote = isolate_paths(clone, t, content_ref)
            print(f"  reisolate: {inote}")
            t.intended_paths = mod
            t.delete_paths = deleted
            for p in mod:
                print(f"    keep {p}")
            for p in deleted:
                print(f"    del  {p}")

        files, deletes, note = resolve_intended(
            repo,
            t,
            prefer_dirty=prefer_dirty,
            work_dir=work_dir,
            clone=clone,
            content_ref=content_ref,
        )
        print(f"  resolve: {note}")
        print(f"  fingerprint: {content_fingerprint(files, deletes)}")
        if not files and not deletes:
            print("  nothing to apply")
            tips[t.path] = t.base_sha
            continue

        tip, pushed = apply_and_push(
            t,
            clone,
            files,
            deletes,
            dry_run=False,
            force=force,
            rewrite=rewrite,
        )
        tips[t.path] = tip
        print(f"  tip={tip[:12]} pushed={pushed}")
        changed = update_gitmodules(repo, t)
        pin_gitlink(repo, t, tip)
        print(
            f"  monorepo pin {t.path} -> {tip[:12]}"
            + (" (.gitmodules updated)" if changed else "")
        )
        if retarget_remotes:
            retarget_submodule_origin(repo, t)

    if dry_run:
        return 0

    run(["git", "add", ".gitmodules"], cwd=repo)
    st = run_out(
        ["git", "status", "--porcelain", ".gitmodules"]
        + [t.path for t in selected],
        cwd=repo,
    )
    print("\nmonorepo status (targets):")
    print(st or "  (clean)")

    if commit_monorepo and st:
        msg = (
            "Point G6LC submodules at isolated etcimon fork tips.\n\n"
            "Retarget .gitmodules and pin gitlinks to single-commit g6lc "
            "branches (net local delta only):\n"
            + "\n".join(f"- {p} -> {sha[:12]}" for p, sha in tips.items())
        )
        run(["git", "commit", "--no-verify", "-m", msg], cwd=repo)
        print("committed monorepo pin")
    if push_monorepo:
        run(["git", "push", "origin", "HEAD"], cwd=repo)
        print("pushed monorepo")
    return 0


def cmd_point(
    repo: Path,
    targets: list[Target],
    *,
    from_remote: bool,
    shas: dict[str, str],
    commit_monorepo: bool,
    push_monorepo: bool,
    dry_run: bool,
    retarget_remotes: bool,
) -> int:
    for t in targets:
        if from_remote:
            sha = remote_branch_sha(t)
        elif t.path in shas or t.name in shas:
            sha = shas.get(t.path) or shas[t.name]
        else:
            raise CmdError(
                f"no SHA for {t.name}; pass --from-remote or --sha name=..."
            )
        print(f"{t.name}: {t.fork_url} @ {sha[:12]}")
        if dry_run:
            continue
        update_gitmodules(repo, t)
        pin_gitlink(repo, t, sha)
        if retarget_remotes:
            retarget_submodule_origin(repo, t)
    if dry_run:
        return 0
    run(["git", "add", ".gitmodules"], cwd=repo)
    st = run_out(["git", "status", "--porcelain"], cwd=repo)
    print(st or "(clean)")
    if commit_monorepo and st.strip():
        run(
            [
                "git",
                "commit",
                "--no-verify",
                "-m",
                "Point G6LC submodules at etcimon fork tips.",
            ],
            cwd=repo,
            check=False,
        )
    if push_monorepo:
        run(["git", "push", "origin", "HEAD"], cwd=repo)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def load_targets(config_path: Optional[Path]) -> list[Target]:
    if not config_path:
        return [Target.from_dict(d) for d in DEFAULT_TARGETS]
    data = json.loads(config_path.read_text(encoding="utf-8"))
    items = (
        data["targets"]
        if isinstance(data, dict) and "targets" in data
        else data
    )
    return [Target.from_dict(d) for d in items]


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Isolate intended submodule changes, push to github.com/etcimon "
            "forks, and pin monorepo gitlinks."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument(
        "--repo",
        type=Path,
        default=None,
        help="Monorepo root (default: current git toplevel)",
    )
    ap.add_argument(
        "--config",
        type=Path,
        default=None,
        help="Optional JSON config overriding default targets",
    )
    ap.add_argument(
        "--only",
        action="append",
        default=[],
        help="Only process these target names or paths (repeatable)",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_status = sub.add_parser(
        "status", help="Show pins, intended files, remote tips"
    )
    p_status.set_defaults(func="status")

    p_verify = sub.add_parser(
        "verify", help="Exit non-zero unless pins match etcimon g6lc tips"
    )
    p_verify.set_defaults(func="verify")

    p_iso = sub.add_parser(
        "isolate",
        help=(
            "Discover net local paths: diff(base_sha, content_ref) filtered "
            "by include/exclude globs"
        ),
    )
    p_iso.add_argument(
        "--work-dir", type=Path, default=Path(".g6lc-forks-win")
    )
    p_iso.add_argument(
        "--content-ref",
        default=None,
        help="Tree/commit with final content (default: origin/g6lc tip)",
    )
    p_iso.add_argument(
        "--write-config",
        type=Path,
        default=None,
        help="Write isolated intended_paths JSON config",
    )
    p_iso.add_argument(
        "--apply",
        action="store_true",
        help="Update in-memory targets (for chaining; use with --write-config)",
    )
    p_iso.add_argument("--dry-run", action="store_true")
    p_iso.set_defaults(func="isolate")

    p_sync = sub.add_parser(
        "sync",
        help="Apply isolated diffs only, push g6lc, pin monorepo",
    )
    p_sync.add_argument(
        "--work-dir", type=Path, default=Path(".g6lc-forks-win")
    )
    p_sync.add_argument("--dry-run", action="store_true")
    p_sync.add_argument(
        "--force",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="force-with-lease push (default: on)",
    )
    p_sync.add_argument(
        "--rewrite",
        action=argparse.BooleanOptionalAction,
        default=False,
        help=(
            "Rewrite g6lc as a single commit on base_sha with only intended "
            "paths (drops intermediate monorepo-only history)"
        ),
    )
    p_sync.add_argument(
        "--reisolate",
        action="store_true",
        help=(
            "Before apply, recompute intended_paths from "
            "diff(base_sha, content_ref) ∩ globs"
        ),
    )
    p_sync.add_argument(
        "--prefer-dirty",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Prefer dirty submodule worktree bytes (default: on)",
    )
    p_sync.add_argument(
        "--reuse-clones",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Reuse work-dir clones (default: on)",
    )
    p_sync.add_argument(
        "--source-commit",
        default=None,
        help="Monorepo commit with intended trees under submodule paths",
    )
    p_sync.add_argument("--commit-monorepo", action="store_true")
    p_sync.add_argument("--push-monorepo", action="store_true")
    p_sync.add_argument(
        "--retarget-remotes",
        action="store_true",
        help="Set checked-out submodule origin URL to etcimon fork",
    )
    p_sync.set_defaults(func="sync")

    p_point = sub.add_parser(
        "point", help="Only retarget .gitmodules + gitlinks to etcimon"
    )
    p_point.add_argument(
        "--from-remote",
        action="store_true",
        help="Use fork g6lc tip SHAs",
    )
    p_point.add_argument(
        "--sha",
        action="append",
        default=[],
        help="name=sha or path=sha (repeatable)",
    )
    p_point.add_argument("--commit-monorepo", action="store_true")
    p_point.add_argument("--push-monorepo", action="store_true")
    p_point.add_argument("--dry-run", action="store_true")
    p_point.add_argument(
        "--retarget-remotes",
        action="store_true",
        help="Set checked-out submodule origin URL to etcimon fork",
    )
    p_point.set_defaults(func="point")

    p_dump = sub.add_parser("dump-config", help="Print default JSON config")
    p_dump.set_defaults(func="dump")

    args = ap.parse_args(argv)

    if args.func == "dump":
        print(json.dumps({"targets": DEFAULT_TARGETS}, indent=2))
        return 0

    repo = (args.repo or monorepo_root()).resolve()
    targets = load_targets(args.config)
    only = args.only or None

    try:
        if args.func == "status":
            return cmd_status(repo, select_targets(targets, only))
        if args.func == "verify":
            return cmd_verify(repo, select_targets(targets, only))
        if args.func == "isolate":
            work = args.work_dir
            if not work.is_absolute():
                work = repo / work
            return cmd_isolate(
                repo,
                select_targets(targets, only),
                work_dir=work,
                dry_run=args.dry_run,
                write_config=args.write_config,
                content_ref_flag=args.content_ref,
                apply_to_defaults=args.apply,
            )
        if args.func == "sync":
            work = args.work_dir
            if not work.is_absolute():
                work = repo / work
            return cmd_sync(
                repo,
                targets,
                work_dir=work,
                dry_run=args.dry_run,
                force=args.force,
                prefer_dirty=args.prefer_dirty,
                source_commit=args.source_commit,
                commit_monorepo=args.commit_monorepo,
                push_monorepo=args.push_monorepo,
                only=only,
                reuse_clones=args.reuse_clones,
                retarget_remotes=args.retarget_remotes,
                rewrite=args.rewrite,
                reisolate=args.reisolate,
            )
        if args.func == "point":
            shas: dict[str, str] = {}
            for item in args.sha:
                if "=" not in item:
                    raise CmdError(f"--sha expects name=sha, got {item}")
                k, v = item.split("=", 1)
                shas[k] = v
            return cmd_point(
                repo,
                select_targets(targets, only),
                from_remote=args.from_remote,
                shas=shas,
                commit_monorepo=args.commit_monorepo,
                push_monorepo=args.push_monorepo,
                dry_run=args.dry_run,
                retarget_remotes=args.retarget_remotes,
            )
    except CmdError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
