# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Launch the storamic Python unittest suite on the remote testharness.

Builds a content-addressed code-base closure from the working tree (every
git-tracked file the suite can touch), uploads it as a tar plus a sha256
manifest and the expected ``test_*.py`` list, then runs
``run_unittests_leaf.py`` through ``testharness_proxy.py py``. The leaf
serializes concurrent launches on a flock counting semaphore, validates a
cached extraction under an init mutex, runs each test file consecutively plus
one full discover, and writes ``unittests-result.json`` for pull.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

TEST_DIR = Path("verif/tb/storamic")
TEST_PATTERN = "test_*.py"

# Closure rules. ``ALL_DIRS`` contribute every tracked file; ``SRC_DIRS``
# contribute only source/data extensions (keeps the tar small while covering
# every RTL/config/bench file the suite parses or hashes).
ALL_DIRS = (
    "verif/tb/storamic/",
    "verif/regress/remote/",
    "g6lc_storamic/",
)
SRC_DIRS = (
    "verif/tb/apu/",
    "verif/tb/core/",
    "corev_apu/",
    "core/",
    "common/",
    "vendor/",
    "config/",
)
# Binary/object/archive extensions excluded from the tar. Everything else under
# the closure prefixes ships: the suite parses or hashes RTL, firmware images,
# data vectors, Flist manifests and submodule sources whose extensions are too
# varied to enumerate safely (.sv/.svh/.v/.vh/.f/.F/.S/.s/.dts/.dtsi/.hjson/
# .storamic*/.hex/.mem/.dat/.spv*/...). Git submodules are covered via
# ``git ls-files --recurse-submodules``.
BLOCK_EXTS = {
    ".o", ".a", ".so", ".dylib", ".dll", ".exe", ".lib", ".elf",
    ".class", ".jar", ".zip", ".gz", ".tgz", ".bz2", ".xz", ".7z",
    ".pyc", ".pyo", ".gcno", ".gcda", ".gcov", ".gcda",
    ".vcd", ".fst", ".vpd", ".wlf",
}


def _git_files(root):
    """Tracked files (recursing submodules) plus untracked under ALL_DIRS.

    ``--recurse-submodules`` is required: hpdcache/cvfpu/common_cells/
    tech_cells_generic and the corev_apu/vendored trees are git submodules whose
    contents exist in the working tree but not in the parent's ``ls-files``.
    ``--others --exclude-standard`` adds the suite's own new (uncommitted)
    sources under ALL_DIRS while keeping ignored build outputs out.
    """
    tracked = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "--recurse-submodules", "-z"],
        text=True)
    files = {p for p in tracked.split("\0") if p}
    others = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "--others", "--exclude-standard",
         "-z", "--", *[d.rstrip("/") for d in ALL_DIRS]], text=True)
    files.update(p for p in others.split("\0") if p)
    return sorted(files)


def closure_files(root):
    """Repo-relative paths forming the unittest code-base closure."""
    chosen = set()
    for rel in _git_files(root):
        if not rel.startswith(SRC_DIRS + ALL_DIRS):
            continue
        if Path(rel).suffix.lower() in BLOCK_EXTS:
            continue
        chosen.add(rel)
    return sorted(chosen)


def aggregate_sha(manifest):
    digest = hashlib.sha256()
    for rel in sorted(manifest):
        digest.update(rel.encode())
        digest.update(b"\0")
        digest.update(manifest[rel].encode())
        digest.update(b"\n")
    return digest.hexdigest()


