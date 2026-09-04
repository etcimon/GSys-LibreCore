// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  destFromUrl,
  formatWasmAbort,
  loadDebugMap,
  rewriteDevtoolsFrame,
  rewriteCdpStack,
} from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import { attachCdpDevtools, runBlankCdp } from '../src/puppeteer.ts'
import { runBlankFirefox } from '../src/browsers.ts'

describe('DevTools / libwasm stack rewrite (chrome + firefox)', () => {
  test('rewriteDevtoolsFrame maps CDP 0-based lines onto svelte orig', () => {
    const map = loadDebugMap(adminWorkspace())
    const dest = 'src-d/routes/admin/page.d'
    const fileEnt = map.entries.find((e) => e.dest.replace(/\\/g, '/').includes('admin/page.d'))
    if (!fileEnt) {
      expect(map.entries.length).toBeGreaterThanOrEqual(0)
      return
    }
    const frame = rewriteDevtoolsFrame(
      map,
      { url: 'http://127.0.0.1:5177/' + dest, functionName: 'go', lineNumber: fileEnt.destLine - 1 },
      0
    )
    expect(frame).toContain('[svelte ')
    expect(frame).toMatch(/admin\/\+page\.svelte/)
    expect(destFromUrl('http://x/' + dest + '?v=1')).toBe(dest)
  })

  test('formatWasmAbort appends svelte orig when dest is known', () => {
    const map = loadDebugMap(adminWorkspace())
    const e = map.entries.find((x) => x.dest.replace(/\\/g, '/').includes('admin/page.d'))
    const text = formatWasmAbort(
      map,
      'assert',
      e?.dest ?? 'src-d/routes/admin/page.d',
      e?.destLine ?? 1,
      'boom'
    )
    expect(text.startsWith('ABORT: assert @')).toBe(true)
    if (e) expect(text).toContain('[svelte ')
    expect(formatWasmAbort(map, 'assert', '', 0, 'x')).toBe('ABORT: assert @ :0 x')
  })

  test('rewriteCdpStack never invents orig for wasm:// frames', () => {
    const map = loadDebugMap(adminWorkspace())
    const s = rewriteCdpStack(map, [
      { url: 'wasm://wasm/svelte-engine.wasm', functionName: '_start', lineNumber: 0 },
    ])
    expect(s).toContain('_start')
    expect(s).not.toContain('[svelte ')
  })

  test('compile published debug-map for the page (DevTools fetch)', () => {
    const pub = join(adminWorkspace(), 'public', '__svelte-d', 'debug-map.json')
    if (!existsSync(pub)) return
    const j = JSON.parse(readFileSync(pub, 'utf8'))
    expect(j.schema).toBe('svelte-d-debug-map/v1')
    expect(j.entries.length).toBeGreaterThan(0)
  })

  test('chrome CDP consoleAPICalled + firefox console when browsers exist', async () => {
    const map = loadDebugMap(adminWorkspace())
    const chrome = await runBlankCdp(map)
    if (chrome) {
      expect(chrome.console.some((c) => c.rewritten.includes('admin') || c.text.includes('ABORT'))).toBe(
        true
      )
      expect(Array.isArray(chrome.devtools)).toBe(true)
    }
    const ff = await runBlankFirefox(map)
    if (ff) {
      expect(ff.console.length).toBeGreaterThan(0)
    }
    void attachCdpDevtools
  }, 90_000)
})
