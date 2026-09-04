<script lang="ts" context="module">
  export function comboIfCmpReady() {
    return true
  }
</script>

<script lang="d">
  bool on = true;
  int lim = 0;
  string[] zeds = [];
  void flip() { this.update.on = !on; }
</script>

<div class="combo-if-cmp">
  <button type="button" class="ifcmp-flip" on:click={flip}>Flip</button>
  {#each gts as gt}
    {#if gt.n > 0}
      <li class="ifcmp-gt">{gt}</li>
    {/if}
  {/each}
  {#each lors as lor}
    {#if lor.n > 0 || !on}
      <li class="ifcmp-lor">{lor}</li>
    {/if}
  {/each}
  {#each eqs as eq}
    {#if eq.n == 0}
      <li class="ifcmp-eq">{eq}</li>
    {/if}
  {/each}
  {#each nes as ne}
    {#if ne.n != 0}
      <li class="ifcmp-ne">{ne}</li>
    {/if}
  {/each}
  {#each lts as lt}
    {#if lt.n < 1}
      <li class="ifcmp-lt">{lt}</li>
    {/if}
  {/each}
  {#each les as le}
    {#if le.n <= 0}
      <li class="ifcmp-le">{le}</li>
    {/if}
  {/each}
  {#each ges as ge}
    {#if ge.n >= 1}
      <li class="ifcmp-ge">{ge}</li>
    {/if}
  {/each}
  {#each gas as ga}
    {#if ga.n >= 1 && on}
      <li class="ifcmp-ga">{ga}</li>
    {/if}
  {/each}
  {#each hfs as hf}
    {#if on && hf.n > 0}
      <li class="ifcmp-hf">{hf}</li>
    {/if}
  {/each}
  {#each his as hi}
    {#if hi.n > 1}
      <li class="ifcmp-hi">{hi}</li>
    {/if}
  {/each}
  {#each nts as nt}
    {#if !(nt.n > 0)}
      <li class="ifcmp-nt">{nt}</li>
    {/if}
  {/each}
  {#each zeds as zed}
    {#if zed.n > 0}
      <li class="ifcmp-zed">{zed}</li>
    {/if}
  {/each}
  {#each vss as vs}
    {#if vs.n > lim}
      <li class="ifcmp-vs">{vs}</li>
    {/if}
  {/each}
</div>
