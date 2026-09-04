import { VirtualDOMNode } from '../../../virtual-dom-node/virtual-dom-node.class';
import { virtualDOMNodeQuerySelectorIterator } from './virtual-dom-node-query-selector-iterator';

export function virtualDOMNodeQuerySelector<GNode extends VirtualDOMNode>(
  node: VirtualDOMNode,
  selector: string,
): GNode | null {
  const iterator: Generator<GNode> = virtualDOMNodeQuerySelectorIterator<GNode>(node, selector);
  const result: IteratorResult<GNode> = iterator.next();
  iterator.return(void 0);
  return result.done
    ? null
    : result.value;
}

export function virtualDOMNodeQuerySelectorOrThrow<GNode extends VirtualDOMNode>(
  node: VirtualDOMNode,
  selector: string,
): GNode {
  const selectedNode: GNode | null = virtualDOMNodeQuerySelector<GNode>(node, selector);
  if (selectedNode === null) {
    throw new Error(`Failed to select element`);
  } else {
    return selectedNode;
  }
}
