export function isHTMLInputElement(
  input: Node,
): input is HTMLInputElement {
  return (input instanceof HTMLInputElement);
}
