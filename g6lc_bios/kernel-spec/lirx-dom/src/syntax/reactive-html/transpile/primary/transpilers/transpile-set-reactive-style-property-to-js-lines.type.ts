import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileSetReactiveStylePropertyToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: IReactiveValue;
}

export interface ITranspileSetReactiveStylePropertyToJSLinesFunction {
  (
    options: ITranspileSetReactiveStylePropertyToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveStylePropertyToJSLinesTrait {
  readonly transpileSetReactiveStylePropertyToJSLines: ITranspileSetReactiveStylePropertyToJSLinesFunction;
}
