<script lang="ts" context="module">
  export function adminUserReady(id: string) {
    return id
  }
</script>

<script lang="d">
  import kit.app_environment;
  import kit.app_paths;
  import kit.app_navigation;
  bool show = true;
  string id = "";
  void goList() { gotoUrl("/admin/users"); }
</script>

<div class="admin-user">
  <svelte:head>
    <title>User</title>
  </svelte:head>
  <p class="admin-user-id">{id}</p>
  <button type="button" class="admin-user-list" on:click={goList}>List</button>
  {#if show}
    <Panel title={id} />
  {/if}
  {#await job}
    <p>Loading</p>
  {:then v}
    <p>Ready</p>
  {:catch e}
    <p>Fail</p>
  {/await}
</div>
