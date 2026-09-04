export function isHTMLAnchorElement(
  input: Node,
): input is HTMLAnchorElement {
  return (input instanceof HTMLAnchorElement);
}

