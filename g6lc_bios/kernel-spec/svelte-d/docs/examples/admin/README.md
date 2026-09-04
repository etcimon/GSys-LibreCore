# Example: simplified admin

Copy of the kit-admin *shape* (layout, dashboard, users, `:id`) without Postgres, Redis, or browser CDP. Walkthrough: the docs [Development guide → Example: admin panel](../../pages/guide/first-project.mdx).

```bash
bun add github:etcimon/svelte-d
bunx svelte-d setup
bunx svelte-d drop-ws --force
bunx svelte-d compile --project .
```
