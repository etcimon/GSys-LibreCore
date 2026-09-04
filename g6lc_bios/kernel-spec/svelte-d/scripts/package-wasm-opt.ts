#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Stage CI-built wasm-opt + Binaryen LICENSE into
// binaryen-build/<variant>/ and a redistributable .tar.gz.
import { copyFileSync, existsSync, mkdirSync, readdirSync, statSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const variant = process.argv[2]
if (!variant) {
  console.error('usage: bun scripts/package-wasm-opt.ts <variant>')
  process.exit(2)
}

const exe = process.platform === 'win32' ? 'wasm-opt.exe' : 'wasm-opt'
const search = [
  join(root, 'binaryen-cmake', 'bin', exe),
  join(root, 'binaryen-cmake', 'bin', 'Release', exe),
  join(root, 'binaryen-cmake', 'Release', exe),
  join(root, 'binaryen', 'build', 'bin', exe),
  join(root, 'binaryen', 'build', 'bin', 'Release', exe),
]

function findBin(): string {
  for (const p of search) {
    if (existsSync(p)) return p
  }
  const walk = (dir: string, depth: number): string => {
    if (depth < 0 || !existsSync(dir)) return ''
    let names: string[] = []
    try {
      names = readdirSync(dir)
    } catch {
      return ''
    }
    for (const n of names) {
      const p = join(dir, n)
      let st
      try {
        st = statSync(p)
      } catch {
        continue
      }
      if (st.isFile() && n === exe) return p
      if (st.isDirectory()) {
        const hit = walk(p, depth - 1)
        if (hit) return hit
      }
    }
    return ''
  }
  return walk(join(root, 'binaryen-cmake'), 4)
}

const bin = findBin()
if (!bin) {
  console.error('wasm-opt not found after cmake build')
  process.exit(1)
}

const destDir = join(root, 'binaryen-build', variant)
const distDir = join(root, 'binaryen-build', 'dist')
mkdirSync(destDir, { recursive: true })
mkdirSync(distDir, { recursive: true })
copyFileSync(bin, join(destDir, exe))
const licenseSrc = join(root, 'binaryen', 'LICENSE')
const licenseDst = join(root, 'binaryen-build', 'LICENSE')
if (existsSync(licenseSrc)) {
  copyFileSync(licenseSrc, licenseDst)
  copyFileSync(licenseSrc, join(destDir, 'LICENSE'))
}

// Relative archive path: Git bash tar on Windows treats `D:` as a remote host
// (`Cannot connect to D: resolve failed`).
const archiveName = `wasm-opt-${variant}.tar.gz`
const members = [exe, ...(existsSync(join(destDir, 'LICENSE')) ? ['LICENSE'] : [])]
const tar = spawnSync('tar', ['-czf', join('..', 'dist', archiveName), ...members], {
  cwd: destDir,
  stdio: 'inherit',
  shell: false,
})
const archive = join(distDir, archiveName)
if ((tar.status ?? 1) !== 0 || !existsSync(archive)) {
  console.error('tar failed for', archive)
  process.exit(1)
}
console.log('packed', archive)
console.log('installed', join(destDir, exe))
