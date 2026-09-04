import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLNodesToJSLines } from '../../../../nodes/transpile-reactive-html-nodes-to-js-lines';
import { generateJSLinesForRXTemplate } from './generate-js-lines-for-rx-template';

export interface IGenerateJSLinesForRXTemplateFromNodesOptions extends IHavingPrimaryTranspilersOptions {
  readonly nodes: ArrayLike<Node>;
  readonly argumentsLines: ILinesOrNull,
}

export function generateJSLinesForRXTemplateFromNodes(
  {
    nodes,

    argumentsLines,
    ...options
  }: IGenerateJSLinesForRXTemplateFromNodesOptions,
): ILines {
  return generateJSLinesForRXTemplate({
    argumentsLines,
    bodyLines: transpileReactiveHTMLNodesToJSLines({
      ...options,
      nodes,
    }),
  });
}

