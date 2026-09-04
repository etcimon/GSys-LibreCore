// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// One LDC 1.43+ compiles the svelte-d CLI, the vibe.0 host, and the
// wasm-eh cell. Wasm vs host stay different targets (no shared objects /
// DFLAGS); they share this compiler. Does not start a second HTTP stack.
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { spawnSync } from 'node:child_process'
import { homedir, tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { findLibwasmCheckout, findRiscvDev, pkgRoot } from './paths.ts'

export const DEFAULT_LDC_VERSION = process.env.SVELTE_D_LDC_VERSION || '1.43.0-beta1'

export type HostTriple = {
  os: 'windows' | 'linux' | 'osx'
  arch: 'x64' | 'arm64'
  /** LDC release folder / archive stem suffix, e.g. windows-x64, linux-x86_64 */
  variant: string
  exe: string
  archiveExt: '7z' | 'tar.xz'
}

export type PlatformReport = {
  triple: HostTriple
  ldc: string
  dub: string
  libwasm: string
  vibe0: string
  wasmOpt: string
  ok: boolean
  downloaded: boolean
}

/** First Binaryen that parses wasm `try_table` (Ubuntu apt 108 cannot). */
export const DEFAULT_BINARYEN_VERSION =
  process.env.SVELTE_D_BINARYEN_VERSION || 'version_123'
export const MIN_WASM_OPT_VERSION = 123

/** Rolling GitHub Release tag for the etcimon/binaryen wasm-opt CI builds. */
export const DEFAULT_WASM_OPT_RELEASE =
  process.env.SVELTE_D_WASM_OPT_RELEASE || 'wasm-opt-svelte-d'
/** Branch that holds wasm-opt-<triple>.tar.gz when the Release is missing. */
export const DEFAULT_WASM_OPT_BINARIES_BRANCH =
  process.env.SVELTE_D_WASM_OPT_BRANCH || 'wasm-opt-binaries'
/** Git tag on etcimon/binaryen (branch svelte-d) for this svelte-d increment. */
export const BINARYEN_FORK_TAG =
  process.env.SVELTE_D_BINARYEN_TAG || 'svelte-d-v0.2.0'
export const DEFAULT_WASM_OPT_REPO =
  process.env.SVELTE_D_WASM_OPT_REPO || 'etcimon/svelte-d'
export const OPENSSL_GIT =
  process.env.SVELTE_D_OPENSSL_GIT || 'https://github.com/etcimon/openssl.git'
export const OPENSSL_GIT_BRANCH = process.env.SVELTE_D_OPENSSL_BRANCH || 'http2fix'

/** Features LDC 1.43 wasm-eh emits. Do not add `--asyncify` on this list. */
export const WASM_EH_FEATURES = [
  '--enable-exception-handling',
  '--enable-bulk-memory',
  '--enable-bulk-memory-opt',
  '--enable-reference-types',
  '--enable-multivalue',
  '--enable-nontrapping-float-to-int',
  '--enable-sign-ext',
] as const

/** Asyncify import list for libwasm `.await` (env.libwasm_await__void). */
export const WASM_ASYNCIFY_ARGS = [
  '--asyncify',
  '--optimize-level=0',
  '--pass-arg=asyncify-imports@env.libwasm_await__void',
] as const

export type OptimizeWasmMode = 'debug' | 'release'

export type OptimizeWasmResult = {
  ok: boolean
  skipped: boolean
  reason: string
  wasmOpt: string
  bytesIn: number
  bytesOut: number
  mode: OptimizeWasmMode
}

const HOST_PKGS: { dir: string; dub: string }[] = [
  { dir: 'memutils', dub: 'memutils' },
  { dir: 'botan-math', dub: 'botan-math' },
  { dir: 'libasync', dub: 'libasync' },
  { dir: 'botan', dub: 'botan' },
  { dir: 'libhttp2', dub: 'libhttp2' },
  { dir: 'openssl', dub: 'openssl' },
  { dir: 'vibe.0', dub: 'vibe-0' },
]

export function hostTriple(
  platform = process.platform,
  arch = process.arch
): HostTriple {
  const os = platform === 'win32' ? 'windows' : platform === 'darwin' ? 'osx' : 'linux'
  const a: 'x64' | 'arm64' = arch === 'arm64' ? 'arm64' : 'x64'
  const exe = os === 'windows' ? 'ldc2.exe' : 'ldc2'
  if (os === 'windows')
    return { os, arch: a, variant: 'windows-x64', exe, archiveExt: '7z' }
  if (os === 'osx')
    return {
      os,
      arch: a,
      variant: a === 'arm64' ? 'osx-arm64' : 'osx-x86_64',
      exe,
      archiveExt: 'tar.xz',
    }
  return {
    os,
    arch: a,
    variant: a === 'arm64' ? 'linux-aarch64' : 'linux-x86_64',
    exe,
    archiveExt: 'tar.xz',
  }
}

/** True when `--version` text is 1.43 or later (not 1.42 / 1.36). */
export function isLdc143Text(text: string): boolean {
  if (!text) return false
  // Only the first LDC identity line. Later "built with LDC (1.42.0)" is the
  // bootstrap compiler, not this binary.
  const first =
    text.split(/\r?\n/).find((l) => /LDC - the LLVM D compiler/i.test(l)) || text
  const m = first.match(/\(([^)]+)\)/)
  const ver = m?.[1] ?? first
  if (/1\.(36|40|41|42)\./.test(ver)) return false
  return /1\.(43|44|45|46)/.test(ver)
}

export function isLdc143(bin: string): boolean {
  if (!bin || !existsSync(bin)) return false
  const r = spawnSync(bin, ['--version'], { encoding: 'utf8', shell: false })
  return isLdc143Text((r.stdout || '') + (r.stderr || ''))
}

