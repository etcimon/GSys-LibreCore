// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { loadDebugMap, rewriteStack } from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import { runBlankCdp } from '../src/puppeteer.ts'

describe('kit-admin Puppeteer/CDP platform', () => {
  test('rewriteStack is the CDP sink even without Chrome', () => {
    const map = loadDebugMap(adminWorkspace())
    const raw = 'console src-d/routes/admin/users/page.d:30 each'
    const out = rewriteStack(map, raw)
    if (map.entries.some((e) => e.dest.includes('admin/users'))) {
      expect(out).toContain('[svelte ')
    } else {
      expect(out).toBe(raw)
    }
  })

  test('headless about:blank rewrites console when Chromium is present', async () => {
    const map = loadDebugMap(adminWorkspace())
    const session = await runBlankCdp(map)
    if (!session) {
      expect(true).toBe(true)
      return
    }
    expect(session.console.length).toBeGreaterThan(0)
    const hit = session.console.find((c) => c.text.includes('admin/page.d'))
    expect(hit).toBeTruthy()
    if (map.entries.some((e) => e.dest.includes('admin/page.d'))) {
      expect(hit?.rewritten).toContain('[svelte ')
    }
  }, 60_000)
})
