// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Shared DevTools error sink for interaction tests. Rewrites through the
// debug map. Fatal = ABORT / pageerror / CDP exceptionThrown.
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import type { DebugMap } from 'svelte-d'
import {
  attachCdpDevtools,
  attachDebugListeners,
  type CdpSession,
} from './puppeteer.ts'

export type { CdpSession }

export function emptySink(): CdpSession {
  return { console: [], pageErrors: [], devtools: [] }
}

export async function attachPageDevtools(
  page: {
    on: (ev: string, fn: (...args: never[]) => void) => void
    createCDPSession?: () => Promise<unknown>
  },
  map: DebugMap,
  sink: CdpSession = emptySink()
): Promise<CdpSession> {
  attachDebugListeners(page, map, sink)
  await attachCdpDevtools(page, map, sink)
  return sink
}

function isKnownResidual(text: string): boolean {
  return /pglite|nodefs|o\.resolve is not a function/i.test(text)
}

export function devtoolsFaults(sink: CdpSession): string[] {
  const out: string[] = []
  for (const e of sink.pageErrors) {
    const t = 'pageerror ' + e.rewritten
    if (!isKnownResidual(t)) out.push(t)
  }
  for (const c of sink.console) {
    if (/ABORT:/i.test(c.text) || /ABORT:/i.test(c.rewritten))
      out.push(c.type + ' ' + c.rewritten)
  }
  for (const d of sink.devtools) {
    const t =
      d.kind === 'exception' ? 'cdp-exception ' + d.rewritten : d.rewritten
    if (d.kind === 'exception') {
      if (!isKnownResidual(t)) out.push(t)
    } else if (/ABORT:/i.test(d.text) || /ABORT:/i.test(d.rewritten))
      out.push((d.kind === 'log' ? 'cdp-log-abort ' : 'cdp-abort ') + d.rewritten)
  }
  return out
}

export type LangProbe = { dest: string; rewritten: string; hooked: boolean }

/** Emit dest:line through the page debug bridge so CDP console/log see the orig. */
export async function probeLangDests(
  page: { evaluate: (fn: (d: string[]) => unknown, dests: string[]) => Promise<unknown> },
  dests: string[]
): Promise<LangProbe[]> {
  const raw = (await page.evaluate((list: string[]) => {
    const w = window as unknown as {
      __svelteDProbe?: (s: string) => string
      __svelteDRewrite?: (s: string) => string
    }
    const probe = w.__svelteDProbe
    const rewrite = w.__svelteDRewrite
    return list.map((dest) => {
      if (typeof probe === 'function') {
        return { dest, rewritten: String(probe(dest)), hooked: true }
      }
      if (typeof rewrite === 'function') {
        const r = String(rewrite(dest))
        console.info('svelte-d-probe', r)
        return { dest, rewritten: r, hooked: true }
      }
      return { dest, rewritten: dest, hooked: false }
    })
  }, dests)) as LangProbe[]
  return raw
}

export type LangDomSnap = {
  ifToggle: string
  langCoverage: string
  combo: string
  comboMore: string
  comboNest: string
  comboExpr: string
  comboWide: string
  comboMedia: string
  extrasLi: number
  nestLi: number
  nestShow: boolean
  nestUl: number
  okRow: number
  pickRow: number
  holdRow: number
  skipRow: number
  cutRow: number
  keepRow: number
  dropRow: number
  bothRow: number
  nandRow: number
  hitRow: number
  moreRow: number
  lotRow: number
  fewRow: number
  navLogo: boolean
  navOpen: boolean
  comboWideShown: boolean
  comboDone: boolean
  comboWait: boolean
  voidsNone: boolean
  langEmpty: boolean
  langEmptyInUl: boolean
  comboMediaOk: boolean
  comboMediaFail: boolean
  failMsg: string
  ifCmp: Record<string, number>
  nestRow: Record<string, number>
  ifHost: Record<string, number>
  coverElse: Record<string, number>
  coverAwait: Record<string, number>
  coverBind: { note: string; ok: boolean; open: boolean; pick: string; files: boolean }
  surfDir: { on: boolean; style: string; spread: string }
  surfSpec: Record<string, number>
  surfBound: Record<string, number>
}

