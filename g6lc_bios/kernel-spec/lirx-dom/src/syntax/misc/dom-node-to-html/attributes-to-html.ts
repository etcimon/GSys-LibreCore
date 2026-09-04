import { ILines } from '../lines/lines.type';
import { attributeNodeToHTML } from './attribute-node-to-html';
import { nodesToHTML } from './nodes-to-html';

export function attributesToHTML(
  nodes: ArrayLike<Attr>,
): ILines {
  const lines: ILines = [];
  for (let i = 0, l = nodes.length; i < l; i++) {
    lines.push(...attributeNodeToHTML(nodes[i]));
  }
  return nodesToHTML(nodes);
}