function which(cmd: string): string {
  const r = spawnSync(process.platform === 'win32' ? 'where' : 'which', [cmd], {
    encoding: 'utf8',
    shell: false,
  })
  if (r.status !== 0) return ''
  return (r.stdout || '').split(/\r?\n/).map((s) => s.trim()).find(Boolean) || ''
}

function walkSeeds(start?: string): string[] {
  const seeds: string[] = []
  if (start) seeds.push(resolve(start))
  try {
    seeds.push(findRiscvDev())
  } catch {
    /* no engine host */
  }
  seeds.push(process.cwd())
  const seen = new Set<string>()
  const out: string[] = []
  for (const s of seeds) {
    if (!s || seen.has(s)) continue
    seen.add(s)
    out.push(s)
  }
  return out
}

function ldcInDir(dir: string, exe: string): string {
  const cand = join(dir, exe)
  return existsSync(cand) ? cand : ''
}

function scanToolchainDir(root: string, exe: string): string {
  if (!existsSync(root)) return ''
  let names: string[] = []
  try {
    names = readdirSync(root)
  } catch {
    return ''
  }
  const prefer = names
    .filter((n) => /ldc2-(1\.43|1\.44|1\.45|master|build)/i.test(n))
    .sort()
    .reverse()
  for (const n of prefer) {
    const bin = ldcInDir(join(root, n, 'bin'), exe)
    if (bin && isLdc143(bin)) return bin
  }
  return ''
}

export function toolchainHome(): string {
  const env = process.env.SVELTE_D_TOOLCHAINS
  if (env) return env
  return join(homedir(), '.svelte-d', 'toolchains')
}

/** LDC 1.43+ for CLI, vibe.0 host, and wasm-eh. Never returns 1.42. */
export function findLdc(start?: string): string {
  const exe = hostTriple().exe
  const envKeys = ['SVELTE_D_LDC', 'LDC', 'WASM_LDC', 'SVELTE_D_WASM_LDC', 'DC']
  for (const k of envKeys) {
    const v = process.env[k]
    if (v && existsSync(v) && isLdc143(v)) return v
  }
  const cached = scanToolchainDir(toolchainHome(), exe)
  if (cached) return cached
  for (const seed of walkSeeds(start)) {
    let p = seed
    for (let i = 0; i < 10; i++) {
      for (const rel of [
        join('riscv-compilers', 'ldc2-build', 'bin'),
        join('ldc2-build', 'bin'),
      ]) {
        const bin = ldcInDir(join(p, rel), exe)
        if (bin && isLdc143(bin)) return bin
      }
      const fromTc = scanToolchainDir(join(p, 'toolchains'), exe)
      if (fromTc) return fromTc
      const parent = dirname(p)
      if (parent === p) break
      p = parent
    }
  }
  const onPath = which('ldc2')
  if (onPath && isLdc143(onPath)) return onPath
  return ''
}

export function findDub(ldc = findLdc()): string {
  if (ldc) {
    const name = process.platform === 'win32' ? 'dub.exe' : 'dub'
    const cand = join(dirname(ldc), name)
    if (existsSync(cand)) return cand
  }
  return which('dub')
}

function isVibe0Root(p: string): boolean {
  return (
    existsSync(join(p, 'source', 'vibe', 'http', 'server.d')) ||
    existsSync(join(p, 'source', 'vibe', 'd.d'))
  )
}

export function findVibe0Checkout(start?: string): string {
  const env = process.env.VIBE0_ROOT
  if (env && isVibe0Root(env)) return env
  for (const seed of walkSeeds(start)) {
    let p = seed
    for (let i = 0; i < 10; i++) {
      for (const cand of [join(p, 'vibe.0'), join(p, 'riscv-dev', 'vibe.0')]) {
        if (isVibe0Root(cand)) return cand
      }
      const parent = dirname(p)
      if (parent === p) break
      p = parent
    }
  }
  return ''
}

function findPkgDir(dirName: string, start?: string): string {
  for (const seed of walkSeeds(start)) {
    let p = seed
    for (let i = 0; i < 10; i++) {
      for (const cand of [join(p, dirName), join(p, 'riscv-dev', dirName)]) {
        if (existsSync(join(cand, 'dub.json')) || existsSync(join(cand, 'dub.sdl')))
          return cand
      }
      const parent = dirname(p)
      if (parent === p) break
      p = parent
    }
  }
  return ''
}

function run(cmd: string, args: string[]): { status: number; out: string } {
  const r = spawnSync(cmd, args, { encoding: 'utf8', shell: false })
  return { status: r.status ?? 1, out: (r.stdout || '') + (r.stderr || '') }
}

/** dub add-local for vibe.0 + its host graph when checkouts exist. */
export function ensureHostAddLocals(start?: string): string[] {
  const dub = findDub()
  if (!dub) return []
  const done: string[] = []
  for (const pkg of HOST_PKGS) {
    const root = pkg.dir === 'vibe.0' ? findVibe0Checkout(start) : findPkgDir(pkg.dir, start)
    if (!root) continue
    run(dub, ['remove-local', root])
    const r = run(dub, ['add-local', root])
    if (r.status === 0) done.push(`${pkg.dub}=${root}`)
  }
  return done
}

export function ldcDownloadUrl(
  version = DEFAULT_LDC_VERSION,
  triple = hostTriple()
): string {
  const tag = version.startsWith('v') ? version : `v${version}`
  const stem = `ldc2-${version}-${triple.variant}`
  return `https://github.com/ldc-developers/ldc/releases/download/${tag}/${stem}.${triple.archiveExt}`
}

