import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileSetReactiveClassNamesListToJSLinesOptions {
  readonly node: ILines;
  readonly value: IReactiveValue;
}

export interface ITranspileSetReactiveClassNamesListToJSLinesFunction {
  (
    options: ITranspileSetReactiveClassNamesListToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveClassNamesListToJSLinesTrait {
  readonly transpileSetReactiveClassNamesListToJSLines: ITranspileSetReactiveClassNamesListToJSLinesFunction;
}
