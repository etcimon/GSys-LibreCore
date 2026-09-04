import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactivePropertyToJSLinesFunction,
  ITranspileSetReactivePropertyToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-property-to-js-lines.type';
import { transpileReactiveValueToJSLines } from './special/transpile-reactive-value-to-js-lines';

export const transpileSetReactivePropertyToJSLines: ITranspileSetReactivePropertyToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetReactivePropertyToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`bindCaseInsensitivePropertyWithObservable(`],
    node,
    [', '],
    name,
    [', '],
    transpileReactiveValueToJSLines(value),
    [');'],
  );
};


