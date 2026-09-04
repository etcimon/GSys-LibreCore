<script lang="ts" context="module">
  export function filesReady(path: string) {
    return path
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="files">
  <svelte:head>
    <title>Files</title>
  </svelte:head>
  {#if show}
    <Panel title="Files" />
  {/if}
  {#each items as item}
    <li>{item}</li>
  {/each}
</div>
