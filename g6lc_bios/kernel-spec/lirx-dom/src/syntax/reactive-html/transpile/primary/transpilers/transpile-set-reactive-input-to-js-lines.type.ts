import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileSetReactiveInputToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: IReactiveValue;
}

export interface ITranspileSetReactiveInputToJSLinesFunction {
  (
    options: ITranspileSetReactiveInputToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveInputToJSLinesTrait {
  readonly transpileSetReactiveInputToJSLines: ITranspileSetReactiveInputToJSLinesFunction;
}
