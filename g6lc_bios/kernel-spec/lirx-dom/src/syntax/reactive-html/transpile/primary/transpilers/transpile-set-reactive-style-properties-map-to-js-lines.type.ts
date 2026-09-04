import { ILines } from '../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../misc/extract-reactive-value-from-string';

export interface ITranspileSetReactiveStylePropertiesMapToJSLinesOptions {
  readonly node: ILines;
  readonly value: IReactiveValue;
}

export interface ITranspileSetReactiveStylePropertiesMapToJSLinesFunction {
  (
    options: ITranspileSetReactiveStylePropertiesMapToJSLinesOptions,
  ): ILines;
}

export interface ITranspileSetReactiveStylePropertiesMapToJSLinesTrait {
  readonly transpileSetReactiveStylePropertiesMapToJSLines: ITranspileSetReactiveStylePropertiesMapToJSLinesFunction;
}
