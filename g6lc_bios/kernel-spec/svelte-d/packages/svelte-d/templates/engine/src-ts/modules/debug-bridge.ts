// svelte-d debug bridge — fetch debug-map and rewrite libwasm/svelte stacks
// in the page so Chrome/Firefox DevTools console shows orig .svelte lines.
declare let window: any

type Entry = {
  dest: string
  destLine: number
  orig: string
  origLine: number
  kind: string
  name: string
}

function destFromUrl(url: string): string {
  const u = (url || '').replace(/\\/g, '/').split('?')[0]
  const i = u.indexOf('src-d/')
  if (i >= 0) return u.slice(i)
  return u
}

function lookup(entries: Entry[], destHint: string, line: number): Entry | null {
  const hint = destHint.replace(/\\/g, '/')
  let best: Entry | null = null
  for (const e of entries) {
    const d = e.dest.replace(/\\/g, '/')
    if (!(d === hint || d.endsWith('/' + hint) || d.endsWith(hint))) continue
    if (e.destLine > line) continue
    if (!best || e.destLine > best.destLine) best = e
  }
  return best
}

function rewriteText(entries: Entry[], text: string): string {
  const one = (all: string, file: string, ln: string) => {
    const e = lookup(entries, file.replace(/\\/g, '/'), Number(ln))
    if (!e) return all
    return `${all} [svelte ${e.orig}:${e.origLine} kind=${e.kind}]`
  }
  const colon = text.replace(
    /(?:^|[(\s])((?:[\w./\\[\]-])+\.d):(\d+)/g,
    one
  )
  return colon.replace(/((?:[\w./\\[\]-])+\.d)\((\d+)(?:,\d+)?\)/g, one)
}

function rewriteWasmNames(
  names: { name: string; orig: string; origLine: number; kind: string }[],
  text: string
): string {
  let out = text
  for (const n of names) {
    if (!n.name || !n.orig) continue
    if (n.name.length < 8 && !n.name.includes('.') && !n.name.startsWith('_D')) continue
    if (out.includes('[svelte ' + n.orig)) continue
    if (out.includes(n.name))
      out = out.split(n.name).join(`${n.name} [svelte ${n.orig}:${n.origLine} kind=${n.kind}]`)
  }
  return out
}

/** Tag asyncify / wasm-function frames. Never invents an orig line. */
function rewriteAsyncFrames(text: string): string {
  return text
    .replace(/\bwasm-function\[(\d+)\]/g, (all) =>
      all.includes('[async-wasm]') ? all : `${all} [async-wasm]`
    )
    .replace(/\basyncify_(?:start|stop)_(?:un)?wind\b/g, (all) =>
      all.includes('[asyncify]') ? all : `${all} [asyncify]`
    )
}

export function rewriteErrorStack(err: unknown, rewrite: (s: string) => string): string {
  if (err == null) return ''
  const stack =
    typeof err === 'object' && err && 'stack' in err && (err as { stack?: unknown }).stack
      ? String((err as { stack: unknown }).stack)
      : String(err)
  return rewrite(rewriteAsyncFrames(stack))
}

export async function installSvelteDDebug(): Promise<void> {
  let entries: Entry[] = []
  let wasmNames: { name: string; orig: string; origLine: number; kind: string }[] = []
  try {
    const r = await fetch('/__svelte-d/debug-map.json')
    if (r.ok) {
      const j = await r.json()
      entries = Array.isArray(j.entries) ? j.entries : []
    }
  } catch {
    /* overlay optional until compile wrote public/ */
  }
  try {
    const w = await fetch('/__svelte-d/wasm-names.json')
    if (w.ok) {
      const j = await w.json()
      wasmNames = Array.isArray(j.functions)
        ? j.functions.filter((f: { orig?: string }) => f && f.orig)
        : []
    }
  } catch {
    /* names optional until ensureWasm */
  }
  const rewrite = (s: string) =>
    rewriteWasmNames(wasmNames, rewriteAsyncFrames(rewriteText(entries, String(s))))
  window.__svelteDDebugMap = entries
  window.__svelteDWasmNames = wasmNames
  window.__svelteDRewrite = rewrite
  window.__svelteDRewriteError = (err: unknown) => rewriteErrorStack(err, rewrite)
  window.__svelteDLastAwait = window.__svelteDLastAwait || {
    failed: false,
    reason: '',
    exportName: '',
  }
  window.__svelteDNoteAwait = (s: { failed?: boolean; reason?: string; exportName?: string }) => {
    window.__svelteDLastAwait = s
    if (s && s.failed) {
      const r = rewrite(String(s.reason || 'await failed'))
      window.__svelteDLastFaults.push(r)
      console.error('await-failed', r)
    }
  }
  window.__svelteDLastFaults = Array.isArray(window.__svelteDLastFaults)
    ? window.__svelteDLastFaults
    : []
  window.__svelteDFormatAbort = (what: string, file: string, line: number, msg: string) => {
    const raw = `ABORT: ${what} @ ${file}:${line} ${msg}`
    const e = file ? lookup(entries, file, line) : null
    return e ? `${raw} [svelte ${e.orig}:${e.origLine} kind=${e.kind}]` : raw
  }
  // Runtime probe: rewrite dest:line and emit through console so CDP
  // Runtime.consoleAPICalled / Log.entryAdded see the orig .svelte.
  window.__svelteDProbe = (s: string) => {
    const r = rewrite(String(s ?? ''))
    console.info('svelte-d-probe', r)
    return r
  }
  const noteFault = (raw: string) => {
    const r = rewrite(raw)
    window.__svelteDLastFaults.push(r)
    return r
  }
  window.onerror = (msg, src, line, _col, err) => {
    const stack = err && err.stack ? String(err.stack) : String(msg)
    const loc = src ? `${src}:${line || 0}` : ''
    console.error(noteFault(loc ? stack + ' ' + loc : stack))
    return false
  }
  window.addEventListener('unhandledrejection', (ev: PromiseRejectionEvent) => {
    const reason = ev && ev.reason != null ? String(ev.reason && ev.reason.stack ? ev.reason.stack : ev.reason) : 'rejection'
    console.error('unhandledrejection', noteFault(reason))
  })
  const wrap = (fn: (...a: unknown[]) => void) =>
    function (this: unknown, ...args: unknown[]) {
      const next = args.map((a) => (typeof a === 'string' ? rewrite(a) : a))
      return fn.apply(this, next)
    }
  console.log = wrap(console.log.bind(console))
  console.info = wrap(console.info.bind(console))
  console.warn = wrap(console.warn.bind(console))
  console.error = wrap(console.error.bind(console))
  console.debug = wrap(console.debug.bind(console))
  console.trace = wrap(console.trace.bind(console))
  attachSvelteDPopstate()
}

/** wasm-eh window.onpopstate is not reliable; JS popstate → navigate_to. */
export function attachSvelteDPopstate(): void {
  if (window.__svelteDPopstate) return
  window.__svelteDPopstate = true
  window.addEventListener('popstate', () => {
    const path = location.pathname + location.search
    window.__svelteDLastPop = path
    const nav = window.callNative as
      | ((n: string, v: string) => Promise<void>)
      | undefined
    if (typeof nav === 'function') void nav('navigate_to', path)
  })
}

void destFromUrl
