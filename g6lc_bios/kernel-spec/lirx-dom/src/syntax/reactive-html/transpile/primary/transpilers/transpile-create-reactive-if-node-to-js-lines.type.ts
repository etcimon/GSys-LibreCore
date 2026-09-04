import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileCreateReactiveIfNodeToJSLinesOptions {
  readonly condition: IReactiveValue;
  readonly templateTrue: ILines;
  readonly templateFalse: ILines;
}

export interface ITranspileCreateReactiveIfNodeToJSLinesFunction {
  (
    options: ITranspileCreateReactiveIfNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileCreateReactiveIfNodeToJSLinesTrait {
  readonly transpileCreateReactiveIfNodeToJSLines: ITranspileCreateReactiveIfNodeToJSLinesFunction;
}
