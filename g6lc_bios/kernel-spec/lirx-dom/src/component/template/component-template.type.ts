import {
  IVirtualComponentNodeSlotsMap,
} from '../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { VirtualDOMNode } from '../../dom-manipulation/virtual-nodes/virtual-dom-node/virtual-dom-node.class';

export interface IComponentTemplate<GTemplateData extends object> {
  (
    parentNode: VirtualDOMNode,
    $: GTemplateData,
    slots: IVirtualComponentNodeSlotsMap,
  ): void;
}

export type IGenericComponentTemplate = IComponentTemplate<object>;