function find7z(): string {
  const onPath = which('7z') || which('7za')
  if (onPath) return onPath
  if (process.platform === 'win32') {
    for (const p of [
      join(process.env['ProgramFiles'] || 'C:\\Program Files', '7-Zip', '7z.exe'),
      join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', '7-Zip', '7z.exe'),
    ]) {
      if (existsSync(p)) return p
    }
  }
  return ''
}

/** Download official LDC 1.43 into ~/.svelte-d/toolchains. No-op if already there. */
export async function downloadLdc(
  version = DEFAULT_LDC_VERSION,
  triple = hostTriple()
): Promise<string> {
  const dest = join(toolchainHome(), `ldc2-${version}-${triple.variant}`)
  const bin = join(dest, 'bin', triple.exe)
  if (existsSync(bin) && isLdc143(bin)) return bin
  mkdirSync(toolchainHome(), { recursive: true })
  const url = ldcDownloadUrl(version, triple)
  const archive = join(tmpdir(), basename(url))
  console.log('svelte-d: downloading', url)
  const res = await fetch(url)
  if (!res.ok) throw new Error(`LDC download failed ${res.status} ${url}`)
  writeFileSync(archive, Buffer.from(await res.arrayBuffer()))
  if (triple.archiveExt === 'tar.xz') {
    const r = spawnSync('tar', ['-xJf', archive, '-C', toolchainHome()], {
      stdio: 'inherit',
      shell: false,
    })
    if ((r.status ?? 1) !== 0) throw new Error('tar extract failed for ' + archive)
  } else {
    const z7 = find7z()
    if (!z7)
      throw new Error(
        '7-Zip required to extract LDC on Windows (install 7-Zip or add 7z to PATH)'
      )
    const r = spawnSync(z7, ['x', '-y', `-o${toolchainHome()}`, archive], {
      stdio: 'inherit',
      shell: false,
    })
    if ((r.status ?? 1) !== 0) throw new Error('7z extract failed for ' + archive)
  }
  if (!existsSync(bin)) throw new Error('ldc2 missing after extract: ' + bin)
  return bin
}

function wasmOptExeName(os = hostTriple().os): string {
  return os === 'windows' ? 'wasm-opt.exe' : 'wasm-opt'
}

/** Binaryen release-asset stem (not LDC's osx/windows-x64 names). */
export function binaryenVariant(
  platform = process.platform,
  arch = process.arch
): string {
  if (platform === 'win32') return 'x86_64-windows'
  if (platform === 'darwin') return arch === 'arm64' ? 'arm64-macos' : 'x86_64-macos'
  return arch === 'arm64' ? 'aarch64-linux' : 'x86_64-linux'
}

/** Folder name under `binaryen-build/` and the CI wasm-opt release assets. */
export function binaryenBuildVariant(
  platform = process.platform,
  arch = process.arch
): string {
  if (platform === 'win32') return 'windows-x86_64'
  if (platform === 'darwin') return arch === 'arm64' ? 'darwin-arm64' : 'darwin-x86_64'
  return arch === 'arm64' ? 'linux-aarch64' : 'linux-x86_64'
}

/** Repo / package `binaryen-build/` (LICENSE + per-triple wasm-opt). */
export function findBinaryenBuildRoot(start?: string): string {
  const env = process.env.SVELTE_D_BINARYEN_BUILD
  if (env && existsSync(env)) return env
  const exe = wasmOptExeName()
  const variant = binaryenBuildVariant()
  const looks = (dir: string) =>
    existsSync(join(dir, 'LICENSE')) ||
    existsSync(join(dir, 'README.md')) ||
    existsSync(join(dir, variant, exe)) ||
    existsSync(join(dir, exe))
  const candidates: string[] = []
  for (const seed of walkSeeds(start)) {
    let p = seed
    for (let i = 0; i < 10; i++) {
      candidates.push(join(p, 'binaryen-build'))
      const parent = dirname(p)
      if (parent === p) break
      p = parent
    }
  }
  try {
    candidates.push(join(pkgRoot, 'binaryen-build'))
    candidates.push(join(pkgRoot, '..', '..', 'binaryen-build'))
  } catch {
    /* paths optional */
  }
  candidates.push(join(process.cwd(), 'binaryen-build'))
  for (const c of candidates) {
    if (looks(c)) return c
  }
  return ''
}

export function forkedWasmOptDownloadUrl(
  variant = binaryenBuildVariant(),
  repo = DEFAULT_WASM_OPT_REPO,
  tag = DEFAULT_WASM_OPT_RELEASE
): string {
  return `https://github.com/${repo}/releases/download/${tag}/wasm-opt-${variant}.tar.gz`
}

/** Public zip of the latest successful `wasm-opt` workflow artifact. */
export function forkedWasmOptArtifactUrls(
  variant = binaryenBuildVariant(),
  repo = DEFAULT_WASM_OPT_REPO,
  branch = 'master'
): string[] {
  const art = `wasm-opt-${variant}`
  return [
    `https://nightly.link/${repo}/workflows/wasm-opt.yml/${branch}/${art}.zip`,
    `https://nightly.link/${repo}/workflows/wasm-opt/${branch}/${art}.zip`,
  ]
}

/** Release, wasm-opt-binaries branch, then CI artifacts (nightly.link). */
export function forkedWasmOptDownloadUrls(
  variant = binaryenBuildVariant(),
  repo = DEFAULT_WASM_OPT_REPO,
  tag = DEFAULT_WASM_OPT_RELEASE,
  branch = DEFAULT_WASM_OPT_BINARIES_BRANCH
): string[] {
  return [
    forkedWasmOptDownloadUrl(variant, repo, tag),
    `https://github.com/${repo}/raw/${branch}/wasm-opt-${variant}.tar.gz`,
    `https://raw.githubusercontent.com/${repo}/${branch}/wasm-opt-${variant}.tar.gz`,
    ...forkedWasmOptArtifactUrls(variant, repo),
  ]
}

