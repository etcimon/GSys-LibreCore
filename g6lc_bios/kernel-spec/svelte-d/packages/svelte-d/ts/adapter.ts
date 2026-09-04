// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Adapters consume ws/.svelte-d/manifest.json and copy artifacts.
// They do not add a Node HTTP stack, do not replace vibe.0 listenHTTP,
// and do not parse Svelte with svelte/compiler.
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { workspaceDir } from './paths.ts'

export const ADAPTERS = [
  'static',
  'libwasm-spa',
  'vibe0',
  'vibe0-proxy',
] as const

export type AdapterName = (typeof ADAPTERS)[number]

export type ManifestV1 = {
  schema: string
  workspace?: string
  ok?: number
  fail?: number
  pglite?: string
  srcD?: string
  tsModules?: number
  lodash?: number
  bindings?: number
  router?: number
  host?: number
  dom?: number
  fallthrough?: string
  bootstrap?: string
  accommodate?: string
  [key: string]: unknown
}

export type AdaptOpts = {
  ws?: string
  adapter: string
  out: string
}

export type AdapterReport = {
  schema: 'svelte-d-adapter/v1'
  adapter: AdapterName
  workspace: string
  out: string
  manifest: ManifestV1
  copied: string[]
  missing: string[]
  notes: string[]
}

const SKIP_DIR = new Set(['node_modules', '.dub', '.git', '.vs'])

export function normalizeAdapter(name: string): AdapterName {
  const n = String(name ?? '')
    .trim()
    .replace(/^adapter-/, '')
    .toLowerCase()
  if (n === 'spa') return 'libwasm-spa'
  if (
    n === 'static' ||
    n === 'libwasm-spa' ||
    n === 'vibe0' ||
    n === 'vibe0-proxy'
  )
    return n
  throw new Error(
    `unknown adapter ${name} (want static | libwasm-spa | vibe0 | vibe0-proxy)`
  )
}

export function manifestPath(ws: string): string {
  return join(ws, '.svelte-d', 'manifest.json')
}

export function readWsManifest(ws: string): ManifestV1 {
  const p = manifestPath(ws)
  if (!existsSync(p)) {
    throw new Error(
      `missing ${p.replace(/\\/g, '/')} — compile the workspace first`
    )
  }
  const j = JSON.parse(readFileSync(p, 'utf8')) as ManifestV1
  if (j.schema !== 'svelte-d-manifest/v1') {
    throw new Error(`unexpected manifest schema ${String(j.schema)}`)
  }
  return j
}

function posixRel(rel: string): string {
  return rel.replace(/\\/g, '/')
}

function skipName(name: string, adapter: AdapterName): boolean {
  if (SKIP_DIR.has(name)) return true
  if (name.endsWith('.pdb') || name.endsWith('.obj')) return true
  if (name === 'hmr-tick' && adapter !== 'vibe0-proxy') return true
  return false
}

function copyFileInto(
  from: string,
  destRoot: string,
  destRel: string,
  copied: string[]
): void {
  const dest = join(destRoot, destRel)
  mkdirSync(dirname(dest), { recursive: true })
  copyFileSync(from, dest)
  const rel = posixRel(destRel)
  if (!copied.includes(rel)) copied.push(rel)
}

function copyTree(
  srcRoot: string,
  destRoot: string,
  srcRel: string,
  destRel: string,
  adapter: AdapterName,
  copied: string[]
): void {
  const from = join(srcRoot, srcRel)
  if (!existsSync(from)) return
  const st = statSync(from)
  if (st.isDirectory()) {
    for (const name of readdirSync(from)) {
      if (skipName(name, adapter)) continue
      copyTree(
        srcRoot,
        destRoot,
        srcRel ? join(srcRel, name) : name,
        destRel ? join(destRel, name) : name,
        adapter,
        copied
      )
    }
    return
  }
  copyFileInto(from, destRoot, destRel, copied)
}

function hostExeRel(ws: string): string | null {
  const win = join('webserver', 'svelte-engine-server.exe')
  const posix = join('webserver', 'svelte-engine-server')
  if (existsSync(join(ws, win))) return win
  if (existsSync(join(ws, posix))) return posix
  return null
}

function copyHostExe(ws: string, out: string, copied: string[]): string | null {
  const rel = hostExeRel(ws)
  if (!rel) return null
  const base = rel.endsWith('.exe')
    ? 'svelte-engine-server.exe'
    : 'svelte-engine-server'
  copyFileInto(join(ws, rel), out, base, copied)
  return base
}

function copyPublicFlat(
  ws: string,
  out: string,
  adapter: AdapterName,
  copied: string[]
): void {
  const pub = join(ws, 'public')
  if (!existsSync(pub)) return
  copyTree(ws, out, 'public', '', adapter, copied)
}

