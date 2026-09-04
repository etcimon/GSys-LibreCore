// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compileWorkspace, loadDebugMap, loadInspector } from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import { tryLoadPuppeteer } from '../src/puppeteer.ts'
import { assertNoDevtoolsFaults, attachPageDevtools, servePublic } from '../src/devtools-sink.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))

describe('I3 IR inspector: read-only debug-map listing', () => {
  test('compile wrote ir.json + inspector page; dests include admin IR', () => {
    const ws = adminWorkspace()
    if (
      !existsSync(join(ws, 'public', '__svelte-d', 'ir.html')) ||
      !loadInspector(ws).dests.some((d) => d.includes('AdminDash.d'))
    ) {
      expect(compileWorkspace({ ws, project }).status).toBe(0)
    }
    const ir = loadInspector(ws)
    expect(ir.schema).toBe('svelte-d-ir-inspector/v1')
    expect(ir.principle).toContain('inspector-is-read-only')
    expect(ir.entries).toBeGreaterThan(0)
    expect(ir.dests.some((d) => d.includes('AdminDash.d'))).toBe(true)
    expect(ir.dests.some((d) => d.includes('routes/admin/users/page.d'))).toBe(true)
    expect(ir.dests.some((d) => d.includes('routes/admin/features/page.d'))).toBe(true)
    expect(ir.dests.some((d) => d.includes('users/_id_/page.d'))).toBe(true)
    expect(ir.kinds.each).toBeGreaterThan(0)
    const html = readFileSync(join(ws, 'public', '__svelte-d', 'ir.html'), 'utf8')
    expect(html).toContain('svelte-d IR inspector')
    expect(html).toContain('Does not execute')
    expect(html).toContain('/__svelte-d/debug-map.json')
    expect(html).not.toContain('compile!(')
    expect(html).not.toContain('libwasm.init')
  })

  test('Chrome DevTools: IR inspector filter has no ABORT/pageerror', async () => {
    const puppeteer = await tryLoadPuppeteer()
    if (!puppeteer) return
    const ws = adminWorkspace()
    const srv = servePublic(ws, 5192)
    const browser = await puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-gpu'],
    })
    try {
      const page = await browser.newPage()
      const sink = await attachPageDevtools(page, loadDebugMap(ws))
      await page.goto(srv.origin + '/__svelte-d/ir.html', {
        waitUntil: 'domcontentloaded',
        timeout: 15_000,
      })
      await page.waitForFunction(
        () => {
          const t = document.getElementById('status')?.textContent ?? ''
          return t.includes('ir inspector') && /\d+ entries/.test(t)
        },
        { timeout: 10_000 }
      )
      await page.click('#q')
      await page.type('#q', 'AdminDash')
      const body = await page.$eval('#rows', (el) => el.textContent ?? '')
      expect(body).toMatch(/AdminDash/)
      await page.click('a[href="/__svelte-d/overlay.html"]').catch(() => null)
      assertNoDevtoolsFaults(sink, 'ir inspector filter')
    } finally {
      await browser.close()
      srv.stop()
    }
  }, 60_000)
})
