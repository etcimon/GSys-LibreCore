import { createShouldNotHaveChildNodesError } from '../../../syntax/misc/errors/create-should-not-have-child-node-error';
import { hasChildNodes } from './has-child-nodes';

export function throwIfHasChildNodes(
  node: Element,
): void {
  if (hasChildNodes(node)) {
    throw createShouldNotHaveChildNodesError(node);
  }
}

