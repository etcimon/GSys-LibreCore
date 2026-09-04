// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  buildHost,
  compileWorkspace,
  dropWorkspace,
  workspaceDir,
} from 'svelte-d'

describe('host cell inside svelte-engine-ws/webserver', () => {
  test('compile wraps +page.server.d as registerWebInterface and hangs it on app.d', () => {
    const ws = workspaceDir()
    expect(dropWorkspace({ force: true }).status).toBe(0)
    expect(compileWorkspace(ws).status).toBe(0)

    const gen = join(ws, 'webserver', 'source', 'generated', 'routes', 'page_server.d')
    expect(existsSync(gen)).toBe(true)
    const src = readFileSync(gen, 'utf8')
    expect(src).toContain('module generated.routes.page_server')
    expect(src).toContain('class PageServer')
    expect(src).toContain('void get(')
    expect(src).toContain('res.writeBody')
    expect(src).not.toContain('import libwasm')

    const app = readFileSync(join(ws, 'webserver', 'source', 'app.d'), 'utf8')
    expect(app).toContain('import generated.routes.page_server')
    expect(app).toContain('registerWebInterface(new PageServer')
    expect(app).toContain('/__svelte-d/host/')
    expect(app).toContain('reverseProxyRequest')
    expect(app).not.toContain('mixin Spa!')
  })

  test('svelte-d host builds or skips when host LDC is absent', () => {
    const ws = workspaceDir()
    const r = buildHost(ws)
    expect([0, 3]).toContain(r.status)
    if (r.status === 3) {
      expect(r.stdout + r.stderr).toMatch(/skip|LDC 1\.43|SVELTE_D_LDC/)
      return
    }
    const exe = join(ws, 'webserver', 'svelte-engine-server.exe')
    const posix = join(ws, 'webserver', 'svelte-engine-server')
    expect(existsSync(exe) || existsSync(posix)).toBe(true)
    const man = join(ws, '.svelte-d', 'host.json')
    expect(existsSync(man)).toBe(true)
    expect(JSON.parse(readFileSync(man, 'utf8')).ok).toBe(true)
  }, 300_000)
})
