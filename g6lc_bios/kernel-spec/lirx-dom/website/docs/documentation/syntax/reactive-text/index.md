# Text

```html
{{ $.text$ }}
```

To create a **text Node** whose content is updated by a [reactive value](/docs/documentation/syntax/reactive-value/) of type `string`, put this value in double curly brackets, `{{}}`.

It's converted to something similar to this:

```ts
toObservable($.text$)((value) => text.value = value);
```


## Example

```html
<div>
  Hello {{ single('world') }} !
</div>
```

Output:

```html
<div>
  Hello world !
</div>
```

---

**[Example file](https://github.com/lirx-js/dom-examples/tree/main/src/syntax/reactive-text/component/reactive-text-example.component.ts)**