/** Parse `wasm-opt --version` (`wasm-opt version 123 (version_123)`). */
export function parseWasmOptVersion(text: string): number {
  if (!text) return 0
  const m = text.match(/version[_\s]+(\d+)/i)
  return m ? parseInt(m[1], 10) : 0
}

export function isWasmOptNewText(text: string): boolean {
  return parseWasmOptVersion(text) >= MIN_WASM_OPT_VERSION
}

export function isWasmOptNew(bin: string): boolean {
  if (!bin || !existsSync(bin)) return false
  const r = spawnSync(bin, ['--version'], { encoding: 'utf8', shell: false })
  return isWasmOptNewText((r.stdout || '') + (r.stderr || ''))
}

function wasmOptInDir(dir: string, exe: string): string {
  const cand = join(dir, exe)
  return existsSync(cand) ? cand : ''
}

function scanBinaryenDir(root: string, exe: string): string {
  if (!existsSync(root)) return ''
  let names: string[] = []
  try {
    names = readdirSync(root)
  } catch {
    return ''
  }
  const prefer = names
    .filter((n) => /binaryen-version[_-]?\d+/i.test(n))
    .sort((a, b) => {
      const na = parseInt((a.match(/(\d+)/) || ['0'])[0], 10)
      const nb = parseInt((b.match(/(\d+)/) || ['0'])[0], 10)
      return nb - na
    })
  for (const n of prefer) {
    const bin = wasmOptInDir(join(root, n, 'bin'), exe)
    if (bin && isWasmOptNew(bin)) return bin
  }
  return ''
}

/** Out-of-tree install of the etcimon/binaryen (Flatten try_table) fork. */
export function forkedWasmOptHome(): string {
  return join(toolchainHome(), 'binaryen-svelte-d')
}

export function isForkedWasmOpt(bin: string): boolean {
  if (!bin) return false
  const n = bin.replace(/\\/g, '/').toLowerCase()
  return (
    n.includes('binaryen-svelte-d') ||
    n.includes('binaryen-build') ||
    /\/binaryen\/(bin|build)\//.test(n)
  )
}

function isBinaryenSource(dir: string): boolean {
  return existsSync(join(dir, 'src', 'passes', 'Flatten.cpp'))
}

/** svelte-d `binaryen/` submodule (etcimon/binaryen, branch svelte-d). */
export function findBinaryenSource(start?: string): string {
  const env = process.env.SVELTE_D_BINARYEN
  if (env && isBinaryenSource(env)) return env
  for (const seed of walkSeeds(start)) {
    let p = seed
    for (let i = 0; i < 10; i++) {
      for (const cand of [join(p, 'binaryen'), join(p, 'riscv-dev', 'svelte-D', 'binaryen')]) {
        if (isBinaryenSource(cand)) return cand
      }
      const parent = dirname(p)
      if (parent === p) break
      p = parent
    }
  }
  return ''
}

const VS_CMAKE = [
  join(
    process.env['ProgramFiles'] || 'C:\\Program Files',
    'Microsoft Visual Studio',
    '18',
    'Community',
    'Common7',
    'IDE',
    'CommonExtensions',
    'Microsoft',
    'CMake',
    'CMake',
    'bin',
    'cmake.exe'
  ),
  join(
    process.env['ProgramFiles'] || 'C:\\Program Files',
    'Microsoft Visual Studio',
    '2022',
    'Community',
    'Common7',
    'IDE',
    'CommonExtensions',
    'Microsoft',
    'CMake',
    'CMake',
    'bin',
    'cmake.exe'
  ),
  join(
    process.env['ProgramFiles'] || 'C:\\Program Files',
    'Microsoft Visual Studio',
    '2022',
    'BuildTools',
    'Common7',
    'IDE',
    'CommonExtensions',
    'Microsoft',
    'CMake',
    'CMake',
    'bin',
    'cmake.exe'
  ),
]

export function findCMake(): string {
  const env = process.env.CMAKE
  if (env && existsSync(env)) return env
  const onPath = which('cmake')
  if (onPath) return onPath
  for (const p of VS_CMAKE) {
    if (existsSync(p)) return p
  }
  return ''
}

function locateBuiltWasmOpt(root: string): string {
  const exe = wasmOptExeName()
  for (const rel of ['bin', join('bin', 'Release'), 'Release', join('bin', 'Debug')]) {
    const cand = join(root, rel, exe)
    if (existsSync(cand)) return cand
  }
  return ''
}

/**
 * Source rebuild is opt-in. A pulled CI artifact must not compile Binaryen
 * just because the submodule and cmake are on the machine.
 */
export function shouldBuildWasmOptFromSource(haveForked: boolean): boolean {
  if (process.env.SVELTE_D_NO_BUILD_WASM_OPT === '1') return false
  if (process.env.SVELTE_D_BUILD_WASM_OPT === '1') return true
  return !haveForked
}

/**
 * Configure + build `wasm-opt` from the etcimon/binaryen submodule.
 * Installs to ~/.svelte-d/toolchains/binaryen-svelte-d. Needs CMake + a C++ toolchain.
 * Skips the compile when a pulled/installed fork already works.
 */
