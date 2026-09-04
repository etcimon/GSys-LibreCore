import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { createInvalidRXComponentError } from '../../../../../../misc/errors/create-invalid-rx-component-error';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';

/*
Syntax:

<rx-...
>
</rx-...>

 */

const TAG_NAME: string = 'rx-';

export interface ITranspileReactiveHTMLRXUnknownToLinesOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXUnknownToLines(
  {
    node,
  }: ITranspileReactiveHTMLRXUnknownToLinesOptions,
): ILinesOrNull {
  const name: string = getElementTagName(node);
  if (name.startsWith(TAG_NAME)) {
    throw createInvalidRXComponentError(node);
  } else {
    return null;
  }
}
