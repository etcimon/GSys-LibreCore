// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { kitToPattern, mapKitPath, parseSvelte, templateDir } from 'svelte-d'

describe('kit-env map: account page + host load (import svelte-d)', () => {
  test('engine .env and account fixtures exist', () => {
    const tpl = templateDir()
    expect(existsSync(join(tpl, '.env'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'account', '+page.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'account', '+page.server.d'))).toBe(true)
  })

  test('mapKitPath / kitToPattern send account to wasm + host', () => {
    expect(kitToPattern('src/routes/account/+page.svelte')).toBe('/account')
    const page = mapKitPath('src/routes/account/+page.svelte')
    expect(page.kind).toBe('page')
    expect(page.srcD).toBe('src-d/routes/account/page.d')
    expect(page.runtime).toContain('libwasm')
    const host = mapKitPath('src/routes/account/+page.server.d')
    expect(host.kind).toBe('page_server')
    expect(host.cell).toBe('host')
    expect(host.host).toBe('webserver/source/generated/routes/account/page_server.d')
  })

  test('parseSvelte sees dual-script on account page', () => {
    const pg = parseSvelte(
      join(templateDir(), 'src-svelte', 'routes', 'account', '+page.svelte')
    )
    expect(pg.status).toBe(0)
    expect(pg.stdout).toMatch(/lang=d/)
    expect(pg.stdout).toMatch(/Panel|lang=ts/)
  })
})
