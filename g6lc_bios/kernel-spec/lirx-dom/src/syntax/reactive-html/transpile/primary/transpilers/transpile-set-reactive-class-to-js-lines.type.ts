import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileSetReactiveClassToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: IReactiveValue;
}

export interface ITranspileSetReactiveClassToJSLinesFunction {
  (
    options: ITranspileSetReactiveClassToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveClassToJSLinesTrait {
  readonly transpileSetReactiveClassToJSLines: ITranspileSetReactiveClassToJSLinesFunction;
}
