import { isCustomError } from '@lirx/utils';
import { ERROR_WITH_DOM_CONTEXT_NAME, IErrorWithDOMContextName } from './error-with-dom-context-name.constant';
import { IErrorWithDOMContext, IErrorWithDOMContextProperties } from './error-with-dom-context.type';

export function isErrorWithDOMContext(
  value: unknown,
): value is IErrorWithDOMContext {
  return isCustomError<IErrorWithDOMContextName, IErrorWithDOMContextProperties>(
    value,
    ERROR_WITH_DOM_CONTEXT_NAME,
  );
}

