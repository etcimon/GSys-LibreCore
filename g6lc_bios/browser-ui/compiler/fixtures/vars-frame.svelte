<!--
  Example: Svelte passes a parent JS map into the iframe as `vars={frameVars}`.
  Nested page JS reads each key from its env. Applies on remote too (fail-closed
  fetch; bindings still intern). Not App.svelte.
-->
<script>
  let greeting = "hello";
</script>

<main id="ex-vars-ui">
  <p id="ex-vars-before">Parent copy.</p>
  <iframe id="ex-vars-frame" src="https://example/path" vars={frameVars} width="320" height="120" title="session"></iframe>
  <p id="ex-vars-after">Still parent.</p>
</main>
