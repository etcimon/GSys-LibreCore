// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dlopen, FFIType, suffix } from 'bun:ffi'
import { kitProjectDir, nativeExe, nativeLib, workspaceDir } from './paths.ts'
import { ensureForkedWasmOptSync } from './platform.ts'

export type Via = 'ffi' | 'exe' | 'auto'

export type RunResult = {
  status: number
  stdout: string
  stderr: string
  via: 'ffi' | 'exe'
}

let ffi: ReturnType<typeof loadFfi> | null | undefined

function loadFfi() {
  const lib = nativeLib()
  if (!existsSync(lib)) return null
  try {
    const { symbols } = dlopen(lib, {
      svelte_d_version: { args: [], returns: FFIType.i32 },
      svelte_d_drop_ws: {
        args: [FFIType.cstring, FFIType.i32],
        returns: FFIType.i32,
      },
      svelte_d_compile: { args: [FFIType.cstring], returns: FFIType.i32 },
      svelte_d_parse_svelte: { args: [FFIType.cstring], returns: FFIType.i32 },
    })
    if (symbols.svelte_d_version() < 1) return null
    return symbols
  } catch {
    return null
  }
}

export function ffiAvailable(): boolean {
  if (ffi === undefined) ffi = loadFfi()
  return ffi !== null
}

function useFfi(via: Via = 'auto'): boolean {
  if (via === 'exe') return false
  if (via === 'ffi') return ffiAvailable()
  // auto: prefer exe so stdout from parse/drop/compile is captured
  return !existsSync(nativeExe()) && ffiAvailable()
}

function runExe(args: string[]): RunResult {
  const exe = nativeExe()
  if (!existsSync(exe)) {
    throw new Error(
      `svelte-d exe missing at ${exe} — bun run build (ldc2 + dub) or dub build --config=application --compiler=ldc2`
    )
  }
  const r = spawnSync(exe, args, { encoding: 'utf8', shell: false })
  return {
    status: r.status ?? 1,
    stdout: r.stdout ?? '',
    stderr: r.stderr ?? '',
    via: 'exe',
  }
}

export function dropWorkspace(
  opts: { dest?: string; force?: boolean; via?: Via } = {}
): RunResult {
  const dest = opts.dest ?? workspaceDir()
  if (useFfi(opts.via) && ffi) {
    const status = ffi.svelte_d_drop_ws(Buffer.from(dest + '\0'), opts.force ? 1 : 0)
    return { status, stdout: '', stderr: '', via: 'ffi' }
  }
  const args = ['drop-ws', '--dest', dest]
  if (opts.force) args.push('--force')
  return runExe(args)
}

export type CompileOpts = {
  ws?: string
  project?: string
  via?: Via
  only?: string[]
}

export function compileWorkspace(
  wsOrOpts?: string | CompileOpts,
  via: Via = 'auto'
): RunResult {
  let dest = workspaceDir()
  let project = ''
  let v = via
  if (typeof wsOrOpts === 'string') dest = wsOrOpts
  else if (wsOrOpts) {
    if (wsOrOpts.ws) dest = wsOrOpts.ws
    if (wsOrOpts.project) project = wsOrOpts.project
    if (wsOrOpts.via) v = wsOrOpts.via
  }
  if (!project) project = kitProjectDir()
  if (useFfi(v) && ffi && !project) {
    const status = ffi.svelte_d_compile(Buffer.from(dest + '\0'))
    return { status, stdout: '', stderr: '', via: 'ffi' }
  }
  const args = ['compile', '--ws', dest]
  if (project) args.push('--project', project)
  const only = typeof wsOrOpts === 'object' && wsOrOpts?.only ? wsOrOpts.only : []
  for (const o of only) {
    if (o) args.push('--only', o)
  }
  return runExe(args)
}

function pinForkedWasmOpt(): void {
  process.env.SVELTE_D_NO_BUILD_WASM_OPT = '1'
  try {
    const bin = ensureForkedWasmOptSync()
    if (bin) process.env.SVELTE_D_WASM_OPT = bin
  } catch (e) {
    console.warn(
      'svelte-d: forked wasm-opt download skipped —',
      e instanceof Error ? e.message : e
    )
  }
}

export function buildWasm(
  ws?: string,
  opts: { probes?: boolean; force?: boolean; mode?: 'debug' | 'release' } = {}
): RunResult {
  pinForkedWasmOpt()
  const dest = ws ?? workspaceDir()
  const args = ['wasm', '--ws', dest]
  if (opts.probes) args.push('--probes')
  if (opts.force) args.push('--force')
  if (opts.mode === 'debug') args.push('--debug')
  else if (opts.mode === 'release') args.push('--release')
  return runExe(args)
}

export function buildHost(
  ws?: string,
  opts: { mode?: 'debug' | 'release' } = {}
): RunResult {
  const dest = typeof ws === 'string' ? ws : workspaceDir()
  const args = ['host', '--ws', dest]
  if (opts.mode === 'release') args.push('--release')
  else if (opts.mode === 'debug') args.push('--debug')
  return runExe(args)
}

export function parseSvelte(path: string, via: Via = 'auto'): RunResult {
  if (useFfi(via) && ffi) {
    const status = ffi.svelte_d_parse_svelte(Buffer.from(path + '\0'))
    return { status, stdout: '', stderr: '', via: 'ffi' }
  }
  return runExe(['parse', path])
}

export function runCli(args: string[]): RunResult {
  return runExe(args)
}

void suffix
