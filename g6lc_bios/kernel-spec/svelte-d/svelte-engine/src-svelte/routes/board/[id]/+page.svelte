<script lang="ts" context="module">
  export function boardIdReady(id: string) {
    return id
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="board-item">
  <svelte:head>
    <title>Item</title>
  </svelte:head>
  {#if show}
    <Panel title="Item" />
  {/if}
  {#await job}
    <p>Loading</p>
  {:then v}
    <p>Done</p>
  {:catch e}
    <p>Fail</p>
  {/await}
</div>
