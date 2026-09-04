// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import {
  colorizeHostLog,
  formatBridgeLine,
  kitLogLevel,
  rewriteStack,
  loadDebugMap,
} from 'svelte-d'
import { adminWorkspace } from '../src/ws.ts'
import { printKitLine } from '../src/bridge.ts'
import { runBlankFirefox } from '../src/browsers.ts'
import { runBlankCdp } from '../src/puppeteer.ts'

describe('kit-admin dual-browser + vibe.0 colored logs', () => {
  test('kitLogLevel maps console and vibe.0 prefixes', () => {
    expect(kitLogLevel('error')).toBe('error')
    expect(kitLogLevel('ERR')).toBe('error')
    expect(kitLogLevel('warn')).toBe('warn')
    expect(kitLogLevel('WRN')).toBe('warn')
    expect(kitLogLevel('info')).toBe('info')
    expect(kitLogLevel('INF')).toBe('info')
    expect(kitLogLevel('trace')).toBe('trace')
    expect(kitLogLevel('trc')).toBe('trace')
    expect(kitLogLevel('dbg')).toBe('debug')
  })

  test('formatBridgeLine tags chrome/firefox/host for the bun prompt', () => {
    const prev = process.env.NO_COLOR
    process.env.NO_COLOR = '1'
    expect(formatBridgeLine({ source: 'chrome', kind: 'error', text: 'boom' })).toContain(
      '[chrome error]'
    )
    expect(formatBridgeLine({ source: 'firefox', kind: 'log', text: 'hi' })).toContain(
      '[firefox log]'
    )
    const host = formatBridgeLine({
      source: 'host',
      kind: 'log',
      text: '[00000001:00000000 ERR] admin postgres skip',
    })
    expect(host).toContain('[host log]')
    expect(host).toContain('admin postgres skip')
    if (prev === undefined) delete process.env.NO_COLOR
    else process.env.NO_COLOR = prev
  })

  test('colorizeHostLog is a no-op under NO_COLOR', () => {
    const prev = process.env.NO_COLOR
    process.env.NO_COLOR = '1'
    const line = '[aabbccdd:00000000 ERR] fail'
    expect(colorizeHostLog(line)).toBe(line)
    if (prev === undefined) delete process.env.NO_COLOR
    else process.env.NO_COLOR = prev
  })

  test('printKitLine writes a tagged line', () => {
    const prev = process.env.NO_COLOR
    process.env.NO_COLOR = '1'
    const chunks: string[] = []
    const out = { write(s: string) { chunks.push(s); return true } } as unknown as NodeJS.WriteStream
    printKitLine('chrome', 'info', 'ready', loadDebugMap(adminWorkspace()), out)
    expect(chunks.join('')).toContain('[chrome info]')
    expect(chunks.join('')).toContain('ready')
    if (prev === undefined) delete process.env.NO_COLOR
    else process.env.NO_COLOR = prev
  })

  test('chrome and firefox about:blank consoles rewrite when browsers exist', async () => {
    const map = loadDebugMap(adminWorkspace())
    const chrome = await runBlankCdp(map)
    if (chrome) {
      expect(chrome.console.some((c) => c.text.includes('admin/page.d'))).toBe(true)
    }
    const ff = await runBlankFirefox(map)
    if (ff) {
      expect(ff.console.some((c) => c.text.includes('admin/page.d'))).toBe(true)
    }
    expect(rewriteStack(map, 'at unknown.js:1:1')).toBe('at unknown.js:1:1')
  }, 90_000)
})
