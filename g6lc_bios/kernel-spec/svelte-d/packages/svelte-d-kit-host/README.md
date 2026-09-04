# svelte-d-kit-host

bun + TypeScript consumer of `svelte-d`. Exercises **host-cell** kit mappings
through `import { … } from 'svelte-d'`: `[...rest]` → trailing `*`,
`hooks.server.d` → `HTTPServerSettings.errorPageHandler`, and form `actions`
as vibe.0 `post` / `postSave`.

```
bun test
```
