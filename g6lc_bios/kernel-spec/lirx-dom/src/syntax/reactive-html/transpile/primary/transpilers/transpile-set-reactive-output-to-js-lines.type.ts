import { ILines } from '../../../../misc/lines/lines.type';

export interface ITranspileSetReactiveOutputToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: ILines;
  readonly observableMode: boolean;
}

export interface ITranspileSetReactiveOutputToJSLinesFunction {
  (
    options: ITranspileSetReactiveOutputToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveOutputToJSLinesTrait {
  readonly transpileSetReactiveOutputToJSLines: ITranspileSetReactiveOutputToJSLinesFunction;
}