export async function snapshotLangDom(page: {
  evaluate: (fn: () => LangDomSnap) => Promise<LangDomSnap>
}): Promise<LangDomSnap> {
  return page.evaluate(() => {
    const t = (sel: string) => document.querySelector(sel)?.textContent ?? ''
    return {
      ifToggle: t('.if-toggle'),
      langCoverage: t('.lang-coverage'),
      combo: t('.combo'),
      comboMore: t('.combo-more'),
      comboNest: t('.combo-nest'),
      comboExpr: t('.combo-expr'),
      comboWide: t('.combo-wide'),
      comboMedia: t('.combo-media'),
      extrasLi: document.querySelectorAll('.lang-coverage li').length,
      nestLi: document.querySelectorAll('.combo-nest li').length,
      nestShow: (document.querySelector('.combo-nest')?.textContent ?? '').includes('Show'),
      nestUl: document.querySelectorAll('.combo-nest ul').length,
      okRow: document.querySelectorAll('.combo-nest .ok-row').length,
      pickRow: document.querySelectorAll('.combo-nest .pick-row').length,
      holdRow: document.querySelectorAll('.combo-nest .hold-row').length,
      skipRow: document.querySelectorAll('.combo-nest .skip-row').length,
      cutRow: document.querySelectorAll('.combo-nest .cut-row').length,
      keepRow: document.querySelectorAll('.combo-nest .keep-row').length,
      dropRow: document.querySelectorAll('.combo-nest .drop-row').length,
      bothRow: document.querySelectorAll('.combo-nest .both-row').length,
      nandRow: document.querySelectorAll('.combo-nest .nand-row').length,
      hitRow: document.querySelectorAll('.combo-nest .hit-row').length,
      moreRow: document.querySelectorAll('.combo-nest .more-row').length,
      lotRow: document.querySelectorAll('.combo-nest .lot-row').length,
      fewRow: document.querySelectorAll('.combo-nest .few-row').length,
      navLogo: (document.querySelector('.navbar')?.textContent ?? '').includes('PsxAI'),
      navOpen: !!document.querySelector('.navbar .burger-menu'),
      comboWideShown: (document.querySelector('.combo-wide')?.textContent ?? '').includes('Shown'),
      comboDone: (document.querySelector('.combo')?.textContent ?? '').includes('Done'),
      comboWait: (document.querySelector('.combo')?.textContent ?? '').includes('Wait'),
      voidsNone: (document.querySelector('.lang-coverage')?.textContent ?? '').includes('None'),
      langEmpty: (document.querySelector('.lang-coverage')?.textContent ?? '').includes('Empty'),
      langEmptyInUl: Array.from(document.querySelectorAll('.lang-coverage ul')).some((ul) =>
        (ul.textContent ?? '').includes('Empty')
      ),
      comboMediaOk: (document.querySelector('.combo-media')?.textContent ?? '').includes('Ok'),
      comboMediaFail: (document.querySelector('.combo-media .fail-msg')?.textContent ?? '').length > 0,
      failMsg: document.querySelector('.combo-media .fail-msg')?.textContent ?? '',
      ifCmp: (() => {
        const o: Record<string, number> = {}
        document.querySelectorAll('.combo-if-cmp li').forEach((li) => {
          for (const c of li.classList) {
            if (!c.startsWith('ifcmp-')) continue
            const id = c.slice(6)
            o[id] = (o[id] ?? 0) + 1
          }
        })
        return o
      })(),
      nestRow: (() => {
        const o: Record<string, number> = {}
        document.querySelectorAll('.combo-nest li').forEach((li) => {
          for (const c of li.classList) {
            if (!c.endsWith('-row')) continue
            const id = c.slice(0, -4)
            o[id] = (o[id] ?? 0) + 1
          }
        })
        return o
      })(),
      ifHost: (() => {
        const o: Record<string, number> = {}
        document.querySelectorAll('.combo-if-host [class*="ifhost-"]').forEach((el) => {
          for (const c of el.classList) {
            if (!c.startsWith('ifhost-') || c === 'ifhost-flip') continue
            const id = c.slice(7)
            o[id] = (o[id] ?? 0) + 1
          }
        })
        return o
      })(),
      coverElse: (() => {
        const o: Record<string, number> = {}
        document.querySelectorAll('.combo-cover [class*="else-"]').forEach((el) => {
          for (const c of el.classList) {
            if (!c.startsWith('else-')) continue
            const id = c.slice(5)
            o[id] = (o[id] ?? 0) + 1
          }
        })
        return o
      })(),
      coverAwait: (() => {
        const o: Record<string, number> = {}
        document.querySelectorAll('.combo-cover [class*="await-"]').forEach((el) => {
          for (const c of el.classList) {
            if (!c.startsWith('await-')) continue
            const id = c.slice(6)
            o[id] = (o[id] ?? 0) + 1
          }
        })
        return o
      })(),
      coverBind: {
        note: document.querySelector('.combo-cover .bind-note-out')?.textContent ?? '',
        ok: !!(document.querySelector('.combo-cover .bind-ok') as HTMLInputElement | null)?.checked,
        open: !!(document.querySelector('.combo-cover .bind-open') as HTMLDetailsElement | null)?.open,
        pick: (document.querySelector('.combo-cover .bind-group-b') as HTMLInputElement | null)
          ?.checked
          ? 'b'
          : 'a',
        files: !!document.querySelector('.combo-cover .bind-files'),
      },
      surfDir: {
        on: !!document.querySelector('.combo-surf .dir-on.on'),
        style: (document.querySelector('.combo-surf .dir-style p') as HTMLElement | null)?.style
          ?.color ?? '',
        spread:
          document.querySelector('.combo-surf .dir-spread')?.getAttribute('data-k') ??
          document.querySelector('.combo-surf .dir-spread')?.getAttribute('data-spread') ??
          '',
      },
      surfSpec: {
        static: document.querySelectorAll('.combo-surf .spec-static-kid').length,
        dyn: document.querySelectorAll('.combo-surf .spec-dyn-kid').length,
        frag: document.querySelectorAll('.combo-surf .spec-frag').length,
      },
      surfBound: (() => {
        const o: Record<string, number> = {}
        document.querySelectorAll('.combo-surf [class*="bound-"]').forEach((el) => {
          for (const c of el.classList) {
            if (!c.startsWith('bound-') || c === 'bound-retry') continue
            const id = c.slice(6)
            o[id] = (o[id] ?? 0) + 1
          }
        })
        return o
      })(),
    }
  })
}

