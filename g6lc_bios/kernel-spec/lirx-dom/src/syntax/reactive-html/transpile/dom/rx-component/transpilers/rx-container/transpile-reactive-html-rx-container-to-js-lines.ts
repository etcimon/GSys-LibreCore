import { createShouldNotHaveAttributesError } from '../../../../../../misc/errors/create-should-not-have-attributes-error';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLNodesToJSLines } from '../../../nodes/transpile-reactive-html-nodes-to-js-lines';
import { isRXContainer } from './is-rx-container';

/*
Syntax:

<rx-container
>
  ...content
</rx-container>

 */

export interface ITranspileReactiveHTMLRXContainerToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXContainerToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLRXContainerToJSLinesOptions,
): ILinesOrNull {
  if (isRXContainer(node)) {
    if (node.attributes.length === 0) {
      return transpileReactiveHTMLNodesToJSLines({
        ...options,
        nodes: node.childNodes,
      });
    } else {
      throw createShouldNotHaveAttributesError(node);
    }
  } else {
    return null;
  }
}