export function buildWasmOptFromSource(
  src = findBinaryenSource(),
  cmake = findCMake()
): string {
  if (!src || !isBinaryenSource(src)) {
    throw new Error('binaryen source missing (git submodule update --init binaryen)')
  }
  if (!cmake) {
    throw new Error('cmake missing (install CMake, or set CMAKE)')
  }
  const dest = forkedWasmOptHome()
  const exe = wasmOptExeName()
  const installed = join(dest, 'bin', exe)
  if (existsSync(installed) && isWasmOptNew(installed) && !shouldBuildWasmOptFromSource(true))
    return installed
  const flatten = join(src, 'src', 'passes', 'Flatten.cpp')
  if (existsSync(installed) && existsSync(flatten) && !shouldBuildWasmOptFromSource(true)) {
    try {
      if (statSync(installed).mtimeMs >= statSync(flatten).mtimeMs) return installed
    } catch {
      /* rebuild */
    }
  }
  const buildDir = join(toolchainHome(), 'binaryen-svelte-d-build')
  mkdirSync(buildDir, { recursive: true })
  mkdirSync(join(dest, 'bin'), { recursive: true })
  console.log('svelte-d: building wasm-opt from', src)
  const isWin = process.platform === 'win32'
  const configure = isWin
    ? [cmake, '-S', src, '-B', buildDir, '-A', 'x64', '-DENABLE_WERROR=OFF', '-DBUILD_TESTS=OFF']
    : [
        cmake,
        '-S',
        src,
        '-B',
        buildDir,
        '-DCMAKE_BUILD_TYPE=Release',
        '-DENABLE_WERROR=OFF',
        '-DBUILD_TESTS=OFF',
      ]
  const cfg = spawnSync(configure[0], configure.slice(1), { stdio: 'inherit', shell: false })
  if ((cfg.status ?? 1) !== 0) throw new Error('cmake configure failed for binaryen')
  const buildArgs = ['--build', buildDir, '--target', 'wasm-opt']
  if (isWin) buildArgs.push('--config', 'Release')
  const bld = spawnSync(cmake, buildArgs, { stdio: 'inherit', shell: false })
  if ((bld.status ?? 1) !== 0) throw new Error('cmake --build wasm-opt failed')
  const built = locateBuiltWasmOpt(buildDir)
  if (!built) throw new Error('wasm-opt missing after cmake build in ' + buildDir)
  copyFileSync(built, installed)
  return installed
}

function wasmOptInBuildRoot(root: string): string {
  if (!root) return ''
  const exe = wasmOptExeName()
  const variant = binaryenBuildVariant()
  for (const cand of [
    join(root, variant, exe),
    join(root, exe),
    join(root, 'bin', exe),
  ]) {
    if (existsSync(cand) && isWasmOptNew(cand)) return cand
  }
  return ''
}

/** Binaryen ≥123 `wasm-opt`. Prefers the etcimon Flatten-try_table fork. */
export function findWasmOpt(start?: string): string {
  const exe = wasmOptExeName()
  for (const k of ['SVELTE_D_WASM_OPT', 'WASM_OPT']) {
    const v = process.env[k]
    if (v && existsSync(v) && isWasmOptNew(v)) return v
  }
  const fromBuild = wasmOptInBuildRoot(findBinaryenBuildRoot(start))
  if (fromBuild) return fromBuild
  const forked = join(forkedWasmOptHome(), 'bin', exe)
  if (existsSync(forked) && isWasmOptNew(forked)) return forked
  const src = findBinaryenSource(start)
  if (src) {
    const inTree = locateBuiltWasmOpt(src) || locateBuiltWasmOpt(join(src, 'build'))
    if (inTree && isWasmOptNew(inTree)) return inTree
  }
  const cached = scanBinaryenDir(toolchainHome(), exe)
  if (cached) return cached
  for (const seed of walkSeeds(start)) {
    let p = seed
    for (let i = 0; i < 10; i++) {
      const fromTc = scanBinaryenDir(join(p, 'toolchains'), exe)
      if (fromTc) return fromTc
      const parent = dirname(p)
      if (parent === p) break
      p = parent
    }
  }
  const onPath = which('wasm-opt')
  if (onPath && isWasmOptNew(onPath)) return onPath
  return ''
}

export function binaryenDownloadUrl(
  version = DEFAULT_BINARYEN_VERSION,
  variant = binaryenVariant()
): string {
  const tag = version.startsWith('version_') ? version : `version_${version}`
  return `https://github.com/WebAssembly/binaryen/releases/download/${tag}/binaryen-${tag}-${variant}.tar.gz`
}

function ensureBinaryenBuildRoot(start?: string): string {
  const existing = findBinaryenBuildRoot(start)
  if (existing) return existing
  let dest = ''
  try {
    const repo = resolve(pkgRoot, '..', '..')
    if (existsSync(join(repo, 'package.json'))) dest = join(repo, 'binaryen-build')
  } catch {
    /* ignore */
  }
  if (!dest) dest = join(process.cwd(), 'binaryen-build')
  mkdirSync(dest, { recursive: true })
  return dest
}

function extractArchive(archive: string, destDir: string): void {
  mkdirSync(destDir, { recursive: true })
  const r = spawnSync('tar', ['-xf', archive, '-C', destDir], {
    stdio: 'inherit',
    shell: false,
  })
  if ((r.status ?? 1) === 0) return
  const z7 = find7z()
  if (!z7) throw new Error('tar/7z extract failed for ' + archive)
  const z = spawnSync(z7, ['x', '-y', `-o${destDir}`, archive], {
    stdio: 'inherit',
    shell: false,
  })
  if ((z.status ?? 1) !== 0) throw new Error('7z extract failed for ' + archive)
}

function findNamedFile(root: string, want: string, depth = 4): string {
  if (depth < 0 || !existsSync(root)) return ''
  let names: string[] = []
  try {
    names = readdirSync(root)
  } catch {
    return ''
  }
  for (const n of names) {
    const p = join(root, n)
    let st
    try {
      st = statSync(p)
    } catch {
      continue
    }
    if (st.isFile() && n === want) return p
    if (st.isDirectory()) {
      const hit = findNamedFile(p, want, depth - 1)
      if (hit) return hit
    }
  }
  return ''
}

