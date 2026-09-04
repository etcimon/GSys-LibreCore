// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Dest is this package's svelte-engine-ws. Debug vs release+strip-all sizes.
import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { compileWorkspace, dropWorkspace } from 'svelte-d'
import { compileCellsCompare, formatDualSizes } from '../src/cells.ts'
import { adminProject, adminWorkspace, writeWorkspaceEnv } from '../src/ws.ts'

describe('kit-admin workspace dest + artifact sizes', () => {
  test('svelte-d.config.ts puts dest at this package top-level', () => {
    const ws = adminWorkspace()
    expect(ws.replace(/\\/g, '/')).toBe(
      join(adminProject, 'svelte-engine-ws').replace(/\\/g, '/')
    )
    expect(ws.replace(/\\/g, '/')).toMatch(/svelte-d-kit-admin\/svelte-engine-ws$/)
  })

  test(
    'debug vs release+strip-all sizes for wasm and host',
    () => {
      const ws = adminWorkspace()
      if (!existsSync(join(ws, 'src-d', 'app.d'))) {
        const dropped = dropWorkspace({ dest: ws, force: true })
        expect(dropped.status === 0 || existsSync(join(ws, 'src-d', 'app.d'))).toBe(true)
      }
      writeWorkspaceEnv(ws)
      expect(compileWorkspace({ ws, project: adminProject }).status).toBe(0)
      const sizes = compileCellsCompare(ws)
      console.log(formatDualSizes(sizes))
      if (sizes.wasm.debug.bytes) expect(sizes.wasm.debug.bytes).toBeGreaterThan(1024)
      if (sizes.wasm.release.bytes) expect(sizes.wasm.release.bytes).toBeGreaterThan(1024)
      if (sizes.host.debug.bytes) expect(sizes.host.debug.bytes).toBeGreaterThan(1024)
      if (sizes.host.release.bytes) expect(sizes.host.release.bytes).toBeGreaterThan(1024)
      if (sizes.wasm.debug.bytes && sizes.wasm.release.bytes)
        expect(sizes.wasm.release.bytes).toBeLessThanOrEqual(sizes.wasm.debug.bytes)
      if (sizes.host.debug.bytes && sizes.host.release.bytes)
        expect(sizes.host.release.bytes).toBeLessThanOrEqual(sizes.host.debug.bytes)
    },
    30 * 60 * 1000
  )
})
