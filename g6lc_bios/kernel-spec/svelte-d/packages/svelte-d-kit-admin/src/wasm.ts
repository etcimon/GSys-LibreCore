// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { copyFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { findRiscvDev, writeWasmNameMap } from 'svelte-d'

/** Drop skips *.wasm. Copy the sibling engine artifact so Vite can boot libwasm. */
export function ensureWasm(ws: string): string | null {
  const pub = join(ws, 'public')
  const dest = join(pub, 'svelte-engine.wasm')
  const destRaw = join(pub, 'svelte-engine-raw.wasm')
  const looksWasm = (p: string) => {
    try {
      const b = readFileSync(p)
      return b.length >= 4 && b[0] === 0 && b[1] === 0x61 && b[2] === 0x73 && b[3] === 0x6d
    } catch {
      return false
    }
  }
  let wasm = existsSync(dest) && looksWasm(dest) ? dest : ''
  if (!wasm) {
    const src = join(findRiscvDev(), 'svelte-engine', 'public', 'svelte-engine.wasm')
    const raw = join(findRiscvDev(), 'svelte-engine', 'public', 'svelte-engine-raw.wasm')
    const from =
      existsSync(destRaw) && looksWasm(destRaw)
        ? destRaw
        : existsSync(src) && looksWasm(src)
          ? src
          : existsSync(raw) && looksWasm(raw)
            ? raw
            : ''
    if (!from) return null
    mkdirSync(pub, { recursive: true })
    copyFileSync(from, dest)
    wasm = dest
  }
  writeWasmNameMap({ ws, wasm })
  return wasm
}
