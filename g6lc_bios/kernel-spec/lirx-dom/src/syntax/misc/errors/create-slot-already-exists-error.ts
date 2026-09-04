import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createSlotAlreadyExistsError(
  slotName: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `The slot '${slotName}' is already defined`,
    node,
  });
}
