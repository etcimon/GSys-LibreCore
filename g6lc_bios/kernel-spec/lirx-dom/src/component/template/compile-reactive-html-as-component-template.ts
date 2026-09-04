import { indentLines } from '../../syntax/misc/lines/functions/indent-lines';
import { linesToString } from '../../syntax/misc/lines/functions/lines-to-string';
import { ILines } from '../../syntax/misc/lines/lines.type';
import { generateJsLinesForValuesToImportFromObject } from '../../syntax/misc/misc/generate-js-lines-for-values-to-import-from-object';
import {
  IComponentTemplateWithImportsAsFirstArgument,
} from '../../syntax/reactive-html/transpile/html/component/component-template-with-imports-as-first-argument/component-template-with-imports-as-first-argument.type';
import {
  transpileReactiveHTMLToJSLinesAsComponentTemplateWithImportsAsFirstArgument,
} from '../../syntax/reactive-html/transpile/html/component/component-template-with-imports-as-first-argument/transpile-reactive-html-to-js-lines-as-component-template-with-imports-as-first-argument';
import { ITranspileReactiveHTMLToJSLinesOptions } from '../../syntax/reactive-html/transpile/html/transpile-reactive-html-to-js-lines';

import {
  PRIMARY_TRANSPILERS_FOR_VIRTUAL_NODE_BASED_REACTIVE_HTML,
} from '../../syntax/reactive-html/transpile/primary/virtual-node-based/primary-transpilers-for-virtual-node-based-reactive-html.constant';
import {
  VALUES_TO_IMPORT_FOR_VIRTUAL_NODE_BASED_REACTIVE_HTML,
} from '../../syntax/reactive-html/transpile/primary/virtual-node-based/values-to-import-for-virtual-node-based-reactive-html.constant';
import { IComponentTemplate } from './component-template.type';
import {
  generateApplyNodeModifiersFunctionFromModifierList,
  IGenericVirtualDOMNodeModifierList,
} from './apply-node-modifier-function/generate-apply-node-modifiers-function-from-modifier-list';
import {
  generateCreateCustomElementFunctionFromComponentList,
  IGenericAbstractComponentList,
} from './create-custom-element-function/generate-create-custom-element-function-from-component-list';

export interface ICompileReactiveHTMLAsComponentTemplateOptions extends Omit<ITranspileReactiveHTMLToJSLinesOptions, 'transpilers'> {
  readonly components?: IGenericAbstractComponentList;
  readonly modifiers?: IGenericVirtualDOMNodeModifierList;
}

/**
 * Compiles some reactive html to a component template.
 */
export function compileReactiveHTMLAsComponentTemplate<GData extends object>(
  {
    components,
    modifiers,
    ...options
  }: ICompileReactiveHTMLAsComponentTemplateOptions,
): IComponentTemplate<GData> {
  const createCustomElement = generateCreateCustomElementFunctionFromComponentList(components);
  const applyNodeModifiers = generateApplyNodeModifiersFunctionFromModifierList(modifiers);

  const valuesToImport = {
    ...VALUES_TO_IMPORT_FOR_VIRTUAL_NODE_BASED_REACTIVE_HTML,
    createCustomElement,
    applyNodeModifiers,
  };

  const functionImportLines: ILines = [
    `{`,
    ...indentLines(
      generateJsLinesForValuesToImportFromObject(valuesToImport),
    ),
    `},`,
  ];

  const lines: ILines = transpileReactiveHTMLToJSLinesAsComponentTemplateWithImportsAsFirstArgument({
    ...options,
    functionImportLines,
    transpilers: PRIMARY_TRANSPILERS_FOR_VIRTUAL_NODE_BASED_REACTIVE_HTML,
  });

  const compiledReactiveHTML: string = linesToString(lines);

  // console.log(compiledReactiveHTML);

  const fnc = new Function(
    '...a',
    `return(${compiledReactiveHTML})(...a);`,
  ) as IComponentTemplateWithImportsAsFirstArgument<GData>;

  return (...args: Parameters<IComponentTemplate<GData>>): ReturnType<IComponentTemplate<GData>> => {
    return fnc(valuesToImport, ...args);
  };
}


