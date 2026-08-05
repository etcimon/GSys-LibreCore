// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { existsSync, statSync } from 'node:fs'
import { join, resolve, sep } from 'node:path'

const BASE_PATH = process.env.DOCS_BASE_PATH || '/librecore'
const PORT = parseInt(process.env.PORT || '3000', 10)
const ROOT = resolve(process.env.DOCS_DIST_DIR || 'dist')

const rootResolved = resolve(ROOT)

console.log(`[preview] serving ${ROOT} at http://localhost:${PORT}${BASE_PATH}`)

Bun.serve({
  port: PORT,
  fetch(req) {
    const url = new URL(req.url)
    const pathname = decodeURIComponent(url.pathname)

    // Only serve under the configured base path.
    if (pathname !== BASE_PATH && !pathname.startsWith(BASE_PATH + '/')) {
      return new Response('Not Found', { status: 404 })
    }

    // Strip the base path and normalize the relative route.
    let rel = pathname.slice(BASE_PATH.length)
    rel = rel.replace(/^\/+/, '')

    const target = resolve(join(rootResolved, rel))

    // Guard against directory traversal outside the dist folder.
    if (!target.startsWith(rootResolved + sep) && target !== rootResolved) {
      return new Response('Forbidden', { status: 403 })
    }

    // Try exact file, directory index, or a generated `.html` page.
    const candidates = [target, join(target, 'index.html'), target + '.html']
    for (const c of candidates) {
      if (existsSync(c) && statSync(c).isFile()) {
        return new Response(Bun.file(c))
      }
    }

    // Missing assets (e.g. _next/static) should 404, not get index.html.
    if (rel.startsWith('_next/')) {
      return new Response('Not Found', { status: 404 })
    }

    // For everything else, fall back to index.html so client-side routing works.
    const indexHtml = join(rootResolved, 'index.html')
    if (existsSync(indexHtml)) {
      return new Response(Bun.file(indexHtml))
    }

    return new Response('Not Found', { status: 404 })
  },
})
