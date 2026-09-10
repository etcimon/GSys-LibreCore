<!--
  Example: a session iframe between two paragraphs in the BIOS setup tree.
  Same g6b-iframe controller as a tab; no window chrome. Not App.svelte.
-->
<script>
  let url = "/ui/help.html";
</script>

<main id="ex-article">
  <p id="ex-before">Before the nested session.</p>
  <iframe id="ex-inline-frame" src="/ui/help.html" width="320" height="120" title="session"></iframe>
  <p id="ex-after">After the nested session.</p>
</main>
