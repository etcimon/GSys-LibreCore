// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { existsSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveConfigWorkspace } from './config.ts'

const here = dirname(fileURLToPath(import.meta.url))
const pkgRoot = resolve(here, '..')

function isEngineRoot(p: string): boolean {
  return existsSync(join(p, 'src-d', 'app.d')) && existsSync(join(p, 'dub.sdl'))
}

/** svelte-d package root: ships svelte-engine for drop/compile in node_modules. */
export function isSvelteDPackage(p: string): boolean {
  if (
    existsSync(join(p, 'ts', 'index.ts')) &&
    (isEngineRoot(join(p, 'svelte-engine')) ||
      isEngineRoot(join(p, 'templates', 'engine')))
  )
    return true
  // Repo root / github:etcimon/svelte-d install (exports point here).
  return (
    existsSync(join(p, 'packages', 'svelte-d', 'ts', 'index.ts')) &&
    (isEngineRoot(join(p, 'svelte-engine')) ||
      isEngineRoot(join(p, 'packages', 'svelte-d', 'svelte-engine')) ||
      isEngineRoot(join(p, 'packages', 'svelte-d', 'templates', 'engine')))
  )
}

function walkHasEngine(start: string): string {
  let p = resolve(start)
  for (let i = 0; i < 10; i++) {
    if (
      existsSync(join(p, 'svelte-engine', 'AGENTS.md')) ||
      isEngineRoot(join(p, 'svelte-engine')) ||
      isSvelteDPackage(p)
    )
      return p
    const parent = dirname(p)
    if (parent === p) break
    p = parent
  }
  return ''
}

/** Packaged svelte-engine inside this svelte-d package (node_modules/svelte-d). */
export function bundledTemplateDir(): string {
  const packaged = resolve(pkgRoot, 'svelte-engine')
  if (isEngineRoot(packaged)) return packaged
  const legacy = resolve(pkgRoot, 'templates', 'engine')
  if (isEngineRoot(legacy)) return legacy
  return ''
}

/** Directory that contains the drop-source engine (checkout, or this package). */
export function findRiscvDev(start = process.cwd()): string {
  const fromCwd = walkHasEngine(start)
  if (fromCwd) return fromCwd
  const fromPkg = walkHasEngine(pkgRoot)
  if (fromPkg) return fromPkg
  if (bundledTemplateDir()) return pkgRoot
  throw new Error(
    'cannot find svelte-engine (no svelte-engine/ above cwd or in the svelte-d package)'
  )
}

/** Walk up for a bun + SvelteKit project. Skips engine / svelte-d package trees. */
export function findKitProjectRoot(start = process.cwd()): string {
  let p = resolve(start)
  for (let i = 0; i < 12; i++) {
    const b = basename(p).toLowerCase()
    if (b !== 'node_modules' && b !== 'svelte-engine' && b !== 'svelte-engine-ws') {
      const kit =
        existsSync(join(p, 'src', 'routes')) || existsSync(join(p, 'src-svelte'))
      if (kit && !isEngineRoot(p) && !isSvelteDPackage(p)) return p
    }
    const parent = dirname(p)
    if (parent === p) break
    p = parent
  }
  return ''
}

/**
 * Drop dest. Precedence: svelte-d.config.ts/js `workspace`, then
 * `<kit-project>/svelte-engine-ws`, then an existing checkout sibling,
 * then `<cwd>/svelte-engine-ws` for an installed package (project top-level,
 * not node_modules/svelte-d).
 */
export function workspaceDir(root = findRiscvDev()) {
  const fromCfg = resolveConfigWorkspace()
  if (fromCfg) return fromCfg
  const kit = findKitProjectRoot()
  if (kit) return join(kit, 'svelte-engine-ws')
  const here = join(root, 'svelte-engine-ws')
  if (existsSync(here)) return here
  if (isSvelteDPackage(root)) {
    const cwd = process.cwd()
    if (!isSvelteDPackage(cwd) && !isEngineRoot(cwd))
      return join(cwd, 'svelte-engine-ws')
    return here
  }
  const beside = join(dirname(root), 'svelte-engine-ws')
  if (existsSync(beside)) return beside
  return here
}

