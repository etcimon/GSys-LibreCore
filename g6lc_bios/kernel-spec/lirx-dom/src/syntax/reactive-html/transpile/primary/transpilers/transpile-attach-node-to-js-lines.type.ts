import { ILines } from '../../../../misc/lines/lines.type';

export interface ITranspileAttachNodeToJSLinesOptions {
  readonly node: ILines;
  readonly parentNode: ILines;
}

export interface ITranspileAttachNodeToJSLinesFunction {
  (
    options: ITranspileAttachNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileAttachNodeToJSLinesTrait {
  readonly transpileAttachNodeToJSLines: ITranspileAttachNodeToJSLinesFunction;
}


