// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { afterAll, describe, expect, test } from 'bun:test'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import {
  ADAPTERS,
  adaptWorkspace,
  normalizeAdapter,
  readWsManifest,
  workspaceDir,
} from 'svelte-d'
import staticAdapter from '../../adapter-static/index.ts'
import spaAdapter from '../../adapter-libwasm-spa/index.ts'
import vibe0Adapter from '../../adapter-vibe0/index.ts'
import vibe0ProxyAdapter from '../../adapter-vibe0-proxy/index.ts'

const scratch = mkdtempSync(join(tmpdir(), 'svelte-d-adapt-'))

afterAll(() => {
  try {
    rmSync(scratch, { recursive: true, force: true })
  } catch {
    /* leftover */
  }
})

function fixtureWs(): string {
  const dir = mkdtempSync(join(scratch, 'ws-'))
  mkdirSync(join(dir, '.svelte-d', 'prerender'), { recursive: true })
  mkdirSync(join(dir, 'public', '__svelte-d'), { recursive: true })
  mkdirSync(join(dir, 'webserver', 'certs'), { recursive: true })
  mkdirSync(join(dir, 'dist'), { recursive: true })
  writeFileSync(
    join(dir, '.svelte-d', 'manifest.json'),
    JSON.stringify({
      schema: 'svelte-d-manifest/v1',
      workspace: dir.replace(/\\/g, '/'),
      ok: 1,
      fail: 0,
      pglite: 'passthrough',
      srcD: 'libwasm-ir',
      tsModules: 1,
      lodash: 0,
      bindings: 0,
      router: 1,
      host: 1,
      dom: 1,
      fallthrough: 'kit-equivalent-ws',
      bootstrap: 'svelte-engine',
      accommodate: 'engine-libwasm-vibe0',
    }) + '\n'
  )
  writeFileSync(
    join(dir, 'index.html'),
    '<!doctype html><html><body><div id="root"></div></body></html>\n'
  )
  writeFileSync(join(dir, 'public', 'svelte-engine.wasm'), 'wasm-stub')
  writeFileSync(join(dir, 'public', 'vite.svg'), '<svg/>')
  writeFileSync(join(dir, 'public', '__svelte-d', 'hmr-tick'), 'reload')
  writeFileSync(join(dir, '.svelte-d', 'prerender', 'about.html'), '<p>about</p>')
  writeFileSync(join(dir, 'dist', 'bundle.js'), '/* vite */')
  writeFileSync(join(dir, 'webserver', 'svelte-engine-server.exe'), 'exe-stub')
  writeFileSync(join(dir, 'webserver', 'certs', 'cert.crt'), 'cert')
  writeFileSync(join(dir, 'webserver', '3dify.json'), '{}')
  return dir
}

describe('adapter names', () => {
  test('normalizeAdapter accepts package and short names', () => {
    expect(normalizeAdapter('adapter-static')).toBe('static')
    expect(normalizeAdapter('spa')).toBe('libwasm-spa')
    expect(normalizeAdapter('adapter-libwasm-spa')).toBe('libwasm-spa')
    expect(normalizeAdapter('adapter-vibe0-proxy')).toBe('vibe0-proxy')
    expect(ADAPTERS).toEqual(['static', 'libwasm-spa', 'vibe0', 'vibe0-proxy'])
  })

  test('unknown adapter throws', () => {
    expect(() => normalizeAdapter('node')).toThrow(/unknown adapter/)
    expect(() =>
      adaptWorkspace({ ws: fixtureWs(), adapter: 'cloudflare', out: join(scratch, 'no') })
    ).toThrow(/unknown adapter/)
  })
})

