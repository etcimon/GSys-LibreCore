// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import nextra from 'nextra'

const withNextra = nextra({
  theme: 'nextra-theme-docs',
  themeConfig: './theme.config.tsx',
  defaultShowCopyCode: true,
  staticImage: true,
})

// `next dev` must serve `/` (localhost:3000). A default `/svelte-d` basePath
// makes the root 404. Production / GH Pages still prefix `/svelte-d` unless
// DOCS_BASE_PATH is set (including to "" for a root deploy).
const fromEnv = process.env.DOCS_BASE_PATH
const base =
  fromEnv !== undefined
    ? fromEnv
    : process.env.NODE_ENV === 'production'
      ? '/svelte-d'
      : ''

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  output: 'export',
  distDir: 'dist',
  images: {
    unoptimized: true,
  },
  ...(base ? { basePath: base, assetPrefix: base } : {}),
}

export default withNextra(nextConfig)
