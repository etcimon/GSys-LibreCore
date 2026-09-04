// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  destFromWasmName,
  destToModule,
  demangleD,
  encodeNamedWasm,
  loadDebugMap,
  parseWasmNames,
  rewriteCdpStack,
  rewriteStack,
  writeWasmNameMap,
} from 'svelte-d'
import { ensureWasm } from '../src/wasm.ts'
import { adminWorkspace } from '../src/ws.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))
void project

describe('I4 wasm name section → orig .svelte', () => {
  test('parse name section from a synthetic module', () => {
    const buf = encodeNamedWasm([
      { name: 'lib.AdminDash.construct' },
      { name: '_start' },
    ])
    const names = parseWasmNames(buf)
    expect(names.map((n) => n.name)).toEqual(['lib.AdminDash.construct', '_start'])
    expect(names[0].index).toBe(0)
  })

  test('destFromWasmName joins D symbols onto printed dests; never invents', () => {
    const dests = [
      'src-d/lib/AdminDash.d',
      'src-d/routes/admin/page.d',
      'src-d/routes/admin/users/_id_/page.d',
    ]
    expect(destToModule('src-d/lib/AdminDash.d')).toBe('lib.AdminDash')
    expect(destToModule('src-d/routes/admin/users/_id_/page.d')).toBe(
      'routes.admin.users._id_.page'
    )
    expect(destFromWasmName('lib.AdminDash.construct', dests)).toBe('src-d/lib/AdminDash.d')
    expect(destFromWasmName('_D3lib9AdminDash9constructFZv', dests)).toBe('src-d/lib/AdminDash.d')
    expect(demangleD('_D3lib9AdminDash9constructFZv')).toEqual(['lib', 'AdminDash', 'construct'])
    expect(destFromWasmName('src-d/routes/admin/page.d:20', dests)).toBe(
      'src-d/routes/admin/page.d'
    )
    expect(destFromWasmName('_start', dests)).toBeNull()
    expect(destFromWasmName('malloc', dests)).toBeNull()
  })

  test('rewriteStack / rewriteCdpStack join wasm frames only when dest is known', () => {
    const map = loadDebugMap(adminWorkspace())
    const at = 'at lib.AdminDash.construct (wasm://wasm/svelte-engine.wasm:0:0)'
    const out = rewriteStack(map, at)
    if (map.entries.some((e) => e.dest.includes('AdminDash.d'))) {
      expect(out).toMatch(/AdminDash\.svelte/)
    }
    const start = rewriteCdpStack(map, [
      { url: 'wasm://wasm/svelte-engine.wasm', functionName: '_start', lineNumber: 0 },
    ])
    expect(start).toContain('_start')
    expect(start).not.toContain('[svelte ')
    const dash = rewriteCdpStack(map, [
      {
        url: 'wasm://wasm/svelte-engine.wasm',
        functionName: 'lib.AdminDash.construct',
        lineNumber: 0,
      },
    ])
    if (map.entries.some((e) => e.dest.includes('AdminDash.d'))) {
      expect(dash).toMatch(/AdminDash\.svelte/)
    }
  })

  test('writeWasmNameMap parses shipped wasm and writes schema', () => {
    const ws = adminWorkspace()
    const wasm = ensureWasm(ws)
    const report = writeWasmNameMap({ ws, wasm: wasm ?? undefined })
    expect(report.schema).toBe('svelte-d-wasm-names/v1')
    expect(report.principle).toContain('names-are-trace-only')
    expect(existsSync(join(ws, '.svelte-d', 'wasm-names.json'))).toBe(true)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'wasm-names.json'))).toBe(true)
    expect(report.named).toBeGreaterThanOrEqual(0)
    expect(report.joined).toBeLessThanOrEqual(report.named)
  })
})
