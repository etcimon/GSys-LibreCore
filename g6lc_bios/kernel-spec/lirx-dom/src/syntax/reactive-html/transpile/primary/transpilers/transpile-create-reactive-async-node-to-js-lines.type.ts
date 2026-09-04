import { ILines } from '../../../../misc/lines/lines.type';

export interface ITranspileCreateReactiveAsyncNodeToJSLinesOptions {
  readonly expression: ILines;
  readonly templatePending: ILines;
  readonly templateFulfilled: ILines;
  readonly templateRejected: ILines;
}

export interface ITranspileCreateReactiveAsyncNodeToJSLinesFunction {
  (
    options: ITranspileCreateReactiveAsyncNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileCreateReactiveAsyncNodeToJSLinesTrait {
  readonly transpileCreateReactiveAsyncNodeToJSLines: ITranspileCreateReactiveAsyncNodeToJSLinesFunction;
}
