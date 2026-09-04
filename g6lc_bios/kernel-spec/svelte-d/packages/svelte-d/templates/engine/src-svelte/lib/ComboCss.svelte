<script lang="ts" context="module">
  export function comboCssReady() {
    return true
  }
</script>

<script lang="d">
  string tag = "article";
  string tone = "navy";
  string rest = "x";
  Handle extra;
</script>

<style>
  .box { color: navy; }
  .on { font-weight: bold; }
</style>

<div class="combo-css">
  <svelte:element this={tag} class="box" {...rest} {...extra}>
    <p style:color={tone} style:background|important={tone}>Paint</p>
  </svelte:element>
</div>
