import { ILinesOrNull } from '../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileCreateReactiveForLoopNodeToJSLinesOptions {
  readonly items: IReactiveValue;
  readonly template: ILines,
  readonly trackBy: ILinesOrNull,
}

export interface ITranspileCreateReactiveForLoopNodeToJSLinesFunction {
  (
    options: ITranspileCreateReactiveForLoopNodeToJSLinesOptions,
  ): ILines;
}

export interface ITranspileCreateReactiveForLoopNodeToJSLinesTrait {
  readonly transpileCreateReactiveForLoopNodeToJSLines: ITranspileCreateReactiveForLoopNodeToJSLinesFunction;
}
