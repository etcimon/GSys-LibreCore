// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync, utimesSync } from 'node:fs'
import { join } from 'node:path'
import { buildWasm, compileWorkspace, dropWorkspace, workspaceDir } from 'svelte-d'

describe('wasm cell inside svelte-engine-ws', () => {
  test('svelte-d wasm builds or skips when wasm LDC is absent', () => {
    const ws = workspaceDir()
    expect(dropWorkspace({ force: true }).status).toBe(0)
    expect(compileWorkspace(ws).status).toBe(0)
    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('import lib.ClickField')
    expect(app).toContain('@child ClickField clickField')

    const r = buildWasm(ws)
    // 0 = built, 3 = no wasm LDC (gated)
    expect([0, 3]).toContain(r.status)
    if (r.status === 3) {
      expect(r.stdout + r.stderr).toMatch(/skip|LDC 1\.43|SVELTE_D_LDC|ldc2-build/)
      return
    }
    const raw = join(ws, 'public', 'svelte-engine-raw.wasm')
    const ship = join(ws, 'public', 'svelte-engine.wasm')
    expect(existsSync(raw) || existsSync(ship)).toBe(true)
    const man = join(ws, '.svelte-d', 'wasm.json')
    expect(existsSync(man)).toBe(true)
    const j1 = JSON.parse(readFileSync(man, 'utf8'))
    expect(j1.ok).toBe(true)
    expect(['objects', 'dub', 'skip']).toContain(j1.mode ?? 'dub')

    const dest = join(ws, 'src-d', 'lib', 'ClickField.d')
    if (existsSync(dest)) {
      const later = new Date(Date.now() + 5_000)
      utimesSync(dest, later, later)
      const r2 = buildWasm(ws)
      expect(r2.status).toBe(0)
      const j2 = JSON.parse(readFileSync(man, 'utf8'))
      expect(j2.ok).toBe(true)
      expect(['objects', 'dub']).toContain(j2.mode)
      if (j2.mode === 'objects') {
        expect(j2.compiled).toBeGreaterThan(0)
        expect(j2.objects).toBeGreaterThan(0)
        expect(existsSync(join(ws, '.svelte-d', 'o'))).toBe(true)
      }
    }
  }, 600_000)
})
