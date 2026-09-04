# Modifier

---

:::info

The purpose of a Modifier is to **modify** directly a **[VirtualDOMNode](/docs/reference/virtual-dom-node/)**.

In consequence, it's a **powerful tool to use with caution**. 
Simple operations like setting a style on the element or listening to events are relatively safe,
but mutating the DOM (appending/moving/deleting nodes or setting attributes/properties for example) is unsafe.
It could result in conflicts between the modifiers, unwanted DOM mutation, or uncontrolled effects.

Thus, it's sometimes better to use **wrapper component** instead of a modifier.


:::

---

Now that you've been warned, let's get into the topic:

### Definition

```ts
interface IVirtualDOMNodeModifier<GValue, GNode extends VirtualDOMNode> {
  readonly name: string;
  readonly apply: IVirtualDOMNodeModifierFunction<GValue, GNode>;
  readonly weight: number;
}
```

A modifier has a `name`, an `apply` function, and a `weight`.

When the `reactive html` is executed, the modifiers present on an element are sorted by weights,
and their `apply` functions are called from the lowest weight (first) to the highest weight (last).

The role of this `apply` function is to **modify** directly a `VirtualDOMNode`.


```ts
interface IVirtualDOMNodeModifierFunction<GValue, GNode extends VirtualDOMNode> {
  (
    node: VirtualDOMNode,
    value: GValue,
  ): GNode;
}
```

It receives two arguments:

- a `VirtualDOMNode`: this is the node being modified by this modifier. We can change its contents, its properties, its attributes, etc...
- a `value`: usually used as a config object for the modifier.

Then, we have to return a `VirtualDOMNode`. It can be the input `node` or a new one.

:::caution

Returning a different `VirtualDOMNode` is a very risky operation as we are swapping the current node with a new one.
It should be used **only if you master** the modifiers and perfectly now what you are doing.

:::


### Creation

#### createVirtualDOMNodeModifier

To create a `IVirtualDOMNodeModifier`, we may use the function `createVirtualDOMNodeModifier`.

<details>
  <summary>Definitions</summary>

```ts
function createVirtualDOMNodeModifier<GValue, GNode extends VirtualDOMNode>(
  name: string,
  apply: IVirtualDOMNodeModifierFunction<GValue, GNode>,
  options?: ICreateVirtualDOMNodeModifierOptions,
): IVirtualDOMNodeModifier<GValue, GNode>
```

```ts
interface ICreateVirtualDOMNodeModifierOptions {
  readonly weight?: number; // (default: 0)
}
```

</details>

##### Example

```ts
const TooltipModifier = createVirtualDOMNodeModifier('tooltip', (node: VirtualDOMNode, value: string): VirtualDOMNode => {
  if (node instanceof VirtualCustomElementNode) {
    node.elementNode.title = value;
  }
  return node;
});
```

#### createVirtualReactiveElementNodeModifier

Usually we'll prefer `createVirtualReactiveElementNodeModifier` as we mostly play with a [VirtualReactiveElementNode](/docs/reference/virtual-reactive-element-node/) instead of a `VirtualDOMNode`.

<details>
  <summary>Definitions</summary>

```ts
function createVirtualReactiveElementNodeModifier<GValue, GNode extends VirtualDOMNode>(
  name: string,
  apply: IVirtualReactiveElementNodeModifierFunction<GValue, GNode>,
  options?: ICreateVirtualReactiveElementNodeModifierOptions,
): IVirtualDOMNodeModifier<GValue, GNode>
```

```ts
interface IVirtualReactiveElementNodeModifierFunction<GValue, GNode extends VirtualDOMNode> {
  (
    node: IGenericVirtualReactiveElementNode,
    value: GValue,
  ): GNode;
}
```

</details>

##### Example

```ts
const TooltipModifier = createVirtualReactiveElementNodeModifier('tooltip', (node: VirtualCustomElementNode, value: string): VirtualDOMNode => {
  node.elementNode.title = value;
  return node;
});
```


### Syntax

```html
<div
  #name="value"
></div>
```

To use a modifier write `#name`, where `name` is the name of the modifier, and the right-hand side is the value to provide to this modifier.

#### Weight

It's possible to override the modifier's weight from the `reactive html`:

```html
<div
  #5-name="value"
></div>
```

In this example, the modifier `name` has a weight of `5`.
If this weight is not specified, then the modifier's weight is taken.

:::note

Weights have been introduced because [html attributes are not ordered](https://developer.mozilla.org/en-US/docs/Web/API/Element/attributes#:~:text=the%20Attr%20nodes,among%20browsers).

They should be used only if the modifiers require to be executed in a specific order.
This is a very rare case, and you should always prefer to create modifiers that could be executed in any order without impacting the others.


:::

<details>
  <summary>Negative weights</summary>

Negative weights are supported too:

```html
<div
  #-5-name="value"
></div>
```

</details>


### Example

First we have to create our modifier:

```ts title="tooltip.modifier.ts"
const TooltipModifier = createVirtualReactiveElementNodeModifier('tooltip', (node: VirtualCustomElementNode, value: string): VirtualDOMNode => {
  node.elementNode.title = value;
  return node;
});
```

Then we use it into the template:

```html title="app.component.html"
<div #tooltip="'hello world !'">
  Some content
</div>
```

And we don't forget to import it:

```ts title="app.component.ts"
compileReactiveHTMLAsComponentTemplate({
  html,
  modifiers: [
    TooltipModifier,
  ],
});
```

#### What happens in the template ?

It is converted to something similar to this:

```ts
// here 'node' is the div
const newNode = applyNodeModifier('tooltip', node, 'hello world !');
```

Which expands to:

```ts
const newNode = ((node: VirtualDOMNode, value: string): VirtualDOMNode => {
  if (node instanceof VirtualCustomElementNode) {
    node.elementNode.title = value;
  }
  return node;
})(element, 'hello world !');
```

---

#### Alternative syntax

```html
<div
  mod-name="value"
></div>
```

Instead of prefixing it with `#` you may prefix it with `mod-`.


