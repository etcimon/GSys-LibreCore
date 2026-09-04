import { getElementTagName } from '../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createShouldNotContainTextNodeError(
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `The content of ${getElementTagName(node)} should not contain any Text Node`,
    node,
  });
}

