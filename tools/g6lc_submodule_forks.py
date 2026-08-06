#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon / GlobecSys Inc.
"""
Push *intended* G6LC submodule changes to github.com/etcimon forks and pin
the monorepo gitlinks to those forks.

Problem this solves
-------------------
Dirty submodule worktrees are easy to lose and disastrous to absorb as plain
directories (huge commits, wrong history). This tool:

  1. Ensures etcimon forks of the upstream submodule remotes exist
  2. Resolves *only* the configured intended paths (never whole-tree rsync)
  3. Stages path-by-path on top of a known base SHA (no ``git add -A``)
  4. Skips push when the remote ``g6lc`` tip already carries the same content
  5. Pushes branch ``g6lc`` on each fork (force-with-lease only when needed)
  6. Updates monorepo ``.gitmodules`` URLs + ``160000`` gitlink pins
  7. Optionally retargets checked-out submodule ``origin`` remotes

Default targets (LibreCore residual stack)
------------------------------------------

  | monorepo path                 | upstream                    | fork                |
  |-------------------------------|-----------------------------|---------------------|
  | core/cache_subsystem/hpdcache | openhwgroup/cv-hpdcache     | etcimon/cv-hpdcache |
  | verif/core-v-verif            | openhwgroup/core-v-verif    | etcimon/core-v-verif|
  | verif/sim/dv                  | google/riscv-dv             | etcimon/riscv-dv   |

Content resolution order for each intended path
-----------------------------------------------
  1. ``--source-commit`` monorepo tree blob  (historical absorb / WIP commit)
  2. Dirty submodule worktree file (when present and ``--prefer-dirty``)
  3. Existing remote fork ``g6lc`` tip blob  (idempotent re-sync)
  4. Local clone / modules cache of the base SHA (no-op if identical)

Examples
--------
  python tools/g6lc_submodule_forks.py status
  python tools/g6lc_submodule_forks.py sync --dry-run
  python tools/g6lc_submodule_forks.py sync --work-dir .g6lc-forks-win
  python tools/g6lc_submodule_forks.py sync --source-commit d6a03a042 --force
  python tools/g6lc_submodule_forks.py point --from-remote --retarget-remotes
  python tools/g6lc_submodule_forks.py verify
  python tools/g6lc_submodule_forks.py dump-config > g6lc-forks.json
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
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional, Sequence
from urllib.parse import urlparse


# ---------------------------------------------------------------------------
# Default G6LC fork plan — intended_paths is the allowlist (never whole tree)
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
        # Tip that already carried LibreCore Zacas work before dirty edits
        "base_sha": "9e5c9537bbd60ac5e79c56b7169856951fadb958",
        "extra_fetch": [],
        "intended_paths": [
            "rtl/hpdcache.Flist",
            "rtl/src/hpdcache_amo.sv",
            "rtl/src/hpdcache_pkg.sv",
            "rtl/src/hpdcache_uncached.sv",
            "rtl/src/hpdcache_victim_sel.sv",
            "rtl/src/utils/hpdcache_mem_to_axi_write.sv",
        ],
        "delete_paths": [
            "rtl/src/hpdcache_victim_rrip.sv",
        ],
        # When auto-discovering dirty files, drop these (docs/binaries/noise)
        "exclude_globs": [
            "*.pdf",
            "*.docx",
            "*.o",
            "*.a",
            "*.so",
            "*.exe",
            "*.bin",
            "docs/**",
            "**/.git/**",
        ],
        "commit_message": (
            "G6LC: AMOCAS/Zacas and local HPDCache bring-up edits.\n\n"
            "LibreCore monorepo intended-path carry on top of the Zacas AMOCAS tip:\n"
            "uncached path, AMO unit, victim select, Flist, and AXI write util updates."
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
        "exclude_globs": ["*.o", "*.a", "*.so", "docs/**"],
        "commit_message": (
            "G6LC: Spike Proc/Simulation/spike patches for LibreCore dual-hart.\n\n"
            "Intended monorepo residual-verification edits only (not full tree absorb)."
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
        "exclude_globs": [],
        "commit_message": (
            "G6LC: riscv-dv scripts/lib.py fixes for LibreCore regress.\n\n"
            "Intended monorepo script fix only (not full tree absorb)."
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
    # Avoid interactive credential prompts hanging automation
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
    """Resolve the git dir for a submodule (modules/ or nested .git)."""
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
    """Minimal ** / * matcher for exclude globs (posix paths)."""
    rel = rel.replace("\\", "/")
    for g in globs:
        g = g.replace("\\", "/")
        if _glob_match(g, rel):
            return True
    return False


def _glob_match(pattern: str, path: str) -> bool:
    # Convert simple gitignore-like globs to regex
    # ** = any path segments, * = within segment
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
    """Return (modified_or_added, deleted) paths relative to submodule root."""
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
    """Normalize to https://github.com/owner/repo.git form when possible."""
    url = url.strip().rstrip("/")
    if url.endswith(".git"):
        core = url[:-4]
    else:
        core = url
    # git@github.com:owner/repo
    m = re.match(r"git@github\.com:([^/]+)/(.+)$", core)
    if m:
        return f"https://github.com/{m.group(1)}/{m.group(2)}.git"
    # https://github.com/owner/repo(.git)?
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
    # Optional monorepo commit that holds intended trees under path/
    source_commit: Optional[str] = None

    @staticmethod
    def from_dict(d: dict) -> "Target":
        known = set(Target.__dataclass_fields__)
        return Target(**{k: d[k] for k in d if k in known})  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# Fork / clone / content resolution
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


