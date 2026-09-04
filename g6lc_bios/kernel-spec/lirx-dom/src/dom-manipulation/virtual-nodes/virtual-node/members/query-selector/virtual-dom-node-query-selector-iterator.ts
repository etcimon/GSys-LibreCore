import { querySelectorIterator } from '../../../../helpers/query-selector/query-selector-iterator';
import { VirtualDOMNode } from '../../../virtual-dom-node/virtual-dom-node.class';
import { getLinkedVirtualDOMNodeOfDOMNodeOrThrow } from '../link/link-dom-node-with-virtual-dom-node';

export function* virtualDOMNodeQuerySelectorIterator<GNode extends VirtualDOMNode>(
  node: VirtualDOMNode,
  selector: string,
): Generator<GNode> {
  const domNodes: readonly Node[] = node.getSelfDOMNodes();
  for (let i = 0, l = domNodes.length; i < l; i++) {
    const iterator: Generator<Element> = querySelectorIterator(domNodes[i], selector);
    try {
      let result: IteratorResult<Element>;
      while (!(result = iterator.next()).done) {
        yield getLinkedVirtualDOMNodeOfDOMNodeOrThrow(result.value) as GNode;
      }
    } finally {
      iterator.return(void 0);
    }
  }
}
