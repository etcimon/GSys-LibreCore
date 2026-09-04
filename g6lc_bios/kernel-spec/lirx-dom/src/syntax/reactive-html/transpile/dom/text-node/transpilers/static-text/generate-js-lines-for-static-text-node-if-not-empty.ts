import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { generateJSLinesForStaticTextNode } from './generate-js-lines-for-static-text-node';

export interface IGenerateJSLinesForStaticTextNodeIfNotEmptyOptions extends IHavingPrimaryTranspilersOptions {
  readonly value: string;
}

export function generateJSLinesForStaticTextNodeIfNotEmpty(
  {
    value,
    ...options
  }: IGenerateJSLinesForStaticTextNodeIfNotEmptyOptions,
): ILinesOrNull {
  return (value === '')
    ? null
    : generateJSLinesForStaticTextNode({
      ...options,
      value,
    });
}
