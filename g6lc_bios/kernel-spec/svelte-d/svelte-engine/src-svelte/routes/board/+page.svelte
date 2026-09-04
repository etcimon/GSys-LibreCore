<script lang="ts" context="module">
  export function boardPageReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="board-page">
  {#if show}
    <AppShell />
  {/if}
  {#await job}
    <p>Wait</p>
  {:then v}
    <p>Ready</p>
  {/await}
</div>
