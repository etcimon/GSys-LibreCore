<script lang="ts" context="module">
  export function appShellReady() {
    return true
  }
  export const jsExports = {
    env: {
      appShellReady: () => appShellReady(),
    },
  }
</script>

<script lang="d">
  bool ready = true;
  string who = "Ada";
  Handle panelRef;
  void go() { this.update.ready = !ready; }
</script>

<div class="app-shell">
  {#if ready}
    <Panel bind:this={panelRef} title={who} on:done={go} />
  {/if}
  {#each items as item}
    <li class:on>{item}</li>
  {/each}
</div>
