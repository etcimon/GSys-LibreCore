import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForReactiveTextNodeOptions extends IHavingPrimaryTranspilersOptions {
  readonly value: IReactiveValue;
}

export function generateJSLinesForReactiveTextNode(
  {
    value,
    transpilers,
  }: IGenerateJSLinesForReactiveTextNodeOptions,
): ILines {

  const {
    transpileAttachNodeToJSLines,
    transpileCreateReactiveTextNodeToJSLines,
  } = transpilers;

  return [
    `// reactive text node`,
    ...transpileAttachNodeToJSLines({
      node: transpileCreateReactiveTextNodeToJSLines({
        value,
      }),
      parentNode: ['parentNode'],
    }),
  ];
}
