import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';

export interface IGenerateJSLinesForStaticTextNodeOptions extends IHavingPrimaryTranspilersOptions {
  readonly value: string;
}

export function generateJSLinesForStaticTextNode(
  {
    value,
    transpilers,
  }: IGenerateJSLinesForStaticTextNodeOptions,
): ILines {
  const {
    transpileAttachNodeToJSLines,
    transpileCreateStaticTextNodeToJSLines,
  } = transpilers;
  return [
    `// static text node`,
    ...transpileAttachNodeToJSLines({
      node: transpileCreateStaticTextNodeToJSLines({
        value: [JSON.stringify(value)],
      }),
      parentNode: ['parentNode'],
    }),
  ];
}
