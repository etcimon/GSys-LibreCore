# svelte-engine

Bootstrap **libwasm wasm-eh** SPA + **vibe.0** host that svelte-d drops into
`svelte-engine-ws`. `<script lang="d">` prints onto `src-d/`; `+page.server.d`
prints onto `webserver/`. Consumers never clone this next to a `riscv-dev`
tree — `bun add github:etcimon/svelte-d` ships a packaged copy, and
`bunx svelte-d drop-ws` overlays it onto the project dest.

- Notes: [`architecture/README.md`](architecture/README.md)
- `<script lang="d">` contract: [`architecture/script-lang-d.md`](architecture/script-lang-d.md)
- Guider: [`AGENTS.md`](AGENTS.md)

## WASM (default = LDC 1.43 / wasm-eh)

From a dropped workspace, or this tree after `bunx svelte-d setup`:

```bash
bunx svelte-d wasm --ws .            # release + strip-all + wasm-opt -Oz
bunx svelte-d wasm --ws . --debug    # symbols for IR work (`wasm-opt -g -O0`)
```

Or `dub build --arch=wasm32-unknown-wasi --compiler=ldc2 --config=application --build=release`.
Probes: `svelte_engine_eh_probe` / `svelte_engine_phobos_probe` (`node run-probes.mjs`). Binaryen ≥123 parses `try_table` and `-Oz`s the ship module. The etcimon/binaryen fork also `--asyncify`s it; probes must still return 1 (D catch). Landing pad and `.await` stay in different functions. Kit-admin release is **0.93 MiB** / 224 KB gzipped.

libwasm is `dependency "libwasm" version=">=0.11.1"` from `github.com/etcimon/libwasm`.
A live checkout is optional (`dub add-local`); otherwise DUB fetches.

## Host (vibe.0)

```bash
bunx svelte-d host --ws .            # debug
bunx svelte-d host --ws . --release  # optimize + strip
```

Or `dub build --compiler=ldc2 --build=debug` in `webserver/`. The host graph is
the DUB registry (`vibe-0`, botan, memutils, …). `svelte-d setup` `dub add-local`s
those packages only when checkouts happen to sit next to the compiler; a
consumer machine does not need them.

`bun run dev` in a svelte-d app keeps debug. `bun run build` / `svelte-d build`
is release + strip.

## License

MIT. Dependencies keep their own terms (libwasm MIT, vibe.0 MIT + file exceptions).
