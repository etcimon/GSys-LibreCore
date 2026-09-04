<script lang="ts" context="module">
  export function adminLayoutReady() {
    return true
  }
</script>

<script lang="d">
  bool open = true;
</script>

<div class="admin-layout">
  <svelte:head>
    <title>Admin</title>
  </svelte:head>
  {#if open}
    <nav>Admin</nav>
  {/if}
  <slot>admin fallback</slot>
</div>
