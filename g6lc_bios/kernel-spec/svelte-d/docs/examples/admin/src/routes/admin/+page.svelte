<script lang="ts" context="module">
  export function adminReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="admin-dash">
  {#if show}
    <AdminDash />
  {/if}
</div>