def remote_blob_via_archive(
    t: Target, sha: str, sub_rel: str, cache_dir: Path
) -> Optional[bytes]:
    """
    Fetch a single blob from a remote commit without a full clone when possible.
    Uses `git archive` over the fork URL (requires server support).
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    out = cache_dir / f"{t.name}-{sha[:12]}-{hashlib.sha1(sub_rel.encode()).hexdigest()[:8]}"
    if out.is_file():
        return out.read_bytes()
    r = run(
        ["git", "archive", "--remote", t.fork_url, sha, sub_rel],
        check=False,
    )
    # git archive --remote writes a tar to stdout; often disabled on GitHub
    if r.returncode != 0:
        return None
    # Minimal tar extract of single file (ustar)
    data = r.stdout
    # Skip 512-byte header, read size from header bytes 124-135 octal
    if len(data) < 512:
        return None
    try:
        size = int(data[124:136].split(b"\0", 1)[0] or b"0", 8)
    except ValueError:
        return None
    payload = data[512 : 512 + size]
    write_bytes(out, payload)
    return payload


def resolve_intended(
    repo: Path,
    t: Target,
    *,
    prefer_dirty: bool,
    work_dir: Path,
) -> tuple[dict[str, bytes], list[str], str]:
    """
    Returns (path->bytes, paths_to_delete, source_note).

    Never walks the full submodule tree. Only configured intended_paths
    (or filtered dirty porcelain when intended_paths is empty).
    """
    files: dict[str, bytes] = {}
    deletes = [p.replace("\\", "/") for p in t.delete_paths]
    notes: list[str] = []

    # Decide path list
    if t.intended_paths:
        use_paths = [p.replace("\\", "/") for p in t.intended_paths]
    else:
        mod, deleted = porcelain_paths(repo, t.path, exclude_globs=t.exclude_globs)
        use_paths = mod
        deletes = sorted(set(deletes) | set(deleted))
        notes.append(f"auto-dirty ({len(use_paths)} paths)")

    if not use_paths and not deletes:
        raise CmdError(
            f"{t.name}: no intended paths (configure intended_paths or dirty worktree)"
        )

    remote_tip: Optional[str] = None
    try:
        remote_tip = remote_branch_sha(t)
    except CmdError:
        remote_tip = None

    for p in use_paths:
        data: Optional[bytes] = None
        src = ""

        if t.source_commit:
            data = monorepo_blob(repo, t.source_commit, f"{t.path}/{p}")
            if data is not None:
                src = f"source-commit:{t.source_commit[:12]}"

        if data is None and prefer_dirty:
            data = worktree_blob(repo, t, p)
            if data is not None:
                src = "dirty-worktree"

        if data is None and t.source_commit is None:
            # historical fallback used previously
            for cand in ("HEAD", "d6a03a042"):
                data = monorepo_blob(repo, cand, f"{t.path}/{p}")
                if data is not None:
                    src = f"monorepo:{cand[:12]}"
                    break

        if data is None and remote_tip:
            # Prefer reading from a local work clone if present
            clone = work_dir / t.name
            if (clone / ".git").exists() or (clone / ".git").is_file():
                r = run(
                    ["git", "show", f"{remote_tip}:{p}"],
                    cwd=clone,
                    check=False,
                )
                if r.returncode == 0:
                    data = r.stdout
                    src = f"local-clone@{remote_tip[:12]}"
            if data is None:
                data = remote_blob_via_archive(
                    t, remote_tip, p, work_dir / ".blob-cache"
                )
                if data is not None:
                    src = f"archive@{remote_tip[:12]}"

        if data is None:
            raise CmdError(
                f"{t.name}: cannot resolve intended path {p}; "
                f"pass --source-commit <mono-rev>, populate dirty worktree, "
                f"or ensure fork {t.fork_gh}@{t.branch} already has it"
            )
        files[p] = data
        notes.append(f"{p} <- {src}")

    note = "; ".join(notes[:8])
    if len(notes) > 8:
        note += f" … (+{len(notes) - 8})"
    return files, deletes, note


def modules_candidates(repo: Path, t: Target) -> list[Path]:
    cands: list[Path] = []
    env_key = f"G6LC_{t.name.upper().replace('-', '_')}_GITDIR"
    if os.environ.get(env_key):
        cands.append(Path(os.environ[env_key]))
    if os.environ.get("G6LC_HPDCACHE_GITDIR") and t.name == "cv-hpdcache":
        cands.append(Path(os.environ["G6LC_HPDCACHE_GITDIR"]))
    cands.append(repo / ".git" / "modules" / Path(t.path))
    # Alternate nested layouts some checkouts use
    cands.append(repo / ".git" / "modules" / t.name)
    gd = submodule_git_dir(repo, t.path)
    if gd:
        cands.append(gd)
    # Prior work clone
    return [c for c in cands if c and Path(c).exists()]


def ensure_base_reachable(clone: Path, t: Target, repo: Path) -> None:
    r = run(["git", "cat-file", "-t", t.base_sha], cwd=clone, check=False)
    if r.returncode == 0:
        return
    run(["git", "fetch", "upstream", t.base_sha], cwd=clone, check=False)
    r = run(["git", "cat-file", "-t", t.base_sha], cwd=clone, check=False)
    if r.returncode == 0:
        return
    run(["git", "fetch", "origin", t.base_sha], cwd=clone, check=False)
    r = run(["git", "cat-file", "-t", t.base_sha], cwd=clone, check=False)
    if r.returncode == 0:
        return
    for extra in t.extra_fetch:
        run(["git", "fetch", extra, t.base_sha], cwd=clone, check=False)
    for cand in modules_candidates(repo, t):
        run(["git", "fetch", str(cand), t.base_sha], cwd=clone, check=False)
        r = run(["git", "cat-file", "-t", t.base_sha], cwd=clone, check=False)
        if r.returncode == 0:
            print(f"  base_sha fetched from {cand}")
            return
    # Last resort: base might already be ancestor of remote g6lc
    run(["git", "fetch", "origin", t.branch], cwd=clone, check=False)
    r = run(["git", "cat-file", "-t", t.base_sha], cwd=clone, check=False)
    if r.returncode == 0:
        return
    raise CmdError(
        f"{t.name}: base_sha {t.base_sha} not found after fetch; "
        f"set {f'G6LC_{t.name.upper().replace(chr(45), chr(95))}_GITDIR'} "
        f"to a git dir that contains it, or push the base first"
    )


def prepare_clone(
    t: Target, work_dir: Path, repo: Path, *, dry_run: bool, reuse: bool
) -> Path:
    dest = work_dir / t.name
    if dry_run:
        return dest
    work_dir.mkdir(parents=True, exist_ok=True)

    if reuse and dest.exists() and (dest / ".git").exists():
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

    ensure_base_reachable(dest, t, repo)
    run(["git", "checkout", "-B", t.branch, t.base_sha], cwd=dest)
    # Drop any leftover untracked from a prior partial apply
    run(["git", "reset", "--hard", t.base_sha], cwd=dest)
    run(["git", "clean", "-fdx"], cwd=dest, check=False)
    return dest


def blob_at(clone: Path, rev: str, path: str) -> Optional[bytes]:
    r = run(["git", "show", f"{rev}:{path}"], cwd=clone, check=False)
    if r.returncode != 0:
        return None
    return r.stdout


def filter_noop_against_base(
    clone: Path, t: Target, files: dict[str, bytes], deletes: list[str]
) -> tuple[dict[str, bytes], list[str]]:
    """Drop writes identical to base and deletes of already-absent paths."""
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
    """True if remote tip already has exactly the intended file contents."""
    if not tip:
        return False
    for p, data in files.items():
        cur = blob_at(clone, tip, p)
        if cur != data:
            return False
    for p in deletes:
        # deleted => path must not exist at tip
        if blob_at(clone, tip, p) is not None:
            return False
    return True


def apply_and_push(
    t: Target,
    clone: Path,
    files: dict[str, bytes],
    deletes: list[str],
    *,
    dry_run: bool,
    force: bool,
) -> tuple[str, bool]:
    """
    Apply path-scoped changes and push. Returns (tip_sha, pushed).
    Stages only intended paths — never ``git add -A``.
    """
    print(f"  apply {len(files)} file(s), delete {len(deletes)}")
    if dry_run:
        for p in sorted(files):
            print(f"    write {p} ({len(files[p])} bytes)")
        for p in deletes:
            print(f"    delete {p}")
        return t.base_sha, False

    files, deletes = filter_noop_against_base(clone, t, files, deletes)

    # Idempotency: if origin/g6lc already has this content, reuse tip
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

    if remote_tip and tip_already_matches(clone, remote_tip, files, deletes):
        # Still ensure branch points at that tip and base ancestry is fine
        print(f"  idempotent: origin/{t.branch} already has intended content @ {remote_tip[:12]}")
        run(["git", "checkout", "-B", t.branch, remote_tip], cwd=clone)
        return remote_tip, False

    if not files and not deletes:
        print("  no delta vs base after filtering; pinning base/remote tip")
        tip = remote_tip or t.base_sha
        if remote_tip:
            run(["git", "checkout", "-B", t.branch, remote_tip], cwd=clone)
            return remote_tip, False
        # push base as branch if missing
        run(["git", "checkout", "-B", t.branch, t.base_sha], cwd=clone)
        push_cmd = ["git", "push", "-u", "origin", t.branch]
        if force:
            push_cmd.append("--force-with-lease")
        run(push_cmd, cwd=clone)
        return run_out(["git", "rev-parse", "HEAD"], cwd=clone), True

    for p, data in files.items():
        write_bytes(clone / p, data)
        run(["git", "add", "--", p], cwd=clone)

    for p in deletes:
        fp = clone / p
        if fp.exists() or blob_at(clone, "HEAD", p) is not None:
            run(["git", "rm", "-f", "--", p], cwd=clone, check=False)

    st = run_out(["git", "status", "--porcelain"], cwd=clone)
    if not st:
        print("  index clean after path-stage; nothing to commit")
        tip = run_out(["git", "rev-parse", "HEAD"], cwd=clone)
        return tip, False

    # Guard: refuse unexpected paths in the index
    cached = run_out(["git", "diff", "--cached", "--name-only"], cwd=clone)
    allowed = set(files) | set(deletes)
    unexpected = [p for p in cached.splitlines() if p and p not in allowed]
    if unexpected:
        raise CmdError(
            f"{t.name}: refusing to commit unexpected paths: {unexpected}. "
            f"Only intended_paths/delete_paths are allowed."
        )

    print(run_out(["git", "diff", "--cached", "--stat"], cwd=clone))
    # Prefer monorepo identity when available
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
    if force:
        push_cmd.append("--force-with-lease")
    print(f"  push origin {t.branch} @ {tip[:12]}" + (" (force-with-lease)" if force else ""))
    run(push_cmd, cwd=clone)
    return tip, True


def update_gitmodules(repo: Path, t: Target) -> bool:
    """Set submodule URL to the etcimon fork. Returns True if file changed."""
    gm = repo / ".gitmodules"
    text = gm.read_text(encoding="utf-8")
    # Match path then url within the same submodule section
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
        # try url-before-path ordering
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


def remote_branch_sha(t: Target) -> str:
    out = run_out(["git", "ls-remote", t.fork_url, f"refs/heads/{t.branch}"])
    if not out:
        raise CmdError(f"no remote branch {t.fork_gh}@{t.branch}")
    return out.split()[0]


def retarget_submodule_origin(repo: Path, t: Target) -> None:
    """Point a checked-out submodule's origin at the etcimon fork URL."""
    wt = repo / t.path
    if not wt.is_dir():
        return
    gd = submodule_git_dir(repo, t.path)
    if gd is None:
        return
    # Only retarget if this looks like a real submodule checkout
    r = run(
        ["git", "--git-dir", str(gd), "--work-tree", str(wt), "remote"],
        check=False,
    )
    if r.returncode != 0:
        return
    remotes = r.stdout.decode().split()
    if "origin" in remotes:
        run(
            [
                "git",
                "--git-dir",
                str(gd),
                "--work-tree",
                str(wt),
                "remote",
                "set-url",
                "origin",
                t.fork_url,
            ],
            check=False,
        )
    else:
        run(
            [
                "git",
                "--git-dir",
                str(gd),
                "--work-tree",
                str(wt),
                "remote",
                "add",
                "origin",
                t.fork_url,
            ],
            check=False,
        )
    # Keep upstream remote for cherry-picks
    if "upstream" in remotes:
        run(
            [
                "git",
                "--git-dir",
                str(gd),
                "--work-tree",
                str(wt),
                "remote",
                "set-url",
                "upstream",
                t.upstream,
            ],
            check=False,
        )
    else:
        run(
            [
                "git",
                "--git-dir",
                str(gd),
                "--work-tree",
                str(wt),
                "remote",
                "add",
                "upstream",
                t.upstream,
            ],
            check=False,
        )
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


