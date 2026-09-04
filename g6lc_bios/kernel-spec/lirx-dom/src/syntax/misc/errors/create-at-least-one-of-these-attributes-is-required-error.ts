import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createAtLeastOneOfTheseAttributesIsRequiredError(
  attributNames: readonly string[],
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `At least one of these attributes is required: ${attributNames.map(_ => `'${_}'`).join(', ')}`,
    node,
  });
}
