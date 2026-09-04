import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';

export interface IGenerateJSLinesForRXAsyncOptions extends IHavingPrimaryTranspilersOptions {
  readonly expression: string;
  readonly templatePending: ILines;
  readonly templateFulfilled: ILines;
  readonly templateRejected: ILines;
}

export function generateJSLinesForRXAsync(
  {
    expression,
    templatePending,
    templateFulfilled,
    templateRejected,
    transpilers,
  }: IGenerateJSLinesForRXAsyncOptions,
): ILines {
  const {
    transpileAttachNodeToJSLines,
    transpileCreateReactiveAsyncNodeToJSLines,
  } = transpilers;

  return [
    `// reactive async node`,
    ...transpileAttachNodeToJSLines({
      node: transpileCreateReactiveAsyncNodeToJSLines({
        expression: [expression],
        templatePending,
        templateFulfilled,
        templateRejected,
      }),
      parentNode: ['parentNode'],
    }),
  ];
}
