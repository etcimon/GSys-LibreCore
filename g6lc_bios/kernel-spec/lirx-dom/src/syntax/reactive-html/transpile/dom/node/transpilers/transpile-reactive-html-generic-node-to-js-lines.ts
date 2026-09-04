import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLElementToJSLines } from '../../element/transpile-reactive-html-element-to-js-lines';
import { transpileReactiveHTMLTextNodeToJSLines } from '../../text-node/transpile-reactive-html-text-node-to-js-lines';

export interface ITranspileReactiveHTMLGenericNodeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Node;
}

export function transpileReactiveHTMLGenericNodeToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLGenericNodeToJSLinesOptions,
): ILinesOrNull {
  switch (node.nodeType) {
    case Node.TEXT_NODE:
      return transpileReactiveHTMLTextNodeToJSLines({
        ...options,
        node: node as Text,
      });
    case Node.COMMENT_NODE:
      return null;
    case Node.ELEMENT_NODE:
      return transpileReactiveHTMLElementToJSLines({
        ...options,
        node: node as Element,
      });
    default:
      return null;
  }
}
