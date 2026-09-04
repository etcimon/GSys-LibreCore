// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
  utimesSync,
  watch,
  type Dirent,
} from 'node:fs'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import {
  compileWorkspace,
  dropWorkspace,
  parseSvelte,
  runCli,
  findRiscvDev,
  workspaceDir,
  templateDir,
  mapKitPath,
  buildWasm,
  buildHost,
  type RunResult,
} from 'svelte-d'

export type CellPolicy = 'if-missing' | 'if-stale' | 'always' | 'never'

export type PrepareOpts = {
  forceDrop?: boolean
  wasm?: CellPolicy
  host?: CellPolicy
}

export function dropWs(force = false) {
  return dropWorkspace({ force })
}

export function compileWs(only?: string) {
  if (only)
    return compileWorkspace({ ws: workspaceDir(), only: [only] })
  return compileWorkspace(workspaceDir())
}

export function parseGolden() {
  const page = join(templateDir(), 'src-svelte', 'routes', '+page.svelte')
  return parseSvelte(page)
}

export function readManifest() {
  const man = join(workspaceDir(), '.svelte-d', 'manifest.json')
  if (!existsSync(man)) return null
  return JSON.parse(readFileSync(man, 'utf8'))
}

export function runSvelteD(args: string[]) {
  return runCli(args)
}

export function wasmArtifact(ws: string): string | null {
  const ship = join(ws, 'public', 'svelte-engine.wasm')
  const raw = join(ws, 'public', 'svelte-engine-raw.wasm')
  if (existsSync(ship)) return ship
  if (existsSync(raw)) return raw
  return null
}

export function hostArtifact(ws: string): string | null {
  const win = join(ws, 'webserver', 'svelte-engine-server.exe')
  const posix = join(ws, 'webserver', 'svelte-engine-server')
  if (existsSync(win)) return win
  if (existsSync(posix)) return posix
  return null
}

function mtime(p: string): number {
  try {
    return statSync(p).mtimeMs
  } catch {
    return 0
  }
}

function newestUnder(dir: string, ext: string[]): number {
  if (!existsSync(dir)) return 0
  let newest = 0
  const stack = [dir]
  while (stack.length) {
    const d = stack.pop()!
    let ents: Dirent[]
    try {
      ents = readdirSync(d, { withFileTypes: true })
    } catch {
      continue
    }
    for (const e of ents) {
      const p = join(d, e.name)
      if (e.isDirectory()) {
        if (e.name === '.dub' || e.name === 'node_modules') continue
        stack.push(p)
      } else if (ext.some((x) => e.name.endsWith(x))) {
        const t = mtime(p)
        if (t > newest) newest = t
      }
    }
  }
  return newest
}

export function wasmDirty(ws: string, policy: CellPolicy = 'if-stale'): boolean {
  if (policy === 'never') return false
  if (policy === 'always') return true
  const art = wasmArtifact(ws)
  if (!art) return true
  if (policy === 'if-missing') return false
  if (!existsSync(join(ws, '.svelte-d', 'wasm.json'))) return true
  // Reprint of wasm dests this compile — clocks can tie dest and artifact.
  if (readWriteStats(ws).wasm > 0) return true
  // Printed IR + cell pin, not src-svelte. A hash-skip compile must not
  // relink wasm just because a .svelte was touched.
  const src = Math.max(
    newestUnder(join(ws, 'src-d'), ['.d']),
    mtime(join(ws, 'dub.sdl'))
  )
  return src > mtime(art)
}

export function hostDirty(ws: string, policy: CellPolicy = 'if-stale'): boolean {
  if (policy === 'never') return false
  if (policy === 'always') return true
  const art = hostArtifact(ws)
  if (!art) return true
  if (policy === 'if-missing') return false
  if (!existsSync(join(ws, '.svelte-d', 'host.json'))) return true
  const src = Math.max(
    newestUnder(join(ws, 'webserver', 'source'), ['.d']),
    newestUnder(join(ws, 'src-svelte'), ['.d'])
  )
  return src > mtime(art)
}

export function notifyWasmReload(ws: string): boolean {
  const art = wasmArtifact(ws)
  if (!art) return false
  const now = new Date()
  utimesSync(art, now, now)
  return true
}

