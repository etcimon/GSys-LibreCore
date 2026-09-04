import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveTextNodeToJSLinesFunction,
  ITranspileCreateReactiveTextNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-text-node-to-js-lines.type';
import { transpileReactiveValueToJSLines } from './special/transpile-reactive-value-to-js-lines';

export const transpileCreateReactiveTextNodeToJSLines: ITranspileCreateReactiveTextNodeToJSLinesFunction = (
  {
    value,
  }: ITranspileCreateReactiveTextNodeToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`new VirtualReactiveTextNode(`],
    transpileReactiveValueToJSLines(value),
    [')'],
  );
};


