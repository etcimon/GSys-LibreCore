// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import nextra from 'nextra'

const withNextra = nextra({
  theme: 'nextra-theme-docs',
  themeConfig: './theme.config.tsx',
  defaultShowCopyCode: true,
  staticImage: true,
})

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  output: 'export',
  distDir: 'dist',
  // GitHub Pages project path (https://etcimon.github.io/GSys-LibreCore/);
  // override with DOCS_BASE_PATH for alternate deploy roots (empty string = site root).
  basePath: process.env.DOCS_BASE_PATH ?? '/GSys-LibreCore',
  assetPrefix: process.env.DOCS_BASE_PATH ?? '/GSys-LibreCore',
  images: {
    unoptimized: true,
  },
}

export default withNextra(nextConfig)
