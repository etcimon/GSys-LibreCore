// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Wasm + vibe.0 host cells. `dev` is --build=debug (symbols kept).
// `build` is --build=release plus lflags -strip-all.
import { spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { findLdc, optimizeWasm } from 'svelte-d'
import {
  adminWorkspace,
  fileBytes,
  fmtBytes,
  hostExePath,
  pinHostBotanConfig,
  wasmPath,
  writeWorkspaceEnv,
} from './ws.ts'

export type CellMode = 'debug' | 'release'

export type CellBuild = {
  mode: CellMode
  status: number
  path: string
  bytes: number
  label: string
  stdout: string
}

export type DualSizes = {
  workspace: string
  mode: CellMode | 'compare'
  wasm: { debug: CellBuild; release: CellBuild }
  host: { debug: CellBuild; release: CellBuild }
}

function ldcBin(): string {
  const found = findLdc()
  if (found) {
    process.env.SVELTE_D_LDC = found
    process.env.WASM_LDC = found
    process.env.LDC = found
  }
  return found
}

function cleanEnv(): NodeJS.ProcessEnv {
  const env = { ...process.env }
  delete env.DFLAGS
  delete env.DC
  delete env.DMD
  return env
}

function dub(args: string[], cwd: string): { status: number; out: string } {
  const r = spawnSync('dub', args, {
    cwd,
    encoding: 'utf8',
    env: cleanEnv(),
  })
  return { status: r.status ?? 1, out: (r.stdout ?? '') + (r.stderr ?? '') }
}

/** Release keeps -strip-all; debug does not. */
export function pinWasmBuildModes(ws = adminWorkspace()): void {
  const sdl = join(ws, 'dub.sdl')
  if (!existsSync(sdl)) return
  let src = readFileSync(sdl, 'utf8')
  src = src.replace(/^lflags "-strip-all"\r?\n/m, '')
  src = src.replace(/lflags "-strip-all" "/g, 'lflags "')
  if (!src.includes('buildType "release"')) {
    src += `

buildType "debug" {
    buildOptions "debugMode" "debugInfo"
}

buildType "release" {
    buildOptions "releaseMode" "optimize" "inline"
    lflags "-strip-all"
}
`
  }
  writeFileSync(sdl, src)
}

/** Host release: optimize + lflags -strip-all (POSIX) / OPT:REF+DEBUG:NONE (Windows). */
export function pinHostBuildModes(ws = adminWorkspace()): void {
  pinHostBotanConfig(ws)
  const sdl = join(ws, 'webserver', 'dub.sdl')
  if (!existsSync(sdl)) return
  let src = readFileSync(sdl, 'utf8')
  const releaseBlock = `
buildType "debug" {
    buildOptions "debugMode" "debugInfo"
}

buildType "release" {
    buildOptions "releaseMode" "optimize" "inline"
    lflags "-strip-all"
    lflags "/OPT:REF" "/OPT:ICF" "/DEBUG:NONE" platform="windows"
}
`
  if (src.includes('buildType "release"')) {
    src = src.replace(/\nbuildType "debug" \{[\s\S]*?\n\}\r?\n\r?\nbuildType "release" \{[\s\S]*?\n\}\r?\n?/, releaseBlock)
  } else {
    src += releaseBlock
  }
  writeFileSync(sdl, src)
}

function snapshot(path: string, dest: string): void {
  if (!path || !existsSync(path)) return
  copyFileSync(path, dest)
}

export function buildWasmCell(mode: CellMode, ws = adminWorkspace(), force = true): CellBuild {
  const ldc = ldcBin()
  pinWasmBuildModes(ws)
  const empty: CellBuild = { mode, status: 3, path: '', bytes: 0, label: '0 bytes', stdout: '' }
  if (!ldc) return { ...empty, stdout: 'no LDC 1.43' }
  const args = [
    'build',
    '--arch=wasm32-unknown-wasi',
    '--compiler=' + ldc,
    '--config=application',
    '--build=' + mode,
  ]
  if (force) args.push('--force')
  const r = dub(args, ws)
  const pub = join(ws, 'public')
  const raw = join(pub, 'svelte-engine-raw.wasm')
  const ship = join(pub, 'svelte-engine.wasm')
  if (existsSync(raw)) copyFileSync(raw, ship)
  if (existsSync(ship) || existsSync(raw)) {
    const opt = optimizeWasm({
      input: existsSync(raw) ? raw : ship,
      output: ship,
      mode,
    })
    if (opt.skipped) console.log('wasm-opt skip  ' + opt.reason)
    else
      console.log(
        'wasm-opt ' + opt.reason + '  ' + opt.bytesIn + ' -> ' + opt.bytesOut
      )
  }
  const path = existsSync(ship) ? ship : existsSync(raw) ? raw : ''
  const bytes = fileBytes(path)
  return { mode, status: r.status, path, bytes, label: fmtBytes(bytes), stdout: r.out }
}

export function buildHostCell(mode: CellMode, ws = adminWorkspace()): CellBuild {
  const ldc = ldcBin()
  pinHostBuildModes(ws)
  writeWorkspaceEnv(ws)
  const empty: CellBuild = { mode, status: 3, path: '', bytes: 0, label: '0 bytes', stdout: '' }
  if (!ldc) return { ...empty, stdout: 'no LDC 1.43' }
  const dir = join(ws, 'webserver')
  const args = ['build', '--compiler=' + ldc, '--build=' + mode]
  if (mode === 'release') args.push('--force')
  const r = dub(args, dir)
  const path = hostExePath(ws)
  const bytes = fileBytes(path)
  return { mode, status: r.status, path, bytes, label: fmtBytes(bytes), stdout: r.out }
}

export function writeDualSizes(sizes: DualSizes, ws = adminWorkspace()): string {
  const dir = join(ws, '.svelte-d')
  mkdirSync(dir, { recursive: true })
  const dest = join(dir, 'artifact-sizes.json')
  writeFileSync(dest, JSON.stringify(sizes, null, 2) + '\n')
  return dest
}

/** Build debug then release+strip for both cells; leave release as the shipped names. */
export function compileCellsCompare(ws = adminWorkspace()): DualSizes {
  pinWasmBuildModes(ws)
  pinHostBuildModes(ws)
  writeWorkspaceEnv(ws)

  const wasmWas = wasmPath(ws)
  const hostWas = hostExePath(ws)
  if (wasmWas) snapshot(wasmWas, join(ws, 'public', 'svelte-engine.prev.wasm'))
  if (hostWas) snapshot(hostWas, hostWas + '.prev')

  const wasmDebug = buildWasmCell('debug', ws, true)
  if (wasmDebug.path) snapshot(wasmDebug.path, join(ws, 'public', 'svelte-engine.debug.wasm'))

  const wasmRelease = buildWasmCell('release', ws, true)
  if (wasmRelease.path) snapshot(wasmRelease.path, join(ws, 'public', 'svelte-engine.release.wasm'))

  const hostDebug = buildHostCell('debug', ws)
  if (hostDebug.path) snapshot(hostDebug.path, hostDebug.path + '.debug')

  const hostRelease = buildHostCell('release', ws)
  if (hostRelease.path) snapshot(hostRelease.path, hostRelease.path + '.release')

  const sizes: DualSizes = {
    workspace: ws,
    mode: 'compare',
    wasm: { debug: slim(wasmDebug), release: slim(wasmRelease) },
    host: { debug: slim(hostDebug), release: slim(hostRelease) },
  }
  writeDualSizes(sizes, ws)
  return sizes
}

function slim(b: CellBuild): CellBuild {
  return {
    mode: b.mode,
    status: b.status,
    path: b.path,
    bytes: b.bytes,
    label: b.label,
    stdout: b.status === 0 ? '' : b.stdout.slice(-800),
  }
}

export function formatDualSizes(s: DualSizes): string {
  const lines = [
    'workspace ' + s.workspace,
    'wasm  debug    ' + s.wasm.debug.label,
    'wasm  release  ' + s.wasm.release.label + '  (-strip-all + wasm-opt -Oz)',
    'host  debug    ' + s.host.debug.label,
    'host  release  ' + s.host.release.label + '  (-strip-all)',
  ]
  if (s.wasm.debug.bytes && s.wasm.release.bytes)
    lines.push(
      'wasm  delta    ' +
        fmtBytes(s.wasm.debug.bytes - s.wasm.release.bytes) +
        ' smaller in release'
    )
  if (s.host.debug.bytes && s.host.release.bytes)
    lines.push(
      'host  delta    ' +
        fmtBytes(s.host.debug.bytes - s.host.release.bytes) +
        ' smaller in release'
    )
  return lines.join('\n')
}
