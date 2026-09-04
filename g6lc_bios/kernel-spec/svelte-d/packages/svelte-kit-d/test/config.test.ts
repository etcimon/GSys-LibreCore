// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import {
  findKitProjectRoot,
  bundledTemplateDir,
  dropWorkspace,
  findSvelteDConfigPath,
  loadSvelteDConfig,
  parseWorkspaceField,
  resolveConfigWorkspace,
  workspaceDir,
} from 'svelte-d'

describe('svelte-d.config.ts/js', () => {
  test('parseWorkspaceField reads ts / js / json shapes', () => {
    expect(parseWorkspaceField(`export default { workspace: './svelte-engine-ws' }`)).toBe(
      './svelte-engine-ws'
    )
    expect(parseWorkspaceField(`export default defineConfig({ workspace: "./out" })`)).toBe(
      './out'
    )
    expect(parseWorkspaceField(`{ "workspaceDir": "build/ws" }`)).toBe('build/ws')
  })

  test('repo-root svelte-d.config.ts defaults dest to ./svelte-engine-ws', () => {
    const loaded = loadSvelteDConfig(process.cwd())
    expect(loaded).not.toBeNull()
    expect(loaded!.path.replace(/\\/g, '/')).toMatch(/svelte-d\.config\.ts$/)
    expect(loaded!.config.workspace).toBe('./svelte-engine-ws')
    const dest = resolveConfigWorkspace(process.cwd())
    expect(dest.replace(/\\/g, '/')).toMatch(/\/svelte-engine-ws$/)
    expect(workspaceDir().replace(/\\/g, '/')).toBe(dest.replace(/\\/g, '/'))
  })

  test('a consumer svelte-d.config.ts sets dest at that project root', () => {
    const dir = mkdtempSync(join(tmpdir(), 'svelte-d-cfg-'))
    writeFileSync(
      join(dir, 'svelte-d.config.ts'),
      `export default { workspace: './svelte-engine-ws' }\n`
    )
    mkdirSync(join(dir, 'src', 'routes'), { recursive: true })
    writeFileSync(join(dir, 'src', 'routes', '+page.svelte'), '<p>ok</p>\n')
    expect(findSvelteDConfigPath(dir).replace(/\\/g, '/')).toMatch(/svelte-d\.config\.ts$/)
    expect(resolveConfigWorkspace(dir)).toBe(resolve(dir, 'svelte-engine-ws'))
    expect(findKitProjectRoot(dir)).toBe(resolve(dir))
  })

  test('drop-ws overlays and never removes dest extras', () => {
    const dir = mkdtempSync(join(tmpdir(), 'svelte-d-overlay-'))
    const dest = join(dir, 'svelte-engine-ws')
    expect(bundledTemplateDir().length).toBeGreaterThan(0)
    expect(dropWorkspace({ dest }).status).toBe(0)
    expect(existsSync(join(dest, 'src-d', 'app.d'))).toBe(true)
    const extra = join(dest, 'src-d', 'user-keep.d')
    writeFileSync(extra, '// user customisation\n')
    expect(dropWorkspace({ dest, force: true }).status).toBe(0)
    expect(existsSync(extra)).toBe(true)
    expect(existsSync(dest)).toBe(true)
    expect(existsSync(join(dest, 'src-d', 'app.d'))).toBe(true)
  })

  test('kit project without config still defaults to <project>/svelte-engine-ws', () => {
    const dir = mkdtempSync(join(tmpdir(), 'svelte-d-kit-'))
    mkdirSync(join(dir, 'src', 'routes'), { recursive: true })
    writeFileSync(join(dir, 'src', 'routes', '+page.svelte'), '<p>ok</p>\n')
    expect(findSvelteDConfigPath(dir)).toBe('')
    expect(findKitProjectRoot(dir)).toBe(resolve(dir))
  })
})
