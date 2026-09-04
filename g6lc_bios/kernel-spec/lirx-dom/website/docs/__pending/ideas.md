
https://kaleidawave.github.io/posts/introducing-ezno/#eliminating-the-need-for-a-virtual-document-object-(vdom)



# A new kind of Virtual Document Object (VDOM)


Firstly a definition of the VDOM:

> The virtual DOM is a structure akin to the DOM.
> It is slimmer and has a subset of the API of the structures defined in the DOM JS spec e.g. HTMLElement.
> VDOM is a virtual representation of the document, actual DOM references the document (e.g. .click() isn't on VDOM structures).
> It is used to add to or update the existing actual DOM / UI.

VDOM implements declarative programming. When state changes it recreates the UI by rerunning the method with the declaration method.
This allows programming as a map state of the rather than manually adding the imperative updates to the document at every state change.

## The VDOM isn't free:

### Every update requires evaluating the UI

Every time an update to state happens, the runtime needs to rebuild the UI whole tree (at least from the parent where the change occurred).
This is necessary to find that any of the nodes have changed, but the majority of the new UI hasn't changed, and you have to create and store duplicate nodes.
The UI can require evaluating expensive calculations that often returns the existing value.

### Inferring the DOM changes cost a lots of computation

To find the updates, it uses a process named "diffing".
After a new frame has been built it has to be compared to an original frame, which requires walking these trees and comparing nodes.
This has an important computation cost, especially on large applications.
