// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// D IR for wasm-eh is same-function try/catch (throwBoundary).
// When a dest wasm exists, run-probes.mjs must pass on raw and, if the
// etcimon fork asyncified it, on the ship module too.
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { workspaceDir, templateDir, compileWorkspace } from 'svelte-d'
import { WASM_ASYNCIFY_ARGS, WASM_EH_FEATURES } from 'svelte-d'

describe('wasm-eh D IR + probes', () => {
  test('throwBoundary is same-function try/catch Exception', () => {
    const ws = workspaceDir()
    const surf = join(ws, 'src-d', 'lib', 'combosurf.d')
    if (!existsSync(surf)) return
    const src = readFileSync(surf, 'utf8')
    expect(src).toContain('void throwBoundary(string msg)')
    expect(src).toContain('try { throw new Exception(msg); }')
    expect(src).toContain('catch (Exception e) { failBoundary(e.msg); }')
    const body = src.slice(src.indexOf('void throwBoundary'))
    expect(body.slice(0, 180)).not.toMatch(/\.await\b/)
  })

  test('wireAwait prints .await off the landing pad, with then fallback', () => {
    const ws = workspaceDir()
    if (existsSync(join(ws, 'src-d', 'app.d')))
      compileWorkspace({ ws, project: templateDir() })
    const cover = join(ws, 'src-d', 'lib', 'ComboCover.d')
    if (!existsSync(cover)) return
    const src = readFileSync(cover, 'utf8')
    const body = src.slice(src.indexOf('void wireAwait()'))
    expect(body).toContain('import await_status')
    expect(body).toContain('libwasmAwaitSupported()')
    expect(body).toMatch(/job\.await/)
    expect(body).toContain('libwasmAwaitFailed()')
    expect(body).toContain('libwasmAwaitError()')
    expect(body).toContain('eP.e =')
    expect(body).toContain('libwasmAwaitValue()')
    expect(body).toContain('vP.v =')
    expect(body).toContain('.then(delegate void(Any _v)')
    expect(body).not.toMatch(/try\s*\{\s*job\.await/)
  })

  test('WASM_ASYNCIFY_ARGS lists libwasm_await and not Flatten-crash flags', () => {
    expect(WASM_EH_FEATURES).toContain('--enable-exception-handling')
    expect(WASM_ASYNCIFY_ARGS.join(' ')).toContain('asyncify-imports@env.libwasm_await__void')
    expect(WASM_ASYNCIFY_ARGS).toContain('--optimize-level=0')
  })

  test('engine run-probes: D catch on raw and asyncified ship', () => {
    const probe = join(templateDir(), 'run-probes.mjs')
    const roots = [
      workspaceDir(),
      join(process.cwd(), 'packages', 'svelte-d-kit-admin', 'svelte-engine-ws'),
      join(process.cwd(), 'svelte-engine'),
    ]
    const files: string[] = []
    for (const root of roots) {
      for (const name of [
        'svelte-engine-raw.wasm',
        'svelte-engine-ay.wasm',
        'svelte-engine.wasm',
      ]) {
        const p = join(root, 'public', name)
        if (existsSync(p) && !files.includes(p)) files.push(p)
      }
    }
    if (!existsSync(probe) || !files.length) return
    const r = spawnSync('node', [probe, ...files], { encoding: 'utf8' })
    expect(r.status).toBe(0)
    expect((r.stdout || '') + (r.stderr || '')).toContain(
      'svelte_engine_eh_probe returned 1'
    )
  })
})
