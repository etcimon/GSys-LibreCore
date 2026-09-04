// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  buildWasm,
  compileWorkspace,
  dropWorkspace,
  loadDebugMap,
  rewriteStack,
} from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import { tryLoadPuppeteer } from '../src/puppeteer.ts'
import { tryLoadPlaywright } from '../src/browsers.ts'
import { killPort, killProcessTree } from '../src/proc.ts'
import { ensureWasm } from '../src/wasm.ts'
import { assertNoDevtoolsFaults, attachPageDevtools } from '../src/devtools-sink.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 5188
const ORIGIN = `http://127.0.0.1:${PORT}`

async function waitHttp(url: string, ms = 20_000): Promise<boolean> {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    try {
      const r = await fetch(url)
      if (r.ok || r.status === 404) return true
    } catch {
      /* retry */
    }
    await new Promise((r) => setTimeout(r, 200))
  }
  return false
}

type ImplProbe = {
  root: boolean
  adminDash: boolean
  panel: boolean
  navbar: boolean
  rewriteIsFn: boolean
  rewriteDash: string
  rewritePage: string
  rewriteUsers: string
  rewriteId: string
  rewriteFeatures: string
  mapLen: number
  bodyText: string
}

const probeFn = () => {
  const w = window as unknown as {
    __svelteDRewrite?: (s: string) => string
    __svelteDDebugMap?: unknown[]
  }
  const rewrite = w.__svelteDRewrite
  return {
    root: !!document.querySelector('#root'),
    adminDash: !!document.querySelector('.admin-dash'),
    panel: !!document.querySelector('.panel'),
    navbar: !!document.querySelector('.navbar') || !!document.querySelector('nav'),
    rewriteIsFn: typeof rewrite === 'function',
    rewriteDash: typeof rewrite === 'function' ? rewrite('src-d/lib/AdminDash.d:20') : '',
    rewritePage: typeof rewrite === 'function' ? rewrite('src-d/routes/admin/page.d:20') : '',
    rewriteUsers: typeof rewrite === 'function' ? rewrite('src-d/routes/admin/users/page.d:20') : '',
    rewriteId:
      typeof rewrite === 'function' ? rewrite('src-d/routes/admin/users/_id_/page.d:20') : '',
    rewriteFeatures:
      typeof rewrite === 'function' ? rewrite('src-d/routes/admin/features/page.d:20') : '',
    mapLen: Array.isArray(w.__svelteDDebugMap) ? w.__svelteDDebugMap.length : 0,
    bodyText: (document.body?.innerText ?? '').slice(0, 500),
  }
}

function assertRewrite(impl: ImplProbe) {
  expect(impl.root).toBe(true)
  expect(impl.rewriteIsFn).toBe(true)
  expect(impl.mapLen).toBeGreaterThan(0)
  expect(impl.rewriteDash).toMatch(/AdminDash\.svelte/)
  expect(impl.rewritePage).toMatch(/admin\/\+page\.svelte/)
  expect(impl.rewriteUsers).toMatch(/admin\/users\/\+page\.svelte/)
  expect(impl.rewriteId).toMatch(/admin\/users\/\[id\]\/\+page\.svelte|admin\/users/)
  expect(impl.rewriteFeatures).toMatch(/admin\/features\/\+page\.svelte/)
}

