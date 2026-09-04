// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Puppeteer/CDP test platform. Consumes svelte-d rewriteStack.
// Optional: skip when Chromium is not installed.
import {
  rewriteConsole,
  rewriteCdpStack,
  rewriteStack,
  type DebugMap,
  type DevtoolsFrame,
} from 'svelte-d'

export type ConsoleEvent = {
  type: string
  text: string
  rewritten: string
}

export type PageErrorEvent = {
  message: string
  stack: string
  rewritten: string
}

export type DevtoolsEvent = {
  kind: 'console' | 'exception' | 'log'
  text: string
  rewritten: string
  frames: string
}

export type CdpSession = {
  console: ConsoleEvent[]
  pageErrors: PageErrorEvent[]
  devtools: DevtoolsEvent[]
}

export async function attachCdpDevtools(
  page: { createCDPSession?: () => Promise<any> },
  map: DebugMap,
  sink: CdpSession
): Promise<boolean> {
  if (typeof page.createCDPSession !== 'function') return false
  try {
    const session = await page.createCDPSession()
    await session.send('Runtime.enable')
    await session.send('Debugger.enable')
    await session.send('Log.enable').catch(() => null)
    session.on('Log.entryAdded', (ev: {
      entry?: { text?: string; level?: string; source?: string }
    }) => {
      const text = ev.entry?.text ?? ''
      sink.devtools.push({
        kind: 'log',
        text,
        rewritten: rewriteStack(map, text),
        frames: ev.entry?.source ? String(ev.entry.source) : '',
      })
    })
    session.on('Runtime.consoleAPICalled', (ev: {
      type?: string
      args?: { value?: unknown; description?: string }[]
      stackTrace?: { callFrames?: DevtoolsFrame[] }
    }) => {
      const text = (ev.args ?? [])
        .map((a) => String(a.value ?? a.description ?? ''))
        .join(' ')
      const frames = rewriteCdpStack(map, ev.stackTrace?.callFrames ?? [], 0)
      sink.devtools.push({
        kind: 'console',
        text,
        rewritten: rewriteStack(map, text),
        frames,
      })
    })
    session.on('Runtime.exceptionThrown', (ev: {
      exceptionDetails?: {
        text?: string
        exception?: { description?: string }
        stackTrace?: { callFrames?: DevtoolsFrame[] }
      }
    }) => {
      const d = ev.exceptionDetails ?? {}
      const text = d.exception?.description ?? d.text ?? ''
      const frames = rewriteCdpStack(map, d.stackTrace?.callFrames ?? [], 0)
      sink.devtools.push({
        kind: 'exception',
        text,
        rewritten: rewriteStack(map, text),
        frames,
      })
    })
    return true
  } catch {
    return false
  }
}

export async function tryLoadPuppeteer(): Promise<typeof import('puppeteer') | null> {
  try {
    return await import('puppeteer')
  } catch {
    return null
  }
}

export function attachDebugListeners(
  page: {
    on: (ev: string, fn: (...args: never[]) => void) => void
  },
  map: DebugMap,
  sink: CdpSession
): void {
  page.on('console', ((msg: { type: () => string; text: () => string }) => {
    const raw = msg.text()
    sink.console.push({
      type: msg.type(),
      text: raw,
      rewritten: rewriteConsole(map, [raw]).text,
    })
  }) as (...args: never[]) => void)
  page.on('pageerror', ((err: Error) => {
    const stack = err.stack ?? err.message
    sink.pageErrors.push({
      message: err.message,
      stack,
      rewritten: rewriteStack(map, stack),
    })
  }) as (...args: never[]) => void)
}

export async function runBlankCdp(
  map: DebugMap
): Promise<CdpSession | null> {
  const puppeteer = await tryLoadPuppeteer()
  if (!puppeteer) return null
  let browser: Awaited<ReturnType<typeof puppeteer.launch>> | undefined
  try {
    browser = await puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-gpu'],
    })
    const page = await browser.newPage()
    const sink: CdpSession = { console: [], pageErrors: [], devtools: [] }
    attachDebugListeners(page, map, sink)
    await attachCdpDevtools(page, map, sink)
    await page.goto('about:blank')
    await page.evaluate(() => {
      console.log('src-d/routes/admin/page.d:18 Panel construct')
      console.error('ABORT: assert @ src-d/routes/admin/page.d:18 boom')
    })
    await new Promise((r) => setTimeout(r, 80))
    return sink
  } catch {
    return null
  } finally {
    if (browser) await browser.close()
  }
}
