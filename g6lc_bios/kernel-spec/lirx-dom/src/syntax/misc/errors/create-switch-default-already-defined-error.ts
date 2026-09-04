import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createSwitchDefaultAlreadyDefinedError(
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `Switch - default already defined`,
    node,
  });
}

