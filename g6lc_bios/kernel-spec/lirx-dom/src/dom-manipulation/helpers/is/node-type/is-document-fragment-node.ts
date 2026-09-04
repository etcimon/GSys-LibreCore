export function isDocumentFragmentNode(
  node: Node,
): node is Element {
  return node.nodeType === Node.DOCUMENT_FRAGMENT_NODE;
}