def cmd_status(repo: Path, targets: list[Target]) -> int:
    print(f"monorepo: {repo}")
    ok = True
    for t in targets:
        print(f"\n[{t.name}] path={t.path}")
        print(f"  upstream: {t.upstream_gh}")
        print(f"  fork:     {t.fork_gh} ({t.branch})")
        print(f"  base:     {t.base_sha[:12]}")
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
        except CmdError as e:
            print(f"  remote {t.branch}: ({e})")
            ok = False
    return 0 if ok else 2


def cmd_verify(repo: Path, targets: list[Target]) -> int:
    """Hard check: etcimon URLs + gitlink == remote g6lc tip."""
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
) -> int:
    if source_commit:
        for t in targets:
            t.source_commit = source_commit

    selected = [
        t for t in targets if not only or t.name in only or t.path in only
    ]
    tips: dict[str, str] = {}

    for t in selected:
        print(f"\n==> {t.name}")
        if not is_etcimon_url(t.fork_url):
            raise CmdError(f"{t.name}: fork_url must be github.com/etcimon/: {t.fork_url}")
        ensure_fork(t, dry_run=dry_run)
        files, deletes, note = resolve_intended(
            repo, t, prefer_dirty=prefer_dirty, work_dir=work_dir
        )
        print(f"  resolve: {note}")
        print(f"  fingerprint: {content_fingerprint(files, deletes)}")
        if not files and not deletes:
            print("  nothing to apply")
            tips[t.path] = t.base_sha
            continue
        clone = prepare_clone(
            t, work_dir, repo, dry_run=dry_run, reuse=reuse_clones
        )
        tip, pushed = apply_and_push(
            t, clone, files, deletes, dry_run=dry_run, force=force
        )
        tips[t.path] = tip
        print(f"  tip={tip[:12]} pushed={pushed}")
        if not dry_run:
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
            "Point G6LC submodules at etcimon forks.\n\n"
            "Retarget .gitmodules and pin gitlinks to g6lc branch tips:\n"
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
    items = data["targets"] if isinstance(data, dict) and "targets" in data else data
    return [Target.from_dict(d) for d in items]


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Push intended submodule changes to github.com/etcimon forks "
            "and pin monorepo gitlinks."
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
        "status", help="Show pins, dirty intended files, remote tips"
    )
    p_status.set_defaults(func="status")

    p_verify = sub.add_parser(
        "verify", help="Exit non-zero unless pins match etcimon g6lc tips"
    )
    p_verify.set_defaults(func="verify")

    p_sync = sub.add_parser(
        "sync",
        help="Fork/ensure, apply intended diffs only, push g6lc, pin monorepo",
    )
    p_sync.add_argument(
        "--work-dir", type=Path, default=Path(".g6lc-forks-win")
    )
    p_sync.add_argument("--dry-run", action="store_true")
    p_sync.add_argument(
        "--force",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="force-with-lease push (default: on; use --no-force to disable)",
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
        help="Reuse work-dir clones instead of full re-clone (default: on)",
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
            selected = [
                t
                for t in targets
                if not only or t.name in only or t.path in only
            ]
            return cmd_status(repo, selected)
        if args.func == "verify":
            selected = [
                t
                for t in targets
                if not only or t.name in only or t.path in only
            ]
            return cmd_verify(repo, selected)
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
            )
        if args.func == "point":
            shas: dict[str, str] = {}
            for item in args.sha:
                if "=" not in item:
                    raise CmdError(f"--sha expects name=sha, got {item}")
                k, v = item.split("=", 1)
                shas[k] = v
            selected = [
                t
                for t in targets
                if not only or t.name in only or t.path in only
            ]
            return cmd_point(
                repo,
                selected,
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
