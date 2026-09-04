import { getElementTagName } from '../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { createErrorWithDOMContext } from './error-with-dom-context/create-error-with-dom-context';

export function createLetPropertyRequiresAValueError(
  name: string,
  node: Element,
): Error {
  return createErrorWithDOMContext({
    message: `The let property '${name}' of ${getElementTagName(node)} must have a value`,
    node,
  });
}

