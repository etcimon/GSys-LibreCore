// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Architectural contract: lang=ts splice, third-party Svelte packages,
// and Node/Bun helpers (scss, jquery) fall through into svelte-engine-ws.
// Does not start a second DOM/HTTP stack.
import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWorkspace,
  dropWorkspace,
  identFromRel,
  mapKitPath,
  runCli,
  workspaceDir,
} from 'svelte-d'

const CASES: {
  from: string
  kind: string
  runtime: string
  srcTs?: string
  srcD?: string
  srcSvelte?: string
}[] = [
  {
    from: 'src/lib/jquery-bridge.ts',
    kind: 'ts_helper',
    runtime: 'src-ts',
    srcTs: 'src-ts/modules/helpers/lib/jquery-bridge.ts',
  },
  {
    from: 'src/styles/app.scss',
    kind: 'style',
    runtime: 'vite-css',
    srcTs: 'styles/app.scss',
  },
  {
    from: 'styles/theme.scss',
    kind: 'style',
    runtime: 'vite-css',
    srcTs: 'styles/theme.scss',
  },
  {
    from: 'node_modules/svelte-grid/Grid.svelte',
    kind: 'ext_component',
    runtime: 'libwasm+jsExports',
    srcSvelte: 'src-svelte/ext/svelte-grid/Grid.svelte',
    srcD: 'src-d/ext/svelte-grid/Grid.d',
  },
  {
    from: 'node_modules/@scope/graph/src/Chart.svelte',
    kind: 'ext_component',
    runtime: 'libwasm+jsExports',
    srcSvelte: 'src-svelte/ext/@scope/graph/src/Chart.svelte',
    srcD: 'src-d/ext/@scope/graph/src/Chart.d',
  },
  {
    from: 'src/lib/Dock.svelte',
    kind: 'component',
    runtime: 'libwasm+jsExports',
    srcTs: 'src-ts/modules/generated/lib_Dock_svelte.ts',
    srcD: 'src-d/lib/Dock.d',
  },
  {
    from: 'public/logo.png',
    kind: 'static',
    runtime: 'vibe.0-static',
    srcSvelte: 'public/logo.png',
  },
]

describe('extension + helper fall-through (map)', () => {
  test('table: ts helper, scss, npm svelte package, lang=ts dest', () => {
    for (const c of CASES) {
      const m = mapKitPath(c.from)
      expect(m.kind).toBe(c.kind)
      expect(m.runtime).toBe(c.runtime)
      if (c.srcTs) expect(m.srcTs).toBe(c.srcTs)
      if (c.srcD) expect(m.srcD).toBe(c.srcD)
      if (c.srcSvelte) expect(m.srcSvelte).toBe(c.srcSvelte)
    }
  })

  test('D CLI map agrees with TS mapKitPath on extension rows', () => {
    for (const c of CASES) {
      const r = runCli(['map', c.from])
      expect(r.status).toBe(0)
      const j = JSON.parse(r.stdout.trim().split('\n')[0])
      const ts = mapKitPath(c.from)
      expect(j.kind).toBe(ts.kind)
      expect(j.runtime).toBe(ts.runtime)
      expect(j.srcTs).toBe(ts.srcTs)
      expect(j.srcD).toBe(ts.srcD)
      expect(j.srcSvelte).toBe(ts.srcSvelte)
    }
  })
})

describe('ingest imported svelte + local ts/scss', () => {
  test('compile --project copies helpers, scss, and node_modules .svelte', () => {
    const project = join(import.meta.dir, 'fixtures', 'ext-app')
    expect(existsSync(join(project, 'node_modules', 'fake-grid', 'Grid.svelte'))).toBe(true)
    const ws = workspaceDir()
    expect(dropWorkspace({ dest: ws, force: existsSync(ws) }).status).toBe(0)
    expect(compileWorkspace({ ws, project }).status).toBe(0)
    expect(existsSync(join(ws, 'src-ts', 'modules', 'helpers', 'lib', 'bridge.ts'))).toBe(true)
    expect(readFileSync(join(ws, 'src-ts', 'modules', 'helpers', 'lib', 'bridge.ts'), 'utf8')).toContain(
      'export function ready'
    )
    expect(existsSync(join(ws, 'styles', 'app.scss'))).toBe(true)
    expect(existsSync(join(ws, 'src-svelte', 'ext', 'fake-grid', 'Grid.svelte'))).toBe(true)
    const printed = join(ws, 'src-d', 'ext', 'fake-grid', 'Grid.d')
    expect(existsSync(printed)).toBe(true)
    const d = readFileSync(printed, 'utf8')
    expect(d).toContain('module ext.fake_grid.Grid')
    expect(d).toContain('struct Grid')
    expect(d).toContain('int n')
    expect(existsSync(join(ws, 'public', 'hello.txt'))).toBe(true)
    expect(readFileSync(join(ws, 'public', 'hello.txt'), 'utf8')).toContain('svelte-d-static')
    const pin = join(ws, '.svelte-d', 'wasm-ldc.json')
    expect(existsSync(pin)).toBe(true)
    const j = JSON.parse(readFileSync(pin, 'utf8'))
    expect(j.schema).toBe('svelte-d-wasm-ldc/v1')
    expect(j.cell).toBe('wasm-eh')
    const wsPkg = JSON.parse(readFileSync(join(ws, 'package.json'), 'utf8')) as {
      dependencies?: Record<string, string>
    }
    const fg = wsPkg.dependencies?.['fake-grid'] ?? ''
    expect(fg.length).toBeGreaterThan(0)
    expect(fg === '0.0.0' || fg.startsWith('file:')).toBe(true)
    expect(existsSync(join(ws, 'node_modules', 'fake-grid', 'package.json'))).toBe(true)
    expect(JSON.parse(readFileSync(join(ws, 'node_modules', 'fake-grid', 'package.json'), 'utf8')).name).toBe(
      'fake-grid'
    )
    const pageTs = join(ws, 'src-ts', 'modules', 'generated', identFromRel('routes/+page.svelte') + '.ts')
    expect(existsSync(pageTs)).toBe(true)
    const pageBody = readFileSync(pageTs, 'utf8')
    expect(pageBody).toContain("from 'fake-grid'")
    expect(pageBody).toMatch(/from ['\"]\.\.\/\.\.\/helpers\/lib\/bridge['\"]/)
  })
})

describe('lang=ts is spliced into src-ts/modules', () => {
  test('compile writes generated module and folds it into index.ts', () => {
    const ws = workspaceDir()
    if (!existsSync(join(ws, 'src-d', 'app.d'))) {
      expect(dropWorkspace({ dest: ws, force: existsSync(ws) }).status).toBe(0)
    }
    expect(compileWorkspace(ws).status).toBe(0)
    const pageRel = 'routes/+page.svelte'
    const ident = identFromRel(pageRel)
    const gen = join(ws, 'src-ts', 'modules', 'generated')
    const idx = readFileSync(join(ws, 'src-ts', 'modules', 'index.ts'), 'utf8')
    expect(idx).toContain("from './bindings.ts'")
    expect(idx).toContain("from './libwasm.ts'")
    expect(idx).toContain('generated/')
    expect(idx).toMatch(/routes__page_svelte/)
    const mod = join(gen, ident + '_mod.ts')
    const inst = join(gen, ident + '.ts')
    const hit = existsSync(mod) ? mod : inst
    expect(existsSync(hit)).toBe(true)
    const body = readFileSync(hit, 'utf8')
    expect(body).toContain('jsExports')
    expect(body).toMatch(/pageReady|export const jsExports/)
  })
})
