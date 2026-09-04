import { getElementTagName } from '../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { indentLines } from '../lines/functions/indent-lines';
import { ILines } from '../lines/lines.type';
import { attributesToHTML } from './attributes-to-html';
import { nodesToHTML } from './nodes-to-html';

export function elementNodeToHTML(
  node: Element,
): ILines {
  const lines: ILines = [];
  const tagName: string = getElementTagName(node);

  const attributesLines: ILines = attributesToHTML(node.attributes);
  const childLines: ILines = nodesToHTML(node.childNodes);

  if (attributesLines.length > 0) {
    if (childLines.length > 0) {
      lines.push(
        `<${tagName}`,
        ...indentLines(attributesLines),
        `>`,
        ...indentLines(childLines),
        `</${tagName}>`,
      );
    } else {
      lines.push(
        `<${tagName}`,
        ...indentLines(attributesLines),
        `></${tagName}>`,
      );
    }
  } else {
    if (childLines.length > 0) {
      lines.push(
        `<${tagName}>`,
        ...indentLines(childLines),
        `</${tagName}>`,
      );
    } else {
      lines.push(
        `<${tagName}></${tagName}>`,
      );
    }
  }

  return lines;
}
