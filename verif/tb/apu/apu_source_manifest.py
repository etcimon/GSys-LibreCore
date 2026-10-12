#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Scoped source inventory for run-apu-regress.sh.

Two inventory modes:

  walk      os.walk() over SURFACES with directory exclusions and an
            extension/special-name filter — what the launcher does for a
            normal in-tree run.
  file-list APU_SOURCE_FILES names a newline-separated list of
            root-relative paths (the remote leaf's pushed file list).
            Listed files are hashed regardless of extension; a listed path
            that is not a regular file records ``null`` so a mid-run
            deletion shows up as identity drift.
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

SURFACES = ('core', 'corev_apu', 'vendor', 'common', 'config', 'verif/tb',
            'verif/regress', 'verif/core-v-verif/lib', 'software/apu-venus-probe',
            'specs/venus-protocol', 'verilator_config.vlt')
# Single-file surfaces live at the repo root (the soc stage needs the
# repo-root verilator_config.vlt); everything else is walked as a directory.
FILE_SURFACES = ('verilator_config.vlt',)
EXCLUDED_DIRS = {'.git', '.cache', '__pycache__', 'node_modules', 'obj_dir',
                 'build', 'out'}
# 'target' is deliberately NOT excluded: the hpdcache target directory is RTL
# required by Flist.cva6.
EXTENSIONS = {'.sv', '.svh', '.v', '.vh', '.c', '.h', '.cpp', '.cc', '.py', '.sh',
              '.sby', '.vlt', '.toml', '.xml', '.hex', '.exp', '.json', '.spv',
              '.s', '.elf', '.bin', '.dts', '.dtsi', '.tab', '.txt', '.comp',
              '.pay', '.ld', '.spvasm', '.glsl', '.yaml', '.yml', '.f', '.mk'}
EXTRA_NAMES = {'user-data', 'meta-data'}

CONFIGURATION_KEYS = ('TARGET_CFG', 'VERILATOR', 'VERILATOR_ROOT', 'YOSYS',
                      'NUM_JOBS', 'APU_REGRESS_TIMEOUT', 'G6LC_QEMU', 'G6LC_QLIB')


def _wanted(name: str) -> bool:
    return (Path(name).suffix.lower() in EXTENSIONS
            or name.startswith(('Flist.', 'Makefile'))
            or name in EXTRA_NAMES)


def _excluded(rel: Path) -> bool:
    return any(part in EXCLUDED_DIRS or part.startswith('work-ver')
               for part in rel.parts)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root: Path, files: list[str] | None = None) -> dict[str, str | None]:
    """Return ``{root-relative posix path: sha256|None}``, keys sorted."""
    root = Path(root)
    dir_surfaces = [s for s in SURFACES if s not in FILE_SURFACES]
    sources: dict[str, str | None] = {}
    if files is None:
        for surface in dir_surfaces:
            for directory, dirs, names in os.walk(root / surface):
                dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS
                                 and not d.startswith('work-ver'))
                for name in sorted(names):
                    p = Path(directory) / name
                    if _wanted(name):
                        sources[p.relative_to(root).as_posix()] = _sha256(p)
        for surface in FILE_SURFACES:
            p = root / surface
            if p.is_file():
                sources[surface] = _sha256(p)
    else:
        for entry in files:
            posix = Path(entry).as_posix()
            under = (posix in SURFACES
                     or any(posix.startswith(s + '/') for s in dir_surfaces))
            if not under or _excluded(Path(posix)):
                continue
            p = root / posix
            sources[posix] = _sha256(p) if p.is_file() else None
    return dict(sorted(sources.items()))


def _git(root: Path, *args: str) -> str | None:
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True)
    return result.stdout.decode().strip() if result.returncode == 0 else None


def manifest(root: Path, stages: str, files_from: Path | None,
             files: list[str] | None = None) -> dict:
    """Same JSON shape the runner's heredoc produced, plus inventory metadata.

    ``files_from`` (a newline-separated path list) wins over an inline
    ``files`` list; with neither, the inventory walks SURFACES.
    """
    mode = 'walk'
    file_list = None
    if files_from is not None:
        file_list = str(files_from)
        files = [line.strip() for line in
                 Path(files_from).read_text(encoding='utf-8').splitlines()
                 if line.strip()]
    if files is not None:
        mode = 'file-list'
    items = inventory(root, files)
    identity = hashlib.sha256(
        json.dumps(sorted(items.items()), separators=(',', ':')).encode()
    ).hexdigest()
    return {
        'schemaVersion': 1,
        'sourceSha256': identity,
        'sources': items,
        'gitHead': _git(root, 'rev-parse', 'HEAD'),
        'stages': stages.split(','),
        'proxyTag': os.environ.get('TH_PROXY_TAG'),
        'scope': 'scoped source inventory, not an elaborated build manifest',
        'configuration': {k: os.environ.get(k) for k in CONFIGURATION_KEYS},
        'inventoryMode': mode,
        'fileList': file_list,
        'fileCount': len(items),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f'usage: {argv[0]} ROOT STAGES', file=sys.stderr)
        return 2
    files_from = None
    env = os.environ.get('APU_SOURCE_FILES')
    if env:
        files_from = Path(env)
        if not files_from.is_file():
            print(f'APU_SOURCE_FILES unreadable: {env}', file=sys.stderr)
            return 4
    try:
        report = manifest(Path(argv[1]), argv[2], files_from)
    except OSError as exc:
        print(f'source manifest failed: {exc}', file=sys.stderr)
        return 4
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
