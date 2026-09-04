import { ILines } from '../../../../misc/lines/lines.type';

export interface ITranspileCreateReactiveElementNodeToJSLinesOptions {
  readonly namespaceURI: string,
  readonly name: string,
  readonly options?: ElementCreationOptions,
}

export interface ITranspileCreateReactiveElementNodeToJSLinesFunction {
  (
    options: ITranspileCreateReactiveElementNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileCreateReactiveElementNodeToJSLinesTrait {
  readonly transpileCreateReactiveElementNodeToJSLines: ITranspileCreateReactiveElementNodeToJSLinesFunction;
}
