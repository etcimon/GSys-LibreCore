# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Remote leaf: run the storamic Python unittest suite on the testharness.

Runs under ``testharness_proxy.py py``. A counting semaphore (flock slots under
``/opt/testharness/locks/storamic-unittest/``) serializes concurrent launches;
an init mutex guards a content-addressed code-base cache under
``/opt/testharness/cache/storamic-unittest/<aggregate-sha>/`` whose necessity is
validated by re-hashing every file against the uploaded manifest. Each expected
``test_*.py`` runs consecutively via ``python3 -m unittest discover -s
verif/tb/storamic -p <file> -v`` followed by one full discover whose total must
equal the sum of the per-file totals. The manifest is re-hashed afterwards to
detect test-induced drift. Only ``unittests-result.json`` and per-file logs are
written to ``output/`` for pull.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

LOCK_ROOT = Path("/opt/testharness/locks/storamic-unittest")
CACHE_ROOT = Path("/opt/testharness/cache/storamic-unittest")
TEST_START_DIR = "verif/tb/storamic"
TEST_PATTERN = "test_*.py"
# Skips are reported per test; any skip not on this allowlist makes the run
# incomplete. Start empty: every skip must be justified before it is allowed.
SKIP_ALLOWLIST = frozenset()
RAN_RE = re.compile(r"Ran (\d+) tests?")
# unittest ends with a single summary line ``OK`` / ``OK (skipped=N)`` or
# ``FAILED (key=N, key=N, ...)`` whose parenthesised list may order the keys
# arbitrarily (``errors=`` can precede ``failures=``, ``unexpected successes``
# carries a space). Parse the key=value pairs generically instead of assuming
# ``failures=`` comes first.
SUMMARY_RE = re.compile(r"^(OK|FAILED)\b\s*(?:\(([^)]*)\))?", re.M)
KV_RE = re.compile(r"([A-Za-z_][A-Za-z_ ]*?)\s*=\s*(\d+)")
SKIP_RE = re.compile(r"\.\.\. skipped ['\"]([^'\"]*)['\"]")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def aggregate_sha(manifest):
    """Order-independent digest over the {relpath: sha256} manifest."""
    digest = hashlib.sha256()
    for rel in sorted(manifest):
        digest.update(rel.encode())
        digest.update(b"\0")
        digest.update(manifest[rel].encode())
        digest.update(b"\n")
    return digest.hexdigest()


def _slot_paths(lock_root, slots):
    return [lock_root / f"slot-{i}.lock" for i in range(slots)]


def acquire_slot(lock_root, slots=1, wait_seconds=1800.0, poll=0.25):
    """Take one of ``slots`` flock slots; return (index, handle, waited).

    Raises TimeoutError when no slot frees within ``wait_seconds``. The caller
    must keep the returned handle open for the duration of the critical section
; closing it (or process exit) releases the slot.
    """
    lock_root.mkdir(parents=True, exist_ok=True)
    paths = _slot_paths(lock_root, slots)
    deadline = time.monotonic() + wait_seconds
    started = time.monotonic()
    while True:
        for index, path in enumerate(paths):
            handle = open(path, "a")
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return index, handle, time.monotonic() - started
            except OSError:
                handle.close()
        if time.monotonic() >= deadline:
            raise TimeoutError(
                f"no unittest slot free within {wait_seconds}s ({slots} slots)")
        time.sleep(poll)


def release_slot(handle):
    try:
        fcntl.flock(handle, fcntl.LOCK_UN)
    finally:
        handle.close()


def _hash_tree(root, manifest):
    """Return list of relpaths whose on-disk sha256 differs from ``manifest``."""
    bad = []
    for rel, expected in manifest.items():
        path = root / rel
        try:
            actual = sha256_file(path)
        except OSError:
            actual = None
        if actual != expected:
            bad.append(rel)
    return bad


def _verify_cache(dest, manifest):
    """True iff complete.json exists, its manifest equals ``manifest`` and every
    file on disk re-hashes to the recorded digest."""
    complete = dest / "complete.json"
    if not complete.is_file():
        return False
    try:
        recorded = json.loads(complete.read_text()).get("manifest")
    except (OSError, ValueError):
        return False
    if recorded != manifest:
        return False
    return not _hash_tree(dest, manifest)


def _extract_tar(tar_path, staging):
    staging.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tar_path, "r:*") as archive:
        archive.extractall(staging)


