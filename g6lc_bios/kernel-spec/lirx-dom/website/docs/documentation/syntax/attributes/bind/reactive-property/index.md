# Property

```html
<div
  [prop]="$.property$"
></div>
```

To update an **element's property** whose value is updated by a [reactive value](/docs/documentation/syntax/reactive-value/), enclose it in square brackets, `[]`.
When the right-hand side (the reactive value), emits a value, the property is set with this value. 

It's converted to something similar to this:

```ts
toObservable($.property$)((value) => div.prop = value);
```


## Example

```html
<div
  [innerHTML]="single('<strong>abc</strong>')"
></div>
```

Output:

```html
<div><strong>abc</strong></div>
```

---

#### Alternative syntax

```html
<div
  bind-prop="$.property$"
></div>
```

Instead of using square brackets you may prefix the property with `bind-`.