describe('live admin DevTools: vite + chrome/firefox console', () => {
  test('SPA boots, debug-map rewrite, IR implementations, no wasm abort', async () => {
    killPort(PORT)
    const ws = adminWorkspace()
    if (!existsSync(join(ws, 'src-d', 'app.d'))) {
      const dropped = dropWorkspace({ dest: ws, force: existsSync(ws) })
      expect(dropped.status).toBe(0)
    }
    expect(compileWorkspace({ ws, project }).status).toBe(0)

    const app = readFileSync(join(ws, 'src-d', 'app.d'), 'utf8')
    expect(app).toContain('@child AdminDash adminDash')
    expect(app).toContain('@child KitRoutes kitRoutes')
    const kr = readFileSync(join(ws, 'src-d', 'kit_router.d'), 'utf8')
    expect(kr).toContain('setVisible!"adminPage"(adminLayout, true)')
    const dashIr = readFileSync(join(ws, 'src-d', 'lib', 'AdminDash.d'), 'utf8')
    expect(dashIr).toContain('struct AdminDash')
    expect(dashIr).toContain('@child Panel panel')
    expect(dashIr).toContain('@visible!"panel"')
    expect(dashIr).toContain('kind=if')
    expect(dashIr).toContain('AdminDash construct')
    const usersIr = readFileSync(join(ws, 'src-d', 'routes', 'admin', 'users', 'page.d'), 'utf8')
    expect(usersIr).toContain('UnorderedList!')
    expect(usersIr).toContain('kind=each')
    expect(usersIr).toContain('@visible!"users"')

    const map = loadDebugMap(ws)
    const dests = map.entries.map((e) => e.dest.replace(/\\/g, '/'))
    expect(dests.some((d) => d.includes('src-d/lib/AdminDash.d'))).toBe(true)
    expect(dests.some((d) => d.includes('routes/admin/page.d'))).toBe(true)
    expect(dests.some((d) => d.includes('routes/admin/users/page.d'))).toBe(true)
    expect(dests.some((d) => d.includes('routes/admin/users/_id_/page.d'))).toBe(true)
    expect(dests.some((d) => d.includes('routes/admin/features/page.d'))).toBe(true)
    expect(dests.some((d) => d.includes('routes/admin/logs/page.d'))).toBe(true)
    const kinds = new Set(map.entries.filter((e) => e.dest.includes('admin') || e.dest.includes('AdminDash')).map((e) => e.kind))
    expect(kinds.has('file')).toBe(true)
    expect(kinds.has('if')).toBe(true)
    expect(kinds.has('each')).toBe(true)
    expect(rewriteStack(map, 'src-d/lib/AdminDash.d:12')).toMatch(/AdminDash\.svelte/)

    const built = buildWasm(ws)
    expect([0, 3]).toContain(built.status)
    const wasm = ensureWasm(ws)
    const viteJs = join(ws, 'node_modules', 'vite', 'package.json')
    if (!existsSync(viteJs)) {
      const inst = spawn('bun', ['install'], { cwd: ws, stdio: 'inherit' })
      const code = await new Promise<number>((res) => inst.on('exit', (c) => res(c ?? 1)))
      expect(code).toBe(0)
    }

    const viteNames = ['vite.exe', 'vite.cmd', 'vite']
    let viteBin = 'vite'
    for (const n of viteNames) {
      const p = join(ws, 'node_modules', '.bin', n)
      if (existsSync(p)) {
        viteBin = p
        break
      }
    }
    const vite = spawn(viteBin, ['--host', '127.0.0.1', '--port', String(PORT), '--strictPort'], {
      cwd: ws,
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: viteBin === 'vite' || viteBin.endsWith('.cmd'),
    })
    let viteLog = ''
    vite.stdout?.on('data', (b) => {
      viteLog += String(b)
    })
    vite.stderr?.on('data', (b) => {
      viteLog += String(b)
    })
    try {
      const up = await waitHttp(ORIGIN + '/')
      if (!up) {
        throw new Error('vite did not listen on ' + ORIGIN + '\n' + viteLog)
      }
      const mapRes = await fetch(ORIGIN + '/__svelte-d/debug-map.json')
      expect(mapRes.ok).toBe(true)
      const pub = await mapRes.json()
      expect(pub.schema).toBe('svelte-d-debug-map/v1')
      expect(pub.entries.length).toBeGreaterThan(0)
      const pubDests = (pub.entries as { dest: string }[]).map((e) => e.dest.replace(/\\/g, '/'))
      expect(pubDests.some((d) => d.includes('AdminDash.d'))).toBe(true)
      expect(pubDests.some((d) => d.includes('routes/admin/page.d'))).toBe(true)

      const ovRes = await fetch(ORIGIN + '/__svelte-d/overlay.json')
      expect(ovRes.ok).toBe(true)
      const ovj = await ovRes.json()
      expect(ovj.schema).toBe('svelte-d-overlay/v1')
      expect(ovj.ok).toBe(true)
      let htmlRes = await fetch(ORIGIN + '/__svelte-d/overlay.html')
      if (!htmlRes.ok) htmlRes = await fetch(ORIGIN + '/__svelte-d/overlay/index.html')
      expect(htmlRes.ok).toBe(true)
      expect(await htmlRes.text()).toContain('svelte-d overlay')

      const irRes = await fetch(ORIGIN + '/__svelte-d/ir.json')
      expect(irRes.ok).toBe(true)
      const irj = await irRes.json()
      expect(irj.schema).toBe('svelte-d-ir-inspector/v1')
      expect(irj.entries).toBeGreaterThan(0)
      let irHtml = await fetch(ORIGIN + '/__svelte-d/ir.html')
      if (!irHtml.ok) irHtml = await fetch(ORIGIN + '/__svelte-d/ir/index.html')
      expect(irHtml.ok).toBe(true)
      expect(await irHtml.text()).toContain('svelte-d IR inspector')

      const wn = await fetch(ORIGIN + '/__svelte-d/wasm-names.json')
      expect(wn.ok).toBe(true)
      const wnj = await wn.json()
      expect(wnj.schema).toBe('svelte-d-wasm-names/v1')
      expect(wnj.named).toBeGreaterThanOrEqual(0)

      const puppeteer = await tryLoadPuppeteer()
      if (puppeteer) {
        const browser = await puppeteer.launch({
          headless: true,
          args: ['--no-sandbox', '--disable-gpu'],
        })
        try {
          const page = await browser.newPage()
          const cons: string[] = []
          page.on('console', (m) => cons.push(m.type() + ' ' + m.text()))
          page.on('pageerror', (e) => cons.push('pageerror ' + e.message))
          const mapLive = loadDebugMap(ws)
          const sink = await attachPageDevtools(page, mapLive)
          const res = await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded', timeout: 30_000 })
          expect(res?.ok() ?? false).toBe(true)
          await page
            .waitForFunction(
              () =>
                typeof (window as unknown as { __svelteDRewrite?: unknown }).__svelteDRewrite ===
                'function',
              { timeout: 15_000 }
            )
            .catch(() => null)
          // debug-bridge is JS; wait for libwasm _start to paint App.
          await page
            .waitForFunction(
              () =>
                !!document.querySelector('.navbar') ||
                !!document.querySelector('.dock') ||
                !!document.querySelector('.admin-dash'),
              { timeout: 20_000 }
            )
            .catch(() => null)
          await page.evaluate(() => {
            const w = window as unknown as { __svelteDRewrite?: (s: string) => string }
            if (typeof w.__svelteDRewrite === 'function') {
              console.info('svelte-d-probe', w.__svelteDRewrite('src-d/lib/AdminDash.d:20'))
              console.info('svelte-d-probe', w.__svelteDRewrite('src-d/routes/admin/page.d:20'))
            }
          })
          const impl = (await page.evaluate(probeFn)) as ImplProbe
          assertRewrite(impl)
          const abort = cons.filter((l) => /ABORT:/i.test(l))
          if (wasm) {
            expect(abort.length).toBe(0)
            assertNoDevtoolsFaults(sink, 'boot')
          }
          if (built.status === 0) {
            if (!impl.adminDash) {
              throw new Error(
                'admin-dash missing after wasm paint. body=' +
                  impl.bodyText +
                  ' cons=' +
                  cons.slice(-24).join(' | ')
              )
            }
            expect(impl.adminDash).toBe(true)
            expect(impl.panel).toBe(true)
          } else if (impl.adminDash) {
            expect(impl.panel).toBe(true)
          }
          const probeLine = cons.find((l) => /svelte-d-probe/.test(l) && /AdminDash\.svelte/.test(l))
          expect(probeLine).toBeTruthy()

          if (built.status === 0) {
            const adminHtml = await fetch(ORIGIN + '/admin')
            expect(adminHtml.ok).toBe(true)
            expect(await adminHtml.text()).toMatch(/id="root"|svelte-engine/)
            // In-page remount: same Spa!App. libwasm exportDelegate("navigate_to").
            await page.evaluate(async () => {
              history.pushState({}, '', '/admin')
              const w = window as unknown as { callNative?: (n: string, v: string) => Promise<void> }
              if (typeof w.callNative === 'function') await w.callNative('navigate_to', '/admin')
              else window.dispatchEvent(new PopStateEvent('popstate'))
            })
            await page
              .waitForFunction(() => !!document.querySelector('.admin-layout'), { timeout: 15_000 })
              .catch(() => null)
            const onAdmin = await page.evaluate(() => ({
              path: location.pathname,
              layout: !!document.querySelector('.admin-layout'),
              dash: !!document.querySelector('.admin-layout .admin-dash'),
              users: !!document.querySelector('.admin-users'),
              nav: (document.querySelector('.admin-layout nav')?.textContent ?? '').includes('Admin'),
              title: document.title,
              body: (document.body?.innerText ?? '').slice(0, 200),
            }))
            if (!onAdmin.layout) {
              throw new Error(
                'admin-layout missing after popstate /admin. ' + JSON.stringify(onAdmin)
              )
            }
            expect(onAdmin.layout).toBe(true)
            expect(onAdmin.dash).toBe(true)
            expect(onAdmin.users).toBe(false)
            expect(onAdmin.nav).toBe(true)
            assertNoDevtoolsFaults(sink, 'navigate /admin')
            await page.evaluate(async () => {
              const lay = document.querySelector('.admin-layout')
              if (lay) lay.id = 'kit-layout-stay'
              history.pushState({}, '', '/admin/users')
              const w = window as unknown as { callNative?: (n: string, v: string) => Promise<void> }
              if (typeof w.callNative === 'function') await w.callNative('navigate_to', '/admin/users')
              else window.dispatchEvent(new PopStateEvent('popstate'))
            })
            await page
              .waitForFunction(() => !!document.querySelector('.admin-users'), { timeout: 10_000 })
              .catch(() => null)
            const onUsers = await page.evaluate(() => ({
              sameLayout: !!document.getElementById('kit-layout-stay'),
              layout: !!document.querySelector('.admin-layout'),
              dash: !!document.querySelector('.admin-layout .admin-dash'),
              users: !!document.querySelector('.admin-users'),
            }))
            expect(onUsers.sameLayout).toBe(true)
            expect(onUsers.layout).toBe(true)
            expect(onUsers.users).toBe(true)
            expect(onUsers.dash).toBe(false)
            assertNoDevtoolsFaults(sink, 'navigate /admin/users')

            const kitNav = async (path: string, waitSel: string) => {
              await page.evaluate(async (p) => {
                history.pushState({}, '', p)
                const w = window as unknown as {
                  callNative?: (n: string, v: string) => Promise<void>
                }
                if (typeof w.callNative === 'function') await w.callNative('navigate_to', p)
                else window.dispatchEvent(new PopStateEvent('popstate'))
              }, path)
              await page
                .waitForFunction((s: string) => !!document.querySelector(s), { timeout: 10_000 }, waitSel)
                .catch(() => null)
            }
            const probeAdmin = () =>
              page.evaluate(() => {
                const w = window as unknown as {
                  __svelteDPopstate?: boolean
                  __svelteDLastPop?: string
                  callNative?: (n: string, v: string) => Promise<void>
                }
                return {
                  path: location.pathname,
                  sameLayout: !!document.getElementById('kit-layout-stay'),
                  layout: !!document.querySelector('.admin-layout'),
                  users: !!document.querySelector('.admin-users'),
                  user: !!document.querySelector('.admin-user'),
                  features: !!document.querySelector('.admin-features'),
                  logs: !!document.querySelector('.admin-logs'),
                  dash: !!document.querySelector('.admin-layout .admin-dash'),
                  popAttached: !!w.__svelteDPopstate,
                  lastPop: w.__svelteDLastPop ?? '',
                  hasCallNative: typeof w.callNative === 'function',
                }
              })

            await kitNav('/admin/users/42', '.admin-user')
            const onId = await probeAdmin()
            expect(onId.sameLayout).toBe(true)
            expect(onId.layout).toBe(true)
            expect(onId.user).toBe(true)
            expect(onId.users).toBe(false)
            expect(onId.dash).toBe(false)
            const idText = await page.$eval('.admin-user', (el) => el.textContent ?? '')
            expect(idText).toContain('42')
            assertNoDevtoolsFaults(sink, 'navigate /admin/users/42')

            await kitNav('/admin/features', '.admin-features')
            const onFeat = await probeAdmin()
            expect(onFeat.sameLayout).toBe(true)
            expect(onFeat.layout).toBe(true)
            expect(onFeat.features).toBe(true)
            expect(onFeat.user).toBe(false)
            await page.click('.click-field button, .admin-features button').catch(() => null)
            assertNoDevtoolsFaults(sink, 'navigate /admin/features + click')

            await kitNav('/admin/logs', '.admin-logs')
            const onLogs = await probeAdmin()
            expect(onLogs.sameLayout).toBe(true)
            expect(onLogs.layout).toBe(true)
            expect(onLogs.logs).toBe(true)
            expect(onLogs.features).toBe(false)
            assertNoDevtoolsFaults(sink, 'navigate /admin/logs')

            // popstate only — no callNative from the test.
            await page.evaluate(() => {
              history.pushState({}, '', '/admin/features')
              window.dispatchEvent(new PopStateEvent('popstate'))
            })
            await page
              .waitForFunction(() => !!document.querySelector('.admin-features'), {
                timeout: 10_000,
              })
              .catch(() => null)
            const onBack = await probeAdmin()
            if (!onBack.features) {
              throw new Error('popstate did not remount features ' + JSON.stringify(onBack))
            }
            expect(onBack.popAttached).toBe(true)
            expect(onBack.lastPop).toMatch(/\/admin\/features/)
            expect(onBack.hasCallNative).toBe(true)
            expect(onBack.sameLayout).toBe(true)
            expect(onBack.layout).toBe(true)
            expect(onBack.features).toBe(true)
            expect(onBack.logs).toBe(false)

            await page.evaluate(() => {
              history.pushState({}, '', '/admin/users/42')
              window.dispatchEvent(new PopStateEvent('popstate'))
            })
            await page
              .waitForFunction(() => !!document.querySelector('.admin-user'), {
                timeout: 10_000,
              })
              .catch(() => null)
            const onBackId = await probeAdmin()
            if (!onBackId.user) {
              throw new Error('popstate did not remount users/42 ' + JSON.stringify(onBackId))
            }
            expect(onBackId.sameLayout).toBe(true)
            expect(onBackId.user).toBe(true)
            expect(onBackId.features).toBe(false)
            const idAgain = await page.$eval('.admin-user', (el) => el.textContent ?? '')
            expect(idAgain).toContain('42')
            await page.click('.navbar a, .navbar .btn, .dock button').catch(() => null)
            assertNoDevtoolsFaults(sink, 'popstate remount + chrome click')
          }

          const ovPage = await browser.newPage()
          const ovSink = await attachPageDevtools(ovPage, mapLive)
          const ovGoto = await ovPage.goto(ORIGIN + '/__svelte-d/overlay.html', {
            waitUntil: 'domcontentloaded',
            timeout: 15_000,
          })
          if (!ovGoto?.ok()) {
            await ovPage.goto(ORIGIN + '/__svelte-d/overlay/index.html', {
              waitUntil: 'domcontentloaded',
              timeout: 15_000,
            })
          }
          await ovPage.waitForFunction(
            () => {
              const t = document.getElementById('status')?.textContent ?? ''
              return t.includes('compile clean') || t.includes('compile fail')
            },
            { timeout: 10_000 }
          )
          const status = await ovPage.$eval('#status', (el) => el.textContent ?? '')
          expect(status).toMatch(/compile clean|svelte-d-overlay/)
          assertNoDevtoolsFaults(ovSink, 'overlay.html')

          const irPage = await browser.newPage()
          const irSink = await attachPageDevtools(irPage, mapLive)
          const irGoto = await irPage.goto(ORIGIN + '/__svelte-d/ir.html', {
            waitUntil: 'domcontentloaded',
            timeout: 15_000,
          })
          if (!irGoto?.ok()) {
            await irPage.goto(ORIGIN + '/__svelte-d/ir/index.html', {
              waitUntil: 'domcontentloaded',
              timeout: 15_000,
            })
          }
          await irPage.waitForFunction(
            () => {
              const t = document.getElementById('status')?.textContent ?? ''
              return t.includes('ir inspector') && /\d+ entries/.test(t)
            },
            { timeout: 10_000 }
          )
          const irStatus = await irPage.$eval('#status', (el) => el.textContent ?? '')
          expect(irStatus).toMatch(/ir inspector/)
          const rows = await irPage.$$eval('#rows tr', (trs) => trs.length)
          expect(rows).toBeGreaterThan(0)
          const body = await irPage.$eval('#rows', (el) => el.textContent ?? '')
          expect(body).toMatch(/AdminDash/)
          await irPage.click('#q')
          await irPage.type('#q', 'features')
          const filtered = await irPage.$eval('#rows', (el) => el.textContent ?? '')
          expect(filtered.toLowerCase()).toMatch(/features/)
          assertNoDevtoolsFaults(irSink, 'ir.html filter')
        } finally {
          await browser.close()
        }
      }

      const pw = await tryLoadPlaywright()
      if (pw) {
        const browser = await pw.firefox.launch({ headless: true }).catch(() => null)
        if (browser) {
          try {
            const page = await browser.newPage()
            const cons: string[] = []
            page.on('console', (m) => cons.push(m.text()))
            page.on('pageerror', (e) => cons.push('pageerror ' + e.message))
            await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded', timeout: 30_000 })
            await page
              .waitForFunction(
                () =>
                  typeof (window as unknown as { __svelteDRewrite?: unknown }).__svelteDRewrite ===
                  'function',
                { timeout: 15_000 }
              )
              .catch(() => null)
            await page.evaluate(() => {
              const w = window as unknown as { __svelteDRewrite?: (s: string) => string }
              if (typeof w.__svelteDRewrite === 'function') {
                console.info('svelte-d-probe', w.__svelteDRewrite('src-d/lib/AdminDash.d:20'))
              }
            })
            const impl = (await page.evaluate(probeFn)) as ImplProbe
            assertRewrite(impl)
            expect(cons.some((l) => /ABORT:/i.test(l))).toBe(false)
          } finally {
            await browser.close()
          }
        }
      }
    } finally {
      killProcessTree(vite)
      killPort(PORT)
    }
    void viteLog
  }, 240_000)
})
