// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  kitToPattern,
  kitToPatterns,
  mapKitPath,
  parseSvelte,
  templateDir,
} from 'svelte-d'

describe('kit-fs map: groups, optional, layout.server (import svelte-d)', () => {
  test('engine (app) tree exists', () => {
    const tpl = templateDir()
    const app = join(tpl, 'src-svelte', 'routes', '(app)')
    expect(existsSync(join(app, '+layout.svelte'))).toBe(true)
    expect(existsSync(join(app, '+layout.server.d'))).toBe(true)
    expect(existsSync(join(app, 'shop', '+page.svelte'))).toBe(true)
    expect(existsSync(join(app, 'shop', '+page.server.d'))).toBe(true)
    expect(existsSync(join(app, 'docs', '[[lang]]', '+page.svelte'))).toBe(true)
  })

  test('(groups) strip; [[optional]] full pattern is :name; expand omit+include', () => {
    expect(kitToPattern('src/routes/(app)/shop/+page.svelte')).toBe('/shop')
    expect(kitToPattern('src/routes/(app)/+layout.svelte')).toBe('/')
    expect(kitToPattern('src/routes/(app)/docs/[[lang]]/+page.svelte')).toBe('/docs/:lang')
    expect(kitToPatterns('src/routes/(app)/docs/[[lang]]/+page.svelte')).toEqual([
      '/docs',
      '/docs/:lang',
    ])
    expect(kitToPatterns('src/routes/(app)/shop/+page.svelte')).toEqual(['/shop'])
    expect(kitToPattern('src/routes/(app)/blog/[id]/+page.svelte')).toBe('/blog/:id')
    expect(kitToPattern('src/routes/board/+error.svelte')).toBe('')
  })

  test('mapKitPath sends group files to wasm dests and layout.server to host', () => {
    const shop = mapKitPath('src/routes/(app)/shop/+page.svelte')
    expect(shop.kind).toBe('page')
    expect(shop.srcD).toBe('src-d/routes/(app)/shop/page.d')
    expect(shop.runtime).toContain('libwasm')

    const lay = mapKitPath('src/routes/(app)/+layout.svelte')
    expect(lay.kind).toBe('layout')
    expect(lay.srcD).toBe('src-d/routes/(app)/layout.d')

    const ls = mapKitPath('src/routes/(app)/+layout.server.d')
    expect(ls.kind).toBe('layout_server')
    expect(ls.cell).toBe('host')
    expect(ls.runtime).toContain('vibe.0')
    expect(ls.host).toBe('webserver/source/generated/routes/(app)/layout_server.d')
    expect(ls.srcD).toBe('')

    const docs = mapKitPath('src/routes/(app)/docs/[[lang]]/+page.svelte')
    expect(docs.kind).toBe('page')
    expect(docs.srcD).toBe('src-d/routes/(app)/docs/_lang_/page.d')

    const shopHost = mapKitPath('src/routes/(app)/shop/+page.server.d')
    expect(shopHost.host).toBe('webserver/source/generated/routes/(app)/shop/page_server.d')
  })

  test('parseSvelte sees dual-script on group layout, shop, docs', () => {
    const tpl = templateDir()
    const app = join(tpl, 'src-svelte', 'routes', '(app)')
    const lay = parseSvelte(join(app, '+layout.svelte'))
    expect(lay.status).toBe(0)
    expect(lay.stdout).toMatch(/lang=d/)
    expect(lay.stdout).toMatch(/lang=ts/)

    const shop = parseSvelte(join(app, 'shop', '+page.svelte'))
    expect(shop.status).toBe(0)
    expect(shop.stdout).toMatch(/ClickField|lang=ts/)

    const docs = parseSvelte(join(app, 'docs', '[[lang]]', '+page.svelte'))
    expect(docs.status).toBe(0)
    expect(docs.stdout).toMatch(/Panel|lang=ts/)
  })
})
