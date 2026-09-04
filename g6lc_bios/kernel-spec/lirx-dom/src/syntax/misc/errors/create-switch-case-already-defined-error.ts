import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createSwitchCaseAlreadyDefinedError(
  caseValue: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `Switch - case '${caseValue}' already defined`,
    node,
  });
}

