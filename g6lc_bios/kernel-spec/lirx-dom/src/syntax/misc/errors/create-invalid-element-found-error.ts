import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createInvalidElementFoundError(
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `Found invalid element`,
    node,
  });
}
