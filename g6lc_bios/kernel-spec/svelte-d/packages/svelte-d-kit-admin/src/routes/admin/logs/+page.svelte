<script lang="ts" context="module">
  export function adminLogsReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="admin-logs">
  {#if show}
    {#each items as item}
      <li>{item}</li>
    {/each}
  {/if}
</div>
