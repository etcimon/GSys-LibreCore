import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileApplyNodeModifiersToJSLinesFunction,
  ITranspileApplyNodeModifiersToJSLinesOptions,
} from '../../transpilers/transpile-apply-node-modifiers-to-js-lines.type';
import { transpileApplyNodeModifiersToJSLines } from '../../virtual-node-based/transpilers/transpile-apply-node-modifiers-to-js-lines';

export const transpileAOTApplyNodeModifiersToJSLines: ITranspileApplyNodeModifiersToJSLinesFunction = (
  options: ITranspileApplyNodeModifiersToJSLinesOptions,
): ILines => {
  return transpileApplyNodeModifiersToJSLines(options);
};


