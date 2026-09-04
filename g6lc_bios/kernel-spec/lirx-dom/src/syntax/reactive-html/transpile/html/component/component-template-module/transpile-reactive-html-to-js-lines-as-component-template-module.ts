import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../primary/primary-transpilers.type';
import {
  transpileReactiveHTMLToJSLinesAsComponentTemplateWithImportsAsFirstArgument,
} from '../component-template-with-imports-as-first-argument/transpile-reactive-html-to-js-lines-as-component-template-with-imports-as-first-argument';

export interface ITranspileReactiveHTMLToJSLinesAsComponentTemplateModuleOptions extends IHavingPrimaryTranspilersOptions {
  readonly html: string;
  readonly commentLines?: ILines;
  readonly importLines: ILines;
  readonly functionImportLines: ILines;
}

export function transpileReactiveHTMLToJSLinesAsComponentTemplateModule(
  {
    commentLines = [],
    importLines,
    ...options
  }: ITranspileReactiveHTMLToJSLinesAsComponentTemplateModuleOptions,
): ILines {
  return [
    `import {`,
    ...indentLines(importLines),
    `} from '@lirx/dom';`,
    ``,
    ...commentLines,
    ``,
    `export default (`,
    ...indentLines(
      transpileReactiveHTMLToJSLinesAsComponentTemplateWithImportsAsFirstArgument(options),
    ),
    `)`,
  ];
}

