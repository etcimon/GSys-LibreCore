import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { compileWs, dropWs, parseGolden, readManifest, runSvelteD } from '../src/pipeline.ts'
import { findRiscvDev, nativeExe, templateDir, mapKitPath } from 'svelte-d'

describe('svelte-kit-d pipeline', () => {
  test('riscv-dev + svelte-engine template exist', () => {
    const root = findRiscvDev()
    expect(existsSync(join(templateDir(root), 'src-d', 'pglite.d'))).toBe(true)
    expect(existsSync(join(templateDir(root), 'src-svelte', 'routes', '+page.svelte'))).toBe(true)
  })

  test('svelte-d binary is built', () => {
    expect(existsSync(nativeExe())).toBe(true)
  })

  test('parse dual-script +page.svelte (lang=d + lang=ts)', () => {
    const r = parseGolden()
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('Pegged OK')
    expect(r.stdout).toContain('ParseTree=SvelteKit.Document')
    expect(r.stdout).toMatch(/lang=d/)
    expect(r.stdout).toMatch(/lang=ts/)
  })

  test('drop-ws + compile writes libwasm IR + attaches lang=ts jsExports', () => {
    const d = dropWs(true)
    expect(d.status).toBe(0)
    expect(d.stdout).toContain('dropped')
    const c = compileWs()
    expect(c.status).toBe(0)
    const man = readManifest()
    expect(man).toBeTruthy()
    expect(man.schema).toBe('svelte-d-manifest/v1')
    expect(man.srcD).toBe('libwasm-ir')
    expect(man.pglite).toBe('passthrough')
    expect(man.fail).toBe(0)
    expect(man.tsModules).toBeGreaterThan(0)
    expect(man.fallthrough).toBe('kit-equivalent-ws')
    expect(man.bootstrap).toBe('svelte-engine')
    expect(man.accommodate).toBe('engine-libwasm-vibe0')
    expect(man.lodash).toBeGreaterThan(0)
    expect(existsSync(join(findRiscvDev(), 'svelte-engine-ws', 'src-d', 'lib', 'LodashDemo.d'))).toBe(true)
    const root = findRiscvDev()
    expect(existsSync(join(root, 'svelte-engine-ws', '.svelte-d', 'bootstrap.json'))).toBe(true)
    const ft = JSON.parse(
      readFileSync(join(root, 'svelte-engine-ws', '.svelte-d', 'fallthrough.json'), 'utf8')
    )
    expect(ft.schema).toBe('svelte-d-fallthrough/v1')
    const pageMap = mapKitPath('routes/+page.svelte')
    const pageEntry = ft.entries.find((e: { kitRel: string }) => e.kitRel === 'routes/+page.svelte')
    expect(pageEntry.srcSvelte).toBe(pageMap.srcSvelte)
    expect(pageEntry.srcD).toBe(pageMap.srcD)
    const gen = join(root, 'svelte-engine-ws', 'src-ts', 'modules', 'generated')
    expect(existsSync(gen)).toBe(true)
    const idx = readFileSync(
      join(root, 'svelte-engine-ws', 'src-ts', 'modules', 'index.ts'),
      'utf8'
    )
    expect(idx).toContain('generated/')
    expect(idx).toContain('routes__page_svelte')
    const pageTs = readFileSync(
      join(gen, 'routes__page_svelte_mod.ts'),
      'utf8'
    )
    expect(pageTs).toContain('jsExports')
    expect(pageTs).toContain('pageReady')
  })

  test('markup parse names Pegged vs scan fallback', () => {
    const root = findRiscvDev()
    const dock = join(templateDir(root), 'src-svelte', 'lib', 'Dock.svelte')
    const combo = join(templateDir(root), 'src-svelte', 'lib', 'Combo.svelte')
    const d = runSvelteD(['parse', dock])
    expect(d.status).toBe(0)
    expect(d.stdout).toMatch(/markup-parse=pegged/)
    const c = runSvelteD(['parse', combo])
    expect(c.status).toBe(0)
    expect(c.stdout).toMatch(/markup-parse=scan-/)
  })

  test('scan sees kit files', () => {
    const r = runSvelteD(['scan', '--ws', join(findRiscvDev(), 'svelte-engine')])
    expect(r.status).toBe(0)
    expect(r.stdout).toContain('page')
    expect(r.stdout).toContain('+page.svelte')
  })
})
