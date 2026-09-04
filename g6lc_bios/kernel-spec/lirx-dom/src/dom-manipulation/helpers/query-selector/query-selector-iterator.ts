import { elementMatches } from './element-matches';

/**
 * Creates an iterator, returning the child elements of "parentNode" matching "selector"
 * Similar to parentNode.querySelectorAll
 */
export function* querySelectorIterator<GElement extends Element>(
  parentNode: Node,
  selector: string,
): Generator<GElement> {
  if (parentNode.firstChild !== null) {
    const treeWalker: TreeWalker = document.createTreeWalker(parentNode, NodeFilter.SHOW_ELEMENT);
    let node: Element | null;
    while (node = treeWalker.nextNode() as Element | null) {
      if (elementMatches(node, selector, { scope: parentNode })) {
        yield node as GElement;
      }
    }
  }
}
