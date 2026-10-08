# GSys LibreCore Docs Site

A Next.js + Nextra documentation site for **GSys LibreCore** (shorthand **LibreCore**,
code prefix **G6LC**) — a source-available RISC-V project derived from OpenHW CVA6.

This site is the **primary human-facing** documentation for monorepo layers
(worktree, build-platform, boards, PDK, **sv-timing**, agent workflows).
Sphinx manuals under `docs/01_…` remain OpenHW-lineage references. Edit-time
authority for agents stays in repo-root `AGENTS*.md` and package guides. See
`docs/README.md` for the three-plane map.

## Quick start

From the repo root:

```bash
./docs.sh dev     # Linux / macOS / WSL / Git-Bash
.\docs.ps1 dev    # Windows PowerShell
```

Or directly inside this directory:

```bash
bun install
bun run dev
```

## Build for static hosting

```bash
./docs.sh build
```

The static export lands in `docs/website/dist/`.

## Deployment

`.github/workflows/deploy-docs.yml` builds this site on every push to `master`
that touches `docs/website/**` and publishes it with the GitHub Pages actions
(`configure-pages` → `upload-pages-artifact` → `deploy-pages`). The live site is
<https://etcimon.github.io/GSys-LibreCore/>, sourced from
<https://github.com/etcimon/GSys-LibreCore>.

Project Pages sites are served under `/<repository-name>/`, so `next.config.mjs`
defaults `basePath`/`assetPrefix` to `/GSys-LibreCore`. Set `DOCS_BASE_PATH`
(empty for a custom-domain site root, or `/<fork-name>` on a fork) to deploy
under a different root; the workflow derives it from the repository name and
`preview.mjs` honours the same variable.

## Site map (top-level)

| Section | Path | Focus |
|---|---|---|
| Getting Started | `pages/getting-started.mdx` | Bootstrap + first checks |
| Architecture | `pages/architecture/` | Worktree, upgrade program, SKU matrix, specs/DTS, SI development |
| Core / APU / MB / Tech | `pages/core/`, `corev-apu/`, `corev-mb/`, `technology/` | Layer + product features (OoO, SMT, H, RVV, L2/L3, multi-core, …) |
| Build Platform | `pages/build-platform/` | Commands, probe/verify, timings, extending |
| sv-timing | `pages/sv-timing/` | Structural FO4 package + host boundary |
| Guides | `pages/guides/` | Agent workflow, building docs |

## Add a page

1. Create a `.mdx` file under `pages/<section>/`.
2. Add YAML frontmatter with `title` and `description`.
3. Add the file name to the section's `_meta.ts` for sidebar order.

## License

The code in this directory is MIT (Etienne Cimon) per the repo-root
`.licensing-policy`. Markdown content does not carry a license header.