describe('adaptWorkspace packages artifacts from manifest.json', () => {
  test('missing manifest throws', () => {
    const empty = mkdtempSync(join(scratch, 'empty-'))
    expect(() =>
      adaptWorkspace({ ws: empty, adapter: 'static', out: join(empty, 'out') })
    ).toThrow(/compile the workspace first/)
  })

  test('adapter-static flattens public, overlays dist, copies prerender, skips host and hmr-tick', () => {
    const ws = fixtureWs()
    const out = join(scratch, 'static-out')
    const r = adaptWorkspace({ ws, adapter: 'static', out })
    expect(r.schema).toBe('svelte-d-adapter/v1')
    expect(r.adapter).toBe('static')
    expect(r.manifest.schema).toBe('svelte-d-manifest/v1')
    expect(existsSync(join(out, 'adapter.json'))).toBe(true)
    expect(existsSync(join(out, 'index.html'))).toBe(true)
    expect(readFileSync(join(out, 'index.html'), 'utf8')).toContain('id="root"')
    expect(existsSync(join(out, 'svelte-engine.wasm'))).toBe(true)
    expect(existsSync(join(out, 'vite.svg'))).toBe(true)
    expect(existsSync(join(out, 'bundle.js'))).toBe(true)
    expect(existsSync(join(out, 'about.html'))).toBe(true)
    expect(existsSync(join(out, 'svelte-engine-server.exe'))).toBe(false)
    expect(existsSync(join(out, '__svelte-d', 'hmr-tick'))).toBe(false)
    expect(r.notes.some((n) => n.includes('Node HTTP'))).toBe(true)
    expect(r.notes.some((n) => n.includes('prerender'))).toBe(true)
    const written = JSON.parse(readFileSync(join(out, 'adapter.json'), 'utf8'))
    expect(written.schema).toBe('svelte-d-adapter/v1')
    expect(written.copied).toContain('adapter.json')
  })

  test('adapter-libwasm-spa is CSR-only (no prerender, no host)', () => {
    const ws = fixtureWs()
    const out = join(scratch, 'spa-out')
    const r = spaAdapter({ ws, out })
    expect(r.adapter).toBe('libwasm-spa')
    expect(existsSync(join(out, 'svelte-engine.wasm'))).toBe(true)
    expect(existsSync(join(out, 'about.html'))).toBe(false)
    expect(existsSync(join(out, 'svelte-engine-server.exe'))).toBe(false)
    expect(r.notes.some((n) => /SPA/.test(n))).toBe(true)
  })

  test('adapter-vibe0 copies exe + public/ + certs, does not flatten', () => {
    const ws = fixtureWs()
    const out = join(scratch, 'vibe0-out')
    const r = vibe0Adapter({ ws, out })
    expect(r.adapter).toBe('vibe0')
    expect(existsSync(join(out, 'svelte-engine-server.exe'))).toBe(true)
    expect(existsSync(join(out, 'public', 'svelte-engine.wasm'))).toBe(true)
    expect(existsSync(join(out, 'certs', 'cert.crt'))).toBe(true)
    expect(existsSync(join(out, '3dify.json'))).toBe(true)
    expect(existsSync(join(out, 'svelte-engine.wasm'))).toBe(false)
    expect(r.notes.some((n) => n.includes('serveStaticFiles'))).toBe(true)
    expect(r.notes.some((n) => n.includes('does not rewrite the host'))).toBe(true)
  })

  test('adapter-vibe0-proxy copies the host and names the Vite reverse proxy', () => {
    const ws = fixtureWs()
    const out = join(scratch, 'proxy-out')
    const r = vibe0ProxyAdapter({ ws, out })
    expect(r.adapter).toBe('vibe0-proxy')
    expect(existsSync(join(out, 'svelte-engine-server.exe'))).toBe(true)
    expect(existsSync(join(out, 'public', '__svelte-d', 'hmr-tick'))).toBe(true)
    expect(r.notes.some((n) => n.includes('reverseProxyRequest'))).toBe(true)
    expect(r.notes.some((n) => n.includes(':5173'))).toBe(true)
  })

  test('package default exports pin the adapter name', () => {
    const ws = fixtureWs()
    expect(staticAdapter({ ws, out: join(scratch, 'pkg-static') }).adapter).toBe(
      'static'
    )
    expect(spaAdapter({ ws, out: join(scratch, 'pkg-spa') }).adapter).toBe(
      'libwasm-spa'
    )
    expect(vibe0Adapter({ ws, out: join(scratch, 'pkg-v0') }).adapter).toBe('vibe0')
    expect(
      vibe0ProxyAdapter({ ws, out: join(scratch, 'pkg-px') }).adapter
    ).toBe('vibe0-proxy')
  })

  test('refuses to write --out onto the workspace root', () => {
    const ws = fixtureWs()
    expect(() => adaptWorkspace({ ws, adapter: 'static', out: ws })).toThrow(
      /must not be the workspace root/
    )
  })
})

describe('adapt CLI + live workspace', () => {
  test('svelte-kit-d adapt static writes adapter.json', () => {
    const ws = fixtureWs()
    const out = join(scratch, 'cli-out')
    const cli = join(import.meta.dir, '..', 'src', 'cli.ts')
    const r = spawnSync(
      'bun',
      [cli, 'adapt', 'static', '--ws', ws, '--out', out],
      { encoding: 'utf8' }
    )
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('svelte-d-adapter/v1')
    expect(existsSync(join(out, 'adapter.json'))).toBe(true)
    expect(existsSync(join(out, 'svelte-engine.wasm'))).toBe(true)
  })

  test('live svelte-engine-ws adapt static when compiled', () => {
    const ws = workspaceDir()
    const man = join(ws, '.svelte-d', 'manifest.json')
    if (!existsSync(man)) return
    expect(readWsManifest(ws).schema).toBe('svelte-d-manifest/v1')
    const out = join(scratch, 'live-static')
    const r = adaptWorkspace({ ws, adapter: 'static', out })
    expect(r.schema).toBe('svelte-d-adapter/v1')
    expect(existsSync(join(out, 'adapter.json'))).toBe(true)
    expect(existsSync(join(out, 'index.html'))).toBe(true)
    expect(r.copied).not.toContain('svelte-engine-server.exe')
  })
})
