<script lang="ts" context="module">
  export function comboMiscReady() {
    return true
  }
</script>

<script lang="d">
  int n = 1;
  string tone = "navy";
  Handle files;
  void drag() { }
  void bump() { this.update.n = n + 1; }
</script>

<div class="combo-misc">
  {#if n > 0}
    <p>Pos</p>
  {/if}
  <input type="file" bind:files />
  <input type="range" min="0" max="10" />
  <input list="dl" />
  <datalist id="dl"><option>A</option></datalist>
  <output>Out</output>
  <ruby>漢<rt>kan</rt></ruby>
  <map name="m"><area alt="x" href="#" /></map>
  <video><track kind="captions" /></video>
  <table>
    <caption>Cap</caption>
    <colgroup><col /></colgroup>
    <tfoot><tr><td>F</td></tr></tfoot>
  </table>
  <template><p>Tmpl</p></template>
  <abbr title="Hypertext">HTML</abbr>
  <p style:--accent={tone}>Var</p>
  <div on:dragstart={drag}>Drag</div>
</div>
