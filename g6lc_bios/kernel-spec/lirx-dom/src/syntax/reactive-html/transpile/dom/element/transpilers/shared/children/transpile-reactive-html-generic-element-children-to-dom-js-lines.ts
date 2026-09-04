import { wrapLinesWithCurlyBrackets } from '../../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLNodesToJSLines } from '../../../../nodes/transpile-reactive-html-nodes-to-js-lines';

export interface ITranspileReactiveHTMLGenericElementChildrenToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLGenericElementChildrenToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLGenericElementChildrenToJSLinesOptions,
): ILines {
  const transpiledChildren: ILinesOrNull = transpileReactiveHTMLNodesToJSLines({
    ...options,
    nodes: node.childNodes,
  });
  return (transpiledChildren === null)
    ? []
    : wrapLinesWithCurlyBrackets([
      `// child nodes`,
      `const parentNode = node;`,
      ...transpiledChildren,
    ]);
}
