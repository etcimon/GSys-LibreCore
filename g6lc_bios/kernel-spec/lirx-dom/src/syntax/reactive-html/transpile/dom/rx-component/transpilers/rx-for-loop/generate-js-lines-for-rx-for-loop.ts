import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { IReactiveValue } from '../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForRXForLoopOptions extends IHavingPrimaryTranspilersOptions {
  readonly items: IReactiveValue;
  readonly template: ILines;
  readonly trackBy?: string | undefined;
}

export function generateJSLinesForRXForLoop(
  {
    items,
    template,
    trackBy,
    transpilers,
  }: IGenerateJSLinesForRXForLoopOptions,
): ILines {
  const {
    transpileAttachNodeToJSLines,
    transpileCreateReactiveForLoopNodeToJSLines,
  } = transpilers;

  return [
    `// reactive for loop node`,
    ...transpileAttachNodeToJSLines({
      node: transpileCreateReactiveForLoopNodeToJSLines({
        items,
        template,
        trackBy: (trackBy === void 0)
          ? null
          : [trackBy],
      }),
      parentNode: ['parentNode'],
    }),
  ];
}
