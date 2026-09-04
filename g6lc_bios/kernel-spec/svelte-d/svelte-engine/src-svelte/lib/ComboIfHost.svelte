<script lang="ts" context="module">
  export function comboIfHostReady() {
    return true
  }
</script>

<script lang="d">
  bool on = true;
  bool hide = false;
  bool flag = true;
  int n = 1;
  string who = "a";
  string extra = "a";
  void flip() { this.update.on = !on; }
</script>

<div class="combo-if-host">
  <button type="button" class="ifhost-flip" on:click={flip}>Flip</button>
  {#if on}
    <span class="ifhost-on">on</span>
  {/if}
  {#if !on}
    <span class="ifhost-not">not</span>
  {/if}
  {#if on && !hide}
    <span class="ifhost-and">and</span>
  {/if}
  {#if flag || on}
    <span class="ifhost-or">or</span>
  {/if}
  {#if n > 0}
    <span class="ifhost-gt">gt</span>
  {/if}
  {#if who == extra}
    <span class="ifhost-eq">eq</span>
  {/if}
</div>
