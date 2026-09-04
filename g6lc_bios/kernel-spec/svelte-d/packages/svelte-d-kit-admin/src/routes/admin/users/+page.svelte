<script lang="ts" context="module">
  export function adminUsersReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="admin-users">
  {#if show}
    {#each users as user}
      <li>{user}</li>
    {/each}
  {/if}
</div>
