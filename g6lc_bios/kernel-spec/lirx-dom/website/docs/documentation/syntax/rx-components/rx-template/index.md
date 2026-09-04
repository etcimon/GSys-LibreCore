# rx-template

```html
<rx-template
  name="templateReference"
  let-var1
  let-var2
>
  ...content
</rx-template>
```

A template is a **portion of html that can be re-used later**.
This is a really important block and concept of this library,
as it is usually provided to other `rx-` components to generate repetitive or conditional parts of the application.

To create such a template, use `rx-template`.

It has the following attributes:

- `name` (required): the name of the template
- `as` (optional): creates a locale variable with the attribute's value as name pointing to the template
- `export` (optional): emits the template into an Observer
- `let-XXX`: declare a variable for this template

The interface of a template is defined in `IVirtualReactiveDOMNodeTemplate`,
and the html template is converted to something similar to this:

```ts
const template_templateReference = (
  parentNode: VirtualDOMNode,
  {
    var1,
    var2
  },
): void => {
  // here "content" represents the content of the template
  return content.attach(parentNode);
};
```

You may access your template in 3 different ways:

1) Referencing it directly from another `rx-` component - ex:

```html
<rx-if
  condition="observable$"
  true="templateReference"
></rx-if>
```

When using `rx-if`, for example, you have to specify a template.
This template **MUST** have the same name as the attribute `name` of the template.

2) Using the `export` attribute

```html
<rx-template
  name="templateReference"
  export="$.$template"
  ...
>
  ...content
</rx-template>
```

It exports the template into the Observer `$.$template`. You may receive it like this:

```ts
templateData: (node: VirtualComponentNode<HTMLElement, IComponentData>): ITemplateData => {
  const $template = (
    template: IVirtualReactiveDOMNodeTemplate<void>,
  ) => {
    // play with template
    template(node, {});
  };

  return {
    $template
  };
},
```

3) Using the `as` attribute

This creates a local variable whose name is the `as` attribute's value.

```html
<rx-template
  name="templateReference"
  as="myTemplate"
  ...
>
  ...content
</rx-template>

<some-child-component
  $[template]="myTemplate"
></some-child-component>
```

:::note

Usually, you won't have to create directly a template, as the other `rx-` components already have a way to declare such templates directly as child elements or commands.
However, in some cases it may be useful if you prefer to provide your templates to other components.

:::

:::caution

html attribute's names are case-insensitive, so the `let` properties are converted from `dash-case`
to `camelCase`. Example: `let-my-var="myNewVar"` => `{ myVar: myNewVar }`

:::
