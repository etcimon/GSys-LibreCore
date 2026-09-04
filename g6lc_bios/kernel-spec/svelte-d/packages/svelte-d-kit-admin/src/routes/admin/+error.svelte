<script lang="ts" context="module">
  export function adminErrorReady() {
    return true
  }
</script>

<script lang="d">
  bool shown = true;
</script>

<div class="admin-error">
  {#if shown}
    <p>admin error</p>
  {/if}
</div>
