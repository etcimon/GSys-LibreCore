import { VirtualDOMNode } from '../../virtual-nodes/virtual-dom-node/virtual-dom-node.class';

export type IApplyNodeModifierEntry = readonly [
  weigth: number | undefined,
  name: string,
  value: any,
];

export type IApplyNodeModifierList = readonly IApplyNodeModifierEntry[];

export interface IApplyNodeModifiersFunction {
  (
    node: VirtualDOMNode,
    modifiers: IApplyNodeModifierList,
  ): VirtualDOMNode;
}
