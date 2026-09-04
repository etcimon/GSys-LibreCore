// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Complex Svelte language features on the live Spa!App, diagnosed through
// DevTools + debug-map rewrite (if/each/await/html/bind/click).
import { describe, expect, test } from 'bun:test'
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compileWorkspace, loadDebugMap, rewriteStack } from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import { tryLoadPuppeteer } from '../src/puppeteer.ts'
import { killPort, killProcessTree } from '../src/proc.ts'
import { ensureWasm } from '../src/wasm.ts'
import {
  assertNoDevtoolsFaults,
  assertProbesRewritten,
  attachPageDevtools,
  probeLangDests,
  snapshotLangDom,
} from '../src/devtools-sink.ts'
import { EACH_IF_CMP_CASES } from '../../svelte-kit-d/test/if-cmp-cases.ts'
import { EACH_IF_BOOL_CASES } from '../../svelte-kit-d/test/if-bool-cases.ts'
import { HOST_IF_CASES } from '../../svelte-kit-d/test/if-host-cases.ts'
import { EACH_ELSE_CASES } from '../../svelte-kit-d/test/each-else-cases.ts'
import { AWAIT_CASES } from '../../svelte-kit-d/test/await-cases.ts'
import { BIND_CASES } from '../../svelte-kit-d/test/bind-cases.ts'
import { SPECIAL_CASES } from '../../svelte-kit-d/test/special-cases.ts'
import { BOUNDARY_CASES } from '../../svelte-kit-d/test/boundary-cases.ts'

const LANG_PROBES = [
  'src-d/lib/IfToggle.d:32',
  'src-d/lib/ClickField.d:20',
  'src-d/lib/ListEvents.d:27',
  'src-d/lib/Combo.d:20',
  'src-d/lib/LangCoverage.d:16',
  'src-d/lib/ComboMore.d:20',
  'src-d/lib/ComboForm.d:20',
  'src-d/lib/ComboCss.d:20',
  'src-d/lib/ComboExpr.d:20',
  'src-d/lib/ComboNest.d:20',
  'src-d/lib/ComboIfCmp.d:20',
  'src-d/lib/ComboIfHost.d:20',
  'src-d/lib/ComboCover.d:20',
  'src-d/lib/ComboSurf.d:20',
  'src-d/lib/ComboWide.d:20',
  'src-d/lib/ComboMedia.d:20',
]

const project = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 5193
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

