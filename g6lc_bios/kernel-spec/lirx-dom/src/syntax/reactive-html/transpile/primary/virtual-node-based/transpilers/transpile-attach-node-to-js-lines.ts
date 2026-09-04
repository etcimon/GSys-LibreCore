import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { wrapLinesWithRoundBrackets } from '../../../../../misc/lines/functions/wrap-lines-with-round-brackets';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileAttachNodeToJSLinesFunction,
  ITranspileAttachNodeToJSLinesOptions,
} from '../../transpilers/transpile-attach-node-to-js-lines.type';

export const transpileAttachNodeToJSLines: ITranspileAttachNodeToJSLinesFunction = (
  {
    node,
    parentNode,
  }: ITranspileAttachNodeToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    wrapLinesWithRoundBrackets(node),
    [`.attach(`],
    parentNode,
    [`);`],
  );
};


