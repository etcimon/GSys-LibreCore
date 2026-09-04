import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveIfNodeToJSLinesFunction,
  ITranspileCreateReactiveIfNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-if-node-to-js-lines.type';
import { transpileReactiveValueToJSLines } from './special/transpile-reactive-value-to-js-lines';

export const transpileCreateReactiveIfNodeToJSLines: ITranspileCreateReactiveIfNodeToJSLinesFunction = (
  {
    condition,
    templateTrue,
    templateFalse,
  }: ITranspileCreateReactiveIfNodeToJSLinesOptions,
): ILines => {
  return [
    `new VirtualReactiveIfNode(`,
    ...indentLines([
      ...inlineLastLines(
        transpileReactiveValueToJSLines(condition),
        [','],
      ),
      ...inlineLastLines(
        // (templateTrue === null) ? ['null'] : templateTrue,
        templateTrue,
        [','],
      ),
      ...inlineLastLines(
        // (templateFalse === null) ? ['null'] : templateFalse,
        templateFalse,
        [','],
      ),
    ]),
    `)`,
  ];
};


