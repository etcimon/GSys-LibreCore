import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLAttributesToJSLines } from '../../../../attributes/transpile-reactive-html-attributes-to-js-lines';

export interface ITranspileReactiveHTMLGenericElementAttributesToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLGenericElementAttributesToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLGenericElementAttributesToJSLinesOptions,
): ILines {
  const transpiledAttributes: ILinesOrNull = transpileReactiveHTMLAttributesToJSLines({
    ...options,
    attributes: node.attributes,
  });
  return (transpiledAttributes === null)
    ? []
    : [
      `// attributes`,
      ...transpiledAttributes,
    ];
}
