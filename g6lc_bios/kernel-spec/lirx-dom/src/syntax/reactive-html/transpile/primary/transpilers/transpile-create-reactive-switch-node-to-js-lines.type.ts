import { ILinesOrNull } from '../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../misc/lines/lines.type';
import { ILinesMap } from '../../../../misc/misc/generate-js-lines-for-lines-map';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export type ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap = ILinesMap;

export interface ITranspileCreateReactiveSwitchNodeToJSLinesOptions {
  readonly expression: IReactiveValue,
  readonly templatesMap: ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap;
  readonly defaultTemplate: ILinesOrNull;
}

export interface ITranspileCreateReactiveSwitchNodeToJSLinesFunction {
  (
    options: ITranspileCreateReactiveSwitchNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileCreateReactiveSwitchNodeToJSLinesTrait {
  readonly transpileCreateReactiveSwitchNodeToJSLines: ITranspileCreateReactiveSwitchNodeToJSLinesFunction;
}
