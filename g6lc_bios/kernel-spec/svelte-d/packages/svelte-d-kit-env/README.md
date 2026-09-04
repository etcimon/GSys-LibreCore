# svelte-d-kit-env

bun + TypeScript consumer of `svelte-d`. Exercises **`$app` / `$env`** generated
D enums and a host `load` that uses vibe.0 `cookies` / `redirect` / `setCookie`
/ `headers`. `PUBLIC_*` lands in both cells; other keys are host-only.
Wasm importing `$env/static/private` is a compile graph error.

```
bun test
```
