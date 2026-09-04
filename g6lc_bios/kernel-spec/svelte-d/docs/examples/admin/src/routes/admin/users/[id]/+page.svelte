<script lang="ts" context="module">
  export function adminUserReady(id: string) {
    return id
  }
</script>

<script lang="d">
  import kit.app_navigation;
  bool show = true;
  string id = "";
  void goList() { gotoUrl("/admin/users"); }
</script>

<div class="admin-user">
  <p class="admin-user-id">{id}</p>
  <button type="button" class="admin-user-list" on:click={goList}>List</button>
  {#if show}
    <p>{id}</p>
  {/if}
</div>
