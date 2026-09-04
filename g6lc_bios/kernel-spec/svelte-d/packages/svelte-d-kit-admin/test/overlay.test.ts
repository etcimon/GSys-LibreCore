// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  compileWorkspace,
  loadDebugMap,
  loadOverlay,
  rewriteStack,
} from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import { tryLoadPuppeteer } from '../src/puppeteer.ts'
import { assertNoDevtoolsFaults, attachPageDevtools, servePublic } from '../src/devtools-sink.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))

describe('I2 overlay: compile diagnostics named by orig .svelte', () => {
  test('compile wrote overlay.json + overlay page; LDC dests rewrite', () => {
    const ws = adminWorkspace()
    const map0 = loadDebugMap(ws)
    const ov0 = existsSync(join(ws, 'public', '__svelte-d', 'overlay.json'))
      ? loadOverlay(ws)
      : null
    if (
      !existsSync(join(ws, 'public', '__svelte-d', 'overlay', 'index.html')) ||
      !map0.entries.some((e) => e.dest.replace(/\\/g, '/').includes('AdminDash.d')) ||
      !ov0?.diagnostics.some(
        (d) => d.status === 'hmr-each' && /:l:N:/.test(d.raw)
      )
    ) {
      expect(compileWorkspace({ ws, project }).status).toBe(0)
    }
    const ov = loadOverlay(ws)
    expect(ov.schema).toBe('svelte-d-overlay/v1')
    const each = ov.diagnostics.find((d) => d.status === 'hmr-each')
    expect(each).toBeTruthy()
    expect(each.raw).toMatch(/:l:N:/)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'overlay', 'index.html'))).toBe(true)
    expect(existsSync(join(ws, 'public', '__svelte-d', 'overlay.html'))).toBe(true)
    const html = readFileSync(join(ws, 'public', '__svelte-d', 'overlay', 'index.html'), 'utf8')
    expect(html).toContain('svelte-d overlay')
    expect(html).toContain('/__svelte-d/overlay.json')

    const map = loadDebugMap(ws)
    const ldc = rewriteStack(
      map,
      'src-d/lib/AdminDash.d(20,1): Error: undefined identifier show'
    )
    expect(ldc).toMatch(/AdminDash\.svelte/)
    expect(rewriteStack(map, 'unknown.c(1): Error: x')).toBe('unknown.c(1): Error: x')
  })

  test('Chrome DevTools: overlay page has no ABORT/pageerror', async () => {
    const puppeteer = await tryLoadPuppeteer()
    if (!puppeteer) return
    const ws = adminWorkspace()
    const srv = servePublic(ws, 5191)
    const browser = await puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-gpu'],
    })
    try {
      const page = await browser.newPage()
      const sink = await attachPageDevtools(page, loadDebugMap(ws))
      await page.goto(srv.origin + '/__svelte-d/overlay.html', {
        waitUntil: 'domcontentloaded',
        timeout: 15_000,
      })
      await page.waitForFunction(
        () => {
          const t = document.getElementById('status')?.textContent ?? ''
          return t.includes('compile') || t.includes('fail') || t.includes('overlay')
        },
        { timeout: 10_000 }
      )
      await page.click('#diags').catch(() => null)
      assertNoDevtoolsFaults(sink, 'overlay static')
    } finally {
      await browser.close()
      srv.stop()
    }
  }, 60_000)
})
