import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForRXIfOptions extends IHavingPrimaryTranspilersOptions {
  readonly condition: IReactiveValue;
  readonly templateTrue: ILines;
  readonly templateFalse: ILines;
}

export function generateJSLinesForRXIf(
  {
    condition,
    templateTrue,
    templateFalse,
    transpilers,
  }: IGenerateJSLinesForRXIfOptions,
): ILines {
  const {
    transpileAttachNodeToJSLines,
    transpileCreateReactiveIfNodeToJSLines,
  } = transpilers;

  return [
    `// reactive if node`,
    ...transpileAttachNodeToJSLines({
      node: transpileCreateReactiveIfNodeToJSLines({
        condition,
        templateTrue,
        templateFalse,
      }),
      parentNode: ['parentNode'],
    }),
  ];
}
