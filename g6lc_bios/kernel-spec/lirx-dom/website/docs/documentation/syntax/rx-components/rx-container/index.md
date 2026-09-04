# rx-container

```html
<rx-container>
  ...content
</rx-container>
```

An `rx-container` is a **transparent wrapper** to group many nodes or elements, with usually one or many specific `*commands`: like an `*if` or a `*for`.

## Example

```html
<div class="list-for-names">
  List of names:

  <rx-container
    *for="let item of of('Alice', 'Bob', 'Carol')"
  >
    {{ single(item) }},
  </rx-container>
</div>
```

Output:

```html
<div class="list-for-names">
  List of names: Alice, Bob, Carol
</div>
```

:::note

As you may see there's no element around the generated text nodes.
The `rx-container` is fully transparent and doesn't create an element as a container.

:::

