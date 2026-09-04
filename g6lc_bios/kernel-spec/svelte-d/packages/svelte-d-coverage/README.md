# svelte-d-coverage

bun + TypeScript consumer of `svelte-d`. Exercises **multi-file** official `.svelte`
graphs (parent `AppShell` + child `Panel`) and the `src/routes/board` layout + page +
host file through the public `import { … } from 'svelte-d'` API: drop → compile → parse,
kit fall-through, lang=ts `jsExports` / `__svelteD.ts`, composed libwasm IR (`{#if}` + component `on:` +
`bind:this` + `{#each}`), and dest-unique `BoardPageServer`. Nested `[id]` / `+error` /
`+server.d` live in the sibling package `svelte-d-kit-app`.

```
bun test
```
