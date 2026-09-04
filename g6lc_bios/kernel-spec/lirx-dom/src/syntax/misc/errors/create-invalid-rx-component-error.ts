import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createInvalidRXComponentError(
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `Found invalid rx-component`,
    node,
  });
}

