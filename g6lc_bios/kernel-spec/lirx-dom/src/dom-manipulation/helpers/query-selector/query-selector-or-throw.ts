/**
 * Similar to querySelector, but throws if an element is not found
 */
export function querySelectorOrThrow<GElement extends HTMLElement>(
  node: Element,
  selector: string,
): GElement {
  const selectedNode: GElement | null = node.querySelector<GElement>(selector);
  if (selectedNode === null) {
    throw new Error(`Failed to select element`);
  } else {
    return selectedNode;
  }
}
