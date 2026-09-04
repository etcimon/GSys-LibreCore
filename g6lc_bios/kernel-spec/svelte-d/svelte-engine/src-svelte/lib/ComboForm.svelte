<script lang="ts" context="module">
  export function comboFormReady() {
    return true
  }
</script>

<script lang="d">
  string note = "hi";
  string pick = "a";
  string html = "<b>x</b>";
  bool open = false;
  bool on = true;
  void save() { }
  void tap() { }
</script>

<div class="combo-form">
  <textarea bind:value={note}></textarea>
  <select bind:value={pick}>
    <option value="a">A</option>
    <option value="b">B</option>
  </select>
  <div contenteditable="true" bind:innerHTML={html}></div>
  <details bind:open={open}><summary>More</summary></details>
  <button type="button" disabled class:on on:click|once={save} on:keydown={tap}>Go</button>
</div>
