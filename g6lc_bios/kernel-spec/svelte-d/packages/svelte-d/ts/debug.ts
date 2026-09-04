// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Debug map is a *trace* of the printed D IR back to .svelte.
// It does not invent orig paths. D IR remains the correctness surface.
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { workspaceDir } from './paths.ts'

export type DebugEntry = {
  dest: string
  destLine: number
  orig: string
  origLine: number
  kind: string
  name: string
}

export type DebugMap = {
  schema: string
  principle: string
  entries: DebugEntry[]
}

export function debugMapPath(ws = workspaceDir()): string {
  return join(ws, '.svelte-d', 'debug-map.json')
}

export function loadDebugMap(ws = workspaceDir()): DebugMap {
  const p = debugMapPath(ws)
  if (!existsSync(p)) {
    return {
      schema: 'svelte-d-debug-map/v1',
      principle: 'D-IR-is-correctness-surface; map-is-trace-only',
      entries: [],
    }
  }
  return JSON.parse(readFileSync(p, 'utf8')) as DebugMap
}

const FRAME = /(?:^|[(\s])((?:[\w./\\[\]-])+\.d):(\d+)(?::\d+)?/g
const LDC_FRAME = /((?:[\w./\\[\]-])+\.d)\((\d+)(?:,\d+)?\)/g

export function lookupOrig(
  map: DebugMap,
  destHint: string,
  line: number
): DebugEntry | null {
  const hint = destHint.replace(/\\/g, '/')
  const hits = map.entries.filter((e) => {
    const d = e.dest.replace(/\\/g, '/')
    return d === hint || d.endsWith('/' + hint) || d.endsWith(hint)
  })
  if (!hits.length) return null
  let best: DebugEntry | null = null
  for (const e of hits) {
    if (e.destLine > line) continue
    if (!best || e.destLine > best.destLine) best = e
  }
  return best
}

function appendOrig(map: DebugMap, all: string, file: string, ln: string): string {
  const e = lookupOrig(map, file.replace(/\\/g, '/'), Number(ln))
  if (!e) return all
  return `${all} [svelte ${e.orig}:${e.origLine} kind=${e.kind}]`
}

/** D length-prefixed mangle: `_D3lib9AdminDash9construct…`. */
export function demangleD(name: string): string[] {
  let s = name.startsWith('_D') ? name.slice(2) : ''
  if (!s) return []
  const parts: string[] = []
  while (s.length) {
    let n = 0
    let i = 0
    while (i < s.length && s[i] >= '0' && s[i] <= '9') {
      n = n * 10 + (s.charCodeAt(i) - 48)
      i++
    }
    if (n <= 0 || i + n > s.length) break
    parts.push(s.slice(i, i + n))
    s = s.slice(i + n)
  }
  return parts
}

export function destToModule(dest: string): string {
  let s = dest.replace(/\\/g, '/')
  if (s.startsWith('src-d/')) s = s.slice(6)
  s = s.replace(/\.d$/i, '')
  return s
    .split('/')
    .filter(Boolean)
    .map((part) => part.replace(/[^A-Za-z0-9]/g, '_'))
    .join('.')
}

/** Map a wasm / D symbol onto a printed dest that already exists. Never invents. */
export function destFromWasmName(name: string, dests: string[]): string | null {
  if (!name || !dests.length) return null
  const n = name.replace(/\\/g, '/')
  const destHit = n.match(/(?:^|[^\w])((?:src-d\/)?(?:[\w./\[\]-])+\.d)/)
  if (destHit) {
    const hint = destHit[1]
    const exact = dests.find((d) => d === hint || d.endsWith('/' + hint) || d.endsWith(hint))
    if (exact) return exact
  }
  const dotted = n.includes('.') ? n.replace(/^\$/, '').split(/[^A-Za-z0-9._]/)[0] : ''
  const mangled = demangleD(name)
  const moduleHint = mangled.length >= 2 ? mangled.slice(0, -1).join('.') : dotted
  if (!moduleHint) return null
  let best: string | null = null
  for (const d of dests) {
    const mod = destToModule(d)
    if (!mod) continue
    if (moduleHint === mod || moduleHint.startsWith(mod + '.') || moduleHint.endsWith('.' + mod)) {
      if (!best || mod.length > destToModule(best).length) best = d
    }
  }
  return best
}

export function lookupWasmOrig(map: DebugMap, name: string): DebugEntry | null {
  const dests = [...new Set(map.entries.map((e) => e.dest.replace(/\\/g, '/')))]
  const dest = destFromWasmName(name, dests)
  if (!dest) return null
  return lookupOrig(map, dest, 1) ?? lookupOrig(map, dest, 99999)
}

export function isWasmUrl(url: string | undefined): boolean {
  if (!url) return false
  const u = url.replace(/\\/g, '/')
  return u.startsWith('wasm:') || /\.wasm(?:$|[?#:])/.test(u)
}

const WASM_AT = /\bat\s+(\S+)\s+\((wasm:\/\/[^)]+)\)/g
const WASM_FN = /\bwasm-function\[(\d+)\]/g
const ASYNCIFY_FN = /\basyncify_(?:start|stop)_(?:un)?wind\b/g

/** Rewrite one stack. Unmapped frames stay verbatim. Never invents orig. */
export function rewriteStack(map: DebugMap, stack: string): string {
  if (!stack) return stack
  const colon = stack.replace(FRAME, (all, file: string, ln: string) => appendOrig(map, all, file, ln))
  const ldc = colon.replace(LDC_FRAME, (all, file: string, ln: string) => appendOrig(map, all, file, ln))
  const wasm = ldc.replace(WASM_AT, (all, fn: string, url: string) => {
    const e = lookupWasmOrig(map, fn)
    if (!e) return all
    return `${all} [svelte ${e.orig}:${e.origLine} kind=${e.kind}]`
  })
  return wasm
    .replace(WASM_FN, (all) => (all.includes('[async-wasm]') ? all : `${all} [async-wasm]`))
    .replace(ASYNCIFY_FN, (all) => (all.includes('[asyncify]') ? all : `${all} [asyncify]`))
}

export type DevtoolsFrame = {
  url?: string
  functionName?: string
  lineNumber?: number
  columnNumber?: number
}

export function destFromUrl(url: string): string {
  const u = (url ?? '').replace(/\\/g, '/').split('?')[0]
  const i = u.indexOf('src-d/')
  if (i >= 0) return u.slice(i)
  const j = u.indexOf('routes/')
  if (j >= 0 && u.endsWith('.d')) return 'src-d/' + u.slice(j)
  return u
}

/** Chrome CDP lineNumber is 0-based; Playwright location() is 1-based. */
export function rewriteDevtoolsFrame(
  map: DebugMap,
  frame: DevtoolsFrame,
  lineBase: 0 | 1 = 0
): string {
  if (isWasmUrl(frame.url)) {
    const fn = frame.functionName || '(anonymous)'
    const e = lookupWasmOrig(map, fn)
    const head = `${fn} (${frame.url || 'wasm'})`
    if (!e) return head
    return `${head} [svelte ${e.orig}:${e.origLine} kind=${e.kind}]`
  }
  const dest = destFromUrl(frame.url ?? '')
  const rawLine = frame.lineNumber ?? 0
  const line = lineBase === 0 ? rawLine + 1 : rawLine
  const fn = frame.functionName || '(anonymous)'
  const e = dest ? lookupOrig(map, dest, line) : null
  const head = `${fn} (${dest || frame.url || '?'}:${line})`
  if (!e) return head
  return `${head} [svelte ${e.orig}:${e.origLine} kind=${e.kind}]`
}

export function rewriteCdpStack(
  map: DebugMap,
  frames: DevtoolsFrame[],
  lineBase: 0 | 1 = 0
): string {
  return frames.map((f) => '    at ' + rewriteDevtoolsFrame(map, f, lineBase)).join('\n')
}

export function formatWasmAbort(
  map: DebugMap,
  what: string,
  file: string,
  line: number,
  msg: string
): string {
  const raw = `ABORT: ${what} @ ${file}:${line} ${msg}`
  const e = file ? lookupOrig(map, file, line) : null
  if (!e) return raw
  return `${raw} [svelte ${e.orig}:${e.origLine} kind=${e.kind}]`
}

export function rewriteConsole(
  map: DebugMap,
  args: unknown[]
): { text: string; rewritten: boolean } {
  const text = args.map((a) => (typeof a === 'string' ? a : String(a))).join(' ')
  const next = rewriteStack(map, text)
  return { text: next, rewritten: next !== text }
}

export type KitLogLevel =
  | 'trace'
  | 'debug'
  | 'info'
  | 'warn'
  | 'error'
  | 'critical'
  | 'log'

const ANSI: Record<string, string> = {
  reset: '\x1b[0m',
  dim: '\x1b[2m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  green: '\x1b[32m',
  cyan: '\x1b[36m',
  magenta: '\x1b[35m',
}

function paint(color: string, s: string): string {
  if (process.env.NO_COLOR) return s
  const c = ANSI[color] ?? ''
  return c ? c + s + ANSI.reset : s
}

/** Map browser console / vibe.0 prefix → kit level. */
export function kitLogLevel(raw: string): KitLogLevel {
  const s = raw.toLowerCase()
  if (s.includes('fatal') || s.includes('critical') || s === 'critical') return 'critical'
  if (s.includes('err') || s === 'error' || s === 'assert') return 'error'
  if (s.includes('wrn') || s === 'warn' || s === 'warning') return 'warn'
  if (s.includes('trc') || s === 'trace') return 'trace'
  if (s.includes('dbg') || s.includes('dbv') || s === 'debug') return 'debug'
  if (s.includes('dia') || s === 'diagnostic') return 'debug'
  if (s.includes('inf') || s === 'info' || s === 'log') return 'info'
  return 'log'
}

function levelColor(level: KitLogLevel): string {
  if (level === 'error' || level === 'critical') return 'red'
  if (level === 'warn') return 'yellow'
  if (level === 'info') return 'green'
  if (level === 'trace' || level === 'debug') return 'cyan'
  return 'dim'
}

/** Color a vibe.0 FileLogger line (`[tid:fid ERR] …`) for the bun prompt. */
export function colorizeHostLog(line: string): string {
  const m = line.match(/\b(trc|dbv|dbg|dia|INF|WRN|ERR|CRITICAL|FATAL)\b/)
  const level = kitLogLevel(m?.[1] ?? line)
  return paint(levelColor(level), line)
}

/** One line for the bun+ts+svelte-d command prompt. */
export type OverlayDiag = {
  level: string
  status: string
  source: string
  dest: string
  raw: string
  rewritten: string
}

export type OverlayReport = {
  schema: string
  principle: string
  ok: boolean
  fail: number
  diagnostics: OverlayDiag[]
}

export function overlayPath(ws = workspaceDir()): string {
  return join(ws, '.svelte-d', 'overlay.json')
}

export function loadOverlay(ws = workspaceDir()): OverlayReport {
  const p = overlayPath(ws)
  if (!existsSync(p)) {
    return {
      schema: 'svelte-d-overlay/v1',
      principle: 'D-IR-is-correctness-surface; overlay-is-trace-only',
      ok: true,
      fail: 0,
      diagnostics: [],
    }
  }
  return JSON.parse(readFileSync(p, 'utf8')) as OverlayReport
}

export type InspectorReport = {
  schema: string
  principle: string
  entries: number
  kinds: Record<string, number>
  dests: string[]
}

export function inspectorPath(ws = workspaceDir()): string {
  return join(ws, '.svelte-d', 'ir.json')
}

export function loadInspector(ws = workspaceDir()): InspectorReport {
  const p = inspectorPath(ws)
  if (!existsSync(p)) {
    return {
      schema: 'svelte-d-ir-inspector/v1',
      principle: 'D-IR-is-correctness-surface; inspector-is-read-only',
      entries: 0,
      kinds: {},
      dests: [],
    }
  }
  return JSON.parse(readFileSync(p, 'utf8')) as InspectorReport
}

export function formatBridgeLine(opts: {
  source: 'chrome' | 'firefox' | 'host' | 'vite' | 'compile'
  kind?: string
  text: string
}): string {
  const kind = opts.kind ?? 'log'
  const level = kitLogLevel(kind)
  const tag = `[${opts.source} ${kind}]`
  const body = opts.source === 'host' ? colorizeHostLog(opts.text) : paint(levelColor(level), opts.text)
  return paint(levelColor(level), tag) + ' ' + body
}
