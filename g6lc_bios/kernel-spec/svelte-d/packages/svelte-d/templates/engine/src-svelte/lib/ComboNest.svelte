<script lang="ts" context="module">
  export function comboNestReady() {
    return true
  }
</script>

<script lang="d">
  bool on = true;
  bool hide = false;
  bool checked = false;
  void copy() { }
  void scroll() { }
  void flip() { this.update.on = !on; }
</script>

<div class="combo-nest">
  <button type="button" on:click={flip}>Flip</button>
  <button type="button" class="pin" on:click={fill_rows}>Pin</button>
  <button type="button" class="skip" on:click={fill_skips}>Skip</button>
  <button type="button" class="hit" on:click={fill_hits}>Hit</button>
  {#if on && !hide}
    <p>Show</p>
  {/if}
  {#each items as item}
    {#if on}
      <li>{item}</li>
    {/if}
  {/each}
  {#each rows as row}
    {#if row.ok}
      <li class="ok-row">{row}</li>
    {/if}
  {/each}
  {#each picks as pick}
    {#if pick.ok && on}
      <li class="pick-row">{pick}</li>
    {/if}
  {/each}
  {#each holds as hold}
    {#if hold.ok || on}
      <li class="hold-row">{hold}</li>
    {/if}
  {/each}
  {#each skips as skip}
    {#if !skip.ok}
      <li class="skip-row">{skip}</li>
    {/if}
  {/each}
  {#each cuts as cut}
    {#if !cut.ok && on}
      <li class="cut-row">{cut}</li>
    {/if}
  {/each}
  {#each keeps as keep}
    {#if !keep.ok || on}
      <li class="keep-row">{keep}</li>
    {/if}
  {/each}
  {#each drops as drop}
    {#if drop.ok && !on}
      <li class="drop-row">{drop}</li>
    {/if}
  {/each}
  {#each boths as both}
    {#if !both.ok || !on}
      <li class="both-row">{both}</li>
    {/if}
  {/each}
  {#each nands as nand}
    {#if !nand.ok && !on}
      <li class="nand-row">{nand}</li>
    {/if}
  {/each}
  {#each hits as hit}
    {#if hit.n > 0}
      <li class="hit-row">{hit}</li>
    {/if}
  {/each}
  {#each mores as more}
    {#if more.n > 0 && on}
      <li class="more-row">{more}</li>
    {/if}
  {/each}
  {#each lots as lot}
    {#if lot.n > 0 || on}
      <li class="lot-row">{lot}</li>
    {/if}
  {/each}
  {#each fews as few}
    {#if few.n > 0 && !on}
      <li class="few-row">{few}</li>
    {/if}
  {/each}
  {#each pairs as [x, y]}
    <li>{x}</li>
  {/each}
  <input type="checkbox" bind:indeterminate={checked} />
  <ol reversed>
    <li>One</li>
  </ol>
  <input type="email" />
  <object data="x"></object>
  <embed src="x" />
  <bdi>B</bdi><bdo dir="rtl">D</bdo>
  <q cite="#">Q</q>
  <cite>C</cite><dfn>F</dfn><var>V</var><samp>S</samp>
  <address>Ad</address>
  <data value="1">1</data>
  <b>B</b><u>U</u><s>S</s>
  <wbr />
  <div on:copy={copy} on:scroll={scroll} on:contextmenu={copy}>Box</div>
</div>
