import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForReactiveClassNamesListOptions extends IHavingPrimaryTranspilersOptions {
  readonly value: IReactiveValue;
}

export function generateJSLinesForReactiveClassNamesList(
  {
    value,
    transpilers,
  }: IGenerateJSLinesForReactiveClassNamesListOptions,
): ILines {
  const {
    transpileSetReactiveClassNamesListToJSLines,
  } = transpilers;

  return [
    `// reactive class names list`,
    ...transpileSetReactiveClassNamesListToJSLines({
      node: ['node'],
      value,
    }),
  ];
}
