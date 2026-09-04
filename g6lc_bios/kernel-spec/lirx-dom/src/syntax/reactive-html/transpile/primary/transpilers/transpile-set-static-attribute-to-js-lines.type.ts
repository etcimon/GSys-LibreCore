import { ILines } from '../../../../misc/lines/lines.type';

export interface ITranspileSetStaticAttributeToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: ILines;
}

export interface ITranspileSetStaticAttributeToJSLinesFunction {
  (
    options: ITranspileSetStaticAttributeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetStaticAttributeToJSLinesTrait {
  readonly transpileSetStaticAttributeToJSLines: ITranspileSetStaticAttributeToJSLinesFunction;
}
