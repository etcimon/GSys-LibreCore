import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileSetReactivePropertyToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: IReactiveValue;
}

export interface ITranspileSetReactivePropertyToJSLinesFunction {
  (
    options: ITranspileSetReactivePropertyToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactivePropertyToJSLinesTrait {
  readonly transpileSetReactivePropertyToJSLines: ITranspileSetReactivePropertyToJSLinesFunction;
}