function unwrapWasmOptArchive(destDir: string, exe: string, destBin: string): string {
  let found =
    (existsSync(destBin) ? destBin : '') ||
    locateBuiltWasmOpt(destDir) ||
    wasmOptInDir(destDir, exe) ||
    wasmOptInDir(join(destDir, 'bin'), exe) ||
    findNamedFile(destDir, exe)
  if (found && existsSync(found)) return found
  const inner =
    findNamedFile(destDir, `wasm-opt-${binaryenBuildVariant()}.tar.gz`) ||
    findNamedFile(destDir, 'wasm-opt.tar.gz')
  if (inner) {
    extractArchive(inner, destDir)
    found =
      (existsSync(destBin) ? destBin : '') ||
      locateBuiltWasmOpt(destDir) ||
      findNamedFile(destDir, exe)
  }
  return found && existsSync(found) ? found : ''
}

function markWasmOptExecutable(bin: string): void {
  if (process.platform === 'win32') return
  try {
    chmodSync(bin, 0o755)
  } catch {
    /* ignore */
  }
}

function finishForkedInstall(found: string, destBin: string, buildRoot: string): string {
  if (found !== destBin) {
    mkdirSync(dirname(destBin), { recursive: true })
    copyFileSync(found, destBin)
    found = destBin
  }
  markWasmOptExecutable(found)
  installForkedWasmOpt(found, buildRoot)
  return found
}

/**
 * Download the CI-built etcimon/binaryen `wasm-opt` (Flatten + asyncify
 * try_table) the same way LDC 1.43 is fetched. Unpacks into
 * `binaryen-build/<triple>/` (with LICENSE) and `~/.svelte-d/toolchains/binaryen-svelte-d`.
 * Apple Silicon uses `darwin-arm64`.
 */
export async function downloadForkedWasmOpt(
  variant = binaryenBuildVariant()
): Promise<string> {
  const exe = wasmOptExeName()
  const existing = findWasmOpt()
  if (existing && isForkedWasmOpt(existing)) return existing
  const buildRoot = ensureBinaryenBuildRoot()
  const destDir = join(buildRoot, variant)
  const destBin = join(destDir, exe)
  if (existsSync(destBin) && isWasmOptNew(destBin)) {
    installForkedWasmOpt(destBin, buildRoot)
    return destBin
  }
  mkdirSync(destDir, { recursive: true })
  const urls = forkedWasmOptDownloadUrls(variant)
  let archive = ''
  let lastErr = ''
  for (const url of urls) {
    console.log('svelte-d: downloading', url)
    try {
      const res = await fetch(url)
      if (!res.ok) {
        lastErr = `${res.status} ${url}`
        continue
      }
      archive = join(tmpdir(), basename(url.split('?')[0] || url))
      writeFileSync(archive, Buffer.from(await res.arrayBuffer()))
      lastErr = ''
      break
    } catch (e) {
      lastErr = e instanceof Error ? e.message : String(e)
    }
  }
  if (!archive) throw new Error(`forked wasm-opt download failed: ${lastErr}`)
  extractArchive(archive, destDir)
  const found = unwrapWasmOptArchive(destDir, exe, destBin)
  if (!found) throw new Error('wasm-opt missing after extract: ' + destDir)
  return finishForkedInstall(found, destBin, buildRoot)
}

/** Forked wasm-opt on this host, downloading the matching triple if needed. */
export async function ensureForkedWasmOpt(
  variant = binaryenBuildVariant()
): Promise<string> {
  const have = findWasmOpt()
  if (have && isForkedWasmOpt(have)) return have
  return downloadForkedWasmOpt(variant)
}

/** Sync form for dest `buildWasm` / pipeline (Apple Silicon → darwin-arm64). */
export function ensureForkedWasmOptSync(
  variant = binaryenBuildVariant()
): string {
  const have = findWasmOpt()
  if (have && isForkedWasmOpt(have)) return have
  const exe = wasmOptExeName()
  const buildRoot = ensureBinaryenBuildRoot()
  const destDir = join(buildRoot, variant)
  const destBin = join(destDir, exe)
  if (existsSync(destBin) && isWasmOptNew(destBin)) {
    installForkedWasmOpt(destBin, buildRoot)
    return destBin
  }
  mkdirSync(destDir, { recursive: true })
  let lastErr = ''
  for (const url of forkedWasmOptDownloadUrls(variant)) {
    console.log('svelte-d: downloading', url)
    const archive = join(tmpdir(), basename(url.split('?')[0] || url) || 'wasm-opt.bin')
    const curl = spawnSync('curl', ['-fsSL', '--max-time', '30', '-o', archive, url], {
      stdio: 'inherit',
      shell: false,
    })
    if ((curl.status ?? 1) !== 0 || !existsSync(archive) || statSync(archive).size < 64) {
      lastErr = `curl ${curl.status ?? 1} ${url}`
      continue
    }
    try {
      extractArchive(archive, destDir)
      const found = unwrapWasmOptArchive(destDir, exe, destBin)
      if (found) return finishForkedInstall(found, destBin, buildRoot)
      lastErr = 'no wasm-opt in ' + archive
    } catch (e) {
      lastErr = e instanceof Error ? e.message : String(e)
    }
  }
  throw new Error(`forked wasm-opt download failed: ${lastErr}`)
}

function installForkedWasmOpt(bin: string, buildRoot: string): void {
  const exe = wasmOptExeName()
  const home = join(forkedWasmOptHome(), 'bin')
  mkdirSync(home, { recursive: true })
  const installed = join(home, exe)
  if (resolve(bin) !== resolve(installed)) {
    try {
      copyFileSync(bin, installed)
    } catch {
      /* dest may be the same file */
    }
  }
  const srcLicense = join(buildRoot, 'LICENSE')
  const packedLicense = join(dirname(bin), 'LICENSE')
  const homeLicense = join(forkedWasmOptHome(), 'LICENSE')
  for (const from of [srcLicense, packedLicense]) {
    if (existsSync(from) && resolve(from) !== resolve(homeLicense)) {
      try {
        copyFileSync(from, homeLicense)
      } catch {
        /* ignore */
      }
      break
    }
  }
}

