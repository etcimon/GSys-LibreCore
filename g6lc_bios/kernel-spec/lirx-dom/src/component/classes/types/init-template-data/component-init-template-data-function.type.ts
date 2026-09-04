import { IComponentVirtualComponentNode } from '../component-virtual-component-node.type';

export type InferComponentOptionsInitTemplateDataFunction<GElement extends Element, GData extends object, GTemplateData extends object> =
  object extends GTemplateData
    ? {
      templateData?: IComponentInitVoidTemplateDataFunction<GElement, GData, GTemplateData> | undefined;
    }
    : {
      templateData: IComponentInitTemplateDataFunction<GElement, GData, GTemplateData>;
    }
  ;

export interface IComponentInitTemplateDataFunction<GElement extends Element, GData extends object, GTemplateData extends object> {
  (
    node: IComponentVirtualComponentNode<GElement, GData>,
  ): GTemplateData;
}

export interface IComponentInitVoidTemplateDataFunction<GElement extends Element, GData extends object, GTemplateData extends object> {
  (
    node: IComponentVirtualComponentNode<GElement, GData>,
  ): GTemplateData | void | undefined;
}
