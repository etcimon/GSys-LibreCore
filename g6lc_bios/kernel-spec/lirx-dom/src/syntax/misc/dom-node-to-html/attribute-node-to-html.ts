import { ILines } from '../lines/lines.type';

export function attributeNodeToHTML(
  node: Attr,
): ILines {
  return [
    `${node.name}${(node.value === '') ? '' : `=${JSON.stringify(node.value)}`}`,
  ];
}
