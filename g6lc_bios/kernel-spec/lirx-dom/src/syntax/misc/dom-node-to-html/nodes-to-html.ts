import { ILines } from '../lines/lines.type';
import { nodeToHTML } from './node-to-html';

export function nodesToHTML(
  nodes: ArrayLike<Node>,
): ILines {
  const lines: ILines = [];
  for (let i = 0, l = nodes.length; i < l; i++) {
    lines.push(...nodeToHTML(nodes[i]));
  }
  return lines;
}
