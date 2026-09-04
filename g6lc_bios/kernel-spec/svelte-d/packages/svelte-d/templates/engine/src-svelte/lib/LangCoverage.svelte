<script lang="ts" context="module">
  export function langCoverageReady() {
    return true
  }
</script>

<script lang="d">
  bool on = true;
  string tone = "navy";
  bool ok = false;
  string raw = "<b>x</b>";
  string[] voids;
  void flip() { this.update.on = !on; }
  void wipe() { extras = []; }
</script>

<div class="lang-coverage">
  <button type="button" on:click={flip} class:on={on}>Flip</button>
  <input type="checkbox" bind:checked={ok} />
  <p id={tone} style:color={tone}>{tone}</p>
  {@html raw}
  <ClickField />
  <section>
    {#if on}
      <p>On</p>
    {:else}
      <p>Off</p>
    {/if}
  </section>
  <ul>
    {#each extras as extra}
      <li>{extra}</li>
    {:else}
      <p>Empty</p>
    {/each}
  </ul>
  <button type="button" class="wipe" on:click={wipe}>Wipe</button>
  {#each voids as v}
    <li>{v}</li>
  {:else}
    <p>None</p>
  {/each}
</div>
