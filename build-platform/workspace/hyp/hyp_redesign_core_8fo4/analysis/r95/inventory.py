# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Refresh scoped Hyp source/caller candidates and immutable timing-task evidence.

This is a lexical search index, not an elaborator or a proof of a live path.
Run from the repository root with --repo <root> --tag <new-evidence-tag>.
"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess


TOKEN = re.compile(r"\b[A-Za-z_]\w*\b")
DECL = re.compile(r"\bmodule\s+(?:automatic\s+)?([A-Za-z_]\w*)")
INSTANCE = re.compile(r"\s*([A-Za-z_]\w*)\s*(?:\[[^\]]+\]\s*)*\(")
TRIVIA = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', re.S)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def clean_source(text):
    return TRIVIA.sub(lambda m: "".join("\n" if c == "\n" else " "
                                      for c in m.group()), text)


def instance_after(text, start):
    pos = start
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if text[pos:pos + 1] == "#":
        pos += 1
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if text[pos:pos + 1] != "(":
            return None
        depth = 1
        pos += 1
        while pos < len(text) and depth:
            depth += (text[pos] == "(") - (text[pos] == ")")
            pos += 1
        if depth:
            return None
    return INSTANCE.match(text, pos)


def git_head(repo):
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+", args.tag):
        parser.error("tag must contain only letters, digits and hyphens")
    repo = args.repo.resolve()
    here = Path(__file__).resolve().parent
    analysis = here.parent
    core = analysis.parent
    apu = core.parent / "hyp_redesign_corev_apu_8fo4"
    outputs = [here / f"{args.tag}-{name}.json"
               for name in ("sources", "analysis-index", "workqueue")]
    if any(p.exists() for p in outputs):
        raise SystemExit("Refusing to overwrite evidence; choose a new tag")

    head = git_head(repo)
    old = json.loads((analysis / "source-callers.json").read_text(encoding="utf-8"))
    old_files = {f["file"]: f for f in old["files"]}
    paths = {repo / name for name in old_files}
    for base in (core / "core", apu / "corev_apu"):
        paths.update(p for p in base.rglob("*")
                     if p.is_file() and p.suffix in {".sv", ".svh", ".v"}
                     and not {"obj_dir", ".git"} & set(p.parts))
    sources = []
    bodies = {}
    providers = defaultdict(list)
    missing = []
    for path in sorted(paths):
        name = path.relative_to(repo).as_posix()
        if not path.is_file():
            missing.append(name)
            continue
        data = path.read_bytes()
        body = clean_source(data.decode("utf-8-sig", errors="replace"))
        declarations = [{"name": m.group(1),
                         "line": body.count("\n", 0, m.start()) + 1}
                        for m in DECL.finditer(body)]
        previous = old_files.get(name, {})
        ref = (previous.get("reference_mapping") or {}).get("reference")
        if not ref:
            for base in (core, apu):
                if path.is_relative_to(base):
                    candidate = path.relative_to(base).as_posix()
                    if (repo / candidate).is_file():
                        ref = candidate
                    break
        reference = repo / ref if ref else None
        sources.append({
            "task_id": "C95-" + digest(name.encode("utf-8"))[:12],
            "file": name, "sha256": digest(data), "bytes": len(data),
            "changed_since_old_index": previous.get("sha256") != digest(data),
            "old_reference_mapping": previous.get("reference_mapping"),
            "reference": ref,
            "reference_sha256": digest(reference.read_bytes())
            if reference and reference.is_file() else None,
            "modules": declarations, "callers": [], "callees": [],
            "review_state": "inventory-only",
        })
        bodies[name] = body
        for declaration in declarations:
            providers[declaration["name"]].append(name)

    by_file = {f["file"]: f for f in sources}
    callers = defaultdict(list)
    for name, body in bodies.items():
        for token in TOKEN.finditer(body):
            module = token.group()
            if module not in providers:
                continue
            if re.search(r"\bmodule\s+(?:automatic\s+)?$",
                         body[max(0, token.start() - 40):token.start()]):
                continue
            instance = instance_after(body, token.end())
            if instance is None:
                continue
            call = {"file": name, "line": body.count("\n", 0, token.start()) + 1,
                    "module": module, "instance": instance.group(1)}
            callers[module].append(call)
            by_file[name]["callees"].append(
                dict(call, providers=providers[module]))
    for source in sources:
        source["callers"] = [
            c for m in source["modules"] for c in callers[m["name"]]]

    artifacts = []
    for base in (core / "analysis", apu / "analysis",
                 core.parent / "hyp_core_ws/analysis"):
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file():
                continue
            stat = path.stat()
            row = {"file": path.relative_to(repo).as_posix(),
                   "bytes": stat.st_size, "mtime_ns": stat.st_mtime_ns,
                   "semantic_review": "not-established-by-index"}
            if path.suffix == ".md":
                text = path.read_text(encoding="utf-8-sig", errors="replace")
                row["sha256"] = digest(path.read_bytes())
                row["headings"] = re.findall(r"^#{1,6} .+", text, re.M)
            artifacts.append(row)

    reports = []
    tasks = {}
    hash_cache = {}
    manifest_paths = list((analysis / "r94/boards").glob("final-*.manifest.json"))
    manifest_paths += list((here / "boards").glob("baseline-*.manifest.json"))
    for manifest_path in sorted(manifest_paths):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        report_path = manifest_path.with_name(
            manifest_path.name.replace(".manifest.json", ".json"))
        report_data = report_path.read_bytes()
        report = json.loads(report_data)
        bad = []
        for name, expected in manifest["sha256"].items():
            path = Path(name)
            canonical = path.resolve().as_posix()
            if canonical not in hash_cache:
                hash_cache[canonical] = (digest(path.read_bytes())
                                         if path.is_file() else None)
            if hash_cache[canonical] != expected:
                bad.append(name)
        identity = {
            "profile": manifest["group"],
            "manifest": manifest_path.relative_to(repo).as_posix(),
            "manifest_sha256": digest(manifest_path.read_bytes()),
            "report": report_path.relative_to(repo).as_posix(),
            "report_sha256": digest(report_data),
            "versions": report["versions"], "argv": manifest["argv"],
            "input_count": len(manifest["sha256"]), "changed_inputs": bad,
            "returncode": manifest["returncode"],
            "skipped_files": report["skipped_files"],
            "qualification": "module-local binding; live hierarchy unqualified",
        }
        reports.append(identity)
        modules = {m["id"]: m for m in report["modules"]}
        worst = {}
        for path in report["paths"]:
            key = (path["module_id"], path["path_kind"])
            if key not in worst or path["total_fo4"] > worst[key]["total_fo4"]:
                worst[key] = path
        for (module_id, kind), path in worst.items():
            if path["total_fo4"] <= 8:
                continue
            module = modules[module_id]["name"]
            task = tasks.setdefault(module, {
                "id": f"H95-{module}", "module": module,
                "providers": providers.get(module, []),
                "caller_candidates": callers.get(module, []),
                "paths": [], "status": "pending-source-and-caller-audit",
                "live_hierarchy": "not-established",
                "required_exit": [
                    "Confirm active specialization and observable sink.",
                    "Trace every source/output caller to its sequential owner.",
                    "State transfer, lifetime, reset, kill and reconvergence contract.",
                    "Compare prior exact/relocation/window alternatives.",
                    "Measure all path classes with matched identities.",
                    "Validate the smallest changed invariant, then its integration.",
                ],
            })
            task["paths"].append({
                "profile": manifest["group"], "kind": kind,
                "fo4": path["total_fo4"], "location": path["primary_loc"],
                "path_class": path["path_class"],
                "multi_cycle_label": path["multi_cycle"],
                "report": identity["report"], "path_id": path["path_id"],
                "inputs_match_current": not bad,
                "note": path["class_note"],
            })
    exclusions = {
        "g6lc_ai_fp_dot": "r94 simulation reference, not selected GEMM arithmetic",
        "g6lc_ai_gemm_arplan": "r94 found no live caller for this extraction",
        "g6lc_ai_cluster_set": "r94 found no live caller for this extraction",
        "g6lc_inval_bus": "r94 reset/NBA aggregation needs measurement audit",
        "g6lc_coherence_hub": "r94 top counter cone had no functional sink",
    }
    for module, reason in exclusions.items():
        if module in tasks:
            tasks[module]["prior_exclusion"] = reason
            tasks[module]["status"] = "audit-before-any-timing-credit"
    for source in sources:
        if digest((repo / source["file"]).read_bytes()) != source["sha256"]:
            raise SystemExit("Source changed during inventory; evidence not emitted")
    if git_head(repo) != head:
        raise SystemExit("HEAD changed during inventory; evidence not emitted")
    common = {
        "captured_utc": datetime.now(timezone.utc).isoformat(),
        "git_head": head, "tool_sha256": digest(Path(__file__).read_bytes()),
    }
    documents = [
        dict(common, schema="hyp8-r95-source-index.v1",
             method="Exact-token lexical instance candidates, not elaboration; "
                    "includes inactive branches and unflisted sources.",
             old_inventory_head=old["git_head"], missing=missing, files=sources),
        dict(common, schema="hyp8-r95-analysis-index.v1", files=artifacts),
        dict(common, schema="hyp8-r95-module-task-queue.v1",
             budget_fo4=8, fo4_ps=20, margin=0.2, reports=reports,
             tasks=sorted(tasks.values(), key=lambda t: t["module"])),
    ]
    for path, document in zip(outputs, documents):
        with path.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(document, stream, indent=2, ensure_ascii=True)
            stream.write("\n")
    print(json.dumps({
        "sources": len(sources), "module_names": len(providers),
        "changed_or_added_since_old_index": sum(
            f["changed_since_old_index"] for f in sources),
        "analysis_artifacts": len(artifacts), "high_fo4_module_tasks": len(tasks),
        "report_input_matches": {r["profile"]: not r["changed_inputs"]
                                 for r in reports},
        "outputs": [str(p) for p in outputs],
    }, indent=2))


if __name__ == "__main__":
    main()
