// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { kitToPattern, mapKitPath, parseSvelte } from 'svelte-d'

const project = dirname(dirname(fileURLToPath(import.meta.url)))

describe('kit-admin map: admin tree + host dests (import svelte-d)', () => {
  test('project admin fixtures exist (not in the engine bootstrap)', () => {
    const admin = join(project, 'src', 'routes', 'admin')
    expect(existsSync(join(admin, '+layout.svelte'))).toBe(true)
    expect(existsSync(join(admin, '+page.svelte'))).toBe(true)
    expect(existsSync(join(admin, '+page.server.d'))).toBe(true)
    expect(existsSync(join(admin, 'users', '+page.svelte'))).toBe(true)
    expect(existsSync(join(admin, 'users', '+page.server.d'))).toBe(true)
    expect(existsSync(join(admin, 'users', '[id]', '+page.svelte'))).toBe(true)
    expect(existsSync(join(admin, 'users', '[id]', '+page.server.d'))).toBe(true)
    expect(existsSync(join(admin, 'logs', '+page.svelte'))).toBe(true)
    expect(existsSync(join(admin, 'logs', '+page.server.d'))).toBe(true)
    expect(existsSync(join(admin, 'features', '+page.svelte'))).toBe(true)
    expect(existsSync(join(admin, 'features', '+page.server.d'))).toBe(true)
    expect(existsSync(join(admin, '+error.svelte'))).toBe(true)
  })

  test('mapKitPath / kitToPattern for /admin /admin/users /admin/logs', () => {
    expect(kitToPattern('src/routes/admin/+page.svelte')).toBe('/admin')
    expect(kitToPattern('src/routes/admin/users/+page.svelte')).toBe('/admin/users')
    expect(kitToPattern('src/routes/admin/users/[id]/+page.svelte')).toBe('/admin/users/:id')
    expect(kitToPattern('src/routes/admin/logs/+page.svelte')).toBe('/admin/logs')
    expect(kitToPattern('src/routes/admin/features/+page.svelte')).toBe('/admin/features')
    expect(kitToPattern('src/routes/admin/+error.svelte')).toBe('')
    expect(mapKitPath('src/routes/admin/+page.svelte').srcD).toBe(
      'src-d/routes/admin/page.d'
    )
    const host = mapKitPath('src/routes/admin/+page.server.d')
    expect(host.cell).toBe('host')
    expect(host.host).toBe('webserver/source/generated/routes/admin/page_server.d')
    expect(mapKitPath('src/routes/admin/users/+page.server.d').host).toBe(
      'webserver/source/generated/routes/admin/users/page_server.d'
    )
  })

  test('parseSvelte sees dual-script on admin pages', () => {
    const dash = parseSvelte(join(project, 'src', 'routes', 'admin', '+page.svelte'))
    expect(dash.status).toBe(0)
    expect(dash.stdout).toMatch(/lang=d/)
    const users = parseSvelte(
      join(project, 'src', 'routes', 'admin', 'users', '+page.svelte')
    )
    expect(users.status).toBe(0)
    expect(users.stdout).toMatch(/lang=d/)
  })
})
