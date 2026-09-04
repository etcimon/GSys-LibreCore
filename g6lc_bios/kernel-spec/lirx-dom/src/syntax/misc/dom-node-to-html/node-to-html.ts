import { ILines } from '../lines/lines.type';
import { attributeNodeToHTML } from './attribute-node-to-html';
import { commentNodeToHTML } from './comment-node-to-html';
import { elementNodeToHTML } from './element-node-to-html';
import { textNodeToHTML } from './text-node-to-html';

export function nodeToHTML(
  node: Node,
): ILines {
  switch (node.nodeType) {
    case Node.ATTRIBUTE_NODE:
      return attributeNodeToHTML(node as Attr);
    case Node.TEXT_NODE:
      return textNodeToHTML(node as Text);
    case Node.COMMENT_NODE:
      return commentNodeToHTML(node as Comment);
    case Node.ELEMENT_NODE:
      return elementNodeToHTML(node as Element);
    default:
      throw new Error(`Unsupported node`);
  }
}
