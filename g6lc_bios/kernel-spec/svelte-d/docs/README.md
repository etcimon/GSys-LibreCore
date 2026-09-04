# svelte-d docs

Next.js + Nextra documentation for **svelte-d**. The pages are paragraph-driven: why a construct exists, how it becomes libwasm D IR, and what goes wrong if you treat it as official Svelte-to-JS. Agent-facing architecture notes stay in `../architecture/`.

```bash
cd docs
bun install
bun run dev      # http://localhost:3000
bun run build    # static export → dist/
bun run start    # preview the export
```

From the repo root: `bun run docs` / `bun run docs:build`.

The copyable [admin example](examples/admin) is a simplified `svelte-d-kit-admin` (layout, dashboard, users, `:id`) without Postgres, Redis, or CDP.

[libwasm](pages/libwasm) and [vibe.0](pages/vibe.0) document the two D cells. [Wasm and host sizes](pages/advanced/sizes.mdx) records debug vs release+strip then Binaryen `-Oz` on the admin tree (12.64 MiB → 0.93 MiB / 224 KB gzipped). Getting Started recommends VS Code plus code-d pointed at `svelte-engine-ws`. A consumer machine does not include a `riscv-dev` tree.
