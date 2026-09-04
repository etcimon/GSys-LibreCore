#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// bun bin: `bunx svelte-d compile --project .`
// Forwards to the native exe produced by `bun run build` / `bun install`.
import { existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const exeName = process.platform === 'win32' ? 'svelte-d.exe' : 'svelte-d'
const exe = join(root, 'packages', 'svelte-d', 'bin', exeName)

if (process.argv[2] === 'setup') {
  const setup = join(root, 'scripts', 'setup-platform.ts')
  const r = spawnSync(process.execPath, [setup, ...process.argv.slice(3)], {
    cwd: root,
    stdio: 'inherit',
  })
  process.exit(r.status ?? 1)
}

if (process.argv[2] === 'wasm' || process.argv[2] === 'build') {
  process.env.SVELTE_D_NO_BUILD_WASM_OPT = '1'
  const { ensureForkedWasmOpt } = await import('../packages/svelte-d/ts/platform.ts')
  try {
    const bin = await ensureForkedWasmOpt()
    if (bin) process.env.SVELTE_D_WASM_OPT = bin
  } catch (e) {
    console.warn(
      'svelte-d: forked wasm-opt download skipped —',
      e instanceof Error ? e.message : e
    )
  }
}

if (!existsSync(exe)) {
  const build = join(root, 'scripts', 'build-cli.ts')
  const b = spawnSync(process.execPath, [build], { cwd: root, stdio: 'inherit' })
  if ((b.status ?? 1) !== 0 || !existsSync(exe)) {
    console.error(
      'svelte-d CLI missing. From this package: bun run build  (needs ldc2 + dub)'
    )
    process.exit(1)
  }
}

const r = spawnSync(exe, process.argv.slice(2), { stdio: 'inherit' })
process.exit(r.status ?? 1)
