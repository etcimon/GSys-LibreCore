#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  compileWs,
  dropWs,
  parseGolden,
  prepareDev,
  watchSrcSvelte,
  notifyWasmReload,
  buildDirtyCells,
  hostArtifact,
  viteBin,
  cellForSrc,
  readWriteStats,
} from './pipeline.ts'
import { workspaceDir } from './paths.ts'
import { adaptWorkspace, ADAPTERS } from 'svelte-d'

const cmd = process.argv[2] ?? 'help'
const args = process.argv.slice(3)

function print(r: { status: number; stdout: string; stderr: string }) {
  if (r.stdout) process.stdout.write(r.stdout)
  if (r.stderr) process.stderr.write(r.stderr)
  return r.status
}

function flag(name: string): boolean {
  return args.includes(name)
}

function argValue(name: string): string | undefined {
  const eq = args.find((a) => a.startsWith(name + '='))
  if (eq) return eq.slice(name.length + 1)
  const i = args.indexOf(name)
  if (i < 0) return undefined
  const v = args[i + 1]
  if (!v || v.startsWith('-')) return undefined
  return v
}

if (cmd === 'drop') process.exit(print(dropWs(flag('--force'))))
if (cmd === 'compile') process.exit(print(compileWs()))
if (cmd === 'parse') process.exit(print(parseGolden()))

if (cmd === 'adapt') {
  const positionals: string[] = []
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('-')) {
      if (!args[i].includes('=') && args[i + 1] && !args[i + 1].startsWith('-'))
        i++
      continue
    }
    positionals.push(args[i])
  }
  const adapter = argValue('--adapter') ?? positionals[0]
  const ws = argValue('--ws') ?? workspaceDir()
  const out = argValue('--out') ?? join(ws, 'build', adapter ?? 'static')
  if (!adapter) {
    console.error(
      'usage: svelte-kit-d adapt <static|libwasm-spa|vibe0|vibe0-proxy> --out <dir> [--ws <dir>]'
    )
    console.error('adapters:', ADAPTERS.join(', '))
    process.exit(1)
  }
  try {
    const report = adaptWorkspace({ ws, adapter, out })
    console.log(JSON.stringify(report, null, 2))
    process.exit(0)
  } catch (e) {
    console.error(e instanceof Error ? e.message : e)
    process.exit(1)
  }
}

if (cmd === 'dev' || cmd === 'serve') {
  const noHost = flag('--no-host')
  const noWatch = flag('--no-watch')
  const prepared = prepareDev({
    forceDrop: flag('--force'),
    wasm: 'if-stale',
    host: noHost ? 'never' : 'if-stale',
  })
  if (prepared.drop) print(prepared.drop)
  print(prepared.compile)
  if (prepared.compile.status !== 0) process.exit(prepared.compile.status)
  if (prepared.cells.wasm) print(prepared.cells.wasm)
  if (prepared.cells.host) print(prepared.cells.host)
  print(prepared.deps)
  if (prepared.deps.status !== 0) {
    console.error('bun install failed in', prepared.ws)
    process.exit(prepared.deps.status)
  }

  const ws = prepared.ws
  const vite = join(ws, 'vite.config.js')
  if (!existsSync(vite)) {
    console.error('no vite.config.js in', ws)
    process.exit(1)
  }

  const kids: ChildProcess[] = []
  const killKids = () => {
    for (const c of kids) {
      try {
        c.kill()
      } catch {
        /* already gone */
      }
    }
  }
  process.on('SIGINT', () => {
    killKids()
    process.exit(0)
  })
  process.on('SIGTERM', killKids)

  if (!noHost) {
    const exe = hostArtifact(ws)
    if (exe) {
      console.log('svelte-kit-d host:', exe, '(vibe.0 :8180, best-effort)')
      const host = spawn(exe, [], {
        cwd: join(ws, 'webserver'),
        stdio: 'inherit',
        windowsHide: true,
      })
      kids.push(host)
      host.on('exit', (c) => {
        if (c && c !== 0)
          console.error(
            'host exited',
            c,
            '(Redis/TLS may be missing; Vite still serves :5173)'
          )
      })
    } else {
      console.log('svelte-kit-d host: skip (no svelte-engine-server)')
    }
  }

  if (!noWatch) {
    const w = watchSrcSvelte(ws, (file) => {
      console.log('svelte-kit-d: compile', file)
      const c = compileWs(file)
      print(c)
      if (c.status !== 0) return
      const cell = cellForSrc(file)
      const st = readWriteStats(ws)
      if (cell === 'host' || cell === 'both') {
        if (st.host > 0) {
          const cells = buildDirtyCells(ws, { wasm: 'never', host: 'if-stale' })
          if (cells.host) print(cells.host)
        }
      }
      if (cell === 'wasm' || cell === 'both') {
        if (st.wasm > 0) {
          const cells = buildDirtyCells(ws, { wasm: 'if-stale', host: 'never' })
          if (cells.wasm) print(cells.wasm)
          else notifyWasmReload(ws)
        }
      }
    })
    process.on('exit', () => w.close())
  }

  console.log(
    'svelte-kit-d',
    cmd + ':',
    'vite in',
    ws,
    '(HMR ws :3001; host :8180 reverse-proxies here)'
  )
  const child = spawn(
    viteBin(ws),
    ['--config', 'vite.config.js', '--host', '127.0.0.1'],
    {
      cwd: ws,
      stdio: 'inherit',
      shell: viteBin(ws) === 'vite' && process.platform === 'win32',
    }
  )
  kids.push(child)
  child.on('exit', (c) => {
    killKids()
    process.exit(c ?? 1)
  })
} else if (cmd === 'help' || cmd === '-h') {
  console.log(`svelte-kit-d — bun DX over svelte-d + svelte-engine-ws
  bun src/cli.ts drop [--force]
  bun src/cli.ts compile
  bun src/cli.ts parse
  bun src/cli.ts adapt <static|libwasm-spa|vibe0|vibe0-proxy> --out <dir> [--ws <dir>]
      consume ws/.svelte-d/manifest.json and copy artifacts (no Node HTTP)
  bun src/cli.ts dev|serve [--force] [--no-host] [--no-watch]
      drop if needed, compile IR, wasm/host if dirty, vite :5173
      HMR ws :3001; vibe.0 :8180 if the host exe exists
`)
} else {
  console.error('unknown command', cmd)
  process.exit(1)
}

void workspaceDir
