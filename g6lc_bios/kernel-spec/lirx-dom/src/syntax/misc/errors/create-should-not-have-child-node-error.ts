import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createShouldNotHaveChildNodesError(
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `This element should not have any child node`,
    node,
  });
}
