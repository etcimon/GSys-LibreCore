# Reactive HTML

`@lirx/dom` comes with an HTML like syntax which is used as templates for the components.
This special syntax is usually called `reactive html`, is close to the Angular template syntax, and is based on Observables.

This template language gives us the possibility to easily manipulate the DOM using special tags and attributes.
It doesn't require to be precompiled (as opposed to JSX or SolidJS for example).
However, by design, it perfectly supports this option though an [AOT compiler](/docs/documentation/aot-compiler/), greatly improving the performances.

To convert some `reactive html` to executable javascript, and usable by our components, we have to use the function 
[compileReactiveHTMLAsComponentTemplate](/docs/reference/compile-reactive-html-as-component-template/).
**This section is only about the syntax of the template.**
It won't explain how to create components nor use or interact with the template.
If you need more details on this particular topic, I invite you to read [this tutotial](/docs/documentation/component/component/).


