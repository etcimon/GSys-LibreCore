import {
  IGenericComponentTemplateWithImportsAsFirstArgument,
} from '../../syntax/reactive-html/transpile/html/component/component-template-with-imports-as-first-argument/component-template-with-imports-as-first-argument.type';
import { IComponentTemplate } from './component-template.type';
import { ICompileReactiveHTMLAsComponentTemplateOptions } from './compile-reactive-html-as-component-template';
import {
  generateApplyNodeModifiersFunctionFromModifierList,
} from './apply-node-modifier-function/generate-apply-node-modifiers-function-from-modifier-list';
import {
  generateCreateCustomElementFunctionFromComponentList,
} from './create-custom-element-function/generate-create-custom-element-function-from-component-list';

export interface IConvertRawComponentTemplateToComponentTemplateOptions extends Omit<ICompileReactiveHTMLAsComponentTemplateOptions, 'html'> {
  readonly template: IGenericComponentTemplateWithImportsAsFirstArgument;
}

export function convertRawComponentTemplateToComponentTemplate<GData extends object>(
  {
    template,
    components,
    modifiers,
  }: IConvertRawComponentTemplateToComponentTemplateOptions,
): IComponentTemplate<GData> {
  const createCustomElement = generateCreateCustomElementFunctionFromComponentList(components);
  const applyNodeModifiers = generateApplyNodeModifiersFunctionFromModifierList(modifiers);

  const valuesToImport = {
    createCustomElement,
    applyNodeModifiers,
  };

  return (...args: Parameters<IComponentTemplate<GData>>): ReturnType<IComponentTemplate<GData>> => {
    return template(
      valuesToImport,
      ...args,
    );
  };
}
