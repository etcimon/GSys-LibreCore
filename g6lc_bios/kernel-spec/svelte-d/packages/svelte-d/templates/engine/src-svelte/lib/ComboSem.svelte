<script lang="ts" context="module">
  export function comboSemReady() {
    return true
  }
</script>

<script lang="d">
  bool ready = true;
  bool ok = true;
  string who = "Ada";
  string extra = "x";
  Handle field;
  double amt = 1.5;
  void ping() { }
  void ch() { }
</script>

<div class="combo-sem">
  {#if (ready && ok)}
    <p>Both</p>
  {/if}
  {#if who == extra}
    <p>Eq</p>
  {/if}
  {#snippet pair(a, b)}
    <span>{a}</span><i>{b}</i>
  {/snippet}
  {@render pair(who, extra)}
  <ClickField bind:this={field} />
  <input type="number" bind:value={amt} />
  <input type="color" />
  <article>
    <header><h1>H</h1></header>
    <nav>N</nav>
    <main>
      <section>
        <figure><figcaption>Cap</figcaption></figure>
        <pre><code>C</code></pre>
        <blockquote>Q</blockquote>
        <dl><dt>T</dt><dd>D</dd></dl>
      </section>
    </main>
    <aside>A</aside>
    <footer>
      <small>s</small><sub>1</sub><sup>2</sup>
      <mark>m</mark><kbd>k</kbd>
      <ins>i</ins><del>x</del>
    </footer>
  </article>
  <hr />
  <br />
  <noscript>No</noscript>
  <button type="button" on:pointerdown={ping} on:focus={ping} on:change={ch} on:wheel={ping} on:touchstart={ping}>Go</button>
</div>
