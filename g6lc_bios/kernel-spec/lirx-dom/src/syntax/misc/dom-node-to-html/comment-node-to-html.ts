import { ILines } from '../lines/lines.type';

export function commentNodeToHTML(
  node: Comment,
): ILines {
  return [
    `<!--${node.data}-->`,
  ];
}
