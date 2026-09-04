import {
  IVirtualComponentNodeSlotsMap,
} from '../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { IGenericVirtualRootNode, VirtualRootNode } from '../dom-manipulation/virtual-nodes/virtual-root-node/virtual-root-node.class';
import { AbstractComponent } from './classes/abstract-component.class';
import { IComponentVirtualComponentNode } from './classes/types/component-virtual-component-node.type';

/**
 * Creates "component", and appends it to "container" (usually the <body>)
 */
export function bootstrap<GElement extends Element, GData extends object>(
  component: AbstractComponent<GElement, GData>,
  slots?: IVirtualComponentNodeSlotsMap,
  container: HTMLElement | IGenericVirtualRootNode = VirtualRootNode.body,
): IComponentVirtualComponentNode<GElement, GData> {
  const elementNode: IComponentVirtualComponentNode<GElement, GData> = component.create(slots);
  elementNode.attach(
    (container instanceof VirtualRootNode)
      ? container
      : new VirtualRootNode(container),
  );
  return elementNode;
}
