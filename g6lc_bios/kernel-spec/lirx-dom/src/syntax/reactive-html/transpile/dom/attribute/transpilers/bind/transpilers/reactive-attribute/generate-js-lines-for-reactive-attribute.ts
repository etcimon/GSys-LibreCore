import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForReactiveAttributeOptions extends IHavingPrimaryTranspilersOptions {
  readonly name: string;
  readonly value: IReactiveValue;
}

export function generateJSLinesForReactiveAttribute(
  {
    name,
    value,
    transpilers,
  }: IGenerateJSLinesForReactiveAttributeOptions,
): ILines {
  const {
    transpileSetReactiveAttributeToJSLines,
  } = transpilers;

  return [
    `// reactive attribute '${name}'`,
    ...transpileSetReactiveAttributeToJSLines({
      node: ['node'],
      name: [JSON.stringify(name)],
      value,
    }),
  ];
}
