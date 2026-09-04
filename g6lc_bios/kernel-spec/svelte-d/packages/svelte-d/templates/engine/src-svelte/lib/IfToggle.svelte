<script lang="ts" context="module">
  export function ifToggleReady() {
    return true
  }
</script>

<script lang="d">
  bool open = false;
  void toggle() { this.update.open = !open; }
</script>

<div class="if-toggle">
  <button type="button" on:click={toggle}>Toggle</button>
  {#if open}
    <p>Visible</p>
  {:else}
    <p>Hidden</p>
  {/if}
</div>
