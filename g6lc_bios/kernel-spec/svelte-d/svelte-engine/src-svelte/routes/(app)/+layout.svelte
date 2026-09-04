<script lang="ts" context="module">
  export function appGroupReady() {
    return true
  }
</script>

<script lang="d">
  bool open = true;
</script>

<div class="app-group">
  <svelte:head>
    <title>App</title>
  </svelte:head>
  {#if open}
    <nav>App</nav>
  {/if}
  <slot>app fallback</slot>
</div>
