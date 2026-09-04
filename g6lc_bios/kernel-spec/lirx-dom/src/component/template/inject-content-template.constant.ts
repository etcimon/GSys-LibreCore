import {
  IVirtualComponentNodeSlotsMap,
} from '../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { VirtualDOMNode } from '../../dom-manipulation/virtual-nodes/virtual-dom-node/virtual-dom-node.class';
import { IComponentTemplate } from './component-template.type';

export const INJECT_CONTENT_TEMPLATE: IComponentTemplate<any> = (
  parentNode: VirtualDOMNode,
  $: any,
  slots: IVirtualComponentNodeSlotsMap,
): void => {
  if (slots.has('*')) {
    slots.get('*')!(parentNode, {});
  }
};
