// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Project-level svelte-d.config.ts / .js / .json. Dest default is the
// consuming project's top-level ./svelte-engine-ws — never the template.
import { existsSync, readFileSync } from 'node:fs'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'

export type SvelteDConfig = {
  /** Drop dest relative to the config file (or absolute). Default: './svelte-engine-ws' */
  workspace?: string
}

export type LoadedSvelteDConfig = {
  config: SvelteDConfig
  dir: string
  path: string
}

export function defineConfig(config: SvelteDConfig): SvelteDConfig {
  return config
}

export const svelteDConfigNames = [
  'svelte-d.config.ts',
  'svelte-d.config.js',
  'svelte-d.config.mjs',
  'svelte-d.config.cjs',
  'svelte-d.config.json',
] as const

function skipWalkDir(name: string): boolean {
  const b = name.toLowerCase()
  return b === 'node_modules' || b === '.git' || b === 'svelte-engine-ws'
}

/** Walk up from `start` for svelte-d.config.ts/js/json. */
export function findSvelteDConfigPath(start = process.cwd()): string {
  let p = resolve(start)
  for (let i = 0; i < 12; i++) {
    if (!skipWalkDir(basename(p))) {
      for (const name of svelteDConfigNames) {
        const cand = join(p, name)
        if (existsSync(cand)) return cand
      }
    }
    const parent = dirname(p)
    if (parent === p) break
    p = parent
  }
  return ''
}

/** Extract `workspace` / `workspaceDir` from a config source without executing it. */
export function parseWorkspaceField(text: string): string {
  const m = text.match(/["']?workspace(?:Dir)?["']?\s*[:=]\s*["']([^"']+)["']/)
  return m?.[1] ?? ''
}

function normalizeConfig(raw: unknown): SvelteDConfig {
  if (!raw || typeof raw !== 'object') return {}
  const o = raw as Record<string, unknown>
  const workspace =
    typeof o.workspace === 'string'
      ? o.workspace
      : typeof o.workspaceDir === 'string'
        ? o.workspaceDir
        : undefined
  return workspace ? { workspace } : {}
}

/** Load svelte-d.config.* from `start` upward. Does not `import()` the file. */
export function loadSvelteDConfig(start = process.cwd()): LoadedSvelteDConfig | null {
  const path = findSvelteDConfigPath(start)
  if (!path) return null
  const dir = dirname(path)
  try {
    const text = readFileSync(path, 'utf8')
    if (path.endsWith('.json')) {
      return { config: normalizeConfig(JSON.parse(text)), dir, path }
    }
    const workspace = parseWorkspaceField(text)
    return { config: workspace ? { workspace } : {}, dir, path }
  } catch {
    return { config: {}, dir, path }
  }
}

/** Absolute workspace dest from config, or ''. */
export function resolveConfigWorkspace(start = process.cwd()): string {
  const loaded = loadSvelteDConfig(start)
  const rel = loaded?.config.workspace
  if (!rel) return ''
  if (isAbsolute(rel)) return resolve(rel)
  return resolve(loaded.dir, rel)
}
