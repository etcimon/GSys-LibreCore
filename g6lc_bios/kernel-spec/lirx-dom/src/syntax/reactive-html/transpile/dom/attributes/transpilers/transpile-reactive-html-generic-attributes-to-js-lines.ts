import { nullIfEmptyLines } from '../../../../../misc/lines/functions/null-if-empty-lines';
import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLAttributeToJSLines } from '../../attribute/transpile-reactive-html-attribute-to-js-lines';

export interface ITranspileReactiveHTMLGenericAttributesToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly attributes: ArrayLike<Attr>;
}

export function transpileReactiveHTMLGenericAttributesToJSLines(
  {
    attributes,
    ...options
  }: ITranspileReactiveHTMLGenericAttributesToJSLinesOptions,
): ILinesOrNull {
  const lines: ILines = [];
  for (let i = 0, l = attributes.length; i < l; i++) {
    const result: ILinesOrNull = transpileReactiveHTMLAttributeToJSLines({
      ...options,
      attribute: attributes[i],
    });
    if (result !== null) {
      lines.push(...result);
    }
  }
  return nullIfEmptyLines(lines);
}

