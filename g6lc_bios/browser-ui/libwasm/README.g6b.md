# libwasm (g6b kernel clone)

Local clone of `kernel-spec/libwasm` for the BIOS-UI wasm cell. **Not** the
kernel-spec tree (that spec is never compiled). DUB `path=` from
`svelte-engine-ws/dub.sdl` points here.

`version(G6LC_G6B)` replaces the JS `Object_Call_*` import table with D stubs
that call the g6b-wasm Host:

| Import | g6b-wasm / g6b-kernel |
|---|---|
| `env.set_inner_text` | `Host::set_inner_text` → DOM |
| `env.fetch` | `Host::fetch` → `g6b-http::Router` |
| `env.console_log` / `env.set_visible` | Host no-ops / visibility |

LDC 1.43 (`riscv-compilers/ldc2-build`) + `dub --arch=wasm32-unknown-wasi`.
PATH LDC 1.41/1.42 is refused.
