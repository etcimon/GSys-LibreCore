<script lang="ts" context="module">
  export function comboCoverReady() {
    return true
  }
</script>

<script lang="d">
  string[] extras = ["one", "two"];
  string[] voids;
  string note = "hi";
  string pick = "a";
  bool ok = false;
  bool open = false;
  Handle files;
  JsPromise!Any job;
  JsPromise!Any other;
  void wipe() { extras = []; }
  void go() { this.update.await_then = true; }
  void fail() { this.update.await_catch = true; }
  void setNote() { this.update.note = "yo"; }
</script>

<div class="combo-cover">
  <button type="button" class="cover-wipe" on:click={wipe}>Wipe</button>
  <button type="button" class="cover-go" on:click={go}>Go</button>
  <button type="button" class="cover-fail" on:click={fail}>Fail</button>
  <button type="button" class="cover-note" on:click={setNote}>Note</button>
  <ul class="cover-extras">
    {#each extras as extra}
      <li class="else-extra">{extra}</li>
    {:else}
      <p class="else-empty">Empty</p>
    {/each}
  </ul>
  {#each voids as v}
    <li class="else-void">{v}</li>
  {:else}
    <p class="else-none">None</p>
  {/each}
  {#await job}
    <p class="await-pend">Wait</p>
  {:then v}
    <p class="await-then">{v}</p>
  {:catch e}
    <p class="await-catch">{e}</p>
  {/await}
  {#await other}
    <p class="await2-pend">Wait2</p>
  {:then v}
    <p class="await2-then">{v}</p>
  {:catch e}
    <p class="await2-catch">{e}</p>
  {/await}
  <input class="bind-note" bind:value={note} />
  <span class="bind-note-out">{note}</span>
  <input type="checkbox" class="bind-ok" bind:checked={ok} />
  <span class="bind-ok-out" class:on={ok}>ok</span>
  <details class="bind-open" bind:open={open}><summary>More</summary></details>
  <select class="bind-pick" bind:value={pick}>
    <option value="a">A</option>
    <option value="b">B</option>
  </select>
  <span class="bind-pick-out">{pick}</span>
  <input type="radio" class="bind-group-a" bind:group={pick} value="a" />
  <input type="radio" class="bind-group-b" bind:group={pick} value="b" />
  <input type="file" class="bind-files" bind:files={files} />
</div>
