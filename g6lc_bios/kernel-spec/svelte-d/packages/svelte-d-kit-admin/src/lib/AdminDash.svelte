<script lang="ts" context="module">
  export function adminDashReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
  void construct()
  {
    console.log("src-d/lib/AdminDash.d:1 AdminDash construct");
  }
</script>

<div class="admin-dash">
  {#if show}
    <Panel title="Dashboard" />
  {/if}
</div>
