<script lang="ts" context="module">
  export function bindingsReady() {
    return true
  }
</script>

<script lang="d">
  // libwasm.bindings — Handle table {1:document, 2:window}.
  // import libwasm already public-imports Document, Window, Console.

  string docTitle()
  {
    return document().title();
  }

  string winPath()
  {
    return window().location().pathname();
  }

  void logInfo(string msg)
  {
    console.info(msg);
  }

  Handle documentHandle()
  {
    return document().handle;
  }
</script>

<p class="px-4 text-sm opacity-70">libwasm bindings demo (lang=d)</p>
