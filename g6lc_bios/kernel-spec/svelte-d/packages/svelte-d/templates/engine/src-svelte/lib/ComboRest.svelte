<script lang="ts" context="module">
  export function comboRestReady() {
    return true
  }
</script>

<script lang="d">
</script>

<svelte:options namespace="html" runes={true} />
<div class="combo-rest">
  <svelte:head>
    <title>Rest</title>
  </svelte:head>
  {let extra = 3}
  {#each rows as row, i (row)}
    <li>{row}</li>
  {/each}
  <slot let:item>fallback</slot>
  <svelte:self>
    <p>Self</p>
  </svelte:self>
</div>
