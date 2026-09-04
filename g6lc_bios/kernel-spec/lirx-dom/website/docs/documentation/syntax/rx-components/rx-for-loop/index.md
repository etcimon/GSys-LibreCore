# rx-for-loop

```html

<rx-for-loop
  items="$.items$"
  template="templateReference"
  track-by="trackByFunction"
></rx-for-loop>
```

Short syntax:

```html

<tag-name *for="let item of $.items$; index$ as i; trackBy: trackByFn">
  ...content
</tag-name>
```

This is used to create **repetitively** an element or a node, iterating over a list of values.


Under the hoods, it creates a virtual Node which:

- subscribes to `$.items$`
- and injects the template `templateReference` for each received values

:::note

This `rx-` component takes care to optimize the DOM and the rendering process (by re-using the existing nodes when possible, performing bulk DOM operations, etc...).

:::

Attributes:

- `items`: the [reactive value](/docs/documentation/syntax/reactive-value/) to listen to
- `template`: the name of the template to inject for each values
- `track-by` (optional): a trackByFunction to known which nodes may be re-used

It's converted to something similar to this:

```ts
new VirtualReactiveForLoopNode(
  $.items$,
  templateReference,
  { tackBy: trackByFunction },
).attach(parentNode);
```

## Example

```html

<div *for="let item of single(['a', 'b', 'c']); index$ as i">
  #{{ i }} : {{ item }}
</div>
```

Output:

```html

<div>
  #0 : a
</div>
<div>
  #1 : b
</div>
<div>
  #2 : c
</div>
```

---

**[Example file](https://github.com/lirx-js/dom-examples/tree/main/src/syntax/rx-for-loop/component/rx-for-loop-example.component.ts)**

### Alternative syntaxes

##### Using \*for

```html

<tag-name
  *for="let item of $.items$; index$ as i; trackBy: trackByFn"
  ...otherAttributes
>
  ...content
</tag-name>
```


<details>
  <summary>Which is equivalent to</summary>

```html

<rx-template
  name="uuid"
  let-item="item"
  let-index$="i"
>
  <tag-mame
    ...otherAttributes
  >
    ...content
  </tag-mame>
</rx-template>

<rx-for-loop
  items="$.items$"
  template="uuid"
  track-by="trackByFn"
></rx-for-loop>
```

</details>

