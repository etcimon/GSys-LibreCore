# CTFE-compiled interactive web apps

## How it works

The product is not “run Phobos in the browser”. It is **compile-time construction of a SPA**: `mixin Spa!App` in the consumer (`slideshow3dai/src-d/app.d`) injects `_start`, which `application.compile()`s annotated structs (`@child`, `@prop`, `@callback`, `@style`) into a DOM tree and injects `enum css = GetCss!(Application, Theme)` as a stylesheet. Diet views (`src-d-views/*.dt`) and WebIDL bindings (`source/libwasm/bindings/`) are likewise compile-time. What remains at runtime is handle-table DOM ops, the bump allocator, and JS events.

That is why `druntime-wasm/std/` exists: **CTFE** needs `std.algorithm`, `std.traits`, `std.meta`, `std.format`, `std.range`, `std.conv`, … libdparse classification shows the CTFE-keep set is already complete versus LDC 1.36 (41 identical, 1 adapted `std/traits.d`, **0 missing**). Runtime Phobos I/O and math are not part of that contract — `std.numeric` pulled by `gammafunction` is an accidental runtime import, not a CTFE requirement.

slideshow3dai is the reference app: D structs for navbar/dock/pglite, Vite+Capacitor for the shell, vibe-0 on a **different** LDC for the host server. Interactive means JS `domEvent` + optional `.await` (asyncify), not D threads or a GC.

## Loci

`source/libwasm/spa.d` (`mixin Spa`, `_start`, `__VERSION__ == 2106`)  
`source/libwasm/css.d` (`GetCss`)  
`source/libwasm/dom.d` / `node.d`  
slideshow3dai `src-d/app.d`

## Invariants

- Pin stays LDC 1.36.0 until `spa.d`, `druntime-wasm`, and the generated tree move together. Construction.
- CTFE modules may stay closer to stock Phobos than runtime modules; do not “fix” them by adding GC. Convention.

## Extension points

New screen: a D struct + Diet/CSS UDAs, not a TS page. New compile-time helper: keep it in the CTFE-keep set (port into `druntime-wasm/std/` if missing). Same-type `@child T*` (`svelte:self`): `compile!` / `registerRoutes` skip null and do not grow `Ts` (would infinite-instantiate).
