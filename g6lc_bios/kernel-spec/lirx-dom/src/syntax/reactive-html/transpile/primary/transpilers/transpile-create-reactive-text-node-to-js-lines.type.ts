import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileCreateReactiveTextNodeToJSLinesOptions {
  readonly value: IReactiveValue;
}

export interface ITranspileCreateReactiveTextNodeToJSLinesFunction {
  (
    options: ITranspileCreateReactiveTextNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileCreateReactiveTextNodeToJSLinesTrait {
  readonly transpileCreateReactiveTextNodeToJSLines: ITranspileCreateReactiveTextNodeToJSLinesFunction;
}
