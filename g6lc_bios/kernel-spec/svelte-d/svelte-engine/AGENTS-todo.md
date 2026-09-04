# svelte-engine queue

## Green (2026-08-14)

| Cell | Command | Result |
|---|---|---|
| WASM / EH | `powershell -File build-ldc-master.ps1` | PASS (`svelte_engine_eh_probe` + `svelte_engine_phobos_probe`) |
| Host | `. ..\setenv.ps1` ; `cd webserver` ; `dub build --compiler=ldc2` | PASS (`svelte-engine-server.exe`) |
| vibe.0 Windows | `..\vibe.0\scripts\build-windows-libs.ps1` then `dub build` of `examples/http_static_server` | PASS |

## Next

- Printer (svelte-D PR3): emit `src-d/` from `src-svelte/` `<script lang="d">`
- Optional: restore GeoLite2 (`dmaxminddb` needs a Phobos-current pin)
