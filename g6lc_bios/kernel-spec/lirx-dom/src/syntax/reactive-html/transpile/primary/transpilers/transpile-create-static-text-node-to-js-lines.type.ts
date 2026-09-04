import { ILines } from '../../../../misc/lines/lines.type';

export interface ITranspileCreateStaticTextNodeToJSLinesOptions {
  readonly value: ILines;
}

export interface ITranspileCreateStaticTextNodeToJSLinesFunction {
  (
    options: ITranspileCreateStaticTextNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileCreateStaticTextNodeToJSLinesTrait {
  readonly transpileCreateStaticTextNodeToJSLines: ITranspileCreateStaticTextNodeToJSLinesFunction;
}