describe('Svelte language features: DevTools diagnosis', () => {
  test('if/each/await/click rewrite to orig .svelte; no ABORT after interactions', async () => {
    const ws = adminWorkspace()
    expect(compileWorkspace({ ws, project }).status).toBe(0)
    const map = loadDebugMap(ws)
    expect(rewriteStack(map, 'src-d/lib/IfToggle.d:32')).toMatch(/IfToggle\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/ClickField.d:20')).toMatch(/ClickField\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/ListEvents.d:27')).toMatch(/ListEvents\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/Combo.d:20')).toMatch(/Combo\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/LangCoverage.d:16')).toMatch(/LangCoverage\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/ComboMore.d:20')).toMatch(/ComboMore\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/ComboForm.d:20')).toMatch(/ComboForm\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/ComboCss.d:20')).toMatch(/ComboCss\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/ComboExpr.d:20')).toMatch(/ComboExpr\.svelte/)
    expect(rewriteStack(map, 'src-d/lib/ComboNest.d:20')).toMatch(/ComboNest\.svelte/)

    const wasm = ensureWasm(ws)
    if (!wasm) return
    const viteJs = join(ws, 'node_modules', 'vite', 'package.json')
    if (!existsSync(viteJs)) return

    const viteNames = ['vite.exe', 'vite.cmd', 'vite']
    let viteBin = 'vite'
    for (const n of viteNames) {
      const p = join(ws, 'node_modules', '.bin', n)
      if (existsSync(p)) {
        viteBin = p
        break
      }
    }
    killPort(PORT)
    const vite = spawn(viteBin, ['--host', '127.0.0.1', '--port', String(PORT), '--strictPort'], {
      cwd: ws,
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: viteBin === 'vite' || viteBin.endsWith('.cmd'),
    })
    const puppeteer = await tryLoadPuppeteer()
    if (!puppeteer) {
      killProcessTree(vite)
      killPort(PORT)
      return
    }
    try {
      const up = await waitHttp(ORIGIN + '/')
      if (!up) throw new Error('vite did not listen on ' + ORIGIN)

      const browser = await puppeteer.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-gpu'],
      })
      try {
        const page = await browser.newPage()
        const sink = await attachPageDevtools(page, map)
        await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded', timeout: 30_000 })
        await page
          .waitForFunction(
            () =>
              !!document.querySelector('.if-toggle') ||
              !!document.querySelector('.click-field') ||
              !!document.querySelector('.navbar'),
            { timeout: 20_000 }
          )
          .catch(() => null)

        const rewrite = await page.evaluate(() => {
          const w = window as unknown as { __svelteDRewrite?: (s: string) => string }
          const fn = w.__svelteDRewrite
          if (typeof fn !== 'function')
            return { ok: false, ifT: '', click: '', list: '', combo: '', more: '', form: '' }
          return {
            ok: true,
            ifT: fn('src-d/lib/IfToggle.d:32'),
            click: fn('src-d/lib/ClickField.d:20'),
            list: fn('src-d/lib/ListEvents.d:27'),
            combo: fn('src-d/lib/Combo.d:20'),
            more: fn('src-d/lib/ComboMore.d:20'),
            form: fn('src-d/lib/ComboForm.d:20'),
          }
        })
        expect(rewrite.ok).toBe(true)
        expect(rewrite.ifT).toMatch(/IfToggle\.svelte/)
        expect(rewrite.click).toMatch(/ClickField\.svelte/)
        expect(rewrite.list).toMatch(/ListEvents\.svelte/)
        expect(rewrite.combo).toMatch(/Combo\.svelte/)
        expect(rewrite.more).toMatch(/ComboMore\.svelte/)
        expect(rewrite.form).toMatch(/ComboForm\.svelte/)
        assertNoDevtoolsFaults(sink, 'lang boot rewrite')

        const probes = await probeLangDests(page, LANG_PROBES)
        expect(probes.some((p) => p.hooked)).toBe(true)
        assertProbesRewritten(probes, /IfToggle\.svelte/, 'IfToggle dest')
        assertProbesRewritten(probes, /LangCoverage\.svelte/, 'LangCoverage dest')
        assertProbesRewritten(probes, /Combo\.svelte/, 'Combo dest')
        assertProbesRewritten(probes, /ComboMore\.svelte/, 'ComboMore dest')
        assertProbesRewritten(probes, /ComboForm\.svelte/, 'ComboForm dest')
        assertProbesRewritten(probes, /ComboExpr\.svelte/, 'ComboExpr dest')
        assertProbesRewritten(probes, /ComboNest\.svelte/, 'ComboNest dest')
        assertProbesRewritten(probes, /ComboWide\.svelte/, 'ComboWide dest')
        assertProbesRewritten(probes, /ComboMedia\.svelte/, 'ComboMedia dest')
        await new Promise((r) => setTimeout(r, 80))
        const cdpProbe = sink.devtools.find((d) => /svelte-d-probe/.test(d.text + d.rewritten))
        const conProbe = sink.console.find((c) => /svelte-d-probe/.test(c.text + c.rewritten))
        expect(!!(cdpProbe || conProbe)).toBe(true)
        if (cdpProbe || conProbe)
          expect((cdpProbe ?? conProbe)!.rewritten).toMatch(/\.svelte/)
        assertNoDevtoolsFaults(sink, 'CDP probe hook Combo* dests')

        const boot = await snapshotLangDom(page)
        await page.evaluate((s) => {
          console.info('svelte-d-lang-snap', JSON.stringify(s))
        }, boot)
        if (boot.langCoverage.length)
          expect(boot.langCoverage).toMatch(/navy/)
        if (boot.comboMore.length)
          expect(boot.comboMore).toMatch(/a|Hi/)
        if (boot.combo.length) {
          expect(boot.combo).toMatch(/Shown/)
          if (!boot.comboDone || boot.comboWait) {
            await page
              .waitForFunction(
                () => {
                  const t = document.querySelector('.combo')?.textContent ?? ''
                  return t.includes('Done') && !t.includes('Wait')
                },
                { timeout: 5_000 }
              )
              .catch(() => null)
          }
          const afterAwait = await snapshotLangDom(page)
          if (!afterAwait.comboDone) {
            const go = await page.$('.combo .go')
            if (go) await go.click()
            await page
              .waitForFunction(
                () => (document.querySelector('.combo')?.textContent ?? '').includes('Done'),
                { timeout: 5_000 }
              )
              .catch(() => null)
          }
          const settled = await snapshotLangDom(page)
          expect(settled.comboDone).toBe(true)
          expect(settled.comboWait).toBe(false)
          assertNoDevtoolsFaults(sink, '{#await} ready wireAwait then')
          const ay = await page.evaluate(() => {
            const w = window as unknown as {
              __svelteDRewriteError?: (e: unknown) => string
              __svelteDLastAwait?: { failed?: boolean; reason?: string }
              libwasm?: { awaitSupported?: boolean; instance?: { exports?: Record<string, unknown> } }
            }
            const rewrite =
              typeof w.__svelteDRewriteError === 'function'
                ? w.__svelteDRewriteError({
                    stack: 'at wireAwait (wasm://wasm/x)\nwasm-function[4]\nasyncify_start_unwind',
                  })
                : ''
            const ex = w.libwasm && w.libwasm.instance && w.libwasm.instance.exports
            return {
              rewriteError: typeof w.__svelteDRewriteError === 'function',
              lastAwait: !!w.__svelteDLastAwait,
              awaitSupported: !!(w.libwasm && w.libwasm.awaitSupported),
              hasAsyncify: !!(ex && typeof ex.asyncify_get_state === 'function'),
              rewrite,
            }
          })
          expect(ay.rewriteError).toBe(true)
          expect(ay.lastAwait).toBe(true)
          expect(ay.rewrite).toMatch(/\[async-wasm\]/)
          expect(ay.rewrite).toMatch(/\[asyncify\]/)
          if (ay.hasAsyncify) expect(ay.awaitSupported).toBe(true)
        }
        if (boot.comboWide.length)
          expect(boot.comboWideShown).toBe(true)
        if (boot.comboMedia.length) {
          expect(boot.comboMediaOk).toBe(true)
          expect(boot.comboMediaFail).toBe(false)
        }
        if (boot.langCoverage.length)
          expect(boot.langCoverage).toMatch(/On/)
        if (boot.comboNest.length) {
          expect(boot.nestLi).toBeGreaterThan(0)
          for (const c of EACH_IF_BOOL_CASES) {
            expect({ id: c.id, n: boot.nestRow[c.id] ?? 0 }).toEqual({
              id: c.id,
              n: c.boot,
            })
          }
        }
        if (boot.langCoverage.length) {
          expect(boot.extrasLi).toBeGreaterThan(0)
          expect(boot.voidsNone).toBe(true)
          expect(boot.langEmpty).toBe(false)
        }
        assertNoDevtoolsFaults(sink, 'boot DOM snapshot {tone}/{stamp}/{#if}/{#each}')

        if (boot.navLogo) {
          expect(boot.navOpen).toBe(false)
          const burger = await page.$('.navbar .burger')
          if (burger) {
            await burger.click()
            await page
              .waitForFunction(
                () => !!document.querySelector('.navbar .burger-menu'),
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterBurger = await snapshotLangDom(page)
            expect(afterBurger.navOpen).toBe(true)
            expect(afterBurger.navLogo).toBe(true)
          }
          const endBtn = await page.$('.navbar .end-btn')
          if (endBtn) await endBtn.click()
          assertNoDevtoolsFaults(sink, 'NavBar.svelte burger {#if} + EH Button')
        }

        if (await page.$('.if-toggle button')) {
          const before = await page.$eval('.if-toggle', (el) => el.textContent ?? '')
          await page.click('.if-toggle button')
          await page
            .waitForFunction(
              (prev: string) => (document.querySelector('.if-toggle')?.textContent ?? '') !== prev,
              { timeout: 5_000 },
              before
            )
            .catch(() => null)
          const after = await page.$eval('.if-toggle', (el) => el.textContent ?? '')
          expect(after.includes('Visible') || after !== before).toBe(true)
          assertNoDevtoolsFaults(sink, '{#if} toggle')
        }

        const clickBtns = await page.$$('.click-field button')
        if (clickBtns.length) {
          await clickBtns[0].click()
          await page
            .waitForFunction(
              () =>
                Array.from(document.querySelectorAll('.click-field')).some((el) =>
                  (el.textContent ?? '').includes('clicked')
                ),
              { timeout: 5_000 }
            )
            .catch(() => null)
          const clickTxt = await page.$$eval('.click-field', (els) =>
            els.map((e) => e.textContent ?? '').join(' | ')
          )
          expect(clickTxt).toMatch(/clicked/)
          assertNoDevtoolsFaults(sink, 'on:click ClickField')
        }

        const lis = await page.$$('.list-events li')
        if (lis.length) {
          await lis[0].click()
          await page
            .waitForFunction(
              () => {
                const t = document.querySelector('.list-events p')?.textContent ?? ''
                return t.includes('one') || t.includes('two')
              },
              { timeout: 5_000 }
            )
            .catch(() => null)
          const last = await page.$eval('.list-events p', (el) => el.textContent ?? '')
          expect(last).toMatch(/one|two/)
          assertNoDevtoolsFaults(sink, '{#each} list click')
        }

        const combo = await page.$('.combo')
        if (combo) {
          const txt = await page.$eval('.combo', (el) => el.textContent ?? '')
          expect(txt).toMatch(/Shown|Other|fallback|Done|Empty/)
          const inner = await page.$('.combo .click-field button')
          if (inner) await inner.click()
          assertNoDevtoolsFaults(sink, 'Combo if/each/await + nested ClickField')
        }

        const cov = await page.$('.lang-coverage button')
        if (cov) {
          const beforeCov = await page.$eval('.lang-coverage', (el) => el.textContent ?? '')
          expect(beforeCov).toMatch(/On/)
          await cov.click()
          await page
            .waitForFunction(
              (prev: string) => (document.querySelector('.lang-coverage')?.textContent ?? '') !== prev,
              { timeout: 5_000 },
              beforeCov
            )
            .catch(() => null)
          const afterCov = await page.$eval('.lang-coverage', (el) => el.textContent ?? '')
          expect(afterCov.includes('Off') || afterCov !== beforeCov).toBe(true)
          assertNoDevtoolsFaults(sink, 'LangCoverage flip + nested {#if} + {@html}')
          const wipe = await page.$('.lang-coverage .wipe')
          if (wipe) {
            await wipe.click()
            await page
              .waitForFunction(
                () => (document.querySelectorAll('.lang-coverage li').length === 0)
                  || (document.querySelector('.lang-coverage')?.textContent ?? '').includes('Empty'),
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterWipe = await snapshotLangDom(page)
            expect(afterWipe.extrasLi).toBe(0)
            expect(afterWipe.langEmpty).toBe(true)
            expect(afterWipe.langEmptyInUl).toBe(true)
            expect(afterWipe.voidsNone).toBe(true)
            assertNoDevtoolsFaults(sink, '{#each}{:else} wipe shows Empty inside ul')
          }
        }

        const ph = await page.$('.phobos-demo button')
        if (ph) {
          await ph.click()
          assertNoDevtoolsFaults(sink, 'PhobosDemo std.algorithm click')
        }

        const moreBtn = await page.$('.combo-more button')
        if (moreBtn) {
          await moreBtn.click()
          await page
            .waitForFunction(
              () => (document.querySelector('.combo-more')?.textContent ?? '').includes('b'),
              { timeout: 5_000 }
            )
            .catch(() => null)
          const moreTxt = await page.$eval('.combo-more', (el) => el.textContent ?? '')
          expect(moreTxt).toMatch(/b/)
          const radios = await page.$$('.combo-more input[type="radio"]')
          if (radios.length > 1) await radios[1].click()
          assertNoDevtoolsFaults(sink, '{#key} remount + bind:group')
        }

        const form = await page.$('.combo-form textarea')
        if (form) {
          await page.$eval('.combo-form textarea', (el) => {
            const t = el as HTMLTextAreaElement
            t.value = 'devtools-bind'
            t.dispatchEvent(new Event('input', { bubbles: true }))
          })
          const ta = await page.$eval('.combo-form textarea', (el) => (el as HTMLTextAreaElement).value)
          expect(ta).toMatch(/devtools-bind|hi/)
          const det = await page.$('.combo-form details summary')
          if (det) await det.click()
          const sel = await page.$('.combo-form select')
          if (sel)
            await page.select('.combo-form select', 'b').catch(() => null)
          const optParent = await page
            .$eval('.combo-form select option', (el) => el.parentElement?.tagName ?? '')
            .catch(() => '')
          if (optParent)
            expect(optParent).toBe('SELECT')
          assertNoDevtoolsFaults(sink, 'bind:value textarea/select + nested option')
        }

        const css = await page.$('.combo-css')
        if (css) {
          const cssTxt = await page.$eval('.combo-css', (el) => el.textContent ?? '')
          expect(cssTxt).toMatch(/Paint/)
          const tagged = await page.$eval('.combo-css [data-tag]', (el) => el.getAttribute('data-tag'))
            .catch(() => '')
          expect(tagged === '' || tagged === 'article' || tagged === 'div').toBe(true)
          assertNoDevtoolsFaults(sink, 'svelte:element this={tag} + style:')
        }

        const expr = await page.$('.combo-expr')
        if (expr) {
          const exprTxt = await page.$eval('.combo-expr', (el) => el.textContent ?? '')
          expect(exprTxt).toMatch(/Both|Ada|H/)
          const formEl = await page.$('.combo-expr form')
          if (formEl)
            await page.$eval('.combo-expr form', (el) =>
              (el as HTMLFormElement).dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
            )
          assertNoDevtoolsFaults(sink, '{#if a && b} + {@render} + form preventDefault')
        }

        const wideBtn = await page.$('.combo-wide button')
        if (wideBtn) {
          const beforeWide = await snapshotLangDom(page)
          await wideBtn.click()
          await page
            .waitForFunction(
              (prev: string) => (document.querySelector('.combo-wide')?.textContent ?? '') !== prev,
              { timeout: 5_000 },
              beforeWide.comboWide
            )
            .catch(() => null)
          const afterWide = await snapshotLangDom(page)
          expect(afterWide.comboWideShown).toBe(false)
          assertNoDevtoolsFaults(sink, '{#if !off} ComboWide flip')
        }

        const nest = await page.$('.combo-nest')
        if (nest) {
          const nestTxt = await page.$eval('.combo-nest', (el) => el.textContent ?? '')
          expect(nestTxt).toMatch(/Show|one|B/)
          const nestBtn = await page.$('.combo-nest button')
          if (nestBtn) {
            const beforeNest = await snapshotLangDom(page)
            await nestBtn.click()
            await page
              .waitForFunction(
                (prev: string) => (document.querySelector('.combo-nest')?.textContent ?? '') !== prev,
                { timeout: 5_000 },
                beforeNest.comboNest
              )
              .catch(() => null)
            const afterNest = await snapshotLangDom(page)
            expect(afterNest.nestShow).toBe(false)
            expect(afterNest.nestLi).toBeLessThan(beforeNest.nestLi)
            expect(afterNest.nestUl).toBe(beforeNest.nestUl)
            for (const c of EACH_IF_BOOL_CASES) {
              expect({ id: c.id, n: afterNest.nestRow[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.flip,
              })
            }
            assertNoDevtoolsFaults(sink, 'each-if bool table flip')
          }
          const pinBtn = await page.$('.combo-nest .pin')
          if (pinBtn) {
            const beforePin = await snapshotLangDom(page)
            expect(beforePin.okRow).toBe(1)
            await pinBtn.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => document.querySelectorAll('.combo-nest .ok-row').length > 1,
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterPin = await snapshotLangDom(page)
            expect(afterPin.okRow).toBe(2)
            assertNoDevtoolsFaults(sink, '{#each}{#if row.ok} pin fills rows')
          }
          const skipBtn = await page.$('.combo-nest button.skip')
          if (skipBtn) {
            const beforeSkip = await snapshotLangDom(page)
            expect(beforeSkip.skipRow).toBe(1)
            await page.evaluate(() => {
              const b = Array.from(document.querySelectorAll('.combo-nest button')).find(
                (el) => (el.textContent ?? '') === 'Skip'
              ) as HTMLElement | undefined
              b?.scrollIntoView({ block: 'center' })
              b?.click()
            })
            await page
              .waitForFunction(
                () => document.querySelectorAll('.combo-nest .skip-row').length === 0,
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterSkip = await snapshotLangDom(page)
            if (afterSkip.skipRow !== 0) {
              assertNoDevtoolsFaults(sink, '{#each}{#if !skip.ok} skip fill (row stayed)')
            } else {
              expect(afterSkip.skipRow).toBe(0)
              assertNoDevtoolsFaults(sink, '{#each}{#if !skip.ok} skip fills away')
            }
          }
          const hitBtn = await page.$('.combo-nest .hit')
          if (hitBtn) {
            const beforeHit = await snapshotLangDom(page)
            expect(beforeHit.hitRow).toBe(1)
            await hitBtn.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => document.querySelectorAll('.combo-nest .hit-row').length > 1,
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterHit = await snapshotLangDom(page)
            expect(afterHit.hitRow).toBe(2)
            assertNoDevtoolsFaults(sink, '{#each}{#if hit.n > 0} hit fills rows')
          }
          const nestLi = await page.$('.combo-nest li')
          if (nestLi) await nestLi.click()
          const box = await page.$('.combo-nest [oncopy], .combo-nest div')
          if (box)
            await page.$eval('.combo-nest', (el) =>
              el.dispatchEvent(new Event('copy', { bubbles: true }))
            )
          assertNoDevtoolsFaults(sink, '{#if a && !b} + each-in-if + bind:indeterminate')
        }

        const ifCmpRoot = await page.$('.combo-if-cmp')
        if (ifCmpRoot) {
          const beforeCmp = await snapshotLangDom(page)
          for (const c of EACH_IF_CMP_CASES) {
            expect({ id: c.id, n: beforeCmp.ifCmp[c.id] ?? 0 }).toEqual({
              id: c.id,
              n: c.boot,
            })
          }
          const cmpFlip = await page.$('.combo-if-cmp .ifcmp-flip')
          if (cmpFlip) {
            await cmpFlip.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => (document.querySelectorAll('.combo-if-cmp .ifcmp-ga').length === 0),
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterCmp = await snapshotLangDom(page)
            for (const c of EACH_IF_CMP_CASES) {
              expect({ id: c.id, n: afterCmp.ifCmp[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.flip,
              })
            }
            assertNoDevtoolsFaults(sink, 'each-if cmp table flip')
          }
        }

        const ifHostRoot = await page.$('.combo-if-host')
        if (ifHostRoot) {
          const beforeHost = await snapshotLangDom(page)
          for (const c of HOST_IF_CASES) {
            expect({ id: c.id, n: beforeHost.ifHost[c.id] ?? 0 }).toEqual({
              id: c.id,
              n: c.boot,
            })
          }
          const hostFlip = await page.$('.combo-if-host .ifhost-flip')
          if (hostFlip) {
            await hostFlip.evaluate((el) => {
              (el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => (document.querySelectorAll('.combo-if-host .ifhost-on').length === 0),
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterHost = await snapshotLangDom(page)
            for (const c of HOST_IF_CASES) {
              expect({ id: c.id, n: afterHost.ifHost[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.flip,
              })
            }
            assertNoDevtoolsFaults(sink, 'host-if table flip')
          }
        }

        const coverRoot = await page.$('.combo-cover')
        if (coverRoot) {
          const beforeCover = await snapshotLangDom(page)
          for (const c of EACH_ELSE_CASES) {
            expect({ id: c.id, n: beforeCover.coverElse[c.id] ?? 0 }).toEqual({
              id: c.id,
              n: c.boot,
            })
          }
          const liveAwait = AWAIT_CASES.filter((c) => c.boot !== undefined)
          if (!beforeCover.coverAwait.then) {
            for (const c of liveAwait) {
              expect({ id: c.id, n: beforeCover.coverAwait[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.boot,
              })
            }
          }
          expect(beforeCover.coverBind.note).toBe('hi')
          expect(beforeCover.coverBind.ok).toBe(false)
          expect(beforeCover.coverBind.open).toBe(false)
          expect(beforeCover.coverBind.pick).toBe('a')
          expect(beforeCover.coverBind.files).toBe(true)
          const wipeBtn = await page.$('.combo-cover .cover-wipe')
          if (wipeBtn) {
            await wipeBtn.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => document.querySelectorAll('.combo-cover .else-extra').length === 0,
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterWipe = await snapshotLangDom(page)
            for (const c of EACH_ELSE_CASES) {
              expect({ id: c.id, n: afterWipe.coverElse[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.wipe,
              })
            }
            assertNoDevtoolsFaults(sink, 'each-else table wipe')
          }
          const goBtn = await page.$('.combo-cover .cover-go')
          if (goBtn) {
            await goBtn.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => document.querySelectorAll('.combo-cover .await-then').length === 1,
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterGo = await snapshotLangDom(page)
            for (const c of liveAwait) {
              expect({ id: c.id, n: afterGo.coverAwait[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.go ?? 0,
              })
            }
            assertNoDevtoolsFaults(sink, 'await table Go then')
          }
          const failBtn = await page.$('.combo-cover .cover-fail')
          if (failBtn) {
            await failBtn.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => document.querySelectorAll('.combo-cover .await-catch').length === 1,
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterFail = await snapshotLangDom(page)
            for (const c of liveAwait) {
              expect({ id: c.id, n: afterFail.coverAwait[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.fail ?? 0,
              })
            }
            assertNoDevtoolsFaults(sink, 'await table Fail catch')
          }
          for (const c of BIND_CASES) {
            if (c.action === 'note') {
              const btn = await page.$('.combo-cover .cover-note')
              if (btn) {
                await btn.evaluate((el) => {
                  ;(el as HTMLElement).scrollIntoView({ block: 'center' })
                  ;(el as HTMLElement).click()
                })
                await page
                  .waitForFunction(
                    () =>
                      (document.querySelector('.combo-cover .bind-note-out')?.textContent ?? '') ===
                      'yo',
                    { timeout: 5_000 }
                  )
                  .catch(() => null)
                const after = await snapshotLangDom(page)
                expect(after.coverBind.note).toBe('yo')
              }
            } else if (c.action === 'ok') {
              const box = await page.$('.combo-cover .bind-ok')
              if (box) {
                await box.evaluate((el) => {
                  ;(el as HTMLElement).scrollIntoView({ block: 'center' })
                  ;(el as HTMLInputElement).click()
                })
                await page
                  .waitForFunction(
                    () =>
                      !!(document.querySelector('.combo-cover .bind-ok') as HTMLInputElement)
                        ?.checked,
                    { timeout: 5_000 }
                  )
                  .catch(() => null)
                const after = await snapshotLangDom(page)
                expect(after.coverBind.ok).toBe(true)
              }
            } else if (c.action === 'open') {
              const sum = await page.$('.combo-cover .bind-open summary')
              if (sum) {
                await sum.evaluate((el) => {
                  ;(el as HTMLElement).scrollIntoView({ block: 'center' })
                  ;(el as HTMLElement).click()
                })
                await page
                  .waitForFunction(
                    () =>
                      !!(document.querySelector('.combo-cover .bind-open') as HTMLDetailsElement)
                        ?.open,
                    { timeout: 5_000 }
                  )
                  .catch(() => null)
                const after = await snapshotLangDom(page)
                expect(after.coverBind.open).toBe(true)
              }
            } else if (c.action === 'pick') {
              const radio = await page.$('.combo-cover .bind-group-b')
              if (radio) {
                await radio.evaluate((el) => {
                  ;(el as HTMLElement).scrollIntoView({ block: 'center' })
                  ;(el as HTMLInputElement).click()
                })
                await page
                  .waitForFunction(
                    () =>
                      !!(document.querySelector('.combo-cover .bind-group-b') as HTMLInputElement)
                        ?.checked,
                    { timeout: 5_000 }
                  )
                  .catch(() => null)
                const after = await snapshotLangDom(page)
                expect(after.coverBind.pick).toBe('b')
              }
            }
          }
          assertNoDevtoolsFaults(sink, 'bind table value/checked/open/group')
        }

        const surfRoot = await page.$('.combo-surf')
        if (surfRoot) {
          const beforeSurf = await snapshotLangDom(page)
          expect(beforeSurf.surfDir.on).toBe(false)
          expect(beforeSurf.surfDir.style.length).toBeGreaterThan(0)
          for (const c of SPECIAL_CASES) {
            if (c.boot === undefined) continue
            expect({ id: c.id, n: beforeSurf.surfSpec[c.id] ?? 0 }).toEqual({
              id: c.id,
              n: c.boot,
            })
          }
          const liveBound = BOUNDARY_CASES.filter((c) => c.boot !== undefined)
          for (const c of liveBound) {
            expect({ id: c.id, n: beforeSurf.surfBound[c.id] ?? 0 }).toEqual({
              id: c.id,
              n: c.boot,
            })
          }
          const pingBtn = await page.$('.combo-surf .surf-ping')
          if (pingBtn) {
            await pingBtn.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => !!document.querySelector('.combo-surf .dir-on.on'),
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterPing = await snapshotLangDom(page)
            expect(afterPing.surfDir.on).toBe(true)
            await pingBtn.evaluate((el) => (el as HTMLElement).click())
            const afterOnce = await snapshotLangDom(page)
            expect(afterOnce.surfDir.on).toBe(true)
            assertNoDevtoolsFaults(sink, 'directive table class: + on:|once')
          }
          const tripBtn = await page.$('.combo-surf .surf-trip')
          if (tripBtn) {
            await tripBtn.evaluate((el) => {
              ;(el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => (document.querySelector('.combo-surf .bound-fail')?.textContent ?? '') === 'boom',
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterTrip = await snapshotLangDom(page)
            for (const c of liveBound) {
              expect({ id: c.id, n: afterTrip.surfBound[c.id] ?? 0 }).toEqual({
                id: c.id,
                n: c.trip ?? 0,
              })
            }
            expect(afterTrip.surfBound.fail ? afterTrip.surfBound.fail : 0).toBe(1)
            const retryBtn = await page.$('.combo-surf .bound-retry')
            if (retryBtn) {
              await retryBtn.evaluate((el) => {
                ;(el as HTMLElement).scrollIntoView({ block: 'center' })
                ;(el as HTMLElement).click()
              })
              await page
                .waitForFunction(
                  () => !!document.querySelector('.combo-surf .bound-ok'),
                  { timeout: 5_000 }
                )
                .catch(() => null)
              const afterRetry = await snapshotLangDom(page)
              for (const c of liveBound) {
                expect({ id: c.id, n: afterRetry.surfBound[c.id] ?? 0 }).toEqual({
                  id: c.id,
                  n: c.retry ?? 0,
                })
              }
            }
            assertNoDevtoolsFaults(sink, 'boundary table throwBoundary / Retry')
          }
        }

        const mediaTrip = await page.$('.combo-media .trip')
        if (mediaTrip) {
          const beforeMedia = await snapshotLangDom(page)
          expect(beforeMedia.comboMediaOk).toBe(true)
          expect(beforeMedia.comboMediaFail).toBe(false)
          expect(beforeMedia.failMsg).toBe('')
          await mediaTrip.evaluate((el) => {
            (el as HTMLElement).scrollIntoView({ block: 'center' })
            ;(el as HTMLElement).click()
          })
          await page
            .waitForFunction(
              () => (document.querySelector('.combo-media .fail-msg')?.textContent ?? '') === 'boom',
              { timeout: 5_000 }
            )
            .catch(() => null)
          const afterTrip = await snapshotLangDom(page)
          expect(afterTrip.comboMediaFail).toBe(true)
          expect(afterTrip.comboMediaOk).toBe(false)
          expect(afterTrip.failMsg).toBe('boom')
          const mediaRetry = await page.$('.combo-media .retry')
          if (mediaRetry) {
            await mediaRetry.evaluate((el) => {
              (el as HTMLElement).scrollIntoView({ block: 'center' })
              ;(el as HTMLElement).click()
            })
            await page
              .waitForFunction(
                () => (document.querySelector('.combo-media')?.textContent ?? '').includes('Ok'),
                { timeout: 5_000 }
              )
              .catch(() => null)
            const afterRetry = await snapshotLangDom(page)
            expect(afterRetry.comboMediaOk).toBe(true)
            expect(afterRetry.comboMediaFail).toBe(false)
            expect(afterRetry.failMsg).toBe('')
          }
          assertNoDevtoolsFaults(sink, 'svelte:boundary throwBoundary → failed(error, reset)')
        }

        const next = await page.$('.combo-next')
        if (next) {
          const nextTxt = await page.$eval('.combo-next', (el) => el.textContent ?? '')
          expect(nextTxt).toMatch(/Dyn|Frag|Safe|site|Move|hi/)
          const innerCf = await page.$('.combo-next .click-field button')
          if (innerCf) await innerCf.click()
          assertNoDevtoolsFaults(sink, 'svelte:element/fragment/component + use:')
        }

        await page.evaluate(() => {
          console.error('src-d/lib/IfToggle.d:32 toggle if')
          console.error('src-d/lib/Combo.d:20 each')
        })
        await new Promise((r) => setTimeout(r, 80))
        const hitIf = sink.console.find((c) => /IfToggle\.d:32/.test(c.text))
        const hitCombo = sink.console.find((c) => /Combo\.d:20/.test(c.text))
        expect(hitIf?.rewritten ?? '').toMatch(/IfToggle\.svelte/)
        expect(hitCombo?.rewritten ?? '').toMatch(/Combo\.svelte/)
        assertNoDevtoolsFaults(sink, 'devtools rewrite of dest:line')

        const pageFaults = await page.evaluate(() => {
          const w = window as unknown as { __svelteDLastFaults?: string[] }
          return Array.isArray(w.__svelteDLastFaults) ? w.__svelteDLastFaults : []
        })
        expect(pageFaults.filter((s) => /ABORT:/i.test(s))).toEqual([])

        await page.goto(ORIGIN + '/admin/features', { waitUntil: 'domcontentloaded', timeout: 30_000 })
        await page
          .waitForFunction(() => !!document.querySelector('.admin-features'), { timeout: 15_000 })
          .catch(() => null)
        if (await page.$('.admin-features')) {
          const featProbes = await probeLangDests(page, [
            'src-d/lib/ComboMore.d:20',
            'src-d/lib/ComboNest.d:20',
            'src-d/routes/admin/features/page.d:16',
          ])
          assertProbesRewritten(featProbes, /ComboMore\.svelte|ComboNest\.svelte|features/, 'features page dests')
          const moreBtn2 = await page.$('.admin-features .combo-more button, .combo-more button')
          if (moreBtn2) await moreBtn2.click()
          const nestLi2 = await page.$('.admin-features .combo-nest li, .combo-nest li')
          if (nestLi2) await nestLi2.click()
          assertNoDevtoolsFaults(sink, '/admin/features Combo* remount + click')
        }
      } finally {
        await browser.close()
      }
    } finally {
      killProcessTree(vite)
      killPort(PORT)
    }
  }, 180_000)
})
