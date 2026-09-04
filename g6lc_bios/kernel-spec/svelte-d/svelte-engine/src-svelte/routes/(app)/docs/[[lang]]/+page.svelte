<script lang="ts" context="module">
  export function docsReady(lang: string) {
    return lang
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="docs">
  <svelte:head>
    <title>Docs</title>
  </svelte:head>
  {#if show}
    <Panel title="Docs" />
  {/if}
</div>