def build_payload(root, files, tar_path):
    """Hash and tar every closure file in a single pass.

    Each file's bytes are read exactly once and used for both the sha256
    manifest entry and the tar member, so a file modified while the payload is
    being built cannot make the manifest and archive disagree (TOCTOU). Files
    that vanish or are unreadable are skipped from both. Symlinks are stored
    as regular files containing their resolved bytes. Returns the manifest.
    """
    manifest = {}
    with tarfile.open(tar_path, "w:gz") as archive:
        for rel in files:
            path = root / rel
            try:
                data = path.read_bytes()
                mtime = int(path.stat().st_mtime)
            except OSError:
                continue
            manifest[rel] = hashlib.sha256(data).hexdigest()
            info = tarfile.TarInfo(rel)
            info.size = len(data)
            info.mtime = mtime
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--tag", default=None)
    parser.add_argument("--timeout", type=int, default=2400,
                        help="proxy remote timeout seconds")
    parser.add_argument("--slots", type=int, default=None,
                        help="semaphore slots (default leaf env or 1)")
    parser.add_argument("--wait", type=float, default=None,
                        help="bounded slot wait seconds (default 1800)")
    parser.add_argument("--per-file-timeout", type=float, default=None,
                        help="per-test-file timeout seconds (default 600)")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--prepared", type=Path, default=None,
                        help="reuse an already-built payload dir containing "
                             "manifest-*.json, codebase-*.tar* and "
                             "expected-*.json instead of rebuilding the "
                             "closure (keeps the aggregate sha stable across "
                             "concurrent launches)")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[3]
    tests = sorted(p.name for p in (root / TEST_DIR).glob(TEST_PATTERN))
    if not tests:
        print("Incomplete: no test_*.py found under " + str(TEST_DIR))
        return 4
    if args.prepared is not None:
        # Reuse a frozen payload: identical manifest => identical aggregate sha
        # => the remote cache is shared, which is what concurrency/reuse
        # evidence needs. No rebuild, so a churning working tree cannot drift
        # the snapshot between launches.
        pdir = args.prepared
        mans = sorted(pdir.glob("manifest-*.json"))
        tars = sorted(pdir.glob("codebase-*.tar*"))
        exps = sorted(pdir.glob("expected-*.json"))
        if not (mans and tars and exps):
            print(f"Incomplete: --prepared {pdir} lacks manifest/codebase/"
                  "expected payload files")
            return 4
        manifest = json.loads(mans[0].read_text())
        tests = json.loads(exps[0].read_text())["tests"]
        agg = aggregate_sha(manifest)
        tag = args.tag or ("storamic-unittests-" + agg[:12])
        work = (args.output_root or root / "remote-runs") / tag
        work.mkdir(parents=True, exist_ok=True)
        tar_path = work / tars[0].name
        manifest_path = work / mans[0].name
        expected_path = work / exps[0].name
        shutil.copyfile(tars[0], tar_path)
        shutil.copyfile(mans[0], manifest_path)
        shutil.copyfile(exps[0], expected_path)
        files = list(manifest)
    else:
        files = closure_files(root)
        # Build the payload to a staging tar first: the manifest (and thus the
        # content-addressed tag) is only known after every file has been
        # hashed, and the tar must contain exactly the bytes the manifest
        # recorded.
        staging = Path(tempfile.mkdtemp(
            prefix="ut-payload-", dir=args.output_root or root / "remote-runs"))
        staging_tar = staging / "codebase.tar.gz"
        manifest = build_payload(root, files, staging_tar)
        agg = aggregate_sha(manifest)
        tag = args.tag or ("storamic-unittests-" + agg[:12])
        work = (args.output_root or root / "remote-runs") / tag
        work.mkdir(parents=True, exist_ok=True)
        tar_path = work / f"codebase-{agg[:12]}.tar.gz"
        manifest_path = work / f"manifest-{agg[:12]}.json"
        expected_path = work / f"expected-{agg[:12]}.json"
        os.replace(staging_tar, tar_path)
        shutil.rmtree(staging, ignore_errors=True)
        manifest_path.write_text(json.dumps(manifest, indent=1, sort_keys=True))
        expected_path.write_text(json.dumps({"tests": tests}, indent=1))

    leaf = Path(__file__).with_name("run_unittests_leaf.py")
    leaf_sha = hashlib.sha256(leaf.read_bytes()).hexdigest()
    plan = {
        "status": "prepared", "qualification": False, "tag": tag,
        "aggregate_sha256": agg, "files": len(files), "tests": len(tests),
        "tar": str(tar_path), "manifest": str(manifest_path),
        "expected": str(expected_path), "leaf_sha256": leaf_sha,
        "expected_tests": tests,
    }
    (work / "unittest-launch-plan.json").write_text(json.dumps(plan, indent=2))
    if args.prepare_only:
        print(f"Prepared locally (no remote launch): {work / 'unittest-launch-plan.json'}")
        return 0

    bun = shutil.which("bun")
    if bun is None:
        print("Incomplete: Bun is required for the configured remote gateway")
        return 4
    dest = work / "output"
    command = [
        bun, str(root / "build-platform/src/cli/index.ts"), "remote",
        "--timeout", str(args.timeout), "py", "--", str(leaf),
        "--tag", tag, "--pull", "--pull-exclude-build", "--dest", str(dest),
        "--data", str(tar_path), "--data", str(manifest_path),
        "--data", str(expected_path),
        "--env", "STORAMIC_UT_MANIFEST=" + manifest_path.name,
    ]
    env_pairs = []
    if args.slots is not None:
        env_pairs.append(("STORAMIC_UT_SLOTS", str(args.slots)))
    if args.wait is not None:
        env_pairs.append(("STORAMIC_UT_WAIT", str(args.wait)))
    if args.per_file_timeout is not None:
        env_pairs.append(("STORAMIC_UT_TIMEOUT", str(args.per_file_timeout)))
    for key, value in env_pairs:
        command += ["--env", f"{key}={value}"]
    rc = subprocess.call(command, cwd=root)
    result = dest / "unittests-result.json"
    if not result.exists():
        print(f"Incomplete: no unittests-result.json in {dest}")
        return 4
    record = json.loads(result.read_text())
    print(f"unittest verdict: {record.get('status')} "
          f"(init={record.get('init')}, slot={record.get('slot')}, "
          f"files={len(record.get('files', {}))}) -> {result}")
    return 0 if record.get("status") == "pass" and rc == 0 else (
        1 if record.get("status") in ("fail", "incomplete") else 4)


if __name__ == "__main__":
    sys.exit(main())
