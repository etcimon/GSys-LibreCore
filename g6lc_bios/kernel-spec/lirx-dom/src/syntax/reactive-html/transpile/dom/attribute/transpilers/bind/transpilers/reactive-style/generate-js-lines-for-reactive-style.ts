import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForReactiveStyleOptions extends IHavingPrimaryTranspilersOptions {
  readonly name: string;
  readonly value: IReactiveValue;
}

export function generateJSLinesForReactiveStyle(
  {
    name,
    value,
    transpilers,
  }: IGenerateJSLinesForReactiveStyleOptions,
): ILines {
  const {
    transpileSetReactiveStylePropertyToJSLines,
  } = transpilers;

  return [
    `// reactive style '${name}'`,
    ...transpileSetReactiveStylePropertyToJSLines({
      node: ['node'],
      name: [JSON.stringify(name)],
      value,
    }),
  ];
}