export function assertProbesRewritten(probes: LangProbe[], origRe: RegExp, where: string): void {
  const hit = probes.find((p) => origRe.test(p.rewritten))
  if (!hit)
    throw new Error(
      'devtools probe missed ' + origRe + ' after ' + where + ': ' +
        probes.map((p) => p.dest + '→' + p.rewritten).join(' | ')
    )
}

export function assertNoDevtoolsFaults(sink: CdpSession, where: string): void {
  const f = devtoolsFaults(sink)
  if (f.length)
    throw new Error('devtools faults after ' + where + ': ' + f.slice(0, 8).join(' | '))
}

/** Serve `ws/public` so overlay/inspector fetch JSON without Vite. */
export function servePublic(ws: string, port: number): { stop: () => void; origin: string } {
  const origin = `http://127.0.0.1:${port}`
  const server = Bun.serve({
    port,
    hostname: '127.0.0.1',
    fetch(req) {
      const u = new URL(req.url)
      let rel = u.pathname.replace(/\\/g, '/')
      if (rel.endsWith('/')) rel += 'index.html'
      const abs = join(ws, 'public', rel)
      if (!existsSync(abs)) return new Response('not found', { status: 404 })
      return new Response(Bun.file(abs))
    },
  })
  return {
    origin,
    stop() {
      server.stop(true)
    },
  }
}
