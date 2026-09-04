import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveClassNamesListToJSLinesFunction,
  ITranspileSetReactiveClassNamesListToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-class-names-list-to-js-lines.type';
import { transpileReactiveValueToJSLines } from './special/transpile-reactive-value-to-js-lines';

export const transpileSetReactiveClassNamesListToJSLines: ITranspileSetReactiveClassNamesListToJSLinesFunction = (
  {
    node,
    value,
  }: ITranspileSetReactiveClassNamesListToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    node,
    [`.setReactiveClassNamesList(`],
    transpileReactiveValueToJSLines(value),
    [');'],
  );
};


