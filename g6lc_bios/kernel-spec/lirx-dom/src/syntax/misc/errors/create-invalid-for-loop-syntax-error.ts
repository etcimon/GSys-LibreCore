import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createInvalidForLoopSyntaxError(
  message: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message,
    node,
  });
}

