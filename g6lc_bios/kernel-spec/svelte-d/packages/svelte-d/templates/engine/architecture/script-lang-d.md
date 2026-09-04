# `<script lang="d">` — plan (addressed to the printer)

Two scripts per `.svelte` (both are first-class):

- **`<script lang="d">`** — libwasm-format D. Lands in `svelte-engine-ws/src-d/`. `svelte.config.js` blanks this block so vscode-svelte / svelte-check do not parse D as TS.
- **`<script lang="ts">` / `context="module"`** — nominal TypeScript the IDE parses. svelte-d **attaches** the body into `src-ts/modules/generated/*.ts` using the `jsExports` template (`libwasm.init` merges `modules[].jsExports`) and `ensureSvelteD().registerTs`. Same-file D calls those exports by the simple name (`callTs`). See svelte-D `architecture/cross-calling.md`.

The svelte-d compiler (`../svelte-D/packages/svelte-d/`) is a **D / vibe.0** program. It scans both blocks, libdparse-checks `lang=d` / `+*.d`, and does not use npm `svelte/compiler`.

## Why D in the script

libwasm components are D structs. A TS script would need a reject-by-default subset and a lowerer (svelte-D K14). Putting D in the script means:

- Fields are D fields (`string title = "Home";`).
- Event handlers are D methods (`void onClick(MouseEvent ev)`).
- `this.update.title = "x";` is written by the author, or inferred from `title = "x";` assignments in handlers.
- wasm-eh `try/catch` is ordinary D.
- No npm imports in the wasm cell. Browser work uses **`libwasm.bindings`**, **`Lodash` + `execute!T()`**, **`moment()`**, or a PgLite-style `Eval("window.X")` wrap — see svelte-D `architecture/libwasm-js.md`.
- **`import std.algorithm`** (and the rest of the spa-phobos set) is wasm Phobos. The printer lifts it to the module header above `nothrow:`. Not `std.file` / `std.stdio`. Throwing APIs (`std.conv.to`) stay inside `try/catch` because the printed struct is `nothrow`.

## File shape

```svelte
<!-- src-svelte/routes/+page.svelte -->
<script lang="d">
  string title = "Home";

  void onClick(MouseEvent ev) {
    this.update.title = "Clicked";
  }
</script>

<section class="container mx-auto p-4">
  <h1 class="text-4xl font-bold">{title}</h1>
  <button on:click={onClick}>Ping</button>
</section>
```

Printer output (this tree’s target idiom):

```d
struct Page {
  @prop!"innerText" string title = "Home";
  @child Ping ping;
  struct Ping {
    mixin Slot!("clicker");
    @callback!"click" void onClick(MouseEvent ev) {
      this.emit(clicker);
    }
    mixin NodeDef!"button";
  }
  @connect!"ping.clicker" void onPing() {
    this.update.title = "Clicked";
  }
  @style!"container mx-auto p-4" mixin NodeDef!"section";
}
```

Inference rules (v1):

| Svelte | D |
|---|---|
| `<script lang="d">` declarations | struct fields (same type/init) |
| markup element | `mixin NodeDef!"tag"` + `@style` / `@attr` / `@prop` |
| `{ident}` text / attr | `@prop` / `@attr` field named `ident` |
| `on:click={onClick}` | `@callback!"click"` on that node, or `Slot` + `@connect` if the handler lives on the parent |
| `this.update.x =` in the script | keep as-is (already libwasm) |
| `x =` in a handler | rewrite to `this.update.x =` |
| `+layout.svelte` | parent `@child` wrapper that stays mounted |
| `+page.server.d` (not `.ts`) | vibe.0 `registerWebInterface` method / `URLRouter` handler |
| anything else | hard diagnostic; do not invent JS |

`lang` other than `d` is rejected in this engine. TS `+page.ts` / `+page.server.ts` stay out of v1 (svelte-D design).

## Server scripts

`src-svelte/routes/api/+server.d` is a vibe.0 handler module: `void get(HTTPServerRequest req, HTTPServerResponse res)`. No lowering. The printer copies it into `webserver/source/generated/` and registers the route.

## What this tree holds today

Hand-written **target** D in `src-d/` (the IR output). Example sources in `src-svelte/` (the IR input). svelte-d prints into a **dropped** `svelte-engine-ws`, not this template.

## Invariants

- Script D must compile as a mixin-able fragment under `nothrow: @safe:` unless marked `@trusted` (navbar EH path).
- Do not import `vibe.*` from a client script.
- Do not import `libwasm` from a `+server.d` (wrong cell).
