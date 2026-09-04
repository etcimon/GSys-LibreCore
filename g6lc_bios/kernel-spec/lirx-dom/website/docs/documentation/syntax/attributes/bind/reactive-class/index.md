# Class

```html
<div
  [class.name]="$.classEnabled$"
></div>
```

To toggle an **element's css class** whose state is updated by a [reactive value](/docs/documentation/syntax/reactive-value/) of type `boolean`, write `[class.name]`,
where `name` is the css class name your element will have if the reactive value send `true`.

It's converted to something similar to this:

```ts
toObservable($.classEnabled$)((enabled) => div.classList.toggle('name', enabled));
```

:::info

You can cumulate many `[class.name]`, and you can cumulate them too with `[class...]`.

:::

## Example

```html
<div
  [class.class-a]="single(true)"
  [class.class-b]="single(false)"
></div>
```

Output:

```html
<div
  class="class-a"
></div>
```

---

#### Alternative syntax

```html
<div
  bind-class-name="$.classEnabled$"
></div>
```

Instead of using square brackets you may prefix the class name with `bind-class-`.
