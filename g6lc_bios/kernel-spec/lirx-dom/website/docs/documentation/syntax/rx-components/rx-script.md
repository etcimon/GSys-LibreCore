## Inject some javascript

```html
<rx-script>
  ...js code
</rx-script>
```

To inject some javascript code into the compiled javascript output, use `rx-script`.

## Example

```html
<rx-script>
  const isLoading$ = map$$($.state$, state => (state === 'loading'));
</rx-script>
```

It's converted directly to this:

```ts
const isLoading$ = map$$($.state$, state => (state === 'loading'));
```

The DOM is untouched.

**NOTE:** when possible, always prefer to write your javascript code into your component's `typescript file` instead of using `rx-script`

### Alternative syntax

```html
<script rx>
  ...js code
</script>
```
