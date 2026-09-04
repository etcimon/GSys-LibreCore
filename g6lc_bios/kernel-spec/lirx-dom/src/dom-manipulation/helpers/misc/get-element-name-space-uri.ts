import { HTML_NAMESPACE_URI_CONSTANT } from '../../misc/namespace-uri/html-namespace-uri.constant';

export function getElementNameSpaceURI(
  node: Element,
): string {
  return node.namespaceURI ?? HTML_NAMESPACE_URI_CONSTANT;
}

