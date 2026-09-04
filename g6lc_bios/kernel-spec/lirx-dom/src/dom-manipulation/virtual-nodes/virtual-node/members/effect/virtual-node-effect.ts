import { effect, IEffetFunction } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import { VirtualNode } from '../../virtual-node.class';

export function virtualNodeEffect(
  node: VirtualNode,
  effectFunction: IEffetFunction,
): IUnsubscribe {
  return node.onConnected((): IUnsubscribe => {
    return effect(effectFunction);
  });
}
