import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForReactiveStylePropertiesMapOptions extends IHavingPrimaryTranspilersOptions {
  readonly value: IReactiveValue;
}

export function generateJSLinesForReactiveStylePropertiesMap(
  {
    value,
    transpilers,
  }: IGenerateJSLinesForReactiveStylePropertiesMapOptions,
): ILines {
  const {
    transpileSetReactiveStylePropertiesMapToJSLines,
  } = transpilers;

  return [
    `// reactive style properties map`,
    ...transpileSetReactiveStylePropertiesMapToJSLines({
      node: ['node'],
      value,
    }),
  ];
}
