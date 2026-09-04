# rx-switch

```html
<rx-switch expression="$.expression$">
  <rx-switch-case
    case="valueA"
    template="templateReferenceA"
  ></rx-switch-case>
  <rx-switch-case
    case="valueB"
    template="templateReferenceB"
  ></rx-switch-case>
  <rx-switch-default
    template="templateReferenceC"
  ></rx-switch-default>
</rx-switch>
```

Short syntax:

```html
<rx-switch expression="$.expression$">
  <div *switch-case="valueA">
    value A
  </div>
  <div *switch-case="valueB">
    value B
  </div>
  <div *switch-default>
    default
  </div>
</rx-switch>
```

This is used to display **conditionally** an element or a node, **switching** on a specific value.

Under the hoods, it creates a virtual Node which:

- subscribes to `$.expression$`
- and injects `templateReferenceA`, `templateReferenceB` or `templateReferenceC` according to the received value

:::note

The previously injected template is always removed from the DOM before the new one is appended.

:::

Attributes:

- rx-switch
  - `expression`: the [reactive value](/docs/documentation/syntax/reactive-value/) to listen to
- rx-switch-case
  - `case`: the value for this template
  - `template`: the template reference to inject
- rx-switch-default
  - `template`: the template reference to inject

:::note

You may omit `rx-switch-default`.

:::

It's converted to something similar to this:

```ts
new VirtualReactiveSwitchNode(
  $.expression$,
  new Map([
    [valueA, templateReferenceA],
    [valueB, templateReferenceB],
  ]),
  templateReferenceC,
).attach(parentNode);
```

## Example

```html
<rx-switch expression="single('done')">
  <div *switch-case="'pending'">
    Pending...
  </div>
  <div *switch-case="'done'">
    Done !
  </div>
</rx-switch>
```

Output:

```html
<div>
  Done !
</div>
```

---

**[Example file](https://github.com/lirx-js/dom-examples/tree/main/src/syntax/rx-switch/component/rx-switch-example.component.ts)**

### Alternative syntaxes

##### Using \*switch-case and \*switch-default

```html
<rx-switch expression="$.expression$">
  <tag-name-a
    *switch-case="valueA"
    ...otherAttributesA
  >
    ...contentA
  </tag-name-a>
  <tag-name-b
    *switch-case="valueB"
    ...otherAttributesB
  >
    ...contentB
  </tag-name-b>
  <tag-name-c
    *switch-default
    ...otherAttributesC
  >
    ...contentC
  </tag-name-c>
</rx-switch>
```

<details>
  <summary>Which is equivalent to</summary>

```html
<rx-template
  name="uuidA"
>
  <tag-mame-a
    ...otherAttributesA
  >
    ...contentA
  </tag-mame-a>
</rx-template>

<rx-template
    name="uuidB"
>
  <tag-mame-b
    ...otherAttributesB
  >
    ...contentB
  </tag-mame-b>
</rx-template>

<rx-template
  name="uuidC"
>
  <tag-mame-c
    ...otherAttributesC
  >
    ...contentC
  </tag-mame-c>
</rx-template>

<rx-switch
  expression="$.expression$"
>
  <rx-switch-case
    case="valueA"
    template="uuidA"
  ></rx-switch-case>
  <rx-switch-case
    case="valueB"
    template="uuidB"
  ></rx-switch-case>
  <rx-switch-default
    template="uuidC"
  ></rx-switch-default>
</rx-switch>
```

</details>


##### Using rx-switch-case and rx-switch-default with in-place template

```html
<rx-switch expression="$.expression$">
  <rx-switch-case case="valueA">
    ...contentA
  </rx-switch-case>
  <rx-switch-case case="valueB">
    ...contentB
  </rx-switch-case>
  <rx-switch-default>
    ...contentC
  </rx-switch-default>
</rx-switch>
```
