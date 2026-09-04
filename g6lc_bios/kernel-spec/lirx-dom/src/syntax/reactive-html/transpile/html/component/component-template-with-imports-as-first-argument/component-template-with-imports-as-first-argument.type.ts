import { IComponentTemplate } from '../../../../../../component/template/component-template.type';

export interface IComponentTemplateWithImportsAsFirstArgument<GData extends object> {
  (
    imports: object,
    ...args: Parameters<IComponentTemplate<GData>>
  ): ReturnType<IComponentTemplate<GData>>;
}

export type IGenericComponentTemplateWithImportsAsFirstArgument = IComponentTemplateWithImportsAsFirstArgument<object>;
