import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForReactiveClassOptions extends IHavingPrimaryTranspilersOptions {
  readonly name: string;
  readonly value: IReactiveValue;
}

export function generateJSLinesForReactiveClass(
  {
    name,
    value,
    transpilers,
  }: IGenerateJSLinesForReactiveClassOptions,
): ILines {
  const {
    transpileSetReactiveClassToJSLines,
  } = transpilers;

  return [
    `// reactive class '${name}'`,
    ...transpileSetReactiveClassToJSLines({
      node: ['node'],
      name: [JSON.stringify(name)],
      value,
    }),
  ];
}