def _write_complete(dest, manifest, agg, source):
    (dest / "complete.json").write_text(json.dumps({
        "aggregate_sha256": agg, "manifest": manifest, "source": source,
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, indent=2, sort_keys=True))


def _prune_cache(cache_root, keep=3):
    """Remove oldest complete cache entries beyond ``keep`` (own dirs only)."""
    entries = [p for p in cache_root.iterdir()
               if p.is_dir() and (p / "complete.json").is_file()]
    entries.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    for stale in entries[keep:]:
        shutil.rmtree(stale, ignore_errors=True)


def init_cache(cache_root, agg, manifest, tar_path, lock_path):
    """Initialize/validate the code-base cache under the init mutex.

    Returns (status, repo_root) where status is "reused", "created" or
    "repaired". Raises RuntimeError if the extracted tree fails verification —
    tests must never run on an unverified tree.
    """
    cache_root.mkdir(parents=True, exist_ok=True)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a") as mutex:
        fcntl.flock(mutex, fcntl.LOCK_EX)
        try:
            dest = cache_root / agg
            if dest.is_dir() and _verify_cache(dest, manifest):
                _prune_cache(cache_root)
                return "reused", dest
            reason = "absent" if not dest.is_dir() else "verification-failed"
            staging = Path(tempfile.mkdtemp(prefix=".init-", dir=cache_root))
            try:
                _extract_tar(tar_path, staging)
                bad = _hash_tree(staging, manifest)
                if bad:
                    raise RuntimeError(
                        "STORAMIC_UT_INIT_HASH_MISMATCH: " + ",".join(bad[:8]))
                _write_complete(staging, manifest, agg, str(tar_path))
                if dest.exists():
                    shutil.rmtree(dest)
                os.rename(staging, dest)
            finally:
                if staging.exists():
                    shutil.rmtree(staging, ignore_errors=True)
            _prune_cache(cache_root)
            return ("created" if reason == "absent" else "repaired"), dest
        finally:
            fcntl.flock(mutex, fcntl.LOCK_UN)


def parse_unittest_output(text):
    """Extract (ran, failures, errors, skipped, ok, ...) from -v output.

    The final ``OK``/``FAILED (...)`` summary is the LAST matching line; its
    parenthesised ``key=value`` list is parsed generically so ``errors=``-only,
    ``unexpected successes=`` and reordered variants are all counted.
    """
    ran = int(RAN_RE.search(text).group(1)) if RAN_RE.search(text) else 0
    matches = list(SUMMARY_RE.finditer(text))
    status, paren = (matches[-1].group(1), matches[-1].group(2)) if matches \
        else (None, None)
    kv = {}
    if paren:
        for key, val in KV_RE.findall(paren):
            kv[key.strip()] = int(val)
    failures = kv.get("failures", 0)
    errors = kv.get("errors", 0)
    skipped = kv.get("skipped", 0)
    unexpected = kv.get("unexpected successes", 0)
    expected_fail = kv.get("expected failures", 0)
    reasons = SKIP_RE.findall(text)
    return {"ran": ran, "failures": failures, "errors": errors,
            "skipped": skipped, "unexpected_successes": unexpected,
            "expected_failures": expected_fail,
            "ok": status == "OK", "status": status,
            "skip_reasons": reasons}


def run_one_file(repo_root, pattern, timeout):
    """Run unittest discover for ``pattern``; return log text + parsed summary."""
    cmd = [sys.executable, "-m", "unittest", "discover",
           "-s", TEST_START_DIR, "-p", pattern, "-v"]
    started = time.monotonic()
    try:
        proc = subprocess.run(cmd, cwd=str(repo_root), capture_output=True,
                              text=True, timeout=timeout)
        text = proc.stdout + proc.stderr
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        text = (exc.stdout or "") + (exc.stderr or "")
        if isinstance(text, bytes):
            text = text.decode(errors="replace")
        timed_out = True
    elapsed = time.monotonic() - started
    summary = parse_unittest_output(text)
    summary["timed_out"] = timed_out
    summary["seconds"] = round(elapsed, 3)
    summary["returncode"] = None if timed_out else proc.returncode
    return text, summary


def compute_verdict(expected, discovered, per_file, full, drift, init_status):
    """Decide pass/incomplete. Pure function for unit testing."""
    reasons = []
    if sorted(discovered) != sorted(expected):
        reasons.append("test-set-mismatch")
    total = 0
    for name in expected:
        rec = per_file.get(name)
        if rec is None:
            reasons.append(f"missing:{name}")
            continue
        if rec["timed_out"]:
            reasons.append(f"timeout:{name}")
        if rec["ran"] < 1:
            reasons.append(f"no-tests:{name}")
        if not rec.get("ok"):
            reasons.append(f"not-ok:{name}")
        rc = rec.get("returncode")
        if rc is not None and rc != 0:
            reasons.append(f"rc:{name}")
        if (rec["failures"] or rec["errors"]
                or rec.get("unexpected_successes")):
            reasons.append(f"failed:{name}")
        total += rec["ran"]
        for reason in rec.get("skip_reasons", []):
            if reason not in SKIP_ALLOWLIST:
                reasons.append(f"unlisted-skip:{name}:{reason}")
    if full is None or full.get("timed_out"):
        reasons.append("full-discover-timeout")
    else:
        if not full.get("ok"):
            reasons.append("full-not-ok")
        frc = full.get("returncode")
        if frc is not None and frc != 0:
            reasons.append("full-rc")
        if full["ran"] != total:
            reasons.append(f"total-mismatch:{full['ran']}!={total}")
    if drift:
        reasons.append("source-drift:" + ",".join(drift[:5]))
    status = "incomplete" if reasons else "pass"
    return {"status": status, "reasons": reasons, "init": init_status,
            "total_tests": total if not reasons else None}


def _discover_tests(repo_root):
    """The remote-discovered ``test_*.py`` set under the start dir."""
    return sorted(p.name for p in (repo_root / TEST_START_DIR).glob(TEST_PATTERN))


def main():
    data_dir = Path(os.environ["TH_DATA_DIR"])
    out_dir = Path(os.environ["TH_OUT_DIR"])
    out_dir.mkdir(parents=True, exist_ok=True)
    slots = int(os.environ.get("STORAMIC_UT_SLOTS", "1"))
    wait = float(os.environ.get("STORAMIC_UT_WAIT", "1800"))
    timeout = float(os.environ.get("STORAMIC_UT_TIMEOUT", "600"))

    archives = list(data_dir.glob("codebase-*.tar*"))
    manifests = list(data_dir.glob("manifest-*.json"))
    expected_files = list(data_dir.glob("expected-*.json"))
    if not (archives and manifests and expected_files):
        raise RuntimeError("STORAMIC_UT_MISSING_INPUTS")
    tar_path = archives[0]
    manifest = json.loads(manifests[0].read_text())
    expected = json.loads(expected_files[0].read_text())["tests"]
    agg = aggregate_sha(manifest)

    slot_index = None
    handle = None
    waited = 0.0
    init_status = "skipped"
    repo_root = None
    per_file = {}
    full = None
    drift = []
    discovered = []
    verdict = None
    error = None
    execution = {"started_utc": None, "ended_utc": None}
    try:
        slot_index, handle, waited = acquire_slot(LOCK_ROOT, slots, wait)
        init_status, repo_root = init_cache(
            CACHE_ROOT, agg, manifest, tar_path, LOCK_ROOT / "init.lock")
        # Scratch dir the suite may write into (tests use build-platform/workspace).
        (repo_root / "build-platform/workspace").mkdir(parents=True, exist_ok=True)
        execution["started_utc"] = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        execution["started_epoch"] = time.time()
        discovered = _discover_tests(repo_root)
        logs = out_dir / "logs"
        logs.mkdir(exist_ok=True)
        for name in sorted(expected):
            text, summary = run_one_file(repo_root, Path(name).name, timeout)
            per_file[name] = summary
            (logs / (Path(name).stem + ".log")).write_text(text)
        # One full discover; its total must equal the sum of per-file totals.
        full_text, full = run_one_file(repo_root, TEST_PATTERN, timeout)
        (logs / "full.log").write_text(full_text)
        drift = _hash_tree(repo_root, manifest)
        execution["ended_utc"] = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        execution["ended_epoch"] = time.time()
    except TimeoutError as exc:
        error = str(exc)
        verdict = {"status": "incomplete", "reasons": [error], "init": init_status}
    except Exception as exc:  # noqa: BLE001 - record any failure as incomplete
        error = f"{type(exc).__name__}: {exc}"
        verdict = {"status": "incomplete", "reasons": [error], "init": init_status}
    finally:
        if handle is not None:
            release_slot(handle)
    if verdict is None:
        verdict = compute_verdict(expected, discovered, per_file, full,
                                  drift, init_status)
    result = {
        "status": verdict["status"], "reasons": verdict.get("reasons", []),
        "error": error,
        "init": init_status, "slot": slot_index, "slot_wait_seconds": round(waited, 3),
        "aggregate_sha256": agg, "slots": slots, "per_file_timeout": timeout,
        "execution": execution,
        "files": {k: {kk: v[kk] for kk in
                      ("ran", "failures", "errors", "skipped",
                       "unexpected_successes", "expected_failures",
                       "ok", "status", "returncode", "timed_out",
                       "seconds", "skip_reasons")}
                  for k, v in per_file.items()},
        "full": {k: full.get(k) for k in
                 ("ran", "failures", "errors", "skipped",
                  "unexpected_successes", "expected_failures",
                  "ok", "status", "returncode", "timed_out")}
        if full else None,
        "discovered": discovered,
        "drift": drift, "expected": expected,
        "source_drift": drift,
    }
    (out_dir / "unittests-result.json").write_text(json.dumps(result, indent=2))
    print("STORAMIC_UT_" + result["status"].upper())
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
