// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * svelte-engine-ws wasm cell — svelte-d `workspace/wasm_build.d`:
 *   dub build --arch=wasm32-unknown-wasi --compiler=<LDC 1.43> --config=application
 * DFLAGS/DC/DMD cleared so 1.41 objects never mix. Host vibe.0 cell refused.
 */
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { type Toolchain } from "./ldc.ts";

export type WasmCellResult = {
  status: number;
  via: "dub" | "skip";
  reason: string;
  raw: string;
  ship: string;
  log: string;
};

function posix(p: string): string {
  return p.replace(/\\/g, "/");
}

/** Engine `dub.sdl` (wasm-eh / ldc-master), BIOS target names. */
export function engineDubSdl(libwasm: string): string {
  const lib = libwasm
    ? `dependency "libwasm" path="${posix(libwasm)}"\n`
    : `dependency "libwasm" version=">=0.11.1" repository="git+https://github.com/etcimon/libwasm.git"\n`;
  return `name "svelte-engine"
description "BIOS-UI wasm cell: libwasm SPA (svelte-d fall-through). Not vibe.0."
authors "Etienne Cimon"
copyright "Copyright © 2026, Etienne Cimon"
license "MIT"
dflags "--wasm-enable-eh" "-mattr=+exception-handling" "-fvisibility=hidden" "-fno-moduleinfo"
versions "G6LC_G6B"
targetPath "public"
targetName "bios-ui-raw"
sourcePaths "src-d"
stringImportPaths "src-d-views"
buildRequirements "allowWarnings"

configuration "application" {
    targetType "executable"
    dflags "-link-internally" "-defaultlib=" "--foptimize-nothrow=false" "-disable-linker-strip-dead"
    lflags "--export=_start" "--export=dumpApp" "--export=loadApp" "--export=allocString"
    postBuildCommands "node -e \\"require('fs').copyFileSync('public/bios-ui-raw.wasm','public/bios-ui.wasm')\\""
    ${lib}    subConfiguration "libwasm" "ldc-master"
}

configuration "ldc-master" {
    targetType "executable"
    dflags "-link-internally" "-defaultlib=" "--foptimize-nothrow=false" "-disable-linker-strip-dead"
    lflags "--export=_start" "--export=dumpApp" "--export=loadApp" "--export=allocString"
    postBuildCommands "node -e \\"require('fs').copyFileSync('public/bios-ui-raw.wasm','public/bios-ui.wasm')\\""
    ${lib}    subConfiguration "libwasm" "ldc-master"
}

buildType "debug" {
    buildOptions "debugMode" "debugInfo"
}

buildType "release" {
    buildOptions "releaseMode" "optimize" "inline"
    lflags "-strip-all"
}
`;
}

export function pinWasmLdc(ws: string, tc: Toolchain): void {
  mkdirSync(join(ws, ".svelte-d"), { recursive: true });
  const body = JSON.stringify(
    {
      schema: "svelte-d-wasm-ldc/v1",
      ldc: posix(tc.ldc),
      dub: posix(tc.dub),
      libwasm: posix(tc.libwasm),
      cell: "wasm-eh",
      version: tc.versionLine,
      ok: tc.ok,
    },
    null,
    2,
  ) + "\n";
  writeFileSync(join(ws, ".svelte-d", "wasm-ldc.json"), body);
}

function cellEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  delete env.DFLAGS;
  delete env.DC;
  delete env.DMD;
  return env;
}

export function addLocalLibwasm(tc: Toolchain): string {
  if (!tc.dub || !tc.libwasm) return "skip add-local";
  spawnSync(tc.dub, ["remove-local", tc.libwasm], {
    encoding: "utf8",
    shell: false,
    env: cellEnv(),
  });
  const r = spawnSync(tc.dub, ["add-local", tc.libwasm, "~master"], {
    encoding: "utf8",
    shell: false,
    env: cellEnv(),
  });
  const out = (r.stdout || "") + (r.stderr || "");
  if ((r.status ?? 1) !== 0) return `add-local failed: ${out}`;
  return `dub add-local ${tc.libwasm} ~master`;
}

/** 0 = built/skipped, 2 = dub failed, 3 = LDC 1.43 missing. */
export function buildWasmCell(
  ws: string,
  tc: Toolchain,
  opts: { force?: boolean; buildType?: "debug" | "release" } = {},
): WasmCellResult {
  const raw = join(ws, "public", "bios-ui-raw.wasm");
  const ship = join(ws, "public", "bios-ui.wasm");
  pinWasmLdc(ws, tc);
  if (!tc.ok) {
    const reason = !tc.ldc
      ? "no LDC 1.43 (refusing PATH 1.41/1.42; set SVELTE_D_LDC or riscv-compilers/ldc2-build)"
      : "dub missing";
    writeFileSync(
      join(ws, ".svelte-d", "wasm-build.json"),
      JSON.stringify({ ok: false, via: "skip", reason }, null, 2) + "\n",
    );
    return { status: 3, via: "skip", reason, raw, ship, log: reason };
  }
  mkdirSync(join(ws, "public"), { recursive: true });
  const local = addLocalLibwasm(tc);
  const buildType = opts.buildType ?? "release";
  const args = [
    "build",
    "--arch=wasm32-unknown-wasi",
    `--compiler=${tc.ldc}`,
    "--config=application",
    `--build=${buildType}`,
  ];
  const r = spawnSync(tc.dub, args, {
    cwd: ws,
    encoding: "utf8",
    shell: false,
    env: cellEnv(),
  });
  const log = `${local}\n+ ${tc.dub} ${args.join(" ")}\n${r.stdout || ""}${r.stderr || ""}`;
  const ok = (r.status ?? 1) === 0 && (existsSync(ship) || existsSync(raw));
  writeFileSync(
    join(ws, ".svelte-d", "wasm-build.json"),
    JSON.stringify(
      {
        ok,
        via: "dub",
        status: r.status ?? 1,
        compiler: posix(tc.ldc),
        version: tc.versionLine,
        args,
      },
      null,
      2,
    ) + "\n",
  );
  writeFileSync(join(ws, ".svelte-d", "wasm-build.log"), log);
  return {
    status: ok ? 0 : 2,
    via: "dub",
    reason: ok ? "ok" : `dub status ${r.status}`,
    raw,
    ship,
    log,
  };
}
