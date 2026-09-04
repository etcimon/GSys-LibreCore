import { isTextNode } from './is-text-node';

export function isTextNodeWithNonWhiteSpaceCharacters(
  node: Node,
): node is Text {
  return isTextNode(node)
    && (node.data.trim() !== '');
}

