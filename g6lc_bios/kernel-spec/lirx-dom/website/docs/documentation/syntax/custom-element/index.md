# Custom Components

A *Component* is equivalent to an Element, but it has its own template, style, properties, and interactions.

To append a custom component into the DOM, simply write its tag name:

```html
<app-component></app-component>
```

However, **do not forget to declare** and import the component when compiling the template:

```ts
template: compileReactiveHTMLAsComponentTemplate({
  html,
  customElements: [
    AppComponent,
  ],
}),
```

Then, like any other elements, we can [bind properties](/docs/documentation/syntax/attributes/bind/reactive-property/),
[listen to events](/docs/documentation/syntax/attributes/event/event-listener/),
[use special commands](/docs/documentation/syntax/rx-components/rx-if/), etc :

```html
<app-component
  *if="$.condition$"
  [tabIndex]="$.tabIndex$"
  (click)="$.$onClick"
></app-component>
```

Moreover, the custom components additionally support [inputs](/docs/documentation/syntax/attributes/bind/reactive-input/)
and [outputs](/docs/documentation/syntax/attributes/event/reactive-output/):

```html
<app-component
  $[in]="$.in$"
  $(out)="$.$out"
></app-component>
```

## Slotting - ak provide templates to our components

Occasionally, we'll find some components **requiring html content**.
They'll usually use and inject this content somewhere else in their personal template.

We may think about an `<app-article>` component, requiring a header and a body,
both being html content provided by the parent on the creation of `<app-article>`.

Such an action is called **slotting**.

This is a little complex to explain, but really easy to use:

> A **slot** is simply an HTML template **with a specific name**, provided to a component.
> Many slots having different names may be given to a child component.
> Then, this child component may use the slots in its own template.

### Named slot

So, let's begin with a simple example:

```html title="parent/parent.component.html"
<app-child>
  <rx-slot name="header">
    My article title
  </rx-slot>
  <rx-slot name="body">
    Hello world !
  </rx-slot>
</app-child>
```

Here, we've created the slots `header` and `body`, using the special component `rx-slot`.
It is only available as a child of a custom component, and it accepts a `name` attribute used to set the name of the slot.

Then, these slots are transmitted to the component `<app-child>`, and may be used directly from its template using `rx-inject-slot`:

```html title="child/child.component.html"
<article>
  <header>
    <rx-inject-slot name="header">
      No title
    </rx-inject-slot>
  </header>
  <p>
    <rx-inject-slot name="body"></rx-inject-slot>
  </p>
  <footer>
    <rx-inject-slot name="footer">
      No footer
    </rx-inject-slot>
  </footer>
</article>
```

An `rx-inject-slot` may contain some HTML in it. It is used as a placeholder if the parent didn't provide a slot with the corresponding name.
In our case, we omitted the `footer` slot, so `No footer` will be displayed as a replacement.

We may swap the `rx-inject-slot` syntax with the command `*inject-slot="name"`, which is usually more convenient:

```html title="child/child.component.html"
<article>
  <header *inject-slot="header">
    No title
  </header>
  <p *inject-slot="body"></p>
  <footer *inject-slot="footer">
    No footer
  </footer>
</article>
```

If we recapitulate, in our example, the resulting HTML will be:

```html title="OUTPUT"
<app-child>
  <article>
    <header>
      My article title
    </header>
    <p>
      Hello world !
    </p>
    <footer>
      No footer
    </footer>
  </article>
</app-child>
```

### Default slot

Any HTML written inside a custom component, but outside a `rx-slot` is appended to the default slot called `*`:

```html title="parent/parent.component.html"
<app-child>
  <rx-slot name="header">
    Im slotted
  </rx-slot>
  Im not, so instead I belong to the '*' slot
</app-child>
```

```html title="child/child.component.html"
<article>
  <header *inject-slot="header"></header>
  <p *inject-slot="*"></p>
</article>
```

```html title="OUTPUT"
<app-child>
  <article>
    <header>
      Im slotted
    </header>
    <p>
      Im not, so instead I belong to the '*' slot
    </p>
  </article>
</app-child>
```

However, **we do not recommend to mix named slots with the default slot** on the same component.
It tends to confuse everyone.


The previous illustration serves purely as an example and should be avoided.
The default slot will mostly be used with components requiring only one slot:

```html title="parent/parent.component.html"
<app-super-button>
  Hello world !
</app-super-button>
```


```html title="child/child.component.html"
<button>
  <icon></icon>
  <span *inject-slot="*"></span>
</button>
```


```html title="OUTPUT"
<app-super-button>
  <button>
    <icon></icon>
    <span>Hello world !</span>
  </button>
</app-super-button>
```

In consequence:

- if you have just one slot, use the default slot
- if you have many slots, use only named slots


### Providing variables to the slots

As explained earlier, the slots are just HTML template similar to **[rx-template](/docs/documentation/syntax/rx-components/rx-template/)**.
In consequence, we may declare variables for our slots and set them later in the child component:


```html title="parent/parent.component.html"
<app-child>
  <rx-slot
    name="content"
    let-data="data"
  >
    {{ data }}
  </rx-slot>
</app-child>
```

We declare these variables using the prefix `let-` followed by the variable name.

:::note

html attribute's names are case-insensitive, so the `let` properties are converted from `dash-case`
to `camelCase`. Example: `let-my-var="myNewVar"` => `{ myVar: myNewVar }`

:::

Then, we may set these *let properties* when injecting the slot from the child component:


```html title="child/child.component.html"
<article>
  <rx-inject-slot
    name="content"
    let-data="$.childData$"
  ></rx-inject-slot>
</article>
```

### Proxying a slot - ak transfer a slot to a child component

Sometimes, we have to provide a slot to a child component, which contains a slot coming from the parent component:

```html title="child/child.component.html"
<article>
  <app-sub-child>
    <rx-slot name="header">
      <rx-inject-slot name="header"></rx-inject-slot>
    </rx-slot>
  </app-sub-child>
</article>
```

Here the `<app-child>` component provides to the component `<app-sub-child>` its own slot with the name `header`.

This is usually done to transfer a slot to a child component requiring it.

In this case, we may use the attribute `proxy` as a shortcut:

```html title="child/child.component.html"
<article>
  <app-sub-child>
    <rx-slot proxy="header"></rx-slot>
  </app-sub-child>
</article>
```

It shares the slot `header` with `<app-sub-child>`.

### Playing with slots from the ts file

:::caution

Playing with slots, as well as DOM manipulations, from the `.ts` file is not recommended.
You should always prefer to write a proper `reactive-html` template.

:::

When defining a child component, it's possible to access the different slots using the property `slots` on the incoming `node` of the `init` function:

```ts
export const AppChildComponent = new Component<HTMLElement, object, void>({
  name: 'app-child',
  template,
  templateData: (node: VirtualCustomElementNode<HTMLElement, object>): void => {
    const bodySlot: IVirtualCustomElementNodeSlotTemplate | undefined = node.slots.get('body');
    if (bodySlot !== void 0) {
      bodySlot(node, {}); // create and append bodySlot into this node
    }
  },
});
```

However, it should be reversed for advanced users only.


[//]: # (TODO example files)

