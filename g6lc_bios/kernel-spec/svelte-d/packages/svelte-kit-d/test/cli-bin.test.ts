// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { nativeExe, pkgRoot, runCli } from 'svelte-d'

describe('repo-root bun package produces the CLI', () => {
  test('native exe exists after bun install / bun run build', () => {
    expect(existsSync(nativeExe())).toBe(true)
    expect(nativeExe().replace(/\\/g, '/')).toMatch(/packages\/svelte-d\/bin\/svelte-d/)
    expect(existsSync(join(pkgRoot, 'ts', 'index.ts'))).toBe(true)
  })

  test('CLI version via bun-forwarded native exe', () => {
    const r = runCli(['version'])
    expect(r.status).toBe(0)
    expect(r.stdout.trim().split(/\r?\n/)[0]).toBe('1')
  })
})
