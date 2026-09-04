<script lang="ts" context="module">
  export function adminBridgeReady(flag = true) {
    return flag
  }
</script>

<script lang="ts">
  import { dash } from 'admin-mini'
  import { fmt } from './admin-fmt'
  import { fmt as fmtLib } from '$lib/admin-fmt'

  export function label(name = 'admin', extra = ''): string {
    return fmt(dash(name)) + extra
  }

  export async function loadLabel(id = 0): Promise<string> {
    return fmtLib('id-' + id)
  }
</script>

<script lang="d">
  extern(C) export int tally(int a, int b = 1) { return a + b; }

  string caption = "";
  void go() { this.update.caption = label("Ada"); }
  void goDef() { this.update.caption = label(); }
</script>

<div class="admin-bridge">
  <button type="button" on:click={go}>Go</button>
  <span>{caption}</span>
</div>
