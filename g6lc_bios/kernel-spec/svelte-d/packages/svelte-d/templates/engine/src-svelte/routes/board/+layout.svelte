<script lang="ts" context="module">
  export function boardLayoutReady() {
    return true
  }
</script>

<script lang="d">
  bool open = true;
</script>

<div class="board-layout">
  <svelte:head>
    <title>Board</title>
  </svelte:head>
  {#if open}
    <nav>Board</nav>
  {/if}
  <slot>board fallback</slot>
</div>
