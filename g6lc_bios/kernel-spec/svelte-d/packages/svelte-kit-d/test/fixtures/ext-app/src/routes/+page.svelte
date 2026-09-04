<script lang="ts">
  import Grid from 'fake-grid'
  import { ready } from '$lib/bridge'
  export const jsExports = { env: {} as Record<string, unknown> }
  void Grid
  void ready
</script>

<script lang="d">
  string title = "ext-app";
</script>

<section class="grid">{title}</section>
