import {
  IApplyNodeModifierEntry,
  IApplyNodeModifierList,
  IApplyNodeModifiersFunction,
} from '../../../dom-manipulation/modifiers/types/apply-node-modifiers-function.type';
import {
  IGenericVirtualDOMNodeModifier,
} from '../../../dom-manipulation/modifiers/virtual-dom-node-modifier/virtual-dom-node-modifier.type';
import { VirtualDOMNode } from '../../../dom-manipulation/virtual-nodes/virtual-dom-node/virtual-dom-node.class';

export type IGenericVirtualDOMNodeModifierList = readonly IGenericVirtualDOMNodeModifier[];

interface IApplyNodeModifierNormalizedEntry {
  readonly weight: number,
  readonly apply: (node: VirtualDOMNode) => VirtualDOMNode,
}

export function generateApplyNodeModifiersFunctionFromModifierList(
  modifiers: IGenericVirtualDOMNodeModifierList = [],
): IApplyNodeModifiersFunction {
  const modifiersElementsMap = new Map<string, IGenericVirtualDOMNodeModifier>(
    modifiers.map((modifier: IGenericVirtualDOMNodeModifier): [string, IGenericVirtualDOMNodeModifier] => {
      return [modifier.name, modifier];
    }),
  );

  return (
    node: VirtualDOMNode,
    modifiers: IApplyNodeModifierList,
  ): VirtualDOMNode => {
    return modifiers
      .map(([weight, name, value]: IApplyNodeModifierEntry): IApplyNodeModifierNormalizedEntry => {
        if (modifiersElementsMap.has(name)) {
          const modifier: IGenericVirtualDOMNodeModifier = modifiersElementsMap.get(name)!;
          return {
            weight: weight ?? modifier.weight,
            apply: (node: VirtualDOMNode): VirtualDOMNode => {
              return modifier.apply(node, value);
            },
          };
        } else {
          throw new Error(`Missing import of modifier '${name}'`);
        }
      })
      .sort((a: IApplyNodeModifierNormalizedEntry, b: IApplyNodeModifierNormalizedEntry): number => {
        return a.weight - b.weight;
      })
      .reduce((node: VirtualDOMNode, { apply }: IApplyNodeModifierNormalizedEntry): VirtualDOMNode => {
        return apply(node);
      }, node);
  };
}
