/** @type {import('@sveltejs/kit').Config | Record<string, unknown>} */
const config = {
  // Official svelte LS / svelte-check parse lang=ts. lang=d is libwasm IR —
  // blank it so the IDE does not try to parse D as TypeScript.
  preprocess: {
    script: ({ content, attributes }) => {
      if (attributes.lang === 'd') {
        return { code: '/* libwasm D — compiled by svelte-d into src-d/ */\n' }
      }
      return { code: content }
    },
  },
}

export default config
