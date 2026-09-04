import { ILines } from '../lines/lines.type';

export function textNodeToHTML(
  node: Text,
  discardIfWhiteSpaceOnly: boolean = true,
): ILines {
  if (
    discardIfWhiteSpaceOnly
    && (node.data.trim() === '')
  ) {
    return [];
  } else {
    return [
      node.data,
    ];
  }
}
