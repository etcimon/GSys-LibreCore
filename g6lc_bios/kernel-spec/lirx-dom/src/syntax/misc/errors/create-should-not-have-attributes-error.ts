import { getElementTagName } from '../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createShouldNotHaveAttributesError(
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `${getElementTagName(node)} should not have any attributes`,
    node,
  });
}

