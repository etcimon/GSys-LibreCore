import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createMissingAttributeError(
  attributeName: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `Missing attribute '${attributeName}'`,
    node,
  });
}
