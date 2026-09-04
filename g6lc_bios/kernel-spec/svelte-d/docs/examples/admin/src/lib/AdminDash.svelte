<script lang="ts" context="module">
  export function adminDashReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="admin-dash">
  {#if show}
    <p>Dashboard</p>
  {/if}
</div>
