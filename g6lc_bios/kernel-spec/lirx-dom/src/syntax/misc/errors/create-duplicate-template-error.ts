import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createDuplicateTemplateError(
  templateName: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `The template '${templateName}' is already defined`,
    node,
  });
}