export function buildDirtyCells(
  ws: string,
  opts: { wasm?: CellPolicy; host?: CellPolicy } = {}
): { wasm: RunResult | null; host: RunResult | null } {
  const wasmPol = opts.wasm ?? 'if-stale'
  const hostPol = opts.host ?? 'if-stale'
  let wasm: RunResult | null = null
  let host: RunResult | null = null
  if (wasmDirty(ws, wasmPol)) wasm = buildWasm(ws)
  if (hostDirty(ws, hostPol)) host = buildHost(ws)
  return { wasm, host }
}

/** bun install in the ws when Vite is missing (drop skips node_modules). */
export function ensureWsDeps(ws: string): RunResult {
  const viteJs = join(ws, 'node_modules', 'vite', 'package.json')
  let need = !existsSync(viteJs)
  const pkgPath = join(ws, 'package.json')
  if (!need && existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(readFileSync(pkgPath, 'utf8')) as {
        dependencies?: Record<string, string>
      }
      for (const name of Object.keys(pkg.dependencies ?? {})) {
        if (!existsSync(join(ws, 'node_modules', name, 'package.json'))) {
          need = true
          break
        }
      }
    } catch {
      need = true
    }
  }
  if (!need) {
    return { status: 0, stdout: 'vite already installed\n', stderr: '', via: 'exe' }
  }
  const r = spawnSync('bun', ['install'], {
    cwd: ws,
    encoding: 'utf8',
    shell: false,
  })
  return {
    status: r.status ?? 1,
    stdout: r.stdout ?? '',
    stderr: r.stderr ?? '',
    via: 'exe',
  }
}

export function viteBin(ws: string): string {
  const names = ['vite.exe', 'vite.cmd', 'vite']
  for (const n of names) {
    const p = join(ws, 'node_modules', '.bin', n)
    if (existsSync(p)) return p
  }
  return 'vite'
}

/** Drop if needed, compile IR, build missing/stale cells, bun install. */
export function prepareDev(opts: PrepareOpts = {}): {
  ws: string
  drop: RunResult | null
  compile: RunResult
  cells: { wasm: RunResult | null; host: RunResult | null }
  deps: RunResult
} {
  const ws = workspaceDir()
  let drop: RunResult | null = null
  if (!existsSync(ws) || opts.forceDrop) {
    drop = dropWorkspace({ force: !!opts.forceDrop || existsSync(ws) })
  }
  const compile = compileWorkspace(ws)
  const cells = buildDirtyCells(ws, {
    wasm: opts.wasm ?? 'if-stale',
    host: opts.host ?? 'if-stale',
  })
  const deps = ensureWsDeps(ws)
  return { ws, drop, compile, cells, deps }
}

/** Kit source → which cell a watch fire should relink. */
export function cellForSrc(file: string): 'wasm' | 'host' | 'both' {
  const s = String(file).replace(/\\/g, '/')
  if (
    s.endsWith('+page.server.d') ||
    s.endsWith('+layout.server.d') ||
    s.endsWith('+server.d') ||
    s.includes('hooks.server') ||
    s.includes('webserver/source')
  )
    return 'host'
  return 'wasm'
}

export function readWriteStats(ws: string): {
  wrote: number
  skipped: number
  wasm: number
  host: number
  parsed: number
  hashSkip: number
} {
  const z = { wrote: 0, skipped: 0, wasm: 0, host: 0, parsed: 0, hashSkip: 0 }
  const p = join(ws, '.svelte-d', 'write.json')
  if (!existsSync(p)) return z
  try {
    const j = JSON.parse(readFileSync(p, 'utf8')) as Partial<typeof z>
    return {
      wrote: j.wrote ?? 0,
      skipped: j.skipped ?? 0,
      wasm: j.wasm ?? 0,
      host: j.host ?? 0,
      parsed: j.parsed ?? 0,
      hashSkip: j.hashSkip ?? 0,
    }
  } catch {
    return z
  }
}

export function watchSrcSvelte(
  ws: string,
  onChange: (file: string) => void
): { close: () => void } {
  const dir = join(ws, 'src-svelte')
  if (!existsSync(dir)) return { close() {} }
  let timer: ReturnType<typeof setTimeout> | undefined
  let last = ''
  const w = watch(dir, { recursive: true }, (_ev, fn) => {
    if (!fn) return
    const s = String(fn)
    if (
      !(
        s.endsWith('.svelte') ||
        s.endsWith('.d') ||
        s.endsWith('.ts')
      )
    )
      return
    last = s
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => onChange(last), 120)
  })
  return {
    close() {
      if (timer) clearTimeout(timer)
      w.close()
    },
  }
}

export { findRiscvDev, workspaceDir, templateDir, mapKitPath }
