// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Chrome (puppeteer) + Firefox (playwright) console → bun stdout.
import { loadDebugMap, type DebugMap } from 'svelte-d'
import { attachDebugListeners, tryLoadPuppeteer, type CdpSession } from './puppeteer.ts'
import { printKitLine } from './bridge.ts'

export async function tryLoadPlaywright(): Promise<typeof import('playwright') | null> {
  try {
    return await import('playwright')
  } catch {
    return null
  }
}

export async function runBlankFirefox(map: DebugMap): Promise<CdpSession | null> {
  const pw = await tryLoadPlaywright()
  if (!pw) return null
  let browser: Awaited<ReturnType<typeof pw.firefox.launch>> | undefined
  try {
    browser = await pw.firefox.launch({ headless: true })
    const page = await browser.newPage()
    const sink: CdpSession = { console: [], pageErrors: [], devtools: [] }
    page.on('console', (msg) => {
      const raw = msg.text()
      sink.console.push({
        type: msg.type(),
        text: raw,
        rewritten: raw,
      })
    })
    page.on('pageerror', (err) => {
      const stack = err.stack ?? err.message
      sink.pageErrors.push({ message: err.message, stack, rewritten: stack })
    })
    await page.goto('about:blank')
    await page.evaluate(() => {
      console.log('src-d/routes/admin/page.d:18 Panel construct')
    })
    await new Promise((r) => setTimeout(r, 80))
    for (const c of sink.console)
      c.rewritten = printKitLine('firefox', c.type, c.text, map).slice(0)
    return sink
  } catch {
    return null
  } finally {
    if (browser) await browser.close()
  }
}

export async function attachLiveBrowsers(opts: {
  url: string
  chrome?: boolean
  firefox?: boolean
  map?: DebugMap
}): Promise<{ chrome: boolean; firefox: boolean }> {
  const map = opts.map ?? loadDebugMap()
  const wantChrome = opts.chrome !== false
  const wantFf = opts.firefox !== false
  let chrome = false
  let firefox = false

  if (wantChrome) {
    const puppeteer = await tryLoadPuppeteer()
    if (puppeteer) {
      try {
        const browser = await puppeteer.launch({
          headless: false,
          args: ['--no-sandbox', '--disable-gpu'],
        })
        const page = await browser.newPage()
        const sink: CdpSession = { console: [], pageErrors: [], devtools: [] }
        attachDebugListeners(page, map, sink)
        page.on('console', (msg) => {
          printKitLine('chrome', msg.type(), msg.text(), map)
        })
        page.on('pageerror', (err) => {
          printKitLine('chrome', 'pageerror', err.stack ?? err.message, map)
        })
        await page.goto(opts.url, { waitUntil: 'domcontentloaded' }).catch(() => {})
        chrome = true
      } catch {
        chrome = false
      }
    }
  }

  if (wantFf) {
    const pw = await tryLoadPlaywright()
    if (pw) {
      try {
        const browser = await pw.firefox.launch({ headless: false })
        const page = await browser.newPage()
        page.on('console', (msg) => {
          printKitLine('firefox', msg.type(), msg.text(), map)
        })
        page.on('pageerror', (err) => {
          printKitLine('firefox', 'pageerror', err.stack ?? err.message, map)
        })
        await page.goto(opts.url, { waitUntil: 'domcontentloaded' }).catch(() => {})
        firefox = true
      } catch {
        firefox = false
      }
    }
  }

  return { chrome, firefox }
}
