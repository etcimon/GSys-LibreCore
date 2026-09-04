<script lang="ts" context="module">
  export function boardErrorReady() {
    return true
  }
</script>

<script lang="d">
  bool shown = true;
</script>

<div class="board-error">
  {#if shown}
    <p>board error</p>
  {/if}
</div>
