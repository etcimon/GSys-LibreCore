import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createInvalidSlotNameError(
  slotName: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `Found invalid slot name ${slotName}`,
    node,
  });
}