function copyPublicNested(
  ws: string,
  out: string,
  adapter: AdapterName,
  copied: string[]
): void {
  if (!existsSync(join(ws, 'public'))) return
  copyTree(ws, out, 'public', 'public', adapter, copied)
}

function notesFor(adapter: AdapterName, hasDist: boolean, hasPrerender: boolean): string[] {
  const notes: string[] = [
    'consumes .svelte-d/manifest.json; does not add a Node HTTP stack',
    'does not replace vibe.0 listenHTTP',
    'HMR :3001 is not packaged',
  ]
  if (adapter === 'static') {
    notes.push(
      'static fileserver of out/; public/ is flattened (Vite public convention)'
    )
    notes.push(
      hasDist
        ? 'ws/dist present — Vite production files overlay the shell'
        : 'no ws/dist — index.html still points at src-ts/main.ts (run Vite build for a JS bundle)'
    )
    if (hasPrerender)
      notes.push('.svelte-d/prerender flattened onto out/')
    else notes.push('no prerender crawl (Host-JS-only); CSR shell only')
  }
  if (adapter === 'libwasm-spa') {
    notes.push(
      'SPA: fileserver fallback is index.html; no prerender; no host exe'
    )
    notes.push(
      hasDist
        ? 'ws/dist present — Vite production files overlay the shell'
        : 'no ws/dist — index.html still points at src-ts/main.ts (run Vite build for a JS bundle)'
    )
  }
  if (adapter === 'vibe0') {
    notes.push(
      'production host packaging: exe + public/ + certs; cwd of the exe should see ./public/'
    )
    notes.push(
      'engine app.d currently reverse-proxies * to :5173; production static is the commented serveStaticFiles("./public/") — this adapter does not rewrite the host'
    )
  }
  if (adapter === 'vibe0-proxy') {
    notes.push(
      'dev-style: svelte-engine-server :8180 reverseProxyRequest to Vite :5173 (app.d)'
    )
    notes.push('run Vite alongside the exe; do not treat this as a no-Vite ship')
  }
  return notes
}

export function adaptWorkspace(opts: AdaptOpts): AdapterReport {
  const adapter = normalizeAdapter(opts.adapter)
  const ws = resolve(opts.ws ?? workspaceDir())
  const out = resolve(opts.out)
  if (!existsSync(ws)) throw new Error(`workspace missing: ${ws}`)
  if (out === ws) throw new Error('adapter --out must not be the workspace root')
  const manifest = readWsManifest(ws)
  mkdirSync(out, { recursive: true })

  const copied: string[] = []
  const missing: string[] = []
  const hasDist = existsSync(join(ws, 'dist'))
  const hasPrerender = existsSync(join(ws, '.svelte-d', 'prerender'))

  if (adapter === 'static' || adapter === 'libwasm-spa') {
    if (existsSync(join(ws, 'index.html')))
      copyFileInto(join(ws, 'index.html'), out, 'index.html', copied)
    else missing.push('index.html')
    if (existsSync(join(ws, 'public'))) copyPublicFlat(ws, out, adapter, copied)
    else missing.push('public/')
    if (hasDist) copyTree(ws, out, 'dist', '', adapter, copied)
    if (adapter === 'static' && hasPrerender)
      copyTree(ws, out, join('.svelte-d', 'prerender'), '', adapter, copied)
  }

  if (adapter === 'vibe0' || adapter === 'vibe0-proxy') {
    const exe = copyHostExe(ws, out, copied)
    if (!exe) missing.push('webserver/svelte-engine-server')
    if (existsSync(join(ws, 'public')))
      copyPublicNested(ws, out, adapter, copied)
    else missing.push('public/')
    if (existsSync(join(ws, 'webserver', 'certs')))
      copyTree(ws, out, join('webserver', 'certs'), 'certs', adapter, copied)
    else missing.push('webserver/certs')
    if (existsSync(join(ws, 'webserver', '3dify.json')))
      copyFileInto(join(ws, 'webserver', '3dify.json'), out, '3dify.json', copied)
    if (existsSync(join(ws, 'index.html')))
      copyFileInto(join(ws, 'index.html'), out, 'index.html', copied)
  }

  if (!copied.includes('adapter.json')) copied.push('adapter.json')
  copied.sort()
  const report: AdapterReport = {
    schema: 'svelte-d-adapter/v1',
    adapter,
    workspace: posixRel(ws),
    out: posixRel(out),
    manifest,
    copied,
    missing,
    notes: notesFor(adapter, hasDist, hasPrerender),
  }
  writeFileSync(
    join(out, 'adapter.json'),
    JSON.stringify(report, null, 2) + '\n'
  )
  return report
}
