#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Produce bin/svelte-d (native CLI) so `bun install` / `bun run build`
// leaves a working compiler. Packs svelte-engine if the packaged copy
// is missing. Uses one LDC 1.43+ for the CLI (same compiler as wasm/host).
import { existsSync, mkdirSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { findDub, findLdc, setupPlatform } from '../packages/svelte-d/ts/platform.ts'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const compiler = join(root, 'packages', 'svelte-d')
const exeName = process.platform === 'win32' ? 'svelte-d.exe' : 'svelte-d'
const exe = join(compiler, 'bin', exeName)

function isEngineRoot(p: string): boolean {
  return existsSync(join(p, 'src-d', 'app.d')) && existsSync(join(p, 'dub.sdl'))
}

function run(cmd: string, args: string[], cwd: string): number {
  console.log('+', cmd, args.join(' '))
  const r = spawnSync(cmd, args, { cwd, stdio: 'inherit', shell: false })
  return r.status ?? 1
}

function ensurePackedEngine(): void {
  const packed = join(compiler, 'svelte-engine')
  if (isEngineRoot(packed)) return
  const pack = join(compiler, 'scripts', 'pack-engine.ts')
  if (!existsSync(pack)) {
    throw new Error('cannot pack svelte-engine: missing ' + pack)
  }
  const st = run(process.execPath, [pack], compiler)
  if (st !== 0) throw new Error('pack-engine failed status=' + st)
  if (!isEngineRoot(packed) && !isEngineRoot(join(compiler, 'templates', 'engine'))) {
    throw new Error('pack-engine did not produce packages/svelte-d/svelte-engine')
  }
}

async function buildNative(): Promise<void> {
  mkdirSync(join(compiler, 'bin'), { recursive: true })
  let ldc2 = findLdc()
  let dub = findDub(ldc2)
  if (!ldc2 || !dub) {
    const report = await setupPlatform({ download: true })
    ldc2 = report.ldc
    dub = report.dub
  }
  if (!ldc2 || !dub) {
    throw new Error(
      'svelte-d CLI build needs LDC 1.43 + dub. Run `bunx svelte-d setup` ' +
        '(downloads into ~/.svelte-d/toolchains) or set SVELTE_D_LDC. Missing: ' +
        (!ldc2 ? 'ldc2 ' : '') +
        (!dub ? 'dub' : '')
    )
  }
  const st = run(dub, ['build', '--config=application', '--compiler=' + ldc2], compiler)
  if (st !== 0) throw new Error('dub build application failed status=' + st)
  if (!existsSync(exe)) {
    throw new Error('dub build reported ok but ' + exe + ' is missing')
  }
  const libSt = run(dub, ['build', '--config=library', '--compiler=' + ldc2], compiler)
  if (libSt !== 0) {
    console.warn('svelte-d: library (bun:ffi) build skipped/failed status=' + libSt)
  }
}

const force =
  process.argv.includes('--force') ||
  process.env.npm_lifecycle_event === 'build' ||
  process.env.SVELTE_D_FORCE_BUILD === '1'
const packed = join(compiler, 'svelte-engine')
if (!force && existsSync(exe) && isEngineRoot(packed)) {
  console.log('svelte-d CLI already built', exe)
  process.exit(0)
}
ensurePackedEngine()
await buildNative()
console.log('svelte-d CLI', exe)
