# rx-inject-template

```html
<rx-inject-template
  template="templateReference"
  let-var1="data1"
  let-var2="data2"
></rx-inject-template>
```

To inject a template, use `rx-inject-template`.

It has the following attributes:

- `template`: the name of the template to inject
- `let-XXX`: the variables to provide to this template

It's converted to something similar to this:

```ts
templateReference(
  parentNode,
  {
    var1: data1,
    var2: data2,
  },
);
```

:::note

Usually, you won't have to inject directly a template, as the other `rx-` components already have a way to declare and inject such templates.
However, in some cases it may be useful if you prefer to inject your templates with names.

:::

## Example

```html
<rx-template
  name="helloTemplate"
  let-name
>
  Hello {{ name }}!
</rx-template>

<div class="main-container">
  <rx-inject-template
    template="helloTemplate"
    let-name="single('Alice')"
  ></rx-inject-template>
</div>
```

Output:

```html
<div class="main-container">
  Hello Alice!
</div>
```

---

**[Example file](https://github.com/lirx-js/dom-examples/tree/main/src/syntax/rx-inject-template/component/rx-inject-template-example.component.ts)**

