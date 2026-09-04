<script lang="ts" context="module">
  export function shopReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
</script>

<div class="shop">
  {#if show}
    <ClickField />
  {/if}
  {#await job}
    <p>Browse</p>
  {:then v}
    <p>Listed</p>
  {/await}
</div>
