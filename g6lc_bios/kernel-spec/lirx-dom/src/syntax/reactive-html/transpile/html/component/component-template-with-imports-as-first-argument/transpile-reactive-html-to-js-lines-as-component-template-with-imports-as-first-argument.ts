import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { linesOrNullToLines } from '../../../../../misc/lines/functions/lines-or-null-to-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLToJSLines } from '../../transpile-reactive-html-to-js-lines';

export interface ITranspileReactiveHTMLToJSLinesAsComponentTemplateWithImportsAsFirstArgumentOptions extends IHavingPrimaryTranspilersOptions {
  readonly html: string;
  readonly functionImportLines: ILines;
}

export function transpileReactiveHTMLToJSLinesAsComponentTemplateWithImportsAsFirstArgument(
  {
    functionImportLines,
    ...options
  }: ITranspileReactiveHTMLToJSLinesAsComponentTemplateWithImportsAsFirstArgumentOptions,
): ILines {
  return [
    `(`,
    ...indentLines([
      ...functionImportLines,
      `parentNode,`,
      `$,`,
      `slots,`,
    ]),
    `) => {`,
    ...indentLines(
      linesOrNullToLines(
        transpileReactiveHTMLToJSLines(options),
      ),
    ),
    `}`,
  ];
}


