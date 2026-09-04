import { ILines } from '../../../../misc/lines/lines.type';

export interface IRawModifier {
  readonly weight: number | undefined;
  readonly name: string;
  readonly value: ILines;
}

export interface ITranspileApplyNodeModifiersToJSLinesOptions {
  readonly node: ILines;
  readonly modifiers: readonly IRawModifier[];
}

export interface ITranspileApplyNodeModifiersToJSLinesFunction {
  (
    options: ITranspileApplyNodeModifiersToJSLinesOptions,
  ): ILines;
}

export interface ITranspileApplyNodeModifiersToJSLinesTrait {
  readonly transpileApplyNodeModifiersToJSLines: ITranspileApplyNodeModifiersToJSLinesFunction;
}
