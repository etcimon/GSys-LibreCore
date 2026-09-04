// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Best-effort wasm name section → printed dest → orig .svelte.
// No DWARF. Never invents an orig. D IR stays the correctness surface.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadDebugMap, lookupWasmOrig, destFromWasmName } from './debug.ts'
import { workspaceDir } from './paths.ts'

export type WasmNameFn = {
  index: number
  name: string
  dest: string
  orig: string
  origLine: number
  kind: string
}

export type WasmNameReport = {
  schema: string
  principle: string
  source: string
  functions: WasmNameFn[]
  named: number
  joined: number
}

const EMPTY: WasmNameReport = {
  schema: 'svelte-d-wasm-names/v1',
  principle: 'D-IR-is-correctness-surface; names-are-trace-only',
  source: '',
  functions: [],
  named: 0,
  joined: 0,
}

export function wasmNamesPath(ws = workspaceDir()): string {
  return join(ws, '.svelte-d', 'wasm-names.json')
}

export function loadWasmNames(ws = workspaceDir()): WasmNameReport {
  const p = wasmNamesPath(ws)
  if (!existsSync(p)) return { ...EMPTY }
  return JSON.parse(readFileSync(p, 'utf8')) as WasmNameReport
}

function readU32(buf: Uint8Array, i: number): [number, number] {
  let result = 0
  let shift = 0
  while (i < buf.length) {
    const b = buf[i++]
    result |= (b & 0x7f) << shift
    if ((b & 0x80) === 0) break
    shift += 7
  }
  return [result >>> 0, i]
}

function readBytes(buf: Uint8Array, i: number, n: number): [Uint8Array, number] {
  return [buf.subarray(i, i + n), i + n]
}

function readString(buf: Uint8Array, i: number): [string, number] {
  const [n, j] = readU32(buf, i)
  const [bytes, k] = readBytes(buf, j, n)
  return [new TextDecoder('utf-8').decode(bytes), k]
}

/** Parse the custom `name` section. Empty if the wasm has no names. */
export function parseWasmNames(buf: Uint8Array): { index: number; name: string }[] {
  if (buf.length < 8) return []
  if (buf[0] !== 0x00 || buf[1] !== 0x61 || buf[2] !== 0x73 || buf[3] !== 0x6d) return []
  let i = 8
  const out: { index: number; name: string }[] = []
  while (i < buf.length) {
    const id = buf[i++]
    const [size, j] = readU32(buf, i)
    const end = j + size
    if (end > buf.length) break
    if (id === 0) {
      const [secName, k] = readString(buf, j)
      if (secName === 'name') {
        let p = k
        while (p < end) {
          const sub = buf[p++]
          const [subSize, q] = readU32(buf, p)
          const subEnd = q + subSize
          if (sub === 1) {
            const [count, r0] = readU32(buf, q)
            let r = r0
            for (let n = 0; n < count && r < subEnd; n++) {
              const [idx, r1] = readU32(buf, r)
              const [name, r2] = readString(buf, r1)
              out.push({ index: idx, name })
              r = r2
            }
          }
          p = subEnd
        }
      }
    }
    i = end
  }
  return out
}

export function writeWasmNameMap(
  opts: { ws?: string; wasm?: string } = {}
): WasmNameReport {
  const ws = opts.ws ?? workspaceDir()
  const wasm =
    opts.wasm ??
    (existsSync(join(ws, 'public', 'svelte-engine.wasm'))
      ? join(ws, 'public', 'svelte-engine.wasm')
      : join(ws, 'public', 'svelte-engine-raw.wasm'))
  const map = loadDebugMap(ws)
  const dests = [...new Set(map.entries.map((e) => e.dest.replace(/\\/g, '/')))]
  const report: WasmNameReport = {
    ...EMPTY,
    source: wasm.replace(/\\/g, '/'),
  }
  if (!existsSync(wasm)) {
    persist(ws, report)
    return report
  }
  const parsed = parseWasmNames(new Uint8Array(readFileSync(wasm)))
  report.named = parsed.length
  for (const fn of parsed) {
    const e = lookupWasmOrig(map, fn.name)
    const dest = e ? e.dest.replace(/\\/g, '/') : destFromWasmName(fn.name, dests) ?? ''
    report.functions.push({
      index: fn.index,
      name: fn.name,
      dest,
      orig: e?.orig ?? '',
      origLine: e?.origLine ?? 0,
      kind: e?.kind ?? '',
    })
    if (e) report.joined++
  }
  persist(ws, report)
  return report
}

function persist(ws: string, report: WasmNameReport): void {
  const json = JSON.stringify(report) + '\n'
  const dir = join(ws, '.svelte-d')
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'wasm-names.json'), json)
  const pub = join(ws, 'public', '__svelte-d')
  mkdirSync(pub, { recursive: true })
  writeFileSync(join(pub, 'wasm-names.json'), json)
}

/** Encode a tiny wasm module with a name section (tests). */
export function encodeNamedWasm(fns: { name: string }[]): Uint8Array {
  const typeSec = Uint8Array.from([0x01, 0x04, 0x01, 0x60, 0x00, 0x00])
  const funcSec = encodeSection(0x03, [...u32(fns.length), ...fns.map(() => 0)])
  const bodies = fns.map(() => [0x02, 0x00, 0x0b])
  const codePayload: number[] = [...u32(fns.length), ...bodies.flat()]
  const codeSec = encodeSection(0x0a, codePayload)
  const nameInner = encodeFuncNameSub(fns.map((f, i) => ({ index: i, name: f.name })))
  const nameSec = encodeSection(0x00, [...u32(4), 0x6e, 0x61, 0x6d, 0x65, ...nameInner])
  return Uint8Array.from([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...typeSec,
    ...funcSec,
    ...codeSec,
    ...nameSec,
  ])
}

function encodeFuncNameSub(fns: { index: number; name: string }[]): number[] {
  const entries: number[] = [...u32(fns.length)]
  for (const f of fns) {
    entries.push(...u32(f.index))
    const bytes = [...new TextEncoder().encode(f.name)]
    entries.push(...u32(bytes.length), ...bytes)
  }
  return [0x01, ...u32(entries.length), ...entries]
}

function encodeSection(id: number, payload: number[]): number[] {
  return [id, ...u32(payload.length), ...payload]
}

function u32(n: number): number[] {
  const o: number[] = []
  let v = n >>> 0
  while (v >= 0x80) {
    o.push((v & 0x7f) | 0x80)
    v >>>= 7
  }
  o.push(v)
  return o
}
