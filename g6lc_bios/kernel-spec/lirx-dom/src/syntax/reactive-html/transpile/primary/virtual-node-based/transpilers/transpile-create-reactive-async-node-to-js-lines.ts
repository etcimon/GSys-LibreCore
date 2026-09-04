import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveAsyncNodeToJSLinesFunction,
  ITranspileCreateReactiveAsyncNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-async-node-to-js-lines.type';

export const transpileCreateReactiveAsyncNodeToJSLines: ITranspileCreateReactiveAsyncNodeToJSLinesFunction = (
  {
    expression,
    templatePending,
    templateFulfilled,
    templateRejected,
  }: ITranspileCreateReactiveAsyncNodeToJSLinesOptions,
): ILines => {
  return [
    `new VirtualReactiveAsyncNode(`,
    ...indentLines([
      ...inlineLastLines(
        expression,
        [','],
      ),
      ...inlineLastLines(
        templatePending,
        [','],
      ),
      ...inlineLastLines(
        templateFulfilled,
        [','],
      ),
      ...inlineLastLines(
        templateRejected,
        [','],
      ),
    ]),
    `)`,
  ];
};


