<script lang="ts" context="module">
  export function comboMoreReady() {
    return true
  }
</script>

<script lang="d">
  string stamp = $state("a");
  string stampLabel = $derived(stamp);
  string pick = "a";
  Handle box;
  $effect(() => { console.log(stamp); });
  void onKey() { }
  void bump() { this.update.stamp = "b"; remount_stamp(); }
</script>

<div class="combo-more">
  <svelte:window on:keydown|preventDefault={onKey} />
  {#snippet greet(name)}
    <p>Hi</p>
  {/snippet}
  {@render greet()}
  {@const doubled = 2}
  {@debug pick}
  {#key stamp}
    <p>{stamp}</p>
  {/key}
  <div bind:this={box}>box</div>
  <input type="radio" bind:group={pick} value="a" />
  <input type="radio" bind:group={pick} value="b" />
  <button type="button" on:click|preventDefault={bump}>Bump</button>
</div>
