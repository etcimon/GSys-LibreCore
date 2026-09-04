import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileSetReactiveAttributeToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: IReactiveValue;
}

export interface ITranspileSetReactiveAttributeToJSLinesFunction {
  (
    options: ITranspileSetReactiveAttributeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveAttributeToJSLinesTrait {
  readonly transpileSetReactiveAttributeToJSLines: ITranspileSetReactiveAttributeToJSLinesFunction;
}