/** DUB `openssl ~>3.3.4` (vibe-0 1.2.1). Registry has no matching config. */
export function ensureOpensslForDub(start?: string): string {
  const dub = findDub()
  if (!dub) return ''
  const existing = findPkgDir('openssl', start)
  if (existing && existsSync(join(existing, 'dub.sdl'))) {
    pinOpensslRecipeVersion(existing, '3.3.4')
    run(dub, ['remove-local', existing])
    const r = run(dub, ['add-local', existing])
    return r.status === 0 ? existing : ''
  }
  const dest = join(toolchainHome(), 'openssl-3.3.4')
  if (!existsSync(join(dest, 'dub.sdl')) && !existsSync(join(dest, 'dub.json'))) {
    mkdirSync(toolchainHome(), { recursive: true })
    console.log('svelte-d: cloning', OPENSSL_GIT, OPENSSL_GIT_BRANCH)
    const g = spawnSync(
      'git',
      ['clone', '--depth', '1', '--branch', OPENSSL_GIT_BRANCH, OPENSSL_GIT, dest],
      { stdio: 'inherit', shell: false }
    )
    if ((g.status ?? 1) !== 0 || !existsSync(join(dest, 'dub.sdl'))) return ''
  }
  pinOpensslRecipeVersion(dest, '3.3.4')
  run(dub, ['remove-local', dest])
  const r = run(dub, ['add-local', dest])
  return r.status === 0 ? dest : ''
}