/** Drop source: live svelte-engine checkout, else the copy packaged with svelte-d. */
export function templateDir(_root = findRiscvDev()) {
  const sub = join(_root, 'svelte-engine')
  if (isEngineRoot(sub)) return sub
  const bundled = bundledTemplateDir()
  if (bundled) return bundled
  return sub
}

/** Bun + SvelteKit project to ingest on compile (`src/routes` or `src-svelte`). */
export function kitProjectDir(start = process.cwd()): string {
  if (existsSync(join(start, 'src', 'routes'))) return start
  if (existsSync(join(start, 'src-svelte'))) return start
  return ''
}

function isLibwasmRoot(p: string): boolean {
  return existsSync(join(p, 'source', 'libwasm', 'dom.d'))
}

function isLibwasmDubCache(p: string): boolean {
  const n = p.replace(/\\/g, '/')
  return n.includes('/.dub/packages/') || n.includes('/dub/packages/')
}

/** Source checkout only (for `dub add-local ~master`). */
export function findLibwasmCheckout(start = findRiscvDev()): string {
  const env = process.env.LIBWASM_ROOT
  if (env && isLibwasmRoot(env) && !isLibwasmDubCache(env)) return env
  const seeds = [start, dirname(start), process.cwd(), pkgRoot]
  for (const seed of seeds) {
    let p = resolve(seed)
    for (let i = 0; i < 10; i++) {
      for (const cand of [join(p, 'libwasm'), join(p, 'riscv-compilers', 'libwasm')]) {
        if (isLibwasmRoot(cand) && !isLibwasmDubCache(cand)) return cand
      }
      const parent = dirname(p)
      if (parent === p) break
      p = parent
    }
  }
  return ''
}

function findLibwasmInDubCache(): string {
  const homes = [
    process.env.DUB_HOME,
    process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, 'dub') : '',
    process.env.USERPROFILE ? join(process.env.USERPROFILE, '.dub') : '',
    process.env.HOME ? join(process.env.HOME, '.dub') : '',
  ].filter(Boolean) as string[]
  for (const h of homes) {
    const pkgs = join(h, 'packages')
    for (const rel of [
      join('libwasm', '~master', 'libwasm'),
      join('libwasm', 'master', 'libwasm'),
      join('libwasm', '0.10.0', 'libwasm'),
    ]) {
      const cand = join(pkgs, rel)
      if (isLibwasmRoot(cand)) return cand
    }
  }
  return ''
}

/** libwasm: live checkout, else the fetched DUB copy of etcimon/libwasm master. */
export function findLibwasmRoot(start = findRiscvDev()): string {
  const env = process.env.LIBWASM_ROOT
  if (env && isLibwasmRoot(env)) return env
  const checkout = findLibwasmCheckout(start)
  if (checkout) return checkout
  const cached = findLibwasmInDubCache()
  if (cached) return cached
  throw new Error(
    'cannot find libwasm (source/libwasm/dom.d; set LIBWASM_ROOT or dub fetch)'
  )
}

export function nativeExe(): string {
  const exe = process.platform === 'win32' ? 'svelte-d.exe' : 'svelte-d'
  return join(pkgRoot, 'bin', exe)
}

export function nativeLib(): string {
  const name =
    process.platform === 'win32'
      ? 'svelte-d.dll'
      : process.platform === 'darwin'
        ? 'libsvelte-d.dylib'
        : 'libsvelte-d.so'
  return join(pkgRoot, 'lib', name)
}

export function nativeArtifacts() {
  const exe = nativeExe()
  const lib = nativeLib()
  return {
    exe,
    lib,
    exeExists: existsSync(exe),
    libExists: existsSync(lib),
    pkgRoot,
  }
}

export { pkgRoot }
