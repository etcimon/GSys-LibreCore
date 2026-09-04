import { freeze } from '@lirx/core';
import { IComponentInitTemplateDataFunction, IComponentInitVoidTemplateDataFunction } from './component-init-template-data-function.type';
import { IComponentVirtualComponentNode } from '../component-virtual-component-node.type';

const DEFAULT_TEMPLATE_DATA: Readonly<object> = freeze({});
const DEFAULT_INIT_TEMPLATE_DATA_FUNCTION: IComponentInitTemplateDataFunction<any, any, object> = () => DEFAULT_TEMPLATE_DATA;

export function normalizeComponentInitTemplateDataFunction<GElement extends Element, GData extends object, GTemplateData extends object>(
  input: IComponentInitVoidTemplateDataFunction<GElement, GData, GTemplateData> | undefined,
): IComponentInitTemplateDataFunction<GElement, GData, GTemplateData> {
  return (input === void 0)
    ? DEFAULT_INIT_TEMPLATE_DATA_FUNCTION as IComponentInitTemplateDataFunction<GElement, GData, GTemplateData>
    : (node: IComponentVirtualComponentNode<GElement, GData>): GTemplateData => {
      return input(node) ?? DEFAULT_TEMPLATE_DATA as GTemplateData;
    };
}
