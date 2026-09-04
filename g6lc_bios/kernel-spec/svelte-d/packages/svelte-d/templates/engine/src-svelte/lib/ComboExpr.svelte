<script lang="ts" context="module">
  export function comboExprReady() {
    return true
  }
</script>

<script lang="d">
  bool ready = true;
  bool ok = true;
  string who = "Ada";
  int wide = 0;
  void send() { }
  void go() { this.update.ready = !ready; }
</script>

<div class="combo-expr">
  {#if ready && ok}
    <p>Both</p>
  {/if}
  {#await job then v}
    <p>{v}</p>
  {/await}
  {#snippet greet(name)}
    <span>{name}</span>
  {/snippet}
  {@render greet(who)}
  {#each rows as {name}}
    <li>{name}</li>
  {/each}
  <form on:submit|preventDefault={send}>
    <label for={who}>Who</label>
    <table>
      <thead><tr><th>H</th></tr></thead>
      <tbody><tr><td>C</td></tr></tbody>
    </table>
  </form>
  <div bind:clientWidth={wide}></div>
</div>
