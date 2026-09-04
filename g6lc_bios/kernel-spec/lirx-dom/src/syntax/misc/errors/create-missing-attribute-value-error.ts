import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createMissingAttributeValueError(
  attributeName: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `Missing a value for the attribute '${attributeName}'`,
    node,
  });
}
