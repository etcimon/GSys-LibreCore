# svelte-d-kit-app

bun + TypeScript consumer of `svelte-d`. Exercises a **nested SvelteKit tree**
through the public `import { … } from 'svelte-d'` API: `src/routes/board` layout
+ page + `[id]` + `+error` + `+page.server.d` + `+server.d`. Compile writes
libwasm dests, `kit_router.d` `@entering` patterns, and unique vibe.0 host
classes (`PageServer`, `BoardPageServer`, `BoardServer`).

```
bun test
```
