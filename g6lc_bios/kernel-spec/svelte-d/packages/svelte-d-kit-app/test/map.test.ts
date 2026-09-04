// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  kitToPattern,
  mapKitPath,
  parseSvelte,
  templateDir,
} from 'svelte-d'

describe('kit-app map: nested board tree falls through (import svelte-d)', () => {
  test('engine board tree exists', () => {
    const tpl = templateDir()
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'board', '+layout.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'board', '+page.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'board', '+error.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'board', '+server.d'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'board', '+page.server.d'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'board', '[id]', '+page.svelte'))).toBe(true)
  })

  test('mapKitPath / kitToPattern for layout, page, param, error, hosts', () => {
    expect(kitToPattern('src/routes/+page.svelte')).toBe('/')
    expect(kitToPattern('src/routes/board/+page.svelte')).toBe('/board')
    expect(kitToPattern('src/routes/board/+layout.svelte')).toBe('/board')
    expect(kitToPattern('src/routes/board/[id]/+page.svelte')).toBe('/board/:id')
    expect(kitToPattern('src/routes/[slug]/+page.svelte')).toBe('/:slug')
    expect(kitToPattern('src/routes/board/+error.svelte')).toBe('')
    expect(kitToPattern('src/routes/board/+server.d')).toBe('')

    const page = mapKitPath('src/routes/board/[id]/+page.svelte')
    expect(page.kind).toBe('page')
    expect(page.srcSvelte).toBe('src-svelte/routes/board/[id]/+page.svelte')
    expect(page.srcD).toBe('src-d/routes/board/_id_/page.d')
    expect(page.runtime).toContain('libwasm')

    const err = mapKitPath('src/routes/board/+error.svelte')
    expect(err.kind).toBe('error')
    expect(err.srcD).toBe('src-d/routes/board/error.d')
    expect(err.host).toBe('')

    const ep = mapKitPath('src/routes/board/+server.d')
    expect(ep.kind).toBe('endpoint')
    expect(ep.cell).toBe('host')
    expect(ep.runtime).toContain('vibe.0')
    expect(ep.host).toBe('webserver/source/generated/routes/board/server.d')
    expect(ep.srcD).toBe('')
  })

  test('parseSvelte sees dual-script on error and [id] page', () => {
    const tpl = templateDir()
    const err = parseSvelte(join(tpl, 'src-svelte', 'routes', 'board', '+error.svelte'))
    expect(err.status).toBe(0)
    expect(err.stdout).toMatch(/lang=d/)
    expect(err.stdout).toMatch(/lang=ts/)

    const item = parseSvelte(join(tpl, 'src-svelte', 'routes', 'board', '[id]', '+page.svelte'))
    expect(item.status).toBe(0)
    expect(item.stdout).toMatch(/lang=d/)
    expect(item.stdout).toMatch(/Panel|lang=ts/)
  })
})
