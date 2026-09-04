import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import { generateJsLinesForValuesToImportFromObject } from '../../../../../misc/misc/generate-js-lines-for-values-to-import-from-object';
import {
  PRIMARY_TRANSPILERS_FOR_AOT_BASED_REACTIVE_HTML,
} from '../../../primary/aot-based/primary-transpilers-for-aot-based-reactive-html.constant';
import {
  VALUES_TO_IMPORT_FOR_AOT_BASED_REACTIVE_HTML,
} from '../../../primary/aot-based/values-to-import-for-aot-based-reactive-html.constant';
import {
  ITranspileReactiveHTMLToJSLinesAsComponentTemplateModuleOptions,
  transpileReactiveHTMLToJSLinesAsComponentTemplateModule,
} from './transpile-reactive-html-to-js-lines-as-component-template-module';

export interface ITranspileReactiveHTMLToComponentTemplateModuleOptions extends //
  Omit<ITranspileReactiveHTMLToJSLinesAsComponentTemplateModuleOptions, 'transpilers' | 'importLines' | 'functionImportLines'>,
  Partial<Pick<ITranspileReactiveHTMLToJSLinesAsComponentTemplateModuleOptions, 'transpilers'>>
//
{
  readonly importLines?: ILines;
}

export function transpileReactiveHTMLToComponentTemplateModule(
  {
    transpilers = PRIMARY_TRANSPILERS_FOR_AOT_BASED_REACTIVE_HTML,
    importLines = getDefaultImportLines(),
    ...options
  }: ITranspileReactiveHTMLToComponentTemplateModuleOptions,
): ILines {

  const functionImportLines: ILines = [
    `{`,
    ...indentLines([
      `createCustomElement,`,
      `applyNodeModifiers,`,
    ]),
    `},`,
  ];

  return transpileReactiveHTMLToJSLinesAsComponentTemplateModule({
    ...options,
    transpilers,
    importLines,
    functionImportLines,
  });
}

/*-----*/

let DEFAULT_IMPORT_LINES: ILines;

function getDefaultImportLines(): ILines {
  if (DEFAULT_IMPORT_LINES === void 0) {
    DEFAULT_IMPORT_LINES = generateJsLinesForValuesToImportFromObject(VALUES_TO_IMPORT_FOR_AOT_BASED_REACTIVE_HTML);
  }
  return DEFAULT_IMPORT_LINES;
}
