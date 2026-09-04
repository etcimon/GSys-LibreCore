import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createShouldNotHaveAttributeValueError(
  attributeName: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `The attribute '${attributeName}' should not have any value`,
    node,
  });
}
