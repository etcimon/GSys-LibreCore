// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { spawn } from 'node:child_process'
import {
  compileWorkspace,
  dropWorkspace,
  workspaceDir,
  templateDir,
  serveSurfaces,
} from 'svelte-d'
import {
  notifyWasmReload,
  prepareDev,
  viteBin,
  wasmArtifact,
} from '../src/pipeline.ts'

describe('compiled svelte-engine-ws is a serve surface', () => {
  test('drop+compile leaves index, vite, kit_router, and bootstrap wasm', () => {
    const ws = workspaceDir()
    if (!existsSync(join(ws, 'src-svelte'))) {
      expect(dropWorkspace({ force: true }).status).toBe(0)
    }
    expect(compileWorkspace(ws).status).toBe(0)
    const s = serveSurfaces(ws)
    expect(s.index).toBe(true)
    expect(s.vite).toBe(true)
    expect(s.mainTs).toBe(true)
    expect(s.kitRouter).toBe(true)
    expect(s.bindingsD).toBe(true)
    expect(s.typesD).toBe(true)
    expect(s.slugPage).toBe(true)
    expect(s.wasm).toBe(true)
    expect(s.pageServer).toBe(true)
    const html = readFileSync(join(ws, 'index.html'), 'utf8')
    expect(html).toContain('id="root"')
    expect(html).toContain('src-ts/main.ts')
    expect(
      existsSync(join(templateDir(), 'public', 'svelte-engine.wasm')) ||
        existsSync(join(workspaceDir(), 'public', 'svelte-engine.wasm'))
    ).toBe(true)
  })

  test('prepareDev compiles IR and builds missing cells', () => {
    const r = prepareDev({
      wasm: 'if-missing',
      host: 'if-missing',
    })
    expect(r.compile.status).toBe(0)
    expect(r.deps.status).toBe(0)
    const s = serveSurfaces(r.ws)
    expect(s.index && s.vite && s.kitRouter).toBe(true)
    expect(s.wasm).toBe(true)
  }, 180_000)

  test('vite GET / and wasm are 200; HMR ws sends reload', async () => {
    const ws = workspaceDir()
    const s = serveSurfaces(ws)
    expect(s.vite && s.index).toBe(true)
    const port = 5179
    const bin = viteBin(ws)
    const child = spawn(
      bin,
      ['--host', '127.0.0.1', '--port', String(port), '--strictPort'],
      {
        cwd: ws,
        stdio: ['ignore', 'pipe', 'pipe'],
        shell: bin === 'vite' && process.platform === 'win32',
      }
    )
    let started = false
    let viteErr = ''
    child.stderr?.on('data', (b) => {
      viteErr += String(b)
    })
    child.stdout?.on('data', (b) => {
      viteErr += String(b)
    })
    const deadline = Date.now() + 40000
    try {
      while (Date.now() < deadline) {
        try {
          const res = await fetch(`http://127.0.0.1:${port}/`)
          if (res.ok) {
            started = true
            const body = await res.text()
            expect(body).toContain('id="root"')
            const w = await fetch(
              `http://127.0.0.1:${port}/svelte-engine.wasm`
            )
            expect(w.ok).toBe(true)
            break
          }
        } catch {
          await Bun.sleep(250)
        }
      }
      if (!started) throw new Error('vite did not start: ' + viteErr.slice(-2000))
      expect(started).toBe(true)

      const art = wasmArtifact(ws)
      expect(art).toBeTruthy()
      const msg = await new Promise<string>((resolve, reject) => {
        const sock = new WebSocket('ws://127.0.0.1:3001')
        const t = setTimeout(() => {
          sock.close()
          reject(new Error('no HMR reload within 8s'))
        }, 8000)
        sock.addEventListener('open', () => {
          writeFileSync(art!, readFileSync(art!))
          notifyWasmReload(ws)
        })
        sock.addEventListener('message', (ev) => {
          clearTimeout(t)
          const data = String(ev.data)
          sock.close()
          resolve(data)
        })
        sock.addEventListener('error', () => {
          clearTimeout(t)
          reject(new Error('HMR websocket failed'))
        })
      })
      expect(msg === 'reload' || msg === 'full-reload').toBe(true)
    } finally {
      child.kill()
    }
  }, 60_000)
})
