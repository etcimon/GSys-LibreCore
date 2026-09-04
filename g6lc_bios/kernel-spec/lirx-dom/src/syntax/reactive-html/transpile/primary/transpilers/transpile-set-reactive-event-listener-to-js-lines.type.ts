import { ILines } from '../../../../misc/lines/lines.type';

export interface ITranspileSetReactiveEventListenerToJSLinesOptions {
  readonly node: ILines;
  readonly name: ILines;
  readonly value: ILines;
  readonly observableMode: boolean;
}

export interface ITranspileSetReactiveEventListenerToJSLinesFunction {
  (
    options: ITranspileSetReactiveEventListenerToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveEventListenerToJSLinesTrait {
  readonly transpileSetReactiveEventListenerToJSLines: ITranspileSetReactiveEventListenerToJSLinesFunction;
}
