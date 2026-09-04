import { IGenericAbstractComponent } from '../../classes/abstract-component.class';
import { IGenericCreateCustomElementFunction } from './create-custom-element-function.type';
import {
  IVirtualComponentNodeSlotsMap,
} from '../../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { VirtualComponentNode } from '../../../dom-manipulation/virtual-nodes/virtual-component-node/virtual-component-node.class';

export type IGenericAbstractComponentList = readonly IGenericAbstractComponent[];

export function generateCreateCustomElementFunctionFromComponentList(
  components: IGenericAbstractComponentList = [],
): IGenericCreateCustomElementFunction {
  const customElementsMap = new Map<string, IGenericAbstractComponent>(
    components.map((customElement: IGenericAbstractComponent): [string, IGenericAbstractComponent] => {
      return [customElement.name, customElement];
    }),
  );

  return (
    name: string,
    slots?: IVirtualComponentNodeSlotsMap,
  ): VirtualComponentNode<any, any> => {
    if (customElementsMap.has(name)) {
      return customElementsMap.get(name)!.create(slots);
    } else {
      throw new Error(`Missing import of component '${name}'`);
    }
  };
}
