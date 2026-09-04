import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createInvalidAttributeFoundError(
  node: Attr,
): Error {
  return createErrorWithDOMContext({
    message: `Found invalid attribute '${node.name}'`,
    node,
  });
}
