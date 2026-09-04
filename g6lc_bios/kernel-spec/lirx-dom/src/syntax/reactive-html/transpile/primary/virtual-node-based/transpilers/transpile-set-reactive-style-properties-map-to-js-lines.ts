import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveStylePropertiesMapToJSLinesFunction,
  ITranspileSetReactiveStylePropertiesMapToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-style-properties-map-to-js-lines.type';
import { transpileReactiveValueToJSLines } from './special/transpile-reactive-value-to-js-lines';

export const transpileSetReactiveStylePropertiesMapToJSLines: ITranspileSetReactiveStylePropertiesMapToJSLinesFunction = (
  {
    node,
    value,
  }: ITranspileSetReactiveStylePropertiesMapToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    node,
    [`.setReactiveStylePropertiesMap(`],
    transpileReactiveValueToJSLines(value),
    [');'],
  );
};