function pinOpensslRecipeVersion(dir: string, ver: string): void {
  const p = join(dir, 'dub.sdl')
  if (!existsSync(p)) return
  let txt = readFileSync(p, 'utf8')
  if (/^version\s+"/m.test(txt)) return
  txt = txt.replace(/^name\s+"openssl"\s*$/m, `name "openssl"\nversion "${ver}"`)
  writeFileSync(p, txt)
}

/** Download Binaryen ≥123 into ~/.svelte-d/toolchains. No-op if already there. */
export async function downloadBinaryen(
  version = DEFAULT_BINARYEN_VERSION,
  variant = binaryenVariant()
): Promise<string> {
  const tag = version.startsWith('version_') ? version : `version_${version}`
  const dest = join(toolchainHome(), `binaryen-${tag}`)
  const exe = wasmOptExeName()
  const bin = join(dest, 'bin', exe)
  if (existsSync(bin) && isWasmOptNew(bin)) return bin
  mkdirSync(toolchainHome(), { recursive: true })
  const url = binaryenDownloadUrl(tag, variant)
  const archive = join(tmpdir(), basename(url))
  console.log('svelte-d: downloading', url)
  const res = await fetch(url)
  if (!res.ok) throw new Error(`Binaryen download failed ${res.status} ${url}`)
  writeFileSync(archive, Buffer.from(await res.arrayBuffer()))
  const r = spawnSync('tar', ['-xzf', archive, '-C', toolchainHome()], {
    stdio: 'inherit',
    shell: false,
  })
  if ((r.status ?? 1) !== 0) {
    const z7 = find7z()
    if (!z7) throw new Error('tar/7z extract failed for ' + archive)
    const z = spawnSync(z7, ['x', '-y', `-o${toolchainHome()}`, archive], {
      stdio: 'inherit',
      shell: false,
    })
    if ((z.status ?? 1) !== 0) throw new Error('7z extract failed for ' + archive)
  }
  if (!existsSync(bin)) throw new Error('wasm-opt missing after extract: ' + bin)
  return bin
}

/**
 * Official wasm-eh post-link. Binaryen ≥123 *parses* `try_table`.
 * Release: `-Oz --converge --strip-debug --strip-dwarf --strip-producers`.
 * Debug: `-g -O0` (keep DWARF / name section).
 * Never `--asyncify` on stock Binaryen 123/132. The etcimon/binaryen
 * submodule (branch svelte-d) Flattens try_table; enable asyncify only
 * after that wasm-opt is the one on PATH (isForkedWasmOpt).
 */
export function optimizeWasm(opts: {
  input: string
  output?: string
  mode?: OptimizeWasmMode
  wasmOpt?: string
}): OptimizeWasmResult {
  const mode: OptimizeWasmMode = opts.mode === 'debug' ? 'debug' : 'release'
  const input = opts.input
  const output = opts.output || input
  const empty = (): OptimizeWasmResult => ({
    ok: false,
    skipped: true,
    reason: 'missing input',
    wasmOpt: '',
    bytesIn: 0,
    bytesOut: 0,
    mode,
  })
  if (!input || !existsSync(input)) return empty()
  const bytesIn = statSync(input).size
  const wasmOpt = opts.wasmOpt || findWasmOpt()
  if (!wasmOpt) {
    if (input !== output) copyFileSync(input, output)
    return {
      ok: true,
      skipped: true,
      reason: 'no wasm-opt ≥123 (bunx svelte-d setup; set SVELTE_D_WASM_OPT)',
      wasmOpt: '',
      bytesIn,
      bytesOut: existsSync(output) ? statSync(output).size : bytesIn,
      mode,
    }
  }
  const tmp = output + '.opt.tmp'
  const wantAsyncify =
    process.env.SVELTE_D_WASM_ASYNCIFY !== '0' &&
    (isForkedWasmOpt(wasmOpt) || process.env.SVELTE_D_WASM_ASYNCIFY === '1')
  let optInput = input
  let asyncified = false
  if (wantAsyncify) {
    const ayTmp = output + '.ay.tmp'
    const ay = spawnSync(
      wasmOpt,
      [...WASM_EH_FEATURES, ...WASM_ASYNCIFY_ARGS, input, '-o', ayTmp],
      { encoding: 'utf8', shell: false }
    )
    if ((ay.status ?? 1) === 0 && existsSync(ayTmp)) {
      optInput = ayTmp
      asyncified = true
    } else {
      try {
        if (existsSync(ayTmp)) unlinkSync(ayTmp)
      } catch {
        /* ignore */
      }
    }
  }
  const args =
    mode === 'release'
      ? [
          '-Oz',
          '--converge',
          '--strip-debug',
          '--strip-dwarf',
          '--strip-producers',
          ...WASM_EH_FEATURES,
          optInput,
          '-o',
          tmp,
        ]
      : ['-g', '-O0', ...WASM_EH_FEATURES, optInput, '-o', tmp]
  const r = spawnSync(wasmOpt, args, { encoding: 'utf8', shell: false })
  const out = (r.stdout || '') + (r.stderr || '')
  if ((r.status ?? 1) !== 0 || !existsSync(tmp)) {
    try {
      if (existsSync(tmp)) unlinkSync(tmp)
    } catch {
      /* ignore */
    }
    if (input !== output) copyFileSync(input, output)
    return {
      ok: false,
      skipped: true,
      reason: (out || 'wasm-opt failed').slice(-400),
      wasmOpt,
      bytesIn,
      bytesOut: existsSync(output) ? statSync(output).size : bytesIn,
      mode,
    }
  }
  copyFileSync(tmp, output)
  try {
    unlinkSync(tmp)
  } catch {
    /* ignore */
  }
  if (optInput !== input) {
    try {
      unlinkSync(optInput)
    } catch {
      /* ignore */
    }
  }
  const sizeTag = mode === 'release' ? '-Oz --converge --strip-*' : '-g -O0'
  return {
    ok: true,
    skipped: false,
    reason: sizeTag + ' + wasm-eh' + (asyncified ? ' + asyncify' : ''),
    wasmOpt,
    bytesIn,
    bytesOut: statSync(output).size,
    mode,
  }
}

export async function setupPlatform(
  opts: { download?: boolean; start?: string } = {}
): Promise<PlatformReport> {
  const triple = hostTriple()
  let downloaded = false
  let ldc = findLdc(opts.start)
  if (!ldc && opts.download !== false && process.env.SVELTE_D_NO_DOWNLOAD !== '1') {
    try {
      ldc = await downloadLdc()
      downloaded = true
    } catch (e) {
      console.warn(
        'svelte-d: LDC 1.43 download skipped —',
        e instanceof Error ? e.message : e
      )
    }
  }
  let wasmOpt = findWasmOpt(opts.start)
  if (
    (!wasmOpt || !isForkedWasmOpt(wasmOpt)) &&
    opts.download !== false &&
    process.env.SVELTE_D_NO_DOWNLOAD !== '1'
  ) {
    try {
      wasmOpt = await downloadForkedWasmOpt()
      downloaded = true
    } catch (e) {
      console.warn(
        'svelte-d: forked wasm-opt download skipped —',
        e instanceof Error ? e.message : e
      )
    }
  }
  const src = findBinaryenSource(opts.start)
  const cmake = findCMake()
  const haveForked = Boolean(wasmOpt && isForkedWasmOpt(wasmOpt))
  const wantForkBuild =
    Boolean(src && cmake) &&
    opts.download !== false &&
    shouldBuildWasmOptFromSource(haveForked)
  if (wantForkBuild) {
    try {
      wasmOpt = buildWasmOptFromSource(src, cmake)
      downloaded = true
    } catch (e) {
      console.warn(
        'svelte-d: forked wasm-opt build skipped —',
        e instanceof Error ? e.message : e
      )
    }
  }
  if (!wasmOpt && opts.download !== false && process.env.SVELTE_D_NO_DOWNLOAD !== '1') {
    try {
      wasmOpt = await downloadBinaryen()
      downloaded = true
    } catch (e) {
      console.warn(
        'svelte-d: Binaryen wasm-opt download skipped —',
        e instanceof Error ? e.message : e
      )
    }
  }
  const dub = findDub(ldc)
  let libwasm = ''
  try {
    libwasm = findLibwasmCheckout()
  } catch {
    libwasm = ''
  }
  const vibe0 = findVibe0Checkout(opts.start)
  if (dub) {
    ensureOpensslForDub(opts.start)
    if (libwasm) {
      run(dub, ['remove-local', libwasm])
      run(dub, ['add-local', libwasm, '~master'])
    }
    ensureHostAddLocals(opts.start)
  }
  return {
    triple,
    ldc,
    dub,
    libwasm,
    vibe0,
    wasmOpt,
    ok: Boolean(ldc && dub),
    downloaded,
  }
}

export function writePlatformPin(ws: string, report: PlatformReport): void {
  mkdirSync(join(ws, '.svelte-d'), { recursive: true })
  const body = {
    schema: 'svelte-d-platform/v1',
    ldc: report.ldc.replace(/\\/g, '/'),
    dub: report.dub.replace(/\\/g, '/'),
    cell: 'ldc-1.43',
    os: report.triple.os,
    arch: report.triple.arch,
    variant: report.triple.variant,
    libwasm: report.libwasm.replace(/\\/g, '/'),
    vibe0: report.vibe0.replace(/\\/g, '/'),
    wasmOpt: (report.wasmOpt || '').replace(/\\/g, '/'),
    ok: report.ok,
  }
  writeFileSync(join(ws, '.svelte-d', 'platform.json'), JSON.stringify(body, null, 2) + '\n')
}

