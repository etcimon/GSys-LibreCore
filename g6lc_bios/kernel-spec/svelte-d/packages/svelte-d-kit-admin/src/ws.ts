// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Resolve this package's dest from svelte-d.config.ts even when cwd is
// the repo root (which has its own svelte-d.config.ts).
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveConfigWorkspace } from 'svelte-d'

export const adminProject = dirname(dirname(fileURLToPath(import.meta.url)))

export function adminWorkspace(): string {
  return resolveConfigWorkspace(adminProject) || join(adminProject, 'svelte-engine-ws')
}

/** Engine leftovers import SECRET_TOKEN from $env/static/private. */
export function writeWorkspaceEnv(ws = adminWorkspace()): void {
  const dest = join(ws, '.env')
  const candidates = [join(adminProject, '.env'), join(adminProject, '.env.example')]
  const src = candidates.find((p) => existsSync(p))
  const text = src
    ? readFileSync(src, 'utf8')
    : 'PUBLIC_APP_NAME=svelte-d-kit-admin\nSECRET_TOKEN=dev-secret\n'
  writeFileSync(dest, text)
}

/** Keep botan off full_openssl so vibe-0 can use openssl 3.3.4. */
export function pinHostBotanConfig(ws = adminWorkspace()): void {
  const sdl = join(ws, 'webserver', 'dub.sdl')
  if (!existsSync(sdl)) return
  const src = readFileSync(sdl, 'utf8')
  if (src.includes('subConfiguration "botan"')) return
  writeFileSync(
    sdl,
    src.replace(
      /dependency "botan" version="[^"]+"/,
      (m) => m + '\nsubConfiguration "botan" "full"'
    )
  )
}

export function hostExePath(ws = adminWorkspace()): string {
  const win = join(ws, 'webserver', 'svelte-engine-server.exe')
  const posix = join(ws, 'webserver', 'svelte-engine-server')
  if (existsSync(win)) return win
  if (existsSync(posix)) return posix
  return ''
}

export function wasmPath(ws = adminWorkspace()): string {
  const pub = join(ws, 'public', 'svelte-engine.wasm')
  const raw = join(ws, 'public', 'svelte-engine-raw.wasm')
  if (existsSync(pub)) return pub
  if (existsSync(raw)) return raw
  return ''
}

export function fileBytes(path: string): number {
  if (!path || !existsSync(path)) return 0
  return statSync(path).size
}

export function fmtBytes(n: number): string {
  if (n >= 1024 * 1024) return (n / (1024 * 1024)).toFixed(2) + ' MiB (' + n + ' bytes)'
  if (n >= 1024) return (n / 1024).toFixed(1) + ' KiB (' + n + ' bytes)'
  return n + ' bytes'
}

export type ArtifactSizes = {
  workspace: string
  wasm: { path: string; bytes: number; label: string }
  host: { path: string; bytes: number; label: string }
}

export function artifactSizes(ws = adminWorkspace()): ArtifactSizes {
  const wasm = wasmPath(ws)
  const host = hostExePath(ws)
  const wasmBytes = fileBytes(wasm)
  const hostBytes = fileBytes(host)
  return {
    workspace: ws,
    wasm: { path: wasm, bytes: wasmBytes, label: fmtBytes(wasmBytes) },
    host: { path: host, bytes: hostBytes, label: fmtBytes(hostBytes) },
  }
}
