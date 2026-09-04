# Open questions

1. First wasm `dub build` + `wasm-opt` cell on LDC 1.36.0.
2. Host `webserver/` (vibe-0) still blocked on Windows abs lib paths; separate cell.
3. `wasm-opt` present as Binaryen 132 — whether this version’s `--asyncify` matches the vendored `asyncify.ts`.
4. EH TS runtime is in `src-ts/modules/error-handling.ts`. 1.43 catch is
   validated by `slideshow_eh_probe` on the **raw** module. Browser
   `.await` still needs Binaryen asyncify + `try_table` (Flatten.cpp).
