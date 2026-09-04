// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Directed vibe.0 PG/Redis soak through printed AdminPageServer.getSoak.
// Redis/Postgres down or bad creds → skip (do not fail the suite).
import { describe, expect, test } from 'bun:test'
import { spawn, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Socket } from 'node:net'
import { buildHost, compileWorkspace, findRiscvDev } from 'svelte-d'
import { adminWorkspace, hostExePath } from '../src/ws.ts'
import { killPort, killProcessTree } from '../src/proc.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))

function envFileValue(path: string, key: string): string {
  if (!existsSync(path)) return ''
  for (const raw of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const i = line.indexOf('=')
    if (i < 0) continue
    if (line.slice(0, i).trim() !== key) continue
    return line
      .slice(i + 1)
      .trim()
      .replace(/^['"]|['"]$/g, '')
  }
  return ''
}

/** Postgres password from PGPASSWORD or a gitignored `.env` (never committed). */
function pgPassword(): string {
  if (process.env.PGPASSWORD) return process.env.PGPASSWORD
  for (const p of [
    join(project, '.env'),
    join(project, '.env.local'),
    join(project, '..', '..', '.env'),
  ]) {
    const v = envFileValue(p, 'PGPASSWORD')
    if (v) return v
  }
  return ''
}
const PORT = 8180
const ORIGIN = `https://127.0.0.1:${PORT}`
const ROUNDS = 16

function portOpen(port: number, host = '127.0.0.1'): Promise<boolean> {
  return new Promise((resolve) => {
    const s = new Socket()
    const done = (ok: boolean) => {
      s.removeAllListeners()
      s.destroy()
      resolve(ok)
    }
    s.setTimeout(400)
    s.once('connect', () => done(true))
    s.once('timeout', () => done(false))
    s.once('error', () => done(false))
    s.connect(port, host)
  })
}

function ensureHostCerts(ws: string): void {
  const dest = join(ws, 'webserver', 'certs')
  if (existsSync(join(dest, 'cert.crt')) && existsSync(join(dest, 'private.pem'))) return
  const src = join(findRiscvDev(), 'svelte-engine', 'webserver', 'certs')
  mkdirSync(dest, { recursive: true })
  for (const n of ['cert.crt', 'private.pem', 'ca.crt', 'public.pem', 'ca.key']) {
    const from = join(src, n)
    if (existsSync(from)) cpSync(from, join(dest, n))
  }
}

function ensureSlideshowDb(): void {
  const psql = join('C:\\Program Files\\PostgreSQL\\18\\bin', 'psql.exe')
  if (!existsSync(psql)) return
  const pass = pgPassword()
  if (!pass) return
  const env = { ...process.env, PGPASSWORD: pass }
  const args = ['-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
  const seen = spawnSync(psql, [...args, '-tAc', "SELECT 1 FROM pg_database WHERE datname='slideshow3dai'"], {
    env,
    encoding: 'utf8',
  })
  if ((seen.stdout ?? '').includes('1')) return
  spawnSync(psql, [...args, '-c', 'CREATE DATABASE slideshow3dai'], { env, encoding: 'utf8' })
}

async function waitHttps(url: string, ms = 20_000): Promise<boolean> {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    try {
      const r = await fetch(url, { tls: { rejectUnauthorized: false } } as RequestInit)
      if (r.status > 0) return true
    } catch {
      /* retry */
    }
    await new Promise((r) => setTimeout(r, 200))
  }
  return false
}

describe('host PG/Redis soak via vibe.0 helpers', () => {
  test('printed getSoak; live SETEX/GET + SELECT 1 when daemons answer', async () => {
    const ws = adminWorkspace()
    expect(compileWorkspace({ ws, project }).status).toBe(0)
    const hostSrc = readFileSync(
      join(ws, 'webserver', 'source', 'generated', 'routes', 'admin', 'page_server.d'),
      'utf8'
    )
    expect(hostSrc).toContain('void getSoak(')
    expect(hostSrc).toContain('connectCache()')
    expect(hostSrc).toContain('connectDB()')
    expect(hostSrc).toContain('redis.set(')
    expect(hostSrc).toContain('scoped!PGCommand')
    expect(hostSrc).toContain('svelte-d-host-soak/v1')
    expect(hostSrc).not.toContain('import libwasm')

    const built = buildHost(ws)
    expect([0, 3]).toContain(built.status)
    if (built.status !== 0) return

    const exe = hostExePath(ws)
    if (!exe) return

    const redisUp = await portOpen(6379)
    const pgUp = await portOpen(5432)
    ensureHostCerts(ws)
    if (pgUp) ensureSlideshowDb()
    killPort(PORT)
    const host = spawn(exe, [], {
      cwd: join(ws, 'webserver'),
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
      env: {
        ...process.env,
        ...(pgPassword() ? { PGPASSWORD: pgPassword() } : {}),
        PGSSL: 'disable',
        PGDATABASE: 'slideshow3dai',
        PGUSER: 'postgres',
        PGHOST: '127.0.0.1',
      },
    })
    let hostLog = ''
    host.stdout?.on('data', (b) => {
      hostLog += String(b)
    })
    host.stderr?.on('data', (b) => {
      hostLog += String(b)
    })
    try {
      const soakUrl = ORIGIN + '/__svelte-d/host/soak?n=' + ROUNDS
      const up = await waitHttps(soakUrl)
      if (!up) {
        throw new Error('host did not listen on ' + soakUrl + '\n' + hostLog.slice(-2000))
      }
      const res = await fetch(soakUrl, {
        tls: { rejectUnauthorized: false },
      } as RequestInit)
      expect(res.ok).toBe(true)
      const j = (await res.json()) as {
        schema: string
        rounds: number
        redis: string
        postgres: string
        redisHits: number
        postgresHits: number
      }
      expect(j.schema).toBe('svelte-d-host-soak/v1')
      expect(j.rounds).toBe(ROUNDS)
      if (redisUp) {
        if (j.redisHits !== ROUNDS) {
          throw new Error('redis soak missed ' + JSON.stringify(j) + ' log=' + hostLog.slice(-1200))
        }
        expect(j.redisHits).toBe(ROUNDS)
        expect(j.redis).toBe(String(ROUNDS))
      } else {
        expect(j.redis.startsWith('skip')).toBe(true)
      }
      if (pgUp) {
        if (j.postgresHits !== ROUNDS) {
          throw new Error('postgres soak missed ' + JSON.stringify(j) + ' log=' + hostLog.slice(-800))
        }
        expect(j.postgresHits).toBe(ROUNDS)
        expect(j.postgres).toBe(String(ROUNDS))
      } else {
        expect(j.postgres.startsWith('skip')).toBe(true)
      }
    } finally {
      killProcessTree(host)
      killPort(PORT)
    }
  }, 180_000)
})
