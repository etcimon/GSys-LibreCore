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

describe('kit-host map: rest, hooks, inbox actions (import svelte-d)', () => {
  test('engine rest / hooks / inbox fixtures exist', () => {
    const tpl = templateDir()
    expect(existsSync(join(tpl, 'src-svelte', 'hooks.server.d'))).toBe(true)
    expect(
      existsSync(join(tpl, 'src-svelte', 'routes', 'files', '[...path]', '+page.svelte'))
    ).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'inbox', '+page.svelte'))).toBe(true)
    expect(existsSync(join(tpl, 'src-svelte', 'routes', 'inbox', '+page.server.d'))).toBe(true)
  })

  test('[...path] → /files/* ; hooks and inbox map to host dests', () => {
    expect(kitToPattern('src/routes/files/[...path]/+page.svelte')).toBe('/files/*')
    expect(kitToPatterns('src/routes/files/[...path]/+page.svelte')).toEqual(['/files/*'])
    expect(kitToPattern('src/routes/inbox/+page.svelte')).toBe('/inbox')
    expect(kitToPattern('src/hooks.server.d')).toBe('')

    const rest = mapKitPath('src/routes/files/[...path]/+page.svelte')
    expect(rest.kind).toBe('page')
    expect(rest.srcD).toBe('src-d/routes/files/_path_/page.d')
    expect(rest.runtime).toContain('libwasm')

    const hooks = mapKitPath('src/hooks.server.d')
    expect(hooks.kind).toBe('hooks')
    expect(hooks.cell).toBe('host')
    expect(hooks.runtime).toContain('vibe.0')
    expect(hooks.host).toBe('webserver/source/generated/hooks.d')
    expect(hooks.srcD).toBe('')

    const inbox = mapKitPath('src/routes/inbox/+page.server.d')
    expect(inbox.kind).toBe('page_server')
    expect(inbox.host).toBe('webserver/source/generated/routes/inbox/page_server.d')
  })

  test('parseSvelte sees dual-script on files and inbox pages', () => {
    const tpl = templateDir()
    const files = parseSvelte(
      join(tpl, 'src-svelte', 'routes', 'files', '[...path]', '+page.svelte')
    )
    expect(files.status).toBe(0)
    expect(files.stdout).toMatch(/lang=d/)
    expect(files.stdout).toMatch(/Panel|lang=ts/)

    const inbox = parseSvelte(join(tpl, 'src-svelte', 'routes', 'inbox', '+page.svelte'))
    expect(inbox.status).toBe(0)
    expect(inbox.stdout).toMatch(/ClickField|lang=ts/)
  })
})
