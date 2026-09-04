import { isHTMLElementFocusable } from '../is/html-element/state/is-html-element-focusable';

export function* focusableHTMLElementsIterable(
  parentElement: HTMLElement,
): Generator<HTMLElement> {
  if (parentElement.firstChild !== null) {
    const treeWalker: TreeWalker = document.createTreeWalker(parentElement, NodeFilter.SHOW_ELEMENT);
    let element: HTMLElement | null;
    while (element = treeWalker.nextNode() as HTMLElement | null) {
      if (isHTMLElementFocusable(element)) {
        yield element;
      }
    }
  }
}
