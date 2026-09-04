export function isHTMLAreaElement(
  input: Node,
): input is HTMLAreaElement {
  return (input instanceof HTMLAreaElement);
}
